// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// TabStatusHintOffScenarios.swift — the tab's trailing slot with the ⌘N hint
// turned off.
//
// With no number to fall back to, the slot carries the tab's status, on the
// selected tab as on the rest. Each leg drives a real shell in a real tab
// group and reads the slot AppKit holds: the status dot on a selected tab, no
// ellipsis for unread output, no ring on the selected tab whose pill draws the
// bar, and a bell that stays on the selected tab of a window that was not key
// until the window is activated.

/// Registers the hint-off tab-slot scenarios with the UI-test runner.
enum TabStatusHintOffScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("tab_slot_with_hints_off_shows_the_status_dot_on_every_tab") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withHintsOff(t) { pair in
                    pair.surface.transmitAsUserInputForTesting("printf '\\033]21337;indicator=#FF8800\\007'\r")
                    t.expect(
                        t.wait(until: { isStatusDot(pair.first.tab.accessoryView) }, timeout: 6),
                        desc: "the tab behind shows its status dot (\(describe(pair.first)))"
                    )
                    select(pair.first, over: pair.second, in: pair.group)
                    t.pump(0.6)
                    t.expect(
                        isStatusDot(pair.first.tab.accessoryView),
                        desc: "and keeps it once selected, where its number would be (\(describe(pair.first)))"
                    )
                    let dot = pair.first.tab.accessoryView as? TabAttentionDots
                    let ink = dot?.tintColor.usingColorSpace(.sRGB)
                    t.expect(
                        ink.map { Int(($0.redComponent * 255).rounded()) == 0xFF && Int(($0.greenComponent * 255).rounded()) == 0x88 }
                            ?? false,
                        desc: "in the colour the program set"
                    )
                }
            }
        }

        UBUITestRegister("tab_program_status_shows_its_symbol_in_the_themes_colour") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withHintsOff(t) { pair in
                    let states: [(String, String)] = [
                        ("done", "checkmark.circle.fill"),
                        ("error", "xmark.octagon.fill"),
                        ("blocked", "questionmark.bubble.fill"),
                        ("blocked:kind=question", "questionmark.bubble.fill"),
                        ("blocked:kind=permission", "hand.raised.fill"),
                        ("blocked:kind=auth", "key.fill"),
                    ]
                    for (state, symbol) in states {
                        pair.surface.transmitAsUserInputForTesting("printf '\\033]7501;id=test:state=\(state)\\033\\\\'; sleep 2\r")
                        t.expect(
                            t.wait(
                                until: {
                                    guard let mark = pair.first.tab.accessoryView as? TabStatusMark, mark.symbolName == symbol else {
                                        return false
                                    }
                                    return wearsThemeStatusColour(mark.ink, of: pair.surface)
                                },
                                timeout: 6
                            ),
                            desc: "OSC 7501 \(state) shows \(symbol) in the theme's colour for it (\(describe(pair.first)))"
                        )
                        t.expect(
                            t.wait(until: { (pair.first.tab.accessoryView as? TabStatusMark)?.isGlowing == true }, timeout: 3),
                            desc: "and glows, unseen behind another tab"
                        )
                        t.pump(2.1)
                    }
                    pair.surface.transmitAsUserInputForTesting("printf '\\033]7501;id=test:state=working\\033\\\\'; sleep 2\r")
                    t.expect(
                        t.wait(
                            until: {
                                guard let mark = pair.first.tab.accessoryView as? TabStatusMark else { return false }
                                return mark.symbolName == "ellipsis" && mark.isShowingProgress
                            },
                            timeout: 6
                        ),
                        desc: "OSC 7501 working shows the ellipsis, as progress of unknown length does (\(describe(pair.first)))"
                    )
                    t.pump(2.1)
                }
            }
        }

        UBUITestRegister("tab_working_program_shows_the_ellipsis_and_a_report_the_indicator") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withHintsOff(t) { pair in
                    // One program, so the working record lasts through every
                    // phase: the last sleep outlasts the wait for the ellipsis
                    // after the clear, which a loaded machine can see late.
                    runAsOneProgram(
                        #"printf '\033]7501;id=test:state=working\033\\\\'; sleep 3; printf '\033]9;4;3;0\007'; sleep 3; "#
                            + #"printf '\033]9;4;1;40\007'; sleep 3; printf '\033]9;4;0;0\007'; sleep 8"#,
                        in: pair.surface
                    )
                    let mark = { pair.first.tab.accessoryView as? TabStatusMark }
                    t.expect(
                        t.wait(until: { mark()?.symbolName == "ellipsis" }, timeout: 2.5),
                        desc: "a working program with no report of its own shows the ellipsis (\(describe(pair.first)))"
                    )
                    t.expect(
                        t.wait(until: { mark().map { $0.symbolName == nil && $0.progressStateForTesting == 3 } ?? false }, timeout: 3.5),
                        desc: "progress of unknown length reported over it shows the spinning indicator (\(describe(pair.first)))"
                    )
                    t.expect(
                        t.wait(until: { mark().map { $0.symbolName == nil && $0.progressStateForTesting == 1 } ?? false }, timeout: 3.5),
                        desc: "and a percent, the filling one (\(describe(pair.first)))"
                    )
                    t.expect(
                        t.wait(until: { mark()?.symbolName == "ellipsis" }, timeout: 6),
                        desc: "the report cleared, the still working program's ellipsis is back (\(describe(pair.first)))"
                    )
                    t.pump(3.5)
                }
            }
        }

        UBUITestRegister("tab_working_program_with_a_percent_fills_the_ring") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withHintsOff(t) { pair in
                    // One program, so the working record outlives every phase.
                    runAsOneProgram(
                        #"printf '\033]7501;id=test:state=working:progress=40\033\\\\'; sleep 3; "#
                            + #"printf '\033]7501;id=test:state=working\033\\\\'; sleep 3"#,
                        in: pair.surface
                    )
                    let mark = { pair.first.tab.accessoryView as? TabStatusMark }
                    t.expect(
                        t.wait(until: { mark().map { $0.symbolName == nil && $0.progressStateForTesting == 1 } ?? false }, timeout: 2.5),
                        desc: "a working record with a percent shows the filling ring, not the ellipsis (\(describe(pair.first)))"
                    )
                    t.expect(
                        t.wait(until: { mark()?.symbolName == "ellipsis" }, timeout: 3.5),
                        desc: "and the same record without one, the ellipsis (\(describe(pair.first)))"
                    )
                    t.pump(3.5)
                }
            }
        }

        UBUITestRegister("tab_status_arriving_in_view_is_seen_at_once") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withHintsOff(t) { pair in
                    select(pair.first, over: pair.second, in: pair.group)
                    t.pump(0.4)
                    pair.surface.transmitAsUserInputForTesting("printf '\\033]7501;id=test:state=error\\033\\\\'\r")
                    t.expect(
                        t.wait(until: { (pair.first.tab.accessoryView as? TabStatusMark)?.symbolName == "xmark.octagon.fill" }, timeout: 6),
                        desc: "with hints off, the selected tab carries its failure (\(describe(pair.first)))"
                    )
                    t.pump(1.0)
                    t.expect(
                        (pair.first.tab.accessoryView as? TabStatusMark)?.isGlowing == false,
                        desc: "and does not glow: it arrived where the reader was looking"
                    )
                    select(pair.second, over: pair.first, in: pair.group)
                    t.pump(1.0)
                    t.expect(
                        (pair.first.tab.accessoryView as? TabStatusMark)?.isGlowing == false,
                        desc: "nor once another tab is selected: it was seen (\(describe(pair.first)))"
                    )
                    pair.surface.transmitAsUserInputForTesting("printf '\\033]7501;state=clear\\033\\\\'\r")
                }
            }
        }

        UBUITestRegister("tab_working_in_the_selected_tab_leaves_its_progress_to_the_bar") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withHintsOff(t) { pair in
                    select(pair.first, over: pair.second, in: pair.group)
                    t.pump(0.4)
                    pair.surface.transmitAsUserInputForTesting("printf '\\033]7501;id=test:state=working\\033\\\\'; sleep 5\r")
                    t.expect(
                        t.wait(until: { stripBand(inGroupOf: pair.first) != nil }, timeout: 2.5),
                        desc: "a working program's tab, selected, shows the bar in its pill"
                    )
                    t.expect(
                        (pair.first.tab.accessoryView as? TabStatusMark)?.symbolName == nil,
                        desc: "and no ellipsis beside it (\(describe(pair.first)))"
                    )
                    select(pair.second, over: pair.first, in: pair.group)
                    t.expect(
                        t.wait(until: { (pair.first.tab.accessoryView as? TabStatusMark)?.symbolName == "ellipsis" }, timeout: 2),
                        desc: "behind another tab, the ellipsis carries it (\(describe(pair.first)))"
                    )
                    t.pump(3.5)
                }
            }
        }

        UBUITestRegister("tab_program_status_stops_glowing_once_its_tab_is_seen") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withHintsOff(t) { pair in
                    pair.surface.transmitAsUserInputForTesting("printf '\\033]7501;id=test:state=error\\033\\\\'\r")
                    t.expect(
                        t.wait(until: { (pair.first.tab.accessoryView as? TabStatusMark)?.isGlowing == true }, timeout: 6),
                        desc: "a failure behind another tab glows (\(describe(pair.first)))"
                    )
                    select(pair.first, over: pair.second, in: pair.group)
                    t.pump(0.6)
                    select(pair.second, over: pair.first, in: pair.group)
                    t.expect(
                        t.wait(
                            until: {
                                guard let mark = pair.first.tab.accessoryView as? TabStatusMark else { return false }
                                return mark.symbolName == "xmark.octagon.fill" && !mark.isGlowing
                            },
                            timeout: 6
                        ),
                        desc: "and once seen, keeps its symbol without the glow (\(describe(pair.first)))"
                    )
                    pair.surface.transmitAsUserInputForTesting("printf '\\033]7501;state=clear\\033\\\\'\r")
                }
            }
        }

        UBUITestRegister("tab_slot_with_hints_off_shows_no_ellipsis_for_unread_output") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withHintsOff(t) { pair in
                    pair.surface.transmitAsUserInputForTesting("for i in 1 2 3; do echo \"unread-$i\"; sleep 0.2; done\r")
                    t.expect(
                        t.wait(until: { pair.controller.hasUnseenActivity }, timeout: 6),
                        desc: "the tab behind has unread output"
                    )
                    t.pump(0.8)
                    t.expect(
                        !isActivityDots(pair.first.tab.accessoryView) && isEmptySlot(pair.first.tab.accessoryView),
                        desc: "and its slot shows no ellipsis (\(describe(pair.first)))"
                    )
                    pair.surface.transmitAsUserInputForTesting("printf '\\033]21337;indicator=#33AA55\\007'\r")
                    t.expect(
                        t.wait(until: { isStatusDot(pair.first.tab.accessoryView) }, timeout: 6),
                        desc: "a status the program sets is what the slot shows (\(describe(pair.first)))"
                    )
                }
            }
        }

        UBUITestRegister("tab_slot_with_hints_off_leaves_the_selected_tabs_progress_to_the_bar") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withHintsOff(t) { pair in
                    select(pair.first, over: pair.second, in: pair.group)
                    t.pump(0.4)
                    pair.surface.transmitAsUserInputForTesting("printf '\\033]9;4;3;0\\007'\r")
                    t.expect(
                        t.wait(until: { stripBand(inGroupOf: pair.first) != nil }, timeout: 6),
                        desc: "the selected tab's pill draws the horizontal bar"
                    )
                    t.pump(0.4)
                    t.expect(
                        (pair.first.tab.accessoryView as? TabStatusMark)?.isShowingProgress != true
                            && isEmptySlot(pair.first.tab.accessoryView),
                        desc: "and its slot shows no spinner beside it (\(describe(pair.first)))"
                    )
                    select(pair.second, over: pair.first, in: pair.group)
                    t.expect(
                        t.wait(until: { (pair.first.tab.accessoryView as? TabStatusMark)?.isShowingProgress == true }, timeout: 6),
                        desc: "behind another tab, the job's ring is back in the slot (\(describe(pair.first)))"
                    )
                    pair.surface.transmitAsUserInputForTesting("printf '\\033]9;4;0;0\\007'\r")
                }
            }
        }

        UBUITestRegister("tab_slot_with_hints_off_keeps_a_bell_until_the_window_is_activated") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withHintsOff(t) { pair in
                    select(pair.first, over: pair.second, in: pair.group)
                    pair.controller.isKeyWindowForTesting = false
                    defer { pair.controller.isKeyWindowForTesting = nil }
                    t.pump(0.4)
                    pair.surface.transmitAsUserInputForTesting("printf '\\a'\r")
                    t.expect(
                        t.wait(until: { pair.controller.hasUnheardBell }, timeout: 8),
                        desc: "a bell in the selected tab of a window that is not key goes unheard"
                    )
                    t.expect(
                        t.wait(until: { (pair.first.tab.accessoryView as? TabStatusMark)?.symbolName == "bell.fill" }, timeout: 4),
                        desc: "and the selected tab keeps its mark (\(describe(pair.first)))"
                    )
                    t.pump(0.6)
                    t.expect(
                        (pair.first.tab.accessoryView as? TabStatusMark)?.symbolName == "bell.fill",
                        desc: "for as long as the window stays inactive"
                    )

                    pair.controller.isKeyWindowForTesting = true
                    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: pair.first)
                    t.expect(
                        t.wait(
                            until: {
                                !pair.controller.hasUnheardBell
                                    && (pair.first.tab.accessoryView as? TabStatusMark)?.symbolName != "bell.fill"
                            },
                            timeout: 4
                        ),
                        desc: "activating the window answers the bell and takes the mark away (\(describe(pair.first)))"
                    )
                }
            }
        }
    }

    /// Two tabs of one group with the hint turned off: the first, whose shell
    /// a leg drives, standing behind the second.
    @MainActor
    private struct Pair {
        let controller: TerminalWindowController
        let first: NSWindow
        let second: NSWindow
        let group: NSWindowTabGroup
        let surface: TerminalSurface
    }

    /// Runs a leg on a fresh pair with the hint turned off, and puts the
    /// setting and the windows back afterwards.
    @MainActor
    private static func withHintsOff(_ t: UBUITestContext, _ leg: (Pair) -> Void) {
        guard let app = NSApp.delegate as? UBAppDelegate else {
            t.expect(false, desc: "the app delegate answers")
            return
        }
        let hadMode = Int(
            Ubiquitty.Preferences.tabShortcutHintsToInt(
                Ubiquitty.Preferences.Effective.tabShortcutHints(Ubiquitty.Preferences.values().pointee)
            )
        )
        app.settingsSetTabShortcutHintMode(Int(Ubiquitty.Preferences.tabShortcutHintsToInt(.Off)))
        TerminalWindowController.refreshTabAccessoriesForOpenWindows()
        defer {
            app.settingsSetTabShortcutHintMode(hadMode)
            TerminalWindowController.refreshTabAccessoriesForOpenWindows()
        }
        guard let shell = TerminalWindowController.spawn(), let first = shell.window else {
            t.expect(false, desc: "a Swift-shell window opens")
            return
        }
        defer { first.tabGroup?.windows.forEach { $0.close() } }
        first.setContentSize(NSSize(width: 620, height: 220))
        t.pump(0.4)
        guard let surface = shell.focusedSurfaceForTesting else {
            t.expect(false, desc: "the window has a pane")
            return
        }
        surface.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
        guard t.wait(until: { surface.searchScrollbackAndWait("ready-42").totalMatches > 0 }, timeout: 8) else {
            t.expect(false, desc: "the shell is up")
            return
        }
        shell.newWindowForTab(nil)
        guard t.wait(until: { (first.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20),
            let group = first.tabGroup,
            let second = group.windows.first(where: { $0 !== first })
        else {
            t.expect(false, desc: "a second tab opens")
            return
        }
        select(second, over: first, in: group)
        t.pump(0.6)
        leg(Pair(controller: shell, first: first, second: second, group: group, surface: surface))
    }

    /// Types a line that runs `commands` as one program, under `sh`.
    ///
    /// Under a shell that marks no prompt, a working record ends when the
    /// pane sees the shell take the terminal back, and an interactive shell
    /// takes it back between the commands of one line. One program holds the
    /// terminal from its first report to its last, as the program a working
    /// record stands for does.
    ///
    /// - Parameters:
    ///   - commands: The program's commands. They are typed inside double
    ///     quotes, so a backslash the program reads is written twice.
    ///   - surface: The pane whose shell runs the line.
    @MainActor
    private static func runAsOneProgram(_ commands: String, in surface: TerminalSurface) {
        surface.transmitAsUserInputForTesting("sh -c \"" + commands + "\"\r")
    }

    /// Selects a tab the way the strip does, and tells both windows.
    @MainActor
    private static func select(_ window: NSWindow, over other: NSWindow, in group: NSWindowTabGroup) {
        group.selectedWindow = window
        NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: other)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
    }

    @MainActor
    private static func isStatusDot(_ view: NSView?) -> Bool {
        (view as? TabAttentionDots)?.dotCount == 1
    }

    @MainActor
    private static func isActivityDots(_ view: NSView?) -> Bool {
        (view as? TabAttentionDots)?.dotCount == 3
    }

    /// Whether `ink` is the colour Core resolved for the pane's status: its
    /// theme's colour for that status.
    @MainActor
    private static func wearsThemeStatusColour(_ ink: NSColor?, of surface: TerminalSurface) -> Bool {
        let status = surface.drive.tabStatusColor()
        guard status.isSet, let ink = ink?.usingColorSpace(.sRGB) else { return false }
        let channels = [ink.redComponent, ink.greenComponent, ink.blueComponent].map { Int(($0 * 255).rounded()) }
        return channels == [Int(status.red), Int(status.green), Int(status.blue)]
    }

    /// Whether a slot shows nothing: no view, or the hint label holding no
    /// text.
    @MainActor
    private static func isEmptySlot(_ view: NSView?) -> Bool {
        guard let view else { return true }
        return (view as? NSTextField).map { $0.stringValue.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
    }

    /// The band the strip draws in the selected tab's pill, if any.
    @MainActor
    private static func stripBand(inGroupOf window: NSWindow) -> ProgressBar? {
        guard let content = TabStripStyling.activePillContent(inGroupOf: window) else { return nil }
        var stack: [NSView] = [content]
        while let view = stack.popLast() {
            if let band = view as? ProgressBar {
                return band
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// One line for what a tab's slot holds.
    @MainActor
    private static func describe(_ window: NSWindow) -> String {
        switch window.tab.accessoryView {
        case nil: "none"
        case let dots as TabAttentionDots: "dots(\(dots.dotCount))"
        case let mark as TabStatusMark: mark.isShowingProgress ? "ring" : "mark(\(mark.symbolName ?? ""))"
        case let label as NSTextField: "hint'\(label.stringValue)'"
        case let view?: "\(type(of: view))"
        }
    }
}
