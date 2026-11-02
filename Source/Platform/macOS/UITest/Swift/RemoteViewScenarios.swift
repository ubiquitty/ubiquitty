// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// RemoteViewScenarios.swift — a remote pane in a tab nobody has in front costs
// its host nothing, against a ubiquitty-host this scenario forks with a home of
// its own.
//
// One claim: the view a window's tabs hold reaches the host (Docs/sync.md
// §6.8). Two remote sessions share a window as two tabs; the one in the back
// floods. While it is in the back its pane is Dormant, and the bytes the host
// sends it stay flat however much it writes; brought to the front it is Live
// again, and its screen arrives.

/// Registers the view-state scenarios with the UI-test runner.
enum RemoteViewScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("remote_hidden_tab_costs_its_host_nothing") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                run(t)
            }
        }
    }

    @MainActor
    private static func run(_ t: UBUITestContext) {
        guard let hostBinary = ProcessInfo.processInfo.environment["UBIQUITTY_UI_TEST_HOST"],
            FileManager.default.isExecutableFile(atPath: hostBinary)
        else {
            t.expect(false, desc: "UBIQUITTY_UI_TEST_HOST names a built ubiquitty-host (Scripts/run-ui-tests.sh sets it)")
            return
        }
        // Under /tmp: a Unix socket path is capped at 103 bytes, and the
        // daemon's socket lives in this home.
        let root = "/tmp/ubq-view-" + String(UUID().uuidString.prefix(8))
        let home = root + "/.ubiquitty"
        do {
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            t.expect(false, desc: "an isolated UBIQUITTY_HOME was made (\(error))")
            return
        }
        let quotedHost = "'" + hostBinary.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let quotedHome = "'" + home.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let attachCommand = "UBIQUITTY_HOME=\(quotedHome) \(quotedHost) --attach"
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        defer {
            if let previousHome {
                setenv("UBIQUITTY_HOME", previousHome, 1)
            } else {
                unsetenv("UBIQUITTY_HOME")
            }
            try? FileManager.default.removeItem(atPath: root)
        }

        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: hostBinary)
        daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
        daemon.environment = ProcessInfo.processInfo.environment.merging(["UBIQUITTY_HOME": home]) { $1 }
        do {
            try daemon.run()
        } catch {
            t.expect(false, desc: "the daemon started (\(error))")
            return
        }
        defer {
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }
        let hasSocket = t.wait(
            until: {
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
                return entries.contains { $0.hasPrefix("host-") && $0.hasSuffix(".sock") }
            },
            timeout: 20
        )
        t.expect(hasSocket, desc: "the daemon opened its socket")
        guard hasSocket else { return }

        // Two sessions, each its own window, made into one window's two tabs.
        let open = { (label: String) -> TerminalWindowController? in
            TerminalWindowController.spawnRemoteWindow(
                shellCommand: attachCommand,
                hostLabel: label,
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: 0
            )
        }
        guard let flooding = open("flooding tab"), let floodingSurface = flooding.remoteSurface,
            let front = open("front tab"), let frontSurface = front.remoteSurface,
            let floodingWindow = flooding.window, let frontWindow = front.window
        else {
            t.expect(false, desc: "two remote windows opened")
            return
        }
        defer { t.closeAllWindows() }
        let isConnected = { (surface: TerminalSurface) in
            surface.drive.remoteState == Ubiquitty.Session.State.Connected && surface.remoteSessionID != 0
        }
        t.expect(
            t.wait(until: { isConnected(floodingSurface) && isConnected(frontSurface) }, timeout: 40),
            desc: "both sessions attached"
        )
        t.expect(
            t.wait(until: { floodingSurface.drive.remotePaneBytesReceived > 0 }, timeout: 20),
            desc: "the shown tab was sent its screen"
        )

        floodingWindow.addTabbedWindow(frontWindow, ordered: .above)
        guard let group = floodingWindow.tabGroup, t.wait(until: { group.windows.count == 2 }, timeout: 20) else {
            t.expect(false, desc: "the two windows became one window's tabs")
            return
        }
        // The harness's windows never take key, so the front tab is set the
        // way a click on it would set it, with the main edges a switch fires.
        // Nothing is ordered front or activated: the windows stay off the
        // maintainer's screen.
        let bringToFront = { (window: NSWindow, other: NSWindow) in
            group.selectedWindow = window
            NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: other)
            NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        }
        bringToFront(frontWindow, floodingWindow)
        t.expect(
            t.wait(until: { !floodingSurface.isRemotePaneShown && frontSurface.isRemotePaneShown }, timeout: 10),
            desc: "the tab in the back is Dormant and the one in front Live"
        )

        // The tab in the back floods. Its bytes stay flat: one `PaneDirty` when it
        // changed, and the records a program's start sends, never its screen.
        floodingSurface.send("yes ubiquitty-dormant-flood\r")
        t.pump(1.0)
        let before = floodingSurface.drive.remotePaneBytesReceived
        t.pump(3.0)
        let during = floodingSurface.drive.remotePaneBytesReceived
        t.expect(
            during - before < 4096,
            desc: "a flooding tab in the back was sent \(during - before) bytes in 3 s, not its screen"
        )

        // Brought to the front, it is Live again and its screen arrives.
        bringToFront(floodingWindow, frontWindow)
        t.expect(t.wait(until: { floodingSurface.isRemotePaneShown }, timeout: 10), desc: "the tab brought to the front is Live")
        t.expect(
            t.wait(until: { floodingSurface.gridTextForTesting().contains("ubiquitty-dormant-flood") }, timeout: 20),
            desc: "the tab brought to the front shows its flood"
        )
        // Waking sends one diff of the rows that changed while it was
        // Dormant, never a checkpoint (Docs/sync.md §6.8), and the history
        // it missed travels as transfers on the connection's channel, which
        // these pane bytes do not count. So the tab is sent its screen's rows
        // and no more: something, and under a screen's worth of whole rows
        // twice over.
        let afterWake = floodingSurface.drive.remotePaneBytesReceived
        t.expect(
            afterWake > during && afterWake - during < 2 * 24 * 80 * 4,
            desc: "the tab brought to the front was sent its screen's rows (\(afterWake - during) bytes after it woke)"
        )
        floodingSurface.send("\u{3}")
    }
}
