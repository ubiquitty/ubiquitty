// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(UIKit)

import UIKit
internal import UbiquittyCore

// The surface's UIKit lifecycle, the counterpart of the AppKit file beside
// it. Same edges, different names — and nothing else: what each hook does
// lives once, in the surface.

extension TerminalSurface {
    override public func didMoveToWindow() {
        super.didMoveToWindow()
        // A link outside a window fires against no display, and holds the
        // surface alive doing it.
        if window == nil {
            invalidateFrameDisplayLink()
            finishFontZoomPinch()
            followSelectionWithLoupe(.ended, at: .zero)
        }
        surfaceDidMoveToWindow()
        guard window != nil else { return }
        // Once, and here rather than in the initialiser: a recogniser added to
        // a view outside a window is kept, but a surface that never reaches one
        // has nothing to recognise on.
        if !pointerGesturesInstalled {
            installPointerGestures()
        }
        // The scale arrives with the window, and nothing else delivers it.
        // AppKit has viewDidChangeBackingProperties for this edge; UIKit has
        // no callback at all, so a surface that never asks keeps the layer's
        // default scale of 1 while the drawable is sized in real device
        // pixels — the frame is drawn at three times the size the layer
        // presents, which is a blank terminal, not a blurred one.
        surfaceDidChangeBackingProperties()
        if displayScaleRegistration == nil {
            displayScaleRegistration = registerForTraitChanges(
                [UITraitDisplayScale.self],
                action: #selector(surfaceDisplayScaleDidChange)
            )
        }
    }

    /// The scale changed under this view — an external display, or a window
    /// moved between screens.
    @objc
    private func surfaceDisplayScaleDidChange() {
        surfaceDidChangeBackingProperties()
    }

    /// Asks for one frame at the next refresh.
    ///
    /// Idempotent: marks arriving between refreshes coalesce into the frame
    /// already armed.
    internal func armFrameDisplayLink() {
        guard window != nil else { return }
        if let link = frameDisplayLink {
            link.isPaused = false
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(frameDisplayLinkFired))
        link.add(to: .main, forMode: .common)
        frameDisplayLink = link
    }

    /// Draws the frame the mark asked for, then pauses until the next mark.
    @objc
    private func frameDisplayLinkFired() {
        applyPendingPinchFontSize()
        frameDisplayLink?.isPaused = true
        drawSurfaceFrame()
        // After the frame, whose selection spans say where the ends are.
        layoutSelectionHandles()
    }

    /// Tears the link down. A CADisplayLink retains its target until it does.
    internal func invalidateFrameDisplayLink() {
        frameDisplayLink?.invalidate()
        frameDisplayLink = nil
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        surfaceDidResize(to: bounds.size)
    }

    /// The window edges a phone has.
    ///
    /// No miniaturize and no occlusion state: an app is foreground or it is
    /// not, which the scene notifications report. What they trigger is the
    /// surface's own presentation recompute, unchanged.
    internal func installPlatformWindowObservers() {
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        windowObservers.removeAll()
        // Registered on `.main`, which is what lets the block re-enter the
        // surface's isolation rather than hop to it.
        let onEdge: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recomputePresentation()
                // Pointer lock's focus fact reads the scene's activation
                // state, so a foreground/background edge can move the
                // verdict — a lock held into the background would trap a
                // pointer no window reads.
                self?.updatePointerLock()
            }
        }
        windowObservers.append(
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: onEdge)
        )
        windowObservers.append(
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: onEdge)
        )
        // Another text input beginning or ending its editing is what moves a
        // touch shell's keyboard off the terminal and back, and this surface's
        // own responder callbacks see neither: the input that took the
        // keyboard may have taken it from the keyboard's view, not from here.
        let onTextInputEdge: @Sendable (Notification) -> Void = { [weak self] notification in
            let input = notification.object as? UIView
            MainActor.assumeIsolated {
                guard let self, let input else { return }
                self.editingOtherTextInput = input
                self.refreshSurfaceFocus()
            }
        }
        for name in [
            UITextField.textDidBeginEditingNotification,
            UITextField.textDidEndEditingNotification,
            UITextView.textDidBeginEditingNotification,
            UITextView.textDidEndEditingNotification,
        ] {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main, using: onTextInputEdge))
        }
    }

    /// Who holds the keyboard, as Core's touch rule reads it.
    ///
    /// Not this surface's responder status: the surface takes first responder
    /// for the selection menu and for a hardware keyboard's click and hands it
    /// to the keyboard's view on the next tap, all without the keys leaving
    /// the terminal. Only a text input outside it, still editing in this
    /// surface's window, holds the keyboard elsewhere.
    internal var touchKeyboardHolder: Ubiquitty.Runtime.TouchKeyboardHolder {
        guard let input = editingOtherTextInput, input.isFirstResponder, let window, input.window === window else {
            return .Terminal
        }
        return .OtherTextInput
    }

    /// Reports a modifier edge to Core's break-out chord.
    ///
    /// UIKit has no `flagsChanged` the way AppKit does; a hardware
    /// modifier key is itself a ``UIPress``, so every edge that can move
    /// one arrives through these four overrides instead. Which press fired
    /// does not matter — ``updatePointerLockChord()`` re-reads the whole
    /// keyboard state rather than reading flags off this method's own
    /// event, so each override only has to say that something did.
    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        countNonModifierPresses(presses, delta: +1)
        updatePointerLockChord()
        super.pressesBegan(presses, with: event)
    }

    override public func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        countNonModifierPresses(presses, delta: -1)
        updatePointerLockChord()
        super.pressesEnded(presses, with: event)
    }

    override public func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        updatePointerLockChord()
        super.pressesChanged(presses, with: event)
    }

    override public func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        countNonModifierPresses(presses, delta: -1)
        // A cancelled press (a system gesture stealing the key) still ends
        // whatever it was: the break-out chord must not read a modifier as
        // still down once UIKit has taken the press away.
        updatePointerLockChord()
        super.pressesCancelled(presses, with: event)
    }
}

#endif
