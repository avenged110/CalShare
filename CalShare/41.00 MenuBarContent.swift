// MARK: - MenuBarContent.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import CalShareCore
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.hasLoaded ? model.snapshot.overallState : .working
        Image(systemName: state >= HealthState.warning && model.statusRevealed ? "calendar.badge.exclamationmark" : "calendar.and.person")
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let snapshot = model.snapshot
        if model.statusRevealed {
            Text(OverallStatus.title(for: model.hasLoaded ? snapshot.overallState : .working))
            if let port = snapshot.httpsPort {
                Text(verbatim: "\(snapshot.deviceHostname):\(port)")
            }
        } else {
            Text(OverallStatus.configuring)
        }
        ForEach(snapshot.health.filter { $0.state >= HealthState.warning && model.statusRevealed }) { item in
            Text("\(item.title): \(item.summary)")
        }
        Divider()
        // The same shortcuts as their counterparts in the app's menu bar.
        Button("Open Dashboard") { open(nil) }
            .keyboardShortcut("d", modifiers: .command)
        Button(SharedText.setUpDevice) { open(.devices) }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        Button(SharedText.backUpNow) { model.perform(.backupNow) }
            .keyboardShortcut("b", modifiers: [.command, .shift])
        Divider()
        Button("Settings…") { open(.settings) }
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit CalShare (Stops Syncing)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ item: SidebarItem?) {
        model.openWindowAction = { openWindow(id: $0) }
        if let item { model.show(item) } else { model.openDashboard() }
    }
}
