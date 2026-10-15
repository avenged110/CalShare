// MARK: - Notifications.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Notification Center alerts for problems that last. A component that stays at warning or
// error for half a minute posts one notification; it posts again only after it has been
// healthy in between. Brief blips (a listener restarting itself, a network change being
// rechecked) never reach Notification Center. Nothing is posted before setup is finished.

import AppKit
import CalShareCore
import UserNotifications

@MainActor
final class ProblemNotifier: NSObject, UNUserNotificationCenterDelegate, Loggable {
    static let logTag = "[Notify]"

    /// How long a problem must last before it is worth interrupting someone.
    static let grace: TimeInterval = 30

    /// When each component's current problem began, and whether it has been announced.
    private var problems: [String: (since: Date, notified: Bool)] = [:]
    private var authorizationRequested = false
    var onOpen: (() -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks for permission once; macOS remembers the answer, so later calls are free.
    func requestAuthorization() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            let message = error.map { "Authorization failed: \($0.localizedDescription)" } ?? "Authorization \(granted ? "granted" : "declined")"
            Task { @MainActor in Self.log(message) }
        }
    }

    /// Called with every snapshot.
    func update(_ snapshot: SupervisorSnapshot) {
        Self.setupCompleted.withLock { $0 = snapshot.configuration.setupCompleted }
        guard snapshot.configuration.setupCompleted, Preferences.notifyAboutProblems else {
            problems = [:]
            return
        }
        let now = Date()
        // The stall is posted straight from the watchdog (`postStall`), not from here.
        let failing = Dictionary(uniqueKeysWithValues: snapshot.health.filter { $0.state >= HealthState.warning && $0.id != Self.stallID }.map { ($0.id, $0) })
        problems = problems.filter { failing[$0.key] != nil }
        for (id, item) in failing {
            var problem = problems[id] ?? (now, false)
            if !problem.notified, now.timeIntervalSince(problem.since) >= Self.grace {
                post(item)
                problem.notified = true
            }
            problems[id] = problem
        }
    }

    nonisolated static let stallID = "supervisor"
    /// Whether setup is finished, as of the last snapshot; readable without the Supervisor.
    nonisolated static let setupCompleted = Locked(false)

    /// Posted by the Supervisor's watchdog on its own queue, so it gets out even while the
    /// main thread is waiting on the stuck Supervisor. Before setup, nothing is posted, as
    /// with every other problem.
    nonisolated static func postStall(since: Date) {
        guard Preferences.notifyAboutProblems, setupCompleted.current else { return }
        let content = UNMutableNotificationContent()
        content.title = "CalShare Isn't Responding"
        content.body = "Its status may be out of date, and new problems may not be reported. Quitting and reopening CalShare usually fixes it."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "problem.\(stallID)", content: content, trigger: nil))
    }

    nonisolated static func withdrawStall() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["problem.\(stallID)"])
    }

    private func post(_ item: ComponentHealth) {
        requestAuthorization()
        let content = UNMutableNotificationContent()
        let (title, body) = Self.text(for: item)
        content.title = title
        content.body = body
        content.sound = item.state == .error ? .default : nil
        // One notification per component: a newer one replaces the older.
        let request = UNNotificationRequest(identifier: "problem.\(item.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            let message = "Couldn't post: \(error.localizedDescription)"
            Task { @MainActor in Self.log(message, level: .warning) }
        }
        log("Posted: \(item.title) — \(item.summary)")
    }

    /// A notification says what is wrong and what it means for the devices, briefly. The
    /// specifics (addresses, ports, errors) stay on the dashboard, which the notification opens.
    static func text(for item: ComponentHealth) -> (title: String, body: String) {
        switch item.id {
        case "server":
            ("Calendar & Contacts Server Stopped", "Devices can't sync with CalShare until the server is running again.")
        case "setup":
            ("Device Setup Unavailable", "New devices can't be set up with a QR code until the setup service is running again.")
        case "certificate" where item.fix == .trustOnThisMac:
            ("Certificate Not Trusted", "Calendar and Contacts on this Mac can't sync with CalShare until its certificate is trusted.")
        case "certificate":
            ("Secure Connection Problem", "Devices can't sync with CalShare until its certificate is fixed.")
        case "access":
            ("Incoming Connections Blocked", "Devices can't sync with CalShare until incoming connections are allowed.")
        case "delivery" where item.fix == .restartServer:
            ("Devices May Be Missing Data", "Large transfers from CalShare aren't arriving intact, so devices may not have everything.")
        case "delivery":
            ("Problem Noticed", "CalShare noticed a problem that may keep a device from getting everything. The Overview has details.")
        case "network" where item.state == .error:
            ("This Mac's IP Address Changed", "Devices can't sync with CalShare until they can reach it again. CalShare's Overview shows how to fix it.")
        case "network":
            ("No Local Network Connection", "Devices can't sync with CalShare until this Mac reconnects to the network.")
        case "bonjour":
            ("Bonjour Discovery Stopped", "Configured devices will keep syncing, but new ones can't find CalShare on the network.")
        case "database" where item.state == .warning:
            ("Database Restored from Backup", "Each device syncs again in full to match the restored data.")
        case "database":
            ("Database Problem", "Devices can't sync with CalShare until the database is repaired.")
        case "backups" where item.state == .warning:
            ("Backups Are Out of Date", "CalShare hasn't backed up recent changes in over three days.")
        case "backups":
            ("Backup Failed", "Recent changes aren't backed up yet.")
        case "accounts" where item.fix == .clearLockouts:
            ("Address Blocked", "A device was blocked after repeated failed sign-in attempts.")
        case "accounts":
            ("No Accounts", "Devices can't sync with CalShare until an account is created.")
        default:
            (item.title, item.summary)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// While the dashboard is in front, it already shows the problem.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        await MainActor.run { NSApp.isActive && AppModel.dashboardWindow?.isKeyWindow == true } ? [] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { onOpen?() }
    }
}
