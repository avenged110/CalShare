// MARK: - ActivityView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import CalShareCore
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.events
    /// Methods hidden from the request list; empty shows everything (the default).
    @State private var hiddenMethods: Set<String> = []

    enum Tab: String, CaseIterable { case events = "Events", requests = "Requests" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Review events, which cover actions which occurred on the server, such as backups, certificate renewals, and incident recovery, as well as requests which detail interactions with connected devices.") {
                HStack {
                    SegmentedControl(selection: $tab, segments: Tab.allCases.map { .init($0, $0.rawValue) })
                        .fixedSize()
                    Spacer()
                    MethodFilterMenu(hidden: $hiddenMethods)
                        .disabled(tab != .requests)
                }
            }
            Divider()

            switch tab {
            case .events:
                if model.snapshot.events.isEmpty {
                    ContentUnavailableView("No Events Yet", systemImage: "list.bullet")
                } else {
                    // The lists read the model inside the scroll view, as on the Overview
                    // (see OverviewView), so a new event isn't a whole new page.
                    PageScrollView {
                        EventList()
                            .padding(24)
                    }
                }
            case .requests:
                if model.snapshot.requests.isEmpty {
                    ContentUnavailableView("No Requests Yet", systemImage: "arrow.left.arrow.right",
                                           description: Text("Requests from Calendar, Reminders, and Contacts appear here."))
                } else if !model.snapshot.requests.contains(where: { RequestList.shows($0, hiding: hiddenMethods) }) {
                    ContentUnavailableView("No Matching Requests", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Every request so far uses a method the filter hides."))
                } else {
                    PageScrollView {
                        RequestList(hiddenMethods: hiddenMethods)
                            .padding(24)
                    }
                }
            }
        }
    }
}

private struct EventList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupedTable(style: .card) {
            ForEach(model.snapshot.events) { EventRow(event: $0) }
        }
    }
}

/// The requests in a grouped table like the events', with fixed columns so every row
/// lines up with the header.
private struct RequestList: View {
    @Environment(AppModel.self) private var model
    let hiddenMethods: Set<String>

    static func shows(_ entry: RequestLogEntry, hiding hidden: Set<String>) -> Bool {
        !hidden.contains(MethodFilterMenu.group(of: entry.method))
    }

    var body: some View {
        let requests = model.snapshot.requests.filter { Self.shows($0, hiding: hiddenMethods) }
        GroupedTable(style: .card) {
            row(time: Text("Time"), method: Text("Method"), path: Text("Path"), status: Text("Status"),
                account: Text("Account"), client: Text("Client"), milliseconds: Text("ms"))
                .bold()
                .foregroundStyle(.secondary)
            // By each entry's own identity: identified by position, every row would change
            // whenever a new request arrived at the top.
            ForEach(requests) { entry in
                row(time: Text(entry.date, format: .dateTime.hour().minute().second()),
                    method: Text(entry.method).monospaced(),
                    path: Text(entry.path).help(entry.path),
                    status: Text("\(entry.status)").monospaced()
                        .foregroundStyle(entry.status >= 500 ? .red : entry.status >= 400 && entry.status != 401 && entry.status != 404 ? .orange : .primary),
                    account: Text(entry.username ?? "—"),
                    client: Text(entry.client.isEmpty ? entry.remoteAddress : "\(entry.remoteAddress) (\(entry.client))").help(entry.client),
                    milliseconds: Text("\(entry.milliseconds)").monospacedDigit())
            }
        }
        .font(.subheadline)
    }

    private func row(time: some View, method: some View, path: some View, status: some View,
                     account: some View, client: some View, milliseconds: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            time.frame(width: 70, alignment: .leading)
            method.frame(width: 80, alignment: .leading)
            path.lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            status.frame(width: 44, alignment: .leading)
            account.lineLimit(1).frame(width: 80, alignment: .leading)
            client.lineLimit(1).truncationMode(.tail).frame(width: 150, alignment: .leading)
            milliseconds.frame(width: 36, alignment: .trailing)
        }
    }
}

/// Chooses which request methods the Requests list shows. Every method is shown by
/// default; the glyph fills while any is hidden.
struct MethodFilterMenu: View {
    @Binding var hidden: Set<String>

    /// Every method a request can have (the server's own list), plus Other for anything
    /// a client might send that the server doesn't know.
    static let methods = DAVHandler.loggedMethods + [other]
    static let other = "Other"

    static func group(of method: String) -> String {
        DAVHandler.loggedMethods.contains(method) ? method : other
    }

    var body: some View {
        Menu {
            ForEach(Self.methods, id: \.self) { method in
                Toggle(method, isOn: Binding(
                    get: { !hidden.contains(method) },
                    set: { shown in if shown { hidden.remove(method) } else { hidden.insert(method) } }))
            }
            Divider()
            Button("Show All") { hidden = [] }
                .disabled(hidden.isEmpty)
        } label: {
            Image(systemName: hidden.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by Method")
    }
}
