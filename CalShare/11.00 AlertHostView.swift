// MARK: - AlertHostView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Invisible view that presents every alert in the app, modeled on Film Tracker's
// AlertHostView. Alerts are requested through `AppModel.present(_:)` and queued there; one
// host sits in the dashboard window and one in every sheet, and only the host in front
// (the open sheet, else the window) shows them. SwiftUI's `.alert` on macOS is attached to
// the window or sheet it belongs to, so nothing here is app-modal.

import SwiftUI

// MARK: - Host Alert

/// One alert, carrying everything its buttons act on. The payload travels with the alert,
/// so a request arriving while another alert is open can neither retarget nor lose it.
struct HostAlert: Identifiable {
    struct Action {
        var title: String
        var role: ButtonRole?
        var perform: @MainActor () -> Void
    }

    let id = UUID()
    var title: String
    var message: String
    /// The default (or destructive) button. Nil for a plain notice with one button.
    var primary: Action?
    /// The button that only dismisses: "OK" for a notice, "Cancel" for a confirmation.
    var dismissTitle: String
    /// Run when the dismiss button is chosen, to undo whatever led to the question.
    var cancel: (@MainActor () -> Void)?

    /// A notice with a single OK button.
    static func notice(_ title: String, _ message: String) -> HostAlert {
        HostAlert(title: title, message: message, primary: nil, dismissTitle: "OK")
    }

    /// A question with a dismiss button and one action.
    static func confirm(_ title: String, _ message: String, action: String, role: ButtonRole? = nil,
                        dismiss: String = "Cancel", cancel: (@MainActor () -> Void)? = nil,
                        perform: @escaping @MainActor () -> Void) -> HostAlert {
        HostAlert(title: title, message: message, primary: Action(title: action, role: role, perform: perform),
                  dismissTitle: dismiss, cancel: cancel)
    }
}

// MARK: - Alert Queue

/// The alert on screen and the ones waiting behind it, in arrival order.
@MainActor
@Observable
final class AlertQueue {
    private(set) var presented: HostAlert?
    private var waiting: [HostAlert] = []

    func enqueue(_ alert: HostAlert) {
        if presented == nil && waiting.isEmpty { presented = alert } else { waiting.append(alert) }
    }

    func dismissPresented() {
        guard presented != nil else { return }
        presented = nil
        // The next alert goes up one turn later, off the dismissal's own call stack.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presented == nil, !self.waiting.isEmpty else { return }
            self.presented = self.waiting.removeFirst()
        }
    }
}

// MARK: - Alert Host View

struct AlertHostView: View {
    enum Scope { case window, sheet }

    @Environment(AppModel.self) private var model
    let scope: Scope

    var body: some View {
        let alerts = model.alerts
        let inFront = (scope == .sheet) == (model.openSheets > 0)
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .alert(Text(alerts.presented?.title ?? ""), isPresented: Binding(
                get: { inFront && alerts.presented != nil },
                set: { if !$0 { alerts.dismissPresented() } }),
                   presenting: alerts.presented) { alert in
                if let primary = alert.primary {
                    Button(alert.dismissTitle, role: .cancel) { alert.cancel?() }
                    Button(primary.title, role: primary.role) { primary.perform() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(alert.dismissTitle) {}
                        .keyboardShortcut(.defaultAction)
                }
            } message: { alert in
                Text(alert.message)
            }
    }
}
