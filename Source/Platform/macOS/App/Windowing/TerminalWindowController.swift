// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController.swift — the Swift window shell: one NSWindow
// projecting one surface of the app's Core window model. The model
// (Runtime::WorkspaceSession) owns the topology, the pane sessions and every
// pane verb's resolution; this file is chrome: make a view per pane the model
// minted, mirror its tree into NSSplitViews, relay the observer events AppKit
// expresses as window state, and write divider drags back as ratios.
//
// The application delegate reaches this controller through its generated
// Objective-C interface.

import AppKit
import SwiftUI
internal import UbiquittyCore
package import UbiquittyRenderKit

extension Notification.Name {
    /// Signals that terminal appearance configuration has reached the open panes.
    package static let terminalAppearanceChanged = Notification.Name("UBTerminalAppearanceChanged")

    /// Signals that what an inspector shows of a terminal window changed: its
    /// title, directory, processes or focused pane. The object is the window's
    /// controller.
    package static let terminalInspectedFactsChanged = Notification.Name("UBTerminalInspectedFactsChanged")
}

/// The model's pane id, hashable so it can key the view map — the imported
/// enum is a raw-value handle, and `RawRepresentable`'s defaults are the
/// whole conformance.
extension Ubiquitty.Session.Layout.PaneID: @retroactive Hashable {}
extension Ubiquitty.Session.Layout.TabID: @retroactive Hashable {}
extension Ubiquitty.Session.Layout.SurfaceID: @retroactive Hashable {}

/// The observer relay, a separate object for the reason the surface's clock
/// bridge is one: the controller stays free of protocol conformances that
/// would ride its public interface. Every surface path that reaches an
/// observer — the ingest delivery, the key, text and paste writers, the
/// pointer and selection handlers — is main-actor isolated with the view
/// class it belongs to, so each hop asserts that isolation rather than
/// re-dispatching. The witnesses are `nonisolated` because the protocol's
/// requirements are.
@MainActor
final class SurfaceWindowBridge: TerminalSurfaceObserver {
    /// Weak, because the surfaces outlive the controller's dealloc for a
    /// moment: the window the controller owns releases its view tree from
    /// inside `[NSWindowController dealloc]`, each surface's
    /// `viewDidMoveToWindow` recomputes its presentation, and that asks the
    /// observer — while the controller's Swift stored properties, this bridge
    /// among them, are still to be destroyed. An unowned reference to the
    /// deallocating controller aborts there; a weak one reads nil and the
    /// surface takes its own answer.
    weak var controller: TerminalWindowController?

    @MainActor
    init(controller: TerminalWindowController) {
        self.controller = controller
    }

    nonisolated func terminalSurfaceNeedsProcessState(_ surface: TerminalSurface) -> Bool {
        MainActor.assumeIsolated { controller?.needsProcessTitle(for: surface) ?? surface.hasProcessInspector }
    }

    nonisolated func terminalSurfacePaneIdentifier(_ surface: TerminalSurface) -> Int? {
        MainActor.assumeIsolated { controller?.paneIdentifier(of: surface) }
    }

    nonisolated func terminalSurface(_ surface: TerminalSurface, didChangeTitle title: String) {
        MainActor.assumeIsolated {
            controller?.surfaceDidChangeTitle(surface, title: title)
        }
    }

    nonisolated func terminalSurface(_ surface: TerminalSurface, didChangeCurrentDirectory directory: String) {
        MainActor.assumeIsolated {
            controller?.surfaceDidChangeCurrentDirectory(surface, directory: directory)
        }
    }

    nonisolated func terminalSurfaceDidChangeProcessState(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.surfaceDidChangeProcessState(surface)
        }
    }

    nonisolated func terminalSurface(_ surface: TerminalSurface, didResizeGridTo rows: Int, columns: Int) {
        MainActor.assumeIsolated {
            controller?.surfaceDidResizeGrid(surface)
        }
    }

    nonisolated func terminalSurfacePreservesVisibleTopOnResize(_ surface: TerminalSurface) -> Bool {
        MainActor.assumeIsolated { (surface.window as? ZoomTrackingWindow)?.isZoomResizeInProgress == true }
    }

    nonisolated func terminalSurfaceDidExit(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.surfaceDidExit(surface)
        }
    }

    nonisolated func terminalSurface(_ surface: TerminalSurface, didRingBell reaction: TerminalSurface.BellReaction) {
        MainActor.assumeIsolated {
            controller?.reactToBell(reaction, from: surface)
        }
    }

    nonisolated func terminalSurfaceRequestsDeployConfirmation(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.confirmHostDeploy(on: surface)
        }
    }

    nonisolated func terminalSurfaceDidChangePresence(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.refreshPresence()
        }
    }

    nonisolated func terminalSurface(_ surface: TerminalSurface, willAskForConsent question: String, from actor: String) {
        MainActor.assumeIsolated {
            controller?
                .drawAttentionToConsent(
                    on: surface,
                    title: question,
                    body: "\(actor) is asking for access. Open Ubiquitty to allow or deny it."
                )
        }
    }

    nonisolated func terminalSurfaceDidFailHostDeploy(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.presentHostDeployFailure(on: surface)
        }
    }

    nonisolated func terminalSurfaceNeedsManualHostInstall(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.presentManualHostInstall(on: surface)
        }
    }

    nonisolated func terminalSurfaceDidReceiveHostFile(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.landHostFile(from: surface)
        }
    }

    nonisolated func terminalSurface(_ surface: TerminalSurface, didSettlePastePushWithStatus status: UInt32) {
        MainActor.assumeIsolated {
            controller?.pastePushSettled(status: status, on: surface)
        }
    }

    nonisolated func terminalSurface(_ surface: TerminalSurface, didChangeHint text: String) {
        MainActor.assumeIsolated {
            controller?.surfaceDidChangeHint(text)
        }
    }

    nonisolated func terminalSurface(_ surface: TerminalSurface, didChangeFocus isFocused: Bool) {
        guard isFocused else { return }
        MainActor.assumeIsolated {
            controller?.surfaceDidFocus(surface)
        }
    }

    nonisolated func terminalSurface(_ surface: TerminalSurface, didTransmit bytes: [CChar], count: Int) {
        MainActor.assumeIsolated {
            controller?.surfaceDidTransmit(surface, bytes: bytes, count: count)
        }
    }

    // The palette has no change notification of its own: a theme applied by a
    // setting, by OSC 4/11, or by a remote host reaches the model the same way
    // any other screen change does. The controller compares against what it
    // last painted, so the frequency of this callback costs a comparison.
    nonisolated func terminalSurfaceDidUpdateScreen(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.surfaceDidUpdateScreen(surface)
        }
    }

    nonisolated func terminalSurfaceDidChangeWithheldPalette(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.surfaceDidChangeWithheldPalette(surface)
        }
    }

    nonisolated func terminalSurface(_ surface: TerminalSurface, didChangeLinkPreview target: String?) {
        MainActor.assumeIsolated {
            controller?.showLinkPreview(target, from: surface)
        }
    }

    nonisolated func terminalSurfaceDidChangeProgress(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.syncProgressChrome()
        }
    }

    nonisolated func terminalSurfaceDidChangeSearch(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.surfaceDidChangeSearch(surface)
        }
    }

    nonisolated func terminalSurfaceDidChangeTabStatus(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            // The tab's own slot, the title's bell where one is standing, and
            // every title the label can appear in — the window's component, the
            // tab's text and tooltip, the pane headers: all of them read this
            // report, so a report that reached some and not others would have
            // them disagree. A working program counts as progress, so the
            // bands and the selected tab's bar follow it too.
            controller?.refreshTabAccessory()
            controller?.syncProgressChromeIfStatusMovedIt()
            controller?.refreshTitleBellMark()
            controller?.refreshTitles()
        }
    }

    nonisolated func terminalSurfaceDidDetectFileTransfer(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.surfaceDidDetectFileTransfer(surface)
        }
    }

    nonisolated func terminalSurfaceDidChangeRemoteSession(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.remoteSessionDidChange(on: surface)
        }
    }
    nonisolated func terminalSurfaceDidChangeInputInDoubt(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.presentInputInDoubt(on: surface)
        }
    }
    nonisolated func terminalSurfaceDidChangeRemoteWorkspace(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.remoteWorkspaceDidChange(on: surface)
        }
    }
    nonisolated func terminalSurfaceDidRequestFontSwap(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.applyFontSwap(on: surface)
        }
    }
    nonisolated func terminalSurfaceDidRequestWindowOperation(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.performPendingWindowRequests(from: surface)
        }
    }
    nonisolated func terminalSurfaceDidPostNotification(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.postPendingNotifications(from: surface)
        }
    }
    nonisolated func terminalSurfaceDidMatchTrigger(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.performPendingTriggerEffects(from: surface)
        }
    }
    nonisolated func terminalSurfaceDidChangeHostedWindows(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            controller?.hostedWindowsDidChange(on: surface)
        }
    }
}

/// The view a window's panes are mirrored into.
///
/// A material host that places native text above the panes' ordinary tint.
/// It reports layout so whatever follows a pane's edges — the window's OSC 9;4
/// band, while it overlays the pane it speaks for — can be placed. The panes
/// themselves are frame-driven leaves of `NSSplitView`s, and a view added to
/// one of those would become a third pane its divider could drag, so an
/// overlay lives here and is placed rather than pinned.
@MainActor
package final class PaneHostView: NSVisualEffectView {
    private(set) var hasBlur = false

    func setBlurEnabled(_ enabled: Bool) {
        guard hasBlur != enabled || maskImage == nil && !enabled else { return }
        hasBlur = enabled
        blendingMode = .behindWindow
        material = .hudWindow
        state = .active
        // An empty material mask disables the backdrop without hiding panes.
        maskImage = enabled ? nil : NSImage(size: NSSize(width: 1, height: 1))
    }

    /// Called after every layout pass, on the main thread.
    package var onLayout: (@MainActor () -> Void)?

    override package func layout() {
        super.layout()
        onLayout?()
    }
}

/// One terminal window over a Core pane tree of surfaces.
///
/// Spawns behind the app delegate's flip. Split Right and Split Down arrive
/// through the responder chain from the app's View menu (the same selectors
/// the Metal arm's controller answers); a pane whose shell exits closes its
/// leaf, and the last pane's exit closes the window.
@objc(UBSwiftTerminalWindowController)
@MainActor
public final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    /// How a terminal window behaves in Spaces, Mission Control and full
    /// screen.
    ///
    /// `managed` keeps the window on the Space it was opened on and in Mission
    /// Control; `participatesInCycle` puts it in ⌘` rotation. `fullScreenPrimary`
    /// is what makes the window full-screen CAPABLE at all: without it AppKit
    /// validates `toggleFullScreen:` false, so ⌃⌘F and the green button do
    /// nothing and the View menu's item greys out, and a window that declares
    /// no behaviour gets `default`, which lacks it.
    static let terminalCollectionBehavior: NSWindow.CollectionBehavior = [
        .managed, .participatesInCycle, .fullScreenPrimary,
    ]

    // The live controllers, owned here so the spawning side holds nothing: a
    // closed window removes itself, and with it every surface, session and
    // shell process it hosts.
    package static var spawnedControllers: [TerminalWindowController] = []

    /// Shared by the native tabs participating in one window handoff.
    var windowSharing: WindowSharing?

    /// The frame this window had when it last began entering full screen,
    /// until it leaves full screen again: what a saved arrangement records
    /// for a window in full screen, since its frame there is the screen's.
    package internal(set) var frameBeforeFullScreen: NSRect?

    private var inspectorSplit: NSSplitViewController?
    private var inspectorItem: NSSplitViewItem?
    private var terminalSafeTop: NSLayoutConstraint?
    private var terminalFullTop: NSLayoutConstraint?
    package var inspectorModel: TerminalInspectorModel?

    /// The width reserved by the visible native inspector and its divider.
    package var inspectorWidth: CGFloat {
        guard let inspectorItem, !inspectorItem.isCollapsed else { return 0 }
        return inspectorItem.viewController.view.frame.width + (inspectorSplit?.splitView.dividerThickness ?? 0)
    }

    /// The measured window area outside the terminal viewport.
    ///
    /// Includes native title/tab chrome and the visible inspector. Measuring the
    /// viewport keeps full-size content windows on the same grid geometry.
    package var terminalFrameOverhead: NSSize {
        guard let window else { return .zero }
        return NSSize(
            width: max(0, window.frame.width - paneHost.bounds.width),
            height: max(0, window.frame.height - paneHost.bounds.height)
        )
    }

    /// Converts a terminal viewport size to its containing window size.
    ///
    /// - Parameter viewport: The terminal area, including renderer padding.
    /// - Returns: The window frame size with native chrome and inspector space.
    package func windowSize(forTerminalViewport viewport: NSSize) -> NSSize {
        let overhead = terminalFrameOverhead
        return NSSize(width: viewport.width + overhead.width, height: viewport.height + overhead.height)
    }

    /// Toggles AppKit's native inspector beside the terminal content.
    ///
    /// - Parameter sender: The menu item or inspector button.
    @objc
    public func toggleNativeInspector(_ sender: Any?) {
        guard let window else { return }
        let inspected = activeSurface ?? inspectorModel?.surface ?? projectedSurfaces.first
        if inspectorSplit == nil {
            let model = TerminalInspectorModel()
            model.controller = self
            inspectorModel = model
            let terminal = NSViewController()
            terminal.view = NSView()
            paneHost.removeFromSuperview()
            paneHost.translatesAutoresizingMaskIntoConstraints = false
            let split = NSSplitViewController()
            split.splitView.isVertical = true
            split.splitView.dividerStyle = .thin
            let content = NSSplitViewItem(viewController: terminal)
            content.minimumThickness = 160
            split.addSplitViewItem(content)
            let hosting = TerminalInspectorViewController(model: model, hidesTitleBar: hidesTitleBar)
            let inspector = NSSplitViewItem(inspectorWithViewController: hosting)
            inspector.allowsFullHeightLayout = false
            inspector.minimumThickness = 280
            inspector.maximumThickness = 480
            inspector.preferredThicknessFraction = 0.3
            inspector.isCollapsed = true
            split.addSplitViewItem(inspector)
            inspectorSplit = split
            inspectorItem = inspector
            let frame = window.frame
            window.styleMask.insert(.fullSizeContentView)
            window.contentViewController = split
            // The split item supplies the width, while the root view supplies
            // the vertical safe area. A child of the item receives the native
            // tab inset again after AppKit reflows the strip.
            split.view.addSubview(paneHost)
            NSLayoutConstraint.activate([
                paneHost.leadingAnchor.constraint(equalTo: terminal.view.leadingAnchor),
                paneHost.trailingAnchor.constraint(equalTo: terminal.view.trailingAnchor),
                paneHost.bottomAnchor.constraint(equalTo: split.view.bottomAnchor),
            ])
            terminalSafeTop = paneHost.topAnchor.constraint(equalTo: split.view.safeAreaLayoutGuide.topAnchor)
            terminalFullTop = paneHost.topAnchor.constraint(equalTo: split.view.topAnchor)
            terminalSafeTop?.isActive = !hidesTitleBar
            terminalFullTop?.isActive = hidesTitleBar
            window.setFrame(frame, display: true)
            split.view.layoutSubtreeIfNeeded()
        }
        // The split re-hosts the window's content, and the style mask moves
        // with it: whatever the title row was painted into, or the window's
        // band was standing in, may not be the view it holds now.
        paintedChromeInputs = nil
        TabStripStyling.forgetTitlebar(of: window)
        syncPaneProgressBands()
        guard let inspectorItem else { return }
        let shouldCollapse = !inspectorItem.isCollapsed
        inspectorModel?.isObservationActive = !shouldCollapse
        if !shouldCollapse, let inspected {
            inspectorModel?.refresh(from: inspected)
        } else if let inspected {
            window.makeFirstResponder(inspected)
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            inspectorItem.isCollapsed = shouldCollapse
            window.contentView?.layoutSubtreeIfNeeded()
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                inspectorItem.animator().isCollapsed = shouldCollapse
            }
        }
    }

    /// Refreshes the visible inspector from the title and focus event path.
    ///
    /// - Parameter surface: The pane reporting a change, or the current pane.
    func refreshNativeInspector(from surface: TerminalSurface? = nil) {
        // The application's shared panel may be inspecting this window too.
        NotificationCenter.default.post(name: .terminalInspectedFactsChanged, object: self)
        guard let inspectorItem, !inspectorItem.isCollapsed, let model = inspectorModel,
            let inspected = surface ?? activeSurface ?? model.surface ?? projectedSurfaces.first
        else { return }
        if let surface, surface !== model.surface && surface !== activeSurface { return }
        // A call naming a surface is an event about that pane and refreshes on
        // it; a call with none is the self-healing pass every screen update
        // makes, and it re-captures the session's whole information and
        // rewrites every field the view observes. The key is what that pass is
        // compared against.
        let inputs = inspectorFacts(for: inspected)
        if surface == nil, inspectorInputs == inputs {
            return
        }
        inspectorInputs = inputs
        inspectorRefreshesForTesting += 1
        model.refresh(from: inspected)
    }

    /// Everything the Inspector shows, as facts rather than as a capture.
    ///
    /// The process table is the field with no event of its own: the session's
    /// process-state event fires when the chain moves, and a reaped background
    /// job or a stopped program leaves the chain standing. Core counts the
    /// sample's own moves, and that count is what this carries.
    ///
    /// - Parameter surface: The inspected pane.
    /// - Returns: The key.
    private func inspectorFacts(for surface: TerminalSurface) -> InspectorInputs {
        let renderer = surface.renderer as? SurfaceRenderer
        return InspectorInputs(
            surface: ObjectIdentifier(surface),
            session: surface.drive.sessionIdentity,
            weave: titleWeaveInputs(for: surface),
            background: themeBackground(of: surface),
            paletteEpoch: surface.drive.borrowTerminal()?.paletteEpoch ?? 0,
            processRecordsGeneration: surface.drive.processRecordsGeneration,
            answerbackDisplay: surface.drive.inspectorAnswerbackDisplay,
            fontFamily: renderer?.familyName ?? "",
            fontSize: renderer?.pointSize ?? 0
        )
    }

    /// What the Inspector was last refreshed from.
    private struct InspectorInputs: Equatable {
        var surface: ObjectIdentifier
        var session: UInt
        var weave: TitleWeaveFacts
        var background: UInt32
        var paletteEpoch: UInt64
        var processRecordsGeneration: UInt64
        var answerbackDisplay: String
        var fontFamily: String
        var fontSize: Double
    }

    private var inspectorInputs: InspectorInputs?

    /// Finds the view presenting a client request's originating session.
    package static func surface(forSessionIdentity identity: UInt) -> TerminalSurface? {
        for controller in spawnedControllers {
            if let surface = controller.projectedSurfaces.first(where: { $0.drive.sessionIdentity == identity }) {
                return surface
            }
        }
        return nil
    }

    // The app's one window model: topology, pane sessions and verb
    // resolution live in Core; each window of this shell projects one of its
    // surfaces. Optional only for the allocation failure spawn refuses on.
    static let windowModel = makeWindowModel()

    /// Makes the window model, its sessions able to host the windows of a
    /// program that asks to — a typed `tmux -CC` — through Core's control
    /// host, the one source this shell links.
    private static func makeWindowModel() -> Ubiquitty.Runtime.WorkspaceSession? {
        RuntimeDrive.enableHostedWindows(factoryAddress: UInt(Ubiquitty.Runtime.tmuxControlHostFactoryAddress()))
        return Ubiquitty.Runtime.WorkspaceSession.make(.threadDrained, .SizedAndProportional)
    }

    // This window's surface in the model, or invalidSurface for the hosted
    // shapes (tmux, remote) whose topology another authority owns — every
    // model call on it answers the empty case.
    private(set) var workspaceSurface = Ubiquitty.Session.Layout.invalidSurface

    // The views over the model's panes, keyed by the model's pane ids.
    internal var surfaces: [Ubiquitty.Session.Layout.PaneID: TerminalSurface] = [:] {
        // The ground is painted per pane, so a pane joining or leaving is a
        // chrome input like the theme is.
        didSet { paneSetGeneration += 1 }
    }
    // Which tree node each split view mirrors, for writing a divider drag
    // back as the node's ratio. Rebuilt with the hierarchy.
    private var splitNodes: [ObjectIdentifier: Int32] = [:]
    // The container the mirrored hierarchy lives in, so a rebuild swaps one
    // subview rather than the window's content.
    package let paneHost = PaneHostView(frame: .zero)

    /// The ⌘F bar, and the grid inset it costs while it is up.
    ///
    /// Held rather than made on demand so a query survives closing and
    /// reopening the bar, which is what makes ⌘F ⌘G ⌘G a workable rhythm.
    package lazy var findBar = UBFindBar(frame: .zero)
    internal var findBarInset: CGFloat = 0

    /// The frame CSI 9 t grew from, kept so `CSI 9 ; 0 t` can put it back.
    ///
    /// Nil while the window is at a size the reader chose. Maximize records it
    /// on the way out and clears it on the way back, so a second maximize does
    /// not overwrite the frame the first one is holding.
    internal var preMaximizeFrame: NSRect?

    /// The frame CSI 10 t filled the screen from, on the same terms.
    internal var preProgramFillScreenFrame: NSRect?

    /// Whether a program has filled the screen without a native transition.
    ///
    /// Its own flag rather than a comparison against the screen: a reader who
    /// zoomed the window to the same size did not ask a program to fill it, and
    /// `CSI 10 ; 0 t` must not shrink a window it never grew.
    internal var isProgramFillingScreen = false

    /// Whether a native full-screen transition is animating.
    internal var isInFullScreenTransition = false

    /// The state the running transition is heading for.
    ///
    /// The style mask lags the animation by its whole duration, so this is what
    /// a request arriving mid-flight is judged against.
    internal var fullScreenTransitionTarget = false

    /// How many times the chrome was painted again after a full-screen
    /// transition settled, for a scenario that drives the transition's hooks.
    package internal(set) var chromeSettlesAfterFullScreenForTesting = 0

    /// Whether the full-screen bracket is open, for a scenario that drives
    /// the transition's hooks.
    package var isInFullScreenTransitionForTesting: Bool { isInFullScreenTransition }

    /// The Dock bounce this window asked for, or nil when it asked for none.
    ///
    /// Kept because a cancel has no other handle: AppKit auto-cancels a
    /// critical request on activation, but a program that changes its mind
    /// before the reader looks can only name the request it made.
    internal var attentionRequestIdentifier: Int?

    /// A full-screen request that arrived mid-transition, run once it lands.
    internal var pendingFullScreenRequest: Bool?

    /// Geometry requests that arrived mid-transition, run once it lands.
    ///
    /// Sizing a window to a frame the animation is still moving lands it
    /// somewhere it will not be, so these wait for the frame to settle.
    internal var deferredGeometryRequests: [(operation: Int, first: Int, second: Int)] = []

    /// The frame a program's geometry requests have arrived at, not yet applied.
    ///
    /// CSI 3, 4, 8 and 9 t and DECCOLM land here rather than on the window, so
    /// a burst of them costs one frame change — one layout, one drawable size,
    /// one retained-grid allocation — for where the burst ends, instead of a
    /// synchronous draw and a fresh drawable allocation for every step.
    internal var programFrameTarget: NSRect?

    /// When a program's frame was last applied, for the once-per-display-frame bound.
    internal var programFrameAppliedAt: TimeInterval = 0

    /// Whether a held program frame has its flush booked.
    internal var isProgramFrameFlushBooked = false

    /// The find toggles, this window's. Not persisted yet: the Metal arm keeps
    /// them in config and this arm has no writer for one — see
    /// the-swift-shell-reaches-the-preference-writer.
    internal var isFindRegex = false
    package var isFindCaseSensitive = false

    // Strong, because the surface's renderer reference is weak by design —
    // one renderer serves every surface in a window, and the owner is the
    // window's controller.
    private let surfaceRenderer: any TerminalSurfaceRenderer
    private var bridge: SurfaceWindowBridge?

    // The zoom this window carries over the configured font size, in points.
    // View state: a zoom step is never persisted, and a new window opens at
    // zero.
    public private(set) var fontZoomOffset = 0.0

    // tmux hosting: surfaces keyed by tmux pane id, bound by the layout
    // apply; empty for a window of local sessions.
    var tmuxSurfaces: [Int32: TerminalSurface] = [:]
    // The model and lock each bound pane's surface adopted, so a bind naming
    // another pair for the same pane is seen as a retarget.
    var tmuxAdoptions: [Int32: TmuxAdoption] = [:]
    // The session each bound pane belongs to, as the address its binder named.
    // A pane id names a pane only inside its session, so the pane registry is
    // keyed by both and an unbind reads the pane's session back from here.
    var tmuxSessionAddresses: [Int32: UInt] = [:]
    // The hosted pane the reader was last in. A palette summoned over the
    // window takes the keyboard, and the intent it carries is still about the
    // pane the reader was typing in.
    weak var lastFocusedTmuxSurface: TerminalSurface?
    // The control-client size this window last reported to tmux, so a resize
    // that moves no cell sends nothing.
    var reportedTmuxClientGrid: TmuxClientGrid?
    // The windows a pane of this window hosts through its session, by the id
    // that session numbers them with; empty for every other window.
    var hostedWindows: [Int32: TerminalWindowController] = [:]
    // The pane whose session hosts this window's panes, when that session is
    // this process's own; nil for a window hosted from anywhere else.
    weak var hostingSurface: TerminalSurface?
    package var hostedWindowID: Int32 = -1
    package var isArrangementControlClient = false
    // Thin-client hosting: the one surface whose session attached remotely,
    // or nil for every other window shape.
    package var remoteSurface: TerminalSurface?
    // The host a remote window may install ubiquitty-host on, empty when the
    // connect offered none. Held here because the confirmation arrives later,
    // as an event, and names the host the user is being asked about.
    var deploySSHHost = ""
    /// The bundled hosts a push to ``deploySSHHost`` chooses from, by remote
    /// `uname -sm`; kept so a window replacing this one installs the same way.
    var remoteDeployBinaries: [String: String] = [:]
    /// What the last refusal sheet on this window said.
    package var lastRefusalSheetContent: RefusalSheetContent?
    /// Whether this connection's version refusal has had its sheet, so the
    /// state changes that follow the refusal do not put it up again.
    var hasPresentedVersionRefusal = false
    // The host this window's pairing is filed under, empty for a window whose
    // session is not remembered. Held rather than looked up: the host pins its
    // session id later, as an event, so the key a pairing is written with has
    // to outlive the connect that chose it. Reachable from the package so a
    // scenario can put a window on a host without a machine to connect to.
    package var remoteHostKey = ""
    // The session this window asked the host for, and thereafter the one the
    // host gave it. A reattach answered with a different id is a session that
    // had ended, and the two are told apart by comparing against this.
    var remoteRequestedSessionID: UInt32 = 0
    // A directory selection waits for its pane's first authoritative layout.
    var pendingRemoteActivationSessionID: UInt32 = 0
    // The host's workspace name, initially the connect intent until its first layout.
    package var remoteWorkspaceName = ""
    // Whether this window has said that the host restarted and recreated its
    // workspace; said once per window.
    var hasShownHostRestartNotice = false
    // How this window reached its host, so a sibling pane or tab of the
    // hosted workspace attaches the same way; nil for every other shape.
    var remoteConnection: RemoteConnection?
    /// The window's protected resume, when its attach prepared one.
    package var remoteResume: RemoteResume?
    // The hosted workspace's tab this window projects, keyed by the host's
    // pane ids: the remote surface among them once the first layout named
    // its pane, a view attached to each other pane's session beside it.
    package var remotePaneSurfaces: [Ubiquitty.Session.Layout.PaneID: TerminalSurface] = [:]
    // The host tab this window projects, invalid until the first layout.
    package var remoteWorkspaceTab = Ubiquitty.Session.Layout.invalidTab
    // The divider ratio a drag on a hosted workspace has yet to send.
    package var pendingRemoteDivider: (surface: TerminalSurface, generation: UInt64, splitIndex: Int32, ratio: Float)?
    // Set when the host dropped this window's tab, so the close that follows
    // asks the host for nothing.
    var isClosingWithHostTab = false
    /// The captured remote close/detach choice, retired when its attachment changes.
    var remoteClosePresentation: RemoteWindowClosePresentation?
    var windowRenderer: any TerminalSurfaceRenderer { surfaceRenderer }
    var windowBridge: SurfaceWindowBridge? { bridge }
    var transferTree = Ubiquitty.Panes.Tree()

    /// The surface of the model's focused pane — the model names it, the map
    /// resolves it.
    ///
    /// A hosted window holds no pane in the model, so this answers nothing for
    /// one: it is for a step the model itself takes. A verb about the window's
    /// focused pane reaches it through ``focusedPaneSurface``, which every
    /// window shape answers.
    var focusedSurface: TerminalSurface? {
        guard let model = Self.windowModel else {
            return nil
        }
        return surfaces[model.focusedPane(workspaceSurface)]
    }

    /// The focused pane's surface, whichever authority keeps the window's
    /// layout: the model's focused pane; the tmux pane the reader was last
    /// in, else the lowest; the pane a hosted workspace's host reports
    /// focused, else the hosted root, which a window shows before the host's
    /// first layout names a pane.
    ///
    /// Every window shape answers it, so a window verb about its focused pane
    /// cannot skip the hosted shapes by reading the model alone.
    /// ``activeSurface`` is this behind the first responder.
    var focusedPaneSurface: TerminalSurface? {
        if let local = focusedSurface { return local }
        if let last = lastFocusedTmuxSurface, tmuxSurfaces.values.contains(where: { $0 === last }) {
            return last
        }
        if let lowest = tmuxSurfaces.keys.min() { return tmuxSurfaces[lowest] }
        if let pane = Ubiquitty.Session.Layout.PaneID(rawValue: UInt32(max(0, transferTree.focusedPaneID()))),
            let remote = remotePaneSurfaces[pane]
        {
            return remote
        }
        return remoteSurface
    }

    /// The live pane count, from the model that owns the layout.
    var paneCount: Int {
        guard let model = Self.windowModel else {
            return 0
        }
        return Int(model.paneCount(workspaceSurface))
    }

    /// Whether the model records a zoomed pane for this window.
    var isZoomed: Bool {
        guard let model = Self.windowModel else {
            return false
        }
        return model.zoomedPane(workspaceSurface) != Ubiquitty.Session.Layout.invalidPane
    }

    /// Whether every native tab and pane can join the window's handoff.
    package var isWindowShareable: Bool {
        guard let model = Self.windowModel, let window else {
            return false
        }
        if let windowSharing { return windowSharing.canRetry }
        let tabs = window.tabbedWindows ?? [window]
        return tabs.allSatisfy {
            guard let controller = $0.windowController as? TerminalWindowController, controller.remoteSurface == nil else { return false }
            return model.isSurfaceShareable(controller.workspaceSurface)
        }
    }

    /// Whether closing the window kills no live job — the model's
    /// safe-to-close fact, the same one the edited dot mirrors.
    package var isSafeToClose: Bool {
        guard let model = Self.windowModel else {
            return true
        }
        return model.isSurfaceSafeToClose(workspaceSurface)
    }

    /// The surface a pane verb addresses: the first responder when it is a
    /// surface of this window (the tmux and remote maps included), else the
    /// window's ``focusedPaneSurface``. The verb itself goes to the session,
    /// which knows what its backend is — this side only finds the pane the
    /// user means.
    var activeSurface: TerminalSurface? {
        if let responder = window?.firstResponder as? TerminalSurface, responder.window === window {
            return responder
        }
        return focusedPaneSurface
    }

    /// The surface whose facts name the window and its tab: the active pane,
    /// or a hosted window's root while no surface of it holds focus.
    var titleSurface: TerminalSurface? { activeSurface ?? remoteSurface }

    /// The Stream Debug recorder of the frontmost local session in this window.
    /// Used by the Stream Debug window to follow the active terminal.
    package static func frontmostStreamDebugRecorder() -> StreamDebugRecorder? {
        // The window z-order, front to back: the key window leads it when a
        // terminal is key, and when the floating debug window itself is key
        // the frontmost TERMINAL window is still the one the user was just
        // on — where spawn order would name an arbitrary window instead.
        let controllers = spawnedControllers
        for window in NSApp.orderedWindows {
            guard let controller = controllers.first(where: { $0.window === window }) else { continue }
            if let surface = controller.activeSurface ?? controller.focusedSurface {
                return surface.streamDebugRecorder
            }
        }
        return nil
    }

    /// The adaptive drive readout of `window`'s active surface, for the
    /// Adaptive Drive debug window; nil when `window` is not one of ours.
    package static func adaptiveDriveFacts(for window: NSWindow) -> AdaptiveDriveFacts? {
        guard let controller = spawnedControllers.first(where: { $0.window === window }) else { return nil }
        return (controller.activeSurface ?? controller.focusedSurface)?.adaptiveDriveFacts()
    }

    /// The renderer configuration this window draws under: Core's fold of the
    /// live document, with the window's profile — the one it was opened or
    /// re-dressed under, and its temporary overrides — laid over it first.
    var windowRenderConfiguration: Ubiquitty.Rendering.RenderConfiguration {
        Ubiquitty.Preferences.Effective.renderConfiguration(Ubiquitty.Preferences.values().pointee, effectiveProfile)
    }

    /// The last typography applied to this window, including its platform and profile overrides.
    var appliedTypographyConfiguration: Ubiquitty.Rendering.RenderConfiguration?

    /// What the live configuration document could not apply, as the title
    /// row says it; empty when it applied whole.
    private static var configurationDiagnostic = ""

    /// The diagnostic lines the reader dismissed, for as long as the app runs.
    ///
    /// Keyed by the line, which names the file and carries the diagnostics'
    /// own content: the same document reloaded raises the same line and stays
    /// quiet, and a document that says something else is heard.
    private static var dismissedConfigurationDiagnostics: Set<String> = []

    /// The diagnostic as a window should show it: empty once dismissed.
    private static var shownConfigurationDiagnostic: String {
        dismissedConfigurationDiagnostics.contains(configurationDiagnostic) ? "" : configurationDiagnostic
    }

    /// Shows the live document's diagnostics in every open window's title row.
    ///
    /// A key the parse could not place is a setting the reader wrote and will
    /// not get; the log is not where they look. A window opened later shows
    /// the same line, and a document that applies whole withdraws it.
    @objc
    public static func showConfigurationDiagnostics() {
        let summary = String(Ubiquitty.Preferences.liveDiagnosticSummary())
        let line = summary.isEmpty ? "" : "config.toml \(summary)"
        guard line != configurationDiagnostic else { return }
        configurationDiagnostic = line
        for controller in spawnedControllers {
            controller.showConfigurationDiagnostic()
        }
    }

    /// Withdraws the diagnostic from every window and remembers it was read.
    private static func dismissConfigurationDiagnostic() {
        let line = configurationDiagnostic
        guard !line.isEmpty else { return }
        dismissedConfigurationDiagnostics.insert(line)
        // A window teaching a gesture in the same line keeps its lesson.
        for controller in spawnedControllers where controller.windowHintAccessory?.stringValue == line {
            controller.windowHintAccessory?.show("")
        }
    }

    /// Puts the diagnostic, or nothing, in this window's hint line.
    private func showConfigurationDiagnostic() {
        let line = Self.shownConfigurationDiagnostic
        windowHintAccessory?.show(line, onDismiss: line.isEmpty ? nil : { Self.dismissConfigurationDiagnostic() })
    }

    /// Re-feeds every open window's terminal the settings the model carries as
    /// they now stand: the password-prompt heuristic, the bell cue and the
    /// ambiguous-width choice. Each is a per-terminal fact Core seeds at
    /// launch, and a reader who turns one on expects the next prompt — or the
    /// next bell — in an open window to obey.
    ///
    /// The process-wide ones ride the same reload: `[unicode] normalization`
    /// has no terminal to live on, and every find in every window reads it.
    @objc
    public static func applyTerminalPreferencesToOpenWindows() {
        defer { NotificationCenter.default.post(name: .terminalAppearanceChanged, object: nil) }
        let config = Ubiquitty.Preferences.values()
        Ubiquitty.Runtime.applyProcessPreferences(config.pointee)
        for controller in spawnedControllers {
            for surface in controller.projectedSurfaces {
                surface.drive.applyTerminalPreferences(config.pointee)
                // The rules a launch compiled, compiled again from the file as
                // it now stands, so a rule added to an open window's config
                // fires in that window and not only in the next one.
                Self.reportTriggerConfiguration(surface.drive.applyTriggerConfiguration(config.pointee))
                // A preference write produces no ingest, so nothing would
                // republish the snapshot every reader downstream polls — the
                // frame's cursor shape, and the animation schedule's decision
                // about whether anything on screen still moves. Without this a
                // blink turned on sits inert until the next PTY echo, which
                // for a reader means until they type.
                surface.republishAfterPreferenceWrite()
            }
        }
    }

    /// Applies the cursor preferences to every open window after the reader
    /// picked a shape.
    ///
    /// Distinct from ``applyTerminalPreferencesToOpenWindows`` in one field:
    /// Core hands `cursorStyle` back to the reader here, so the pick outranks
    /// whatever DECSCUSR a shell that dresses its prompt left standing. A
    /// reload takes the other path and leaves that style alone.
    @objc
    public static func applyPickedCursorShapeToOpenWindows() {
        defer { NotificationCenter.default.post(name: .terminalAppearanceChanged, object: nil) }
        let config = Ubiquitty.Preferences.values()
        for controller in spawnedControllers {
            for surface in controller.projectedSurfaces {
                surface.drive.applyPickedCursorPreferences(config.pointee)
                // A preference write produces no ingest, so nothing else would
                // republish the snapshot the frame's cursor is read from.
                surface.republishAfterPreferenceWrite()
            }
        }
    }

    /// Installs the configured background image on every pane of this window.
    ///
    /// The decode is the Kit component both shells call, and the result is
    /// cached against the path and colour space it was decoded for: this runs
    /// from the translucency pass, which a theme repaint and an opacity change
    /// both reach, and re-reading the file on each of those would cost a
    /// decode per repaint for a picture that has not moved.
    private func applyBackgroundImage() {
        let configuration = windowRenderConfiguration
        let path = String(configuration.backgroundImagePath.string())
        let usesDisplayP3 = configuration.usesDisplayP3
        let opacity = configuration.backgroundImageOpacity
        let mode = Int32(configuration.backgroundImageMode.rawValue)
        // One comparison covers both the change and the clear: an emptied key
        // differs from the path that was decoded, and the decode refuses an
        // empty path, so the picture comes down without a case of its own.
        if backdropImagePath != path || backdropImageUsesDisplayP3 != usesDisplayP3 {
            backdropImage = projectedSurfaces.lazy
                .compactMap { $0.renderer as? SurfaceRenderer }
                .first
                .flatMap { BackdropImage.load(path: path, usesDisplayP3: usesDisplayP3, device: $0.device) }
            backdropImagePath = path
            backdropImageUsesDisplayP3 = usesDisplayP3
        }
        for surface in projectedSurfaces {
            guard let renderer = surface.renderer as? SurfaceRenderer else { continue }
            renderer.setBackdrop(
                texture: backdropImage?.texture,
                opacity: opacity,
                mode: mode,
                pixelWidth: Int32(backdropImage?.pixelWidth ?? 0),
                pixelHeight: Int32(backdropImage?.pixelHeight ?? 0)
            )
            surface.needsDisplay = true
        }
    }

    /// Re-feeds every open window the font configuration as it now stands.
    ///
    /// A setting a window was opened with is one the reader can change while
    /// it is open. Each window re-reads its own configuration — the live fold
    /// with its profile over it — rather than being handed a value, so this
    /// cannot drift from what a newly opened window would read.
    @objc
    public static func applyFontConfigurationToOpenWindows() {
        defer { NotificationCenter.default.post(name: .terminalAppearanceChanged, object: nil) }
        var reached = 0
        var skipped = 0
        for controller in spawnedControllers {
            let counts = controller.applyWindowTypography()
            reached += counts.reached
            skipped += counts.skipped
        }
        if ProcessInfo.processInfo.environment["UBQ_FONTLOG"] != nil {
            NSLog(
                "UBQ_FONTLOG apply controllers=%d reached=%d skipped=%d spec=%@",
                spawnedControllers.count,
                reached,
                skipped,
                String(Ubiquitty.Preferences.Effective.liveRenderConfiguration().fontFeatures.string())
            )
        }
    }

    /// Re-feeds this window the faces its configuration names: the family,
    /// the size through the window's zoom, the typography and the colour
    /// space the frame is tagged with.
    ///
    /// - Returns: How many surfaces took the faces, and how many had no
    ///   renderer of this arm to take them.
    @discardableResult
    func applyWindowTypography() -> (reached: Int, skipped: Int) {
        let configuration = windowRenderConfiguration
        appliedTypographyConfiguration = configuration
        let typography = SurfaceTypography(configuration: configuration)
        let family = TerminalSurface.family(of: configuration)
        // The configured size is the default; each window renders it through
        // its own zoom, so a zoomed window keeps its zoom over the new default.
        let pointSize = Ubiquitty.Preferences.Zoom.zoomedFontSize(configuration.fontSizePoints, fontZoomOffset)
        var reached = 0
        var skipped = 0
        // One wrapped pass: the family, the size and the typography —
        // variations, weight, width, tracking, line spacing — all move the
        // cell, so the window follows the font or holds and reflows. Features
        // move no cell and the answer is a no-op.
        applyCellMetricChange {
            for surface in projectedSurfaces {
                guard let renderer = surface.renderer as? SurfaceRenderer else {
                    // Its frames were drawn on the cell the change moves,
                    // whichever renderer drew them.
                    surface.discardRetainedFrames()
                    skipped += 1
                    continue
                }
                // A family the face store refuses leaves the window on what it
                // is drawing rather than on a name whose sheets could not be
                // cut, and the house family is what a configuration naming
                // nothing resolves to.
                if !renderer.adopt(pointSize: pointSize, familyName: family, typography: typography) {
                    renderer.adopt(pointSize: pointSize, familyName: TerminalSurface.installedHouseFontFamily(), typography: typography)
                }
                surface.drive.publishActualFont(family: renderer.familyName, sizePoints: renderer.pointSize)
                // The colour-space tag rides the same re-apply: it is the other
                // setting that changes how the frame's bytes are read.
                renderer.adopt(usesDisplayP3: configuration.usesDisplayP3, relabeling: surface.metalLayer)
                // The adopt drops the renderer's retained stamps; the
                // surface's own renderers, their grids and the baseline go
                // with them, or the next frame clears and paints no row over
                // the clear, because the cells did not change — only the faces
                // they are drawn with did.
                surface.discardRetainedFrames()
                reached += 1
            }
        }
        // The colour space the chrome paints in rides this re-feed, since it
        // is what re-tags the body's layer: the chrome's memo holds the space
        // it painted, and a triple is a different colour in each.
        isTerminalColorSpaceDisplayP3 = configuration.usesDisplayP3
        paintedChromeInputs = nil
        applyChromeTheme()
        return (reached, skipped)
    }

    /// Applies scroll preferences to every open terminal.
    package static func applyScrollPreferencesToOpenWindows() {
        for controller in spawnedControllers {
            for surface in controller.projectedSurfaces {
                surface.applyScrollPreferences()
            }
        }
    }

    /// Re-feeds every open window the appearance styling as it now stands —
    /// the padding, the underline rule, bold brightening, cursor inversion,
    /// the opacity — and relays each surface's grid out under it.
    ///
    /// The style is re-derived from the fold rather than patched field by
    /// field, so it cannot drift from what a newly opened window reads. A
    /// window that reads its padding only at launch keeps its text hard
    /// against the old inset until a cursor move happens to repaint it.
    @objc
    public static func applyAppearanceToOpenWindows() {
        defer { NotificationCenter.default.post(name: .terminalAppearanceChanged, object: nil) }
        for controller in spawnedControllers {
            controller.applyWindowStyle()
        }
    }

    /// Re-feeds this window the frame style its configuration names, then the
    /// ground and the chrome that follow it.
    func applyWindowStyle() {
        // The chrome-dependent top edge is folded into the style before it is
        // applied, so the four edges land in one pass: the fold carries
        // `padding_top`, and a chromeless window's grid takes the inset sized
        // for a frame edge instead. Applied through the cell-metric path,
        // because padding moves the box the grid fits and a window that chose
        // its size keeps its grid at the new padding.
        let configuration = windowRenderConfiguration
        var adopted = SurfaceStyle(configuration: configuration, systemTransparency: Self.systemTransparency)
        adopted.paddingTopPoints = ChromelessWindowChrome.contentTopPadding(isChromeless: hidesTitleBar, configuration: configuration)
        applyCellMetricChange {
            for surface in projectedSurfaces {
                guard let renderer = surface.renderer as? SurfaceRenderer else { continue }
                renderer.style = adopted
            }
        }
        // The opacity is a window fact as much as a frame one: the frame
        // carries the alpha, the window lets the compositor honour it.
        applyTranslucency()
        applyChromeTheme()
        // The chrome's own type size rides `[appearance] ui_font_scale`, so
        // the labels are re-derived here as well as the frame: a reader who
        // enlarged them and saw the grid restyle around unchanged titles
        // would read the setting as half-applied.
        refreshTitles()
    }

    /// Re-feeds every open window the Tektronix styling as it now stands.
    @objc
    public static func applyTektronixSettingsToOpenWindows() {
        let adopted = SurfaceTekSettings(configuration: Ubiquitty.Preferences.Effective.liveRenderConfiguration())
        for controller in spawnedControllers {
            for surface in controller.projectedSurfaces {
                guard let renderer = surface.renderer as? SurfaceRenderer else { continue }
                renderer.tekSettings = adopted
                surface.needsDisplay = true
            }
        }
    }

    /// Applies an Inspector font choice to the inspected renderer and its shared panes.
    ///
    /// - Parameters:
    ///   - surface: The inspected terminal surface.
    ///   - family: The requested font family.
    ///   - size: The requested point size.
    /// - Returns: Whether the renderer accepted the font.
    func applyInspectedFont(on surface: TerminalSurface, family: String, size: Double) -> Bool {
        guard projectedSurfaces.contains(where: { $0 === surface }),
            let renderer = surface.renderer as? SurfaceRenderer,
            size.isFinite, size >= 6, size <= 144
        else { return false }
        var accepted = false
        applyCellMetricChange {
            accepted = renderer.adopt(pointSize: size, familyName: family, typography: renderer.typography)
            guard accepted else { return }
            for pane in projectedSurfaces where pane.renderer === renderer {
                pane.drive.publishActualFont(family: renderer.familyName, sizePoints: renderer.pointSize)
                pane.discardRetainedFrames()
            }
        }
        refreshNativeInspector(from: surface)
        return accepted
    }

    /// Applies the font swap an application asked for with OSC 50.
    ///
    /// Core resolves each operation in order against the acknowledged actual
    /// font. This adapter adopts it and reports the outcome, including the face
    /// actually drawn when the font store substitutes one.
    ///
    /// - Parameter surface: The surface whose session carries the request.
    func applyFontSwap(on surface: TerminalSurface) {
        guard let renderer = surface.renderer as? SurfaceRenderer else { return }
        let configuration = windowRenderConfiguration
        let configuredFamily = TerminalSurface.family(of: configuration)
        for _ in 0..<RuntimeDrive.maxFontRequestsPerDelivery {
            guard
                let request = surface.drive.beginFontRequest(
                    configuredFamily: configuredFamily,
                    configuredSizePoints: configuration.fontSizePoints
                )
            else { break }
            let didApply =
                request.isResolved
                && renderer.adopt(
                    pointSize: request.sizePoints,
                    familyName: request.family,
                    typography: renderer.typography
                )
            let didAcknowledge = surface.drive.acknowledgeFontRequest(
                request,
                didApply: didApply,
                actualFamily: renderer.familyName,
                actualSizePoints: renderer.pointSize
            )
            if didApply {
                // Panes can share a renderer; each Core session must learn
                // the actual font its shared glyph sheets now represent.
                for sibling in projectedSurfaces
                where sibling !== surface && sibling.renderer === renderer {
                    sibling.drive.publishActualFont(family: renderer.familyName, sizePoints: renderer.pointSize)
                    sibling.resizeGridToBounds()
                    sibling.invalidateRetainedBaseline()
                    sibling.needsDisplay = true
                }
                surface.resizeGridToBounds()
                surface.invalidateRetainedBaseline()
                surface.needsDisplay = true
            }
            if !didAcknowledge { break }
        }
    }

    /// Builds an empty window for tmux hosting; the layout apply fills it.
    ///
    /// - Returns: The controller, or nil when the renderer cannot be built.
    static func spawnEmptyForTmux() -> TerminalWindowController? {
        let launch = Ubiquitty.Preferences.Effective.launchSettings()
        guard
            let renderer = TerminalSurface.makeRenderer(
                configuration: Ubiquitty.Preferences.Effective.liveRenderConfiguration(),
                systemTransparency: systemTransparency
            )
        else {
            return nil
        }
        let controller = TerminalWindowController(tmuxRenderer: renderer)
        controller.applyWindowAppearance(launch)
        return controller
    }

    /// Builds a window, launches the login shell in it, and shows it.
    ///
    /// - Returns: The controller, or nil when the window cannot be built — no
    ///   Metal device, no shader library, an unresolvable font, or a shell
    ///   that does not start. The person is told which.
    @objc
    public static func spawn() -> TerminalWindowController? {
        spawn(inheritingDirectory: "")
    }

    /// Opens a window whose login shell starts in a directory.
    ///
    /// What the directory means when it is the user's home, or empty, is
    /// Core's: `LaunchCommand::startDirectoryFor` answers empty for both, so
    /// the login program reaches home the cheap way rather than through a
    /// flag and a re-exec.
    ///
    /// - Parameters:
    ///   - directory: Where the new session starts; empty for home.
    ///   - request: What the person asked for, which names a refusal's notice.
    /// - Returns: The controller, or nil when the window cannot be built.
    package static func spawn(inheritingDirectory directory: String, as request: SpawnRequest = .window) -> TerminalWindowController? {
        spawn(inheritingDirectory: directory, openingScreen: .none, as: request)
    }

    /// Opens a window whose login shell starts in a directory, its first
    /// output held for a screen the caller writes.
    ///
    /// - Parameters:
    ///   - directory: Where the new session starts; empty for home.
    ///   - openingScreen: Whether the shell's output waits for
    ///     `RuntimeDrive.finishOpeningScreen`.
    ///   - request: What the person asked for, which names a refusal's notice.
    /// - Returns: The controller, or nil when the window cannot be built.
    package static func spawn(
        inheritingDirectory directory: String,
        openingScreen: Ubiquitty.Runtime.OpeningScreen,
        as request: SpawnRequest = .window
    ) -> TerminalWindowController? {
        let start = Ubiquitty.Runtime.LaunchCommand.startDirectoryFor(std.string(directory), std.string(NSHomeDirectory()))
        var command = Ubiquitty.Runtime.LaunchCommand.loginSession(start)
        command.setOpeningScreen(openingScreen)
        return spawn(as: request, opening: { $0.addWindowSurface(command) })
    }

    /// Builds a window running an explicit argument vector — the open-with
    /// event, the `-e` command line, the picker that names a program.
    ///
    /// The arguments cross as a Core draft rather than as a container: the
    /// model assembles the command, resolves the rest of the launch from
    /// config, and answers with the surface, so this side spells intent and
    /// nothing more.
    ///
    /// - Parameters:
    ///   - arguments: The argument vector; the first names the executable.
    ///     Empty opens the login shell.
    ///   - localePolicy: How the child's character locale is decided.
    ///   - sessionLifetime: Whether this window's session ends when the
    ///     program does. It rides the launch so the exit reads it per session;
    ///     a `-e` window and a ⌘N window of one process hold both answers.
    /// - Returns: The controller, or nil when the window cannot be built.
    ///
    /// Package rather than public because both policies are C++ types: the
    /// framework's evolution interface has no spelling for one, so the public
    /// entry is the raw-value pair below and this is the typed body behind
    /// it, which the scenarios in the package name directly.
    package static func spawn(
        arguments: [String],
        localePolicy: Ubiquitty.PAL.CharacterLocalePolicy,
        sessionLifetime: Ubiquitty.Runtime.SessionLifetime,
        showing presentation: SpawnPresentation = .showsAndEnrols,
        tmuxControlHost: String? = nil
    ) -> TerminalWindowController? {
        spawn(
            showing: presentation,
            opening: { model in
                var draft = Ubiquitty.Runtime.LaunchCommandDraft()
                for argument in arguments {
                    draft.addArgument(std.string(argument))
                }
                draft.setCharacterLocalePolicy(localePolicy)
                draft.setSessionLifetime(sessionLifetime)
                if let tmuxControlHost {
                    draft.setTmuxControlHost(std.string(tmuxControlHost))
                }
                return model.addWindowSurface(draft)
            }
        )
    }

    /// Builds a window rebuilt from a captured split layout — the restore at
    /// launch.
    ///
    /// The model adopts the layout and launches a shell per leaf; this side
    /// makes a view for each pane it reports, which is the same projection
    /// an ordinary window does after a split.
    ///
    /// - Parameter layout: The captured layout string.
    /// - Returns: The controller, or nil when the window cannot be built.
    public static func spawn(restoringLayout layout: String) -> TerminalWindowController? {
        spawn(opening: { $0.addWindowSurfaceRestoring(std.string(layout)) })
    }

    /// Opens fresh local shells in a captured arrangement's exact pane layout.
    package static func spawn(restoringArrangement archive: String) -> TerminalWindowController? {
        spawn(opening: { $0.addWindowSurfaceFromArrangement(std.string(archive)) })
    }

    /// Builds a window without showing it — the drop-down panel's shape.
    ///
    /// The panel restyles its window into a borderless floating strip and
    /// drives the show itself, so a spawn that ordered the window front
    /// would flash an ordinary window first. It stays out of the spawn
    /// roster too: the panel is a singleton its own owner holds, and a
    /// closed roster entry would end its sessions behind that owner's back.
    ///
    /// - Returns: The controller, or nil when the window cannot be built.
    @objc(spawnUnshownPanel)
    public static func spawnUnshownPanel() -> TerminalWindowController? {
        spawn(showing: .staysHidden, opening: { $0.addWindowSurface() })
    }

    /// Builds a window under a named profile — the "New Window with Profile"
    /// menu.
    ///
    /// The profile resolves into the launch fold in Core, so the window is
    /// built from one struct whether a profile named it or not, and a field
    /// the profile leaves unset keeps the configuration's answer.
    ///
    /// A profile's `startup_host` opens the window on that host. What the value
    /// may say is Core's rule: a profile is shareable, and the spawn executes
    /// argument zero, so the value names a host and nothing that could run a
    /// program. A refused value opens the local shell and says why on the
    /// diagnostics stream — a setting that stops working silently reads as a
    /// broken feature.
    ///
    /// - Parameter profileName: The profile to resolve, by name.
    /// - Returns: The controller, or nil when the window cannot be built.
    @objc(spawnWithProfileNamed:)
    public static func spawn(profileNamed profileName: String) -> TerminalWindowController? {
        spawn(profileNamed: profileName, as: .window)
    }

    /// Builds a window under a named profile, for a window or a tab.
    ///
    /// - Parameters:
    ///   - profileName: The profile to resolve, by name.
    ///   - request: What the person asked for, which names a refusal's notice.
    /// - Returns: The controller, or nil when the window cannot be built.
    package static func spawn(profileNamed profileName: String, as request: SpawnRequest) -> TerminalWindowController? {
        let values = Ubiquitty.Preferences.values().pointee
        let profile = Ubiquitty.Preferences.resolvedSessionProfile(
            values,
            std.string(profileName),
            Ubiquitty.Preferences.Profile(),
            Ubiquitty.Preferences.Profile()
        )
        let launch = Ubiquitty.Preferences.Effective.launchSettings(values, profile)
        let remoteArguments = startupHostArguments(launch, profileName: profileName)
        let controller = spawn(
            launch: launch,
            configuration: Ubiquitty.Preferences.Effective.renderConfiguration(values, profile),
            as: request,
            opening: { model in
                guard !remoteArguments.isEmpty else { return model.addWindowSurface() }
                var draft = Ubiquitty.Runtime.LaunchCommandDraft()
                for argument in remoteArguments {
                    draft.addArgument(std.string(argument))
                }
                return model.addWindowSurface(draft)
            }
        )
        // Remembered for the title segment that names it: the profile is a
        // property of the window a person opened, and nothing on the session
        // carries it back afterwards.
        controller?.appliedProfileName = profileName
        controller?.refreshTitles()
        return controller
    }

    /// The argument vector a profile's `startup_host` launches.
    ///
    /// - Parameters:
    ///   - launch: The profile's resolved launch settings.
    ///   - profileName: The profile, for the refusal's sentence.
    /// - Returns: The ssh or mosh argv, or empty for the local shell.
    package static func startupHostArguments(
        _ launch: Ubiquitty.Preferences.Effective.LaunchSettings,
        profileName: String
    ) -> [String] {
        guard !launch.startupHost.empty() else { return [] }
        let plan = Ubiquitty.Network.buildStartupHostLaunch(
            Ubiquitty.Preferences.values().pointee,
            std.string(resolveTool(named: "ssh") ?? ""),
            std.string(resolveTool(named: "mosh") ?? ""),
            launch.startupHost
        )
        guard plan.accepted() else {
            let reason = String(cString: Ubiquitty.Network.startupHostRejectionReason(plan.rejection))
            NSLog(
                "ubiquitty: profile \"%@\" startup_host refused: %@ (%@)",
                profileName,
                reason,
                String(launch.startupHost)
            )
            return []
        }
        return plan.arguments.map { String($0) }
    }

    /// Applies a resolved profile's presentation to this window's existing sessions.
    ///
    /// - Parameter profileName: The configured profile to resolve through Core.
    @objc(applyProfileNamed:)
    public func applyProfile(named profileName: String) {
        let configuration = Ubiquitty.Preferences.values().pointee
        let profile = Ubiquitty.Preferences.resolvedSessionProfile(
            configuration,
            std.string(profileName),
            Ubiquitty.Preferences.Profile(),
            temporaryProfile
        )
        appliedProfileName = profileName
        if let theme = profile.themeName.value {
            applyColorPreset(named: String(theme))
        } else {
            for surface in projectedSurfaces {
                _ = surface.drive.reseedLaunchTheme(configuration)
                surface.republishAfterPreferenceWrite()
            }
        }
        applyHideTitleBar(Ubiquitty.Preferences.Effective.hideTitleBar(configuration, profile))
        // The faces and the frame style re-derive from the configuration with
        // the profile folded in, the path every configure takes, so a profile
        // and a later settings change cannot disagree about a field.
        applyWindowTypography()
        applyWindowStyle()
        applyWindowTags()
        // A profile moves settings the chrome reads without moving the
        // terminal's colours — hiding the title bar at the same theme is the
        // case that reached a window and did nothing — so the memo is dropped
        // rather than trusted to carry every one of them.
        paintedChromeInputs = nil
        refreshTitles()
        applyChromeTheme()
    }

    /// Builds a window on a serial line — the Session menu's serial open.
    ///
    /// - Parameters:
    ///   - devicePath: The line to open.
    ///   - baudRate: The speed, 0 for the line's current one.
    /// - Returns: The controller, or nil when the line or the window refused.
    @objc(spawnOnSerialDevice:baudRate:)
    public static func spawn(serialDevice devicePath: String, baudRate: Int32) -> TerminalWindowController? {
        spawn(opening: { $0.addWindowSurfaceOnSerialLine(std.string(devicePath), baudRate) })
    }

    /// The spawn above, for the Objective-C++ app delegate.
    ///
    /// The policy crosses as its raw value because a C++ enum in an `@objc`
    /// signature reaches the generated header as a forward reference, which
    /// is not a thing C++ allows; the delegate holds the enum itself and
    /// casts at the call. Out of range resolves to `auto`, which is the
    /// policy a caller naming nothing should get.
    ///
    /// - Parameters:
    ///   - arguments: The argument vector; the first names the executable.
    ///   - localePolicyRawValue: `PAL::CharacterLocalePolicy`'s raw value.
    ///   - sessionLifetimeRawValue: `Runtime::SessionLifetime`'s raw value.
    /// - Returns: The controller, or nil when the window cannot be built.
    @objc(spawnWithArguments:localePolicyRawValue:sessionLifetimeRawValue:)
    public static func spawn(arguments: [String], localePolicyRawValue: Int32, sessionLifetimeRawValue: Int32) -> TerminalWindowController?
    {
        let policy = Ubiquitty.PAL.CharacterLocalePolicy(rawValue: max(0, localePolicyRawValue)) ?? .auto
        // Anything but the one value that names the child's lifetime resolves
        // to the lifetime a caller naming nothing should get: a window must not
        // inherit a command line's lifetime by accident.
        let endsWithChild = Ubiquitty.Runtime.SessionLifetime.endsWithChild
        let lifetime: Ubiquitty.Runtime.SessionLifetime =
            sessionLifetimeRawValue == Int32(endsWithChild.rawValue) ? endsWithChild : .outlivesChild
        return spawn(arguments: arguments, localePolicy: policy, sessionLifetime: lifetime)
    }

    /// Opens a remote shell command through the session's normal input and output route.
    @objc(spawnRemoteShellWithArguments:host:localePolicyRawValue:)
    public static func spawnRemoteShell(arguments: [String], host: String, localePolicyRawValue: Int32) -> TerminalWindowController? {
        let policy = Ubiquitty.PAL.CharacterLocalePolicy(rawValue: max(0, localePolicyRawValue)) ?? .auto
        guard let controller = spawn(arguments: arguments, localePolicy: policy, sessionLifetime: .outlivesChild) else { return nil }
        controller.remoteHostKey = host
        controller.remoteHostLabel = host
        controller.refreshTitles()
        return controller
    }

    /// Whether a spawn presents its window and enrols it in the roster.
    package enum SpawnPresentation {
        /// The ordinary window: ordered front, focused, roster-tracked.
        case showsAndEnrols
        /// The panel: built and handed back for its owner to place.
        case staysHidden
        /// A retained control connection whose hosted windows provide its interface.
        case hiddenControlClient
    }

    /// The one spawn body: whatever opens the surface, the view work is the
    /// same — a renderer from the launch fold, a view over the root pane's
    /// session, a window sized to the grid.
    ///
    /// A spawn that cannot proceed says why, to the diagnostics stream and to
    /// the person (``report(_:opening:)``): the command that asked has no
    /// window to show, and a refusal nobody hears reads as a command the app
    /// ignored.
    ///
    /// - Parameters:
    ///   - launch: The launch fold the window is sized and seeded from.
    ///   - configuration: The render configuration its renderer is built from.
    ///   - presentation: Whether the window is shown and enrolled.
    ///   - request: What the person asked for, which names a refusal's notice.
    ///   - open: Opens the model surface this window projects.
    /// - Returns: The controller, or nil when the window cannot be built.
    private static func spawn(
        launch: Ubiquitty.Preferences.Effective.LaunchSettings = Ubiquitty.Preferences.Effective.launchSettings(),
        configuration: Ubiquitty.Rendering.RenderConfiguration = Ubiquitty.Preferences.Effective.liveRenderConfiguration(),
        showing presentation: SpawnPresentation = .showsAndEnrols,
        as request: SpawnRequest = .window,
        opening open: (Ubiquitty.Runtime.WorkspaceSession) -> Ubiquitty.Session.Layout.SurfaceID
    ) -> TerminalWindowController? {
        guard let model = windowModel else {
            report(.noWindowModel, opening: request)
            return nil
        }
        let renderer: any TerminalSurfaceRenderer
        switch TerminalSurface.buildRenderer(configuration: configuration, systemTransparency: systemTransparency) {
        case .success(let built):
            renderer = built
        case .failure(let reason):
            report(
                .noRenderer(reason, family: TerminalSurface.family(of: configuration), pointSize: configuration.fontSizePoints),
                opening: request
            )
            return nil
        }
        // The system's contrast request, written where the model's theme
        // application reads it, before the model seeds the surface's theme.
        adoptSystemAccessibility()
        // The process-wide preferences as the configuration stands, so the
        // first window's find normalizes the way the file says before any
        // reload has run.
        Ubiquitty.Runtime.applyProcessPreferences(Ubiquitty.Preferences.values().pointee)
        // The model opens the window's surface whole: the root pane, its
        // session, the launched shell. This side makes the view.
        let workspaceSurface = open(model)
        // What the seed's trigger compile refused, written where the reload's
        // refusals are: a rule the launch dropped leaves no other trace, and
        // reads as a rule the file never carried. Every pane this open made —
        // a restored layout's leaves among them — compiled from one
        // configuration, so the model's last report speaks for all of them,
        // and the sink drops a report it has already written.
        Self.reportTriggerConfiguration(String(model.lastLaunchReport()))
        guard workspaceSurface != Ubiquitty.Session.Layout.invalidSurface else {
            report(.noSurface, opening: request)
            return nil
        }
        let pane = model.focusedPane(workspaceSurface)
        guard let session = model.session(pane) else {
            model.closeWindowSurface(workspaceSurface)
            report(.noSession, opening: request)
            return nil
        }
        let surface = TerminalSurface(drive: RuntimeDrive(over: session), rows: launch.rows, columns: launch.columns)
        surface.renderer = renderer
        let controller = TerminalWindowController(
            workspaceSurface: workspaceSurface,
            pane: pane,
            surface: surface,
            renderer: renderer,
            rows: launch.rows,
            columns: launch.columns,
            isGridPinned: launch.isGridPinned
        )
        controller.adoptModelPanes(besides: pane, renderer: renderer, launch: launch)
        controller.applyAutomaticThemeAtLaunch()
        controller.applyWindowAppearance(launch)
        guard presentation != .staysHidden else {
            return controller
        }
        ClosedWindowRecovery.shared.installMenuItem()
        spawnedControllers.append(controller)
        if presentation == .hiddenControlClient {
            controller.isArrangementControlClient = true
            controller.window?.isExcludedFromWindowsMenu = true
            controller.window?.tabbingMode = .disallowed
            return controller
        }
        // Opened the way the last one was left: a reader who asked for floating
        // windows asked about windows, not about that one.
        controller.window.map { WindowLevelMemory.apply(to: $0) }
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(surface)
        return controller
    }

    /// Applies the current macOS appearance before a new window is shown.
    private func applyAutomaticThemeAtLaunch() {
        applyAutomaticTheme(to: projectedSurfaces)
    }

    /// Gives panes opening in this window the theme of the current macOS
    /// appearance, when the reader follows the system.
    ///
    /// A session opens on the theme its configuration names, which is the
    /// pinned one and not the follow-system pair, so a pane a split adds is
    /// given the appearance's theme here as the window's first pane was: a
    /// split left alone opened on whatever theme the reader last pinned.
    ///
    /// - Parameter surfaces: The panes opening.
    private func applyAutomaticTheme(to surfaces: [TerminalSurface]) {
        let configuration = Ubiquitty.Preferences.values()
        guard Ubiquitty.Preferences.Effective.followSystemAppearance(configuration.pointee) else { return }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let appearance = isDark ? Ubiquitty.Themes.AutomaticAppearance.Dark : .Light
        let index = Int(Ubiquitty.Themes.resolvedAutomaticThemeIndex(appearance))
        guard index >= 0 else { return }
        for surface in surfaces where surface.applyTheme(at: index) {
            surface.republishAfterPreferenceWrite()
        }
    }

    /// Whether the system accessibility switch is being watched.
    private static var isWatchingSystemAccessibility = false

    /// Writes the system's Increase Contrast request where Core's theme
    /// application reads it, and watches for the switch to move.
    ///
    /// The colour-vision mode beside it is the configuration's and is written
    /// by the launch seed; this is the one fact only a GUI frontend can read.
    /// On a change every open surface re-seeds its launch theme, so the
    /// palette derives from the theme under the new strength rather than
    /// boosting an already boosted one.
    ///
    /// The registration is on the WORKSPACE notification centre, which is the
    /// only one this notification is posted on: an observer on the default
    /// centre is never called, so the switches would take effect at the next
    /// window and not on the windows the reader is looking at.
    ///
    /// Reduce Transparency travels with Increase Contrast — one notification
    /// announces both — so the ground is re-realized here as well as the
    /// palette. That switch turns blur and opacity off and back ON, and a
    /// handler that only re-seeded the theme leaves a window the reader has
    /// flattened see-through until it is reopened.
    static func adoptSystemAccessibility() {
        Ubiquitty.Accessibility.paletteAdaptation().pointee.contrastStrength =
            SystemDisplayOptions.shouldIncreaseContrast ? 1.0 : 0.0
        guard !isWatchingSystemAccessibility else {
            return
        }
        isWatchingSystemAccessibility = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                adoptSystemAccessibility()
                applyThemeToOpenWindows()
                applyBackgroundEffectsToOpenWindows()
            }
        }
    }

    /// Re-applies the `[render]` pacing keys to every open Swift window: the
    /// frame cap to each surface's clock and the vsync choice to its layer.
    @objc
    public static func applyRenderPreferencesToOpenWindows() {
        for controller in spawnedControllers {
            let configuration = controller.windowRenderConfiguration
            for surface in controller.projectedSurfaces {
                surface.applyRenderPreferences(configuration)
            }
        }
    }

    /// Re-realizes the ground on every open Swift-shell window.
    ///
    /// The fold is re-read rather than remembered, so the same call serves an
    /// accessibility switch that moved and an opacity the reader just edited.
    @objc
    public static func applyBackgroundEffectsToOpenWindows() {
        for controller in spawnedControllers {
            controller.applyTranslucency()
            controller.applyChromeTheme()
        }
    }

    /// The pane this window's verbs address, for a caller outside this module.
    ///
    /// The focus answer is the controller's — a window with no pane focused
    /// has none, rather than a first entry standing in for one.
    #if UBIQUITTY_UI_TESTS
    /// Delivers delayed remote lifecycle events through the production handlers.
    package func deliverRemoteEventsForTesting(layout surface: TerminalSurface) {
        remoteWorkspaceDidChange(on: surface)
    }

    package func deliverRemoteEventsForTesting(exit surface: TerminalSurface) {
        surfaceDidExit(surface)
    }

    package var isClosedForTesting: Bool { isWindowClosed }

    /// Detaches only the local projections sharing the captured connection.
    ///
    /// - Parameter drive: The probe's exact workspace connection owner.
    package static func detachRemoteWorkspaceForTesting(from drive: RuntimeDrive) {
        RemoteWorkspaceProjection.detach(from: drive)
    }
    #endif

    package var focusedSurfaceForTesting: TerminalSurface? { focusedSurface }

    /// The pane the host's tree focuses in a hosted window, whatever holds
    /// the keyboard.
    package var hostedFocusedPaneForTesting: TerminalSurface? {
        Ubiquitty.Session.Layout.PaneID(rawValue: UInt32(max(0, transferTree.focusedPaneID()))).flatMap { remotePaneSurfaces[$0] }
    }

    /// The views over this window's model panes, for a scenario that asks
    /// which of them a window-wide action reaches.
    package var paneSurfacesForTesting: [TerminalSurface] { Array(surfaces.values) }

    /// What every pane of this tab is reporting, as one sample.
    ///
    /// A backgrounded tab's ring stands in for panes nobody can see, so the
    /// fold is `OSC::aggregateProgress`: an error surfaces over a comet, a
    /// comet over a fill, and a determinate result reads the LEAST-complete
    /// pane, because a ring that read the greatest would say a window had
    /// finished while a pane still ran. A pane whose program says it is
    /// working, and reports nothing of its own, counts as indeterminate,
    /// unless `isReportedOnly`, which folds the panes' own reports alone.
    ///
    /// - Parameter isReportedOnly: Whether to leave the programs' statuses out.
    /// - Returns: The folded state and percent.
    private func aggregatePaneProgress(isReportedOnly: Bool = false) -> Ubiquitty.OSC.ProgressSample {
        var samples: [Ubiquitty.OSC.ProgressSample] = []
        for surface in projectedSurfaces {
            let published = surface.drive.readSnapshot()
            samples.append(
                isReportedOnly
                    ? Ubiquitty.OSC.ProgressSample(state: published.progressState, value: published.progressValue)
                    : paneProgress(published)
            )
        }
        return samples.withUnsafeBufferPointer { buffer in
            Ubiquitty.OSC.aggregateProgress(Ubiquitty.OSC.ProgressSampleSpan(buffer))
        }
    }

    /// What one pane shows as progress: its OSC 9;4 report, or with none,
    /// its program's working status as progress: the record's percent, or
    /// with none, progress of unknown length.
    ///
    /// - Parameter published: The pane's published snapshot.
    /// - Returns: The state and percent.
    private func paneProgress(_ published: Ubiquitty.Runtime.RuntimeSnapshot) -> Ubiquitty.OSC.ProgressSample {
        Ubiquitty.App.progressWithProgramStatus(
            Ubiquitty.OSC.ProgressSample(state: published.progressState, value: published.progressValue),
            published.programStatusKind,
            published.programProgress
        )
    }

    /// The band a window wears for the one pane filling it, once it has one:
    /// the lone pane of an unsplit window, or the zoomed pane of a split.
    ///
    /// It stands where it moves no text. While the window shows a title row
    /// the band runs along that row's bottom edge, in the window's chrome and
    /// outside the content, as a browser's loading bar does. A chromeless or a
    /// full-screen window shows none, so there the band overlays the pane's
    /// top edge from the pane host and reserves nothing under it. Both homes
    /// are outside the Metal view's subtree: animating inside a
    /// `CAMetalLayer`'s tree re-snaps the grid's rows as the comet loops,
    /// which reads as the text twitching while a download runs. A split pane's
    /// report is its chrome's to draw, in the pane's own header.
    private var windowProgressBand: ProgressBar?

    /// The pane the window's band speaks for, whose top edge it overlays
    /// while the window shows no title row.
    private weak var windowProgressBandPane: TerminalSurface?

    /// The progress the panes last folded to when a status report came in.
    private var statusFoldedProgress = Ubiquitty.OSC.ProgressSample()

    /// Reconciles the progress chrome after a status report, when the report
    /// moved what the panes fold to: a working program counts as progress,
    /// and a report that leaves the fold where it was (a prompt, unread
    /// output, a colour) moves no band and no bar.
    func syncProgressChromeIfStatusMovedIt() {
        let sample = aggregatePaneProgress()
        guard sample.state != statusFoldedProgress.state || sample.value != statusFoldedProgress.value else { return }
        statusFoldedProgress = sample
        syncProgressChrome()
    }

    /// Reconciles this window's progress chrome with what its panes report.
    ///
    /// Which slot lights up is Core's (`OSC::contentBarVisible`): the
    /// window's own bar is the sole indicator of a lone, unsplit window, and
    /// it steps aside when the window is tabbed or split, because the tab
    /// button and the panes' headers own those cases. Three slots that each
    /// decided for themselves would show two bars for one download.
    func syncProgressChrome() {
        // The strip is one row for the whole group, so a report on any tab is
        // news for every tab's ring — each stands in for panes that are not on
        // screen to carry their own.
        let group = window?.tabGroup?.windows ?? [window].compactMap { $0 }
        for tabWindow in group {
            (tabWindow.windowController as? TerminalWindowController)?.refreshTabAccessory()
        }
        // The band is one view for the whole strip, so exactly one window
        // reconciles it: the selected one, whose report it carries.
        let selected = window?.tabGroup?.selectedWindow ?? window
        (selected?.windowController as? TerminalWindowController)?.syncSelectedTabBand()
        syncPaneProgressBands()
    }

    /// Reconciles the bands this window draws for its own panes.
    ///
    /// Its own half of the reconcile above, so a walk over a whole group can
    /// run the group's part once and each window's part once, rather than the
    /// group's part once per window. Also run where the window's chrome
    /// changes shape under a standing report, the title row hidden or shown
    /// and full screen entered or left, because the window's band changes
    /// home with it.
    func syncPaneProgressBands() {
        guard let window else { return }
        let isTabbed = (window.tabGroup?.windows.count ?? 1) > 1
        let projected = projectedSurfaces
        let splitLayout: Ubiquitty.OSC.SplitLayout = projected.count > 1 ? .Split : .Unsplit
        var windowReport: WindowProgressReport?
        let zoomed = paneChromeZoomedPane
        for surface in projected {
            // Off the published snapshot rather than the model: a report moves
            // no cell, so it reaches this shell the way OSC 22's pointer shape
            // does — carried by the drain that noticed it, with no lock taken
            // on the main thread to read two bytes.
            let sample = paneProgress(surface.drive.readSnapshot())
            let role = Ubiquitty.OSC.progressTint(
                sample.state,
                surface === activeSurface ? .Focused : .Unfocused,
                splitLayout == .Split ? .MultiPane : .SinglePane,
                WindowTabSelection.isGroupActive(window) ? .Active : .Background
            )
            let tint = ProgressTintPalette.color(forTintRole: role, colors: surface.drive.statusColors())
            let isPaneSlot = Ubiquitty.OSC.paneBarVisible(sample.state, splitLayout)
            // A pane in a split is framed by its chrome, which draws the
            // report in the pane's own header. The zoomed pane fills the
            // window, so the window's band speaks for it, as it does for a
            // pane no chrome frames.
            let chrome = surface.superview as? PaneChrome
            let isZoomedPane = zoomed != Ubiquitty.Session.Layout.invalidPane && paneChromeID(of: surface) == zoomed
            let paneState = isPaneSlot && !isZoomedPane ? sample.state : UInt8(Ubiquitty.OSC.ProgressNone.rawValue)
            chrome?.showProgress(state: paneState, value: sample.value, tint: tint)
            let isWindowSlot =
                Ubiquitty.OSC.contentBarVisible(sample.state, isTabbed ? .Tabbed : .SingleTab, splitLayout)
                || (isPaneSlot && (chrome == nil || isZoomedPane) && surface.window === window)
            if isWindowSlot, windowReport == nil {
                windowReport = WindowProgressReport(pane: surface, sample: sample, tint: tint)
            }
        }
        showWindowProgress(windowReport)
        // A percent moves without the title, so each bar's mark follows the
        // bands rather than waiting for its title to restyle.
        for chrome in paneChromes {
            guard let pane = Ubiquitty.Session.Layout.PaneID(rawValue: UInt32(chrome.paneID)),
                let surface = remotePaneSurfaces[pane] ?? surfaces[pane],
                let inputs = paneChromeInputs[chrome.paneID]
            else { continue }
            updatePaneStatusMark(chrome, pane: pane, surface: surface, inputs: inputs)
        }
    }

    /// Puts this window's report on the strip's one band, or takes it off.
    ///
    /// Called for the SELECTED window of a group and no other: the band is one
    /// view shared by the strip, so a group that reconciled it per window would
    /// have every unselected tab remove what the selected one just placed.
    private func syncSelectedTabBand() {
        guard let window else { return }
        let sample = aggregatePaneProgress()
        let isTabbed = (window.tabGroup?.windows.count ?? 1) > 1
        let isWanted = Ubiquitty.OSC.tabButtonBarVisible(
            sample.state,
            window.tabGroup?.selectedWindow === window ? .Active : .Inactive,
            isTabbed ? .Tabbed : .SingleTab,
            projectedSurfaces.count > 1 ? .Split : .Unsplit
        )
        TabButtonProgressBar.reconcile(
            in: window,
            state: sample.state,
            value: sample.value,
            tint: ProgressTintPalette.colorForWindowSlot(
                state: sample.state,
                isWindowActive: WindowTabSelection.isGroupActive(window),
                colors: titleSurface?.drive.statusColors() ?? Ubiquitty.Themes.StatusColors()
            ),
            isWanted: isWanted
        )
    }

    /// The report the window's own band carries, and the pane it is about.
    private struct WindowProgressReport {
        var pane: TerminalSurface
        var sample: Ubiquitty.OSC.ProgressSample
        var tint: NSColor
    }

    /// Puts a report on the window's band, in whichever home the window's
    /// chrome offers it, or takes the band away.
    ///
    /// - Parameter report: The report, or nil when no pane's report is the
    ///   window's to show.
    private func showWindowProgress(_ report: WindowProgressReport?) {
        guard let window else { return }
        guard let report else {
            windowProgressBand?.setState(UInt8(Ubiquitty.OSC.ProgressNone.rawValue), value: 0)
            return
        }
        let band = windowProgressBand ?? makeWindowProgressBand()
        windowProgressBandPane = report.pane
        // A chromeless window's body grows up under a title row emptied of
        // everything, and full screen moves the row into a window of AppKit's
        // own that shows only with the menu bar, so neither row is a place a
        // reader would see the bar.
        let titleRow = hidesTitleBar || window.styleMask.contains(.fullScreen) ? nil : window.titlebarContainer
        let home: NSView = titleRow ?? paneHost
        if band.superview !== home {
            band.removeFromSuperview()
            // Pinned by constraints in the title row, whose layout is AppKit's
            // and moves without telling anyone; placed by frame over the
            // pane, which follows the host's own layout.
            band.translatesAutoresizingMaskIntoConstraints = home === paneHost
            home.addSubview(band, positioned: .above, relativeTo: nil)
            if home !== paneHost {
                NSLayoutConstraint.activate([
                    band.leadingAnchor.constraint(equalTo: home.leadingAnchor),
                    band.trailingAnchor.constraint(equalTo: home.trailingAnchor),
                    band.bottomAnchor.constraint(equalTo: home.bottomAnchor),
                ])
            }
        }
        band.tintColor = report.tint
        band.setState(report.sample.state, value: report.sample.value)
        layoutWindowProgressBand()
    }

    /// Makes the window's band, dressed as every band in this app is.
    ///
    /// - Returns: The band, unplaced.
    private func makeWindowProgressBand() -> ProgressBar {
        let band = ProgressBar(frame: .zero)
        // Flush square ends and no groove: the band spans the window's whole
        // width and a pill with a hairline track reads as a control, which
        // this is not — nothing here can be clicked.
        band.capRadius = 0
        band.borderWidth = 0
        band.trackColor = .clear
        windowProgressBand = band
        return band
    }

    /// Places the window's band at the top edge of the pane it speaks for,
    /// while it overlays the pane host.
    ///
    /// Run from the host's own layout as well as at placement, because the
    /// pane moves without telling anyone: a window resize, the find bar
    /// opening above it and a re-mirrored tree all leave a band over the wrong
    /// row otherwise. A band in the title row is pinned there and needs
    /// nothing from here.
    internal func layoutWindowProgressBand() {
        guard let band = windowProgressBand, band.superview === paneHost,
            let surface = windowProgressBandPane, surface.window === window
        else {
            return
        }
        let height = ProgressBar.bandHeightInPoints
        let overPane = paneHost.convert(surface.bounds, from: surface)
        // The host's own sense of up: a flipped view puts a pane's top
        // edge at minY and an unflipped one at maxY, and a band placed by
        // the wrong one lands under the last row instead of over the first.
        let top = paneHost.isFlipped ? overPane.minY : overPane.maxY - height
        band.frame = NSRect(x: overPane.minX, y: top, width: overPane.width, height: height)
    }

    /// Updates sessions using the native palette when macOS colors change.
    @objc
    public static func refreshSystemTheme() {
        let nativeSurfaces = spawnedControllers.flatMap { $0.projectedSurfaces }
            .compactMap { surface -> (TerminalSurface, String)? in
                guard let name = surface.currentThemeName else { return nil }
                return ["System", "Glass", "Glass Dark"].contains(name) ? (surface, name) : nil
            }
        SystemTheme.refresh()
        for (surface, name) in nativeSurfaces {
            let index = name.withCString { Ubiquitty.Themes.indexForName($0) }
            _ = surface.applyTheme(at: Int(index))
            surface.invalidateRetainedBaseline()
            surface.republishAfterPreferenceWrite()
        }
        for controller in spawnedControllers { controller.refreshSessionAppearance() }
    }

    /// Re-seeds every open window's theme from the configuration as it now
    /// stands, chrome included.
    ///
    /// The fold is re-read rather than an index passed in, so this resolves
    /// whatever the configuration names — a chosen theme, the follow-system
    /// pair, the colorblind remap — exactly as a newly opened window would,
    /// and the two cannot drift. The chrome repaints with the body: a theme
    /// that reaches the cells and not the titlebar reads as a half-applied
    /// setting.
    @objc
    public static func applyThemeToOpenWindows() {
        let config = Ubiquitty.Preferences.values()
        applyThemeToOpenWindows { surface in
            surface.drive.reseedLaunchTheme(config.pointee)
        }
    }

    /// Applies one resolved theme to every open Swift-shell window.
    ///
    /// The system-appearance resolver has already selected the light or dark
    /// member of the configured pair. Keep that answer through the frontend
    /// boundary: re-reading the launch theme here would resolve only the
    /// pinned `[appearance] theme`, which remains independent of the
    /// current macOS appearance.
    ///
    /// - Parameter index: The resolved catalog theme index.
    @objc(applyThemeToOpenWindowsAtIndex:)
    public static func applyThemeToOpenWindows(at index: Int) {
        applyThemeToOpenWindows { surface in
            surface.applyTheme(at: index)
        }
    }

    /// Applies a theme operation and refreshes every dependent surface.
    private static func applyThemeToOpenWindows(_ apply: (TerminalSurface) -> Bool) {
        defer { NotificationCenter.default.post(name: .terminalAppearanceChanged, object: nil) }
        for controller in spawnedControllers {
            for surface in controller.projectedSurfaces {
                _ = apply(surface)
                surface.drive.republishSnapshot()
                surface.invalidateRetainedBaseline()
                surface.needsDisplay = true
            }
            // The memo holds the facts, and a theme reseeded under it moves
            // every one of them; dropped here so the repaint does not depend
            // on the key being complete.
            controller.paintedChromeInputs = nil
            controller.refreshSessionAppearance()
        }
    }

    /// Applies a theme to one inspected session and refreshes its native chrome.
    ///
    /// - Parameters:
    ///   - index: The catalog theme selected by the user.
    ///   - surface: The inspected session's surface.
    /// - Returns: Whether the owning session accepts the change.
    package func applyInspectedTheme(_ index: Int, to surface: TerminalSurface) -> Bool {
        guard projectedSurfaces.contains(where: { $0 === surface }), surface.applyTheme(at: index) else { return false }
        surface.invalidateRetainedBaseline()
        surface.republishAfterPreferenceWrite()
        refreshSessionAppearance()
        return true
    }

    /// Refreshes theme-dependent chrome across the native tab group.
    ///
    /// The terminal palettes remain session-owned. Every tab redraws its own
    /// labels while the selected tab supplies the shared titlebar appearance.
    package func refreshSessionAppearance() {
        guard let window else { return }
        for tab in window.tabGroup?.windows ?? [window] {
            guard let controller = tab.windowController as? TerminalWindowController else { continue }
            controller.applyTranslucency()
            controller.applyChromeTheme()
            controller.applyThemeToFindBar()
            controller.refreshTabTitle()
            controller.refreshPaneChrome()
        }
        let selected = window.tabGroup?.selectedWindow ?? window
        (selected.windowController as? TerminalWindowController)?.tintTitlebar()
        refreshTabGroupForFocusChange()
    }

    /// Makes a view for every pane the model holds beyond the one the spawn
    /// already projected — the restored window's other leaves.
    ///
    /// - Parameters:
    ///   - rootPane: The pane the spawn already made a view for.
    ///   - renderer: The window's renderer, shared by every pane.
    ///   - launch: The launch fold the views size from.
    func adoptModelPanes(
        besides rootPane: Ubiquitty.Session.Layout.PaneID,
        renderer: any TerminalSurfaceRenderer,
        launch: Ubiquitty.Preferences.Effective.LaunchSettings
    ) {
        guard let model = Self.windowModel else {
            return
        }
        let tree = model.paneTreeSnapshot(workspaceSurface)
        var isAnyAdopted = false
        for index in 0..<Ubiquitty.Panes.maxNodes where tree.isLeaf(index) {
            guard let pane = Ubiquitty.Session.Layout.PaneID(rawValue: UInt32(tree.node(index).paneID)),
                pane != rootPane,
                surfaces[pane] == nil,
                let session = model.session(pane)
            else {
                continue
            }
            let view = TerminalSurface(drive: RuntimeDrive(over: session), rows: launch.rows, columns: launch.columns)
            view.renderer = renderer
            if let bridge {
                view.observer = bridge
            }
            if isTranslucent {
                view.metalLayer.isOpaque = false
            }
            surfaces[pane] = view
            hostCellMetricChanges(of: view)
            isAnyAdopted = true
        }
        if isAnyAdopted {
            rebuildPaneLayout()
        }
    }

    /// Ends the window's surface in the model — every pane's session with it
    /// — and releases the controller. A hosted window's invalid surface makes
    /// the model call the empty case.
    /// Watches the content view for the height the tab strip takes and gives
    /// back.
    ///
    /// A strip appearing takes its height out of the content view, so a window
    /// that does nothing loses a row of terminal to it. The compensation is
    /// Core's arithmetic (Source/Core/Runtime/TabStripChrome.h); this reports
    /// the heights and applies the move.
    ///
    /// - Parameter contentView: The window's content view.
    internal func observeContentFrameForTabStrip(_ contentView: NSView) {
        guard contentFrameObserver == nil else { return }
        contentView.postsFrameChangedNotifications = true
        lastContentHeight = contentView.bounds.height
        hadTabStrip = (window?.tabbedWindows?.count ?? 0) > 1
        contentFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keepGridAcrossTabStripToggle()
                // A hosted window's grid is tmux's client size, and the
                // content view moving is the only notice of it: tmux tiles
                // the session across whatever this says.
                self?.reportTmuxClientGrid()
            }
        }
    }

    #if UBIQUITTY_UI_TESTS
    /// Stands in for `isKeyWindow` in a scenario: the UI-test app runs as an
    /// accessory and its windows never become key, so a scenario that has to
    /// activate a window says so here before sending the key notification.
    package var isKeyWindowForTesting: Bool?
    #endif

    /// Whether the reader is looking at this window's tab: its window is key
    /// and it is the group's selected tab.
    private func isLookedAt(_ window: NSWindow) -> Bool {
        var isKey = window.isKeyWindow
        #if UBIQUITTY_UI_TESTS
        isKey = isKeyWindowForTesting ?? isKey
        #endif
        return isKey && (window.tabGroup?.selectedWindow ?? window) === window
    }

    /// Output landed on this window's pane.
    ///
    /// Whether it counts as news is Core's
    /// (Source/Core/Runtime/TabStripChrome.h); this reports the facts and
    /// paints the mark.
    internal func noteOutputForUnseenActivity() {
        guard let window else { return }
        let isForeground = isLookedAt(window)
        guard
            Ubiquitty.Runtime.doesOutputMarkUnseenActivity(
                Ubiquitty.Runtime.UnseenActivityFacts(
                    isAlreadyMarked: hasUnseenActivity,
                    isForeground: isForeground,
                    isWithinResizeSettle: ProcessInfo.processInfo.systemUptime < resizeSettleEndsAt
                )
            )
        else {
            return
        }
        hasUnseenActivity = true
        refreshTabAccessory()
    }

    /// A bell rang on this window's pane.
    ///
    /// Whether it leaves a mark is Core's (`Runtime::doesBellMarkUnheard`);
    /// this reports the one fact and paints it. The mark outlives the bell's
    /// own cue: the sound, the bounce and the banner are gone by the time the
    /// reader comes back, and this is what is still there to be found.
    ///
    /// It rides the cue rather than the BEL byte, which is the one thing worth
    /// saying about its reach: a reader who turned both `[bell]` switches off
    /// resolves `BellMode::Off`, no bell event is raised at all, and no mark
    /// appears. That is the setting answering — they asked the terminal not to
    /// react to bells — not a gap in this path.
    internal func noteBellForUnheardMark() {
        guard let window else { return }
        let isForeground = isLookedAt(window)
        guard Ubiquitty.Runtime.doesBellMarkUnheard(isForeground) else { return }
        hasUnheardBell = true
        refreshTabAccessory()
        refreshTitleBellMark()
    }

    /// A program asked for the reader with a banner.
    ///
    /// Marks the tab only when the reader is not already on it: a banner for
    /// the tab in front of them needs no reminder once it has gone.
    internal func noteNotificationForUnseenMark() {
        guard let window, !hasUnseenNotification else { return }
        let isForeground = isLookedAt(window)
        guard !isForeground else { return }
        hasUnseenNotification = true
        refreshTabAccessory()
    }

    /// The tab is being looked at, so nothing on it is unseen any more.
    internal func clearUnseenActivityIfLookedAt() {
        guard let window, hasUnseenActivity || hasUnheardBell || hasUnseenNotification else { return }
        let isForeground = isLookedAt(window)
        guard isForeground else { return }
        hasUnseenActivity = false
        hasUnheardBell = false
        hasUnseenNotification = false
        refreshTabAccessory()
        refreshTitleBellMark()
    }

    /// Whether the tab-selecting modifier is down, application-wide.
    ///
    /// Stored on the presenter, which is what reads it; this is the name the
    /// application already calls, forwarding rather than keeping a second copy
    /// that could disagree with the one the accessory is dressed from.
    @objc
    public static var isCommandKeyHeld: Bool {
        get { TabAccessoryPresenter.isCommandKeyHeld }
        set { TabAccessoryPresenter.isCommandKeyHeld = newValue }
    }

    /// Re-walks every open Swift window's tab strip.
    ///
    /// The modifier's edge is the application's, and a hint is per tab, so the
    /// application's handler comes through here.
    @objc
    public static func refreshTabAccessoriesForOpenWindows() {
        for controller in spawnedControllers {
            controller.refreshTabAccessory()
        }
    }

    /// Puts one thing in this tab's accessory slot, or nothing.
    ///
    /// The choosing and the dressing are both the presenter's, shared by every
    /// window kind; this reports the facts only a window knows.
    package func refreshTabAccessory() {
        guard let window else { return }
        // Both of these are about a STRIP. A lone window has a trivial tab group
        // whose one window is always the selected one, so reading the group
        // without asking whether there is a strip makes a lone window look like
        // the tab the reader is on — which suppresses the marks it should show.
        // Numbering the only tab names a key for a choice with no alternatives.
        let tabs = window.tabbedWindows ?? []
        let hasStrip = tabs.count > 1
        if hasStrip {
            sharedTabGroup = window.tabGroup
            // Recorded while the group is whole: AppKit takes a closing window
            // out of its group before it says the window will close, so by then
            // neither the group nor the window names the other, and a sibling's
            // close is no longer tellable from any other window's.
            sharedTabWindows.removeAllObjects()
            for tab in tabs {
                sharedTabWindows.add(tab)
            }
        }
        verifyLoneGroupNextTurn(isTabbed: hasStrip)
        let position =
            hasStrip
            ? Int(
                Ubiquitty.Session.tabShortcutPositionForIndex(
                    Int32(tabs.firstIndex(of: window) ?? -1),
                    Int32(tabs.count)
                )
            )
            : 0
        let aggregate = aggregatePaneProgress()
        let colors = titleSurface.flatMap(tabInkColors(of:))
        let titleSnapshot = titleSurface?.drive.readSnapshot()
        tabAccessoryPresenter.apply(
            to: window,
            hintPosition: position,
            isSelected: hasStrip && window.tabGroup?.selectedWindow === window,
            reportedProgressState: aggregatePaneProgress(isReportedOnly: true).state,
            progressState: aggregate.state,
            progressValue: aggregate.value,
            statusColor: tabStatusIndicatorColor(),
            isStatusColorNeutral: titleSnapshot?.tabStatusSlot == HostOutlineStatusSlot.neutral.rawValue,
            programStatusRaw: titleSnapshot?.programStatusKind ?? 0,
            programBlockKindRaw: titleSnapshot?.programBlockKind ?? 0,
            notificationColor: ProgressTintPalette.color(
                for: .Notification,
                colors: titleSurface?.drive.statusColors() ?? Ubiquitty.Themes.StatusColors()
            ),
            hasUnheardBell: hasUnheardBell,
            hasUnseenNotification: hasUnseenNotification,
            hasUnseenActivity: hasUnseenActivity,
            foreground: colors?.foreground ?? 0xC0C0C0,
            background: colors?.background ?? 0x101014,
            usesNativeColors: isUsingNativeTitlebar,
            fontSize: ChromeTypography.scaled(NSFont.smallSystemFontSize - 1.0)
        )
    }

    /// Brings every tab of this window's group into line with the group as it
    /// reads now: each tab's title and accessory, and which slot carries each
    /// window's progress.
    ///
    /// The one walk. Whether a report lights the window's own band, the
    /// strip's band or a tab's ring is partitioned by facts that a tab joining or
    /// leaving moves — and a window that is neither key nor newly selected
    /// sees no other edge where they are re-read.
    package func reconcileTabGroupChrome() {
        guard !isWindowClosed, let window else { return }
        let group = window.tabGroup?.windows ?? [window]
        for tabWindow in group {
            guard let controller = tabWindow.windowController as? TerminalWindowController,
                !controller.isWindowClosed
            else {
                continue
            }
            controller.refreshTabTitle()
            controller.refreshTabAccessory()
            controller.syncPaneProgressBands()
        }
        // The strip's band is one view shared by the group, so the selected
        // window reconciles it and no other.
        let selected = window.tabGroup?.selectedWindow ?? window
        (selected.windowController as? TerminalWindowController)?.syncSelectedTabBand()
    }

    /// Reconciles the group after a sibling left it, counting the walk.
    ///
    /// The count is the claim a close makes: one walk per close, whichever tab
    /// was the one closing.
    private func reconcileTabGroupChromeAfterSiblingLeft() {
        tabGroupCloseReconcilesForTesting += 1
        reconcileTabGroupChrome()
    }

    /// Hands a shared group's chrome back when a sibling that is not a
    /// `TerminalWindowController` closes.
    ///
    /// A `TerminalWindowController` announces its own going through
    /// `windowWillClose`, which is where a group whose tabs are all this
    /// shell's is answered. A tab group can mix window kinds — AppKit's own tab
    /// drag puts either window in either group — and a close walk that skips a
    /// sibling it does not own announces nothing, so a group whose last
    /// foreign tab closes tells this controller nothing. The survivor then
    /// keeps the number and the band partition it last computed as a tab,
    /// since the tab left selected gets no key or main change to provoke a
    /// walk of its own.
    ///
    /// One survivor answers for the whole group, the shape the close path
    /// already uses, so a close still costs exactly one walk however many of
    /// this shell's windows share the group.
    ///
    /// - Parameter notification: The close, whose object is the window.
    @objc
    private func answerSiblingClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, !isWindowClosed,
            !(closing.windowController is TerminalWindowController)
        else {
            return
        }
        guard sharedTabWindows.contains(closing), let group = sharedTabGroup else { return }
        let survivor =
            group.windows
            .lazy
            .compactMap { $0.windowController as? TerminalWindowController }
            .first { !$0.isWindowClosed }
        guard survivor === self else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isWindowClosed else { return }
            self.reconcileTabGroupChromeAfterSiblingLeft()
        }
    }

    /// Re-verifies a tabbed-to-lone read one turn later, and walks the group
    /// again when the settled group disagrees.
    ///
    /// `NSWindow.tabGroup` can under-report while AppKit is mutating the group
    /// — close churn, a reorder re-homing the strip — and the deferred walks
    /// run exactly while such a mutation is in flight. Chrome torn down off
    /// that thin read sticks: a window that is already key gets no event to
    /// re-run the walk, so its tab keeps neither its number nor its report
    /// until the reader clicks something. A window that is genuinely lone
    /// re-reads lone here and does nothing.
    ///
    /// - Parameter isTabbed: What this walk read the group as.
    private func verifyLoneGroupNextTurn(isTabbed: Bool) {
        let wasTabbed = didLastChromeWalkReadTabbed
        didLastChromeWalkReadTabbed = isTabbed
        guard wasTabbed, !isTabbed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isWindowClosed, let window = self.window else { return }
            guard (window.tabbedWindows?.count ?? 0) > 1 else { return }
            self.thinGroupReverifiesForTesting += 1
            self.reconcileTabGroupChrome()
        }
    }

    /// Moves the window's bottom edge so the grid keeps its rows across a tab
    /// strip appearing or going.
    ///
    /// Gated on the tabbed-state transition, because the compensating
    /// `setFrame` brings the content view's frame around again and an
    /// ungated pass would answer its own move.
    private func keepGridAcrossTabStripToggle() {
        guard let window else { return }
        let currentContentHeight = paneHost.bounds.height
        defer { lastContentHeight = paneHost.bounds.height }
        let hasTabStrip = (window.tabbedWindows?.count ?? 0) > 1
        // A content resize sends SIGWINCH to every pane, and a shell answers by
        // redrawing its prompt. A tab that goes to the background as part of
        // that same resize would be marked for output the user caused and never
        // read, so the mark ignores what arrives for the next moment.
        resizeSettleEndsAt =
            ProcessInfo.processInfo.systemUptime
            + Ubiquitty.Runtime.resizeSettleSuppressionSeconds
        guard hasTabStrip != hadTabStrip else { return }
        hadTabStrip = hasTabStrip
        if inspectorSplit != nil {
            // AppKit publishes the strip's new safe area after this frame
            // notification. Reflow the root once on the next turn so its pane
            // constraint uses the settled inset.
            DispatchQueue.main.async { [weak self] in
                guard let split = self?.inspectorSplit else { return }
                split.view.needsUpdateConstraints = true
                split.view.updateConstraintsForSubtreeIfNeeded()
                split.view.needsLayout = true
                split.view.layoutSubtreeIfNeeded()
            }
        }
        // The strip coming or going is the group forming around this window or
        // leaving it, and a window that stays selected and key through that
        // sees no key or main edge to re-dress its tab: a lone window's slot
        // was dressed as no strip's selected tab, so the marks it holds would
        // stand on the selected tab until something else asked.
        scheduleTabFocusRefresh()
        // A full-screen window is pinned to the screen, so there is no bottom
        // edge to move and nothing to give back later.
        guard !window.styleMask.contains(.fullScreen) else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        var frame = window.frame
        let facts = Ubiquitty.Runtime.TabStripFrameFacts(
            previousContentHeight: lastContentHeight,
            currentContentHeight: currentContentHeight,
            roomBelow: frame.origin.y - screen.visibleFrame.origin.y,
            grownAmount: tabStripGrowth
        )
        if hasTabStrip {
            let growth = Ubiquitty.Runtime.tabStripGrowth(facts)
            if growth > 0 {
                frame.origin.y -= growth
                frame.size.height += growth
                window.setFrame(frame, display: true)
            }
            tabStripGrowth = growth
        } else {
            let undo = Ubiquitty.Runtime.tabStripUndo(facts, frame.size.height)
            if undo > 0 {
                frame.origin.y += undo
                frame.size.height -= undo
                window.setFrame(frame, display: true)
            }
            tabStripGrowth = 0
        }
    }

    public func windowWillClose(_ notification: Notification) {
        remoteClosePresentation?.cancel()
        ClosedWindowRecovery.shared.forget(self)
        inspectorModel?.isObservationActive = false
        isWindowClosed = true
        releaseUnusedArrangementConnection()
        // The diagnostics windows report on this window's panes and keep their
        // timers running; they go with it.
        closePerfDiagnostics()
        // A tmux window the reader closed. tmux did not close it, so nothing
        // on the tmux side unbinds its panes; left bound, each surface keeps
        // reading a model the session will free, and the pane registry keeps
        // this window alive and answering for panes it no longer shows.
        releaseTmuxPanes()
        // A pane of this window hosting windows of its own: they close first,
        // because the session going with this window owns every model their
        // panes read.
        for surface in projectedSurfaces where surface.drive.isHostingWindows {
            endHostedWindows(from: surface)
        }
        // Where this window ended is where the next one starts.
        rememberWindowFrame()
        // A tab leaving renumbers every tab after it and hands its group's
        // chrome back — a lone survivor has no strip to carry a report or a
        // number. The walk runs next turn, once the close has settled, and the
        // survivor left selected is not guaranteed a key or main change to
        // provoke one of its own.
        //
        // One walk, asked of one survivor, for the whole group. A second
        // identical walk per close lands mid-close-churn, exactly where a
        // group read can be thin, and the walk is what dominates a tab switch.
        //
        // Through `sharedTabGroup`, not `window.tabGroup`: AppKit takes a
        // closing window out of its group before it says the window will
        // close, so by here the window's own group holds nobody to ask.
        let group = sharedTabGroup
        DispatchQueue.main.async { [weak self] in
            let survivor =
                (group?.windows ?? [])
                .lazy
                .compactMap { $0.windowController as? TerminalWindowController }
                .first { $0 !== self && !$0.isWindowClosed }
            survivor?.reconcileTabGroupChromeAfterSiblingLeft()
        }
        if let observer = contentFrameObserver {
            NotificationCenter.default.removeObserver(observer)
            contentFrameObserver = nil
        }
        tabSelectionObservation = nil
        tabMembershipObservation = nil
        observedTabGroup = nil
        for observer in applicationFocusObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        applicationFocusObservers.removeAll()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        Self.windowModel?.closeWindowSurface(workspaceSurface)
        Self.spawnedControllers.removeAll { $0 === self }
        RemoteWorkspaceProjection.forget(self, declining: isClosingWithHostTab ? remoteWorkspaceTab : Ubiquitty.Session.Layout.invalidTab)
        detachRemoteOnClose()
    }

    /// Keeps a hosted tab visible until its authority accepts the close.
    func resetRemoteCloseConfirmation() {
        isCloseConfirmed = false
    }

    private func beginClosingConfirmedWindow() -> Bool {
        guard !refuseCloseForLocalAdoptionIfNeeded() else { return false }
        if !isCloseConfirmed, ClosedWindowRecovery.shared.retainForRecovery(self) { return false }
        return true
    }

    // The confirmation sheet's re-entry latch: its Close button closes the
    // window again, and that second pass must not raise a second sheet.
    private var isCloseConfirmed = false

    /// Confirms before a close that would kill a live job — the model's
    /// safe-to-close fact over every pane of every tab, the same rule the
    /// edited dot shows. A safe window closes silently.
    ///
    /// - Parameter sender: The window asking.
    /// - Returns: Whether the close proceeds now.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !refuseCloseForLocalAdoptionIfNeeded() else { return false }
        if isClosingWithHostTab { return true }
        if remoteSurface != nil {
            presentRemoteWindowClose(.closeTab)
            return false
        }
        guard !isCloseConfirmed else { return beginClosingConfirmedWindow() }
        guard sender.attachedSheet == nil else { return false }
        // Core's local job facts cannot describe processes on a tmux server.
        if isHostingTmux {
            confirmTmuxWindowClose(sender)
            return false
        }
        // What the close is about is Core's, over the job fact this window
        // reads off its model and the pin it holds itself.
        var facts = Ubiquitty.Session.CloseFacts()
        facts.wouldKillARunningJob = Self.windowModel.map { !$0.isSurfaceSafeToClose(workspaceSurface) } ?? false
        facts.isPinned = isPinned
        let confirmation = Ubiquitty.Session.closeConfirmation(facts)
        guard confirmation != .none else { return beginClosingConfirmedWindow() }

        let alert = NSAlert()
        if confirmation == .pinnedTab {
            alert.messageText = "Close Pinned Tab?"
            alert.informativeText = "This tab is pinned. Closing it also unpins it."
        } else {
            let scope: Ubiquitty.Session.CloseScope = (sender.tabGroup?.windows.count ?? 1) > 1 ? .tab : .window
            alert.messageText = String(Ubiquitty.Session.closeConfirmationTitle(scope))
            if let model = Self.windowModel {
                alert.informativeText = String(model.closeConfirmationBody(workspaceSurface, scope, Ubiquitty.Session.Layout.invalidPane))
            }
        }
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: confirmation == .pinnedTab ? "Close" : "Terminate")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            // Unpinned on the way out: the reader answered the question the pin
            // exists to ask, and a pin that survived it would ask again.
            self?.isPinned = false
            self?.isCloseConfirmed = true
            // The sheet is still attached while its handler runs, and a window
            // hosting a sheet refuses performClose, so the confirmed close is
            // issued directly: a hosted tab asks its authority and waits, a
            // local window closes.
            if self?.beginClosingConfirmedWindow() ?? true {
                sender.close()
            }
        }
        return false
    }

    /// Window ▸ Pin Tab — hold this tab at the front of its group, mark it, and
    /// ask before it closes.
    ///
    /// - Parameter sender: The menu item, whose check mark follows the state.
    @objc
    public func togglePinTab(_ sender: Any?) {
        isPinned.toggle()
        (sender as? NSMenuItem)?.state = isPinned ? .on : .off
        if isPinned {
            enforcePinnedLeftmost()
        }
        // The marker is part of the label and the pin is one of the memo's
        // facts, so the rebuild follows from the state changing. Dropping the
        // memo here as well would be a second mechanism for one fact, and the
        // one that is easier to forget.
        refreshTitles()
    }

    /// Holds a pinned tab at the front of its group.
    ///
    /// AppKit exposes no reorder on a tab group, so the window is re-added
    /// above the current first tab, which is the move that puts it there. A
    /// lone window and one already in front are both already correct. The
    /// selection is restored because re-adding takes it.
    @objc
    public func enforcePinnedLeftmost() {
        guard isPinned, let window, let group = window.tabGroup else { return }
        let tabs = group.windows
        guard tabs.count > 1, let first = tabs.first, first !== window else { return }
        let wasSelected = group.selectedWindow === window
        first.addTabbedWindow(window, ordered: .above)
        if wasSelected {
            group.selectedWindow = window
        }
    }

    /// Refreshes close indicators after a change to the confirmation policy.
    public static func refreshClosePolicy() {
        for controller in spawnedControllers {
            controller.refreshCloseSafetyIndicator()
        }
    }

    /// Reflects the model's close-confirmation policy in the close button.
    func refreshCloseSafetyIndicator() {
        guard let model = Self.windowModel else {
            return
        }
        window?.isDocumentEdited = model.needsRunningJobMarker(workspaceSurface)
    }

    /// Tells the title-bar badge which pasteboard this window's programs read.
    ///
    /// The decision is Core's ``Ubiquitty/Clipboard/scopeFor(_:)``: the same
    /// three facts answer it on every frontend, and a window controller
    /// resolving it privately would be a second copy of a security rule that
    /// drifts from the one another frontend reads. What is chosen here is only
    /// which three facts to hand over.
    ///
    /// - Parameter surface: The window's remote surface.
    func reportClipboardScope(for surface: TerminalSurface) {
        var facts = Ubiquitty.Clipboard.ScopeFacts()
        facts.isRemoteSession = surface.isRemoteAttached
        facts.isServingEnabled = surface.isServingClipboardToHost
        facts.didClientClaimServe = surface.isServingClipboardToHost
        ClipboardScopeIndicator.report(Ubiquitty.Clipboard.scopeFor(facts), for: window)
    }

    /// Shows Core's hint in the title row's trailing bar, or withdraws it.
    ///
    /// Nothing here decides whether to teach, what to say, or how long it
    /// stands -- the ladder settled all three, and the surface asks it again
    /// when a lesson fades. A window whose bar has not been built yet has no
    /// title row to teach in, and a hint is a courtesy: dropping it costs
    /// discoverability, never function.
    ///
    /// - Parameter text: What to show, empty for nothing.
    func surfaceDidChangeHint(_ text: String) {
        // A lesson that fades hands the line back to the diagnostic it covered.
        guard !text.isEmpty else {
            showConfigurationDiagnostic()
            return
        }
        windowHintAccessory?.show(text)
    }

    /// Applies the launch fold's window-level appearance: the chromeless
    /// title bar and the translucent ground a sub-unity opacity needs.
    ///
    /// - Parameter launch: The resolved launch settings.
    func applyWindowAppearance(_ launch: Ubiquitty.Preferences.Effective.LaunchSettings) {
        guard let window else {
            return
        }
        if windowAccessoryBar == nil {
            let bar = ChromeAccessoryBar(scope: .window, heightInPoints: ChromeAccessoryBar.titleRowHeightInPoints)
            window.addTitlebarAccessoryViewController(bar.makeTitlebarAccessory())
            SecureKeyboardEntryLock.install(in: bar)
            // Beside the lock, and hidden until a session reports a scope: a
            // local window has one pasteboard and nothing to disambiguate.
            let clipboardSelector = ClipboardScopeIndicator.install(in: bar)
            clipboardSelector.canSelectLocal = { [weak self] in
                self?.activeSurface?.canChangeClipboardServing == true
            }
            clipboardSelector.isChangingSource = { [weak self] in
                self?.activeSurface?.isClipboardRoutingPending == true
            }
            clipboardSelector.unavailableReason = { [weak self] in
                guard self?.activeSurface?.drive.remoteState == .Connected else {
                    return "Connect to the host to change clipboard source."
                }
                return "Update the host to change clipboard source."
            }
            clipboardSelector.selectLocal = { [weak self] enabled in
                guard let self, let surface = self.activeSurface else { return false }
                let accepted = surface.setClipboardServing(enabled)
                self.reportClipboardScope(for: surface)
                if !accepted {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t Change the Clipboard Source"
                    alert.informativeText =
                        "The host must support clipboard routing, and this session’s clipboard read policy must allow access."
                    alert.addButton(withTitle: "OK")
                    if let window = self.window { alert.beginSheetModal(for: window) }
                }
                return accepted
            }
            // Left of the clipboard badge: who else is on this session, and
            // the revoke a reader can spend on an agent among them.
            let presence = SessionPresenceIndicator.install(in: bar)
            presence.revoke = { [weak self] action, attachmentID, identity in
                self?.revokeConsent(action, attachmentID: attachmentID, identity: identity)
            }
            remoteConnectionIndicator = RemoteConnectionIndicator(window: window)
            proxyIconReveal?.connectionIndicator = remoteConnectionIndicator
            // Behind all of them: the line that teaches an invisible gesture,
            // and says what the configuration could not apply.
            windowHintAccessory = HintAccessory.install(in: bar)
            showConfigurationDiagnostic()
            // Innermost of the row, and hidden unless `[debug] show_build_hash`
            // asks for it: the build this window is running.
            installedBuildIdentityBadge = BuildIdentityBadge.install(in: bar)
            windowAccessoryBar = bar
        }
        if let remoteSurface {
            // The bar was just made, so a window whose attach reported before
            // it existed would carry a badge nobody had told anything.
            reportClipboardScope(for: remoteSurface)
            refreshRemoteConnectionIndicator(on: remoteSurface)
        }
        // The bar exists from here on, so the mode restored at init reaches
        // the title row — a pill installed before the bar would have nowhere
        // to go, and the mode would be on with nothing saying so.
        updateBroadcastIndicator()
        // A bar born into a window that is already chromeless starts hidden:
        // there is no title row for it to stand in, and it would draw over the
        // grid's first rows instead.
        ChromelessWindowChrome.syncAccessories(in: window, isChromeless: hidesTitleBar)
        usesNativeTitlebar = launch.titlebarStyle == .Native
        isTerminalColorSpaceDisplayP3 = windowRenderConfiguration.usesDisplayP3
        snapsWindowResize = launch.shouldSnapWindowResize
        // The ground's layer and the hook that re-places whatever sits over
        // the panes — a divider drag and a window resize move them without
        // telling anyone. Installed once, with the window: the host is this
        // controller's for its whole life, and the chrome pass runs only on a
        // real repaint, too late to install them.
        paneHost.wantsLayer = true
        paneHost.onLayout = { [weak self] in
            self?.layoutWindowProgressBand()
        }
        applyHideTitleBar(launch.shouldHideTitleBar)
        applyTranslucency()
        // Once here as well as on every screen update: the first frame is the
        // one a user sees the window open with, and it arrives before anything
        // has changed the model.
        applyChromeTheme()
    }

    /// Makes the window and every pane's layer agree with the fold's opacity,
    /// in both directions.
    ///
    /// The desktop shows through where cells are translucent: the window and
    /// the layer both stop declaring themselves opaque, and the per-cell alpha
    /// is the renderer's (the style's opacity). Against an opaque window the
    /// compositor keeps a translucent frame's premultiplied colour and drops
    /// its alpha, so an opacity lowered after launch darkened the theme
    /// towards black instead of revealing the desktop; raised back to one,
    /// the window must declare itself opaque again or the shadow and the
    /// resize hit-testing stay those of a see-through window.
    ///
    /// The ground is read from the live configuration, by Core's precedence:
    /// a key the configuration sets, then the appearance of the theme the
    /// window shows, then the key's default.
    package func applyTranslucency() {
        guard let window else {
            return
        }
        // Reduce Transparency overrides configured translucency, as it does
        // for the system's own materials.
        let appearance =
            activeSurface.map { surface in
                (surface.currentThemeName ?? "")
                    .withCString { name in
                        Ubiquitty.Themes.get(Ubiquitty.Themes.indexForName(name))?.pointee.appearance
                            ?? Ubiquitty.Themes.ThemeAppearance()
                    }
            } ?? Ubiquitty.Themes.ThemeAppearance()
        let values = Ubiquitty.Preferences.values()
        let effects = Ubiquitty.Preferences.Effective.backgroundEffects(values.pointee, Self.systemTransparency, appearance)
        let isBlurred = effects.isBlurred
        let isNowTranslucent = effects.isTranslucent
        isTranslucent = isNowTranslucent
        // The body's alpha and the title row's are one number, and it is the
        // renderer's — one on an opaque window whatever the key says.
        chromeBackgroundOpacity = CGFloat(effects.rendererOpacity)
        for surface in projectedSurfaces {
            guard let renderer = surface.renderer as? SurfaceRenderer else { continue }
            let (markStyle, isDark, textContrast) = (surface.currentThemeName ?? "")
                .withCString { name in
                    if let theme = Ubiquitty.Themes.get(Ubiquitty.Themes.indexForName(name)) {
                        return (
                            theme.pointee.appearance.terminalMarks, theme.pointee.isDark,
                            Ubiquitty.Preferences.Effective.textContrast(values.pointee, theme.pointee.appearance)
                        )
                    }
                    return (
                        Ubiquitty.Themes.TerminalMarkStyle.Palette,
                        surface.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                        Ubiquitty.Preferences.Effective.textContrast(values.pointee)
                    )
                }
            let markColor: NSColor?
            switch markStyle {
            case .Palette: markColor = nil
            case .Primary: markColor = .labelColor
            case .Secondary: markColor = .secondaryLabelColor
            case .Tertiary: markColor = .tertiaryLabelColor
            }
            func markInk(under appearance: NSAppearance.Name) -> SIMD4<Float> {
                var ink = SIMD4<Float>.zero
                NSAppearance(named: appearance)?
                    .performAsCurrentDrawingAppearance {
                        if let color = markColor?.usingColorSpace(.sRGB) {
                            ink = SIMD4(
                                Float(color.redComponent),
                                Float(color.greenComponent),
                                Float(color.blueComponent),
                                Float(color.alphaComponent)
                            )
                        }
                    }
                return ink
            }
            let ordinaryMark = markInk(under: isDark ? .darkAqua : .aqua)
            let vibrantMark = markInk(under: isDark ? .vibrantDark : .vibrantLight)
            if renderer.style.backgroundOpacity != effects.rendererOpacity
                || renderer.style.defaultBackgroundOpacity != effects.defaultBackgroundOpacity
                || renderer.style.shouldEnhanceTextContrast != textContrast
                || renderer.style.usesTextVibrancy != effects.shouldEnhanceTextOnBlur
                || renderer.style.preservesBackgroundTints != (isBlurred && appearance.usesSystemColors)
                || renderer.style.usesBackgroundVibrancy != effects.usesBackgroundVibrancy
                || renderer.style.promptMarkInk != ordinaryMark || renderer.style.vibrantPromptMarkInk != vibrantMark
            {
                renderer.style.backgroundOpacity = effects.rendererOpacity
                renderer.style.defaultBackgroundOpacity = effects.defaultBackgroundOpacity
                renderer.style.shouldEnhanceTextContrast = textContrast
                renderer.style.usesTextVibrancy = effects.shouldEnhanceTextOnBlur
                renderer.style.preservesBackgroundTints = isBlurred && appearance.usesSystemColors
                renderer.style.usesBackgroundVibrancy = effects.usesBackgroundVibrancy
                renderer.style.promptMarkInk = ordinaryMark
                renderer.style.vibrantPromptMarkInk = vibrantMark
                // The style is part of the retained target's stamp, so the
                // next frame rebuilds in full rather than Loading pixels
                // drawn at the other alpha.
                surface.invalidateRetainedBaseline()
                surface.needsDisplay = true
            }
        }
        // The picture behind the cells, on the same pass: the ground and the
        // backdrop are one appearance, and a settings write or a config reload
        // reaches both through here rather than through two fan-outs that can
        // disagree about which window got which half.
        applyBackgroundImage()
        window.isOpaque = !isNowTranslucent
        for surface in projectedSurfaces {
            surface.metalLayer.isOpaque = !isNowTranslucent
        }
        paneHost.setBlurEnabled(isBlurred)
        // Zero removes the window-server blur.
        windowServerBlurRadius = effects.blurRadius
        reassertWindowServerBlur()
        // Painted again below by applyChromeTheme, which reads isTranslucent;
        // forgetting the painted colour makes it repaint rather than compare
        // equal to the backing it painted under the other opacity.
        paintedChromeInputs = nil
    }

    // Whether the window's ground is translucent, so a pane split in later
    // stops declaring its layer opaque too.
    private(set) var isTranslucent = false

    /// The behind-window blur radius this window asks the window server for,
    /// in points; zero for none.
    private var windowServerBlurRadius: Double = 0

    /// Asks the window server again for the blur radius this window wants.
    ///
    /// The radius lives on the window server's window, and nothing AppKit
    /// keeps remembers it: AppKit re-hosts the window when it is ordered in,
    /// when a tab joins or leaves a group, and across full screen, and the
    /// radius can go with the move while nothing announces that it went. So
    /// each of those edges asks again, which costs nothing when it had stayed.
    func reassertWindowServerBlur() {
        guard let window else { return }
        WindowBlurBackdrop.applyWindowServerRadius(windowServerBlurRadius, to: window)
    }

    /// Orders the window in, and asks for its blur on the window it now has.
    ///
    /// - Parameter sender: The object asking, unread.
    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        reassertWindowServerBlur()
    }

    /// Whether the blur backdrop is installed and shown, for a scenario.
    package var isBlurBackdropShownForTesting: Bool {
        paneHost.hasBlur
    }

    /// The blur radius last asked of the window server for this window, in
    /// points, or nil before any ask; the call itself cannot be read back.
    package var lastRequestedBlurRadiusForTesting: Int? {
        guard let window, window.windowNumber > 0 else { return nil }
        return WindowBlurBackdrop.lastRequestedRadiusForTesting[window.windowNumber]
    }

    /// Forgets the radius last asked for this window, so a scenario can tell
    /// whether the next edge asks again.
    package func forgetRequestedBlurRadiusForTesting() {
        guard let window else { return }
        WindowBlurBackdrop.lastRequestedRadiusForTesting[window.windowNumber] = nil
    }

    /// What the Reduce Transparency switch says, read through
    /// `SystemDisplayOptions` like every other display option, or what a
    /// scenario forces here: one answer, so the style a surface is created with
    /// and the ground a window realizes read the same one.
    static var systemTransparency: Ubiquitty.Preferences.Effective.SystemTransparency {
        if let forced = systemTransparencyOverrideForTesting {
            return forced
        }
        return SystemDisplayOptions.shouldReduceTransparency ? .Reduced : .Allowed
    }

    /// Forces the switch for a scenario; nil reads the machine.
    package static var systemTransparencyOverrideForTesting: Ubiquitty.Preferences.Effective.SystemTransparency?

    // The alpha the Metal body carries, which the title row matches while the
    // window is translucent: one strip painted opaque over a see-through grid
    // is the seam this exists to avoid.
    private var chromeBackgroundOpacity: CGFloat = 1

    /// The title row's trailing accessories: the Secure Keyboard Entry lock,
    /// and whatever a later indicator adds beside it.
    package var windowAccessoryBar: ChromeAccessoryBar?
    package var remoteConnectionIndicator: RemoteConnectionIndicator?

    /// Where this tab's title pane lives, as the last title refresh found
    /// it; nil before the first. What the group's other tabs read to learn
    /// whether the window mixes places.
    var tabHost: (place: Ubiquitty.Session.HostPlace, machine: String)?

    /// The presence badge in the title row, which holds this window's roster,
    /// nil before the bar exists. It carries the roster whether or not it is
    /// showing, so the Session menu reads the same list the badge would pop.
    package var presenceIndicator: SessionPresenceIndicator? {
        windowAccessoryBar?.subviews.lazy.compactMap { $0 as? SessionPresenceIndicator }.first
    }

    /// The build identity badge in the title row, nil before the bar exists
    /// or in a bundle that names no build.
    ///
    /// Kept from the install rather than found in the bar: the chrome's memo
    /// asks for it on every screen update.
    package var buildIdentityBadge: BuildIdentityBadge? { installedBuildIdentityBadge }

    /// The badge the bar was built with, weakly: the bar owns it.
    private weak var installedBuildIdentityBadge: BuildIdentityBadge?

    /// Shows or hides every open window's build identity badge as
    /// `[debug] show_build_hash` now says — after the View menu's toggle and
    /// after a reload of the file.
    @objc
    public static func applyShowBuildHashToOpenWindows() {
        for controller in spawnedControllers {
            controller.buildIdentityBadge?.applyPreference()
        }
    }

    /// What asks the Dock to bounce for a session nobody is looking at.
    ///
    /// A property rather than a call, because what AppKit did with the ask is
    /// not readable afterwards: a case proving a background consent request
    /// asks for attention replaces this and reads what it was asked for.
    package var requestUserAttention: (NSApplication.RequestUserAttentionType) -> Void = {
        NSApp.requestUserAttention($0)
    }

    /// What posts the banner standing in for a sheet nobody can see, tagged
    /// with the window and pane a click returns to.
    ///
    /// Replaceable for the reason the ask above is: a delivered banner is the
    /// notification centre's, not this process's, to read back.
    package var postConsentBanner: (Int, Int, String, String) -> Void = { windowNumber, paneID, title, body in
        Notifications.post(
            Notifications.Request(title: title, body: body, windowNumber: windowNumber, paneID: paneID, source: .consent)
        )
    }

    /// What a landed download an allowlisted extension names is handed to.
    ///
    /// Replaceable so a case can prove which of the two a file reached without
    /// launching whatever is registered for it.
    package var openDownload: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// What a landed download the allowlist does not cover is shown through:
    /// Finder, with the file selected and nothing opened.
    package var revealDownload: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    /// The teaching line in that bar, raised and withdrawn by Core's verdicts.
    private var windowHintAccessory: HintAccessory?

    /// What this window's title-row hint line says, for a scenario; empty
    /// when it shows nothing.
    package var hintTextForTesting: String {
        guard let hint = windowHintAccessory, !hint.isHidden else { return "" }
        return hint.stringValue
    }

    /// The title-row hint line itself, for a scenario that measures where it
    /// sits or presses it.
    package var hintViewForTesting: NSView? { windowHintAccessory }

    /// A terminal colour as the window will show it.
    ///
    /// The body's layer is tagged with the configured colour space, which
    /// reinterprets the channel values rather than converting them: under
    /// Display P3 the renderer's `(r, g, b)` is a more saturated colour than
    /// the same numbers mean in sRGB. Chrome painted in sRGB therefore lands
    /// beside a body painted from the same triple and does not match it, and
    /// the title row is where a person sees the two meet. So the chrome
    /// carries the terminal's space, not AppKit's default.
    ///
    /// - Parameters:
    ///   - red: The channel, 0...1.
    ///   - green: The channel, 0...1.
    ///   - blue: The channel, 0...1.
    ///   - alpha: The opacity the row carries.
    /// - Returns: The colour in the configured space.
    func terminalColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
        isTerminalColorSpaceDisplayP3
            ? NSColor(displayP3Red: red, green: green, blue: blue, alpha: alpha)
            : NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Whether the configured colour space is Display P3, as the body's layer
    /// reads it.
    ///
    /// Stored rather than folded per ask: the chrome asks on every screen
    /// update, and the fold behind it parses the whole launch configuration.
    /// Written where the setting is applied — at window setup and by the live
    /// re-feed — so a window flipped by a setting reads the same value one
    /// opened after it does.
    private(set) var isTerminalColorSpaceDisplayP3 = false

    /// Paints the ground the panes sit on with the theme's own background.
    ///
    /// A window is ordered in before its Metal layer has presented anything,
    /// and a pane host with no fill of its own shows whatever lies behind it
    /// for that gap — the window's backing, and through it the material
    /// AppKit builds into the containers it owns. So the host carries the
    /// colour the renderer clears to, and a person opening a tab sees the
    /// terminal's own ground rather than a blurred desktop that resolves.
    ///
    /// Clear while the window is translucent: there the desktop showing
    /// through is the point, and an opaque fill here would suppress it.
    ///
    /// - Parameter tint: The chrome's colour, or nil before a surface can name
    ///   a theme.
    private func paintPaneGround(_ tint: Ubiquitty.Runtime.ChromeTint?) {
        paneGroundPaintsForTesting += 1
        if let tint {
            let color = terminalColor(
                red: CGFloat(tint.red),
                green: CGFloat(tint.green),
                blue: CGFloat(tint.blue),
                alpha: isTranslucent ? chromeBackgroundOpacity : 1
            )
            .cgColor
            for surface in projectedSurfaces {
                surface.overscrollBackgroundColor = color
            }
        }
        guard let tint, !isTranslucent || tint.isLetterbox else {
            setPaneGround(NSColor.clear.cgColor)
            return
        }
        setPaneGround(
            terminalColor(red: CGFloat(tint.red), green: CGFloat(tint.green), blue: CGFloat(tint.blue)).cgColor
        )
    }

    /// Assigns the pane host's ground, skipping a colour it already carries.
    ///
    /// Assigning an equal colour is not free: Core Animation takes a new
    /// CGColor and marks the layer for display, so a quiet screen would repaint
    /// its ground on every update to arrive at the pixels already there.
    ///
    /// - Parameter color: The ground to carry.
    private func setPaneGround(_ color: CGColor) {
        guard let layer = paneHost.layer else { return }
        if let current = layer.backgroundColor, current == color {
            return
        }
        layer.backgroundColor = color
    }

    private var titlebarBlurBackdrop: WindowBlurBackdrop?

    /// The decoded background image, and the two things it was decoded for.
    ///
    /// Kept per window rather than per surface: every pane of a window samples
    /// the same picture, and a split would otherwise decode the file once per
    /// pane. Compared against the path and the colour space, because either
    /// moving means the bytes on the texture are the wrong ones.
    private var backdropImage: BackdropImage?
    private var backdropImagePath = ""
    private var backdropImageUsesDisplayP3 = false

    /// The background image this window last installed on its panes: the
    /// path it decoded, the decoded width (zero when nothing decoded), and the
    /// opacity and mode its configuration handed the renderers.
    package var backdropImageForTesting: (path: String, pixelWidth: Int, opacity: Double, mode: Int) {
        let configuration = windowRenderConfiguration
        return (
            backdropImagePath, backdropImage?.pixelWidth ?? 0, configuration.backgroundImageOpacity,
            Int(configuration.backgroundImageMode.rawValue)
        )
    }

    // Whether the title row is AppKit's to draw. Read from the launch fold at
    // window setup rather than per repaint, so the chrome pass costs no
    // configuration lookup.
    private var usesNativeTitlebar = false
    private var usesSystemTheme: Bool {
        activeSurface.map { surface in
            (surface.currentThemeName ?? "")
                .withCString { name in
                    Ubiquitty.Themes.get(Ubiquitty.Themes.indexForName(name))?.pointee.appearance.usesSystemColors ?? false
                }
        } ?? false
    }

    /// Whether the title row is AppKit's own rather than a themed one.
    ///
    /// The identity's ink follows it: a native row takes the system label
    /// colour at an alpha, a themed one takes the terminal's foreground.
    internal var isUsingNativeTitlebar: Bool { usesNativeTitlebar || isTranslucent || usesSystemTheme }
    // Whether the launch fold hid the title bar; a hidden bar has no slot for
    // a proxy icon.
    private var hidesTitleBar = false

    /// Whether this window hides its title bar.
    ///
    /// Per window rather than per configuration: the identity's slot
    /// arbitration and the body-drag gesture both ask the window they are in
    /// rather than the configuration, so a window toggled chromeless behaves
    /// like one whatever the default has since become.
    package var isTitleBarHiddenForIdentity: Bool { hidesTitleBar }

    /// Hides or shows this window's title bar, leaving the default alone.
    ///
    /// - Parameter sender: The menu item, whose check mark follows the state.
    @objc
    public func toggleHideTitleBar(_ sender: Any?) {
        applyHideTitleBar(!hidesTitleBar)
        (sender as? NSMenuItem)?.state = hidesTitleBar ? .on : .off
        // The identity's slot depends on it: a chromeless window shows no
        // proxy icon, and one that just grew a title bar back may.
        updateRepresentedURL()
    }

    // Whether a drag quantises the window to whole cells.
    private var snapsWindowResize = true

    /// Whether this window quantises a live resize to whole cells.
    ///
    /// Read by the harness: the fact is held per window, so nothing a frame
    /// carries would show whether the setting reached it. Settable by a
    /// scenario that stages a drag under DECCOLM: the snap is off by default,
    /// and the fact under test there is the mode's override of the snap, not
    /// the preference.
    package var snapsWindowResizeForTesting: Bool {
        get { snapsWindowResize }
        set { snapsWindowResize = newValue }
    }

    // Which end of each axis the open drag is moving. A resize callback carries
    // a proposed size and never the handle that asked for it, so the press is
    // sampled once when the drag opens and read for the rest of it.
    /// The profile this window was opened with, for the title segment that
    /// names it. Empty for a window opened with no profile named.
    private var temporaryProfile = Ubiquitty.Preferences.Profile()

    /// Applies reviewed presentation overrides to this window for its lifetime.
    ///
    /// - Parameter profile: The reviewed presentation proposal.
    package func applyTemporaryProfile(_ profile: Ubiquitty.Preferences.Profile) {
        temporaryProfile = Ubiquitty.Preferences.presentationProfile(profile)
        temporaryProfile.name = std.string()
        hasTemporaryProfile = true
        applyProfile(named: appliedProfileName)
    }

    /// Removes this window's temporary overrides and restores inheritance.
    package func resetTemporaryProfile() {
        temporaryProfile = Ubiquitty.Preferences.Profile()
        hasTemporaryProfile = false
        applyProfile(named: appliedProfileName)
    }

    /// Whether this window carries temporary overrides, so its configuration
    /// is the profile-overlaid fold even with no profile named.
    private var hasTemporaryProfile = false

    /// The effective presentation, including this window's temporary overrides.
    package var effectiveProfile: Ubiquitty.Preferences.Profile {
        Ubiquitty.Preferences.resolvedSessionProfile(
            Ubiquitty.Preferences.values().pointee,
            std.string(appliedProfileName),
            Ubiquitty.Preferences.Profile(),
            temporaryProfile
        )
    }

    package private(set) var appliedProfileName = ""

    /// The custom titles held here because no Core model carries them.
    ///
    /// The window's title always: the workspace model has no window title and
    /// Sync carries none, so a hosted window's custom title stays on this Mac.
    /// The tab's only for a window no model owns — a tmux window — since a
    /// local tab's title is the workspace model's and a hosted tab's is the
    /// host's. Written only by ``setCustomTitles(window:tab:)``; read through
    /// ``customWindowTitle`` and ``customTabTitle``.
    private var heldTitles = Ubiquitty.Session.CustomTitles()

    /// The window's custom title, empty for automatic.
    ///
    /// Fills the window's name and, until the tab is named apart, the tab's;
    /// what it does to the composed title is Core's
    /// (``Ubiquitty/Session/resolveTitleNames``).
    package var customWindowTitle: String { String(heldTitles.window) }

    /// The tab's custom title, empty for automatic, read from its owner.
    ///
    /// A hosted tab's is the host's, as the last Sync layout states it; a
    /// local tab's is the workspace model's, which the arrangement capture and
    /// the workspace presentation read too; a tmux window's is held here.
    package var customTabTitle: String {
        if let drive = remoteSurface?.drive, remoteWorkspaceTab != Ubiquitty.Session.Layout.invalidTab {
            return drive.remoteWorkspaceTabTitle(of: remoteWorkspaceTab)
        }
        if let model = Self.windowModel, workspaceSurface != Ubiquitty.Session.Layout.invalidSurface {
            return String(model.customTabTitle(workspaceSurface, model.activeTab(workspaceSurface)))
        }
        return String(heldTitles.tab)
    }

    /// The columns×rows readout the window's title row draws beside its
    /// text, as the window's weave answers it; empty where the composition
    /// hides it or the window names no pane.
    package var windowTitleReadoutForTesting: String {
        titleSurface.map { wovenTitle(for: $0, as: .window).dimensions } ?? ""
    }

    /// Sets this window's and its tab's custom titles: the one writer every
    /// surface — the title popover, Rename Tab, the inspector, a script, the
    /// control socket, a restore — goes through.
    ///
    /// Each is kept as Core keeps a typed title, so empty or spaces means
    /// automatic again. A hosted tab's title is asked of the host, which
    /// confirms it in its next layout; the title moves when that arrives, and
    /// a refused request beeps rather than showing a name the host does not
    /// hold.
    ///
    /// - Parameters:
    ///   - window: The window's title as typed, or nil to leave it.
    ///   - tab: The tab's title as typed, or nil to leave it.
    package func setCustomTitles(window: String? = nil, tab: String? = nil) {
        var didChange = false
        if let window {
            let kept = Ubiquitty.Session.customTitleFromTyped(std.string(window))
            if String(kept) != customWindowTitle {
                heldTitles.window = kept
                didChange = true
            }
        }
        if let tab {
            let kept = Ubiquitty.Session.customTitleFromTyped(std.string(tab))
            if String(kept) != customTabTitle {
                if let drive = remoteSurface?.drive, remoteWorkspaceTab != Ubiquitty.Session.Layout.invalidTab {
                    if !drive.remoteWorkspaceRenameTab(remoteWorkspaceTab, title: String(kept)) {
                        NSSound.beep()
                    }
                } else if let model = Self.windowModel, workspaceSurface != Ubiquitty.Session.Layout.invalidSurface {
                    didChange = model.renameTab(workspaceSurface, model.activeTab(workspaceSurface), kept) || didChange
                } else {
                    heldTitles.tab = kept
                    didChange = true
                }
            }
        }
        if didChange {
            // Both surfaces read both titles, and one call re-derives both.
            refreshTitles()
        }
    }

    /// The file File ▸ Log Session to File… appends to, or nil while this
    /// window keeps no log.
    package internal(set) var sessionLogPath: String?

    /// The pane whose session the log records: the one focused when the log
    /// started, which a later focus change does not move.
    internal weak var sessionLogSurface: TerminalSurface?

    /// The titlebar identity: the folder proxy's reveal, the styled title, the
    /// document-actions popover and the tag markers, which are one controller
    /// because they share the one row they are drawn in.
    internal var proxyIconReveal: ProxyIconRevealController?

    #if UBIQUITTY_UI_TESTS
    /// The title's own words in the title field's coordinates, for a scenario;
    /// see ``ProxyIconRevealController/titleWordsFrameForTesting``.
    package var titleWordsFrameForTesting: NSRect? { proxyIconReveal?.titleWordsFrameForTesting }
    package var rowTitleTextForTesting: String? { proxyIconReveal?.rowTitleText }
    /// Core's row and system strings for this window's title composition.
    package var wovenWindowTitlesForTesting: (row: String, system: String)? {
        guard let titleSurface else { return nil }
        let woven = wovenTitle(for: titleSurface, as: .window)
        return (woven.title, woven.systemTitle)
    }
    #endif

    package var resolvedTagLocationName = ""

    /// Tags the reader put on this window by hand, beside the ones its host and
    /// profile match by rule.
    package var manualTags: [String] = [] {
        didSet { applyWindowTags() }
    }

    /// The tags this window wears, rule and hand-set alike, as Core composed
    /// them (`Session::resolveWindowTags`): what the title row, the tab and the
    /// title popover all draw.
    package internal(set) var windowTags = Ubiquitty.Session.ResolvedTags()

    /// The tint the first loud tag washes the title row with, or nil when no
    /// tag is loud.
    ///
    /// Held because the title's ink is read against it: a washed row is no
    /// longer a question about the theme.
    internal var loudTagTint: NSColor?

    /// The colour of the loud tag that washes the row, before it is mixed into
    /// the row's ground: a capsule filled with it keeps an outline there.
    internal var loudTagColor: NSColor?

    /// The loud tag's colour and the wash it lays on the row, for a scenario.
    package var loudTagColorsForTesting: (color: NSColor?, wash: NSColor?) { (loudTagColor, loudTagTint) }

    /// What tmux calls the window behind this tab, which outranks the focused
    /// pane's own title so a rename survives the next prompt redraw.
    ///
    /// Held apart from the pane's own OSC title rather than written over it:
    /// the two are resolved at composition time, so a prompt redraw's OSC write
    /// cannot clobber a rename. Set by the tmux controller, which is the only
    /// thing that hears `%window-renamed`.
    @objc
    public var tmuxWindowName = "" {
        didSet {
            guard tmuxWindowName != oldValue else { return }
            refreshTitles()
        }
    }

    /// The tmux session this window's panes belong to, which its title row
    /// names in a pill coloured per session.
    ///
    /// Set by the tmux controller at discovery and again on
    /// `%session-renamed`: the session is the same unit under a new name, so
    /// the pill re-typesets and keeps its colour.
    @objc
    public var tmuxSessionName = "" {
        didSet {
            guard tmuxSessionName != oldValue else { return }
            applyTmuxSessionBadge()
        }
    }

    /// What a host is called, for a remote window whose stream has set no title
    /// of its own. A host name reads better than the application's.
    package var remoteHostLabel = ""

    /// The tag the `[[tags]]` rules give the host this window lives on, which
    /// the host chip wears as its capsule; nil when no rule colours it.
    var hostChipTag: HostChipTag?

    /// The opacity this window draws its tags' colours at, in the title row
    /// and on its tab: `[appearance] tag_color_opacity`, read where the tags
    /// are resolved.
    var tagColorOpacity = CGFloat(Ubiquitty.Preferences.Defaults.tagColorOpacity)

    /// How the title row last laid its tags' colours down, which the host
    /// chip and the markers were drawn with.
    var titleRowTagStyle = TitlebarTagStyle.fullStrength

    /// The marks this window's tab title leads with (``TabTagMarks``): one
    /// for each tag Core places on the tab, by rule or by hand, in the
    /// window's order; empty for none.
    var tabTagMarks: [TabTagMark] = []

    /// The names of the tags the tab draws, which its tooltip says.
    var tabTagNames = ""

    /// The tags each pane header leads its title with, by pane, and the host
    /// identity they were resolved against; emptied whenever the window's
    /// tags are resolved again.
    var paneHeaderTagRuns: [Int32: (hostIdentity: String, run: TabTagMarkRun?)] = [:]

    /// Whether the reader pinned this tab: it is held leftmost in its group,
    /// carries a marker, and asks before it closes.
    ///
    /// Read by the tab commands that hold a pinned tab leftmost, and by the UI
    /// scenarios that pin and unpin one.
    @objc
    public private(set) var isPinned = false

    /// Whether this tab has produced output nobody has looked at since.
    ///
    /// Read by the strip's mark, cleared when the tab is looked at. Package
    /// rather than private so a scenario reads the applied state rather than
    /// recomputing the decision it is meant to check.
    package private(set) var hasUnseenActivity = false

    /// Whether a bell rang on this tab with the reader somewhere else.
    ///
    /// A separate latch from the activity one, because they answer different
    /// questions and are cleared by the same gesture: output arriving is news
    /// the reader may want, a bell is a program asking for them. Package for
    /// the same reason as its neighbour — a scenario reads the applied state.
    package private(set) var hasUnheardBell = false

    /// Whether a program asked for the reader with a banner while they were
    /// somewhere else.
    ///
    /// A third latch beside the two above, cleared by the same gesture: the
    /// banner is gone by the time the reader comes back, and this is what is
    /// still there to be found. Package for the same reason as its neighbours.
    package private(set) var hasUnseenNotification = false

    /// The dots the strip shows for unseen activity, made on first use and
    /// kept so the accessory is not rebuilt per drain.
    private lazy var tabAccessoryPresenter: TabAccessoryPresenter = {
        let presenter = TabAccessoryPresenter()
        // An accessory write makes AppKit rebuild the tab's stack view and
        // re-derive the pill's title from the tab's attributed one, so the
        // bake is written back over it.
        presenter.onAccessoryWrite = { [weak self] in
            self?.requestStripWriteBack()
        }
        return presenter
    }()

    /// When a content resize stops explaining this pane's output.
    ///
    /// A resize sends SIGWINCH to every pane and a shell answers by redrawing
    /// its prompt, so output arriving before this is the resize's own echo.
    private var resizeSettleEndsAt = 0.0

    /// The content height this window last settled at, which the next change
    /// is measured against. Zero until the window has been laid out once.
    private var lastContentHeight = 0.0

    /// Whether this window carried a tab strip at the last frame change, so a
    /// compensating `setFrame` cannot read as another toggle when it comes
    /// back around.
    private var hadTabStrip = false

    /// Whether the last walk of this window's tab chrome read its group as
    /// tabbed, which is what a tabbed-to-lone read is measured against.
    private var didLastChromeWalkReadTabbed = false

    /// The tab group this window shares with siblings, as the last chrome walk
    /// that found a strip saw it.
    ///
    /// Held because a closing window has already left its group by the time
    /// AppKit says it will close: the siblings it owes a walk are reachable
    /// through the group it was in, and no longer through the window.
    private weak var sharedTabGroup: NSWindowTabGroup?

    /// How many times a sibling leaving this window's group has made it
    /// reconcile the group's chrome, for a scenario asking that a close costs
    /// exactly one walk.
    package private(set) var tabGroupCloseReconcilesForTesting = 0

    /// How many times a thin tabbed-to-lone read has been overturned a turn
    /// later, for a scenario asking that the chrome it took down is given back
    /// by the guard rather than by a focus walk that happens to follow.
    package private(set) var thinGroupReverifiesForTesting = 0

    /// How many times the pane ground has been painted, for a scenario asking
    /// what a quiet screen update costs.
    package private(set) var paneGroundPaintsForTesting = 0

    /// How many times the window's backing, appearance and title row have been
    /// written — the chrome repaint a quiet update must not run.
    package private(set) var chromeRepaintsForTesting = 0

    /// How many times the window's own title has been woven.
    package private(set) var windowTitleWeavesForTesting = 0

    /// How many times the tab's title has been baked.
    package private(set) var tabTitleBakesForTesting = 0

    /// How many times a pane bar has been restyled.
    package private(set) var paneChromeRestylesForTesting = 0

    /// How many times the Inspector's model has been refreshed.
    package private(set) var inspectorRefreshesForTesting = 0

    /// How many focus edges a pane has reported to this window.
    package private(set) var paneFocusEdgesForTesting = 0

    /// Re-mirrors the pane tree, for a scenario asking that a rebuilt bar comes
    /// up carrying its pane's title.
    package func rebuildPaneLayoutForTesting() {
        rebuildPaneLayout()
    }

    /// Sets the root divider through the model and refreshes its native views.
    package func setRootSplitRatioForTesting(_ ratio: Float) -> Bool {
        guard let model = Self.windowModel else { return false }
        let tree = model.paneTreeSnapshot(workspaceSurface)
        guard model.setDividerRatio(workspaceSurface, tree.root(), ratio) else { return false }
        rebuildPaneLayout()
        return true
    }

    /// The windows this window's group held when its last chrome walk saw a
    /// strip, weakly.
    ///
    /// A closing window has already left its group, so which group it was in
    /// is a fact only a walk that ran earlier holds.
    private let sharedTabWindows = NSHashTable<NSWindow>.weakObjects()

    /// How far this window's bottom was moved down for the strip, and so how
    /// far it moves back when the strip goes. Zeroed by a live resize: the
    /// person who dragged the window owns its size.
    private var tabStripGrowth = 0.0

    /// The frame-change observer on the content view, held so it is registered
    /// once and released with the controller.
    private var contentFrameObserver: (any NSObjectProtocol)?
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabSelectionObservation: NSKeyValueObservation?
    private var tabMembershipObservation: NSKeyValueObservation?
    private var applicationFocusObservers: [any NSObjectProtocol] = []
    private var isTabFocusRefreshScheduled = false
    /// Whether this controller has completed window teardown.
    package private(set) var isWindowClosed = false

    /// This window's Paint Heatmap, made on first open.
    package var paintHeatmapWindow: PaintHeatmapWindowController?

    /// This window's Drawing Debug panel, made on first open.
    package var drawingDebugPanel: DrawingDebugPanelController?

    /// Observes selection independently of key and main notification ordering.
    func observeTabSelection() {
        guard let window else { return }
        if applicationFocusObservers.isEmpty {
            applicationFocusObservers = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
                .map { name in
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleTabFocusRefresh() }
                    }
                }
            // Any window's close, not this window's: a tab of a foreign window kind
            // leaving a shared group announces nothing to this one, and the
            // group's chrome is this controller's to hand back when the survivor
            // is one of ours. By selector, because the notification names the
            // window that is closing and only a synchronous delivery carries it
            // here: a queued block would have to send it across an isolation
            // boundary it cannot cross.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(answerSiblingClose(_:)),
                name: NSWindow.willCloseNotification,
                object: nil
            )
        }
        let group = window.tabGroup
        guard group !== observedTabGroup else { return }
        observedTabGroup = group
        tabSelectionObservation = group?
            .observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // The selection is what a pane reads to know whether it
                    // stands behind the group's front tab, and it moves here
                    // for a programmatic switch — a remote host binding a tab,
                    // an attachment, Beam — with no key or main edge of its
                    // own. The tab reaching the front notes its reveal there.
                    let selected = self.window?.tabGroup?.selectedWindow
                    let controller = selected?.windowController as? TerminalWindowController
                    for surface in controller?.projectedSurfaces ?? [] {
                        surface.refreshWindowTabBackgrounding()
                    }
                    // A hosted tab in front is the host's to name, so the
                    // move is reported to it; the tab's own controller says
                    // whether a person made it.
                    controller?.reportTabBroughtToFront()
                    self.scheduleTabFocusRefresh()
                }
            }
        // A tab joining or leaving moves every tab's number and, for the tab
        // that was lone, whether it reads as a strip's selected tab at all;
        // neither comes with a selection change when the selected tab stays.
        tabMembershipObservation = group?
            .observe(\.windows, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.scheduleTabFocusRefresh()
                }
            }
    }

    func scheduleTabFocusRefresh() {
        guard !isTabFocusRefreshScheduled else { return }
        isTabFocusRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isTabFocusRefreshScheduled = false
            self.refreshTabGroupForFocusChange()
        }
    }

    private var horizontalDragEdge = Ubiquitty.Rendering.DragEdge.Neither
    private var verticalDragEdge = Ubiquitty.Rendering.DragEdge.Neither

    // How far from an edge a press still counts as grabbing it.
    private static let resizeEdgeTolerance = 32.0

    /// Remembers this window's geometry as where the next window opens.
    ///
    /// Which frames are worth remembering is Core's, the session's lifetime
    /// among them: a window running one program belongs to that program rather
    /// than to a person arranging a desktop.
    private func rememberWindowFrame() {
        guard let window else { return }
        let endsWithChild = focusedSurface?.drive.doesSessionEndWithChild ?? false
        WindowFrameMemory.remember(window, doesSessionEndWithChild: endsWithChild)
    }

    /// The window was dragged somewhere: that is where the next one opens.
    ///
    /// - Parameter notification: The move notification.
    public func windowDidMove(_ notification: Notification) {
        rememberWindowFrame()
    }

    /// A resize settled: the size the user let go of is the one to remember.
    ///
    /// - Parameter notification: The end-of-live-resize notification.
    public func windowDidEndLiveResize(_ notification: Notification) {
        rememberWindowFrame()
    }

    /// Samples which handle opened this drag.
    ///
    /// - Parameter notification: The live-resize notification.
    public func windowWillStartLiveResize(_ notification: Notification) {
        beginLiveResize(pressedAt: NSEvent.mouseLocation)
    }

    /// Opens a drag pressed at a point, in screen coordinates: the
    /// notification's body, with the press passed in so a scenario can name
    /// the handle a drag would have grabbed.
    ///
    /// - Parameter press: Where the drag was pressed.
    package func beginLiveResize(pressedAt press: NSPoint) {
        // The user owns the size from here: a strip that goes later leaves the
        // window where they put it rather than taking back a move they have
        // already overridden.
        tabStripGrowth = 0
        guard let window else { return }
        let frame = window.frame
        horizontalDragEdge = Ubiquitty.Rendering.dragEdgeForPress(
            press.x,
            frame.minX,
            frame.maxX,
            Self.resizeEdgeTolerance
        )
        verticalDragEdge = Ubiquitty.Rendering.dragEdgeForPress(
            press.y,
            frame.minY,
            frame.maxY,
            Self.resizeEdgeTolerance
        )
    }

    /// Quantises a live drag to whole cells, following the pointer through
    /// the slack off the lattice and up to the screen's edge.
    ///
    /// A window that lands between two cell counts shows the smaller one and
    /// paints the remainder as background, so an unquantised drag gives away up
    /// to a cell on each axis. Core owns the quantiser and both kinds of slack,
    /// because every frontend resizes the same grid.
    ///
    /// - Parameters:
    ///   - sender: The window being dragged.
    ///   - frameSize: The frame extent the drag proposes.
    /// - Returns: The frame extent to apply.
    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        snappedFrameSize(for: sender, proposed: frameSize, isLiveResize: sender.inLiveResize)
    }

    /// The frame extent a drag settles on: `windowWillResize`'s answer, with
    /// the drag's liveness passed in so a scenario can ask it as a drag
    /// would, which AppKit's read-only `inLiveResize` does not let it stage.
    ///
    /// - Parameters:
    ///   - sender: The window being dragged.
    ///   - frameSize: The frame extent the drag proposes.
    ///   - isLiveResize: Whether a drag is in progress.
    /// - Returns: The frame extent to apply.
    package func snappedFrameSize(for sender: NSWindow, proposed frameSize: NSSize, isLiveResize: Bool) -> NSSize {
        // A programmatic resize is not a drag, and a full-screen window is
        // pinned to the screen — quantising either fights whoever set the size.
        // The lattice is the focused pane's whoever keeps the layout: a hosted
        // window's panes are the host's, and the model holds none of them.
        guard snapsWindowResize, isLiveResize,
            !sender.styleMask.contains(.fullScreen),
            let surface = focusedPaneSurface
        else {
            return frameSize
        }
        // DECCOLM owns the column count: while it stands a resize moves rows
        // alone and the cells stretch to whatever width the window has, so a
        // width quantised to whole natural cells would be quantised to a grid
        // the mode is not going to cut. The width is left free there; Core
        // publishes the fact, and Core's grid fit is what holds the count
        // (resizeGridToBounds).
        let isColumnCountHeld = surface.drive.readSnapshot().isColumnCountHeld
        let cell = surfaceRenderer.cellSize(for: surface)
        guard cell.width > 0, cell.height > 0 else { return frameSize }

        let insets = surfaceRenderer.gridFitInsets(for: surface)
        let overhead = terminalFrameOverhead
        let chromeWidth = overhead.width
        let chromeHeight = overhead.height
        let scale = sender.backingScaleFactor > 0 ? sender.backingScaleFactor : 1

        // Only the axis the drag moved. Snapping the other one would nudge an
        // extent the user is not touching, which walks a window across the
        // screen over a long drag.
        let axisEpsilon = 0.5 / scale
        let current = sender.frame.size
        let widthMoved = abs(frameSize.width - current.width) > axisEpsilon && !isColumnCountHeld
        let heightMoved = abs(frameSize.height - current.height) > axisEpsilon

        // The room to the screen's visible bound, from the edge the drag
        // leaves alone; none known for a window on no screen.
        let visible = (sender.screen ?? NSScreen.main)?.visibleFrame
        let frame = sender.frame
        func axis(
            proposed: CGFloat,
            current: CGFloat,
            cellExtent: CGFloat,
            reserve: CGFloat,
            cellLimit: Int32,
            available: Double
        )
            -> CGFloat
        {
            var request = Ubiquitty.Rendering.DragAxisRequest()
            request.proposed = Double(proposed)
            request.current = Double(current)
            request.cellExtent = Double(cellExtent)
            request.reserve = Double(reserve)
            request.cellLimit = cellLimit
            request.available = available
            return CGFloat(Ubiquitty.Rendering.quantiseDragExtent(request))
        }

        var snapped = frameSize
        if widthMoved {
            snapped.width = axis(
                proposed: frameSize.width,
                current: current.width,
                cellExtent: cell.width,
                reserve: insets.left + insets.right + chromeWidth,
                cellLimit: Ubiquitty.maxColumns,
                available: visible.map {
                    Ubiquitty.Rendering.availableExtentForDrag(horizontalDragEdge, frame.minX, frame.maxX, $0.minX, $0.maxX)
                } ?? 0
            )
        }
        if heightMoved {
            snapped.height = axis(
                proposed: frameSize.height,
                current: current.height,
                cellExtent: cell.height,
                reserve: insets.top + insets.bottom + chromeHeight,
                cellLimit: Ubiquitty.maxRows,
                available: visible.map {
                    Ubiquitty.Rendering.availableExtentForDrag(verticalDragEdge, frame.minY, frame.maxY, $0.minY, $0.maxY)
                } ?? 0
            )
        }
        return snapped
    }

    // How many more times a detected handshake may interrupt with a dialog.
    // One per window rather than per pane: the dialogs are app-modal, so the
    // interruption they spend is the window's whatever pane asked.
    private var transferPromptBudget = Ubiquitty.Network.PromptBudget()

    /// A file-transfer handshake arrived on a surface's stream.
    ///
    /// The stream is held from the moment of detection — ingest stopped
    /// reading so the transfer frame stays in the kernel queue — and every
    /// path out of here re-arms the watch, which lifts that hold. A path that
    /// forgot would leave the pane's session parked for its life.
    ///
    /// - Parameter surface: The surface whose session detected the preamble.
    func surfaceDidDetectFileTransfer(_ surface: TerminalSurface) {
        let detection = surface.drive.detectedFileTransfer()
        let isReceive = detection.direction != .Send
        // The budget weighs both reasons a stream may not interrupt: the user
        // turned automatic receiving off, or this stream has spent its declines.
        // The setting only governs the receive direction — a detected send means
        // the remote is waiting for a file this user picks, which auto_receive
        // was never about.
        let configuration = Ubiquitty.Preferences.values().pointee
        let autoReceive: Ubiquitty.Network.AutoReceive =
            (!isReceive || Ubiquitty.Preferences.Effective.transferAutoReceive(configuration)) ? .Enabled : .Disabled
        guard transferPromptBudget.mayPrompt(autoReceive) else {
            surface.drive.armFileTransferWatch()
            return
        }
        guard !Ubiquitty.Network.resolveTransferAgentPath(.Receive).empty() else {
            let alert = NSAlert()
            // copy-ok: lrzsz is a package name and keeps its lowercase spelling in a title
            alert.messageText = "ZMODEM Transfers Need lrzsz"
            alert.informativeText =
                "Ubiquitty detected a ZMODEM transfer, but the rz and sz tools aren’t installed. "
                + "Install them with:\n\n    brew install lrzsz\n\nThen start the transfer again."
            alert.runModal()
            transferPromptBudget.recordDecline() // an unusable prompt is still an interruption
            surface.drive.armFileTransferWatch()
            return
        }

        // The agent's operand: where a receive may write, or which file a send
        // ships. Both come from the user before any byte moves — the save
        // location is the security gate, and a send has no file until one is
        // picked.
        var operand = ""
        if isReceive {
            var downloadDirectory = String(Ubiquitty.Network.resolvedTransferDownloadDirectory(Ubiquitty.Preferences.values().pointee))
            // A platform with no default answers empty, and an empty default is
            // not a place to claim files will land: the chooser asks instead of
            // claiming, and the transfer runs where it points.
            var wantsChooser = downloadDirectory.isEmpty
            if !wantsChooser {
                let alert = NSAlert()
                alert.messageText = "Incoming ZMODEM File Transfer"
                alert.informativeText =
                    "The remote host wants to send you one or more files. They’ll be "
                    + "saved to:\n\n\(downloadDirectory)\n\nAllow the transfer?"
                // Refusing first, through ConsentAlert, because the button a
                // stray Return presses is the one AppKit was given first —
                // and here that keystroke lets a remote host write to this
                // disk. The two allowing buttons permit the same thing and
                // differ only in where the bytes land, so this reads the
                // choice rather than a grant scope.
                let chosen = ConsentAlert.choose(
                    alert,
                    refusing: "Cancel",
                    between: ["Receive", "Choose Folder…"]
                )
                guard chosen > 0 else {
                    transferPromptBudget.recordDecline()
                    surface.drive.armFileTransferWatch()
                    return // cancelled — the remote sz times out on its own
                }
                wantsChooser = chosen == 2
            }
            if wantsChooser {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.prompt = "Save Here"
                guard panel.runModal() == .OK, let chosen = panel.url?.path else {
                    transferPromptBudget.recordDecline()
                    surface.drive.armFileTransferWatch()
                    return
                }
                downloadDirectory = chosen
            }
            operand = downloadDirectory
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Send"
            panel.message = "The remote host is waiting to receive a file with rz. Choose the file to send."
            guard panel.runModal() == .OK, let chosen = panel.url?.path else {
                transferPromptBudget.recordDecline()
                surface.drive.armFileTransferWatch()
                return
            }
            operand = chosen
        }
        transferPromptBudget.recordAccept()

        // What the folder held before the sender wrote into it. A ZMODEM
        // receive names its own files, so which ones this transfer created is
        // the difference — and they are the ones that get the download's tag.
        let entriesBefore = isReceive ? Self.folderEntries(at: operand) : []

        // Take over the PTY: ingest stops so its poll loop cannot lift frames
        // out from under the agent, the agent runs against the master, and the
        // re-arm afterwards is what lifts the detection's hold.
        let descriptor = surface.drive.fileDescriptor()
        surface.drive.stopIngest()
        // The agent runs inside the borrow: the operand crosses as a view over
        // the caller's bytes, and the transfer reads it for its whole run.
        let transferred =
            descriptor >= 0
            && operand.withCString { operandBytes in
                Ubiquitty.Network.runTransferAgent(
                    descriptor,
                    isReceive ? .Receive : .Send,
                    std.string_view(operandBytes)
                )
            }
        _ = surface.drive.startIngest()
        surface.drive.armFileTransferWatch()

        // Whatever the agent's verdict, the bytes it already wrote are on this
        // disk, and the tag is a property of the bytes rather than of the
        // reveal: a sender that pushes one file and then aborts the session
        // decides when the agent exits, and a failed receive that left files
        // untagged would leave exactly the ones this guard exists for.
        if isReceive, !operand.isEmpty {
            Self.tagArrivals(in: operand, addedTo: entriesBefore)
        }

        if !transferred {
            let alert = NSAlert()
            alert.messageText = "The ZMODEM Transfer Didn’t Finish"
            alert.informativeText =
                "The transfer was interrupted or failed. Start it again from the remote host."
            alert.runModal()
        } else if isReceive, !operand.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: operand)])
        }
    }

    /// Tags every file a receive added to a folder as the download it is.
    ///
    /// A file a remote sender pushed is a download whatever it named itself,
    /// and untagged it would open on the first double-click with Gatekeeper
    /// never consulted. Which files are the transfer's is the difference
    /// against what the folder held before it ran, because a ZMODEM receive
    /// names its own files.
    ///
    /// - Parameters:
    ///   - path: The folder the receive wrote into.
    ///   - entriesBefore: What it held before the sender wrote into it.
    /// - Returns: The files tagged, in no particular order.
    @discardableResult
    package static func tagArrivals(in path: String, addedTo entriesBefore: Set<String>) -> [URL] {
        Self.folderEntries(at: path).subtracting(entriesBefore)
            .map { arrival in
                let file = URL(fileURLWithPath: path).appendingPathComponent(arrival)
                QuarantinedDownload.tag(file)
                return file
            }
    }

    /// What a folder holds right now, by name.
    ///
    /// - Parameter path: The folder. One that cannot be read holds nothing as
    ///   far as this is concerned, which leaves the arrivals set empty rather
    ///   than claiming every name in it is new.
    /// - Returns: The entry names.
    package static func folderEntries(at path: String) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
    }

    /// A screen update — the chrome follows the palette it may have moved.
    ///
    /// - Parameter surface: The surface whose model changed.
    func surfaceDidUpdateScreen(_ surface: TerminalSurface) {
        // Every pane's output marks the tab, focused or not: a split's other
        // pane producing output is news on this tab just as the focused one's
        // is. The theme and title below read the focused pane, so they stay
        // behind the guard.
        noteOutputForUnseenActivity()
        guard restyleChromeIfColorsMoved(on: surface) else { return }
        refreshTitles(trigger: surface)
    }

    /// Repaints the chrome a pane's colours paint, against the memos it was
    /// painted from: the pane's bar, and for the window's active pane its
    /// ground, title row and appearance and every tab of its group.
    ///
    /// A screen update asks this. So does a hosted tmux pane's repaint: its
    /// session renders a model the hosting session writes and never drains, so
    /// no screen update reports its output, and a window that opened empty
    /// would otherwise keep the system's appearance under a theme of the other
    /// polarity until a setting moved.
    ///
    /// - Parameter surface: The pane whose model changed.
    /// - Returns: Whether the pane is the window's active one.
    @discardableResult
    func restyleChromeIfColorsMoved(on surface: TerminalSurface) -> Bool {
        // Before the active guard: a background pane's own OSC 10 or 11 moves
        // the colours its bar is painted with and nothing else, so the bar is
        // the one thing that has to answer it. Two borrow reads against the
        // memo the bar was styled from.
        restylePaneChromeIfColorsMoved(on: surface)
        guard surface === activeSurface else { return false }
        let snapshot = surface.drive.readSnapshot()
        if !restyleSessionAppearanceIfColorsMoved(on: surface) {
            applyChromeTheme(from: snapshot)
        }
        return true
    }

    /// A hidden pane's palette moved, which its frames wait for the reveal to
    /// show: a theme reached it through its host after every window was told
    /// of the change, or its program set its colours.
    ///
    /// The chrome drawn from those colours is on screen meanwhile: the tab's
    /// label, icon and marks in the strip, the pane's header. It restyles as
    /// it would for a screen update, without the activity a screen update
    /// marks.
    ///
    /// - Parameter surface: The pane whose palette moved.
    func surfaceDidChangeWithheldPalette(_ surface: TerminalSurface) {
        restylePaneChromeIfColorsMoved(on: surface)
        guard surface === activeSurface else { return }
        _ = restyleSessionAppearanceIfColorsMoved(on: surface)
    }

    /// Restyles the chrome of every tab in the group when the colours the
    /// window's pane wears moved since this window last painted from them.
    ///
    /// - Parameter surface: The window's active pane.
    /// - Returns: Whether the colours moved.
    private func restyleSessionAppearanceIfColorsMoved(on surface: TerminalSurface) -> Bool {
        let colors = (surface.drive.sessionIdentity, themeForeground(of: surface), themeBackground(of: surface))
        if let painted = screenAppearanceColors, painted.0 == colors.0, painted.1 == colors.1, painted.2 == colors.2 {
            return false
        }
        screenAppearanceColors = colors
        refreshSessionAppearance()
        return true
    }

    /// Restyles a pane's bar when the colours it is painted with have moved.
    ///
    /// The bar's own memo holds what it was painted from, so this is a
    /// comparison against the state of the bar rather than a second record to
    /// keep in step.
    ///
    /// - Parameter surface: The pane reporting a screen update.
    private func restylePaneChromeIfColorsMoved(on surface: TerminalSurface) {
        guard !paneChromes.isEmpty, let pane = paneChromeID(of: surface) else { return }
        guard let painted = paneChromeInputs[Int32(pane.rawValue)] else {
            restylePaneChrome(of: surface)
            return
        }
        if painted.foreground != themeForeground(of: surface) || painted.background != themeBackground(of: surface) {
            restylePaneChrome(of: surface)
        }
    }

    private var screenAppearanceColors: (UInt, UInt32, UInt32)?

    /// What a window title is woven from.
    ///
    /// Every fact the weave reads is a member: one left out is a fact whose
    /// change cannot reach the title, because the memo answers first and the
    /// weave never runs.
    struct TitleWeaveFacts: Equatable {
        var osc: String
        var directory: String
        var rows: Int32
        var columns: Int32
        var chain: String
        var chainWithArguments: String
        var shellCommand: String
        var ttyName: String
        var profileName: String
        var tabName: String
        var windowName: String
        var tmuxName: String
        var isPinned: Bool
        var programStatus: String
        /// Core's digest of the whole status text, of which `programStatus`
        /// is the first words: it moves when the hover text does.
        var statusHelpDigest: UInt32
        /// What a host is called, which names a remote window whose stream has
        /// set no title of its own.
        var remoteHostLabel: String
        /// The host the pane lives on as the chrome names it, empty for a
        /// plain local shell: a share or a reclaim moves it without moving any
        /// other fact here.
        var hostName: String
        /// The host the window's chrome names, and whether its tabs live in
        /// more than one place: what decides whether a tab's label carries
        /// its host, and moves when another tab joins, leaves or goes
        /// somewhere else.
        var windowHostName: String
        var doTabsMixPlaces: Bool
        /// The names of the window's tags, for the tab's tooltip.
        var tagNames: String
        /// Whether the session has ended, which drops both process segments
        /// and names the fact in their place.
        var hasSessionEnded: Bool
        /// The program the pane runs, whose icon leads its name; empty for none
        /// or with `[appearance] process_icons` off.
        var processIconKey: String = ""
        /// Whether a program fills the screen, which can leave the directory
        /// out (`[title] directory_hidden_in_full_screen`).
        var isFullScreen: Bool = false
    }

    /// Reports whether a displayed title includes sampled process information.
    ///
    /// - Parameter surface: The pane supplying the title's facts.
    /// - Returns: Whether a visible title consumes the process or shell component.
    func needsProcessTitle(for surface: TerminalSurface) -> Bool {
        var observation = Ubiquitty.Runtime.ProcessObservation()
        observation.isInspectorOpen = surface.hasProcessInspector
        if let window {
            let isSelected = !WindowTabSelection.isBackgroundedTab(window)
            observation.isGroupVisible = surface.isTitlePresentationVisible
            observation.isWindowTitleVisible = surface === titleSurface && isSelected && !hidesTitleBar
            observation.isTabTitleVisible = surface === titleSurface && window.tabGroup?.isTabBarVisible == true
            observation.isPaneTitleVisible =
                isSelected && !surface.isHiddenOrHasHiddenAncestor
                && paneChromes.contains(where: { $0.contentView === surface && $0.showsTitleBar && !$0.isHiddenOrHasHiddenAncestor })
            // A custom title takes the process segments' place, so a surface
            // that carries one shows no sample either.
            let windowNames = titleNames(for: surface, as: .window)
            let tabNames = titleNames(for: surface, as: .tab)
            observation.isWindowTitleReplaced = !windowNames.replacement.isEmpty || windowNames.isCustomName
            observation.isTabTitleReplaced = !tabNames.replacement.isEmpty || tabNames.isCustomName
            observation.isPaneTitleReplaced = !titleNames(for: surface, as: .pane).replacement.isEmpty
            // The marker is the window's and every pane feeds it, so it reads
            // every pane's sample, not only the titled one's. A chromeless
            // window keeps it current too, so revealing its title bar shows
            // the answer rather than whatever it was when the bar went away.
            observation.isCloseMarkerVisible = true
        }
        return Ubiquitty.Runtime.needsProcessObservation(observation, Ubiquitty.Preferences.values().pointee)
    }

    // What the title was last woven from. The weave reads a configuration, a
    // snapshot, a directory and the sampled process facts, which is more than
    // a frame should spend on a string that changes when a prompt does — so
    // the inputs are compared and the weave runs when one of them moved.
    private var titleInputs: TitleWeaveFacts?

    /// Whether a grid move has a title weave queued on the main queue, so the
    /// steps of one turn weave once (`surfaceDidResizeGrid`).
    private var isResizeTitleWeavePending = false

    /// The facts the weave reads for a surface, composed for a memo.
    ///
    /// Read through the drive, which brackets each read with the model lock:
    /// the directory is a std::string the ingest thread rewrites in place, and
    /// a borrow taken while the writer reallocates walks a freed buffer.
    ///
    /// - Parameter surface: The pane the title names.
    /// - Returns: Every fact the weave reads, so equal inputs weave equal.
    private func titleWeaveInputs(for surface: TerminalSurface) -> TitleWeaveFacts {
        let snapshot = surface.drive.readSnapshot()
        let grid = surface.drive.titleGrid(for: surface.publishedGrid)
        // The surface's own copy, not a locked read of the session's: every
        // writer of the directory raises the event that refreshes it, and the
        // surface updates its copy before it delivers the screen change. This
        // is read for every pane on every pass, and a locked read would take
        // the lock the parser holds all flood long.
        let directory = surface.currentDirectory
        let host = paneHost(of: surface)
        if surface === titleSurface {
            noteTabHost(host)
        }
        let window = windowHostFacts()
        return TitleWeaveFacts(
            osc: surface.title,
            directory: directory,
            rows: grid.rows,
            columns: grid.columns,
            chain: surface.drive.processChain,
            chainWithArguments: surface.drive.processChainWithArguments,
            shellCommand: surface.drive.shellCommandName,
            ttyName: surface.drive.ttyName,
            profileName: appliedProfileName,
            tabName: customTabTitle,
            windowName: customWindowTitle,
            tmuxName: tmuxWindowName,
            isPinned: isPinned,
            programStatus: String(snapshot.tabStatusLabel()),
            statusHelpDigest: snapshot.statusHelpDigest,
            remoteHostLabel: remoteHostLabel,
            hostName: RemoteConnectionIndicator.hostName(of: host),
            windowHostName: window.hostName,
            doTabsMixPlaces: window.doTabsMixPlaces,
            tagNames: tabTagNames,
            hasSessionEnded: surface.drive.sessionEnd.didEnd,
            processIconKey: ProcessIcons.isShown ? surface.drive.processIconKey(snapshot) : "",
            isFullScreen: snapshot.modes.alternateScreenActive
        )
    }

    /// Re-derives each title this window shows: the window's own, and its
    /// tab's label.
    ///
    /// The two spell the same facts for two surfaces, so nothing re-derives
    /// one without the other. Derived apart they drift, and they did: the tab
    /// label is re-derived on every focus change and the window title was not,
    /// so a tab could settle on the shell while the window title still named
    /// the `login` that exec'd it, for as long as the session ran.
    ///
    /// The directory is one of the inputs, not just one of the outputs: a `cd`
    /// moves the title without touching the host's title, the row count or the
    /// column count, so a memo keyed on those alone holds the folder the
    /// session started in for as long as it runs.
    ///
    /// Each consumer answers its own memo: the window title, the tab's label
    /// and tooltip, the pane bars and the Inspector read overlapping facts and
    /// none of them is behind another's comparison. The facts the window and
    /// the tab share are read once here and handed to both.
    ///
    /// - Parameters:
    ///   - trigger: The pane whose event asked for this, whose bar alone is
    ///     restyled; nil restyles every bar, for an edge every pane shares.
    ///   - writesStripBack: Whether the tab's label is written back into the
    ///     strip even where the bake did not move — an edge that made AppKit
    ///     re-derive the pill's colour rather than one that moved the title.
    package func refreshTitles(trigger: TerminalSurface? = nil, writesStripBack: Bool = false) {
        for surface in projectedSurfaces {
            surface.recomputePresentation()
        }
        refreshWindowTagLocation()
        let facts = titleSurface.map { titleWeaveInputs(for: $0) }
        // The tab's title is baked whatever the occlusion report says: its
        // label is on the strip, which is as visible as the group's front
        // window, and the window server reports a window that just came to
        // the front as occluded for a moment — the moment a switch re-bakes
        // the weights in. Gated on the report, the tab that went behind kept
        // the selected weight until some later edge re-baked the group.
        refreshTabTitle(facts: facts, writesStripBack: writesStripBack)
        guard titleSurface?.isTitlePresentationVisible == true else { return }
        if let surface = titleSurface, let facts, titleInputs != facts {
            titleInputs = facts
            windowTitleWeavesForTesting += 1
            window?.title = composedTitle(for: surface)
            updateRepresentedURL()
            // The styled title is rebuilt from the same inputs, so the row's
            // dimmed segment names the folder the title was woven from rather
            // than the one it named a moment ago.
            applyWindowTitleStyle()
            // AppKit derives the pill's own copy of the label from the window's
            // title, so a title that moved is an edge the write-back answers.
            requestStripWriteBack()
        }
        if let trigger {
            restylePaneChrome(of: trigger)
        } else {
            refreshPaneChrome()
        }
        refreshNativeInspector()
    }

    /// Restyles one pane's bar, for an event that moved that pane alone.
    ///
    /// A background pane's title, directory, process sample and theme are its
    /// own: nothing about them reaches the window's title or its tab, and a
    /// refresh that ran for the active pane alone left every other bar naming
    /// what the pane was running when it last held focus.
    ///
    /// - Parameter surface: The pane whose bar to restyle.
    internal func restylePaneChrome(of surface: TerminalSurface) {
        pruneDetachedPaneChromes()
        guard !paneChromes.isEmpty, let pane = paneChromeID(of: surface) else { return }
        let zoomed = paneChromeZoomedPane
        for chrome in paneChromes where chrome.paneID == Int32(pane.rawValue) {
            applyPaneChromeStyle(chrome, pane: pane, zoomedPane: zoomed)
        }
    }

    /// Restyles every pane bar on screen, without rebuilding the view tree.
    ///
    /// Driven from the same place the tab label is, so a bar cannot stand on a
    /// title the tab has already moved past. Walking the hierarchy is what keeps
    /// this correct through a zoom or a split, where the panes on screen are not
    /// the panes the model last handed out.
    internal func refreshPaneChrome() {
        pruneDetachedPaneChromes()
        guard !paneChromes.isEmpty else { return }
        let zoomed = paneChromeZoomedPane
        for chrome in paneChromes {
            if let pane = Ubiquitty.Session.Layout.PaneID(rawValue: UInt32(chrome.paneID)) {
                applyPaneChromeStyle(chrome, pane: pane, zoomedPane: zoomed)
            }
        }
    }

    /// Resolves a pane header's owner without treating a hosted pane as local.
    private func paneChromeID(of surface: TerminalSurface) -> Ubiquitty.Session.Layout.PaneID? {
        remotePaneSurfaces.first(where: { $0.value === surface })?.key ?? paneID(of: surface)
    }

    /// Reads zoom from the authority whose tree this window projects.
    private var paneChromeZoomedPane: Ubiquitty.Session.Layout.PaneID {
        if let drive = remoteSurface?.drive, remoteWorkspaceTab != Ubiquitty.Session.Layout.invalidTab {
            return drive.remoteWorkspaceZoomedPane(of: drive.remoteWorkspaceSurface)
        }
        return Self.windowModel?.zoomedPane(workspaceSurface) ?? Ubiquitty.Session.Layout.invalidPane
    }

    /// Drops the bars a rebuilt tree left behind.
    ///
    /// By the window rather than by the superview: re-mirroring the tree takes
    /// the whole old hierarchy out of the window in one piece, and every bar
    /// inside it keeps the split view it stood in as a superview. Left in the
    /// registry, those bars answer for their pane's id — and the memo is keyed
    /// by that id, so the detached one takes the write and the bar a reader
    /// can see compares equal and is skipped.
    private func pruneDetachedPaneChromes() {
        let held = paneChromes.count
        paneChromes.removeAll { $0.window == nil }
        guard paneChromes.count != held else { return }
        let live = Set(paneChromes.map(\.paneID))
        paneChromeInputs = paneChromeInputs.filter { live.contains($0.key) }
        paneStatusNews = paneStatusNews.filter { live.contains($0.key) }
        paneHeaderTagRuns = paneHeaderTagRuns.filter { live.contains($0.key) }
    }

    /// The chrome views this window built, restyled on every title refresh.
    /// Kept rather than found: the refresh runs on every screen update, and
    /// walking the pane host for them cost a recursion per delivery.
    private var paneChromes: [PaneChrome] = []

    /// What a pane bar is styled from: the weave's inputs and the styling.
    private struct PaneChromeInputs: Equatable {
        var weave: TitleWeaveFacts
        var isSelected: Bool
        var isWindowActive: Bool
        var foreground: UInt32
        var background: UInt32
        var isExpanded: Bool
        var isTranslucent: Bool
        var usesSystemTheme: Bool
        /// The system's contrast request, which the bake reads.
        var shouldIncreaseContrast: Bool
        /// Whether the window's panes live in more than one place, which puts
        /// each pane's host in its bar.
        var shouldNameHost: Bool
        /// The width the bar's title has, which its label is fitted to.
        var titleWidth: Int = 0
        /// The tags the bar's title leads with.
        var tagRun: TabTagMarkRun?
    }

    // What each bar was last styled from, by pane, compared before the weave
    // for the reason the tab's inputs are: the restyle runs on every screen
    // update, and the weave and the bake are what it costs.
    private var paneChromeInputs: [Int32: PaneChromeInputs] = [:]

    /// What a tab title is baked from: the weave's inputs and the styling.
    private struct TabTitleInputs: Equatable {
        var weave: TitleWeaveFacts
        var isSelected: Bool
        var isWindowActive: Bool
        var foreground: UInt32
        var background: UInt32
        var shouldIncreaseContrast: Bool
        var isNative: Bool
        // The size the title is baked at, which `[appearance] ui_font_scale`
        // moves. A key that carried only the text and the colours held the bake
        // whenever nothing but the size had changed, so a reader who enlarged
        // the chrome kept the strip they had until the next title change.
        var fontSize: CGFloat
        /// The tags the title leads with: a change of colour, icon, order or
        /// strength moves no other fact here.
        var tagRun: TabTagMarkRun?
        /// The width the tab's title may take in its pill, which the label is
        /// fitted to; zero with no strip to measure.
        var titleWidth: Int = 0
    }

    // What the tab title was last baked from, compared for the same reason as
    // the window title's inputs: the bake runs on every screen update.
    private var tabTitleInputs: TabTitleInputs?

    /// The theme colours a tab's title and accessory are inked from.
    ///
    /// One answer for both, so a mark and the title beside it are read
    /// against the same band.
    ///
    /// - Parameter surface: The pane the tab names.
    /// - Returns: The pane's foreground and the chrome tint the band derives
    ///   from, packed 0xRRGGBB; nil before the window has a tint.
    private func tabInkColors(of surface: TerminalSurface) -> (foreground: UInt32, background: UInt32)? {
        guard let tint = chromeTintSource() else { return nil }
        let background = Self.packed(
            red: UInt8(clamping: Int(tint.red * 255)),
            green: UInt8(clamping: Int(tint.green * 255)),
            blue: UInt8(clamping: Int(tint.blue * 255))
        )
        return (themeForeground(of: surface), background)
    }

    /// Bakes the tab's attributed title and writes it into the strip.
    ///
    /// The bake is the one the Objective-C shell hands AppKit, so a tab reads
    /// the same whichever shell opened it. AppKit copies the title into the
    /// strip with its colour mapped by main-window and selection state, so the
    /// write-back follows a bake, and an edge that moved the map without
    /// moving the bake asks for it on its own.
    package func refreshTabTitle() {
        refreshTabTitle(facts: nil, writesStripBack: false)
    }

    /// The tab's bake, against facts a caller already read.
    ///
    /// - Parameters:
    ///   - facts: The title surface's facts, read once by the caller; nil
    ///     reads them here.
    ///   - writesStripBack: Whether the strip takes the stored bake again even
    ///     where nothing was re-baked.
    func refreshTabTitle(facts: TitleWeaveFacts?, writesStripBack: Bool) {
        _ = Self.installsTitleRefit
        guard let window, let surface = activeSurface, let (foreground, background) = tabInkColors(of: surface) else {
            return
        }
        // The strip's focus fact is the group's: its selected window is the
        // one that can be main, so every tab of a backgrounded window recedes
        // together.
        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        // Compared before the weave, not after it: the weave and the bake are
        // the cost of this call, and a memo behind them saves only the write.
        let inputs = TabTitleInputs(
            weave: facts ?? titleWeaveInputs(for: surface),
            isSelected: selectedWindow === window,
            isWindowActive: WindowTabSelection.isGroupActive(window),
            foreground: foreground,
            background: background,
            shouldIncreaseContrast: SystemDisplayOptions.shouldIncreaseContrast,
            isNative: isUsingNativeTitlebar,
            fontSize: ChromeTypography.scaled(NSFont.smallSystemFontSize),
            // A tab that draws no mark still leads with its names, for a
            // screen reader, when it is placed to show tags the chip carries.
            tagRun: tabTagMarks.isEmpty && tabTagNames.isEmpty
                ? nil : TabTagMarkRun(marks: tabTagMarks, opacity: tagColorOpacity, spokenNames: tabTagNames),
            titleWidth: tabTitleRoom
        )
        guard tabTitleInputs != inputs else {
            if writesStripBack {
                requestStripWriteBack()
            }
            return
        }
        tabTitleInputs = inputs
        tabTitleBakesForTesting += 1
        let woven = wovenTitle(for: surface, as: .tab)
        window.tab.title = woven.title
        // The tag marks and the program's icon lead the title itself, so AppKit
        // centres them in the pill with it, as a site's icon and its page's
        // title: the tags first, then the program's icon, then the words.
        let bake = { (label: String, lead: String) -> NSAttributedString in
            TabTagMarks.title(
                ProcessIcons.title(
                    TabTitleStyling.attributedTitle(
                        label,
                        lead: lead,
                        markPrefix: woven.markPrefix,
                        isSelected: inputs.isSelected,
                        isWindowActive: inputs.isWindowActive,
                        foreground: foreground,
                        background: background,
                        usesNativeColors: self.isUsingNativeTitlebar,
                        fontSize: inputs.fontSize,
                        dimensions: woven.dimensions
                    ),
                    leadingWith: inputs.weave.processIconKey,
                    ground: NSColor(packedRGB: background)
                ),
                leadingWith: inputs.tagRun
            )
        }
        let whole = bake(woven.title, woven.lead)
        tabTitleFittingForTesting = (whole, woven.fitting.map(\.title))
        window.tab.attributedTitle = TabStripStyling.title(
            Self.fitted(whole, steps: woven.fitting, width: inputs.titleWidth, bake: bake),
            ownedBy: window
        )
        // The tab's tooltip is the whole tab's, so it answers wherever the
        // pointer rests on it: the full title, which the strip truncates, and
        // under it everything the program's status says. One tooltip, not
        // one for the title and a second over the mark — a 6-point dot was a
        // target the pointer kept missing, and two labels on one tab disagreed
        // about what hovering it says. Written with the bake, since the
        // status text's digest is one of the facts the bake is keyed on.
        //
        // The status is Core's whole text, not the few words a title has
        // room for: Core composes it, bounds it and removes what a program
        // must not put in a label, and the help tag wraps it over as many
        // lines as it needs.
        let tagLine = inputs.weave.tagNames.isEmpty ? "" : "Tagged \(inputs.weave.tagNames)"
        let statusHelp = inputs.weave.statusHelpDigest == 0 ? "" : surface.drive.statusHelpText()
        let toolTip = [window.tab.title, tagLine, statusHelp].filter { !$0.isEmpty }.joined(separator: "\n")
        if window.tab.toolTip != toolTip {
            window.tab.toolTip = toolTip
        }
        requestStripWriteBack()
    }

    /// Fits a tab's label again when the strip finds its pill holds a width
    /// other than the one the label was fitted to.
    private static let installsTitleRefit: Void = {
        TabStripStyling.titleWidthDidChange = { window, room in
            guard let controller = window.windowController as? TerminalWindowController else { return }
            controller.tabTitleRoom = Int(room.rounded(.down))
            controller.refreshTabTitle(facts: nil, writesStripBack: true)
        }
    }()

    /// The width the tab's title may take in its pill, as the strip's
    /// write-back measured it; zero before it has, which leaves the label
    /// whole.
    private var tabTitleRoom = 0

    /// The whole label and Core's shorter versions of it, as the last tab bake
    /// fitted them, for a scenario to judge the choice against.
    package private(set) var tabTitleFittingForTesting: (whole: NSAttributedString, steps: [String])?

    /// A label that fits its room as its title field draws it.
    ///
    /// The order is AppKit's own for a tab's title: the whole label at its
    /// spacing; then the whole label tightened, as the field tightens a title
    /// before it truncates one; then the longest of Core's shorter versions
    /// that fits either way, which give up the directory the label opens with
    /// and then the processes it closes with before the program's own title
    /// and the marks before it. The last is truncated in its middle only when
    /// even it does not fit, so its marks and its end both stay. Stamped with
    /// the room it was fitted to, so the strip can ask again when the room
    /// changes.
    ///
    /// - Parameters:
    ///   - whole: The whole label, baked.
    ///   - steps: Core's versions of it, longest first.
    ///   - width: The width the text may take; zero to leave the label whole.
    ///   - bake: Bakes one version and the directory it opens with.
    /// - Returns: The label to wear.
    private static func fitted(
        _ whole: NSAttributedString,
        steps: [(title: String, lead: String)],
        width: Int,
        bake: (String, String) -> NSAttributedString
    ) -> NSAttributedString {
        let room = CGFloat(width)
        var versions = [drawable(whole, fittedTo: room)]
        guard width > 0 else { return versions[0] }
        // Longest first, as far as the first that fits at its own spacing.
        var naturalFit: Int?
        var shorter = steps.dropFirst().makeIterator()
        while true {
            if versions[versions.count - 1].size().width <= room {
                naturalFit = versions.count - 1
                break
            }
            guard let step = shorter.next() else { break }
            versions.append(drawable(bake(step.title, step.lead), fittedTo: room))
        }
        // Back from there, the longer versions that fit once tightened. Each is
        // the one after it with more letters, which widen it by more than
        // tightening wins back, so the first that does not fit ends the run.
        var chosen = naturalFit ?? versions.count - 1
        var longer = (naturalFit ?? versions.count) - 1
        while longer >= 0, TabTitleStyling.drawsWhole(versions[longer], width: room) {
            chosen = longer
            longer -= 1
        }
        return versions[chosen]
    }

    /// A label as its title field draws it: tightened before it truncates,
    /// truncated in its middle, and stamped with the room it was fitted to.
    ///
    /// - Parameters:
    ///   - label: The baked label.
    ///   - room: The width it was fitted to; zero for none.
    /// - Returns: The label, restyled.
    private static func drawable(_ label: NSAttributedString, fittedTo room: CGFloat) -> NSAttributedString {
        let stamped = NSMutableAttributedString(attributedString: label)
        let all = NSRange(location: 0, length: stamped.length)
        let paragraph =
            (stamped.length > 0 ? stamped.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.allowsDefaultTighteningForTruncation = true
        stamped.addAttribute(.paragraphStyle, value: paragraph, range: all)
        stamped.addAttribute(TabStripStyling.fittedWidthKey, value: room, range: all)
        return stamped
    }

    /// Writes the stored bake back over AppKit's copy of it, now and over the
    /// next few turns.
    ///
    /// AppKit re-derives the pill's text from the tab's attributed title
    /// whenever it decides the selection or the main window moved, mapping an
    /// unselected title to its own dim grey; the write-back exists to stomp
    /// that, and only works if it runs after the remap. The remap is not
    /// delivered on a schedule this side can observe — for a main transfer
    /// between windows it can be a turn or more away — so the write is
    /// re-asserted rather than made twice. Re-asserting costs nothing when it
    /// changes nothing: the write skips a field that already holds the string.
    ///
    /// Each request writes now; a request while the chain runs extends it
    /// rather than starting a second one.
    internal func requestStripWriteBack() {
        // The native strip keeps AppKit's own colours, and a window showing no
        // strip has nothing to write into.
        guard !usesNativeTitlebar, let window, window.tabGroup?.isTabBarVisible == true else { return }
        TabStripStyling.restyleTitles(in: window)
        let isChainRunning = stripWriteBackTurnsOwed > 0
        stripWriteBackTurnsOwed = focusRestyleReassertTurns
        if !isChainRunning {
            runStripWriteBackChain()
        }
    }

    /// Runs the write-back again on each of the turns it still owes.
    private func runStripWriteBackChain() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isWindowClosed, let window = self.window, self.stripWriteBackTurnsOwed > 0 else {
                    self?.stripWriteBackTurnsOwed = 0
                    return
                }
                self.stripWriteBackTurnsOwed -= 1
                TabStripStyling.restyleTitles(in: window)
                if self.stripWriteBackTurnsOwed > 0 {
                    self.runStripWriteBackChain()
                }
            }
        }
    }

    /// Turns of the main queue the write-back still owes.
    private var stripWriteBackTurnsOwed = 0

    /// Re-bakes every tab of the group once a main change has settled, and
    /// repaints the strip for it.
    ///
    /// Every tab's title carries the window's focus fact, so the whole group
    /// re-bakes rather than this tab alone. AppKit re-maps the title's colour
    /// on the change itself, and the group's selection has moved by the next
    /// turn, so both run now for the window's own facts and again after the
    /// turn for the strip's.
    package func refreshTabGroupForFocusChange() {
        guard !isWindowClosed else { return }
        observeTabSelection()
        let refresh: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, !self.isWindowClosed, let window = self.window else { return }
            for tabWindow in window.tabGroup?.windows ?? [window] {
                let controller = tabWindow.windowController as? TerminalWindowController
                // Both titles, not just the label. A focus change is the one
                // edge every tab of the group is guaranteed to see, so it is
                // where a title that missed its own change event gets to
                // notice: the weave re-reads the process facts and the memo
                // answers on what they say now, not on what was last
                // delivered. Without this the label heals here and the window
                // title does not, so one names the shell while the other still
                // names the `login` that exec'd it.
                controller?.refreshTitles(writesStripBack: true)
                controller?.applyWindowTitleStyle()
                // Activation moves the progress tint between the accent and
                // the grey AppKit dims its own controls to, and it moves the
                // slot too: a window joining or leaving a tab group hands the
                // bar to the strip or takes it back.
                controller?.syncProgressChrome()
                controller?.refreshTabAccessory()
            }
            let selected = window.tabGroup?.selectedWindow ?? window
            (selected.windowController as? TerminalWindowController)?.tintTitlebar()
        }
        // Re-asserted for a few turns, not exactly twice.
        //
        // The bake is not the problem: the application-activation path never
        // re-bakes at all, it only writes the STORED bake back over AppKit's
        // copy, and that is what fixes a strip left dim. So the bake is right
        // and what is wrong is AppKit's own colour map, which re-derives the
        // pill's text from the tab's attributed title whenever it decides main
        // or selection moved. Our write-back exists to stomp that, and it only
        // works if it runs after the remap.
        //
        // Two fixed passes assumed the remap had landed within one turn. For a
        // main transfer BETWEEN windows it need not have, so both passes wrote
        // before AppKit recoloured and nothing was left to correct it — which
        // is exactly why switching applications fixed the strip and switching
        // windows did not. Re-asserting costs nothing when it changes nothing:
        // the write skips a field that already holds the right string.
        refresh()
        Self.reassertFocusRestyle(refresh, turns: focusRestyleReassertTurns)
    }

    /// Runs `refresh` again on each of the next `turns` turns of the main queue.
    ///
    /// The count rides the call rather than living in a captured `var`. A local
    /// function closing over a mutable counter has to be converted to a
    /// `@Sendable` block to be scheduled at all, and the compiler is right to
    /// warn about it: the counter would be shared mutable state reachable from
    /// a queue. Passed as a parameter it belongs to the hop that holds it, so
    /// there is nothing for two turns to share.
    ///
    /// The hop asserts the isolation it already has rather than hopping again:
    /// the block is dispatched to the main queue, so it is on the main actor by
    /// the time it runs, and a `Task { @MainActor in }` would only defer the
    /// same work by another turn — which is the one thing this loop must not do
    /// with a count that is already turn-based.
    ///
    /// - Parameters:
    ///   - refresh: The write-back to re-assert.
    ///   - turns: How many further turns to run it on. Zero ends the chain.
    private static func reassertFocusRestyle(_ refresh: @escaping @MainActor @Sendable () -> Void, turns: Int) {
        guard turns > 0 else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                refresh()
                reassertFocusRestyle(refresh, turns: turns - 1)
            }
        }
    }

    /// How many further turns the focus write-back re-asserts itself over.
    ///
    /// Enough to outlast AppKit's own colour map on a cross-window main
    /// transfer, which is not delivered on a schedule this side can observe.
    private var focusRestyleReassertTurns: Int { 4 }

    /// Latches the focused pane's caret solid across a window activation.
    ///
    /// AppKit hands a window key or main status before it restores a first
    /// responder, and closing a tab leaves the survivor with none, so a
    /// focus recompute taken against that window finds no responder and
    /// latches the caret hollow for a frame, the blink resuming mid-curve
    /// instead of at its solid first frame. Whether the responder may be
    /// restored is the shared component's rule: a find field that holds it
    /// keeps it. Idempotent, since makeFirstResponder answers a responder
    /// that already holds focus with no change and the activity note is a
    /// stamp.
    private func latchFocusOnActivation() {
        guard let window, let focused = focusedPaneSurface else { return }
        if SurfaceFocus.wantsFirstResponderRestore(inWindow: window) {
            window.makeFirstResponder(focused)
        }
        // The activation itself is the input the caret answers. The focus
        // recompute's own note covers only the arrival edge it can see, and
        // a switched-to tab whose responder never moved would otherwise
        // resume mid-blink.
        focused.noteUserActivity()
    }

    public func windowDidResignKey(_ notification: Notification) {
        refreshTabGroupForFocusChange()
        Self.refreshTabAccessoriesForOpenWindows()
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        refreshTitles(writesStripBack: true)
        refreshTabGroupForFocusChange()
        latchFocusOnActivation()
        clearUnseenActivityIfLookedAt()
        // The point a reorder is reliably visible from: AppKit offers no
        // notification for one, and this fires after the group has settled.
        // Cheap on the tabs whose number did not move — the presenter skips a
        // write that would change nothing.
        Self.refreshTabAccessoriesForOpenWindows()
    }

    /// View ▸ Keep on Top — hold this application's windows above others.
    ///
    /// - Parameter sender: The menu item, whose check mark follows the state.
    @objc
    public func toggleKeepOnTop(_ sender: Any?) {
        // Only this window is levelled, the one that asked. The
        // answer is remembered, so the windows that open next float with it.
        let isKeptOnTop = WindowLevelMemory.toggle(applyingTo: window.map { [$0] } ?? [])
        (sender as? NSMenuItem)?.state = isKeptOnTop ? .on : .off
    }

    public func windowDidBecomeMain(_ notification: Notification) {
        refreshTitles(writesStripBack: true)
        // A plain tab switch fires main reliably and key not always, so the
        // latch answers both.
        latchFocusOnActivation()
        clearUnseenActivityIfLookedAt()
        refreshTabGroupForFocusChange()
        // A tab attached to or detached from a group comes back main on a
        // re-hosted window.
        reassertWindowServerBlur()
    }

    public func windowDidResignMain(_ notification: Notification) {
        refreshTabGroupForFocusChange()
        // A backgrounded window has no pointer over it, so it has no hover
        // either: a plate left standing would pin a target the reader is no
        // longer near and cannot dismiss.
        showLinkPreview(nil)
    }

    public func windowDidChangeOcclusionState(_ notification: Notification) {
        refreshTitles(writesStripBack: true)
        if titleSurface?.isTitlePresentationVisible == true {
            refreshCloseSafetyIndicator()
        }
    }

    /// The theme's default foreground, the ink a tab title is baked in.
    ///
    /// - Parameter surface: The pane naming the window.
    /// - Returns: The foreground packed 0xRRGGBB, or Core's default before the
    ///   model exists.
    package func themeForeground(of surface: TerminalSurface) -> UInt32 {
        guard let terminal = surface.drive.borrowTerminal() else {
            return 0xC0C0C0
        }
        let foreground = terminal.palette.defaultForeground
        return Self.packed(
            red: UInt8(foreground.red >> 8),
            green: UInt8(foreground.green >> 8),
            blue: UInt8(foreground.blue >> 8)
        )
    }

    /// The theme's default background, the fill a pane's bar takes.
    ///
    /// A bar takes the plain terminal background, as the tab pills do: active
    /// against inactive reads from the title's own ink, so a second fill would
    /// be one more thing to keep in step with the theme.
    ///
    /// - Parameter surface: The pane whose bar is being filled.
    /// - Returns: The background packed 0xRRGGBB, or Core's default before the
    ///   model exists.
    internal func themeBackground(of surface: TerminalSurface) -> UInt32 {
        guard let terminal = surface.drive.borrowTerminal() else {
            return 0x101014
        }
        let background = terminal.palette.defaultBackground
        return Self.packed(
            red: UInt8(background.red >> 8),
            green: UInt8(background.green >> 8),
            blue: UInt8(background.blue >> 8)
        )
    }

    private static func packed(red: UInt8, green: UInt8, blue: UInt8) -> UInt32 {
        (UInt32(red) << 16) | (UInt32(green) << 8) | UInt32(blue)
    }

    /// Paints the window chrome with the terminal's own background.
    ///
    /// The window is one surface with the grid it contains. Everything the
    /// Metal layer does not cover — the rounding margin at the edges, the
    /// configured padding, the title row above — is drawn by AppKit, and
    /// AppKit's default is the system window colour. Against a themed grid that
    /// reads as a frame of a colour nobody chose, which is what a light strip
    /// down each side of a dark terminal is.
    ///
    /// Native leaves all of it alone: the setting exists for people who want
    /// the system's vibrant title row, and painting it would be ignoring them.
    package func applyChromeTheme(from snapshot: Ubiquitty.Runtime.RuntimeSnapshot? = nil) {
        guard let window else { return }
        // Every fact the paint reads, compared before any of it runs. This is
        // called on every screen update, so a comparison placed after the work
        // it is meant to skip saves only the writes — and the work is a
        // snapshot read per pane, a layer colour per pane, a walk of the title
        // row's view tree and a re-bake of the tab's label.
        let tint = chromeTintSource(from: snapshot)
        let inputs = ChromePaintInputs(
            red: tint?.red ?? 0,
            green: tint?.green ?? 0,
            blue: tint?.blue ?? 0,
            hasTint: tint != nil,
            isLetterbox: tint?.isLetterbox ?? false,
            isDark: tint?.isDark ?? false,
            themeForeground: activeSurface.map { themeForeground(of: $0) } ?? 0,
            usesNativeTitlebar: usesNativeTitlebar,
            hidesTitleBar: hidesTitleBar,
            isTranslucent: isTranslucent,
            chromeBackgroundOpacity: chromeBackgroundOpacity,
            usesDisplayP3: isTerminalColorSpaceDisplayP3,
            shouldIncreaseContrast: SystemDisplayOptions.shouldIncreaseContrast,
            paneSetGeneration: paneSetGeneration
        )
        // AppKit builds the titlebar container after the window is ordered in,
        // and full screen re-hosts it into a window of its own, so "the paint
        // landed" is a question about the view that was painted and not about
        // the colour. A window with no title bar at all expects none.
        let expectsContainer = window.styleMask.contains(.titled)
        let container = expectsContainer ? window.titlebarContainer : nil
        let isTitleRowSettled = container === paintedTitlebarContainer && (container != nil || !expectsContainer)
        let isElsewhereSettled =
            paintedChromeInputs == inputs && paneHost.layer === paintedPaneHostLayer
            && buildIdentityBadge === inkedBuildBadge
        if isElsewhereSettled, isTitleRowSettled {
            return
        }
        if isElsewhereSettled {
            // Only the title row is unsettled — the container arrived late, or
            // the window was re-hosted and built another. The rest of the
            // chrome already carries these inputs.
            tintTitlebar()
            paintedTitlebarContainer = expectsContainer ? window.titlebarContainer : nil
            return
        }
        chromeRepaintsForTesting += 1
        paintPaneGround(tint)
        if usesNativeTitlebar || isTranslucent {
            // Hand it back to AppKit: the setting exists for people who want
            // the system's vibrant title row, and painting it would be
            // ignoring them.
            window.titlebarAppearsTransparent = isTranslucent
            window.backgroundColor = isTranslucent ? .clear : .windowBackgroundColor
            // Native material and title ink share the terminal's polarity,
            // including palette themes made translucent by configuration.
            window.appearance =
                isTranslucent || usesSystemTheme
                ? NSAppearance(named: tint?.isDark == true ? .darkAqua : .aqua)
                : nil
            tintTitlebar()
            buildIdentityBadge?.applySystemInk()
        } else if let tint {
            if let badge = buildIdentityBadge, let surface = activeSurface {
                badge.applyInk(themeForeground: themeForeground(of: surface), wash: Self.packed(tint))
            }
            // Transparent titlebar over a themed backing, rather than a
            // titlebar painted directly: the system still draws the title text
            // and the traffic lights, and they compose over whatever the
            // window's backing holds.
            window.titlebarAppearsTransparent = true
            // A translucent window keeps a clear backing whatever the theme
            // says, or the opaque fill suppresses the effect the translucency
            // exists for. A letterbox fill is the exception: the bars it
            // matches are opaque, so a see-through title row over them would
            // read as a seam.
            window.backgroundColor =
                isTranslucent && !tint.isLetterbox
                ? .clear
                : terminalColor(red: CGFloat(tint.red), green: CGFloat(tint.green), blue: CGFloat(tint.blue))
            // The appearance follows the background's lightness so the
            // system-drawn title and traffic lights flip to the polarity
            // legible on it.
            window.appearance = NSAppearance(named: tint.isDark ? .darkAqua : .aqua)
            tintTitlebar()
            // The tab's ink derives from the same colour; a theme that moved
            // re-bakes it here, since the title's own inputs have not changed.
            refreshTabTitle()
            applyThemeToFindBar()
        }
        paintedChromeInputs = inputs
        paintedPaneHostLayer = paneHost.layer
        inkedBuildBadge = buildIdentityBadge
        paintedTitlebarContainer = expectsContainer ? window.titlebarContainer : nil
    }

    /// Every fact the chrome's paint reads.
    ///
    /// One left out is a change that cannot reach the window: the memo answers
    /// first and the paint never runs. The apply paths drop the memo outright
    /// rather than relying on this being complete.
    private struct ChromePaintInputs: Equatable {
        var red: Float
        var green: Float
        var blue: Float
        /// Whether a surface could name a theme at all. A window with none
        /// paints nothing and must repaint once it has one.
        var hasTint: Bool
        var isLetterbox: Bool
        var isDark: Bool
        var themeForeground: UInt32
        var usesNativeTitlebar: Bool
        var hidesTitleBar: Bool
        var isTranslucent: Bool
        var chromeBackgroundOpacity: CGFloat
        var usesDisplayP3: Bool
        var shouldIncreaseContrast: Bool
        /// Bumped whenever a pane joins or leaves, because the ground is
        /// painted per pane.
        var paneSetGeneration: Int
    }

    /// Forgets what the chrome was painted from, so the next pass repaints.
    ///
    /// Every apply path calls this rather than trusting the key to carry the
    /// setting it moved: a missed input is stale chrome on a window the reader
    /// just changed, and the key is compared on a path that runs per screen
    /// update where dropping it is free.
    internal func invalidateChromePaintMemo() {
        paintedChromeInputs = nil
    }

    // What the chrome was last painted from. The palette carries no change
    // notification, so the chrome is re-derived on screen updates and this is
    // what stops each one repainting the title row, re-resolving the
    // appearance and writing a layer colour into every pane.
    private var paintedChromeInputs: ChromePaintInputs?

    /// The titlebar container the last paint reached, weakly: a container
    /// AppKit built late, or rebuilt for a re-hosted window, is a different
    /// view and the row it draws is unpainted.
    private weak var paintedTitlebarContainer: NSView?

    /// The pane host's layer as it was painted, weakly, for the same reason.
    private weak var paintedPaneHostLayer: CALayer?

    /// The badge whose ink the last paint set, weakly.
    private weak var inkedBuildBadge: BuildIdentityBadge?

    /// Bumped whenever the pane map changes, so the ground is painted for the
    /// panes the window now holds.
    private var paneSetGeneration = 0

    /// Re-weaves every title an open window shows after a `[title]` composition
    /// change: the window's row and its components, the tab's label and
    /// tooltip, and each pane's header.
    ///
    /// The title memos compare the facts a weave reads — the directory, the
    /// process, a program's status — and not the composition that decides
    /// which of them show, so a switch that moves while every fact stands still
    /// would be answered "unchanged". The memos are dropped first for that
    /// reason, and the weave then runs against the switch as it now stands.
    public static func applyTitleCompositionToOpenWindows() {
        for controller in spawnedControllers {
            controller.titleInputs = nil
            controller.tabTitleInputs = nil
            controller.paneChromeInputs.removeAll()
            controller.refreshTitles()
        }
    }

    /// Re-runs the chrome after an `[appearance] titlebar_style` change, so a
    /// live window flips between the themed and the native title bar without a
    /// restart. The style is re-read from the config, and the painted-colour
    /// memo dropped so the new style repaints rather than comparing equal.
    @objc
    public static func applyTitlebarStyleToOpenWindows() {
        // The launch fold, which is what ``applyWindowAppearance`` reads the
        // style from: one derivation, so a window opened after the change and
        // a window flipped by it cannot disagree about which style is set.
        let launch = Ubiquitty.Preferences.Effective.launchSettings()
        for controller in spawnedControllers {
            controller.usesNativeTitlebar = launch.titlebarStyle == .Native
            controller.window.map { TabStripStyling.forgetTitlebar(of: $0) }
            controller.paintedChromeInputs = nil
            controller.applyChromeTheme()
            // The native strip takes the system's label colours and AppKit's
            // own map; the themed one takes Core's ink and the write-back.
            controller.refreshTabTitle()
        }
    }

    /// Re-reads the window facts a settings change can move, on every open
    /// Swift-shell window: the resize snap, the folder icon in the title, and
    /// the frame's corner shape.
    ///
    /// These are held per window rather than per frame, so unlike the style
    /// and the typography there is nothing a redraw would pick them up from.
    @objc
    public static func applyWindowChromeToOpenWindows() {
        let launch = Ubiquitty.Preferences.Effective.launchSettings()
        for controller in spawnedControllers {
            controller.snapsWindowResize = launch.shouldSnapWindowResize
            // The icon is read where the title is built, so rebuilding the
            // title is how the setting reaches the window. The memo holds the
            // facts, not the configuration, and a setting moves none of them —
            // so it is dropped here or the rebuild returns the old string.
            controller.titleInputs = nil
            controller.tabTitleInputs = nil
            controller.paneChromeInputs.removeAll()
            controller.refreshTitles()
            controller.applyWindowCornerShape()
        }
    }

    /// Every surface this window projects, whatever authority owns the
    /// topology behind it: the model's panes, the tmux host's, a hosted
    /// workspace's mirror, and a hosted root that stands outside all three
    /// maps.
    ///
    /// Deduplicated by identity: a remote window's root is also the mirror's
    /// first pane once a layout has named it.
    package var projectedSurfaces: [TerminalSurface] {
        var projected = Array(surfaces.values) + Array(tmuxSurfaces.values) + Array(remotePaneSurfaces.values)
        if let remoteSurface, !projected.contains(where: { $0 === remoteSurface }) {
            projected.append(remoteSurface)
        }
        return projected
    }

    /// Lifts a surface's scroll bar clear of the window's bottom corner.
    ///
    /// A bar starts flush with the edge, so this runs where a surface joins
    /// the window as well as where the shape moves: a window opened under a
    /// rounded corner would otherwise keep its knob in the curve until a
    /// setting happened to be touched.
    ///
    /// - Parameter surface: The surface whose bar is being placed.
    func applyScrollerBottomInset(to surface: TerminalSurface) {
        surface.terminalScroller.setBottomInsetPoints(SquareBottomWindow.bottomCornerClearanceInPoints)
    }

    /// Re-samples the window's frame mask, and moves every scroller off the
    /// corner it has.
    ///
    /// The mask itself reads the setting, so nothing about it needs telling —
    /// but AppKit samples it once and caches it, and only the private
    /// `-_cornerMaskChanged` asks for another. The shadow follows the mask, so
    /// it is invalidated with it.
    private func applyWindowCornerShape() {
        for surface in projectedSurfaces {
            applyScrollerBottomInset(to: surface)
        }
        guard let window else { return }
        let resample = NSSelectorFromString("_cornerMaskChanged")
        if window.responds(to: resample) {
            window.perform(resample)
        }
        window.invalidateShadow()
    }

    /// Hides or restores the title bar on every open Swift-shell window,
    /// after an `[appearance] hide_title_bar` change.
    @objc
    public static func applyHideTitleBarToOpenWindows() {
        let isHidden = Ubiquitty.Preferences.Effective.launchSettings().shouldHideTitleBar
        for controller in spawnedControllers {
            controller.applyHideTitleBar(isHidden)
            controller.window.map { TabStripStyling.forgetTitlebar(of: $0) }
            controller.paintedChromeInputs = nil
            controller.applyChromeTheme()
        }
    }

    /// Hides or restores this window's title bar.
    ///
    /// Symmetric, so the setting can be turned back off on a live window: a
    /// hide that only ever inserts leaves a window that was chromeless once
    /// chromeless for good. The composite itself is
    /// ``ChromelessWindowChrome``, which every window kind applies, so none
    /// can leave different pieces of a title row standing.
    ///
    /// - Parameter isHidden: Whether the title bar is hidden.
    private func applyHideTitleBar(_ isHidden: Bool) {
        guard let window else { return }
        hidesTitleBar = isHidden
        ChromelessWindowChrome.apply(isHidden, to: window)
        if inspectorSplit != nil {
            window.styleMask.insert(.fullSizeContentView)
            terminalSafeTop?.isActive = false
            terminalFullTop?.isActive = false
            terminalSafeTop?.isActive = !isHidden
            terminalFullTop?.isActive = isHidden
            (inspectorItem?.viewController as? TerminalInspectorViewController)?.hidesTitleBar = isHidden
            window.contentView?.layoutSubtreeIfNeeded()
        }
        if isHidden {
            // The theming path's field, set here for its reason: a title row
            // the body grows up under must not paint a band of its own over
            // the grid.
            window.titlebarAppearsTransparent = true
        }
        // No title bar means no proxy icon — AppKit would float it at the
        // content's top-left, over the first row — and the grid meets the
        // frame's top edge, so it takes the inset sized for that rather than
        // the one that stood clear of a title row.
        updateRepresentedURL()
        applyContentTopInset()
        // The window's band had the title row for a home, or now has one.
        syncPaneProgressBands()
    }

    /// Feeds every pane's renderer the top inset this window's chrome asks
    /// for, and lays the grids out under it: every pane the window projects,
    /// a hosted workspace's and a tmux window's as well as the model's.
    ///
    /// Which inset that is comes from ``ChromelessWindowChrome``, the one
    /// place either shell reads it, and the relayout is here because the
    /// window frame has not moved: hiding the title row changes the body's
    /// height without a resize notification to carry the change.
    ///
    /// Panes share their window's renderer, so the first pane to find the
    /// inset stale moves it for its siblings too, and each of them still fits
    /// its own grid under the new inset.
    private func applyContentTopInset() {
        let top = ChromelessWindowChrome.contentTopPadding(isChromeless: hidesTitleBar, configuration: windowRenderConfiguration)
        var movedRenderers = Set<ObjectIdentifier>()
        for surface in projectedSurfaces {
            guard let renderer = surface.renderer as? SurfaceRenderer else { continue }
            let identity = ObjectIdentifier(renderer)
            if renderer.style.paddingTopPoints != top {
                renderer.style.paddingTopPoints = top
                movedRenderers.insert(identity)
            }
            if movedRenderers.contains(identity) {
                surface.restyle()
            }
        }
    }

    /// The colour every chrome surface tints to, and what it came from.
    ///
    /// One source, so the window's backing, the title row and the tab band
    /// cannot disagree about what colour the chrome is: the DECSET 7402
    /// Color-letterbox fill while a fullscreen-content application holds one,
    /// and the theme background otherwise. Read off the same model state the
    /// renderer gates the content fill on, so the bars and the chrome adopt
    /// the fill together and revert together.
    ///
    /// - Returns: The tint, or nil when the window has no surface to read.
    /// The chrome band's colour, for a piece of chrome outside this file.
    ///
    /// The band the tab strip, the inactive pane bars and the find bar all
    /// wear, so a window's chrome reads as one surface rather than as pieces
    /// that happen to be adjacent.
    ///
    /// - Returns: The colour, or nil before a surface can name a theme.
    package func chromeBandColor() -> NSColor? {
        guard let tint = chromeTintSource() else { return nil }
        return terminalColor(red: CGFloat(tint.red), green: CGFloat(tint.green), blue: CGFloat(tint.blue))
    }

    /// The colour every chrome surface tints to.
    ///
    /// Core's fold over the pane's published snapshot
    /// (`Runtime::chromeTint`), so the window's backing, the title row, the
    /// tab band and the pane bars cannot disagree about what colour the chrome
    /// is, and neither can the two shells. Off the snapshot rather than the
    /// model, because this is asked on every screen update and the model's
    /// lock is the one the parser holds all flood long.
    ///
    /// - Parameter snapshot: The snapshot to read, or nil to take one.
    /// - Returns: The tint, or nil when the window has no surface to read.
    private func chromeTintSource(from snapshot: Ubiquitty.Runtime.RuntimeSnapshot? = nil) -> Ubiquitty.Runtime.ChromeTint? {
        guard let surface = activeSurface else { return nil }
        return Ubiquitty.Runtime.chromeTint(snapshot ?? surface.drive.readSnapshot())
    }

    /// A chrome tint packed 0xRRGGBB, each channel rounded to the byte it was
    /// read from.
    ///
    /// - Parameter tint: The tint to pack.
    /// - Returns: The packed triple.
    private static func packed(_ tint: Ubiquitty.Runtime.ChromeTint) -> UInt32 {
        let byte = { (channel: Float) in UInt32(UInt8(clamping: Int((channel * 255).rounded()))) }
        return (byte(tint.red) << 16) | (byte(tint.green) << 8) | byte(tint.blue)
    }

    /// What the title row shows beneath its text, as one colour: what a tag's
    /// translucent fill composites over.
    ///
    /// A loud tag's wash, where one stands. A translucent window's row is the
    /// theme's tint at the window's background opacity over the material
    /// behind it, the system's window background of the tint's polarity
    /// standing in for a desktop no one can read back. A native row is the
    /// system's window background, which resolves under the appearance it is
    /// drawn in. Any other row is the theme's tint.
    ///
    /// - Returns: The ground.
    func titleRowGround() -> NSColor {
        if let loudTagTint {
            return loudTagTint
        }
        return untaggedTitleRowGround()
    }

    /// What the title row shows beneath its text with no loud tag: the ground
    /// a loud tag's wash is mixed into.
    ///
    /// - Returns: The ground.
    func untaggedTitleRowGround() -> NSColor {
        let tint = chromeTintSource()
        if isTranslucent, let tint, let material = NSAppearance(named: tint.isDark ? .darkAqua : .aqua) {
            // The same mix a tag's own fill takes over the row, with the
            // tint's strength in the tag's place.
            let over = TitlebarTagStyle(
                opacity: tint.isLetterbox ? 1 : chromeBackgroundOpacity,
                ground: .windowBackgroundColor
            )
            return TitlebarTagChip.compositedFill(
                terminalColor(red: CGFloat(tint.red), green: CGFloat(tint.green), blue: CGFloat(tint.blue)),
                style: over,
                appearance: material
            )
        }
        guard let tint, !usesNativeTitlebar else {
            return .windowBackgroundColor
        }
        return terminalColor(red: CGFloat(tint.red), green: CGFloat(tint.green), blue: CGFloat(tint.blue))
    }

    /// How the title row lays its tags' colours down now: the configured
    /// strength, over the row's ground, which a pill's ink is chosen against
    /// on every kind of row.
    ///
    /// - Returns: The style.
    func resolvedTitleRowTagStyle() -> TitlebarTagStyle {
        TitlebarTagStyle(opacity: tagColorOpacity, ground: titleRowGround())
    }

    /// Hands the host chip and the markers the row's tag style again when the
    /// row's ground or ink moved under them, as a theme or translucency change
    /// moves them; both repaint the row through ``tintTitlebar()``.
    ///
    /// Leaves a row whose style is unchanged alone, since this runs on every
    /// repaint of the title row.
    func refreshTitleRowTagStyle() {
        let style = resolvedTitleRowTagStyle()
        guard style != titleRowTagStyle else { return }
        titleRowTagStyle = style
        proxyIconReveal?.setTagStyle(style)
        if hostChipTag != nil {
            refreshHostChip()
        }
    }

    /// Paints the titlebar container and the tab band, or hands both back.
    ///
    /// `titlebarAppearsTransparent` alone does not put the theme in the title
    /// row. The container keeps its own `NSVisualEffectView`, and that
    /// material sits in front of the window's backing: left in place it shows
    /// the desktop through the title row while the content rect below carries
    /// the theme, which is the title row reading as transparent. So the
    /// container is painted directly and the material hidden — and both are
    /// undone for a native title bar, where the system's vibrant row is the
    /// whole point of the setting.
    func tintTitlebar() {
        guard let window, let container = window.titlebarContainer else { return }
        // Every restyle of the row may move the ground its tags are drawn
        // over.
        defer { refreshTitleRowTagStyle() }
        container.wantsLayer = true
        // Chromeless wins over both titlebar styles. A hidden title bar gives
        // the window a full-size content view, so the Metal body reaches up
        // through the title row: anything painted over the container covers
        // terminal cells with a strip, and AppKit's material over them is what
        // hiding the title bar was asking to be rid of. Clear rather than
        // unset — the body showing through is the row. No tab strip to tint
        // either; the band went with the row.
        guard !hidesTitleBar else {
            container.layer?.backgroundColor = NSColor.clear.cgColor
            visualEffectView(in: container)?.isHidden = true
            return
        }
        // A loud tag washes the whole row, whatever the theme or the titlebar
        // style: it is the signal for a window on a machine that matters,
        // and it has to register before anything is read.
        if let loudTagTint {
            container.layer?.backgroundColor = loudTagTint.withAlphaComponent(0.85).cgColor
            visualEffectView(in: container)?.isHidden = true
            return
        }
        if isTranslucent && windowServerBlurRadius > 0 {
            if titlebarBlurBackdrop?.superview !== container {
                titlebarBlurBackdrop?.removeFromSuperview()
                titlebarBlurBackdrop = WindowBlurBackdrop.install(under: container)
            }
            container.layer?.backgroundColor = nil
            if let nativeEffect = container.subviews.first(where: { $0 !== titlebarBlurBackdrop && $0 is NSVisualEffectView }) {
                nativeEffect.isHidden = true
            }
            titlebarBlurBackdrop?.setShown(windowServerBlurRadius > 0)
            if let tint = chromeTintSource() {
                titlebarBlurBackdrop?
                    .setTintColor(
                        terminalColor(
                            red: CGFloat(tint.red),
                            green: CGFloat(tint.green),
                            blue: CGFloat(tint.blue),
                            alpha: chromeBackgroundOpacity
                        )
                    )
                titlebarBlurBackdrop?.appearance = NSAppearance(named: tint.isDark ? .vibrantDark : .vibrantLight)
            }
            if #available(macOS 26.0, *) { TabStripStyling.useTransparentMaterial(container: container) }
            return
        }
        titlebarBlurBackdrop?.removeFromSuperview()
        titlebarBlurBackdrop = nil
        guard !usesNativeTitlebar || isTranslucent else {
            container.layer?.backgroundColor = nil
            visualEffectView(in: container)?.isHidden = false
            if #available(macOS 26.0, *) {
                TabStripStyling.clear(container: container)
            }
            return
        }
        guard let tint = chromeTintSource() else { return }
        // While the window is translucent the title row carries the body's own
        // alpha, so the two read as one vibrant surface rather than an opaque
        // strip above a see-through grid. A letterbox fill overrides it: the
        // bars it matches are opaque.
        let alpha: CGFloat =
            isTranslucent && !tint.isLetterbox
            ? chromeBackgroundOpacity
            : 1
        let red = CGFloat(tint.red)
        let green = CGFloat(tint.green)
        let blue = CGFloat(tint.blue)
        // A plain layer colour: Core Animation premultiplies it on its encoded
        // components, and the Metal body stores its cells and its clear the
        // same way, so the title row and the body composite to one surface. A
        // colour compensated for a body premultiplied in linear light is white
        // at this alpha for a light theme, and reads as a pale strip.
        container.layer?.backgroundColor =
            terminalColor(red: red, green: green, blue: blue, alpha: alpha).cgColor
        visualEffectView(in: container)?.isHidden = true

        if #available(macOS 26.0, *) {
            if isTranslucent {
                TabStripStyling.useTransparentMaterial(container: container)
            } else {
                TabStripStyling.apply(container: container, window: window, usesNativeTitleColors: isUsingNativeTitlebar)
            }
        }
    }

    /// The vibrancy material inside a titlebar container.
    ///
    /// AppKit's own material only. The window's accessory bar is a visual
    /// effect view too — it borrows the titlebar material's compositing
    /// environment for its indicators — and it sits in the same container, so a
    /// search that took the first effect view it met hid the whole bar the
    /// moment a theme tinted the row after the bar was built, and the host
    /// chip, the clipboard badge and the secure-input lock went with it. A host
    /// window always meets this: its tint arrives with its first frame.
    ///
    /// - Parameter container: The container to search.
    /// - Returns: The material view, or nil when the container carries none.
    private func visualEffectView(in container: NSView) -> NSView? {
        if container is ChromeAccessoryBar {
            return nil
        }
        if container is NSVisualEffectView {
            return container
        }
        for subview in container.subviews {
            if let found = visualEffectView(in: subview) {
                return found
            }
        }
        return nil
    }

    /// Spawns a sibling session as a native tab — AppKit routes ⌘T here
    /// because the window's tabbing mode prefers tabs.
    ///
    /// - Parameter sender: Ignored.
    override public func newWindowForTab(_ sender: Any?) {
        // A hosted workspace's tabs are the host's: the host mints the tab
        // and its pane, and the layout that follows opens the window.
        // A request the session cannot send yet, before its first layout or
        // while an earlier tab, split or close awaits the host's answer, is
        // the AppKit beep: the command was heard and cannot be carried out now.
        if let root = remoteSurface, root.drive.remoteWorkspaceTab != Ubiquitty.Session.Layout.invalidTab {
            if !root.drive.remoteWorkspaceAddTab() {
                NSSound.beep()
            }
            return
        }
        // The new tab starts where the active one is, which is Core's resolved
        // answer for this pane and not a directory the shell reads for itself
        // (Ubiquitty::paneDirectory): a shell with no integration configured
        // still hands its tab the folder it is in.
        // Through the drive, which brackets the read with the model lock; the
        // borrow read a string the ingest thread rewrites in place.
        let inherited = activeSurface?.drive.currentDirectory() ?? ""
        guard let window, let sibling = Self.spawn(inheritingDirectory: inherited, as: .tab),
            let siblingWindow = sibling.window
        else {
            return
        }
        // The sibling was spawned as a window of its own, at the launch grid
        // and the remembered frame. A tab has no frame of its own: it joins
        // at the host's, and a group handed a newcomer of another size can
        // settle on the newcomer's — which moves the window the reader was
        // working in.
        siblingWindow.setFrame(window.frame, display: false)
        window.addTabbedWindow(siblingWindow, ordered: .above)
        siblingWindow.makeKeyAndOrderFront(nil)
        // A window that opens without focus gets no main change to restyle
        // the group for the new selection, and AppKit moves the strip to its
        // host a turn after the tab joins: restyle now and once more after
        // the turn.
        sibling.refreshTabGroupForFocusChange()
    }

    // MARK: - Splits

    /// Splits the focused pane into two columns — the View menu's ⌘D.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func splitRight(_ sender: Any?) {
        splitFocusedPane(.Vertical)
    }

    /// Splits the focused pane into two rows — the View menu's ⇧⌘D.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func splitDown(_ sender: Any?) {
        splitFocusedPane(.Horizontal)
    }

    /// The hosted pane a verb goes to directly: the key surface when it
    /// belongs to a tmux or remote map rather than the model. Its session
    /// resolves the verb against its own authority; there is no local
    /// topology work behind it.
    private var hostedActiveSurface: TerminalSurface? {
        guard let responder = activeSurface else {
            return nil
        }
        return paneID(of: responder) == nil ? responder : nil
    }

    private func splitFocusedPane(_ orientation: Ubiquitty.Panes.Orientation) {
        if let hosted = hostedActiveSurface {
            _ = hosted.drive.requestPaneVerb(orientation == .Vertical ? .splitBeside : .splitBelow)
            return
        }
        guard let model = Self.windowModel else {
            return
        }
        // The model resolves the verb end to end — the backend consult, the
        // topology mutation, the session mint with its launched shell. The
        // new pane opens at the launch grid and immediately refits to the
        // half its view lands in; only the view is this side's.
        let launch = Ubiquitty.Preferences.Effective.launchSettings()
        let result = model.splitFocusedPane(workspaceSurface, orientation)
        guard result.outcome == .localActionRequired, let session = model.session(result.createdPane) else {
            return
        }
        let sibling = TerminalSurface(drive: RuntimeDrive(over: session), rows: launch.rows, columns: launch.columns)
        sibling.renderer = surfaceRenderer
        if let bridge {
            sibling.observer = bridge
        }
        if isTranslucent {
            sibling.metalLayer.isOpaque = false
        }
        surfaces[result.createdPane] = sibling
        applyAutomaticTheme(to: [sibling])
        hostCellMetricChanges(of: sibling)
        rebuildPaneLayout()
        window?.makeFirstResponder(sibling)
        // Splitting moves the report between slots, so the window's own band
        // steps aside now rather than at the next thing a pane says.
        syncProgressChrome()
        refreshCloseSafetyIndicator()
    }

    /// A surface's shell exited. A session launched to run one program ends
    /// with it: the model closes its pane, and the last pane closes the
    /// window. Every other session outlives its child: the pane stays up with
    /// everything the shell printed, because closing it would discard
    /// scrollback nobody asked to lose. A remote window closes with its one
    /// detached session, since the host owns everything behind it, and a
    /// hosted pane's end is the host's to lay out.
    ///
    /// Which of the two a local session is is Core's, recorded on the session
    /// from the launch it was given. It is asked of the surface and not of the
    /// app: a process-wide answer closes the wrong window as soon as a second
    /// one is open beside the one that named a program.
    ///
    /// - Parameter surface: The surface whose session ended.
    func surfaceDidExit(_ surface: TerminalSurface) {
        guard !isWindowClosed else { return }
        if surface === remoteSurface,
            surface.drive.remoteWorkspaceCloseOutcome == .Accepted
        {
            isClosingWithHostTab = true
            dismissPastePushForRemoteClose()
            close()
            return
        }
        if promoteRemoteAnchor(after: surface) {
            return
        }
        let isHosted = surface === remoteSurface || remotePaneSurfaces.values.contains(where: { $0 === surface })
        guard isHosted || surface.drive.doesSessionEndWithChild else {
            // The pane keeps its session, its scrollback and its place. Core's
            // ingest loop ended with the stream, so nothing drains the line any
            // more and nothing typed into it reaches a reader; what the shell
            // left on the grid and in history stays scrollable and copyable.
            // The safety indicator is refreshed because a window whose job
            // ended is not the window that was holding one.
            refreshCloseSafetyIndicator()
            // Core named the end on its own thread and dropped the process
            // segments there; the STATUS only becomes readable once the child
            // is reaped, which is after the end-of-file that raised the end.
            // Collecting it here is what turns "exited" into "exited 1", and
            // the refresh is what puts that in front of a reader.
            surface.drive.collectSessionExitStatus()
            refreshTitles()
            applyLocalExitPolicy(to: surface)
            return
        }
        closePane(surface)
    }

    /// Applies the profile's local exit choice after collecting the child's status.
    ///
    /// - Parameter surface: The ended surface, retained until any replacement is ready.
    private func applyLocalExitPolicy(to surface: TerminalSurface) {
        guard let model = Self.windowModel, let pane = paneID(of: surface) else { return }
        let profile = Ubiquitty.Preferences.resolvedProfile(Ubiquitty.Preferences.values().pointee, std.string(appliedProfileName))
        let token = profile.processExit.value.map { String($0) } ?? "keep_output"
        let behavior = token.withCString { Ubiquitty.Session.processExitBehavior(std.string_view($0)) }
        Task { @MainActor [weak self, weak surface] in
            guard let self, let surface else { return }
            var action = model.processExitAction(pane, behavior)
            for _ in 0..<50 where action == .awaitStatus {
                try? await Task.sleep(for: .milliseconds(100))
                guard !isWindowClosed, surfaces[pane] === surface else { return }
                action = model.processExitAction(pane, behavior)
            }
            guard !isWindowClosed, surfaces[pane] === surface else { return }
            switch action {
            case .close:
                closePane(surface)
            case .restart:
                try? await Task.sleep(for: .seconds(1))
                guard !isWindowClosed, surfaces[pane] === surface else { return }
                guard model.restartEndedPane(pane), let session = model.session(pane) else {
                    presentProcessRestartFailure("The process couldn’t be started. Its previous output has been kept.")
                    return
                }
                let grid = surface.drive.readSnapshot()
                let replacement = TerminalSurface(drive: RuntimeDrive(over: session), rows: Int(grid.rows), columns: Int(grid.columns))
                replacement.renderer = surface.renderer
                replacement.observer = bridge
                replacement.metalLayer.isOpaque = surface.metalLayer.isOpaque
                surface.observer = nil
                surfaces[pane] = replacement
                hostCellMetricChanges(of: replacement)
                rebuildPaneLayout()
                if model.focusedPane(workspaceSurface) == pane { window?.makeFirstResponder(replacement) }
                refreshTitles()
                refreshCloseSafetyIndicator()
            case .restartLimitReached:
                presentProcessRestartFailure(
                    "The process exited repeatedly. Automatic restart has stopped, and its last output has been kept."
                )
            case .keepOutput, .awaitStatus:
                break
            }
        }
    }

    /// Explains why automatic restart stopped without discarding the terminal.
    ///
    /// - Parameter detail: The launch or crash-loop failure.
    private func presentProcessRestartFailure(_ detail: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Process Restart Stopped"
        alert.informativeText = detail
        alert.addButton(withTitle: "Keep Output")
        alert.beginSheetModal(for: window)
    }

    /// Closes a surface's pane: the model drops it, the last one takes the
    /// window with it. A remote window closes whole, and a hosted pane is
    /// left to the host's next layout.
    ///
    /// The one body behind a shell exit that ends its session and the View
    /// menu's Close Pane, so the two cannot drift; the lifetime question is
    /// the exit's alone and is asked before this.
    ///
    /// - Parameter surface: The surface whose pane closes.
    private func closePane(_ surface: TerminalSurface) {
        guard !refuseCloseForLocalAdoptionIfNeeded() else { return }
        if surface === remoteSurface {
            dismissPastePushForRemoteClose()
            close()
            return
        }
        // A pane of the hosted workspace ended: the host takes it out of the
        // tree and the next layout says what the window is now.
        if remotePaneSurfaces.values.contains(where: { $0 === surface }) {
            return
        }
        guard let model = Self.windowModel, let paneID = paneID(of: surface) else {
            return
        }
        // The pane's session goes with it, and with the session the models
        // every window it hosts reads: those windows close first.
        if surface.drive.isHostingWindows {
            endHostedWindows(from: surface)
        }
        let result = model.closePane(workspaceSurface, paneID)
        guard result.outcome == .localActionRequired else {
            return
        }
        surfaces.removeValue(forKey: paneID)
        if result.removedSurface != Ubiquitty.Session.Layout.invalidSurface {
            // The model ended the surface with its last pane — the window
            // goes with it.
            close()
            return
        }
        rebuildPaneLayout()
        if let focused = focusedSurface {
            window?.makeFirstResponder(focused)
        }
        // The pane count is one of the facts the slots are partitioned by, so
        // a split collapsing to one pane hands its report back to the window's
        // own band — and does so now rather than at the survivor's next report.
        syncProgressChrome()
        refreshCloseSafetyIndicator()
    }

    /// Shows what a click on the hovered link would open, or takes the plate
    /// away.
    ///
    /// The target is turned into the line a reader sees by ``LinkOpener``, the
    /// component every window kind resolves through, so none can
    /// disagree about what a `file:` URI is called. A pane attached to a host
    /// names the host's files, so the host it is attached to is passed along.
    ///
    /// - Parameters:
    ///   - target: The hovered link's target, or nil for none.
    ///   - surface: The pane the link is in, or nil when no pane is asking.
    func showLinkPreview(_ target: String?, from surface: TerminalSurface? = nil) {
        let host = surface.flatMap { $0.isRemoteAttached ? $0.remoteFileHost : nil }
        LinkOpener.showPreview(forTarget: target, onHost: host, in: window)
    }

    /// Executes the whole cue one bell asked for.
    ///
    /// One bell, one reaction. Which of the four parts stand is Core's — the
    /// audible and visible halves through `resolveBellEvent`, which folds the
    /// preference and the coalescer, and the two DECSET escalations and the
    /// notification gate resolved on the same drain — so nothing here decides
    /// anything; it executes. The visible half is the surface's, because the
    /// flash is drawn into its own frames.
    ///
    /// - Parameters:
    ///   - reaction: What the bell asked of the host, as Core decided it.
    ///   - surface: The pane that rang.
    func reactToBell(_ reaction: TerminalSurface.BellReaction, from surface: TerminalSurface) {
        if reaction.isAudible {
            Ubiquitty.PAL.bellRing(.Audio)
        }
        noteBellForUnheardMark()
        // A bell in a window the reader is not in has nowhere on screen to
        // land, so it takes the Dock: the bounce and the badge are
        // `[dock]`'s, and the ask is a no-op while the app is active.
        SessionAttention.note()
        // Pop-on-bell (?1043) jumps the Dock icon until the reader activates
        // the app; raise-urgency (?1042) bounces it once. The louder ask wins
        // where a program set both.
        if reaction.shouldPopWindow {
            NSApp.requestUserAttention(.criticalRequest)
        } else if reaction.shouldRaiseUrgency {
            NSApp.requestUserAttention(.informationalRequest)
        }
        // A bell nobody was looking at also raises a banner, tagged with the
        // pane that rang so a click on it focuses that pane and not merely the
        // frontmost window. Core gated whether it is warranted at all.
        guard reaction.shouldNotify, let window else { return }
        Notifications.post(
            Notifications.Request(
                title: "Terminal bell",
                windowNumber: window.windowNumber,
                paneID: Int(paneID(of: surface)?.rawValue ?? 0),
                source: .bell
            )
        )
    }

    /// Posts every banner a program asked this pane for.
    ///
    /// OSC 9 (iTerm), OSC 99 (kitty) and OSC 777;notify (urxvt) reach a
    /// frontend through `ShellClient`, which this arm cannot install: Swift
    /// cannot subclass a C++ class with virtual methods. Core queues them
    /// instead — resolved title and body, past the `DesktopNotification`
    /// capability gate — and this drains the queue the way
    /// ``performPendingWindowRequests(from:)`` drains its own.
    ///
    /// Drains rather than taking one: a program that notifies twice in a drain
    /// put two in the queue, and a single take would strand the second until
    /// some later pass happened to look.
    ///
    /// Tagged with the window and the pane that asked, so a click on the
    /// banner raises the window, selects its tab and focuses that pane rather
    /// than whatever is frontmost. The reader's `[notifications]` preference
    /// and the per-window rate limit are applied inside the post.
    ///
    /// - Parameter surface: The surface whose session carries the banners.
    func postPendingNotifications(from surface: TerminalSurface) {
        while let notification = surface.drive.takeNotification() {
            postBanner(
                title: notification.title,
                body: notification.body,
                from: surface,
                name: notification.identifier,
                occasion: Ubiquitty.NotificationOccasion(rawValue: notification.occasion) ?? .Always
            )
        }
    }

    /// Everything one banner a program asked for does to the window.
    ///
    /// The OS banner, tagged with the window and the pane so a click reaches
    /// that pane; the Dock, which is where a banner lands for a reader in
    /// another application; and the tab's dot, which is what is still there
    /// for a reader in another tab once the banner has gone. A trigger's
    /// `notify` comes through here too, so a rule and an escape cannot be told
    /// apart by what they leave behind.
    ///
    /// - Parameters:
    ///   - title: The notification's title, already resolved by Core.
    ///   - body: Its body, empty for a body-only message.
    ///   - surface: The pane that asked.
    ///   - name: The program's own name for the notification, or empty.
    ///   - occasion: When the program wants it shown.
    func postBanner(
        title: String,
        body: String,
        from surface: TerminalSurface,
        name: String = "",
        occasion: Ubiquitty.NotificationOccasion = .Always
    ) {
        postBanner(
            title: title,
            body: body,
            from: surface,
            audience: bannerAudience(for: surface),
            name: name,
            occasion: occasion
        )
    }

    /// The same, given where the reader's attention is.
    ///
    /// The facts are taken rather than read so the gate can be put to both
    /// answers — the reason ``drawAttentionToConsent(on:title:body:isWindowForemost:)``
    /// takes its own. A scenario's app is an accessory whose windows never
    /// take key, so the quiet case would otherwise be unreachable.
    ///
    /// What the banner says, in which slot, whether it is posted and what it
    /// replaces are Core's: this reports the place and the audience and posts
    /// what comes back.
    ///
    /// - Parameters:
    ///   - title: The notification's title, already resolved by Core.
    ///   - body: Its body, empty for a body-only message.
    ///   - surface: The pane that asked.
    ///   - audience: Where the reader's attention is.
    ///   - name: The program's own name for the notification, or empty.
    ///   - occasion: When the program wants it shown.
    package func postBanner(
        title: String,
        body: String,
        from surface: TerminalSurface,
        audience: Ubiquitty.OSC.BannerAudience,
        name: String = "",
        occasion: Ubiquitty.NotificationOccasion = .Always
    ) {
        // A banner nobody can be sent to is dropped rather than left to arrive
        // stale on whatever edge next asks.
        guard let window else { return }
        let place = Ubiquitty.Session.describeBannerPlace(bannerPlaceFacts(of: surface))
        let banner = Ubiquitty.OSC.composeBanner(std.string(title), std.string(body), place)
        guard banner.shouldPost else { return }
        if Ubiquitty.OSC.isBannerWanted(audience, occasion) {
            let request = Notifications.Request(
                title: String(banner.title),
                subtitle: String(banner.subtitle),
                body: String(banner.body),
                windowNumber: window.windowNumber,
                paneID: paneIdentifier(of: surface) ?? 0,
                source: .program,
                name: name
            )
            lastBannerForTesting = request
            Notifications.post(request)
        }
        SessionAttention.note()
        noteNotificationForUnseenMark()
    }

    /// Where the reader's attention is, for a banner one pane asked for.
    ///
    /// Four observations and no verdict: whether a reader looking there needs
    /// a banner is Core's (`OSC.isBannerWanted`).
    ///
    /// - Parameter surface: The pane that asked.
    /// - Returns: What this window observes.
    func bannerAudience(for surface: TerminalSurface) -> Ubiquitty.OSC.BannerAudience {
        var audience = Ubiquitty.OSC.BannerAudience()
        guard let window else { return audience }
        audience.isAppActive = NSApp.isActive
        audience.isWindowKey = window.isKeyWindow
        audience.isPaneFocused = activeSurface === surface
        // Drawn, not merely held: a pane another one is zoomed over is out of
        // the view tree, a tab behind another is not on screen, and a window
        // on another Space or in the Dock is not visible.
        audience.isPaneVisible =
            surface.window === window && !surface.isHiddenOrHasHiddenAncestor
            && !window.isMiniaturized && window.occlusionState.contains(.visible)
        return audience
    }

    /// What this window holds about where one pane sits, for a banner's place
    /// line.
    ///
    /// Names and counts as they are; which of them the line states is Core's
    /// (`Session.describeBannerPlace`). The titles are the ones the window
    /// and its tab show, which the pane naming them weaves — the focused one,
    /// not necessarily the one that asked — composed without the host mark,
    /// since the host is a level of its own in the line.
    ///
    /// - Parameter surface: The pane that asked.
    /// - Returns: The facts.
    package func bannerPlaceFacts(of surface: TerminalSurface) -> Ubiquitty.Session.BannerPlaceFacts {
        var facts = Ubiquitty.Session.BannerPlaceFacts()
        facts.host = std.string(hostName(of: surface))
        let workspace = surface.drive.remoteWorkspaceName
        facts.workspace = std.string(workspace.isEmpty ? remoteWorkspaceName : workspace)
        let naming = titleSurface ?? surface
        facts.windowName = std.string(customWindowTitle)
        facts.windowTitle = bannerTitle(for: naming, as: .window)
        facts.tabTitle = bannerTitle(for: naming, as: .tab)
        // No pane label: the host keeps a pane's label for its listings, and
        // the layout a client adopts carries none.
        let panes = panesByIdentifier()
        facts.paneNumber = Int32(panes.first(where: { $0.value === surface })?.key ?? 0)
        facts.paneCount = Int32(max(1, panes.count))
        facts.tabCount = Int32(max(1, window?.tabGroup?.windows.count ?? 1))
        // Each tab is a window of its own in a tab group, so the windows a
        // reader tells apart are the groups.
        var shown = Set<ObjectIdentifier>()
        for controller in Self.spawnedControllers {
            guard let other = controller.window else { continue }
            shown.insert(other.tabGroup.map { ObjectIdentifier($0) } ?? ObjectIdentifier(other))
        }
        facts.windowCount = Int32(max(1, shown.count))
        return facts
    }

    /// The last banner this window posted, so a scenario reads what was asked
    /// of the system rather than what the system chose to show. Set before the
    /// reader's `[notifications]` switch and the rate limit, and not at all
    /// for a banner Core withheld from a reader already looking.
    package private(set) var lastBannerForTesting: Notifications.Request?

    /// The focused pane names the window — a background pane's title change
    /// stays its own.
    func surfaceDidChangeTitle(_ surface: TerminalSurface, title: String) {
        refreshNativeInspector(from: surface)
        refreshWindowTagLocation()
        guard surface.isTitlePresentationVisible else { return }
        if surface === titleSurface {
            refreshTitles(trigger: surface)
        } else {
            // A background pane's own bar names that pane: nothing about its
            // title reaches the window's or its tab's, and a refresh that ran
            // for the active pane alone left the bar naming what the pane was
            // running when it last held focus.
            restylePaneChrome(of: surface)
        }
        refreshCloseSafetyIndicator()
    }

    /// The focused pane's directory names the window and stands its proxy
    /// icon — a background pane's `cd` stays its own.
    func surfaceDidChangeCurrentDirectory(_ surface: TerminalSurface, directory: String) {
        refreshNativeInspector(from: surface)
        refreshWindowTagLocation()
        guard surface.isTitlePresentationVisible else { return }
        guard surface === titleSurface else {
            restylePaneChrome(of: surface)
            return
        }
        refreshTitles(trigger: surface)
    }

    /// The focused pane's process sample moved, so the segments woven from it
    /// name a different program than the title standing does.
    func surfaceDidChangeProcessState(_ surface: TerminalSurface) {
        refreshNativeInspector(from: surface)
        refreshWindowTagLocation()
        guard surface.isTitlePresentationVisible else { return }
        refreshCloseSafetyIndicator()
        guard surface === titleSurface else {
            restylePaneChrome(of: surface)
            return
        }
        refreshTitles(trigger: surface)
    }

    /// The focused pane's grid moved, so the columns-by-rows the title ends
    /// with names a size the pane no longer is.
    ///
    /// The title poll cannot carry a resize: it delivers a MOVED process
    /// sample, and a drag under one program moves none, so a readout left to
    /// the poll stands at the size the drag began at until the settle.
    ///
    /// Woven on the next turn of the main queue rather than here: this is
    /// the surface's resize step, between the grid moving and the frame that
    /// shows it, and a program redrawing on every SIGWINCH is waiting on that
    /// frame. The queue drains between drag events, so the readout still
    /// lands with the step, and steps that pile up in one turn weave once.
    /// No lock: the weave reads the published snapshot.
    func surfaceDidResizeGrid(_ surface: TerminalSurface) {
        guard surface === activeSurface else {
            // A background pane's bar ends with its own columns-by-rows, and a
            // divider drag moves them with no event that reaches the window's
            // title. Queued to the next turn as the active pane's is, so the
            // steps of one drag restyle once.
            guard !isPaneResizeRestylePending else { return }
            isPaneResizeRestylePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isPaneResizeRestylePending = false
                self.refreshPaneChrome()
            }
            return
        }
        guard !isResizeTitleWeavePending else { return }
        isResizeTitleWeavePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isResizeTitleWeavePending = false
            self.refreshTitles()
        }
    }

    /// Whether a background pane's grid move has a bar restyle queued, so the
    /// steps of one drag restyle once.
    private var isPaneResizeRestylePending = false

    /// The window's title, woven by Core from the configured segments.
    ///
    /// The host's OSC title is one segment of several, not the title: a shell
    /// that sets none leaves it empty, which is why assigning it directly gives
    /// a window with no name at a fresh prompt. Core weaves whichever segments
    /// the `[title]` keys ask for, drops the empty ones, and the app name is
    /// the answer when every segment is empty.
    ///
    /// - Parameter surface: The pane naming the window.
    /// - Returns: The composed title.
    func composedTitle(for surface: TerminalSurface) -> String {
        wovenTitle(for: surface, as: .window).systemTitle
    }

    /// Which title a weave is for; each weaves from its own `[title]` composition.
    internal enum TitleWeaveSurface {
        /// The window's title row.
        case window
        /// The tab's label in the strip.
        case tab
        /// A split pane's header.
        case pane

        /// The surface Core ranks this weave's names for.
        var namingSurface: Ubiquitty.Session.TitleSurface {
            switch self {
            case .window: .window
            case .tab: .tab
            case .pane: .pane
            }
        }
    }

    /// A woven title, and the parts a title row draws beside its text.
    internal struct WovenTitle {
        /// The text drawn in the title row or label.
        var title: String
        /// The spaced title supplied to the window server and its menus.
        var systemTitle: String
        /// Whether the text is Core's automatic fallback, rather than a supplied title.
        var usesFallbackName: Bool
        /// The directory segment the text opens with, or empty.
        var lead: String
        /// The columns×rows readout, when the surface draws it apart from its
        /// text; empty where it is woven in or not shown.
        var dimensions: String
        /// A program's status label, when the surface draws it apart from its
        /// text; empty where it is woven in or not shown.
        var programStatus: String
        /// What the tab's or pane's marks put before the label — the pin and
        /// the host — which a bake measures the label's own segments past.
        var markPrefix = ""
        /// Shorter versions of a tab's or pane's label, longest first, each
        /// with the directory it opens with (`Title::fittingSteps`).
        var fitting: [(title: String, lead: String)] = []
    }

    /// A title and the parts drawn beside it.
    ///
    /// Core composes it (`App.composeTitle`): which name wins, which parts
    /// show, which of them a window's row draws beside its text, the join and
    /// the marks are one rule for every frontend and for a pane listed from
    /// another machine. What is gathered here is this pane's facts and the
    /// window's, and the composition is the reader's own `[title]` settings
    /// for the surface.
    ///
    /// The lead is returned beside the title rather than found in it again:
    /// the tab bake dims exactly the segment the weave put first, and a search
    /// for it in the woven text would also match a host title that happens to
    /// start the same way.
    ///
    /// - Parameters:
    ///   - surface: The pane naming the title.
    ///   - titleSurface: Which title is woven, and so whose composition.
    /// - Returns: The woven title and the components drawn beside it.
    internal func wovenTitle(for surface: TerminalSurface, as titleSurface: TitleWeaveSurface) -> WovenTitle {
        let composition = titleComposition(for: titleSurface)
        let (facts, viewer) = titleFacts(for: surface, as: titleSurface, composition: composition)
        let composed = Ubiquitty.App.composeTitle(facts, viewer, composition, titleSurface.namingSurface)
        return WovenTitle(
            title: String(composed.title),
            systemTitle: String(composed.systemTitle),
            usesFallbackName: composed.usesFallbackName,
            lead: String(composed.lead),
            dimensions: String(composed.dimensions),
            programStatus: String(composed.programStatus),
            markPrefix: String(composed.markPrefix),
            fitting: composed.fitting.map { (title: String($0.title), lead: String($0.lead)) }
        )
    }

    /// The title a banner's place line names this window or its tab by.
    ///
    /// Core composes it (`App.composeBannerTitle`) from the facts the
    /// surface's own title is woven from, in the form a place line needs: no
    /// host mark, pin or tag, and a window's parts spaced as a tab's are.
    ///
    /// - Parameters:
    ///   - surface: The pane naming the title.
    ///   - titleSurface: The window or the tab.
    /// - Returns: The title, as Core's string.
    internal func bannerTitle(for surface: TerminalSurface, as titleSurface: TitleWeaveSurface) -> std.string {
        let composition = titleComposition(for: titleSurface)
        let (facts, viewer) = titleFacts(for: surface, as: titleSurface, composition: composition)
        return Ubiquitty.App.composeBannerTitle(facts, viewer, composition, titleSurface.namingSurface)
    }

    /// The reader's `[title]` composition for one surface.
    private func titleComposition(for titleSurface: TitleWeaveSurface) -> Ubiquitty.Preferences.Effective.TitleComposition {
        switch titleSurface {
        case .window:
            Ubiquitty.Preferences.Effective.windowTitleComposition()
        case .tab:
            Ubiquitty.Preferences.Effective.tabTitleComposition()
        case .pane:
            Ubiquitty.Preferences.Effective.paneTitleComposition()
        }
    }

    /// One pane's title facts and this window's, gathered for a composition.
    ///
    /// - Parameters:
    ///   - surface: The pane naming the title.
    ///   - titleSurface: Which title is woven.
    ///   - composition: The composition the facts are gathered for; a part it
    ///     does not show is not sampled.
    /// - Returns: The pane's facts and the reader's.
    private func titleFacts(
        for surface: TerminalSurface,
        as titleSurface: TitleWeaveSurface,
        composition: Ubiquitty.Preferences.Effective.TitleComposition
    ) -> (pane: Ubiquitty.App.PaneTitleFacts, viewer: Ubiquitty.App.TitleViewerFacts) {
        let snapshot = surface.drive.readSnapshot()
        let grid = surface.drive.titleGrid(for: surface.publishedGrid)
        var facts = Ubiquitty.App.PaneTitleFacts()
        var viewer = Ubiquitty.App.TitleViewerFacts()
        facts.programTitle = std.string(surface.title)
        // The title's directory, not the pane's: under a plain ssh the pane's
        // is the local client's folder, which the session has left.
        if composition.showsDirectory, let reported = surface.drive.titleDirectory() {
            // Copied out under the model lock before it is used, not borrowed
            // across the call: the ingest thread rewrites that std::string in
            // place, so handing a reference to it into Core is a read of a
            // buffer the writer may reallocate underneath.
            facts.currentDirectory = std.string(reported)
            // The pane's own home: a hosted pane's is its host's.
            facts.homeDirectory = std.string(surface.drive.titleHomeDirectory(localHome: NSHomeDirectory()))
        }
        // The process-derived segments, sampled by Core's own drain probe
        // rather than by a timer here: the walk of the process table is the
        // costly part, and one session's answer serves every surface that
        // names it. The argv spelling comes from the same walk.
        if composition.showsProcessArguments {
            facts.processChainWithArguments = std.string(surface.drive.processChainWithArguments)
        } else {
            facts.processChain = std.string(surface.drive.processChain)
        }
        facts.shellCommandName = std.string(surface.drive.shellCommandName)
        // What holds the terminal, and whether it fills the screen: Core
        // leaves the directory out for a listed program, or a full-screen one.
        facts.foregroundName = std.string(surface.drive.foregroundProcessName)
        facts.isFullScreen = snapshot.modes.alternateScreenActive
        facts.ttyName = std.string(surface.drive.ttyName)
        viewer.profileName = std.string(appliedProfileName)
        facts.programStatus = snapshot.tabStatusLabel()
        facts.columns = grid.columns
        facts.rows = grid.rows
        facts.end = surface.drive.sessionEnd
        // Every name put on this surface. Core ranks them, so a tab and its
        // window cannot disagree, and a pane never answers to a name given to
        // its tab or window. No pane label is handed over: the host keeps a
        // pane's label for its listings, and the workspace layout a client
        // adopts carries none.
        facts.tabTitle = std.string(customTabTitle)
        facts.windowTitle = std.string(customWindowTitle)
        facts.tmuxWindowName = std.string(tmuxWindowName)
        // The host a tab or pane carries. Whether the label says it is
        // Core's: a pane only where its window mixes places, and a tab only
        // where the window's chrome does not already name that host, from
        // the facts reported here and below.
        if titleSurface != .window {
            facts.hostName = std.string(hostName(of: surface))
            viewer.doPaneHeadersNameHost = titleSurface == .pane && paneHeadersNameHost()
        }
        // What the window's chrome already says of its host, and whether its
        // tabs are in one place: Core decides from them whether this tab's
        // label says where it is.
        if titleSurface == .tab {
            let window = windowHostFacts()
            viewer.windowHostName = std.string(window.hostName)
            viewer.doTabsMixPlaces = window.doTabsMixPlaces
        }
        // The window's own title: what its chip names, so Core can leave out
        // an `ssh` that is only the way to that host.
        if titleSurface == .window {
            viewer.windowHostName = std.string(remoteConnectionIndicator?.statedHostName ?? "")
        }
        // A host that has set no title of its own names the window better than
        // the application does — the reader asked for that machine, not for a
        // terminal.
        viewer.fallbackName = std.string(remoteHostLabel.isEmpty ? Self.applicationName : remoteHostLabel)
        viewer.isPinned = isPinned
        return (facts, viewer)
    }

    /// Which name this surface answers to, and what the app-title segment
    /// carries when the weave still runs.
    ///
    /// Core ranks them; this hands over every name it holds and reads back the
    /// verdict, so which of them a pane may answer to is Core's to say. No pane
    /// label is handed over: the host keeps a pane's label for its listings,
    /// and the workspace layout a client adopts carries none.
    ///
    /// - Parameters:
    ///   - surface: The pane whose facts are named.
    ///   - naming: Which surface is being named.
    /// - Returns: A whole-title replacement or empty, the app-title segment,
    ///   and whether that segment is a custom title.
    private func titleNames(
        for surface: TerminalSurface,
        as naming: Ubiquitty.Session.TitleSurface
    ) -> (replacement: String, appTitle: String, isCustomName: Bool) {
        customTabTitle.withCString { tabBytes in
            customWindowTitle.withCString { windowBytes in
                tmuxWindowName.withCString { tmuxBytes in
                    surface.title.withCString { oscBytes in
                        var names = Ubiquitty.Session.TitleNames()
                        names.tabTitle = std.string_view(tabBytes)
                        names.windowTitle = std.string_view(windowBytes)
                        names.tmuxWindowName = std.string_view(tmuxBytes)
                        names.oscTitle = std.string_view(oscBytes)
                        let outcome = Ubiquitty.Session.resolveTitleNames(names, naming)
                        return (String(outcome.replacement), String(outcome.appTitle), outcome.isCustomName)
                    }
                }
            }
        }
    }

    // The name a window carries when no segment produced text — a shell that
    // sets no title at a prompt it has not yet run anything in.
    private static let applicationName =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Ubiquitty"

    // MARK: - Pane focus

    /// A surface took key focus — the model's focus follows the click (and
    /// tells the pane's backend), and the window takes the newly focused
    /// pane's title. A hosted pane's own session hears the focus directly.
    func surfaceDidFocus(_ surface: TerminalSurface) {
        paneFocusEdgesForTesting += 1
        if tmuxSurfaces.values.contains(where: { $0 === surface }) {
            lastFocusedTmuxSurface = surface
        }
        reportClipboardScope(for: surface)
        inspectorModel?.surface = surface
        refreshNativeInspector(from: surface)
        // The badge speaks for one session, and this is now the one the window
        // means: a pane of a hosted workspace has a roster of its own.
        refreshPresence()
        // The pane changed, so the inputs the memo holds belong to the old one.
        titleInputs = nil
        refreshTitles()
        refreshCloseSafetyIndicator()
        guard let model = Self.windowModel, let paneID = paneID(of: surface) else {
            _ = surface.drive.requestPaneVerb(.focus)
            // The bars read the focus off the model, so they are styled after
            // it has moved: styled before, both the pane focus left and the
            // pane it reached keep the selection they had.
            refreshPaneChrome()
            return
        }
        _ = model.focusPane(workspaceSurface, paneID)
        refreshPaneChrome()
    }

    /// Focuses the pane a banner was tagged with.
    ///
    /// A notification carries the pane that rang, so a click on it reaches
    /// that pane and not merely the frontmost window. The pane may be gone by
    /// then — a banner outlives what posted it — and answering false is what
    /// tells the caller to settle for having raised the window.
    ///
    /// The bind runs even when the pane is already the focused leaf: a window
    /// that was a background tab never made its view first responder, so the
    /// leaf being right is not the same as the keyboard being there.
    ///
    /// A hosted window's pane takes focus the way a click gives it: its
    /// surface becomes first responder, and its session tells the backend the
    /// pane was chosen.
    ///
    /// - Parameter identifier: The pane's id, as the banner carries it.
    /// - Returns: Whether the pane is still open.
    @objc(focusPaneWithIdentifier:)
    @discardableResult
    public func focusPane(withIdentifier identifier: Int) -> Bool {
        guard let surface = panesByIdentifier()[identifier] else {
            return false
        }
        if let paneID = paneID(of: surface), let model = Self.windowModel, surfaces.count > 1 {
            _ = model.focusPane(workspaceSurface, paneID)
        }
        window?.makeFirstResponder(surface)
        return true
    }

    /// The window's panes by the id a banner or a palette destination carries.
    ///
    /// The panes are the window's own: its local splits, or the panes of the
    /// session it hosts, keyed by the id that session numbers them with. A
    /// window is one shape at a time, so the ids of one map never meet
    /// another's.
    ///
    /// - Returns: Every pane surface this window shows, by id.
    func panesByIdentifier() -> [Int: TerminalSurface] {
        if !tmuxSurfaces.isEmpty {
            return Dictionary(uniqueKeysWithValues: tmuxSurfaces.map { (Int($0.key), $0.value) })
        }
        if !remotePaneSurfaces.isEmpty {
            return Dictionary(uniqueKeysWithValues: remotePaneSurfaces.map { (Int($0.key.rawValue), $0.value) })
        }
        return Dictionary(uniqueKeysWithValues: surfaces.map { (Int($0.key.rawValue), $0.value) })
    }

    /// The id a banner posted from one pane is tagged with.
    ///
    /// The same number ``focusPane(withIdentifier:)`` takes, so a caller can
    /// put a pane to it rather than guess what the model minted.
    ///
    /// - Parameter surface: The pane to name.
    /// - Returns: Its id, or nil for a surface this window does not hold.
    package func paneIdentifier(of surface: TerminalSurface) -> Int? {
        panesByIdentifier().first(where: { $0.value === surface })?.key
    }

    func paneID(of surface: TerminalSurface) -> Ubiquitty.Session.Layout.PaneID? {
        surfaces.first(where: { $0.value === surface })?.key
    }

    private func movePaneFocus(_ direction: Ubiquitty.Panes.Direction) {
        if let root = remoteSurface, root.drive.remoteWorkspaceTab != Ubiquitty.Session.Layout.invalidTab {
            _ = root.drive.remoteWorkspaceMoveFocus(direction)
            return
        }
        guard let model = Self.windowModel, model.moveFocus(workspaceSurface, direction), let focused = focusedSurface else {
            return
        }
        window?.makeFirstResponder(focused)
    }

    /// Moves pane focus one pane left — the View menu's navigation set, the
    /// same selectors the Metal arm's controller answers.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func movePaneFocusLeft(_ sender: Any?) { movePaneFocus(.Left) }

    /// Moves pane focus one pane right.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func movePaneFocusRight(_ sender: Any?) { movePaneFocus(.Right) }

    /// Moves pane focus one pane up.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func movePaneFocusUp(_ sender: Any?) { movePaneFocus(.Up) }

    /// Moves pane focus one pane down.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func movePaneFocusDown(_ sender: Any?) { movePaneFocus(.Down) }

    /// Closes the focused pane, ending its session — the View menu's ⇧⌘W.
    /// The last pane's close closes the window.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func closePane(_ sender: Any?) {
        if let hosted = hostedActiveSurface {
            _ = hosted.drive.requestPaneVerb(.close)
            return
        }
        guard let surface = activeSurface else {
            return
        }
        guard paneCount > 1 else {
            window?.performClose(sender)
            return
        }
        guard let model = Self.windowModel, let pane = paneID(of: surface),
            !model.isPaneSafeToClose(pane), let window
        else {
            closePane(surface)
            return
        }
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = String(Ubiquitty.Session.closeConfirmationTitle(.pane))
        alert.informativeText = String(model.closeConfirmationBody(workspaceSurface, .pane, pane))
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak surface] response in
            guard response == .alertFirstButtonReturn, let self, let surface else { return }
            self.closePane(surface)
        }
    }

    // MARK: - Broadcast input

    /// Whether the focused pane's keystrokes replay into every sibling —
    /// the View menu's ⇧⌘B.
    ///
    /// Seeded from what the reader last left, not from off: somebody running
    /// a row of hosts side by side turns this on for a session's work, and a
    /// window that quietly opened out of the mode is one they discover by
    /// typing a command into one host instead of all of them.
    private var isBroadcastingInput = BroadcastInputMemory.isBroadcasting()

    /// Flips broadcast; the menu item's checkmark follows through
    /// validation. Turning it on over a split window asks first — everything
    /// typed lands in every pane, which deserves a confirmation — the same
    /// question the Metal arm's controller asks. The confirm is skipped when
    /// no event loop runs: a modal without one can never be answered, and
    /// the headless parity battery is the caller in that state.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func toggleBroadcastInput(_ sender: Any?) {
        let eligibleCount = Self.broadcastEligibleSurfaces(among: Array(surfaces.values)).count
        if !isBroadcastingInput, eligibleCount > 1, NSApp.isRunning {
            let alert = NSAlert()
            alert.messageText = "Broadcast input to all panes?"
            alert.informativeText =
                "Everything you type or paste will be sent to all \(eligibleCount) panes in this window at once, not just the focused one."
            alert.addButton(withTitle: "Broadcast Input")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }
        isBroadcastingInput.toggle()
        BroadcastInputMemory.set(isBroadcastingInput)
        updateBroadcastIndicator()
    }

    /// Shows or withdraws the title row's broadcast pill.
    ///
    /// A window whose accessory bar has not been built yet has no title row to
    /// mark; the seed below runs after the bar is made, and the toggle can
    /// only be reached from a window that has one.
    private func updateBroadcastIndicator() {
        guard let windowAccessoryBar else { return }
        BroadcastIndicator.setBroadcasting(isBroadcastingInput, in: windowAccessoryBar)
    }

    /// Shows broadcast's on state as the menu checkmark.
    ///
    /// - Parameter item: The menu item asking.
    /// - Returns: Whether the item is enabled.
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(newRemoteWorkspaceWindow(_:)) {
            item.title = "New Window on Remote Host"
            item.isHidden = remoteSurface == nil
            guard let remote = remoteSurface else { return false }
            let connectionName =
                remoteHostKey == Self.thisMacHostKey
                ? RemoteConnectionIndicator.thisMacName
                : (remoteHostLabel.isEmpty ? remoteHostKey : remoteHostLabel)
            if !connectionName.isEmpty {
                item.title = "New Window on \(connectionName)"
            }
            return remote.drive.remoteState == .Connected && remote.drive.remoteWorkspaceID != 0
        }
        if item.action == #selector(shareThisWindow(_:)) {
            item.title = hasUnresolvedLocalAdoption ? "Retry Session Handoff" : "Share This Window with Agents"
            return hasUnresolvedLocalAdoption || isWindowShareable
        }
        if item.action == #selector(retrySessionHandoff(_:)) {
            return hasUnresolvedLocalAdoption
        }
        if item.action == #selector(stopSharingWindow(_:)) {
            return sharedSurface?.drive.isReclaimableSharedSession == true
        }
        if item.action == #selector(toggleBroadcastInput(_:)) {
            item.state = isBroadcastingInput ? .on : .off
        }
        if item.action == #selector(resetFontSize(_:)) {
            item.state = fontZoomOffset == 0.0 ? .on : .off
        }
        if item.action == #selector(togglePinTab(_:)) {
            item.state = isPinned ? .on : .off
        }
        if item.action == #selector(toggleSessionLog(_:)) {
            Self.labelSessionLogItem(item, for: isLoggingSession ? .on : .off)
        }
        if item.action == #selector(toggleKeepOnTop(_:)) {
            item.state = WindowLevelMemory.isKeptOnTop() ? .on : .off
        }
        if item.action == #selector(toggleHideTitleBar(_:)) {
            // This window's chrome, not the default's: the item is validated on
            // the key window's controller, and that is the window the toggle
            // would act on.
            item.state = hidesTitleBar ? .on : .off
        }
        // The Edit menu's own answers, which depend on what is selected and
        // what the shell has marked rather than on this controller's state.
        return validateEditMenuItem(item)
    }

    /// The focused pane transmitted input; under broadcast the same bytes
    /// reach every sibling that can take them. The replay writes to the other
    /// sessions directly, so it cannot echo back through this hook.
    func surfaceDidTransmit(_ surface: TerminalSurface, bytes: [CChar], count: Int) {
        guard isBroadcastingInput, surface === focusedSurface, count > 0 else {
            return
        }
        for sibling in Self.broadcastTargets(from: surface, among: Array(surfaces.values)) {
            bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                sibling.drive.sendInput(base, count: count)
            }
        }
    }

    /// The panes a broadcast can reach: those whose session has a host to
    /// take input — a local PTY, a tmux -CC primary, a remote core.
    ///
    /// Core's answer (`TerminalSession::hasHostInputSink`) and nothing else,
    /// shared by the fan-out and by the count the confirmation names, so the
    /// two cannot disagree. A pane with no host — a passive mirror, a preview
    /// fed by hand — would drop the bytes, and a confirmation counting it
    /// promises the reader a pane their keystrokes never reach.
    ///
    /// - Parameter panes: The window's panes.
    /// - Returns: The ones that take input, in the order given.
    package static func broadcastEligibleSurfaces(among panes: [TerminalSurface]) -> [TerminalSurface] {
        panes.filter { $0.drive.hasHostInputSink }
    }

    /// The siblings one pane's input fans out to under broadcast: every
    /// input-eligible pane but the one that already sent it.
    ///
    /// - Parameters:
    ///   - source: The pane the reader typed into.
    ///   - panes: The window's panes.
    /// - Returns: The panes to replay the input into.
    package static func broadcastTargets(from source: TerminalSurface, among panes: [TerminalSurface]) -> [TerminalSurface] {
        broadcastEligibleSurfaces(among: panes).filter { $0 !== source }
    }

    // MARK: - Font zoom

    /// View > Zoom In: one point larger, this window only.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func growFontSize(_ sender: Any?) {
        stepFontZoom(by: Ubiquitty.Preferences.Zoom.fontZoomStep)
    }

    /// View > Zoom Out: one point smaller, this window only.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func shrinkFontSize(_ sender: Any?) {
        stepFontZoom(by: -Ubiquitty.Preferences.Zoom.fontZoomStep)
    }

    /// View > Actual Size: clears this window's zoom, so it renders the
    /// configured size. Nothing is written.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func resetFontSize(_ sender: Any?) {
        applyFontZoom(offset: 0.0)
    }

    /// Steps from the live size, so a size set by other means steps from
    /// where it stands; the offset recorded is the one that renders the
    /// stepped size over the configured one, clamped to the shared range.
    ///
    /// - Parameter delta: The step, in points.
    private func stepFontZoom(by delta: Double) {
        guard let renderer = surfaceRenderer as? SurfaceRenderer else {
            return
        }
        let configuredSize = Ubiquitty.Preferences.Effective.fontSize(Ubiquitty.Preferences.values().pointee)
        applyFontZoom(offset: Ubiquitty.Preferences.Zoom.fontZoomOffsetForSize(configuredSize, renderer.pointSize + delta))
    }

    /// Wraps a settings apply that moves the cell — font, size, line spacing,
    /// weight, width, variations, padding, the reserved band — so the window
    /// answers it in one way: the geometry is recorded
    /// first, `mutate` moves the metrics, and then either the window resizes
    /// to keep the pre-change grid at the new cell, or it holds and the grid
    /// reflows into it. Core classifies from the facts this records
    /// (`classifyCellMetricChange`); this side reports the window and moves
    /// the frame. `mutate` must not refit the grid itself: a refit before the
    /// verdict reflows a window that is about to be resized back, which is
    /// two resizes and two SIGWINCHes for one change.
    ///
    /// - Parameter mutate: The cell-affecting mutation, over every pane.
    func applyCellMetricChange(_ mutate: () -> Void) {
        let snapshot = captureCellMetricChangeSnapshot()
        mutate()
        resizeWindowToGrid(after: snapshot)
    }

    /// The facts Core classifies a cell-metric change by, read before the
    /// change: the window's content, the focused grid and its cell, and
    /// whether the window manager or a split owns the size.
    private func captureCellMetricChangeSnapshot() -> Ubiquitty.Rendering.CellMetricChangeSnapshot {
        var snapshot = Ubiquitty.Rendering.CellMetricChangeSnapshot()
        guard let window, let surface = activeSurface, let renderer = surface.renderer else {
            return snapshot
        }
        let cell = renderer.cellSize(for: surface)
        guard cell.width > 0, cell.height > 0 else { return snapshot }
        let insets = renderer.gridInsets(for: surface)
        let content = paneHost.bounds.size
        snapshot.isValid = true
        snapshot.isPinned = window.styleMask.contains(.fullScreen) || window.isZoomed
        snapshot.isSplit = projectedSurfaces.count > 1
        snapshot.grid = Ubiquitty.GridSize(columns: Int32(surface.publishedGrid.columns), rows: Int32(surface.publishedGrid.rows))
        snapshot.content = Ubiquitty.FloatSize(width: Float(content.width), height: Float(content.height))
        snapshot.cell = Ubiquitty.FloatSize(width: Float(cell.width), height: Float(cell.height))
        snapshot.insets = Self.coreInsets(insets)
        return snapshot
    }

    /// The Kit's insets as Core spells them.
    private static func coreInsets(_ insets: PlatformEdgeInsets) -> Ubiquitty.Rendering.EdgeInsets {
        var core = Ubiquitty.Rendering.EdgeInsets()
        core.left = Float(insets.left)
        core.right = Float(insets.right)
        core.top = Float(insets.top)
        core.bottom = Float(insets.bottom)
        return core
    }

    /// Answers a cell-metric change with Core's verdict on the pre-change
    /// snapshot: a window that chose its own size follows the font, keeping
    /// its columns and rows at the new cell, anchored top-left and nudged
    /// inside the screen's visible frame; every other window holds and its
    /// grid reflows. Either way the surfaces refit afterwards, which is what
    /// tells the program the pixel size it now has, and a hosted window tells
    /// tmux the client grid it now holds — the reflowing classification moves
    /// no window frame, so no frame-change edge would report it otherwise.
    ///
    /// - Parameter snapshot: The facts recorded before the change.
    private func resizeWindowToGrid(after snapshot: Ubiquitty.Rendering.CellMetricChangeSnapshot) {
        defer {
            for surface in projectedSurfaces {
                surface.restyle()
            }
            reportTmuxClientGrid()
        }
        guard let window, let surface = activeSurface, let renderer = surface.renderer,
            Ubiquitty.Rendering.classifyCellMetricChange(snapshot) == .WindowFollowsGrid
        else {
            return
        }
        let cell = renderer.cellSize(for: surface)
        guard cell.width > 0, cell.height > 0 else { return }
        let columns = min(max(Int(snapshot.grid.columns), 1), Int(Ubiquitty.maxColumns))
        let rows = min(max(Int(snapshot.grid.rows), 1), Int(Ubiquitty.maxRows))
        let extent = Ubiquitty.Rendering.viewportForGrid(
            Ubiquitty.GridSize(columns: Int32(columns), rows: Int32(rows)),
            Ubiquitty.FloatSize(width: Float(cell.width), height: Float(cell.height)),
            Self.coreInsets(renderer.gridInsets(for: surface)),
            0
        )
        // Rounded up to the next device pixel: the fit divides this width by
        // the cell, and a product that rounds a hair under the exact multiple
        // would land the grid one column short of the one being preserved.
        let scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 1
        let content = NSSize(
            width: (Double(extent.width) * scale).rounded(.up) / scale,
            height: (Double(extent.height) * scale).rounded(.up) / scale
        )
        let wanted = windowSize(forTerminalViewport: content)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        var frame = Ubiquitty.FloatRect()
        frame.origin.x = Float(window.frame.origin.x)
        frame.origin.y = Float(window.frame.origin.y)
        frame.size.width = Float(window.frame.size.width)
        frame.size.height = Float(window.frame.size.height)
        var screen = Ubiquitty.FloatRect()
        screen.origin.x = Float(visible.origin.x)
        screen.origin.y = Float(visible.origin.y)
        screen.size.width = Float(visible.size.width)
        screen.size.height = Float(visible.size.height)
        let target = Ubiquitty.Rendering.anchoredWindowFrame(
            frame,
            Ubiquitty.FloatSize(width: Float(wanted.width), height: Float(wanted.height)),
            screen,
            .Up
        )
        let targetRect = NSRect(
            x: CGFloat(target.origin.x),
            y: CGFloat(target.origin.y),
            width: CGFloat(target.size.width),
            height: CGFloat(target.size.height)
        )
        if targetRect != window.frame {
            window.setFrame(targetRect, display: true)
        }
    }

    /// Routes a surface's own cell-metric changes — the pinch zoom — through
    /// this window's answer, so a zoomed surface grows its window as a
    /// settings change to the cell does.
    ///
    /// - Parameter surface: The surface this window shows.
    private func hostCellMetricChanges(of surface: TerminalSurface) {
        surface.cellMetricChangeHost = { [weak self] mutate in
            guard let self else {
                mutate()
                return
            }
            self.applyCellMetricChange(mutate)
        }
    }

    /// Renders the configured size through `offset` on every surface of
    /// this window. The typography is re-read so the adopt carries what the
    /// configuration holds, the same way the live re-feed does.
    ///
    /// - Parameter offset: The zoom, in points over the configured size.
    private func applyFontZoom(offset: Double) {
        guard let renderer = surfaceRenderer as? SurfaceRenderer else {
            return
        }
        fontZoomOffset = offset
        let configuration = windowRenderConfiguration
        applyCellMetricChange {
            renderer.adopt(
                pointSize: Ubiquitty.Preferences.Zoom.zoomedFontSize(configuration.fontSizePoints, offset),
                typography: SurfaceTypography(configuration: configuration)
            )
        }
        for surface in projectedSurfaces {
            if let actualRenderer = surface.renderer as? SurfaceRenderer {
                surface.drive.publishActualFont(family: actualRenderer.familyName, sizePoints: actualRenderer.pointSize)
            }
            // Asked for here, at the step that moved the font, rather than left
            // to the bounds change the step also causes. The two are not the
            // same set: a projected surface whose bounds this step does not move
            // — one mapped outside the window's own layout — would be handed new
            // cell metrics and never asked to draw them, and its glyphs would
            // stay at the previous size until some unrelated damage arrived.
            surface.invalidateRetainedBaseline()
            surface.needsDisplay = true
        }
    }

    /// Expands the focused pane to fill the window, or collapses back —
    /// the View menu's ⇧⌘↩. The zoom is the model's recorded intent; this
    /// side re-mirrors whatever it answers.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func toggleZoomPane(_ sender: Any?) {
        if let hosted = hostedActiveSurface {
            _ = hosted.drive.requestPaneVerb(.zoom)
            return
        }
        guard let model = Self.windowModel else {
            return
        }
        guard model.toggleZoomFocused(workspaceSurface) == .localActionRequired else {
            return
        }
        rebuildPaneLayout()
        if let focused = focusedSurface {
            window?.makeFirstResponder(focused)
        }
    }

    // MARK: - Tree mirroring

    /// Rebuilds the split-view hierarchy from the model's tree. Structure
    /// changes are rare (a split, a close), so the mirror is rebuilt whole
    /// rather than patched — the surfaces themselves persist and just
    /// re-parent.
    internal func rebuildPaneLayout() {
        guard let model = Self.windowModel else {
            return
        }
        rebuildPaneLayout(tree: model.paneTreeSnapshot(workspaceSurface), zoomed: model.zoomedPane(workspaceSurface), views: surfaces)
    }

    /// Rebuilds the split-view hierarchy from a tree and the views over its
    /// leaves — the model's for a local window, the host's mirror for a
    /// hosted workspace's.
    ///
    /// - Parameters:
    ///   - tree: The topology to mirror.
    ///   - zoomed: The pane filling the window alone, or `invalidPane`.
    ///   - views: The view over each leaf, keyed by the tree's pane ids.
    internal func rebuildPaneLayout(
        tree: Ubiquitty.Panes.Tree,
        zoomed: Ubiquitty.Session.Layout.PaneID,
        views: [Ubiquitty.Session.Layout.PaneID: TerminalSurface]
    ) {
        transferTree = tree
        splitNodes.removeAll()
        // The blur backdrop is not a pane: it stays at the bottom while the
        // tree above it is mirrored again.
        paneHost.subviews.forEach { subview in
            subview.removeFromSuperview()
        }
        // A zoomed pane fills the window alone, in its own chrome: the tab
        // still holds its other panes, so the bar stays, and its contract
        // button is the unzoom a reader can see. The tree is untouched and an
        // unzoom re-mirrors it whole.
        let mirrored: NSView
        if zoomed != Ubiquitty.Session.Layout.invalidPane, let zoomedView = views[zoomed] {
            mirrored = paneChrome(for: zoomed, framing: zoomedView, zoomedPane: zoomed)
        } else {
            mirrored = mirrorNode(tree, tree.root(), views, zoomed)
        }
        mirrored.frame = NSRect(
            x: 0,
            y: 0,
            width: paneHost.bounds.width,
            height: max(0, paneHost.bounds.height - findBarInset)
        )
        mirrored.autoresizingMask = [.width, .height]
        paneHost.addSubview(mirrored)
        // Every pane the window shows reaches the tree through here, which is
        // where a bar learns the shape it stands in: a pane opened by a split,
        // adopted from a restored layout, or mirrored from a host has no lift
        // of its own. A bar already at the lift keeps it; the inset ignores a
        // repeat.
        for surface in views.values {
            applyScrollerBottomInset(to: surface)
        }
        // The new chromes start with no report, and the window's band can
        // have gone from the host with the old mirror; the reconcile gives
        // every pane still reporting its slot in the shape it is in now.
        syncProgressChrome()
        refreshPresence()
    }

    /// Whether a pane bar in this window is shown: Pane Title Bars on, and a
    /// window split into two panes or more, whichever authority keeps its
    /// tree.
    ///
    /// A single pane wears no bar: the window title already names what it is
    /// running, and a bar over the only pane repeats it while taking a row of
    /// the grid. The setting is this app's presentation, never a host's.
    var showsPaneTitleBars: Bool {
        Ubiquitty.Preferences.Effective.paneTitleBars(Ubiquitty.Preferences.values().pointee) && transferTree.paneCount() > 1
    }

    /// Shows or hides every pane bar standing in this window by
    /// ``showsPaneTitleBars``, in place.
    ///
    /// A bar is presentation, so a change to the setting moves no pane: each
    /// chrome keeps the view and the session it frames and lays them out
    /// again, which fits the view's grid to the height the bar gave up or
    /// took, and moves a pane's progress band between the bar's bottom edge
    /// and the view's top edge. The bars of a local window, a hosted
    /// workspace and a tmux window all stand under the pane host.
    func applyPaneTitleBars() {
        let shows = showsPaneTitleBars
        var isAnyMoved = false
        for chrome in Self.paneChromesStanding(under: paneHost) where chrome.showsTitleBar != shows {
            chrome.showsTitleBar = shows
            isAnyMoved = true
        }
        guard isAnyMoved else { return }
        refreshPaneChrome()
        syncProgressChrome()
        refreshPresence()
    }

    /// Each pane's badge reports its own surface, including unfocused panes.
    func refreshPanePresence() {
        for chrome in paneChromes {
            guard let surface = chrome.contentView as? TerminalSurface else { continue }
            chrome.updatePresence(
                surface.drive.attendees,
                screenAccesses: surface.drive.screenAccesses,
                hasUnread: surface.drive.hasUnreadScreenAccess
            )
        }
    }

    /// Every pane chrome in a view hierarchy; a chrome frames no other.
    ///
    /// - Parameter view: The root to search under.
    /// - Returns: The chromes, in hierarchy order.
    private static func paneChromesStanding(under view: NSView) -> [PaneChrome] {
        if let chrome = view as? PaneChrome {
            return [chrome]
        }
        return view.subviews.flatMap { paneChromesStanding(under: $0) }
    }

    /// Frames one pane's view in the shared chrome, its bar shown by
    /// ``showsPaneTitleBars``.
    ///
    /// - Parameters:
    ///   - pane: The pane being framed; its id rides both buttons as their tag,
    ///     so one action can tell which pane was clicked.
    ///   - view: The pane's own view.
    ///   - zoomedPane: The pane filling the window alone, if any.
    /// - Returns: The chrome, framing `view`.
    private func paneChrome(
        for pane: Ubiquitty.Session.Layout.PaneID,
        framing view: TerminalSurface,
        zoomedPane: Ubiquitty.Session.Layout.PaneID
    ) -> NSView {
        let chrome = PaneChrome(
            paneID: Int32(pane.rawValue),
            target: self,
            closeAction: #selector(paneChromeClose(_:)),
            expandAction: #selector(paneChromeExpand(_:))
        )
        chrome.showsTitleBar = showsPaneTitleBars
        chrome.contentView = view
        chrome.presenceIndicator.revoke = { [weak view] action, attachmentID, identity in
            view?.drive.revokeConsent(action, attachmentID: attachmentID, identity: identity)
        }
        chrome.presenceIndicator.acknowledgeScreenAccess = { [weak view] cursor in
            view?.drive.acknowledgeScreenAccess(through: cursor)
        }
        chrome.updatePresence(view.drive.attendees, screenAccesses: view.drive.screenAccesses, hasUnread: view.drive.hasUnreadScreenAccess)
        paneChromes.append(chrome)
        // The memo belongs to the bar that was styled, and this is a new one:
        // a rebuilt tree carries the same pane ids, so a memo left standing
        // answers "unchanged" for a bar that has never been given a title.
        paneChromeInputs[chrome.paneID] = nil
        applyPaneChromeStyle(chrome, pane: pane, zoomedPane: zoomedPane)
        return chrome
    }

    /// Rebinds a moved view to the window that owns its chrome and input.
    func adoptTransferredSurface(_ surface: TerminalSurface) {
        surface.removeFromSuperview()
        surface.renderer = windowRenderer
        surface.observer = windowBridge
        surface.metalLayer.isOpaque = !isTranslucent
        hostCellMetricChanges(of: surface)
        surface.linkOpener = { [weak self] uri in LinkOpener.open(uri, from: self?.window) }
    }

    /// Detaches a local pane while keeping its view and running session.
    func extractLocalPane(_ surface: TerminalSurface) -> TerminalWindowController? {
        guard let model = Self.windowModel, let pane = paneID(of: surface), surfaces.count > 1 else { return nil }
        let launch = Ubiquitty.Preferences.Effective.launchSettings()
        guard
            let renderer = TerminalSurface.makeRenderer(
                configuration: Ubiquitty.Preferences.Effective.liveRenderConfiguration(),
                systemTransparency: Self.systemTransparency
            )
        else { return nil }
        let created = model.extractPaneToSurface(workspaceSurface, pane)
        guard created != Ubiquitty.Session.Layout.invalidSurface else { return nil }
        surfaces.removeValue(forKey: pane)
        surface.removeFromSuperview()
        rebuildPaneLayout()
        surface.renderer = renderer
        window?.makeFirstResponder(focusedSurface)
        let controller = TerminalWindowController(
            workspaceSurface: created,
            pane: pane,
            surface: surface,
            renderer: renderer,
            rows: launch.rows,
            columns: launch.columns,
            isGridPinned: launch.isGridPinned
        )
        controller.applyWindowAppearance(launch)
        Self.spawnedControllers.append(controller)
        controller.window?.tabbingMode = .disallowed
        controller.showWindow(nil)
        controller.window?.tabbingMode = .automatic
        controller.window?.makeFirstResponder(surface)
        return controller
    }

    /// Restyles one pane's chrome to the current focus, theme and title.
    ///
    /// The title is baked through the same styling the tab strip uses, so a
    /// pane and a tab naming the same session read the same.
    ///
    /// - Parameters:
    ///   - chrome: The chrome to restyle.
    ///   - pane: The pane it frames.
    ///   - zoomedPane: The pane filling the window alone, if any.
    private func applyPaneChromeStyle(
        _ chrome: PaneChrome,
        pane: Ubiquitty.Session.Layout.PaneID,
        zoomedPane: Ubiquitty.Session.Layout.PaneID
    ) {
        guard let surface = remotePaneSurfaces[pane] ?? surfaces[pane] else { return }
        let isSelected =
            remotePaneSurfaces.isEmpty
            ? (Self.windowModel.map { pane == $0.focusedPane(workspaceSurface) } ?? false)
            : Int32(pane.rawValue) == transferTree.focusedPaneID()
        let foreground = themeForeground(of: surface)
        // Both bars take the plain terminal background, as the tab pills do.
        // Active against inactive reads from the title's own ink, not from a
        // second fill that would have to be kept in step with the theme.
        let background = themeBackground(of: surface)
        let inputs = PaneChromeInputs(
            weave: titleWeaveInputs(for: surface),
            isSelected: isSelected,
            isWindowActive: window.map { WindowTabSelection.isGroupActive($0) } ?? false,
            foreground: foreground,
            background: background,
            isExpanded: pane == zoomedPane,
            isTranslucent: isTranslucent,
            usesSystemTheme: usesSystemTheme,
            shouldIncreaseContrast: SystemDisplayOptions.shouldIncreaseContrast,
            shouldNameHost: paneHeadersNameHost(),
            titleWidth: Int(chrome.titleRoom.rounded(.down)),
            tagRun: paneHeaderTagRun(for: surface, pane: chrome.paneID)
        )
        // Before the memo: a status or a percent moves without the title.
        updatePaneStatusMark(chrome, pane: pane, surface: surface, inputs: inputs)
        if paneChromeInputs[chrome.paneID] == inputs {
            return
        }
        paneChromeInputs[chrome.paneID] = inputs
        paneChromeRestylesForTesting += 1
        // The pane's own composition, not the tab's: a pane header woven from
        // the tab's settings answered none of the pane_* toggles it offers.
        let woven = wovenTitle(for: surface, as: .pane)
        let ground = usesSystemTheme || isTranslucent ? NSColor.windowBackgroundColor : NSColor(packedRGB: background)
        // The tab's fitting, against the bar's room: the directory and the
        // processes give way before the program's own title and its icon.
        // The pane's tags lead it as the window's lead the tab's: the tags
        // first, then the program's icon, then the words.
        let bake = { (label: String, lead: String) -> NSAttributedString in
            TabTagMarks.title(
                ProcessIcons.title(
                    TabTitleStyling.attributedTitle(
                        label,
                        lead: lead,
                        markPrefix: woven.markPrefix,
                        isSelected: isSelected,
                        isWindowActive: inputs.isWindowActive,
                        foreground: foreground,
                        background: background,
                        usesNativeColors: self.isTranslucent || self.usesSystemTheme,
                        fontSize: NSFont.systemFontSize,
                        dimensions: woven.dimensions
                    ),
                    leadingWith: inputs.weave.processIconKey,
                    ground: ground
                ),
                leadingWith: inputs.tagRun
            )
        }
        if chrome.titleRoomDidChange == nil {
            chrome.titleRoomDidChange = { [weak self, weak chrome] in
                guard let self, let chrome, let pane = Ubiquitty.Session.Layout.PaneID(rawValue: UInt32(chrome.paneID)) else { return }
                self.applyPaneChromeStyle(chrome, pane: pane, zoomedPane: self.paneChromeZoomedPane)
            }
        }
        chrome.apply(
            title: Self.fitted(bake(woven.title, woven.lead), steps: woven.fitting, width: inputs.titleWidth, bake: bake),
            background: isTranslucent ? .clear : (usesSystemTheme ? .windowBackgroundColor : NSColor(packedRGB: background)),
            tint: isTranslucent || usesSystemTheme
                ? .secondaryLabelColor : NSColor(packedRGB: foreground).withAlphaComponent(isSelected ? 1.0 : 0.55),
            isExpanded: pane == zoomedPane
        )
    }

    /// What each pane last reported, and whether it is news: a status that
    /// arrives in a pane the reader is not looking at is unseen until that
    /// pane is focused in the tab on screen.
    private struct PaneStatusNews {
        var status: HostOutlineStatus = .none
        var blockKind: HostOutlineBlockKind = .none
        var isUnseen = false
    }

    private var paneStatusNews: [Int32: PaneStatusNews] = [:]

    /// Puts a pane's status in its bar's mark, as a tab's accessory shows a
    /// tab's: its own OSC 9;4 report as the circular indicator, a working
    /// program as the ellipsis, either left to the pane's band while the pane
    /// is focused, and any other status as its symbol in its theme colour,
    /// glowing until seen.
    ///
    /// - Parameters:
    ///   - chrome: The bar.
    ///   - pane: The pane it frames.
    ///   - surface: The pane's surface.
    ///   - inputs: What the bar was styled from.
    private func updatePaneStatusMark(
        _ chrome: PaneChrome,
        pane: Ubiquitty.Session.Layout.PaneID,
        surface: TerminalSurface,
        inputs: PaneChromeInputs
    ) {
        let published = surface.drive.readSnapshot()
        let status = HostOutlineStatus(rawValue: published.programStatusKind) ?? .none
        let blockKind = HostOutlineBlockKind(rawValue: published.programBlockKind) ?? .none
        var news = paneStatusNews[chrome.paneID] ?? PaneStatusNews()
        // A blocked program that comes to wait for something else has news too.
        if status != news.status || blockKind != news.blockKind {
            news = PaneStatusNews(status: status, blockKind: blockKind, isUnseen: status != .none)
        }
        let isInView = inputs.isSelected && (window?.tabGroup?.selectedWindow ?? window) === window
        if isInView {
            news.isUnseen = false
        }
        paneStatusNews[chrome.paneID] = news
        let ringInk = TabTitleStyling.accessoryInk(
            .ProgressRing,
            isSelected: inputs.isSelected,
            isWindowActive: inputs.isWindowActive,
            foreground: inputs.foreground,
            background: inputs.background,
            usesNativeColors: inputs.isTranslucent || inputs.usesSystemTheme
        )
        let content: TabStatusMark.Content
        if published.progressState != 0 {
            content = inputs.isSelected ? .none : .progress(state: published.progressState, value: published.progressValue, ink: ringInk)
        } else {
            switch status {
            case .none: content = .none
            // A working record's percent fills the ring; with none, the ellipsis.
            case .working where published.programProgress >= 0:
                content =
                    inputs.isSelected
                    ? .none
                    : .progress(state: UInt8(Ubiquitty.OSC.ProgressNormal.rawValue), value: UInt8(published.programProgress), ink: ringInk)
            case .working: content = inputs.isSelected ? .none : .working(ink: ringInk)
            default:
                let colour = surface.drive.tabStatusColor()
                let ink =
                    colour.isSet
                    ? NSColor(
                        srgbRed: CGFloat(colour.red) / 255,
                        green: CGFloat(colour.green) / 255,
                        blue: CGFloat(colour.blue) / 255,
                        alpha: 1
                    )
                    : NSColor(packedRGB: inputs.foreground)
                content = .status(status, blockKind: blockKind, ink: ink)
            }
        }
        chrome.statusMark.show(content, isUnseen: news.isUnseen && content != .none)
    }

    /// Closes the pane whose chrome button was clicked.
    ///
    /// - Parameter sender: The button, carrying its pane's id as its tag.
    @objc
    private func paneChromeClose(_ sender: NSButton) {
        guard let pane = Ubiquitty.Session.Layout.PaneID(rawValue: UInt32(sender.tag)),
            let surface = surfaces[pane] ?? remotePaneSurfaces[pane]
        else {
            return
        }
        guard surface.drive.requestPaneVerb(.close) == .localActionRequired else { return }
        closePane(surface)
    }

    /// Zooms, or un-zooms, the pane whose chrome button was clicked.
    ///
    /// The model zooms whichever pane holds focus, so the click moves focus
    /// there first: clicking a background pane's expand button otherwise zooms
    /// the pane the reader was last in, which is not the one they pointed at.
    ///
    /// - Parameter sender: The button, carrying its pane's id as its tag.
    @objc
    private func paneChromeExpand(_ sender: NSButton) {
        guard let pane = Ubiquitty.Session.Layout.PaneID(rawValue: UInt32(sender.tag)) else {
            return
        }
        if let surface = remotePaneSurfaces[pane] {
            _ = surface.drive.requestPaneVerb(.zoom)
            return
        }
        _ = focusPane(withIdentifier: Int(pane.rawValue))
        toggleZoomPane(sender)
    }

    private func mirrorNode(
        _ tree: Ubiquitty.Panes.Tree,
        _ index: Int32,
        _ views: [Ubiquitty.Session.Layout.PaneID: TerminalSurface],
        _ zoomed: Ubiquitty.Session.Layout.PaneID
    ) -> NSView {
        let node = tree.node(index)
        if tree.isLeaf(index) {
            guard let pane = Ubiquitty.Session.Layout.PaneID(rawValue: UInt32(node.paneID)), let view = views[pane] else {
                return NSView(frame: .zero)
            }
            return paneChrome(for: pane, framing: view, zoomedPane: zoomed)
        }
        let split = NSSplitView(frame: .zero)
        split.dividerStyle = .thin
        // AppKit's NSSplitView is "vertical" when its divider is — children
        // side-by-side — which is Core's Vertical orientation too.
        split.isVertical = node.orientation == .Vertical
        split.delegate = self
        split.addArrangedSubview(mirrorNode(tree, node.first, views, zoomed))
        split.addArrangedSubview(mirrorNode(tree, node.second, views, zoomed))
        splitNodes[ObjectIdentifier(split)] = index
        split.layoutSubtreeIfNeeded()
        let extent = split.isVertical ? split.bounds.width : split.bounds.height
        if extent > 0 {
            split.setPosition(extent * CGFloat(node.ratio), ofDividerAt: 0)
        }
        return split
    }

    /// A divider drag writes the first child's fraction back to the model's
    /// node, so the layout survives the next rebuild — the ratio is the
    /// model's state, not the view's.
    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard (notification.userInfo?["NSSplitViewUserResizeKey"] as? NSNumber)?.boolValue == true,
            let split = notification.object as? NSSplitView,
            let index = splitNodes[ObjectIdentifier(split)],
            let first = split.arrangedSubviews.first
        else {
            return
        }
        let extent = split.isVertical ? split.bounds.width : split.bounds.height
        let firstExtent = split.isVertical ? first.frame.width : first.frame.height
        guard extent > 0 else { return }
        if let root = remoteSurface, root.drive.remoteWorkspaceTab != Ubiquitty.Session.Layout.invalidTab {
            scheduleRemoteDividerRatio(splitIndex: index, ratio: Float(firstExtent / extent))
            return
        }
        _ = Self.windowModel?.setDividerRatio(workspaceSurface, index, Float(firstExtent / extent))
    }

    /// Applies the authoritative divider ratio when AppKit resizes the window.
    public func splitView(_ split: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard let index = splitNodes[ObjectIdentifier(split)], split.arrangedSubviews.count == 2 else {
            split.adjustSubviews()
            return
        }
        let ratio: CGFloat
        if let drive = remoteSurface?.drive, drive.remoteWorkspaceTab != Ubiquitty.Session.Layout.invalidTab {
            let tree = drive.remoteWorkspacePaneTreeSnapshot(of: drive.remoteWorkspaceSurface, tab: drive.remoteWorkspaceTab)
            ratio = CGFloat(tree.node(index).ratio)
        } else if let model = Self.windowModel {
            ratio = CGFloat(model.paneTreeSnapshot(workspaceSurface).node(index).ratio)
        } else {
            return
        }
        let bounds = split.bounds
        let extent = split.isVertical ? bounds.width : bounds.height
        let divider = min(split.dividerThickness, max(0, extent))
        let first = min(max(0, (extent * ratio).rounded()), max(0, extent - divider))
        let second = max(0, extent - first - divider)
        if split.isVertical {
            split.arrangedSubviews[0].frame = NSRect(x: bounds.minX, y: bounds.minY, width: first, height: bounds.height)
            split.arrangedSubviews[1].frame = NSRect(x: bounds.minX + first + divider, y: bounds.minY, width: second, height: bounds.height)
        } else {
            split.arrangedSubviews[0].frame = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: first)
            split.arrangedSubviews[1].frame = NSRect(x: bounds.minX, y: bounds.minY + first + divider, width: bounds.width, height: second)
        }
    }

    /// Builds a window over one surface: a model pane's view, or a hosted
    /// surface whose session another authority feeds.
    ///
    /// - Parameters:
    ///   - workspaceSurface: The window's surface in the model, or
    ///     `invalidSurface` for a hosted window.
    ///   - pane: The model pane the surface projects, or nil for a hosted
    ///     surface — it fills the window directly, outside the pane map.
    ///   - surface: The view over the pane's session.
    ///   - renderer: The renderer every pane of this window draws through.
    ///   - rows: The launch grid's rows, sizing the window.
    ///   - columns: The launch grid's columns, likewise.
    ///   - isGridPinned: Whether the config pinned the grid, in which case
    ///     the remembered frame is not applied — it names no grid.
    init(
        workspaceSurface: Ubiquitty.Session.Layout.SurfaceID,
        pane: Ubiquitty.Session.Layout.PaneID?,
        surface: TerminalSurface,
        renderer: any TerminalSurfaceRenderer,
        rows: Int,
        columns: Int,
        isGridPinned: Bool = false
    ) {
        Self.followConfiguration()
        surfaceRenderer = renderer
        self.workspaceSurface = workspaceSurface
        if let pane {
            surfaces[pane] = surface
        }
        let cell = renderer.cellSize(for: surface)
        let insets = renderer.gridFitInsets(for: surface)
        let contentSize = NSSize(
            width: cell.width * Double(columns) + insets.left + insets.right,
            height: cell.height * Double(rows) + insets.top + insets.bottom
        )
        let window = SquareBottomWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .automatic
        window.collectionBehavior = TerminalWindowController.terminalCollectionBehavior
        // No `contentResizeIncrements` here: `windowWillResize(_:to:)` is the
        // one quantiser, and AppKit applies increments first, before the
        // delegate sees the size. The two disagree by construction — increments
        // step from whatever extent the window happens to have, while the
        // delegate snaps the content box to whole cells with the padding
        // reserved — so a drag under both lands between their answers, on a
        // content box that is not a whole grid, and the layer shows the
        // shortfall at its edge. Increments also quantise the sizes the
        // delegate leaves exact because nobody is dragging them: a programmatic
        // resize, a zoom, a full-screen transition.
        // The app manages its own geometry: AppKit's state restoration reopens
        // windows at a stale bottom-left frame and fights the sizing below.
        window.isRestorable = false
        // A pinned grid keeps the size computed above; the remembered frame
        // is a by-product of a drag and names no grid.
        if isGridPinned {
            window.center()
        } else {
            WindowFrameMemory.place(window, cascadingFrom: WindowFrameMemory.visibleTerminalWindowCount() > 0)
        }
        paneHost.frame = NSRect(origin: .zero, size: contentSize)
        paneHost.autoresizingMask = [.width, .height]
        window.contentView = paneHost
        super.init(window: window)
        window.delegate = self
        PaneTransferCoordinator.shared.install()
        observeContentFrameForTabStrip(paneHost)
        let bridge = SurfaceWindowBridge(controller: self)
        self.bridge = bridge
        surface.observer = bridge
        hostCellMetricChanges(of: surface)
        // Core learns a font family from an OSC 50 SET and from nowhere else,
        // so a session whose frontend never publishes one answers the `?` query
        // with the empty string until a program happens to set a font. Seeded
        // with whatever the renderer ended up with, which is the only answer
        // worth reporting: the configured name is what was asked for, and the
        // store may have substituted for it.
        if let renderer = surface.renderer as? SurfaceRenderer {
            surface.drive.publishActualFont(family: renderer.familyName, sizePoints: renderer.pointSize)
        }
        // The terminal has already decided that this click opens this one uri.
        // What receives it is `LinkOpener`'s chain, Welcome screen buttons
        // first; the window is where a button that asks before it writes puts
        // its question.
        surface.linkOpener = { [weak self] uri in
            LinkOpener.open(uri, from: self?.window)
        }
        if pane != nil {
            rebuildPaneLayout()
        } else {
            // A hosted root joins the window with no pane layout, so its bar
            // learns the shape here rather than at the first settings change;
            // a pane's bar learns it where the layout places it.
            applyScrollerBottomInset(to: surface)
            surface.frame = paneHost.bounds
            surface.autoresizingMask = [.width, .height]
            paneHost.addSubview(surface)
        }
        // Last, because it reads the window it decorates and the pane whose
        // title it styles, and both have to be standing first.
        installTitlebarIdentity()
    }

    /// The tmux-hosting shape: an empty window the layout apply fills. The
    /// size is provisional — tmux reports the grid, and the first layout
    /// pass lays panes into whatever the window shows.
    ///
    /// - Parameter tmuxRenderer: The renderer every hosted pane draws through.
    init(tmuxRenderer: any TerminalSurfaceRenderer) {
        Self.followConfiguration()
        surfaceRenderer = tmuxRenderer
        let window = SquareBottomWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .automatic
        window.collectionBehavior = TerminalWindowController.terminalCollectionBehavior
        // The app manages its own geometry: AppKit's state restoration reopens
        // windows at a stale bottom-left frame and fights the sizing below.
        window.isRestorable = false
        WindowFrameMemory.place(window, cascadingFrom: WindowFrameMemory.visibleTerminalWindowCount() > 0)
        paneHost.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        paneHost.autoresizingMask = [.width, .height]
        window.contentView = paneHost
        super.init(window: window)
        window.delegate = self
        PaneTransferCoordinator.shared.install()
        observeContentFrameForTabStrip(paneHost)
        let bridge = SurfaceWindowBridge(controller: self)
        self.bridge = bridge
        installTitlebarIdentity()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("TerminalWindowController is created in code, never from a nib")
    }
}

/// The `[keys]`-changed notice, for Objective-C: the app delegate posts it and
/// Objective-C views observe it, and the name they use is the one the Kit's
/// surfaces watch.
@MainActor
@objc(UBKeyBindingNotice)
public final class KeyBindingNotice: NSObject {
    /// The notification posted when the `[keys]` configuration changes.
    @objc
    public static var didChangeNotificationName: String {
        TerminalSurface.keyBindingsDidChangeNotification.rawValue
    }
}

/// The process-wide password-prompt fact, for the app delegate's secure-input
/// policy: the delegate imports this module and not the render kit, where
/// the registry both shells report into lives.
@MainActor
@objc(UBPasswordPrompts)
public final class PasswordPrompts: NSObject {
    /// Whether any pane, in either shell, is at a password prompt.
    @objc
    public static var hasActivePrompt: Bool { PasswordPromptRegistry.shared.hasActivePrompt }

    /// The notification posted when ``hasActivePrompt`` may have changed.
    @objc
    public static var didChangeNotificationName: String { PasswordPromptRegistry.didChangeNotification.rawValue }
}
