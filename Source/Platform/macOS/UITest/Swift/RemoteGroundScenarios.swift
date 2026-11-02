// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// RemoteGroundScenarios.swift — a window on a host session shows the session's
// theme from the moment it is ordered in, before the host has sent a frame.
//
// A hosted pane has nothing of its own to draw until its first checkpoint
// arrives, and whatever lies under the Metal layer is what a person sees in
// that gap: the pane host's ground, and under it the window's backing. The
// first is clear and the second is the system window colour unless the chrome
// pass found a theme to paint them with, which it reads off the window's
// active surface. So what is asserted is the colour of that stack where a
// person looks — the middle of the pane — at the moment the window is ordered
// in and again while the host stays silent, against the theme the window's
// session uses rather than any fixed colour.

/// Registers the hosted-ground scenarios with the UI-test runner.
enum RemoteGroundScenarios {
    /// Registers every scenario in this file.
    static func register() {
        // The Connect window's door, against a transport that never answers:
        // the first checkpoint is delayed for as long as the scenario looks.
        UBUITestRegister("remote_window_paints_the_theme_ground_before_the_first_checkpoint") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                for theme in ["Dracula", "Gruvbox Light"] {
                    verifySilentHostWindow(t, theme: theme)
                }
            }
        }
        // A tab added on a live host: the tab's own session has sent nothing
        // when its window is ordered in, and the session theme the opening tab
        // uses is the one it must already show.
        UBUITestRegister("remote_new_tab_paints_the_session_theme_before_its_first_checkpoint") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withLightHostSession(t) { opener, ground in verifyNewHostTab(t, opener: opener, ground: ground) }
            }
        }
        // A split on a live host: the pane joins the window before its
        // session has sent anything, beside the pane it divides.
        UBUITestRegister("remote_split_paints_the_session_theme_before_its_first_checkpoint") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withLightHostSession(t) { opener, ground in verifyHostSplit(t, opener: opener, ground: ground) }
            }
        }
    }

    @MainActor
    private static func verifySilentHostWindow(_ t: UBUITestContext, theme: String) {
        let saved = t.configureAppending(
            "[appearance]\nfollow_system = false\ntheme = \"\(theme)\"\nbackground_opacity = 1.0\ntitlebar_style = \"themed\"\n"
        )
        defer { t.restoreConfiguration(saved) }
        guard let expected = themeGround(named: theme) else {
            t.expect(false, desc: "\(theme) is a theme Core knows")
            return
        }
        var orderedIn: GroundSample?
        var orderedInPens: PenSample?
        TerminalWindowController.remoteWindowOrderedInForTesting = { controller in
            orderedIn = visibleGround(of: controller)
            orderedInPens = controller.remoteSurface.flatMap(pens(of:))
        }
        defer { TerminalWindowController.remoteWindowOrderedInForTesting = nil }
        guard
            let controller = TerminalWindowController.spawnRemoteWindow(
                shellCommand: "exec /bin/sleep 30",
                hostLabel: "silent host",
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: 0
            ), let surface = controller.remoteSurface
        else {
            t.expect(false, desc: "a window opens on a host that has not answered")
            return
        }
        defer {
            surface.drive.close()
            controller.shellCloseWindow()
        }
        controller.window?.makeKeyAndOrderFront(nil)
        expect(t, orderedIn, isGround: expected, when: "\(theme): as the window is ordered in")
        t.pump(0.4)
        t.expect(surface.drive.remoteState != .Connected, desc: "\(theme): the silent host has still sent nothing")
        expect(t, visibleGround(of: controller), isGround: expected, when: "\(theme): while the host stays silent")
        expect(t, orderedInPens, match: expected, when: "\(theme): as the window is ordered in")
    }

    /// Runs `body` against a window on an isolated daemon whose session was
    /// switched to a light theme under a dark configuration: a pane dressed in
    /// the configuration rather than in the session it opens from shows the
    /// wrong one of the two.
    @MainActor
    private static func withLightHostSession(
        _ t: UBUITestContext,
        _ body: (TerminalWindowController, ThemeGround) -> Void
    ) {
        guard let hostBinary = ProcessInfo.processInfo.environment["UBIQUITTY_UI_TEST_HOST"],
            FileManager.default.isExecutableFile(atPath: hostBinary)
        else {
            t.expect(false, desc: "UBIQUITTY_UI_TEST_HOST names a built ubiquitty-host (Scripts/run-ui-tests.sh sets it)")
            return
        }
        // A home of its own, under /tmp for the socket path's length cap.
        let root = "/tmp/ubq-ground-" + String(UUID().uuidString.prefix(8))
        let home = root + "/.ubiquitty"
        do {
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            t.expect(false, desc: "an isolated UBIQUITTY_HOME was made (\(error))")
            return
        }
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        defer {
            if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
            try? FileManager.default.removeItem(atPath: root)
        }
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: hostBinary)
        daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24", "--quic-port", "-1"]
        daemon.environment = ProcessInfo.processInfo.environment.merging(["UBIQUITTY_HOME": home]) { $1 }
        do { try daemon.run() } catch {
            t.expect(false, desc: "the daemon started (\(error))")
            return
        }
        defer {
            t.closeAllWindows()
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }
        guard
            t.wait(
                until: {
                    let entries = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
                    return entries.contains { $0.hasPrefix("host-") && $0.hasSuffix(".sock") }
                },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the daemon opened its socket")
            return
        }

        let saved = t.configureAppending(
            "[appearance]\nfollow_system = false\ntheme = \"Dracula\"\nbackground_opacity = 1.0\ntitlebar_style = \"themed\"\n"
        )
        defer { t.restoreConfiguration(saved) }
        let quotedHost = "'" + hostBinary.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let quotedHome = "'" + home.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        guard
            let opener = TerminalWindowController.spawnRemoteWindow(
                shellCommand: "UBIQUITTY_HOME=\(quotedHome) \(quotedHost) --attach",
                hostLabel: "ground host",
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: 0,
                workspaceName: "ground",
                hostKey: ""
            ), let openerSurface = opener.remoteSurface
        else {
            t.expect(false, desc: "a window opens on the host")
            return
        }
        guard
            t.wait(
                until: { opener.remotePaneSurfaces.count == 1 && openerSurface.drive.remoteState == .Connected },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the opening tab attached and the host projected its pane")
            return
        }
        let light = "Gruvbox Light"
        guard let lightGround = themeGround(named: light),
            let lightIndex = TerminalSurface.themeNames.firstIndex(of: light)
        else {
            t.expect(false, desc: "\(light) is a theme Core knows")
            return
        }
        t.expect(openerSurface.applyTheme(at: lightIndex), desc: "the opening tab's session takes \(light)")
        t.expect(
            t.wait(until: { snapshotGround(of: openerSurface).isClose(to: lightGround) }, timeout: 10),
            desc: "the host's checkpoint brings \(light) back to the opening tab"
        )

        body(opener, lightGround)
    }

    @MainActor
    private static func verifyNewHostTab(_ t: UBUITestContext, opener: TerminalWindowController, ground: ThemeGround) {
        guard let openerSurface = opener.remoteSurface else { return }
        var orderedIn: GroundSample?
        var orderedInPens: PenSample?
        var tab: TerminalWindowController?
        TerminalWindowController.remoteWindowOrderedInForTesting = { controller in
            guard controller !== opener else { return }
            orderedIn = visibleGround(of: controller)
            orderedInPens = controller.remoteSurface.flatMap(pens(of:))
            tab = controller
        }
        defer { TerminalWindowController.remoteWindowOrderedInForTesting = nil }
        t.expect(openerSurface.drive.remoteWorkspaceAddTab(), desc: "the host accepts another tab")
        guard t.wait(until: { orderedIn != nil }, timeout: 20), let tab, let tabSurface = tab.remoteSurface else {
            t.expect(false, desc: "the host's new tab opened a window")
            return
        }
        expect(t, orderedIn, isGround: ground, when: "the new tab as its window is ordered in")
        expect(t, orderedInPens, match: ground, when: "the new tab as its window is ordered in")
        // The host's own frames take over without moving the colour.
        t.expect(
            t.wait(until: { hasHostScreen(tabSurface) }, timeout: 20),
            desc: "the new tab's session drew its screen"
        )
        t.pump(0.5)
        expect(t, snapshotGround(of: tabSurface), isGround: ground, when: "the new tab after its first checkpoint")
        expect(t, pens(of: tabSurface), match: ground, when: "the new tab after its first checkpoint")
    }

    @MainActor
    private static func verifyHostSplit(_ t: UBUITestContext, opener: TerminalWindowController, ground: ThemeGround) {
        var joinedGround: GroundSample?
        var joinedPens: PenSample?
        var joined: TerminalSurface?
        TerminalWindowController.remotePaneJoinedForTesting = { controller, pane in
            guard controller === opener else { return }
            joinedGround = visibleGround(of: controller, at: pane)
            joinedPens = pens(of: pane)
            joined = pane
        }
        defer { TerminalWindowController.remotePaneJoinedForTesting = nil }
        opener.splitRight(nil)
        guard t.wait(until: { joined != nil }, timeout: 20), let joined else {
            t.expect(false, desc: "the host's split joined the window")
            return
        }
        expect(t, joinedGround, isGround: ground, when: "the split pane as it joins the window")
        expect(t, joinedPens, match: ground, when: "the split pane as it joins the window")
        t.expect(
            t.wait(until: { hasHostScreen(joined) }, timeout: 20),
            desc: "the split pane's session drew its screen"
        )
        t.pump(0.5)
        expect(t, snapshotGround(of: joined), isGround: ground, when: "the split pane after its first checkpoint")
        expect(t, pens(of: joined), match: ground, when: "the split pane after its first checkpoint")
    }
}

/// Whether the host's screen has reached the pane: its shell's prompt, which
/// only a checkpoint or an update after it can have put there.
@MainActor
private func hasHostScreen(_ surface: TerminalSurface) -> Bool {
    !surface.gridTextForTesting().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// A colour as a person sees it, and the layer it was read from.
private struct GroundSample {
    var red: Double
    var green: Double
    var blue: Double
    var source: String

    var description: String {
        String(format: "%@ (%.3f, %.3f, %.3f)", source, red, green, blue)
    }
}

/// A theme's ground, and the pens a pane of it starts with.
private struct ThemeGround {
    var red: Double
    var green: Double
    var blue: Double
    var foreground: Ubiquitty.ColorRGBA
    var cursor: Ubiquitty.ColorRGBA
    var isDark: Bool
}

extension GroundSample {
    fileprivate func isClose(to ground: ThemeGround) -> Bool {
        abs(red - ground.red) + abs(green - ground.green) + abs(blue - ground.blue) < 0.03
    }
}

/// The theme's own colours, by Core's catalogue.
private func themeGround(named name: String) -> ThemeGround? {
    let index = name.withCString { Ubiquitty.Themes.indexForName($0) }
    guard let theme = Ubiquitty.Themes.get(index)?.pointee else { return nil }
    let background = theme.defaultBackground
    return ThemeGround(
        red: Double(background.red) / 255,
        green: Double(background.green) / 255,
        blue: Double(background.blue) / 255,
        foreground: theme.defaultForeground,
        cursor: theme.cursor,
        isDark: Ubiquitty.Themes.isDark(index)
    )
}

/// The ground the surface's published snapshot holds.
@MainActor
private func snapshotGround(of surface: TerminalSurface) -> GroundSample {
    let snapshot = surface.drive.readSnapshot()
    return GroundSample(
        red: Double(snapshot.defaultBackgroundRed),
        green: Double(snapshot.defaultBackgroundGreen),
        blue: Double(snapshot.defaultBackgroundBlue),
        source: "snapshot"
    )
}

/// What a person sees at the middle of the window's pane: the frame the
/// Metal layer presented when it has presented one, and otherwise the first
/// opaque ground under it — the surface's layer, the pane host's, the
/// window's backing.
///
/// A ground is read in the colour space the pane's Metal layer is tagged
/// with, the space a frame's triple is presented in (Docs/wide-gamut.md): a
/// theme's triple names one colour under sRGB and another under Display P3,
/// so a ground painted from it matches the frame beside it only when both
/// are read in that one space. A ground built in another space resolves to
/// a different triple there, by more than the tolerance for a light theme.
@MainActor
private func visibleGround(of controller: TerminalWindowController, at pane: TerminalSurface? = nil) -> GroundSample? {
    guard let window = controller.window else { return nil }
    let pane = pane ?? controller.remoteSurface
    guard let tag = pane?.metalLayer.colorspace, let space = NSColorSpace(cgColorSpace: tag) else { return nil }
    if let surface = pane,
        surface.adaptiveDriveFacts().framesDrawn > 0,
        let drawn = surface.drawnBackgroundForTesting(), drawn.alpha > 0.99
    {
        return GroundSample(
            red: Double(drawn.color.x),
            green: Double(drawn.color.y),
            blue: Double(drawn.color.z),
            source: "presented frame"
        )
    }
    let layers: [(String, CGColor?)] = [
        ("surface layer", pane?.layer?.backgroundColor),
        ("pane host", controller.paneHost.layer?.backgroundColor),
    ]
    for (source, color) in layers {
        guard let color, color.alpha > 0.99,
            let resolved = NSColor(cgColor: color)?.usingColorSpace(space)
        else { continue }
        return GroundSample(
            red: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent,
            source: source
        )
    }
    // A dynamic system colour resolves against the window's appearance.
    var backing: NSColor?
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
        backing = window.backgroundColor.usingColorSpace(space)
    }
    guard let backing else { return nil }
    return GroundSample(
        red: backing.redComponent,
        green: backing.greenComponent,
        blue: backing.blueComponent,
        source: "window backing"
    )
}

@MainActor
private func expect(_ t: UBUITestContext, _ sample: GroundSample?, isGround ground: ThemeGround, when: String) {
    guard let sample else {
        t.expect(false, desc: "\(when): the pane's ground was sampled")
        return
    }
    t.expect(sample.isClose(to: ground), desc: "\(when): the pane shows the theme's ground, not \(sample.description)")
    let lightness = 0.2126 * sample.red + 0.7152 * sample.green + 0.0722 * sample.blue
    t.expect(
        (lightness < 0.5) == ground.isDark,
        desc: "\(when): the ground is \(ground.isDark ? "dark" : "light") as the theme is (\(sample.description))"
    )
}

/// The default pen and the cursor a pane's model holds, as bytes.
private struct PenSample {
    var foreground: [UInt8]
    var cursor: [UInt8]
}

/// Reads the pens off the pane's model.
@MainActor
private func pens(of surface: TerminalSurface) -> PenSample? {
    guard let terminal = surface.drive.borrowTerminal() else { return nil }
    let palette = terminal.palette
    let byte = { (channel: UInt16) in UInt8(channel >> 8) }
    return PenSample(
        foreground: [byte(palette.defaultForeground.red), byte(palette.defaultForeground.green), byte(palette.defaultForeground.blue)],
        cursor: [byte(palette.cursor.red), byte(palette.cursor.green), byte(palette.cursor.blue)]
    )
}

/// The pens the pane starts with are the theme's, so a prompt drawn before
/// the host's first frame is in the session's colours.
@MainActor
private func expect(_ t: UBUITestContext, _ sample: PenSample?, match ground: ThemeGround, when: String) {
    guard let sample else {
        t.expect(false, desc: "\(when): the pane's pens were read")
        return
    }
    let foreground = [ground.foreground.red, ground.foreground.green, ground.foreground.blue]
    let cursor = [ground.cursor.red, ground.cursor.green, ground.cursor.blue]
    t.expect(sample.foreground == foreground, desc: "\(when): the default pen is the theme's, not \(sample.foreground)")
    t.expect(sample.cursor == cursor, desc: "\(when): the cursor is the theme's, not \(sample.cursor)")
}
