// MARK: - Preferences.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// App-level preferences kept in UserDefaults. Server settings live in the Supervisor's
// configuration file instead, so the server never depends on the UI's defaults domain.

import Foundation

enum Preferences {
    enum Key {
        nonisolated static let loggingEnabled = "debugLoggingEnabled"
        nonisolated static let showMenuBarItem = "showMenuBarItem"
        nonisolated static let notifyAboutProblems = "notifyAboutProblems"
        nonisolated static let hidePasswords = "hidePasswords"
        nonisolated static let sidebarVisible = "sidebarVisible"
        nonisolated static let closeToMenuBar = "closeToMenuBar"
        nonisolated static let launchTo = "launchTo"
    }

    /// What any launch brings up: the dashboard as a regular app, or only the MenuBar item
    /// as an accessory app. Whether CalShare launches at login is the login item's own
    /// state (SMAppService), not a preference.
    enum LaunchTo: String {
        case dashboard, menuBar
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.loggingEnabled: false,
            Key.showMenuBarItem: true,
            Key.notifyAboutProblems: true,
            Key.hidePasswords: true,
            Key.sidebarVisible: true,
            Key.closeToMenuBar: false,
            Key.launchTo: LaunchTo.dashboard.rawValue,
        ])
    }

    nonisolated static var loggingEnabled: Bool { UserDefaults.standard.bool(forKey: Key.loggingEnabled) }
    nonisolated static var notifyAboutProblems: Bool { UserDefaults.standard.bool(forKey: Key.notifyAboutProblems) }
    nonisolated static var closeToMenuBar: Bool { UserDefaults.standard.bool(forKey: Key.closeToMenuBar) }
    nonisolated static var launchTo: LaunchTo {
        UserDefaults.standard.string(forKey: Key.launchTo).flatMap(LaunchTo.init) ?? .dashboard
    }
}
