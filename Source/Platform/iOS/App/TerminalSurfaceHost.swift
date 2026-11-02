// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Metal
import SwiftUI
import UIKit
import UbiquittyKit

/// Puts the shared terminal surface on screen.
///
/// The surface is the whole terminal — Core's model, the Metal renderer, the glyph
/// atlas, the cursor, colour and ligatures — and it is the same one the macOS
/// app draws. What this file adds is a UIKit host and a wire to the carrier:
/// bytes the connection delivers go in through `feed`, bytes the terminal wants
/// to send come out through the observer, and nothing between them is written
/// twice.
///
/// A view controller rather than a bare view: relative pointer lock (DECSET
/// 7403) is answered through `UIViewController.prefersPointerLocked`, which
/// only a controller can override, and ``TerminalSurfaceViewController``
/// is the one that owns the surface for it.
struct TerminalSurfaceHost: UIViewControllerRepresentable {
    let session: TerminalSessionModel
    /// The workspace pane to draw, or nil for the focused one.
    ///
    /// A host given a pane draws that pane whether or not it has focus, which
    /// is what lets two stand side by side; a host given none follows focus.
    var paneID: UInt32?
    /// Stable accessibility identity for the compact host or a named companion.
    var accessibilityIdentifier = "terminal-surface"

    func makeUIViewController(context: Context) -> UIViewController {
        let container = PaneSurfaceContainer(hosted: nil)
        updateContainer(container)
        return container
    }

    private func updateContainer(_ container: PaneSurfaceContainer) {
        // The session's own surface, not one built here: the directory errand
        // that lists a host's sessions runs before any terminal is on screen
        // and needs a surface to run through, and the attach that follows has
        // to happen on the one the terminal draws.
        let requestedSurface = paneID.map { session.surface(forPane: $0) } ?? session.surfaceForDrawing()
        container.editingSession = session
        container.view.backgroundColor = session.groundColor
        guard let surface = requestedSurface else {
            container.replaceHosted(with: nil)
            container.onTouched = nil
            return
        }
        // The surface draws with Metal, so what a reader gets is not the
        // pixels but the surface's own text projection, served as its
        // accessibility value — and only if the view is an element at all:
        // a plain UIView reaches the accessibility tree only by being one.
        surface.isAccessibilityElement = true
        surface.accessibilityLabel = "Terminal"
        surface.accessibilityIdentifier = accessibilityIdentifier
        container.replaceHosted(with: session.controller(for: surface))
        if paneID != nil {
            // With the keyboard down a tap already asks for it, and the model
            // moves focus on that ask; with it up a tap is a click, and this is
            // what moves focus to the pane that was clicked.
            let identity = ObjectIdentifier(surface)
            container.onTouched = { [weak session] in session?.focusPane(showing: identity) }
        } else {
            container.onTouched = nil
        }
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        // The strip a fractional cell leaves at the grid's edge shows this,
        // so it is the terminal's ground and follows a theme change.
        guard let container = controller as? PaneSurfaceContainer else { return }
        updateContainer(container)
        container.claimIfUnheld()
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: ()) {
        (controller as? PaneSurfaceContainer)?.relinquish()
    }

    // Focus belongs to the model. SwiftUI can still update an outgoing host
    // after selecting the next pane; such an update must never adopt the old
    // surface again or route input away from the selected pane.
}

/// The focused pane, or two panes side by side when the window is wide.
///
/// A regular-width window — the inner display of iPhone Duo, an iPad —
/// shows one more level of the workspace than a compact one: the focused
/// pane and the one beside it. The system's arrangement view lays the pair
/// out, side by side when the space is wider than tall and one above the
/// other when it is taller, and moves each clear of the fold when the
/// device is partially folded. It arrived with iOS 27.1; a 27.0 device
/// lays the same pair out by the space's shape alone, which is the whole
/// of what a device with no fold needs from it.
///
/// A compact window shows the focused pane alone, through one host
/// whichever pane has focus: a focus change hands the host's container the
/// newly focused pane's surface, so a surface that keeps focus never leaves
/// its window. A host keyed on the focused pane is rebuilt when the first
/// workspace listing after an attach focuses the pane the attach already
/// draws, and the rebuilt host takes that surface out of its window and puts
/// it back, which tells the host the pane was hidden and shown again.
struct TerminalPaneLayout: View {
    let session: TerminalSessionModel

    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular, let pair = session.arrangedPanePair {
            if #available(iOS 27.1, *) {
                ArrangementView {
                    arrangedPane(pair.primary)
                } secondary: {
                    arrangedPane(pair.secondary)
                }
                .arrangementViewStyle(.split)
            } else {
                GeometryReader { space in
                    let layout: AnyLayout =
                        space.size.width >= space.size.height ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                    layout {
                        arrangedPane(pair.primary)
                        arrangedPane(pair.secondary)
                    }
                }
            }
        } else {
            TerminalSurfaceHost(session: session, paneID: session.activePaneID == 0 ? nil : session.activePaneID)
        }
    }

    /// One of two panes on screen, marked when it has focus.
    ///
    /// The mark is the one thing that tells two identical grids apart: which
    /// of them the keyboard types into. A tap on the other moves focus there.
    private func arrangedPane(_ id: UInt32) -> some View {
        let isFocused = id == session.activePaneID
        return TerminalSurfaceHost(session: session, paneID: id, accessibilityIdentifier: "terminal-surface-\(id)")
            .id(id)
            .overlay {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(isFocused ? 1 : 0), lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .onAppear { if !isFocused { session.visibleCompanionPaneID = id } }
            .onChange(of: isFocused) { _, focused in
                if !focused { session.visibleCompanionPaneID = id }
            }
            .onDisappear {
                if session.visibleCompanionPaneID == id { session.visibleCompanionPaneID = nil }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(isFocused ? "Focused pane" : "Pane")
    }
}

/// Hosts a surface's one controller for as long as this host is the latest to
/// ask for it.
///
/// A surface is a view, and a view belongs to at most one view controller. A
/// window changing width class — iPhone Duo opening, a large iPhone turning —
/// can build the new host for a pane before it takes the old one down, so each
/// host embeds the surface's single controller as a child instead of making a
/// second one. The newest host claims it; an older one gives it back only if it
/// still holds it, so tearing down the old host never takes the surface out of
/// the new one.
final class PaneSurfaceContainer: UIViewController {
    private(set) var hosted: TerminalSurfaceViewController?
    weak var editingSession: TerminalSessionModel?

    override var keyCommands: [UIKeyCommand]? {
        TerminalKeyInputView.editingCommands + TerminalTabCommands.commands + TerminalFindCommands.commands
    }

    @objc
    func performFindCommand(_ command: UIKeyCommand) {
        guard hosted?.parent === self, let editingSession else { return }
        TerminalFindCommands.perform(command, on: editingSession)
    }

    @objc
    func performTabCommand(_ command: UIKeyCommand) {
        guard hosted?.parent === self, let editingSession else { return }
        TerminalTabCommands.perform(command, on: editingSession)
    }

    @objc
    func performWorkspaceCommand(_ command: UIKeyCommand) {
        guard hosted?.parent === self, let editingSession else { return }
        TerminalWorkspaceCommands.perform(command, on: editingSession)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard hosted?.parent === self, let editingSession else { return false }
        switch action {
        case #selector(performWorkspaceCommand(_:)):
            guard let command = sender as? UIKeyCommand else { return false }
            return TerminalWorkspaceCommands.isEnabled(command, on: editingSession)
        case #selector(paste(_:)): return editingSession.canPasteClipboard
        case #selector(copy(_:)): return editingSession.hasSelection
        case #selector(selectAll(_:)): return true
        default: return super.canPerformAction(action, withSender: sender)
        }
    }

    override func paste(_ sender: Any?) {
        guard hosted?.parent === self else { return }
        editingSession?.requestClipboardPaste()
    }

    override func copy(_ sender: Any?) {
        guard hosted?.parent === self else { return }
        editingSession?.copySelection()
    }

    override func selectAll(_ sender: Any?) {
        guard hosted?.parent === self else { return }
        editingSession?.selectAll()
    }

    init(hosted: TerminalSurfaceViewController?) {
        self.hosted = hosted
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneSurfaceContainer has no archived representation")
    }

    /// Called when a tap lands anywhere on the hosted surface.
    var onTouched: (@MainActor () -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        claim()
        let tap = UITapGestureRecognizer(target: self, action: #selector(surfaceWasTapped))
        // Observes and never takes: the surface's own recognizers still
        // decide what the tap means to the terminal.
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    @objc
    private func surfaceWasTapped() {
        onTouched?()
    }

    /// Relative pointer lock is the hosted controller's to answer: it reads
    /// Core's verdict for the surface it hosts.
    override var childViewControllerForPointerLock: UIViewController? { hosted?.parent === self ? hosted : nil }

    /// A host can keep its SwiftUI identity while reconnect replaces the
    /// surface behind a pane ID. Its child must follow that new binding.
    func replaceHosted(with replacement: TerminalSurfaceViewController?) {
        guard hosted !== replacement else { return }
        relinquish()
        hosted = replacement
        if isViewLoaded { claim() }
    }

    /// Takes the surface's controller from whichever host held it last.
    func claim() {
        guard let hosted, hosted.parent !== self else { return }
        if hosted.parent != nil {
            hosted.willMove(toParent: nil)
            hosted.view.removeFromSuperview()
            hosted.removeFromParent()
        }
        addChild(hosted)
        hosted.view.frame = view.bounds
        hosted.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosted.view)
        hosted.didMove(toParent: self)
        setNeedsUpdateOfPrefersPointerLocked()
    }

    /// Takes the surface's controller back when no host holds it — a newer
    /// host that claimed it has since been torn down — and never from a
    /// host that does, so an old host updated during a transition cannot
    /// take the surface out of the new one.
    func claimIfUnheld() {
        if hosted?.parent == nil {
            claim()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        claimIfUnheld()
    }

    /// Gives the surface's controller back, if this host still holds it.
    func relinquish() {
        guard let hosted, hosted.parent === self else { return }
        hosted.willMove(toParent: nil)
        hosted.view.removeFromSuperview()
        hosted.removeFromParent()
    }
}

extension PaneSurfaceContainer: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
