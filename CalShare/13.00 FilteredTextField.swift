// MARK: - FilteredTextField.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// A text field that silently refuses anything it can't hold, after Film Tracker's
// DigitTextField and DigitOnlyFormatter (InputUtilities). The filter runs in the
// formatter's isPartialStringValid, AppKit's intercept before a change reaches the field's
// storage: a disallowed character never appears, not even for a frame, whether it was
// typed, pasted or dictated.

import AppKit
import SwiftUI

/// What a FilteredTextField accepts.
nonisolated struct InputFilter: Sendable {
    /// Characters that may be entered; everything else is dropped.
    let allowed: Set<Character>
    let maxLength: Int
    /// Applied before filtering, so "A" becomes "a" rather than being dropped.
    var lowercases = false

    static let digits = Set("0123456789")

    /// TCP ports: up to five digits.
    static let port = InputFilter(allowed: digits, maxLength: 5)

    /// Account names: Store.isValidUsername's characters and length.
    static let accountName = InputFilter(allowed: Set("abcdefghijklmnopqrstuvwxyz0123456789._-"),
                                         maxLength: 32, lowercases: true)

    /// DNS host names: letters, digits, dots and dashes.
    static let hostname = InputFilter(allowed: Set("abcdefghijklmnopqrstuvwxyz0123456789.-"),
                                      maxLength: 253, lowercases: true)

    func apply(_ text: String) -> String {
        let source = lowercases ? text.lowercased() : text
        return String(source.filter { allowed.contains($0) }.prefix(maxLength))
    }
}

struct FilteredTextField: NSViewRepresentable {
    @Binding var text: String
    let filter: InputFilter
    var placeholder: String?
    var alignment: NSTextAlignment = .natural
    var monospaced = false
    var onSubmit: (() -> Void)?
    /// Escape, when set; otherwise Escape goes on to the window or sheet as usual.
    var onCancel: (() -> Void)?
    /// Takes the keyboard focus once it's in a window, for a field that appears on request.
    var focusesOnAppear = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusableTextField()
        field.focusesOnAppear = focusesOnAppear
        // One formatter per field: AppKit keeps per-field display state in it.
        field.formatter = FilterFormatter(filter: filter)
        field.delegate = context.coordinator
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.focusRingType = .default
        field.font = monospaced ? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                                : .systemFont(ofSize: NSFont.systemFontSize)
        field.alignment = alignment
        field.placeholderString = placeholder
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.stringValue = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.isEnabled = context.environment.isEnabled
        // Never write into a field being edited: AppKit would reset its field editor and
        // lose the cursor. While editing, the delegate keeps `text` current anyway.
        let editing = field.currentEditor() != nil
        if !editing && field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FilteredTextField
        init(_ parent: FilteredTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)), let onSubmit = parent.onSubmit {
                parent.text = control.stringValue
                onSubmit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)), let onCancel = parent.onCancel {
                onCancel()
                return true
            }
            return false
        }
    }
}

/// A text field that can take the focus as soon as it's in a window. The window comes
/// from `viewWillMove(toWindow:)`, which hands it over strongly, rather than from the
/// `unowned(unsafe)` `window` property.
final class FocusableTextField: NSTextField {
    var focusesOnAppear = false
    private weak var hostWindow: NSWindow?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        hostWindow = newWindow
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusesOnAppear, let hostWindow else { return }
        focusesOnAppear = false
        // Next turn, once SwiftUI has finished adding the row.
        DispatchQueue.main.async { [weak self, weak hostWindow] in
            guard let self, let hostWindow else { return }
            hostWindow.makeFirstResponder(self)
        }
    }
}

/// Drops disallowed characters and caps the length before the change reaches storage.
/// Returning true accepts the proposal as is; false applies the cleaned string instead.
nonisolated private final class FilterFormatter: Formatter, @unchecked Sendable {
    let filter: InputFilter

    init(filter: InputFilter) {
        self.filter = filter
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func string(for obj: Any?) -> String? { obj as? String }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        unsafe obj?.pointee = string as AnyObject
        return true
    }

    override func isPartialStringValid(_ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
                                       proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
                                       originalString origString: String, originalSelectedRange origSelRange: NSRange,
                                       errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let proposed = unsafe partialStringPtr.pointee as String
        let filtered = filter.apply(proposed)
        if filtered == proposed { return true }
        // Keep the cursor where the user was typing, less whatever was dropped before it.
        let location = unsafe proposedSelRangePtr?.pointee.location ?? filtered.utf16.count
        let removed = proposed.utf16.count - filtered.utf16.count
        unsafe partialStringPtr.pointee = filtered as NSString
        if let pointer = unsafe proposedSelRangePtr {
            unsafe pointer.pointee = NSRange(location: max(0, min(location - removed, filtered.utf16.count)), length: 0)
        }
        return false
    }
}
