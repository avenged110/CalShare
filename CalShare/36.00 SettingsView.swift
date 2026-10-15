// MARK: - SettingsView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import CalShareCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        // Read inside the scroll view, as on the Overview (see OverviewView).
        SectionPage { SettingsContent() }
    }
}

private struct SettingsContent: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.Key.showMenuBarItem) private var showMenuBarItem = true
    @AppStorage(Preferences.Key.closeToMenuBar) private var closeToMenuBar = false
    @AppStorage(Preferences.Key.launchTo) private var launchTo = Preferences.LaunchTo.dashboard.rawValue
    @AppStorage(Preferences.Key.loggingEnabled) private var loggingEnabled = false
    @AppStorage(Preferences.Key.notifyAboutProblems) private var notifyAboutProblems = true
    @AppStorage(Preferences.Key.hidePasswords) private var hidePasswords = true
    @State private var httpsPort = ""
    @State private var httpPort = ""
    @State private var showingHostnames = false
    @State private var loaded = false

    var body: some View {
        let configuration = model.snapshot.configuration
        // One view, so the modifiers below apply once rather than to every section.
        VStack(alignment: .leading, spacing: 20) {
            TableSection("General") {
                TableRow("Server name") {
                    Text(configuration.serverName)
                        .foregroundStyle(.secondary)
                }
                TableToggle(SharedText.openAtLogin, note: SharedText.loginNote, isOn: Binding(
                    get: { model.loginItemEnabled }, set: { model.setLoginItem($0) }))
                TableRow("At launch, open to:") {
                    MenuPicker(selection: $launchTo, items: [
                        .option(tag: Preferences.LaunchTo.dashboard.rawValue, title: "Dashboard Window"),
                        .option(tag: Preferences.LaunchTo.menuBar.rawValue, title: "MenuBar Only"),
                    ])
                }
                TableToggle("Close to MenuBar", note: "When the dashboard is closed, CalShare runs only in the MenuBar, without appearing in the Dock.",
                            isOn: Binding(get: { closeToMenuBar }, set: { closeToMenuBar = $0; DockPresence.update() }))
                TableToggle(SharedText.keepAwake, note: SharedText.awakeNote, isOn: Binding(
                    get: { configuration.keepAwake },
                    set: { value in model.updateConfiguration { $0.keepAwake = value } }))
                // Closing or launching to the MenuBar needs the MenuBar item, so either holds this on.
                TableToggle("Show CalShare in the MenuBar", isOn: Binding(
                    get: { showMenuBarItem || needsMenuBarItem }, set: { showMenuBarItem = $0 }))
                    .disabled(needsMenuBarItem)
                TableToggle("Send a notification when something needs attention", isOn: $notifyAboutProblems)
            }

            TableSection("Network") {
                TableRow("Server identity", note: "The .local name keeps working when your router gives this Mac a new IP address. To use an IP address instead, first reserve it for this Mac on your router.") {
                    // Confirm before commit, as Film Tracker's release Type picker does: the
                    // binding declines the write and asks, and the button stays on the old
                    // choice, so Cancel has nothing to undo. Only "Change Anyway" writes.
                    let network = model.snapshot.network
                    let automatic = network.bonjourHostName.isEmpty ? network.primaryLANAddress : network.bonjourHostName
                    // A chosen address this Mac no longer has stays listed, so the
                    // button still shows what devices were given.
                    let missing = configuration.preferredHostname.flatMap { model.snapshot.hostnameChoices.contains($0) ? nil : $0 }
                    MenuPicker(selection: Binding(
                        get: { configuration.preferredHostname ?? "" },
                        set: { value in
                            guard value != (configuration.preferredHostname ?? "") else { return }
                            confirmHostnameChange(to: value)
                        }),
                        items: [.option(tag: "", title: "\(automatic ?? "This Mac's name") (automatic)")]
                            + model.snapshot.hostnameChoices.filter { $0 != automatic }.map { .option(tag: $0, title: $0) }
                            + (missing.map { [.option(tag: $0, title: "\($0) (unavailable)")] } ?? []))
                }
                TableRow("Remote hostnames", note: "To sync with CalShare away from home, add a name that reaches this Mac over the Internet or a VPN, then select this name in “Server identity”.") {
                    Button("Manage Hostnames…") { showingHostnames = true }
                }
                TableToggle("Announce with Bonjour", isOn: Binding(
                    get: { configuration.bonjourEnabled },
                    set: { value in model.updateConfiguration { $0.bonjourEnabled = value } }))
                TableRow("Secure port (CalDAV/CardDAV)") {
                    PortField(text: $httpsPort, current: configuration.httpsPort) { confirmSecurePortChange() }
                }
                TableRow("Setup port") {
                    PortField(text: $httpPort, current: configuration.httpPort) { applySetupPort() }
                }
                HStack {
                    Spacer()
                    Button("Reset Ports to Defaults") { confirmResetPorts() }
                        .disabled(configuration.httpsPort == Self.defaults.httpsPort
                                  && configuration.httpPort == Self.defaults.httpPort)
                }
            }

            TableSection("Security", footer: "CalShare stores passwords only as salted PBKDF2 hashes. The profile for this Mac carries the password you type, and is deleted once it's given to macOS. Profiles for other devices never contain a password; those devices ask for it during profile installation.") {
                TableRow("Authority fingerprint") {
                    Text(model.snapshot.authorityFingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                TableRow("Server certificate", note: model.snapshot.certificateExpiry.map {
                    "Renews automatically. Valid until \($0.formatted(date: .abbreviated, time: .omitted))."
                }) {
                    Button("Renew Certificate Now") { model.perform(.reissueCertificate) }
                }
                TableRow(blockedTitle, note: "An address is temporarily blocked after repeated failed sign in attempts.") {
                    Button("Unblock All Addresses") { model.perform(.clearLockouts) }
                        .disabled(model.snapshot.lockedOutAddresses.isEmpty)
                }
            }

            TableSection("Privacy") {
                TableToggle("Obscure passwords in the interface",
                            note: "This does not apply to password prompts from macOS itself.",
                            isOn: $hidePasswords)
            }

            TableSection("Troubleshooting") {
                TableToggle("Debug logging", note: "Messages are buffered before being written to disk every ten seconds.",
                            isOn: $loggingEnabled)
                    .onChange(of: loggingEnabled) { _, enabled in
                        if !enabled { Logger.shutdownLogging() }
                    }
                HStack {
                    Spacer()
                    Button("Reveal Log in Finder") {
                        Logger.prepareLogDirectory()
                        NSWorkspace.shared.activateFileViewerSelecting([Logger.safeLogFileURL])
                    }
                    Button(SharedText.setupAssistant) { model.showSetupAssistant = true }
                }
            }

            // Debug builds only: release builds have no way to wipe the installation.
            #if DEBUG
            TableSection("Testing") {
                TableRow("Wipe installation", note: "Erase everything and quit, so the next launch starts fresh.") {
                    Button("Reset for Testing…", role: .destructive) { confirmReset() }
                }
            }
            #endif
        }
        .onAppear { if !loaded { loadPorts(); loaded = true } }
        // A port changed elsewhere (by "Use Next Free Port", say) replaces the field's
        // value unless the field holds an edit of its own.
        .onChange(of: model.snapshot.configuration) { old, new in
            if httpsPort == String(old.httpsPort) { httpsPort = String(new.httpsPort) }
            if httpPort == String(old.httpPort) { httpPort = String(new.httpPort) }
        }
        .sheet(isPresented: $showingHostnames) {
            RemoteHostnamesSheet()
                .environment(model)
        }
    }

    private var needsMenuBarItem: Bool {
        closeToMenuBar || launchTo == Preferences.LaunchTo.menuBar.rawValue
    }

    private var blockedTitle: String {
        let count = model.snapshot.lockedOutAddresses.count
        return count == 0 ? "No blocked addresses" : "\(count) blocked address\(count == 1 ? "" : "es")"
    }

    private static let defaults = ServerConfiguration()
    private static let newProfileNote = "Devices already configured to connect to CalShare will require a new profile."

    private func loadPorts() {
        httpsPort = String(model.snapshot.configuration.httpsPort)
        httpPort = String(model.snapshot.configuration.httpPort)
    }

    private func confirmSecurePortChange() {
        guard let port = UInt16(httpsPort) else { return }
        model.present(.confirm("Change the Secure Port?", Self.newProfileNote, action: "Change Anyway",
                                cancel: { httpsPort = String(model.snapshot.configuration.httpsPort) }) {
            changePorts(https: port, http: model.snapshot.configuration.httpPort)
        })
    }

    private func applySetupPort() {
        guard let port = UInt16(httpPort) else { return }
        changePorts(https: model.snapshot.configuration.httpsPort, http: port)
    }

    private func confirmResetPorts() {
        let secureChanges = model.snapshot.configuration.httpsPort != Self.defaults.httpsPort
        let ports = "\(Self.defaults.httpsPort) (secure) and \(Self.defaults.httpPort) (setup)"
        model.present(.confirm(
            "Reset Ports to Defaults?",
            "CalShare will use ports \(ports)." + (secureChanges ? " " + Self.newProfileNote : ""),
            action: "Reset Ports") {
                changePorts(https: Self.defaults.httpsPort, http: Self.defaults.httpPort)
            })
    }

    /// Applies the ports, or, when the server refuses them, says so and puts the fields
    /// back to the ports still in use.
    private func changePorts(https: UInt16, http: UInt16) {
        let old = model.snapshot.configuration
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [supervisor = model.supervisor] in
                    try supervisor.changePorts(https: https, http: http)
                }.value
                httpsPort = String(https)
                httpPort = String(http)
            } catch {
                httpsPort = String(old.httpsPort)
                httpPort = String(old.httpPort)
                let reverted = https != old.httpsPort && http != old.httpPort ? "Both ports have been changed back to their prior values."
                    : "The port has been changed back to its prior value, \(https != old.httpsPort ? old.httpsPort : old.httpPort)."
                model.present(.notice("Couldn't Change the Port", "\(error) \(reverted)"))
            }
        }
    }

    private func confirmHostnameChange(to value: String) {
        model.present(.confirm(
            "Change the Address Devices Connect To?",
            "Devices already configured to connect to CalShare will require a new profile.",
            action: "Change Anyway") { [model] in
                model.updateConfiguration { $0.preferredHostname = value.isEmpty ? nil : value }
            })
    }

    #if DEBUG
    private func confirmReset() {
        model.present(.confirm(
            "Reset CalShare for Testing?",
            """
            The server stops, and CalShare deletes its database, backups, certificates, settings, \
            preferences, logs, its login item, and any setup profiles it saved in Downloads, then quits. \
            This can't be undone.

            Profiles already installed on this Mac or other devices aren't touched; remove those in \
            System Settings › General › Device Management (on iPhone: Settings › General › VPN & Device Management).
            """,
            action: "Erase and Quit", role: .destructive) { [model] in model.resetForTesting() })
    }
    #endif
}

// MARK: - PortField

/// A port number with its own Apply button, which is on only while the field holds a
/// different port from the one in use.
private struct PortField: View {
    @Binding var text: String
    let current: UInt16
    let apply: () -> Void

    /// Room for any five-digit port in the monospaced font, plus the bezel's insets.
    private static let width: CGFloat = {
        let field = NSTextField(string: "00000")
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.bezelStyle = .roundedBezel
        return ceil(field.cell?.cellSize.width ?? 50) + 4
    }()

    var body: some View {
        HStack(spacing: 8) {
            FilteredTextField(text: $text, filter: .port, alignment: .center, monospaced: true,
                              onSubmit: { if canApply { apply() } })
                .frame(width: Self.width)
            Button("Apply", action: apply)
                .disabled(!canApply)
        }
    }

    private var canApply: Bool { UInt16(text).map { $0 != current } ?? false }
}

