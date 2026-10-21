// MARK: - MenuBarContent.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

// MenuControlKit uses DebugLogKit's `Loggable`, which lives in CalShareCore here rather
// than in the app target as in the other applets. Re-exporting the module makes it
// visible to the kit without editing the shared file.
@_exported import CalShareCore

/// The menu bar item, built with MenuControlKit as LAN Stream's and Toggler's are, so the
/// informational lines draw in the secondary label color above the clickable items.
@MainActor
final class MenuBarItem {
    private let model: AppModel
    private var controller: MenuController?
    private var defaultsObserver: (any NSObjectProtocol)?

    init(model: AppModel) {
        self.model = model
    }

    /// Shows or hides the item as Settings ask, now and whenever they change.
    func install() {
        update()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func prepareForTermination() {
        controller?.prepareForTerminationSynchronously()
        controller = nil
    }

    /// Closing or launching to the menu bar needs the menu bar item, so it's shown
    /// whatever the checkbox says, which is left as it was for when both are off.
    private var isWanted: Bool {
        UserDefaults.standard.bool(forKey: Preferences.Key.showMenuBarItem)
            || Preferences.closeToMenuBar || Preferences.launchTo == .menuBar
    }

    private func update() {
        // `controller` is set before install and cleared before teardown: AppKit can write
        // the status item's own defaults during either, and the notification can run
        // `update()` again before this call returns, which would otherwise add a second item.
        if isWanted, controller == nil {
            let controller = makeController()
            self.controller = controller
            controller.install()
        } else if !isWanted, let controller {
            // The kit has no uninstall; its teardown removes the status item, and a fresh
            // controller is made if the item is wanted again.
            self.controller = nil
            controller.prepareForTerminationSynchronously()
        }
    }

    private func makeController() -> MenuController {
        MenuController(.init(
            appName: "CalShare",
            icon: { [weak self] in
                guard let self else { return .symbol(.menuBar("calendar.and.person")) }
                let state = model.hasLoaded ? model.snapshot.overallState : .working
                let name = state >= HealthState.warning && model.statusRevealed
                    ? "calendar.badge.exclamationmark" : "calendar.and.person"
                return .symbol(.menuBar(name), fallbackTitle: "CalShare")
            },
            elements: { [weak self] in
                guard let self else { return [] }
                return elements()
            },
            observing: { [weak self] in
                guard let self else { return }
                _ = model.hasLoaded
                _ = model.snapshot
                _ = model.statusRevealed
            },
            prewarmSymbols: [.menuBar("calendar.and.person"), .menuBar("calendar.badge.exclamationmark")]))
    }

    private func elements() -> [MenuElement] {
        let snapshot = model.snapshot
        var elements: [MenuElement] = []
        if model.statusRevealed {
            elements.append(.info(OverallStatus.title(for: model.hasLoaded ? snapshot.overallState : .working)))
            if let port = snapshot.httpsPort {
                elements.append(.info("\(snapshot.deviceHostname):\(port)"))
            }
            for item in snapshot.health where item.state >= HealthState.warning {
                elements.append(.info("\(item.title): \(item.summary)"))
            }
        } else {
            elements.append(.info(OverallStatus.configuring))
        }
        elements += [
            .separator,
            // The same shortcuts as their counterparts in the app's menu bar.
            .action(id: "dashboard", title: "Open Dashboard", key: "d") { [model] in model.openDashboard() },
            .action(id: "setUpDevice", title: SharedText.setUpDevice, key: "d",
                    modifiers: [.command, .shift]) { [model] in model.show(.devices) },
            .action(id: "backUpNow", title: SharedText.backUpNow, key: "b",
                    modifiers: [.command, .shift]) { [model] in model.perform(.backupNow) },
            .separator,
            .action(id: "settings", title: "Settings…", key: ",") { [model] in model.show(.settings) },
            .separator,
            .quit(title: "Quit CalShare (Stops Syncing)"),
        ]
        return elements
    }
}
