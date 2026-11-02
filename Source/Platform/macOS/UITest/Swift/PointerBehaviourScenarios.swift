// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import ImageIO
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit
import UniformTypeIdentifiers

// PointerBehaviourScenarios.swift — four things a Kit-hosted surface does
// around the pointer.
//
// None of them is visible in the input path itself: the keys type, the scroll
// scrolls and the drag selects either way. What these cover is everything
// around that — the caret holds still under the text being entered, the
// pointer hides from over it, the wheel runs at the configured speed, and a
// drag that leaves the window keeps selecting. So each assertion here is about
// the effect beside the action, and each has a witness because AppKit answers
// no question about the OS cursor and Core's activity freeze is a model field.

@MainActor
private final class PointerTestWindow: NSWindow {
    var pointerPosition = NSPoint(x: 20, y: 20)
    override var mouseLocationOutsideOfEventStream: NSPoint { pointerPosition }
    override var isKeyWindow: Bool { true }
}

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let surface = view as? TerminalSurface {
        return surface
    }
    for subview in view.subviews {
        if let found = terminalSurface(under: subview) {
            return found
        }
    }
    return nil
}

/// Whether two cursors are the same cursor.
///
/// The public cursors are singletons and compare by identity; a private one
/// reached by selector need not be, so the picture and the hot spot decide
/// where identity does not.
///
/// - Parameters:
///   - lhs: One cursor.
///   - rhs: The other.
/// - Returns: True when a reader would see no difference.
@MainActor
private func isSameCursor(_ lhs: NSCursor, _ rhs: NSCursor) -> Bool {
    lhs === rhs || (lhs.hotSpot == rhs.hotSpot && lhs.image.tiffRepresentation == rhs.image.tiffRepresentation)
}

/// One key press, synthesised the way AppKit would deliver it.
///
/// - Parameters:
///   - characters: The characters the key produces.
///   - keyCode: The hardware key code.
/// - Returns: The event, or nil when AppKit refuses the combination.
@MainActor
private func keyPress(characters: String, keyCode: UInt16) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )
}

/// A mouse event at a point in the window.
///
/// - Parameters:
///   - type: Which mouse event.
///   - window: The window the point is in.
///   - point: The location, in window coordinates.
/// - Returns: The event, or nil when AppKit refuses it.
@MainActor
private func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: CGPoint) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: type == .leftMouseUp ? 0 : 1
    )
}

/// One mouse event with modifiers held.
///
/// - Parameters:
///   - type: Which mouse event.
///   - window: The window the point is in.
///   - point: The location, in window coordinates.
///   - modifiers: The modifiers held.
/// - Returns: The event, or nil when AppKit refuses it.
@MainActor
private func mouseEvent(
    _ type: NSEvent.EventType,
    in window: NSWindow,
    at point: CGPoint,
    modifiers: NSEvent.ModifierFlags
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: type == .leftMouseUp ? 0 : 1
    )
}

/// Drags from one cell to another and reports what was selected.
///
/// - Parameters:
///   - surface: The surface to drag on.
///   - window: Its window.
///   - from: The starting cell.
///   - to: The ending cell.
///   - modifiers: The modifiers held for the whole gesture.
/// - Returns: The selected text, empty when nothing was selected.
@MainActor
private func dragSelect(
    on surface: TerminalSurface,
    in window: NSWindow,
    from: (row: Int, column: Int),
    to: (row: Int, column: Int),
    modifiers: NSEvent.ModifierFlags
) -> String {
    guard let start = surface.viewPoint(forRow: from.row, column: from.column),
        let end = surface.viewPoint(forRow: to.row, column: to.column)
    else {
        return ""
    }
    let startInWindow = surface.convert(start, to: nil)
    let endInWindow = surface.convert(end, to: nil)
    if let press = mouseEvent(.leftMouseDown, in: window, at: startInWindow, modifiers: modifiers) {
        surface.mouseDown(with: press)
    }
    if let drag = mouseEvent(.leftMouseDragged, in: window, at: endInWindow, modifiers: modifiers) {
        surface.mouseDragged(with: drag)
    }
    if let release = mouseEvent(.leftMouseUp, in: window, at: endInWindow, modifiers: modifiers) {
        surface.mouseUp(with: release)
    }
    return surface.selectedText ?? ""
}

/// Writes the surface's rendered frame as a PNG under /tmp/propdrag, for a
/// reader of a scenario's highlight.
@MainActor
func saveSurfaceFrame(_ surface: TerminalSurface, _ name: String) {
    guard let frame = surface.renderedFrameForTesting() else { return }
    let directory = URL(fileURLWithPath: "/tmp/propdrag", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let provider = CGDataProvider(data: frame.pixels as CFData),
        let image = CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ),
        let destination = CGImageDestinationCreateWithURL(
            directory.appendingPathComponent("\(name).png") as CFURL,
            "public.png" as CFString,
            1,
            nil
        )
    else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

/// The frame's commonest colour, which with nothing selected is its
/// background.
@MainActor
private func backgroundPixel(_ surface: TerminalSurface) -> UInt32 {
    guard let frame = surface.renderedFrameForTesting() else { return 0 }
    var histogram: [UInt32: Int] = [:]
    frame.pixels.withUnsafeBytes { raw in
        for index in 0..<(frame.width * frame.height) {
            histogram[raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self) & 0x00FF_FFFF, default: 0] += 1
        }
    }
    return histogram.max(by: { $0.value < $1.value })?.key ?? 0
}

/// How many pixels of the top two rows are a red plate: the host's `OSC 17`
/// colour, which no text or background of the scenario's theme is.
@MainActor
private func redPlatePixelCount(_ surface: TerminalSurface) -> Int {
    guard let frame = surface.renderedFrameForTesting() else { return 0 }
    let rowsToRead = min(frame.height, 80)
    var count = 0
    frame.pixels.withUnsafeBytes { raw in
        for y in 0..<rowsToRead {
            for x in 0..<frame.width {
                let pixel = raw.loadUnaligned(fromByteOffset: (y * frame.width + x) * 4, as: UInt32.self)
                let b = Int(pixel & 0xFF)
                let g = Int((pixel >> 8) & 0xFF)
                let r = Int((pixel >> 16) & 0xFF)
                // Washed over the background at the native opacity, the plate
                // is well short of pure red; red-dominant is what it is.
                if r - g > 60 && r - b > 60 {
                    count += 1
                }
            }
        }
    }
    return count
}

/// How many pixels of the top two rows the selection plate covers: those
/// whose colour is neither `background` nor near white or black (the text's
/// ink and its edges).
@MainActor
private func selectionPixelCount(_ surface: TerminalSurface, background: UInt32) -> Int {
    guard let frame = surface.renderedFrameForTesting() else { return 0 }
    let rowsToRead = min(frame.height, 80)
    var histogram: [UInt32: Int] = [:]
    frame.pixels.withUnsafeBytes { raw in
        for y in 0..<rowsToRead {
            for x in 0..<frame.width {
                let pixel = raw.loadUnaligned(fromByteOffset: (y * frame.width + x) * 4, as: UInt32.self) & 0x00FF_FFFF
                histogram[pixel, default: 0] += 1
            }
        }
    }
    var count = 0
    for (pixel, n) in histogram where pixel != background {
        let b = Int(pixel & 0xFF)
        let g = Int((pixel >> 8) & 0xFF)
        let r = Int((pixel >> 16) & 0xFF)
        let luma = (r + g + b) / 3
        let bb = Int(background & 0xFF)
        let bg = Int((background >> 8) & 0xFF)
        let br = Int((background >> 16) & 0xFF)
        let backgroundLuma = (br + bg + bb) / 3
        // The plate is a mid tone a good step from the background; ink and its
        // antialiased edges run towards the opposite extreme.
        if abs(luma - backgroundLuma) > 12 && abs(luma - backgroundLuma) < 110 && abs(r - g) < 40 && abs(g - b) < 60 {
            count += n
        }
    }
    return count
}

/// Holds an Option press on a cell, asks a question, and releases.
///
/// The press is what the question is about: a crosshair that appeared only
/// while a modifier was polled would say nothing about the gesture in flight.
///
/// - Parameters:
///   - surface: The surface to press on.
///   - window: Its window.
///   - row: The pressed row.
///   - column: The pressed column.
///   - question: Asked with the button down.
/// - Returns: The answer, or false when the press could not be made.
@MainActor
private func holdingPress(
    on surface: TerminalSurface,
    in window: NSWindow,
    atRow row: Int,
    column: Int,
    modifiers: NSEvent.ModifierFlags = [.option],
    _ question: () -> Bool
) -> Bool {
    guard let point = surface.viewPoint(forRow: row, column: column) else { return false }
    let inWindow = surface.convert(point, to: nil)
    guard let press = mouseEvent(.leftMouseDown, in: window, at: inWindow, modifiers: modifiers) else {
        return false
    }
    surface.mouseDown(with: press)
    let answer = question()
    if let release = mouseEvent(.leftMouseUp, in: window, at: inWindow, modifiers: modifiers) {
        surface.mouseUp(with: release)
    }
    return answer
}

/// Moves the pointer over a cell and reports the cursor the surface resolves.
///
/// - Parameters:
///   - surface: The surface to hover.
///   - window: Its window.
///   - row: The hovered row.
///   - column: The hovered column.
/// - Returns: The cursor, or the arrow when the cell has no place yet.
@MainActor
private func hoverCursor(on surface: TerminalSurface, in window: NSWindow, row: Int, column: Int) -> NSCursor {
    guard let point = surface.viewPoint(forRow: row, column: column) else { return .arrow }
    if let move = mouseEvent(.mouseMoved, in: window, at: surface.convert(point, to: nil), modifiers: []) {
        surface.mouseMoved(with: move)
    }
    return surface.pointerCursor
}

/// Drags between two view points and reports what was selected.
///
/// Takes points rather than cells because the caret model answers to where in
/// a cell the pointer is, and a cell centre cannot ask that question.
///
/// - Parameters:
///   - surface: The surface to drag on.
///   - window: Its window.
///   - fromViewPoint: Where the press lands, in view coordinates.
///   - toViewPoint: Where the drag ends.
/// - Returns: The selected text, empty when nothing was selected.
@MainActor
private func dragSelect(
    on surface: TerminalSurface,
    in window: NSWindow,
    fromViewPoint: CGPoint,
    toViewPoint: CGPoint
) -> String {
    let startInWindow = surface.convert(fromViewPoint, to: nil)
    let endInWindow = surface.convert(toViewPoint, to: nil)
    if let press = mouseEvent(.leftMouseDown, in: window, at: startInWindow, modifiers: []) {
        surface.mouseDown(with: press)
    }
    if let drag = mouseEvent(.leftMouseDragged, in: window, at: endInWindow, modifiers: []) {
        surface.mouseDragged(with: drag)
    }
    if let release = mouseEvent(.leftMouseUp, in: window, at: endInWindow, modifiers: []) {
        surface.mouseUp(with: release)
    }
    return surface.selectedText ?? ""
}

/// Presses, drags to a second cell, asks a question, and releases.
///
/// The question is asked with the button still down, because a shape read
/// after the release would answer about a surface with no gesture running —
/// which is the state the rule under test is the exception to.
///
/// - Parameters:
///   - surface: The surface to drag on.
///   - window: Its window.
///   - from: The pressed cell.
///   - to: The cell dragged to.
///   - question: Asked mid-drag.
/// - Returns: The answer, or the arrow when the drag could not be made.
@MainActor
private func holdingDrag(
    on surface: TerminalSurface,
    in window: NSWindow,
    from: (row: Int, column: Int),
    to: (row: Int, column: Int),
    _ question: () -> NSCursor
) -> NSCursor {
    guard let start = surface.viewPoint(forRow: from.row, column: from.column),
        let end = surface.viewPoint(forRow: to.row, column: to.column)
    else {
        return .arrow
    }
    let startInWindow = surface.convert(start, to: nil)
    let endInWindow = surface.convert(end, to: nil)
    guard let press = mouseEvent(.leftMouseDown, in: window, at: startInWindow, modifiers: []) else {
        return .arrow
    }
    surface.mouseDown(with: press)
    if let drag = mouseEvent(.leftMouseDragged, in: window, at: endInWindow, modifiers: []) {
        surface.mouseDragged(with: drag)
    }
    let answer = question()
    if let release = mouseEvent(.leftMouseUp, in: window, at: endInWindow, modifiers: []) {
        surface.mouseUp(with: release)
    }
    return answer
}

/// A stand-in for a surface that can hold the OS cursor grab.
///
/// The real grab hides and dissociates the cursor of whoever is running the
/// suite, so the sweep is watched through a holder that only counts what it
/// was asked. What a transition asks is the whole claim; the grab itself is
/// `applyPointerLock`'s, and Core's own case covers the mapping.
@MainActor
private final class CountingLockHolder: NSObject, PointerLockHolder {
    var releases = 0
    var reconciles = 0

    func releasePointerLockGrab() {
        releases += 1
    }

    func reconcilePointerLockGrab() {
        reconciles += 1
    }
}

/// Registers the pointer-behaviour scenarios with the UI-test runner.
enum PointerBehaviourScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("pane_header_restores_arrow_and_grid_reentry_resolves_cursor") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                for swiftShell in [false, true] {
                    let modern =
                        swiftShell
                        ? TerminalWindowController.spawn(arguments: ["/bin/sh"], localePolicy: .auto, sessionLifetime: .outlivesChild) : nil
                    let classic = swiftShell ? nil : t.newWindowRunning(["/bin/sh"])
                    guard let original = modern?.window ?? classic?.window,
                        let terminal = (modern?.shellFocusedPaneIdentity as? NSView) ?? classic?.beamSurface
                    else {
                        t.expect(false, desc: "the terminal opens")
                        continue
                    }
                    defer { original.close() }
                    t.pump(0.5)
                    let chrome = PaneChrome(
                        paneID: 1,
                        target: nil,
                        closeAction: #selector(NSView.removeFromSuperview),
                        expandAction: #selector(NSView.removeFromSuperview)
                    )
                    let window = PointerTestWindow(
                        contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                        styleMask: [.borderless],
                        backing: .buffered,
                        defer: false
                    )
                    window.isReleasedWhenClosed = false
                    window.contentView = chrome
                    chrome.contentView = terminal
                    chrome.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
                    defer { window.close() }
                    guard let bar = chrome.subviews.first(where: { $0.accessibilityIdentifier() == "pane.titleBar" }) else {
                        t.expect(false, desc: "the title bar is present")
                        continue
                    }
                    guard
                        let event = NSEvent.enterExitEvent(
                            with: .mouseEntered,
                            location: window.pointerPosition,
                            modifierFlags: [],
                            timestamp: 0,
                            windowNumber: window.windowNumber,
                            context: nil,
                            eventNumber: 0,
                            trackingNumber: 0,
                            userData: nil
                        )
                    else { continue }
                    for tracking in [false, true] {
                        let command = tracking ? "printf '\\033[?1000h'\r" : "printf '\\033[?1000l'\r"
                        if let modern { modern.shellSendProbe(command) }
                        if let classic { t.sendText(command, to: classic) }
                        t.pump(0.5)
                        NSCursor.arrow.set()
                        terminal.mouseEntered(with: event)
                        let gridCursor = NSCursor.current
                        t.expect(
                            tracking ? !isSameCursor(gridCursor, .iBeam) : isSameCursor(gridCursor, .iBeam),
                            desc: "the grid resolves its current tracking policy"
                        )
                        NSCursor.iBeam.set()
                        bar.cursorUpdate(with: event)
                        t.expect(isSameCursor(NSCursor.current, .arrow), desc: "the header claims the arrow")
                        terminal.mouseEntered(with: event)
                        t.expect(
                            isSameCursor(NSCursor.current, gridCursor),
                            desc: "reentry restores the resolved grid cursor without motion"
                        )
                    }
                }
            }
        }

        // A captured pointer is a trap, and the way out is a chord nothing on
        // screen names. So the first few captures of a session say it, and
        // then stop: a lesson repeated at somebody who has learned it is one
        // they stop reading, and an application that locks on every click
        // would otherwise nag on every click.
        UBUITestRegister("swift_shell_a_surface_can_be_swept_by_an_app_transition") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let registry = PointerLockRegistry.shared

                // A pane that could hold a grab joins the registry when it is
                // built, not when it takes one: the sweep has to reach a pane
                // that was locked and torn down before anyone asked it.
                let before = registry.registeredHolderCount
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                t.pump(0.3)
                t.expect(
                    registry.registeredHolderCount > before,
                    desc: "the spawned surface joined the registry"
                        + " (\(registry.registeredHolderCount) from \(before))"
                )

                // What each transition asks is Core's, watched here on a stand-in
                // rather than on the real grab.
                let holder = CountingLockHolder()
                registry.add(holder)
                registry.apply(.deactivated)
                t.expect(
                    holder.releases == 1 && holder.reconciles == 0,
                    desc: "leaving the foreground releases rather than reconciling"
                        + " (\(holder.releases) released, \(holder.reconciles) reconciled)"
                )
                registry.apply(.activated)
                t.expect(
                    holder.reconciles == 1 && holder.releases == 1,
                    desc: "coming back asks the surface instead of re-engaging it"
                        + " (\(holder.releases) released, \(holder.reconciles) reconciled)"
                )
                registry.apply(.terminating)
                t.expect(
                    holder.releases == 2,
                    desc: "and going away releases (\(holder.releases) released)"
                )

                // Held weakly, so a closed pane leaves by itself; the table is
                // NSHashTable's and the moment it drops an entry is the
                // autorelease pool's, so nothing here waits on it.
                window.close()
            }
        }

        UBUITestRegister("swift_shell_a_captured_pointer_is_told_how_to_get_out") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                guard let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }
                t.expect(hintText(in: window).isEmpty, desc: "a window teaching nothing shows nothing")

                // The report the surface makes once the OS has answered — the
                // grab itself needs a key window, which this harness has none
                // of, so the capture is put to the surface at that point.
                surface.reportPointerLockGrab(.held)
                surface.refreshHintForTesting()
                let taught = hintText(in: window)
                t.expect(!taught.isEmpty, desc: "the first capture says how to get out")
                t.expect(
                    taught == surface.drive.hintTextShowing(),
                    desc: "and says the words Core wrote, in the glyphs this keyboard prints"
                )

                surface.reportPointerLockGrab(.released)
                surface.refreshHintForTesting()
                t.expect(hintText(in: window).isEmpty, desc: "and stops once the pointer is given back")

                // Past the budget the lesson stops. Core counts captures, not
                // reports, so each pair below is one.
                for _ in 0..<Ubiquitty.Input.hintMaxShows {
                    surface.reportPointerLockGrab(.held)
                    surface.reportPointerLockGrab(.released)
                }
                surface.reportPointerLockGrab(.held)
                surface.refreshHintForTesting()
                t.expect(
                    hintText(in: window).isEmpty,
                    desc: "and a reader who has been told enough times is not told again"
                )
                surface.reportPointerLockGrab(.released)
            }
        }

        UBUITestRegister("swift_shell_osc22_sets_the_pointer_shape") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                // A fresh surface has been asked for nothing, so what follows is
                // about these escapes and not about the starting state.
                t.expect(surface.appPointerShape == nil, desc: "a fresh surface carries no app-requested shape")
                t.expect(surface.pointerCursor === NSCursor.iBeam, desc: "and shows the terminal's own I-beam")
                // The cursor above is resolved on demand and reads right with
                // no rect installed at all; the witness to what a still
                // pointer sees is the shape the rect was last built for.
                t.expect(
                    t.wait(until: { surface.installedPointerShape == .text }, timeout: 3.0),
                    desc: "the rect a fresh surface installed is the I-beam's (\(String(describing: surface.installedPointerShape)))"
                )

                // Sent through the shell rather than fed to the parser: the
                // shape is read off the published snapshot on the drain that
                // delivers the bytes, so a direct feed would move the model
                // without reaching the path under test.
                @MainActor
                func settle(_ escape: String, until reached: () -> Bool) {
                    surface.send("printf '\\033]22;\(escape)\\007'\n")
                    for _ in 0..<30 {
                        t.pump(0.1)
                        if reached() { break }
                    }
                }

                settle("pointer") { surface.appPointerShape != nil }
                t.expect(
                    surface.appPointerShape == .pointer,
                    desc: "OSC 22 ; pointer reaches the surface (\(String(describing: surface.appPointerShape)))"
                )
                t.expect(surface.pointerCursor === NSCursor.pointingHand, desc: "and the surface resolves the pointing hand")
                t.expect(
                    surface.installedPointerShape == .pointer,
                    desc: "and the drain rebuilt the rect for the pointing hand under a still pointer"
                        + " (\(String(describing: surface.installedPointerShape)))"
                )

                settle(">wait") { surface.appPointerShape == .wait }
                t.expect(surface.appPointerShape == .wait, desc: "a push moves the live shape to wait")
                t.expect(surface.pointerCursor !== NSCursor.iBeam, desc: "and an app-requested shape displaces the I-beam")

                settle("<") { surface.appPointerShape == .pointer }
                t.expect(surface.appPointerShape == .pointer, desc: "a pop returns the shape under it")

                settle("") { surface.appPointerShape == nil }
                t.expect(surface.appPointerShape == nil, desc: "an empty set gives the pointer back to the terminal")
                t.expect(surface.pointerCursor === NSCursor.iBeam, desc: "and the I-beam returns")
                t.expect(
                    surface.installedPointerShape == .text,
                    desc: "and the rect was rebuilt for the I-beam (\(String(describing: surface.installedPointerShape)))"
                )

                // The rect is the authority between moves: what AppKit will
                // re-apply is what the surface resolved.
                settle("crosshair") { surface.appPointerShape == .crosshair }
                surface.window?.invalidateCursorRects(for: surface)
                surface.window?.resetCursorRects()
                t.expect(surface.pointerCursor === NSCursor.crosshair, desc: "a crosshair is the crosshair")
            }
        }

        UBUITestRegister("swift_shell_pointer_shape_mapping_names_native_cursors") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The mapping asserted against named cursors, not against itself:
                // a wrong table passes any check that compares a surface's
                // answer to the same function the surface calls.
                t.expect(PointerShapeCursor.cursor(for: .pointer) === NSCursor.pointingHand, desc: "pointer is the pointing hand")
                t.expect(PointerShapeCursor.cursor(for: .text) === NSCursor.iBeam, desc: "text is the I-beam")
                t.expect(PointerShapeCursor.cursor(for: .crosshair) === NSCursor.crosshair, desc: "crosshair is the crosshair")
                t.expect(PointerShapeCursor.cursor(for: .grabbing) === NSCursor.closedHand, desc: "grabbing is the closed hand")
                t.expect(
                    PointerShapeCursor.cursor(for: .notAllowed) === NSCursor.operationNotAllowed,
                    desc: "not-allowed is the barred pointer"
                )
                t.expect(PointerShapeCursor.cursor(for: .default) === NSCursor.arrow, desc: "default is the arrow")
                // The private cursors answer on this system, so a program that
                // asked for help or busy does not get the arrow that tells the
                // reader nothing.
                t.expect(PointerShapeCursor.cursor(for: .help) !== NSCursor.arrow, desc: "help is not the arrow on this OS")
                t.expect(PointerShapeCursor.cursor(for: .wait) !== NSCursor.arrow, desc: "wait is not the arrow on this OS")
                // AppKit ships no public diagonal resize cursor. Where this
                // system answers the private selectors, the corner shapes are
                // those cursors, distinct from each other; where it does not,
                // the public up-down resize stands in. Either way a window
                // corner reads as a resize, never as an edge or as the arrow.
                // Asserted against the selectors by name, as the table reaches
                // them, rather than against the table.
                let nwse = PointerShapeCursor.cursor(for: .nwseResize)
                let nesw = PointerShapeCursor.cursor(for: .neswResize)
                let cursorClass: AnyObject = NSCursor.self
                let privateNWSE = NSSelectorFromString("_windowResizeNorthWestSouthEastCursor")
                let privateNESW = NSSelectorFromString("_windowResizeNorthEastSouthWestCursor")
                if cursorClass.responds(to: privateNWSE), cursorClass.responds(to: privateNESW) {
                    let expectedNWSE = cursorClass.perform(privateNWSE)?.takeUnretainedValue() as? NSCursor
                    let expectedNESW = cursorClass.perform(privateNESW)?.takeUnretainedValue() as? NSCursor
                    t.expect(
                        expectedNWSE.map { isSameCursor(nwse, $0) } == true,
                        desc: "nwse-resize is the private diagonal cursor this OS ships"
                    )
                    t.expect(
                        expectedNESW.map { isSameCursor(nesw, $0) } == true,
                        desc: "nesw-resize is the other one"
                    )
                    t.expect(!isSameCursor(nwse, nesw), desc: "and the two corners are distinct")
                } else {
                    t.expect(
                        nwse === NSCursor.resizeUpDown && nesw === NSCursor.resizeUpDown,
                        desc: "without them, the public resize cursor stands in for both corners"
                    )
                }
                t.expect(nwse !== NSCursor.arrow && nesw !== NSCursor.arrow, desc: "a corner is never the arrow")
                // The raw-value shim the ObjC view crosses through answers the
                // typed mapping, and an out-of-range value is the default.
                let pointerRaw = Int(Ubiquitty.PAL.MousePointerShape.pointer.rawValue)
                t.expect(
                    PointerShapeCursor.cursor(forPointerShapeRawValue: pointerRaw) === NSCursor.pointingHand,
                    desc: "the raw-value shim reaches the same table"
                )
                let nwseRaw = Int(Ubiquitty.PAL.MousePointerShape.nwseResize.rawValue)
                t.expect(
                    isSameCursor(PointerShapeCursor.cursor(forPointerShapeRawValue: nwseRaw), nwse),
                    desc: "and the corner cursor through it, which is what the classic view installs"
                )
                t.expect(
                    PointerShapeCursor.cursor(forPointerShapeRawValue: 200) === NSCursor.arrow,
                    desc: "an unknown value is the default shape"
                )
            }
        }

        UBUITestRegister("swift_shell_mouse_mode_flip_moves_the_pointer_shape") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                t.expect(surface.pointerCursor === NSCursor.iBeam, desc: "selectable text advertises itself")

                // A tracking application owns the clicks, so the I-beam's
                // promise of selectable text would mislead. The flip arrives on
                // the drain that delivers the mode, under a pointer that has not
                // moved, which is the case AppKit's own machinery never sees.
                // The witness is the shape the rect was rebuilt for, not the
                // shape the ladder resolves: the second is computed on demand
                // and would read right with the reconcile deleted.
                surface.send("printf '\\033[?1003h'\n")
                for _ in 0..<30 {
                    t.pump(0.1)
                    if surface.installedPointerShape == .default { break }
                }
                t.expect(surface.drive.readSnapshot().mouseReportsActive, desc: "the published snapshot reports tracking")
                t.expect(surface.pointerCursor === NSCursor.arrow, desc: "a tracking application takes the arrow")
                t.expect(
                    surface.installedPointerShape == .default,
                    desc: "the rect was rebuilt for it under a still pointer (\(String(describing: surface.installedPointerShape)))"
                )

                surface.send("printf '\\033[?1003l'\n")
                for _ in 0..<30 {
                    t.pump(0.1)
                    if surface.installedPointerShape == .text { break }
                }
                t.expect(surface.pointerCursor === NSCursor.iBeam, desc: "and the I-beam returns when tracking ends")
                t.expect(surface.installedPointerShape == .text, desc: "and the rect was rebuilt for the I-beam")
            }
        }

        UBUITestRegister("swift_shell_typing_holds_the_caret_and_hides_the_pointer") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                guard let press = keyPress(characters: "x", keyCode: 7) else {
                    t.expect(false, desc: "AppKit synthesises a key event")
                    return
                }

                // A fresh window has never typed, so the pointer starts
                // visible and the assertion below is about this keystroke.
                t.expect(!surface.pointerIsHiddenForTyping, desc: "a fresh window has not hidden the pointer")
                let notesBefore = surface.userActivityNotesForTesting
                _ = surface.sendKey(press, eventType: .Press)
                t.pump(0.1)

                // The caret's freeze is Core's and is tested there. What this
                // reaches is whether this arm reports the keystroke at all —
                // it did not, and every key still typed, which is why no
                // typing-level assertion could see it.
                t.expect(
                    surface.userActivityNotesForTesting > notesBefore,
                    desc:
                        "a key press reports activity to the cursor freeze (\(notesBefore) -> \(surface.userActivityNotesForTesting))"
                )
                t.expect(
                    surface.pointerIsHiddenForTyping,
                    desc: "and typing asks the pointer to leave until the next move"
                )

                // A release is not typing: it reports.
                let notesAfterPress = surface.userActivityNotesForTesting
                _ = surface.sendKey(press, eventType: .Release)
                t.pump(0.05)
                t.expect(
                    surface.userActivityNotesForTesting == notesAfterPress,
                    desc: "a key release is not activity (\(surface.userActivityNotesForTesting))"
                )

                // A real move brings the pointer back, so a hover has
                // something to anchor on again.
                let middle = CGPoint(x: window.frame.width / 2, y: window.frame.height / 2)
                if let moved = mouseEvent(.mouseMoved, in: window, at: middle) {
                    surface.mouseMoved(with: moved)
                    t.pump(0.05)
                }
                t.expect(
                    !surface.pointerIsHiddenForTyping,
                    desc: "a mouse move makes the pointer visible again"
                )
            }
        }

        UBUITestRegister("swift_shell_wheel_tuning_comes_from_the_config") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)

                // pointsPerLine is the row height a precise trackpad delta is
                // divided by. An unconfigured policy leaves it at 1.0, which
                // makes a trackpad pan scroll a row height's worth of rows per
                // row of movement — the whole reason a default-constructed
                // policy is not a harmless placeholder.
                let policy = surface.wheelPolicy
                t.expect(
                    policy.pointsPerLine > 1.5,
                    desc: "the tuning carries the live row height, not the unconfigured 1.0 (is \(policy.pointsPerLine))"
                )
                t.expect(
                    policy.baseLinesPerTick > 0,
                    desc: "and a wheel notch moves whole lines (is \(policy.baseLinesPerTick))"
                )
            }
        }

        UBUITestRegister("swift_shell_drag_past_the_top_scrolls_into_history") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                // Somewhere to scroll to.
                surface.send("for i in $(seq 1 200); do echo drag-line-$i; done\n")
                var scrollback = 0
                for _ in 0..<40 {
                    t.pump(0.1)
                    scrollback = Int(surface.drive.readSnapshot().scrollbackCount)
                    if scrollback > 60 { break }
                }
                guard scrollback > 60 else {
                    t.expect(false, desc: "the shell produced scrollback (got \(scrollback))")
                    return
                }
                t.expect(surface.viewOffset == 0, desc: "the view starts at the live tail")

                // Press inside, then drag well ABOVE the window and hold. The
                // hold is necessary: a drag whose button goes up on the
                // same run-loop turn never lets the timer tick, and a scenario
                // written without it passes whether or not the walk works.
                let inside = CGPoint(x: window.frame.width / 2, y: window.frame.height / 2)
                // Just above the window rather than far above it. The step is
                // proportional to how far outside the pointer is, so a point
                // 200 points up walks the whole of this scrollback within a
                // tick or two and the walk then stops itself at the buffer's
                // end — which makes the release below prove nothing, since
                // nothing was still running to stop.
                let above = CGPoint(x: window.frame.width / 2, y: window.frame.height + 60)
                guard let down = mouseEvent(.leftMouseDown, in: window, at: inside),
                    let dragged = mouseEvent(.leftMouseDragged, in: window, at: above),
                    let up = mouseEvent(.leftMouseUp, in: window, at: above)
                else {
                    t.expect(false, desc: "AppKit synthesises the drag events")
                    return
                }
                surface.mouseDown(with: down)
                surface.mouseDragged(with: dragged)
                t.pump(0.6) // several ticks of the 0.05s walk
                let reached = surface.viewOffset
                // The rows arriving under the held point are what the walk is
                // for, so the selection has to have reached them — a view that
                // moved while the selection stayed put is the same bug wearing
                // the passing half of this scenario. Counted in lines rather
                // than looked for by content: the press was already halfway up
                // a screen of numbered lines, so any row it names is one that
                // was on screen before the walk began. A selection taller than
                // the window is one only the walk can have made.
                let selectedLines = (surface.selectedText ?? "")
                    .split(
                        separator: "\n",
                        omittingEmptySubsequences: false
                    )
                    .count
                let windowRows = Int(surface.drive.readSnapshot().rows)
                surface.mouseUp(with: up)
                t.pump(0.1)

                t.expect(
                    reached > 0,
                    desc: "a drag held above the grid walked the view into history (offset \(reached))"
                )
                t.expect(
                    selectedLines > windowRows,
                    desc: "and the selection followed it past the window's own rows"
                        + " (\(selectedLines) lines, \(windowRows) rows)"
                )
                // And the release stops it: the offset must not keep climbing
                // once the button is up.
                let afterRelease = surface.viewOffset
                t.pump(0.3)
                t.expect(
                    surface.viewOffset == afterRelease,
                    desc: "the walk stops on release (offset \(surface.viewOffset), was \(afterRelease))"
                )
            }
        }

        // The same held drag on the alternate screen walks nowhere: that
        // screen keeps no history of its own, and the primary's is not its to
        // walk into. An offset of zero is also what a drag that never armed
        // its walk leaves, so this answers only beside the scenario above,
        // which is the control that says the gesture moves the view at all.
        UBUITestRegister("swift_shell_drag_past_the_top_scrolls_nowhere_on_the_alternate_screen") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                // History on the primary first, so the alternate screen is
                // entered with rows behind it. That is the trap: the rows
                // exist, and the question is whether the walk asks what the
                // active screen can reach or what the buffer holds.
                surface.send("for i in $(seq 1 200); do echo alternate-drag-line-$i; done\n")
                var scrollback = 0
                for _ in 0..<40 {
                    t.pump(0.1)
                    scrollback = Int(surface.drive.readSnapshot().scrollbackCount)
                    if scrollback > 60 { break }
                }
                guard scrollback > 60 else {
                    t.expect(false, desc: "the shell produced scrollback (got \(scrollback))")
                    return
                }

                // Sent through the shell rather than fed to the parser: the
                // walk clamps against the snapshot the drain publishes, so a
                // direct feed would move the model without reaching it.
                surface.send("printf '\\033[?1049h'\n")
                for _ in 0..<30 {
                    t.pump(0.1)
                    if surface.drive.readSnapshot().modes.alternateScreenActive { break }
                }
                let snapshot = surface.drive.readSnapshot()
                t.expect(snapshot.modes.alternateScreenActive, desc: "the alternate screen is up")
                t.expect(
                    snapshot.scrollbackCount > 0,
                    desc: "the primary's history is still behind it (\(snapshot.scrollbackCount) lines)"
                )
                t.expect(
                    Ubiquitty.Runtime.viewOffsetLimit(snapshot) == 0,
                    desc: "and the alternate screen offers none of it to scroll into"
                )
                t.expect(surface.viewOffset == 0, desc: "the view starts at the live tail")

                // The primary scenario's gesture: press inside, drag just
                // above the window, and hold for several ticks of the walk.
                let inside = CGPoint(x: window.frame.width / 2, y: window.frame.height / 2)
                let above = CGPoint(x: window.frame.width / 2, y: window.frame.height + 60)
                guard let down = mouseEvent(.leftMouseDown, in: window, at: inside),
                    let dragged = mouseEvent(.leftMouseDragged, in: window, at: above),
                    let up = mouseEvent(.leftMouseUp, in: window, at: above)
                else {
                    t.expect(false, desc: "AppKit synthesises the drag events")
                    return
                }
                surface.mouseDown(with: down)
                surface.mouseDragged(with: dragged)
                t.pump(0.6)
                let reached = surface.viewOffset
                surface.mouseUp(with: up)
                t.pump(0.1)

                t.expect(
                    reached == 0,
                    desc: "the same drag held above the grid walked nowhere on the alternate screen (offset \(reached))"
                )
            }
        }

        // A drag through a proportional run selects by its letters, and the
        // same two points select the same letters whichever way the pointer
        // travelled between them; a drag that leaves the run takes the plain
        // cells beside it.
        UBUITestRegister("swift_shell_proportional_drag_is_the_same_in_both_directions") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let content = window.contentView, let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a terminal window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                surface.feed(Data("\u{1b}[H\u{1b}[2J\u{1b}[?25labc \u{1b}]66;p=1:c=20;Hello from Ubiquitty\u{1b}\\ xyz\r\n".utf8))
                t.pump(0.4)
                guard let cell0 = surface.viewPoint(forRow: 0, column: 0), let cell1 = surface.viewPoint(forRow: 0, column: 1) else {
                    t.expect(false, desc: "the surface places its cells")
                    return
                }
                let pitch = cell1.x - cell0.x
                let runLeft = cell0.x - pitch / 2 + 4 * pitch
                let y = cell0.y
                // The frame after a drag, saved for a reader of the highlight.
                let saveFrame = { (name: String) in
                    guard let frame = surface.renderedFrameForTesting() else { return }
                    let directory = URL(fileURLWithPath: "/tmp/propdrag", isDirectory: true)
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    guard let provider = CGDataProvider(data: frame.pixels as CFData),
                        let image = CGImage(
                            width: frame.width,
                            height: frame.height,
                            bitsPerComponent: 8,
                            bitsPerPixel: 32,
                            bytesPerRow: frame.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(
                                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                            ),
                            provider: provider,
                            decode: nil,
                            shouldInterpolate: false,
                            intent: .defaultIntent
                        ),
                        let destination = CGImageDestinationCreateWithURL(
                            directory.appendingPathComponent("\(name).png") as CFURL,
                            "public.png" as CFString,
                            1,
                            nil
                        )
                    else { return }
                    CGImageDestinationAddImage(destination, image, nil)
                    CGImageDestinationFinalize(destination)
                }
                var dragIndex = 0
                // A drag as the pointer makes it: a press, a motion every few
                // pixels, a release; the copy after each motion.
                let dragReadingEach = { (from: CGFloat, to: CGFloat) -> [String] in
                    dragIndex += 1
                    var readings: [String] = []
                    let start = surface.convert(CGPoint(x: runLeft + from, y: y), to: nil)
                    if let press = mouseEvent(.leftMouseDown, in: window, at: start) { surface.mouseDown(with: press) }
                    let steps = max(2, Int(abs(to - from)))
                    for step in 1...steps {
                        let x = runLeft + from + (to - from) * CGFloat(step) / CGFloat(steps)
                        let at = surface.convert(CGPoint(x: x, y: y), to: nil)
                        if let drag = mouseEvent(.leftMouseDragged, in: window, at: at) { surface.mouseDragged(with: drag) }
                        let reading = surface.selectedText ?? ""
                        if dragIndex >= 3 && reading != readings.last && reading.count >= 11 {
                            t.pump(0.05)
                            saveFrame("drag\(dragIndex)-\(reading.count)")
                        }
                        readings.append(reading)
                    }
                    let end = surface.convert(CGPoint(x: runLeft + to, y: y), to: nil)
                    if let release = mouseEvent(.leftMouseUp, in: window, at: end) { surface.mouseUp(with: release) }
                    readings.append(surface.selectedText ?? "")
                    return readings
                }
                let rightwards = dragReadingEach(6, 70)
                let leftwards = dragReadingEach(70, 6)
                // Every letter of the run in turn, one pixel at a time: no
                // letter is skipped on the way, whichever way the pointer goes.
                let acrossRight = dragReadingEach(2, 19 * pitch)
                let acrossLeft = dragReadingEach(19 * pitch, 2)
                FileHandle.standardError.write(
                    Data("proportional drag across right: \(Array(Set(acrossRight)).sorted { $0.count < $1.count })\n".utf8)
                )
                FileHandle.standardError.write(
                    Data("proportional drag across left: \(Array(Set(acrossLeft)).sorted { $0.count < $1.count })\n".utf8)
                )
                t.expect(
                    Set(acrossRight).count >= 19,
                    desc: "a pixel-by-pixel drag rightwards reads every letter in turn (\(Set(acrossRight).count) distinct)"
                )
                t.expect(
                    Set(acrossLeft).count >= 19,
                    desc: "a pixel-by-pixel drag leftwards reads every letter in turn (\(Set(acrossLeft).count) distinct)"
                )
                FileHandle.standardError.write(Data("proportional drag rightwards: \(rightwards)\n".utf8))
                FileHandle.standardError.write(Data("proportional drag leftwards: \(leftwards)\n".utf8))
                t.expect(
                    rightwards.last == leftwards.last,
                    desc: "the same two points select the same letters either way: '\(rightwards.last ?? "")' vs '\(leftwards.last ?? "")'"
                )
                let distinctRight = Set(rightwards).count
                t.expect(distinctRight >= 5, desc: "a drag rightwards grows a letter at a time (\(distinctRight) distinct readings)")
                let distinctLeft = Set(leftwards).count
                t.expect(distinctLeft >= 5, desc: "a drag leftwards grows a letter at a time (\(distinctLeft) distinct readings)")

                let outRight = dragReadingEach(40, 24 * pitch + 2 * pitch)
                FileHandle.standardError.write(Data("proportional drag out right: \(outRight)\n".utf8))
                t.expect(
                    (outRight.last ?? "").hasSuffix("xyz") || (outRight.last ?? "").hasSuffix("xy"),
                    desc: "a drag out of the run to the right takes the plain cells after it: '\(outRight.last ?? "")'"
                )
                t.expect(!outRight.dropFirst(2).contains(""), desc: "the selection never vanishes on the way out")
                // The same run set bold: the letters are read where the bold
                // face draws them, not where the regular face would.
                surface.feed(
                    Data("\u{1b}[H\u{1b}[2J\u{1b}[?25labc \u{1b}[1m\u{1b}]66;p=1:c=20;Hello from Ubiquitty\u{1b}\\\u{1b}[0m xyz\r\n".utf8)
                )
                t.pump(0.4)
                dragIndex = 10
                let boldRight = dragReadingEach(2, 19 * pitch)
                FileHandle.standardError.write(
                    Data("proportional drag across a bold run: \(Array(Set(boldRight)).sorted { $0.count < $1.count })\n".utf8)
                )
                t.expect(Set(boldRight).count >= 19, desc: "every letter of a bold run is read in turn (\(Set(boldRight).count) distinct)")

                // The same run across a double-height pair, as the Welcome
                // screen sets its name: a logical cell is two screen cells
                // wide, and the letters are read where they are drawn.
                surface.feed(
                    Data(
                        "\u{1b}[H\u{1b}[2J\u{1b}[?25l\u{1b}#3\u{1b}]66;p=1:c=20;Hello from Ubiquitty\u{1b}\\\r\n\u{1b}#4\u{1b}]66;p=1:c=20;Hello from Ubiquitty\u{1b}\\\r\n"
                            .utf8
                    )
                )
                t.pump(0.4)
                let runLeftDoubled = cell0.x - pitch / 2
                let doubledRight = { () -> [String] in
                    var readings: [String] = []
                    let start = surface.convert(CGPoint(x: runLeftDoubled + 2, y: y), to: nil)
                    if let press = mouseEvent(.leftMouseDown, in: window, at: start) { surface.mouseDown(with: press) }
                    let steps = Int(40 * pitch)
                    for step in 1...steps {
                        let at = surface.convert(CGPoint(x: runLeftDoubled + 2 + CGFloat(step), y: y), to: nil)
                        if let drag = mouseEvent(.leftMouseDragged, in: window, at: at) { surface.mouseDragged(with: drag) }
                        readings.append(surface.selectedText ?? "")
                    }
                    if let release = mouseEvent(.leftMouseUp, in: window, at: start) { surface.mouseUp(with: release) }
                    return readings
                }()
                FileHandle.standardError.write(
                    Data("proportional drag across a double-height run: \(Array(Set(doubledRight)).sorted { $0.count < $1.count })\n".utf8)
                )
                t.expect(
                    Set(doubledRight).count >= 19,
                    desc: "every letter of a double-height run is read in turn (\(Set(doubledRight).count) distinct)"
                )
                surface.feed(Data("\u{1b}[H\u{1b}[2J\u{1b}[?25labc \u{1b}]66;p=1:c=20;Hello from Ubiquitty\u{1b}\\ xyz\r\n".utf8))
                t.pump(0.4)
                let outLeft = dragReadingEach(40, -3 * pitch)
                FileHandle.standardError.write(Data("proportional drag out left: \(outLeft)\n".utf8))
                t.expect(
                    (outLeft.last ?? "").hasPrefix("bc ") || (outLeft.last ?? "").hasPrefix("abc "),
                    desc: "a drag out of the run to the left takes the plain cells before it: '\(outLeft.last ?? "")'"
                )
                t.expect(!outLeft.dropFirst(2).contains(""), desc: "the selection never vanishes on the way out leftwards")
            }
        }

        // A selection through a proportional run is a selection like any
        // other: the window losing key and the app losing active leave it
        // standing and drawn, and Select All takes the run's letters with the
        // rest of the row.
        UBUITestRegister("swift_shell_a_run_selection_survives_deactivation_and_select_all") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let content = window.contentView, let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a terminal window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                surface.feed(
                    Data("\u{1b}[H\u{1b}[2J\u{1b}[?25labc \u{1b}]66;p=1:c=20;Hello from Ubiquitty\u{1b}\\ xyz\r\nsecond row\r\n".utf8)
                )
                t.pump(0.4)
                guard let cell0 = surface.viewPoint(forRow: 0, column: 0), let cell1 = surface.viewPoint(forRow: 0, column: 1) else {
                    t.expect(false, desc: "the surface places its cells")
                    return
                }
                let pitch = cell1.x - cell0.x
                let runLeft = cell0.x - pitch / 2 + 4 * pitch
                let selected = dragSelect(
                    on: surface,
                    in: window,
                    fromViewPoint: CGPoint(x: runLeft + 4, y: cell0.y),
                    toViewPoint: CGPoint(x: runLeft + 60, y: cell0.y)
                )
                t.expect(selected.hasPrefix("Hello"), desc: "letters of the run are selected: '\(selected)'")
                t.pump(0.1)
                let background = backgroundPixel(surface)
                let litBefore = selectionPixelCount(surface, background: background)
                t.expect(litBefore > 0, desc: "the run's selection is drawn (\(litBefore) selection pixels)")

                // The app goes to the back: the window resigns key and main,
                // the app resigns active.
                let center = NotificationCenter.default
                center.post(name: NSWindow.didResignKeyNotification, object: window)
                center.post(name: NSWindow.didResignMainNotification, object: window)
                center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
                t.pump(0.3)
                t.expect(
                    surface.selectedText == selected,
                    desc: "the selection stands through deactivation: '\(surface.selectedText ?? "")'"
                )
                let litAfter = selectionPixelCount(surface, background: background)
                t.expect(litAfter > 0, desc: "and is still drawn (\(litAfter) selection pixels)")
                center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
                center.post(name: NSWindow.didBecomeKeyNotification, object: window)
                t.pump(0.3)
                t.expect(surface.selectedText == selected, desc: "and through reactivation: '\(surface.selectedText ?? "")'")
                t.expect(selectionPixelCount(surface, background: background) > 0, desc: "drawn again after reactivation")

                // The selection recoloured under a retained frame, which is
                // what a focus change does to a native selection: the rows
                // holding it repaint, the run's plate with them. The host's
                // colour drives the same repaint here.
                surface.feed(Data("\u{1b}]17;rgb:ff/00/00\u{1b}\\".utf8))
                t.pump(0.3)
                saveSurfaceFrame(surface, "deact-recoloured")
                let reddened = redPlatePixelCount(surface)
                t.expect(reddened > 200, desc: "the run's plate repaints in the new selection colour (\(reddened) red pixels)")
                surface.feed(Data("\u{1b}]117\u{1b}\\".utf8))
                t.pump(0.3)
                t.expect(
                    surface.selectedText == selected,
                    desc: "the selection stands through the recolour: '\(surface.selectedText ?? "")'"
                )

                saveSurfaceFrame(surface, "deact-before-select-all")
                surface.selectAll(nil)
                t.pump(0.2)
                saveSurfaceFrame(surface, "deact-after-select-all")
                let all = surface.selectedText ?? ""
                t.expect(
                    all.contains("abc Hello from Ubiquitty xyz"),
                    desc: "Select All takes the run's letters with the row: '\(all.prefix(60))'"
                )
                t.expect(all.contains("second row"), desc: "and every row")
                let allLit = selectionPixelCount(surface, background: background)
                t.expect(allLit > litBefore, desc: "and the whole screen's selection is drawn (\(allLit) over \(litBefore))")
            }
        }

        // Select All over the Welcome screen: a screen of runs of every
        // alignment, bold and plain, on single and double-height rows, each
        // of which is lit with the rest of its row.
        UBUITestRegister("swift_shell_select_all_lights_every_run_of_the_welcome_screen") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let content = window.contentView, let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a terminal window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                surface.feed(welcomeScreenBytes(for: surface))
                t.pump(0.5)
                saveSurfaceFrame(surface, "welcome-before")
                let background = backgroundPixel(surface)
                surface.selectAll(nil)
                t.pump(0.3)
                saveSurfaceFrame(surface, "welcome-select-all")
                // Frames that reuse the retained rows — a cursor blink's worth
                // of output on the prompt row — must not composite the plate
                // again over the rows they keep: a wash drawn twice is a
                // darker plate, and drawn every frame it is an opaque one.
                for step in 0..<6 {
                    surface.feed(Data("\u{1b}[24;1H\u{1b}[?25h\(step % 2 == 0 ? "x" : "\u{8} ")".utf8))
                    t.pump(0.12)
                    _ = surface.renderedFrameForTesting()
                }
                saveSurfaceFrame(surface, "welcome-select-all-later")
                // The whole frame but the margins is the plate: the background
                // is no longer the commonest colour anywhere a row is drawn.
                guard let frame = surface.renderedFrameForTesting() else {
                    t.expect(false, desc: "a frame reads back")
                    return
                }
                var backgroundLeft = 0
                frame.pixels.withUnsafeBytes { raw in
                    for index in 0..<(frame.width * frame.height)
                    where raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self) & 0x00FF_FFFF == background {
                        backgroundLeft += 1
                    }
                }
                let share = Double(backgroundLeft) / Double(frame.width * frame.height)
                t.expect(
                    share < 0.12,
                    desc: "Select All lights the runs with the rows: \(Int(share * 100))% of the frame is still the background"
                )
            }
        }

        // The Welcome screen narrowed from eighty columns to sixty-four: the
        // rewrap moves every run to a new row, and each draws whole where it
        // landed — centred, right-ranged or left-set in its claim — rather
        // than as its first letters at the anchor.
        UBUITestRegister("swift_shell_a_narrowed_welcome_screen_draws_every_run_whole") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let content = window.contentView, let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a terminal window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                guard let cell0 = surface.viewPoint(forRow: 0, column: 0), let cell1 = surface.viewPoint(forRow: 0, column: 1) else {
                    return
                }
                let pitch = cell1.x - cell0.x
                let before = window.frame
                FileHandle.standardError.write(Data("grid before: \(surface.publishedGrid.columns)x\(surface.publishedGrid.rows)\n".utf8))
                surface.feed(welcomeScreenBytes(for: surface))
                t.pump(0.5)
                saveSurfaceFrame(surface, "welcome-wide")
                var narrower = before
                narrower.size.width -= 16 * pitch
                window.setFrame(narrower, display: true)
                t.pump(0.8)
                FileHandle.standardError.write(Data("grid after: \(surface.publishedGrid.columns)x\(surface.publishedGrid.rows)\n".utf8))
                saveSurfaceFrame(surface, "welcome-narrow")
                // The ink of each row, in cells: the name is centred on the
                // row and the slogan under it, and no row holding a run is a
                // two-cell stub at the anchor.
                guard let frame = surface.renderedFrameForTesting() else {
                    t.expect(false, desc: "a frame reads back")
                    return
                }
                guard let firstCell = surface.viewPoint(forRow: 0, column: 0),
                    let nextColumn = surface.viewPoint(forRow: 0, column: 1),
                    let nextRow = surface.viewPoint(forRow: 1, column: 0)
                else {
                    t.expect(false, desc: "the drawn cell geometry is available")
                    return
                }
                let columns = surface.publishedGrid.columns
                let pixelsPerPoint = Double(frame.width) / Double(surface.bounds.width)
                let cellWidth = Double(nextColumn.x - firstCell.x) * pixelsPerPoint
                let rowHeight = Double(nextRow.y - firstCell.y) * pixelsPerPoint
                let gridLeft = (Double(firstCell.x) - Double(nextColumn.x - firstCell.x) / 2) * pixelsPerPoint
                let firstRowCentre = Double(firstCell.y) * pixelsPerPoint
                let background = frame.pixels.withUnsafeBytes { raw in
                    raw.loadUnaligned(fromByteOffset: ((frame.height - 3) * frame.width + frame.width - 3) * 4, as: UInt32.self)
                        & 0x00FF_FFFF
                }
                let inkExtent = { (row: Int) -> (first: Double, last: Double)? in
                    var first = Int.max
                    var last = -1
                    frame.pixels.withUnsafeBytes { raw in
                        let centre = Int((firstRowCentre + Double(row) * rowHeight).rounded())
                        let halfBand = max(1, Int(rowHeight * 0.2))
                        for y in stride(from: max(0, centre - halfBand), through: min(frame.height - 1, centre + halfBand), by: 2) {
                            for x in 0..<frame.width {
                                let pixel = raw.loadUnaligned(fromByteOffset: (y * frame.width + x) * 4, as: UInt32.self) & 0x00FF_FFFF
                                let dr = abs(Int(pixel >> 16 & 0xFF) - Int(background >> 16 & 0xFF))
                                let dg = abs(Int(pixel >> 8 & 0xFF) - Int(background >> 8 & 0xFF))
                                let db = abs(Int(pixel & 0xFF) - Int(background & 0xFF))
                                if dr + dg + db > 80 {
                                    first = min(first, x)
                                    last = max(last, x)
                                }
                            }
                        }
                    }
                    return last < 0 ? nil : ((Double(first) - gridLeft) / cellWidth, (Double(last) - gridLeft) / cellWidth)
                }
                let text = surface.gridTextForTesting().components(separatedBy: "\n")
                let nameRow = text.firstIndex(where: { $0.hasPrefix("U") }) ?? -1
                t.expect(nameRow >= 0, desc: "the name's rows are on screen")
                if nameRow >= 0, let name = inkExtent(nameRow) {
                    let centre = (name.first + name.last) / 2
                    t.expect(abs(centre - Double(columns) / 2) < 3, desc: "the name is centred on the narrowed row (\(name))")
                    t.expect(name.last - name.first > 8, desc: "and drawn whole, not a stub at the anchor (\(name))")
                }
                for (row, line) in text.enumerated() where line.contains("F") || line.contains("T") || line.contains("M") {
                    guard line.trimmingCharacters(in: .whitespaces).count == 1, let extent = inkExtent(row) else { continue }
                    t.expect(
                        extent.last > 14 && extent.last < 16,
                        desc: "a right-ranged name ends at its claim's edge on row \(row) (\(extent))"
                    )
                }
            }
        }

        UBUITestRegister("swift_shell_rtl_drag_copies_the_visible_language") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let content = window.contentView, let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a terminal window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                surface.feed(Data("\u{1b}[H\u{1b}[2J\u{1b}[?25lبسم\r\nلا\r\nسلام دنیا  שלום עולם\r\n東京 가나다 オペレーション".utf8))
                t.pump(0.3)
                let arabic = dragSelect(on: surface, in: window, from: (row: 2, column: 10), to: (row: 2, column: 19), modifiers: [])
                t.expect(arabic == "سلام دنیا", desc: "the visual Arabic range copies original Arabic code points: \(arabic)")
                let hebrew = dragSelect(on: surface, in: window, from: (row: 2, column: 8), to: (row: 2, column: 0), modifiers: [.option])
                t.expect(hebrew == "שלום עולם", desc: "a reverse rectangular Hebrew drag copies Hebrew: \(hebrew)")
            }
        }

        UBUITestRegister("swift_shell_option_drag_selects_a_block") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                surface.feed(Data("\u{1b}[H\u{1b}[2JABCDEFGH\r\nIJKLMNOP\r\nQRSTUVWX\r\n".utf8))
                t.pump(0.3)

                // The control: a plain drag flows from the press to the
                // release, taking the rest of the first row with it. Its ends
                // are carets rather than cells — a press at a cell's centre is
                // past that cell's midpoint, so it anchors after the C, which
                // is where a text field would put it.
                let flowing = dragSelect(
                    on: surface,
                    in: window,
                    from: (row: 0, column: 2),
                    to: (row: 1, column: 5),
                    modifiers: []
                )
                t.expect(
                    flowing == "DEFGH\nIJKLMN",
                    desc: "a plain drag selects the flowing span (\(flowing.debugDescription))"
                )

                // Option makes the same two points a column block: every row
                // clips to the pressed columns, which is the whole difference.
                let block = dragSelect(
                    on: surface,
                    in: window,
                    from: (row: 0, column: 2),
                    to: (row: 1, column: 5),
                    modifiers: [.option]
                )
                t.expect(
                    block == "CDEF\nKLMN",
                    desc: "Option-drag selects the column block (\(block.debugDescription))"
                )

                // And the pointer says so for as long as the block is being
                // dragged. The shape is Core's ranking; what this arm owes it
                // is the fact that a block is armed.
                t.expect(
                    surface.pointerCursor === NSCursor.iBeam,
                    desc: "the pointer is an I-beam with no drag in flight"
                )
                t.expect(
                    holdingPress(on: surface, in: window, atRow: 0, column: 2) { surface.pointerCursor === NSCursor.crosshair },
                    desc: "an Option press shows the crosshair for the block it is making"
                )

                // The block chord reaches through an application holding the
                // mouse, the way Shift reaches a flowing selection through one.
                surface.feed(Data("\u{1b}[?1000h".utf8))
                t.pump(0.3)
                t.expect(
                    holdingPress(on: surface, in: window, atRow: 0, column: 2) { surface.pointerCursor === NSCursor.crosshair },
                    desc: "the crosshair is still offered over a tracking app"
                )
                let reachedThrough = dragSelect(
                    on: surface,
                    in: window,
                    from: (row: 0, column: 2),
                    to: (row: 1, column: 5),
                    modifiers: [.option]
                )
                t.expect(
                    reachedThrough == "CDEF\nKLMN",
                    desc: "and the block is really made over the tracking app (\(reachedThrough.debugDescription))"
                )

                // Which chord that is, is the reader's: moved to Shift+Option,
                // Option alone stops arming the block — exactly, so the chord
                // it was cannot still fire — and the configured one arms it.
                let saved = t.configureAppending("[selection]\nblock_select_modifier = \"shift+opt\"\n")
                defer { t.restoreConfiguration(saved) }
                t.expect(
                    holdingPress(on: surface, in: window, atRow: 0, column: 2) { surface.pointerCursor === NSCursor.arrow },
                    desc: "with the chord moved, a bare Option press is the tracking app's again"
                )
                let swallowed = dragSelect(
                    on: surface,
                    in: window,
                    from: (row: 2, column: 1),
                    to: (row: 2, column: 4),
                    modifiers: [.option]
                )
                t.expect(
                    swallowed.isEmpty,
                    desc: "and that Option-click reaches the application instead (\(swallowed.debugDescription))"
                )
                t.expect(
                    holdingPress(on: surface, in: window, atRow: 0, column: 2, modifiers: [.shift, .option]) {
                        surface.pointerCursor === NSCursor.crosshair
                    },
                    desc: "while the configured chord offers the crosshair"
                )
                let movedChord = dragSelect(
                    on: surface,
                    in: window,
                    from: (row: 0, column: 2),
                    to: (row: 1, column: 5),
                    modifiers: [.shift, .option]
                )
                t.expect(
                    movedChord == "CDEF\nKLMN",
                    desc: "and makes the same block (\(movedChord.debugDescription))"
                )
                surface.feed(Data("\u{1b}[?1000l".utf8))
            }
        }

        UBUITestRegister("swift_shell_window_drags_from_any_cell") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                surface.feed(Data("\u{1b}[H\u{1b}[2JABCDEFGH\r\nIJKLMNOP\r\n".utf8))
                t.pump(0.3)

                // The control: a plain drag selects and leaves the window
                // where it was.
                let before = window.frame.origin
                let selected = dragSelect(
                    on: surface,
                    in: window,
                    from: (row: 0, column: 1),
                    to: (row: 0, column: 4),
                    modifiers: []
                )
                t.expect(!selected.isEmpty, desc: "a plain drag selects (\(selected.debugDescription))")
                t.expect(
                    window.frame.origin == before,
                    desc: "and leaves the window where it was"
                )

                // The configured modifiers turn the same drag into a window
                // move, from a cell rather than a title bar.
                let moved = dragSelect(
                    on: surface,
                    in: window,
                    from: (row: 0, column: 1),
                    to: (row: 1, column: 6),
                    modifiers: [.control, .command]
                )
                t.expect(
                    window.frame.origin != before,
                    desc: "the drag modifier moves the window (\(window.frame.origin) from \(before))"
                )
                t.expect(
                    moved == selected,
                    desc: "and leaves the selection it was carrying alone (\(moved.debugDescription))"
                )

                // Chromeless: with no title bar, Command over the body is the
                // grab that the title bar would have been. The pointer says so
                // before anything is dragged.
                let saved = t.configureAppending("[appearance]\nhide_title_bar = false\n")
                defer { t.restoreConfiguration(saved) }
                let withATitleBar = window.frame.origin
                _ = dragSelect(
                    on: surface,
                    in: window,
                    from: (row: 1, column: 2),
                    to: (row: 1, column: 7),
                    modifiers: [.command]
                )
                t.expect(
                    window.frame.origin == withATitleBar,
                    desc: "a window with a title bar is not moved by Command over the grid"
                )

                // The window's own state rather than the default: the toggle
                // is per window, and a window told to hide its bar is
                // chromeless whatever the configuration says, and the
                // configuration still says false.
                shell.toggleHideTitleBar(nil)
                t.pump(0.2)
                let beforeChromeless = window.frame.origin
                let selectionBeforeMove = surface.selectedText ?? ""
                let underCommand = dragSelect(
                    on: surface,
                    in: window,
                    from: (row: 1, column: 2),
                    to: (row: 1, column: 7),
                    modifiers: [.command]
                )
                t.expect(
                    window.frame.origin != beforeChromeless,
                    desc: "Command moves a chromeless window from its body (\(window.frame.origin) from \(beforeChromeless))"
                )
                t.expect(
                    underCommand == selectionBeforeMove,
                    desc: "and makes no selection of its own (\(underCommand.debugDescription))"
                )
            }
        }

        UBUITestRegister("swift_shell_a_plain_drag_selects_by_caret_boundaries") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                window.makeKeyAndOrderFront(nil)
                surface.feed(Data("\u{1b}[H\u{1b}[2JABCDEFGH\r\n".utf8))
                t.pump(0.3)

                guard let cellZero = surface.viewPoint(forRow: 0, column: 0),
                    let cellOne = surface.viewPoint(forRow: 0, column: 1)
                else {
                    t.expect(false, desc: "the grid has been measured")
                    return
                }
                let cellWidth = cellOne.x - cellZero.x
                // A quarter of a cell either side of a centre: near enough to a
                // boundary that a caret snaps to it, and far enough from the
                // next that a whole-cell reading would not move.
                @MainActor
                func point(row: Int, column: Int, towards side: CGFloat) -> CGPoint? {
                    guard let centre = surface.viewPoint(forRow: row, column: column) else { return nil }
                    return CGPoint(x: centre.x + side * cellWidth / 4, y: centre.y)
                }
                guard let rightOfC = point(row: 0, column: 2, towards: 1),
                    let rightOfD = point(row: 0, column: 3, towards: 1)
                else {
                    t.expect(false, desc: "the sub-cell points could be resolved")
                    return
                }

                // Both points sit in the right half of their cell, so the
                // carets are the boundaries following C and following D: the
                // span is the single character between them. A drag reading
                // whole cells would take C as well.
                let selected = dragSelect(on: surface, in: window, fromViewPoint: rightOfC, toViewPoint: rightOfD)
                t.expect(
                    selected == "D",
                    desc: "the drag selects between the boundaries it crossed (\(selected.debugDescription))"
                )

                // The open threshold: a blank line collapses to one slot, so a
                // sweep along it never opens a selection at all — which is what
                // keeps a sloppy click on empty space from highlighting it.
                guard let blankLeft = surface.viewPoint(forRow: 4, column: 1),
                    let blankRight = surface.viewPoint(forRow: 4, column: 30)
                else {
                    t.expect(false, desc: "the blank row could be pointed at")
                    return
                }
                let onBlank = dragSelect(on: surface, in: window, fromViewPoint: blankLeft, toViewPoint: blankRight)
                t.expect(
                    onBlank.isEmpty,
                    desc: "a sweep along a blank line opens nothing (\(onBlank.debugDescription))"
                )
            }
        }

        // Core's cases drive a measurer double whose letters are a fixed
        // fraction of a cell, which pins the arithmetic and nothing else. What
        // they cannot answer is whether the platform's shaper, the surface's
        // pixel geometry and the pointer ladder agree about where a letter
        // sits: the caret is resolved from an unrounded window point through a
        // run laid out by the same face the frame is drawn with, and only a
        // real window has both.
        UBUITestRegister("swift_shell_a_drag_inside_a_packed_proportional_cell_takes_one_letter") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                window.makeKeyAndOrderFront(nil)
                // Six narrow letters in three cells: whatever the face's
                // advances, some cell of the run holds more than one letter's
                // ink. The scenario sweeps points rather than naming any,
                // because the advances are CoreText's.
                let letters = "iljtfr"
                surface.feed(Data("\u{1b}[H\u{1b}[2J\u{1b}[?25l\u{1b}]66;p=1:c=3;\(letters)\u{07}\r\n".utf8))
                t.pump(0.3)

                guard let cellZero = surface.viewPoint(forRow: 0, column: 0),
                    let cellOne = surface.viewPoint(forRow: 0, column: 1)
                else {
                    t.expect(false, desc: "the grid has been measured")
                    return
                }
                let cellWidth = cellOne.x - cellZero.x
                let row = cellZero.y

                // Every distinct text a drag between two points of one cell
                // takes. A gesture reading whole cells has one answer per cell,
                // whatever two points it is given; a caret that resolves inside
                // the cell has one per letter boundary.
                var packedCell = -1
                var fromOnePacked: Set<String> = []
                for column in 0..<3 where packedCell < 0 {
                    let left = cellZero.x + CGFloat(column) * cellWidth - cellWidth / 2
                    var selections: Set<String> = []
                    var from = left
                    while from < left + cellWidth {
                        var to = from + cellWidth / 5
                        while to <= left + cellWidth {
                            let selected = dragSelect(
                                on: surface,
                                in: window,
                                fromViewPoint: CGPoint(x: from, y: row),
                                toViewPoint: CGPoint(x: to, y: row)
                            )
                            if !selected.isEmpty {
                                selections.insert(selected)
                            }
                            to += cellWidth / 5
                        }
                        from += cellWidth / 5
                    }
                    if selections.count >= 2 {
                        packedCell = column
                        fromOnePacked = selections
                    }
                }
                t.expect(
                    packedCell >= 0,
                    desc: "one cell of the run answers two different drags differently (cell \(packedCell))"
                )
                let singles = fromOnePacked.filter { $0.count == 1 }
                t.expect(
                    !singles.isEmpty,
                    desc: "a drag inside that cell takes a single letter (\(fromOnePacked.sorted().debugDescription))"
                )
                t.expect(
                    singles.allSatisfy { letters.contains($0) },
                    desc: "and every single-letter answer is one of the run's letters (\(singles.sorted().debugDescription))"
                )
            }
        }

        UBUITestRegister("swift_shell_a_drag_keeps_the_ibeam_over_the_void") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                window.makeKeyAndOrderFront(nil)
                surface.feed(Data("\u{1b}[H\u{1b}[2JSHORT\r\n".utf8))
                t.pump(0.3)

                let saved = t.configureAppending("[selection]\nrestrict_to_text = true\n")
                defer { t.restoreConfiguration(saved) }

                // The control: with no button down the void is an arrow, which
                // is the affordance this scenario is about suppressing.
                t.expect(
                    hoverCursor(on: surface, in: window, row: 0, column: 40) === NSCursor.arrow,
                    desc: "a free move over the void shows the arrow"
                )

                // A drag opened on the text and swept out past the last glyph:
                // the pointer is driving the selection, so it stays an I-beam.
                let heldShape = holdingDrag(
                    on: surface,
                    in: window,
                    from: (row: 0, column: 1),
                    to: (row: 0, column: 40)
                ) { surface.pointerCursor }
                t.expect(
                    heldShape === NSCursor.iBeam,
                    desc: "the drag keeps the I-beam out over the void"
                )

                // And gives it back: the arrow returns on the next free move.
                t.expect(
                    hoverCursor(on: surface, in: window, row: 0, column: 40) === NSCursor.arrow,
                    desc: "the arrow returns on the first free move after release"
                )

                // The latch is Core's answer about the press, not the fact that
                // a button went down: a press a tracking application received
                // opened no selection, so nothing is being driven and the void
                // keeps its arrow. The program stops tracking between the press
                // and the question, because while it tracks it outranks both
                // answers and the leg would not discriminate.
                surface.feed(Data("\u{1b}[?1000h".utf8))
                t.pump(0.3)
                let reportedShape = holdingDrag(
                    on: surface,
                    in: window,
                    from: (row: 0, column: 1),
                    to: (row: 0, column: 40)
                ) {
                    surface.feed(Data("\u{1b}[?1000l".utf8))
                    t.pump(0.3)
                    return surface.pointerCursor
                }
                t.expect(
                    reportedShape === NSCursor.arrow,
                    desc: "a press the application received drives no selection"
                )
                surface.feed(Data("\u{1b}[?1000l".utf8))
                t.pump(0.3)
            }
        }

        UBUITestRegister("swift_shell_restrict_to_text_arrows_the_void") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                window.makeKeyAndOrderFront(nil)
                surface.feed(Data("\u{1b}[H\u{1b}[2JSHORT\r\n".utf8))
                t.pump(0.3)

                // Off by default: every cell of the row advertises selectable
                // text, printed or not.
                let saved = t.configureAppending("[selection]\nrestrict_to_text = false\n")
                defer { t.restoreConfiguration(saved) }
                t.expect(
                    hoverCursor(on: surface, in: window, row: 0, column: 40) === NSCursor.iBeam,
                    desc: "with the setting off the trailing void is still an I-beam"
                )

                // On: past the last glyph there is nothing to select, and the
                // pointer stops claiming there is.
                t.restoreConfiguration(saved)
                t.configureAppending("[selection]\nrestrict_to_text = true\n")
                t.expect(
                    hoverCursor(on: surface, in: window, row: 0, column: 2) === NSCursor.iBeam,
                    desc: "over the printed text it stays an I-beam"
                )
                t.expect(
                    hoverCursor(on: surface, in: window, row: 0, column: 4) === NSCursor.iBeam,
                    desc: "including the last glyph itself, which is text and not its own void"
                )
                t.expect(
                    hoverCursor(on: surface, in: window, row: 0, column: 5) === NSCursor.arrow,
                    desc: "and the cell after it is an arrow"
                )
                t.expect(
                    hoverCursor(on: surface, in: window, row: 0, column: 40) === NSCursor.arrow,
                    desc: "as is the rest of the line"
                )
                t.expect(
                    hoverCursor(on: surface, in: window, row: 3, column: 2) === NSCursor.arrow,
                    desc: "a row that printed nothing is void all the way across"
                )

                // A full-screen program fills the grid, so a blank cell is its
                // blank cell and not a void.
                surface.feed(Data("\u{1b}[?1049h".utf8))
                t.pump(0.3)
                t.expect(
                    hoverCursor(on: surface, in: window, row: 3, column: 2) === NSCursor.iBeam,
                    desc: "the alternate screen is exempt"
                )
                surface.feed(Data("\u{1b}[?1049l".utf8))
                t.pump(0.3)

                // And an application tracking the pointer owns every cell,
                // which Core ranks above the void anyway.
                surface.feed(Data("\u{1b}[?1000h".utf8))
                t.pump(0.3)
                t.expect(
                    hoverCursor(on: surface, in: window, row: 0, column: 2) === NSCursor.arrow,
                    desc: "and a tracking application takes even the printed cells, which Core ranks above the void"
                )
                surface.feed(Data("\u{1b}[?1000l".utf8))
            }
        }

        UBUITestRegister("swift_shell_resize_rewraps_history_and_defers_it_in_a_drag") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                // Long lines at the starting width, pushed into history: a
                // narrowing rewraps them into more rows than they occupy now,
                // and the reachable count is what says whether it happened.
                let columnsNow = Int(surface.drive.readSnapshot().columns)
                let rowsNow = Int(surface.drive.readSnapshot().rows)
                // Each line fits on one row at the starting width and takes two
                // at half of it, and there are enough of them to fill the
                // screen several times over.
                let wide = String(repeating: "x", count: max(columnsNow - 4, 8))
                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                for _ in 0..<(rowsNow * 3) {
                    surface.feed(Data((wide + "\r\n").utf8))
                }
                t.pump(0.4)
                let reachable = { Int(Ubiquitty.Runtime.viewOffsetLimit(surface.drive.readSnapshot())) }
                let columns = columnsNow
                let rows = rowsNow
                let before = reachable()
                t.expect(before > 0, desc: "the feed left history to rewrap (\(before) rows; grid \(rows)x\(columns))")

                // A settled resize pays for the rewrap now: half the width
                // takes about twice the rows.
                surface.drive.resize(rows: rows, columns: columns / 2, gesture: .settled)
                t.pump(0.3)
                let afterSettled = reachable()
                t.expect(
                    afterSettled > before,
                    desc: "a settled narrowing rewraps history into more rows (\(before) -> \(afterSettled))"
                )

                // Back to the starting width, then the same narrowing as one
                // step of a drag. Asked by whether a rewrap is OWED rather than
                // by the reachable count: reading that count is one of the
                // accesses the deferral resolves on, so the instrument would
                // pay for exactly what it was measuring.
                surface.drive.resize(rows: rows, columns: columns, gesture: .settled)
                t.pump(0.3)
                let restored = reachable()
                t.expect(
                    !surface.drive.hasDeferredHistoryRewrap,
                    desc: "a settled resize owes nothing afterwards"
                )
                surface.drive.resize(rows: rows, columns: columns / 2, gesture: .interactive)
                t.pump(0.3)
                t.expect(
                    surface.drive.hasDeferredHistoryRewrap,
                    desc: "a drag step leaves the history rewrap owed"
                )

                // And the settle pays for it once, at the width the drag
                // stopped at.
                surface.drive.settleResize()
                t.pump(0.3)
                t.expect(
                    !surface.drive.hasDeferredHistoryRewrap,
                    desc: "the settle pays it"
                )
                t.expect(
                    reachable() > restored,
                    desc: "and history is rewrapped to the narrower width (\(restored) -> \(reachable()))"
                )
            }
        }

        UBUITestRegister("swift_shell_tracks_the_pointer_over_its_visible_rect") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                // Without this the pointer never moves as far as the surface is
                // concerned: no move event arrives, so the link hover, the
                // pointer's shape and the document-style arrow are all dead in
                // a real window while a scenario that synthesises a move still
                // sees them work.
                let owned = surface.trackingAreas.filter { $0.owner === surface }
                t.expect(owned.count == 1, desc: "the surface owns one tracking area (\(owned.count))")
                guard let area = owned.first else { return }
                t.expect(
                    area.options.contains(.mouseMoved),
                    desc: "it asks for moves, which is what the hover runs on"
                )
                t.expect(
                    area.options.contains(.inVisibleRect),
                    desc: "and it follows the visible rect, so a pane grown by a sibling closing still tracks"
                )

                // A resize does not leave a second one behind: AppKit re-invokes
                // the update, and an area added per pass would report every
                // move as many times as the view has been laid out.
                surface.setFrameSize(CGSize(width: surface.frame.width - 40, height: surface.frame.height - 20))
                surface.updateTrackingAreas()
                t.pump(0.2)
                t.expect(
                    surface.trackingAreas.filter { $0.owner === surface }.count == 1,
                    desc: "and a layout pass replaces it rather than stacking another"
                )
            }
        }

        UBUITestRegister("swift_shell_top_edge_drag_anchors_the_grid_bottom") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                // The verdict the grid resize anchors on: a window whose
                // bottom held still is one whose top edge the reader is
                // dragging.
                let start = CGRect(x: 100, y: 100, width: 800, height: 600)
                t.expect(
                    TerminalSurface.isBottomEdgeFixed(resizingFrom: start, to: CGRect(x: 100, y: 100, width: 800, height: 500)),
                    desc: "a top-edge drag reads as bottom-fixed"
                )
                t.expect(
                    !TerminalSurface.isBottomEdgeFixed(resizingFrom: start, to: CGRect(x: 100, y: 200, width: 800, height: 500)),
                    desc: "and a bottom-edge drag reads as top-fixed"
                )

                // Outside a drag nothing is anchored anywhere but the top: the
                // flag is a fact about a gesture in progress, and a programmatic
                // resize has no stationary edge to speak of.
                t.expect(
                    !surface.isLiveResizeBottomFixed,
                    desc: "a surface not being dragged anchors at the top"
                )

                // Now the wiring, driven through the surface's own entry points:
                // a drag opens, the window's bottom holds while its height
                // shrinks, and the flag the grid resize reads follows.
                let opening = window.frame
                surface.viewWillStartLiveResize()
                t.expect(
                    surface.isDrivingFramesForTesting,
                    desc: "the drag starts the frame drive, so a reflow arriving mid-drag is drawn"
                )
                window.setFrame(
                    CGRect(x: opening.minX, y: opening.minY, width: opening.width, height: opening.height - 60),
                    display: false
                )
                surface.setFrameSize(CGSize(width: surface.frame.width, height: surface.frame.height - 60))
                t.pump(0.2)
                t.expect(
                    surface.isLiveResizeBottomFixed,
                    desc: "a top-edge drag anchors the grid at its bottom"
                )

                surface.viewDidEndLiveResize()
                t.pump(0.2)
                t.expect(
                    !surface.isLiveResizeBottomFixed,
                    desc: "and the settle puts the anchor back at the top"
                )
            }
        }
    }
    /// What a window's title row is teaching, read off the accessory itself.
    ///
    /// Off the view rather than off the surface's copy: what a reader can act
    /// on is the line in the title row, and a lesson that never reached it
    /// would answer differently here.
    ///
    /// - Parameter window: The window to read.
    /// - Returns: The line, empty when nothing is being taught.
    @MainActor
    private static func hintText(in window: NSWindow) -> String {
        for accessory in window.titlebarAccessoryViewControllers {
            func walk(_ view: NSView) -> String? {
                if let hint = view as? HintAccessory, !hint.isHidden {
                    return hint.stringValue
                }
                for subview in view.subviews {
                    if let found = walk(subview) { return found }
                }
                return nil
            }
            if let found = walk(accessory.view) { return found }
        }
        return ""
    }
}
