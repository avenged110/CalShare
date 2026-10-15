// MARK: - RemoteHostnamesSheet.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// The sheet behind Settings' "Manage Hostnames…": the names that reach this Mac from away
// from home, as an editable list with macOS's add and remove buttons beneath it, the way
// System Settings lists DNS servers. Changes apply as they're made; Done only closes.

import CalShareCore
import SwiftUI

struct RemoteHostnamesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    /// The new hostname being typed, while the add row is open.
    @State private var draft: String?

    var body: some View {
        let configuration = model.snapshot.configuration
        SheetChrome("Manage Remote Hostnames", height: nil) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add a name that reaches this Mac over the Internet or a VPN, close this sheet, then select this name under “Server identity”.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HostnameList(hostnames: configuration.customHostnames,
                            serverIdentity: configuration.preferredHostname,
                            selection: $selection, draft: $draft, commit: commitDraft)
            }
            .padding(20)
        } gutter: {
            HStack {
                Spacer()
                GutterButton("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Adds the typed hostname. A name that isn't a valid host name, or is already listed,
    /// keeps the row open with a beep, as macOS's own lists do.
    private func commitDraft() {
        guard let name = draft?.trimmingCharacters(in: .whitespaces).lowercased() else { return }
        if name.isEmpty { draft = nil; return }
        guard ServerConfiguration.isValidHostname(name),
              !model.snapshot.configuration.customHostnames.contains(name) else {
            NSSound.beep()
            return
        }
        let add: @MainActor () -> Void = { [model] in
            model.updateConfiguration { config in
                if !config.customHostnames.contains(name) { config.customHostnames.append(name) }
            }
        }
        draft = nil
        selection = name
        // CalShare's authority may only vouch for the names it was made with, so a new one
        // means a new authority, which every device must trust again.
        if NameConstraints.permits(name: name, within: model.snapshot.authorityPermittedNames) {
            add()
        } else {
            model.present(.confirm(
                "Replace the Certificate Authority?",
                "CalShare's certificate authority only covers the names it was created with, so adding “\(name)” replaces it. Every device already set up must be set up again: other Macs run the new Terminal command, then each device installs a fresh profile.",
                action: "Add Anyway", perform: add))
        }
    }
}

// MARK: - Hostname List

/// The bordered list and its add and remove bar.
private struct HostnameList: View {
    @Environment(AppModel.self) private var model
    let hostnames: [String]
    let serverIdentity: String?
    @Binding var selection: String?
    @Binding var draft: String?
    let commit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hostnames, id: \.self) { name in
                        HostnameRow(name: name, isServerIdentity: name == serverIdentity,
                                   isSelected: name == selection)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = name; draft = nil }
                    }
                    if draft != nil {
                        FilteredTextField(text: Binding(get: { draft ?? "" }, set: { draft = $0 }),
                                          filter: .hostname, placeholder: "mac.tailnet-name.ts.net",
                                          onSubmit: commit, onCancel: { draft = nil }, focusesOnAppear: true)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The sheet takes its height from its content, as the New Account sheet does.
            .frame(height: 220)
            .overlay {
                if hostnames.isEmpty && draft == nil {
                    Text("No Remote Hostnames")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button { selection = nil; draft = "" } label: { Image(systemName: "plus").frame(width: 14) }
                    .help("Add a hostname")
                Button { remove() } label: { Image(systemName: "minus").frame(width: 14) }
                    .help("Remove the selected hostname")
                    .disabled(selection.map { !hostnames.contains($0) } ?? true)
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            // Set apart from both the list above and the sheet around it.
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    /// Removes the selection at once, unless devices are set to use it: then, as changing
    /// "Server identity" does, it asks first, since the identity goes back to automatic.
    private func remove() {
        guard let name = selection else { return }
        let removal: @MainActor () -> Void = { [model] in
            model.updateConfiguration { config in
                config.customHostnames.removeAll { $0 == name }
                if config.preferredHostname == name { config.preferredHostname = nil }
            }
        }
        if name == serverIdentity {
            model.present(.confirm(
                "Remove the Server Identity?",
                "Devices connect to CalShare using “\(name)”. Removing it sets “Server identity” back to automatic, and devices already configured to connect to CalShare will require a new profile.",
                action: "Remove Anyway", perform: removal))
        } else {
            removal()
        }
        selection = nil
    }
}

/// One hostname, highlighted as a selected list row is, and marked when devices use it.
private struct HostnameRow: View {
    let name: String
    let isServerIdentity: Bool
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            if isServerIdentity {
                Text("Server identity")
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
    }
}
