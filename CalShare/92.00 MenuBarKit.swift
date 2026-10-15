// MARK: - MenuBarKit.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// STANDARDIZED MAIN-MENU-BAR BUILDING BLOCKS — pick the pieces you want, leave the rest.
//
// The shared chrome of the SwiftUI `Commands` menu bars in PhotoGallery, Spectrum, Film
// Tracker, nvNotes and Compare Folders: the application menu's About / Settings… / Hide /
// Quit items, the emptied system slots, the AppKit-validated Edit menu, the restored
// "Bring All to Front", the launch-time flags that strip Dictation and Emoji & Symbols, and
// the refresh-on-open hook several menus use to stay current. Menu CONTENT — Film, Folder,
// Channel, Stream, the File and View items — is app logic and stays in each app.
//
// Not to be confused with `MenuControlKit.swift`, which builds a menu-bar APPLET's status
// item and its drop-down. This file is for the menu bar of a windowed app.
//
// EVERY PIECE STANDS ALONE
// ────────────────────────
// Each `Commands` struct below owns exactly the slots its documentation names and nothing
// else, so any subset can be dropped into an app's own `Commands` body next to its
// hand-written groups. Nothing here depends on anything else here except
// `StandardEditMenu` → `MenuTextFocus` (and `StandardEditCommands` is always paired with
// `StandardEditMenu`), and nothing depends on the other shared files.
//
//   var body: some Commands {
//       AppInfoCommands(appName: "Spectrum")
//       AppSettingsCommands { NotificationCenter.default.post(name: .openSpectrumSettings,
//                                                             object: nil) }
//       // no Save/Print/Services empties after .commandsRemoved() — see EmptyCommandGroup
//       StandardEditCommands()      // + StandardEditMenu.install(undoRedo: .suppressed)
//       BringAllToFrontCommands()
//       // …the app's own File / View / custom menus…
//   }
//
// ONE RULE: A SLOT HAS ONE OWNER
// ──────────────────────────────
// Two `CommandGroup(replacing:)` for the same placement — one here, one in the app — do
// not merge; which one wins is unspecified and has changed between macOS releases. If an
// app needs its own version of a slot, it skips the piece that owns it. The slots each
// piece owns are listed in its doc comment and in the README.
//
// Every piece is also a single `Commands` value, which counts as one argument against
// `CommandsBuilder`'s ten-per-block limit, so adopting them shrinks the `Group {}` splitting
// the hand-written bodies needed.

import AppKit
import Combine
import SwiftUI

// MARK: - Application Menu

/// "About <App>" with the ⌘? key equivalent the stock item lacks.
///
/// Owns: `.appInfo`.
///
/// The default action is sent through the responder chain with `target: nil`, as the stock
/// item is, so an app delegate that implements `orderFrontStandardAboutPanel(_:)` (or a
/// custom selector passed via `action`) can still intercept it.
struct AppInfoCommands: Commands {
    let appName: String
    let action: @MainActor () -> Void

    init(appName: String,
         action: @escaping @MainActor () -> Void = {
             NSApp.sendAction(#selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                              to: nil, from: nil)
         }) {
        self.appName = appName
        self.action = action
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(appName)") { action() }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}

/// "Settings…" ⌘, at the system's own anchor.
///
/// Owns: `.appSettings`.
///
/// Every app here opens a hand-built settings window rather than a SwiftUI `Settings`
/// scene (see SettingsKit.swift), and dropping that scene also drops the item it used to
/// inject. This restores it. How the window is reached — a responder-chain selector, a
/// notification, an event bus — is the app's business and goes in `action`.
struct AppSettingsCommands: Commands {
    let action: @MainActor () -> Void
    let isDisabled: @MainActor () -> Bool

    init(isDisabled: @escaping @MainActor () -> Bool = { false },
         action: @escaping @MainActor () -> Void) {
        self.action = action
        self.isDisabled = isDisabled
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings\u{2026}") { action() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(isDisabled())
        }
    }
}

/// "Hide <App>" ⌘H, "Hide Others" ⌥⌘H, "Show All".
///
/// Owns: `.appVisibility`.
///
/// Only needed where the stock group is gone — after `.commandsRemoved()` — or where the
/// app wants the group's exact wording pinned. An app that keeps the system's application
/// menu already has these items.
struct AppVisibilityCommands: Commands {
    let appName: String

    var body: some Commands {
        CommandGroup(replacing: .appVisibility) {
            Button("Hide \(appName)") { NSApp.hide(nil) }
                .keyboardShortcut("h", modifiers: .command)
            Button("Hide Others") { NSApp.hideOtherApplications(nil) }
                .keyboardShortcut("h", modifiers: [.command, .option])
            Button("Show All") { NSApp.unhideAllApplications(nil) }
        }
    }
}

/// "Quit <App>" ⌘Q.
///
/// Owns: `.appTermination`.
///
/// `action` defaults to `NSApp.terminate(nil)`. Film Tracker passes its own, which
/// dismisses a locked recovery sheet first because AppKit silently refuses to terminate
/// while a sheet is attached.
struct AppTerminationCommands: Commands {
    let appName: String
    let action: @MainActor () -> Void

    init(appName: String,
         action: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.appName = appName
        self.action = action
    }

    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("Quit \(appName)") { action() }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

/// Removes the Services submenu from the application menu.
///
/// Owns: `.systemServices`.
///
/// Not needed after `.commandsRemoved()`, which already removes Services; there it only
/// adds an empty section (a doubled separator). See `EmptyCommandGroup`.
struct ServicesSuppressionCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .systemServices) {}
    }
}

// MARK: - Empty Slots

/// Empties one system command slot.
///
/// Owns: whatever placement it is given.
///
/// The bare empty closure is deliberate: `{ EmptyView() }` fails to compile for some
/// placements, and the empty closure is the one spelling that works for all of them.
///
/// Only empty a slot that actually has items. After `.commandsRemoved()` most slots are
/// already empty, and emptying one again still gives it a section of its own — which shows
/// as a stray separator (Spectrum: two at the bottom of the File menu from `.saveItem` and
/// `.printItem`, and a doubled one in the application menu from
/// `ServicesSuppressionCommands`). Compare a dump of the menu tree with and without it.
///
/// Common uses, each its own line so an app takes only the ones it means:
///
///     EmptyCommandGroup(.saveItem)        // no document model: Save, Save As, Revert
///     EmptyCommandGroup(.printItem)       // Page Setup, Print
///     EmptyCommandGroup(.undoRedo)        // no undo model (or see StandardEditCommands)
///     EmptyCommandGroup(.toolbar)         // Show/Hide/Customize Toolbar
///     EmptyCommandGroup(.sidebar)         // Show/Hide Sidebar
///     EmptyCommandGroup(.singleWindowList) // single-window apps
///     EmptyCommandGroup(.help)            // see "Help menu" below
///
/// ### The duplicate View menu
/// A `CommandMenu("View")` produces a SECOND View menu beside the system one. To put items
/// in the View menu, empty `.sidebar` and `.toolbar` as needed and inject with
/// `CommandGroup(after: .toolbar)` (or `before: .sidebar` to land above AppKit's tab-bar
/// items). Leave `.windowSize` alone: AppKit re-adds Enter Full Screen and the tab items
/// there every time the menu opens, and emptying it makes the menu visibly snap between two
/// versions as SwiftUI strips them again.
///
/// ### Help menu
/// `EmptyCommandGroup(.help)` removes the Help menu in Spectrum and Compare Folders. It
/// does not in nvNotes or PhotoGallery, whose `Commands` bodies re-evaluate on selection
/// changes: the emptied menu's title stays in the MenuBar and every rebuild re-adds it.
/// Those apps keep `EmptyCommandGroup(.help)` and add `HelpMenuRemover.install()`.
/// (`.commandsRemoved()` on the scene drops the Help menu outright — see
/// `HelpMenuRemover`.)
struct EmptyCommandGroup: Commands {
    let placement: CommandGroupPlacement

    init(_ placement: CommandGroupPlacement) {
        self.placement = placement
    }

    var body: some Commands {
        CommandGroup(replacing: placement) {}
    }
}

// MARK: - Edit Menu

/// Empties SwiftUI's two Edit-menu slots, so SwiftUI builds no Edit menu at all and
/// `StandardEditMenu` can install AppKit's. Always used together with it.
///
/// Owns: `.undoRedo` and `.pasteboard`.
///
/// ### Why the Edit menu is not a SwiftUI `Commands` group
/// A command's `.disabled(_:)` is re-evaluated only when SwiftUI state the `Commands`
/// body observes changes (an `@Observable` property, for example). Keyboard focus is
/// AppKit state SwiftUI never observes, so gating Cut / Copy / Paste / Select All on text
/// focus from SwiftUI reads a stale answer: in practice the items stayed disabled while
/// an Open or Save panel's filename field had focus, and ⌘A/⌘C/⌘V did nothing there.
/// AppKit's own items — nil-targeted standard selectors — are validated against the
/// first responder on every menu open and every key equivalent, which is exactly the
/// "enabled when there is something to act on" rule.
struct StandardEditCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {}
        CommandGroup(replacing: .pasteboard) {}
    }
}

/// Installs and keeps an AppKit Edit menu in a SwiftUI app's menu bar: Undo / Redo (by
/// choice), Cut, Copy, Paste and Select All, all sent through the responder chain and
/// validated by AppKit against whatever holds first responder — a text field, a toolbar
/// search field, an Open or Save panel.
///
/// Pair it with `StandardEditCommands()` in the `Commands` body, then install once the menu
/// bar exists:
///
///     // applicationDidFinishLaunching
///     StandardEditMenu.install()                                  // text only, with undo
///     StandardEditMenu.install(undoRedo: .suppressed)              // Spectrum
///     StandardEditMenu.install(selectAll: .scoped(                 // Film Tracker
///         isAvailable: { canSelectAllFilms() }, perform: { selectAllFilms() }))
///
/// Two AppKit/SwiftUI behaviors it handles:
/// - SwiftUI rebuilds the menu bar whenever command state changes (a file load that
///   changes a submenu, for example) and drops every top-level item it did not create.
///   The installer watches the main menu's item notifications and puts the Edit menu back
///   in the same run-loop pass, before the menu bar redraws or a key equivalent is matched.
///   (Measured in Spectrum: present at every 100 ms sample through a file load.)
/// - AppKit appends AutoFill, Start Dictation… and Emoji & Symbols to anything titled
///   "Edit". The menu rebuilds its own items on every update, so those never appear.
///   (`MenuBarPolicy.suppressInputMenuItems()` remains the belt to this suspenders.)
@MainActor
final class StandardEditMenu: NSObject, NSMenuDelegate {

    /// Where Undo and Redo come from.
    enum UndoRedo {
        /// ⌘Z / ⇧⌘Z as `undo:` / `redo:` through the responder chain — enabled whenever the
        /// first responder's undo manager has something to undo, including in any text
        /// field. (PhotoGallery, Film Tracker.)
        case responderChain
        /// No Undo or Redo items. (Spectrum.)
        case suppressed
    }

    /// What Select All does when no text field has focus.
    enum SelectAll {
        /// Text only: the standard nil-targeted `selectAll:` item.
        case text
        /// Text first, then the app's own selection. While a text-entry control has focus
        /// (`MenuTextFocus.isActive()`) `selectAll:` goes to the responder chain; otherwise
        /// `perform` runs. Enabled when either applies — checked live, each time AppKit
        /// validates the item. (PhotoGallery's gallery grid, Film Tracker's film list.)
        case scoped(isAvailable: @MainActor () -> Bool, perform: @MainActor () -> Void)
    }

    private static var shared: StandardEditMenu?

    /// Insert the Edit menu after File and keep it there. Call once, after the menu bar
    /// exists (`applicationDidFinishLaunching`); a second call replaces the configuration.
    static func install(undoRedo: UndoRedo = .responderChain, selectAll: SelectAll = .text) {
        shared?.invalidate()
        let menu = StandardEditMenu(undoRedo: undoRedo, selectAll: selectAll)
        shared = menu
        menu.reinstallIfNeeded()
    }

    private let undoRedo: UndoRedo
    private let selectAll: SelectAll
    private let editMenu = NSMenu(title: "Edit")
    /// The main menu `editMenu` was last inserted into. Tracked here, and weakly, rather
    /// than read back from `editMenu.supermenu`, which AppKit declares `unowned(unsafe)`.
    private weak var hostMenu: NSMenu?

    private init(undoRedo: UndoRedo, selectAll: SelectAll) {
        self.undoRedo = undoRedo
        self.selectAll = selectAll
        super.init()
        editMenu.delegate = self
        populate(editMenu)
        // Any menu's notifications: SwiftUI may also swap in a new main menu object.
        // `menuDidChange` ignores everything but the current main menu.
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(menuDidChange(_:)), name: name, object: nil)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func invalidate() {
        NotificationCenter.default.removeObserver(self)
        if let hostMenu, let item = hostMenu.items.first(where: { $0.submenu === editMenu }) {
            hostMenu.removeItem(item)
        }
    }

    @objc private func menuDidChange(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, menu === NSApp.mainMenu else { return }
        reinstallIfNeeded()
    }

    /// Returns at once when the Edit menu is already in the main menu — including for the
    /// notification its own insertion posts.
    private func reinstallIfNeeded() {
        guard let mainMenu = NSApp.mainMenu else { return }
        if mainMenu.items.contains(where: { $0.submenu === editMenu }) {
            hostMenu = mainMenu   // follow the item should SwiftUI ever carry it over
            return
        }
        // A menu can have only one supermenu; detach it from a main menu SwiftUI replaced.
        if let old = hostMenu, let item = old.items.first(where: { $0.submenu === editMenu }) {
            old.removeItem(item)
        }
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = editMenu
        let fileIndex = mainMenu.items.firstIndex { $0.submenu?.title == "File" }
        mainMenu.insertItem(item, at: fileIndex.map { $0 + 1 } ?? min(1, mainMenu.items.count))
        hostMenu = mainMenu
    }

    // MARK: Items

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        if case .responderChain = undoRedo {
            menu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
            menu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        // No separator before Select All: the system Edit menu has none.
        switch selectAll {
        case .text:
            menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)),
                                    keyEquivalent: "a"))
        case .scoped:
            let item = NSMenuItem(title: "Select All", action: #selector(scopedSelectAll(_:)),
                                  keyEquivalent: "a")
            item.target = self
            menu.addItem(item)
        }
    }

    @objc private func scopedSelectAll(_ sender: Any?) {
        guard case let .scoped(_, perform) = selectAll else { return }
        if MenuTextFocus.isActive() {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender)
        } else {
            perform()
        }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(scopedSelectAll(_:)),
              case let .scoped(isAvailable, _) = selectAll else { return true }
        return MenuTextFocus.isActive() || isAvailable()
    }
}

// MARK: - Text Focus

/// Whether typing would currently land in a text-entry control.
///
/// For decisions made at the moment of an action, such as `StandardEditMenu`'s scoped
/// Select All — never for a SwiftUI command's `.disabled(_:)`, which is evaluated too
/// rarely for focus to be current (see `StandardEditCommands`).
///
/// The single definition of the check Spectrum, PhotoGallery and Film Tracker each carried
/// (Film Tracker's as `TextInputFocus`). It looks at the key window AND at any sheet
/// attached to the main window, which is where an open/save panel's filename field lives
/// while the key window may still report the parent.
enum MenuTextFocus {

    /// True when the key window's, or the main window's attached sheet's, first responder
    /// is a text-entry control.
    @MainActor
    static func isActive() -> Bool {
        if let key = NSApp.keyWindow, isActive(in: key) { return true }
        if let sheet = NSApp.mainWindow?.attachedSheet, sheet !== NSApp.keyWindow,
           isActive(in: sheet) {
            return true
        }
        return false
    }

    /// True when `window`'s first responder is a text-entry control.
    ///
    /// This asks about the window's RETAINED first responder, which a window keeps while
    /// it is not key; callers that care where typing would actually land should use
    /// `isActive()` instead.
    @MainActor
    static func isActive(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder is NSTextField || responder is NSTextView { return true }
        // SwiftUI's text inputs are private NSView subclasses; their class names are the
        // only thing that identifies them.
        return matchesTextClassName(String(describing: type(of: responder)))
    }

    /// True when `name` reads as the class name of a text-entry control. Exposed so the
    /// rule can be exercised without a live window.
    static func matchesTextClassName(_ name: String) -> Bool {
        if name.contains("TextField") || name.contains("TextEditor")
            || name.contains("SearchField") || name.contains("EditableText") {
            return true
        }
        return name.contains("Text")
            && (name.contains("Field") || name.contains("Editor") || name.contains("Input"))
    }
}

// MARK: - Window Menu

/// A divider and "Bring All to Front" at the end of the window-arrangement group.
///
/// Owns: nothing — it inserts `after: .windowArrangement`.
///
/// `.commandsRemoved()` drops SwiftUI's own copy of this item. It is appended rather than
/// restored by replacing `.windowArrangement`, because AppKit rebuilds Minimize, Zoom, the
/// tiling items and the window list every time the Window menu opens; replacing the slot
/// made SwiftUI strip them again a few frames later and the menu visibly snapped.
struct BringAllToFrontCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Bring All to Front") { NSApp.arrangeInFront(nil) }
        }
    }
}

// MARK: - Help Menu Removal

/// Keeps the Help menu out of the menu bar of an app with no help book. Opt-in.
///
/// Owns: nothing in the `Commands` body. Pair it with `EmptyCommandGroup(.help)` there, which
/// stops SwiftUI refilling the menu; this removes the title that remains:
///
///     // applicationDidFinishLaunching
///     HelpMenuRemover.install()
///
/// Needed only where the `Commands` body re-evaluates (nvNotes, PhotoGallery): SwiftUI
/// rebuilds the menu bar on each re-evaluation and puts the Help item back. The remover
/// takes it out at install time and again from the main menu's own add-item notification —
/// the signal `StandardEditMenu` uses, in the same run-loop pass, before the menu bar
/// redraws — with a menu-tracking backstop for any path that posts no notification.
///
/// An app whose window scene uses `.commandsRemoved()` has no Help menu at all and does
/// not need this (Film Tracker, Spectrum). That is the definitive fix, at the cost of
/// rebuilding the application menu's Hide / Quit items (`AppVisibilityCommands`,
/// `AppTerminationCommands`) and anything else the app relied on the stock groups for.
///
/// ### Identifying the menu
/// By identity first: the item whose submenu is `NSApp.helpMenu` — the menu AppKit has
/// designated as the Help menu (it gets the search field), independent of language. Then
/// by title, English "Help", on both the item and its submenu, because AppKit fills the
/// Help menu in late and `NSApp.helpMenu` may not be set yet when a rebuild lands. The
/// title fallback does not work in other localizations.
@MainActor
final class HelpMenuRemover: NSObject {

    private static var shared: HelpMenuRemover?

    /// Start removing the Help menu, now and after every menu-bar rebuild. Call once the
    /// menu bar exists (`applicationDidFinishLaunching`); repeat calls are ignored.
    static func install() {
        guard shared == nil else { return }
        let remover = HelpMenuRemover()
        shared = remover
        remover.removeIfPresent()
    }

    private var trackingBackstop: MenuTrackingObserver?

    private override init() {
        super.init()
        // Any menu's notifications: SwiftUI may also swap in a new main menu object.
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidAddItem(_:)),
            name: NSMenu.didAddItemNotification, object: nil)
        trackingBackstop = MenuTrackingObserver { [weak self] _ in self?.removeIfPresent() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func menuDidAddItem(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, menu === NSApp.mainMenu else { return }
        removeIfPresent()
    }

    private func removeIfPresent() {
        guard let mainMenu = NSApp.mainMenu,
              let item = mainMenu.items.first(where: Self.isHelpItem) else { return }
        mainMenu.removeItem(item)
    }

    /// True when `item` is the menu bar's Help item. See "Identifying the menu" above.
    static func isHelpItem(_ item: NSMenuItem) -> Bool {
        if let help = NSApp.helpMenu, item.submenu === help { return true }
        return item.title == "Help" || item.submenu?.title == "Help"
    }
}

// MARK: - Launch-Time Policy

/// One-time AppKit settings that shape the menu bar. Each is its own call.
@MainActor
enum MenuBarPolicy {

    /// Turns off automatic window tabbing, which removes the View menu's Show Tab Bar /
    /// Show All Tabs items and the Window menu's tab items. Call before the first window
    /// is created — the `App` initializer or `applicationWillFinishLaunching`.
    ///
    /// Skip it in an app that wants tabs (Compare Folders).
    static func disableAutomaticWindowTabbing() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Hides the "Start Dictation…" and "Emoji & Symbols" items AppKit appends to the Edit
    /// menu.
    ///
    /// These two `UserDefaults` keys are undocumented and the only known way to do it.
    /// AppKit reads them ONCE while building the Edit menu, so call this from
    /// `applicationWillFinishLaunching`; any later has no effect. They are written to
    /// `.standard` because that is the domain AppKit reads — a suite would do nothing.
    static func suppressInputMenuItems(dictation: Bool = true,
                                       characterPalette: Bool = true) {
        if dictation {
            UserDefaults.standard.set(true, forKey: "NSDisabledDictationMenuItem")
        }
        if characterPalette {
            UserDefaults.standard.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")
        }
    }
}

// MARK: - Refresh on Open

/// Calls `handler` each time a menu — optionally one with a given title — is about to be
/// shown.
///
/// A `Commands` body only picks up state SwiftUI observes, so a title or checkmark that
/// depends on anything else — AppKit state, a file's name on disk — goes stale (as does
/// `.disabled`; see `StandardEditCommands`). `NSMenu.didBeginTrackingNotification`
/// fires immediately before a menu is displayed, which is the moment to push the current
/// value in. (PhotoGallery's `FileMenuTitleSync`.)
///
/// It observes the notification rather than becoming the menu's `delegate`, which SwiftUI's
/// Commands bridge owns; replacing that would break `.disabled`.
///
/// Selector-based on purpose: the block-based observer API needs an `@Sendable` closure,
/// which drags in "sending risks data races" warnings and a nonisolated-deinit problem for
/// the token. AppKit posts this notification on the main thread.
@MainActor
final class MenuTrackingObserver: NSObject {
    private let menuTitle: String?
    private let handler: @MainActor (NSMenu) -> Void

    /// - Parameters:
    ///   - menuTitle: Only menus with this title trigger `handler` (for example "File").
    ///     `nil` for every menu, the menu bar included.
    ///   - handler: Receives the menu about to open.
    init(menuTitle: String? = nil, handler: @escaping @MainActor (NSMenu) -> Void) {
        self.menuTitle = menuTitle
        self.handler = handler
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Stops observing before the object is released.
    func invalidate() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        if let menuTitle, menu.title != menuTitle { return }
        handler(menu)
    }
}

extension View {
    /// Runs `action` each time any menu is about to be shown — the SwiftUI-side
    /// counterpart of `MenuTrackingObserver`, for a view inside a `Commands` body that
    /// mirrors state into `@State`. (Film Tracker's View-menu submenus.)
    func onMenuTracking(perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            action()
        }
    }
}

extension NSMenu {
    /// The first item with this key equivalent and exactly these modifiers.
    ///
    /// For finding a SwiftUI-built item to retitle from a `MenuTrackingObserver` — the
    /// title is usually the very thing being changed, so it cannot be used to find it.
    func firstItem(keyEquivalent: String,
                   modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
        items.first {
            $0.keyEquivalent == keyEquivalent
                && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                    == modifiers.intersection(.deviceIndependentFlagsMask)
        }
    }
}
