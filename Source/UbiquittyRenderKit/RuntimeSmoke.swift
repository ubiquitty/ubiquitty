// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// RuntimeSmoke.swift — one real session through the Swift drive, end to end.
//
// The pure-Swift runtime path has no snapshot arm: a still frame cannot show
// bytes flowing from a PTY through the ingest thread into the model. This is
// that oracle — a live child process, the extracted loop, the session's
// locks, and a row-text readback, pass or fail. Public like SwiftFrameDrive:
// the app's main is ObjC++, and it reaches this through the generated header
// as one call carrying only scalars.

import Foundation
import UbiquittyCore

/// The smoke's entry, which the application's entry point dispatches. One
/// call at process start; the dispatch cost is not a consideration on a smoke.
public final class SwiftRuntimeSmokeEntry: NSObject {
    /// Runs the smoke.
    ///
    /// - Returns: Whether the marker reached the model through the whole
    ///   path: PTY, poll loop, drain, lock, readback.
    public static func run() -> Bool {
        RuntimeSmoke.run()
    }
}

/// The smoke's scenario, kept as a type so its pieces stay named.
enum RuntimeSmoke {
    /// The marker the child prints and the grid must hold.
    private static let marker = "swift-runtime-smoke-ok"

    /// How long the smoke waits for the child before calling the run hung.
    private static let deadlineSeconds = 5.0

    /// Runs every scenario, in an order that fails fast on the data path.
    ///
    /// - Returns: Whether the data path and the command path both close
    ///   their loops.
    static func run() -> Bool {
        guard runMarkerReadback() else {
            return false
        }
        return runFocusRoundTrip()
    }

    /// Launches a child, drains it through the ingest thread, and checks the
    /// grid.
    ///
    /// - Returns: Whether the marker reached the model through the whole
    ///   path: PTY, poll loop, drain, lock, readback.
    private static func runMarkerReadback() -> Bool {
        guard let drive = RuntimeDrive(rows: 24, columns: 80) else {
            FileHandle.standardError.write(Data("smoke: no session\n".utf8))
            return false
        }
        defer { drive.close() }
        // The child also sets a title: the OSC is the one path that bumps the
        // snapshot's title generation, so the readback below can tell a real
        // publish from a default-valued snapshot on every field it checks.
        guard drive.launchShellCommand("printf '\\033]0;\(marker)\\007'; printf '%s\\n' '\(marker)'") else {
            FileHandle.standardError.write(Data("smoke: launch refused\n".utf8))
            return false
        }
        guard drive.startIngest() else {
            FileHandle.standardError.write(Data("smoke: ingest refused to start\n".utf8))
            return false
        }
        // The exit arrives as a coalesced event bit; the deadline is what
        // separates a hung child from a slow one. Polling is the smoke's own
        // simplicity, not the drive's contract — a live frontend wires the
        // events closure instead.
        var sawExit = false
        var sawEvents: RuntimeEvents = []
        let deadline = Date(timeIntervalSinceNow: deadlineSeconds)
        while Date() < deadline {
            let events = drive.takeEvents()
            sawEvents.formUnion(events)
            if events.contains(.exited) {
                sawExit = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        drive.stopIngest()
        // The readback brackets with the same lock the drain bites, which is
        // the discipline under test as much as the bytes are. It runs whether
        // or not the exit arrived: with the byte count it splits "the data
        // path is dead" from "only the exit event is missing", which are
        // different bugs in different places.
        let didFindMarker = drive.withRenderLock { () -> Bool in
            guard let terminal = drive.borrowTerminal() else {
                return false
            }
            for row in 0..<4 {
                let text = String(Ubiquitty.Screen.absoluteRowText(terminal, Int32(row), 80))
                if text.contains(marker) {
                    return true
                }
            }
            return false
        }
        // The lock-free read seam, against facts the drain proved: a snapshot
        // that never published reads rows 0, and only the title OSC bumps the
        // generation — so each check can fail on its own mechanism.
        let snapshot = drive.readSnapshot()
        let didPublishGeometry = snapshot.rows == 24 && snapshot.columns == 80
        let didBumpTitle = snapshot.titleGeneration > 0
        let drainedBytes = drive.takeDrainedBytes()
        if !sawExit || !didFindMarker || !didPublishGeometry || !didBumpTitle {
            let report =
                "smoke: exit=\(sawExit) marker=\(didFindMarker) "
                + "snapshotRows=\(snapshot.rows) titleGeneration=\(snapshot.titleGeneration) "
                + "drainedBytes=\(drainedBytes) events=\(sawEvents.rawValue)\n"
            FileHandle.standardError.write(Data(report.utf8))
        }
        return sawExit && didFindMarker && didPublishGeometry && didBumpTitle
    }

    /// Drives one focus report through the command ring and back off the PTY.
    ///
    /// The child turns focus reporting on through the transport — the mode
    /// arrives the way a real application sets it — and `cat -v` echoes what
    /// the host receives as visible text. A posted focus change must then
    /// cross the command ring, wake the parked loop, apply under the model
    /// lock, write its report to the host, and come back through the child's
    /// echo as grid text. The post repeats until the report lands because the
    /// mode's own bytes race the first posts: a focus command applied before
    /// the drain processes DECSET 1004 emits nothing, by the mode's rule.
    ///
    /// - Returns: Whether a focus report round-tripped onto the grid.
    private static func runFocusRoundTrip() -> Bool {
        guard let drive = RuntimeDrive(rows: 24, columns: 80) else {
            FileHandle.standardError.write(Data("smoke: focus: no session\n".utf8))
            return false
        }
        defer { drive.close() }
        guard drive.launchShellCommand("printf '\\033[?1004h'; exec cat -v") else {
            FileHandle.standardError.write(Data("smoke: focus: launch refused\n".utf8))
            return false
        }
        guard drive.startIngest() else {
            FileHandle.standardError.write(Data("smoke: focus: ingest refused to start\n".utf8))
            return false
        }
        // The echoed report as cat -v draws it: ESC becomes the visible ^[.
        let echoedReport = "^[[I"
        var didFindReport = false
        let deadline = Date(timeIntervalSinceNow: deadlineSeconds)
        while Date() < deadline {
            // The pair leaves an edge for every retry: a repeated identical
            // state would be edge-gated to silence once the first one lands.
            drive.setDesiredFocus(.Unfocused)
            drive.setDesiredFocus(.Focused)
            Thread.sleep(forTimeInterval: 0.02)
            didFindReport = drive.withRenderLock { () -> Bool in
                guard let terminal = drive.borrowTerminal() else {
                    return false
                }
                for row in 0..<4 {
                    let text = String(Ubiquitty.Screen.absoluteRowText(terminal, Int32(row), 80))
                    if text.contains(echoedReport) {
                        return true
                    }
                }
                return false
            }
            if didFindReport {
                break
            }
        }
        drive.stopIngest()
        if !didFindReport {
            FileHandle.standardError.write(Data("smoke: focus: no report echoed; drained=\(drive.takeDrainedBytes())\n".utf8))
        }
        return didFindReport
    }
}
