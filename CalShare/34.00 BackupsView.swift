// MARK: - BackupsView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import CalShareCore
import SwiftUI

struct BackupsView: View {
    @Environment(AppModel.self) private var model
    @State private var exporting = false
    @State private var verifying = false

    var body: some View {
        page
            .sheet(isPresented: $verifying) {
                VerifyDataSheet()
                    .environment(model)
            }
    }

    private var page: some View {
        HeaderedPage("CalShare backs up automatically every hour when there are changes, and verifies each backup after writing it. Verify Data reads everything the way a device does and checks it against what's stored. Exporting writes every calendar as an .ics file and every address book as a .vcf file.") {
            HStack {
                Button(SharedText.backUpNow) { model.perform(.backupNow) }
                    .buttonStyle(.borderedProminent)
                if let directory = model.snapshot.dataDirectory {
                    Button("Reveal in Finder") {
                        // Opens the folder itself, inside CalShare's container.
                        NSWorkspace.shared.open(directory.appendingPathComponent("Backups", isDirectory: true))
                    }
                }
                Spacer()
                Button("Verify Data…") { verifying = true }
                    .help("Read every calendar and address book the way a device does, and check it against what's stored")
                Button("Export Calendars & Contacts…") { export() }
                    .disabled(exporting)
            }
        } content: {
            Card {
                if model.snapshot.backups.isEmpty {
                    Text("No backups yet. The first one is taken as soon as there's data to protect.")
                        .foregroundStyle(.secondary)
                } else {
                    // Fixed column widths, with Type taking whatever is left: no row's
                    // content can widen a column and shift the rest of the table.
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Text("Date").bold().frame(width: Column.date, alignment: .leading)
                            Text("Type").bold().frame(maxWidth: .infinity, alignment: .leading)
                            Text("Size").bold().frame(width: Column.size, alignment: .leading)
                            Text("Options").bold().frame(width: Column.options, alignment: .trailing)
                        }
                        .foregroundStyle(.secondary)
                        // Outside any GridRow, so it spans every column.
                        Divider()
                        ForEach(model.snapshot.backups) { backup in
                            GridRow {
                                Text(backup.date, format: .dateTime.month().day().year().hour().minute())
                                    .frame(width: Column.date, alignment: .leading)
                                Text(kindTitle(backup.kind)).foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(backup.size.byteString).monospacedDigit()
                                    .frame(width: Column.size, alignment: .leading)
                                HStack(spacing: 6) {
                                    Button("Restore…") { confirmRestore(backup) }
                                        .controlSize(.small)
                                    Button {
                                        confirmDelete(backup)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .controlSize(.small)
                                    .help("Delete this backup")
                                }
                                .frame(width: Column.options, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    private enum Column {
        static let date: CGFloat = 170
        static let size: CGFloat = 70
        static let options: CGFloat = 120
    }

    private func confirmRestore(_ backup: BackupRecord) {
        model.present(.confirm(
            "Restore This Backup?",
            "The server goes back to how it was at that moment. Your current data is backed up first, so this can be undone. Devices sync to match.",
            action: "Restore") { [model] in
                Task { _ = await model.run("Couldn't Restore the Backup") { [supervisor = model.supervisor] in try supervisor.restore(backup) } }
            })
    }

    private func confirmDelete(_ backup: BackupRecord) {
        let when = backup.date.formatted(date: .abbreviated, time: .shortened)
        model.present(.confirm(
            "Delete the Backup from \(when)?",
            "This backup is removed from the Backups folder. Other backups are not affected.",
            action: "Delete", role: .destructive) { [model] in
                model.supervisor.deleteBackup(backup)
            })
    }

    private func kindTitle(_ kind: String) -> String {
        switch kind {
        case "auto": "Automatic"
        case "manual": "Manual"
        case "pre-restore": "Before restore"
        case "pre-delete": "Before account deletion"
        default: kind.capitalized
        }
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the exported calendars and contacts."
        // A sheet on the window, not an app-modal panel.
        if let window = AppModel.dashboardWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let folder = panel.url { export(to: folder) }
            }
        } else if panel.runModal() == .OK, let folder = panel.url {
            export(to: folder)
        }
    }

    private func export(to folder: URL) {
        exporting = true
        let stamp = Date().formatted(.iso8601.year().month().day())
        let destination = folder.appendingPathComponent("CalShare Export \(stamp)", isDirectory: true)
        Task {
            let count = await model.run("Export Failed") { [supervisor = model.supervisor] in
                let access = folder.startAccessingSecurityScopedResource()
                defer { if access { folder.stopAccessingSecurityScopedResource() } }
                return try supervisor.export(to: destination)
            }
            exporting = false
            if count != nil { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
        }
    }
}
