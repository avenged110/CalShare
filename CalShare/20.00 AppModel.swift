// MARK: - AppModel.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// The bridge between the dashboard and the Supervisor. The Supervisor does all of the work
// on its own queues; this model holds the latest snapshot for SwiftUI and turns button
// presses into Supervisor calls, off the main thread where they could block.

import AppKit
import CalShareCore
import Observation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case overview, accounts, devices, backups, activity, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .accounts: "Accounts"
        case .devices: "Devices"
        case .backups: "Backups"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .accounts: "person.2"
        case .devices: "iphone.and.arrow.forward"
        case .backups: "clock.arrow.circlepath"
        case .activity: "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }
}

@MainActor
@Observable
final class AppModel: Loggable {
    static let logTag = "[Model]"

    let supervisor = Supervisor()
    var snapshot = SupervisorSnapshot()
    var hasLoaded = false
    var selection = SidebarItem.overview
    /// Whether the sidebar is showing. Remembered across launches, PhotoGallery's way:
    /// NavigationSplitView keeps no state of its own, so this seeds it at launch and takes
    /// every change back, from the toolbar button and the View menu alike.
    var sidebarVisible = UserDefaults.standard.bool(forKey: Preferences.Key.sidebarVisible) {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: Preferences.Key.sidebarVisible) }
    }
    var showSetupAssistant = false
    /// Set once the setup assistant reaches its server check. Until then (or until setup
    /// is finished) the dashboard behind it shows neutral "Configuring…" states rather
    /// than live status for a server nobody has set up yet.
    var setupReachedChecks = false
    /// The fixes in progress, so their buttons can show it.
    var workingFixes: Set<FixAction> = []
    private let notifier = ProblemNotifier()
    /// Every alert in the app; shown by the AlertHostView in front.
    let alerts = AlertQueue()
    /// Sheets on screen, so alerts attach to the sheet rather than the window behind it.
    var openSheets = 0
    var loginItemEnabled = SMAppService.mainApp.status == .enabled

    private var refreshInFlight = false
    private var refreshAgain = false
    private var timer: Timer?

    /// Whether pages show the server's real status (see `setupReachedChecks`).
    var statusRevealed: Bool { !hasLoaded || snapshot.configuration.setupCompleted || setupReachedChecks }

    func start() {
        notifier.onOpen = { [weak self] in self?.show(.overview) }
        supervisor.onUpdate.withLock { handler in
            handler = { [weak self] in Task { @MainActor in self?.refresh() } }
        }
        // Straight from the watchdog's queue: if the main thread is what's waiting on the
        // Supervisor, this notification is the only sign of it.
        supervisor.onStall.withLock { handler in
            handler = { [weak self] since in
                if let since { ProblemNotifier.postStall(since: since) } else { ProblemNotifier.withdrawStall() }
                Task { @MainActor in self?.applyStall() }
            }
        }
        supervisor.start()
        removeLeftoverProfiles()
        refresh()
        // A slow tick picks up what changes without telling the model, such as connection
        // counts, and gives the problem notifier its sense of time.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Coming back to CalShare, often from changing a firewall setting, checks again
        // at once rather than at the next timed check.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // Straight to the Supervisor: a background check, not a button press, so no
            // button shows it as working.
            self?.supervisor.perform(.checkNetworkAccess)
        }
    }

    func stop() {
        timer?.invalidate()
        supervisor.stop()
    }

    /// Fetches a snapshot off the main thread; bursts of requests collapse into one follow-up.
    func refresh() {
        if refreshInFlight { refreshAgain = true; return }
        refreshInFlight = true
        let supervisor = supervisor
        Task.detached(priority: .userInitiated) {
            let snapshot = supervisor.snapshot()
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Only a changed snapshot is published: every page reading it re-renders,
                // and most refreshes (the timer's, a burst of syncs) bring nothing new.
                if snapshot != self.snapshot { self.snapshot = snapshot }
                self.applyStall()
                if !self.hasLoaded {
                    self.hasLoaded = true
                    if !snapshot.configuration.setupCompleted { self.showSetupAssistant = true }
                    else { self.notifier.requestAuthorization() }
                }
                self.notifier.update(snapshot)
                self.refreshInFlight = false
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                }
            }
        }
    }

    /// While the Supervisor isn't responding, its last report can't be trusted: a card
    /// saying so goes at the front of the health list, which turns the overall status,
    /// the menu bar, and the Overview's summary to an error. It goes once it responds.
    private func applyStall() {
        var updated = snapshot
        updated.health.removeAll { $0.id == ProblemNotifier.stallID }
        if let since = supervisor.stalledSince {
            let time = since.formatted(date: .omitted, time: .shortened)
            updated.health.insert(ComponentHealth(
                id: ProblemNotifier.stallID, title: "CalShare", symbol: "exclamationmark.triangle", state: .error,
                summary: "Not responding since \(time)",
                detail: "CalShare stopped responding internally, so the status shown may be out of date and new problems may not be reported. Quitting and reopening CalShare usually fixes it."),
                at: 0)
        }
        if updated != snapshot { snapshot = updated }
    }

    /// Account names in use, for checking a new name as it is typed.
    var accountNames: Set<String> { Set(snapshot.accounts.map(\.username)) }

    // MARK: Actions

    func perform(_ fix: FixAction) {
        Task { await performAndWait(fix) }
    }

    /// Carries out a fix and returns once it is done, or after two seconds if it was
    /// quicker, so a button showing progress never just flickers.
    func performAndWait(_ fix: FixAction) async {
        guard !workingFixes.contains(fix) else { return }
        workingFixes.insert(fix)
        let started = ContinuousClock.now
        if fix == .trustOnThisMac {
            _ = await trustAuthorityOnThisMac()
        } else {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                supervisor.perform(fix) { done.resume() }
            }
        }
        let remaining = Duration.seconds(2) - (ContinuousClock.now - started)
        if remaining > .zero { try? await Task.sleep(for: remaining) }
        workingFixes.remove(fix)
        refresh()
    }

    /// Runs Verify Data; `completion` runs on the main actor.
    func verifyData(completion: @escaping @MainActor (Result<VerificationReport, any Error>) -> Void) {
        supervisor.verifyData { result in
            Task { @MainActor in
                completion(result)
                self.refresh()
            }
        }
    }

    /// Called when setup finishes, the moment notifications become useful.
    func setupFinished() {
        notifier.requestAuthorization()
    }

    func updateConfiguration(_ mutate: @escaping @Sendable (inout ServerConfiguration) -> Void) {
        supervisor.updateConfiguration(mutate)
    }

    func present(_ alert: HostAlert) {
        alerts.enqueue(alert)
    }

    func openDashboard() {
        DockPresence.showInDock()
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(WindowID.dashboard) == true }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openWindowAction {
            openWindowAction(WindowID.dashboard)
        } else {
            // No view has handed over openWindow yet, as after a launch at login to the
            // MenuBar: SwiftUI's application delegate opens the window as a launch would.
            _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
        }
    }

    /// Brings up the dashboard on `item`, from a menu, the menu bar item or a button.
    func show(_ item: SidebarItem) {
        selection = item
        openDashboard()
    }

    /// Set by the dashboard view, which has the SwiftUI environment's openWindow.
    var openWindowAction: ((String) -> Void)?

    /// Runs a blocking Supervisor call off the main thread and reports failures as alerts.
    func run<T: Sendable>(_ title: String, _ work: @escaping @Sendable () throws -> T) async -> T? {
        do {
            return try await Task.detached(priority: .userInitiated) { try work() }.value
        } catch {
            present(.notice(title, String(describing: error)))
            return nil
        }
    }

    // MARK: Login item

    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("Login item change failed: \(error)", level: .warning)
            present(.notice("Couldn't Change Open at Login",
                            "macOS refused the change (\(error.localizedDescription)). You can add CalShare in System Settings › General › Login Items."))
        }
        loginItemEnabled = SMAppService.mainApp.status == .enabled
    }

    // MARK: Devices

    /// Builds the account's setup profile with its password inside, hands it to System
    /// Settings and brings up Device Management, where it waits to be installed. With the
    /// password in the profile, macOS asks for nothing but the Mac's own login password.
    ///
    /// The profile file holds the password in plain text, so it is deleted once macOS has
    /// taken its copy.
    func installProfileOnThisMac(username: String, password: String) async -> ProfileInstallResult {
        let supervisor = supervisor
        guard await Task.detached(priority: .userInitiated, operation: { supervisor.checkPassword(password, for: username) }).value else {
            return .wrongPassword
        }
        // macOS checks the account against the server while installing the profile, so
        // the certificate must be trusted first or the install fails.
        let trusted = await Task.detached(priority: .userInitiated) { supervisor.checkTrustNow() }.value
        if trusted != true {
            guard await trustAuthorityOnThisMac() else { return .stopped }
        }
        guard let data = await run("Couldn't Create the Setup Profile", {
            guard let data = supervisor.profileData(for: username, password: password, forThisMac: true) else { throw ProfileError.notReady }
            return data
        }) else { return .stopped }
        do {
            let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let url = downloads.appendingPathComponent("CalShare-\(username).mobileconfig")
            // Owner-only from the moment it exists, since it holds the password: written
            // first and narrowed after, it would be readable by others in between.
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            NSWorkspace.shared.open(url)
            log("Opened profile for \(username)")
            // macOS copies an opened profile into its own store straight away; the file has
            // no further use, and it should not linger with a password in it.
            Task {
                try? await Task.sleep(for: .seconds(30))
                try? FileManager.default.removeItem(at: url)
            }
            try? await Task.sleep(for: .seconds(1))
            Self.openProfilesSettings()
            // Remembered, so the dashboard can warn if this Mac ever stops trusting the
            // server: an untrusted Mac can't connect, so it never shows up as a client.
            updateConfiguration { $0.thisMacEnrolled = true }
        } catch {
            present(.notice("Couldn't Save the Setup Profile", error.localizedDescription))
            return .stopped
        }
        return .opened
    }

    enum ProfileInstallResult {
        /// The profile is waiting in System Settings.
        case opened
        /// The password isn't the account's.
        case wrongPassword
        /// Something else stopped it (trust declined, or an error already reported).
        case stopped
    }

    // MARK: Trust

    /// Makes this Mac trust CalShare's certificate authority, which Calendar and Contacts
    /// need before they connect. A setup profile can't do this on a Mac: macOS installs a
    /// profile's certificate without SSL trust. macOS asks for the login password to
    /// confirm. Returns whether the change was made.
    func trustAuthorityOnThisMac() async -> Bool {
        guard let der = supervisor.authorityCertificate else {
            present(.notice("The Server Is Still Starting", "Try again in a moment."))
            return false
        }
        let status = await Task.detached(priority: .userInitiated) { Self.setTrust(for: der) }.value
        supervisor.recheckTrust()
        if status == errSecSuccess {
            log("Authority trusted on this Mac")
            return true
        }
        log("Trusting the authority failed: \(status)", level: .warning)
        if status != errAuthorizationCanceled && status != errSecUserCanceled {
            present(.confirm(
                "Couldn't Trust CalShare's Certificate",
                "macOS refused the change (error \(status)). To trust it by hand: Save the certificate, double-click it to add it to Keychain Access, double-click “CalShare Local Authority” there, open Trust, and set “When using this certificate” to Always Trust.",
                action: "Save Certificate…") { [weak self] in self?.saveAuthorityCertificate() })
        }
        return false
    }

    /// Adds the authority to the login keychain (where Keychain Access shows it) and sets
    /// the user's trust in it. Blocks while macOS asks for the password.
    nonisolated private static func setTrust(for der: Data) -> OSStatus {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return errSecParam }
        let add: [CFString: Any] = [kSecClass: kSecClassCertificate, kSecValueRef: certificate]
        // Best effort: trust settings work without it, since the server sends the
        // authority in every handshake.
        _ = SecItemAdd(add as CFDictionary, nil)
        // Trusted as a root for TLS server certificates only. With no settings array it
        // would be trusted for every purpose, code signing and S/MIME included, which a
        // private authority for one server has no need of.
        let sslOnly: [[String: Any]] = [[
            kSecTrustSettingsPolicy: SecPolicyCreateSSL(true, nil),
            kSecTrustSettingsResult: SecTrustSettingsResult.trustRoot.rawValue,
        ]]
        return SecTrustSettingsSetTrustSettings(certificate, .user, sslOnly as CFArray)
    }

    /// Removes setup profiles an earlier run left in Downloads (one holds a password).
    func removeLeftoverProfiles() {
        let files = FileManager.default
        guard let downloads = files.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let items = try? files.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix("CalShare-") && item.pathExtension == "mobileconfig" {
            try? files.removeItem(at: item)
        }
    }

    /// Opens System Settings on the pane that lists downloaded profiles.
    static func openProfilesSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    func saveAuthorityCertificate() {
        guard let der = supervisor.authorityCertificate else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CalShare Authority.cer"
        panel.allowedContentTypes = [.x509Certificate]
        // A sheet on the window, not an app-modal panel.
        let write: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try der.write(to: url, options: .atomic) } catch {
                self?.present(.notice("Couldn't Save the Certificate", error.localizedDescription))
            }
        }
        if let window = Self.dashboardWindow { panel.beginSheetModal(for: window, completionHandler: write) }
        else { write(panel.runModal()) }
    }

    static var dashboardWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains(WindowID.dashboard) == true && $0.isVisible }
    }

    // MARK: Reset for Testing

    #if DEBUG
    /// Debug builds only. Stops the server, deletes everything CalShare created — the database, backups,
    /// certificates, settings, preferences, logs, the login item and setup profiles in
    /// Downloads — and quits, so the next launch is a first launch.
    func resetForTesting() {
        log("Reset for Testing: erasing everything", level: .warning)
        timer?.invalidate()
        do {
            try supervisor.eraseAllData()
        } catch {
            present(.notice("Couldn't Erase CalShare's Data", "\(error.localizedDescription) Nothing else was changed."))
            return
        }
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }

        removeLeftoverProfiles()
        let files = FileManager.default

        // Logging off before its folder goes, so nothing writes a new log on the way out.
        UserDefaults.standard.set(false, forKey: Preferences.Key.loggingEnabled)
        Logger.shutdownLoggingBlocking()
        // The log sits in Application Support beside macOS's own items, so only the file goes.
        try? files.removeItem(at: Logger.safeLogFileURL)
        let library = files.urls(for: .libraryDirectory, in: .userDomainMask).first
        // Where earlier versions kept the log.
        if let library { try? files.removeItem(at: library.appendingPathComponent("Logs/CalShare.log")) }
        if let library, let bundleID = Bundle.main.bundleIdentifier {
            try? files.removeItem(at: library.appendingPathComponent("Saved Application State/\(bundleID).savedState"))
            try? files.removeItem(at: library.appendingPathComponent("Caches/\(bundleID)"))
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
        }
        NSApp.terminate(nil)
    }
    #endif

    enum ProfileError: Error, CustomStringConvertible {
        case notReady
        var description: String { "The server is still starting up. Try again in a moment." }
    }
}
