// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// QuietChromeScenarios.swift — what a screen update that moved nothing costs,
// and what each real change moves.
//
// A pane writing one line a second delivers a screen update a second, and every
// piece of chrome downstream of that update would re-derive itself: the pane
// ground repainted, the title row re-tinted, the tab's label written back into
// a strip found by walking the window's view tree. None of it changed a pixel.
//
// The counters these read are placed where the work is, not behind the memo
// that is meant to skip it — a counter behind the memo passes for an
// implementation that does the work and then compares.

/// The first terminal surface in a view hierarchy.
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

/// Every pane bar in a window, with the pane it frames.
///
/// - Parameter root: The window's pane host.
/// - Returns: One entry per bar, in tree order.
@MainActor
private func paneBars(under root: NSView) -> [(chrome: PaneChrome, surface: TerminalSurface)] {
    var found: [(chrome: PaneChrome, surface: TerminalSurface)] = []
    if let chrome = root as? PaneChrome, let surface = terminalSurface(under: chrome) {
        found.append((chrome, surface))
    }
    for subview in root.subviews {
        found.append(contentsOf: paneBars(under: subview))
    }
    return found
}

/// A named subview of a pane bar.
@MainActor
private func barView(_ identifier: String, under root: NSView) -> NSView? {
    for subview in root.subviews {
        if subview.accessibilityIdentifier() == identifier {
            return subview
        }
        if let found = barView(identifier, under: subview) {
            return found
        }
    }
    return nil
}

/// A pane bar's title text.
@MainActor
private func barTitle(_ chrome: PaneChrome) -> String {
    (barView("pane.title", under: chrome) as? NSTextField)?.stringValue ?? ""
}

/// A pane bar's fill, in sRGB.
@MainActor
private func barFill(_ chrome: PaneChrome) -> NSColor? {
    guard let color = barView("pane.titleBar", under: chrome)?.layer?.backgroundColor else { return nil }
    return NSColor(cgColor: color)?.usingColorSpace(.sRGB)
}

/// Whether a pane bar is styled as the selected pane's.
@MainActor
private func isBarSelected(_ chrome: PaneChrome) -> Bool {
    guard let close = barView("pane.close", under: chrome) as? NSButton, let tint = close.contentTintColor else {
        return false
    }
    return tint.alphaComponent > 0.9
}

/// Stops every pane's ingest, so only the scenario's own writes move anything.
@MainActor
private func stopIngest(of shell: TerminalWindowController) {
    for surface in shell.paneSurfacesForTesting {
        surface.drive.stopIngest()
    }
}

/// Every counter a quiet screen update must leave alone.
private struct ChromeCost: Equatable {
    var overscrollWrites = 0
    var paneGroundPaints = 0
    var chromeRepaints = 0
    var windowTitleWeaves = 0
    var tabTitleBakes = 0
    var paneChromeRestyles = 0
    var inspectorRefreshes = 0
    var stripWriteBacks = 0
    var containerSearches = 0
    var stripHostSearches = 0

    /// The difference between two readings, field by field.
    static func - (lhs: ChromeCost, rhs: ChromeCost) -> ChromeCost {
        ChromeCost(
            overscrollWrites: lhs.overscrollWrites - rhs.overscrollWrites,
            paneGroundPaints: lhs.paneGroundPaints - rhs.paneGroundPaints,
            chromeRepaints: lhs.chromeRepaints - rhs.chromeRepaints,
            windowTitleWeaves: lhs.windowTitleWeaves - rhs.windowTitleWeaves,
            tabTitleBakes: lhs.tabTitleBakes - rhs.tabTitleBakes,
            paneChromeRestyles: lhs.paneChromeRestyles - rhs.paneChromeRestyles,
            inspectorRefreshes: lhs.inspectorRefreshes - rhs.inspectorRefreshes,
            stripWriteBacks: lhs.stripWriteBacks - rhs.stripWriteBacks,
            containerSearches: lhs.containerSearches - rhs.containerSearches,
            stripHostSearches: lhs.stripHostSearches - rhs.stripHostSearches
        )
    }

    var description: String {
        "overscroll=\(overscrollWrites) paneGround=\(paneGroundPaints) chrome=\(chromeRepaints) "
            + "windowTitle=\(windowTitleWeaves) tabBake=\(tabTitleBakes) paneBar=\(paneChromeRestyles) "
            + "inspector=\(inspectorRefreshes) stripWriteBack=\(stripWriteBacks) "
            + "containerSearch=\(containerSearches) stripHostSearch=\(stripHostSearches)"
    }
}

/// What every window of a group has spent on chrome so far.
@MainActor
private func chromeCost(of shell: TerminalWindowController) -> ChromeCost {
    var cost = ChromeCost()
    let controllers =
        (shell.window?.tabGroup?.windows ?? [shell.window].compactMap { $0 })
        .compactMap { $0.windowController as? TerminalWindowController }
    for controller in controllers.isEmpty ? [shell] : controllers {
        cost.paneGroundPaints += controller.paneGroundPaintsForTesting
        cost.chromeRepaints += controller.chromeRepaintsForTesting
        cost.windowTitleWeaves += controller.windowTitleWeavesForTesting
        cost.tabTitleBakes += controller.tabTitleBakesForTesting
        cost.paneChromeRestyles += controller.paneChromeRestylesForTesting
        cost.inspectorRefreshes += controller.inspectorRefreshesForTesting
        for surface in controller.paneSurfacesForTesting {
            cost.overscrollWrites += surface.overscrollLayerWritesForTesting
        }
    }
    cost.stripWriteBacks = TabStripStyling.stripWriteBacksForTesting
    cost.containerSearches = TabStripStyling.titlebarContainerSearchesForTesting
    cost.stripHostSearches = TabStripStyling.stripHostSearchesForTesting
    return cost
}

/// Delivers screen updates that moved nothing, as a pane writing a line does.
@MainActor
private func deliverQuietUpdates(_ count: Int, to shell: TerminalWindowController, pumpingWith t: UBUITestContext) {
    for _ in 0..<count {
        for surface in shell.paneSurfacesForTesting {
            surface.deliver([.screenDirty])
        }
        t.pump(0.01)
    }
    t.pump(0.3)
}

/// The window shapes a quiet screen update is measured in.
private enum QuietWindowShape: CaseIterable {
    case themedLoneWindow
    case nativeLoneWindow
    case split
    case tabbedPair
    case inspectorShown

    var name: String {
        switch self {
        case .themedLoneWindow: "a themed lone window"
        case .nativeLoneWindow: "a native lone window"
        case .split: "a split"
        case .tabbedPair: "a tabbed pair"
        case .inspectorShown: "the Inspector shown"
        }
    }
}

/// Registers the quiet-chrome scenarios with the UI-test runner.
enum QuietChromeScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_quiet_screen_updates_touch_no_chrome_or_titles") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let wasNative =
                    Ubiquitty.Preferences.Effective.titlebarStyle(Ubiquitty.Preferences.values().pointee)
                    == Ubiquitty.Preferences.TitlebarStyle.Native
                defer { app.settingsSetTitlebarStyle(wasNative ? 1 : 0) }

                for variant in QuietWindowShape.allCases {
                    app.settingsSetTitlebarStyle(variant == .nativeLoneWindow ? 1 : 0)
                    guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                        t.expect(false, desc: "\(variant.name): a Swift-shell window opens")
                        continue
                    }
                    window.makeKeyAndOrderFront(nil)
                    t.pump(0.4)
                    switch variant {
                    case .themedLoneWindow, .nativeLoneWindow:
                        break
                    case .split:
                        shell.splitRight(nil)
                    case .tabbedPair:
                        shell.newWindowForTab(nil)
                        _ = t.wait(until: { (window.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20)
                    case .inspectorShown:
                        shell.toggleNativeInspector(nil)
                    }
                    // Past the turns the focus write-back re-asserts itself
                    // over, and past the late titlebar container.
                    t.pump(1.2)
                    for tab in window.tabGroup?.windows ?? [window] {
                        (tab.windowController as? TerminalWindowController).map(stopIngest(of:))
                    }
                    t.pump(0.4)
                    let before = chromeCost(of: shell)
                    deliverQuietUpdates(40, to: shell, pumpingWith: t)
                    let spent = chromeCost(of: shell) - before
                    FileHandle.standardError.write(Data("[quiet] \(variant.name): \(spent.description)\n".utf8))
                    t.expect(
                        spent == ChromeCost(),
                        desc: "\(variant.name): forty screen updates that moved nothing cost nothing (\(spent.description))"
                    )
                    window.tabGroup?.windows.forEach { $0.close() }
                    window.close()
                    t.pump(0.3)
                }
            }
        }

        UBUITestRegister("swift_shell_one_real_change_moves_only_its_own_counters") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let wasNative =
                    Ubiquitty.Preferences.Effective.titlebarStyle(Ubiquitty.Preferences.values().pointee)
                    == Ubiquitty.Preferences.TitlebarStyle.Native
                defer { app.settingsSetTitlebarStyle(wasNative ? 1 : 0) }
                app.settingsSetTitlebarStyle(0)
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.tabGroup?.windows.forEach { $0.close() } }
                window.makeKeyAndOrderFront(nil)
                t.pump(1.2)
                stopIngest(of: shell)
                t.pump(0.4)

                // (1) A theme change the program made: the chrome follows it,
                // and the container it was painted into is not searched for
                // again.
                var before = chromeCost(of: shell)
                surface.feed(Data("\u{1b}]11;#204060\u{07}".utf8))
                t.pump(0.4)
                var spent = chromeCost(of: shell) - before
                t.expect(spent.chromeRepaints == 1, desc: "an OSC 11 repaints the chrome once (\(spent.chromeRepaints))")
                t.expect(spent.tabTitleBakes >= 1, desc: "and re-bakes the tab's ink (\(spent.tabTitleBakes))")
                t.expect(spent.containerSearches == 0, desc: "and searches for no container (\(spent.containerSearches))")

                // (2) A letterbox fill the same colour as the ground: the
                // colour stands still and the chrome must still follow, since
                // a letterbox paints opaque whatever the window's opacity says.
                let snapshot = surface.drive.readSnapshot()
                let byte = { (channel: Float) in Int((channel * 255).rounded()) }
                let fill = String(
                    format: "%02x%02x%02x",
                    byte(snapshot.defaultBackgroundRed),
                    byte(snapshot.defaultBackgroundGreen),
                    byte(snapshot.defaultBackgroundBlue)
                )
                before = chromeCost(of: shell)
                surface.feed(Data("\u{1b}]7402;fill=\(fill)\u{07}\u{1b}[?7402h".utf8))
                t.pump(0.4)
                spent = chromeCost(of: shell) - before
                t.expect(
                    spent.chromeRepaints >= 1,
                    desc: "a letterbox at the ground's own colour still repaints the chrome (\(spent.chromeRepaints))"
                )
                surface.feed(Data("\u{1b}[?7402l".utf8))
                t.pump(0.3)

                // (3) A titlebar style change searches for the container it has
                // to repaint, and searches once.
                before = chromeCost(of: shell)
                TerminalWindowController.applyTitlebarStyleToOpenWindows()
                t.pump(0.4)
                spent = chromeCost(of: shell) - before
                t.expect(
                    spent.containerSearches == 1,
                    desc: "a titlebar style change searches for the container exactly once (\(spent.containerSearches))"
                )

                // (4) A tab's own title, in a pair: the label is baked and
                // written back, and the write-back chain ends — the quiet
                // updates after it cost nothing.
                shell.newWindowForTab(nil)
                guard t.wait(until: { (window.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20) else {
                    t.expect(false, desc: "a second tab opens")
                    return
                }
                t.pump(1.2)
                stopIngest(of: shell)
                for tab in window.tabGroup?.windows ?? [] {
                    (tab.windowController as? TerminalWindowController).map(stopIngest(of:))
                }
                t.pump(0.4)
                before = chromeCost(of: shell)
                guard let titled = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the front tab has a pane")
                    return
                }
                // Through the pane's shell: an OSC title is consumed by the
                // drain that parsed it, and bytes fed into the parser reach no
                // drain.
                _ = titled.drive.startIngest()
                titled.send("printf '\\033]2;quiet-chrome-title\\007'\n")
                _ = t.wait(until: { window.tab.title?.contains("quiet-chrome-title") == true }, timeout: 10)
                t.pump(0.3)
                spent = chromeCost(of: shell) - before
                t.expect(
                    window.tab.title?.contains("quiet-chrome-title") == true,
                    desc: "an OSC 2 names the tab ('\(window.tab.title ?? "")', \(spent.tabTitleBakes) bake(s))"
                )
                t.expect(spent.tabTitleBakes >= 1, desc: "and bakes its label (\(spent.tabTitleBakes))")
                t.expect(spent.chromeRepaints == 0, desc: "and repaints no chrome (\(spent.chromeRepaints))")
                // The chain the bake starts runs over a few turns; what must
                // end is the per-update write-back behind it.
                t.pump(1.2)
                before = chromeCost(of: shell)
                deliverQuietUpdates(10, to: shell, pumpingWith: t)
                spent = chromeCost(of: shell) - before
                t.expect(
                    spent == ChromeCost(),
                    desc: "and the updates after the chain cost nothing (\(spent.description))"
                )
            }
        }

        UBUITestRegister("swift_shell_a_profile_that_hides_the_title_bar_clears_the_row") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let launch = Ubiquitty.Preferences.Effective.launchSettings()
                let wasHidden = launch.shouldHideTitleBar
                let wasNative = launch.titlebarStyle == Ubiquitty.Preferences.TitlebarStyle.Native
                let profileName = "hide-title-bar-profile-" + UUID().uuidString
                app.settingsSetTitlebarStyle(0)
                app.settingsSetHideTitleBar(false)
                app.settingsSaveProfile(["name": profileName, "hideTitleBar": true])
                defer {
                    app.settingsDeleteProfileNamed(profileName)
                    app.settingsSetHideTitleBar(wasHidden)
                    app.settingsSetTitlebarStyle(wasNative ? 1 : 0)
                }
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.8)
                stopIngest(of: shell)
                guard let content = window.contentView,
                    let container = TabStripStyling.titlebarContainer(searchingFrom: content.superview ?? content)
                else {
                    t.expect(false, desc: "the window has a titlebar container")
                    return
                }
                guard let painted = container.layer?.backgroundColor, painted.alpha > 0.5 else {
                    t.expect(false, desc: "a themed titled window paints its title row to begin with")
                    return
                }

                shell.applyProfile(named: profileName)
                t.pump(0.5)
                let cleared = container.layer?.backgroundColor
                t.expect(
                    cleared == nil || cleared!.alpha < 0.01,
                    desc: "a profile that hides the title bar clears the row the theme had painted"
                )
            }
        }

        UBUITestRegister("swift_shell_every_pane_bar_follows_its_own_pane") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                app.settingsSetPaneTitleBars(true)
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.5)
                shell.splitRight(nil)
                t.pump(0.4)
                shell.splitDown(nil)
                t.pump(0.6)
                var bars = paneBars(under: shell.paneHost)
                guard bars.count == 3 else {
                    t.expect(false, desc: "three panes carry three bars (\(bars.count))")
                    return
                }
                // The pane the second split was made from: it held the keyboard
                // and gave it up, so a click back into it is a focus edge. The
                // first pane of a harness window may never have held it — the
                // window is never key — and a pane taking the keyboard for the
                // first time reports nothing to the window.
                guard let focused = shell.focusedSurfaceForTesting,
                    let background = bars.last(where: { $0.surface !== focused })
                else {
                    t.expect(false, desc: "one of the panes is not the focused one")
                    return
                }

                // (1) A background pane's own title reaches its own bar. Sent
                // through the pane's shell rather than fed into its parser:
                // an OSC title is consumed by the drain that parsed it, and a
                // fed byte reaches no drain.
                background.surface.send("printf '\\033]2;bg-title\\007'\n")
                t.expect(
                    t.wait(
                        until: { barTitle(background.chrome).contains("bg-title") },
                        timeout: 10
                    ),
                    desc: "a background pane's title reaches its own bar ('\(barTitle(background.chrome))')"
                )

                // (2) And its own theme: nothing about a background pane's
                // OSC 11 reaches the window's chrome, and its bar is the one
                // thing painted with it.
                let fillBefore = barFill(background.chrome)
                background.surface.send("printf '\\033]11;#802040\\007'\n")
                t.expect(
                    t.wait(until: { barFill(background.chrome) != fillBefore }, timeout: 10),
                    desc:
                        "a background pane's OSC 11 repaints its own bar (\(background.surface.currentThemeName ?? "no theme"), opaque \(window.isOpaque), fill \(String(describing: barFill(background.chrome))))"
                )

                // Quiet from here: the legs below are about edges that carry
                // no output at all.
                stopIngest(of: shell)
                t.pump(0.4)
                bars = paneBars(under: shell.paneHost)
                t.expect(
                    bars.allSatisfy { !barTitle($0.chrome).isEmpty },
                    desc: "every bar carries a title to begin with"
                )

                // (3) The tree is mirrored again — a split, a close, a restore
                // — and every bar comes up carrying its pane's title. Read on
                // the turn of the rebuild: a later event that happens to
                // restyle every bar would otherwise answer for this.
                shell.rebuildPaneLayoutForTesting()
                bars = paneBars(under: shell.paneHost)
                t.expect(bars.count == 3, desc: "the rebuild put three bars back (\(bars.count))")
                for (index, bar) in bars.enumerated() {
                    t.expect(
                        !barTitle(bar.chrome).isEmpty,
                        desc: "bar \(index) comes back titled after a rebuild ('\(barTitle(bar.chrome))')"
                    )
                }

                // (4) Moving focus with no output restyles both bars: the one
                // leaving focus and the one taking it. Every pane is handed the
                // keyboard once first: a surface starts out as the responder
                // target, so the first time it takes the keyboard it reports
                // nothing, and a harness window that is never key hands out
                // the keyboard less than a reader's window does.
                for bar in bars {
                    window.makeFirstResponder(bar.surface)
                }
                window.makeFirstResponder(focused)
                t.pump(0.4)
                guard let focusedBar = bars.first(where: { $0.surface === focused }),
                    let backgroundBar = bars.first(where: { $0.surface === background.surface })
                else {
                    t.expect(false, desc: "the focused pane has a bar")
                    return
                }
                t.expect(
                    isBarSelected(focusedBar.chrome),
                    desc:
                        "the focused pane's bar reads selected to begin with (\(focusedBar.surface.currentThemeName ?? "no theme"), opaque \(window.isOpaque))"
                )
                let focusEdgesBefore = shell.paneFocusEdgesForTesting
                window.makeFirstResponder(background.surface)
                t.pump(0.6)
                let focusMoved = shell.focusedSurfaceForTesting === background.surface
                let responderMoved = window.firstResponder === background.surface
                let focusEdges = shell.paneFocusEdgesForTesting - focusEdgesBefore
                t.expect(
                    !isBarSelected(focusedBar.chrome),
                    desc: "the bar of the pane focus LEFT reads unselected, with no output to carry it "
                        + "(model focus moved: \(focusMoved), responder moved: \(responderMoved), focus edges: \(focusEdges), "
                        + "bars selected: \(bars.map { isBarSelected($0.chrome) }), focused index: "
                        + "\(String(describing: bars.firstIndex { $0.surface === shell.focusedSurfaceForTesting })), "
                        + "background index: \(String(describing: bars.firstIndex { $0.surface === background.surface })))"
                )
                t.expect(
                    isBarSelected(backgroundBar.chrome),
                    desc: "and the bar of the pane focus reached reads selected"
                )
            }
        }

        UBUITestRegister("swift_inspector_process_table_follows_a_reaped_job") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.5)
                shell.toggleNativeInspector(nil)
                t.pump(0.8)
                guard let model = shell.inspectorModel else {
                    t.expect(false, desc: "the Inspector has a model")
                    return
                }
                t.expect(
                    t.wait(until: { !model.processes.isEmpty }, timeout: 8),
                    desc: "the process sample reaches the Inspector"
                )
                surface.send("sleep 4 &\n")
                t.expect(
                    t.wait(until: { model.processes.contains { $0.name.contains("sleep") } }, timeout: 8),
                    desc: "a background job shows in the Inspector's table"
                )
                surface.send("kill %1\n")
                t.pump(0.5)
                surface.send("echo done\n")
                t.expect(
                    t.wait(until: { !model.processes.contains { $0.name.contains("sleep") } }, timeout: 10),
                    desc: "and leaves the table once it is reaped, with the chain unchanged"
                )
            }
        }
    }
}
