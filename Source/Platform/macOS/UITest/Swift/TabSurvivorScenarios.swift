// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// TabSurvivorScenarios.swift — what a tab group's survivors show after a tab
// leaves, and what a thin read of the group must not cost them.
//
// Two defects, one walk. A tab closing hands its group's chrome back: the
// survivor of a pair carries its own report on its content again, and its
// number goes, because a lone window has no strip to wear either on. Nothing
// else tells it so — the tab that closed was a background tab, so the survivor
// stays selected and stays key, and no focus change arrives to provoke a walk.
// Nor can the closing window point at the survivor: AppKit has already taken it
// out of the group by the time it says the window will close, so the walk is
// asked of the group the closing tab was last seen sharing.
//
// The tab that leaves belongs to either window kind — AppKit's tab drag puts a
// window of one into a group of the other — and an Objective-C tab's going is
// announced to its own delegate, whose walk passes over a sibling that is not
// one of its own. So this controller answers every window's close, and the survivor of a mixed
// group is handed the chrome by the same single walk.
//
// The second is the walk's own hazard. `NSWindow.tabGroup` can under-report
// while AppKit mutates the group, and the deferred walks run exactly then. A
// walk that tears the chrome down off such a read leaves it down, since the
// window it happened to is already key and nothing further fires — which is
// what "the tab bar vanished when I closed a tab" looks like from the outside.
// So a tabbed-to-lone read is verified a turn later against the settled group.

/// Registers the tab-survivor scenarios with the UI-test runner.
enum TabSurvivorScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("tab_drag_keeps_native_mouse_tracking") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let controller = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let first = controller.window
                else { return }
                defer { Array(TerminalWindowController.spawnedControllers).forEach { $0.window?.close() } }
                controller.newWindowForTab(nil)
                t.pump(0.3)
                guard let window = first.tabGroup?.selectedWindow,
                    let strip = TabStripStyling.tabStripView(inGroupOf: window)
                else {
                    t.expect(false, desc: "the native tab strip appears")
                    return
                }
                @MainActor
                func tabButton(in view: NSView) -> NSView? {
                    if NSStringFromClass(type(of: view)) == "NSTabButton" { return view }
                    return view.subviews.lazy.compactMap { tabButton(in: $0) }.first
                }
                guard let button = tabButton(in: strip) else { return }
                let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
                    guard
                        let event = NSEvent.mouseEvent(
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
                    else { continue }
                    NSApp.postEvent(event, atStart: true)
                    let delivered = NSApp.nextEvent(
                        matching: NSEvent.EventTypeMask(rawValue: 1 << type.rawValue),
                        until: Date(timeIntervalSinceNow: 0.05),
                        inMode: .eventTracking,
                        dequeue: true
                    )
                    t.expect(
                        delivered?.type == type && delivered?.windowNumber == window.windowNumber,
                        desc: "\(type) reaches AppKit's native tab tracker (received \(String(describing: delivered?.type)))"
                    )
                }
                t.pump(0.1)
            }
        }
        UBUITestRegister("tab_drop_targets_cover_panes_and_the_complete_tab") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let source = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let sourceWindow = source.window, let pane = source.focusedSurfaceForTesting
                else { return }
                defer { Array(TerminalWindowController.spawnedControllers).forEach { $0.window?.close() } }
                source.newWindowForTab(nil)
                guard let survivorWindow = sourceWindow.tabGroup?.windows.first(where: { $0 !== sourceWindow }),
                    let survivor = survivorWindow.windowController as? TerminalWindowController
                else {
                    t.expect(false, desc: "the source has a tab to reveal")
                    return
                }
                survivor.splitRight(nil)
                survivorWindow.setContentSize(NSSize(width: 1000, height: 700))
                sourceWindow.tabGroup?.removeWindow(sourceWindow)
                survivorWindow.makeKeyAndOrderFront(nil)
                t.pump(0.3)
                t.expect(survivor.paneSurfacesForTesting.count == 2, desc: "the revealed tab keeps both existing panes")
                guard let target = survivor.focusedSurfaceForTesting else { return }
                let coordinator = PaneTransferCoordinator.shared
                let transfer = PaneTransferCoordinator.Transfer(controller: source, surface: pane, wholeTab: true)
                let tabFrame = survivor.paneHost.convert(survivor.paneHost.bounds, to: nil)
                let paneFrame = target.convert(target.bounds, to: nil)
                let placements: [(PaneTransferCoordinator.Placement, NSPoint, NSPoint)] = [
                    (
                        .left, NSPoint(x: tabFrame.minX + 4, y: tabFrame.midY),
                        NSPoint(x: paneFrame.minX + paneFrame.width * 0.2, y: paneFrame.midY)
                    ),
                    (
                        .right, NSPoint(x: tabFrame.maxX - 4, y: tabFrame.midY),
                        NSPoint(x: paneFrame.maxX - paneFrame.width * 0.2, y: paneFrame.midY)
                    ),
                    (
                        .above, NSPoint(x: tabFrame.midX, y: tabFrame.maxY - 4),
                        NSPoint(x: paneFrame.midX, y: paneFrame.maxY - paneFrame.height * 0.2)
                    ),
                    (
                        .below, NSPoint(x: tabFrame.midX, y: tabFrame.minY + 4),
                        NSPoint(x: paneFrame.midX, y: paneFrame.minY + paneFrame.height * 0.2)
                    ),
                ]
                for (placement, outerPoint, innerPoint) in placements {
                    let outer = coordinator.destination(for: transfer, in: survivor, at: outerPoint)
                    let inner = coordinator.destination(for: transfer, in: survivor, at: innerPoint)
                    t.expect(
                        outer?.placement == placement && outer?.insertTarget == .Root,
                        desc: "the outer \(placement) edge splits the whole tab"
                    )
                    t.expect(
                        inner?.placement == placement && inner?.insertTarget == .Pane,
                        desc: "the inner \(placement) target splits the pane"
                    )
                    t.expect(outer?.allowsRootSplit == true && inner?.allowsSplit == true, desc: "both sets of drop guides are available")
                    if let outer {
                        let spanning = placement == .above || placement == .below
                        t.expect(
                            abs(outer.frame.width - tabFrame.width * (spanning ? 1 : 0.5)) < 1
                                && abs(outer.frame.height - tabFrame.height * (spanning ? 0.5 : 1)) < 1,
                            desc: "the outer preview fills the correct half of the tab"
                        )
                    }
                }
                let center = NSPoint(x: paneFrame.midX, y: paneFrame.midY)
                let centerDrop = coordinator.destination(for: transfer, in: survivor, at: center)
                let nativeCenter = coordinator.destination(for: transfer, in: survivor, at: center, native: true)
                let blankBody = NSPoint(x: paneFrame.midX + paneFrame.width * 0.18, y: paneFrame.midY)
                let nativeBody = coordinator.destination(for: transfer, in: survivor, at: blankBody, native: true)
                t.expect(nativeCenter?.acceptsDrop == true, desc: "the explicit tab target accepts a native tab")
                t.expect(nativeBody?.acceptsDrop == false, desc: "blank content preserves native tear-off into a window")
                t.expect(
                    centerDrop?.allowsSplit == true && centerDrop?.allowsRootSplit == true,
                    desc: "all edge guides appear before selecting an edge"
                )
                if let frameView = survivorWindow.contentView?.superview, let centerDrop {
                    let overlay = TransferDropView(frame: frameView.bounds, owner: survivor, coordinator: coordinator, native: true)
                    frameView.addSubview(overlay)
                    overlay.show(centerDrop)
                    t.expect(overlay.hitTest(center) == nil, desc: "the guides leave native tab tracking untouched")
                    if let bitmap = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) {
                        overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: URL(fileURLWithPath: "/private/tmp/ubiquitty-tab-drop-guides.png"))
                        }
                    }
                    overlay.removeFromSuperview()
                }
                t.expect(
                    coordinator.move(transfer, to: survivor, target: target, placement: .above, insertTarget: .Root),
                    desc: "the torn-off tab drops above the tab it revealed"
                )
                t.pump(0.2)
                t.expect(
                    source.isClosedForTesting && survivor.paneSurfacesForTesting.count == 3,
                    desc: "the move keeps all three sessions in the revealed tab"
                )
                t.expect(abs(pane.frame.width - survivor.paneHost.bounds.width) < 2, desc: "the incoming pane spans the complete tab width")
            }
        }
        UBUITestRegister("pane_transfer_preserves_sessions_between_tabs_splits_and_windows") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let source = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let destination = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let target = destination.focusedSurfaceForTesting, let pane = source.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "two terminal windows open")
                    return
                }
                defer { Array(TerminalWindowController.spawnedControllers).forEach { $0.window?.close() } }
                source.window.map { $0.tabGroup?.removeWindow($0) }
                destination.window.map { $0.tabGroup?.removeWindow($0) }
                source.splitRight(nil)
                let coordinator = PaneTransferCoordinator.shared
                let transfer = PaneTransferCoordinator.Transfer(controller: source, surface: pane, wholeTab: false)
                t.expect(coordinator.extract(transfer, newWindow: true), desc: "a pane extracts to a standalone window")
                guard
                    let extracted = TerminalWindowController.spawnedControllers.first(where: {
                        $0 !== source && $0 !== destination && $0.paneSurfacesForTesting.contains(where: { $0 === pane })
                    }), let extractedWindow = extracted.window
                else {
                    t.expect(false, desc: "the extracted pane has a window")
                    return
                }
                t.expect(source.paneSurfacesForTesting.count == 1, desc: "the source split collapses")
                t.expect((extractedWindow.tabGroup?.windows.count ?? 1) == 1, desc: "extraction creates a window outside a tab group")
                t.expect(extracted.focusedSurfaceForTesting === pane, desc: "the pane retains its existing view and session")
                let tab = PaneTransferCoordinator.Transfer(controller: extracted, surface: pane, wholeTab: true)
                t.expect(
                    coordinator.move(tab, to: destination, target: target, placement: .tab),
                    desc: "a tab joins a window that had one tab"
                )
                t.expect(extractedWindow.tabGroup === destination.window?.tabGroup, desc: "the destination has a native tab group")
                t.expect(
                    coordinator.move(tab, to: destination, target: target, placement: .below),
                    desc: "a tab moves into a horizontal split"
                )
                t.expect(extracted.isClosedForTesting, desc: "the empty source window closes")
                t.expect(
                    destination.paneSurfacesForTesting.contains(where: { $0 === pane }),
                    desc: "closing the empty window preserves the moved pane"
                )
                destination.splitRight(nil)
                guard let sourceTarget = source.focusedSurfaceForTesting else { return }
                let nested = PaneTransferCoordinator.Transfer(controller: destination, surface: pane, wholeTab: true)
                t.expect(
                    coordinator.move(nested, to: source, target: sourceTarget, placement: .right),
                    desc: "a complete nested tab moves into a vertical split"
                )
                t.expect(source.paneSurfacesForTesting.count == 4, desc: "every nested pane survives the transfer")
                pane.send("echo transfer-session-$((6*7))\n")
                t.expect(
                    t.wait(until: { pane.searchScrollbackAndWait("transfer-session-42").totalMatches > 0 }, timeout: 8),
                    desc: "input and output survive closing the emptied source windows"
                )
            }
        }
        UBUITestRegister("pane_transfer_keeps_source_and_destination_window_frames") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let source = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let destination = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let sourceWindow = source.window, let destinationWindow = destination.window,
                    let pane = source.focusedSurfaceForTesting, let target = destination.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "source and destination windows open")
                    return
                }
                defer { Array(TerminalWindowController.spawnedControllers).forEach { $0.window?.close() } }
                sourceWindow.tabGroup?.removeWindow(sourceWindow)
                destinationWindow.tabGroup?.removeWindow(destinationWindow)
                source.newWindowForTab(nil)
                guard t.wait(until: { sourceWindow.tabGroup?.windows.count == 2 }, timeout: 8),
                    let remaining = sourceWindow.tabGroup?.windows.first(where: { $0 !== sourceWindow })
                else {
                    t.expect(false, desc: "the source has a tab that stays behind")
                    return
                }
                remaining.setContentSize(NSSize(width: 1120, height: 720))
                destinationWindow.setContentSize(NSSize(width: 760, height: 480))
                t.pump(0.2)
                let sourceFrame = remaining.frame
                let destinationFrame = destinationWindow.frame
                let transfer = PaneTransferCoordinator.Transfer(controller: source, surface: pane, wholeTab: true)
                t.expect(
                    PaneTransferCoordinator.shared.move(transfer, to: destination, target: target, placement: .tab),
                    desc: "a tab moves between differently sized windows"
                )
                t.expect(sourceWindow.tabGroup === destinationWindow.tabGroup, desc: "the moved tab joins the destination")
                t.expect(
                    abs(remaining.frame.width - sourceFrame.width) < 1 && abs(remaining.frame.minX - sourceFrame.minX) < 1,
                    desc: "the remaining source tab keeps its window width and position"
                )
                t.expect(
                    abs(destinationWindow.frame.width - destinationFrame.width) < 1
                        && abs(destinationWindow.frame.minX - destinationFrame.minX) < 1,
                    desc: "the destination keeps its window width and position"
                )
                t.expect(
                    abs(sourceWindow.frame.width - destinationWindow.frame.width) < 1
                        && abs(sourceWindow.frame.minX - destinationWindow.frame.minX) < 1,
                    desc: "the moved tab takes the destination frame"
                )
                t.expect(source.focusedSurfaceForTesting === pane, desc: "the moved tab retains its session")
            }
        }
        // AppKit remaps every pill's text when selection moves, including a
        // third pill whose selection and own title did not change. Its themed
        // ink must be restored in the assignment, before a frame can flash it.
        UBUITestRegister("swift_shell_switching_tabs_keeps_a_third_tabs_title_stable") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard #available(macOS 26.0, *) else { return }
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ), let first = shell.window
                else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer {
                    for window in first.tabGroup?.windows ?? [first] {
                        window.close()
                    }
                }
                first.makeKeyAndOrderFront(nil)
                shell.newWindowForTab(nil)
                guard t.wait(until: { first.tabGroup?.windows.count == 2 }, timeout: 8),
                    let second = first.tabGroup?.windows.first(where: { $0 !== first }),
                    let secondShell = second.windowController as? TerminalWindowController
                else {
                    t.expect(false, desc: "a second tab opens")
                    return
                }
                secondShell.newWindowForTab(nil)
                guard t.wait(until: { first.tabGroup?.windows.count == 3 }, timeout: 8),
                    let group = first.tabGroup,
                    let third = group.windows.first(where: { $0 !== first && $0 !== second }),
                    let thirdShell = third.windowController as? TerminalWindowController
                else {
                    t.expect(false, desc: "a third tab opens")
                    return
                }
                first.makeKeyAndOrderFront(nil)
                t.pump(0.5)
                let bakesBefore = thirdShell.tabTitleBakesForTesting
                guard let titleBefore = third.tab.attributedTitle,
                    let thirdIndex = group.windows.firstIndex(of: third),
                    let field = TabStripStyling.testTitleField(inGroupOf: first, at: thirdIndex),
                    let correctionsBefore = TabStripStyling.testTitleFieldCorrections(inGroupOf: first, at: thirdIndex)
                else {
                    t.expect(false, desc: "the inactive tab has a themed native title field")
                    return
                }
                second.makeKeyAndOrderFront(nil)
                t.pump(0.5)
                let bakes = thirdShell.tabTitleBakesForTesting - bakesBefore
                let corrections =
                    (TabStripStyling.testTitleFieldCorrections(inGroupOf: first, at: thirdIndex) ?? 0)
                    - correctionsBefore
                t.expect(group.selectedWindow === second, desc: "the second tab becomes selected")
                t.expect(bakes == 0, desc: "a tab that stayed inactive never re-bakes its title")
                t.expect(corrections > 0, desc: "AppKit's temporary native ink is corrected in the unchanged tab")
                t.expect(
                    field.attributedStringValue.isEqual(to: titleBefore),
                    desc: "the inactive tab's visible field keeps its themed ink"
                )
                t.expect(
                    third.tab.attributedTitle?.isEqual(to: titleBefore) == true,
                    desc: "the third tab keeps the same title and ink"
                )
            }
        }
        // The selected tab is told by weight: switching tabs, by whichever
        // route, leaves exactly the selected one semibold once the switch has
        // settled, with no focus cycle needed to catch the deselected tab up.
        UBUITestRegister("swift_shell_only_the_selected_tab_reads_semibold_after_a_switch") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let first = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { first.tabGroup?.windows.forEach { $0.close() } }
                first.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                shell.newWindowForTab(nil)
                guard t.wait(until: { (first.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20),
                    let group = first.tabGroup,
                    let second = group.windows.first(where: { $0 !== first })
                else {
                    t.expect(false, desc: "a second tab opens")
                    return
                }
                let weightOf = { (window: NSWindow) -> CGFloat in
                    guard let title = window.tab.attributedTitle, title.length > 0,
                        let font = title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                    else { return -1 }
                    let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
                    return (traits?[.weight] as? CGFloat) ?? -1
                }
                let report = { "first \(weightOf(first)) second \(weightOf(second))" }
                let settle = { t.pump(0.5) }

                group.selectedWindow = second
                second.makeKeyAndOrderFront(nil)
                settle()
                t.expect(weightOf(second) > weightOf(first), desc: "after selecting the second tab, it alone is semibold (\(report()))")

                // Back to the first the way a click on its tab does it: the
                // window becomes key, and AppKit moves the selection with it.
                first.makeKeyAndOrderFront(nil)
                settle()
                t.expect(group.selectedWindow === first, desc: "the first tab is selected")
                t.expect(weightOf(first) > weightOf(second), desc: "after clicking back, the first alone is semibold (\(report()))")

                // And by the tab group's own selection, as the next-tab
                // command moves it.
                group.selectedWindow = second
                settle()
                t.expect(weightOf(second) > weightOf(first), desc: "after the group selects the second, it alone is semibold (\(report()))")
                group.selectedWindow = first
                settle()
                t.expect(weightOf(first) > weightOf(second), desc: "and back again (\(report()))")

                // The window server reports a window that just came to the
                // front as occluded for a moment; the tab that went behind it
                // is re-baked all the same, since its label on the strip is
                // as visible as the strip.
                guard let secondShell = second.windowController as? TerminalWindowController,
                    let secondSurface = secondShell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "the second tab has a surface")
                    return
                }
                secondSurface.isFullyOccludedForTesting = true
                group.selectedWindow = second
                second.makeKeyAndOrderFront(nil)
                settle()
                t.expect(
                    weightOf(second) > weightOf(first),
                    desc: "with the front tab reported occluded, the tab behind it still reads regular (\(report()))"
                )
                secondSurface.isFullyOccludedForTesting = nil
            }
        }

        UBUITestRegister("swift_shell_a_closing_tab_hands_the_strip_back_once") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let first = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { first.tabGroup?.windows.forEach { $0.close() } }
                let restoreHints = hintMode()
                defer { setHintMode(restoreHints) }
                setHintMode(Int(Ubiquitty.Preferences.tabShortcutHintsToInt(.Always)))
                first.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                guard let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }

                // A second tab, then the reporting one is brought back in
                // front: the tab that closes is a BACKGROUND tab, so its going
                // moves neither the selection nor the key window, and the
                // survivor is owed a walk that no event of its own will give.
                shell.newWindowForTab(nil)
                guard t.wait(until: { (first.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20),
                    let group = first.tabGroup,
                    let second = group.windows.first(where: { $0 !== first })
                else {
                    t.expect(false, desc: "a second tab opens")
                    return
                }
                group.selectedWindow = first
                first.makeKeyAndOrderFront(nil)
                t.pump(0.4)

                surface.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait("ready-42").totalMatches > 0 }, timeout: 8),
                    desc: "the survivor's shell is up"
                )
                surface.transmitAsUserInputForTesting("printf '\\033]9;4;1;40\\007'\r")
                t.expect(
                    t.wait(until: { shell.focusedSurfaceForTesting?.drive.readSnapshot().progressState == 1 }, timeout: 6),
                    desc: "the survivor's pane reports progress"
                )
                t.expect(
                    t.wait(until: { ProgressChromeScenarios.windowBand(of: shell)?.isHidden ?? true }, timeout: 4),
                    desc: "a tabbed window keeps the report off its own chrome"
                )
                t.expect(
                    accessoryText(first) == "⌘1",
                    desc: "and wears the number that selects it (\(accessoryText(first)))"
                )

                let reconciles = shell.tabGroupCloseReconcilesForTesting
                second.close()
                t.expect(
                    t.wait(until: { (first.tabbedWindows?.count ?? 1) <= 1 }, timeout: 10),
                    desc: "the background tab left the group"
                )
                t.expect(
                    t.wait(until: { ProgressChromeScenarios.windowBand(of: shell).map { !$0.isHidden } ?? false }, timeout: 4),
                    desc: "the survivor takes its report back into its own chrome"
                )
                t.expect(
                    accessoryText(first).isEmpty,
                    desc: "and drops the number, having no strip to wear it on (\(accessoryText(first)))"
                )
                t.expect(
                    shell.tabGroupCloseReconcilesForTesting == reconciles + 1,
                    desc: "one walk for the close, not two"
                        + " (\(shell.tabGroupCloseReconcilesForTesting - reconciles))"
                )
            }
        }

        UBUITestRegister("swift_shell_a_thin_tab_group_read_is_verified_a_turn_later") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let first = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { first.tabGroup?.windows.forEach { $0.close() } }
                let restoreHints = hintMode()
                defer { setHintMode(restoreHints) }
                setHintMode(Int(Ubiquitty.Preferences.tabShortcutHintsToInt(.Always)))
                first.makeKeyAndOrderFront(nil)
                t.pump(0.4)

                shell.newWindowForTab(nil)
                guard t.wait(until: { (first.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20),
                    let group = first.tabGroup,
                    let second = group.windows.first(where: { $0 !== first })
                else {
                    t.expect(false, desc: "a second tab opens")
                    return
                }
                group.selectedWindow = first
                first.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                TerminalWindowController.refreshTabAccessoriesForOpenWindows()
                t.expect(
                    accessoryText(first) == "⌘1",
                    desc: "the tabbed window wears its number (\(accessoryText(first)))"
                )

                // The thin read, built rather than waited for: the group is
                // taken apart, walked while it reads lone, and put back inside
                // the same turn — which is what AppKit's own mid-mutation read
                // looks like to the walk.
                let reverifies = shell.thinGroupReverifiesForTesting
                group.removeWindow(second)
                shell.refreshTabAccessory()
                t.expect(
                    accessoryText(first).isEmpty,
                    desc: "the walk read the group as lone and took the number off (\(accessoryText(first)))"
                )
                // Re-formed below the survivor, which is the one ordering
                // AppKit does not answer by moving the selection: neither the
                // selection nor the key window changes here, so the walks
                // those edges drive cannot be what gives the number back. The
                // tab that re-joins takes the first slot, so the survivor is
                // now the second.
                first.addTabbedWindow(second, ordered: .below)
                t.expect(
                    (first.tabbedWindows?.count ?? 0) == 2,
                    desc: "the group is whole again (\(first.tabbedWindows?.count ?? 0))"
                )
                t.expect(
                    first.tabGroup?.selectedWindow === first,
                    desc: "with the survivor still selected"
                )

                t.expect(
                    t.wait(until: { shell.thinGroupReverifiesForTesting == reverifies + 1 }, timeout: 4),
                    desc: "the guard overturned the thin read a turn later"
                        + " (\(shell.thinGroupReverifiesForTesting - reverifies))"
                )
                t.expect(
                    t.wait(until: { accessoryText(first) == "⌘2" }, timeout: 4),
                    desc: "and the number is back on the tab"
                        + " (\(accessoryText(first)), \(first.tabbedWindows?.count ?? 0) tabs,"
                        + " \(shell.thinGroupReverifiesForTesting - reverifies) reverifies)"
                )
            }
        }
    }

    /// The number a tab advertises, trimmed of the padding that holds it off
    /// the tab's right edge.
    ///
    /// - Parameter tab: The tab window to read.
    /// - Returns: The label, or empty when the tab wears none.
    @MainActor
    private static func accessoryText(_ tab: NSWindow) -> String {
        ((tab.tab.accessoryView as? NSTextField)?.stringValue ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The tab-hint setting in force, as the settings writer spells it.
    ///
    /// Stated rather than inherited: these scenarios run against a preferences
    /// sandbox of their own, and a leg that passed on whatever that file
    /// happens to say would be reporting on the file.
    ///
    /// - Returns: The setting's integer form.
    @MainActor
    private static func hintMode() -> Int {
        Int(
            Ubiquitty.Preferences.tabShortcutHintsToInt(
                Ubiquitty.Preferences.Effective.tabShortcutHints(Ubiquitty.Preferences.values().pointee)
            )
        )
    }

    /// Puts the tab-hint setting where a scenario needs it, through the real
    /// settings writer so every open window sees it.
    ///
    /// - Parameter mode: The setting's integer form.
    @MainActor
    private static func setHintMode(_ mode: Int) {
        guard let app = NSApp.delegate as? UBAppDelegate else { return }
        app.settingsSetTabShortcutHintMode(mode)
        TerminalWindowController.refreshTabAccessoriesForOpenWindows()
    }
}
