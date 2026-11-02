// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// SessionClipboardScenarios.swift — what a program in a local pane writes to the
// clipboard reaches the pasteboard through the session's clipboard client: an
// OSC 52 write lands as the pasteboard's text, and an OSC 5522 write lands as
// typed items, each under the pasteboard type its MIME maps to; and an OSC 5522
// read hands the program back the item it asked for.
//
// The reads go the same way and are asked by ConsentPromptScenarios
// (swift_osc52_allow_once_delivers_each_reply_and_asks_again). The pasteboard
// here is the run's private board (PasteboardIsolation.swift), never the
// operator's.

/// Registers the session clipboard scenarios with the UI-test runner.
enum SessionClipboardScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_clipboard_writes_reach_the_pasteboard") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = t.configureAppending("[security]\nclipboard_write = \"allow\"\n")
                defer { t.restoreConfiguration(saved) }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard let shell = t.newWindowRunning(["/bin/bash", "--noprofile", "--norc"]) else {
                    t.expect(false, desc: "a shell opens for the clipboard writes")
                    return
                }
                defer { shell.window?.close() }

                // OSC 52 to the clipboard selection: the pasteboard's text.
                t.sendText("printf '\\033]52;c;VUJRLU9TQzUyLVRFWFQ=\\033\\\\'\r", to: shell)
                t.expect(
                    t.wait(until: { pasteboard.string(forType: .string) == "UBQ-OSC52-TEXT" }, timeout: 8),
                    desc: "an OSC 52 write lands as the pasteboard's text (\(pasteboard.string(forType: .string) ?? "nothing"))"
                )

                // OSC 5522: a write session of two typed items, then the commit.
                t.sendText(
                    "printf '\\033]5522;type=write\\033\\\\\\033]5522;type=wdata:mime=dGV4dC9wbGFpbg==;VUJRLTU1MjItVEVYVA==\\033\\\\"
                        + "\\033]5522;type=wdata:mime=dGV4dC9odG1s;PGI+VUJRLTU1MjItSFRNTDwvYj4=\\033\\\\\\033]5522;type=wdata\\033\\\\'\r",
                    to: shell
                )
                t.expect(
                    t.wait(until: { pasteboard.string(forType: .string) == "UBQ-5522-TEXT" }, timeout: 8),
                    desc:
                        "an OSC 5522 write lands its text item as the pasteboard's text (\(pasteboard.string(forType: .string) ?? "nothing"))"
                )
                let html = pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }
                t.expect(
                    html == "<b>UBQ-5522-HTML</b>",
                    desc: "an OSC 5522 write lands its HTML item under the HTML type (\(html ?? "nothing"))"
                )

                // OSC 5522 read of the general clipboard: its typed items are
                // read once, by the session's client, and the HTML comes back
                // as the program asked for it.
                _ = t.configureAppending("[security]\nclipboard_read = \"allow\"\n")
                t.sendText(
                    "stty -echo; printf '\\033]5522;type=read;dGV4dC9odG1s\\033\\\\'; reply=; for packet in 1 2 3; do IFS= read -r -t 3 -d '\\\\' part; reply=\"$reply$part\"; done; stty echo; "
                        + "case \"$reply\" in *PGI+VUJRLTU1MjItSFRNTDwvYj4=*) echo READ5522_$((40+2)) ;; *) echo READ5522_$((2+2)) ;; esac\r",
                    to: shell
                )
                t.expect(t.wait(forText: "READ5522_42", in: shell, timeout: 10), desc: "an OSC 5522 read returns the clipboard's HTML item")
            }
        }
    }
}
