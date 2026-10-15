// MARK: - CalShareApp.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CalShareCore
import SwiftUI

@main
struct CalShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(Preferences.Key.showMenuBarItem) private var showMenuBarItem = true
    @AppStorage(Preferences.Key.closeToMenuBar) private var closeToMenuBar = false
    @AppStorage(Preferences.Key.launchTo) private var launchTo = Preferences.LaunchTo.dashboard.rawValue

    var body: some Scene {
        // `Window` rather than `WindowGroup`: CalShare has exactly one dashboard window.
        Window("CalShare", id: WindowID.dashboard) {
            ZStack {
                DashboardView()
                AlertHostView(scope: .window)
            }
            .environment(appDelegate.model)
            // No frame here: the detail column carries the size (see DashboardView), and
            // MainWindowConfigurator pins the window to it.
            // Pins the window to its fixed size and turns off zoom, full screen and tabbing.
            // A background, so the zero-size probe never takes a click.
            .background(MainWindowConfigurator())
        }
        // Alongside MainWindowConfigurator's style-mask change: this stops SwiftUI from
        // proposing a resizable window, while the configurator makes the zoom button inert.
        .windowResizability(.contentSize)
        .defaultSize(width: Layout.windowWidth, height: Layout.windowHeight)
        .commands {
            // About CalShare, with ⌘? now that there's no Help menu to own it.
            AppInfoCommands(appName: "CalShare")
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                NavigationCommand(title: "Settings…", item: .settings, model: appDelegate.model)
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Server") {
                Button(SharedText.backUpNow) { appDelegate.model.perform(.backupNow) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button(SharedText.restartServer) { appDelegate.model.perform(.restartServer) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                NavigationCommand(title: SharedText.setUpDevice, item: .devices, model: appDelegate.model)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button(SharedText.setupAssistant) {
                    appDelegate.model.openDashboard()
                    appDelegate.model.showSetupAssistant = true
                }
            }
            // The View menu: a page per number, then the sidebar, above the items AppKit
            // adds itself. Replacing the sidebar slot also drops SwiftUI's own sidebar
            // item, whose ⌃⌘S this ⌥⌘S takes over from.
            CommandGroup(replacing: .sidebar) {
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                    NavigationCommand(title: item.title, item: item, model: appDelegate.model)
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Divider()
                SidebarCommand(model: appDelegate.model)
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
            // CalShare has no help book. HelpMenuRemover (installed at launch) takes out
            // the title this leaves, which every menu-bar rebuild would otherwise put back.
            EmptyCommandGroup(.help)
        }

        // Closing or launching to the menu bar needs the menu bar item, so it's shown
        // whatever the checkbox says, which is left as it was for when both are off.
        MenuBarExtra(isInserted: Binding(get: { showMenuBarItem || closeToMenuBar
                                                || launchTo == Preferences.LaunchTo.menuBar.rawValue },
                                         set: { showMenuBarItem = $0 })) {
            MenuBarContent()
                .environment(appDelegate.model)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.model)
        }
    }
}

enum WindowID {
    static let dashboard = "dashboard"
}

/// Fixed dimensions. The window never resizes, so every layout knows exactly how much
/// room it has.
enum Layout {
    static let sidebarWidth: CGFloat = 220
    /// The split view's divider between the sidebar and the page.
    static let dividerWidth: CGFloat = 1
    static let pageWidth: CGFloat = 680
    /// The sidebar, its divider and the page, so the window is already the width the
    /// shown sidebar needs, even when it opens with the sidebar hidden.
    static let windowWidth = sidebarWidth + dividerWidth + pageWidth
    static let windowHeight: CGFloat = 700
    static let sheetSize: CGFloat = 600
}

/// Shows or hides the sidebar. A view of its own, so its title follows the sidebar.
struct SidebarCommand: View {
    let model: AppModel

    var body: some View {
        Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
            withAnimation { model.sidebarVisible.toggle() }
        }
    }
}

/// A menu command that brings up the dashboard on one of its pages. It carries its own
/// `openWindow`, so it works whether or not the window has ever been shown.
struct NavigationCommand: View {
    let title: String
    let item: SidebarItem
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            model.openWindowAction = { openWindow(id: $0) }
            model.show(item)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, Loggable {
    static let logTag = "[App]"

    let model: AppModel

    override init() {
        Preferences.registerDefaults()
        // The observer turns unexpected errors into a dashboard warning, whether or not
        // the debug log is on.
        Logger.bootstrap(.init(fileName: "CalShare.log",
                               destination: .applicationSupport,
                               isEnabled: { Preferences.loggingEnabled },
                               observer: Supervisor.logObserver))
        Logger.prepareLogDirectory()
        // A fixed-size single-window app has no use for window tabbing, and leaving it on
        // adds "Show Tab Bar" and "Merge All Windows" to the menus.
        MenuBarPolicy.disableAutomaticWindowTabbing()
        // Before the window exists, so the toolbar's sidebar button is caught as it's added.
        SidebarToggleFocus.install()
        model = AppModel()
        super.init()
    }

    /// A launch to the menu bar starts as an accessory app, so the Dock icon never shows.
    func applicationWillFinishLaunching(_ notification: Notification) {
        if Preferences.launchTo == .menuBar { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("Launched")
        HelpMenuRemover.install()
        model.start()
        DockPresence.install()
        // Make every launch what Settings asks for. AppKit opens no window for a launch at
        // login, though macOS may still restore the window if it was open at log out.
        switch Preferences.launchTo {
        case .dashboard:
            // The normal launch's own path to its window: SwiftUI's application delegate.
            if DockPresence.dashboard?.isVisible != true { _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp) }
            DockPresence.update()
        case .menuBar:
            DockPresence.dashboard?.close()
            DockPresence.hideFromDock()
        }
        log("Launched to the \(Preferences.launchTo == .dashboard ? "dashboard" : "menu bar")")
    }

    /// The server keeps running with the window closed; the menu bar item reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.openDashboard() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        Logger.shutdownLoggingBlocking()
    }
}

// MARK: - DockPresence

/// Closing to the menu bar: with the setting on, CalShare leaves the Dock and the app menus
/// (becoming an accessory app) while the dashboard is closed, and comes back as a regular
/// app whenever the dashboard is shown, from wherever it's opened.
@MainActor
enum DockPresence {
    private static var observers: [any NSObjectProtocol] = []

    static var dashboard: NSWindow? { NSApp.windows.first(where: isDashboard) }

    private static func isDashboard(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.contains(WindowID.dashboard) == true
    }

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: nil) { note in
            // Posted on the main thread, by the window closing.
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, isDashboard(window) else { return }
                if Preferences.closeToMenuBar { setPolicy(.accessory) }
            }
        })
        // A backstop for any way of showing the window that doesn't go through
        // `showInDock()` first.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let window, isDashboard(window), window.isVisible else { return }
                    setPolicy(.regular)
                }
            })
        }
    }

    /// A launch to the menu bar only: an accessory app until the dashboard is shown.
    static func hideFromDock() {
        setPolicy(.accessory)
    }

    /// Before the dashboard is shown, so it opens with the Dock icon and menus in place.
    static func showInDock() {
        setPolicy(.regular)
    }

    /// Matches the policy to the setting and the dashboard: at launch, and when the
    /// setting changes.
    static func update() {
        setPolicy(Preferences.closeToMenuBar && dashboard?.isVisible != true ? .accessory : .regular)
    }

    private static func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}

// MARK: - SidebarToggleFocus

/// Keeps the toolbar's sidebar button out of keyboard focus. With keyboard navigation
/// turned on, hiding the sidebar takes focus from its list, AppKit hands it to the next
/// control, this button, and the button then shows a focus ring after every toggle.
///
/// SwiftUI builds the button itself, so it is reached through its toolbar item as the item
/// is added, by SwiftUI's identifier for it. Should that identifier ever change, the
/// button simply keeps its focus ring again.
final class SidebarToggleFocus: NSObject {
    private static let identifier = NSToolbarItem.Identifier("com.apple.SwiftUI.navigationSplitView.toggleSidebar")
    private static var shared: SidebarToggleFocus?

    static func install() {
        guard shared == nil else { return }
        let observer = SidebarToggleFocus()
        shared = observer
        NotificationCenter.default.addObserver(observer, selector: #selector(toolbarWillAddItem(_:)),
                                               name: NSToolbar.willAddItemNotification, object: nil)
    }

    @objc private func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem,
              item.itemIdentifier == Self.identifier else { return }
        // The item's button is in place by the next turn of the run loop.
        Task { item.view.map(Self.refuseFocus) }
    }

    private static func refuseFocus(_ view: NSView) {
        (view as? NSControl)?.refusesFirstResponder = true
        view.subviews.forEach(refuseFocus)
    }
}

// MARK: - MainWindowConfigurator

/// Applies the fixed-size window policy to the dashboard window as soon as it exists,
/// following nvNotes' configurator.
///
/// SwiftUI's `.windowResizability(.contentSize)` fixes the size but leaves the zoom button
/// live, so this reaches the NSWindow directly and clears the `.resizable` mask — with the
/// mask cleared, AppKit disables the zoom button itself. Full screen is opted out of
/// through the collection behavior, which also removes "Enter Full Screen" from the menus.
///
/// SwiftUI sets the `.resizable` mask again whenever the content's size range changes,
/// which showing or hiding the sidebar does, so the mask is watched and cleared each time
/// it comes back. The window's size and the sidebar are SwiftUI's; the only other thing
/// this does is put the window back where it was saved (see `configure`).
struct MainWindowConfigurator: NSViewRepresentable {
    /// Holds the observations for as long as the window is on screen.
    final class Coordinator {
        var styleMaskObservation: NSKeyValueObservation?
        var toolbarObservation: (any NSObjectProtocol)?
        /// Where AppKit restored the window, kept until the toolbar is in place.
        var restoredTopLeft: NSPoint?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowProbeView {
        let probe = WindowProbeView(frame: .zero)
        let coordinator = context.coordinator
        // Runs from `viewDidMoveToWindow`, before the first display, so the window never
        // draws once at a different size.
        probe.onAttach = { configure($0, coordinator) }
        return probe
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        // Re-applied on update: AppKit's frame restoration can resize the window after
        // the initial configuration. Every operation here is idempotent.
        configure(nsView.hostWindow, context.coordinator)
    }

    @MainActor
    private func configure(_ window: NSWindow?, _ coordinator: Coordinator) {
        guard let window else { return }
        // Before anything below: clearing `.resizable` already has SwiftUI re-place it.
        if coordinator.styleMaskObservation == nil, window.toolbar == nil {
            coordinator.restoredTopLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        }
        if coordinator.styleMaskObservation == nil {
            coordinator.styleMaskObservation = window.observe(\.styleMask) { window, _ in
                MainActor.assumeIsolated {
                    if window.styleMask.contains(.resizable) { window.styleMask.remove(.resizable) }
                }
            }
        }
        window.styleMask.remove(.resizable)
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)
        window.tabbingMode = .disallowed

        // The window arrives here already at its saved frame, but without its toolbar.
        // SwiftUI then re-places it at the content's height alone, keeping the bottom
        // edge, and grows it for the toolbar keeping the top edge, which drops the window
        // by the toolbar's height on every launch. So the restored corner is kept, and put
        // back once the toolbar is in, before the window is first shown.
        guard window.toolbar != nil else {
            if coordinator.toolbarObservation == nil {
                // SwiftUI grows the window for the toolbar it has just added, so the first
                // resize that finds a toolbar is the moment to put the window back, before
                // it's first drawn.
                coordinator.toolbarObservation = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: nil) { [weak window] _ in
                    MainActor.assumeIsolated {
                        if let window, window.toolbar != nil { configure(window, coordinator) }
                    }
                }
            }
            return
        }
        if let observer = coordinator.toolbarObservation {
            NotificationCenter.default.removeObserver(observer)
            coordinator.toolbarObservation = nil
        }

        // The size is SwiftUI's, from the content: a size worked out here from `Layout`
        // and the measured chrome disagreed with it, and SwiftUI resized the window straight
        // back. Only the corner is put back, anchored at the top-left as AppKit and SwiftUI
        // resize windows.
        let topLeft = coordinator.restoredTopLeft ?? NSPoint(x: window.frame.minX, y: window.frame.maxY)
        coordinator.restoredTopLeft = nil
        if topLeft != NSPoint(x: window.frame.minX, y: window.frame.maxY) { window.setFrameTopLeftPoint(topLeft) }
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
    }
}

/// Zero-size view whose only job is to report the moment it is attached to a window.
final class WindowProbeView: NSView {
    var onAttach: ((NSWindow) -> Void)?

    /// The window this view is in. AppKit's own `window` is `unowned(unsafe)`; this is the
    /// same window, held weakly, as AppKit hands it over strongly just before the move.
    private(set) weak var hostWindow: NSWindow?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        hostWindow = newWindow
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let hostWindow { onAttach?(hostWindow) }
    }
}
