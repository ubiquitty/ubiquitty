// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+UIKitSelection.swift — a selection a finger can see and move.
//
// What is selected is Core's, by the same pointer facts a mouse sends: a
// handle dragged is a press at the far end of the selection and a drag to the
// finger, marked as the platform's selection gesture so a program reading the
// mouse never hears it. What lives here is the touch shell's furniture — the
// two lollipops at the ends, placed from the spans the frame drew, the
// system loupe over the end a finger moves, and the edit menu's entries
// beyond the responder chain's Copy, Paste and Select All.

#if canImport(UIKit)

import UIKit
internal import UbiquittyCore

/// The two handles at a selection's ends.
@MainActor
internal final class SelectionHandles {
    let start: SelectionHandleView
    let end: SelectionHandleView

    init(surface: TerminalSurface) {
        start = SelectionHandleView(isStart: true)
        end = SelectionHandleView(isStart: false)
        for handle in [start, end] {
            handle.isHidden = true
            let drag = UIPanGestureRecognizer(target: surface, action: #selector(TerminalSurface.handleSelectionHandleDrag(_:)))
            drag.maximumNumberOfTouches = 1
            handle.addGestureRecognizer(drag)
            surface.addSubview(handle)
        }
    }
}

/// One lollipop: a bar the height of a row, with a knob beyond the text.
///
/// Drawn in the tint colour, as every iOS text selection's handles are. The
/// view is wider and taller than what it draws, so the finger has a target of
/// the size the HIG asks for while the bar stays one point wide.
internal final class SelectionHandleView: UIView {
    let isStart: Bool
    /// The bar's height: the row it marks.
    var barHeight: CGFloat = 16 {
        didSet { setNeedsLayout() }
    }
    private let bar = UIView()
    private let knob = UIView()
    static let knobDiameter: CGFloat = 10
    static let touchWidth: CGFloat = 44

    init(isStart: Bool) {
        self.isStart = isStart
        super.init(frame: .zero)
        isAccessibilityElement = false
        for part in [bar, knob] {
            part.backgroundColor = tintColor
            part.isUserInteractionEnabled = false
            addSubview(part)
        }
        knob.layer.cornerRadius = Self.knobDiameter / 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SelectionHandleView has no archived representation")
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        bar.backgroundColor = tintColor
        knob.backgroundColor = tintColor
    }

    /// Places the handle with its bar on a cell edge.
    ///
    /// - Parameters:
    ///   - x: The edge, in the surface's coordinates.
    ///   - rowTop: The top of the row the bar spans.
    ///   - rowHeight: The row's height.
    func place(x: CGFloat, rowTop: CGFloat, rowHeight: CGFloat) {
        barHeight = rowHeight
        let height = rowHeight + Self.knobDiameter + 12
        // The start's knob sits above its row and the end's below, as the
        // system's handles do, so neither covers the text it bounds.
        let top = isStart ? rowTop - Self.knobDiameter - 6 : rowTop - 6
        frame = CGRect(x: x - Self.touchWidth / 2, y: top, width: Self.touchWidth, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let midX = bounds.midX
        let barTop = isStart ? Self.knobDiameter + 6 : 6
        bar.frame = CGRect(x: midX - 1, y: barTop, width: 2, height: barHeight)
        let knobY = isStart ? barTop - Self.knobDiameter + 1 : barTop + barHeight - 1
        knob.frame = CGRect(x: midX - Self.knobDiameter / 2, y: knobY, width: Self.knobDiameter, height: Self.knobDiameter)
    }

    /// The point on the text the bar marks: the middle of its row, on its edge.
    var markedPoint: CGPoint {
        CGPoint(x: frame.midX, y: frame.minY + (isStart ? Self.knobDiameter + 6 : 6) + barHeight / 2)
    }
}

/// Adds the touch shell's entries to the edit menu.
///
/// The responder chain already offers Copy, Paste and Select All; these need
/// the selected text itself, and a link needs the point the menu opened at.
@MainActor
internal final class SurfaceEditMenuDelegate: NSObject, @MainActor UIEditMenuInteractionDelegate {
    weak var surface: TerminalSurface?

    init(surface: TerminalSurface) {
        self.surface = surface
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let surface else { return UIMenu(children: suggestedActions) }
        var extra: [UIMenuElement] = []
        let point = configuration.sourcePoint
        let selected = surface.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if surface.link(atViewPoint: point, isCommandHeld: true) != nil {
            extra.append(
                UIAction(title: String(localized: "Open Link"), image: UIImage(systemName: "safari")) { [weak surface] _ in
                    var command = SurfaceModifiers()
                    command.hasCommand = true
                    _ = surface?.openLink(atViewPoint: point, modifiers: command)
                }
            )
        } else if let url = URL(string: selected), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            extra.append(
                UIAction(title: String(localized: "Open Link"), image: UIImage(systemName: "safari")) { _ in
                    UIApplication.shared.open(url)
                }
            )
        }
        if let text = surface.selectedText, !text.isEmpty {
            let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty, !term.contains("\n"), term.count <= 64 {
                extra.append(
                    UIAction(title: String(localized: "Look Up"), image: UIImage(systemName: "character.book.closed")) {
                        [weak surface] _ in
                        surface?.presentFromHost(UIReferenceLibraryViewController(term: term))
                    }
                )
            }
            extra.append(
                UIAction(title: String(localized: "Share…"), image: UIImage(systemName: "square.and.arrow.up")) {
                    [weak surface] _ in
                    guard let surface else { return }
                    let share = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = surface
                    share.popoverPresentationController?.sourceRect = CGRect(origin: configuration.sourcePoint, size: .zero)
                    surface.presentFromHost(share)
                }
            )
        }
        return UIMenu(children: suggestedActions + extra)
    }
}

extension TerminalSurface {
    /// Installs the handles and the edit menu's entries.
    ///
    /// Called once, with the touch gestures.
    internal func installSelectionAffordances() {
        selectionHandles = SelectionHandles(surface: self)
        let delegate = SurfaceEditMenuDelegate(surface: self)
        editMenuDelegate = delegate
        if let editMenuInteraction { removeInteraction(editMenuInteraction) }
        let interaction = UIEditMenuInteraction(delegate: delegate)
        addInteraction(interaction)
        editMenuInteraction = interaction
    }

    /// Places the handles on the ends of the selection the last frame drew,
    /// or hides them when it drew none.
    internal func layoutSelectionHandles() {
        guard let handles = selectionHandles else { return }
        guard let ends = selectionModel.visibleEnds, let renderer else {
            handles.start.isHidden = true
            handles.end.isHidden = true
            return
        }
        let cell = renderer.drawnCellSize(for: self)
        guard cell.width > 0, cell.height > 0 else { return }
        let insets = renderer.gridInsets(for: self)
        func rowTop(_ row: Int) -> CGFloat { insets.top + CGFloat(row) * cell.height + verticalOverscroll }
        handles.start.place(
            x: insets.left + CGFloat(ends.start.column) * cell.width,
            rowTop: rowTop(ends.start.row),
            rowHeight: cell.height
        )
        handles.end.place(
            x: insets.left + CGFloat(ends.end.column + 1) * cell.width,
            rowTop: rowTop(ends.end.row),
            rowHeight: cell.height
        )
        handles.start.isHidden = false
        handles.end.isHidden = false
    }

    /// Moves one end of the selection under the finger, the other held.
    ///
    /// A press at the held end and a drag to the finger, as a mouse would
    /// make it: Core decides what lies between, wide glyphs and wrapped rows
    /// included. The finger is read a little above where it touches, so the
    /// row being chosen is not the one under the fingertip.
    ///
    /// - Parameter recognizer: The handle's drag.
    @objc
    internal func handleSelectionHandleDrag(_ recognizer: UIPanGestureRecognizer) {
        guard let dragged = recognizer.view as? SelectionHandleView else { return }
        var finger = recognizer.location(in: self)
        finger.y -= dragged.barHeight / 2
        let phase: SelectionDragPhase
        switch recognizer.state {
        case .began: phase = .began
        case .changed: phase = .moved
        case .ended: phase = .ended
        case .cancelled, .failed:
            moveSelectionHandle(isStart: dragged.isStart, phase: .ended, to: finger, offersMenu: false)
            return
        default: return
        }
        moveSelectionHandle(isStart: dragged.isStart, phase: phase, to: finger)
    }

    /// The handle-drag rule, on a phase and a point rather than a recogniser.
    ///
    /// - Parameters:
    ///   - isStart: Whether the start handle is the one moving.
    ///   - phase: Where the drag has got to.
    ///   - point: Where the finger asks the end to be, in view coordinates.
    ///   - offersMenu: Whether a finished drag offers the edit menu.
    internal func moveSelectionHandle(isStart: Bool, phase: SelectionDragPhase, to point: CGPoint, offersMenu: Bool = true) {
        guard let handles = selectionHandles else { return }
        let held = isStart ? handles.end : handles.start
        switch phase {
        case .began:
            UISelectionFeedbackGenerator().selectionChanged()
            editMenuInteraction?.dismissMenu()
            forwardSelectionFact(.press, at: held.markedPoint)
            forwardSelectionFact(.motion, at: point)
        case .moved:
            forwardSelectionFact(.motion, at: point)
        case .ended:
            forwardSelectionFact(.release, at: point)
        }
        followSelectionWithLoupe(phase, at: point, from: isStart ? handles.start : handles.end)
        if phase == .ended, offersMenu { presentEditMenu(atViewPoint: point) }
    }

    /// Shows the system loupe over the selection end a finger moves, keeps it
    /// over that end, and puts it away.
    ///
    /// The loupe is UIKit's, and it magnifies this view as the screen shows
    /// it, so what it enlarges is the cells the Metal layer drew. It tracks a
    /// caret on the row under the finger rather than the fingertip itself:
    /// the row the end lands on is the one the finger covers, and snapping to
    /// it keeps the loupe steady while the finger wavers inside the row.
    /// UIKit presents, moves and dismisses it, with the motion every text
    /// view's loupe has, so Reduce Motion applies to it as it does there.
    ///
    /// - Parameters:
    ///   - phase: Where the drag has got to. A loupe begun twice replaces the
    ///     first; one ended or moved without having begun does nothing.
    ///   - point: The touch, in view coordinates.
    ///   - widget: The handle being dragged, which the loupe grows from; nil
    ///     when a hold makes the selection.
    internal func followSelectionWithLoupe(_ phase: SelectionDragPhase, at point: CGPoint, from widget: UIView? = nil) {
        switch phase {
        case .began:
            selectionLoupe?.invalidate()
            selectionLoupe = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: widget, in: self)
            selectionLoupe?.move(to: point, withCaretRect: selectionLoupeCaret(atViewPoint: point), trackingCaret: true)
        case .moved:
            selectionLoupe?.move(to: point, withCaretRect: selectionLoupeCaret(atViewPoint: point), trackingCaret: true)
        case .ended:
            selectionLoupe?.invalidate()
            selectionLoupe = nil
        }
        #if UBIQUITTY_IOS_UI_TESTS
        noteSelectionLoupe(phase, caret: selectionLoupeCaret(atViewPoint: point))
        #endif
    }

    /// The caret the loupe tracks for a selection end under a point.
    ///
    /// One point wide and a row tall, on the row under the point, at the
    /// point's own x kept inside the drawn grid. The x is the finger's rather
    /// than a cell edge's because a row laid out as proportional text has no
    /// edge at a column's multiple of the cell width.
    ///
    /// - Parameter point: The touch, in view coordinates.
    /// - Returns: The caret, or the null rectangle before a cell has been measured.
    internal func selectionLoupeCaret(atViewPoint point: CGPoint) -> CGRect {
        guard let renderer, let cell = reportCell(atViewPoint: point),
            let centre = viewPoint(forRow: Int(cell.row), column: Int(cell.column))
        else { return .null }
        let height = renderer.drawnCellSize(for: self).height
        var x = point.x
        if let clip = renderer.contentClip(for: self), !clip.isEmpty {
            x = min(max(x, clip.minX), clip.maxX)
        }
        return CGRect(x: x, y: centre.y - height / 2, width: 1, height: height)
    }

    /// A character-granularity pointer fact marked as the platform's
    /// selection gesture.
    private func forwardSelectionFact(_ kind: Ubiquitty.Runtime.TerminalSession.PointerFact.Kind, at point: CGPoint) {
        guard
            var fact = makePointerFact(
                atViewPoint: point,
                kind: kind,
                button: .left,
                clickCount: 1,
                isDragging: kind == .motion,
                modifiers: SurfaceModifiers()
            )
        else { return }
        fact.isSelectionGesture = true
        forward(fact)
    }

    /// Grows a word selection to its line, as a third click does.
    ///
    /// - Parameter point: Where the third tap landed.
    /// - Returns: Whether the tap was the third of a selection, and so used.
    internal func selectLineIfThirdTap(atViewPoint point: CGPoint) -> Bool {
        guard let last = lastWordSelection else { return false }
        lastWordSelection = nil
        // The word must still be selected, and a program tracking the mouse
        // is owed its own third click.
        guard hasSelection, !isMouseTrackingActive else { return false }
        guard ProcessInfo.processInfo.systemUptime - last.time < 0.8,
            abs(point.x - last.point.x) < 24, abs(point.y - last.point.y) < 24
        else { return false }
        for kind: Ubiquitty.Runtime.TerminalSession.PointerFact.Kind in [.press, .release] {
            if var fact = makePointerFact(atViewPoint: point, kind: kind, button: .left, clickCount: 3, modifiers: SurfaceModifiers()) {
                fact.isSelectionGesture = true
                forward(fact)
            }
        }
        presentEditMenu(atViewPoint: point)
        return true
    }

    /// Presents a system controller from the view controller that hosts this
    /// surface.
    internal func presentFromHost(_ controller: UIViewController) {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let host = next as? UIViewController {
                var top = host
                while let presented = top.presentedViewController { top = presented }
                top.present(controller, animated: true)
                return
            }
            responder = next
        }
    }
}

#if UBIQUITTY_IOS_UI_TESTS
/// What the loupe has done over one surface, as an element the UI suite reads.
///
/// The system's loupe is not in the accessibility tree, and XCUITest cannot
/// look at the screen while a synthesised finger is down, so a case asks
/// afterwards. The element sits in the surface's window rather than in the
/// surface, because the surface is an element itself and hides every view
/// inside it.
///
/// Its value reads `begun <n>, open <yes|no>, caret <x> <y> <width> <height>`:
/// how many sessions the system began, whether one is open, and the caret
/// the loupe last tracked, in window points.
internal final class SelectionLoupeRecord: UIView {
    var sessionsBegun = 0
    var isOpen = false
    var caret = CGRect.null

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "terminal-selection-loupe"
        accessibilityLabel = "Selection loupe"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SelectionLoupeRecord has no archived representation")
    }

    func publish() {
        let rectangle = caret.isNull ? "none" : "\(caret.minX) \(caret.minY) \(caret.width) \(caret.height)"
        accessibilityValue = "begun \(sessionsBegun), open \(isOpen ? "yes" : "no"), caret \(rectangle)"
    }
}

extension TerminalSurface {
    /// Records what ``followSelectionWithLoupe(_:at:from:)`` just did.
    ///
    /// - Parameters:
    ///   - phase: The phase it was given.
    ///   - caret: The caret it tracked, in view coordinates.
    fileprivate func noteSelectionLoupe(_ phase: SelectionDragPhase, caret: CGRect) {
        // A surface no loupe has opened over keeps no record, so a case can
        // tell a hold that showed none from one that has not happened.
        guard let record = selectionLoupeRecord ?? (selectionLoupe == nil ? nil : SelectionLoupeRecord()) else { return }
        selectionLoupeRecord = record
        if phase == .began, selectionLoupe != nil { record.sessionsBegun += 1 }
        record.isOpen = selectionLoupe != nil
        guard let window else {
            record.removeFromSuperview()
            return
        }
        if record.isOpen, !caret.isNull { record.caret = convert(caret, to: window) }
        if record.superview !== window { window.addSubview(record) }
        record.publish()
    }
}
#endif

#endif
