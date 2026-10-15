// MARK: - SharedText.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Wording that appears in more than one place (Settings and the setup assistant, the
// menus and the pages), kept here so the copies can never drift apart.

import CalShareCore
import Foundation

enum SharedText {
    // Settings and the setup assistant's last step.
    static let openAtLogin = "Launch at login"
    static let keepAwake = "Prevent this Mac from sleeping"
    static let awakeNote = "Devices can only sync with the server while this Mac is awake."
    static let loginNote = "Devices can only sync with the server while CalShare is running."

    // Menus, the menu bar item and pages.
    static let setUpDevice = "Set Up a Device…"
    static let backUpNow = "Back Up Now"
    static let restartServer = "Restart Server"
    static let setupAssistant = "Show Setup Assistant…"

    /// How long a setup link or QR code works.
    static let linkLifetime = EnrollmentHandler.defaultLifetime
    /// The same, in words: "fifteen minutes".
    static let linkLifetimeWords: String = {
        let minutes = Int(linkLifetime / 60)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .spellOut
        return "\(formatter.string(from: minutes as NSNumber) ?? "\(minutes)") minutes"
    }()
}
