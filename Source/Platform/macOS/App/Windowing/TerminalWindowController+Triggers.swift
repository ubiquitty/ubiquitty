// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// TerminalWindowController+Triggers.swift — what a matched trigger does to the
// window.
//
// The engine is Core's and so is every decision about what a match means:
// which of the two `[triggers]` gates a spawn or a POST has to pass, what argv
// a `run_command` template becomes, what body rides to a webhook, what a banner
// heads with (`Runtime::resolveTriggerEffect`). Core reaches a frontend through
// `TriggerClient`, which this arm cannot install — cxx-interop does not let a
// Swift type subclass a C++ class with virtual methods — so the session queues
// the reports and this drains them, performing each act it is handed.
//
// The containment is in what arrives rather than in anything here: a spawn
// comes as an explicit argv whose match is one element, and there is no shell
// on this path to hand it to; a POST comes as an http(s) URL and a body whose
// match is a JSON value. Neither arrives at all while its gate is shut.
//

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

extension TerminalWindowController {
    /// Performs every act a matched trigger has asked of this window.
    ///
    /// Drains rather than taking one, for the reason the banners do: a line
    /// that matched two rules put two acts in the queue.
    ///
    /// - Parameter surface: The pane whose session matched.
    func performPendingTriggerEffects(from surface: TerminalSurface) {
        let configuration = Ubiquitty.Preferences.values().pointee
        while let effect = surface.drive.takeTriggerEffect(configuration) {
            performTriggerEffect(effect, from: surface)
        }
    }

    /// Performs one act.
    ///
    /// - Parameters:
    ///   - effect: What the rule asked for, as Core resolved it.
    ///   - surface: The pane whose session matched.
    private func performTriggerEffect(_ effect: RuntimeDrive.TriggerEffect, from surface: TerminalSurface) {
        switch effect.kind {
        case .notify:
            // The same route an OSC 9 banner takes, so a rule and an escape
            // leave the same banner, Dock ask and tab dot behind.
            postBanner(title: effect.title, body: effect.body, from: surface)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(effect.text, forType: .string)
        case .setTitle:
            // The pane's title, as a program's OSC 2 would set it: every
            // surface that names the window weaves from that one field, and
            // the program's next title replaces this as it replaces its own.
            surface.drive.applyTriggerTitle(effect.title)
            surface.deliver(.titleChanged)
        case .runCommand:
            TriggerActions.spawn(effect.arguments)
        case .webhook:
            TriggerActions.post(effect.requestBody, to: effect.url)
        }
    }

    /// Writes what a trigger compile refused where a reader looking for it
    /// finds it, once per distinct report.
    ///
    /// Once, because the compile runs for every pane on every settings change,
    /// and a malformed rule the reader has not fixed yet is one fact rather
    /// than one per pane per change.
    ///
    /// - Parameter report: Core's account of what was refused, empty for none.
    static func reportTriggerConfiguration(_ report: String) {
        guard report != lastTriggerConfigurationReport else { return }
        lastTriggerConfigurationReport = report
        guard !report.isEmpty else { return }
        NSLog("%@", report)
    }

    /// The report last written, so a repeat of it is not written again.
    private static var lastTriggerConfigurationReport = ""
}
