// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+WindowDrag.swift — moving the window by dragging the grid.
//
// Two readers want this and they are the same gesture: one configured
// `[window] drag_modifier` so any window can be moved without reaching for its
// title bar, and one turned the title bar off entirely and has nowhere else to
// grab. Which modifiers arm it is `Input::windowDragArmed`, so every
// window agrees about when the body stands in for a title bar.
//
// The window is relocated here rather than through `performDrag(with:)`,
// which runs a nested modal loop that forces the arrow cursor back over the
// closed fist for the whole gesture. The move is arithmetic on the event's own
// location, so what the window follows is the pointer that AppKit reported and
// not whatever the cursor happens to be doing when it is asked.

internal import UbiquittyCore

#if canImport(AppKit)
import AppKit

extension TerminalSurface {
    /// Whether a drag now would move the window rather than select.
    ///
    /// Read for the pointer image as well as for the press, so the grab hand
    /// appears while the modifier is held and before anything is dragged.
    internal var isWindowDragArmed: Bool {
        guard let window, !window.styleMask.contains(.fullScreen) else { return false }
        let held = NSEvent.modifierFlags
        var modifiers = Ubiquitty.Input.HeldModifiers()
        modifiers.hasCommand = held.contains(.command)
        modifiers.hasControl = held.contains(.control)
        modifiers.hasAlternate = held.contains(.option)
        modifiers.hasShift = held.contains(.shift)
        return windowDragModifierSpec.withCString {
            Ubiquitty.Input.windowDragArmed(modifiers, std.string_view($0), windowChrome)
        }
    }

    /// Begins a window move if this press asks for one.
    ///
    /// A full-screen window is exempt: it has nowhere to go, and consuming the
    /// press there would cost the reader a selection for nothing.
    ///
    /// - Parameter event: The press.
    /// - Returns: Whether the press was spent on the window rather than the
    ///   grid.
    internal func beginWindowDrag(with event: NSEvent) -> Bool {
        guard let window, !window.styleMask.contains(.fullScreen) else { return false }
        var fact = Ubiquitty.Input.PointerFact()
        fact.kind = .press
        fact.hasCommand = event.modifierFlags.contains(.command)
        fact.hasControl = event.modifierFlags.contains(.control)
        fact.hasAlternate = event.modifierFlags.contains(.option)
        fact.hasShift = event.modifierFlags.contains(.shift)
        let isDragPress = windowDragModifierSpec.withCString {
            Ubiquitty.Input.isWindowDragPress(fact, std.string_view($0), windowChrome)
        }
        guard isDragPress else {
            return false
        }
        // The grab point in the window's own coordinates: the window moves
        // under it, so a screen-space offset would drift by exactly the
        // distance moved.
        windowDragGrabInWindow = event.locationInWindow
        NSCursor.closedHand.set()
        return true
    }

    /// Moves the window so the grabbed point stays under the pointer.
    ///
    /// - Parameter event: The drag.
    /// - Returns: Whether the drag was spent on the window.
    internal func continueWindowDrag(with event: NSEvent) -> Bool {
        guard let window, let grab = windowDragGrabInWindow else { return false }
        let pointerOnScreen = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(
            CGPoint(x: pointerOnScreen.x - grab.x, y: pointerOnScreen.y - grab.y)
        )
        // Held every move: AppKit resets the cursor as the window relocates,
        // and a fist that let go halfway reads as the drag having ended.
        NSCursor.closedHand.set()
        return true
    }

    /// Ends a window move, if one was running.
    ///
    /// - Returns: Whether the release was spent on the window.
    @discardableResult
    internal func endWindowDrag() -> Bool {
        guard windowDragGrabInWindow != nil else { return false }
        windowDragGrabInWindow = nil
        applyPointerCursor()
        return true
    }

    /// Whether this window carries a title bar, or its body stands in for one.
    ///
    /// The hosting window's own state, not the configured default: hiding
    /// the title bar is per window, so a reader who hid this one's can move
    /// it by its body while the window beside it still has a bar to grab.
    /// A surface with no host falls back to the default, which is what a
    /// window opening right now would take.
    private var windowChrome: Ubiquitty.Input.WindowChrome {
        if let host = window?.windowController as? TerminalWindowController {
            return host.isTitleBarHiddenForIdentity ? .chromeless : .titled
        }
        return Ubiquitty.Preferences.Effective.hideTitleBar(Ubiquitty.Preferences.values().pointee)
            ? .chromeless
            : .titled
    }

    /// The reader's `[window] drag_modifier`, read live so an edit takes effect
    /// on the next press rather than at the next window.
    private var windowDragModifierSpec: String {
        String(Ubiquitty.Preferences.Effective.windowDragModifier(Ubiquitty.Preferences.values().pointee))
    }
}

#endif
