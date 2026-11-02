// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
internal import UbiquittyCore
package import UbiquittyRenderKit

/// A program's status symbol in a window's title: the symbol, and the ink it
/// wears (nil wears the status text's own).
package struct TitleStatusSymbol: Equatable {
    package let name: String
    package let ink: NSColor?

    package init(name: String, ink: NSColor?) {
        self.name = name
        self.ink = ink
    }
}

/// Reproduces the unified-toolbar document-proxy rollover in titlebar styles
/// where AppKit does not provide it. The document-proxy state machine uses a
/// 0.25-second reveal hysteresis, then animates the actual titlebar layout for
/// 0.3 seconds with Core Animation's default timing function.
@objc(ProxyIconRevealController)
@MainActor
public final class ProxyIconRevealController: NSObject {
    private enum Policy {
        static let dwellInterval: TimeInterval = 0.25
        /// Ubiquitty holds the revealed icon for the same interval it waited to
        /// show it, so a pointer that clips the title on its way elsewhere does
        /// not start a retreat. AppKit retreats on the first outside event and
        /// buys its forgiveness entirely from the widened sensitive rect.
        static let retreatDwellInterval: TimeInterval = 0.25
        static let transitionDuration: CFTimeInterval = 0.3
        static var timingFunction: CAMediaTimingFunction {
            CAMediaTimingFunction(name: .default)
        }
    }

    /// AppKit keeps the document-actions arrow independent from the document
    /// proxy. Its delayed exit is cancellable; the identity control owns the
    /// chevron's fade on the flight's own 0.3-second default curve.
    private enum TrailingStatusPolicy {
        static let exitDwellInterval: TimeInterval = 0.25
    }

    /// Kern producing equal ink gaps on both sides of the titlebar em dash.
    /// AppKit's own gaps measure unequal — 5.81 pt before, 8.08 pt after at
    /// 13 pt (textedit-chevron/titlebar-gap-metrics.log) — an artefact of its
    /// field padding, not a design worth copying. The two kerns differ
    /// because each rides on its own side's glyph bearings.
    private enum SeparatorGap {
        static let before: CGFloat = 5.9
        static let after: CGFloat = 5.6
    }

    /// A layout gap separates machine identity from the content title without a text connector.
    private static let hostIdentityGap: CGFloat = 10

    /// Whether Core supplied the host as a fallback, already named by the indicator.
    package var isHostFallbackTitle = false

    /// The trailing bell's own metrics.
    ///
    /// The gap is the chevron's, not the separator's: the bell stands where
    /// the chevron does, and the live TextEdit rollover leaves about four
    /// points of air between the last glyph and the arrow. The size is a
    /// point under the title's, which is what makes a filled glyph read as the
    /// same weight as the text rather than heavier than it.
    private enum BellRunPolicy {
        static let gapBeforeGlyph: CGFloat = 4
        static let pointSizeBelowTitle: CGFloat = 1
    }

    /// How the title text's colours follow the rollover when a highlight is
    /// on: the chevron's own length and curve, driven by restyling the string
    /// — there is exactly one rendering of the title at every instant. Two
    /// stacked copies crossfaded would carry extra ink on composited
    /// antialiased edges and never converge to the single-draw endpoint.
    private enum TitleHoverPolicy {
        static let duration: CFTimeInterval = 0.3
        static let frameInterval: TimeInterval = 1.0 / 120
    }

    private enum FlightKey {
        static let fade = "ub-folder-icon-fade"
        static let iconPosition = "ub-folder-icon-slide"
        static let titlePosition = "ub-folder-title-shift"
        static let actionsPosition = "ub-folder-actions-slide"
        static var all: [String] {
            [fade, iconPosition, titlePosition, actionsPosition]
        }
    }

    private enum Phase {
        case hidden
        case dwelling
        case revealing
        case revealed
        case retreating

        var ownsSlot: Bool {
            switch self {
            case .revealing, .revealed, .retreating:
                return true
            case .hidden, .dwelling:
                return false
            }
        }
    }

    /// Everything `applyStoredTitleStyle` reads. Equal keys produce an
    /// identical field, so the rebuild can be skipped.
    private struct StyleKey: Equatable {
        let title: String
        let statusTitle: String
        let programStatus: String
        let programStatusSymbol: TitleStatusSymbol?
        let processIconKey: String
        let dimColor: NSColor
        let brightColor: NSColor
        let detailColor: NSColor
        let hoverSignature: String
        let fieldWidth: CGFloat
        let fieldHeight: CGFloat
        let titleFont: NSFont
        let directorySegment: String
        let prefixBeforeDirectory: String
        let markerSignature: String
        let tagStyle: TitlebarTagStyle
        let appearanceName: NSAppearance.Name
        let connectionSize: NSSize
        let connectionDescription: String
        let isTuckedUnderHostChip: Bool
        let bellSignature: String
        /// The title's pixels per point: the status symbol stands a whole
        /// number of them off the baseline.
        let backingScale: CGFloat
    }

    /// Measures the AppKit attachments and text that the title field draws.
    @MainActor
    private struct TitleTextLayout {
        private let storage: NSTextStorage
        private let manager = NSLayoutManager()
        private let container: NSTextContainer

        init(_ field: NSTextField) {
            let measuredStorage = NSTextStorage(attributedString: field.attributedStringValue)
            let fullRange = NSRange(location: 0, length: measuredStorage.length)
            measuredStorage.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                if value == nil {
                    measuredStorage.addAttribute(.font, value: field.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize), range: range)
                }
            }
            storage = measuredStorage
            let natural = field.cell?.cellSize ?? field.bounds.size
            container = NSTextContainer(
                size: NSSize(width: max(natural.width, field.bounds.width), height: max(natural.height, field.bounds.height))
            )
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 1
            container.lineBreakMode = .byClipping
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
        }

        func bounds(for range: NSRange) -> NSRect {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            // The borderless title cell reserves two points before its text.
            return manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: 2, dy: 0)
        }
    }

    private struct SessionFrames {
        let restingTitleInStrip: NSRect
        let titledTitleInStrip: NSRect

        var horizontalTranslation: CGFloat {
            restingTitleInStrip.midX - titledTitleInStrip.midX
        }
    }

    @objc
    weak var window: NSWindow?

    @objc
    public var alwaysVisible = false {
        didSet {
            promoteIfAlwaysVisible()
        }
    }

    /// How the identity icon enters and leaves during the 0.3-second flight.
    /// Slide moves it through a clipped edge fixed at its resting leading
    /// boundary, symmetric both ways; fade crossfades it while it moves.
    /// Neither changes rollover timing or title geometry.
    @objc(FolderIconIdentityTransition)
    public enum IdentityTransition: Int {
        case slide
        case fade
    }

    @objc
    public var identityTransition: IdentityTransition = .slide

    private var shouldAnimateIdentityOpacity: Bool { identityTransition == .fade }

    @objc
    public var requestSlotResolution: (() -> Void)?

    /// The label a program gave its status colour (OSC 21337), shown as the
    /// title row's last component; empty for none.
    ///
    /// Its own component rather than more text in the dimensions run: it has
    /// its own span, so in the component scope it lifts and answers the pointer
    /// on its own, and it goes when its composition switch is off without
    /// taking the dimensions with it.
    @objc
    public var programStatusTitle = "" {
        didSet {
            guard programStatusTitle != oldValue else { return }
            applyStoredTitleStyle()
            layoutDocumentActions()
        }
    }

    /// The symbol a program's status record shows before what the program
    /// says it is doing, after the title's arrow; nil for no record, where
    /// any status text is the program's own.
    package var programStatusSymbol: TitleStatusSymbol? {
        didSet {
            guard programStatusSymbol != oldValue else { return }
            applyStoredTitleStyle()
            layoutDocumentActions()
        }
    }

    /// The ground the title row is drawn on, which decides whether a process
    /// icon in its owner's colours needs a plate.
    var processIconGround = NSColor.windowBackgroundColor

    /// The program the title's pane runs, whose icon stands before the
    /// program's name; empty for none.
    var processIconKey = "" {
        didSet {
            guard processIconKey != oldValue else { return }
            applyStoredTitleStyle()
            layoutDocumentActions()
        }
    }

    /// The whole of what a program's status record says, which the title's
    /// spoken label reads for the status, whether or not its symbol shows.
    var programStatusSpokenText = "" {
        didSet {
            guard programStatusSpokenText != oldValue else { return }
            applyStoredTitleStyle()
        }
    }

    /// Whether a bell rang in this window with the reader somewhere else.
    ///
    /// The title's answer to a tab's accessory mark. A window with no strip
    /// has no accessory slot on screen at all, so the bell it caught would
    /// have nowhere to be found; it goes at the trailing end of the title
    /// instead, where the chevron sits when the row is hovered.
    @objc
    public var hasUnheardBell = false {
        didSet {
            guard hasUnheardBell != oldValue else { return }
            applyStoredTitleStyle()
        }
    }

    /// The colour a program asked this session to wear (OSC 21337), which the
    /// bell is drawn in; nil for a bell in the title's own ink.
    @objc
    public var bellStatusColor: NSColor? {
        didSet {
            guard hasUnheardBell, bellStatusColor != oldValue else { return }
            applyStoredTitleStyle()
        }
    }

    /// What the trailing bell is currently built from, for the restyle gate.
    /// The colour is spelled out rather than held as a colour, because the
    /// key is compared and two equal colours from different spaces are not.
    private var bellSignature: String {
        guard hasUnheardBell else { return "" }
        return bellStatusColor.map { "coloured:\($0.description)" } ?? "plain"
    }

    /// The composed title's spans, refreshed by every restyle.
    private var identitySpans: [TitleIdentitySpan] = []

    /// The live host identity occupies the title's prefix after the tag markers.
    ///
    /// The chip draws its tag's icon with the same drawing the markers use,
    /// which is this module's: the render kit the chip lives in cannot reach
    /// the app's icon fonts.
    package var connectionIndicator: RemoteConnectionIndicator? {
        didSet {
            guard oldValue !== connectionIndicator else { return }
            oldValue?.presentationDidChange = nil
            oldValue?.removeFromSuperview()
            connectionIndicator?.tagIconDrawing = PhosphorIcons.image(named:weight:side:color:)
            connectionIndicator?.presentationDidChange = { [weak self] in
                guard let self, !self.isApplyingTitleLayout else { return }
                self.lastAppliedStyle = nil
                self.layoutDocumentActions()
            }
            lastAppliedStyle = nil
            layoutDocumentActions()
        }
    }

    /// Whether a click on the title row is one control or per span.
    var titleActivationScope: TitleActivationScope = .wholeTitle {
        didSet {
            documentActions.activationScope = titleActivationScope
        }
    }

    /// What the rollover shows over the title identity.
    var titleHoverStyle = TitleHoverStyle() {
        didSet {
            documentActions.hoverStyle = titleHoverStyle
        }
    }

    /// The rollover's chosen clocks: a shorter rest before the reveal than
    /// AppKit's 0.25 seconds; the exit keeps the entry's own pace, with the
    /// shortened and instant styles available as options.
    var revealTiming = TitleRevealTiming(revealDwell: .quick) {
        didSet {
            documentActions.chevronExitDuration = exitFlightDuration
        }
    }

    /// The retreat flight's length under the chosen exit style.
    private var exitFlightDuration: CFTimeInterval {
        switch revealTiming.exitStyle {
        case .matched:
            return Policy.transitionDuration
        case .fast:
            return revealTiming.fastExitDuration
        case .instant:
            return 0
        }
    }

    private var phase: Phase = .hidden
    /// Where a left press landed on the title while the row was still the
    /// native frame's, in window coordinates. A release within the click
    /// slop of it, with the window unmoved, is a click on the title — and a
    /// click opens the popover whatever the reveal was doing.
    private var titlePressInWindow: NSPoint?
    private var titleMouseDownEvent: NSEvent?
    /// Whether the next landing presents the popover: a click asked for it
    /// while the reveal was still to fly.
    private var shouldPresentPopoverOnLanding = false
    /// How far a press may travel and still be a click rather than a drag.
    private static let clickSlop: CGFloat = 4
    private var dwellTimer: Timer?
    private var retreatDwellTimer: Timer?
    private var trackingArea: NSTrackingArea?
    private weak var trackedStrip: NSView?
    private let hoverOwner = TitleStripHoverOwner()
    private let documentActions = TitlebarDocumentActionsController()
    private var sessionFrames: SessionFrames?
    private var sessionURL: URL?
    /// The separator the drawn title row is woven with, spelled by Core.
    /// The window server receives Core's spaced title; the row keeps the bare
    /// form because its text layout provides the visible gaps.
    ///
    /// Computed rather than stored: a stored property initialised from a C++
    /// interop call gives the type checker nothing to anchor on, and every
    /// expression built from it loses its type too — which surfaces far below
    /// as `.font` and `.foregroundColor` becoming unresolvable.
    static var windowTitleSeparator: String {
        String(Ubiquitty.Title.titleSeparatorText(Ubiquitty.PAL.Process.TitleSeparator.Bare))
    }

    /// The row's text, separately from the title supplied to system menus.
    var rowTitleText: String?

    /// What a program's status follows: the process chain's own arrow.
    static var statusArrow: String {
        String(Ubiquitty.Title.chainArrowText())
    }

    private var titleDirectorySegment = ""
    private var titlePrefixBeforeDirectory = ""
    private var titleDimColor: NSColor?
    private var titleBrightColor: NSColor?
    private var titleDetailColor: NSColor?
    private var trailingStatusIsHovered = false
    private var tagMarkers: [TitlebarTagMarker] = []
    /// The wash a loud tag put on the title bar, so the title and that tag's own
    /// chip can be coloured to read against it.
    private var titlebarTint: NSColor?
    /// How the row lays the markers' colours down.
    private var tagStyle = TitlebarTagStyle.fullStrength
    private var lastAppliedStyle: StyleKey?
    private var trailingStatusExitTimer: Timer?
    private weak var observedTitleField: NSTextField?
    private weak var observedTitleHost: NSView?
    private var titleObservation: NSKeyValueObservation?
    /// The window's edited mark and appearance, either of which changes how the
    /// proxy has to be restored; see ``refreshSolidProxy()``.
    private var documentEditedObservation: NSKeyValueObservation?
    private var appearanceObservation: NSKeyValueObservation?
    /// A full-strength copy of the folder, laid on the proxy's own layer while
    /// the window is marked edited.
    private let solidProxy: CALayer = {
        let layer = CALayer()
        layer.name = "ub-proxy-solid"
        layer.contentsGravity = .resize
        return layer
    }()
    /// What ``solidProxy`` was last drawn from, so a refresh that finds the
    /// same folder, size, scale and appearance keeps the image it has.
    private var solidProxyContentsKey: String?
    /// Confined to the main thread in practice — installed in init, removed
    /// in deinit, both of which run there — but a nonisolated deinit cannot
    /// prove that to the compiler.
    private nonisolated(unsafe) var pressMonitor: Any?
    private var isApplyingTitleLayout = false

    /// One span kind's hover lift in flight.
    private struct SpanHoverFlight {
        let start: CGFloat
        let target: CGFloat
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
    }

    /// How lifted each span kind's colour is, 0 at rest through 1 hovered.
    private var spanHoverFractions: [TitleIdentitySpan.Kind: CGFloat] = [:]
    private var spanHoverFlights: [TitleIdentitySpan.Kind: SpanHoverFlight] = [:]
    private var hoverAnimationTimer: Timer?

    /// The identity de-emphasises in two steps: the directory reads medium at
    /// the title's own size, one under the semibold process name, and the
    /// dimensions wear the chosen `TitleStatusFace`. The em dashes stay in
    /// the title's face, so every dash on the line is one weight.
    private static let directoryFont = NSFont.systemFont(
        ofSize: NSFont.systemFontSize,
        weight: .medium
    )

    /// The dimensions run's chosen face: medium, a point under the title.
    package var statusFace = TitleStatusFace(size: .smaller) {
        didSet {
            lastAppliedStyle = nil
            applyStoredTitleStyle()
            layoutDocumentActions()
        }
    }

    private var statusFont: NSFont {
        NSFont.systemFont(ofSize: ChromeTypography.scaled(statusFace.size.pointSize), weight: statusFace.weight)
    }

    /// The pixels per point the title is drawn at.
    private var titleBackingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    private var ownsSlot: Bool { phase.ownsSlot || alwaysVisible }

    /// The TextEdit-style document-actions control. Its owner remains this
    /// rollover controller so its lifetime and animation cannot drift from the
    /// represented-document button.
    @objc
    public var documentActionsController: TitlebarDocumentActionsController {
        documentActions
    }

    @objc(adjustedResolutionWithProposed:)
    public func adjustedResolution(for proposed: URL?) -> URL? {
        if let proposed {
            sessionURL = proposed
        } else if !ownsSlot {
            sessionURL = nil
        }
        guard ownsSlot else {
            return nil
        }
        return sessionURL
    }

    /// The directory last proposed through ``resolveRepresentedDirectory``,
    /// so a proposal that has not moved asks nothing of the title bar.
    private var lastProposedDirectoryURL: URL?

    /// Stands the folder proxy on a directory, or takes it down, and writes
    /// the window's `representedURL` only when the answer moved.
    ///
    /// The one place both shells hand AppKit a represented URL. Assigning it
    /// re-tiles the title bar whether or not the value changed — the title
    /// field is rebuilt, its frame notification fires, and the identity row
    /// lays itself out again, measuring the title through CoreText. A shell
    /// that resolved on every drain paid that for a spinner glyph in the
    /// title; here an unchanged proposal on an unchanged row is a comparison.
    ///
    /// - Parameters:
    ///   - proposed: The directory the title was woven from, nil for none.
    ///   - alwaysVisible: Whether the proxy stands permanently — the reader's
    ///     `folder_icon_always`, or the system's titlebar-icons switch.
    @objc(resolveRepresentedDirectory:alwaysVisible:)
    public func resolveRepresentedDirectory(_ proposed: URL?, alwaysVisible: Bool) {
        let didVisibilityMove = self.alwaysVisible != alwaysVisible
        self.alwaysVisible = alwaysVisible
        let resolved = adjustedResolution(for: proposed)
        guard let window else { return }
        let didURLMove = window.representedURL != resolved
        if didURLMove {
            window.representedURL = resolved
        }
        guard didURLMove || didVisibilityMove || proposed != lastProposedDirectoryURL else {
            return
        }
        lastProposedDirectoryURL = proposed
        validateAfterURLChange()
    }

    @objc
    public func invalidateSession() {
        titlePressInWindow = nil
        titleMouseDownEvent = nil
        cancelDwellTimer()
        cancelRetreatDwellTimer()
        cancelTrailingStatusExitTimer()
        clearFlightAnimations()
        setTrailingStatusHovered(false, animated: false)
        sessionFrames = nil
        sessionURL = nil
        lastProposedDirectoryURL = nil
        phase = .hidden
        if window?.representedURL != nil {
            window?.representedURL = nil
        }
        layoutDocumentActions()
    }

    /// Replaces the tag markers drawn before the title.
    ///
    /// - Parameters:
    ///   - markers: The window's resolved tags, in order.
    ///   - tint: The wash a loud tag lays over the row, nil for none.
    ///   - style: How the row lays the markers' colours down; nil keeps the
    ///     one the row has.
    func setTagMarkers(_ markers: [TitlebarTagMarker], titlebarTint tint: NSColor?, style: TitlebarTagStyle? = nil) {
        tagMarkers = markers
        titlebarTint = tint
        if let style {
            tagStyle = style
        }
        lastAppliedStyle = nil
        applyStoredTitleStyle()
        layoutDocumentActions()
    }

    /// Restyles the markers for a row whose ground or tag strength moved,
    /// and leaves a row whose style is the same alone.
    ///
    /// - Parameter style: How the row lays the markers' colours down.
    package func setTagStyle(_ style: TitlebarTagStyle) {
        guard style != tagStyle else { return }
        tagStyle = style
        applyStoredTitleStyle()
        layoutDocumentActions()
    }

    /// Receives titlebar tags from the Objective-C window controller.
    ///
    /// The public Objective-C seam carries Foundation objects so framework consumers
    /// do not import the renderer's internal marker representation.
    ///
    /// - Parameters:
    ///   - objects: Resolved titlebar marker objects, in order.
    ///   - tint: The optional titlebar tint.
    @objc(setTagMarkers:titlebarTint:)
    public func setTagMarkerObjects(_ objects: [NSObject], titlebarTint tint: NSColor?) {
        setTagMarkers(objects.compactMap { $0 as? TitlebarTagMarker }, titlebarTint: tint)
    }

    @objc
    public func chromeDidChange() {
        reinstallTrackingIfNeeded()
        stampRestingLookIfIdle()
        applyStoredTitleStyle()
        layoutDocumentActions()
    }

    @objc
    public func validateAfterURLChange() {
        promoteIfAlwaysVisible()
        stampRestingLookIfIdle()
        applyStoredTitleStyle()
        layoutDocumentActions()
    }

    /// Styles the window title's runs.
    ///
    /// Takes the [title] base TEXT rather than a prefix the caller has already
    /// joined: what stands between that text and the directory is the
    /// separator, and the separator is Core's. An arm that appends the
    /// character itself agrees with the weave only while the window title is
    /// woven bare, and dims nothing at all once it is woven spaced. The tab
    /// label asks Core the same question through `joinedLeadingPartLength`.
    ///
    /// - Parameters:
    ///   - directorySegment: The working-directory run to recede.
    ///   - baseTitleBeforeDirectory: The [title] base text preceding it, empty
    ///     when the directory leads the line.
    ///   - trailingRegularSegment: The status readout that follows the title.
    ///   - dimColor: The ink for a receded run.
    ///   - brightColor: The ink for the rest of the line.
    @objc(applyTitleStyleWithDirectorySegment:baseTitleBeforeDirectory:trailingRegularSegment:dimColor:brightColor:detailColor:)
    public func applyTitleStyle(
        directorySegment: String,
        baseTitleBeforeDirectory: String,
        trailingRegularSegment: String,
        dimColor: NSColor,
        brightColor: NSColor,
        detailColor: NSColor
    ) {
        titleDetailColor = detailColor
        titleDirectorySegment = directorySegment
        titlePrefixBeforeDirectory =
            baseTitleBeforeDirectory.isEmpty
            ? ""
            : baseTitleBeforeDirectory + Self.windowTitleSeparator
        documentActions.statusTitle = trailingRegularSegment
        titleDimColor = dimColor
        titleBrightColor = brightColor
        applyStoredTitleStyle()
        layoutDocumentActions()
    }

    @objc
    public init(window: NSWindow) {
        self.window = window
        super.init()
        hoverOwner.controller = self
        // AppKit answers a title change by BUILDING A NEW title field, so the
        // frame observation on the old one dies with it and the fresh field
        // stacks above the identity control — the text stops taking clicks.
        // The window's title is the one signal that survives the swap; the
        // relayout is deferred a turn because the field is built lazily.
        titleObservation = window.observe(\.title) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.layoutDocumentActions()
                    self?.reinstallTrackingIfNeeded()
                }
            }
        }
        documentEditedObservation = window.observe(\.isDocumentEdited) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refreshSolidProxy() }
            }
        }
        appearanceObservation = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.refreshSolidProxy()
                    // A marker's ink is chosen against the row's ground,
                    // which a system colour resolves under this appearance.
                    self?.applyStoredTitleStyle()
                }
            }
        }
        for name in [
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didChangeBackingPropertiesNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowStandingDidChange(_:)),
                name: name,
                object: window
            )
        }
        documentActions.imageRolloverDidChange = { [weak self] isOverImage in
            self?.documentActionsPointerPresenceDidChange(isOverImage)
        }
        documentActions.pointerPresenceDidChange = { [weak self] isInside in
            self?.documentActionsPointerPresenceDidChange(isInside)
        }
        documentActions.popoverVisibilityDidChange = { [weak self] isShown in
            self?.documentActionsPresentationDidChange(isShown)
        }
        documentActions.statusTitleDidChange = { [weak self] in
            self?.layoutDocumentActions()
        }
        // A drag can begin outside the control too — the sensitive rect is
        // wider than the row — and the window says so itself when it starts
        // to move.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillMove(_:)),
            name: NSWindow.willMoveNotification,
            object: window
        )
        // Before the rollover presents, the row belongs to the native frame
        // and no view of ours receives the press. The monitor keeps its down
        // event: a release inside the click slop opens the popover, while a
        // drag past it hands that original event to AppKit and consumes the
        // crossing drag. A reveal must not start under a held button because
        // rebuilding the title field ends the gesture it is tracking.
        pressMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .rightMouseDown, .leftMouseUp]
        ) { [weak self] event in
            let pressedWindow = event.window.map(ObjectIdentifier.init)
            let locationInWindow = event.locationInWindow
            let type = event.type
            var didStartWindowDrag = false
            MainActor.assumeIsolated {
                guard let self, let window = self.window, pressedWindow == ObjectIdentifier(window) else {
                    return
                }
                if type == .leftMouseUp {
                    self.titlePressDidRelease(at: locationInWindow)
                    self.titleMouseDownEvent = nil
                    return
                }
                if type == .leftMouseDragged {
                    guard let start = self.titlePressInWindow,
                        let mouseDown = self.titleMouseDownEvent,
                        hypot(locationInWindow.x - start.x, locationInWindow.y - start.y) > Self.clickSlop
                    else {
                        return
                    }
                    self.titlePressInWindow = nil
                    self.titleMouseDownEvent = nil
                    self.cancelPendingReveal()
                    didStartWindowDrag = true
                    window.performDrag(with: mouseDown)
                    return
                }
                guard let strip = self.titlebarStrip(in: window) else {
                    return
                }
                let point = strip.convert(locationInWindow, from: nil)
                let isOnTitle = self.titleMouseSensitiveRect(in: strip).contains(point)
                // The identity control, once presented, owns its own press —
                // its release opens the popover and its drag moves the
                // window — so only a press the native frame keeps is
                // remembered here.
                let isOnControl =
                    window.contentView?.superview?.hitTest(locationInWindow)
                    .map { $0 === self.documentActions.titlebarView || $0.isDescendant(of: self.documentActions.titlebarView) } ?? false
                let isOnProxyIcon =
                    self.documentButton(in: window)
                    .map {
                        !$0.isHidden && strip.convert($0.bounds, from: $0).contains(point)
                    } ?? false
                if type == .leftMouseDown, isOnTitle, !isOnControl, !isOnProxyIcon {
                    self.titlePressInWindow = locationInWindow
                    self.titleMouseDownEvent = event
                }
                if self.phase == .dwelling || self.phase == .revealing,
                    self.titleTrackingRect(in: strip, window: window).contains(point) || isOnTitle
                {
                    self.cancelPendingReveal()
                }
            }
            return didStartWindowDrag ? nil : event
        }
        documentActions.titleHoverDidChange = { [weak self] isHovered, animated in
            self?.animateTitleHover(isHovered, animated: animated)
        }
        documentActions.chevronExitDuration = exitFlightDuration
        documentActions.hoveredSpanDidChange = { [weak self] kind in
            guard let self, self.titleHoverStyle.highlight == .component,
                self.trailingStatusIsHovered
            else {
                return
            }
            self.setHoveredIdentityKinds(kind.map { [$0] } ?? [], animated: true)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidEndTracking(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
        reinstallTrackingIfNeeded()
    }

    deinit {
        titleObservation?.invalidate()
        documentEditedObservation?.invalidate()
        appearanceObservation?.invalidate()
        if let pressMonitor {
            NSEvent.removeMonitor(pressMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    /// A held button or a moving window is interaction, not hovering — the
    /// intent the dwell exists to separate — so a reveal the entry armed
    /// does not start under it. A reveal already in flight is left to land:
    /// the row was rebuilt when it took off, and its landing only settles
    /// the flight, so neither a press nor the drag the press becomes has
    /// anything to lose to it.
    private func cancelPendingReveal() {
        cancelDwellTimer()
        switch phase {
        case .dwelling:
            phase = .hidden
        case .hidden, .revealing, .revealed, .retreating:
            break
        }
    }

    @objc
    public func windowWillMove(_ notification: Notification) {
        _ = notification
        // A moving window is a drag, not a click: the press that started it
        // opens nothing on release.
        titlePressInWindow = nil
        titleMouseDownEvent = nil
        shouldPresentPopoverOnLanding = false
        cancelPendingReveal()
    }

    /// The window became or stopped being main, or moved to a display of
    /// another scale: the restored proxy follows both, and the title, whose
    /// status symbol stands whole pixels off its baseline, the scale.
    @objc
    public func windowStandingDidChange(_ notification: Notification) {
        refreshSolidProxy()
        if notification.name == NSWindow.didChangeBackingPropertiesNotification {
            applyStoredTitleStyle()
        }
    }

    /// Restores the folder's strength while the window is marked edited.
    ///
    /// A terminal marks its window edited to put the dot in the close button —
    /// closing asks first — and AppKit answers the mark by drawing the proxy at
    /// half strength, the look of an unsaved document whose icon cannot yet be
    /// dragged. A folder has nothing unsaved, so a full-strength copy is laid
    /// over what AppKit drew. The copy is a sublayer of the proxy's own layer:
    /// it rides the reveal's flight, fades and masks with it, hides with the
    /// button, and takes no events, so a drag or the path menu still reaches
    /// AppKit's button beneath.
    ///
    /// AppKit halves the proxy once more in a window that is not main, and the
    /// copy is composited over that drawing rather than instead of it. So its
    /// own strength is the share that lifts the pair to an unmarked window's:
    /// full in the main window, and in a background window the third that
    /// takes the edited quarter to the unmarked half.
    private func refreshSolidProxy() {
        guard let window, window.isDocumentEdited, let url = window.representedURL,
            let icon = documentButton(in: window)
        else {
            solidProxy.removeFromSuperlayer()
            return
        }
        icon.wantsLayer = true
        guard let host = icon.layer, host.bounds.width > 0, host.bounds.height > 0 else {
            solidProxy.removeFromSuperlayer()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if solidProxy.superlayer !== host {
            host.addSublayer(solidProxy)
        }
        solidProxy.frame = host.bounds
        let scale = window.backingScaleFactor
        let appearance = icon.effectiveAppearance
        let key = "\(url.path)|\(host.bounds.size)|\(scale)|\(appearance.name.rawValue)"
        if key != solidProxyContentsKey {
            solidProxyContentsKey = key
            solidProxy.contentsScale = scale
            solidProxy.contents = Self.folderImage(
                for: url,
                size: host.bounds.size,
                scale: scale,
                appearance: appearance
            )
        }
        solidProxy.opacity = window.isMainWindow ? 1 : Float(1.0 / 3.0)
    }

    /// The icon the Finder shows for a location, rendered for one proxy size.
    ///
    /// The same source AppKit's proxy draws from, resolved under the button's
    /// appearance so a folder the system tints for dark mode is tinted here too.
    private static func folderImage(
        for url: URL,
        size: NSSize,
        scale: CGFloat,
        appearance: NSAppearance
    ) -> CGImage? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            var rect = NSRect(origin: .zero, size: size)
            image = icon.cgImage(
                forProposedRect: &rect,
                context: nil,
                hints: [.ctm: AffineTransform(scale: scale)]
            )
        }
        return image
    }

    /// A left release: the popover opens when the press it ends was a click
    /// on the title that the native frame kept.
    ///
    /// - Parameter locationInWindow: Where the button came up.
    private func titlePressDidRelease(at locationInWindow: NSPoint) {
        guard let pressed = titlePressInWindow else {
            return
        }
        titlePressInWindow = nil
        guard hypot(locationInWindow.x - pressed.x, locationInWindow.y - pressed.y) <= Self.clickSlop,
            !alwaysVisible, !documentActions.isPopoverShown
        else {
            return
        }
        switch phase {
        case .revealed:
            presentPopoverForClick()
        case .hidden, .dwelling, .retreating:
            shouldPresentPopoverOnLanding = true
            beginReveal(animated: true)
        case .revealing:
            shouldPresentPopoverOnLanding = true
        }
    }

    /// Presents the popover a click asked for: the rollover first, so the
    /// row is a control while the popover stands over it.
    private func presentPopoverForClick() {
        shouldPresentPopoverOnLanding = false
        setTrailingStatusHovered(true, animated: false)
        documentActions.showPopover(nil)
    }

    private func reinstallTrackingIfNeeded() {
        guard let window, let strip = titlebarStrip(in: window) else {
            detachTracking()
            return
        }
        removeTrackingArea()
        let area = NSTrackingArea(
            rect: titleTrackingRect(in: strip, window: window),
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: hoverOwner,
            userInfo: nil
        )
        strip.addTrackingArea(area)
        trackingArea = area
        trackedStrip = strip
    }

    private func removeTrackingArea() {
        if let trackingArea {
            trackedStrip?.removeTrackingArea(trackingArea)
        }
        trackingArea = nil
        trackedStrip = nil
    }

    private func detachTracking() {
        removeTrackingArea()
        cancelDwellTimer()
        cancelRetreatDwellTimer()
        if phase == .dwelling {
            if sessionFrames == nil {
                phase = .hidden
            } else {
                completeRetreat()
            }
        }
    }

    /// AppKit's private title view uses the document proxy's hover-sensitive
    /// rect with a 4/8/4/8 edge outset. The non-unified path lacks that proxy
    /// object while hidden, so its title field supplies the equivalent base.
    private func titleMouseSensitiveRect(in strip: NSView) -> NSRect {
        guard let titleField = titleTextField(in: strip) else {
            return .zero
        }
        var rect = strip.convert(titleField.bounds, from: titleField)
        if let documentButton = documentButton(in: window) {
            rect = rect.union(strip.convert(documentButton.bounds, from: documentButton))
        }
        let actionsView = documentActions.titlebarView
        if !actionsView.isHidden, actionsView.superview != nil {
            rect = rect.union(strip.convert(actionsView.bounds, from: actionsView))
        }
        return NSInsetRect(rect, -8, -4)
    }

    /// The unified title view occupies the titlebar from 13 points after the
    /// zoom button to a 4-point trailing inset. Its own tracking area covers
    /// that visible region; `_updateRolloverWithEvent:` then applies the much
    /// smaller document-proxy-sensitive rect before changing state.
    private func titleTrackingRect(in strip: NSView, window: NSWindow) -> NSRect {
        let leadingEdge: CGFloat
        if let zoomButton = window.standardWindowButton(.zoomButton) {
            leadingEdge = strip.convert(zoomButton.bounds, from: zoomButton).maxX + 13
        } else {
            leadingEdge = strip.bounds.minX
        }
        let trailingEdge = max(leadingEdge, strip.bounds.maxX - 4)
        // The container spans the tab bar too once one exists; the rollover's
        // world is only the row the title lives in.
        var bottomEdge = strip.bounds.minY
        if let titleField = titleTextField(in: strip) {
            let titleFrame = strip.convert(titleField.bounds, from: titleField)
            bottomEdge = max(bottomEdge, titleFrame.minY - 8)
        }
        return NSRect(
            x: leadingEdge,
            y: bottomEdge,
            width: trailingEdge - leadingEdge,
            height: strip.bounds.maxY - bottomEdge
        )
    }

    private func mouseIsInTitleMouseSensitiveRect(_ event: NSEvent) -> Bool {
        guard let window, let strip = titlebarStrip(in: window) else {
            return false
        }
        return titleMouseSensitiveRect(in: strip).contains(strip.convert(event.locationInWindow, from: nil))
    }

    fileprivate func titleStripHoverBegan(with event: NSEvent) {
        updateRollover(with: event)
    }

    /// A tracking area with `.mouseMoved` delivers movement to its owner even
    /// though the window does not accept mouse-moved events, which a local
    /// `NSEvent` monitor would depend on. This is the single event source, so
    /// each physical move costs one pass rather than two.
    fileprivate func titleStripHoverMoved(with event: NSEvent) {
        updateRollover(with: event)
    }

    fileprivate func titleStripHoverEnded(with event: NSEvent) {
        guard !documentActions.isPopoverShown else {
            return
        }
        cancelDwellTimer()
        scheduleTrailingStatusExit()
        guard !alwaysVisible else {
            return
        }
        // The sensitive rect is wider than the tracking area, so the pointer
        // can still be inside the reveal region here — a pointer on its way to
        // the traffic lights arrives exactly this way. No further event is
        // guaranteed once the area is gone, so the retreat is armed
        // unconditionally and its dwell re-samples the pointer on expiry
        // instead of waiting for a move that never comes.
        scheduleRetreat(animated: !event.modifierFlags.contains(.shift))
    }

    private func updateRollover(with event: NSEvent) {
        if alwaysVisible {
            // With the icon always resident there is no flight to ride, so
            // the chevron answers presence directly.
            if mouseIsInTitleMouseSensitiveRect(event) {
                revealTrailingStatus()
            } else {
                scheduleTrailingStatusExit()
            }
            return
        }
        guard !documentActions.isPopoverShown,
            let window,
            window.isVisible,
            let strip = titlebarStrip(in: window),
            let titleField = titleTextField(in: strip),
            !titleField.isEditable
        else {
            return
        }

        let isInside = mouseIsInTitleMouseSensitiveRect(event)
        if event.modifierFlags.contains(.shift), isInside {
            beginReveal(animated: false)
            return
        }

        guard isInside else {
            cancelDwellTimer()
            scheduleTrailingStatusExit()
            scheduleRetreat(animated: true)
            return
        }

        cancelRetreatDwellTimer()
        switch phase {
        case .hidden, .dwelling, .retreating:
            // Every in-zone movement re-arms the clock: the dwell measures
            // stillness — a pointer travelling across the title is not
            // resting on it, however long the journey takes. The latency this
            // buys varies with how the hand settles, and that is the point.
            phase = .dwelling
            armOrResetDwellTimer()
        case .revealing, .revealed:
            break
        }
    }

    /// Holds the revealed icon for the retreat dwell, then re-checks the
    /// pointer. Re-entry cancels the pending retreat, so crossing the title on
    /// the way somewhere else never starts one.
    private func scheduleRetreat(animated: Bool) {
        switch phase {
        case .hidden, .retreating:
            return
        case .dwelling, .revealing, .revealed:
            break
        }
        guard animated else {
            cancelRetreatDwellTimer()
            if !pointerIsInTitleMouseSensitiveRect() {
                leaveDwelling(animated: false)
            }
            return
        }
        guard retreatDwellTimer == nil else {
            return
        }
        let timer = Timer(
            timeInterval: Policy.retreatDwellInterval,
            target: self,
            selector: #selector(retreatDwellTimerFired),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        retreatDwellTimer = timer
    }

    private func cancelRetreatDwellTimer() {
        retreatDwellTimer?.invalidate()
        retreatDwellTimer = nil
    }

    @objc
    public func retreatDwellTimerFired() {
        cancelRetreatDwellTimer()
        guard !documentActions.isPopoverShown else {
            return
        }
        // A pointer resting in the band between the tracking area and the wider
        // sensitive rect receives no further events, so the dwell keeps watch
        // until the pointer truly leaves rather than stranding the icon.
        guard !pointerIsInTitleMouseSensitiveRect() else {
            scheduleRetreat(animated: true)
            return
        }
        leaveDwelling(animated: true)
    }

    private func leaveDwelling(animated: Bool) {
        if sessionFrames == nil {
            phase = .hidden
        } else {
            beginRetreat(animated: animated)
        }
    }

    private func setTrailingStatusHovered(_ isHovered: Bool, animated: Bool = true) {
        guard trailingStatusIsHovered != isHovered else {
            return
        }
        trailingStatusIsHovered = isHovered
        documentActions.setTitleRegionIsHovered(isHovered, animated: animated)
    }

    /// The row-level hover changing: resolve which span kinds the lift covers.
    private func animateTitleHover(_ isHovered: Bool, animated: Bool) {
        let kinds: Set<TitleIdentitySpan.Kind>
        switch titleHoverStyle.highlight {
        case .none:
            kinds = []
        case .wholeTitle:
            kinds = isHovered ? Set(TitleIdentitySpan.Kind.allCases) : []
        case .component:
            kinds = isHovered ? documentActions.hoveredSpanKind.map { [$0] } ?? [] : []
        }
        setHoveredIdentityKinds(kinds, animated: animated)
    }

    /// Lifts each named kind's colour to bright and settles the rest, on the
    /// chevron's own clock, by restyling the string per step
    /// (`TitleHoverPolicy` records why not a crossfade).
    private func setHoveredIdentityKinds(_ kinds: Set<TitleIdentitySpan.Kind>, animated: Bool) {
        let animating = animated && !SystemDisplayOptions.shouldReduceMotion
        let now = CACurrentMediaTime()
        for kind in TitleIdentitySpan.Kind.allCases {
            let target: CGFloat = kinds.contains(kind) ? 1 : 0
            let current = spanHoverFractions[kind] ?? 0
            if spanHoverFlights[kind]?.target == target {
                continue
            }
            spanHoverFlights[kind] = nil
            guard abs(target - current) > 0.001 else {
                spanHoverFractions[kind] = target
                continue
            }
            let duration = target > current ? TitleHoverPolicy.duration : exitFlightDuration
            guard animating, duration > 0 else {
                spanHoverFractions[kind] = target
                continue
            }
            spanHoverFlights[kind] = SpanHoverFlight(
                start: current,
                target: target,
                startTime: now,
                duration: duration
            )
        }
        guard !spanHoverFlights.isEmpty else {
            hoverAnimationTimer?.invalidate()
            hoverAnimationTimer = nil
            applyStoredTitleStyle()
            return
        }
        guard hoverAnimationTimer == nil else {
            return
        }
        let timer = Timer(
            timeInterval: TitleHoverPolicy.frameInterval,
            target: self,
            selector: #selector(hoverAnimationTimerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        hoverAnimationTimer = timer
    }

    @objc
    public func hoverAnimationTimerFired() {
        let now = CACurrentMediaTime()
        for (kind, flight) in spanHoverFlights {
            let progress = min(1, (now - flight.startTime) / flight.duration)
            spanHoverFractions[kind] =
                flight.start
                + (flight.target - flight.start) * Self.defaultCurveValue(CGFloat(progress))
            if progress >= 1 {
                spanHoverFlights[kind] = nil
            }
        }
        applyStoredTitleStyle()
        if spanHoverFlights.isEmpty {
            hoverAnimationTimer?.invalidate()
            hoverAnimationTimer = nil
        }
    }

    /// Core Animation's default curve — the (0.25, 0.1)-(0.25, 1) bezier every
    /// flight in this file rides — evaluated as y(x), so the text recolour
    /// eases exactly like the layer animations beside it.
    private static func defaultCurveValue(_ x: CGFloat) -> CGFloat {
        guard x > 0 else {
            return 0
        }
        guard x < 1 else {
            return 1
        }
        func coordinate(_ t: CGFloat, _ control1: CGFloat, _ control2: CGFloat) -> CGFloat {
            let u = 1 - t
            return 3 * u * u * t * control1 + 3 * u * t * t * control2 + t * t * t
        }
        var low: CGFloat = 0
        var high: CGFloat = 1
        var t = x
        for _ in 0..<24 {
            let current = coordinate(t, 0.25, 0.25)
            if abs(current - x) < 0.0005 {
                break
            }
            if current < x {
                low = t
            } else {
                high = t
            }
            t = (low + high) / 2
        }
        return coordinate(t, 0.1, 1)
    }

    /// `NSThemeAutosaveButton` keeps the arrow, separator, and status fields
    /// independent of the document proxy. Leaving its image starts a
    /// cancellable 0.25-second task; only expiry starts the native 0.1-second
    /// default-curve transition.
    private func revealTrailingStatus(animated: Bool = true) {
        cancelTrailingStatusExitTimer()
        setTrailingStatusHovered(true, animated: animated)
    }

    private func scheduleTrailingStatusExit() {
        guard trailingStatusIsHovered, trailingStatusExitTimer == nil else {
            return
        }
        let timer = Timer(
            timeInterval: TrailingStatusPolicy.exitDwellInterval,
            target: self,
            selector: #selector(trailingStatusExitTimerFired),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        trailingStatusExitTimer = timer
    }

    private func cancelTrailingStatusExitTimer() {
        trailingStatusExitTimer?.invalidate()
        trailingStatusExitTimer = nil
    }

    @objc
    public func trailingStatusExitTimerFired() {
        cancelTrailingStatusExitTimer()
        guard !documentActions.isPopoverShown,
            !pointerIsInTitleMouseSensitiveRect()
        else {
            return
        }
        setTrailingStatusHovered(false)
    }

    private func pointerIsInTitleMouseSensitiveRect() -> Bool {
        guard let window, let strip = titlebarStrip(in: window) else {
            return false
        }
        let mouseInStrip = strip.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return titleMouseSensitiveRect(in: strip).contains(mouseInStrip)
    }

    /// Presence does not reveal the chevron — its fade-in rides the reveal
    /// flight, so the two arrive as one gesture — but presence decides whether
    /// a revealed chevron stays: re-entry cancels a pending exit, leaving
    /// arms one.
    private func documentActionsPointerPresenceDidChange(_ isInside: Bool) {
        guard !documentActions.isPopoverShown else {
            return
        }
        if isInside {
            cancelTrailingStatusExitTimer()
        } else {
            scheduleTrailingStatusExit()
        }
    }

    @objc
    public func menuDidEndTracking(_ notification: Notification) {
        _ = notification
        DispatchQueue.main.async { [weak self] in
            self?.reevaluatePointerAfterTransientPresentation()
        }
    }

    private func documentActionsPresentationDidChange(_ isShown: Bool) {
        if isShown {
            cancelDwellTimer()
            revealTrailingStatus()
            return
        }
        DispatchQueue.main.async { [weak self] in
            // The z-order repair stands down while the popover is up, because
            // restacking under a presented popover moves the anchor it hangs
            // from. AppKit substitutes a fresh title field whenever the title
            // text changes, though, and one substituted during those seconds
            // lands on top of the identity control; laying out again on the
            // way down puts the control back above the field it takes its
            // clicks through.
            self?.layoutDocumentActions()
            self?.reevaluatePointerAfterTransientPresentation()
        }
    }

    /// A menu can consume the exit event and then be dismissed by a click in
    /// the content view. The pointer has left the titlebar by then, but neither
    /// the tracking-area owner nor its local mouse-move monitor is guaranteed a
    /// final event. Re-sampling the window coordinate after the transient UI
    /// ends closes the held represented-URL slot in that path.
    private func reevaluatePointerAfterTransientPresentation() {
        guard !alwaysVisible,
            !documentActions.isPopoverShown,
            let window,
            window.isVisible,
            let strip = titlebarStrip(in: window)
        else {
            return
        }
        let mouseInStrip = strip.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard !titleMouseSensitiveRect(in: strip).contains(mouseInStrip) else {
            // The pointer stayed on the title. A chevron the popover raised
            // without a dwell goes down without one — the phase records
            // whether the reveal ever ran — and the resting pointer re-arms
            // the ordinary cycle from its start.
            if phase == .dwelling || phase == .hidden {
                setTrailingStatusHovered(false)
                if phase == .dwelling {
                    armOrResetDwellTimer()
                }
            }
            return
        }
        // The pointer is gone and the transient UI is too. The exit dwell is
        // hysteresis for pointers that may come back; nothing here can, so
        // the chevron goes now — with the retreat when there is one.
        cancelTrailingStatusExitTimer()
        switch phase {
        case .dwelling:
            setTrailingStatusHovered(false)
            leaveDwelling(animated: true)
        case .revealing, .revealed:
            beginRetreat(animated: true)
        case .hidden, .retreating:
            setTrailingStatusHovered(false)
        }
    }

    private func armOrResetDwellTimer() {
        cancelDwellTimer()
        let timer = Timer(
            timeInterval: revealTiming.revealDwell.interval,
            target: self,
            selector: #selector(dwellTimerFired),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    private func cancelDwellTimer() {
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    @objc
    public func dwellTimerFired() {
        cancelDwellTimer()
        guard phase == .dwelling else {
            return
        }
        // A button held when the dwell elapses is a drag or a click under
        // way, not a hand at rest: the reveal waits for the next entry.
        guard NSEvent.pressedMouseButtons == 0 else {
            phase = .hidden
            return
        }
        beginReveal(animated: true)
    }

    private func beginReveal(animated: Bool) {
        guard let window, window.isVisible, let container = titlebarStrip(in: window) else {
            cancelDwellTimer()
            phase = .hidden
            return
        }
        cancelDwellTimer()

        let isNewSession = sessionFrames == nil
        if isNewSession {
            container.layoutSubtreeIfNeeded()
            guard let restingTitleField = titleTextField(in: container) else {
                phase = .hidden
                return
            }
            _ = installDocumentActions(in: container, beside: restingTitleField)
            let restingTitleInStrip = container.convert(restingTitleField.bounds, from: restingTitleField)

            phase = .revealing
            requestSlotResolution?()
            container.layoutSubtreeIfNeeded()
            applyStoredTitleStyle()

            guard let titledTitleField = titleTextField(in: container) else {
                completeRetreat()
                return
            }
            let titledTitleInStrip = container.convert(titledTitleField.bounds, from: titledTitleField)
            sessionFrames = SessionFrames(
                restingTitleInStrip: restingTitleInStrip,
                titledTitleInStrip: titledTitleInStrip
            )
        } else {
            phase = .revealing
            container.layoutSubtreeIfNeeded()
            applyStoredTitleStyle()
        }

        guard let frames = sessionFrames else {
            completeRetreat()
            return
        }

        guard let titleField = titleTextField(in: container) else {
            completeRetreat()
            return
        }
        let actionsView = installDocumentActions(in: container, beside: titleField)
        guard let icon = documentButton(in: window) else {
            // No folder stands behind this title — a window on a host has no
            // local directory to proxy — but the row still has its menu, and
            // the chevron is the way to it. Nothing slides: the title has no
            // icon to make room for, so the chevron arrives in place.
            actionsView.alphaValue = 1
            revealTrailingStatus(animated: animated)
            phase = .revealed
            reinstallTrackingIfNeeded()
            if shouldPresentPopoverOnLanding {
                presentPopoverForClick()
            }
            return
        }
        // The chevron fades in on this same flight: the dwell decided, and
        // the icon and the arrow arrive together.
        revealTrailingStatus(animated: animated)

        icon.wantsLayer = true
        titleField.wantsLayer = true
        actionsView.wantsLayer = true
        let iconStartOpacity = isNewSession ? CGFloat(0) : presentationOpacity(of: icon, fallback: icon.alphaValue)
        let iconEndPosition = icon.layer?.position ?? .zero
        let titleEndPosition = titleField.layer?.position ?? .zero
        let actionsEndPosition = actionsView.layer?.position ?? .zero
        let iconStartPosition =
            isNewSession
            ? horizontallyTranslated(iconEndPosition, by: frames.horizontalTranslation)
            : presentationPosition(of: icon, fallback: iconEndPosition)
        let titleStartPosition =
            isNewSession
            ? horizontallyTranslated(titleEndPosition, by: frames.horizontalTranslation)
            : presentationPosition(of: titleField, fallback: titleEndPosition)
        let actionsStartPosition =
            isNewSession
            ? horizontallyTranslated(actionsEndPosition, by: frames.horizontalTranslation)
            : presentationPosition(of: actionsView, fallback: actionsEndPosition)

        clearFlightAnimations(of: icon, titleField, actionsView)
        icon.isHidden = false
        icon.alphaValue = 1
        icon.isEnabled = true
        actionsView.alphaValue = 1

        let duration = animationDuration(animated: animated)
        guard duration > 0 else {
            phase = .revealed
            reinstallTrackingIfNeeded()
            if shouldPresentPopoverOnLanding {
                presentPopoverForClick()
            }
            return
        }

        let iconFade =
            shouldAnimateIdentityOpacity
            ? opacityAnimation(from: iconStartOpacity, to: 1, duration: duration)
            : nil
        let iconPosition = positionAnimation(from: iconStartPosition, to: iconEndPosition, duration: duration)
        let titlePosition = positionAnimation(from: titleStartPosition, to: titleEndPosition, duration: duration)
        let actionsPosition = positionAnimation(from: actionsStartPosition, to: actionsEndPosition, duration: duration)

        // Native `_installMask` clips the sliding icon at the title assembly's
        // leading edge; the mask counter-slides so the clip edge holds still.
        var doorSlide: CABasicAnimation?
        var doorMask: CALayer?
        if identityTransition == .slide {
            let mask = CALayer()
            mask.backgroundColor = NSColor.white.cgColor
            mask.frame = icon.bounds
            icon.layer?.mask = mask
            doorSlide = positionAnimation(
                from: CGPoint(
                    x: mask.position.x + (iconEndPosition.x - iconStartPosition.x),
                    y: mask.position.y
                ),
                to: mask.position,
                duration: duration
            )
            doorMask = mask
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak icon, weak titleField, weak actionsView] in
            guard let self, self.phase == .revealing else {
                return
            }
            self.clearFlightAnimations(of: icon, titleField, actionsView)
            self.phase = .revealed
            self.reinstallTrackingIfNeeded()
            if self.shouldPresentPopoverOnLanding {
                self.presentPopoverForClick()
            }
        }
        if let iconFade {
            icon.layer?.add(iconFade, forKey: FlightKey.fade)
        }
        icon.layer?.add(iconPosition, forKey: FlightKey.iconPosition)
        if let doorMask, let doorSlide {
            doorMask.add(doorSlide, forKey: FlightKey.iconPosition)
        }
        titleField.layer?.add(titlePosition, forKey: FlightKey.titlePosition)
        actionsView.layer?.add(actionsPosition, forKey: FlightKey.actionsPosition)
        CATransaction.commit()
    }

    private func beginRetreat(animated: Bool) {
        // A retreat ends whatever reveal a click was waiting on: the popover
        // it asked for is not owed to a later, unrelated landing.
        shouldPresentPopoverOnLanding = false
        guard let window, let container = titlebarStrip(in: window), let frames = sessionFrames else {
            completeRetreat()
            return
        }
        cancelDwellTimer()
        container.layoutSubtreeIfNeeded()
        applyStoredTitleStyle()
        guard let icon = documentButton(in: window), let titleField = titleTextField(in: container) else {
            // The chevron-only reveal has no icon to retreat with; the chevron
            // leaves on its own clock.
            cancelTrailingStatusExitTimer()
            setTrailingStatusHovered(false, animated: animated)
            completeRetreat()
            return
        }
        let actionsView = documentActions.titlebarView

        icon.wantsLayer = true
        titleField.wantsLayer = true
        actionsView.wantsLayer = true
        let iconStartOpacity = presentationOpacity(of: icon, fallback: icon.alphaValue)
        let iconModelPosition = icon.layer?.position ?? .zero
        let titleModelPosition = titleField.layer?.position ?? .zero
        let actionsModelPosition = actionsView.layer?.position ?? .zero
        let iconStartPosition = presentationPosition(of: icon, fallback: iconModelPosition)
        let titleStartPosition = presentationPosition(of: titleField, fallback: titleModelPosition)
        let actionsStartPosition = presentationPosition(of: actionsView, fallback: actionsModelPosition)
        let iconEndPosition = horizontallyTranslated(iconModelPosition, by: frames.horizontalTranslation)
        let titleEndPosition = horizontallyTranslated(titleModelPosition, by: frames.horizontalTranslation)
        let actionsEndPosition = horizontallyTranslated(actionsModelPosition, by: frames.horizontalTranslation)

        clearFlightAnimations(of: icon, titleField, actionsView)
        if shouldAnimateIdentityOpacity {
            icon.alphaValue = 0
        }
        phase = .retreating
        // The chevron leaves on the retreat's own clock, symmetric with its
        // arrival on the reveal's.
        cancelTrailingStatusExitTimer()
        setTrailingStatusHovered(false, animated: animated)

        let duration =
            animated && !SystemDisplayOptions.shouldReduceMotion
            ? exitFlightDuration
            : 0
        guard duration > 0 else {
            completeRetreat()
            return
        }

        let iconFade =
            shouldAnimateIdentityOpacity
            ? opacityAnimation(from: iconStartOpacity, to: 0, duration: duration)
            : nil
        let iconPosition = positionAnimation(from: iconStartPosition, to: iconEndPosition, duration: duration)
        let titlePosition = positionAnimation(from: titleStartPosition, to: titleEndPosition, duration: duration)
        let actionsPosition = positionAnimation(from: actionsStartPosition, to: actionsEndPosition, duration: duration)

        // Ubiquitty diverges from AppKit's instant hide here: the icon retreats
        // through the same clipped edge it arrived by, symmetric with reveal.
        var doorSlide: CABasicAnimation?
        var doorMask: CALayer?
        if identityTransition == .slide {
            let mask = CALayer()
            mask.backgroundColor = NSColor.white.cgColor
            mask.frame = icon.bounds
            icon.layer?.mask = mask
            doorSlide = positionAnimation(
                from: mask.position,
                to: CGPoint(
                    x: mask.position.x + (iconStartPosition.x - iconEndPosition.x),
                    y: mask.position.y
                ),
                duration: duration
            )
            doorMask = mask
        }
        for animation in [iconFade, iconPosition, titlePosition, actionsPosition, doorSlide].compactMap({ $0 }) {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak icon, weak titleField, weak actionsView] in
            guard let self, self.phase == .retreating else {
                return
            }
            self.completeRetreat(holding: [icon, titleField, actionsView])
        }
        if let iconFade {
            icon.layer?.add(iconFade, forKey: FlightKey.fade)
        }
        icon.layer?.add(iconPosition, forKey: FlightKey.iconPosition)
        if let doorMask, let doorSlide {
            doorMask.add(doorSlide, forKey: FlightKey.iconPosition)
        }
        titleField.layer?.add(titlePosition, forKey: FlightKey.titlePosition)
        actionsView.layer?.add(actionsPosition, forKey: FlightKey.actionsPosition)
        CATransaction.commit()
    }

    private func completeRetreat(holding views: [NSView?] = []) {
        shouldPresentPopoverOnLanding = false
        cancelDwellTimer()
        cancelRetreatDwellTimer()
        phase = .hidden
        sessionFrames = nil
        // The slot is given back here rather than by a shell's callback: the
        // controller decided the session ended, and a second writer of the
        // same URL is a second place the two shells can disagree.
        if window?.representedURL != nil {
            window?.representedURL = nil
        }
        if let icon = documentButton(in: window) {
            icon.isEnabled = false
            icon.isHidden = true
        }
        layoutDocumentActions()
        if views.isEmpty {
            clearFlightAnimations()
        } else {
            for view in views {
                clearFlightAnimations(of: view)
            }
        }
        applyStoredTitleStyle()
        reinstallTrackingIfNeeded()
    }

    private func animationDuration(animated: Bool) -> CFTimeInterval {
        guard animated, !SystemDisplayOptions.shouldReduceMotion else {
            return 0
        }
        return Policy.transitionDuration
    }

    private func horizontallyTranslated(_ position: CGPoint, by distance: CGFloat) -> CGPoint {
        CGPoint(x: position.x + distance, y: position.y)
    }

    private func presentationPosition(of view: NSView, fallback: CGPoint) -> CGPoint {
        view.layer?.presentation()?.position ?? fallback
    }

    private func presentationOpacity(of view: NSView, fallback: CGFloat) -> CGFloat {
        CGFloat(view.layer?.presentation()?.opacity ?? Float(fallback))
    }

    /// Every lift fraction, rounded to the animation's visible resolution, so
    /// the restyle gate reopens exactly when a colour actually changes.
    private var hoverSignature: String {
        TitleIdentitySpan.Kind.allCases
            .map { String(format: "%.3f", spanHoverFractions[$0] ?? 0) }
            .joined(separator: "|")
    }

    #if UBIQUITTY_UI_TESTS
    /// The title's own words, after the tag markers and the host's reserved
    /// span, in the title field's coordinates; nil while the row has none.
    package var titleWordsFrameForTesting: NSRect? {
        guard let window, let strip = titlebarStrip(in: window), let titleField = titleTextField(in: strip) else { return nil }
        let markerEnd = identitySpans.first { $0.kind == .markers }.map { NSMaxRange($0.range) } ?? 0
        let isConnectionShown = connectionIndicator.map { !$0.isHidden && $0.frame.width > 0 } ?? false
        let connection = identitySpans.first { $0.kind == .process && $0.range.location == markerEnd }
        let wordsStart = isConnectionShown ? connection.map { NSMaxRange($0.range) } ?? markerEnd : markerEnd
        let length = (titleField.attributedStringValue.string as NSString).length - wordsStart
        guard length > 0 else { return nil }
        return TitleTextLayout(titleField).bounds(for: NSRange(location: wordsStart, length: length))
    }

    /// Where the tag stack's image runs across the title field, as the title
    /// lays it out, in the field's x; nil while the title leads with no stack.
    /// The layout's vertical measure is its own container's, not the field's,
    /// so only the span is given.
    package var titleTagStackSpanForTesting: ClosedRange<CGFloat>? {
        guard let window, let strip = titlebarStrip(in: window), let titleField = titleTextField(in: strip),
            let markers = identitySpans.first(where: { $0.kind == .markers })
        else { return nil }
        let bounds = TitleTextLayout(titleField).bounds(for: markers.range)
        return bounds.minX...bounds.maxX
    }
    #endif

    private func applyStoredTitleStyle() {
        guard let window,
            let dimColor = titleDimColor,
            let brightColor = titleBrightColor,
            let strip = titlebarStrip(in: window),
            let titleField = titleTextField(in: strip)
        else {
            return
        }

        let hasConnectionIndicator = connectionIndicator.map { !$0.isHidden } ?? false
        let wovenTitle = isHostFallbackTitle && hasConnectionIndicator ? "" : (rowTitleText ?? window.title)
        // The program's icon stands before the program's name, an attachment in
        // the object-replacement character's place: after the directory and
        // its separator, ahead of anything measured from the title's end.
        let iconLocation = processIconKey.isEmpty || wovenTitle.isEmpty ? nil : processIconLocation(in: wovenTitle)
        let title =
            iconLocation.map { (wovenTitle as NSString).replacingCharacters(in: NSRange(location: $0, length: 0), with: "\u{FFFC}") }
            ?? wovenTitle
        let titleLength = (title as NSString).length
        guard titleLength > 0 || hasConnectionIndicator else {
            return
        }
        let wasApplying = isApplyingTitleLayout
        isApplyingTitleLayout = true
        defer {
            isApplyingTitleLayout = wasApplying
        }

        if let indicator = connectionIndicator, indicator.superview !== titleField {
            titleField.addSubview(indicator)
        }
        let titleFont = titleField.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        connectionIndicator?.setTitleFont(titleFont)
        let connectionSize = connectionIndicator.flatMap { $0.isHidden ? nil : $0.frame.size } ?? .zero
        // Without the chip's tag: the spoken title has named every tag, the
        // chip's among them, before it reaches the chip.
        let connectionDescription =
            connectionSize.width > 0 ? (connectionIndicator?.linkDescription ?? "") : ""
        // A chip wearing its tag's capsule is the tag stack's last pill, and
        // the stack tucks under it; the plain chip is text, and stands apart.
        let isTuckedUnderHostChip = connectionSize.width > 0 && connectionIndicator?.isWearingTagCapsule == true

        // The status and the program's status join the title in one string:
        // one baseline, and one spacing rule for every separator on the line.
        let statusTitle = documentActions.statusTitle
        let programStatus = programStatusTitle
        let statusSymbol = programStatusSymbol
        let hasProgramStatus = !programStatus.isEmpty || statusSymbol != nil
        var composedText = title
        if !statusTitle.isEmpty {
            composedText += (composedText.isEmpty ? "" : Self.windowTitleSeparator) + statusTitle
        }
        let statusEnd = (composedText as NSString).length
        // A program's status follows the process chain's arrow: its symbol,
        // an attachment standing in the object-replacement character, then
        // what it says it is doing.
        let arrowLength = statusEnd > 0 && hasProgramStatus ? (Self.statusArrow as NSString).length : 0
        var symbolLocation: Int?
        if hasProgramStatus {
            if statusEnd > 0 {
                composedText += Self.statusArrow
            }
            if statusSymbol != nil {
                symbolLocation = (composedText as NSString).length
                composedText += "\u{FFFC}" + (programStatus.isEmpty ? "" : " ")
            }
            composedText += programStatus
        }
        let composed = composedText as NSString
        let composedLength = composed.length

        // A lifted colour is the dim run's rollover state: dim at rest, the
        // bright title colour under the pointer, interpolated in between.
        let detailColor = titleDetailColor ?? dimColor
        func lifted(_ kind: TitleIdentitySpan.Kind) -> NSColor {
            let resting = kind == .status ? detailColor : dimColor
            let fraction = spanHoverFractions[kind] ?? 0
            guard fraction > 0 else {
                return resting
            }
            return resting.blended(withFraction: fraction, of: brightColor) ?? brightColor
        }

        // The chevron accompanies the last run on the line, so it wears that
        // run's own colour — dim at rest, lifted with it — never the bright
        // title. Assigned before the skip below, and nowhere else, so no stale
        // value can survive an early return.
        if hasProgramStatus {
            documentActions.foregroundColor = lifted(.programStatus)
        } else {
            documentActions.foregroundColor = statusTitle.isEmpty ? brightColor : lifted(.status)
        }

        // Restyling rebuilds and re-measures the whole string, and every caller
        // runs it whether or not anything moved. Skipping an identical re-apply
        // is what keeps a long title's reveal off a per-transition CoreText
        // measurement it would only repeat.
        let styleKey = StyleKey(
            title: title,
            statusTitle: statusTitle,
            programStatus: programStatus,
            programStatusSymbol: statusSymbol,
            processIconKey: processIconKey,
            dimColor: dimColor,
            brightColor: brightColor,
            detailColor: detailColor,
            hoverSignature: hoverSignature,
            fieldWidth: titleField.frame.width,
            fieldHeight: titleField.frame.height,
            titleFont: titleFont,
            directorySegment: titleDirectorySegment,
            prefixBeforeDirectory: titlePrefixBeforeDirectory,
            markerSignature: TitlebarTagMarker.signature(of: tagMarkers),
            tagStyle: tagStyle,
            appearanceName: titleField.effectiveAppearance.name,
            connectionSize: connectionSize,
            connectionDescription: connectionDescription,
            isTuckedUnderHostChip: isTuckedUnderHostChip,
            bellSignature: bellSignature,
            backingScale: titleBackingScale
        )
        // The bell is an attachment, so the field's string ends with the
        // object-replacement character rather than the composed text. Tested
        // for alongside it: a guard written for the text alone answers "moved"
        // on every restyle of a title that carries a bell, which is the whole
        // of what this gate exists to prevent.
        let markSuffix = hasUnheardBell ? "\u{FFFC}" : ""
        if lastAppliedStyle == styleKey, composed.length > 0,
            (titleField.attributedStringValue.string as NSString).hasSuffix(composedText + markSuffix)
        {
            return
        }

        let styledTitle = NSMutableAttributedString(string: composedText)
        let fullRange = NSRange(location: 0, length: composedLength)
        styledTitle.addAttribute(.foregroundColor, value: brightColor, range: fullRange)

        var directoryRange: NSRange?
        let directoryPrefixLength = (titlePrefixBeforeDirectory as NSString).length
        let directoryLength = (titleDirectorySegment as NSString).length
        if directoryLength > 0,
            title.hasPrefix(titlePrefixBeforeDirectory),
            directoryPrefixLength + directoryLength <= titleLength,
            composed.substring(
                with: NSRange(location: directoryPrefixLength, length: directoryLength)
            ) == titleDirectorySegment
        {
            var dimLength = directoryLength
            // The separator joins the dim run, so the bound has to allow for
            // its whole width: the bare spelling is one UTF-16 unit but the
            // spaced one is three, and a guard written for a single character
            // would read past the title.
            let separatorLength = (Self.windowTitleSeparator as NSString).length
            if directoryPrefixLength + dimLength + separatorLength <= titleLength,
                composed.substring(
                    with: NSRange(
                        location: directoryPrefixLength + dimLength,
                        length: separatorLength
                    )
                ) == Self.windowTitleSeparator
            {
                dimLength += separatorLength
            }
            let range = NSRange(location: directoryPrefixLength, length: dimLength)
            styledTitle.addAttribute(.foregroundColor, value: lifted(.directory), range: range)
            styledTitle.addAttribute(
                .font,
                value: Self.directoryFont,
                range: NSRange(location: directoryPrefixLength, length: directoryLength)
            )
            directoryRange = range
        }

        let separatorLength = (Self.windowTitleSeparator as NSString).length
        var statusRange: NSRange?
        if !statusTitle.isEmpty {
            let range = NSRange(location: titleLength, length: statusEnd - titleLength)
            styledTitle.addAttribute(.foregroundColor, value: lifted(.status), range: range)
            // The separator keeps the title's face; the status wears its own.
            styledTitle.addAttribute(
                .font,
                value: statusFont,
                range: NSRange(
                    location: range.location + (titleLength > 0 ? separatorLength : 0),
                    length: range.length - (titleLength > 0 ? separatorLength : 0)
                )
            )
            statusRange = range
        }

        var programStatusRange: NSRange?
        if hasProgramStatus {
            let range = NSRange(location: statusEnd, length: composedLength - statusEnd)
            styledTitle.addAttribute(.foregroundColor, value: lifted(.programStatus), range: range)
            // In the dimensions' face: both are readouts beside the title rather
            // than part of its name, and the arrow keeps the title's face.
            styledTitle.addAttribute(
                .font,
                value: statusFont,
                range: NSRange(location: range.location + arrowLength, length: range.length - arrowLength)
            )
            programStatusRange = range
        }

        // Separators keep one detail color after component and hover styling.
        var search = fullRange
        while search.length > 0 {
            let dash = composed.range(of: "\u{2014}", options: [], range: search)
            guard dash.location != NSNotFound else {
                break
            }
            // A remote session composes its own halves before they reach the
            // window title, and that join carries real spaces. Kerning it too
            // would gap it twice.
            let hasLeadingSpace =
                dash.location > 0
                && composed.substring(with: NSRange(location: dash.location - 1, length: 1)) == " "
            let hasTrailingSpace =
                NSMaxRange(dash) < composedLength
                && composed.substring(with: NSRange(location: NSMaxRange(dash), length: 1)) == " "
            if dash.location > 0, !hasLeadingSpace {
                let previousCharacter = composed.rangeOfComposedCharacterSequence(at: dash.location - 1)
                styledTitle.addAttribute(.kern, value: SeparatorGap.before, range: previousCharacter)
            }
            if NSMaxRange(dash) < composedLength, !hasTrailingSpace {
                styledTitle.addAttribute(.kern, value: SeparatorGap.after, range: dash)
            }
            styledTitle.addAttribute(.foregroundColor, value: detailColor, range: dash)
            search = NSRange(location: NSMaxRange(dash), length: composedLength - NSMaxRange(dash))
        }

        // The status symbol takes its character's place once every colour and
        // face above is set, wearing its status's colour rather than the run's.
        if let symbolLocation, let statusSymbol,
            let symbol = statusSymbolAttachment(
                statusSymbol,
                ink: statusSymbol.ink ?? lifted(.programStatus),
                appearance: titleField.effectiveAppearance,
                backingScale: titleBackingScale
            )
        {
            styledTitle.addAttribute(.attachment, value: symbol, range: NSRange(location: symbolLocation, length: 1))
        }
        // The program's icon wears the program's name's colour, the character after it.
        if let iconLocation {
            let ink =
                iconLocation + 1 < composedLength
                ? styledTitle.attribute(.foregroundColor, at: iconLocation + 1, effectiveRange: nil) as? NSColor ?? brightColor
                : brightColor
            if let icon = ProcessIcons.attachment(forKey: processIconKey, font: titleFont, ink: ink, ground: processIconGround) {
                styledTitle.addAttribute(.attachment, value: icon, range: NSRange(location: iconLocation, length: 1))
            }
        }

        // The bell goes last, after every range above has been measured, so
        // nothing the spans are cut from moves. It lands where the chevron
        // does on a hovered window — the field grows by its width and the
        // chevron steps past it, so the two never sit on top of each other.
        if hasUnheardBell, let bell = trailingBellRun(for: titleField, ink: brightColor) {
            if composedLength > 0 {
                styledTitle.addAttribute(
                    .kern,
                    value: BellRunPolicy.gapBeforeGlyph,
                    range: composed.rangeOfComposedCharacterSequence(at: composedLength - 1)
                )
            }
            styledTitle.append(bell)
        }

        // A standing chip wears the host's tag as its capsule, so the run
        // leaves that marker out; a withdrawn one leaves it to the run. The
        // chip's size is in the style key, so either change restyles.
        let markerRun = TitlebarTagChip.attributedRun(
            for: tagMarkers,
            titleFont: titleFont,
            uncoloredFill: dimColor,
            tint: titlebarTint,
            omitsHostTag: connectionSize.width > 0,
            isTuckedUnderHostChip: isTuckedUnderHostChip,
            iconDrawing: PhosphorIcons.image(named:weight:side:color:),
            style: tagStyle,
            appearance: titleField.effectiveAppearance
        )
        // The stack's last pill reaches under the chip's start by the
        // geometry's overlap, cut by it, so the chip stands that far back over
        // the stack. The reserved span gives the overlap back, since the
        // stack's image already holds it; text layout cannot overlap two
        // attachments, so the chip is placed rather than laid out there.
        let chipOverlap =
            isTuckedUnderHostChip && markerRun.length > 0 ? TitlebarCapsuleGeometry(titleFont: titleFont).overlap : 0
        let connectionRun = NSMutableAttributedString(string: "")
        if connectionSize.width > 0 {
            // The gap is part of the reserved span itself. A kern on an
            // attachment character is not applied by the title field's layout,
            // so the title ran up against the chip with no air between them.
            let reservedGap = composedLength > 0 ? Self.hostIdentityGap : 0
            let spacer = NSTextAttachment()
            spacer.image = NSImage(size: connectionSize, flipped: false) { _ in true }
            spacer.bounds = NSRect(
                x: 0,
                y: -(connectionIndicator?.hostLabelBaselineOffsetFromBottom ?? 0),
                width: connectionSize.width - chipOverlap + reservedGap,
                height: connectionSize.height
            )
            connectionRun.append(NSAttributedString(attachment: spacer))
        }
        if markerRun.length > 0 || connectionRun.length > 0 {
            let withMarkers = NSMutableAttributedString(attributedString: markerRun)
            withMarkers.append(connectionRun)
            withMarkers.append(styledTitle)
            titleField.attributedStringValue = withMarkers
        } else {
            titleField.attributedStringValue = styledTitle
        }
        identitySpans = Self.spans(
            markerLength: markerRun.length,
            connectionLength: connectionRun.length,
            titleLength: titleLength,
            directoryRange: directoryRange,
            statusRange: statusRange,
            programStatusRange: programStatusRange
        )
        let accessibleTitle = isHostFallbackTitle && hasConnectionIndicator ? "" : window.title
        let spokenTitle =
            connectionDescription.isEmpty
            ? accessibleTitle : (accessibleTitle.isEmpty ? connectionDescription : "\(connectionDescription) \(accessibleTitle)")
        var spokenLabel =
            TitlebarTagChip.accessibilityDescription(for: tagMarkers).map { "\($0). \(spokenTitle)" }
            ?? spokenTitle
        if !statusTitle.isEmpty {
            spokenLabel += ", \(statusTitle)"
        }
        if hasProgramStatus {
            // The symbol is not read, so the words it stands for are.
            spokenLabel += ", \(programStatusSpokenText.isEmpty ? programStatus : programStatusSpokenText)"
        }
        if hasUnheardBell {
            spokenLabel += ", \(BellMark.accessibilityDescription)"
        }
        titleField.setAccessibilityLabel(spokenLabel)
        sizeTitleField(titleField, in: strip)
        if connectionSize.width > 0, let indicator = connectionIndicator {
            let reserved = TitleTextLayout(titleField).bounds(for: NSRange(location: markerRun.length, length: 1))
            let baseline =
                titleField.isFlipped
                ? titleField.firstBaselineOffsetFromTop : titleField.bounds.height - titleField.firstBaselineOffsetFromTop
            let indicatorBaseline =
                titleField.isFlipped
                ? connectionSize.height - indicator.hostLabelBaselineOffsetFromBottom : indicator.hostLabelBaselineOffsetFromBottom
            indicator.frame.origin = NSPoint(
                x: reserved.minX - chipOverlap,
                y: baseline - indicatorBaseline
            )
        }
        lastAppliedStyle = StyleKey(
            title: title,
            statusTitle: statusTitle,
            programStatus: programStatus,
            programStatusSymbol: statusSymbol,
            processIconKey: processIconKey,
            dimColor: dimColor,
            brightColor: brightColor,
            detailColor: detailColor,
            hoverSignature: hoverSignature,
            fieldWidth: titleField.frame.width,
            fieldHeight: titleField.frame.height,
            titleFont: titleFont,
            directorySegment: titleDirectorySegment,
            prefixBeforeDirectory: titlePrefixBeforeDirectory,
            markerSignature: TitlebarTagMarker.signature(of: tagMarkers),
            tagStyle: tagStyle,
            appearanceName: titleField.effectiveAppearance.name,
            connectionSize: connectionSize,
            connectionDescription: connectionDescription,
            isTuckedUnderHostChip: isTuckedUnderHostChip,
            bellSignature: bellSignature,
            backingScale: titleBackingScale
        )
    }

    /// The trailing bell as a run of the title string.
    ///
    /// An attachment rather than a view, so the bell rides the title's own
    /// baseline and AppKit's own measurement: the field sizes to `cellSize`,
    /// which counts an attachment, and the trailing limit the title may grow
    /// to already allows the chevron its room past that. A view would need its
    /// own placement, its own clock against the title's restyles, and a second
    /// answer to where the title ends.
    ///
    /// - Parameters:
    ///   - titleField: The field whose face and appearance the glyph matches.
    ///   - ink: The title's own colour, which already recedes when the window
    ///     holds neither key nor main; the bell wears it unchanged.
    /// - Returns: The run, or nil where the system has no such symbol.
    /// A program's status symbol as an attachment in the title: the symbol
    /// tinted whole, its cutouts kept, at the status text's size, centred on
    /// that text's cap-height band as the bell is on the title's.
    ///
    /// - Parameters:
    ///   - symbol: The status's symbol.
    ///   - ink: What it is drawn in.
    ///   - appearance: The appearance a semantic ink resolves under.
    /// - Returns: The attachment, or nil where the system has no such symbol.
    /// Where the program's icon goes in a title: after its directory and that
    /// directory's separator, where the program's name begins, or at the
    /// start of a title that opens with no directory.
    ///
    /// - Parameter title: The woven title.
    /// - Returns: A UTF-16 offset into it.
    private func processIconLocation(in title: String) -> Int {
        let text = title as NSString
        let prefixLength = (titlePrefixBeforeDirectory as NSString).length
        let directoryLength = (titleDirectorySegment as NSString).length
        guard directoryLength > 0, title.hasPrefix(titlePrefixBeforeDirectory), prefixLength + directoryLength <= text.length,
            text.substring(with: NSRange(location: prefixLength, length: directoryLength)) == titleDirectorySegment
        else {
            return 0
        }
        var end = prefixLength + directoryLength
        let separator = Self.windowTitleSeparator as NSString
        if end + separator.length <= text.length,
            text.substring(with: NSRange(location: end, length: separator.length)) == Self.windowTitleSeparator
        {
            end += separator.length
        }
        // A title that is its directory alone names no program after it.
        return end < text.length ? end : 0
    }

    /// The program's status symbol as an attachment in the status's face: in
    /// its ink, and standing on the status's cap band by its own, as
    /// ``TitleIconPlacement`` places every icon in the title row.
    ///
    /// - Parameters:
    ///   - symbol: The status's symbol.
    ///   - ink: The ink it is drawn in.
    ///   - appearance: The appearance a dynamic ink resolves under.
    ///   - backingScale: The pixels per point the title is drawn at.
    /// - Returns: The attachment, nil for a symbol the system does not know.
    private func statusSymbolAttachment(
        _ symbol: TitleStatusSymbol,
        ink: NSColor,
        appearance: NSAppearance,
        backingScale: CGFloat
    ) -> NSTextAttachment? {
        let font = statusFont
        guard
            let glyph = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium))
        else {
            return nil
        }
        var resolved = ink
        appearance.performAsCurrentDrawingAppearance { resolved = ink.usingColorSpace(.sRGB) ?? ink }
        let tinted = resolved
        let image = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            tinted.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // The tinted copy is the glyph's size; the glyph carries the cap band.
        let bottom = TitleIconPlacement.bottomAboveBaseline(of: glyph, capHeight: font.capHeight, backingScale: backingScale)
        attachment.bounds = NSRect(origin: NSPoint(x: 0, y: bottom), size: image.size)
        return attachment
    }

    private func trailingBellRun(for titleField: NSTextField, ink: NSColor) -> NSAttributedString? {
        let font = titleField.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        guard
            let image = BellMark.image(
                pointSize: font.pointSize - BellRunPolicy.pointSizeBelowTitle,
                ink: ink,
                statusColor: bellStatusColor,
                appearance: titleField.effectiveAppearance
            )
        else {
            return nil
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Centred on the cap-height band rather than sat on the baseline: a
        // bell hung from the baseline reads as sunk beside text whose mass is
        // above it, and the descender the glyph does not have is the gap.
        attachment.bounds = NSRect(
            x: 0,
            y: ((font.capHeight - image.size.height) / 2).rounded(),
            width: image.size.width,
            height: image.size.height
        )
        return NSAttributedString(attachment: attachment)
    }

    /// Partitions the composed string into named spans: the chip run, the dim
    /// directory run, the status suffix, a program's status after it, and
    /// whatever title text remains as process spans on either side of the
    /// directory.
    private static func spans(
        markerLength: Int,
        connectionLength: Int,
        titleLength: Int,
        directoryRange: NSRange?,
        statusRange: NSRange?,
        programStatusRange: NSRange?
    ) -> [TitleIdentitySpan] {
        var spans: [TitleIdentitySpan] = []
        if markerLength > 0 {
            spans.append(
                TitleIdentitySpan(kind: .markers, range: NSRange(location: 0, length: markerLength))
            )
        }
        let prefixLength = markerLength + connectionLength
        if connectionLength > 0 {
            spans.append(
                TitleIdentitySpan(
                    kind: .process,
                    range: NSRange(location: markerLength, length: connectionLength)
                )
            )
        }
        var cursor = prefixLength
        if let directoryRange {
            let shifted = NSRange(
                location: directoryRange.location + prefixLength,
                length: directoryRange.length
            )
            if shifted.location > cursor {
                spans.append(
                    TitleIdentitySpan(
                        kind: .process,
                        range: NSRange(location: cursor, length: shifted.location - cursor)
                    )
                )
            }
            spans.append(TitleIdentitySpan(kind: .directory, range: shifted))
            cursor = NSMaxRange(shifted)
        }
        let titleEnd = prefixLength + titleLength
        if titleEnd > cursor {
            spans.append(
                TitleIdentitySpan(kind: .process, range: NSRange(location: cursor, length: titleEnd - cursor))
            )
        }
        if let statusRange {
            spans.append(
                TitleIdentitySpan(
                    kind: .status,
                    range: NSRange(location: statusRange.location + prefixLength, length: statusRange.length)
                )
            )
        }
        if let programStatusRange {
            spans.append(
                TitleIdentitySpan(
                    kind: .programStatus,
                    range: NSRange(
                        location: programStatusRange.location + prefixLength,
                        length: programStatusRange.length
                    )
                )
            )
        }
        return spans
    }

    /// AppKit sizes each titlebar field to `ceil(cellSize)` — text plus the
    /// 4-point borderless padding. The composed string is wider than the plain
    /// title AppKit measured, so the field grows trailing-only to that same
    /// formula: AppKit keeps owning the leading edge (and the icon gap), and
    /// the width is clamped so the chevron keeps its room inside the 4-point
    /// titlebar inset. Tag attachments can be taller than the title font, so
    /// the field also takes the cell's measured height around the same center.
    private func sizeTitleField(_ titleField: NSTextField, in strip: NSView) {
        guard let cell = titleField.cell, let superview = titleField.superview else {
            return
        }
        var frame = titleField.frame
        let cellSize = cell.cellSize
        let natural = min(
            ceil(cellSize.width),
            max(0, trailingLayoutLimit(in: strip, superview: superview) - frame.origin.x)
        )
        let height = ceil(cellSize.height)
        guard abs(frame.width - natural) > 0.5 || abs(frame.height - height) > 0.5 else {
            return
        }
        frame.size.width = natural
        frame.origin.y += (frame.height - height) / 2
        frame.size.height = height
        titleField.frame = frame
    }

    /// The x the title may not grow past, in the field's own coordinate space.
    ///
    /// The chevron needs its room past the text, and the window also parks
    /// accessory controllers at the trailing end (remote status, presence, the
    /// chrome bar carrying the secure-input lock and tmux pill). Measuring
    /// against the titlebar's full width instead lets a long title grow
    /// underneath any of them, so every visible trailing accessory is
    /// consulted.
    private func trailingLayoutLimit(in strip: NSView, superview: NSView) -> CGFloat {
        var limit =
            superview.convert(strip.bounds, from: strip).maxX - 4 - documentActions.trailingRoom
        for controller in window?.titlebarAccessoryViewControllers ?? []
        where controller.layoutAttribute == .right || controller.layoutAttribute == .trailing {
            let view = controller.view
            guard !view.isHidden, view.superview != nil, view.frame.width > 0 else {
                continue
            }
            limit = min(limit, superview.convert(view.bounds, from: view).minX - 4)
        }
        return limit
    }

    private func stampRestingLookIfIdle() {
        guard phase == .hidden || phase == .dwelling, !ownsSlot else {
            return
        }
        guard let icon = documentButton(in: window) else {
            layoutDocumentActions()
            return
        }
        icon.alphaValue = shouldAnimateIdentityOpacity ? 0 : 1
        icon.isHidden = true
        icon.isEnabled = false
        layoutDocumentActions()
    }

    private func promoteIfAlwaysVisible() {
        guard alwaysVisible, phase == .hidden, window?.representedURL != nil else {
            return
        }
        phase = .revealed
        sessionFrames = nil
        if let icon = documentButton(in: window) {
            clearFlightAnimations(of: icon)
            icon.isHidden = false
            icon.alphaValue = 1
            icon.isEnabled = true
        }
        layoutDocumentActions()
    }

    private func clearFlightAnimations(of views: NSView?...) {
        let resolvedViews: [NSView?]
        if views.isEmpty {
            resolvedViews = [
                documentButton(in: window),
                titlebarStrip(in: window).flatMap(titleTextField(in:)),
                documentActions.titlebarView,
            ]
        } else {
            resolvedViews = views
        }
        for view in resolvedViews {
            for key in FlightKey.all {
                view?.layer?.removeAnimation(forKey: key)
            }
            view?.layer?.mask = nil
        }
    }

    @discardableResult
    private func installDocumentActions(in strip: NSView, beside titleField: NSTextField) -> NSView {
        let actionsView = documentActions.titlebarView
        guard let host = titleField.superview else {
            return actionsView
        }
        let wasApplying = isApplyingTitleLayout
        isApplyingTitleLayout = true
        defer {
            isApplyingTitleLayout = wasApplying
        }
        // The control lives beside the field in one superview, so whatever
        // moves the title — a tab bar joining, full screen — moves both or
        // neither, and the frames compare without conversion.
        if actionsView.superview !== host {
            actionsView.removeFromSuperview()
            host.addSubview(actionsView, positioned: .above, relativeTo: titleField)
        } else if !documentActions.isPopoverShown, !documentActions.isTitlePressInFlight,
            let controlIndex = host.subviews.firstIndex(of: actionsView),
            let fieldIndex = host.subviews.firstIndex(of: titleField),
            controlIndex < fieldIndex
        {
            // AppKit recreates the title field when the title changes, and the
            // fresh field lands on top — a click on the text then drags the
            // window instead of reaching the control. Reordered only when
            // actually wrong, because a re-add dismisses a popover anchored
            // on the control, and never under a press: a view removed and
            // added mid-gesture receives no more of that gesture's events,
            // which cancels the drag the press was starting.
            host.addSubview(actionsView, positioned: .above, relativeTo: titleField)
        }
        observeGeometry(of: titleField)
        documentActions.layout(
            overTitleFrame: titleField.frame,
            baselineFromTop: titleField.firstBaselineOffsetFromTop,
            spans: measuredSpans(for: titleField)
        )
        actionsView.isHidden = false
        actionsView.alphaValue = 1
        return actionsView
    }

    /// The stored spans with their horizontal extents measured from the line
    /// the field actually typeset — kerns, chips and fonts included — plus the
    /// borderless cell's own leading padding.
    private func measuredSpans(for titleField: NSTextField) -> [TitleIdentitySpan] {
        guard !identitySpans.isEmpty else {
            return []
        }
        let layout = TitleTextLayout(titleField)
        return identitySpans.map { span in
            var measured = span
            let bounds = layout.bounds(for: span.range)
            measured.horizontalExtent = bounds.minX...bounds.maxX
            return measured
        }
    }

    /// AppKit moves the title without telling anyone — the field drops a
    /// measured 36 points when a tab bar joins — so the field's own frame
    /// notification is the relayout trigger; it fires for every cause, named or
    /// not.
    private func observeGeometry(of titleField: NSTextField) {
        guard observedTitleField !== titleField || observedTitleHost !== titleField.superview else {
            return
        }
        if let observedTitleField {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: observedTitleField
            )
        }
        if let observedTitleHost {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: observedTitleHost
            )
        }
        observedTitleField = titleField
        observedTitleHost = titleField.superview
        titleField.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(titleGeometryDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: titleField
        )
        if let host = observedTitleHost {
            host.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(titleGeometryDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: host
            )
        }
    }

    @objc
    public func titleGeometryDidChange(_ notification: Notification) {
        _ = notification
        guard !isApplyingTitleLayout else {
            return
        }
        layoutDocumentActions()
        reinstallTrackingIfNeeded()
    }

    private func layoutDocumentActions() {
        guard let window,
            let strip = titlebarStrip(in: window)
        else {
            uninstallDocumentActions()
            return
        }
        let wasApplying = isApplyingTitleLayout
        isApplyingTitleLayout = true
        defer {
            isApplyingTitleLayout = wasApplying
        }
        strip.layoutSubtreeIfNeeded()
        applyStoredTitleStyle()
        // Every relayout, because AppKit rebuilds title-bar controls on its own
        // schedule and a copy left on a discarded button restores nothing.
        refreshSolidProxy()
        guard let titleField = titleTextField(in: strip) else {
            uninstallDocumentActions()
            return
        }
        _ = installDocumentActions(in: strip, beside: titleField)
    }

    private func uninstallDocumentActions() {
        let actionsView = documentActions.titlebarView
        clearFlightAnimations(of: actionsView)
        actionsView.isHidden = true
        actionsView.removeFromSuperview()
        documentActions.closePopover()
    }

    private func opacityAnimation(from: CGFloat, to: CGFloat, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = Policy.timingFunction
        return animation
    }

    private func positionAnimation(from: CGPoint, to: CGPoint, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: from)
        animation.toValue = NSValue(point: to)
        animation.duration = duration
        animation.timingFunction = Policy.timingFunction
        return animation
    }

    private func documentButton(in window: NSWindow?) -> NSButton? {
        window?.standardWindowButton(.documentIconButton)
    }

    private func titlebarStrip(in window: NSWindow?) -> NSView? {
        guard let window else {
            return nil
        }
        if !window.styleMask.contains(.fullScreen) {
            let root = window.contentView?.superview ?? window.contentView
            return findSubview(ofClass: "NSTitlebarContainerView", from: root)
        }
        for candidate in NSApp.windows where candidate.parent === window {
            if NSStringFromClass(type(of: candidate)) == "NSToolbarFullScreenWindow" {
                return findSubview(ofClass: "NSTitlebarContainerView", from: candidate.contentView)
            }
        }
        return nil
    }

    /// The window title is a direct subview of `NSTitlebarView`. A tab's label
    /// is an `NSTextField` carrying the same string, but it lives inside the
    /// accessory clip view several levels down, so depth — not content or
    /// width — is what separates the two.
    private func titleTextField(in root: NSView?) -> NSTextField? {
        guard let titlebar = titlebarView(under: root) else {
            return nil
        }
        var best: NSTextField?
        for case let field as NSTextField in titlebar.subviews
        where !field.isHidden && field.frame.width > 0 {
            if best == nil || field.frame.width > best!.frame.width {
                best = field
            }
        }
        return best
    }

    /// The `NSTitlebarView` holding the title row — the container itself, or
    /// its immediate subview.
    private func titlebarView(under root: NSView?) -> NSView? {
        guard let root else {
            return nil
        }
        if NSStringFromClass(type(of: root)) == "NSTitlebarView" {
            return root
        }
        for subview in root.subviews where NSStringFromClass(type(of: subview)) == "NSTitlebarView" {
            return subview
        }
        return nil
    }

    private func findSubview(ofClass className: String, from root: NSView?) -> NSView? {
        guard let root else {
            return nil
        }
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if NSStringFromClass(type(of: view)) == className {
                return view
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }
}

private final class TitleStripHoverOwner: NSResponder {
    weak var controller: ProxyIconRevealController?

    override func mouseEntered(with event: NSEvent) {
        controller?.titleStripHoverBegan(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.titleStripHoverMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        controller?.titleStripHoverEnded(with: event)
    }
}
