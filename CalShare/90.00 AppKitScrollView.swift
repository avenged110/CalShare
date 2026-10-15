// MARK: - AppKitScrollView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Unified AppKit-backed NSScrollView utility shared by all scroll view consumers
// in the project: every dashboard page and the setup assistant's steps. Brought over
// from Film Tracker unchanged apart from this paragraph; the notes below that name Film
// Tracker's views describe how it is used there.
//
// Each consumer wraps this view with a thin facade that captures its required
// environment values and constructs the matching ViewModifier — leaving call sites
// completely unchanged and keeping context-specific concerns (sidebar event bus
// broadcasting, environment re-injection) out of the utility layer.
//
// Architecture
// ────────────
//   AppKitScrollView<Content, Modifier: ViewModifier>  ← SwiftUI entry point
//     GeometryReader → AppKitScrollNSView               ← NSViewRepresentable
//       NSScrollView
//         AppKitFlippedContainerView (documentView)
//           NSHostingView<AppKitScrollContentWrapper<Content, Modifier>>
//
// Structural diffing
// ──────────────────
// The content wrapper uses two concrete generic parameters (Content + Modifier) so
// NSHostingView holds a fully typed, stable View value across updateNSView calls,
// letting SwiftUI diff the hosted subtree incrementally instead of tearing it down
// on every update. AnyView for either parameter would forfeit this.
//
// Live-scroll suppression
// ───────────────────────
// rootView replacement is deferred during willStartLiveScroll…didEndLiveScroll
// phases to prevent SwiftUI re-renders from competing with in-flight momentum
// scroll frames — the primary source of scroll jitter in the SwiftUI ScrollView
// model. Pending updates flush immediately when the live-scroll phase ends.
//
// Programmatic scrolling
// ──────────────────────
// AppKitScrollProxy is a plain (deliberately non-@Observable) reference-type
// bridge. Consumers that need scroll-to-anchor (currently the FilmSheet Details
// tab alone) create one proxy per tab, passed to both the scroll view (which
// wires the implementation) and the content view (which calls scroll(to:)).
// Anchor y-offsets are reported upward via ScrollAnchorPreferenceKey, stored in
// the coordinator, and used by scrollToAnchor(_:) to drive the NSScrollView's
// clip view directly. That preference reader is installed only when a proxy was
// supplied (see ScrollAnchorReporter), so the five consumers that pass none do
// not pay to collect a key nothing in their tree writes or reads.
// scrollHandler is (re-)wired from syncCoordinatorState
// whenever the proxy's identity changes, and cleared in dismantleNSView so a
// proxy outliving its scroll view never keeps a closure aimed at a torn-down
// coordinator.
//
// A proxy made with `tracksViewport` also hears the visible rectangle, on every
// scroll and resize, and when live scrolls begin and end, through the
// `viewportHandler` and `liveScrollHandler` its consumer sets — the Imports session
// list mounts only the cards near it, and changes which only when nothing scrolls. Only such a proxy makes the scroll
// view observe its clip view.
//
// Content width
// ─────────────
// The width proposed to the hosted SwiftUI tree is the GeometryReader's measured
// width minus Coordinator.contentWidthInset — the gap between the NSScrollView's
// own width and the clip view's, measured from live AppKit layout (see
// AppKitFlippedContainerView.onWidthChange). It's 0 under the default overlay
// scroller style, and equals the legacy scroller's width under "Show scroll bars:
// Always," where the clip view is genuinely narrower than the GeometryReader's
// measurement. Without the correction, content in that configuration lays out too
// wide (clipped along the trailing edge), and text wrapping at the wrong width can
// measure a document height short of the real one.
//
// isActive / hit-test isolation
// ─────────────────────────────
// When isActive == false, the underlying NSScrollView (a HitTestGatedScrollView;
// see below) has its hitTest(_:) short-circuited to return nil, removing it and
// its AppKit subviews from AppKit's hit-test chain without ever setting isHidden
// — defense in depth alongside FilmSheet's TabEventShield overlay.
//
// isHidden is deliberately avoided, despite also achieving full hit-test exclusion
// (and being the original implementation). Toggling isHidden from true back to
// false — which happens on every tab activation, not just once — makes AppKit
// treat the scroll view as newly appearing, triggering its automatic "flash scroll
// indicators" behavior regardless of whether content actually scrolled. Consumers
// that reactivate the same scroll view repeatedly (RightSidebar's tab plane, every
// tab switch) would flash on every switch instead of only when scrolled content
// hadn't yet faded. A pure hitTest override sidesteps this: the view is never
// hidden or re-shown, so nothing looks "newly visible" — only its interactivity toggles.
//
// onScrollWillStart callback
// ──────────────────────────
// An optional callback fired synchronously at the start of every live-scroll
// phase. SidebarScrollView uses this to broadcast AppEventBus
// .rightSidebarDidStartLiveScroll, letting sidebar-local subscribers (e.g.
// WatchDetails' viewing popover) dismiss themselves before content re-lays out.
// Kept as a callback, not hard-coded, so the utility stays context-free.
//
// Horizontal swipe recognition (moved out of this utility)
// ──────────────────────────────────────────────────────────
// This utility previously included a HorizontalSwipeScrollView subclass
// overriding scrollWheel(with:) to recognize RightSidebar's horizontal
// two-finger tab-navigation swipe, plus a `class func
// isCompatibleWithResponsiveScrolling() -> Bool { true }` meant to keep that
// override eligible for NSScrollView's responsive scrolling path. Neither
// survived scrutiny: the compatibility method is an *instance* method on
// NSClipView, not a class method on NSScrollView, so the declaration never
// overrode anything and did nothing once `override` was removed to make it
// compile; and even with that dead code gone, scrolling remained measurably
// short of a plain NSScrollView's baseline smoothness — the scrollWheel(with:)
// override itself was the remaining cost.
//
// Swipe recognition now lives in a standalone NSEvent local monitor owned by
// RightSidebar (24_00_RightSidebar.swift) — the same pattern the ReleaseCard
// carousel (FSTabReleasesView) uses for its own trackpad-swipe navigation. A
// local monitor intercepts events before AppKit's normal dispatch and can
// consume (return nil) or pass them through (return the event) unchanged; when
// passed through, AppKit dispatches to the NSScrollView exactly as with no
// monitor installed, since the NSScrollView itself is never subclassed. Every
// consumer of this utility, including RightSidebar, now receives a plain,
// unmodified NSScrollView from makeNSView.

import AppKit
import SwiftUI

// MARK: - AppKitScrollProxy

/// Plain reference-type bridge that lets hosted SwiftUI content trigger
/// programmatic scroll-to-anchor operations on the underlying NSScrollView
/// without touching AppKit directly.
///
/// Deliberately NOT `@Observable`. Its single property is pure plumbing — written
/// once by `AppKitScrollNSView` and read only from event callbacks, never from a
/// `View.body`. `@Observable` would buy nothing while costing something real:
/// consumer views hold a proxy as a stored property of a SwiftUI `View` struct
/// (`FSTabDetailsView.scrollProxy`), and `@Observable`'s fine-grained tracking
/// opens a subscription for any observable object reachable that way. A plain
/// `final class` is stored and passed by reference identically, works the same
/// inside `@State`, and keeps those subtrees out of the observation graph entirely.
///
/// Usage pattern:
///   1. Create one proxy per scroll-view instance (e.g. `@State private var proxy = AppKitScrollProxy()`).
///   2. Pass it to `AppKitScrollView(scrollProxy: proxy)` — the scroll view wires the implementation.
///   3. Pass it to the content view — the content view calls `proxy.scroll(to: anchorID)`.
///   4. Content views report anchor y-offsets via `ScrollAnchorPreferenceKey`.
@MainActor
final class AppKitScrollProxy {
    /// Whether the hosted tree publishes `ScrollAnchorPreferenceKey` anchors for
    /// `scroll(to:)`. Only then is the preference reader installed (see
    /// `ScrollAnchorReporter`); a proxy used solely for `holdForAnimatedShrink`
    /// passes false and costs the hosted tree nothing.
    let tracksAnchors: Bool

    /// Whether the scroll view reports its visible rectangle to `viewportHandler`. Only then
    /// does it observe the clip view; every other consumer pays nothing for it.
    let tracksViewport: Bool

    init(tracksAnchors: Bool = true, tracksViewport: Bool = false) {
        self.tracksAnchors = tracksAnchors
        self.tracksViewport = tracksViewport
    }

    /// Set by the CONSUMER (unlike the handlers below, which the scroll view wires) when the
    /// proxy `tracksViewport`. Called with the clip view's bounds — the visible rectangle in
    /// document coordinates, top-left origin — whenever the person scrolls or the viewport is
    /// resized, synchronously, so content can respond within the same frame.
    var viewportHandler: (@MainActor (CGRect) -> Void)?

    /// Set by the consumer, alongside `viewportHandler`: true when a live scroll (a
    /// trackpad gesture, its momentum, a scroller drag) begins, false when it ends.
    var liveScrollHandler: (@MainActor (Bool) -> Void)?

    /// Wired and cleared alongside `scrollHandler`; consumers use `requestViewport`.
    var viewportRequestHandler: (@MainActor () -> Void)?

    /// Calls `viewportHandler` now with the current visible rectangle, if the scroll view is
    /// live and laid out — for a consumer that installs its handler after the first report.
    func requestViewport() {
        viewportRequestHandler?()
    }

    /// Assigned by AppKitScrollNSView once the NSScrollView is live, and cleared
    /// again in dismantleNSView so a torn-down scroll view never leaves a stale
    /// closure behind on a proxy that outlives it.
    /// Calling this directly is an internal implementation detail; consumers use scroll(to:).
    var scrollHandler: (@MainActor (String) -> Void)?

    /// Wired and cleared alongside `scrollHandler`; consumers use `holdForAnimatedShrink`.
    var shrinkHandler: (@MainActor (Double, Double) -> ShrinkAnchor)?

    /// Scrolls the NSScrollView to the named anchor, vertically centering it in
    /// the visible area without animation.
    func scroll(to anchorID: String) {
        scrollHandler?(anchorID)
    }

    /// Call immediately BEFORE a state change that makes the hosted content shorter
    /// under a SwiftUI spring with these parameters (an animated row removal). The
    /// document keeps its current height until the spring has settled.
    ///
    /// Returns where the caller must place its content, in the same update as its
    /// change, within the (held, taller) frame: `anchor.lowering(frameHeight:
    /// contentHeight:)` points below the frame's top. The rows above a removal then
    /// give up whatever the viewport could no longer show beneath the shorter content,
    /// on the caller's own spring, and when the hold is released the offset follows the
    /// content back up so that nothing moves on screen. See "Animated shrink" on the
    /// coordinator. Unwired, the anchor never lowers anything.
    func holdForAnimatedShrink(response: Double, dampingFraction: Double) -> ShrinkAnchor {
        shrinkHandler?(response, dampingFraction) ?? .top
    }

    /// Wired and cleared alongside `scrollHandler`; consumers use `shrinkDidBegin`.
    var shrinkBeganHandler: (@MainActor (CFTimeInterval) -> Void)?

    /// Call from the hosted tree's own update that applies the shrinking change (an
    /// `onChange` of the state the removal mutated). That update is when SwiftUI's
    /// spring begins, so the hold's release is timed from it.
    func shrinkDidBegin() {
        shrinkBeganHandler?(CACurrentMediaTime())
    }
}

// MARK: - ScrollAnchorPreferenceKey

/// Accumulates named scroll-anchor y-offsets reported by child views. The
/// dictionary maps anchor IDs to y-positions in the hosted content's coordinate
/// space so the Coordinator can drive the NSScrollView's clip view directly.
///
/// Child views report their position by measuring with
/// `onGeometryChange(for:of:action:)` (macOS 15) and publishing the stored result:
/// ```swift
/// @State private var anchorOffset: CGFloat?
/// ...
/// .onGeometryChange(for: CGFloat.self) { proxy in
///     proxy.frame(in: .named("filmSheetScrollContent")).minY
/// } action: { anchorOffset = $0 }
/// .preference(
///     key: ScrollAnchorPreferenceKey.self,
///     value: anchorOffset.map { [anchorID: $0] } ?? [:]
/// )
/// ```
/// A background `GeometryReader` measuring into `.preference` directly is the
/// older form and works, but it is a greedy, layout-participating view that adds
/// a node to every pass and re-evaluates its content on every geometry change,
/// including purely horizontal ones. `onGeometryChange` reduces to the single
/// value and fires only when that value moves. Publishing an empty dictionary
/// before the first measurement is deliberate: `reduce` merges it away, so an
/// unmeasured anchor is absent rather than reported at a placeholder zero, which
/// would scroll the clip view to the top of the document.
struct ScrollAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat],
                       nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - AppKitScrollView

/// SwiftUI entry point for the unified AppKit-backed scroll view.
///
/// - Parameters:
///   - modifier: A `ViewModifier` applied inside the hosted wrapper. Use this to
///     re-inject environment values that NSHostingView does not inherit from the
///     enclosing SwiftUI environment (e.g. `DataCoordinator`, `sidebarFilm`). Each
///     consumer context provides its own concrete modifier type, preserving SwiftUI's
///     structural diffing on the hosted content tree.
///   - scrollProxy: Optional programmatic-scroll bridge. Pass `nil` for consumers
///     that never need scroll-to-anchor; doing so also omits the
///     `ScrollAnchorPreferenceKey` reader from the hosted tree entirely.
///   - isActive: When `false`, the underlying NSScrollView's `hitTest(_:)` is
///     short-circuited to return `nil`, removing it from AppKit's hit-test chain
///     without hiding it (see the "isActive / hit-test isolation" note above for
///     why `isHidden` is deliberately not used). Defaults to `true`.
///   - onScrollWillStart: Optional callback fired synchronously at the start of each
///     live-scroll phase. Called on the main actor.
///   - content: The SwiftUI content to host inside the scroll view.
///
/// Concrete consumer facades (`SidebarScrollView`, `FilmSheetScrollView`, etc.) wrap
/// this view, capturing their required environment values and building the appropriate
/// modifier. Direct consumers may also use `AppKitScrollView` with `EmptyModifier` when
/// no environment re-injection is needed.
struct AppKitScrollView<Content: View, Modifier: ViewModifier>: View {

    let modifier: Modifier
    let content: Content
    var scrollProxy: AppKitScrollProxy?
    var isActive: Bool
    var onScrollWillStart: (@MainActor () -> Void)?
    var contentResetKey: AnyHashable?
    /// True for content that is always taller than the viewport, so a legacy ("always
    /// shown") vertical scroller is always tiled beside it. Lets the very first layout
    /// of a fresh scroll view use the narrower width instead of correcting to it
    /// afterward. See `AppKitScrollInitialInset`.
    var alwaysOverflows: Bool

    init(
        modifier: Modifier,
        scrollProxy: AppKitScrollProxy? = nil,
        isActive: Bool = true,
        onScrollWillStart: (@MainActor () -> Void)? = nil,
        contentResetKey: AnyHashable? = nil,
        alwaysOverflows: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.alwaysOverflows = alwaysOverflows
        self.modifier = modifier
        self.scrollProxy = scrollProxy
        self.isActive = isActive
        self.onScrollWillStart = onScrollWillStart
        self.contentResetKey = contentResetKey
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            AppKitScrollNSView(
                availableWidth: geometry.size.width,
                modifier: modifier,
                scrollProxy: scrollProxy,
                isActive: isActive,
                onScrollWillStart: onScrollWillStart,
                contentResetKey: contentResetKey,
                alwaysOverflows: alwaysOverflows,
                revision: AppKitScrollRevision.next(),
                content: content
            )
            // The representable must fill the GeometryReader frame so that
            // SwiftUI passes correct bounds and Auto Layout inside it receives
            // the right clip view dimensions.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - AppKitScrollRevision

/// Stamps each `AppKitScrollNSView` VALUE SwiftUI builds, so `updateNSView` can tell a new
/// value (new content, width, modifier or flags — every one of which reaches the representable
/// only by SwiftUI re-running the GeometryReader closure that builds it) from an update SwiftUI
/// sends for an unchanged value because the surrounding ENVIRONMENT changed.
///
/// The second kind needs no rootView hand-off: a hosted NSHostingView does not inherit the
/// outer SwiftUI environment at all (which is why consumers re-inject what they need through
/// `Modifier`, itself part of the value), so nothing the hosted tree reads has moved. The
/// hand-off is not free — it invalidates the hosting view's intrinsic size, and the next
/// constraint pass re-measures the entire hosted tree. Measured by the `dataviz-measure`
/// harness scenario (99.50): leaving the Data Visualizations tab delivered exactly such an
/// update to the outgoing page, whose full re-measure (~100 ms) then ran in the display
/// cycle's constraint phase, before the layout phase that removed it.
@MainActor
enum AppKitScrollRevision {
    private static var counter = 0
    static func next() -> Int { counter &+= 1; return counter }
}

// MARK: - DampedSpring

/// SwiftUI's `.spring(response:dampingFraction:)` as a damped oscillator — unit mass,
/// stiffness (2π / response)², damping 4π · dampingFraction / response — for the one
/// thing AppKit needs to know about it: how long it runs. Underdamped fractions only
/// (0 < ζ < 1), which is every spring this project uses.
struct DampedSpring {
    let response: Double
    let dampingFraction: Double

    /// When the remaining motion is under 0.1% of the travel for good: the envelope
    /// of the oscillation, not one zero crossing of it.
    var settlingDuration: Double {
        let naturalFrequency = 2 * .pi / response
        let decay = dampingFraction * naturalFrequency
        let dampedFrequency = naturalFrequency * (1 - dampingFraction * dampingFraction).squareRoot()
        return log((1 + decay / dampedFrequency) / 0.001) / decay
    }
}

// MARK: - ShrinkAnchor

/// Where content shorter than a held document sits within it (see
/// `AppKitScrollProxy.holdForAnimatedShrink`): as low as the viewport's eventual
/// offset requires, and no lower.
struct ShrinkAnchor: Equatable {
    /// How far the held document extends below the viewport's bottom edge.
    var slack: CGFloat
    /// The scroll offset when the hold began — as far as the offset can ever come
    /// back, so as far as the content may be lowered.
    var offset: CGFloat

    /// Never lowers anything: plain top alignment.
    static let top = ShrinkAnchor(slack: .infinity, offset: 0)

    /// Points below the frame's top. The document will end `frameHeight −
    /// contentHeight` shorter; whatever of that the slack beneath the viewport cannot
    /// absorb, the offset must give back — up to all of it, but never past zero.
    func lowering(frameHeight: CGFloat, contentHeight: CGFloat) -> CGFloat {
        min(offset, max(0, frameHeight - slack - contentHeight))
    }
}

// MARK: - AppKitScrollInitialInset

/// The content-width inset (see `Coordinator.contentWidthInset`) a fresh scroll view
/// starts with.
///
/// A fresh scroll view cannot measure its inset until AppKit has tiled its scroller,
/// which happens after the hosted content's first layout — and, with an autohiding
/// scroller, only once that content has proven taller than the viewport. When the person
/// has "Show scroll bars" set to "Always", every mount of a tall page was therefore laid
/// out at the full width first and corrected, a scroller's width narrower, a few hundred
/// milliseconds later: a visible squeeze every time the tab was shown. Content that is
/// always taller than the viewport (`alwaysOverflows`) always has the legacy scroller
/// beside it, so it starts with that scroller's width and the first layout is the final
/// one. Everything else starts at 0, as before — its height (and so whether a scroller
/// shows at all) varies, and a wrong guess would squeeze or widen it instead; the width
/// callback corrects either way.
@MainActor
enum AppKitScrollInitialInset {
    static func initialInset(alwaysOverflows: Bool) -> CGFloat {
        guard alwaysOverflows, NSScroller.preferredScrollerStyle == .legacy else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }
}

// MARK: - WeakCoordinatorBox

/// Holds a weak reference to the Coordinator so AppKitScrollContentWrapper (a
/// struct, as required by View) can refer to it without extending its lifetime.
/// Swift does not permit `weak var` as a stored property of a struct — `weak`
/// requires a class-type storage location.
private final class WeakCoordinatorBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T?) { self.value = value }
}

// MARK: - AppKitScrollContentWrapper

/// Typed wrapper placed as the NSHostingView's rootView. Two concrete generic
/// parameters (Content + Modifier) give NSHostingView a fully stable type across
/// updateNSView calls, enabling incremental SwiftUI diffing of the hosted subtree.
///
/// The modifier parameter re-injects environment values that NSHostingView does not
/// inherit from the enclosing SwiftUI environment. `ScrollAnchorReporter` wires
/// ScrollAnchorPreferenceKey updates back to the coordinator via a
/// WeakCoordinatorBox (avoids retaining the coordinator from within the View
/// value type), and installs itself only when `tracksAnchors` is true.
private struct AppKitScrollContentWrapper<Content: View, Modifier: ViewModifier>: View {
    let content: Content
    let availableWidth: CGFloat
    let modifier: Modifier
    /// Whether this scroll view has a proxy, and therefore whether anything can
    /// ever act on a reported anchor. See `ScrollAnchorReporter`.
    let tracksAnchors: Bool
    /// Weak reference to the coordinator so anchor-offset preference callbacks
    /// can update the coordinator without retaining it.
    let coordinatorBox: WeakCoordinatorBox<AppKitScrollNSView<Content, Modifier>.Coordinator>

    var body: some View {
        content
            // Explicit width lets NSHostingView resolve maxWidth: .infinity before
            // Auto Layout runs. Height is never set here — the container/hosting-view
            // bottom constraint chain drives it via Auto Layout.
            .frame(width: availableWidth)
            // Re-inject caller-supplied environment values.
            .modifier(modifier)
            // Collect anchor y-offsets from the hosted tree and forward them to
            // the coordinator for use in scrollToAnchor(_:) — but only for the one
            // consumer that can actually use them.
            .modifier(ScrollAnchorReporter<Content, Modifier>(
                isEnabled: tracksAnchors,
                coordinatorBox: coordinatorBox
            ))
    }

    /// Returns a copy of this wrapper laid out at a different width, reusing the
    /// existing content, modifier, and coordinator box. Used when AppKit reports
    /// a clip-view width that differs from the GeometryReader's measurement, so
    /// the width can be corrected without rebuilding anything else.
    func withAvailableWidth(_ width: CGFloat) -> AppKitScrollContentWrapper {
        AppKitScrollContentWrapper(
            content: content,
            availableWidth: width,
            modifier: modifier,
            tracksAnchors: tracksAnchors,
            coordinatorBox: coordinatorBox
        )
    }
}

// MARK: - ScrollAnchorReporter

/// Installs the `ScrollAnchorPreferenceKey` reader that feeds
/// `Coordinator.anchorOffsets` — and only when the enclosing scroll view was
/// given a proxy, because a reported anchor with no proxy to act on it is a
/// measurement nothing can consume.
///
/// `onPreferenceChange` is not free: it makes SwiftUI collect and propagate that
/// key through every node of the hosted tree on each layout pass, whether or not
/// anything in the tree writes it. Exactly one consumer publishes anchors (the
/// FilmSheet Details tab, for `.openViewingDatesAddPopover`); the other five —
/// including the two longest trees, the Imports session list and the General
/// settings tab — publish none, and now install no reader either.
///
/// `isEnabled` is derived from the proxy's `tracksAnchors` on the representable, so
/// it is fixed for the lifetime of any given call site. The `if` therefore never
/// flips, and the branch it selects never causes a structural rebuild of
/// `content`.
///
/// The generic parameters are deliberately named `C`/`M` rather than
/// `Content`/`Modifier`: `ViewModifier` already supplies an associated type
/// named `Content` for the view being modified, and a generic parameter of that
/// name would shadow it in `body(content:)`.
private struct ScrollAnchorReporter<C: View, M: ViewModifier>: ViewModifier {
    let isEnabled: Bool
    let coordinatorBox: WeakCoordinatorBox<AppKitScrollNSView<C, M>.Coordinator>

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onPreferenceChange(ScrollAnchorPreferenceKey.self) { [coordinatorBox] offsets in
                    Task { @MainActor [coordinatorBox] in
                        coordinatorBox.value?.anchorOffsets = offsets
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - AppKitFlippedContainerView

/// NSView subclass used as the NSScrollView's documentView.
/// isFlipped = true makes y=0 the top-left origin, matching NSClipView's
/// coordinate space and ensuring Auto Layout places content from the top down.
///
/// It also reports its own laid-out width upward. This container is pinned
/// leading/trailing to the clip view, so its width is exactly the width
/// available to hosted content — which is not always the same as the width the
/// SwiftUI `GeometryReader` measures. Under the default overlay scroller style
/// the two are identical, but when the person has System Settings ▸ Appearance ▸
/// "Show scroll bars" set to "Always", NSScrollView tiles a legacy scroller
/// beside the clip view and the clip view is correspondingly narrower. See
/// `Coordinator.contentWidthInset` for how that difference is folded back into
/// the width proposed to the hosted SwiftUI tree.
private final class AppKitFlippedContainerView: NSView {
    override var isFlipped: Bool { true }

    /// Called whenever this view's laid-out width actually changes. Never called
    /// for height-only changes (which happen constantly as content grows), so
    /// this costs nothing on the common path.
    var onWidthChange: (@MainActor (CGFloat) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.size.width
        super.setFrameSize(newSize)
        if widthChanged { onWidthChange?(newSize.width) }
    }
}

// MARK: - HitTestGatedScrollView

/// `NSScrollView` subclass backing every `AppKitScrollView` instance. Implements
/// the `isActive` parameter's hit-test exclusion by overriding `hitTest(_:)`
/// rather than by toggling `isHidden` — see the "isActive / hit-test isolation"
/// note at the top of this file for why: toggling `isHidden` back to `false` on
/// every reactivation makes AppKit treat the view as newly appearing, which
/// triggers an automatic scroll-indicator flash regardless of whether the
/// content was actually scrolled. A pure `hitTest(_:)` override never hides or
/// re-shows the view, so nothing about it looks "newly visible" to AppKit and no
/// flash is triggered — only its participation in hit-testing toggles.
private final class HitTestGatedScrollView: NSScrollView {
    /// Mirrors `AppKitScrollView`'s `isActive` parameter. `true` (the default)
    /// means normal hit-testing; `false` excludes this view and every one of its
    /// subviews (document view, scrollers, and anything hosted inside) from
    /// AppKit's hit-test chain by short-circuiting to `nil` before `super` is
    /// ever consulted.
    var isHitTestActive: Bool = true

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isHitTestActive else { return nil }
        return super.hitTest(point)
    }
}

// MARK: - AppKitScrollNSView

private struct AppKitScrollNSView<Content: View, Modifier: ViewModifier>: NSViewRepresentable {

    let availableWidth: CGFloat
    let modifier: Modifier
    let scrollProxy: AppKitScrollProxy?
    let isActive: Bool
    let onScrollWillStart: (@MainActor () -> Void)?
    /// Opaque token identifying *which* subject the content is showing. When it
    /// changes, the scroll position is returned to the top — see `updateNSView`.
    let contentResetKey: AnyHashable?
    let alwaysOverflows: Bool
    /// See `AppKitScrollRevision`.
    let revision: Int
    let content: Content

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var hostingView: NSHostingView<AppKitScrollContentWrapper<Content, Modifier>>?
        var scrollView: NSScrollView?

        var isLiveScrolling = false

        /// Mirrors the representable's `isActive`. Content updates that arrive while
        /// this is `false` are buffered into `pendingRootView` and applied when the
        /// view becomes active again, for the same reason they are buffered during a
        /// live scroll: assigning `NSHostingView.rootView` makes Auto Layout re-measure
        /// the entire hosted tree, and doing that for a scroll view the person cannot
        /// see is pure cost. It matters most for the tabbed consumers that actually pass
        /// this flag — FilmSheet's three scrollable tabs and RightSidebar's tab plane —
        /// where leaving a tab otherwise re-measured the whole subtree being hidden, on
        /// the very frame it stopped being visible.
        ///
        /// Nothing is lost by deferring: the buffered tree is applied in updateNSView
        /// before the view is shown again, so a reactivated tab is never displayed
        /// with stale content.
        var isActive = true

        var pendingRootView: AppKitScrollContentWrapper<Content, Modifier>?
        var willScrollToken: (any NSObjectProtocol)?
        var didScrollToken:  (any NSObjectProtocol)?
        /// Clip-view bounds and frame observers, installed only for a proxy that
        /// `tracksViewport` (see `observeViewport`).
        var viewportTokens: [any NSObjectProtocol] = []

        /// Live copy of the representable's `onScrollWillStart`. Refreshed on
        /// every updateNSView rather than captured once by the notification
        /// closure, so a consumer whose callback closes over changing state
        /// cannot end up firing a version frozen at makeNSView time.
        var onScrollWillStart: (@MainActor () -> Void)?

        /// The proxy whose `scrollHandler` this coordinator currently owns.
        /// Weak: the proxy is owned by the consumer (typically as `@State`) and
        /// routinely outlives the scroll view.
        weak var wiredProxy: AppKitScrollProxy?

        /// Difference between the NSScrollView's own width and the width actually
        /// available to hosted content, measured from the live AppKit layout.
        /// Zero under the default overlay scroller style; equal to the legacy
        /// scroller's width whenever a legacy scroller is tiled beside the clip
        /// view. Subtracted from the GeometryReader width before it is proposed
        /// to the hosted SwiftUI tree, so content is neither laid out too wide
        /// (clipped on the trailing edge) nor measured at a width that yields a
        /// too-short document height.
        var contentWidthInset: CGFloat = 0

        /// The GeometryReader width most recently passed to makeWrappedContent, before
        /// `contentWidthInset` is subtracted. The deferred width correction recomputes
        /// from this (not from the width its layout callback saw) so a representable
        /// update landing between the two cannot be overwritten with a stale width.
        var measuredWidth: CGFloat = 0

        /// The most recent wrapper built by makeWrappedContent. Kept so a
        /// width correction arriving from AppKit layout (see the container's
        /// `onWidthChange`) can re-emit the current content at the corrected
        /// width without needing to reach back into the representable — and
        /// therefore without storing a closure that would have to be
        /// reallocated on every updateNSView pass.
        var lastWrapper: AppKitScrollContentWrapper<Content, Modifier>?

        /// The `contentResetKey` most recently applied. `nil` until the first update,
        /// so the initial pass never counts as a change and a freshly created scroll
        /// view (already at the top) is not redundantly scrolled.
        var appliedResetKey: AnyHashable?

        /// Anchor name → y-offset in document coordinates.
        /// Populated via ScrollAnchorPreferenceKey updates from the hosted tree.
        var anchorOffsets: [String: CGFloat] = [:]

        /// Stable weak-reference box for this coordinator, allocated once in
        /// makeNSView and reused by every makeWrappedContent call. Avoids
        /// allocating a new heap object on every updateNSView pass.
        lazy var coordinatorBox = WeakCoordinatorBox(self)

        /// The `revision` of the representable value whose content was last handed to the
        /// hosting view (or buffered for it). See `AppKitScrollRevision`.
        var appliedRevision: Int?

        func removeObservers() {
            if let t = willScrollToken { NotificationCenter.default.removeObserver(t) }
            if let t = didScrollToken  { NotificationCenter.default.removeObserver(t) }
            willScrollToken = nil
            didScrollToken  = nil
            viewportTokens.forEach(NotificationCenter.default.removeObserver)
            viewportTokens = []
        }

        /// Reports the visible rectangle to the wired proxy's `viewportHandler` on every scroll
        /// (clip bounds) and resize (clip frame). Both notifications post synchronously on the
        /// main thread, inside the scroll or layout that caused them.
        func observeViewport(of clipView: NSClipView) {
            guard viewportTokens.isEmpty else { return }
            clipView.postsBoundsChangedNotifications = true
            clipView.postsFrameChangedNotifications = true
            viewportTokens = [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: clipView, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportViewport() }
                }
            }
        }

        func reportViewport() {
            guard let clip = scrollView?.contentView, clip.bounds.height > 0 else { return }
            wiredProxy?.viewportHandler?(clip.bounds)
        }

        // The enclosing class is already @MainActor-isolated, so its members
        // inherit that isolation; no per-member annotation is needed.

        /// Whether an update may be handed to the hosting view right now. Both
        /// conditions suppress the same operation — the `rootView` assignment and the
        /// Auto Layout re-measure it forces — so they share one gate.
        private var canApplyRootView: Bool { !isLiveScrolling && isActive }

        func applyRootView(_ view: AppKitScrollContentWrapper<Content, Modifier>) {
            if canApplyRootView {
                hostingView?.rootView = view
                pendingRootView = nil
            } else {
                pendingRootView = view
            }
        }

        /// Applies anything buffered while suppressed, if nothing is suppressing it
        /// any longer. Safe to call unconditionally; a no-op when there is nothing
        /// buffered or when a gate is still closed.
        func flushPendingRootViewIfPossible() {
            guard canApplyRootView, let pending = pendingRootView else { return }
            hostingView?.rootView = pending
            pendingRootView = nil
        }

        func scrollWillStart() {
            isLiveScrolling = true
            onScrollWillStart?()
            if wiredProxy?.tracksViewport == true { wiredProxy?.liveScrollHandler?(true) }
        }

        func scrollDidEnd() {
            isLiveScrolling = false
            flushPendingRootViewIfPossible()
            if wiredProxy?.tracksViewport == true { wiredProxy?.liveScrollHandler?(false) }
        }

        /// Scrolls the NSScrollView so the named anchor is vertically centered in
        /// the visible area, without animation. Matches the disablesAnimations
        /// transaction semantics used in the former ScrollViewReader calls.
        ///
        /// Centring is unconditional: the sole caller (the
        /// `.openViewingDatesAddPopover` command, which then opens a popover on
        /// the row the anchor names) is a deliberate navigation, so it must land
        /// on a predictable position rather than leaving the row wherever it
        /// already happened to sit.
        func scrollToAnchor(_ anchorID: String) {
            guard let sv = scrollView,
                  let yOffset = anchorOffsets[anchorID] else { return }

            let visibleHeight  = sv.contentView.bounds.height
            let documentHeight = sv.documentView?.frame.height ?? 0
            // Center the anchor in the visible area; clamp to valid document range.
            let centered = yOffset - visibleHeight / 2
            let clamped = max(0, min(centered, max(0, documentHeight - visibleHeight)))

            sv.contentView.scroll(to: NSPoint(x: 0, y: clamped))
            sv.reflectScrolledClipView(sv.contentView)
        }

        // MARK: Animated shrink
        //
        // An animated removal inside the hosted tree changes the content's height in
        // ONE step: SwiftUI reports the final (shorter) intrinsic size at once and
        // only the drawing is interpolated, and Auto Layout applies that size to the
        // document at the next layout pass. When the shorter document can no longer
        // reach the current scroll offset (the person is scrolled to, or near, the
        // bottom), NSClipView clamps the offset in that same pass: every row jumps
        // down by the shortfall in a single frame, and a removed row at the bottom is
        // pushed out of the viewport before its fade is ever seen. (Measured with the
        // `imports-removal` harness scenario, 99.54: the jump lands on the first frame
        // after the removal.)
        //
        // The hold answers it with a single clock — SwiftUI's:
        //
        //   1. A required minimum-height constraint keeps the document at its current
        //      height, so nothing clamps, and the caller learns the `slack`: how much
        //      document lies below the viewport.
        //   2. The caller lays its content out within the held frame bottom-anchored
        //      `slack` above the frame's foot (never above its top; see
        //      `holdForAnimatedShrink`), and makes its change. Whatever the shorter
        //      content can no longer fill beneath the viewport, the content gives up at
        //      its TOP instead — the rows above the removal slide down exactly as far
        //      as the scroll offset will have to come back — and all of it moves in the
        //      one SwiftUI spring that also fades and closes the removal.
        //   3. Once that spring has settled, the hold is dropped and the offset shifts
        //      up by the distance the content was lowered, in the same layout pass that
        //      shortens the document and lifts the content back to its top. On screen,
        //      nothing moves.
        //
        // An earlier form scrolled the clip view per display frame on an AppKit copy
        // of the spring. Its motion matched SwiftUI's curve exactly, but its start
        // could only be estimated, and rows that should have stood still drifted by
        // up to 9 px; the single clock removes the question.

        /// Minimum-height constraint on the document view while a shrink is held.
        private var shrinkHold: NSLayoutConstraint?
        /// The document's height and the slack below the viewport when the hold began.
        /// A second removal inside the hold reuses both: the document has not moved,
        /// so the same anchor places the content for the two changes together.
        private var heldHeight: CGFloat = 0
        private var heldAnchor = ShrinkAnchor.top
        private var shrinkSettling: Double = 0.5
        private var shrinkLink: CADisplayLink?
        private var shrinkRequestedAt: CFTimeInterval = 0
        /// When the hold is dropped: the last spring's start plus its settling time.
        /// nil until the hosted tree reports the change applied (`shrinkDidBegin`), or
        /// until the content is seen to have shrunk, whichever comes first.
        private var shrinkReleaseAt: CFTimeInterval?

        func holdForAnimatedShrink(response: Double, dampingFraction: Double) -> ShrinkAnchor {
            guard let sv = scrollView, let document = sv.documentView else { return .top }
            let clip = sv.contentView
            if shrinkHold == nil {
                heldHeight = document.frame.height
                let offset = max(0, clip.bounds.origin.y)
                heldAnchor = ShrinkAnchor(slack: max(0, heldHeight - clip.bounds.height - offset), offset: offset)
                let hold = document.heightAnchor.constraint(greaterThanOrEqualToConstant: heldHeight)
                hold.isActive = true
                shrinkHold = hold
            }
            shrinkSettling = DampedSpring(response: response, dampingFraction: dampingFraction).settlingDuration
            shrinkRequestedAt = CACurrentMediaTime()
            shrinkReleaseAt = nil
            if shrinkLink == nil {
                let link = sv.displayLink(target: self, selector: #selector(shrinkTick(_:)))
                link.add(to: .main, forMode: .common)
                shrinkLink = link
            }
            return heldAnchor
        }

        func shrinkBegan(at time: CFTimeInterval) {
            guard shrinkHold != nil else { return }
            shrinkReleaseAt = time + shrinkSettling
        }

        @objc private func shrinkTick(_ link: CADisplayLink) {
            guard scrollView != nil, let host = hostingView, shrinkHold != nil else {
                endShrinkHold()
                return
            }
            let now = link.timestamp
            if shrinkReleaseAt == nil {
                if host.intrinsicContentSize.height < heldHeight - 0.5 {
                    // The change landed without a `shrinkDidBegin` report.
                    shrinkReleaseAt = now + shrinkSettling
                } else if now - shrinkRequestedAt > 1 {
                    // It never shortened the content; there is nothing to bridge.
                    releaseShrinkHold()
                    return
                }
            }
            // Released only between scroll gestures, and at the latest a little after
            // the longest spring could have run, whatever else happens.
            guard !isLiveScrolling else { return }
            if now - shrinkRequestedAt > shrinkSettling + 2 || (shrinkReleaseAt.map { now >= $0 } ?? false) {
                releaseShrinkHold()
            }
        }

        /// Ends a hold that ran its course. The content sits `lift` below the held
        /// frame's top (see step 2 above); dropping the hold returns it to the top of
        /// a document that much shorter, so the offset moves up by the same amount in
        /// the same pass, and is brought into range if anything else left it past the
        /// end (NSClipView does not always re-clamp on a document shrink).
        private func releaseShrinkHold() {
            guard let sv = scrollView, let document = sv.documentView, let host = hostingView else {
                endShrinkHold()
                return
            }
            let lift = heldAnchor.lowering(frameHeight: heldHeight, contentHeight: host.intrinsicContentSize.height)
            let clip = sv.contentView
            // Read before the release: the layout below may clamp the offset itself.
            let held = clip.bounds.origin.y
            endShrinkHold()
            sv.layoutSubtreeIfNeeded()
            let maxY = max(0, document.frame.height - clip.bounds.height)
            let y = min(max(0, held - lift), maxY)
            if abs(y - clip.bounds.origin.y) > 0.25 {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                sv.reflectScrolledClipView(clip)
            }
        }

        /// Drops the hold and stops the display link. Idempotent.
        func endShrinkHold() {
            shrinkLink?.invalidate()
            shrinkLink = nil
            shrinkHold?.isActive = false
            shrinkHold = nil
            shrinkReleaseAt = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> HitTestGatedScrollView {
        // Every consumer receives a scroll view whose configuration and scrolling
        // behavior are identical to a plain, unmodified NSScrollView — horizontal
        // swipe recognition (RightSidebar) is handled entirely outside this
        // utility via a standalone NSEvent local monitor — see the header
        // comment above and 24_00_RightSidebar.swift — so nothing here can
        // affect scrolling responsiveness for any consumer. The only difference
        // from a plain NSScrollView is the hitTest(_:) override described in the
        // "isActive / hit-test isolation" note above and on HitTestGatedScrollView
        // itself; it changes only click routing, never rendering or scrolling.
        let scrollView = HitTestGatedScrollView()
        scrollView.isHitTestActive = isActive
        configureScrollView(scrollView)

        let container = AppKitFlippedContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layerContentsRedrawPolicy = .onSetNeedsDisplay
        scrollView.documentView = container

        context.coordinator.contentWidthInset = AppKitScrollInitialInset.initialInset(alwaysOverflows: alwaysOverflows)
        let hostingView = NSHostingView(rootView: makeWrappedContent(coordinator: context.coordinator))
        // Intrinsic size only. The default (.standardBounds) also installs min- and
        // max-size constraints, and each is its own full measurement of the hosted tree
        // at a different proposal — every time the constraints are refreshed, i.e. on
        // every rootView hand-off and every width change. Neither constrains anything
        // here: the width is pinned to the clip view by the container, and the height is
        // exactly the content's (see the constraints below). `dataviz-profile` measured
        // the min-size pass alone at a sixth of a resize step and a third of a mount.
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        container.addSubview(hostingView)

        // Hosting view fills container. Leading/trailing fix width; top/bottom
        // let the container grow to the hosting view's intrinsic content height.
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let clipView = scrollView.contentView
        // Container width and top are pinned to the clip view. bottomAnchor is
        // intentionally omitted — height is content-driven via Auto Layout.
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            container.topAnchor.constraint(equalTo: clipView.topAnchor),
        ])

        wire(scrollView: scrollView, container: container, hostingView: hostingView,
             coordinator: context.coordinator)
        // The hosting view was just built from this value's content, so the updateNSView
        // SwiftUI sends next has nothing to hand off.
        context.coordinator.appliedRevision = revision
        return scrollView
    }

    /// Connects the new scroll view to this mount's coordinator: the coordinator's
    /// references, the width-report callback, and the live-scroll observers.
    private func wire(scrollView: HitTestGatedScrollView, container: AppKitFlippedContainerView,
                      hostingView: NSHostingView<AppKitScrollContentWrapper<Content, Modifier>>,
                      coordinator: Coordinator) {
        coordinator.hostingView = hostingView
        coordinator.scrollView  = scrollView
        syncCoordinatorState(coordinator)

        // Fold the real, AppKit-measured content width back into the width this
        // view proposes to its hosted SwiftUI tree. Fires only when the clip
        // view's width actually changes relative to the scroll view's own width
        // — i.e. when a legacy scroller is tiled in or out — so under the default
        // overlay scroller style the inset stays 0 and this never rebuilds
        // anything. See Coordinator.contentWidthInset.
        container.onWidthChange = { [weak coordinator] width in
            guard let coordinator, let sv = coordinator.scrollView else { return }
            // Ignore transient zero-width passes during initial layout: at that
            // point the scroll view may already have its final width while the
            // container has not yet been sized, which would read as a huge bogus
            // inset and lay the content out at (or near) zero width.
            let scrollWidth = sv.bounds.width
            guard width > 0, scrollWidth > 0 else { return }
            let inset = max(0, scrollWidth - width)
            guard abs(inset - coordinator.contentWidthInset) > 0.5 else { return }
            coordinator.contentWidthInset = inset
            // Deferred out of the Auto Layout pass that produced this callback:
            // assigning rootView here would mutate the hosted view tree in the
            // middle of the layout currently sizing it. DispatchQueue.main.async
            // (not Task) keeps this on the same run-loop turn ordering AppKit
            // expects for deferred work originating in a layout callback.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let wrapper = coordinator.lastWrapper else { return }
                    // Recomputed now, exactly as makeWrappedContent would, rather than
                    // taken from `width`: an updateNSView between the layout callback
                    // and this block (a live-resize step, say) has already handed off
                    // content at the newer width, and re-applying the older one would
                    // leave it laid out wrong until the next update. When that update
                    // already carries the corrected width, there is nothing to hand off.
                    let corrected = max(0, coordinator.measuredWidth - coordinator.contentWidthInset)
                    guard corrected != wrapper.availableWidth else { return }
                    let fixed = wrapper.withAvailableWidth(corrected)
                    // Recorded as the latest wrapper, so a second correction before the
                    // next update compares against what was actually handed off.
                    coordinator.lastWrapper = fixed
                    coordinator.applyRootView(fixed)
                }
            }
        }

        // queue: nil makes NotificationCenter invoke the block synchronously on
        // the posting thread, which for NSScrollView's live-scroll notifications
        // is always the main thread. This matters for correctness, not just for
        // the two saved allocations per gesture: the previous form hopped through
        // both OperationQueue.main and a Task, so `isLiveScrolling` did not
        // actually become true until a later run-loop turn — leaving a window at
        // the very start of a scroll in which an updateNSView pass could still
        // push a fresh rootView into the hosting view and compete with in-flight
        // scroll frames, which is precisely what the flag exists to prevent. The
        // same applied in reverse at didEndLiveScroll. MainActor.assumeIsolated
        // is the sanctioned way to enter main-actor isolation synchronously from
        // a callback AppKit already guarantees is on the main thread.
        let willStart = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: nil
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.scrollWillStart() }
        }

        let didEnd = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: nil
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.scrollDidEnd() }
        }

        coordinator.willScrollToken = willStart
        coordinator.didScrollToken  = didEnd

        if scrollProxy?.tracksViewport == true {
            coordinator.observeViewport(of: scrollView.contentView)
        }
    }

    func updateNSView(_ scrollView: HitTestGatedScrollView, context: Context) {
        let coordinator = context.coordinator
        // Keep the live-scroll callback and the wired proxy current. Both are
        // cheap assignments and are deliberately kept outside the isContinuous
        // guard below so neither can go stale mid-animation.
        syncCoordinatorState(coordinator)
        // Gate hit-testing (not visibility) when this tab is not active, removing
        // this view and all its AppKit subviews from AppKit's hit-test traversal
        // entirely. Deliberately not `isHidden`: see the "isActive / hit-test
        // isolation" note above for why toggling `isHidden` back to `false` on
        // every reactivation would trigger an unwanted scroll-indicator flash.
        scrollView.isHitTestActive = isActive
        // Skip rootView replacement during continuous animation transactions.
        //
        // SwiftUI calls updateNSView on every interpolation frame of a running
        // animation (spring, easeIn/Out, etc.) as well as on genuine content
        // changes. Each call that reaches hostingView.rootView = ... forces Auto
        // Layout to re-measure all hosted SwiftUI content from scratch, outside
        // SwiftUI's animation transaction. For content that contains in-flight
        // SwiftUI animations (e.g. a card collapsing in ImportsView), this causes
        // sibling views to be re-laid out at each frame — producing visible size
        // fluctuations (e.g. bottom-padding shrink/expand) on cards that are not
        // themselves animating.
        //
        // context.transaction.isContinuous is true on every interpolation frame
        // and false on the discrete update that committed the state change. We
        // apply rootView only on non-continuous updates; the animation already
        // running inside NSHostingView's own SwiftUI render loop is unaffected.
        //
        // The isHitTestActive assignment above is intentionally kept outside this
        // guard — it is a cheap assignment that must remain current regardless of
        // animation state.
        guard !context.transaction.isContinuous else {
            // Taking the early return does not mean nothing needs applying. This view
            // may have just become active again while carrying content buffered from
            // the period it was hidden, and returning outright would leave a
            // now-visible tab showing what it held before. Flushing costs one rootView
            // assignment only when something is genuinely outstanding — and only when
            // both gates are open — so at-rest continuous frames remain free.
            coordinator.flushPendingRootViewIfPossible()
            return
        }
        // Hand off a refreshed content tree (suppressed during live scroll, and while
        // this view is inactive — see Coordinator.isActive). The fresh tree supersedes
        // anything buffered, so no separate flush is needed on this path.
        //
        // Only for a NEW value, though: an update for the value already handed off comes
        // from an environment change the hosted tree cannot see, and re-handing it would
        // only re-measure the whole tree for nothing (see AppKitScrollRevision). Anything
        // still buffered from a suppressed hand-off is flushed instead.
        if coordinator.appliedRevision != revision {
            coordinator.appliedRevision = revision
            coordinator.applyRootView(makeWrappedContent(coordinator: coordinator))
        } else {
            coordinator.flushPendingRootViewIfPossible()
        }

        // Return to the top when the content's *subject* changes (a different film in
        // the right sidebar, say) rather than merely its values. Without this, reusing
        // one scroll view for successive subjects — which is the whole point of not
        // giving the hosted content a new SwiftUI identity per subject — would leave
        // the new subject scrolled to wherever the previous one happened to sit.
        //
        // Deliberately keyed on an explicit token rather than inferred from the content:
        // only the consumer knows which changes are a new subject and which are an
        // in-place edit of the current one. Consumers that pass no key (the default)
        // keep the previous behavior exactly — the scroll position is never touched.
        //
        // Ordered after the rootView hand-off so the offset applies to the new content,
        // and skipped on the first update (`appliedResetKey` starts nil) because a
        // freshly made scroll view is already at the top.
        if let key = contentResetKey, coordinator.appliedResetKey != key {
            let isFirstApplication = coordinator.appliedResetKey == nil
            coordinator.appliedResetKey = key
            if !isFirstApplication {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    static func dismantleNSView(_ scrollView: HitTestGatedScrollView, coordinator: Coordinator) {
        coordinator.removeObservers()
        // Drop the width-report callback before anything else: it is the one
        // path that could still fire from an AppKit layout pass after teardown.
        (scrollView.documentView as? AppKitFlippedContainerView)?.onWidthChange = nil
        // Unwire the proxy so a proxy that outlives this scroll view (they are
        // typically @State on the consumer and do) is not left holding a closure
        // pointing at a torn-down coordinator.
        coordinator.wiredProxy?.scrollHandler = nil
        coordinator.wiredProxy?.shrinkHandler = nil
        coordinator.wiredProxy?.shrinkBeganHandler = nil
        coordinator.wiredProxy?.viewportRequestHandler = nil
        coordinator.wiredProxy = nil
        coordinator.endShrinkHold()
        // Release strong references so the hosting view's SwiftUI subtree and
        // the scroll view's AppKit hierarchy are both eligible for deallocation.
        // pendingRootView is cleared first in case dismantleNSView fires while an
        // update is buffered — during a live scroll, or while this view is inactive
        // (applyRootView defers in both cases).
        coordinator.pendingRootView    = nil
        coordinator.lastWrapper        = nil
        coordinator.onScrollWillStart  = nil
        coordinator.anchorOffsets      = [:]
        coordinator.hostingView        = nil
        coordinator.scrollView         = nil
        // Leave the window NOW rather than when SwiftUI removes this view's host, which it
        // does in the display cycle's LAYOUT phase — after the CONSTRAINT phase. In between,
        // the constraint pass still reaches the hosting view, whose graph has been reset by
        // this teardown, and asks it for its intrinsic size: a full rebuild and measurement of
        // the entire hosted tree for a view about to be discarded. Measured by the
        // `dataviz-measure` harness scenario (99.50): ~110–125 ms of every exit from the Data
        // Visualizations tab. Removing an already-removed view is a no-op, so SwiftUI's own
        // removal of the host afterward is unaffected.
        scrollView.removeFromSuperview()
    }

    // MARK: - Helpers

    /// Refreshes the coordinator state that mirrors a value carried on this
    /// (value-type) representable. Called from both makeNSView and updateNSView
    /// so neither the live-scroll callback nor the wired proxy is frozen at
    /// creation time. Both are plain assignments — no allocation per pass.
    @MainActor
    private func syncCoordinatorState(_ coordinator: Coordinator) {
        coordinator.onScrollWillStart = onScrollWillStart
        // Kept in step with the representable so applyRootView can suppress work for a
        // scroll view that is currently hidden. See Coordinator.isActive.
        coordinator.isActive = isActive

        // Re-wire only when the proxy identity actually changes. In practice each
        // consumer passes a stable @State proxy, so this is a single reference
        // comparison per update; handling the change case keeps a swapped proxy
        // from silently pointing at nothing.
        if coordinator.wiredProxy !== scrollProxy {
            coordinator.wiredProxy?.scrollHandler = nil
            coordinator.wiredProxy?.shrinkHandler = nil
            coordinator.wiredProxy?.shrinkBeganHandler = nil
            coordinator.wiredProxy?.viewportRequestHandler = nil
            coordinator.wiredProxy = scrollProxy
            scrollProxy?.scrollHandler = { [weak coordinator] anchorID in
                coordinator?.scrollToAnchor(anchorID)
            }
            scrollProxy?.shrinkHandler = { [weak coordinator] response, dampingFraction in
                coordinator?.holdForAnimatedShrink(response: response, dampingFraction: dampingFraction) ?? .top
            }
            scrollProxy?.shrinkBeganHandler = { [weak coordinator] time in
                coordinator?.shrinkBegan(at: time)
            }
            scrollProxy?.viewportRequestHandler = { [weak coordinator] in
                coordinator?.reportViewport()
            }
        }
    }

    @MainActor
    private func makeWrappedContent(
        coordinator: Coordinator
    ) -> AppKitScrollContentWrapper<Content, Modifier> {
        let wrapper = AppKitScrollContentWrapper(
            content: content,
            // GeometryReader measures the NSScrollView; the hosted tree is laid
            // out inside the clip view. Subtracting the measured inset makes the
            // two agree even when a legacy scroller is tiled beside the clip
            // view. The inset is 0 under the default overlay scroller style, so
            // this is the identity operation in the common case.
            availableWidth: max(0, availableWidth - coordinator.contentWidthInset),
            modifier: modifier,
            // Only a consumer that supplied a proxy can act on a reported anchor,
            // so only that consumer pays for the preference reader that collects
            // them. See ScrollAnchorReporter.
            tracksAnchors: scrollProxy?.tracksAnchors == true,
            coordinatorBox: coordinator.coordinatorBox
        )
        coordinator.measuredWidth = availableWidth
        coordinator.lastWrapper = wrapper
        return wrapper
    }

    @MainActor
    private func configureScrollView(_ scrollView: NSScrollView) {
        scrollView.hasVerticalScroller        = true
        scrollView.hasHorizontalScroller      = false
        scrollView.autohidesScrollers         = true
        scrollView.borderType                 = .noBorder
        scrollView.drawsBackground            = false
        scrollView.verticalScrollElasticity   = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.wantsLayer                 = true
        scrollView.layerContentsRedrawPolicy  = .onSetNeedsDisplay
        // None of this project's AppKitScrollView consumers are the window's
        // direct content view under a titlebar, so automatic safe-area-driven
        // content insets never apply in practice — only the recomputation on
        // every layout pass is being skipped here, not any inset the person
        // would actually see. (Bottom-inset headroom for the StatusBar overlay,
        // where it's needed, is handled separately by each tab's own SwiftUI
        // .safeAreaInset — an independent mechanism from NSScrollView's own
        // contentInsets — so this does not conflict with it.)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
    }
}
