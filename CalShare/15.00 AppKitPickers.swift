// MARK: - AppKitPickers.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// CalShare's pickers: an NSPopUpButton and an NSSegmentedControl driven directly, in place
// of SwiftUI's Picker. Brought over from Film Tracker (SheetPopUpButton and
// SheetSegmentedControl in its FSControlHelpers.swift).
//
// SwiftUI's menu Picker ends up as an NSPopUpButton of plain NSMenuItems anyway, and its
// segmented Picker as an NSSegmentedControl; building them here skips SwiftUI's per-item
// adaptor, and gives the pop-up one thing SwiftUI's can't: a binding can decline a write
// (to ask for confirmation first) and the button goes straight back to the old value,
// with no flash of the declined one.

import AppKit
import SwiftUI

// MARK: - Control Size

extension NSControl.ControlSize {
    /// The AppKit size for a SwiftUI `.controlSize`, so these controls follow the
    /// environment the way SwiftUI's own controls do.
    init(_ size: ControlSize) {
        switch size {
        case .mini:       self = .mini
        case .small:      self = .small
        case .large:      self = .large
        case .extraLarge: self = .large
        default:          self = .regular
        }
    }
}

// MARK: - Pop-up Button

/// A single-select menu: the NSPopUpButton SwiftUI's `Picker(.menu)` builds, configured
/// the same way (rounded bezel, `pullsDown: false`, the control size's system font), so the
/// bezel, keyboard type-select, and accessibility are AppKit's own.
///
/// After every choice the button re-selects whatever the binding then reports. For an
/// ordinary binding that's the choice; for one that declines the write, pending a
/// confirmation, it's the old value, so the closed button never shows the pending choice.
struct PopUpButton<Value: Hashable>: NSViewRepresentable {
    /// One menu row. A separator can never be selected; a disabled option keeps its row
    /// (and stays selected if it's the stored value) but can't be chosen.
    enum Item: Equatable {
        case option(tag: Value, title: String, isEnabled: Bool = true)
        case separator
    }

    /// Layout height at the regular control size: SwiftUI lays the control out by its
    /// alignment rect, 20 pt, and lets the 25 pt bezel overhang it, as it does its own Picker.
    nonisolated static var layoutHeight: CGFloat { 20 }

    @Binding var selection: Value
    let items: [Item]

    /// `items`, plus a row for a selection no row carries, titled with the raw value, so
    /// the button never renders blank.
    private var effectiveItems: [Item] {
        let hasTag = items.contains { item in
            if case .option(let tag, _, _) = item { return tag == selection }
            return false
        }
        return hasTag ? items : items + [.option(tag: selection, title: String(describing: selection))]
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .rounded
        button.isBordered = true
        button.imagePosition = .noImage
        button.alignment = .natural
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentHuggingPriority(.defaultHigh, for: .vertical)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let menu = NSMenu()
        menu.autoenablesItems = false
        button.menu = menu
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        // The binding made with the coordinator may address an older value's owner.
        coordinator.selection = $selection

        let nsSize = NSControl.ControlSize(context.environment.controlSize)
        if button.controlSize != nsSize { button.controlSize = nsSize }
        // Keyed off the font, not the control size: a zero-frame NSPopUpButton already
        // reports `.small`, so a size guard alone would never install the small font.
        let fontSize = NSFont.systemFontSize(for: nsSize)
        if button.font?.pointSize != fontSize { button.font = NSFont.systemFont(ofSize: fontSize) }
        button.isEnabled = context.environment.isEnabled

        coordinator.rebuildMenu(on: button, items: effectiveItems)
        coordinator.select(tag: selection, on: button)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Value>
        /// The tag of each menu row, index-aligned with the menu; nil for a separator.
        private var tags: [Value?] = []
        /// What the menu was built from, so an unchanged update rebuilds nothing.
        private var builtItems: [Item]?

        init(selection: Binding<Value>) { self.selection = selection }

        func rebuildMenu(on button: NSPopUpButton, items: [Item]) {
            guard builtItems != items, let menu = button.menu else { return }
            builtItems = items
            menu.removeAllItems()
            tags.removeAll(keepingCapacity: true)
            for item in items {
                switch item {
                case .option(let tag, let title, let isEnabled):
                    let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    menuItem.isEnabled = isEnabled
                    menu.addItem(menuItem)
                    tags.append(tag)
                case .separator:
                    menu.addItem(.separator())
                    tags.append(nil)
                }
            }
            button.invalidateIntrinsicContentSize()
        }

        func select(tag: Value, on button: NSPopUpButton) {
            guard let index = tags.firstIndex(where: { $0 == tag }) else { return }
            if button.indexOfSelectedItem != index { button.selectItem(at: index) }
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard tags.indices.contains(index), let tag = tags[index] else { return }
            if tag != selection.wrappedValue { selection.wrappedValue = tag }
            // The written value for an ordinary binding, the old one for a declined write.
            select(tag: selection.wrappedValue, on: sender)
        }
    }
}

/// The drop-in for `Picker(…) { … }.labelsHidden()`: a PopUpButton at SwiftUI's layout
/// height, as wide as its longest row unless given a width.
struct MenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [PopUpButton<Value>.Item]
    var width: CGFloat?

    init(selection: Binding<Value>, items: [PopUpButton<Value>.Item], width: CGFloat? = nil) {
        _selection = selection
        self.items = items
        self.width = width
    }

    var body: some View {
        if let width {
            PopUpButton(selection: $selection, items: items)
                .frame(width: width, height: PopUpButton<Value>.layoutHeight, alignment: .leading)
        } else {
            PopUpButton(selection: $selection, items: items)
                .frame(height: PopUpButton<Value>.layoutHeight)
                .fixedSize()
        }
    }
}

// MARK: - Segmented Control

/// A segmented picker: the NSSegmentedControl SwiftUI's `Picker(.segmented)` wraps,
/// configured the same way (`.automatic` style, `.selectOne`, `.fillEqually`). Sized as
/// SwiftUI sizes its own: the proposed width, but no narrower than the segments need, and
/// the equal-width intrinsic size under `.fixedSize()`.
struct SegmentedControl<Value: Hashable>: NSViewRepresentable {
    /// One segment, in order. A disabled one is dimmed and ignores clicks.
    struct Segment: Equatable {
        let tag: Value
        let title: String
        var isEnabled: Bool = true
        init(_ tag: Value, _ title: String, isEnabled: Bool = true) {
            self.tag = tag; self.title = title; self.isEnabled = isEnabled
        }
    }

    @Binding var selection: Value
    let segments: [Segment]

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: segments.map(\.title), trackingMode: .selectOne,
                                         target: context.coordinator,
                                         action: #selector(Coordinator.selectionChanged(_:)))
        control.segmentStyle = .automatic
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultHigh, for: .vertical)
        context.coordinator.remember(segments: segments, on: control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection

        let nsSize = NSControl.ControlSize(context.environment.controlSize)
        if control.controlSize != nsSize {
            control.controlSize = nsSize
            coordinator.invalidateWidths()
        }
        // Keyed off the font, for the reason PopUpButton gives.
        let fontSize = NSFont.systemFontSize(for: nsSize)
        if control.font?.pointSize != fontSize {
            control.font = NSFont.systemFont(ofSize: fontSize)
            coordinator.invalidateWidths()
        }
        control.isEnabled = context.environment.isEnabled

        coordinator.rebuildSegments(on: control, segments: segments)
        coordinator.select(tag: selection, on: control)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSSegmentedControl,
                      context: Context) -> CGSize? {
        let (minWidth, idealWidth) = context.coordinator.widths(of: control)
        let height = control.intrinsicContentSize.height
        if let width = proposal.width, width.isFinite {
            return CGSize(width: max(width, minWidth), height: height)
        }
        return CGSize(width: idealWidth, height: height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Value>
        /// The tag of each segment, index-aligned with the control's segments.
        private var tags: [Value] = []
        /// What the segments were built from, so an unchanged update rebuilds nothing.
        private var builtSegments: [Segment]?
        /// (minimum, ideal) width, measured once per segment set.
        private var cachedWidths: (min: CGFloat, ideal: CGFloat)?

        init(selection: Binding<Value>) { self.selection = selection }

        func remember(segments: [Segment], on control: NSSegmentedControl) {
            builtSegments = segments
            tags = segments.map(\.tag)
            for (index, segment) in segments.enumerated() where !segment.isEnabled {
                control.setEnabled(false, forSegment: index)
            }
        }

        func invalidateWidths() { cachedWidths = nil }

        func rebuildSegments(on control: NSSegmentedControl, segments: [Segment]) {
            guard builtSegments != segments else { return }
            builtSegments = segments
            tags = segments.map(\.tag)
            control.segmentCount = segments.count
            for (index, segment) in segments.enumerated() {
                control.setLabel(segment.title, forSegment: index)
                control.setWidth(0, forSegment: index)
                control.setEnabled(segment.isEnabled, forSegment: index)
            }
            cachedWidths = nil
            control.invalidateIntrinsicContentSize()
        }

        /// The minimum is the `.fit` distribution's width plus the alignment-rect insets;
        /// the ideal is the `.fillEqually` intrinsic width.
        func widths(of control: NSSegmentedControl) -> (min: CGFloat, ideal: CGFloat) {
            if let cachedWidths { return cachedWidths }
            control.segmentDistribution = .fit
            control.invalidateIntrinsicContentSize()
            let insets = control.alignmentRectInsets
            let minWidth = control.intrinsicContentSize.width + insets.left + insets.right
            control.segmentDistribution = .fillEqually
            control.invalidateIntrinsicContentSize()
            let widths = (min: minWidth, ideal: control.intrinsicContentSize.width)
            cachedWidths = widths
            return widths
        }

        func select(tag: Value, on control: NSSegmentedControl) {
            guard let index = tags.firstIndex(of: tag) else {
                if control.selectedSegment != -1 { control.selectedSegment = -1 }
                return
            }
            if control.selectedSegment != index { control.selectedSegment = index }
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard tags.indices.contains(index) else { return }
            let tag = tags[index]
            if tag != selection.wrappedValue { selection.wrappedValue = tag }
            // Not re-read from the binding here: AppKit has already moved the selection,
            // and the next update reconciles it with the binding.
        }
    }
}
