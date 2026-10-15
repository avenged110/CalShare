// MARK: - OverviewView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import CalShareCore
import SwiftUI

struct OverviewView: View {
    var body: some View {
        // The page reads the model inside its scroll view, never here: a body here that
        // read it would re-run on every change and hand the scroll view a whole new page,
        // which it re-measures from scratch (see AppKitScrollRevision).
        SectionPage { OverviewContent() }
    }
}

private struct OverviewContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.snapshot
        Group {
            StatusHero(snapshot: snapshot, loaded: model.hasLoaded)

            HStack(spacing: 12) {
                StatTile(value: snapshot.statistics.events, label: "Events", symbol: "calendar")
                StatTile(value: snapshot.statistics.tasks, label: "Reminders", symbol: "checklist")
                StatTile(value: snapshot.statistics.contacts, label: "Contacts", symbol: "person.crop.circle")
                StatTile(value: snapshot.clients.count, label: "Devices Seen", symbol: "iphone")
            }

            Text("Components").font(.title3.weight(.semibold))
            ComponentGrid(health: snapshot.health)

            if !snapshot.events.isEmpty {
                HStack {
                    Text("Recent Activity").font(.title3.weight(.semibold))
                    Spacer()
                    Button("Show All") { model.selection = .activity }
                        .controlSize(.small)
                }
                Card {
                    ForEach(snapshot.events.prefix(5)) { event in
                        EventRow(event: event)
                    }
                }
            }
        }
    }
}

struct StatusHero: View {
    @Environment(AppModel.self) private var model
    let snapshot: SupervisorSnapshot
    let loaded: Bool

    var body: some View {
        let state = loaded ? snapshot.overallState : .working
        let revealed = model.statusRevealed
        Card {
            HStack(alignment: .center, spacing: 16) {
                // One badge throughout, so every change is a change of its glyph.
                StatusBadge(glyph: revealed ? state.glyph : "gear", color: revealed ? state.color : .gray, diameter: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(revealed ? OverallStatus.title(for: state) : OverallStatus.configuring)
                        .font(.title2.weight(.semibold))
                    Text(revealed ? heroDetail(state: state) : "Awaiting setup. The setup assistant gets everything ready.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if snapshot.accounts.isEmpty, loaded {
                    Button("Set Up CalShare…") { model.showSetupAssistant = true }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Add a Device…") { model.selection = .devices }
                        .controlSize(.large)
                }
            }
        }
    }

    private func heroDetail(state: HealthState) -> String {
        if !loaded { return "Getting the server ready." }
        if snapshot.accounts.isEmpty { return "Create an account to start syncing calendars and contacts." }
        if let port = snapshot.httpsPort {
            let problems = snapshot.health.filter { $0.state >= HealthState.warning }.map(\.title)
            if !problems.isEmpty { return "Check: \(problems.joined(separator: ", "))." }
            return "Serving at \(snapshot.deviceHostname), port \(port). Your devices sync automatically."
        }
        return "The server isn't accepting connections yet."
    }
}

struct StatTile: View {
    let value: Int
    let label: String
    let symbol: String

    var body: some View {
        Card {
            Label(label, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.title.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                // Pages turn animations off (ModelEnvironment); a new count turns them on.
                .transaction(value: value) { transaction in
                    transaction.disablesAnimations = false
                    transaction.animation = .default
                }
        }
    }
}

/// Every component's card, laid out from the first frame: the cards are placeholders until
/// the first report arrives, and are never added, removed or reordered after that.
struct ComponentGrid: View {
    let health: [ComponentHealth]

    var body: some View {
        let items = ComponentHealth.placeholders.map { slot in health.first { $0.id == slot.id } ?? slot }
        let rows = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
        VStack(spacing: 12) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(spacing: 12) {
                    ForEach(row) { HealthCard(item: $0) }
                    if row.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
    }
}

/// A component's card. Its parts are pinned in place: the glyph in a fixed slot before
/// the title, the badge at the top-trailing corner, the fix button at the bottom, and the
/// summary and detail in space reserved for them. What they hold crossfades as it changes.
struct HealthCard: View {
    @Environment(AppModel.self) private var model
    let item: ComponentHealth

    /// Every card is this tall, whatever it holds, so the grid stays even.
    static let height: CGFloat = 180

    var body: some View {
        // Until setup reaches its server check, nothing here is reported as running.
        let revealed = model.statusRevealed
        let summary = revealed ? item.summary : "Awaiting setup"
        let detail = revealed ? item.detail ?? "" : ""
        let fix = revealed && item.fix != nil && item.fixTitle != nil ? item : nil
        Card(height: Self.height, headerBottomPadding: 10) {
            HStack(spacing: 8) {
                GlyphLabel(item.title, symbol: item.symbol)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                StatusBadge(glyph: revealed ? item.state.glyph : "poweroff",
                            color: revealed ? item.state.color : .gray,
                            diameter: Self.badgeDiameter, glyphSize: Self.badgeGlyphSize)
                    .help(revealed ? item.state.rawValue.capitalized : "Awaiting Setup")
            }
        } content: {
            Crossfade(summary) {
                Text($0)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Crossfade(detail) {
                Text($0)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .help($0)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Crossfade(FixKey(fix), alignment: .bottomLeading) { key in
                if let item = key.item, let fix = item.fix, let title = item.fixTitle {
                    FixButton(title: title, fix: fix, prominent: item.state >= HealthState.warning)
                }
            }
            .padding(16)
        }
    }

    private static let badgeDiameter: CGFloat = 16
    /// Just under the usual 9.14pt: symbols are drawn on the pixel grid, and at 9.14pt the
    /// dashed circle lands a fifth of a point right of and below center. Measured at 2x,
    /// 8.75pt centers it, and the poweroff, xmark, and minus as well or better.
    private static let badgeGlyphSize: CGFloat = 8.75

    /// What the fix button shows; it crossfades only when one of these changes.
    private struct FixKey: Hashable {
        let item: ComponentHealth?
        init(_ item: ComponentHealth?) { self.item = item }
        static func == (a: FixKey, b: FixKey) -> Bool {
            a.item?.fix == b.item?.fix && a.item?.fixTitle == b.item?.fixTitle && a.urgent == b.urgent
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(item?.fix)
            hasher.combine(item?.fixTitle)
            hasher.combine(urgent)
        }
        private var urgent: Bool { (item?.state ?? .ok) >= HealthState.warning }
    }
}

/// Lets a button choose its style at runtime.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct EventRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusBadge(glyph: glyph, color: color)
            Text(event.message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(event.date, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var glyph: String {
        switch event.level {
        case .info: "info"
        case .success: "checkmark"
        case .warning: "exclamationmark"
        case .error: "xmark"
        }
    }

    private var color: Color {
        switch event.level {
        case .info: .gray
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
