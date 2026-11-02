// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+UIKitPointer.swift — touch becomes pointer and scroll facts.
//
// A touch screen has no hover, no buttons and no click count, so the gestures
// carry meanings a mouse gets from its hardware:
//
//   swipe up or down   the wheel, which Core's ladder routes to the program,
//                      to cursor keys on the alternate screen, or to the local view
//   swipe sideways     the next or previous tab, asked of the host; a pan
//                      settles on one axis early, so a scroll never turns into
//                      a tab switch halfway through
//   tap                the keyboard, until the keyboard is already up — then
//                      it is a click, because a reader who can already type
//                      has no other way to press a button
//   double-tap, drag   a selection, dragged from the second tap; under a program
//                      that tracks the mouse, the program's own drag
//   hold, drag         a selection the program never hears, whatever it tracks,
//                      under the system loupe on the glass:
//                      a finger has no Shift to hold; over a selection, the edit
//                      menu instead, so what was selected can be copied — a
//                      phone has no Cmd-C
//   pinch              the window's font zoom, an offset over the configured
//                      size that Core clamps
//   two-finger tap     the host's settings
//   two-finger swipe   the next or previous connection, asked of the host
//
// The facts they produce are the ones AppKit produces; everything downstream
// of `forward` is shared, so the phone cannot diverge from the desktop on what
// a press means.

#if canImport(UIKit)

import GameController
import UIKit
internal import UbiquittyCore

extension TerminalSurface {
    /// Installs the touch gestures. Called once, as the view is built.
    internal func installPointerGestures() {
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        // One finger: two is the system's own gesture space (split view, app
        // switcher), and a terminal that claimed it would fight the OS.
        scroll.minimumNumberOfTouches = 1
        scroll.maximumNumberOfTouches = 1
        scroll.allowedScrollTypesMask = .all
        addGestureRecognizer(scroll)
        scrollPan = scroll
        let arbiter = TouchGestureArbiter(surface: self)
        touchGestureArbiter = arbiter
        // The arbiter watches for a second finger that lands after this pan has
        // begun; the pan ignores touches past its maximum, so only its delegate
        // is asked about them.
        scroll.delegate = arbiter

        // A tap, then a press that may drag — which is "double-tap and drag on
        // the second tap". A zero press duration answers on touch-down rather
        // than after a hold, so the selection starts where the finger landed.
        let select = UILongPressGestureRecognizer(target: self, action: #selector(handleSelectionDrag(_:)))
        select.numberOfTapsRequired = 1
        select.minimumPressDuration = 0
        addGestureRecognizer(select)

        // Zoom is the frontend's own gesture: it changes how large the grid is
        // drawn and sends the program nothing, which is why it never becomes a
        // pointer fact.
        let zoom = UIPinchGestureRecognizer(target: self, action: #selector(handleFontZoomPinch(_:)))
        zoom.delegate = arbiter
        addGestureRecognizer(zoom)
        fontZoomPinch = zoom

        // One recogniser for both meanings of a hold, chosen as it begins: two
        // recognisers claiming the same held finger means neither is
        // predictable. Delegated to the arbiter, which sees what kind of touch
        // it is.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldPress(_:)))
        hold.require(toFail: select)
        hold.delegate = arbiter
        addGestureRecognizer(hold)
        holdPress = hold

        // Settings, on two fingers. The one gesture on this surface that takes
        // more than one touch besides the pinch.
        //
        // It collides with nothing already here, and the reason is worth stating
        // because the item that asked for it assumed otherwise: the scroll pan
        // above is pinned to ONE touch, the selection drag and the hold are
        // long presses on one, and the single tap is one. A pointer fact is only
        // ever built from those one-finger paths, so a mouse-reporting program
        // never sees this and cannot have it taken from it.
        //
        // What it does reverse is the scroll pan's stated reason for taking one
        // touch — that two is the system's gesture space. A two-finger tap is not
        // a system gesture on any Apple platform; the system's two-finger claims
        // are drags, and edge-anchored, so the two-finger drag below starts
        // anywhere but answers only once the fingers have crossed a third of
        // the view.
        let settings = UITapGestureRecognizer(target: self, action: #selector(handleSettingsTap(_:)))
        settings.numberOfTouchesRequired = 2
        addGestureRecognizer(settings)

        // Another connection, on two fingers dragged sideways. The one real collision on this
        // surface: a pinch is also two fingers and begins identically, so the two are separated
        // by what the fingers do rather than by how many there are — a pinch changes the
        // distance between them, a swipe moves them together.
        //
        // require(toFail:) is not used. A pinch only "fails" when it ends, so the
        // swipe would not act until the reader lifted their fingers and then only if UIKit had
        // decided the pinch was over — which is a swipe that sometimes does nothing. Nor is
        // UIKit's default exclusion left to choose: whichever of the two passed its own
        // hysteresis first would fail the other, so a swipe whose spacing wavered zoomed and a
        // pinch whose centroid drifted switched. The arbiter lets both recognise together, and
        // each handler decides on both facts at once — the pan's travel and the pinch's scale —
        // through ``TouchPanRule/twoFingerMeaning(translation:pinchScale:viewWidth:)``.
        let connections = UIPanGestureRecognizer(target: self, action: #selector(handleConnectionSwipe(_:)))
        connections.minimumNumberOfTouches = 2
        connections.maximumNumberOfTouches = 2
        connections.delegate = arbiter
        addGestureRecognizer(connections)
        connectionPan = connections

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        // A single tap must not fire on the way into a double-tap: the first
        // tap of a selection gesture would otherwise send a click the reader
        // never asked for.
        tap.require(toFail: select)
        addGestureRecognizer(tap)

        installSelectionAffordances()

        pointerGesturesInstalled = true
    }

    /// Whether the surface answers the edit menu's entries.
    ///
    /// Copy alone, and only over a selection: paste belongs to the keyboard
    /// path, and a terminal has no editable text for the rest of the menu to
    /// act on.
    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            return hasSelection
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Puts the selection on the system pasteboard.
    ///
    /// - Parameter sender: The menu entry, unused.
    override public func copy(_ sender: Any?) {
        guard let text = selectedText, !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    override public var canBecomeFirstResponder: Bool { true }

    /// Whether a tap types rather than summons the keyboard.
    ///
    /// A reader who can already type has no other way to press a button, so
    /// the tap becomes a click once there is a keyboard — the software one on
    /// screen, or a hardware one attached. Until then the tap is how the
    /// keyboard arrives at all, and a terminal that swallowed it would leave
    /// no way to type.
    ///
    /// A program that has enabled mouse tracking (DECSET 9/1000/1002/1003) has
    /// explicitly asked for clicks, so the tap is a click even with no
    /// keyboard — the program is waiting for it and the keyboard would hide
    /// the very thing the program is showing.
    private var shouldTapSendClick: Bool {
        if isKeyboardPresented {
            return true
        }
        if isMouseTrackingActive {
            return true
        }
        return hasHardwareKeyboard
    }

    /// Whether a hardware keyboard is attached.
    ///
    /// The software keyboard does not count here even though it counts for
    /// typing: it has no ⌘, ⌥ or ⇧ to hold through a drag, and the two
    /// questions this answers — can the reader click, can the reader reach
    /// through — differ on exactly that.
    internal var hasHardwareKeyboard: Bool {
        if #available(iOS 14.0, *) {
            return GCKeyboard.coalesced != nil
        }
        return false
    }

    /// Whether the terminal has asked for mouse button reports: Core's
    /// disjunction of the tracking modes, as published. A copy spelled here
    /// is the one that drops 1001.
    internal var isMouseTrackingActive: Bool {
        drive.readSnapshot().mouseReportsActive
    }

    /// Folds a swipe into wheel deltas, or into a tab switch.
    ///
    /// Reported incrementally: the recogniser's translation is cumulative, so
    /// each callback sends the change since the last one and the sub-line
    /// accumulator in Core sees the same stream a trackpad produces.
    ///
    /// A finger on the glass settles on an axis first (see ``TouchPanRule``).
    /// Nothing is forwarded until it has, so a sideways flick that becomes a
    /// tab switch has sent the program no horizontal wheel on the way; a
    /// vertical settle forwards everything travelled so far in one delta. A
    /// trackpad or wheel scroll carries no finger and never settles: it is a
    /// scroll on both axes, as it is on every other surface.
    ///
    /// A pan that a second finger joined is a two-finger swipe whose first finger
    /// moved early, so its sideways answer is a connection, never a tab: this pan
    /// took the first finger before the two-finger pan could see the pair.
    ///
    /// - Parameter recognizer: The pan.
    @objc
    private func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            lastScrollTranslation = .zero
            scrollIsDirectTouch = recognizer.numberOfTouches > 0
            scrollPanAxis = nil
            scrollPanIsActive = true
            scrollPanSawAnotherFinger = false
            fallthrough
        case .changed, .ended:
            let translation = recognizer.translation(in: self)
            let meaning: TouchPanMeaning
            if scrollIsDirectTouch {
                scrollPanAxis = TouchPanRule.axis(after: translation, lockedAxis: scrollPanAxis)
                meaning = TouchPanRule.meaning(
                    axis: scrollPanAxis,
                    translation: translation,
                    velocity: recognizer.state == .ended ? recognizer.velocity(in: self) : .zero,
                    hasEnded: recognizer.state == .ended,
                    viewWidth: bounds.width
                )
            } else {
                meaning = .scroll
            }
            if recognizer.state == .ended {
                scrollPanIsActive = false
            }
            switch meaning {
            case .scroll:
                forwardScrollPanDelta(
                    to: translation,
                    atViewPoint: recognizer.location(in: self),
                    modifiers: heldModifiers(during: recognizer)
                )
            case .swipeLeft, .swipeRight:
                if scrollPanSawAnotherFinger {
                    // Distance alone, as the two-finger pan decides: the velocity is one finger's.
                    requestConnection(
                        for: TouchPanRule.twoFingerMeaning(translation: translation, pinchScale: 1, viewWidth: bounds.width)
                    )
                } else if meaning == .swipeLeft {
                    observer?.terminalSurfaceDidRequestNextTab(self)
                } else {
                    observer?.terminalSurfaceDidRequestPreviousTab(self)
                }
            case .nothing:
                break
            }
        default:
            lastScrollTranslation = .zero
            scrollIsDirectTouch = false
            scrollPanAxis = nil
            scrollPanIsActive = false
        }
    }

    /// Notes a finger that touched down while the one-finger pan was under way.
    internal func noteTouchDuringScrollPan() {
        if scrollPanIsActive {
            scrollPanSawAnotherFinger = true
        }
    }

    /// Forwards the pan's travel since the last forward as wheel deltas.
    ///
    /// A finger's pan scrolls only once it has settled vertical, so its
    /// sideways travel is never a wheel: the wheel takes the larger of the two
    /// deltas as its direction, and a thumb's arc that crossed further than it
    /// fell in one callback would otherwise reach the program as a sideways
    /// wheel it never asked for, which tmux and vim drop, and the travel down
    /// the glass in that callback would be lost. A trackpad's scroll keeps both
    /// axes.
    ///
    /// - Parameters:
    ///   - translation: The pan's cumulative translation.
    ///   - point: Where the finger is, in view coordinates.
    ///   - modifiers: The modifiers held as the callback arrived.
    private func forwardScrollPanDelta(to translation: CGPoint, atViewPoint point: CGPoint, modifiers: SurfaceModifiers) {
        let deltaX = scrollIsDirectTouch ? 0 : Double(translation.x - lastScrollTranslation.x)
        let deltaY = Double(translation.y - lastScrollTranslation.y)
        lastScrollTranslation = translation
        guard deltaX != 0 || deltaY != 0 else { return }
        // Dragging the content down brings older lines into view, which is
        // the sign a wheel reports for scrolling up.
        forwardScroll(
            atViewPoint: point,
            deltaX: deltaX,
            deltaY: deltaY,
            isPrecise: true,
            isDirectTouch: scrollIsDirectTouch,
            modifiers: modifiers
        )
    }

    /// The modifiers held as a gesture's callback arrived.
    ///
    /// The recogniser's own flags, which UIKit keeps with the touches it
    /// recognised from, so a key let go a moment after the finger lifted is
    /// still the key that was held. These are facts: what a held Shift or
    /// Control means for a press or a wheel is Core's to decide, the same rule
    /// the desktop runs.
    ///
    /// - Parameter recognizer: The recogniser whose callback this is.
    /// - Returns: Shift, Control, Option and Command, as held.
    internal func heldModifiers(during recognizer: UIGestureRecognizer) -> SurfaceModifiers {
        SurfaceModifiers(flags: recognizer.modifierFlags)
    }

    /// The modifiers a hardware keyboard holds right now.
    ///
    /// GameController's live keyboard, which the pointer-lock chord also
    /// reads, for a caller holding a point rather than a recogniser. With no
    /// hardware keyboard nothing is held.
    ///
    /// - Returns: Shift, Control, Option and Command, as held.
    internal func heldKeyboardModifiers() -> SurfaceModifiers {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return SurfaceModifiers() }
        func isDown(_ code: GCKeyCode) -> Bool {
            input.button(forKeyCode: code)?.isPressed == true
        }
        return SurfaceModifiers(
            hasShift: isDown(.leftShift) || isDown(.rightShift),
            hasAlternate: isDown(.leftAlt) || isDown(.rightAlt),
            hasControl: isDown(.leftControl) || isDown(.rightControl),
            hasCommand: isDown(.leftGUI) || isDown(.rightGUI)
        )
    }

    /// Asks the host to show its settings.
    ///
    /// Nothing is sent to the program: a two-finger tap is the frontend's own
    /// gesture, the way the pinch is, so it never becomes a pointer fact.
    ///
    /// - Parameter recognizer: The two-finger tap.
    @objc
    private func handleSettingsTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        observer?.terminalSurfaceDidRequestSettings(self)
    }

    /// Asks the host for the next or the previous connection.
    ///
    /// Decided once, as the fingers lift, and only past the swipe distance with the spacing
    /// held: a two-finger drag that has barely moved, or whose fingers spread or closed, is a
    /// pinch rather than a swipe. The pinch recognises alongside this pan, so its scale is the
    /// spacing's answer.
    ///
    /// - Parameter recognizer: The two-finger pan.
    @objc
    private func handleConnectionSwipe(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        requestConnection(
            for: TouchPanRule.twoFingerMeaning(
                translation: recognizer.translation(in: self),
                pinchScale: fontZoomPinch?.scale ?? 1,
                viewWidth: bounds.width
            )
        )
    }

    /// Asks the host for the connection a two-finger meaning names, if it names one.
    ///
    /// - Parameter meaning: From ``TouchPanRule/twoFingerMeaning(translation:pinchScale:viewWidth:)``.
    private func requestConnection(for meaning: TouchPanMeaning) {
        switch meaning {
        case .swipeLeft:
            observer?.terminalSurfaceDidRequestNextConnection(self)
        case .swipeRight:
            observer?.terminalSurfaceDidRequestPreviousConnection(self)
        case .scroll, .nothing:
            break
        }
    }

    /// Sends a tap as a click, or asks the host for a keyboard.
    ///
    /// - Parameter recognizer: The tap.
    @objc
    private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        if selectLineIfThirdTap(atViewPoint: point) { return }
        // A tap beside a selection puts it away, as it does over any iOS
        // text, and still means what a tap means. A program tracking the
        // mouse is owed the click, and Core drops the selection for a
        // reported press.
        if hasSelection, !isMouseTrackingActive {
            editMenuInteraction?.dismissMenu()
            clearSelection()
        }
        tap(atViewPoint: point, modifiers: heldModifiers(during: recognizer))
    }

    /// The tap rule, on a point rather than a recogniser.
    ///
    /// Separate from the callback so the rule can be exercised without
    /// synthesising a touch: what a recogniser adds is where the finger was,
    /// and that is the one part a test cannot assert about itself.
    ///
    /// - Parameters:
    ///   - point: Where the tap landed, in view coordinates.
    ///   - modifiers: The modifiers held; the hardware keyboard's when omitted.
    internal func tap(atViewPoint point: CGPoint, modifiers: SurfaceModifiers? = nil) {
        let held = modifiers ?? heldKeyboardModifiers()
        if openLink(atViewPoint: point, modifiers: held) { return }
        guard shouldTapSendClick else {
            observer?.terminalSurfaceDidRequestKeyboard(self)
            return
        }
        // A click sent with a hardware keyboard attached and no software
        // keyboard up is the one case this surface is not already first
        // responder for. Pointer lock's focus fact and the break-out
        // chord's presses both read that status, so a click is where a
        // reader with a mouse and keyboard first gives the surface either.
        // Left alone whenever the software keyboard is up: that keyboard's
        // proxy view must keep first responder, or the keyboard drops.
        if hasHardwareKeyboard, !isKeyboardPresented {
            _ = becomeFirstResponder()
        }
        // Press and release, because a touch has no state between them: an
        // application waiting for the button to come back up would otherwise
        // wait for a release that never arrives.
        if let press = makePointerFact(atViewPoint: point, kind: .press, button: .left, modifiers: held) {
            forward(press)
        }
        if let release = makePointerFact(atViewPoint: point, kind: .release, button: .left, modifiers: held) {
            forward(release)
        }
    }

    /// Drags a selection from the second tap of a double-tap.
    ///
    /// - Parameter recognizer: The tap-then-press gesture.
    @objc
    private func handleSelectionDrag(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        let held = heldModifiers(during: recognizer)
        switch recognizer.state {
        case .began:
            selectionDrag(.began, atViewPoint: point, modifiers: held)
        case .changed:
            selectionDrag(.moved, atViewPoint: point, modifiers: held)
        case .ended:
            selectionDrag(.ended, atViewPoint: point, modifiers: held)
            // A double-tap that selected offers what to do with the word, and
            // a third tap close behind grows it to the line.
            if hasSelection {
                lastWordSelection = (ProcessInfo.processInfo.systemUptime, point)
                presentEditMenu(atViewPoint: point)
            }
        case .cancelled, .failed:
            selectionDrag(.ended, atViewPoint: point, modifiers: held)
        default:
            break
        }
    }

    /// Zooms the font, in points, from the pinch's scale.
    ///
    /// The scale is relative to the gesture's start, so the offset is computed
    /// from the offset the pinch BEGAN at rather than accumulated per callback:
    /// accumulating multiplies the rounding by the callback rate, and the same
    /// pinch then lands somewhere different depending on how fast a finger
    /// moved.
    ///
    /// - Parameter recognizer: The pinch.
    @objc
    private func handleFontZoomPinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            zoomOffsetAtPinchStart = fontZoomOffset
            isPinchingFont = true
            fallthrough
        case .changed:
            queuePinchFontSize(scale: Double(recognizer.scale))
        case .ended:
            // The same rule the connection pan lifts on, so the two fingers mean one thing
            // whichever recogniser hears the lift first: a swipe keeps the size it began at.
            let swipe = TouchPanRule.twoFingerMeaning(
                translation: connectionPan?.translation(in: self) ?? .zero,
                pinchScale: recognizer.scale,
                viewWidth: bounds.width
            )
            guard swipe == .nothing else {
                abandonFontZoomPinch()
                return
            }
            queuePinchFontSize(scale: Double(recognizer.scale))
            applyPendingPinchFontSize()
            finishFontZoomPinch()
        case .cancelled, .failed:
            abandonFontZoomPinch()
        default:
            break
        }
    }

    private func queuePinchFontSize(scale: Double) {
        guard isPinchingFont, configuredPointSize > 0, scale.isFinite, scale > 0 else { return }
        let base = Ubiquitty.Preferences.Zoom.zoomedFontSize(configuredPointSize, zoomOffsetAtPinchStart)
        let step = Ubiquitty.Preferences.Zoom.fontZoomStep
        let delta = ((base * scale - base) / step).rounded() * step
        let size = Ubiquitty.Preferences.Zoom.clampFontZoom(base + delta)
        guard size != zoomedPointSize else {
            pendingPinchPointSize = nil
            return
        }
        pendingPinchPointSize = size
        armFrameDisplayLink()
    }

    /// Applies one coalesced font size and resizes the terminal before its next frame.
    internal func applyPendingPinchFontSize() {
        guard let size = pendingPinchPointSize else { return }
        pendingPinchPointSize = nil
        applyFontZoom(offset: Ubiquitty.Preferences.Zoom.fontZoomOffsetForSize(configuredPointSize, size))
    }

    /// Returns the font to the size the pinch began at and settles the grid there.
    private func abandonFontZoomPinch() {
        pendingPinchPointSize = nil
        if isPinchingFont { applyFontZoom(offset: zoomOffsetAtPinchStart) }
        finishFontZoomPinch()
    }

    /// Settles the history rewrap after the gesture's visible grid resizes.
    internal func finishFontZoomPinch() {
        pendingPinchPointSize = nil
        guard isPinchingFont else { return }
        isPinchingFont = false
        noteViewportBeforeResize()
        drive.settleResize()
        carryViewOffsetAcrossResize()
        needsDisplay = true
    }

    /// Offers the edit menu over a selection, and otherwise drags one.
    ///
    /// Chosen once, as the hold begins. The menu's entries all act on selected
    /// text, so without a selection a hold selects instead: on the glass it is
    /// the platform's selection gesture, which a program tracking the mouse
    /// never hears; from a pointer, which has Shift to hold, it is an ordinary
    /// drag that Core routes as it routes any other.
    ///
    /// - Parameter recognizer: The hold.
    @objc
    private func handleHoldPress(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        let held = heldModifiers(during: recognizer)
        let isSelectionGesture = holdPressIsOnTheGlass
        switch recognizer.state {
        case .began:
            holdPressOffersEditMenu = hasSelection
            holdPressMadeSelection = !holdPressOffersEditMenu && isSelectionGesture
            if holdPressOffersEditMenu {
                presentEditMenu(atViewPoint: point)
            } else {
                selectionDrag(.began, atViewPoint: point, modifiers: held, isSelectionGesture: isSelectionGesture)
                // A pointer's hold is a drag like a mouse's, and a pointer
                // has no fingertip over the text to see past.
                if isSelectionGesture { followSelectionWithLoupe(.began, at: point) }
            }
        case .changed:
            guard !holdPressOffersEditMenu else { return }
            selectionDrag(.moved, atViewPoint: point, modifiers: held, isSelectionGesture: isSelectionGesture)
            followSelectionWithLoupe(.moved, at: point)
        case .ended, .cancelled, .failed:
            guard !holdPressOffersEditMenu else {
                holdPressOffersEditMenu = false
                return
            }
            selectionDrag(.ended, atViewPoint: point, modifiers: held, isSelectionGesture: isSelectionGesture)
            followSelectionWithLoupe(.ended, at: point)
            // The selection a finger made is offered its menu as the finger
            // lifts, as on every iOS text surface: Copy is one tap away.
            if holdPressMadeSelection, recognizer.state == .ended, hasSelection {
                presentEditMenu(atViewPoint: point)
            }
            holdPressMadeSelection = false
        default:
            break
        }
    }

    /// Shows the edit menu at a point.
    ///
    /// - Parameter point: Where to anchor it, in view coordinates.
    internal func presentEditMenu(atViewPoint point: CGPoint) {
        guard #available(iOS 16.0, *), let interaction = editMenuInteraction else { return }
        _ = becomeFirstResponder()
        interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    /// Where a selection drag has got to.
    internal enum SelectionDragPhase {
        case began
        case moved
        case ended
    }

    /// The selection-drag rule, on a phase and a point.
    ///
    /// Click count two throughout, which is what the ladder reads to open a
    /// word selection — the same value AppKit reports for a second click.
    ///
    /// - Parameters:
    ///   - phase: Where the drag has got to.
    ///   - point: Where the finger is, in view coordinates.
    ///   - modifiers: The modifiers held; the hardware keyboard's when omitted.
    ///   - isSelectionGesture: Whether this is the platform's selection
    ///     gesture: a hold on the glass, which has no modifier to hold. Whether
    ///     that keeps it from a program tracking the mouse is the ladder's rule,
    ///     as Shift's is; a double-tap drag is not it, so such a program still
    ///     receives a drag from a finger.
    internal func selectionDrag(
        _ phase: SelectionDragPhase,
        atViewPoint point: CGPoint,
        modifiers: SurfaceModifiers? = nil,
        isSelectionGesture: Bool = false
    ) {
        let kind: Ubiquitty.Runtime.TerminalSession.PointerFact.Kind =
            switch phase {
            case .began: .press
            case .moved: .motion
            case .ended: .release
            }
        if let fact = makePointerFact(
            atViewPoint: point,
            kind: kind,
            button: .left,
            clickCount: 2,
            isDragging: phase == .moved,
            modifiers: modifiers ?? heldKeyboardModifiers()
        ) {
            var gesture = fact
            gesture.isSelectionGesture = isSelectionGesture
            forward(gesture)
        }
    }
}

/// The axis a one-finger pan settled on.
internal enum TouchPanAxis: Equatable {
    case vertical
    case horizontal
}

/// What a pan means at one callback.
internal enum TouchPanMeaning: Equatable {
    /// Forward the travel since the last forward as wheel deltas.
    case scroll
    /// The fingers crossed leftward far enough, or fast enough, to ask for what comes next.
    case swipeLeft
    /// The fingers crossed rightward far enough, or fast enough, to ask for what came before.
    case swipeRight
    /// Forward nothing: the pan has not settled, or settled sideways and has not ended.
    case nothing
}

/// The rule that tells a scroll from a sideways swipe, on numbers rather than a recogniser.
///
/// Separate from the handler for the reason ``TerminalSurface/tap(atViewPoint:modifiers:)`` is: what a
/// recogniser adds is where the finger went, and that is the one part a test cannot synthesise
/// in-process.
///
/// The axis is chosen early and changes at most once. A drag that starts down the grid and
/// wanders sideways is still a scroll, and a flick that starts sideways and dips is still a
/// swipe; deciding per callback would let one gesture be both, and the program would see half a
/// scroll before the tab changed under it. Sideways needs a two-to-one lean, because a thumb's
/// scroll often opens with an arc: anything less settles vertical, and a pan settled sideways
/// that then travels further up or down than across becomes the scroll it turned out to be,
/// carrying everything it travelled. A vertical settle is final, so a scroll never ends as a
/// tab switch.
internal enum TouchPanRule {
    /// How far a finger travels, in points, before the pan settles on an axis.
    ///
    /// Just past UIKit's own pan hysteresis, so the first callback usually settles it and a
    /// vertical scroll starts as promptly as it would with no axis to choose.
    static let axisLockDistance: CGFloat = 12

    /// How fast a sideways flick has to be moving as it lifts, in points per second, to count
    /// as a swipe without having crossed the distance.
    static let decisiveVelocity: CGFloat = 800

    /// How many times its vertical travel a pan's horizontal travel has to be to settle
    /// sideways: about 27 degrees off horizontal, the most a sideways swipe leans in practice.
    static let sidewaysLean: CGFloat = 2

    /// How much tighter the two fingers may come together or spread apart, as a factor of
    /// their spacing at touch-down, and still be a swipe rather than a pinch.
    static let pinchScaleTolerance: CGFloat = 0.15

    /// The axis after this callback.
    ///
    /// - Parameters:
    ///   - translation: The pan's cumulative translation.
    ///   - lockedAxis: The axis already chosen, if any. Vertical is kept; horizontal is kept
    ///     until the vertical travel passes the horizontal by ``axisLockDistance``.
    /// - Returns: The axis, or nil while the pan is still within ``axisLockDistance``.
    static func axis(after translation: CGPoint, lockedAxis: TouchPanAxis?) -> TouchPanAxis? {
        switch lockedAxis {
        case .vertical:
            return .vertical
        case .horizontal:
            return abs(translation.y) >= abs(translation.x) + axisLockDistance ? .vertical : .horizontal
        case nil:
            guard hypot(translation.x, translation.y) >= axisLockDistance else {
                return nil
            }
            return settlingAxis(of: translation)
        }
    }

    /// What a one-finger pan means at this callback.
    ///
    /// A pan that ends before it has settled is judged by the way it was heading, so a short
    /// vertical nudge still scrolls by what it travelled.
    ///
    /// - Parameters:
    ///   - axis: The axis from ``axis(after:lockedAxis:)``.
    ///   - translation: The pan's cumulative translation.
    ///   - velocity: The pan's velocity as it lifted; read only once it has ended.
    ///   - hasEnded: Whether the finger has lifted.
    ///   - viewWidth: The width of the surface, which scales the swipe distance.
    /// - Returns: What to do with this callback.
    static func meaning(
        axis: TouchPanAxis?,
        translation: CGPoint,
        velocity: CGPoint,
        hasEnded: Bool,
        viewWidth: CGFloat
    ) -> TouchPanMeaning {
        let settled = axis ?? (hasEnded ? settlingAxis(of: translation) : nil)
        switch settled {
        case .vertical:
            return .scroll
        case nil:
            return .nothing
        case .horizontal:
            guard hasEnded else { return .nothing }
            let direction = translation.x != 0 ? translation.x : velocity.x
            let isFarEnough = abs(translation.x) >= swipeDistance(viewWidth: viewWidth)
            let isFastEnough =
                abs(velocity.x) >= decisiveVelocity && abs(velocity.x) > abs(velocity.y)
                && (velocity.x < 0) == (direction < 0)
            guard direction != 0, isFarEnough || isFastEnough else { return .nothing }
            return direction < 0 ? .swipeLeft : .swipeRight
        }
    }

    /// What a two-finger pan means as it lifts: a sideways swipe, or nothing.
    ///
    /// - Parameters:
    ///   - translation: The pan's cumulative translation.
    ///   - pinchScale: The pinch's scale over the same fingers, 1 when their spacing held.
    ///   - viewWidth: The width of the surface.
    /// - Returns: ``TouchPanMeaning/swipeLeft``, ``TouchPanMeaning/swipeRight`` or
    ///   ``TouchPanMeaning/nothing``.
    static func twoFingerMeaning(translation: CGPoint, pinchScale: CGFloat, viewWidth: CGFloat) -> TouchPanMeaning {
        // Fingers that spread or closed were zooming, however far their centroid travelled.
        guard abs(pinchScale - 1) <= pinchScaleTolerance else {
            return .nothing
        }
        // Predominantly horizontal: a two-finger drag up or down is a scroll on every other
        // surface a reader touches, and answering it with a navigation would be a surprise.
        guard dominantAxis(of: translation) == .horizontal,
            abs(translation.x) >= swipeDistance(viewWidth: viewWidth)
        else {
            return .nothing
        }
        return translation.x < 0 ? .swipeLeft : .swipeRight
    }

    /// How far a swipe travels before it is a swipe rather than a drag that drifted.
    ///
    /// A third of the view, not a fixed point count: the same gesture has to mean the same thing
    /// on a phone and on an iPad, and a constant that reads as decisive on one is a twitch on the
    /// other. The floor keeps a narrow pane from turning a nudge into a switch.
    ///
    /// - Parameter viewWidth: The width of the surface.
    /// - Returns: The distance, in points.
    static func swipeDistance(viewWidth: CGFloat) -> CGFloat {
        max(viewWidth / 3, 80)
    }

    /// The axis a translation leans along; a perfect diagonal reads as vertical, the gesture that
    /// was here first.
    private static func dominantAxis(of translation: CGPoint) -> TouchPanAxis {
        abs(translation.x) > abs(translation.y) ? .horizontal : .vertical
    }

    /// The axis a one-finger pan settles on: sideways only on a clear lean, vertical otherwise.
    private static func settlingAxis(of translation: CGPoint) -> TouchPanAxis {
        translation.x != 0 && abs(translation.x) >= sidewaysLean * abs(translation.y) ? .horizontal : .vertical
    }
}

/// The delegate of the scroll pan, the pinch, the connection pan and the hold.
///
/// A delegate rather than the surface itself, so the surface's public type does not take on
/// a conformance its embedders would see.
internal final class TouchGestureArbiter: NSObject, UIGestureRecognizerDelegate {
    private weak var surface: TerminalSurface?

    /// - Parameter surface: The surface the recognisers are installed on.
    init(surface: TerminalSurface) {
        self.surface = surface
    }

    /// Lets the pinch and the two-finger pan recognise together, and nothing else.
    ///
    /// The two see the same fingers, and only together do they say which gesture it was: the
    /// pan's travel and the pinch's scale. Left to exclusion, the first to pass its own
    /// hysteresis would fail the other, deciding on half the facts.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let surface, let pinch = surface.fontZoomPinch, let pan = surface.connectionPan else {
            return false
        }
        return (gestureRecognizer === pinch && otherGestureRecognizer === pan)
            || (gestureRecognizer === pan && otherGestureRecognizer === pinch)
    }

    /// Notes a finger offered to the one-finger pan while it is under way, and what kind of
    /// touch the hold is offered.
    ///
    /// The pan ignores a touch past its maximum without telling its handler, and this is the
    /// one place UIKit names that touch. The hold's handler sees no touch at all, so this is
    /// also where the hold learns whether it is on the glass. iPadOS types a trackpad or
    /// mouse click as an indirect pointer only for an app that opts into indirect input
    /// events; otherwise it arrives here as a direct touch.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let surface, gestureRecognizer === surface.scrollPan {
            surface.noteTouchDuringScrollPan()
        }
        if let surface, gestureRecognizer === surface.holdPress {
            surface.holdPressIsOnTheGlass = touch.type == .direct || touch.type == .pencil
        }
        return true
    }
}

// Relative pointer-lock ("mouselook", private mode 7403) on iPadOS's own
// pointer-lock API.
//
// UIKit answers 7403 differently from AppKit: instead of an idempotent
// enable/teardown this arm performs itself, a UIViewController states its
// wish through `prefersPointerLocked` and iPadOS decides whether, and when,
// to grant it, reporting back through `UIPointerLockState`. So the shape
// here is push-then-poll rather than AppKit's single apply: `updatePointerLock`
// only asks the hosting controller to re-read Core's verdict, and
// `reportPointerLockGrab` only runs once the OS answers.
//
// The break-out chord (hold the control-command pair) is the same as
// AppKit's: Core's arming and hold thresholds
// (`Input::isPointerLockBreakoutArmed`, `pointerLockBreakoutHoldTicks`) and
// the mode clear are the session's, so a hung application that never resets
// 7403 cannot re-trap the pointer. UIKit has no `flagsChanged`; the presses
// that report it are overridden beside the rest of this surface's UIKit
// lifecycle, in `TerminalSurface+UIKitEvents.swift`.

extension TerminalSurface {
    /// Whether this surface should hold the OS pointer grab: the published
    /// 7403 bit, and this surface being first responder in a foreground
    /// scene — a backgrounded lock would trap a pointer no window owns.
    ///
    /// Read by ``TerminalSurfaceViewController/prefersPointerLocked``, which
    /// iPadOS polls; nothing here takes or releases anything itself.
    public var isPointerLockDesired: Bool {
        guard drive.readSnapshot().mouseRelativePointerLockActive || isPointerLocked else {
            return false
        }
        // The one fact Core cannot see: whether this surface is the live
        // input target in a scene the reader can currently see. The
        // decision is Core's.
        let isFocused = isFirstResponder && window?.windowScene?.activationState == .foregroundActive
        return drive.pointerLockVerdict(isSurfaceFocused: isFocused) == .hold
    }

    /// Whether the OS grab is held, as last reported.
    public var isPointerLockHeld: Bool { isPointerLocked }

    /// Whether GameController is wired for deltas, which is so exactly while
    /// the grab is held: the framework is never touched before a grab, and is
    /// let go with it.
    public var isPointerLockMouseWired: Bool { pointerLockMouseConnectObserver != nil }

    /// Asks the hosting controller to re-read ``isPointerLockDesired``.
    ///
    /// Idempotent and cheap; called from every edge that can move the
    /// answer — a mode drain, a focus edge, a scene activation change. The
    /// grab itself is iPadOS's to take or release; this only asks it to look
    /// again.
    internal func updatePointerLock() {
        pointerLockHostingController?.setNeedsUpdateOfPrefersPointerLocked()
    }

    /// The view controller downstream in the responder chain, when this
    /// surface is its whole view — the one ``TerminalSurfaceViewController``
    /// builds around it.
    private var pointerLockHostingController: UIViewController? {
        var responder: UIResponder? = self
        while let candidate = responder {
            if let controller = candidate as? UIViewController {
                return controller
            }
            responder = candidate.next
        }
        return nil
    }

    /// Reports the OS's own answer to the pointer-lock ask, so the lesson
    /// naming the way out stands for exactly as long as the trap does.
    ///
    /// Called from ``TerminalSurfaceViewController`` when
    /// ``UIPointerLockState`` reports an edge. The grab is a fact only that
    /// state carries; everything after — that the way out is owed for as
    /// long as the trap lasts, and for how many traps — is the ladder's.
    ///
    /// - Parameter grab: Whether the OS took the grab.
    public func reportPointerLockGrab(_ grab: Ubiquitty.Input.PointerLockGrab) {
        isPointerLocked = grab == .held
        // GameController is wired for deltas only while the grab is held.
        // Asking it any earlier starts its device discovery, and on a device
        // with a keyboard attached that changes what a later tap means: a
        // tap clicks instead of summoning the keyboard. An unlocked mouse's
        // deltas belong to no application anyway.
        if isPointerLocked {
            installPointerLockMouseHandling()
        } else {
            removePointerLockMouseHandling()
        }
        drive.notePointerLockGrab(grab)
        refreshHint()
    }

    /// Stands in for GameController's keyboard, for a run with no keyboard
    /// to hold: the Simulator has none, and the chord's wire through this
    /// arm -- report, wake-up, release -- is otherwise unreachable there.
    ///
    /// - Parameter keys: The keys Core's arming rule reads, or nil to read
    ///   GameController again.
    public func overridePointerLockChordKeys(_ keys: (() -> Ubiquitty.Input.PointerLockKeyState)?) {
        pointerLockChordKeyStateOverride = keys
    }

    /// Reports a modifier edge to Core's chord and books its one wake-up.
    ///
    /// Public for the same run as ``overridePointerLockChordKeys(_:)``: a
    /// press edge is what calls it, and a run with no keyboard has none.
    public func reportPointerLockChordEdge() {
        updatePointerLockChord()
    }

    /// Reports a modifier edge to Core's chord and books its one wake-up.
    ///
    /// The arming rule, the hold and the abort on a release in the last
    /// instant are the ladder's; this arm reports what the keys are, asks
    /// when to ask again, and executes the release it is told to. Called
    /// from every presses override in `TerminalSurface+UIKitEvents.swift` —
    /// UIKit has no single `flagsChanged` the way AppKit does, so any of
    /// them can be the edge that moved a modifier.
    internal func updatePointerLockChord() {
        // Nothing to release while no grab is held, and reading the keyboard
        // through GameController would start its device discovery on the
        // first key of every session for a chord that cannot arm.
        guard isPointerLocked else { return }
        drive.notePointerLockChord(pointerLockChordKeyState())
        bookPointerLockChordTick()
    }

    /// Books the one wake-up Core names for the chord, if it is armed.
    private func bookPointerLockChordTick() {
        let ticks = drive.pointerLockChordTicksUntilDeadline()
        guard ticks != 0, !isPointerLockChordTickBooked else { return }
        isPointerLockChordTickBooked = true
        // One tick past the deadline, so the ask lands on its far side.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(ticks + 1) / 60.0) { [weak self] in
            self?.firePointerLockChordTick()
        }
    }

    /// The wake-up fired: ask Core against the live modifier flags, and
    /// release the grab if it says so by asking the hosting controller to
    /// re-read the verdict. The mode is already clear by then.
    private func firePointerLockChordTick() {
        isPointerLockChordTickBooked = false
        if drive.tickPointerLockChord(pointerLockChordKeyState()) == .breakOut {
            updatePointerLock()
        } else {
            bookPointerLockChordTick()
        }
    }

    /// The chord state Core reads: GameController's live keyboard buttons.
    ///
    /// UIKit's presses carry a snapshot only of the edge that fired, with
    /// nothing to read on the chord's own wake-up, which has no press of
    /// its own. GameController's coalesced keyboard is queryable at any
    /// moment, the counterpart of AppKit's `NSEvent.modifierFlags` static
    /// read, so both this method's callers read it the same way.
    ///
    /// A non-modifier key held alongside the pair makes it a shortcut, not
    /// the break-out; the presses overrides count those keys down and up, so
    /// a ⌃⌘X held for half a second releases nothing.
    ///
    /// - Returns: The keys Core's arming rule reads.
    private func pointerLockChordKeyState() -> Ubiquitty.Input.PointerLockKeyState {
        if let pointerLockChordKeyStateOverride {
            return pointerLockChordKeyStateOverride()
        }
        let input = GCKeyboard.coalesced?.keyboardInput
        func isDown(_ code: GCKeyCode) -> Bool {
            input?.button(forKeyCode: code)?.isPressed == true
        }
        var keys = Ubiquitty.Input.PointerLockKeyState()
        keys.isControlHeld = isDown(.leftControl) || isDown(.rightControl)
        keys.isCommandHeld = isDown(.leftGUI) || isDown(.rightGUI)
        keys.isShiftHeld = isDown(.leftShift) || isDown(.rightShift)
        keys.isOptionHeld = isDown(.leftAlt) || isDown(.rightAlt)
        keys.isAnyNonModifierKeyHeld = heldNonModifierPressCount > 0
        return keys
    }

    /// Counts a press edge toward the non-modifier keys held, for the chord.
    ///
    /// - Parameters:
    ///   - presses: The presses the edge carried.
    ///   - delta: +1 for a begin, -1 for an end or cancel.
    internal func countNonModifierPresses(_ presses: Set<UIPress>, delta: Int) {
        // The HID usage table keeps the eight modifiers contiguous, from the
        // left Control to the right GUI key, so the range names them all.
        let modifierUsages = UIKeyboardHIDUsage.keyboardLeftControl.rawValue...UIKeyboardHIDUsage.keyboardRightGUI.rawValue
        let nonModifiers =
            presses.filter { press in
                guard let key = press.key else { return false }
                return !modifierUsages.contains(key.keyCode.rawValue)
            }
            .count
        heldNonModifierPressCount = max(0, heldNonModifierPressCount + delta * nonModifiers)
    }

    /// Wires GameController's relative mouse deltas to the pointer-lock
    /// ladder, and re-arms whenever a mouse connects after this surface is
    /// already on screen — a Bluetooth mouse commonly pairs late.
    internal func installPointerLockMouseHandling() {
        removePointerLockMouseHandling()
        installPointerLockMouseHandler(for: GCMouse.current)
        // The connecting mouse is read back from `GCMouse.current` inside the
        // isolated block rather than off the notification: a `Notification`
        // is not `Sendable`, and re-reading GameController's own current
        // mouse is the same fact its `object` would have named.
        pointerLockMouseConnectObserver = NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.installPointerLockMouseHandler(for: GCMouse.current)
            }
        }
    }

    /// Unwires GameController when the grab ends: the handler and the
    /// late-pairing observer both go, so a surface that is never locked again
    /// holds nothing of the framework's.
    internal func removePointerLockMouseHandling() {
        GCMouse.current?.mouseInput?.mouseMovedHandler = nil
        if let pointerLockMouseConnectObserver {
            NotificationCenter.default.removeObserver(pointerLockMouseConnectObserver)
        }
        pointerLockMouseConnectObserver = nil
    }

    /// Points one mouse's relative-motion handler at this surface.
    ///
    /// - Parameter mouse: The mouse to read, or nil when none is connected.
    private func installPointerLockMouseHandler(for mouse: GCMouse?) {
        mouse?.mouseInput?.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            MainActor.assumeIsolated {
                self?.forwardPointerLockMotion(deltaX: deltaX, deltaY: deltaY)
            }
        }
    }

    /// Forwards one relative sample to Core's ladder under DECSET 7403.
    ///
    /// Only while the grab is actually held: an unlocked mouse still reports
    /// deltas over GameController's API, and forwarding those would spend
    /// the wire on a pointer no application asked to own. GameController's
    /// frame is up-positive; the fact this builds matches AppKit's own
    /// locked-motion fact, whose sign is the raw HID convention — the one
    /// `NSEvent.deltaY` already carries — so this negates it.
    ///
    /// - Parameters:
    ///   - deltaX: The horizontal delta GameController measured, in points.
    ///   - deltaY: The vertical delta, up-positive in GameController's frame.
    private func forwardPointerLockMotion(deltaX: Float, deltaY: Float) {
        guard isPointerLocked else { return }
        var fact = Ubiquitty.Runtime.TerminalSession.PointerFact()
        fact.kind = .motion
        fact.button = .none
        fact.deltaX = Int(deltaX.rounded())
        fact.deltaY = Int(-deltaY.rounded())
        forward(fact)
    }
}

/// Hosts a ``TerminalSurface`` as its whole view, and owns the one UIKit API
/// relative pointer lock (DECSET 7403) needs on this toolkit: a view
/// controller to answer ``UIViewController/prefersPointerLocked``.
///
/// SwiftUI has no such override — a `UIViewRepresentable` wraps a view, not
/// a controller — so a `UIViewControllerRepresentable` builds one of these
/// around the surface instead. It owns both halves relative pointer lock
/// needs on iPadOS: the answer the OS polls, and the
/// ``UIPointerLockState`` notification that reports back whether the OS
/// actually took the grab it asked for.
public final class TerminalSurfaceViewController: UIViewController {
    /// The surface this controller hosts and drives pointer lock for.
    public let surface: TerminalSurface

    /// The token observing ``UIPointerLockState/didChangeNotification`` for
    /// this controller's scene.
    private var pointerLockStateObserver: NSObjectProtocol?

    /// - Parameter surface: The surface to host as this controller's whole view.
    public init(surface: TerminalSurface) {
        self.surface = surface
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("TerminalSurfaceViewController has no archived representation")
    }

    override public func loadView() {
        view = surface
    }

    /// Whether iPadOS should confine the pointer to this surface: Core's
    /// verdict, read fresh on every poll.
    override public var prefersPointerLocked: Bool {
        surface.isPointerLockDesired
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        // The notification's own payload is not read: a `Notification` is
        // not `Sendable`, and re-reading this scene's own pointer-lock state
        // fresh answers the same question the payload would have, for
        // whichever scene the edge was actually about — a stray edge on
        // another scene just re-reports the state this one already has.
        pointerLockStateObserver = NotificationCenter.default.addObserver(
            forName: UIPointerLockState.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pointerLockStateDidChange()
            }
        }
    }

    deinit {
        // Every instance is built and torn down on main, the thread UIKit
        // itself confines a view controller's lifecycle to.
        MainActor.assumeIsolated {
            if let pointerLockStateObserver {
                NotificationCenter.default.removeObserver(pointerLockStateObserver)
            }
        }
    }

    /// Reports the OS's own answer to Core, whichever way it moved.
    private func pointerLockStateDidChange() {
        let isLocked = surface.window?.windowScene?.pointerLockState?.isLocked == true
        surface.reportPointerLockGrab(isLocked ? .held : .released)
    }
}

/// The modifiers UIKit records with a touch, as the facts a pointer fact carries.
extension SurfaceModifiers {
    /// - Parameter flags: The modifier flags a recogniser or a press reports.
    init(flags: UIKeyModifierFlags) {
        self.init(
            hasShift: flags.contains(.shift),
            hasAlternate: flags.contains(.alternate),
            hasControl: flags.contains(.control),
            hasCommand: flags.contains(.command)
        )
    }
}

#endif
