// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// Whether a click on the title identity is one control or several.
///
/// `.wholeTitle` is the native shape: the row is a single button and one
/// popover serves it. `.components` routes a click through the span under the
/// pointer, opening the shared popover on that span's own field.
public enum TitleActivationScope {
    case wholeTitle
    case components
}

/// Which text the rollover lifts to the bright colour.
///
/// `.none` changes no text. `.wholeTitle` lifts every dim run together;
/// `.component` lifts only the span under the pointer.
public enum TitleHoverHighlight {
    case none
    case wholeTitle
    case component
}

/// What the rollover shows over the title identity. The two axes are
/// independent: the chevron's fade and the text lift can each be on alone.
public struct TitleHoverStyle: Equatable {
    /// Fades the chevron in while the row is hovered.
    var revealsChevron = true
    /// Which text the rollover lifts.
    var highlight: TitleHoverHighlight = TitleHoverHighlight.none
}

/// The face the dimensions run wears.
public struct TitleStatusFace: Equatable {
    /// Its size relative to the title's 13 points.
    package enum Size: Equatable {
        /// The title's own size, the native autosave status's choice.
        case title
        /// A point under the title.
        case smaller

        var pointSize: CGFloat {
            switch self {
            case .title:
                return NSFont.systemFontSize
            case .smaller:
                return NSFont.systemFontSize - 1
            }
        }
    }

    package var size: Size
    package var weight: NSFont.Weight

    package init(size: Size = .title, weight: NSFont.Weight = .medium) {
        self.size = size
        self.weight = weight
    }
}

/// Timing the rollover wears.
public struct TitleRevealTiming: Equatable {
    /// How long the pointer rests on the title before the reveal begins. The
    /// dwell filters cross-traffic: a pointer crossing the titlebar spends
    /// 30-50 ms in it, so every case here ignores a fly-by; they differ only
    /// in how quickly a rested pointer is answered.
    enum RevealDwell: Equatable {
        /// AppKit's own 0.25-second document-proxy hysteresis.
        case native
        /// 0.15 seconds — several crossing-times long, but reads as immediate
        /// when the pointer actually stops.
        case quick
        /// No rest: the reveal starts on entry.
        case immediate

        var interval: TimeInterval {
            switch self {
            case .native:
                return 0.25
            case .quick:
                return 0.15
            case .immediate:
                return 0
            }
        }
    }

    /// How the retreat flight, the chevron's fade-out, and a highlight's
    /// settle run once the exit dwell has decided: on the entry's own
    /// 0.3-second clock, shortened to `fastExitDuration`, or with no
    /// animation at all.
    enum ExitStyle: Equatable {
        case matched
        case fast
        case instant
    }

    var revealDwell: RevealDwell = .native
    var exitStyle: ExitStyle = .matched
    /// Seconds a `.fast` exit takes.
    var fastExitDuration: TimeInterval = 0.12
}

/// One named span of the composed title string.
public struct TitleIdentitySpan {
    enum Kind: CaseIterable {
        case markers
        case directory
        case process
        case status
        /// A program's own status label, after the app title.
        case programStatus
    }

    let kind: Kind
    /// The span's range in the title field's attributed string.
    let range: NSRange
    /// The span's horizontal extent in the identity control's coordinates,
    /// measured from the laid-out line at layout time.
    var horizontalExtent: ClosedRange<CGFloat> = 0...0
}

/// Owns the titlebar document-actions popover and the surface that makes the
/// whole title identity one control.
///
/// The identity's text — tag chips, directory, process, and the trailing
/// dimensions — is a single attributed string in AppKit's own title field, so
/// one baseline and one separator rule cover all of it, and AppKit keeps
/// owning its placement. Only two views exist beside the field: the chevron,
/// because it fades, and a transparent control spanning the row, because text
/// in a titlebar field cannot take a click.
@objc(TitlebarDocumentActionsController)
@MainActor
public final class TitlebarDocumentActionsController: NSObject, NSPopoverDelegate {
    private let identityControl = TitlebarTitleIdentityControl()
    private let editor = TitlebarDocumentActionsPopoverViewController()
    private lazy var popover: NSPopover = makePopover() {
        didSet {
            oldValue.delegate = nil
        }
    }
    private weak var previousFirstResponder: NSResponder?
    private var titleRegionHoverState = false
    private var clickThroughMonitor: Any?
    private var dismissalWatchdog: Timer?
    private weak var observedPopoverWindow: NSWindow?
    /// Deduplicates the three dismissal ears — delegate, popover notification,
    /// and the popover window's own willClose — of which only the last has
    /// proven reliable when the close sequence is interrupted.
    private var announcedPopoverVisible = false
    /// A press on the control while the popover stands dismisses it through
    /// the transient behaviour before the control ever hears the press; the
    /// release's action then reads as "open" and resurrects what the press
    /// just closed. The press is remembered so its release is a dismissal.
    private var pressDismissedPopoverAt: TimeInterval = 0

    /// Refreshes the public values immediately before the popover is presented.
    @objc
    public var willPresent: (() -> Void)?

    /// Applies the two override fields. An empty string clears an override.
    @objc
    public var applyTitles: ((String, String) -> Void)?

    /// Applies an explicit cell-grid size after both values pass validation.
    @objc
    public var applyGridSize: ((Int, Int) -> Void)?

    /// Applies the window's hand-set tag names, replacing the previous set.
    @objc
    public var applyTags: (([String]) -> Void)?

    /// Opens the indexed tag rule, or the window's matched rule for -1.
    @objc
    public var openTagRules: ((Int) -> Void)?

    /// The window's hand-set tag names, refreshed by `willPresent`.
    @objc
    public var tags: [String] = []

    /// The tags the window's `[[tags]]` rules give it, refreshed by
    /// `willPresent`: shown beside the hand-set names, never edited as them.
    public var ruleTags: [TitlebarRuleTag] = []

    /// Why the size row cannot act, or nil when it can. Refreshed by
    /// `willPresent`; shown beside the disabled fields rather than hiding them.
    @objc
    public var sizeUnavailableReason: String?

    /// Reports the transient popover lifecycle so hover retreat can be gated.
    @objc
    public var popoverVisibilityDidChange: ((Bool) -> Void)?

    /// Reports transitions across the chevron's actual image rect. The owner
    /// uses this to reproduce `NSThemeAutosaveButton`'s separate suffix
    /// hysteresis without coupling it to document-proxy rollover.
    var imageRolloverDidChange: ((Bool) -> Void)?

    /// Reports the pointer entering or leaving the title row; the owner drives
    /// the shared rollover state through its exit dwell.
    var pointerPresenceDidChange: ((Bool) -> Void)?

    /// Reports the trailing status changing, so the owner can recompose the
    /// title string that carries it.
    @objc
    public var statusTitleDidChange: (() -> Void)?

    /// Reports hover-state changes so the owner recolours the title text in
    /// step with the chevron's fade. Arguments are hovered and animated.
    var titleHoverDidChange: ((Bool, Bool) -> Void)?

    @objc
    public var windowTitleOverride = ""

    @objc
    public var tabTitleOverride = ""

    @objc
    public var columns = 80

    @objc
    public var rows = 24

    /// The transparent control spanning the title row. Also the popover anchor.
    @objc
    public var titlebarView: NSView { identityControl }

    /// How far past the title field's frame the chevron needs, so the title's
    /// growth limit can leave room for it.
    @objc
    public var trailingRoom: CGFloat { TitlebarTitleIdentityControl.chevronRoom }

    /// Whether the row acts as one control or per span. Both scopes share the
    /// one popover; `.components` opens it focused on the clicked span's field.
    var activationScope: TitleActivationScope = .wholeTitle {
        didSet {
            identityControl.activationScope = activationScope
            updateSpanTracking()
        }
    }

    /// What the rollover shows. The owner reads the highlight axis when it
    /// restyles; the control needs the chevron axis and whether spans matter.
    var hoverStyle = TitleHoverStyle() {
        didSet {
            updateSpanTracking()
            identityControl.setChevronRevealed(
                titleRegionHoverState && identityControl.hasAction && hoverStyle.revealsChevron,
                animated: false
            )
        }
    }

    private func updateSpanTracking() {
        identityControl.tracksHoveredSpan =
            activationScope == .components || hoverStyle.highlight == .component
    }

    /// How long the chevron's fade-out runs; the owner sets it from its
    /// reveal timing so the arrow leaves with the flight it accompanies.
    var chevronExitDuration: TimeInterval {
        get { identityControl.exitFadeDuration }
        set { identityControl.exitFadeDuration = newValue }
    }

    /// The span under the pointer, when the scope resolves spans.
    var hoveredSpanKind: TitleIdentitySpan.Kind? { identityControl.hoveredSpanKind }

    /// Reports the pointer crossing between spans while over the row.
    var hoveredSpanDidChange: ((TitleIdentitySpan.Kind?) -> Void)?

    /// The titlebar status composed after the title, for example `80×24`.
    @objc
    public var statusTitle = "" {
        didSet {
            guard oldValue != statusTitle else {
                return
            }
            statusTitleDidChange?()
        }
    }

    /// An optional custom context menu for the reusable title-identity action.
    @objc
    public var contextMenu: NSMenu? {
        didSet {
            identityControl.customContextMenu = contextMenu
        }
    }

    /// A live read of the ground truth, never a tracked flag:
    /// `NSPopover.isShown` alone can wedge true after an interrupted close —
    /// measured: neither `popoverDidClose` nor its notification arrives —
    /// and a flag fed by those callbacks wedges with it. The window either
    /// holds the editor visibly or it does not.
    /// Whether a press on the title row is in flight: between its mouse-down
    /// and its release, or its hand-off to the window drag.
    var isTitlePressInFlight: Bool { identityControl.isPressInFlight }

    @objc
    public var isPopoverShown: Bool {
        popover.isShown && (editor.viewIfLoaded?.window?.isVisible ?? false)
    }

    /// The titlebar's resolved normal foreground, which the chevron wears.
    @objc
    public var foregroundColor: NSColor = .labelColor {
        didSet {
            identityControl.chevronColor = foregroundColor
        }
    }

    /// Mirrors AppKit's autosave-button rollover state: the chevron fades and
    /// the owner is told to lift the title's colours.
    @objc
    public var isTitleRegionHovered: Bool {
        get { titleRegionHoverState }
        set { setTitleRegionIsHovered(newValue, animated: true) }
    }

    func setTitleRegionIsHovered(_ isHovered: Bool, animated: Bool) {
        guard titleRegionHoverState != isHovered else {
            return
        }
        titleRegionHoverState = isHovered
        identityControl.isRolloverPresented = isHovered
        identityControl.setChevronRevealed(
            isHovered && identityControl.hasAction && hoverStyle.revealsChevron,
            animated: animated
        )
        titleHoverDidChange?(isHovered, animated)
    }

    /// Frames the control over the title row and hangs the chevron off the
    /// title's own baseline.
    ///
    /// - Parameters:
    ///   - titleFrame: The title field's frame, in the shared superview.
    ///   - baselineFromTop: The title field's first-baseline offset.
    ///   - spans: The composed title's spans with their measured extents.
    func layout(
        overTitleFrame titleFrame: NSRect,
        baselineFromTop: CGFloat,
        spans: [TitleIdentitySpan]
    ) {
        identityControl.frame = NSRect(
            x: titleFrame.minX,
            y: titleFrame.minY,
            width: titleFrame.width + TitlebarTitleIdentityControl.chevronRoom,
            height: titleFrame.height
        )
        identityControl.spans = spans
        identityControl.layoutChevron(baselineFromTop: baselineFromTop)
        // A committed title edit recomposes the row under a standing popover;
        // the anchor moved, so the popover follows it rather than pointing at
        // the title's previous end.
        if isPopoverShown {
            popover.positioningRect = identityControl.popoverAnchorRect()
        }
    }

    override init() {
        super.init()
        identityControl.target = self
        identityControl.action = #selector(showPopover(_:))
        identityControl.imageRolloverDidChange = { [weak self] isOverImage in
            self?.imageRolloverDidChange?(isOverImage)
        }
        identityControl.pointerPresenceDidChange = { [weak self] isInside in
            self?.pointerPresenceDidChange?(isInside)
        }
        identityControl.hoveredSpanDidChange = { [weak self] kind in
            self?.hoveredSpanDidChange?(kind)
        }
        editor.applyTitles = { [weak self] windowTitle, tabTitle in
            guard let self else {
                return
            }
            self.windowTitleOverride = windowTitle
            self.tabTitleOverride = tabTitle
            self.applyTitles?(windowTitle, tabTitle)
        }
        editor.applyGridSize = { [weak self] columns, rows in
            guard let self else {
                return
            }
            self.columns = columns
            self.rows = rows
            self.applyGridSize?(columns, rows)
        }
        editor.applyTags = { [weak self] tags in
            guard let self else {
                return
            }
            self.tags = tags
            self.applyTags?(tags)
        }
        editor.openTagRules = { [weak self] index in
            self?.openTagRules?(index)
        }
    }

    @objc
    public func showPopover(_ sender: Any?) {
        if isPopoverShown {
            popover.performClose(sender)
            return
        }
        if ProcessInfo.processInfo.systemUptime - pressDismissedPopoverAt < 1 {
            pressDismissedPopoverAt = 0
            return
        }
        if popover.isShown {
            // The popover wedged: it says shown with no window on screen, and
            // measured, neither close() nor show() brings it back. A wedged
            // popover is dead; the editor moves to a fresh one.
            popover.delegate = nil
            NotificationCenter.default.removeObserver(
                self,
                name: NSPopover.didCloseNotification,
                object: popover
            )
            popover.close()
            popover.contentViewController = nil
            popover = makePopover()
        }

        willPresent?()
        editor.configure(
            windowTitleOverride: windowTitleOverride,
            tabTitleOverride: tabTitleOverride,
            columns: columns,
            rows: rows,
            tags: tags,
            ruleTags: ruleTags,
            sizeUnavailableReason: sizeUnavailableReason
        )
        previousFirstResponder = identityControl.window?.firstResponder
        popover.show(
            relativeTo: identityControl.popoverAnchorRect(),
            of: identityControl,
            preferredEdge: .minY
        )
        editor.focus(initialField)
        installClickThroughMonitor()
        observePopoverWindow()
        startDismissalWatchdog()
    }

    /// Every close signal this environment offers has measured silent at
    /// least once — delegate, popover notification, window willClose,
    /// occlusion. The watchdog reads the live state instead of waiting to be
    /// told, so a dismissal is noticed within a tick no matter how it
    /// happened. It runs only while the popover is believed open.
    private func startDismissalWatchdog() {
        dismissalWatchdog?.invalidate()
        let timer = Timer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(dismissalWatchdogFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        dismissalWatchdog = timer
    }

    @objc
    public func dismissalWatchdogFired() {
        guard !isPopoverShown else {
            verifyPopoverStillStands()
            return
        }
        handlePopoverDismissed()
    }

    /// Closes a popover whose tab is no longer the one on screen.
    ///
    /// A popover belongs to its tab. Deselecting that tab takes the popover
    /// off the screen and announces nothing — measured: not `willClose`, not
    /// occlusion, not resign-key on either window — while the popover goes on
    /// reporting `isShown` and its window `isVisible`. Every rollover gate
    /// reads that belief, so left uncorrected the folder icon and chevron stay
    /// suppressed for the life of the window, and the click that would rebuild
    /// the popover cannot land because the identity takes clicks only while
    /// the rollover it is suppressing is presented.
    ///
    /// The tab group is the account that does change: the anchor stops being
    /// its group's selected window the moment the user leaves, and this runs
    /// every tick while the popover is believed open, so the close lands while
    /// the tab is away. By the time the tab is selected again there is nothing
    /// left to ask, which is what makes a question that is ambiguous for a
    /// reselected tab the right one for a watchdog.
    ///
    /// The window server's on-screen list was the first answer tried and is
    /// not this one: behind a locked screen every window stays ordered in, so
    /// the list never changed on a tab switch, and a locked screen is how the
    /// macOS test runner spends its day.
    private func verifyPopoverStillStands() {
        guard let anchor = identityControl.window else {
            return
        }
        let isAnchorAway: Bool
        if let group = anchor.tabGroup {
            isAnchorAway = group.selectedWindow !== anchor
        } else {
            isAnchorAway = !anchor.isVisible
        }
        guard isAnchorAway else {
            return
        }
        // Closed, not merely forgotten: a popover still reporting itself shown
        // meets the next press as a wedge to replace rather than one to reopen.
        popover.close()
        handlePopoverDismissed()
    }

    /// Watches, never consumes: while the popover stands, a press inside the
    /// control is stamped before the transient behaviour closes the popover,
    /// so the release knows what its press already did.
    ///
    /// A local monitor runs on the main thread but its closure is not
    /// statically isolated, and `NSEvent` may not cross an isolation
    /// boundary; the two facts the decision needs are read first, as values.
    private func installClickThroughMonitor() {
        removeClickThroughMonitor()
        clickThroughMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            let pressedWindow = event.window.map(ObjectIdentifier.init)
            let locationInWindow = event.locationInWindow
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown,
                    let window = self.identityControl.window,
                    pressedWindow == ObjectIdentifier(window)
                else {
                    return
                }
                let point = self.identityControl.convert(locationInWindow, from: nil)
                if self.identityControl.bounds.contains(point) {
                    self.pressDismissedPopoverAt = ProcessInfo.processInfo.systemUptime
                }
            }
            return event
        }
    }

    private func removeClickThroughMonitor() {
        if let clickThroughMonitor {
            NSEvent.removeMonitor(clickThroughMonitor)
            self.clickThroughMonitor = nil
        }
    }

    /// Which editor field takes focus when the popover opens: the whole-row
    /// scope starts at the title, the span scope starts at the clicked span's
    /// own field.
    private var initialField: TitlebarDocumentActionsPopoverViewController.Field {
        guard activationScope == .components,
            let span = identityControl.activatedSpanKind
        else {
            return .title
        }
        switch span {
        case .markers, .directory, .process:
            return .title
        case .status:
            return .columns
        case .programStatus:
            // Nothing in the popover edits a program's report; the title is the
            // field a click on the row opens to.
            return .title
        }
    }

    @objc
    public func closePopover() {
        popover.performClose(nil)
    }

    @objc
    public func invalidate() {
        handlePopoverDismissed()
        popover.delegate = nil
        popover.close()
        popoverVisibilityDidChange = nil
        imageRolloverDidChange = nil
        titleHoverDidChange = nil
        statusTitleDidChange = nil
        previousFirstResponder = nil
        identityControl.removeFromSuperview()
    }

    public func popoverWillShow(_ notification: Notification) {
        announcedPopoverVisible = true
        popoverVisibilityDidChange?(true)
    }

    private func observePopoverWindow() {
        guard let window = editor.viewIfLoaded?.window else {
            return
        }
        observedPopoverWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popoverWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        // The popover reuses its window and can leave the screen by ordering
        // out, posting no close at all; the occlusion change is the public
        // signal that still fires for that exit.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popoverWindowOcclusionDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    @objc
    public func popoverWindowWillClose(_ notification: Notification) {
        handlePopoverDismissed()
    }

    @objc
    public func popoverWindowOcclusionDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !window.isVisible else {
            return
        }
        handlePopoverDismissed()
    }

    /// Every way the popover leaves the screen funnels here once: the owner
    /// hears the visibility change, the monitor and window observation go,
    /// and focus returns to where it was.
    private func handlePopoverDismissed() {
        guard announcedPopoverVisible else {
            return
        }
        announcedPopoverVisible = false
        dismissalWatchdog?.invalidate()
        dismissalWatchdog = nil
        if let observedPopoverWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: observedPopoverWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeOcclusionStateNotification,
                object: observedPopoverWindow
            )
            self.observedPopoverWindow = nil
        }
        removeClickThroughMonitor()
        popoverVisibilityDidChange?(false)
        if let responder = previousFirstResponder, responder !== identityControl {
            identityControl.window?.makeFirstResponder(responder)
        }
        previousFirstResponder = nil
    }

    public func popoverWillClose(_ notification: Notification) {
        // Committing inside the close sequence ends editing and can re-lay
        // the titlebar under NSPopover's own teardown; the didClose that
        // should follow is then dropped and `isShown` wedges true. One turn
        // later the popover is gone and the commit runs on settled ground.
        DispatchQueue.main.async { [weak self] in
            self?.editor.commitPendingEdits()
        }
    }

    public func popoverDidClose(_ notification: Notification) {
        handlePopoverDismissed()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = editor
        popover.delegate = self
        // The delegate callback alone proved lossy: a close whose sequence is
        // interrupted skips it, wedging the tracked state. The notification is
        // the second, independent ear for the same fact.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popoverDidCloseByNotification(_:)),
            name: NSPopover.didCloseNotification,
            object: popover
        )
        return popover
    }

    @objc
    public func popoverDidCloseByNotification(_ notification: Notification) {
        handlePopoverDismissed()
    }
}

/// The transparent control spanning the title row, carrying the chevron.
///
/// A click anywhere on the row is the action; a press that travels past the
/// drag slop hands the event to the window instead, so the title remains a
/// place the window can be dragged by. The represented-document icon is not
/// covered — the control starts at the title field's leading edge — so the
/// icon keeps its own click and context menu.
@MainActor
private final class TitlebarTitleIdentityControl: NSControl {
    private enum Metrics {
        /// The native cell's 8 x 6 arrow. Its own metrics put it one point
        /// after the title rect, but the rect carries trailing padding the
        /// ink never reaches; the live TextEdit rollover shows about four
        /// points of air between the last glyph and the arrow.
        static let arrowSize = NSSize(width: 8, height: 6)
        static let textToArrow: CGFloat = 4
        /// The borderless field's side padding between its frame edge and the
        /// text it measured; the arrow gap counts from the text, not the frame.
        static let fieldTrailingPadding: CGFloat = 2
        /// The arrow's box hangs 1.5 points above the baseline it accompanies,
        /// which centres its ink on the status run's x-height band — where the
        /// live TextEdit rollover puts it, and one point under the value the
        /// native cell's image rect suggests on paper.
        static let arrowBottomAboveBaseline: CGFloat = 1.5
        /// Movement past this many points is a window drag, not a click.
        static let dragSlop: CGFloat = 4
        /// The chevron fades on the icon flight's clock, so the two arrivals
        /// read as one gesture.
        static let revealDuration: TimeInterval = 0.3
    }

    /// How far past the title field's frame the control extends for the arrow.
    static var chevronRoom: CGFloat {
        Metrics.textToArrow + Metrics.arrowSize.width - Metrics.fieldTrailingPadding
    }

    private let arrowView = NSImageView()
    private var trackingAreaReference: NSTrackingArea?
    private var pointerIsOverImage = false
    private var mouseDownEvent: NSEvent?
    private var isDraggingWindow = false
    /// Whether a press on the row is between its mouse-down and its release
    /// or hand-off to the window drag.
    private(set) var isPressInFlight = false

    var imageRolloverDidChange: ((Bool) -> Void)?
    var pointerPresenceDidChange: ((Bool) -> Void)?
    var hoveredSpanDidChange: ((TitleIdentitySpan.Kind?) -> Void)?
    var customContextMenu: NSMenu?
    var activationScope: TitleActivationScope = .wholeTitle
    var tracksHoveredSpan = false
    var spans: [TitleIdentitySpan] = []

    /// Whether the rollover has presented — set alongside the chevron, but
    /// keyed on the hover state so a chevron-less hover style still activates.
    /// Before anything is presented, a click on the row is aimed at nothing:
    /// the press still cancels the dwell and a drag still moves the window,
    /// but no action fires. Accessibility activation bypasses this — it goes
    /// through the action directly, since a screen-reader user cannot hover.
    var isRolloverPresented = false

    /// The span under the pointer; tracked in the span scope, nil otherwise.
    private(set) var hoveredSpanKind: TitleIdentitySpan.Kind?

    /// The span the last click or context-click landed on.
    private(set) var activatedSpanKind: TitleIdentitySpan.Kind?

    var chevronColor: NSColor = .labelColor {
        didSet {
            arrowView.contentTintColor = chevronColor
        }
    }

    /// Whether anything happens when the row is clicked. A row with no action
    /// takes no clicks and shows no chevron, so the affordance never promises
    /// something the click cannot deliver.
    var hasAction: Bool {
        action != nil && target != nil || customContextMenu != nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    /// The point arrives in the superview's coordinates, so it is converted
    /// before it is tested — comparing it against `bounds` directly answers
    /// nil for every click the control actually receives.
    ///
    /// Until the rollover has presented, the row is not a control at all:
    /// claiming the press would eat the titlebar's own gestures — the
    /// double-click zoom above all — so the native frame keeps every event
    /// and the window behaves exactly as a titlebar without this control.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else {
            return nil
        }
        guard hasAction, isRolloverPresented,
            bounds.contains(convert(point, from: superview))
        else {
            return nil
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool { // bool-ok: AppKit override
        false
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerPresenceDidChange?(true)
        updateImageRollover(with: event)
        updateHoveredSpan(with: event)
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateImageRollover(with: event)
        updateHoveredSpan(with: event)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        pointerPresenceDidChange?(false)
        setPointerIsOverImage(false)
        setHoveredSpanKind(nil)
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        isDraggingWindow = false
        isPressInFlight = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDraggingWindow, let mouseDownEvent else {
            return
        }
        let start = mouseDownEvent.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > Metrics.dragSlop else {
            return
        }
        isDraggingWindow = true
        // The window's drag takes the gesture from here; the release reaches
        // the window server, not this view.
        isPressInFlight = false
        window?.performDrag(with: mouseDownEvent)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownEvent = nil
            isDraggingWindow = false
            isPressInFlight = false
        }
        let point = convert(event.locationInWindow, from: nil)
        guard !isDraggingWindow, mouseDownEvent != nil, bounds.contains(point),
            isRolloverPresented
        else {
            return
        }
        activatedSpanKind = spanKind(at: point)
        sendAction(action, to: target)
    }

    /// The represented-document icon owns the contextual path menu; every other
    /// component of the title identity opens the actions popover on either
    /// button, so a right-click on the title never raises a second menu.
    override func rightMouseDown(with event: NSEvent) {
        guard isRolloverPresented else {
            return
        }
        activatedSpanKind = spanKind(at: convert(event.locationInWindow, from: nil))
        if let customContextMenu {
            NSMenu.popUpContextMenu(customContextMenu, with: event, for: self)
            return
        }
        sendAction(action, to: target)
    }

    /// The span whose measured extent holds the point, chevron included — the
    /// arrow accompanies the status it follows.
    private func spanKind(at point: NSPoint) -> TitleIdentitySpan.Kind? {
        if let span = spans.first(where: { $0.horizontalExtent.contains(point.x) }) {
            return span.kind
        }
        if arrowView.frame.insetBy(dx: -Metrics.textToArrow, dy: 0).contains(point) {
            return spans.last?.kind
        }
        return nil
    }

    private func updateHoveredSpan(with event: NSEvent) {
        guard tracksHoveredSpan else {
            return
        }
        setHoveredSpanKind(spanKind(at: convert(event.locationInWindow, from: nil)))
    }

    private func setHoveredSpanKind(_ kind: TitleIdentitySpan.Kind?) {
        guard hoveredSpanKind != kind else {
            return
        }
        hoveredSpanKind = kind
        hoveredSpanDidChange?(kind)
    }

    /// The fade-out's clock; the fade-in always rides the entry flight's.
    var exitFadeDuration: TimeInterval = Metrics.revealDuration

    func setChevronRevealed(_ isRevealed: Bool, animated: Bool) {
        let animationDuration =
            animated && !SystemDisplayOptions.shouldReduceMotion
            ? (isRevealed ? Metrics.revealDuration : exitFadeDuration)
            : 0
        guard animationDuration > 0 else {
            arrowView.alphaValue = isRevealed ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .default)
            arrowView.animator().alphaValue = isRevealed ? 1 : 0
        }
    }

    /// Places the arrow one point after the title text, hung off its baseline.
    func layoutChevron(baselineFromTop: CGFloat) {
        arrowView.frame = NSRect(
            x: bounds.maxX - Metrics.arrowSize.width,
            y: bounds.height - baselineFromTop + Metrics.arrowBottomAboveBaseline,
            width: Metrics.arrowSize.width,
            height: Metrics.arrowSize.height
        )
    }

    /// Where the popover hangs from: the chevron when the whole row is one
    /// control, the activated span when spans are the controls.
    func popoverAnchorRect() -> NSRect {
        if activationScope == .components,
            let kind = activatedSpanKind,
            let span = spans.last(where: { $0.kind == kind })
        {
            return NSRect(
                x: span.horizontalExtent.lowerBound,
                y: 0,
                width: span.horizontalExtent.upperBound - span.horizontalExtent.lowerBound,
                height: bounds.height
            )
        }
        return arrowView.frame
    }

    private func updateImageRollover(with event: NSEvent) {
        setPointerIsOverImage(arrowView.frame.contains(convert(event.locationInWindow, from: nil)))
    }

    private func setPointerIsOverImage(_ isOverImage: Bool) {
        guard pointerIsOverImage != isOverImage else {
            return
        }
        pointerIsOverImage = isOverImage
        imageRolloverDidChange?(isOverImage)
    }

    private func configure() {
        wantsLayer = true
        setAccessibilityRole(.menuButton)
        setAccessibilityLabel("document actions")
        setAccessibilityHelp("Edit the title and window size")
        setAccessibilityIdentifier("titlebarDocumentActions.button")

        arrowView.image = makeChevronImage()
        arrowView.imageScaling = .scaleNone
        arrowView.imageAlignment = .alignCenter
        arrowView.alphaValue = 0
        arrowView.setAccessibilityElement(false)
        addSubview(arrowView)
    }

    private func makeChevronImage() -> NSImage {
        let image = NSImage(size: Metrics.arrowSize, flipped: false) { _ in
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: 0.75, y: 4.5))
            path.line(to: NSPoint(x: 4, y: 1.5))
            path.line(to: NSPoint(x: 7.25, y: 4.5))
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
private final class TitlebarDocumentActionsPopoverViewController: NSViewController, NSTextFieldDelegate, NSTokenFieldDelegate {
    private enum Layout {
        static let width: CGFloat = 400
        static let height: CGFloat = 186
        static let reasonHeight: CGFloat = 34
        /// The row of rule-tag icons under the names field, with its spacing.
        static let ruleIconsHeight: CGFloat = 24
        static let horizontalInset: CGFloat = 20
        static let verticalInset: CGFloat = 16
        static let labelWidth: CGFloat = 72
        static let fieldWidth: CGFloat = 272
        static let numberFieldWidth: CGFloat = 58
        static let rowSpacing: CGFloat = 10
    }

    private let windowTitleField = NSTextField()
    private let tabTitleField = NSTextField()
    private let tagsField = NSTokenField()
    private let columnsField = NSTextField()
    private let rowsField = NSTextField()
    private var tagDots: [TagDotButton] = []
    private let customColorSwatch = TagCustomColorSwatch(look: .dot)
    private let ruleIconsRow = NSStackView()
    private let sizeReasonLabel = NSTextField(wrappingLabelWithString: "")

    var applyTitles: ((String, String) -> Void)?
    var applyGridSize: ((Int, Int) -> Void)?
    var applyTags: (([String]) -> Void)?
    var openTagRules: ((Int) -> Void)?

    private var lastAppliedWindowTitle = ""
    private var lastAppliedTabTitle = ""
    private var lastAppliedColumns = 0
    private var lastAppliedRows = 0
    private var lastAppliedTags: [String] = []
    private var ruleTags: [TitlebarRuleTag] = []

    override func loadView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height))
        content.setAccessibilityIdentifier("titlebarDocumentActions.popover")
        view = content

        configureTitleField(
            windowTitleField,
            label: "Title",
            identifier: "titlebarDocumentActions.windowTitle"
        )
        configureTitleField(
            tabTitleField,
            label: "Tab Title",
            identifier: "titlebarDocumentActions.tabTitle"
        )
        configureTagsField()
        configureNumberField(columnsField, label: "Columns")
        configureNumberField(rowsField, label: "Rows")

        let sizeControls = NSStackView(views: [
            columnsField,
            plainLabel("columns"),
            plainLabel("\u{00d7}"),
            rowsField,
            plainLabel("rows"),
        ])
        sizeControls.orientation = .horizontal
        sizeControls.alignment = .centerY
        sizeControls.spacing = 7

        sizeReasonLabel.font = NSFont.systemFont(ofSize: ChromeTypography.scaled(NSFont.smallSystemFontSize))
        sizeReasonLabel.textColor = .secondaryLabelColor
        sizeReasonLabel.isHidden = true
        sizeReasonLabel.preferredMaxLayoutWidth = Layout.fieldWidth
        sizeReasonLabel.setAccessibilityIdentifier("titlebarDocumentActions.sizeReason")
        let sizeRow = NSStackView(views: [sizeControls, sizeReasonLabel])
        sizeRow.orientation = .vertical
        sizeRow.alignment = .leading
        sizeRow.spacing = 4

        let grid = NSGridView(views: [
            [formLabel("Title:"), windowTitleField],
            [formLabel("Tab Title:"), tabTitleField],
            [formLabel("Tags:"), tagControls()],
            [formLabel("Size:"), sizeRow],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = Layout.rowSpacing
        grid.columnSpacing = 12
        grid.column(at: 0).width = Layout.labelWidth
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.row(at: 2).yPlacement = .top
        content.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Layout.horizontalInset),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Layout.horizontalInset),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: Layout.verticalInset),
            windowTitleField.widthAnchor.constraint(equalToConstant: Layout.fieldWidth),
            tabTitleField.widthAnchor.constraint(equalToConstant: Layout.fieldWidth),
            tagsField.widthAnchor.constraint(equalToConstant: Layout.fieldWidth),
            columnsField.widthAnchor.constraint(equalToConstant: Layout.numberFieldWidth),
            rowsField.widthAnchor.constraint(equalToConstant: Layout.numberFieldWidth),
        ])

        windowTitleField.nextKeyView = tabTitleField
        tabTitleField.nextKeyView = tagsField
        tagsField.nextKeyView = columnsField
        columnsField.nextKeyView = rowsField
        rowsField.nextKeyView = windowTitleField
    }

    /// The tag row's controls: the palette's dot strip and its custom colour,
    /// with the jump to the rule editor beside them, over the free-form names
    /// field and the icons of the tags the window's rules give it.
    private func tagControls() -> NSStackView {
        tagDots = TitlebarTagPalette.entries.map { entry in
            let dot = TagDotButton(name: entry.name, color: entry.nsColor)
            dot.onToggle = { [weak self] in
                self?.toggleTag(named: entry.name)
            }
            return dot
        }
        customColorSwatch.setAccessibilityIdentifier("titlebarDocumentActions.tagCustomColor")
        customColorSwatch.onPick = { [weak self] literal in
            self?.chooseCustomColor(literal)
        }

        let rulesButton = NSButton(
            title: "Rules\u{2026}",
            target: self,
            action: #selector(rulesButtonAction(_:))
        )
        rulesButton.controlSize = .small
        rulesButton.font = NSFont.systemFont(ofSize: ChromeTypography.scaled(NSFont.smallSystemFontSize))
        rulesButton.setAccessibilityIdentifier("titlebarDocumentActions.tagRules")

        let dotsRow = NSStackView(views: tagDots + [customColorSwatch, rulesButton])
        dotsRow.orientation = .horizontal
        dotsRow.alignment = .centerY
        dotsRow.spacing = 5
        dotsRow.setCustomSpacing(14, after: customColorSwatch)

        ruleIconsRow.orientation = .horizontal
        ruleIconsRow.alignment = .centerY
        ruleIconsRow.spacing = 10
        ruleIconsRow.isHidden = true
        ruleIconsRow.setAccessibilityIdentifier("titlebarDocumentActions.ruleIcons")
        ruleIconsRow.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.fieldWidth).isActive = true

        let controls = NSStackView(views: [dotsRow, tagsField, ruleIconsRow])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6
        controls.detachesHiddenViews = true
        return controls
    }

    /// Lists the window's rule tags that carry an icon, each in its colour and
    /// weight, as a press that opens the rule.
    ///
    /// The names field lists every rule tag already, as text; a token cannot
    /// carry an image, so the icons stand in their own row. A tag whose icon
    /// the catalog does not carry has nothing to add there and is left out.
    /// Icons that do not fit the row's width are dropped from its end.
    private func rebuildRuleIcons() {
        for view in ruleIconsRow.arrangedSubviews {
            ruleIconsRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let font = NSFont.systemFont(ofSize: ChromeTypography.scaled(NSFont.smallSystemFontSize))
        for tag in ruleTags {
            guard let image = ruleIcon(for: tag, side: 14) else { continue }
            let button = NSButton(
                title: tag.name.isEmpty ? tag.spokenName : tag.name,
                image: image,
                target: self,
                action: #selector(ruleIconAction(_:))
            )
            button.isBordered = false
            button.imagePosition = .imageLeading
            button.font = font
            button.contentTintColor = .secondaryLabelColor
            button.tag = tag.ruleIndex
            button.toolTip = tag.originDescription
            button.setAccessibilityLabel("\(tag.spokenName). \(tag.originDescription)")
            button.setAccessibilityIdentifier("titlebarDocumentActions.ruleIcon.\(tag.ruleIndex)")
            ruleIconsRow.addArrangedSubview(button)
            ruleIconsRow.setVisibilityPriority(.detachOnlyIfNecessary, for: button)
        }
        ruleIconsRow.isHidden = ruleIconsRow.arrangedSubviews.isEmpty
    }

    /// A rule tag's icon in its colour and weight, nil when it names none the
    /// catalog carries.
    private func ruleIcon(for tag: TitlebarRuleTag, side: CGFloat) -> NSImage? {
        PhosphorIcons.cachedImage(
            named: tag.icon,
            weight: tag.isIconRegular ? .Regular : .Fill,
            side: side,
            color: tag.color ?? .secondaryLabelColor
        )
    }

    func configure(
        windowTitleOverride: String,
        tabTitleOverride: String,
        columns: Int,
        rows: Int,
        tags: [String],
        ruleTags: [TitlebarRuleTag],
        sizeUnavailableReason: String?
    ) {
        loadViewIfNeeded()
        let sizeReason = sizeUnavailableReason ?? ""
        columnsField.isEnabled = sizeReason.isEmpty
        rowsField.isEnabled = sizeReason.isEmpty
        columnsField.toolTip = sizeUnavailableReason
        rowsField.toolTip = sizeUnavailableReason
        sizeReasonLabel.stringValue = sizeReason
        sizeReasonLabel.isHidden = sizeReason.isEmpty
        self.ruleTags = ruleTags
        rebuildRuleIcons()
        let height =
            Layout.height + (sizeReason.isEmpty ? 0 : Layout.reasonHeight)
            + (ruleIconsRow.isHidden ? 0 : Layout.ruleIconsHeight)
        view.setFrameSize(NSSize(width: Layout.width, height: height))
        preferredContentSize = view.frame.size
        windowTitleField.stringValue = windowTitleOverride
        tabTitleField.stringValue = tabTitleOverride
        columnsField.integerValue = columns
        rowsField.integerValue = rows
        tagsField.objectValue = tokens(handSet: tags)
        lastAppliedWindowTitle = windowTitleOverride
        lastAppliedTabTitle = tabTitleOverride
        lastAppliedColumns = columns
        lastAppliedRows = rows
        lastAppliedTags = tags
        refreshTagDots()
    }

    /// A field the popover can open focused on.
    enum Field {
        case title
        case columns
    }

    func focus(_ field: Field) {
        let responder: NSTextField
        switch field {
        case .title:
            responder = windowTitleField
        case .columns:
            responder = columnsField
        }
        view.window?.makeFirstResponder(responder)
    }

    func commitPendingEdits() {
        view.window?.makeFirstResponder(nil)
        commitTitles()
        commitTags()
        commitGridSize()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }
        if field === windowTitleField || field === tabTitleField {
            commitTitles()
        } else if field === tagsField {
            commitTags()
        } else {
            commitGridSize()
        }
    }

    @objc
    public func titleFieldAction(_ sender: NSTextField) {
        commitTitles()
    }

    @objc
    public func tagsFieldAction(_ sender: NSTokenField) {
        commitTags()
    }

    @objc
    public func sizeFieldAction(_ sender: NSTextField) {
        commitGridSize()
    }

    @objc
    public func rulesButtonAction(_ sender: Any?) {
        openTagRules?((sender as? NSMenuItem)?.representedObject as? Int ?? -1)
    }

    @objc
    public func ruleIconAction(_ sender: NSButton) {
        openTagRules?(sender.tag)
    }

    /// Adds the palette name to the hand-set tags, or removes its match. The
    /// match is by name, caseless, so a dot lit by a hand-typed "RED" removes
    /// that spelling rather than adding a duplicate.
    ///
    /// A dot lit only by a rule changes nothing: the rule would put the tag
    /// back on its next match, and a hand-set tag of the same colour beside
    /// it would read as the press having done something it did not. Core has
    /// no way to suppress a rule's tag on one window; the rule is edited in
    /// Settings, which the dot's tooltip says.
    private func toggleTag(named name: String) {
        var tags = tokenTagNames()
        let hadMatch = tags.contains { tagNamesMatch($0, name) }
        if hadMatch == false, ruleTags.contains(where: { $0.colorName == name }) {
            NSSound.beep()
            return
        }
        tags.removeAll { tagNamesMatch($0, name) }
        if hadMatch == false {
            tags.append(name)
        }
        tagsField.objectValue = tokens(handSet: tags)
        commitTags()
    }

    /// Sets the hand-set tag a custom colour names, in place of any other.
    ///
    /// The colour is the tag's name, as a palette dot's colour is: a hand-set
    /// tag carries a name and nothing else, so a colour outside the palette
    /// travels as its `#rrggbb` literal. A window wears one such tag from
    /// here; a second choice replaces the first.
    ///
    /// - Parameter literal: The colour chosen, as `#rrggbb`.
    private func chooseCustomColor(_ literal: String) {
        var tags = tokenTagNames()
        tags.removeAll { TagColorValue.isCustom($0) }
        tags.append(literal)
        tagsField.objectValue = tokens(handSet: tags)
        commitTags()
    }

    /// The token field's contents: the rule tags first, as the window wears
    /// them, then the hand-set names.
    private func tokens(handSet names: [String]) -> [Any] {
        ruleTags.map { RuleTagToken(tag: $0) as Any } + names.map { $0 as Any }
    }

    func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
        (representedObject as? RuleTagToken)?.tag.displayName ?? representedObject as? String
    }

    func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
        // A rule's tag is not text to edit; it keeps its place whatever is
        // typed, and is put back if deleted.
        (representedObject as? RuleTagToken)?.tag.displayName ?? representedObject as? String
    }

    func tokenField(_ tokenField: NSTokenField, styleForRepresentedObject representedObject: Any) -> NSTokenField.TokenStyle {
        representedObject is RuleTagToken ? .plainSquared : .rounded
    }

    func tokenField(_ tokenField: NSTokenField, hasMenuForRepresentedObject representedObject: Any) -> Bool {
        representedObject is RuleTagToken
    }

    func tokenField(_ tokenField: NSTokenField, menuForRepresentedObject representedObject: Any) -> NSMenu? {
        guard let token = representedObject as? RuleTagToken else { return nil }
        let menu = NSMenu()
        let origin = NSMenuItem(title: token.tag.originDescription, action: nil, keyEquivalent: "")
        origin.image = ruleIcon(for: token.tag, side: 16)
        origin.isEnabled = false
        menu.addItem(origin)
        menu.addItem(NSMenuItem(title: "Edit Rule\u{2026}", action: #selector(rulesButtonAction(_:)), keyEquivalent: ""))
        menu.items.last?.target = self
        menu.items.last?.representedObject = token.tag.ruleIndex
        return menu
    }

    /// Name equality as Core's `tagNamesEqual` resolves it: caseless, and a
    /// name is a literal — `*` is a character here, not a pattern.
    private func tagNamesMatch(_ left: String, _ right: String) -> Bool {
        left.caseInsensitiveCompare(right) == .orderedSame
    }

    private func configureTitleField(_ field: NSTextField, label: String, identifier: String) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "Automatic"
        field.delegate = self
        field.target = self
        field.action = #selector(titleFieldAction(_:))
        field.cell?.sendsActionOnEndEditing = true
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier(identifier)
    }

    private func configureTagsField() {
        tagsField.translatesAutoresizingMaskIntoConstraints = false
        tagsField.placeholderString = "None"
        tagsField.delegate = self
        tagsField.target = self
        tagsField.action = #selector(tagsFieldAction(_:))
        tagsField.cell?.sendsActionOnEndEditing = true
        tagsField.setAccessibilityLabel("Tags")
        tagsField.setAccessibilityIdentifier("titlebarDocumentActions.tags")
    }

    private func configureNumberField(_ field: NSTextField, label: String) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 1000
        formatter.allowsFloats = false
        formatter.generatesDecimalNumbers = false

        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = .right
        field.formatter = formatter
        field.delegate = self
        field.target = self
        field.action = #selector(sizeFieldAction(_:))
        field.cell?.sendsActionOnEndEditing = true
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier("titlebarDocumentActions.\(label.lowercased())")
    }

    private func formLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        return label
    }

    private func plainLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func commitTitles() {
        let windowTitle = windowTitleField.stringValue
        let tabTitle = tabTitleField.stringValue
        guard windowTitle != lastAppliedWindowTitle || tabTitle != lastAppliedTabTitle else {
            return
        }
        lastAppliedWindowTitle = windowTitle
        lastAppliedTabTitle = tabTitle
        applyTitles?(windowTitle, tabTitle)
    }

    /// The hand-set names the token field holds, trimmed, with empties and
    /// the rule tags dropped.
    private func tokenTagNames() -> [String] {
        let tokens = tagsField.objectValue as? [Any] ?? []
        return
            tokens
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
    }

    private func commitTags() {
        let tags = tokenTagNames()
        // A deleted rule token comes back: the rule still matches.
        let shown = tagsField.objectValue as? [Any] ?? []
        if shown.compactMap({ $0 as? RuleTagToken }).count != ruleTags.count {
            tagsField.objectValue = tokens(handSet: tags)
        }
        refreshTagDots()
        guard tags != lastAppliedTags else {
            return
        }
        lastAppliedTags = tags
        applyTags?(tags)
    }

    /// Lights each palette dot whose name a hand-set tag carries, and marks
    /// the dot of each colour a rule gives the window.
    private func refreshTagDots() {
        let tags = tokenTagNames()
        for dot in tagDots {
            dot.isActive = tags.contains { tagNamesMatch($0, dot.tagName) }
            dot.rule = ruleTags.first { $0.colorName == dot.tagName }
        }
        // The swatch keeps the last custom colour it showed when the window
        // stops wearing it, so a press puts it back.
        let custom = tags.last { TagColorValue.isCustom($0) }
        customColorSwatch.isChosen = custom != nil
        if let custom {
            customColorSwatch.color = TagColorValue.color(of: custom)
        }
        tagsField.placeholderString = ruleTags.isEmpty ? "None" : nil
    }

    private func commitGridSize() {
        guard columnsField.isEnabled, columnsField.stringValue.isEmpty == false,
            rowsField.stringValue.isEmpty == false
        else {
            return
        }
        let columns = columnsField.integerValue
        let rows = rowsField.integerValue
        guard (1...1000).contains(columns), (1...1000).contains(rows),
            columns != lastAppliedColumns || rows != lastAppliedRows
        else {
            return
        }
        lastAppliedColumns = columns
        lastAppliedRows = rows
        applyGridSize?(columns, rows)
    }

    /// Escape cancels: every field reverts to its last-applied value before
    /// the same keystroke goes on to close the popover, so the commits that
    /// fire during the teardown find nothing changed and write nothing.
    /// Return and click-away still commit through end-of-editing.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        windowTitleField.stringValue = lastAppliedWindowTitle
        tabTitleField.stringValue = lastAppliedTabTitle
        columnsField.integerValue = lastAppliedColumns
        rowsField.integerValue = lastAppliedRows
        tagsField.objectValue = tokens(handSet: lastAppliedTags)
        refreshTagDots()
        return false
    }
}

/// A tag a `[[tags]]` rule gives the window, as the title popover shows it.
///
/// Core's effective tag state (`Session::resolveWindowTags`) is what the title
/// row draws; the popover shows the rule half of it beside the hand-set names
/// so the two never disagree about what the window wears.
public struct TitlebarRuleTag: Equatable {
    /// The tag's title, empty for an untitled tag.
    public let name: String
    /// What a screen reader speaks for it, Core's `Session::tagSpokenName`.
    public let spokenName: String
    /// The palette colour it wears, lower case, or empty for a `#rrggbb` one.
    public let colorName: String
    /// What the rule matches, Core's `Session::tagRulePattern`.
    public let rulePattern: String
    /// The rule's position among the `[[tags]]` blocks.
    public let ruleIndex: Int
    /// The Phosphor icon the rule draws in the tag's place, empty for none.
    public let icon: String
    /// Whether the icon is drawn in its regular weight rather than its fill.
    public let isIconRegular: Bool
    /// The colour the rule gives the tag, nil when it names none.
    public let color: NSColor?

    /// Makes a rule tag.
    ///
    /// - Parameters:
    ///   - name: The title, empty for an untitled tag.
    ///   - spokenName: What a screen reader speaks for it.
    ///   - colorName: Its palette colour, or empty.
    ///   - rulePattern: What the rule matches.
    ///   - ruleIndex: The rule's position.
    ///   - icon: The icon it draws, empty for none.
    ///   - isIconRegular: Whether the icon is drawn in its regular weight.
    ///   - color: The colour it is drawn in, nil for none.
    public init(
        name: String,
        spokenName: String,
        colorName: String,
        rulePattern: String,
        ruleIndex: Int,
        icon: String = "",
        isIconRegular: Bool = false,
        color: NSColor? = nil
    ) {
        self.name = name
        self.spokenName = spokenName
        self.colorName = colorName
        self.rulePattern = rulePattern
        self.ruleIndex = ruleIndex
        self.icon = icon
        self.isIconRegular = isIconRegular
        self.color = color
    }

    /// Makes the rule tag Core resolved, carrying everything the popover
    /// draws it with.
    ///
    /// - Parameter tag: One of the window's tags a rule supplied, from
    ///   `Session::resolveWindowTags`.
    init(resolved tag: Ubiquitty.Session.ResolvedTag) {
        self.init(
            name: String(tag.name),
            spokenName: String(Ubiquitty.Session.tagSpokenName(tag)),
            colorName: String(tag.colorName),
            rulePattern: String(tag.rulePattern),
            ruleIndex: Int(tag.ruleIndex),
            icon: String(tag.icon),
            isIconRegular: tag.iconWeight == .Regular,
            color: TagColorValue.color(of: tag.color)
        )
    }

    /// What the token field shows: the title, or for an untitled tag a dot and
    /// its spoken name, so it is not read as a hand-set name.
    var displayName: String { name.isEmpty ? "\u{25CF} \(spokenName)" : name }

    /// Where the tag comes from, in the words its tooltip and label use.
    var originDescription: String { "From rule: \(rulePattern)" }
}

/// A rule's tag in the popover's token field: an object rather than a string,
/// so a commit can tell it from a name the reader typed.
private final class RuleTagToken: NSObject {
    let tag: TitlebarRuleTag

    init(tag: TitlebarRuleTag) {
        self.tag = tag
    }
}

/// One palette colour in the popover's dot strip. A click toggles the tag
/// named for the colour; a solid ring marks the dot whose tag is set by hand,
/// a dashed ring the dot of a colour a rule gives the window.
private final class TagDotButton: NSControl {
    let tagName: String
    private let dotColor: NSColor

    var isActive = false {
        didSet {
            needsDisplay = true
        }
    }

    /// The rule that gives the window this colour, if one does.
    var rule: TitlebarRuleTag? {
        didSet {
            guard rule != oldValue else { return }
            needsDisplay = true
            let colour = tagName.capitalized
            if let rule {
                toolTip = "\(colour). \(rule.originDescription)"
                setAccessibilityLabel("\(colour) tag. \(rule.originDescription)")
            } else {
                toolTip = colour
                setAccessibilityLabel("\(colour) tag")
            }
        }
    }

    var onToggle: (() -> Void)?

    init(name: String, color: NSColor) {
        tagName = name
        dotColor = color
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        toolTip = name.capitalized
        // A checkbox, not a button: the dot carries an on/off state, and a
        // reader that hears only "button" cannot tell a set tag from an unset
        // one.
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("\(name.capitalized) tag")
        setAccessibilityIdentifier("titlebarDocumentActions.tagDot.\(name)")
    }

    /// On for a tag set by hand; mixed for one only a rule sets, which a
    /// press does not clear.
    override func accessibilityValue() -> Any? {
        isActive ? 1 : (rule != nil ? 2 : 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 18, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4))
        dotColor.setFill()
        dot.fill()
        guard isActive || rule != nil else {
            return
        }
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.25, dy: 1.25))
        ring.lineWidth = 1.5
        if !isActive {
            // Dashed: the window wears the colour, but by a rule, which this
            // dot does not set or clear.
            ring.setLineDash([2, 1.6], count: 2, phase: 0)
        }
        dotColor.setStroke()
        ring.stroke()
    }

    /// Whether the ring is the dashed one a rule draws, for a scenario.
    var isMarkedByRuleForTesting: Bool { rule != nil && !isActive }

    override func mouseDown(with event: NSEvent) {
        // Taking the press keeps it from falling through to the popover and
        // routes the release to mouseUp below.
    }

    override func mouseUp(with event: NSEvent) {
        // Toggle on release inside, the button convention, so a drag off the
        // dot abandons the press.
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onToggle?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }
}
