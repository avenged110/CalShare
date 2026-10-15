// MARK: - AccountsView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import CalShareCore
import SwiftUI

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewAccount = false
    @State private var passwordReveal: PasswordReveal?

    var body: some View {
        HeaderedPage("Each account stores its own content. The individual calendars, their events, reminders, and contacts that make up this content are created and managed in Apple's applications.") {
            Button("Add New Account…") { showingNewAccount = true }
        } content: {
            if model.snapshot.accounts.isEmpty {
                Card {
                    Text("No Accounts Yet").font(.headline)
                    Text("Create an account to start syncing. You'll use its name and password when setting up CalShare on each device.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.snapshot.accounts) { account in
                AccountCard(account: account,
                            resetPassword: { confirmResetPassword(account) },
                            delete: { confirmDelete(account) })
            }
        }
        .sheet(isPresented: $showingNewAccount) {
            NewAccountSheet { reveal in passwordReveal = reveal }
                .environment(model)
        }
        .sheet(item: $passwordReveal) { reveal in
            PasswordRevealSheet(reveal: reveal)
                .environment(model)
        }
    }

    private func confirmDelete(_ account: AccountSummary) {
        model.present(.confirm(
            "Delete the Account “\(account.username)”?",
            "All of its calendars, reminders, and contacts will be removed from this server. A backup is taken first, and devices keep their local copies until they next sync.",
            action: "Delete Account", role: .destructive) { [model] in
                Task { _ = await model.run("Couldn't Delete the Account") { [supervisor = model.supervisor] in try supervisor.deleteAccount(account.username) } }
            })
    }

    private func confirmResetPassword(_ account: AccountSummary) {
        model.present(.confirm(
            "Reset the Password for “\(account.username)”?",
            "CalShare creates a new password and shows it to you. Devices already configured will ask for it the next time they sync.",
            action: "Reset Password") { resetPassword(account) })
    }

    private func resetPassword(_ account: AccountSummary) {
        let password = RandomToken.password()
        Task {
            if await model.run("Couldn't Change the Password", { [supervisor = model.supervisor] in
                try supervisor.setPassword(password, for: account.username)
            }) != nil {
                passwordReveal = PasswordReveal(username: account.username, password: password, isNew: false)
            }
        }
    }
}

struct PasswordReveal: Identifiable {
    var id: String { username }
    var username: String
    var password: String
    var isNew: Bool
}

struct AccountCard: View {
    @Environment(AppModel.self) private var model
    let account: AccountSummary
    let resetPassword: () -> Void
    let delete: () -> Void

    var body: some View {
        Card {
            // Centered as a row, so the menu sits midway between the card's top and the divider.
            HStack(alignment: .center) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34))
                    // The person in the primary color, on an accent-colored circle.
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.primary, Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName.isEmpty ? account.username : account.displayName)
                        .font(.title3.weight(.semibold))
                    Text("Account name: \(account.username)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button(SharedText.setUpDevice) { model.show(.devices) }
                    Button("Reset Password…", action: resetPassword)
                    Divider()
                    Button("Delete Account…", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
        } content: {
            // Grouped by type: calendars, then reminders lists, then address books.
            let isReminders: (CollectionSummary) -> Bool = { $0.components == ["VTODO"] }
            let calendars = account.collections.filter { $0.kind == .calendar && !isReminders($0) }
                + account.collections.filter { $0.kind == .calendar && isReminders($0) }
            let books = account.collections.filter { $0.kind == .addressBook }
            // Fixed columns, with the name taking what's left: no name, however long, moves
            // the other columns.
            GroupedTable(dividers: .belowTitles, rowPadding: 4) {
                CollectionRow(marker: EmptyView(), name: "Name", kind: "Type", count: "Contents")
                    .bold()
                    .foregroundStyle(.secondary)
                ForEach(calendars) { collection in
                    CollectionRow(marker: Circle().fill(Color(hexString: collection.color) ?? .accentColor).frame(width: 10, height: 10),
                                  name: collection.displayName.isEmpty ? "Untitled" : collection.displayName,
                                  kind: collection.components == ["VTODO"] ? "Reminders list" : "Calendar",
                                  count: "\(collection.itemCount) item\(collection.itemCount == 1 ? "" : "s")")
                }
                ForEach(books) { collection in
                    CollectionRow(marker: Image(systemName: "person.crop.square").foregroundStyle(.secondary),
                                  name: collection.displayName.isEmpty ? "Contacts" : collection.displayName,
                                  kind: "Address book",
                                  count: "\(collection.itemCount) contact\(collection.itemCount == 1 ? "" : "s")")
                }
            }
        }
    }
}

/// One row of an account's collection table.
private struct CollectionRow<Marker: View>: View {
    let marker: Marker
    let name: String
    let kind: String
    let count: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            marker.frame(width: 14)
            Text(name).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(kind).foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(count).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 110, alignment: .trailing)
        }
    }
}

struct NewAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onCreated: (PasswordReveal) -> Void

    @State private var displayName = ""
    @State private var username = ""
    @State private var usernameEdited = false
    @State private var password = ""
    @State private var generatedPassword = RandomToken.password()
    @State private var working = false
    /// Captured when the sheet opens, so the account it creates never flags itself as taken
    /// while the sheet closes.
    @State private var taken: Set<String> = []

    var body: some View {
        SheetChrome("Create New Account", height: nil) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Devices sign in with the account name and password. The suggested password below will be used unless you enter your own.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AccountFields(displayName: $displayName, username: $username, usernameEdited: $usernameEdited,
                              password: $password, generatedPassword: generatedPassword, taken: taken,
                              trailingFields: true)
            }
            .padding(24)
            .onAppear { taken = model.accountNames }
        } gutter: {
            HStack {
                Spacer()
                GutterButton("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                GutterButton("Create Account") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!AccountFields.isValid(username: username, password: password, taken: taken) || working)
            }
        }
    }

    private func create() {
        working = true
        let (username, displayName) = (username, displayName)
        let password = AccountFields.effectivePassword(password, generated: generatedPassword)
        Task {
            let created = await model.run("Couldn't Create the Account") { [supervisor = model.supervisor] in
                try supervisor.createAccount(username: username, displayName: displayName, password: password)
            }
            working = false
            if created != nil {
                dismiss()
                onCreated(PasswordReveal(username: username, password: password, isNew: true))
            }
        }
    }
}

/// Name, account name and password fields, shared by the New Account sheet and the setup
/// assistant. The account name follows the name until edited by hand. The password field
/// shows a generated password as its placeholder: left empty, that password is used;
/// anything typed replaces it.
struct AccountFields: View {
    @Binding var displayName: String
    @Binding var username: String
    @Binding var usernameEdited: Bool
    @Binding var password: String
    let generatedPassword: String
    /// Account names already in use.
    let taken: Set<String>
    /// Right-aligns the text inside the fields (the setup assistant's layout).
    var trailingFields = false

    /// `password` is what was typed; empty means the generated one is accepted. `taken`
    /// holds the account names already in use.
    static func isValid(username: String, password: String, taken: Set<String>) -> Bool {
        Store.isValidUsername(username) && !taken.contains(username) && (password.isEmpty || password.count >= 8)
    }

    static func effectivePassword(_ typed: String, generated: String) -> String {
        typed.isEmpty ? generated : typed
    }

    static func suggestedUsername(from name: String) -> String {
        let first = name.split(separator: " ").first.map(String.init) ?? name
        // The account name field's own filter: its characters, lowercased, at most 32.
        return InputFilter.accountName.apply(first.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current))
    }

    /// What's wrong with the fields as typed, checked on every keystroke.
    private var problem: String? {
        if username.hasPrefix(".") {
            return "An account name can't start with a period."
        }
        if taken.contains(username) {
            return "There's already an account named “\(username)”. Choose another account name."
        }
        if !password.isEmpty && password.count < 8 {
            return "Use at least 8 characters, or clear the field to use the suggested password."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupedTable {
                TableRow("Full name") {
                    TextField("Full name", text: $displayName, prompt: Text("Jane Appleseed"))
                        .labelsHidden()
                        .multilineTextAlignment(trailingFields ? .trailing : .leading)
                        .frame(width: 280)
                        .onChange(of: displayName) { _, new in
                            if !usernameEdited { username = Self.suggestedUsername(from: new) }
                        }
                }
                TableRow("Account name") {
                    FilteredTextField(text: Binding(get: { username }, set: { username = $0; usernameEdited = true }),
                                      filter: .accountName, placeholder: "jane",
                                      alignment: trailingFields ? .right : .natural)
                        .frame(width: 280)
                }
                TableRow("Password") {
                    TextField("Password", text: $password, prompt: Text(verbatim: generatedPassword))
                        .labelsHidden()
                        .multilineTextAlignment(trailingFields ? .trailing : .leading)
                        .font(.body.monospaced())
                        .frame(width: 280)
                }
            }
            // Room for the longest message is always reserved, so the sheet's height and
            // everything in it stay put when one appears.
            Text(problem ?? " ")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .opacity(problem == nil ? 0 : 1)
                .accessibilityHidden(problem == nil)
        }
    }
}

struct PasswordRevealSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reveal: PasswordReveal

    var body: some View {
        SheetChrome(reveal.isNew ? "Account Created" : "Password Changed", height: nil) {
            VStack(alignment: .leading, spacing: 14) {
                Text(reveal.isNew
                     ? "Each device asks for this password once, when CalShare is being set up on it. Keep it somewhere safe, such as a password manager."
                     : "Devices already configured will ask for the new password the next time they sync.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                GroupedTable {
                    CopyableValue(label: "Account name", value: reveal.username)
                    CopyableValue(label: "Password", value: reveal.password)
                }
            }
            .padding(24)
        } gutter: {
            HStack {
                Spacer()
                GutterButton("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

extension Color {
    /// Parses Apple's calendar colors: "#RRGGBB" or "#RRGGBBAA".
    init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
