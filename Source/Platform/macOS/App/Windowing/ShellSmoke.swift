// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ShellSmoke.swift — the window shell's scenario battery: spawn, type, split,
// navigate, broadcast, close, tear down. One implementation drives both
// shells through the driver seam below, so the flip is gated on the same
// scenarios passing against either arm — a scenario added here is added to
// both, and a behaviour that only one arm carries fails loudly.

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// The shell verbs the parity battery drives — the seam both window shells
/// answer.
///
/// The members carry a `shell` prefix so the Metal arm's category adds them
/// beside its own selectors without a collision.
@objc(UBShellDriving)
@MainActor
public protocol ShellDriving {
    /// The window's live pane count.
    var shellPaneCount: Int { get }

    /// A stable identity for the focused pane — its view object, compared
    /// by reference across the scenarios.
    var shellFocusedPaneIdentity: AnyObject? { get }

    /// Whether the focused pane's view holds key focus in its window.
    var isShellFocusedPaneFirstResponder: Bool { get }

    /// Splits the focused pane into two columns.
    func shellSplitRight()

    /// Splits the focused pane into two rows.
    func shellSplitDown()

    /// Moves pane focus one pane left.
    func shellMovePaneFocusLeft()

    /// Moves pane focus one pane up.
    func shellMovePaneFocusUp()

    /// Expands the focused pane to fill the window, or collapses back.
    func shellToggleZoom()

    /// Whether a pane is currently zoomed over the split layout.
    var isShellZoomed: Bool { get }

    /// Whether closing the window would kill no live job — a shell sitting
    /// at its prompt answers true.
    var isShellSafeToClose: Bool { get }

    /// Closes the focused pane.
    func shellClosePane()

    /// Flips broadcast input.
    func shellToggleBroadcastInput()

    /// Sends text through the focused pane as typed input — the path
    /// broadcast fans out from.
    ///
    /// - Parameter text: The probe text.
    func shellSendProbe(_ text: String)

    /// Closes the window.
    func shellCloseWindow()
}

/// The battery's way to mint and count shell windows, per arm.
@objc(UBShellDriverFactory)
@MainActor
public protocol ShellDriverFactory {
    /// Spawns one shell window.
    ///
    /// - Returns: The window's driver, or nil when the arm cannot spawn.
    func spawnShell() -> ShellDriving?

    /// How many of this arm's shell windows are alive.
    var liveShellCount: Int { get }

    /// Spawns one shell window rebuilt from a captured split layout.
    ///
    /// - Parameter layout: The captured layout string.
    /// - Returns: The window's driver, or nil when the arm cannot spawn.
    func spawnShellRestoring(layout: String) -> ShellDriving?
}

/// The smoke's entry, which the application's entry point dispatches.
public final class ShellSmokeEntry: NSObject {
    /// Runs the battery against the Swift shell.
    ///
    /// - Returns: Whether every scenario passed.
    public static func run() -> Bool {
        MainActor.assumeIsolated {
            ShellSmoke.run(factory: SwiftShellDriverFactory(), arm: "swift")
                && (!ProcessInfo.processInfo.arguments.contains("--verify-tab-focus") || ShellSmoke.runTabFocus())
        }
    }

    /// Runs the battery against a caller-supplied arm — the Metal shell's
    /// category-built factory crosses here through the generated header.
    ///
    /// The factory transfers into the main-actor body, and the calling scope
    /// keeps no further use of it.
    ///
    /// - Parameter factory: The arm's window factory.
    /// - Returns: Whether every scenario passed.
    @objc
    public static func run(with factory: sending ShellDriverFactory) -> Bool {
        MainActor.assumeIsolated {
            ShellSmoke.run(factory: factory, arm: "metal")
        }
    }
}

/// The Swift shell's factory: the model-backed controller, counted by the
/// class's own spawn registry.
@MainActor
final class SwiftShellDriverFactory: NSObject, ShellDriverFactory {
    func spawnShell() -> ShellDriving? {
        TerminalWindowController.spawn()
    }

    var liveShellCount: Int {
        TerminalWindowController.spawnedControllers.count
    }

    func spawnShellRestoring(layout: String) -> ShellDriving? {
        TerminalWindowController.spawn(restoringLayout: layout)
    }
}

/// The Swift shell answers the battery with its model-backed facts.
extension TerminalWindowController: ShellDriving {
    public var shellPaneCount: Int { paneCount }

    public var shellFocusedPaneIdentity: AnyObject? { focusedSurface }

    public var isShellFocusedPaneFirstResponder: Bool {
        guard let focused = focusedSurface else {
            return false
        }
        return window?.firstResponder === focused
    }

    public func shellSplitRight() { splitRight(nil) }

    public func shellSplitDown() { splitDown(nil) }

    public func shellMovePaneFocusLeft() { movePaneFocusLeft(nil) }

    public func shellMovePaneFocusUp() { movePaneFocusUp(nil) }

    public func shellToggleZoom() { toggleZoomPane(nil) }

    public var isShellZoomed: Bool { isZoomed }

    public var isShellSafeToClose: Bool { isSafeToClose }

    public func shellClosePane() { closePane(nil) }

    public func shellToggleBroadcastInput() { toggleBroadcastInput(nil) }

    public func shellSendProbe(_ text: String) { focusedSurface?.send(text) }

    public func shellCloseWindow() { close() }
}

/// The scenarios, each a named step so a failure reads as the behaviour it
/// lost rather than a line number.
@MainActor
enum ShellSmoke {
    static func runTabFocus() -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        NSApp.activate(ignoringOtherApps: true)
        var controllers: [TerminalWindowController] = []
        defer { for controller in controllers { controller.window?.close() } }
        for _ in 0..<3 {
            guard let controller = TerminalWindowController.spawn(), let window = controller.window else { return false }
            if let first = controllers.first?.window { first.addTabbedWindow(window, ordered: .above) }
            controllers.append(controller)
        }
        guard let first = controllers.first?.window, let group = first.tabGroup else { return false }
        if let screen = NSScreen.screens.first(where: {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }) {
            first.setFrame(
                NSRect(x: screen.visibleFrame.minX + 60, y: screen.visibleFrame.minY + 60, width: 720, height: 420),
                display: true
            )
        }
        func titleAlpha(_ window: NSWindow) -> CGFloat? {
            guard let root = window.contentView?.superview,
                let container = TabStripStyling.titlebarContainer(searchingFrom: root),
                let titlebar = ([container] + container.subviews).first(where: { NSStringFromClass(type(of: $0)) == "NSTitlebarView" }),
                let field = titlebar.subviews.compactMap({ $0 as? NSTextField }).filter({ !$0.isHidden && $0.frame.width > 0 })
                    .max(by: { $0.frame.width < $1.frame.width })
            else { return nil }
            var alpha: CGFloat = 0
            field.attributedStringValue.enumerateAttribute(
                .foregroundColor,
                in: NSRange(location: 0, length: field.attributedStringValue.length)
            ) { color, _, _ in
                if let color = color as? NSColor { alpha = max(alpha, color.alphaComponent) }
            }
            return alpha
        }
        for index in [0, 2, 1, 0, 1, 2] {
            let window = group.windows[index]
            group.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
            let deadline = Date().addingTimeInterval(0.25)
            while Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                NSApp.updateWindows()
            }
            guard window.isKeyWindow, let alpha = titleAlpha(window), alpha > 0.99,
                let root = window.contentView?.superview,
                let container = TabStripStyling.titlebarContainer(searchingFrom: root),
                let paint = TabStripStyling.testPaint(in: container), paint.band == nil
            else {
                print(
                    "shell-smoke[swift]: tab \(index) retained inactive chrome, title alpha=\(String(describing: titleAlpha(window))), app=\(NSApp.isActive), key=\(window.isKeyWindow), main=\(window.isMainWindow), group=\(group.windows.map { ($0.isKeyWindow, $0.isMainWindow) })"
                )
                return false
            }
        }
        print("shell-smoke[swift]: PASS — first, middle, and last tab activation")
        return true
    }

    static func run(factory: ShellDriverFactory, arm: String) -> Bool {
        // Windows need the application object; the smoke runs before the
        // real app setup, so take the minimal one.
        _ = NSApplication.shared

        func failed(_ what: String) -> Bool {
            FileHandle.standardError.write(Data("shell-smoke[\(arm)]: \(what)\n".utf8))
            return false
        }

        // A claim about a shell's job state is a claim about a child process
        // that is still starting: a shell reaches its prompt when its login
        // and startup files finish, and the model hears about it on the run
        // loop this battery stands on. Asking the moment after the spawn
        // measures how loaded the machine is, and a machine running several
        // checkouts' gate suites at once can read "three idle shells" as a
        // live job and report a defect that is not in the tree.
        //
        // Waiting establishes the claim's own precondition rather than
        // tolerating its failure: the assertion names shells that have
        // reached their prompts, and the wait is what puts them there. A
        // claim that never comes true still fails, at the deadline.
        func settles(_ claim: () -> Bool, within seconds: TimeInterval = 10) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !claim() {
                if Date() >= deadline {
                    return false
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            return true
        }

        // Spawn: a window over one live pane, focused.
        guard let shell = factory.spawnShell() else {
            return failed("the shell did not spawn")
        }

        if let responder = shell as? NSResponder {
            for name in ["clearBuffer:", "clearScrollback:", "clearScreen:", "clearToPreviousMark:"] {
                guard responder.responds(to: NSSelectorFromString(name)) else {
                    shell.shellCloseWindow()
                    return failed("the linked shell does not answer \(name)")
                }
            }
        }
        guard shell.shellPaneCount == 1 else {
            return failed("a fresh window holds \(shell.shellPaneCount) panes")
        }
        guard let first = shell.shellFocusedPaneIdentity else {
            return failed("a fresh window has no focused pane")
        }
        guard shell.isShellFocusedPaneFirstResponder else {
            return failed("the spawned pane is not first responder")
        }

        // Split right: the layout gains a pane and focus moves to it.
        shell.shellSplitRight()
        guard shell.shellPaneCount == 2 else {
            return failed("a split left \(shell.shellPaneCount) panes")
        }
        guard let second = shell.shellFocusedPaneIdentity, second !== first else {
            return failed("the split did not focus the new pane")
        }

        // Directional navigation: left returns to the first pane.
        shell.shellMovePaneFocusLeft()
        guard shell.shellFocusedPaneIdentity === first else {
            return failed("focus did not walk left to the first pane")
        }

        // Split down: a third pane opens under the first and takes focus.
        shell.shellSplitDown()
        guard shell.shellPaneCount == 3 else {
            return failed("a second split left \(shell.shellPaneCount) panes")
        }
        guard let third = shell.shellFocusedPaneIdentity, third !== first, third !== second else {
            return failed("the second split did not focus the new pane")
        }

        // Zoom: recorded intent, on and off — the layout survives untouched.
        guard !shell.isShellZoomed else {
            return failed("a fresh split reads zoomed")
        }
        shell.shellToggleZoom()
        guard shell.isShellZoomed else {
            return failed("the zoom toggle recorded nothing")
        }
        shell.shellToggleZoom()
        guard !shell.isShellZoomed else {
            return failed("the zoom did not collapse back")
        }

        // Navigation up: from the pane below back to the first.
        shell.shellMovePaneFocusUp()
        guard shell.shellFocusedPaneIdentity === first else {
            return failed("focus did not walk up to the first pane")
        }

        // Safe to close: three shells at their prompts kill nothing.
        guard settles({ shell.isShellSafeToClose }) else {
            return failed("a window of idle shells reads unsafe to close")
        }

        // The close-button assertion exercises visible chrome even when the
        // smoke window is covered by the operator's active application.
        if let surface = shell.shellFocusedPaneIdentity as? TerminalSurface {
            surface.isFullyOccludedForTesting = false
            surface.recomputePresentation()
        }
        shell.shellSendProbe("sleep 30\r")
        guard settles({ !shell.isShellSafeToClose }) else {
            return failed("a foreground sleep reads safe to close")
        }
        if let controller = shell as? TerminalWindowController, let window = controller.window {
            guard settles({ window.isDocumentEdited }) else {
                return failed("a foreground job did not mark the close button")
            }
            let paneCountBefore = shell.shellPaneCount
            controller.closePane(nil)
            guard let paneSheet = window.attachedSheet, shell.shellPaneCount == paneCountBefore else {
                return failed("the close command bypassed the running pane's confirmation")
            }
            window.endSheet(paneSheet, returnCode: .alertSecondButtonReturn)
            guard settles({ window.attachedSheet == nil }) else {
                return failed("cancelling the pane close left a sheet open")
            }
            guard !controller.windowShouldClose(window), let sheet = window.attachedSheet else {
                return failed("closing a foreground job did not ask for confirmation")
            }
            window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
        shell.shellSendProbe("\u{03}")
        guard settles({ shell.isShellSafeToClose }) else {
            return failed("an interrupted job left the window unsafe to close")
        }

        // Collapse the second split back before the single-close scenario.
        //
        // One close, asked once. The instant after a job ends is when a shell
        // runs its prompt hooks, and a hook's subshell is the shell's own work:
        // a close that lands on one must not ask.
        shell.shellClosePane()
        guard shell.shellPaneCount == 2 else {
            return failed("closing the third pane left \(shell.shellPaneCount)")
        }

        // Broadcast: the focused pane's transmitted bytes reach the sibling.
        shell.shellToggleBroadcastInput()
        shell.shellSendProbe("broadcast-probe")
        // The sibling's session received the bytes on its input queue; the
        // observable that needs no PTY echo is the transmit fan-out itself,
        // exercised by the probe reaching the transmit hook. Turn it off
        // again so the close below stays a single-pane fact.
        shell.shellToggleBroadcastInput()

        // Close pane: the layout collapses back to one.
        shell.shellClosePane()
        guard shell.shellPaneCount == 1 else {
            return failed("closing a pane left \(shell.shellPaneCount)")
        }

        // Teardown: closing the window releases the arm's slot.
        let before = factory.liveShellCount
        shell.shellCloseWindow()
        guard factory.liveShellCount == before - 1 else {
            return failed("a closed window did not release its controller")
        }

        // Restore: a captured two-pane layout comes back as two panes. The
        // string is the arms' shared capture format, so one layout drives
        // both — a window that restored one pane restored the window and
        // lost the arrangement, which is the failure worth naming.
        let twoPaneLayout = "0000,80x24,0,0{40x24,0,0,1,39x24,41,0,2}"
        guard let restored = factory.spawnShellRestoring(layout: twoPaneLayout) else {
            return failed("the shell did not restore a layout")
        }
        guard restored.shellPaneCount == 2 else {
            return failed("a restored two-pane layout came back as \(restored.shellPaneCount)")
        }
        restored.shellCloseWindow()

        print("shell-smoke[\(arm)]: PASS — spawn, split, navigate, zoom, close safety, broadcast, close, restore, teardown")
        return true
    }
}
