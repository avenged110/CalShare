// MARK: - Supervisor.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Owns every moving part — storage, certificates, both listeners, Bonjour, backups — keeps
// each one healthy, and describes their state for the dashboard.
//
// Self-healing, in one place:
//   • Listeners that fail are restarted with exponential backoff (2 s … 5 min).
//   • A periodic self-probe makes a real HTTPS request to the server; two misses in a row
//     restart it.
//   • The server certificate is reissued when it nears expiry or when the Mac's names or
//     addresses change. Devices trust the authority, so they never notice.
//   • A damaged database is set aside and the newest verified backup restored, at launch or
//     whenever a storage error suggests corruption.
//   • A damaged settings file is set aside and defaults used.
//   • Accounts missing their default address book get it back.
//   • Problems no component owns — cut-off responses, unexpected errors, stalled requests,
//     a device re-downloading the same listing — are kept for a day and shown on the Sync
//     Reliability card, so the dashboard never reads healthy while devices miss data. A burst
//     of them restarts the server, at most once an hour.
//   • Error-level log messages from anywhere in the app (Logger's observer) become faults
//     too, so an error nobody wired to a card still shows.
//   • A watchdog on its own queue notices when this one stops responding, which would
//     otherwise freeze the dashboard on its last, possibly healthy, report.
//   • A 2 MB test transfer checks every few minutes that the server sends large responses
//     whole; two failures in a row
//     restart the server.

import Foundation
import Security

public enum HealthState: String, Sendable, Comparable {
    /// `notice`: working, with something worth knowing; never a problem.
    case ok, working, off, notice, warning, error

    var rank: Int { switch self { case .ok: 0; case .off: 1; case .notice: 2; case .working: 3; case .warning: 4; case .error: 5 } }
    public static func < (lhs: HealthState, rhs: HealthState) -> Bool { lhs.rank < rhs.rank }
}

public enum FixAction: String, Sendable {
    case restartServer, useNextFreePort, reissueCertificate, backupNow, restartBonjour, repairDatabase, clearLockouts, checkNetworkAccess
    /// Points devices at the .local name, after the IP address they used went away.
    case useLocalName
    /// Dismisses the notice that the IP address changed.
    case acknowledgeAddressChange
    /// Runs the large-transfer test now.
    case testDelivery
    /// Clears the problems shown on the Sync Reliability card.
    case dismissFaults
    /// Handled by the app, which can ask macOS (and the user) to trust the authority.
    case trustOnThisMac
}

public struct ComponentHealth: Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var symbol: String
    public var state: HealthState
    public var summary: String
    public var detail: String?
    public var fix: FixAction?
    public var fixTitle: String?

    public init(id: String, title: String, symbol: String, state: HealthState, summary: String,
                detail: String? = nil, fix: FixAction? = nil, fixTitle: String? = nil) {
        self.id = id; self.title = title; self.symbol = symbol; self.state = state
        self.summary = summary; self.detail = detail; self.fix = fix; self.fixTitle = fixTitle
    }

    /// Every component the Supervisor reports, in its order, as it reads before the first
    /// report: the dashboard lays these out at once and fills them in as reports arrive.
    public static let placeholders: [ComponentHealth] = [
        ("server", "Calendar & Contacts Server", "server.rack"),
        ("setup", "Device Setup Service", "qrcode"),
        ("certificate", "Secure Connection", "lock.shield"),
        ("access", "Network Access", "network.badge.shield.half.filled"),
        ("delivery", "Sync Reliability", "arrow.down.circle.dotted"),
        ("network", "Network Name", "network"),
        ("bonjour", "Bonjour Discovery", "dot.radiowaves.left.and.right"),
        ("database", "Database", "cylinder.split.1x2"),
        ("backups", "Backups", "clock.arrow.circlepath"),
        ("accounts", "Accounts & Sign-In", "person.2"),
    ].map { ComponentHealth(id: $0.0, title: $0.1, symbol: $0.2, state: .working, summary: "Starting…") }
}

public struct ActivityEvent: Sendable, Identifiable, Equatable {
    public enum Level: String, Sendable { case info, success, warning, error }
    public let id = UUID()
    public var date: Date
    public var level: Level
    public var message: String
}

public struct CollectionSummary: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var kind: CollectionKind
    public var displayName: String
    public var color: String
    public var components: [String]
    public var itemCount: Int
}

public struct AccountSummary: Sendable, Equatable, Identifiable {
    public var id: String { username }
    public var username: String
    public var displayName: String
    public var createdAt: Date
    public var collections: [CollectionSummary]
}

public struct SupervisorSnapshot: Sendable, Equatable {
    public var configuration = ServerConfiguration()
    public var health: [ComponentHealth] = []
    public var network = NetworkSnapshot(localHostName: "", computerName: "", addresses: [])
    public var httpsPort: UInt16?
    public var httpPort: UInt16?
    public var deviceHostname = ""
    public var hostnameChoices: [String] = []
    public var authorityFingerprint = ""
    /// The names the authority may vouch for; a remote hostname outside them needs a new one.
    public var authorityPermittedNames: [String] = []
    public var certificateNames: [String] = []
    public var certificateExpiry: Date?
    public var accounts: [AccountSummary] = []
    public var statistics = StoreStatistics()
    public var backups: [BackupRecord] = []
    public var events: [ActivityEvent] = []
    public var requests: [RequestLogEntry] = []
    public var clients: [ClientRecord] = []
    public var lockedOutAddresses: [String] = []
    /// Setup links used so far; a page showing one replaces it when this changes.
    public var enrollmentUses = 0
    public var dataDirectory: URL?
    /// Whether this Mac's own trust settings accept the server certificate, the way
    /// Calendar and Contacts check it; nil until certificates exist.
    public var trustedOnThisMac: Bool?

    public init() {}

    public var overallState: HealthState { health.map(\.state).max() ?? .working }

    /// Whether a client connected from this Mac itself.
    public func isThisMac(_ client: ClientRecord) -> Bool { network.isLocal(client.remoteAddress) }

    /// Calendar, Reminders, or Contacts on this Mac, as opposed to another Mac.
    public var thisMacClients: [ClientRecord] { clients.filter { $0.platform.hasPrefix("macOS") && isThisMac($0) } }

    /// Calendar, Reminders, or Contacts on any other Mac.
    public var otherMacClients: [ClientRecord] { clients.filter { $0.platform.hasPrefix("macOS") && !isThisMac($0) } }

    /// iPhones and iPads. Only remote addresses count: a Mac service can describe itself
    /// with an iOS-style user agent, and an iPhone is never this Mac.
    public var mobileClients: [ClientRecord] {
        clients.filter { ($0.platform.hasPrefix("iOS") || $0.platform.hasPrefix("iPadOS")) && !isThisMac($0) }
    }
    public var serverURL: String { httpsPort.map { "https://\(deviceHostname):\($0)/" } ?? "" }
}

public struct CalSharePaths: Sendable {
    public var base: URL
    public var database: URL { base.appendingPathComponent("calshare.sqlite") }
    public var configuration: URL { base.appendingPathComponent("config.json") }
    /// The devices that have signed in, so they are still known after a relaunch.
    public var clients: URL { base.appendingPathComponent("clients.json") }
    public var backups: URL { base.appendingPathComponent("Backups", isDirectory: true) }
    public var certificates: URL { base.appendingPathComponent("Certificates", isDirectory: true) }
    public var damaged: URL { base.appendingPathComponent("Damaged", isDirectory: true) }

    public init(base: URL) { self.base = base }

    /// The sandbox container's Application Support folder itself: the container already
    /// belongs to CalShare alone, so a folder of its own would only add a level.
    public static var standard: CalSharePaths {
        CalSharePaths(base: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!)
    }

    /// Everything CalShare keeps in `base`. The folder also holds macOS's own links
    /// (AddressBook, iCloud…), so erasing removes these and nothing else.
    var ownedItems: [URL] {
        [database, URL(fileURLWithPath: database.path + "-wal"), URL(fileURLWithPath: database.path + "-shm"),
         configuration, clients, backups, certificates, damaged]
    }

    /// Moves the data of earlier versions up out of `base/CalShare/`. Runs before anything
    /// opens a file. Folders present in both places are merged; a file already at the new
    /// location is left alone, and anything left over stays in the old folder.
    func migrateFromLegacyFolder() {
        Self.merge(base.appendingPathComponent("CalShare", isDirectory: true), into: base)
    }

    private static func merge(_ source: URL, into destination: URL) {
        let files = FileManager.default
        guard let items = try? files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent != ".DS_Store" {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            // Resource values rather than fileExists(atPath:isDirectory:) and its ObjCBool
            // pointer; resolving first follows a link the way fileExists does.
            if let existing = try? target.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]) {
                if existing.isDirectory == true { merge(item, into: target) }
            } else {
                try? files.moveItem(at: item, to: target)
            }
        }
        let remaining = (try? files.contentsOfDirectory(atPath: source.path))?.filter { $0 != ".DS_Store" } ?? []
        if remaining.isEmpty { try? files.removeItem(at: source) }
    }
}

public enum AccountError: Error, CustomStringConvertible {
    case weakPassword
    case store(StoreError)
    case notReady

    public var description: String {
        switch self {
        case .weakPassword: "Use a password of at least 8 characters."
        case .store(let error): error.description
        case .notReady: "The server is still starting. Try again in a moment."
        }
    }
}

/// A restore or deletion refused because the backup taken first failed.
public struct SafetyBackupError: Error, CustomStringConvertible {
    /// What would have happened: "restored", "deleted".
    public var undone: String
    public var reason: String

    public var description: String { "The current data couldn't be backed up first, so nothing was \(undone). (\(reason))" }
}

/// Why a port change was refused. The ports in use are left as they were.
public enum PortChangeError: Error, CustomStringConvertible {
    case reserved(UInt16)
    case same(UInt16)
    case inUse(UInt16)

    public var description: String {
        switch self {
        case .reserved(let port): "Port \(port) is reserved by macOS. Choose a port from 1024 to 65535."
        case .same(let port): "The secure port and the setup port can't both be \(port)."
        case .inUse(let port): "Port \(port) is already in use by another application."
        }
    }
}

public final class Supervisor: @unchecked Sendable, Loggable {
    public static let logTag = "[Supervisor]"

    public struct Options: Sendable {
        public var advertiseBonjour = true
        public var watchNetwork = true
        public var maintenanceInterval: TimeInterval = 300
        public var manageProcessActivity = true
        /// How long the Supervisor may go without responding before the watchdog reports
        /// it. Its longest legitimate work (a backup, a restore, a new certificate) takes
        /// seconds.
        public var stallThreshold: TimeInterval = 60
        public init() {}
    }

    public let paths: CalSharePaths
    public let options: Options
    private let queue = DispatchQueue(label: "CalShare.Supervisor")
    /// Self-probes wait on network round trips; they run here so `queue`, which every
    /// dashboard call goes through, is never held up by one.
    private let probeQueue = DispatchQueue(label: "CalShare.Supervisor.Probe")
    private var probeInFlight = false
    private var probeWaiters: [@Sendable () -> Void] = []
    private var trustCheck: (date: Date, trusted: Bool)?
    /// When each device was last written to `paths.clients`.
    private var savedClients: [String: Date] = [:]

    // Everything below is touched only on `queue`, except where a Locked box says otherwise.
    private var configuration = ServerConfiguration()
    private let configurationStore: ConfigurationStore
    private(set) public var store: Store?
    private var authenticator: Authenticator?
    private(set) public var davHandler: DAVHandler?
    private var enrollment: EnrollmentHandler!
    private var httpsServer: HTTPServer?
    private var httpServer: HTTPServer?
    private let bonjour = BonjourAdvertiser()
    private var watcher: NetworkWatcher?
    private var maintenanceTimer: DispatchSourceTimer?
    private var accessTimer: DispatchSourceTimer?
    private var authority: CertificateMaterial?
    private var serverCertificate: CertificateMaterial?
    private let certificateStore: CertificateStore
    private let backups: BackupManager
    private var network = NetworkEnvironment.snapshot()
    private var restartAttempts: [String: Int] = [:]
    private var probeFailures = 0
    /// Problems noticed while serving; see Faults.swift.
    private var faults = FaultLedger()
    private var repeats = RepeatDetector()
    /// The last large-transfer test: when, over which address, and why it failed, if it did.
    private var deliveryTest: (date: Date, host: String, failure: String?)?
    private var deliveryFailures = 0
    private var deliveryInFlight = false
    private var deliveryWaiters: [@Sendable () -> Void] = []
    /// Set at launch and on network changes, so a test follows the next reachability check.
    private var deliveryTestDue = true
    /// When the server was last restarted because of faults; restarts are at most hourly.
    private var lastFaultRestart: Date?
    /// Admits the large-transfer test, and nothing else, to its endpoint.
    private let deliveryToken = UUID().uuidString
    /// When each fault message was last noted, so one repeating in a loop is noted once a minute.
    private var faultSeen: [String: Date] = [:]
    /// The watchdog's view of `queue`; touched only under its lock.
    private struct WatchdogState { var pingSent: UInt64?; var stalledSince: Date?; var timer: DispatchSourceTimer? }
    private let watchdog = Locked(WatchdogState())
    private let watchdogQueue = DispatchQueue(label: "CalShare.Supervisor.Watchdog")
    /// Whether the server answered on this Mac's network address, the way a device reaches
    /// it; nil until checked or while there is no network address.
    private var networkAccessible: Bool?
    private var databaseHealth: (HealthState, String, String?) = (.working, "Opening…", nil)
    private var certificateHealth: (HealthState, String, String?) = (.working, "Preparing…", nil)
    /// The IP address change shown on the Network Name card while devices use the .local
    /// name, until dismissed.
    private var addressChange: (from: String, to: String)?
    private var lastBackupAttempt: Date?
    private var lastBackupError: String?
    private var running = false
    private var activity: (any NSObjectProtocol)?

    private let dirty = Locked(false)
    private let eventLog = Locked<[ActivityEvent]>([])
    private let requestLog = Locked<[RequestLogEntry]>([])
    private let snapshotCache = Locked<SupervisorSnapshot?>(nil)
    private let notifyPending = Locked(false)
    /// Called (on a background queue, coalesced) whenever anything the dashboard shows changes.
    public let onUpdate = Locked<(@Sendable () -> Void)?>(nil)
    /// Called on the watchdog's queue when the Supervisor stops responding (with when it
    /// stopped) and when it responds again (nil). Nothing that waits on the Supervisor may
    /// run here: it is the one report that has to get out while the Supervisor is stuck.
    public let onStall = Locked<(@Sendable (Date?) -> Void)?>(nil)
    /// When the Supervisor stopped responding, while it hasn't; never waits on it.
    public var stalledSince: Date? { watchdog.current.stalledSince }

    public init(paths: CalSharePaths = .standard, options: Options = Options()) {
        self.paths = paths
        self.options = options
        paths.migrateFromLegacyFolder()
        configurationStore = ConfigurationStore(url: paths.configuration)
        certificateStore = CertificateStore(directory: paths.certificates)
        backups = BackupManager(directory: paths.backups)
        enrollment = EnrollmentHandler(
            profileProvider: { [weak self] username in self?.profileData(for: username, password: nil) },
            authorityProvider: { [weak self] in self?.queue.sync { self?.authority?.certificateDER } },
            secureEndpoint: { [weak self] in
                guard let self else { return (8443, "localhost") }
                return self.queue.sync { (self.activeHTTPSPort ?? self.configuration.httpsPort, self.deviceHostname) }
            })
        enrollment.onEnrollment.withLock { handler in
            handler = { [weak self] username, address in self?.record(.info, "A device at \(address) downloaded the setup profile for “\(username)”.") }
        }
    }

    // MARK: Events

    public func record(_ level: ActivityEvent.Level, _ message: String) {
        eventLog.withLock { events in
            events.insert(ActivityEvent(date: Date(), level: level, message: message), at: 0)
            if events.count > 300 { events.removeLast(events.count - 300) }
        }
        log(message, level: level == .error ? .error : level == .warning ? .warning : .info)
        changed()
    }

    /// Coalesces bursts of changes into one update notification.
    private func changed() {
        let shouldSchedule = notifyPending.withLock { pending -> Bool in
            if pending { return false }
            pending = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.notifyPending.withLock { $0 = false }
            self.onUpdate.current?()
        }
    }

    // MARK: Lifecycle

    public func start() {
        startWatchdog()
        queue.async { [self] in
            guard !running else { return }
            running = true
            Self.current.withLock { $0 = self }
            try? FileManager.default.createDirectory(at: paths.base, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let (loaded, recovery) = configurationStore.load()
            configuration = loaded
            if let recovery { record(.warning, recovery) }
            network = NetworkEnvironment.snapshot()
            migrateAutomaticIdentity()
            trackLANAddress()
            openStore()
            ensureCertificates()
            startServers()
            advertise()
            updateProcessActivity()
            if options.watchNetwork {
                watcher = NetworkWatcher { [weak self] in
                    guard let self else { return }
                    self.queue.async { self.networkChanged() }
                }
                watcher?.start()
            }
            scheduleMaintenance()
            scheduleNetworkAccessCheck()
            if options.watchNetwork { scheduleNetworkAccessTimer() }
            record(.info, "CalShare started.")
        }
    }

    public func stop() { stop(backingUp: true) }

    private func stop(backingUp: Bool) {
        // Before the queue, which a final backup can hold for a while: that's a stop, not a stall.
        stopWatchdog()
        queue.sync {
            guard running else { return }
            running = false
            Self.current.withLock { if $0 === self { $0 = nil } }
            maintenanceTimer?.cancel()
            maintenanceTimer = nil
            accessTimer?.cancel()
            accessTimer = nil
            watcher?.stop()
            watcher = nil
            bonjour.stop()
            httpsServer?.stop()
            httpServer?.stop()
            httpsServer = nil
            httpServer = nil
            saveClients()
            if backingUp, dirty.current, let store { _ = try? backups.create(from: store, kind: "auto") }
            store?.checkpoint()
            store?.close()
            store = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
        log("Stopped")
    }

    #if DEBUG
    /// Stops everything without a final backup and deletes all of CalShare's data: the
    /// database, backups, certificates, and settings. The supervisor stays stopped; the app
    /// quits afterward. For "Reset for Testing", which exists only in debug builds.
    public func eraseAllData() throws {
        stop(backingUp: false)
        enrollment.tokens.withLock { $0.removeAll() }
        for item in paths.ownedItems where FileManager.default.fileExists(atPath: item.path) {
            try FileManager.default.removeItem(at: item)
        }
        log("Erased all data", level: .warning)
    }
    #endif

    /// Runs `body` on the supervisor queue and waits; for the app's settings actions.
    private func sync<R>(_ body: () throws -> R) rethrows -> R { try queue.sync(execute: body) }

    // MARK: Storage

    private func openStore() {
        databaseHealth = (.working, "Opening…", nil)
        do {
            let store = try Store(url: paths.database)
            guard store.quickCheck() else {
                store.close()
                throw SQLiteError(code: 11, message: "The integrity check failed")
            }
            install(store)
            databaseHealth = (.ok, "Healthy", nil)
        } catch let error as SQLiteError where error.isCorruption {
            recoverDatabase(reason: error.description)
        } catch {
            databaseHealth = (.error, "Could not open the database", "\(error)")
            record(.error, "The database could not be opened: \(error). CalShare will retry.")
        }
    }

    private func install(_ store: Store) {
        self.store = store
        store.onChange.withLock { handler in
            handler = { [weak self] in self?.dirty.withLock { $0 = true }; self?.changed() }
        }
        let authenticator = Authenticator(store: store)
        authenticator.onLockout.withLock { handler in handler = { [weak self] message in self?.record(.warning, message) } }
        self.authenticator = authenticator
        let handler = DAVHandler(store: store, authenticator: authenticator)
        // Devices seen before a relaunch (or by the handler this one replaces) are still known.
        let known = davHandler?.clients.current ?? loadClients()
        handler.clients.withLock { $0 = known }
        handler.onUnreadableResource.withLock { callback in
            callback = { [weak self] message in self?.queue.async { self?.fault(.unreadableData, message) } }
        }
        handler.onRequest.withLock { callback in
            callback = { [weak self] entry in
                guard let self else { return }
                self.requestLog.withLock { log in
                    log.insert(entry, at: 0)
                    if log.count > 200 { log.removeLast(log.count - 200) }
                }
                self.queue.async { self.requestFinished(entry) }
                self.changed()
            }
        }
        davHandler = handler
        // Self-heal: every account keeps at least one address book.
        for user in (try? store.users()) ?? [] where ((try? store.collections(ownerID: user.id, kind: .addressBook)) ?? []).isEmpty {
            _ = try? store.createCollection(ownerID: user.id, kind: .addressBook, uri: "contacts", displayName: "Contacts")
            record(.warning, "Recreated the missing address book for “\(user.username)”.")
        }
    }

    /// Sets the damaged database aside and restores the newest backup that verifies.
    private func recoverDatabase(reason: String) {
        store?.close()
        store = nil
        let stamp = Int(Date().timeIntervalSince1970)
        let folder = paths.damaged.appendingPathComponent("\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: paths.database.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.moveItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
            }
        }
        record(.error, "The database was damaged (\(reason)). It was moved aside to Damaged/\(stamp).")
        for candidate in backups.list() where BackupManager.verify(candidate.url) {
            do {
                try FileManager.default.copyItem(at: candidate.url, to: paths.database)
                let store = try Store(url: paths.database)
                try store.renewSyncEpoch()
                install(store)
                let when = DateFormatter.localizedString(from: candidate.date, dateStyle: .medium, timeStyle: .short)
                databaseHealth = (.warning, "Restored from backup", "Recovered automatically from the backup taken \(when). Each device syncs again in full to match it.")
                record(.success, "Restored the database from the backup taken \(when).")
                return
            } catch {
                try? FileManager.default.removeItem(at: paths.database)
            }
        }
        do {
            let store = try Store(url: paths.database)
            // A fresh database reuses collection IDs and counters too.
            try store.renewSyncEpoch()
            install(store)
            databaseHealth = (.error, "Started with an empty database", "No usable backup was found. Your devices still have their copies; re-adding the account will upload them again.")
            record(.error, "No usable backup was found; started a new, empty database.")
        } catch {
            databaseHealth = (.error, "Could not create a database", "\(error)")
        }
    }

    private func storageErrorObserved() {
        guard let store, running else { return }
        if !store.quickCheck() {
            httpsServer?.stop()
            httpsServer = nil
            recoverDatabase(reason: "integrity check failed while serving")
            startServers()
        }
    }

    // MARK: Certificates

    private var desiredNames: [String] {
        var names: [String] = []
        if !network.bonjourHostName.isEmpty { names.append(network.bonjourHostName.lowercased()) }
        names += configuration.customHostnames.map { $0.lowercased() }
        names.append("localhost")
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private var desiredAddresses: [String] {
        var seen = Set<String>()
        // Only addresses the authority may vouch for: one outside its constraints would make
        // devices reject the whole certificate.
        return (network.usableAddresses.map(\.address) + ["127.0.0.1", "::1"])
            .filter { NameConstraints.permits(address: $0) && seen.insert($0).inserted }
    }

    private func ensureCertificates(force: Bool = false) {
        do {
            var authorityIsNew = false
            if authority == nil { authority = certificateStore.load("authority") }
            var authorityReason: String?
            if let current = authority {
                if current.notAfter < Date().addingTimeInterval(30 * 86_400) { authorityReason = "the old one expires soon" }
                // Made before authorities were limited to this Mac's own names.
                else if current.names.isEmpty { authorityReason = "the old one wasn't limited to this Mac's names" }
                else if !desiredNames.allSatisfy({ NameConstraints.permits(name: $0, within: current.names) }) {
                    authorityReason = "a remote hostname was added that the old one doesn't cover"
                }
            }
            if authority == nil || authorityReason != nil {
                let name = "CalShare Local Authority (\(network.computerName.isEmpty ? "Mac" : network.computerName))"
                authority = try CertificateBuilder.makeAuthority(
                    commonName: name, permittedNames: NameConstraints.names(customHostnames: configuration.customHostnames))
                try certificateStore.save(authority!, as: "authority")
                try Data(name.utf8).write(to: paths.certificates.appendingPathComponent("authority-name.txt"), options: .atomic)
                authorityIsNew = true
                serverCertificate = nil
                record(.info, "Created a new certificate authority for this Mac\(authorityReason.map { ", because \($0)" } ?? "").")
            }
            guard let authority else { return }
            let authorityName = (try? String(contentsOf: paths.certificates.appendingPathComponent("authority-name.txt"), encoding: .utf8))
                ?? "CalShare Local Authority"
            if serverCertificate == nil, !authorityIsNew { serverCertificate = certificateStore.load("server") }
            let names = desiredNames
            let addresses = desiredAddresses
            var reason: String?
            if force { reason = "requested" }
            else if let current = serverCertificate {
                if current.notAfter < Date().addingTimeInterval(30 * 86_400) { reason = "it expires soon" }
                else if Set(current.names) != Set(names) { reason = "this Mac's names changed" }
                else if !Set(addresses).isSubset(of: Set(current.addresses)) { reason = "this Mac's network addresses changed" }
                else if !CertificateBuilder.evaluate(current, authority: authority, hostname: names.first ?? "localhost") { reason = "it no longer validates" }
            } else {
                reason = "none existed"
            }
            if let reason {
                let issued = try CertificateBuilder.makeServerCertificate(names: names, addresses: addresses, authority: authority,
                                                                         authorityName: authorityName)
                try certificateStore.save(issued, as: "server")
                serverCertificate = issued
                // This Mac's trust was checked against the old certificate (and maybe the old
                // authority), so the dashboard mustn't keep showing that answer.
                trustCheck = nil
                if httpsServer != nil {
                    httpsServer?.stop()
                    httpsServer = nil
                    startServers()
                }
                record(.info, "Issued a new server certificate because \(reason).")
            }
            certificateHealth = (.ok, "Valid until \(DateFormatter.localizedString(from: serverCertificate!.notAfter, dateStyle: .medium, timeStyle: .none))",
                                 "Covers \((serverCertificate!.names + serverCertificate!.addresses).joined(separator: ", ")). Renewed automatically.")
            if authorityIsNew, (try? store?.users().isEmpty) == false {
                record(.warning, "Devices set up earlier must be set up again, because the certificate authority was replaced: other Macs run the new Terminal command, then every device installs a fresh setup profile.")
            }
        } catch {
            certificateHealth = (.error, "Could not create certificates", "\(error)")
            record(.error, "Certificate creation failed: \(error)")
        }
    }

    // MARK: Servers

    private var activeHTTPSPort: UInt16? {
        if case .ready(let port) = httpsServer?.state.current { return port }
        return nil
    }

    private var activeHTTPPort: UInt16? {
        if case .ready(let port) = httpServer?.state.current { return port }
        return nil
    }

    private func startServers() {
        guard running else { return }
        if httpsServer == nil, let davHandler, let serverCertificate,
           let identity = CertificateBuilder.identity(for: serverCertificate) {
            let chain = authority.flatMap { SecCertificateCreateWithData(nil, $0.certificateDER as CFData) }.map { [$0] } ?? []
            let enrollment = self.enrollment!
            let token = deliveryToken
            let server = HTTPServer(name: "HTTPS", port: configuration.httpsPort, identity: identity, chain: chain) { request in
                if request.path == SelfProbe.deliveryPath {
                    return request.headers[SelfProbe.tokenHeader] == token ? SelfProbe.deliveryResponse : .text(404, "Not Found")
                }
                // Setup links for a Mac that already trusts the authority come here, so the
                // profile can't be tampered with on the way.
                return request.path.hasPrefix("/enroll/") ? enrollment.handle(request) : davHandler.handle(request)
            }
            observe(server, key: "https")
            server.onSendFailure.withLock { callback in
                callback = { [weak self] message in self?.queue.async { self?.fault(.cutOff, message) } }
            }
            httpsServer = server
            server.start()
        }
        if httpServer == nil {
            let enrollment = self.enrollment!
            let server = HTTPServer(name: "HTTP", port: configuration.httpPort, identity: nil) { request in
                enrollment.handle(request)
            }
            server.limits.maxBodyBytes = 64 * 1024
            observe(server, key: "http")
            httpServer = server
            server.start()
        }
    }

    private func observe(_ server: HTTPServer, key: String) {
        server.onStateChange.withLock { handler in
            handler = { [weak self, weak server] state in
                guard let self, let server else { return }
                self.queue.async { self.serverStateChanged(server, key: key, state: state) }
            }
        }
    }

    private func serverStateChanged(_ server: HTTPServer, key: String, state: HTTPServer.State) {
        switch state {
        case .ready:
            if restartAttempts[key, default: 0] > 0 { record(.success, "The \(key.uppercased()) listener recovered.") }
            restartAttempts[key] = 0
            if key == "https" { advertise() }
        case .failed(let message, let addressInUse):
            let isCurrent = (key == "https" ? httpsServer : httpServer) === server
            guard isCurrent, running else { break }
            // Its listener is gone, but connections it accepted are still open; they're
            // closed here, since nothing cancels them once the server is released.
            server.stop()
            if key == "https" { httpsServer = nil } else { httpServer = nil }
            let attempt = restartAttempts[key, default: 0] + 1
            restartAttempts[key] = attempt
            let delay = min(pow(2, Double(attempt)), 300)
            if attempt == 1 || attempt % 5 == 0 {
                record(addressInUse ? .error : .warning,
                       addressInUse ? "Port \(server.requestedPort) is used by another application. Retrying, or choose another port in Settings."
                                    : "The \(key.uppercased()) listener stopped (\(message)). Restarting in \(Int(delay)) s.")
            }
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.startServers() }
        default:
            break
        }
        changed()
    }

    private func restartServers() {
        // Whatever the restart was for, large transfers are checked again soon after.
        deliveryTestDue = true
        httpsServer?.stop()
        httpServer?.stop()
        httpsServer = nil
        httpServer = nil
        restartAttempts = [:]
        startServers()
    }

    // MARK: Bonjour & network

    private func advertise() {
        guard options.advertiseBonjour else { return }
        guard configuration.bonjourEnabled, let port = activeHTTPSPort else { bonjour.stop(); return }
        bonjour.onStatusChange.withLock { handler in handler = { [weak self] in self?.changed() } }
        bonjour.advertise(name: configuration.serverName, port: port)
    }

    private func networkChanged() {
        let fresh = NetworkEnvironment.snapshot()
        guard fresh != network else { return }
        let oldName = network.bonjourHostName
        network = fresh
        if !oldName.isEmpty, oldName != fresh.bonjourHostName {
            record(.warning, "This Mac's network name changed from \(oldName) to \(fresh.bonjourHostName). Devices using the old name need a new setup profile.")
        }
        trackLANAddress()
        ensureCertificates()
        advertise()
        networkAccessible = nil
        trustCheck = nil
        deliveryTestDue = true
        scheduleNetworkAccessCheck()
        changed()
    }

    /// Settings from versions whose automatic identity was the IP address: devices set up
    /// then were given that address, so it becomes the explicit choice, once.
    private func migrateAutomaticIdentity() {
        guard !configuration.automaticIsLocalName else { return }
        let address = configuration.setupCompleted && configuration.preferredHostname == nil ? network.primaryLANAddress : nil
        applyConfiguration {
            $0.automaticIsLocalName = true
            if let address { $0.preferredHostname = address }
        }
    }

    /// Whether devices are given the .local name.
    private var usesLocalName: Bool { configuration.preferredHostname == nil && !network.bonjourHostName.isEmpty }

    /// The IP address devices were given, when it is one this Mac no longer has. Every
    /// device set up with it has stopped syncing.
    private var lostDeviceAddress: String? {
        guard let preferred = configuration.preferredHostname, IPAddressBytes.parse(preferred) != nil,
              network.primaryLANAddress != nil, !network.usableAddresses.contains(where: { $0.address == preferred }) else { return nil }
        return preferred
    }

    /// Notices a new local network IP address, and remembers it.
    private func trackLANAddress() {
        guard let current = network.primaryLANAddress else { return }
        let last = configuration.lastLANAddress
        guard last != current else { return }
        if let last {
            if lostDeviceAddress != nil {
                record(.error, "This Mac's IP address changed from \(last) to \(current). Devices set up with \(configuration.preferredHostname ?? last) can't sync until they can reach it again.")
            } else if usesLocalName {
                addressChange = (last, current)
                record(.info, "This Mac's IP address changed from \(last) to \(current). Devices reach it by its .local name, so they keep syncing.")
            }
        }
        applyConfiguration { $0.lastLANAddress = current }
    }

    // MARK: Maintenance

    /// Re-checks the server and network access every 20 seconds. Nothing in macOS announces
    /// that another app's firewall rules changed, so a light probe (one local request) is
    /// the only way to notice promptly, and a server that stops answering is restarted
    /// within a minute. Network path changes still trigger a check of their own.
    private func scheduleNetworkAccessTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.probe()
            self.saveClients()
        }
        timer.resume()
        accessTimer = timer
    }

    /// Checks network access soon, rather than at the next maintenance pass, once the
    /// listener has had a moment to come up.
    private func scheduleNetworkAccessCheck() {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.running else { return }
            self.probe()
        }
    }

    private func scheduleMaintenance() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: options.maintenanceInterval, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.maintenance() }
        timer.resume()
        maintenanceTimer = timer
    }

    /// Devices are forgotten after this long without signing in.
    static let clientMemory: TimeInterval = 30 * 86_400

    private func loadClients() -> [String: ClientRecord] {
        guard let data = try? Data(contentsOf: paths.clients),
              let records = try? JSONDecoder().decode([ClientRecord].self, from: data) else { return [:] }
        let recent = records.filter { Date().timeIntervalSince($0.lastSeen) < Self.clientMemory }
        savedClients = Dictionary(recent.map { ($0.id, $0.lastSeen) }, uniquingKeysWith: max)
        return Dictionary(recent.map { ($0.id, $0) }, uniquingKeysWith: { $0.lastSeen > $1.lastSeen ? $0 : $1 })
    }

    /// Writes the known devices when one is new, or was last written over a minute before
    /// it was seen again. Runs on the queue.
    private func saveClients() {
        guard let handler = davHandler else { return }
        let records = handler.clients.withLock { clients in
            clients = clients.filter { Date().timeIntervalSince($0.value.lastSeen) < Self.clientMemory }
            return Array(clients.values)
        }
        let changed = records.count != savedClients.count || records.contains { record in
            savedClients[record.id].map { record.lastSeen.timeIntervalSince($0) > 60 } ?? true
        }
        guard changed, let data = try? JSONEncoder().encode(records) else { return }
        do {
            try data.write(to: paths.clients, options: .atomic)
            savedClients = Dictionary(records.map { ($0.id, $0.lastSeen) }, uniquingKeysWith: max)
        } catch {
            log("Couldn't save the known devices: \(error)", level: .warning)
        }
    }

    /// Whether Calendar, Reminders, or Contacts on this Mac has signed in within the last
    /// month (devices are remembered across launches).
    private var localMacClientSeen: Bool {
        davHandler?.clients.current.values.contains { $0.platform.hasPrefix("macOS") && network.isLocal($0.remoteAddress) } ?? false
    }

    private func maintenance() {
        guard running else { return }
        // Macs set up before this was recorded: remember them once they are seen.
        if !configuration.thisMacEnrolled, localMacClientSeen { applyConfiguration { $0.thisMacEnrolled = true } }
        if store == nil {
            openStore()
            // A listener left from before the store closed (a restore or recovery that
            // couldn't reopen it) still serves the closed store's handler; replace it.
            if store != nil { httpsServer?.stop(); httpsServer = nil }
            startServers()
        }
        ensureCertificates()
        backupIfNeeded()
        probe()
        testDelivery()
        faults.prune()
        changed()
    }

    private func backupIfNeeded() {
        guard let store else { return }
        let latest = backups.latest
        let hasData = ((try? store.users()) ?? []).isEmpty == false
        let stale = latest.map { Date().timeIntervalSince($0.date) > 3_600 } ?? true
        guard hasData, stale, dirty.current || latest == nil else { return }
        performBackup(kind: "auto")
    }

    private func performBackup(kind: String) {
        guard let store else { return }
        lastBackupAttempt = Date()
        do {
            dirty.withLock { $0 = false }
            try backups.create(from: store, kind: kind)
            backups.prune(hourly: configuration.hourlyBackupsToKeep, daily: configuration.dailyBackupsToKeep)
            lastBackupError = nil
            if kind != "auto" { record(.success, "Backup created.") }
        } catch {
            dirty.withLock { $0 = true }
            lastBackupError = "\(error)"
            record(.error, "Backup failed: \(error)")
        }
    }

    /// Makes a real HTTPS request to the server through the loopback interface, trusting
    /// only CalShare's authority, then one on the Mac's network address, the way devices
    /// reach it. A firewall that filters incoming connections (Little Snitch, Lulu, the
    /// macOS firewall) passes loopback but drops the second, which is otherwise invisible
    /// from here. Both run on `probeQueue`; results come back to `queue`.
    private func probe(then waiter: (@Sendable () -> Void)? = nil) {
        if let waiter { probeWaiters.append(waiter) }
        guard !probeInFlight else { return }
        guard running, let port = activeHTTPSPort, let authority else { finishProbeWaiters(); return }
        probeInFlight = true
        let address = network.primaryLANAddress
        let der = authority.certificateDER
        probeQueue.async { [weak self] in
            let loopback = SelfProbe.run(port: port, authorityDER: der)
            // The second probe means nothing while the server can't answer at all.
            let lan = loopback ? address.map { SelfProbe.run(host: $0, port: port, authorityDER: der) } : nil
            guard let self else { return }
            self.queue.async { self.probeFinished(port: port, loopback: loopback, address: address, lan: lan) }
        }
    }

    private func finishProbeWaiters() {
        let waiters = probeWaiters
        probeWaiters = []
        for waiter in waiters { waiter() }
    }

    private func probeFinished(port: UInt16, loopback: Bool, address: String?, lan: Bool?) {
        probeInFlight = false
        defer { finishProbeWaiters() }
        // A restart or port change while the probe ran makes its answer stale.
        guard running, activeHTTPSPort == port else { changed(); return }
        if loopback {
            if probeFailures >= 2 { record(.success, "The server is answering again.") }
            probeFailures = 0
        } else {
            probeFailures += 1
            log("Self-probe failed (\(probeFailures))", level: .warning)
            if probeFailures == 2 {
                record(.warning, "The server stopped answering; restarting it.")
                restartServers()
            }
        }
        if let lan, address == network.primaryLANAddress {
            if lan != networkAccessible {
                if !lan {
                    record(.warning, "Devices can't connect: Something on this Mac is blocking incoming connections to CalShare.")
                } else if networkAccessible == false {
                    record(.success, "Devices can connect again.")
                }
            }
            networkAccessible = lan
        } else if address == nil {
            networkAccessible = nil
        }
        // The first test waits for this check, so it can go over the network address.
        if deliveryTestDue, loopback { testDelivery() }
        changed()
    }

    // MARK: Faults & delivery

    /// Notes a problem no component owns: it goes in the Activity log and on the Sync
    /// Reliability card, and a burst of ones a restart might clear restarts the server. The
    /// same message again within a minute (something failing in a loop) is noted once.
    private func fault(_ kind: FaultLedger.Kind, _ message: String) {
        let now = Date()
        if let last = faultSeen[message], now.timeIntervalSince(last) < 60 { return }
        faultSeen[message] = now
        if faultSeen.count > 200 { faultSeen = faultSeen.filter { now.timeIntervalSince($0.value) < 60 } }
        faults.add(kind, message, at: now)
        record(.warning, message)
        guard running, kind.restartMayHelp, faults.isBurst(since: lastFaultRestart) else { return }
        restartForFaults("Several responses failed within a few minutes")
    }

    // MARK: Logged errors

    /// Hand to `Logger.bootstrap` as its observer: error-level messages logged anywhere in
    /// the app become faults on the running Supervisor.
    public static let logObserver = LogObserver(minimumLevel: .error) { message, _, category, _ in
        current.current?.loggedError(message, category: category)
    }

    /// The running Supervisor, for the log observer; set by `start`, cleared by `stop`.
    private static let current = Locked<Supervisor?>(nil)

    /// Components whose errors already show on their own cards (or come back here as
    /// faults by another route), so they aren't counted twice. This file's own messages
    /// are among them, which also keeps a fault's own log line from coming back as one.
    static let tagsReportedElsewhere: Set<String> = [logTag, HTTPServer.logTag, DAVHandler.logTag, BonjourAdvertiser.logTag]

    func loggedError(_ message: String, category: String?) {
        if let category, Self.tagsReportedElsewhere.contains(category) { return }
        let source = category.map { "\($0) " } ?? ""
        queue.async { [weak self] in self?.fault(.loggedError, "An unexpected error was logged: \(source)\(message)") }
    }

    // MARK: Watchdog

    /// Every 10 seconds, from its own queue, asks `queue` to check in. A check-in still
    /// outstanding after `options.stallThreshold` means the Supervisor is stuck. Time is measured
    /// on the uptime clock, which stops while the Mac sleeps, so waking isn't mistaken for it.
    private func startWatchdog() {
        watchdog.withLock { state in
            guard state.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
            let interval = min(10, options.stallThreshold / 6)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
            timer.setEventHandler { [weak self] in self?.watchdogTick() }
            state = WatchdogState(timer: timer)
            timer.resume()
        }
    }

    private func stopWatchdog() {
        let wasStalled = watchdog.withLock { state -> Bool in
            state.timer?.cancel()
            let stalled = state.stalledSince != nil
            state = WatchdogState()
            return stalled
        }
        if wasStalled { onStall.current?(nil) }
    }

    private func watchdogTick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let threshold = UInt64(options.stallThreshold * 1_000_000_000)
        enum Step { case ping, stalled(Date), none }
        let step = watchdog.withLock { state -> Step in
            guard state.timer != nil else { return .none }
            guard let sent = state.pingSent else { state.pingSent = now; return .ping }
            guard state.stalledSince == nil, now &- sent > threshold else { return .none }
            let since = Date().addingTimeInterval(-Double(now &- sent) / 1_000_000_000)
            state.stalledSince = since
            return .stalled(since)
        }
        switch step {
        case .ping:
            queue.async { [weak self] in self?.watchdogCheckIn() }
        case .stalled(let since):
            log("The Supervisor hasn't responded for \(Int(options.stallThreshold)) s; status shown may be out of date.", level: .error)
            onStall.current?(since)
        case .none:
            break
        }
    }

    /// Holds the Supervisor's queue, for tests of the watchdog.
    func occupyQueue(for seconds: TimeInterval) {
        queue.async { Thread.sleep(forTimeInterval: seconds) }
    }

    private func watchdogCheckIn() {
        let stalledSince = watchdog.withLock { state -> Date? in
            let since = state.stalledSince
            state.pingSent = nil
            state.stalledSince = nil
            return since
        }
        guard let stalledSince else { return }
        record(.warning, "CalShare stopped responding internally for \(Int(Date().timeIntervalSince(stalledSince))) s and has recovered. Problems during that time may not have been reported.")
        onStall.current?(nil)
    }

    /// Restarts the server for faults, at most once an hour: a restart clears a wedged
    /// listener or connection, and repeating it wouldn't clear anything else.
    private func restartForFaults(_ reason: String) {
        if let last = lastFaultRestart, Date().timeIntervalSince(last) < 3_600 { return }
        lastFaultRestart = Date()
        record(.warning, "\(reason); restarting the server.")
        restartServers()
    }

    /// Looks at every finished request for signs that a device didn't get what it needed.
    private func requestFinished(_ entry: RequestLogEntry) {
        if entry.status == 503 { storageErrorObserved() }
        let request = "\(entry.method) \(entry.path) from \(entry.remoteAddress)"
        if entry.status >= 500 {
            fault(.serverError, "\(request) failed with status \(entry.status) (\(HTTPResponse.reason(entry.status))).")
        } else if entry.milliseconds > 30_000 {
            fault(.slowRequest, "\(request) took \(entry.milliseconds / 1000) s to answer.")
        }
        if repeats.observe(entry) {
            let size = ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file)
            fault(.repeatedDownload, "A device at \(entry.remoteAddress) downloaded \(entry.path) (\(size)) \(RepeatDetector.threshold) times in \(Int(RepeatDetector.window / 60)) minutes. It may not be accepting what it receives.")
        }
    }

    /// Downloads a 2 MB response and checks every byte arrived: the whole sending path —
    /// TLS, pieces, idle timers, and any firewall filtering the network address — at the
    /// size that once failed. It goes over the network address once that's known to be
    /// reachable, otherwise over loopback. Either way macOS keeps it inside this Mac, so it
    /// can't catch a stall out on the network itself; cut-off responses and repeated
    /// downloads (requestFinished) are what show those.
    private func testDelivery(then waiter: (@Sendable () -> Void)? = nil) {
        if let waiter { deliveryWaiters.append(waiter) }
        guard !deliveryInFlight else { return }
        guard running, let port = activeHTTPSPort, let authority else { finishDeliveryWaiters(); return }
        deliveryInFlight = true
        deliveryTestDue = false
        let host = networkAccessible == true ? network.primaryLANAddress ?? "127.0.0.1" : "127.0.0.1"
        let der = authority.certificateDER
        let token = deliveryToken
        probeQueue.async { [weak self] in
            let failure = SelfProbe.delivery(host: host, port: port, authorityDER: der, token: token)
            guard let self else { return }
            self.queue.async { self.deliveryFinished(port: port, host: host, failure: failure) }
        }
    }

    private func finishDeliveryWaiters() {
        let waiters = deliveryWaiters
        deliveryWaiters = []
        for waiter in waiters { waiter() }
    }

    private func deliveryFinished(port: UInt16, host: String, failure: String?) {
        deliveryInFlight = false
        defer { finishDeliveryWaiters(); changed() }
        guard running, activeHTTPSPort == port else { return }
        // A test that couldn't reach the server at all is the reachability check's to report.
        if failure != nil, probeFailures > 0 || (host != "127.0.0.1" && networkAccessible == false) { return }
        deliveryTest = (Date(), host, failure)
        guard let failure else {
            if deliveryFailures >= 2 { record(.success, "Large transfers arrive in full again.") }
            deliveryFailures = 0
            return
        }
        deliveryFailures += 1
        log("Delivery test over \(host) failed (\(deliveryFailures)): \(failure)", level: .warning)
        if deliveryFailures == 1 {
            // Once could be a blip; a second try settles it.
            queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.testDelivery() }
        } else if deliveryFailures == 2 {
            faults.add(.deliveryTest, "A 2 MB test transfer over \(host) didn't arrive intact: \(failure).")
            record(.warning, "A 2 MB test transfer over \(host) didn't arrive intact: \(failure).")
            restartForFaults("Large transfers aren't arriving intact")
        }
    }

    /// Whether macOS itself accepts the server certificate, using this Mac's own trust
    /// settings as Calendar and Contacts do. Checked at most every 30 seconds.
    private func trustedOnThisMac() -> Bool? {
        guard let authority, let serverCertificate else { return nil }
        if let trustCheck, Date().timeIntervalSince(trustCheck.date) < 30 { return trustCheck.trusted }
        let trusted = CertificateBuilder.evaluateWithSystemTrust(serverCertificate, authority: authority, hostname: "localhost")
        trustCheck = (Date(), trusted)
        return trusted
    }

    /// Checks this Mac's trust in the server certificate now, ignoring the cached answer.
    public func checkTrustNow() -> Bool? {
        sync {
            trustCheck = nil
            return trustedOnThisMac()
        }
    }

    /// Forgets the last trust check, after the app has changed this Mac's trust settings.
    public func recheckTrust() {
        queue.async { [self] in
            trustCheck = nil
            changed()
        }
    }

    private func updateProcessActivity() {
        guard options.manageProcessActivity else { return }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        var options: ProcessInfo.ActivityOptions = [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled]
        if configuration.keepAwake { options.insert(.idleSystemSleepDisabled) }
        activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "Serving calendars and contacts")
    }

    // MARK: Public actions

    /// Verify Data: reads everything the way a device does and checks it against what's
    /// stored (see Verification.swift). Read-only, and run off the Supervisor's queue, so the
    /// server keeps answering devices meanwhile. `completion` runs on a background queue.
    public func verifyData(completion: @escaping @Sendable (Result<VerificationReport, any Error>) -> Void) {
        let (handler, store) = queue.sync { (davHandler, self.store) }
        guard let handler, let store else {
            completion(.failure(VerificationError.notRunning))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Verifier.run(handler: handler, store: store) }
            if case .success(let report) = result {
                let items = "\(report.itemCount) item\(report.itemCount == 1 ? "" : "s") in \(report.results.count) collection\(report.results.count == 1 ? "" : "s")"
                if report.isClean {
                    self?.record(.success, "Verified \(items): everything matches what devices see.")
                } else {
                    self?.record(.warning, "Verify Data found \(report.problemCount) problem\(report.problemCount == 1 ? "" : "s") in \(items).")
                }
            } else if case .failure(let error) = result {
                self?.record(.error, "Verify Data couldn't finish: \(error)")
            }
            completion(result)
        }
    }

    public enum VerificationError: Error, CustomStringConvertible {
        case notRunning
        public var description: String { "The server isn't running." }
    }

    /// Carries out a fix on the Supervisor's queue; `completion` runs (on that queue) once
    /// it has, so a button can show that it is working until then.
    public func perform(_ fix: FixAction, completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            var completion = completion
            defer { completion?() }
            switch fix {
            case .restartServer:
                record(.info, "Restarting the server.")
                restartServers()
            case .useNextFreePort:
                let https = PortFinder.nextFree(after: configuration.httpsPort)
                let http = PortFinder.nextFree(after: configuration.httpPort, avoiding: [https])
                applyConfiguration { $0.httpsPort = https; $0.httpPort = http }
                record(.info, "Switched to ports \(https) (secure) and \(http) (setup).")
            case .reissueCertificate:
                ensureCertificates(force: true)
            case .backupNow:
                performBackup(kind: "manual")
            case .restartBonjour:
                bonjour.stop()
                advertise()
            case .repairDatabase:
                if let store, store.quickCheck() {
                    record(.success, "The database checked out fine; no repair was needed.")
                } else {
                    httpsServer?.stop(); httpsServer = nil
                    recoverDatabase(reason: "repair requested")
                    startServers()
                }
            case .checkNetworkAccess:
                // Done when the probe answers, not when it starts.
                probe(then: completion)
                completion = nil
            case .trustOnThisMac:
                trustCheck = nil
            case .clearLockouts:
                authenticator?.clearLockouts()
                record(.info, "Cleared sign-in lockouts.")
            case .useLocalName:
                applyConfiguration { $0.preferredHostname = nil }
                addressChange = nil
                record(.info, "Devices now reach this Mac at \(deviceHostname). Set up each device again to use it.")
            case .acknowledgeAddressChange:
                addressChange = nil
            case .testDelivery:
                // Done when the test finishes, not when it starts.
                testDelivery(then: completion)
                completion = nil
            case .dismissFaults:
                faults.clear()
            }
            changed()
        }
    }

    public func updateConfiguration(_ mutate: @escaping @Sendable (inout ServerConfiguration) -> Void) {
        queue.async { [self] in applyConfiguration(mutate) }
    }

    private func applyConfiguration(_ mutate: (inout ServerConfiguration) -> Void) {
        let old = configuration
        var new = configuration
        mutate(&new)
        new.customHostnames = new.customHostnames.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter(ServerConfiguration.isValidHostname)
        var seenHostnames = Set<String>()
        new.customHostnames = new.customHostnames.filter { seenHostnames.insert($0).inserted }
        guard new != old else { return }
        configuration = new
        do { try configurationStore.save(new) } catch { record(.error, "Settings could not be saved: \(error)") }
        if new.httpsPort != old.httpsPort || new.httpPort != old.httpPort { restartServers() }
        if new.customHostnames != old.customHostnames { ensureCertificates() }
        if new.bonjourEnabled != old.bonjourEnabled { advertise() }
        if new.keepAwake != old.keepAwake { updateProcessActivity() }
        changed()
    }

    /// Moves the servers to new ports, first checking that each port that changes can be
    /// opened. Throws, changing nothing, when one can't.
    public func changePorts(https: UInt16, http: UInt16) throws {
        try sync {
            for port in [https, http] where port < 1024 { throw PortChangeError.reserved(port) }
            guard https != http else { throw PortChangeError.same(https) }
            // A port this server holds now is free to it; any other must be free outright.
            let held: Set<UInt16> = [activeHTTPSPort, activeHTTPPort].compactMap { $0 }.reduce(into: []) { $0.insert($1) }
            for port in [https, http] where !held.contains(port) && !PortFinder.isFree(port) {
                throw PortChangeError.inUse(port)
            }
            applyConfiguration { $0.httpsPort = https; $0.httpPort = http }
            record(.info, "Switched to ports \(https) (secure) and \(http) (setup).")
        }
    }

    public var currentConfiguration: ServerConfiguration { sync { configuration } }

    // Accounts

    @discardableResult
    public func createAccount(username: String, displayName: String, password: String) throws -> AccountSummary {
        guard password.count >= 8 else { throw AccountError.weakPassword }
        guard let store = sync({ store }) else { throw AccountError.notReady }
        do {
            let user = try store.createUser(username: username, displayName: displayName, passwordHash: PasswordHasher.hash(password))
            record(.success, "Created the account “\(user.username)”.")
            queue.async { self.performBackup(kind: "auto") }
            return summary(for: user, in: store)
        } catch let error as StoreError {
            throw AccountError.store(error)
        }
    }

    /// Whether `password` is the account's password; for building a profile with it.
    public func checkPassword(_ password: String, for username: String) -> Bool {
        guard let store = sync({ store }), let user = try? store.user(named: username) else { return false }
        return PasswordHasher.verify(password, against: user.passwordHash)
    }

    public func setPassword(_ password: String, for username: String) throws {
        guard password.count >= 8 else { throw AccountError.weakPassword }
        guard let store = sync({ store }), let user = try store.user(named: username) else { throw AccountError.store(.notFound) }
        try store.setPasswordHash(PasswordHasher.hash(password), for: user.id)
        sync { authenticator?.invalidateCache() }
        record(.info, "Changed the password for “\(username)”. Devices will ask for the new one.")
    }

    public func setDisplayName(_ name: String, for username: String) throws {
        guard let store = sync({ store }), let user = try store.user(named: username) else { throw AccountError.store(.notFound) }
        try store.setDisplayName(name, for: user.id)
    }

    public func deleteAccount(_ username: String) throws {
        guard let store = sync({ store }), let user = try store.user(named: username) else { throw AccountError.store(.notFound) }
        // Backed up first, as the dashboard promises; if that fails, nothing is deleted.
        if let failure = sync({ performBackup(kind: "pre-delete"); return lastBackupError }) {
            throw SafetyBackupError(undone: "deleted", reason: failure)
        }
        try store.deleteUser(user.id)
        enrollment.revokeTokens(for: username)
        sync { authenticator?.invalidateCache() }
        record(.warning, "Deleted the account “\(username)”. A backup was taken first.")
    }

    private func summary(for user: User, in store: Store) -> AccountSummary {
        var collections: [CollectionSummary] = []
        for kind in CollectionKind.allCases {
            for collection in (try? store.collections(ownerID: user.id, kind: kind)) ?? [] {
                collections.append(CollectionSummary(id: collection.id, kind: kind, displayName: collection.displayName,
                                                     color: collection.color, components: collection.components,
                                                     itemCount: store.resourceCount(collectionID: collection.id)))
            }
        }
        return AccountSummary(username: user.username, displayName: user.displayName, createdAt: user.createdAt, collections: collections)
    }

    // Devices

    private var deviceHostname: String {
        if let preferred = configuration.preferredHostname, hostnameChoicesUnsafe.contains(preferred) { return preferred }
        // The .local name by default: it follows this Mac when the router hands it a new
        // IP address, which would otherwise stop every device from syncing.
        if !network.bonjourHostName.isEmpty { return network.bonjourHostName }
        return network.primaryLANAddress ?? "localhost"
    }

    private var usesLocalNameAvailable: Bool { !network.bonjourHostName.isEmpty }

    private var hostnameChoicesUnsafe: [String] {
        var choices = network.usableAddresses.filter { $0.family == .ipv4 && NameConstraints.permits(address: $0.address) }.map(\.address)
        if !network.bonjourHostName.isEmpty { choices.append(network.bonjourHostName) }
        choices += configuration.customHostnames
        return choices
    }

    /// A setup profile for the account. `forThisMac` builds the one this Mac installs: it
    /// reaches the server at `localhost`, which no firewall filters and no change of
    /// network or address can break, and it leaves the authority out, because the app
    /// trusts it on this Mac directly (a profile can't grant a Mac SSL trust).
    public func profileData(for username: String, password: String?, forThisMac: Bool = false) -> Data? {
        let (authority, hostname, port, name) = sync {
            (self.authority, forThisMac ? "localhost" : deviceHostname, activeHTTPSPort ?? configuration.httpsPort, configuration.serverName)
        }
        guard let authority, let store = sync({ store }), let user = try? store.user(named: username) else { return nil }
        let request = ProfileRequest(username: user.username, displayName: user.displayName, hostname: hostname, port: port,
                                     authorityDER: authority.certificateDER, authorityFingerprint: authority.fingerprint,
                                     serverName: name, password: password, includeAuthority: !forThisMac)
        return try? ProfileBuilder.build(request)
    }

    /// A short-lived setup link. `secure` serves it over HTTPS, for another Mac that has
    /// already trusted the authority; an iPhone or iPad hasn't yet, so it gets plain HTTP.
    public func enrollmentURL(for username: String, secure: Bool = false) -> URL? {
        let (hostname, port) = sync { (deviceHostname, secure ? activeHTTPSPort : activeHTTPPort) }
        guard let port else { return nil }
        let token = enrollment.issueToken(for: username)
        return URL(string: "\(secure ? "https" : "http")://\(EnrollmentHandler.bracketed(hostname)):\(port)/enroll/\(token.token)")
    }

    public var authorityCertificate: Data? { sync { authority?.certificateDER } }

    // Backups

    public func restore(_ record: BackupRecord) throws {
        try sync {
            guard BackupManager.verify(record.url) else { throw SQLiteError(code: 11, message: "That backup failed verification.") }
            // Staged next to the database first, so a failed copy leaves the live database
            // untouched instead of deleted (the next maintenance pass would otherwise open
            // an empty one in its place).
            let staged = URL(fileURLWithPath: paths.database.path + ".restoring")
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: record.url, to: staged)
            // The current data is backed up first, as the dashboard promises; if that fails,
            // nothing is replaced.
            if store != nil {
                performBackup(kind: "pre-restore")
                if let lastBackupError {
                    try? FileManager.default.removeItem(at: staged)
                    throw SafetyBackupError(undone: "restored", reason: lastBackupError)
                }
            }
            httpsServer?.stop(); httpsServer = nil
            store?.checkpoint()
            store?.close()
            store = nil
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: paths.database.path + suffix) }
            do {
                try FileManager.default.moveItem(at: staged, to: paths.database)
            } catch {
                openStore()
                startServers()
                throw error
            }
            openStore()
            // Every device must sync afresh against the restored contents.
            do { try store?.renewSyncEpoch() } catch { self.record(.error, "Couldn't reset sync state after restoring: \(error)") }
            startServers()
            dirty.withLock { $0 = false }
        }
        let when = DateFormatter.localizedString(from: record.date, dateStyle: .medium, timeStyle: .short)
        self.record(.success, "Restored the backup from \(when). Devices will sync to match it.")
    }

    public func deleteBackup(_ record: BackupRecord) {
        backups.delete(record)
        changed()
    }

    public func export(to folder: URL) throws -> Int {
        guard let store = sync({ store }) else { throw AccountError.notReady }
        let count = try Exporter.export(store: store, to: folder)
        record(.success, "Exported \(count) calendars and address books to \(folder.lastPathComponent).")
        return count
    }

    // MARK: Snapshot

    public func snapshot() -> SupervisorSnapshot {
        var snapshot = sync { () -> SupervisorSnapshot in
            var snapshot = SupervisorSnapshot()
            snapshot.configuration = configuration
            snapshot.network = network
            snapshot.httpsPort = activeHTTPSPort
            snapshot.httpPort = activeHTTPPort
            snapshot.deviceHostname = deviceHostname
            snapshot.hostnameChoices = hostnameChoicesUnsafe
            snapshot.authorityFingerprint = authority?.fingerprint ?? ""
            snapshot.authorityPermittedNames = authority?.names ?? []
            snapshot.certificateNames = (serverCertificate?.names ?? []) + (serverCertificate?.addresses ?? [])
            snapshot.certificateExpiry = serverCertificate?.notAfter
            snapshot.lockedOutAddresses = authenticator?.lockedOutAddresses ?? []
            snapshot.dataDirectory = paths.base
            snapshot.trustedOnThisMac = trustedOnThisMac()
            snapshot.health = health()
            return snapshot
        }
        if let store = sync({ store }) {
            snapshot.statistics = store.statistics()
            snapshot.accounts = ((try? store.users()) ?? []).map { summary(for: $0, in: store) }
        }
        snapshot.backups = backups.list()
        snapshot.events = eventLog.current
        snapshot.enrollmentUses = enrollment.uses.current
        snapshot.requests = requestLog.current
        snapshot.clients = (sync { davHandler })?.clients.current.values.sorted { $0.lastSeen > $1.lastSeen } ?? []
        return snapshot
    }

    private func health() -> [ComponentHealth] {
        var items: [ComponentHealth] = []

        // Server
        switch httpsServer?.state.current {
        case .ready(let port)?:
            items.append(.init(id: "server", title: "Calendar & Contacts Server", symbol: "server.rack", state: .ok,
                               summary: "Running on port \(port)",
                               detail: "\(httpsServer?.connectionCount ?? 0) open connection(s). Restarts automatically if it stops.",
                               fix: .restartServer, fixTitle: "Restart"))
        case .failed(let message, let inUse)?:
            items.append(.init(id: "server", title: "Calendar & Contacts Server", symbol: "server.rack", state: .error,
                               summary: inUse ? "Port \(configuration.httpsPort) is in use" : "Stopped", detail: message,
                               fix: inUse ? .useNextFreePort : .restartServer, fixTitle: inUse ? "Use Another Port" : "Restart"))
        default:
            let failing = restartAttempts["https", default: 0] > 0
            items.append(.init(id: "server", title: "Calendar & Contacts Server", symbol: "server.rack",
                               state: failing ? .error : .working,
                               summary: failing ? "Retrying (attempt \(restartAttempts["https", default: 0]))" : "Starting…",
                               detail: failing ? "Port \(configuration.httpsPort) could not be opened." : nil,
                               fix: failing ? .useNextFreePort : nil, fixTitle: failing ? "Use Another Port" : nil))
        }

        // Setup listener
        switch httpServer?.state.current {
        case .ready(let port)?:
            items.append(.init(id: "setup", title: "Device Setup Service", symbol: "qrcode", state: .ok,
                               summary: "Ready on port \(port)", detail: "Serves setup profiles and discovery redirects only — never calendar data."))
        default:
            let failing = restartAttempts["http", default: 0] > 0
            items.append(.init(id: "setup", title: "Device Setup Service", symbol: "qrcode", state: failing ? .warning : .working,
                               summary: failing ? "Port \(configuration.httpPort) is unavailable" : "Starting…",
                               detail: failing ? "Devices can still be set up with “Add to This Mac” or manual settings." : nil,
                               fix: failing ? .useNextFreePort : nil, fixTitle: failing ? "Use Another Port" : nil))
        }

        // Certificate. Once this Mac syncs with CalShare, it must trust the authority too,
        // or Calendar and Contacts refuse every connection.
        let macUsesServer = configuration.thisMacEnrolled || localMacClientSeen
        if certificateHealth.0 == .ok, trustCheck?.trusted == false, macUsesServer {
            items.append(.init(id: "certificate", title: "Secure Connection", symbol: "lock.shield", state: .error,
                               summary: "Not Trusted on This Mac",
                               detail: "Calendar and Contacts on this Mac refuse the connection until CalShare's certificate authority is trusted.",
                               fix: .trustOnThisMac, fixTitle: "Trust…"))
        } else {
            items.append(.init(id: "certificate", title: "Secure Connection", symbol: "lock.shield", state: certificateHealth.0,
                               summary: certificateHealth.1, detail: certificateHealth.2,
                               fix: .reissueCertificate, fixTitle: "Renew Now"))
        }

        // Network access
        if httpsServer.map({ if case .ready = $0.state.current { true } else { false } }) == true, let lan = network.primaryLANAddress {
            switch networkAccessible {
            case true?:
                items.append(.init(id: "access", title: "Network Access", symbol: "network.badge.shield.half.filled", state: .ok,
                                   summary: "Reachable from other devices",
                                   detail: "The server answers on \(lan), the way an iPhone or another Mac reaches it. Checked every 20 seconds.",
                                   fix: .checkNetworkAccess, fixTitle: "Check Now"))
            case false?:
                items.append(.init(id: "access", title: "Network Access", symbol: "network.badge.shield.half.filled", state: .error,
                                   summary: "Incoming connections are blocked",
                                   detail: "Connections to \(lan) are refused before they reach CalShare, usually by a firewall such as Little Snitch. Allow incoming connections for CalShare; the Devices page has the steps.",
                                   fix: .checkNetworkAccess, fixTitle: "Check Now"))
            case nil:
                items.append(.init(id: "access", title: "Network Access", symbol: "network.badge.shield.half.filled", state: .working,
                                   summary: "Checking…", detail: nil))
            }
        } else if network.primaryLANAddress == nil {
            // Always reported, so the dashboard's cards never shift as one comes and goes.
            items.append(.init(id: "access", title: "Network Access", symbol: "network.badge.shield.half.filled", state: .off,
                               summary: "No local network", detail: "Checked again once this Mac is on a network."))
        } else {
            items.append(.init(id: "access", title: "Network Access", symbol: "network.badge.shield.half.filled", state: .working,
                               summary: "Waiting for the server…", detail: nil))
        }

        items.append(deliveryHealth())

        // Network name
        let name = deviceHostname
        let lan = network.primaryLANAddress
        if let lost = lostDeviceAddress, let lan {
            // Every device was set up with an address this Mac no longer has.
            items.append(.init(id: "network", title: "Network Name", symbol: "network", state: .error,
                               summary: "IP address changed to \(lan)",
                               detail: "Devices use \(lost), so they can't sync. Reserve \(lost) for this Mac on your router, or switch to the .local name and set up each device again.",
                               fix: usesLocalNameAvailable ? .useLocalName : nil, fixTitle: "Use .local Name"))
        } else if let change = addressChange, usesLocalName {
            items.append(.init(id: "network", title: "Network Name", symbol: "network", state: .notice,
                               summary: "IP address changed to \(change.to)",
                               detail: "Was \(change.from). Devices use \(name), so they keep syncing; anything set up with the old IP address by hand needs the new one.",
                               fix: .acknowledgeAddressChange, fixTitle: "OK"))
        } else {
            items.append(.init(id: "network", title: "Network Name", symbol: "network",
                               state: lan == nil && network.tailscaleAddress == nil ? .warning : .ok,
                               summary: name,
                               detail: lan.map { "This Mac is at \($0) on the local network\(network.tailscaleAddress.map { " and \($0) on Tailscale" } ?? "")." }
                                   ?? "No local network connection. Devices can't sync with CalShare until this Mac reconnects to the network."))
        }

        // Bonjour
        if !options.advertiseBonjour || !configuration.bonjourEnabled {
            items.append(.init(id: "bonjour", title: "Bonjour Discovery", symbol: "dot.radiowaves.left.and.right", state: .off,
                               summary: "Off", detail: "Devices are set up with the profile or manual settings instead."))
        } else {
            let status = bonjour.status.current
            items.append(.init(id: "bonjour", title: "Bonjour Discovery", symbol: "dot.radiowaves.left.and.right",
                               state: status.error != nil ? .warning : (status.registered >= 2 ? .ok : .working),
                               summary: status.error ?? (status.registered >= 2 ? "Advertising as “\(configuration.serverName)”" : "Registering…"),
                               detail: "Announces the CalDAV and CardDAV services on the local network.",
                               fix: status.error != nil ? .restartBonjour : nil, fixTitle: "Retry"))
        }

        // Database
        items.append(.init(id: "database", title: "Database", symbol: "cylinder.split.1x2", state: databaseHealth.0,
                           summary: databaseHealth.1, detail: databaseHealth.2,
                           fix: databaseHealth.0 == .ok ? nil : .repairDatabase, fixTitle: "Check & Repair"))

        // Backups
        let latest = backups.latest
        if let lastBackupError {
            items.append(.init(id: "backups", title: "Backups", symbol: "clock.arrow.circlepath", state: .error,
                               summary: "Last backup failed", detail: lastBackupError, fix: .backupNow, fixTitle: "Try Again"))
        } else if let latest {
            let stale = Date().timeIntervalSince(latest.date) > 3 * 86_400 && dirty.current
            items.append(.init(id: "backups", title: "Backups", symbol: "clock.arrow.circlepath", state: stale ? .warning : .ok,
                               summary: "Last backup \(latest.date.relative)",
                               detail: "Automatic, hourly while things change. Keeps \(configuration.hourlyBackupsToKeep) hourly and \(configuration.dailyBackupsToKeep) daily copies.",
                               fix: .backupNow, fixTitle: "Back Up Now"))
        } else {
            items.append(.init(id: "backups", title: "Backups", symbol: "clock.arrow.circlepath", state: .off,
                               summary: "No backups yet", detail: "The first backup is taken once there is data to protect.",
                               fix: .backupNow, fixTitle: "Back Up Now"))
        }

        // Accounts
        let userCount = ((try? store?.users()) ?? []).count
        let lockedOut = authenticator?.lockedOutAddresses ?? []
        items.append(.init(id: "accounts", title: "Accounts & Sign-In", symbol: "person.2", state: userCount == 0 ? .warning : (lockedOut.isEmpty ? .ok : .warning),
                           summary: userCount == 0 ? "No accounts yet" : (lockedOut.isEmpty ? "\(userCount) account\(userCount == 1 ? "" : "s")" : "Blocked \(lockedOut.count) address(es) after failed sign-ins"),
                           detail: lockedOut.isEmpty ? "Passwords are stored as salted PBKDF2 hashes. Repeated failed sign-ins are blocked." : lockedOut.joined(separator: ", "),
                           fix: lockedOut.isEmpty ? nil : .clearLockouts, fixTitle: "Unblock"))
        return items
    }

    /// The Sync Reliability card: whether what the server sends reaches devices whole, and
    /// anything else that went wrong that no other card reports.
    private func deliveryHealth() -> ComponentHealth {
        func card(_ state: HealthState, _ summary: String, _ detail: String?, _ fix: FixAction?, _ fixTitle: String?) -> ComponentHealth {
            .init(id: "delivery", title: "Sync Reliability", symbol: "arrow.down.circle.dotted", state: state,
                  summary: summary, detail: detail, fix: fix, fixTitle: fixTitle)
        }
        var ledger = faults
        ledger.prune()
        let recent = ledger.faults
        if let test = deliveryTest, let failure = test.failure, deliveryFailures >= 2 {
            return card(.error, "Large transfers are failing",
                        "A 2 MB test over \(test.host) failed: \(failure). Devices may be missing data without showing an error.",
                        .restartServer, "Restart")
        }
        if let latest = recent.last {
            let count = recent.count
            // Ones that keep coming after the server was restarted for them are past
            // what a restart fixes.
            let persisting = lastFaultRestart.map { restart in recent.lazy.filter { $0.kind.restartMayHelp && $0.date > restart }.count >= FaultLedger.burstCount } ?? false
            return card(persisting ? .error : .warning,
                        "\(count) problem\(count == 1 ? "" : "s") in the last day",
                        "Latest, \(latest.date.relative): \(latest.message)" + (count > 1 ? " The Activity page has the rest." : ""),
                        .dismissFaults, "Dismiss")
        }
        guard activeHTTPSPort != nil else { return card(.working, "Waiting for the server…", nil, nil, nil) }
        guard let test = deliveryTest else { return card(.working, "Testing…", nil, nil, nil) }
        // One failure is retried before it counts.
        if test.failure != nil { return card(.working, "Testing again…", nil, nil, nil) }
        let over = test.host == "127.0.0.1" ? "on this Mac" : "over \(test.host)"
        return card(.ok, "Responses arrive in full",
                    "A 2 MB test transfer \(over) arrived intact \(test.date.relative). Cut-off responses and unexpected errors show here.",
                    .testDelivery, "Test Now")
    }
}

// MARK: - Helpers

public enum PortFinder {
    public static func isFree(_ port: UInt16) -> Bool {
        let socketFD = socket(AF_INET6, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        var no: Int32 = 0
        var yes: Int32 = 1
        unsafe setsockopt(socketFD, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size))
        // SO_REUSEADDR ignores connections lingering in TIME_WAIT, but still fails against a live listener.
        unsafe setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_any
        let result = unsafe withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        return result == 0
    }

    public static func nextFree(after port: UInt16, avoiding: Set<UInt16> = []) -> UInt16 {
        var candidate = port
        for _ in 0..<200 {
            candidate = candidate >= 65_000 ? 8_000 : candidate + 1
            if !avoiding.contains(candidate), isFree(candidate) { return candidate }
        }
        return port
    }
}

/// A synchronous HTTPS GET to the local server that trusts only CalShare's authority.
enum SelfProbe {
    static let deliveryPath = "/.calshare/delivery-test"
    static let tokenHeader = "X-CalShare-Probe"
    /// Larger than the listing that once arrived cut off. Patterned, so a piece that arrives
    /// out of place doesn't match either.
    static let deliveryBody: Data = {
        var state: UInt32 = 0x9E37_79B9
        return Data((0..<(2 * 1024 * 1024)).map { _ in
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        })
    }()
    static let deliveryResponse = HTTPResponse(status: 200, headers: HTTPHeaders([("Content-Type", "application/octet-stream"),
                                                                                  ("Cache-Control", "no-store")]),
                                               body: deliveryBody)

    /// Downloads the test body; nil when every byte arrived, otherwise what went wrong.
    static func delivery(host: String, port: UInt16, authorityDER: Data, token: String, timeout: TimeInterval = 30) -> String? {
        guard let authority = SecCertificateCreateWithData(nil, authorityDER as CFData),
              let url = URL(string: "https://\(host.contains(":") ? "[\(host)]" : host):\(port)\(deliveryPath)") else { return "the test couldn't be set up" }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration, delegate: Delegate(authority: authority), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: tokenHeader)
        let semaphore = DispatchSemaphore(value: 0)
        let failure = Locked<String?>("it timed out")
        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let expected = deliveryBody.count
            failure.withLock {
                if let error { $0 = error.localizedDescription }
                else if status != 200 { $0 = "status \(status.map(String.init) ?? "none")" }
                else if let data, data.count != expected {
                    $0 = "\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(expected), countStyle: .file)) arrived"
                } else if data != deliveryBody { $0 = "the bytes that arrived didn't match what was sent" }
                else { $0 = nil }
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return failure.current
    }

    final class Delegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        let authority: SecCertificate
        init(authority: SecCertificate) { self.authority = authority }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard let trust = challenge.protectionSpace.serverTrust else { completionHandler(.cancelAuthenticationChallenge, nil); return }
            SecTrustSetAnchorCertificates(trust, [authority] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            if SecTrustEvaluateWithError(trust, nil) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    static func run(host: String = "127.0.0.1", port: UInt16, authorityDER: Data, timeout: TimeInterval = 10) -> Bool {
        guard let authority = SecCertificateCreateWithData(nil, authorityDER as CFData),
              let url = URL(string: "https://\(host.contains(":") ? "[\(host)]" : host):\(port)/") else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration, delegate: Delegate(authority: authority), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let semaphore = DispatchSemaphore(value: 0)
        let ok = Locked(false)
        session.dataTask(with: url) { _, response, _ in
            ok.withLock { $0 = (response as? HTTPURLResponse)?.statusCode == 200 }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return ok.current
    }
}
