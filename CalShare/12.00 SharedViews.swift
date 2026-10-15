// MARK: - SharedViews.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Building blocks every page and sheet uses: the scroll container, the sheet chrome
// (titlebar and button gutter, after Film Tracker's SettingsSheet), grouped tables, cards
// and status badges.

import AppKit
import CalShareCore
import SwiftUI

// MARK: - Scrolling

/// Re-injects what NSHostingView does not inherit from the enclosing SwiftUI environment.
struct ModelEnvironment: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .environment(model)
            .textFieldStyle(.roundedBorder)
            // Each hosted page is a SwiftUI tree of its own, so PageSwitcher's transaction
            // doesn't reach it. Without this, the page animates its own re-layout while
            // AppKit resizes the detail column for the sidebar, and wiggles.
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}

/// The app's one scroll container: AppKitScrollView with the model re-injected.
struct PageScrollView<Content: View>: View {
    @Environment(AppModel.self) private var model
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        AppKitScrollView(modifier: ModelEnvironment(model: model)) { content }
    }
}

// MARK: - Pages

/// A dashboard page: an optional introduction, then the page's content, scrolling. The
/// page's name is in the window's toolbar, not repeated here.
struct SectionPage<Content: View>: View {
    let introduction: String?
    let content: Content

    init(_ introduction: String? = nil, @ViewBuilder content: () -> Content) {
        self.introduction = introduction
        self.content = content()
    }

    var body: some View {
        PageScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let introduction {
                    Text(introduction)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The fixed header of a page, for the controls that apply to the whole page: an optional
/// description, then the controls. Every page's header is the same height, whatever it
/// holds, with its content centered in it.
struct PageHeader<Controls: View>: View {
    let text: String?
    let controls: Controls

    init(_ text: String? = nil, @ViewBuilder controls: () -> Controls) {
        self.text = text
        self.controls = controls()
    }

    /// Room for two lines of description and a row of controls, padded 24pt.
    static var height: CGFloat { 88 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let text {
                Text(text)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            controls
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
    }
}

/// A page with a PageHeader; the content scrolls beneath it.
struct HeaderedPage<Controls: View, Content: View>: View {
    let header: PageHeader<Controls>
    let content: Content

    init(_ text: String, @ViewBuilder controls: () -> Controls, @ViewBuilder content: () -> Content) {
        header = PageHeader(text, controls: controls)
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            SectionPage { content }
        }
    }
}

// MARK: - Sheets

/// The frame every sheet shares: a titlebar, the content, and a button gutter. Hosts the
/// sheet's alerts, so alerts raised while it is open attach to it.
struct SheetChrome<Content: View, Gutter: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    var width: CGFloat = Layout.sheetSize
    var height: CGFloat? = Layout.sheetSize
    let content: Content
    let gutter: Gutter

    init(_ title: String, width: CGFloat = Layout.sheetSize, height: CGFloat? = Layout.sheetSize,
         @ViewBuilder content: () -> Content, @ViewBuilder gutter: () -> Gutter) {
        self.title = title
        self.width = width
        self.height = height
        self.content = content()
        self.gutter = gutter()
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(Divider(), alignment: .bottom)
            content
                .frame(maxWidth: .infinity, maxHeight: height == nil ? nil : .infinity)
            Divider()
            gutter
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: width, height: height)
        .textFieldStyle(.roundedBorder)
        .background(AlertHostView(scope: .sheet))
        .onAppear { model.openSheets += 1 }
        .onDisappear { model.openSheets -= 1 }
    }
}

/// A gutter button with Film Tracker's sheet button sizing.
struct GutterButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .padding(4)
                .font(.system(size: 12))
        }
    }
}

// MARK: - Tables and cards

/// A grouped table: rows on the lighter grouped background, divided by separators, like a
/// grouped Form section but without a scroll view of its own.
struct GroupedTable<Content: View>: View {
    /// `.inset` for a table inside a card, on a fill that contrasts with the card's;
    /// `.card` for a table standing on the page, in the cards' own chrome.
    enum Style { case inset, card }
    /// Which rows have a divider above them: every row, or only the first row after the
    /// column titles.
    enum Dividers { case everyRow, belowTitles }

    var style: Style
    var dividers: Dividers
    /// The padding above and below a row where it meets another row with no divider
    /// between them. The table's edges and its dividers always get `edgePadding`.
    var rowPadding: CGFloat
    let content: Content

    static var edgePadding: CGFloat { 9 }

    init(style: Style = .inset, dividers: Dividers = .everyRow, rowPadding: CGFloat = edgePadding,
         @ViewBuilder content: () -> Content) {
        self.style = style
        self.dividers = dividers
        self.rowPadding = rowPadding
        self.content = content()
    }

    private func hasDivider(above index: Int) -> Bool {
        index > 0 && (dividers == .everyRow || index == 1)
    }

    var body: some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if hasDivider(above: index) { Divider().padding(.horizontal, 12) }
                    row
                        .padding(.horizontal, 12)
                        .padding(.top, index == 0 || hasDivider(above: index) ? Self.edgePadding : rowPadding)
                        .padding(.bottom, index == rows.count - 1 || hasDivider(above: index + 1) ? Self.edgePadding : rowPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        switch style {
        case .inset:
            rows
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.5)))
        case .card:
            rows.cardChrome()
        }
    }
}

/// A labeled row inside a GroupedTable: the label leading, the control trailing. A note
/// sits under the label, inside the row, making the row taller; the control then centers
/// vertically on the label and note together, and otherwise sits on the label's baseline.
struct TableRow<Control: View>: View {
    let label: String
    var note: String?
    let control: Control

    init(_ label: String, note: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.note = note
        self.control = control()
    }

    var body: some View {
        HStack(alignment: note == nil ? .firstTextBaseline : .center, spacing: 12) {
            LabelWithNote(label, note: note)
            Spacer(minLength: 12)
            control
        }
    }
}

/// A checkbox row with a note under its title, inside the row. The checkbox stays on the
/// title's line.
struct NotedToggle: View {
    let title: String
    let note: String?
    @Binding var isOn: Bool

    init(_ title: String, note: String?, isOn: Binding<Bool>) {
        self.title = title
        self.note = note
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) { LabelWithNote(title, note: note) }
    }
}

/// A checkbox row in the TableRow layout: the title (and any note) leading, the checkbox
/// trailing with the other rows' controls, placed as in TableRow.
struct TableToggle: View {
    let title: String
    var note: String?
    @Binding var isOn: Bool

    init(_ title: String, note: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.note = note
        self._isOn = isOn
    }

    var body: some View {
        TableRow(title, note: note) {
            Toggle(title, isOn: $isOn).labelsHidden()
        }
    }
}

/// AppKit's color for the text of a disabled control, for titles that sit beside one.
let disabledControlTextColor = Color(nsColor: .disabledControlTextColor)

/// A row's title, and its note in the table footer's style beneath it. Its first baseline
/// is the title's, so whatever sits beside it lines up with the title.
struct LabelWithNote: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let note: String?

    init(_ title: String, note: String?) {
        self.title = title
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Dimmed with its control, as Film Tracker's settings rows are: the title in
            // AppKit's disabled text color, the note a step fainter than usual.
            Text(title)
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(disabledControlTextColor))
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A titled group of tables, the way grouped Form sections read.
struct TableSection<Content: View>: View {
    let title: String
    var footer: String?
    let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            GroupedTable(style: .card) { content }
            if let footer { TableFooter(footer) }
        }
    }
}

/// A label whose glyph sits in a fixed-width slot, so labels with different glyphs line
/// their titles up.
struct GlyphLabel: View {
    let title: String
    let symbol: String
    var glyphWidth: CGFloat = 28
    var spacing: CGFloat = 6

    init(_ title: String, symbol: String, glyphWidth: CGFloat = 28, spacing: CGFloat = 6) {
        self.title = title
        self.symbol = symbol
        self.glyphWidth = glyphWidth
        self.spacing = spacing
    }

    var body: some View {
        HStack(spacing: spacing) {
            Image(systemName: symbol)
                .frame(width: glyphWidth, alignment: .center)
            Text(title)
        }
    }
}

/// The note under a grouped table.
struct TableFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

struct Card<Header: View, Content: View>: View {
    /// A fixed height, for cards that must line up in a grid; nil fits the content.
    var height: CGFloat?
    /// A title row above a divider, centered between the card's top edge and the divider.
    let header: Header?
    /// The space between the header's content and the divider.
    var headerBottomPadding: CGFloat
    let content: Content

    init(height: CGFloat? = nil, @ViewBuilder content: () -> Content) where Header == EmptyView {
        self.height = height
        header = nil
        headerBottomPadding = 12
        self.content = content()
    }

    init(height: CGFloat? = nil, headerBottomPadding: CGFloat = 12,
         @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.height = height
        self.header = header()
        self.headerBottomPadding = headerBottomPadding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                // Centered between the card's top edge and the divider, whatever the
                // height of the glyphs in it.
                header
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, headerBottomPadding)
                    // Always its natural height. The scroll view offers its content the
                    // visible height, and content a little taller than that was squeezed
                    // to fit, starting with the first card's header.
                    .fixedSize(horizontal: false, vertical: true)
                // Inset like a standard divider: the content's width, not the card's.
                Divider()
                    .padding(.horizontal, 16)
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .cardChrome()
    }
}

/// Film Tracker's FieldEdgeTreatment outline: the separator color at 20%, fading to
/// nothing from a tenth of the way down.
enum CardChrome {
    static let borderGradient = LinearGradient(
        stops: [
            .init(color: Color(nsColor: .separatorColor).opacity(0.2), location: 0),
            .init(color: Color(nsColor: .separatorColor).opacity(0.2), location: 0.1),
            .init(color: Color(nsColor: .separatorColor).opacity(0), location: 1),
        ],
        startPoint: .top, endPoint: .bottom)
}

extension View {
    /// The cards' chrome, Film Tracker's reorderable-table chrome (listContainerChrome,
    /// FieldEdgeTreatment): the inset list's fill, an outline that fades out down the shape
    /// so the lower edge is carried by the shadow, and a soft shadow.
    ///
    /// The shadow is cast by the fill alone. On the whole view, SwiftUI gives every layer
    /// inside it (each text, label and glyph) a shadow of its own, and the compositor draws
    /// each of those offscreen on every frame of a scroll: 105 of them on the Overview.
    func cardChrome() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return background {
            shape
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.16), radius: 1.5, x: 0, y: 1)
        }
        .overlay(shape.strokeBorder(CardChrome.borderGradient, lineWidth: 1))
    }
}

/// The label column of a value table (CopyableValue rows and rows built like them).
struct TableLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    static let width: CGFloat = 110

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: Self.width, alignment: .leading)
    }
}

/// A row of a value table: the label, the value, and buttons at the trailing end. The
/// buttons sit on the value's first line by a fixed guide rather than by their glyphs'
/// baselines, so a button that changes glyph never moves itself or the row.
struct ValueRow<Value: View, Buttons: View>: View {
    let label: String
    let value: Value
    let buttons: Buttons

    init(_ label: String, @ViewBuilder value: () -> Value, @ViewBuilder buttons: () -> Buttons) {
        self.label = label
        self.value = value()
        self.buttons = buttons()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            TableLabel(label)
            value
            Spacer(minLength: 8)
            HStack(spacing: 8) { buttons }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
    }
}

struct CopyableValue: View {
    let label: String
    let value: String
    /// Adds a Share button (AirDrop, Messages, …) before Copy.
    var shareURL: URL?
    /// Shares text instead (a command), when there's no URL.
    var shareText: String?
    /// False while the value is still being made: `value` is then a stand-in of the same
    /// length, laid out but not shown, so the row is already its final size, and the
    /// buttons are disabled.
    var ready = true
    /// Shows the Share button even before `shareURL` exists (disabled until then).
    var sharable = false
    /// Smaller for long values (addresses, fingerprints).
    var small = false

    var body: some View {
        ValueRow(label) {
            Text(verbatim: value)
                .textSelection(.enabled)
                .font(small ? .subheadline.monospaced() : .body.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .opacity(ready ? 1 : 0)
        } buttons: {
            if let shareURL, ready {
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: CopyButton.glyphSize, height: CopyButton.glyphSize)
                }
                .controlSize(.small)
                .help("Share")
            } else if let shareText, ready {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: CopyButton.glyphSize, height: CopyButton.glyphSize)
                }
                .controlSize(.small)
                .help("Share")
            } else if sharable || shareURL != nil {
                Button {} label: {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: CopyButton.glyphSize, height: CopyButton.glyphSize)
                }
                .controlSize(.small)
                .disabled(true)
            }
            CopyButton(value: value)
                .disabled(!ready)
        }
    }
}

/// Copies a value to the clipboard. After a successful copy its glyph turns into a
/// checkmark for two seconds, both ways with the native replace animation. The glyph sits
/// in a fixed box, so the button keeps its size whichever glyph it shows.
struct CopyButton: View {
    let value: String
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    static let glyphSize: CGFloat = 16

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(value, forType: .string) else { return }
            copied = true
            reset?.cancel()
            reset = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.glyphSize, height: Self.glyphSize)
                // The pages turn animations off (ModelEnvironment); this change turns them on.
                .transaction(value: copied) { transaction in
                    transaction.disablesAnimations = false
                    transaction.animation = .default
                }
        }
        .controlSize(.small)
        .help("Copy")
        .onDisappear { reset?.cancel() }
    }
}

/// Swaps its content with a 0.2-second crossfade whenever `value` changes. Only opacity
/// animates: the outgoing and incoming content are both laid out where they finally sit,
/// and nothing else that changed alongside is animated with them.
struct Crossfade<Value: Hashable, Content: View>: View {
    let value: Value
    let alignment: Alignment
    let content: (Value) -> Content
    @State private var shown: Value
    @State private var outgoing: Value?
    /// 0 shows `outgoing`, 1 shows `shown`.
    @State private var progress: Double = 1
    @State private var fade: Task<Void, Never>?

    init(_ value: Value, alignment: Alignment = .topLeading, @ViewBuilder content: @escaping (Value) -> Content) {
        self.value = value
        self.alignment = alignment
        self.content = content
        _shown = State(initialValue: value)
    }

    var body: some View {
        ZStack(alignment: alignment) {
            if let outgoing {
                content(outgoing).opacity(1 - progress)
            }
            content(shown).opacity(progress)
        }
        // The pages turn animations off (ModelEnvironment); the fade turns them on for itself.
        .transaction(value: progress) { transaction in
            if progress == 1 {
                transaction.disablesAnimations = false
                transaction.animation = .easeInOut(duration: 0.2)
            }
        }
        .onChange(of: value) { _, new in
            fade?.cancel()
            outgoing = shown
            shown = new
            progress = 0
            // The fade runs as an update of its own, a frame later, from 0 now on screen.
            fade = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled else { return }
                progress = 1
                try? await Task.sleep(for: .seconds(0.25))
                guard !Task.isCancelled else { return }
                outgoing = nil
            }
        }
        .onDisappear { fade?.cancel() }
    }
}

/// A password field that hides what is typed, or shows it, as Settings chooses.
struct PasswordField: View {
    @AppStorage(Preferences.Key.hidePasswords) private var hidePasswords = true
    let title: String
    @Binding var text: String
    var prompt: Text?

    init(_ title: String, text: Binding<String>, prompt: Text? = nil) {
        self.title = title
        _text = text
        self.prompt = prompt
    }

    var body: some View {
        if hidePasswords {
            SecureField(title, text: $text, prompt: prompt)
        } else {
            TextField(title, text: $text, prompt: prompt)
        }
    }
}

// MARK: - Status badges

/// A status indicator composed like Film Tracker's IndicatorBadge (ReleasesTable): a filled
/// circle in the state's color with a bold white glyph centered on it. The glyph carries a
/// half-point drop shadow so its edges hold on any saturated fill.
///
/// A new glyph comes in with SwiftUI's own SF Symbols replace transition, over the
/// circle's crossfade to the new color.
///
/// Every badge (the sidebar's, the Overview's large one and the cards') is this one view
/// and sets its own animations, so they behave identically wherever they sit.
struct StatusBadge: View {
    let glyph: String
    let color: Color
    let diameter: CGFloat
    /// The glyph's point size, when not the usual share of the diameter.
    let glyphSize: CGFloat?

    init(_ state: HealthState, diameter: CGFloat = 16) {
        self.init(glyph: state.glyph, color: state.color, diameter: diameter)
    }

    init(glyph: String, color: Color, diameter: CGFloat = 16, glyphSize: CGFloat? = nil) {
        self.glyph = glyph
        self.color = color
        self.diameter = diameter
        self.glyphSize = glyphSize
        _shown = State(initialValue: Look(glyph: glyph, color: color))
    }

    private struct Look: Equatable {
        var glyph: String
        var color: Color
    }

    /// What is on screen. A new look is taken in by `onChange`, in an update of its own:
    /// read straight from the inputs, it would share the transaction of whatever layout
    /// change came with it, and the badge's animation would slide the badge along too.
    @State private var shown: Look

    var body: some View {
        ZStack {
            // A flat fill (which can blend from one color to the next) under the same
            // light-to-dark sheen `Color.gradient` draws (which can't, so it jumped). The
            // shadow is cast by the fill alone: on the fill and sheen together, each gets a
            // shadow of its own, drawn offscreen on every frame of a scroll.
            Circle()
                .fill(shown.color)
                .shadow(color: .black.opacity(0.2), radius: diameter / 32, y: diameter / 32)
                .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.15), .clear],
                                                      startPoint: .top, endPoint: .bottom)))
            // The glyph's shadow is a second copy of the glyph, darkened, blurred and
            // dropped half a point, playing the same effects at the same moments: a shadow
            // modifier on the glyph is drawn outside its symbol effects and doesn't turn.
            ZStack {
                glyphImage
                    .foregroundStyle(.black.opacity(0.5))
                    .blur(radius: 0.5)
                    .offset(y: 0.5)
                glyphImage
                    .foregroundStyle(.white)
            }
            // Flattened into one layer, with room for the blur: left live, the blur is a
            // filter the compositor redraws on every frame of a scroll. The circle stays
            // outside, since flattening it clips its shadow and shifts its color.
            .padding(2)
            .drawingGroup()
            .padding(-2)
        }
        .frame(width: diameter, height: diameter)
        // The badge sets its own animations, whatever its surroundings turn off
        // (ModelEnvironment, the sidebar): the replace transition and the circle's
        // crossfade on a new look, and nothing on any other change. The outer modifier
        // applies first, so the new look's animation is set after the reset.
        .transaction(value: shown) { transaction in
            transaction.animation = .easeInOut(duration: 0.2)
        }
        .transaction { transaction in
            transaction.disablesAnimations = false
            transaction.animation = nil
        }
        .onChange(of: Look(glyph: glyph, color: color)) { _, new in shown = new }
        // Sits on a text baseline the way an SF Symbol would, centered on the capitals.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + diameter * 0.3 }
    }

    private var glyphImage: some View {
        Image(systemName: shown.glyph)
            // Film Tracker's ratio: an 8pt glyph in a 14pt circle.
            .font(.system(size: glyphSize ?? diameter * 8 / 14, weight: .bold))
            .contentTransition(.symbolEffect(.replace))
    }
}

/// A button for work that takes a moment: while the work runs (and for at least two
/// seconds) the button is disabled and a spinner fades in beside it. The spinner's space
/// is always reserved, so nothing around it moves.
struct WorkingButton: View {
    let title: String
    let working: Bool
    var prominent = false
    var controlSize: ControlSize = .small
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(title, action: action)
                .controlSize(controlSize)
                .buttonStyle(prominent ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
                .disabled(working)
            ProgressView()
                .controlSize(.small)
                .opacity(working ? 1 : 0)
        }
        .transaction(value: working) { transaction in
            transaction.disablesAnimations = false
            transaction.animation = .easeInOut(duration: 0.2)
        }
    }
}

/// A button that carries out a FixAction and shows that it is working until it is done.
struct FixButton: View {
    @Environment(AppModel.self) private var model
    let title: String
    let fix: FixAction
    var prominent = false
    var controlSize: ControlSize = .small

    var body: some View {
        WorkingButton(title: title, working: model.workingFixes.contains(fix), prominent: prominent,
                      controlSize: controlSize) { model.perform(fix) }
    }
}

extension HealthState {
    var color: Color {
        switch self {
        case .ok: .green
        case .working: .blue
        case .off: .gray
        case .notice: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    /// The glyph StatusBadge draws on the state's color.
    var glyph: String {
        switch self {
        case .ok: "checkmark"
        case .working: "power"
        case .off: "minus"
        case .notice: "info"
        case .warning: "exclamationmark"
        case .error: "xmark"
        }
    }
}

enum OverallStatus {
    static func title(for state: HealthState) -> String {
        switch state {
        case .ok, .off, .notice: "Everything Is Working"
        case .working: "Starting Up…"
        case .warning: "Needs Attention"
        case .error: "Something Is Wrong"
        }
    }

    static let configuring = "Configuring…"
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
