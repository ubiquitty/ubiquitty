// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// ScriptingScenarios.swift — what `tell application "Ubiquitty"` reaches on a
// Swift-shell window.
//
// The dictionary is structural and a gate already reads it (test_macos_
// applescript); what it cannot say is whether the terminology resolves to
// anything. So the command is driven in-process, the way an Apple Event drives
// it: the suite registry is asked for `do script`'s description, the instance
// it makes is the class the dictionary names, its `in` argument is an object
// specifier that has to be evaluated through the application's `windows`
// element, and the specifier it answers with is evaluated back.
//
// Two halves of the scripting surface: reading a window's visible screen,
// and putting a command line into one. Where that
// line lands is the second scenario's subject: the dictionary addresses a
// window and a tab and has no word for a pane, so a scripted line goes to the
// session it named and Broadcast Input does not widen it — which is a claim
// only a window in the mode can make, with a typed line from the same pane
// fanning out beside it.

/// Registers the scripting scenarios with the UI-test runner.
enum ScriptingScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_answers_the_scripting_dictionary") { context in
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

                // The dictionary's `window` and `tab` classes are these
                // classes: a wrapper Cocoa Scripting cannot place in the suite
                // answers no property at all.
                t.expect(
                    NSScriptClassDescription(for: ScriptableWindow.self)?.className == "window",
                    desc: "the dictionary's window class is the shell-agnostic wrapper"
                )
                t.expect(
                    NSScriptClassDescription(for: ScriptableTab.self)?.className == "tab",
                    desc: "and its tab class likewise"
                )

                guard let scriptable = NSApp.scriptableWindows.first(where: { $0.windowNumber == window.windowNumber })
                else {
                    t.expect(false, desc: "the Swift-shell window is among the application's scriptable windows")
                    return
                }

                surface.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait("ready-42").totalMatches > 0 }, timeout: 8),
                    desc: "the shell is up"
                )

                // `contents` is read through KVC, the way the scripting
                // machinery reads it.
                let contents = (scriptable.value(forKey: "scriptContents") as? String) ?? ""
                t.expect(contents.contains("ready-42"), desc: "the window's contents carry what the shell printed")
                let rows = contents.components(separatedBy: "\n")
                t.expect(
                    rows.count == surface.publishedGrid.rows,
                    desc: "one line per visible row (\(rows.count) of \(surface.publishedGrid.rows))"
                )
                t.expect(rows.allSatisfy { !$0.hasSuffix(" ") }, desc: "with trailing blanks trimmed")
                // The dictionary's two boolean properties, through the same
                // door: a key the sdef names and the class does not answer
                // reads as an unset property rather than as an error.
                t.expect(
                    (scriptable.value(forKey: "isScriptFrontmost") as? Bool) == window.isKeyWindow,
                    desc: "`frontmost` reads the window's key state"
                )

                // `do script`, driven through the command the dictionary names.
                guard
                    let description = NSScriptSuiteRegistry.shared()
                        .commandDescription(withAppleEventClass: code("UbqT"), andAppleEventCode: code("DScr"))
                else {
                    t.expect(false, desc: "the suite registry knows the `do script` command")
                    return
                }
                let command = description.createCommandInstance()
                t.expect(command is DoScriptCommand, desc: "and builds the command class the bridge defines")
                guard let tab = scriptable.scriptTabs.first, let tabSpecifier = tab.objectSpecifier else {
                    t.expect(false, desc: "the window's tab has an object specifier")
                    return
                }
                t.expect(
                    (tabSpecifier.objectsByEvaluatingSpecifier as? ScriptableTab)?.windowNumber == window.windowNumber,
                    desc: "the tab specifier resolves back through the application's windows"
                )
                t.expect(
                    (tab.value(forKey: "isScriptSelected") as? Bool) == true,
                    desc: "a lone window's one tab is the selected one"
                )
                command.directParameter = "echo scripted-$((6*7))"
                command.arguments = ["targetSession": tabSpecifier]
                let answer = command.execute()
                t.expect(command.scriptErrorNumber == 0, desc: "the command reports no error (\(command.scriptErrorNumber))")
                let answered = (answer as? NSScriptObjectSpecifier)?.objectsByEvaluatingSpecifier as? ScriptableTab
                t.expect(
                    answered?.windowNumber == window.windowNumber,
                    desc: "and answers with the tab it ran in"
                )
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait("scripted-42").totalMatches > 0 }, timeout: 8),
                    desc: "the command line ran in the session"
                )

                // The title round trip, through the same KVC door.
                scriptable.setValue("scripted name", forKey: "scriptTitle")
                t.pump(0.3)
                t.expect(
                    window.title.contains("scripted name"),
                    desc: "a scripted title names the window (\(window.title))"
                )
                t.expect(
                    (scriptable.value(forKey: "scriptTitle") as? String)?.contains("scripted name") ?? false,
                    desc: "and reads back"
                )
                scriptable.setValue("", forKey: "scriptTitle")
                t.pump(0.2)
                t.expect(!window.title.contains("scripted name"), desc: "an empty title clears it")
            }
        }

        UBUITestRegister("swift_shell_a_scripted_command_reaches_only_the_session_it_addressed") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let restoreBroadcast = BroadcastInputMemory.isBroadcasting()
                defer { BroadcastInputMemory.set(restoreBroadcast) }
                BroadcastInputMemory.set(false)

                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)

                shell.splitRight(nil)
                t.expect(
                    t.wait(until: { shell.projectedSurfaces.count == 2 }, timeout: 10),
                    desc: "the window has two panes (\(shell.projectedSurfaces.count))"
                )
                let panes = shell.projectedSurfaces
                for pane in panes {
                    pane.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
                }
                t.expect(
                    t.wait(
                        until: { panes.allSatisfy { $0.searchScrollbackAndWait("ready-42").totalMatches > 0 } },
                        timeout: 10
                    ),
                    desc: "both shells are up"
                )

                guard let addressed = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a focused pane")
                    return
                }
                let others = panes.filter { $0 !== addressed }
                t.expect(others.count == 1, desc: "and a pane beside the focused one (\(others.count))")

                // Broadcast is the discriminator, and it is on for both legs:
                // the scripted line reaches only the session the script could
                // name, and a typed line from that same pane reaches every
                // pane — which is how this leg is known to be measuring the
                // mode rather than an off switch.
                shell.toggleBroadcastInput(nil)
                t.pump(0.2)
                shell.sendScriptText("echo scripted-$((3*5))\r")
                t.expect(
                    t.wait(until: { addressed.searchScrollbackAndWait("scripted-15").totalMatches > 0 }, timeout: 10),
                    desc: "the scripted command line ran in the session the script addressed"
                )
                addressed.transmitAsUserInputForTesting("echo typed-$((3*5))\r")
                t.expect(
                    t.wait(
                        until: { others.allSatisfy { $0.searchScrollbackAndWait("typed-15").totalMatches > 0 } },
                        timeout: 10
                    ),
                    desc: "a typed line reaches every pane the mode broadcasts to"
                )
                t.expect(
                    others.allSatisfy { $0.searchScrollbackAndWait("scripted-15").totalMatches == 0 },
                    desc: "and the scripted line reached none of them"
                )
                shell.toggleBroadcastInput(nil)
                t.pump(0.2)
            }
        }
    }

    /// An Apple Event code packed from its four characters.
    ///
    /// - Parameter text: The four characters.
    /// - Returns: The packed code, which the event classes take.
    private static func code(_ text: String) -> UInt32 {
        text.utf8.reduce(UInt32(0)) { ($0 << 8) + UInt32($1) }
    }
}
