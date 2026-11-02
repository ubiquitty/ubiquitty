// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import QuartzCore
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// ProgressChromeScenarios.swift — where a program's OSC 9;4 report shows, and
// that showing it moves no text.
//
// A report never moves a grid: no pane gains or loses a row or a column, and
// none moves its first cell, when a report starts, changes or ends. So each
// slot a report can light is one that has its height already. A lone window
// wears the bar along its title bar's bottom edge, in the chrome and outside
// the content; a split pane wears it along the bottom edge of its own header;
// and a pane with no header, or a window with no title bar, wears it over its
// top edge as an overlay that reserves nothing. Two things hold in every slot
// and are invisible from the setting alone. The band is a *sibling* of the
// Metal view rather than a layer inside its subtree: a comet animating in
// there re-snaps the grid's rows as it loops, which reads as the text
// twitching while a download runs. And its colour is a rule, not a constant:
// an error stays red in a window nobody is looking at, where a running
// download dims to the grey AppKit uses for the controls of an inactive
// window.

/// Registers the progress-chrome scenarios with the UI-test runner.
enum ProgressChromeScenarios {
    /// Registers every scenario in this file.
    static func register() {
        // A lone window's report rides the bottom edge of its title bar: in
        // the window's chrome, outside the content, so the grid keeps its rows
        // and its columns and stays where it stood while the report starts,
        // changes and ends.
        UBUITestRegister("swift_shell_a_lone_windows_report_rides_its_title_bars_edge_and_moves_no_text") { context in
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
                surface.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait("ready-42").totalMatches > 0 }, timeout: 8),
                    desc: "the shell is up"
                )
                t.pump(0.3)
                var samples = [placements(of: [surface])]

                // A determinate report at 40 per cent.
                surface.transmitAsUserInputForTesting("printf '\\033]9;4;1;40\\007'\r")
                t.expect(
                    t.wait(until: { surface.drive.readSnapshot().progressState == 1 }, timeout: 4),
                    desc: "the report reaches the published snapshot"
                )
                samples.append(settledPlacements(t, of: [surface], from: samples[0]))
                t.expect(
                    t.wait(until: { titleRowBand(of: window).map { !$0.isHidden } ?? false }, timeout: 4),
                    desc: "and raises a bar in the window's title bar"
                )
                let band = titleRowBand(of: window)
                let bandInWindow = band.map { $0.convert($0.bounds, to: nil) }
                let rowInWindow = titlebarStrip(of: window).map { $0.convert($0.bounds, to: nil) }
                let contentInWindow = shell.paneHost.convert(shell.paneHost.bounds, to: nil)
                t.expect(
                    isEdge(bandInWindow?.minY, rowInWindow?.minY) && isEdge(bandInWindow?.width, rowInWindow?.width),
                    desc:
                        "along the title bar's bottom edge, across its width (bar \(describe(bandInWindow)), title bar \(describe(rowInWindow)))"
                )
                t.expect(
                    bandInWindow.map { $0.minY >= contentInWindow.maxY - 0.5 } ?? false,
                    desc: "outside the content area (bar \(describe(bandInWindow)), content \(describe(contentInWindow)))"
                )
                t.expect(band.map { !$0.isDescendant(of: surface) } ?? false, desc: "and outside the Metal view's subtree")
                // The harness's windows never take main, which is the dimmed
                // case: a running download in a window nobody is looking at.
                t.expect(band?.tintColor == NSColor.systemGray, desc: "a running bar in an inactive window is dimmed")

                // An error is an alert, so it keeps its red in the same
                // window the running bar was just dimmed in. Without this
                // step a tint that was always grey would pass.
                surface.transmitAsUserInputForTesting("printf '\\033]9;4;2;0\\007'\r")
                t.wait(until: { surface.drive.readSnapshot().progressState == 2 }, timeout: 4)
                t.expect(
                    t.wait(until: { band?.tintColor == NSColor.systemRed }, timeout: 4),
                    desc: "an error stays red where a running bar dims"
                )
                samples.append(settledPlacements(t, of: [surface], from: samples[0]))

                surface.transmitAsUserInputForTesting("printf '\\033]9;4;0;0\\007'\r")
                t.expect(
                    t.wait(until: { surface.drive.readSnapshot().progressState == 0 }, timeout: 4),
                    desc: "the cleared report reaches the published snapshot"
                )
                t.expect(t.wait(until: { band?.isHidden ?? false }, timeout: 4), desc: "and withdraws the bar")
                samples.append(settledPlacements(t, of: [surface], from: samples[0]))
                expectUnmoved(t, samples, names: ["the pane"])
            }
        }

        // A percent that moves travels to its new length; every other arrival
        // is a step. The difference is invisible in geometry — a frame after
        // either one the fill stands at the same width — so what is asked for
        // is the animation itself, and the length it starts from, which is the
        // only thing that says the bar left where it was rather than appearing
        // at the destination.
        //
        // Driven on a band of this scenario's own, laid out between reports: a
        // report is applied by a layout pass, and two reports queued without
        // one between them are a single step no assertion could tell from a
        // missing sweep.
        UBUITestRegister("swift_shell_a_moved_progress_percent_sweeps_the_bands_length") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let span: CGFloat = 200.0
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: span, height: 40),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                defer { window.close() }
                let band = ProgressBar(frame: NSRect(x: 0, y: 0, width: span, height: ProgressBar.bandHeightInPoints))
                window.contentView?.addSubview(band)
                window.orderFrontRegardless()
                t.pump(0.05)
                guard band.bounds.width == span else {
                    t.expect(false, desc: "the band stands at the width its lengths are read against")
                    return
                }

                // The first percent after the band appears has nowhere to
                // travel from, so it is drawn where it lands.
                report(band, state: 1, value: 20)
                t.expect(lengthSweep(of: band) == nil, desc: "a first determinate percent sets the length outright")
                t.expect(isLength(band.fillLayerForTesting.bounds.width, span * 0.2), desc: "and stands at that percent")

                report(band, state: 1, value: 70)
                guard let rise = lengthSweep(of: band) else {
                    t.expect(false, desc: "a second determinate percent sweeps the length")
                    return
                }
                t.expect(isLength(animationLength(rise.fromValue), span * 0.2), desc: "the sweep starts at the length it stood at")
                t.expect(isLength(animationLength(rise.toValue), span * 0.7), desc: "and ends at the one the percent asks for")
                t.expect(
                    isLength(band.fillLayerForTesting.bounds.width, span * 0.7),
                    desc: "while the layer itself stands at the new length"
                )
                t.expect(rise.duration == 0.25, desc: "the sweep takes a quarter of a second")
                t.expect(
                    rise.timingFunction == CAMediaTimingFunction(name: .easeInEaseOut),
                    desc: "and eases in and out of it"
                )

                // A percent that falls is a report like any other. A sweep
                // built to grow would leave this one stepping back.
                report(band, state: 1, value: 45)
                guard let fall = lengthSweep(of: band) else {
                    t.expect(false, desc: "a percent that falls sweeps as well")
                    return
                }
                t.expect(isLength(animationLength(fall.fromValue), span * 0.7), desc: "back from the length it stood at")
                t.expect(isLength(animationLength(fall.toValue), span * 0.45), desc: "to the lower one")

                // Pausing, erring and the comet each take the bar to a length
                // the percent did not ask for, so each is a step — and a sweep
                // still in flight from the report before it is dropped rather
                // than left to land after the colour has already changed.
                report(band, state: 4, value: 80)
                t.expect(lengthSweep(of: band) == nil, desc: "a pause steps to its held length")
                report(band, state: 2, value: 0)
                t.expect(lengthSweep(of: band) == nil, desc: "an error steps to its full bar")
                report(band, state: 3, value: 0)
                t.expect(lengthSweep(of: band) == nil, desc: "and the comet carries no length sweep of its own")

                report(band, state: 1, value: 50)
                t.expect(lengthSweep(of: band) == nil, desc: "the first percent after the comet sets the length outright")
                report(band, state: 1, value: 55)
                t.expect(
                    isLength(lengthSweep(of: band).flatMap { animationLength($0.fromValue) }, span * 0.5),
                    desc: "and the one after it sweeps from there"
                )

                // A withdrawn band is a band that appears again, so the percent
                // that raises it is a first one.
                report(band, state: 0, value: 0)
                t.expect(lengthSweep(of: band) == nil, desc: "a cleared report leaves no sweep behind")
                report(band, state: 1, value: 90)
                t.expect(lengthSweep(of: band) == nil, desc: "and the percent that raises the band again steps to it")
            }
        }

        // The three slots partition the cases, and a tab strip is where two of
        // them meet: the window's own band steps aside, the selected tab wears
        // the report on its pill, and a tab standing behind wears it as a ring
        // — because the panes it stands for are not on screen to carry it.
        UBUITestRegister("swift_shell_a_tab_strip_takes_the_report_off_the_content") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let first = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { first.tabGroup?.windows.forEach { $0.close() } }
                first.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                guard let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }
                surface.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait("ready-42").totalMatches > 0 }, timeout: 8),
                    desc: "the shell is up"
                )
                surface.transmitAsUserInputForTesting("printf '\\033]9;4;3;0\\007'\r")
                t.expect(
                    t.wait(until: { windowBand(of: shell).map { !$0.isHidden } ?? false }, timeout: 4),
                    desc: "a lone window carries the report in its own chrome"
                )

                // A second tab, selected, so the reporting one stands behind.
                shell.newWindowForTab(nil)
                guard t.wait(until: { (first.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20),
                    let group = first.tabGroup,
                    let second = group.windows.first(where: { $0 !== first })
                else {
                    t.expect(false, desc: "a second tab opens")
                    return
                }
                group.selectedWindow = second
                second.makeKeyAndOrderFront(nil)
                NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: first)
                NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: second)
                t.pump(0.4)

                t.expect(
                    t.wait(until: { windowBand(of: shell)?.isHidden ?? true }, timeout: 4),
                    desc: "and gives it up once there is a strip to carry it"
                )
                t.expect(
                    t.wait(until: { (first.tab.accessoryView as? TabStatusMark)?.isShowingProgress == true }, timeout: 4),
                    desc: "the tab standing behind wears it as a ring"
                )
                // The control: the selected tab has its panes on screen, so it
                // shows no ring for them.
                t.expect((second.tab.accessoryView as? TabStatusMark)?.isShowingProgress != true, desc: "and the selected tab wears none")

                // Bringing it forward hands the report to its pill.
                group.selectedWindow = first
                first.makeKeyAndOrderFront(nil)
                NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: second)
                NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: first)
                // The pill is found by a private traversal — the strip's glass
                // children, and the `active` flag on the tab button above one.
                // Asked as its own claim, because a band that never lands has
                // two explanations and only one of them is this shell's.
                let foundPill = t.wait(until: { TabStripStyling.activePillContent(inGroupOf: first) != nil }, timeout: 4)
                if !foundPill {
                    print(TabStripStyling.describeStrip(inGroupOf: first))
                }
                t.expect(foundPill, desc: "the traversal finds the selected tab's pill")
                t.expect(
                    t.wait(until: { stripBand(inGroupOf: first) != nil }, timeout: 4),
                    desc: "the selected tab wears it on its pill"
                )
                t.expect(
                    t.wait(until: { (first.tab.accessoryView as? TabStatusMark)?.isShowingProgress != true }, timeout: 4),
                    desc: "and drops the ring, so one report lights one slot"
                )

                // Which pill it is homed in, asked the only way a test can:
                // give the other tab a report too and select it, and the one
                // band must MOVE. A traversal that took whichever pill it met
                // first would leave it where it was.
                let firstHome = stripBand(inGroupOf: first)?.superview
                guard let secondController = second.windowController as? TerminalWindowController,
                    let secondPane = secondController.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "the second tab has a pane")
                    return
                }
                secondPane.transmitAsUserInputForTesting("k=7; echo \"second-${k}\"\r")
                t.expect(
                    t.wait(until: { secondPane.searchScrollbackAndWait("second-7").totalMatches > 0 }, timeout: 8),
                    desc: "the second tab's shell is up"
                )
                secondPane.transmitAsUserInputForTesting("printf '\\033]9;4;3;0\\007'\r")
                group.selectedWindow = second
                second.makeKeyAndOrderFront(nil)
                NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: first)
                NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: second)
                t.expect(
                    t.wait(until: { stripBand(inGroupOf: first).map { $0.superview !== firstHome } ?? false }, timeout: 6),
                    desc: "and the band follows the selection to the other tab's pill"
                )

                secondPane.transmitAsUserInputForTesting("printf '\\033]9;4;0;0\\007'\r")
                t.expect(
                    t.wait(until: { stripBand(inGroupOf: first) == nil }, timeout: 6),
                    desc: "a cleared report takes the pill's band away"
                )
            }
        }

        // The state behind a band left on the wrong tab, built rather than hoped
        // for. AppKit may keep the pills across a selection change instead of
        // rebuilding them, which leaves the band in a live pill that is no longer
        // the selected tab's; a desk rebuilds them and never shows it. So the
        // band is put in the other tab's pill by hand and the slot reconciled,
        // and it must end in the selected tab's pill on any machine.
        UBUITestRegister("swift_shell_a_band_left_in_a_deselected_pill_moves_to_the_selected_one") { context in
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
                    let group = first.tabGroup
                else {
                    t.expect(false, desc: "a second tab opens")
                    return
                }
                group.selectedWindow = first
                first.makeKeyAndOrderFront(nil)
                t.pump(0.4)

                let tint = NSColor.systemBlue
                TabButtonProgressBar.reconcile(in: first, state: 1, value: 40, tint: tint, isWanted: true)
                guard let band = stripBand(inGroupOf: first),
                    let selectedPill = TabStripStyling.activePillContent(inGroupOf: first)
                else {
                    print(TabStripStyling.describeStrip(inGroupOf: first))
                    t.expect(false, desc: "a wanted band is homed in the strip")
                    return
                }
                t.expect(band.superview === selectedPill, desc: "the band starts in the selected tab's pill")
                guard
                    let otherPill = TabStripStyling.pillContentsForTesting(inGroupOf: first)
                        .first(where: { !$0.isSelected })?
                        .content
                else {
                    t.expect(false, desc: "the strip has a pill for the tab that is not selected")
                    return
                }

                // The defect's state: the band left in a live pill that is not
                // the selected tab's.
                band.removeFromSuperview()
                otherPill.addSubview(band)
                t.expect(band.window != nil, desc: "the band stands in a live pill")
                TabButtonProgressBar.reconcile(in: first, state: 1, value: 50, tint: tint, isWanted: true)
                t.expect(
                    stripBand(inGroupOf: first)?.superview === TabStripStyling.activePillContent(inGroupOf: first),
                    desc: "reconciling moves the band into the selected tab's pill"
                )

                TabButtonProgressBar.reconcile(in: first, state: 0, value: 0, tint: tint, isWanted: false)
                t.expect(stripBand(inGroupOf: first) == nil, desc: "and a band no longer wanted leaves the strip")
            }
        }

        // A split tab's ring stands in for panes nobody can see, so it shows
        // the fold of all of them rather than the focused one's report. The
        // precedence is Core's: an error surfaces over everything, which is
        // the case a single pane cannot produce.
        UBUITestRegister("swift_shell_a_split_tabs_ring_folds_every_pane") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let first = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { first.tabGroup?.windows.forEach { $0.close() } }
                first.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                shell.splitRight(nil)
                t.expect(t.wait(until: { panes(of: shell).count == 2 }, timeout: 8), desc: "the window splits")
                let split = panes(of: shell)
                for pane in split {
                    pane.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
                }
                t.expect(
                    t.wait(
                        until: { split.allSatisfy { $0.searchScrollbackAndWait("ready-42").totalMatches > 0 } },
                        timeout: 12
                    ),
                    desc: "both panes have a shell"
                )
                // The FOCUSED pane runs and the other one errs. Which way
                // round matters: a fold that read the focused pane alone would
                // answer with a running fill, so only reaching every pane can
                // produce the error this asserts.
                guard let focused = shell.focusedSurfaceForTesting,
                    let unfocused = split.first(where: { $0 !== focused })
                else {
                    t.expect(false, desc: "the split has a focused pane and another")
                    return
                }
                focused.transmitAsUserInputForTesting("printf '\\033]9;4;1;70\\007'\r")
                unfocused.transmitAsUserInputForTesting("printf '\\033]9;4;2;0\\007'\r")

                shell.newWindowForTab(nil)
                guard t.wait(until: { (first.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20),
                    let group = first.tabGroup,
                    let second = group.windows.first(where: { $0 !== first })
                else {
                    t.expect(false, desc: "a second tab opens")
                    return
                }
                group.selectedWindow = second
                second.makeKeyAndOrderFront(nil)
                NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: first)
                NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: second)

                t.expect(
                    t.wait(
                        until: { (first.tab.accessoryView as? TabStatusMark)?.progressStateForTesting == 2 },
                        timeout: 6
                    ),
                    desc: "the ring shows the error one pane reported, over the other's running fill"
                )
            }
        }

        // A split pane wears its report on the bottom edge of its own header,
        // which stands at its height whether a report runs or not, so neither
        // the pane that reports nor the pane beside it moves a row. Each takes
        // its own pane's report and its own colour, which one bar across the
        // window could not do.
        UBUITestRegister("swift_shell_a_split_wears_each_report_in_its_panes_header_and_moves_no_text") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                shell.splitRight(nil)
                t.expect(t.wait(until: { panes(of: shell).count == 2 }, timeout: 8), desc: "the window splits")
                let split = panes(of: shell)
                guard split.count == 2 else { return }
                for pane in split {
                    pane.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
                }
                t.expect(
                    t.wait(
                        until: { split.allSatisfy { $0.searchScrollbackAndWait("ready-42").totalMatches > 0 } },
                        timeout: 12
                    ),
                    desc: "both panes have a shell"
                )
                t.expect(split.allSatisfy { header(of: $0).map { !$0.isHidden } ?? false }, desc: "both panes wear a header")
                t.pump(0.3)
                var samples = [placements(of: split)]

                // One pane reports and the other says nothing.
                split[1].transmitAsUserInputForTesting("printf '\\033]9;4;1;30\\007'\r")
                t.wait(until: { split[1].drive.readSnapshot().progressState == 1 }, timeout: 4)
                samples.append(settledPlacements(t, of: split, from: samples[0]))
                t.expect(
                    t.wait(until: { isShowingInHeader(split[1]) }, timeout: 4),
                    desc: "the reporting pane wears its bar along its own header's bottom edge"
                )
                t.expect(paneBand(over: split[0]).map { $0.isHidden } ?? true, desc: "and the pane beside it wears none")

                split[0].transmitAsUserInputForTesting("printf '\\033]9;4;2;0\\007'\r")
                t.wait(until: { split[0].drive.readSnapshot().progressState == 2 }, timeout: 4)
                samples.append(settledPlacements(t, of: split, from: samples[0]))
                t.expect(
                    t.wait(until: { isShowingInHeader(split[0]) }, timeout: 4),
                    desc: "a report in the other pane lights that pane's header"
                )
                let erring = paneBand(over: split[0])
                let running = paneBand(over: split[1])
                t.expect(
                    (erring.map { !$0.isDescendant(of: split[0]) } ?? false) && (running.map { !$0.isDescendant(of: split[1]) } ?? false),
                    desc: "each bar stands outside its pane's Metal subtree"
                )
                t.expect(erring != nil && erring !== running, desc: "and each pane has one of its own")
                // The colours separate a bar per pane from one across the
                // window: an error is red wherever it is, and the pane beside
                // it is only running.
                t.expect(erring?.tintColor == NSColor.systemRed, desc: "the erring pane's bar is red")
                t.expect(running.map { $0.tintColor != NSColor.systemRed } ?? false, desc: "and its neighbour's is not")

                // Clearing one leaves the other standing, which a shared bar
                // could not do.
                split[0].transmitAsUserInputForTesting("printf '\\033]9;4;0;0\\007'\r")
                t.expect(t.wait(until: { erring?.isHidden ?? false }, timeout: 8), desc: "a cleared pane drops its bar")
                t.expect(running.map { !$0.isHidden } ?? false, desc: "and its neighbour keeps the one it is still earning")
                samples.append(settledPlacements(t, of: split, from: samples[0]))

                split[1].transmitAsUserInputForTesting("printf '\\033]9;4;0;0\\007'\r")
                t.wait(until: { split[1].drive.readSnapshot().progressState == 0 }, timeout: 4)
                samples.append(settledPlacements(t, of: split, from: samples[0]))
                expectUnmoved(t, samples, names: ["the pane that erred", "the pane that ran"])
            }
        }

        // With pane headers turned off a split pane has no bar to draw in, so
        // its report overlays the pane's own top edge, from inside the frame
        // its chrome gives it; the pane's view keeps that whole frame.
        UBUITestRegister("swift_shell_a_headerless_split_pane_wears_its_report_over_its_top_edge") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                app.settingsSetPaneTitleBars(false)
                defer { app.settingsSetPaneTitleBars(true) }
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                shell.splitRight(nil)
                t.expect(t.wait(until: { panes(of: shell).count == 2 }, timeout: 8), desc: "the window splits")
                let split = panes(of: shell)
                guard split.count == 2 else { return }
                for pane in split {
                    pane.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
                }
                t.expect(
                    t.wait(
                        until: { split.allSatisfy { $0.searchScrollbackAndWait("ready-42").totalMatches > 0 } },
                        timeout: 12
                    ),
                    desc: "both panes have a shell"
                )
                t.expect(split.allSatisfy { header(of: $0).map { $0.isHidden } ?? true }, desc: "neither pane wears a header")
                t.pump(0.3)
                var samples = [placements(of: split)]

                split[0].transmitAsUserInputForTesting("printf '\\033]9;4;3;0\\007'\r")
                t.wait(until: { split[0].drive.readSnapshot().progressState == 3 }, timeout: 4)
                samples.append(settledPlacements(t, of: split, from: samples[0]))
                t.expect(
                    t.wait(until: { isOverlayingTopEdge(split[0]) }, timeout: 4),
                    desc: "the reporting pane wears its bar over its own top edge, inside the frame its view keeps whole"
                )
                t.expect(
                    paneBand(over: split[0]).map { !$0.isDescendant(of: split[0]) } ?? false,
                    desc: "and outside its Metal subtree"
                )
                t.expect(paneBand(over: split[1]).map { $0.isHidden } ?? true, desc: "and the pane beside it wears none")

                split[0].transmitAsUserInputForTesting("printf '\\033]9;4;0;0\\007'\r")
                t.wait(until: { split[0].drive.readSnapshot().progressState == 0 }, timeout: 4)
                t.expect(
                    t.wait(until: { paneBand(over: split[0])?.isHidden ?? false }, timeout: 4),
                    desc: "a cleared report withdraws the bar"
                )
                samples.append(settledPlacements(t, of: split, from: samples[0]))
                expectUnmoved(t, samples, names: ["the pane that reported", "the pane beside it"])
            }
        }

        // Pane Title Bars turned off and on again over an open split takes the
        // headers off and puts them back in place: each pane keeps the chrome
        // and the view it had, the view fills the frame its header gave up,
        // and a pane's report moves to the view's top edge and back. The
        // setting applies as it is written, so the headers have moved by the
        // time the setter returns.
        UBUITestRegister("swift_shell_pane_title_bars_follow_the_setting_on_an_open_split") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                app.settingsSetPaneTitleBars(true)
                defer { app.settingsSetPaneTitleBars(true) }
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                shell.splitRight(nil)
                t.expect(t.wait(until: { panes(of: shell).count == 2 }, timeout: 8), desc: "the window splits")
                let split = panes(of: shell)
                guard split.count == 2 else { return }
                split[0].transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
                t.expect(
                    t.wait(until: { split[0].searchScrollbackAndWait("ready-42").totalMatches > 0 }, timeout: 12),
                    desc: "the reporting pane has a shell"
                )
                let chromes = split.map { $0.superview.map(ObjectIdentifier.init) }
                @MainActor
                func isWearingHeaders() -> Bool {
                    split.allSatisfy { header(of: $0).map { !$0.isHidden } ?? false }
                }
                @MainActor
                func isHeaderless() -> Bool {
                    split.allSatisfy { pane in
                        (header(of: pane)?.isHidden ?? false) && pane.superview.map { pane.frame == $0.bounds } ?? false
                    }
                }
                t.expect(isWearingHeaders(), desc: "both panes of the split wear a header")

                split[0].transmitAsUserInputForTesting("printf '\\033]9;4;3;0\\007'\r")
                t.wait(until: { split[0].drive.readSnapshot().progressState == 3 }, timeout: 6)
                t.expect(
                    t.wait(until: { isShowingInHeader(split[0]) }, timeout: 4),
                    desc: "the reporting pane shows its report in its header"
                )

                app.settingsSetPaneTitleBars(false)
                t.expect(isHeaderless(), desc: "turning Pane Title Bars off takes both headers off, and each view fills its frame")
                t.expect(
                    split.map { $0.superview.map(ObjectIdentifier.init) } == chromes,
                    desc: "in place: each pane keeps the chrome it had"
                )
                t.expect(
                    t.wait(until: { isOverlayingTopEdge(split[0]) }, timeout: 4),
                    desc: "and the report moves over the reporting view's top edge"
                )

                app.settingsSetPaneTitleBars(true)
                t.expect(isWearingHeaders(), desc: "turning it on again puts both headers back")
                t.expect(
                    split.map { $0.superview.map(ObjectIdentifier.init) } == chromes,
                    desc: "in place again"
                )
                t.expect(
                    t.wait(until: { isShowingInHeader(split[0]) }, timeout: 4),
                    desc: "and the report returns to the reporting pane's header"
                )
                split[0].transmitAsUserInputForTesting("printf '\\033]9;4;0;0\\007'\r")
                t.wait(until: { split[0].drive.readSnapshot().progressState == 0 }, timeout: 4)
            }
        }

        // A window with its title bar hidden has no title row to hang the bar
        // from, so the bar overlays its pane's top edge, which there is the
        // window's own, and reserves nothing under it.
        UBUITestRegister("swift_shell_a_chromeless_window_wears_its_report_over_its_top_edge") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                shell.toggleHideTitleBar(nil)
                t.pump(0.4)
                t.expect(shell.isTitleBarHiddenForIdentity, desc: "the window hides its title bar")
                guard let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }
                surface.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait("ready-42").totalMatches > 0 }, timeout: 8),
                    desc: "the shell is up"
                )
                t.pump(0.3)
                var samples = [placements(of: [surface])]

                surface.transmitAsUserInputForTesting("printf '\\033]9;4;1;50\\007'\r")
                t.wait(until: { surface.drive.readSnapshot().progressState == 1 }, timeout: 4)
                samples.append(settledPlacements(t, of: [surface], from: samples[0]))
                t.expect(
                    t.wait(until: { windowBand(of: shell).map { !$0.isHidden } ?? false }, timeout: 4),
                    desc: "the report raises a bar"
                )
                let band = windowBand(of: shell)
                let overPane = shell.paneHost.convert(surface.bounds, from: surface)
                let paneTop = shell.paneHost.isFlipped ? overPane.minY : overPane.maxY
                let bandTop = band.map { shell.paneHost.isFlipped ? $0.frame.minY : $0.frame.maxY }
                t.expect(
                    band?.superview === shell.paneHost && isEdge(bandTop, paneTop),
                    desc:
                        "over the pane's top edge rather than in a title row the window does not show (bar \(describe(band?.frame)), pane \(describe(overPane)))"
                )
                t.expect(band.map { !$0.isDescendant(of: surface) } ?? false, desc: "and outside the Metal view's subtree")

                surface.transmitAsUserInputForTesting("printf '\\033]9;4;0;0\\007'\r")
                t.wait(until: { surface.drive.readSnapshot().progressState == 0 }, timeout: 4)
                t.expect(t.wait(until: { band?.isHidden ?? false }, timeout: 4), desc: "a cleared report withdraws the bar")
                samples.append(settledPlacements(t, of: [surface], from: samples[0]))
                expectUnmoved(t, samples, names: ["the pane"])
            }
        }
    }

    /// Puts one OSC 9;4 report on a band and applies it.
    ///
    /// A report is applied by a layout pass, so the pass is taken here rather
    /// than left to the caller: two reports with no pass between them reach the
    /// band as one, which reads as a bar that never swept.
    ///
    /// - Parameters:
    ///   - band: The band to report to.
    ///   - state: A `Ubiquitty::OSC::ProgressState`, as stored on the wire.
    ///   - value: The percent, 0 to 100.
    @MainActor
    private static func report(_ band: ProgressBar, state: UInt8, value: UInt8) {
        band.setState(state, value: value)
        band.layoutSubtreeIfNeeded()
    }

    /// The length animation a band's fill carries, if it carries one.
    ///
    /// Picked out by key rather than named, so a bar that travels its `bounds`
    /// and one that travels its `frame` both answer — what is being asked is
    /// whether the length is animated, not which of the two spellings says so.
    ///
    /// - Parameter band: The band to read.
    /// - Returns: The animation, or nil when the fill stands where it was put.
    @MainActor
    private static func lengthSweep(of band: ProgressBar) -> CABasicAnimation? {
        let fill = band.fillLayerForTesting
        guard
            let key = (fill.animationKeys() ?? []).first(where: { $0.contains("bounds") || $0.contains("frame") })
        else {
            return nil
        }
        return fill.animation(forKey: key) as? CABasicAnimation
    }

    /// One end of a length animation, in points.
    ///
    /// - Parameter end: A `fromValue` or `toValue`, as the animation stores it.
    /// - Returns: The length, or nil when the end carries something else.
    private static func animationLength(_ end: Any?) -> CGFloat? {
        (end as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    /// Whether a length is the one wanted, to within half a point.
    ///
    /// - Parameters:
    ///   - measured: The length read off the layer or the animation.
    ///   - wanted: The length the percent asks for.
    /// - Returns: `true` when they agree.
    private static func isLength(_ measured: CGFloat?, _ wanted: CGFloat) -> Bool {
        guard let measured else { return false }
        return abs(measured - wanted) < 0.5
    }

    /// Every terminal pane under a window, in the order the host holds them.
    ///
    /// - Parameter shell: The window to walk.
    /// - Returns: The panes.
    @MainActor
    private static func panes(of shell: TerminalWindowController) -> [TerminalSurface] {
        var found: [TerminalSurface] = []
        func walk(_ view: NSView) {
            if let surface = view as? TerminalSurface {
                found.append(surface)
                return
            }
            view.subviews.forEach(walk)
        }
        walk(shell.paneHost)
        return found
    }

    /// The band standing in a group's tab strip, if one is placed.
    ///
    /// Walked off the strip rather than asked of the component, because where
    /// it is homed is the claim: the pill is a view AppKit publishes nothing
    /// about, and a component that reported its own intent would pass with the
    /// band nowhere.
    ///
    /// - Parameter window: Any window of the group.
    /// - Returns: The band, or nil when none is placed.
    @MainActor
    private static func stripBand(inGroupOf window: NSWindow) -> ProgressBar? {
        guard let strip = TabStripStyling.tabStripView(inGroupOf: window) else { return nil }
        func walk(_ view: NSView) -> ProgressBar? {
            if let band = view as? ProgressBar { return band }
            for subview in view.subviews {
                if let found = walk(subview) { return found }
            }
            return nil
        }
        return walk(strip)
    }

    /// Where one pane's grid stands, as a reader would see it move.
    ///
    /// The rows and columns are the grid's own; the corner is its first
    /// cell's top-left, in points from the window frame's top-left, so a grid
    /// pushed down inside a pane that kept its frame and a pane pushed down
    /// with its grid both read as moved.
    private struct GridPlacement: Equatable, CustomStringConvertible {
        var rows: Int
        var columns: Int
        var left: Double
        var top: Double

        var description: String { "\(columns)x\(rows) at (\(left), \(top))" }
    }

    /// Where a pane's grid stands now.
    ///
    /// - Parameter surface: The pane to read.
    /// - Returns: The placement, or nil for a pane with no window or renderer.
    @MainActor
    private static func placement(of surface: TerminalSurface) -> GridPlacement? {
        guard let window = surface.window, let fit = surface.gridFitBoxForTesting else { return nil }
        let snapshot = surface.drive.readSnapshot()
        let inWindow = surface.convert(surface.bounds, to: nil)
        // To a hundredth of a point: the smallest move a reader sees is a
        // device pixel, and arithmetic noise is far below one.
        let rounded = { (value: CGFloat) in Double((value * 100).rounded()) / 100 }
        return GridPlacement(
            rows: Int(snapshot.rows),
            columns: Int(snapshot.columns),
            left: rounded(inWindow.minX + fit.insets.left),
            top: rounded(window.frame.height - inWindow.maxY + fit.insets.top)
        )
    }

    /// Where each of several panes' grids stands now, in their order.
    ///
    /// - Parameter panes: The panes to read.
    /// - Returns: One placement per pane.
    @MainActor
    private static func placements(of panes: [TerminalSurface]) -> [GridPlacement?] {
        panes.map { placement(of: $0) }
    }

    /// Where each pane's grid stands once a report has had time to move it.
    ///
    /// A grid that moves does so a pass or two after the report lands, once
    /// the chrome has reconciled and the panes have laid out again, so this
    /// waits up to a second for any of them to leave where it stood. A grid
    /// that never moves costs the second.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - panes: The panes to read.
    ///   - before: Where they stood before the report.
    /// - Returns: One placement per pane.
    @MainActor
    private static func settledPlacements(
        _ t: UBUITestContext,
        of panes: [TerminalSurface],
        from before: [GridPlacement?]
    ) -> [GridPlacement?] {
        t.wait(until: { placements(of: panes) != before }, timeout: 1.0)
        return placements(of: panes)
    }

    /// Asserts that each pane's grid stood in one place through every sample.
    ///
    /// One claim per pane across the whole report, because a grid that moves
    /// when the bar appears and moves back when it goes stands where it began
    /// at the end: only the samples taken while it ran can tell.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - samples: The placements read before, during and after, each in
    ///     the panes' order.
    ///   - names: What to call each pane in a failure.
    @MainActor
    private static func expectUnmoved(_ t: UBUITestContext, _ samples: [[GridPlacement?]], names: [String]) {
        for (index, name) in names.enumerated() {
            let track = samples.map { $0[index] }
            t.expect(
                track.allSatisfy { $0 != nil && $0 == track[0] },
                desc:
                    "\(name) keeps its rows, its columns and its place before, during and after the report (\(track.map { $0?.description ?? "none" }))"
            )
        }
    }

    /// Whether two edges, read off two views, are the same edge.
    ///
    /// - Parameters:
    ///   - measured: One edge, in points.
    ///   - wanted: The other.
    /// - Returns: `true` when both are known and within half a point.
    private static func isEdge(_ measured: CGFloat?, _ wanted: CGFloat?) -> Bool {
        guard let measured, let wanted else { return false }
        return abs(measured - wanted) < 0.5
    }

    /// A rectangle as a failure prints it, or a word for its absence.
    ///
    /// - Parameter rect: The rectangle.
    /// - Returns: Its description.
    private static func describe(_ rect: NSRect?) -> String {
        rect.map { "\($0)" } ?? "none"
    }

    /// The band a window wears for the pane that fills it, wherever its
    /// chrome puts it: on the title row's bottom edge, or over that pane's top
    /// edge where the window shows no title row.
    ///
    /// Looked for in both homes rather than asked of the controller, because
    /// where it lives is half of what this file pins; and only among their
    /// direct children, so the band a tab strip wears inside a pill is never
    /// taken for it.
    ///
    /// - Parameter shell: The window to look in.
    /// - Returns: The band, or nil before one is raised.
    @MainActor
    static func windowBand(of shell: TerminalWindowController) -> ProgressBar? {
        if let window = shell.window, let band = titleRowBand(of: window) {
            return band
        }
        return shell.paneHost.subviews.compactMap { $0 as? ProgressBar }.first
    }

    /// The band standing in a window's title row, if one is.
    ///
    /// - Parameter window: The window to look in.
    /// - Returns: The band, or nil when the title row holds none.
    @MainActor
    private static func titleRowBand(of window: NSWindow) -> ProgressBar? {
        titlebarStrip(of: window)?.subviews.compactMap { $0 as? ProgressBar }.first
    }

    /// The band a split pane wears, from inside the frame its chrome gives it.
    ///
    /// - Parameter surface: The pane.
    /// - Returns: The band, or nil when the pane's chrome holds none.
    @MainActor
    static func paneBand(over surface: TerminalSurface) -> ProgressBar? {
        (surface.superview as? PaneChrome)?.subviews.compactMap { $0 as? ProgressBar }.first
    }

    /// A pane's header, shown or not.
    ///
    /// - Parameter surface: The pane.
    /// - Returns: The header, or nil for a pane its chrome does not frame.
    @MainActor
    private static func header(of surface: TerminalSurface) -> NSView? {
        (surface.superview as? PaneChrome)?.subviews.first { $0.accessibilityIdentifier() == "pane.titleBar" }
    }

    /// Whether a pane's report is showing along its header's bottom edge,
    /// inside the height the header already has.
    ///
    /// - Parameter surface: The pane.
    /// - Returns: `true` when the band is up, in the header, at its lower edge.
    @MainActor
    private static func isShowingInHeader(_ surface: TerminalSurface) -> Bool {
        guard let band = paneBand(over: surface), !band.isHidden, let header = header(of: surface), !header.isHidden else {
            return false
        }
        // The chrome lays out unflipped, so the header's lower edge is its
        // minimum Y, and the edge it shares with the pane's view.
        return header.frame.contains(band.frame) && isEdge(band.frame.minY, header.frame.minY)
    }

    /// Whether a headerless pane's report overlays its top edge, from inside
    /// a frame the pane's view still fills.
    ///
    /// - Parameter surface: The pane.
    /// - Returns: `true` when the band is up at the top of the chrome and the
    ///   view keeps the chrome's whole bounds.
    @MainActor
    private static func isOverlayingTopEdge(_ surface: TerminalSurface) -> Bool {
        guard let chrome = surface.superview as? PaneChrome, let band = paneBand(over: surface), !band.isHidden else {
            return false
        }
        return isEdge(band.frame.maxY, chrome.bounds.maxY) && surface.frame == chrome.bounds
    }
}
