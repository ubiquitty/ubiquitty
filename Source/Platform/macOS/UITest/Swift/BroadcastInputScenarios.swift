// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit
import UbiquittyRenderKit

// BroadcastInputScenarios.swift — the mode that fans every keystroke out to
// every pane is remembered, and says so in the title row.
//
// Both halves are the same defect if either is missing. A mode that resets on
// the next window is one a reader turns on again and again; a mode that
// persists with nothing on screen saying so is one they discover by typing a
// command into four hosts they meant to type into one.
//
// So the pill is read off the WINDOW'S OWN title row rather than off either
// controller's flag: the flag is what the pill is derived from, and a pill
// that never reached the bar leaves the flag perfectly correct and the window
// silent. Reading the view tree also lets one instrument ask both arms, which
// is the claim that matters, because the preference and the pill are one
// component each and neither shell has a copy.

/// Registers the broadcast-input scenarios with the UI-test runner.
enum BroadcastInputScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_broadcast_mode_is_remembered_and_marked") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The preference is the real one, so it is put back whatever
                // this scenario decides: a battery that left it on would open
                // every later window broadcasting.
                let restore = BroadcastInputMemory.isBroadcasting()
                defer { BroadcastInputMemory.set(restore) }
                BroadcastInputMemory.set(false)

                guard let first = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                first.window?.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                t.expect(
                    !isWearingBroadcastPill(first.window),
                    desc: "a window opened out of the mode wears no pill"
                )

                first.toggleBroadcastInput(nil)
                t.pump(0.2)
                t.expect(
                    isWearingBroadcastPill(first.window),
                    desc: "turning the mode on marks the title row"
                )
                t.expect(
                    BroadcastInputMemory.isBroadcasting(),
                    desc: "and the answer is remembered for the next window"
                )
                first.window?.close()
                t.pump(0.3)

                guard let second = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a second Swift-shell window opens")
                    return
                }
                defer { second.window?.close() }
                second.window?.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                t.expect(
                    isWearingBroadcastPill(second.window),
                    desc: "a window opened afterwards comes back in the mode, pill and all"
                )

                second.toggleBroadcastInput(nil)
                t.pump(0.2)
                t.expect(
                    !isWearingBroadcastPill(second.window),
                    desc: "turning it off withdraws the pill rather than leaving a stale warning"
                )
                t.expect(
                    !BroadcastInputMemory.isBroadcasting(),
                    desc: "and the off answer is remembered too"
                )
            }
        }

        // Broadcast reaches the panes that can take input, and only those:
        // Core's answer about a session's host, read by the fan-out and by
        // the confirmation's count alike. A pane over a session with no host
        // -- the shape a passive mirror has -- is neither a target nor
        // counted, because the keystrokes sent to it go nowhere.
        UBUITestRegister("swift_shell_broadcast_reaches_only_panes_that_take_input") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restore = BroadcastInputMemory.isBroadcasting()
                defer { BroadcastInputMemory.set(restore) }
                // Born broadcasting, so no confirmation stands between the
                // scenario and the fan-out.
                BroadcastInputMemory.set(true)
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "LC_ALL=C exec cat -v"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window
                else {
                    t.expect(false, desc: "a Swift-shell window opens on cat -v")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.6)
                shell.splitRight(nil)
                t.pump(0.8)

                let panes = shell.paneSurfacesForTesting
                guard panes.count == 2, let source = shell.focusedSurfaceForTesting,
                    let sibling = panes.first(where: { $0 !== source })
                else {
                    t.expect(false, desc: "the split leaves two panes, one focused (\(panes.count))")
                    return
                }
                guard let passive = TerminalSurface(rows: 24, columns: 80) else {
                    t.expect(false, desc: "a surface over a session with no host can be made")
                    return
                }
                t.expect(
                    source.drive.hasHostInputSink && sibling.drive.hasHostInputSink,
                    desc: "both launched panes have a host to take input"
                )
                t.expect(!passive.drive.hasHostInputSink, desc: "a session nothing launched has none")

                let all = panes + [passive]
                t.expect(
                    TerminalWindowController.broadcastEligibleSurfaces(among: all).count == 2,
                    desc: "the confirmation counts the two panes with a host, not all three"
                )
                let targets = TerminalWindowController.broadcastTargets(from: source, among: all)
                t.expect(
                    targets.count == 1 && targets.first === sibling,
                    desc: "the fan-out reaches the sibling and not the pane with no host (\(targets.count) targets)"
                )

                // The live fan-out still reaches the sibling that can take it.
                source.transmitAsUserInputForTesting("fanout-probe")
                var siblingText = sibling.gridTextForTesting()
                for _ in 0..<40 where !siblingText.contains("fanout-probe") {
                    t.pump(0.1)
                    siblingText = sibling.gridTextForTesting()
                }
                t.expect(
                    siblingText.contains("fanout-probe"),
                    desc: "typing into the focused pane reaches its sibling (sibling grid \(siblingText.debugDescription))"
                )
            }
        }
    }

    /// Whether a window's title row is wearing a broadcast pill.
    ///
    /// Walked off the window rather than asked of a controller, so the same
    /// question reaches both arms and so a mode that never reached the title
    /// row cannot answer yes.
    ///
    /// - Parameter window: The window to look at.
    /// - Returns: Whether a visible pill is in its title row.
    @MainActor
    private static func isWearingBroadcastPill(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        for accessory in window.titlebarAccessoryViewControllers where visiblePill(in: accessory.view) {
            return true
        }
        return false
    }

    /// Whether a visible pill stands anywhere under a view.
    ///
    /// - Parameter view: The root to walk.
    /// - Returns: Whether the pill is there and shown.
    @MainActor
    private static func visiblePill(in view: NSView) -> Bool {
        if view.isHidden {
            return false
        }
        if view is BroadcastIndicator {
            return true
        }
        return view.subviews.contains { visiblePill(in: $0) }
    }
}
