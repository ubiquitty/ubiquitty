// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ClipboardReadPrompt.swift — the OSC 52 clipboard-READ confirmation UI.
//
// A remote/untrusted app can issue OSC 52 `?` to read the clipboard and
// exfiltrate it. When [security] clipboard_read = "prompt", Core defers the
// read and the native PAL hook fires this presenter (on main) with an opaque
// `token` identifying the pending request. The user chooses Allow once /
// Allow for this session / Deny; the choice crosses back into Core through
// the C++ bridge (Ubiquitty.SwiftBridge.resolveClipboardRead), which frames or
// suppresses the reply on the ingest path. The requesting app waits.
//
// Decision logic (read vs. not) lives in Core; this file only presents and
// returns allow/deny. The single piece of state it keeps is the per-session
// "allow for this session" latch, scoped per pane, so repeated reads from the
// same pane don't re-prompt, but a grant in pane A never auto-approves pane B.
//

import AppKit
import UbiquittyAppBridge
import UbiquittyKit
import UbiquittyRenderKit

@MainActor
@objc(UBClipboardReadPrompt)
public final class ClipboardReadPrompt: NSObject {
    // Grant identities whose user picked "Allow for this session": each pane's
    // session clipboard client. WEAK refs, so a closed pane's grant lapses with
    // its client and a new pane can never inherit a prior grant. Keyed by that
    // identity, not the window: split panes in the same window are independent
    // trust origins and each must prompt on its own.
    // @MainActor on the class enforces single-thread (main) access.
    // A nil pane can't be scoped, so its "Allow for this session" degrades to
    // a one-shot allow (no stored grant).
    private static let sessionGrants = NSHashTable<NSObject>.weakObjects()

    private static func hasSessionGrant(_ pane: NSObject?) -> Bool {
        guard let pane else { return false }
        return sessionGrants.contains(pane)
    }

    /// Presents on the requesting session's window with a client-owned grant identity.
    @objc(presentForSession:grantIdentity:setSpec:completion:)
    public static func present(
        forSession identity: UInt,
        grantIdentity: NSObject,
        setSpec: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard let surface = TerminalWindowController.surface(forSessionIdentity: identity), let window = surface.window else {
            completion(false)
            return
        }
        present(setSpec: setSpec, pane: grantIdentity, window: window, completion: completion)
    }

    // Human label for an OSC 52 selection selector, so the prompt names
    // which selection is being read. The selector is the char(s) before the
    // `;` in `OSC 52 ; <sel> ; <data>` (xterm semantics): `c` is the system
    // clipboard; `p`/`s`/`0` (primary / select / cut-buffer 0) map to the
    // primary selection, which on macOS is also served from the clipboard.
    private static func selectionLabel(forSpec spec: String) -> String {
        if spec.isEmpty { return "clipboard" }
        // Multiple selectors can be listed; the first concrete one wins.
        for ch in spec {
            switch ch {
            case "c": return "clipboard"
            case "p", "s", "0": return "primary selection"
            case "1", "2", "3", "4", "5", "6", "7":
                return "cut buffer \(ch)"
            case "q": return "secondary selection"
            default: continue
            }
        }
        return "clipboard"
    }

    // Present the confirmation for the pending read identified by `token`.
    // Must run on the main thread (AppKit) — enforced by @MainActor. `setSpec`
    // is the OSC 52 selection set, named in the prompt for context. `pane`
    // is the originating UBPane (as NSObject) — it is the grant key, so a grant
    // in one pane never auto-approves another pane in the same window. `window`
    // anchors the alert as a sheet; runs app-modal when nil.
    @objc
    public static func present(
        token: UnsafeRawPointer,
        setSpec: String,
        pane: NSObject?,
        window: NSWindow?
    ) {
        present(setSpec: setSpec, pane: pane, window: window) { approve in
            Ubiquitty.SwiftBridge.resolveClipboardRead(token, approve)
        }
    }

    // The closure form of the same prompt, for a caller that owns its own
    // completion path rather than the bridge's token registry — the Swift
    // shell's client answers its session directly. One prompt, one grant
    // latch, however the answer travels back.
    @objc
    public static func present(
        setSpec: String,
        pane: NSObject?,
        window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        // This pane already granted for the session — approve without re-prompting.
        if hasSessionGrant(pane) {
            completion(true)
            return
        }

        #if UBIQUITTY_UI_TESTS
        // A UI test answers here rather than driving AppKit. The count is the
        // point of the seam: "Allow Once restores the ask state" is only
        // observable as the NEXT read presenting again.
        if injectedAnswer != ClipboardReadPrompt.injectedAnswerNone {
            presentCount += 1
            switch injectedAnswer {
            case ClipboardReadPrompt.injectedAnswerAllowOnce:
                completion(true) // no session grant: the next read must ask again
            case ClipboardReadPrompt.injectedAnswerAllowSession:
                if let pane {
                    sessionGrants.add(pane)
                }
                completion(true)
            default:
                completion(false)
            }
            return
        }
        #endif

        let selection = selectionLabel(forSpec: setSpec)
        let alert = NSAlert()
        alert.messageText = "Allow a program to read the \(selection)?"
        alert.informativeText =
            "A program running in this terminal wants to see what you copied to the "
            + "\(selection)."
        alert.alertStyle = .warning

        // ConsentAlert decides the button order, so Return refuses rather
        // than handing the clipboard over.
        ConsentAlert.ask(
            alert,
            refusing: "Deny",
            allowing: ConsentAlert.onceOrSession,
            on: window
        ) { decision in
            // A session grant is this prompt's own memory — Core answers what
            // the human chose, and the latch that stops the next read asking
            // again is scoped to the pane here.
            if decision == .allowSession, let pane {
                sessionGrants.add(pane)
            }
            completion(decision != .deny)
        }
    }

    #if UBIQUITTY_UI_TESTS
    // Test-only seam: answer the prompt without AppKit, and count how many
    // times it was actually presented. Not compiled into release builds.
    static let injectedAnswerNone = 0 // no injection: raise the real alert
    static let injectedAnswerAllowOnce = 1
    static let injectedAnswerAllowSession = 2
    static let injectedAnswerDeny = 3

    private static var injectedAnswer = injectedAnswerNone
    private static var presentCount = 0

    @objc
    public static func uiTestSetInjectedAnswer(_ answer: Int) {
        injectedAnswer = answer
    }

    @objc
    public static func uiTestPresentCount() -> Int {
        presentCount
    }

    @objc
    public static func uiTestResetPresentCount() {
        presentCount = 0
    }

    @objc
    public static func uiTestClearSessionGrants() {
        sessionGrants.removeAllObjects()
    }
    #endif
}
