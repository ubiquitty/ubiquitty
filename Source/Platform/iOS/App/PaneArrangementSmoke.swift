// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyCore
import UbiquittyKit

/// Which two panes a wide window shows, and that focusing one moves nothing.
///
/// The layout is the system's; the choice of panes is the shell's, and it is
/// the part a person tracks by position. Each case below is one way that
/// choice could shift a pane under the reader: a focus change that swaps the
/// two, a new pick that pushes out the pane they were in, or a closed pane
/// that leaves a gap the next pane should fill.
enum PaneArrangementSmokeEntry {
    @MainActor
    static func run() -> Bool {
        let a: UInt32 = 1
        let b: UInt32 = 2
        let c: UInt32 = 3
        let cases: [(String, [UInt32], UInt32, UInt32?, [UInt32], [UInt32])] = [
            ("the first focus fills both places", [], a, nil, [a, b, c], [a, b]),
            ("focusing a shown pane moves nothing", [a, b], b, a, [a, b, c], [a, b]),
            ("a new pick keeps the pane left behind", [a, b], c, a, [a, b, c], [a, c]),
            ("a new pick keeps it in either place", [a, b], c, b, [a, b, c], [c, b]),
            ("a closed pane is replaced in its place", [a, b], a, b, [a, c], [a, c]),
            ("one pane is shown alone", [a], a, nil, [a], [a]),
            ("a workspace with no panes shows none", [a, b], c, a, [], []),
        ]
        var failures: [String] = []
        for (name, shown, focusing, previous, available, expected) in cases {
            let got = TerminalPaneArrangement.arrangement(
                after: shown,
                focusing: focusing,
                previouslyFocused: previous,
                available: available
            )
            if got != expected {
                failures.append("\(name): expected \(expected), got \(got)")
            }
        }
        let replacements: [(UInt32, [UInt32], [UInt32], UInt32?)] = [
            (b, [a, b, c], [a, c], c),
            (c, [a, b, c], [a, b], b),
            (b, [a, b, c], [a], a),
            (b, [a, b, c], [], nil),
            (0, [], [c, a], c),
        ]
        for (focused, previous, available, expected) in replacements
        where TerminalPaneArrangement.replacementFocus(for: focused, previous: previous, available: available) != expected {
            failures.append("closing a pane did not select its nearest surviving neighbor")
        }
        let session = TerminalSessionModel()
        for _ in 0..<2 {
            guard let pane = session.makePaneSurface(), pane.renderer != nil else {
                failures.append("a workspace pane has no renderer")
                continue
            }
            if pane.zoomedPointSize != session.fontPointSize {
                failures.append("a workspace pane did not inherit the configured size")
            }
            pane.applyFontZoom(offset: 2)
            if !pane.applyFont(familyName: "Menlo", pointSize: 17) || pane.zoomedPointSize != 17 {
                failures.append("changing the configured font did not clear the pane's temporary zoom")
            }
            pane.resetFontZoom()
            if pane.zoomedPointSize != 17 {
                failures.append("reset zoom did not retain the configured size")
            }
            if pane.applyFont(familyName: "Menlo", pointSize: .nan) || pane.zoomedPointSize != 17 {
                failures.append("an invalid size changed the pane's font")
            }
        }
        // The settings sheet's size write is a by-key edit of the live
        // document, clamped to the range the renderer draws.
        let savedDocument = String(Ubiquitty.Preferences.liveDocument().pointee)
        AppSettingsModel().selectFont(pointSize: 18)
        if session.fontPointSize != 18 {
            failures.append("a font size write did not reach the configuration")
        }
        AppSettingsModel().selectFont(pointSize: 10000)
        if session.fontPointSize != TerminalFontSection.sizeRange.upperBound {
            failures.append("a written font size escaped the supported range")
        }
        _ = Ubiquitty.Preferences.configureOwnDocument(std.string(savedDocument))
        var transcript = TerminalVoiceTranscript()
        if transcript.accept("hello", endingAt: 1, isFinal: false) != nil || transcript.preview != "hello" {
            failures.append("partial speech reached terminal input")
        }
        if transcript.accept("hello world", endingAt: 2, isFinal: true) != "hello world" || !transcript.preview.isEmpty {
            failures.append("final speech was not inserted exactly once")
        }
        if transcript.accept("hello world", endingAt: 2, isFinal: true) != nil {
            failures.append("a repeated final speech result duplicated input")
        }
        if transcript.accept("\nnext\r\u{1b}", endingAt: 3, isFinal: true) != " next  " {
            failures.append("speech could submit a command or emit terminal controls")
        }
        if transcript.accept(" 👩‍💻", endingAt: 4, isFinal: true) != " 👩‍💻" {
            failures.append("speech altered a Unicode grapheme")
        }
        for failure in failures {
            SmokeLaunch.report("pane-arrangement: FAIL: \(failure)")
        }
        SmokeLaunch.report("pane-arrangement and appearance: \(failures.count) failures")
        return failures.isEmpty
    }
}
