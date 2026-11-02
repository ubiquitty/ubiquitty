// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// TriggerScenarios.swift — a configured trigger acts in a Swift-shell window,
// and a program's banner leaves its mark on the tab.
//
// This shell could not install a `TriggerClient` or a `ShellClient`, because a
// Swift type cannot subclass a C++ class with virtual methods; Core queues what
// those clients would have heard and the window drains it. What is asked here
// is what reaches the reader through that route: the clipboard a `copy` rule
// fills, the title a `set_title` rule names, the banner a `notify` rule posts,
// the file a `run_command` rule's program touches — and that last one only
// once `allow_run_command` is open, which is the gate that separates a rule
// from arbitrary execution driven by whatever the program printed.
//
// Each typed line computes its text rather than spelling it (`k=42; echo
// "COPYME-${k}"`), so the echo of the command line itself matches no rule and
// every act is the output's.

/// Registers the trigger and notification scenarios with the UI-test runner.
enum TriggerScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_triggers_act_on_a_matched_line") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.applyTerminalPreferencesToOpenWindows()
                }
                let markerNumber = Int.random(in: 100_000...999_999)
                let marker = "/tmp/ubqtrigger\(markerNumber)"
                try? FileManager.default.removeItem(atPath: marker)
                defer { try? FileManager.default.removeItem(atPath: marker) }

                // Set before the window opens, so what compiles them is the
                // launch's own seed and not the reload below.
                let launchRules =
                    rule("COPYME-[0-9]+", "copy")
                    + rule("DEPLOY-[0-9]+", "set_title")
                    + rule("BUILD-FAILED-[0-9]+", "notify:Build")
                    + rule("/tmp/ubqtrigger[0-9]+", "run_command:/usr/bin/touch %s")
                t.configureAppending("[triggers]\nallow_run_command = false\n" + launchRules)

                // A plain sh: its prompt names no title, so the one a rule
                // sets is not replaced by the next prompt before it is read.
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window
                else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.4)
                guard let surface = shell.focusedSurfaceForTesting, let pane = shell.paneIdentifier(of: surface) else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }
                surface.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait("ready-42").totalMatches > 0 }, timeout: 8),
                    desc: "the shell is up"
                )

                // copy: the match, and only the match, on the clipboard.
                NSPasteboard.general.clearContents()
                surface.transmitAsUserInputForTesting("k=42; echo \"line COPYME-${k} trailing\"\r")
                t.expect(
                    t.wait(until: { NSPasteboard.general.string(forType: .string) == "COPYME-42" }, timeout: 8),
                    desc:
                        "a copy rule puts the match on the clipboard (\(NSPasteboard.general.string(forType: .string) ?? "nothing"))"
                )

                // set_title with no text of its own: the match names the pane.
                surface.transmitAsUserInputForTesting("k=7; echo \"DEPLOY-${k}\"\r")
                t.expect(
                    t.wait(until: { surface.title == "DEPLOY-7" }, timeout: 8),
                    desc: "a bare set_title rule names the pane after the match (\(surface.title))"
                )

                // notify: the match heads the banner, with the rule's text
                // beneath it as the sender, tagged with the pane that matched.
                surface.transmitAsUserInputForTesting("k=42; echo \"BUILD-FAILED-${k}\"\r")
                t.expect(
                    t.wait(until: { shell.lastBannerForTesting?.title == "BUILD-FAILED-42" }, timeout: 8),
                    desc: "a notify rule posts a banner headed by the match"
                )
                t.expect(
                    shell.lastBannerForTesting?.subtitle == "Build",
                    desc: "with the rule's text beneath it (\(shell.lastBannerForTesting?.subtitle ?? "none"))"
                )
                t.expect(shell.lastBannerForTesting?.paneID == pane, desc: "and tagged with the pane that matched")

                // run_command with the gate shut: the line matches, and nothing
                // runs. Watched for long enough that a spawn would have landed.
                surface.transmitAsUserInputForTesting("n=\(markerNumber); echo \"/tmp/ubqtrigger${n}\"; echo shut-${n}\r")
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait("shut-\(markerNumber)").totalMatches > 0 }, timeout: 8),
                    desc: "the shut-gate line is printed"
                )
                t.pump(1.0)
                t.expect(
                    !FileManager.default.fileExists(atPath: marker),
                    desc: "a run_command rule spawns nothing while allow_run_command is shut"
                )

                // Opened: the same line runs the program, with the match as its
                // argument.
                t.restoreConfiguration(saved)
                t.configureAppending("[triggers]\nallow_run_command = true\n" + launchRules)
                surface.transmitAsUserInputForTesting("n=\(markerNumber); echo \"/tmp/ubqtrigger${n}\"\r")
                t.expect(
                    t.wait(until: { FileManager.default.fileExists(atPath: marker) }, timeout: 8),
                    desc: "and once it is open, the program runs with the match as its argument"
                )

                // A reload recompiles the open window's rules: the old copy
                // rule stops firing and the new one starts.
                t.restoreConfiguration(saved)
                t.configureAppending("[triggers]\nallow_run_command = true\n" + rule("PASTEME-[0-9]+", "copy"))
                TerminalWindowController.applyTerminalPreferencesToOpenWindows()
                NSPasteboard.general.clearContents()
                surface.transmitAsUserInputForTesting("k=43; echo \"COPYME-${k}\"; k=44; echo \"PASTEME-${k}\"\r")
                t.expect(
                    t.wait(until: { NSPasteboard.general.string(forType: .string) == "PASTEME-44" }, timeout: 8),
                    desc:
                        "a reload's rule fires in the window already open (\(NSPasteboard.general.string(forType: .string) ?? "nothing"))"
                )
            }
        }

        // OSC 9 leaves a banner tagged with the pane, a Dock ask while the app
        // is away, and a dot on the tab until the reader looks.
        //
        // The harness cannot take key, so its window is one the reader is not
        // in — the state the dot exists for. The clearing half is the same
        // foreground fact the unseen-activity latch clears on, and no window
        // here can satisfy it.
        UBUITestRegister("swift_shell_a_notification_banners_marks_the_tab_and_asks_the_dock") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.4)
                guard let surface = shell.focusedSurfaceForTesting, let pane = shell.paneIdentifier(of: surface) else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }
                t.expect(!window.isKeyWindow, desc: "the harness's window cannot take key, so nobody is looking at it")
                surface.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait("ready-42").totalMatches > 0 }, timeout: 8),
                    desc: "the shell is up"
                )
                t.expect(!shell.hasUnseenNotification, desc: "no banner has been asked for yet")

                SessionAttention.clear()
                // OSC 9 carries a body and no title; the typed line spells
                // neither, so the banner is the output's.
                surface.transmitAsUserInputForTesting("printf '\\033]9;%s\\007' \"Build $((6*7)) done\"\r")
                t.expect(
                    t.wait(until: { shell.lastBannerForTesting != nil }, timeout: 8),
                    desc: "an OSC 9 notification posts a banner"
                )
                t.expect(
                    shell.lastBannerForTesting?.title == "Build 42 done" && shell.lastBannerForTesting?.subtitle == "",
                    desc: "whose body is promoted to its heading (\(shell.lastBannerForTesting?.title ?? "none"))"
                )
                t.expect(shell.lastBannerForTesting?.paneID == pane, desc: "tagged with the pane that asked")
                t.expect(
                    shell.lastBannerForTesting?.identifier.hasSuffix(".pane.\(pane)") == true,
                    desc: "and posted under the pane's own identifier, so its next banner replaces this one"
                )

                // OSC 99 sends a title and a body as two sequences under one
                // name: they are one banner, headed by the action, with the
                // sender beneath it, posted under the program's own name.
                surface.transmitAsUserInputForTesting(
                    "printf '\\033]99;i=b1:d=0;%s\\033\\\\\\033]99;i=b1:p=body;%s\\033\\\\' Sender \"Needs $((6*7)) answers\"\r"
                )
                t.expect(
                    t.wait(until: { shell.lastBannerForTesting?.title == "Needs 42 answers" }, timeout: 8),
                    desc: "a chunked OSC 99 posts one banner headed by its body (\(shell.lastBannerForTesting?.title ?? "none"))"
                )
                t.expect(
                    shell.lastBannerForTesting?.subtitle == "Sender",
                    desc: "with its title beneath as the sender (\(shell.lastBannerForTesting?.subtitle ?? "none"))"
                )
                t.expect(
                    shell.lastBannerForTesting?.identifier.hasSuffix(".pane.\(pane).name.b1") == true,
                    desc: "under the name the program gave it (\(shell.lastBannerForTesting?.identifier ?? "none"))"
                )

                // A reader looking at the pane that asks gets no banner: the
                // one standing is still the last one posted.
                var looking = Ubiquitty.OSC.BannerAudience()
                looking.isAppActive = true
                looking.isWindowKey = true
                looking.isPaneFocused = true
                looking.isPaneVisible = true
                shell.postBanner(title: "", body: "Seen as it was printed", from: surface, audience: looking)
                t.expect(
                    shell.lastBannerForTesting?.title == "Needs 42 answers",
                    desc: "a pane the reader is looking at posts no banner (\(shell.lastBannerForTesting?.title ?? "none"))"
                )

                t.expect(shell.hasUnseenNotification, desc: "a banner nobody was looking at marks the tab")
                guard let dots = window.tab.accessoryView as? TabAttentionDots else {
                    t.expect(false, desc: "and the strip carries the notification dot")
                    return
                }
                // One dot in the system's blue, not the three dim ones unread
                // output earns: the banner outranks the output that carried it.
                t.expect(dots.dotCount == 1, desc: "one dot, not the activity ellipsis (\(dots.dotCount))")
                t.expect(dots.tintColor == NSColor.systemBlue, desc: "in the system's blue")

                // The Dock is asked exactly when the reader is elsewhere.
                if NSApp.isActive {
                    t.expect(!SessionAttention.isBadgeShowing, desc: "an active app takes no Dock badge")
                } else {
                    t.expect(SessionAttention.isBadgeShowing, desc: "an app the reader is away from takes the Dock")
                }
                SessionAttention.clear()
            }
        }
    }

    /// Registers the `[scripting]` hook scenario.
    ///
    /// Apart from the two above because it configures Core from documents of
    /// its own, as a load does, and restores the document that was live.
    static func registerScriptingHook() {
        // A config script's rules join the configuration only once the gate is
        // open, and a trigger rule it prints is live in a Swift-shell pane. A
        // script that never stops printing is ended at the bound rather than
        // holding the load open.
        UBUITestRegister("swift_shell_a_config_script_s_rules_reach_a_swift_pane") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let savedDocument = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer {
                    _ = Ubiquitty.Preferences.configureScriptOutput(std.string())
                    _ = Ubiquitty.Preferences.configure(std.string(savedDocument), .Permissive)
                }
                // The live document with a `[scripting]` table of the test's.
                func configureScripting(enabled: Bool, program: URL) {
                    let document = savedDocument + "\n[scripting]\nenable = \(enabled)\nconfig_script = \"\(program.path)\"\n"
                    _ = Ubiquitty.Preferences.configure(std.string(document), .Permissive)
                }

                let directory = FileManager.default.temporaryDirectory
                let script = directory.appendingPathComponent("ubq-rules-\(UUID().uuidString).sh")
                let runaway = directory.appendingPathComponent("ubq-runaway-\(UUID().uuidString).sh")
                let silent = directory.appendingPathComponent("ubq-silent-\(UUID().uuidString).sh")
                defer {
                    try? FileManager.default.removeItem(at: script)
                    try? FileManager.default.removeItem(at: runaway)
                    try? FileManager.default.removeItem(at: silent)
                }
                let wrote =
                    writeExecutable(script, "#!/bin/sh\necho '# emitted by the test'\necho 'trigger HOOKED-[0-9]+ = copy'\n")
                    && writeExecutable(runaway, "#!/bin/sh\nexec yes '# filler that never ends'\n")
                    && writeExecutable(silent, "#!/bin/sh\nexec sleep 45\n")
                t.expect(wrote, desc: "the three scripts are written")

                // Named but not enabled: the gate is shut and nothing runs.
                configureScripting(enabled: false, program: script)
                let before = Ubiquitty.Preferences.values().pointee.triggers.size()
                t.expect(ScriptingHook.run() == 0, desc: "a script behind a shut gate merges nothing")
                t.expect(
                    Ubiquitty.Preferences.values().pointee.triggers.size() == before,
                    desc: "and the configuration keeps only its own rules"
                )

                // Open: its rule is the configuration's.
                configureScripting(enabled: true, program: script)
                t.expect(ScriptingHook.run() == 1, desc: "an open gate merges the one rule the script printed")
                let merged = Ubiquitty.Preferences.values().pointee.triggers
                t.expect(
                    merged.size() == before + 1 && merged.last.map { String($0.pattern) } == "HOOKED-[0-9]+",
                    desc: "after the rules the file declared"
                )
                // A by-key edit re-parses the document; the script's rule is
                // Core's to keep, not the edit's to drop.
                _ = Ubiquitty.Preferences.configure(Ubiquitty.Preferences.liveDocument().pointee, .Permissive)
                t.expect(
                    Ubiquitty.Preferences.values().pointee.triggers.size() == before + 1,
                    desc: "and a re-configure of the same document keeps it"
                )

                // And live in a Swift-shell pane: the launch compiles it.
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window
                else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.4)
                guard let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }
                NSPasteboard.general.clearContents()
                surface.transmitAsUserInputForTesting("k=42; echo \"HOOKED-${k}\"\r")
                t.expect(
                    t.wait(until: { NSPasteboard.general.string(forType: .string) == "HOOKED-42" }, timeout: 8),
                    desc:
                        "the script's trigger fires in the pane (\(NSPasteboard.general.string(forType: .string) ?? "nothing"))"
                )

                // A script that never stops is ended at the bound, and what it
                // printed names no rule.
                configureScripting(enabled: true, program: runaway)
                let started = Date()
                t.expect(ScriptingHook.run() == 0, desc: "a runaway script merges nothing")
                t.expect(
                    Date().timeIntervalSince(started) < 10,
                    desc: "and is ended at the bound rather than read forever"
                )

                // A script that stops writing without closing its output holds
                // the read open for as long as it lives; the deadline ends it,
                // so the load this runs on is not the script's to hold.
                configureScripting(enabled: true, program: silent)
                let waitedFrom = Date()
                t.expect(ScriptingHook.run() == 0, desc: "a silent script merges nothing")
                t.expect(
                    Date().timeIntervalSince(waitedFrom) < 25,
                    desc: "and is ended at the deadline rather than outliving the load"
                )
            }
        }
    }

    /// Writes a script and marks it executable.
    ///
    /// - Parameters:
    ///   - url: Where.
    ///   - text: The script.
    /// - Returns: Whether both succeeded.
    private static func writeExecutable(_ url: URL, _ text: String) -> Bool {
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8)) else { return false }
        return (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)) != nil
    }

    /// A trigger rule as the config spells it: one `[triggers]` line.
    ///
    /// - Parameters:
    ///   - pattern: What a completed line has to contain.
    ///   - action: The action spec, `name` or `name:argument`.
    /// - Returns: The line, newline included.
    private static func rule(_ pattern: String, _ action: String) -> String {
        "\(tomlQuoted(pattern)) = \(tomlQuoted(action))\n"
    }
}
