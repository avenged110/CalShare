// MARK: - DevicesView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import CalShareCore
import CoreImage.CIFilterBuiltins
import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedAccount: String?

    var body: some View {
        let accounts = model.snapshot.accounts
        // The chosen account while it exists; after it's deleted, the first one left.
        let username = accounts.first { $0.username == selectedAccount }?.username ?? accounts.first?.username
        HeaderedPage("Add the account once on each device, using the card for that device. Calendar, Reminders, and Contacts then sync on their own.") {
            // Always here, so the header never changes; there's only a choice with two or more.
            HStack {
                Text("Account:")
                    .foregroundStyle(accounts.count < 2 ? AnyShapeStyle(disabledControlTextColor) : AnyShapeStyle(.primary))
                // Room for long account names.
                MenuPicker(selection: Binding(get: { username ?? "" }, set: { selectedAccount = $0 }),
                           items: accounts.isEmpty ? [.option(tag: "", title: "None")]
                               : accounts.map { .option(tag: $0.username, title: $0.displayName.isEmpty ? $0.username : "\($0.displayName) (\($0.username))") },
                           width: 240)
            }
            .disabled(accounts.count < 2)
        } content: {
            // Read inside the scroll view, as on the Overview (see OverviewView): only a
            // different account makes this a new page.
            DevicesContent(username: username)
        }
    }
}

private struct DevicesContent: View {
    @Environment(AppModel.self) private var model
    /// Nil only while there are no accounts.
    let username: String?

    var body: some View {
        if model.snapshot.health.contains(where: { $0.id == "access" && $0.state == .error }) {
            BlockedConnectionsCard()
        }
        if let username {
            ThisMacCard(username: username)
            OtherMacCard(username: username)
            PhoneCard(username: username)
            ManualSetupCard(username: username)
        } else {
            Card {
                Text("Create an Account First").font(.headline)
                Button("Go to Accounts") { model.show(.accounts) }
            }
        }
        ConnectedDevicesCard()
    }
}

/// Every setup card has the same shape: a title (with an optional status at the far
/// end of its row), numbered steps, then the controls that carry them out.
struct SetupCard<Controls: View>: View {
    let title: String
    let symbol: String
    let steps: [String]
    let status: AnyView?
    let controls: Controls

    init(_ title: String, symbol: String, steps: [String], status: AnyView? = nil, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.symbol = symbol
        self.steps = steps
        self.status = status
        self.controls = controls()
    }

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                // Every card's glyph gets the same slot, so the titles line up.
                GlyphLabel(title, symbol: symbol)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                if let status { status }
            }
            InstructionList(steps: steps)
            controls
        }
    }
}

struct ThisMacCard: View {
    @Environment(AppModel.self) private var model
    let username: String
    /// Shown at the end of the title row (the setup assistant's sync indicator).
    var status: DeviceWaitIndicator?
    @State private var password = ""
    @State private var wrongPassword = false
    @State private var working = false

    var body: some View {
        SetupCard("This Mac", symbol: "laptopcomputer", steps: [
            "Enter the password for the CalShare account “\(username)” and click “Add to This Mac”.",
            "If macOS asks, enter your Mac's login password to trust CalShare's certificate.",
            "In System Settings, which opens on its own, double-click “CalShare — \(username)”, then click “Install” and confirm the installation.",
        ], status: status.map { AnyView($0) }) {
            GroupedTable {
                HStack(alignment: .firstTextBaseline) {
                    TableLabel("Password")
                    PasswordField("Account password", text: $password, prompt: Text("Password for “\(username)”"))
                        .labelsHidden()
                        .frame(width: 240)
                        .onSubmit(add)
                        .onChange(of: password) { wrongPassword = false }
                    Spacer(minLength: 8)
                    Button("Add to This Mac", action: add)
                        .buttonStyle(.borderedProminent)
                        .disabled(password.isEmpty || working)
                }
            }
            if wrongPassword {
                Text("That isn't the password for “\(username)”. If it's lost, reset it in Accounts.")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("The password goes into the profile, so macOS doesn't ask for it, and the profile file is deleted as soon as macOS has it. This Mac connects to CalShare directly (as localhost), so firewalls and network changes never get in the way.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: username) { password = ""; wrongPassword = false }
    }

    private func add() {
        guard !password.isEmpty, !working else { return }
        working = true
        Task {
            let result = await model.installProfileOnThisMac(username: username, password: password)
            working = false
            wrongPassword = result == .wrongPassword
            // Kept for another try unless the profile went through.
            if result == .opened { password = "" }
        }
    }
}

/// A setup link and its QR code, made together off the main thread.
struct EnrollmentCode: @unchecked Sendable {
    let url: URL
    let issued: Date
    /// Immutable once made, so safe to hand across threads.
    let qrCode: CGImage?

    var expires: Date { issued.addingTimeInterval(SharedText.linkLifetime) }
}

/// A fifteen-minute setup link for the account, kept fresh while on screen. Another Mac
/// opens it in Safari; an iPhone or iPad scans it as a QR code.
struct EnrollmentLink: ViewModifier {
    @Environment(AppModel.self) private var model
    let username: String
    /// Whether the card shows the link as a QR code too.
    let qrCode: Bool
    @Binding var code: EnrollmentCode?

    func body(content: Content) -> some View {
        content
            .task(id: "\(username)|\(model.snapshot.httpPort ?? 0)|\(model.snapshot.httpsPort ?? 0)|\(model.snapshot.deviceHostname)|\(model.snapshot.enrollmentUses)") { await refresh() }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    if let code, Date().timeIntervalSince(code.issued) > SharedText.linkLifetime - 3 * 60 { await refresh() }
                }
            }
    }

    private func refresh() async {
        code = await Self.issue(for: username, qrCode: qrCode, supervisor: model.supervisor)
    }

    static func issue(for username: String, qrCode: Bool, supervisor: Supervisor) async -> EnrollmentCode? {
        await Task.detached(priority: .userInitiated) {
            // Another Mac (no QR code) trusts the authority by now, from the Terminal step, so
            // its link is HTTPS; an iPhone or iPad doesn't until the profile is installed.
            guard let url = supervisor.enrollmentURL(for: username, secure: !qrCode) else { return nil }
            return EnrollmentCode(url: url, issued: Date(), qrCode: qrCode ? QRCodeView.render(url.absoluteString) : nil)
        }.value
    }

    /// A stand-in as long as the real address, so the address row is laid out at its final
    /// size before the link exists.
    static func placeholder(snapshot: SupervisorSnapshot, secure: Bool) -> String {
        let host = snapshot.deviceHostname.contains(":") ? "[\(snapshot.deviceHostname)]" : snapshot.deviceHostname
        let port = secure ? snapshot.httpsPort ?? snapshot.configuration.httpsPort : snapshot.httpPort ?? snapshot.configuration.httpPort
        return "\(secure ? "https" : "http")://\(host):\(port)/enroll/" + String(repeating: "x", count: 24)
    }
}

/// The setup link's address and expiration rows, shared by Another Mac and iPhone or iPad.
struct EnrollmentRows: View {
    @Environment(AppModel.self) private var model
    let username: String
    /// Whether the card shows the link as a QR code too.
    let qrCode: Bool
    @Binding var code: EnrollmentCode?
    @State private var refreshes = 0

    var body: some View {
        CopyableValue(label: "Address", value: code?.url.absoluteString ?? EnrollmentLink.placeholder(snapshot: model.snapshot, secure: !qrCode),
                      shareURL: code?.url, ready: code != nil, sharable: true, small: true)
        ValueRow("Code expiration") {
            if let code {
                Text(timerInterval: code.issued...code.expires, countsDown: true)
                    .font(.body.monospacedDigit())
            } else {
                Text((qrCode ? model.snapshot.httpPort : model.snapshot.httpsPort) == nil ? "Waiting for the setup service…" : " ")
                    .foregroundStyle(.secondary)
            }
        } buttons: {
            Button {
                refreshes += 1
                Task { code = await EnrollmentLink.issue(for: username, qrCode: qrCode, supervisor: model.supervisor) ?? code }
            } label: {
                // Turns once per click, so it's clear the click took. A plain rotation: the
                // discrete SF Symbols rotate effect (triggered by a value) doesn't play on
                // macOS 15, while CopyButton's replace is a content transition, which does.
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .rotationEffect(.degrees(Double(refreshes) * 360))
                    // The pages turn animations off (ModelEnvironment); a click turns them
                    // back on for itself.
                    .transaction(value: refreshes) { transaction in
                        transaction.disablesAnimations = false
                        transaction.animation = .easeInOut(duration: 0.6)
                    }
                    .frame(width: CopyButton.glyphSize, height: CopyButton.glyphSize)
            }
            .controlSize(.small)
            .disabled(code == nil)
            .help("Generate a new code that lasts another \(SharedText.linkLifetimeWords)")
        }
    }
}

struct OtherMacCard: View {
    @Environment(AppModel.self) private var model
    let username: String
    /// Shown at the end of the title row (the setup assistant's sync indicator).
    var status: DeviceWaitIndicator?
    @State private var code: EnrollmentCode?

    var body: some View {
        SetupCard("Another Mac", symbol: "desktopcomputer", steps: [
            "Connect the device to the same network as this Mac.",
            "Open Terminal, paste the command below, press Return, and enter that Mac's login password when macOS asks to change its certificate trust settings.",
            "Open Safari and navigate to the address below. If prompted, click “Allow” to download the profile.",
            "Open System Settings › General › Device Management and double-click “CalShare — \(username)”.",
            "Click “Install” and enter the password for the CalShare account “\(username)” each time it's requested; don't leave it blank.",
        ], status: status.map { AnyView($0) }) {
            GroupedTable {
                let command = TrustCommand.make(snapshot: model.snapshot)
                CopyableValue(label: "Command", value: command ?? TrustCommand.placeholder, shareText: command,
                              ready: command != nil, sharable: true, small: true)
                EnrollmentRows(username: username, qrCode: false, code: $code)
            }
            Text("The Terminal command is necessary because macOS otherwise won't trust CalShare's root certificate, specifically for SSL/TLS connections, without manual intervention.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Another Mac opens the link itself, so no QR code is made for it.
        .modifier(EnrollmentLink(username: username, qrCode: false, code: $code))
    }
}

/// A Terminal command that makes another Mac trust CalShare's authority for SSL, which a
/// profile can't grant a Mac. It fetches the certificate over the setup service, refuses it
/// unless its SHA-256 fingerprint matches, and sets trust for the current user only.
enum TrustCommand {
    static func make(snapshot: SupervisorSnapshot) -> String? {
        guard let port = snapshot.httpPort, !snapshot.authorityFingerprint.isEmpty else { return nil }
        let host = snapshot.deviceHostname.contains(":") ? "[\(snapshot.deviceHostname)]" : snapshot.deviceHostname
        let hex = snapshot.authorityFingerprint.replacingOccurrences(of: ":", with: "").lowercased()
        return command(host: host, port: port, hex: hex)
    }

    private static func command(host: String, port: UInt16, hex: String) -> String {
        "f=$(mktemp) && curl -fsS -m 20 http://\(host):\(port)/calshare-authority.cer -o \"$f\" && "
            + "[ \"$(shasum -a 256 \"$f\" | cut -c1-64)\" = \"\(hex)\" ] && "
            + "security add-trusted-cert -r trustRoot -p ssl -k ~/Library/Keychains/login.keychain-db \"$f\" && "
            + "echo \"CalShare certificate trusted.\" || echo \"CalShare certificate not trusted. Copy the command from CalShare again and retry.\"; rm -f \"$f\""
    }

    /// A stand-in of about the same length, so the row is laid out at its final size.
    static let placeholder = command(host: "calshare-server.local", port: 8080, hex: String(repeating: "0", count: 64))
}

struct PhoneCard: View {
    let username: String
    /// Shown at the end of the title row (the setup assistant's sync indicator).
    var status: DeviceWaitIndicator?
    @State private var code: EnrollmentCode?

    var body: some View {
        SetupCard("iPhone or iPad", symbol: "iphone", steps: PhoneSteps.steps(username: username),
                  status: status.map { AnyView($0) }) {
            GroupedTable {
                // The code's space is reserved; the code appears in it when it's ready.
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                        .opacity(code == nil ? 1 : 0)
                    if let code {
                        QRCodeView(image: code.qrCode)
                    }
                }
                .frame(width: 160, height: 160)
                .frame(maxWidth: .infinity)
                EnrollmentRows(username: username, qrCode: true, code: $code)
            }
        }
        .modifier(EnrollmentLink(username: username, qrCode: true, code: $code))
    }
}

enum PhoneSteps {
    static func steps(username: String) -> [String] {
        [
            "Connect the device to the same local network as this Mac.",
            "Point the Camera at the code below, tap the link, then tap “Allow” to download the profile, or open the address manually instead.",
            "Open Settings, tap “Profile Downloaded” near the top, then “Install”. Enter the password for the CalShare account “\(username)” each time it's requested; don't leave it blank.",
            "In Settings › General › About › Certificate Trust Settings, turn on “CalShare Local Authority”.",
        ]
    }
}

struct ManualSetupCard: View {
    @Environment(AppModel.self) private var model
    let username: String

    var body: some View {
        let snapshot = model.snapshot
        let port = snapshot.httpsPort ?? snapshot.configuration.httpsPort
        SetupCard("Other Applications and Devices", symbol: "wrench.and.screwdriver", steps: [
            "Download the certificate below and install it on the device as a trusted root certificate. Android, Windows, and Linux each have a place for this in their security settings.",
            "In the application (for example DAVx⁵ on Android, or Thunderbird), add a CalDAV account and a CardDAV account using the values below and the password for the CalShare account “\(username)”.",
        ]) {
            GroupedTable {
                CopyableValue(label: "Server URL", value: "https://\(snapshot.deviceHostname):\(port)/dav/")
                CopyableValue(label: "User name", value: username)
                CopyableValue(label: "Server", value: snapshot.deviceHostname)
                CopyableValue(label: "Port", value: "\(port) (SSL on)")
                CopyableValue(label: "Principal path", value: "/dav/principals/\(username)/")
                CopyableValue(label: "Fingerprint", value: snapshot.authorityFingerprint, small: true)
            }
            Button("Download Certificate…") { model.saveAuthorityCertificate() }
            Text("On an Apple device without a profile, use System Settings › Internet Accounts › Add Other Account › CalDAV or CardDAV, Account Type: Manual, with the same values.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shown at the top of the page when the server can't be reached from the network, since
/// no other device can be set up until that is fixed.
struct BlockedConnectionsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let https = model.snapshot.httpsPort ?? model.snapshot.configuration.httpsPort
        let http = model.snapshot.httpPort ?? model.snapshot.configuration.httpPort
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusBadge(.error, diameter: 20)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Other Devices Can't Reach CalShare").font(.headline)
                    Text("Something on this Mac refuses incoming connections to CalShare, almost always a firewall. Until that's fixed, other devices can't sync, and setup profiles fail to install.")
                        .fixedSize(horizontal: false, vertical: true)
                    InstructionList(steps: [
                        "Little Snitch: Add a rule that allows CalShare incoming TCP connections on ports \(https) and \(http) from the local network. A rule allowing outgoing connections doesn't cover this.",
                        "macOS firewall: System Settings › Network › Firewall › Options, set CalShare to Allow incoming connections.",
                        "Lulu or another firewall: Allow incoming connections for CalShare.",
                    ])
                    FixButton(title: "Check Now", fix: .checkNetworkAccess, controlSize: .regular)
                }
            }
        }
    }
}

struct ConnectedDevicesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            GlyphLabel("Devices Seen", symbol: "antenna.radiowaves.left.and.right")
                .font(.title3.weight(.semibold))
            if model.snapshot.clients.isEmpty {
                Text("No device has synced in the last 30 days.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Device").bold()
                        Text("Service").bold()
                        Text("Account").bold()
                        Text("Address").bold()
                        Text("Last Sync").bold()
                    }
                    .foregroundStyle(.secondary)
                    ForEach(model.snapshot.clients) { client in
                        GridRow {
                            GlyphLabel(client.platform,
                                       symbol: client.platform.hasPrefix("iOS") || client.platform.hasPrefix("iPadOS") ? "iphone" : "desktopcomputer",
                                       glyphWidth: 22)
                            Text(ClientNames.friendly(client.product))
                            Text(client.username)
                            Text(client.remoteAddress).monospaced()
                            // Kept current on its own: the page re-renders only when the
                            // snapshot changes.
                            TimelineView(.periodic(from: .now, by: 5)) { _ in
                                Text(client.lastSeen.relative)
                            }
                        }
                    }
                }
            }
        }
    }
}

enum ClientNames {
    static func friendly(_ product: String) -> String {
        switch product {
        case "dataaccessd": "Calendar & Contacts"
        case "CalendarAgent": "Calendar"
        case "AddressBookCore", "AddressBookSourceSync", "ContactsAgent": "Contacts"
        case "remindd": "Reminders"
        case "": "Unknown"
        default: product
        }
    }
}

struct InstructionList: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.tint.opacity(0.2)))
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct QRCodeView: View {
    /// Made off the main thread with `render`.
    let image: CGImage?

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    nonisolated static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
