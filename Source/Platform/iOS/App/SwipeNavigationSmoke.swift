// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftUI
import UIKit
import UbiquittyCore
import UbiquittyKit

/// Workspace pane order and UIKit ownership during sideways swipes.
///
/// Each case is a way the walk could strand or mislead a reader: a swipe at
/// the last pane that goes nowhere instead of wrapping, a split tab skipped
/// entirely, a single pane or connection that answers with a
/// switch to itself, and a model whose notice outlives the moment it names.
enum SwipeNavigationSmokeEntry {
    @MainActor
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ failure: String) {
            if !condition { failures.append(failure) }
        }

        // The walk itself, over plain entries.
        let neighbors: [(String, Int?, [Int], SwipeStep, Int?)] = [
            ("next moves right", 2, [1, 2, 3], .next, 3),
            ("previous moves left", 2, [1, 2, 3], .previous, 1),
            ("next wraps from the last", 3, [1, 2, 3], .next, 1),
            ("previous wraps from the first", 1, [1, 2, 3], .previous, 3),
            ("two entries swap either way", 1, [1, 2], .previous, 2),
            ("one entry has nowhere to go", 1, [1], .next, nil),
            ("one entry has nowhere to go back to", 1, [1], .previous, nil),
            ("an empty list has nowhere to go", nil, [], .next, nil),
            ("a missing current walks in from the front", 9, [1, 2, 3], .next, 1),
            ("a missing current walks in from the back", nil, [1, 2, 3], .previous, 3),
        ]
        for (name, current, ordered, step, expected) in neighbors {
            let got = TerminalSwipeNavigation.neighbor(of: current, in: ordered, step: step)
            check(got == expected, "neighbor: \(name): expected \(String(describing: expected)), got \(String(describing: got))")
        }

        // Tabs: two windows, the first with a split tab and a named one.
        func pane(_ id: UInt32, window: Int, tab: Int, title: String) -> TerminalPane {
            TerminalPane(id: id, title: "\(title) · Pane", windowIndex: window, tabIndex: tab, tabTitle: title)
        }
        let panes = [
            pane(10, window: 0, tab: 0, title: "Tab 1"),
            pane(11, window: 0, tab: 0, title: "Tab 1"),
            pane(20, window: 0, tab: 1, title: "build"),
            pane(30, window: 1, tab: 0, title: "Tab 1"),
            pane(31, window: 1, tab: 0, title: "Tab 1"),
        ]
        let tabs: [(String, UInt32, SwipeStep, UInt32?)] = [
            ("next visits the second pane in the same tab", 10, .next, 11),
            ("next from the second pane of a tab is the next tab", 11, .next, 20),
            ("next crosses into the next window's first pane", 20, .next, 30),
            ("next wraps to the first tab's first pane", 31, .next, 10),
            ("previous lands on a split tab's last pane", 20, .previous, 11),
            ("previous visits the first pane of the same tab", 11, .previous, 10),
            ("previous wraps to the last pane", 10, .previous, 31),
            ("a pane the list no longer holds walks in from the front", 99, .next, 10),
        ]
        for (name, active, step, expected) in tabs {
            let got = TerminalSwipeNavigation.paneDestination(from: active, among: panes, step: step)?.id
            check(got == expected, "tab: \(name): expected \(String(describing: expected)), got \(String(describing: got))")
        }
        check(
            TerminalSwipeNavigation.paneDestination(from: 11, among: panes, step: .next)?.tabTitle == "build",
            "tab: the destination does not carry its tab's own title"
        )
        let splitOnly = [pane(1, window: 0, tab: 0, title: "Tab 1"), pane(2, window: 0, tab: 0, title: "Tab 1")]
        check(
            TerminalSwipeNavigation.paneDestination(from: 2, among: splitOnly, step: .next)?.id == 1,
            "pane: one tab split in two did not navigate between panes"
        )
        check(
            TerminalSwipeNavigation.paneDestination(from: 0, among: [], step: .previous) == nil,
            "tab: a session with no workspace answered with a switch"
        )

        var tree = Ubiquitty.Panes.Tree(10)
        _ = tree.split(.Vertical, 11)
        _ = tree.focusPane(10)
        _ = tree.split(.Horizontal, 12)
        check(TerminalSwipeNavigation.paneIDs(in: tree) == [10, 12, 11], "pane order followed allocation slots instead of visual children")
        _ = tree.closePane(10)
        check(TerminalSwipeNavigation.paneIDs(in: tree) == [12, 11], "pane order changed after collapsing a removed leaf")

        // Connections, ordered as the host list is.
        let hostA = UUID()
        let hostB = UUID()
        let hostC = UUID()
        let open = [hostA, hostB, hostC]
        check(TerminalSwipeNavigation.neighbor(of: hostC, in: open, step: .next) == hostA, "connection: next did not wrap")
        check(TerminalSwipeNavigation.neighbor(of: hostA, in: open, step: .previous) == hostC, "connection: previous did not wrap")
        check(TerminalSwipeNavigation.neighbor(of: hostB, in: [hostB], step: .next) == nil, "connection: one connection switched to itself")
        check(
            TerminalSwipeNavigation.connectionNotice(hostName: "build-box", sessionSummary: "") == "build-box",
            "connection: a model with no summary did not name the host alone"
        )
        check(
            TerminalSwipeNavigation.connectionNotice(hostName: "build-box", sessionSummary: "Session 7, workspace review")
                == "build-box · Session 7, workspace review",
            "connection: the notice dropped the session summary"
        )

        let closing = TerminalSessionModel()
        closing.seedShowcaseWorkspace()
        closing.requestKeyboardClose(wholeTab: false)
        if let request = closing.keyboardCloseRequest {
            closing.selectPane(3)
            closing.confirmKeyboardClose(request)
            check(
                closing.surface(forPane: 1) == nil && closing.surface(forPane: 3) != nil,
                "keyboard close followed focus instead of the confirmed pane"
            )
        } else {
            check(false, "keyboard close did not ask before ending a pane")
        }
        let changed = TerminalSessionModel()
        changed.seedShowcaseWorkspace()
        changed.requestKeyboardClose(wholeTab: true)
        if let request = changed.keyboardCloseRequest {
            changed.seedShowcaseWorkspace()
            changed.confirmKeyboardClose(request)
            check(changed.surface(forPane: 1) != nil, "a stale keyboard confirmation closed a replacement pane")
        } else {
            check(false, "keyboard close did not ask before ending a tab")
        }

        // The connection walk as the host list runs it: only hosts with a
        // connection under way, in list order, and the notice on the model the
        // arriving screen draws.
        let hostD = UUID()
        let saved = [hostA, hostB, hostC, hostD]
        let underWay: Set<UUID> = [hostA, hostC, hostD]
        let switches: [(String, UUID, Set<UUID>, SwipeStep, UUID?, UUID)] = [
            ("next skips a host with no connection", hostA, underWay, .next, hostC, hostC),
            ("previous skips a host with no connection", hostC, underWay, .previous, hostA, hostA),
            ("next wraps past the last open host", hostD, underWay, .next, hostA, hostA),
            ("previous wraps past the first open host", hostA, underWay, .previous, hostD, hostD),
            ("a lone open host stays and names itself", hostC, [hostC], .next, nil, hostC),
            ("a swipe from a host not yet connecting walks in from the front", hostB, underWay, .next, hostA, hostA),
        ]
        for (name, current, open, step, destination, announced) in switches {
            let got = TerminalSwipeNavigation.connectionSwitch(from: current, hosts: saved, isOpen: { open.contains($0) }, step: step)
            check(
                got == ConnectionSwitch(destination: destination, announcedOn: announced),
                "connection switch: \(name): expected \(String(describing: destination)) announced on \(announced), got \(got)"
            )
        }

        // The model walks every pane and names the destination tab and pane.
        let workspace = TerminalSessionModel()
        let initial = TerminalSessionModel()
        var initialSurfaces: [UInt32: TerminalSurface] = [:]
        for pane in panes { initialSurfaces[pane.id] = initial.makePaneSurface() }
        initial.adoptSeededPanes(panes, surfaces: initialSurfaces)
        initial.reconcilePaneFocus(attachmentPaneID: 30, previousPaneIDs: [])
        check(initial.activePaneID == 30, "initial attachment selected the first pane instead of the requested session")
        initial.selectPane(20)
        initial.reconcilePaneFocus(attachmentPaneID: 30, previousPaneIDs: panes.map(\.id))
        check(initial.activePaneID == 20, "a workspace refresh replaced the person's selection")
        workspace.seedWorkspaceForTesting(panes, focusing: 11)
        check(workspace.activePaneID == 11, "model: the seeded workspace did not focus its pane, so the tab cases assert nothing")
        workspace.switchTab(.next)
        check(workspace.activePaneID == 20, "model: a tab swipe left the focus on pane \(workspace.activePaneID), wanted the next tab's 20")
        check(workspace.notice == "build · Pane", "model: a pane swipe did not name both the tab and pane: \"\(workspace.notice)\"")
        workspace.switchTab(.next)
        check(workspace.activePaneID == 30, "model: a tab swipe did not cross into the next window, focus \(workspace.activePaneID)")
        workspace.switchTab(.next)
        check(workspace.activePaneID == 31, "model: a swipe skipped the last tab's second pane")
        workspace.switchTab(.next)
        check(
            workspace.activePaneID == 10,
            "model: a tab swipe from the last tab did not wrap to the first, focus \(workspace.activePaneID)"
        )
        check(workspace.notice == "Tab 1 · Pane", "model: the wrap announced \"\(workspace.notice)\"")
        workspace.switchTab(.previous)
        check(
            workspace.activePaneID == 31,
            "model: a previous tab swipe from the first tab did not wrap to the last, focus \(workspace.activePaneID)"
        )

        // Real UIKit containment, not just a model walk. The compact window's
        // own layout hands one host each newly focused surface; a host rebuilt
        // on every switch, animated, keeps the outgoing host alive while its
        // replacement claims the surface, as a window changing width class
        // does. Each runs the same swipes over retained surfaces.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        func seededWorkspace() -> TerminalSessionModel {
            let seeded = TerminalSessionModel()
            seeded.seedWorkspaceForTesting(panes, focusing: 11)
            return seeded
        }
        let compact = seededWorkspace()
        let rebuilt = seededWorkspace()
        let hosts: [(String, TerminalSessionModel, AnyView)] = [
            ("compact layout", compact, AnyView(TerminalPaneLayout(session: compact).environment(\.horizontalSizeClass, .compact))),
            ("rebuilt host", rebuilt, AnyView(RebuiltOnFocusHost(session: rebuilt))),
        ]
        for (host, workspace, root) in hosts {
            guard let scene else {
                check(false, "UIKit: \(host): no scene for actual pane-host transitions")
                continue
            }
            let previousWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: root)
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousWindow?.makeKey()
            }
            func settle(until isSettled: () -> Bool) -> Bool {
                let deadline = Date().addingTimeInterval(2)
                repeat {
                    window.layoutIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                    if isSettled() { return true }
                } while Date() < deadline
                return false
            }
            func settleDrawing(_ id: UInt32) -> Bool {
                settle { workspace.surface(forPane: id)?.window === window }
            }
            check(settleDrawing(workspace.activePaneID), "UIKit: \(host): initial pane is not in the smoke window")
            for index in 0..<20 {
                let previous = workspace.surface(forPane: workspace.activePaneID)
                workspace.switchTab(index.isMultiple(of: 2) ? .next : .previous)
                check(settleDrawing(workspace.activePaneID), "UIKit: \(host): swipe \(index) left the selected surface unhosted")
                // One host hands its container the next surface, so the one
                // it held leaves the window. A host rebuilt per pane leaves
                // the outgoing surface in the host SwiftUI still holds, which
                // is the overlap it stands for.
                if workspace === compact {
                    check(settle { previous?.window == nil }, "UIKit: \(host): swipe \(index) left the outgoing surface in the window")
                }
                // Observe routing directly: a selected pane's update is
                // accepted, while a still-alive outgoing pane cannot retitle
                // it. This does not depend on offscreen VT title delivery.
                if let current = workspace.surface(forPane: workspace.activePaneID) {
                    workspace.terminalSurface(current, didChangeTitle: "pane-\(workspace.activePaneID)")
                }
                if let previous { workspace.terminalSurface(previous, didChangeTitle: "outgoing") }
                check(
                    workspace.title == "pane-\(workspace.activePaneID)",
                    "UIKit: \(host): outgoing host retargeted focus to title \(workspace.title)"
                )
            }
            let removed = workspace.surface(forPane: workspace.activePaneID)
            workspace.seedWorkspaceForTesting(
                [
                    pane(1, window: 0, tab: 0, title: "first"),
                    pane(2, window: 0, tab: 1, title: "second"),
                ],
                focusing: 1
            )
            check(settleDrawing(1), "UIKit: \(host): rebuilding the selected pane left it unhosted")
            let replaced = workspace.surface(forPane: 1)
            workspace.seedWorkspaceForTesting(
                [pane(1, window: 0, tab: 0, title: "replacement"), pane(2, window: 0, tab: 1, title: "second")],
                focusing: 1
            )
            check(settleDrawing(1), "UIKit: \(host): replacing a surface with the same pane ID left the old terminal on screen")
            check(replaced?.window == nil, "UIKit: \(host): the retired surface still occupies the pane")
            if let removed {
                workspace.terminalSurfaceDidRequestNextTab(removed)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                check(workspace.activePaneID == 1, "UIKit: \(host): a removed surface's delayed swipe changed the replacement workspace")
            }
            if let current = workspace.surface(forPane: 1) {
                for _ in 0..<8 { workspace.terminalSurfaceDidRequestNextTab(current) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                check(workspace.activePaneID == 1, "UIKit: \(host): eight rapid swipes did not traverse the two-pane workspace evenly")
            }
            check(settleDrawing(workspace.activePaneID), "UIKit: \(host): rapid swipes left the selected surface unhosted")

            if let current = workspace.surface(forPane: workspace.activePaneID) {
                let missing = UIHostingController(rootView: TerminalSurfaceHost(session: workspace, paneID: 999))
                missing.loadViewIfNeeded()
                missing.view.frame = window.bounds
                missing.view.layoutIfNeeded()
                check(current.window === window, "UIKit: \(host): a removed pane's host stole the focused pane's surface")
                check(
                    current.accessibilityIdentifier == "terminal-surface",
                    "UIKit: \(host): compact pane changed its accessibility identity"
                )
            }
        }

        // A container's claim on a controller, outside any view: the newest
        // claim holds, and an older container gives back only what it holds.
        if let current = compact.surface(forPane: compact.activePaneID) {
            let controller = compact.controller(for: current)
            let oldContainer = PaneSurfaceContainer(hosted: controller)
            oldContainer.loadViewIfNeeded()
            let replacement = PaneSurfaceContainer(hosted: controller)
            replacement.loadViewIfNeeded()
            check(
                oldContainer.childViewControllerForPointerLock == nil,
                "UIKit: retired container advertises a foreign pointer-lock child"
            )
            oldContainer.relinquish()
            check(controller.parent === replacement, "UIKit: old dismantle stole the replacement's child")
            replacement.relinquish()
            oldContainer.claimIfUnheld()
            check(controller.parent === oldContainer, "UIKit: a surviving container could not reclaim its unheld child")
            oldContainer.relinquish()
        }

        // The first listing after an attach focuses the pane the attach
        // already draws, in the layout a compact window shows. The surface
        // stays where it is: a host rebuilt for the new focus takes it out of
        // its window and back, and the host it is attached to is told the
        // pane was hidden and shown again.
        let attached = TerminalSessionModel()
        if let scene, let anchor = attached.surfaceForDrawing() {
            let previousWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(
                rootView: TerminalPaneLayout(session: attached).environment(\.horizontalSizeClass, .compact)
            )
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousWindow?.makeKey()
            }
            func settle(until isSettled: () -> Bool) -> Bool {
                let deadline = Date().addingTimeInterval(2)
                repeat {
                    window.layoutIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                    if isSettled() { return true }
                } while Date() < deadline
                return false
            }
            check(settle { anchor.window === window }, "UIKit: the attached surface is not in the smoke window")
            let container = attached.controller(for: anchor).parent
            let reports = anchor.remotePaneViewReportCount
            attached.seedAttachedWorkspaceForTesting(
                [pane(7, window: 0, tab: 0, title: "attached"), pane(8, window: 0, tab: 1, title: "beside")],
                attachedPane: 7
            )
            check(attached.activePaneID == 7, "model: the first listing did not focus the attached pane, focus \(attached.activePaneID)")
            _ = settle { false }
            check(anchor.window === window, "UIKit: focusing the attached pane left its surface out of the window")
            check(
                container != nil && attached.controller(for: anchor).parent === container,
                "UIKit: focusing the pane the attach already drew rebuilt its host"
            )
            check(
                anchor.remotePaneViewReportCount == reports && anchor.isRemotePaneShown,
                "UIKit: focusing the attached pane told the host it was hidden and shown "
                    + "(\(anchor.remotePaneViewReportCount - reports) view reports)"
            )
            // What reaches the pane after the listing is drawn.
            let frames = anchor.drawnFrameCount
            anchor.feed(Data("listed\r\n".utf8))
            anchor.serviceIngestEvents()
            check(settle { anchor.drawnFrameCount > frames }, "UIKit: the attached pane drew nothing after the first listing")
        } else {
            check(false, "UIKit: no scene or surface for the first focus of an attached pane")
        }

        // The model's half: a swipe with nowhere to go still answers, and the
        // answer clears itself.
        let model = TerminalSessionModel()
        model.switchTab(.next)
        check(
            model.notice == TerminalSwipeNavigation.noPanesNotice,
            "model: a tab swipe on a session with no tabs left the notice at \"\(model.notice)\""
        )
        model.seedWorkspaceForTesting([splitOnly[0]], focusing: 1)
        model.switchTab(.next)
        check(model.notice == TerminalSwipeNavigation.onlyOnePaneNotice, "model: a single pane reported a misleading tab count")
        let deadline = Date().addingTimeInterval(TimeInterval(TerminalSessionModel.noticeDuration.components.seconds) + 2)
        while !model.notice.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        check(model.notice.isEmpty, "model: the notice never cleared itself")

        // A newer notice is not cut short by the older one's clear.
        model.announce("first")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        model.announce("second")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        check(model.notice == "second", "model: an earlier notice's clear cut a later notice short")

        for failure in failures {
            SmokeLaunch.report("swipe-navigation: FAIL: \(failure)")
        }
        SmokeLaunch.report("swipe-navigation: \(failures.count) failures")
        return failures.isEmpty
    }
}

/// A host rebuilt on every focus change, the change animated, so SwiftUI
/// builds the next host while the last is still up and two hosts ask for one
/// surface at once.
///
/// No production view is keyed on focus: the compact layout keeps one host,
/// and an arranged pane is keyed on its own pane. This one stands for the
/// overlap that remains, a window changing width class, where the host that
/// leaves and the host that arrives both hold the same pane's surface.
private struct RebuiltOnFocusHost: View {
    let session: TerminalSessionModel

    var body: some View {
        TerminalSurfaceHost(session: session, paneID: session.activePaneID == 0 ? nil : session.activePaneID)
            .id(session.activePaneID)
            .animation(.linear(duration: 0.05), value: session.activePaneID)
    }
}
