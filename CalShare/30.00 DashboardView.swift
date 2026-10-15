// MARK: - DashboardView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import CalShareCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: Binding(
            get: { model.sidebarVisible ? .all : .detailOnly },
            set: { model.sidebarVisible = $0 != .detailOnly })) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: Layout.sidebarWidth, ideal: Layout.sidebarWidth, max: Layout.sidebarWidth)
        } detail: {
            PageSwitcher()
                // Film Tracker's fix for the sidebar reveal glitch: the size goes on the
                // detail column's content, never on the split view or anything around it.
                // A fixed frame outside the split view makes it re-layout both columns
                // against that frame while AppKit animates the sidebar in.
                .frame(minWidth: Layout.pageWidth, minHeight: Layout.windowHeight)
                .navigationTitle(model.selection.title)
                .navigationSubtitle("")
        }
        .navigationSplitViewStyle(.prominentDetail)
        .sheet(isPresented: $model.showSetupAssistant) {
            SetupAssistant()
                .environment(model)
                .interactiveDismissDisabled()
        }
        .onAppear {
            model.openWindowAction = { id in openWindow(id: id) }
        }
    }
}

/// The sidebar. Its List holds a local selection, so a click updates the row at once and
/// the model follows; programmatic changes (menus, buttons) flow back down.
private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var localSelection: SidebarItem = .overview

    var body: some View {
        List(selection: $localSelection) {
            ForEach(SidebarItem.allCases) { item in
                Label(item.title, systemImage: item.symbol)
                    .badge(badge(for: item))
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
        // Film Tracker's strong form, on the column's content rather than the split view:
        // AppKit animates the sidebar column itself, and any SwiftUI animation inside it
        // (the rows, the footer) would run against that and slide the other way.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .safeAreaInset(edge: .bottom) { SidebarStatusFooter() }
        .onAppear { localSelection = model.selection }
        .onChange(of: model.selection) { _, new in
            if new != localSelection { localSelection = new }
        }
        .onChange(of: localSelection) { _, new in
            if model.selection != new { model.selection = new }
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        guard item == .overview, model.statusRevealed else { return 0 }
        return model.snapshot.health.filter { $0.state >= HealthState.warning }.count
    }
}

/// One stable container for every page.
private struct PageSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.selection {
            case .overview: OverviewView().id(SidebarItem.overview)
            case .accounts: AccountsView().id(SidebarItem.accounts)
            case .devices: DevicesView().id(SidebarItem.devices)
            case .backups: BackupsView().id(SidebarItem.backups)
            case .activity: ActivityView().id(SidebarItem.activity)
            case .settings: SettingsView().id(SidebarItem.settings)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Film Tracker's strong form (GalleryView): no animations of any kind on the detail
        // column's content, which AppKit moves and resizes as the sidebar is shown or
        // hidden. SwiftUI's own transaction otherwise animates the pages against it.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

struct SidebarStatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.hasLoaded ? model.snapshot.overallState : .working
        let revealed = model.statusRevealed
        HStack(spacing: 8) {
            StatusBadge(glyph: revealed ? state.glyph : "gear", color: revealed ? state.color : .gray, diameter: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(revealed ? OverallStatus.title(for: state) : OverallStatus.configuring)
                    .font(.callout.weight(.medium))
                if revealed, let port = model.snapshot.httpsPort {
                    Text(verbatim: "\(model.snapshot.deviceHostname):\(port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        // Tall enough for the title and the address beneath it, from launch: the badge never
        // moves, and the title moves up when the address appears.
        .frame(height: 32)
        .padding(12)
    }
}
