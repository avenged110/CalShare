// MARK: - SetupAssistant.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// First-run walkthrough: an account, a server health check, this Mac, another Mac, an
// iPhone, done.
// Each device step watches the server for that device's first sync and says so, so the
// user never has to guess whether it worked. Every step is laid out by SetupPage.

import AppKit
import CalShareCore
import SwiftUI

struct SetupAssistant: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case welcome, account, checks, thisMac, otherMac, phone, done

        /// Steps whose content can outgrow the sheet. The rest are laid out to fit it
        /// and sit fixed, with no scroll view.
        var scrolls: Bool {
            switch self {
            case .checks, .thisMac, .otherMac, .phone: true
            case .welcome, .account, .done: false
            }
        }
    }

    @State private var step = Step.welcome
    @State private var username = ""
    @State private var displayName = NSFullUserName()
    @State private var usernameEdited = false
    /// What was typed in the password field; empty means the generated password is used.
    @State private var password = ""
    @State private var generatedPassword = RandomToken.password()
    @State private var createdPassword: String?
    @State private var working = false
    @State private var openAtLogin = true
    @State private var keepAwake = false

    var body: some View {
        SheetChrome("Set Up CalShare") {
            Group {
                if step.scrolls {
                    PageScrollView { page }
                } else {
                    page.frame(maxHeight: .infinity, alignment: .top)
                }
            }
            // A fresh scroll position for every step.
            .id(step)
        } gutter: {
            footer
        }
        // From the server check on, the dashboard behind shows real status, matching
        // what this sheet shows.
        .onChange(of: step) { _, new in
            if new.rawValue >= Step.checks.rawValue { model.setupReachedChecks = true }
        }
        .onAppear {
            if username.isEmpty { username = AccountFields.suggestedUsername(from: displayName) }
            // The account this Mac already syncs with, if any, else the first account.
            if let existing = model.snapshot.thisMacClients.first?.username ?? model.snapshot.accounts.first?.username {
                username = existing
            }
            keepAwake = model.snapshot.configuration.keepAwake
            openAtLogin = model.snapshot.configuration.setupCompleted ? model.loginItemEnabled : true
        }
    }

    private var page: some View {
        content
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .account: account
        case .checks: checks
        case .thisMac: thisMac
        case .otherMac: otherMac
        case .phone: phone
        case .done: done
        }
    }

    // MARK: Steps

    private var welcome: some View {
        SetupPage(symbol: "calendar.badge.checkmark",
                  title: "Locally Sync Your Calendars and Contacts",
                  description: "CalShare turns this Mac into a private sync server for Calendar, Reminders, and Contacts — like iCloud, but your data stays on your devices.") {
            GroupedTable {
                GlyphLabel("You keep using Apple's applications exactly as before.", symbol: "apps.iphone")
                GlyphLabel("Everything is encrypted between your devices and this Mac.", symbol: "lock.fill")
                GlyphLabel("Backups happen automatically, and problems fix themselves where possible.", symbol: "arrow.triangle.2.circlepath")
            }
            SetupNote("Setup takes about five minutes. Keep your other devices handy and connected to the same network as this Mac.")
        }
    }

    @ViewBuilder private var account: some View {
        if let existing = model.snapshot.accounts.first(where: { $0.username == username }), createdPassword == nil {
            SetupPage(symbol: "person.crop.circle.badge.checkmark", title: "Your Account Is Ready",
                      description: "You already have the account “\(existing.username)”. Continue to set up devices with it, or create another one later in the Accounts tab.") {
                EmptyView()
            }
        } else if let createdPassword {
            SetupPage(symbol: "person.crop.circle.badge.checkmark", title: "Your Account Is Ready",
                      description: "Each device asks for this password once — save it in a password manager or write it down.") {
                GroupedTable {
                    CopyableValue(label: "Account name", value: username)
                    CopyableValue(label: "Password", value: createdPassword)
                }
            }
        } else {
            SetupPage(symbol: "person.crop.circle.badge.plus", title: "Create Your Account",
                      description: "This is what your devices sign in with. A strong password has been made for you — keep it by leaving the field empty, or create your own. You'll only enter it once per device.") {
                AccountFields(displayName: $displayName, username: $username, usernameEdited: $usernameEdited,
                              password: $password, generatedPassword: generatedPassword, taken: model.accountNames,
                              trailingFields: true)
            }
        }
    }

    private var checks: some View {
        SetupPage(symbol: "stethoscope", title: "Checking the Server",
                  description: "CalShare sets all of this up by itself. If something requires action on your part, it says so here.") {
            GroupedTable {
                ForEach(checkItems) { item in
                    HStack(alignment: .firstTextBaseline) {
                        StatusBadge(item.state)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.headline)
                            Text(item.summary).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.state >= HealthState.warning, let fix = item.fix, let title = item.fixTitle {
                            FixButton(title: title, fix: fix)
                        }
                    }
                }
            }
            if !model.snapshot.deviceHostname.isEmpty {
                SetupNote("Your devices will reach this Mac at **\(model.snapshot.deviceHostname)**. You can add a name for syncing away from home later in Settings.")
            }
        }
    }

    @ViewBuilder private var thisMac: some View {
        // There is only one of this Mac: once it syncs and trusts the server, re-running
        // setup has nothing left to do here, the way the account step works.
        if macAlreadySetUp {
            SetupPage(symbol: "checkmark.circle", title: "This Mac Is Ready",
                      description: "Calendar, Reminders, and Contacts on this Mac are already syncing with CalShare. There's nothing more to do here.") {
                EmptyView()
            }
        } else {
            SetupPage(symbol: "laptopcomputer", title: "Add CalShare to This Mac",
                      description: "This Mac trusts CalShare's certificate, then a setup profile adds the account to Calendar, Reminders, and Contacts.") {
                ThisMacCard(username: username, status: DeviceWaitIndicator(seen: macSeen, waitingText: "Waiting for this Mac to sync…",
                                                                            doneText: "This Mac is syncing."))
                SetupNote("Tip: To bring existing calendars over, use File › Export in Calendar, then File › Import into the CalShare calendar. In Contacts, drag cards from iCloud onto the CalShare account.")
            }
        }
    }

    private var otherMac: some View {
        SetupPage(symbol: "desktopcomputer", title: "Add Another Mac",
                  description: "Run the command below in Terminal on the other Mac, then open the address below in Safari. Each link works once, within \(SharedText.linkLifetimeWords), and only on this network.") {
            OtherMacCard(username: username, status: DeviceWaitIndicator(seen: otherMacSeen, waitingText: "Waiting for the other Mac to sync…",
                                                                         doneText: "The other Mac is syncing."))
        }
    }

    private var phone: some View {
        SetupPage(symbol: "iphone", title: "Add Your iPhone or iPad",
                  description: "Scan the code with the device's Camera. Each code works once, within \(SharedText.linkLifetimeWords), and only on this network.") {
            PhoneCard(username: username, status: DeviceWaitIndicator(seen: phoneSeen, waitingText: "Waiting for your device to sync…",
                                                                       doneText: "Your device is syncing."))
        }
    }

    private var done: some View {
        SetupPage(symbol: "checkmark.seal.fill", title: "You're All Set",
                  description: "Events, reminders, and contacts added to the CalShare account will sync across every device you added.") {
            GroupedTable {
                NotedToggle(SharedText.openAtLogin, note: SharedText.loginNote, isOn: $openAtLogin)
                NotedToggle(SharedText.keepAwake, note: SharedText.awakeNote, isOn: $keepAwake)
            }
            SetupNote("To make CalShare the default for new items, navigate to Settings › Apps › Calendar › Default Calendar, and Settings › Apps › Contacts › Default Account on iOS and Calendar › Settings › General on macOS.")
            SetupNote("You can close this window and CalShare will keep running in the background. Add more accounts and devices at any time from the dashboard.")
        }
    }

    // MARK: Gutter

    private var footer: some View {
        ZStack {
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                if step == .welcome && model.snapshot.configuration.setupCompleted {
                    GutterButton("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                } else if step == .welcome {
                    GutterButton("Exit and Quit") { confirmQuit() }
                } else {
                    GutterButton("Back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                        .disabled(working)
                }
                Spacer()
                if isOptional && !requirementMet {
                    GutterButton("Skip") { advance() }
                }
                GutterButton(primaryTitle) { primaryAction() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!requirementMet || working)
            }
        }
    }

    private var checkItems: [ComponentHealth] {
        let wanted: Set<String> = ["server", "setup", "access", "certificate", "network", "bonjour", "database"]
        return model.snapshot.health.filter { wanted.contains($0.id) }
    }

    private var hasAccount: Bool { model.snapshot.accounts.contains { $0.username == username } }
    private var macSeen: Bool { model.snapshot.thisMacClients.contains { $0.username == username } }
    /// Any other Mac syncing with CalShare, whichever account it uses.
    private var otherMacSeen: Bool { !model.snapshot.otherMacClients.isEmpty }
    /// Any iPhone or iPad syncing with CalShare, whichever account it uses.
    private var phoneSeen: Bool { !model.snapshot.mobileClients.isEmpty }
    /// This Mac syncs with CalShare (under any account) and trusts it. Devices are
    /// remembered across launches, so this holds as soon as the sheet opens.
    private var macAlreadySetUp: Bool {
        !model.snapshot.thisMacClients.isEmpty && model.snapshot.trustedOnThisMac != false
    }

    /// Steps that may be skipped. Skip shows only until the step's requirement is met;
    /// the primary button never skips.
    private var isOptional: Bool { step == .thisMac || step == .otherMac || step == .phone }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .account: hasAccount ? "Continue" : "Create Account"
        case .done: "Finish"
        default: "Continue"
        }
    }

    /// Whether the current step's requirement is satisfied, which is what enables the
    /// primary button.
    private var requirementMet: Bool {
        switch step {
        case .welcome, .done: true
        case .account: hasAccount || AccountFields.isValid(username: username, password: password, taken: model.accountNames)
        case .checks: model.snapshot.httpsPort != nil
        case .thisMac: macSeen || macAlreadySetUp
        case .otherMac: otherMacSeen
        case .phone: phoneSeen
        }
    }

    private func primaryAction() {
        guard requirementMet, !working else { return }
        switch step {
        case .account where !hasAccount:
            createAccount()
        case .done:
            if openAtLogin != model.loginItemEnabled { model.setLoginItem(openAtLogin) }
            let keepAwake = keepAwake
            model.updateConfiguration { $0.setupCompleted = true; $0.keepAwake = keepAwake }
            model.setupFinished()
            dismiss()
        default:
            advance()
        }
    }

    /// Quits from first-time setup. Setup isn't marked complete, so the assistant opens
    /// again on the next launch.
    private func confirmQuit() {
        model.present(.confirm(
            "Quit Setup?",
            "This will quit CalShare. The setup assistant will open again on the next launch and you will need to complete the setup process before you can use the application.",
            action: "Quit"
        ) {
            // AppKit silently refuses to terminate while a sheet is attached, so the sheet
            // is detached first, in the same turn, and the app quits before anything redraws.
            // Innermost first: the alert's own sheet may still be attached to the assistant's.
            while let parent = NSApp.windows.first(where: { $0.attachedSheet != nil && $0.attachedSheet?.attachedSheet == nil }),
                  let sheet = parent.attachedSheet {
                parent.endSheet(sheet)
            }
            model.showSetupAssistant = false
            NSApp.terminate(nil)
        })
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    private func createAccount() {
        working = true
        let (username, displayName) = (username, displayName)
        let password = AccountFields.effectivePassword(password, generated: generatedPassword)
        Task {
            let created = await model.run("Couldn't Create the Account") { [supervisor = model.supervisor] in
                try supervisor.createAccount(username: username, displayName: displayName, password: password)
            }
            if created != nil {
                createdPassword = password
                model.refresh()
            }
            working = false
        }
    }

}

/// The layout every setup step shares: a large glyph, the title, the description, then
/// the step's own content.
struct SetupPage<Content: View>: View {
    let symbol: String
    let title: String
    let description: String
    let content: Content

    init(symbol: String, title: String, description: String, @ViewBuilder content: () -> Content) {
        self.symbol = symbol
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .frame(height: 56)
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(description)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    // Twice the page's margin on each side: a narrower measure for the
                    // centered description alone.
                    .padding(.horizontal, 28)
            }
            .frame(maxWidth: .infinity)
            content
        }
    }
}

/// The one paragraph style of the setup assistant, below a step's content.
struct SetupNote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct DeviceWaitIndicator: View {
    let seen: Bool
    let waitingText: String
    let doneText: String

    var body: some View {
        HStack(spacing: 6) {
            if seen {
                StatusBadge(.ok)
                Text(doneText).foregroundStyle(.green)
            } else {
                ProgressView().controlSize(.small)
                Text(waitingText).foregroundStyle(.secondary)
            }
        }
        .animation(.default, value: seen)
        // Sat low in the cards; raised without changing their layout.
        .offset(y: -2)
    }
}
