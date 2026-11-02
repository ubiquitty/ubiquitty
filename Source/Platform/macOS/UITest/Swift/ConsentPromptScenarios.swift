// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

private typealias SyncWire = Ubiquitty.`Protocol`.Sync

// ConsentPromptScenarios.swift — a permission prompt refuses when nobody
// answers it.
//
// Every prompt this app raises to ask permission is built by `ConsentAlert`,
// a type rather than a rule each call site restates, because the rule is easy
// to state backwards: AppKit makes the *first* button added the default, so a
// prompt listing its allowing button first grants on a Return aimed at
// whatever the sheet appeared over.
//
// So these ask AppKit which button it has made the default, and press that one.
// The assertion a scenario could make cheaply — that `alert.buttons.first` is
// titled "Deny" — is a restatement of the code, and it would keep passing if
// AppKit ever changed which button Return picks. `defaultButtonCell` is the
// panel's own answer, and it is the property the defect turns on.
//
// Sheets, never `runModal()`. An app-modal alert inside a scenario has no
// event loop to answer it and the runner hangs; a sheet returns immediately
// and reports through its completion, which is also how these prompts appear
// to a person.

/// The button a Return would press, as AppKit decides it.
///
/// Found through `defaultButtonCell`, because that is where an alert panel keeps
/// the answer: its buttons carry no key equivalent at all, and Return reaches
/// the default one through the window's own key handling. A scenario reading
/// `keyEquivalent` finds nothing on any button and concludes the prompt has no
/// default, which is both wrong and the comfortable direction to be wrong in.
///
/// The cell is then resolved back to its button, because only the button
/// answers with the response code the prompt's completion reads — pressing the
/// cell dismisses the sheet as though nobody had chosen, which is a refusal
/// whichever button was default, and therefore no evidence about which one was.
///
/// - Parameter window: The sheet or window to ask.
/// - Returns: The default button, or nil when the panel has none.
@MainActor
private func defaultButton(of window: NSWindow) -> NSButton? {
    guard let cell = window.defaultButtonCell, let content = window.contentView else {
        return nil
    }
    func walk(_ view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.cell === cell {
            return button
        }
        for subview in view.subviews {
            if let found = walk(subview) {
                return found
            }
        }
        return nil
    }
    return walk(content)
}

/// A button by title, anywhere under a window.
///
/// - Parameters:
///   - title: The title to match.
///   - window: The sheet or window to search.
/// - Returns: The button, or nil.
@MainActor
private func button(titled title: String, of window: NSWindow) -> NSButton? {
    guard let content = window.contentView else {
        return nil
    }
    func walk(_ view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let found = walk(subview) {
                return found
            }
        }
        return nil
    }
    return walk(content)
}

/// Presses the button Return activates.
///
/// Not by synthesizing a Return: with the buttons reordered so the default is
/// "Allow Once", a fake keystroke still closes the sheet and still produces a
/// refusal — the panel ends by a path of its own rather than through its
/// default button, so the leg passes on a prompt that grants. A drive
/// answering the same under the defect and under the fix is measuring the
/// harness.
///
/// - Parameter window: The sheet to answer.
/// - Returns: Whether there was a default button to press. False means the
///   scenario proved nothing and must say so.
@MainActor
private func pressDefaultButton(of window: NSWindow) -> Bool {
    guard let button = defaultButton(of: window) else {
        return false
    }
    button.performClick(nil)
    return true
}

/// The sheet a window is showing, once AppKit has put it up.
///
/// - Parameters:
///   - window: The window the sheet is attached to.
///   - t: The running scenario, for pumping.
/// - Returns: The sheet, or nil when none appeared.
@MainActor
private func waitForSheet(on window: NSWindow, pumpingWith t: UBUITestContext) -> NSWindow? {
    for _ in 0..<40 {
        if let sheet = window.attachedSheet {
            return sheet
        }
        t.pump(0.05)
    }
    return nil
}

/// Registers the consent-prompt scenarios with the UI-test runner.
enum ConsentPromptScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("structure_consent_offers_one_operation_and_retires_its_sheet") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                defer { window.close() }
                window.orderBack(nil)
                var request = SyncWire.StructureConsent()
                request.workspaceID = 7
                request.workspaceName = std.string("review")
                request.method = std.string("workspace.rename")
                request.parameters = std.string("{\"workspace\":7,\"name\":\"release\"}")
                request.peerProcess = std.string("/usr/bin/tool")
                let words = Ubiquitty.Security.structureConsentText(request)
                let prompt = RuntimeDrive.StructureConsentPrompt(
                    token: 1,
                    question: String(words.question),
                    detail: String(words.detail),
                    allowTitle: String(words.allow),
                    denyTitle: String(words.deny)
                )
                for approves in [false, true] {
                    var answer: Bool?
                    let presentation = StructureConsentPresentation(prompt)
                    presentation.present(on: window) { answer = $0 }
                    guard let sheet = waitForSheet(on: window, pumpingWith: t) else {
                        t.expect(false, desc: "the operation is presented as a native sheet")
                        return
                    }
                    t.expect(defaultButton(of: sheet)?.title == prompt.denyTitle, desc: "Return denies the operation")
                    t.expect(button(titled: prompt.allowTitle, of: sheet) != nil, desc: "the one-shot approval is offered")
                    for title in ["Allow This Session", "Allow for This Session", "Always Allow", "Always Allow This Agent"] {
                        t.expect(button(titled: title, of: sheet) == nil, desc: "the operation offers no reusable grant: \(title)")
                    }
                    if approves {
                        button(titled: prompt.allowTitle, of: sheet)?.performClick(nil)
                    } else {
                        t.expect(pressDefaultButton(of: sheet), desc: "the refusing default can be activated")
                    }
                    t.expect(t.wait(until: { answer != nil }, timeout: 3), desc: "the native button reports an answer")
                    t.expect(answer == approves, desc: "only Allow Once approves the operation")
                }
                var wasRetiredQuestionApproved: Bool?
                let retired = StructureConsentPresentation(prompt)
                retired.present(on: window) { wasRetiredQuestionApproved = $0 }
                guard waitForSheet(on: window, pumpingWith: t) != nil else {
                    t.expect(false, desc: "the question appears before host retirement")
                    return
                }
                retired.dismiss()
                t.expect(
                    t.wait(until: { window.attachedSheet == nil && wasRetiredQuestionApproved != nil }, timeout: 3),
                    desc: "host retirement removes the question"
                )
                t.expect(wasRetiredQuestionApproved == false, desc: "retiring a question never approves it")
            }
        }

        UBUITestRegister("structure_consent_surface_tracks_the_live_core_question") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let surface = TerminalSurface(rows: 24, columns: 80) else {
                    t.expect(false, desc: "a surface owns the consent queue")
                    return
                }
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                defer { window.close() }
                window.contentView = surface
                window.orderBack(nil)
                var request = SyncWire.StructureConsent()
                request.requestID = 11
                request.sessionID = 2
                request.workspaceID = 7
                request.revision = 1
                request.workspaceName = std.string("review")
                request.method = std.string("workspace.rename")
                request.parameters = std.string("{\"workspace\":7,\"name\":\"release\"}")
                request.peerProcess = std.string("/usr/bin/tool")
                surface.drive.noteStructureConsentForTesting(request)
                surface.serviceIngestEvents()
                guard let first = surface.drive.pendingStructureConsent,
                    let firstSheet = waitForSheet(on: window, pumpingWith: t)
                else {
                    t.expect(false, desc: "Core's first question reaches the native surface")
                    return
                }
                t.expect(surface.structureConsentPresentation?.request.token == first.token, desc: "the sheet captures Core's local token")
                t.expect(defaultButton(of: firstSheet)?.title == first.denyTitle, desc: "the live question defaults to refusal")
                request.requestID = 12
                request.parameters = std.string("{\"workspace\":7,\"name\":\"next\"}")
                surface.drive.noteStructureConsentForTesting(request)
                surface.serviceIngestEvents()
                t.expect(window.attachedSheet === firstSheet, desc: "a queued question does not replace the displayed question")
                surface.drive.noteStructureConsentResolvedForTesting(11)
                surface.serviceIngestEvents()
                t.expect(
                    t.wait(until: { window.attachedSheet != nil && window.attachedSheet !== firstSheet }, timeout: 3),
                    desc: "retiring the first question presents the queued question"
                )
                guard let second = surface.drive.pendingStructureConsent, let secondSheet = window.attachedSheet else {
                    t.expect(false, desc: "the next question remains pending")
                    return
                }
                t.expect(second.token != first.token, desc: "each question has a distinct local identity")
                t.expect(
                    surface.structureConsentPresentation?.request.detail == second.detail,
                    desc: "the replacement sheet describes the new operation"
                )
                surface.drive.respondToStructureConsent(first.token, allow: true)
                t.expect(
                    surface.drive.pendingStructureConsent?.token == second.token,
                    desc: "a late answer to the retired sheet cannot approve its successor"
                )
                t.expect(pressDefaultButton(of: secondSheet), desc: "the replacement's refusing default can be pressed")
                t.expect(
                    t.wait(until: { surface.drive.pendingStructureConsent == nil }, timeout: 3),
                    desc: "the native answer settles its captured question"
                )
                surface.serviceIngestEvents()

                // A restarted host can reuse its request number. The native
                // presentation still has a new local identity.
                request.requestID = 11
                surface.drive.noteStructureConsentForTesting(request)
                surface.serviceIngestEvents()
                guard let reused = surface.drive.pendingStructureConsent,
                    waitForSheet(on: window, pumpingWith: t) != nil
                else {
                    t.expect(false, desc: "a reused host request number asks again")
                    return
                }
                t.expect(reused.token != first.token, desc: "host request reuse never reuses the presentation token")
                surface.drive.respondToStructureConsent(first.token, allow: true)
                t.expect(
                    surface.drive.pendingStructureConsent?.token == reused.token,
                    desc: "the old token cannot answer a reused host request number"
                )
                surface.drive.noteStructureConsentResolvedForTesting(11)
                surface.serviceIngestEvents()
                t.expect(
                    t.wait(until: { window.attachedSheet == nil }, timeout: 3),
                    desc: "retirement of the final question removes its sheet"
                )
                t.expect(surface.structureConsentPresentation == nil, desc: "no stale native presentation remains")
            }
        }

        UBUITestRegister("paste_buffers_panel_native_layout") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let store = ClipboardStore.shared()
                store.setBytes(Data("git diff --stat".utf8), forBuffer: 3)
                store.setBytes(Data("/Users/user/Projects/ubiquitty/Source/Core/Clipboard".utf8), forBuffer: 4)
                store.recordRecentCopy("cmake --build build/macos --target Ubiquitty")
                let controller = PasteBuffersWindowController()
                guard let window = controller.window, let view = window.contentView else {
                    t.expect(false, desc: "the paste panel has native content")
                    return
                }
                defer { window.close() }
                window.setContentSize(NSSize(width: 480, height: 400))
                controller.showWindow(nil)
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    window.appearance = NSAppearance(named: appearance)
                    t.pump(0.3)
                    view.layoutSubtreeIfNeeded()
                    // Measured against what the panel's own content asks for
                    // rather than a number. A fixed floor is met by the window
                    // size the machine chose, so it holds whether or not the
                    // previews and actions it names still fit.
                    t.expect(
                        window.contentLayoutRect.width >= view.fittingSize.width,
                        desc: "the panel lays out at least as wide as its previews and actions need"
                    )
                    if let directory = ProcessInfo.processInfo.environment["UBIQUITTY_PASTE_PANEL_CAPTURE"],
                        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("paste-buffers-\(name).png"))
                        }
                    }
                }
            }
        }

        UBUITestRegister("swift_osc52_allow_once_delivers_each_reply_and_asks_again") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let store = ClipboardStore.shared()
                let savedBuffer = store.bytes(forBuffer: 1)
                let saved = t.configureAppending("[security]\nclipboard_read = \"prompt\"\n")
                store.setBytes(Data("UBQ52MARK".utf8), forBuffer: 1)
                ClipboardReadPrompt.uiTestClearSessionGrants()
                ClipboardReadPrompt.uiTestResetPresentCount()
                ClipboardReadPrompt.uiTestSetInjectedAnswer(1)
                defer {
                    t.restoreConfiguration(saved)
                    store.setBytes(savedBuffer ?? Data(), forBuffer: 1)
                    ClipboardReadPrompt.uiTestSetInjectedAnswer(0)
                    ClipboardReadPrompt.uiTestClearSessionGrants()
                }
                guard let shell = t.newWindowRunning(["/bin/bash", "--noprofile", "--norc"]) else {
                    t.expect(false, desc: "a shell opens for an OSC 52 round trip")
                    return
                }
                defer { shell.window?.close() }
                for attempt in 1...2 {
                    t.sendText(
                        "printf '\\033]52;p;?\\033\\\\'; IFS= read -r -t 2 -d '\\' reply; case \"$reply\" in *VUJRNTJNQVJL*) verdict=OK ;; *) verdict=BAD ;; esac; echo \"OSC52_\(attempt)_${verdict}\"\r",
                        to: shell
                    )
                    t.expect(
                        t.wait(forText: "OSC52_\(attempt)_OK", in: shell, timeout: 8),
                        desc: "Allow Once delivers clipboard bytes on read \(attempt)"
                    )
                    t.expect(
                        ClipboardReadPrompt.uiTestPresentCount() == attempt,
                        desc: "each read prompts independently after its predecessor completes"
                    )
                }
            }
        }

        UBUITestRegister("swift_tmux_osc52_writes_obey_the_pane_policy") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-clipboard-policy-uitest"
                let store = ClipboardStore.shared()
                let savedBuffer = store.bytes(forBuffer: 1)
                let saved = t.configureAppending("[security]\nclipboard_write = \"deny\"\n")
                store.setBytes(Data("unchanged".utf8), forBuffer: 1)
                t.killTmuxServer(onSocket: socket)
                defer {
                    t.restoreConfiguration(saved)
                    store.setBytes(savedBuffer ?? Data(), forBuffer: 1)
                    t.killTmuxServer(onSocket: socket)
                }
                guard let primary = t.launchTmuxArguments("-L \(socket) -CC new-session -s clipboard-policy") else {
                    t.expect(false, desc: "a private tmux session launches with clipboard writes denied")
                    return
                }
                var surface: TerminalSurface?
                t.expect(
                    t.wait(
                        until: {
                            guard let child = t.tmuxChildren(of: primary).first as? TerminalWindowController,
                                let pane = child.boundTmuxPaneIDs().first
                            else { return false }
                            surface = child.tmuxSurfaceForTesting(pane)
                            return surface != nil
                        },
                        timeout: 10
                    ),
                    desc: "the tmux pane adopts its own terminal"
                )
                guard let surface else { return }
                let write = "printf '\\033]52;p;dG11eC1jbGlwYm9hcmQ=\\033\\\\'"
                surface.send(write + "; printf 'POLICY_%s\\n' DENIED\n")
                t.expect(
                    t.wait(until: { surface.gridTextForTesting().contains("POLICY_DENIED") }, timeout: 5),
                    desc: "the hosted shell emits its denied clipboard request"
                )
                t.expect(store.bytes(forBuffer: 1) == Data("unchanged".utf8), desc: "a denied write cannot change the clipboard")
                t.restoreConfiguration(saved)
                t.configureAppending("[security]\nclipboard_write = \"allow\"\n")
                TerminalWindowController.applyTerminalPreferencesToOpenWindows()
                surface.send(write + "\n")
                t.expect(
                    t.wait(
                        until: {
                            store.bytes(forBuffer: 1) == Data("tmux-clipboard".utf8)
                        },
                        timeout: 3
                    ),
                    desc: "reloading Allow enables writes from that same pane"
                )
            }
        }

        UBUITestRegister("swift_tmux_pane_installs_and_releases_its_clients") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let socket = "ubiquitty-clipboard-uitest"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                guard let primary = t.launchTmuxArguments("-L \(socket) -CC new-session -s clipboard") else {
                    t.expect(false, desc: "a private tmux control session launches")
                    return
                }
                var shell: TerminalWindowController?
                _ = t.wait(
                    until: {
                        shell = t.tmuxChildren(of: primary).first as? TerminalWindowController
                        return shell?.boundTmuxPaneIDs().isEmpty == false
                    },
                    timeout: 10
                )
                guard let shell, let pane = shell.boundTmuxPaneIDs().first, let surface = shell.tmuxSurfaceForTesting(pane) else {
                    t.expect(false, desc: "the tmux pane has an adopted Swift surface")
                    return
                }
                t.expect(
                    surface.drive.withTerminal { $0.capabilityPolicy.installed() } == true,
                    desc: "the adopted pane installs its capability policy"
                )
                t.expect(
                    TerminalWindowController.surface(forSessionIdentity: surface.drive.sessionIdentity) === surface,
                    desc: "consent resolves the adopted session's own surface"
                )
                t.expect(
                    surface.drive.hasAdoptedModelClients,
                    desc: "the pane's window verbs, banners and triggers queue on its own session"
                )
                if let pane = shell.boundTmuxPaneIDs().first {
                    shell.unbindTmuxPane(pane)
                    t.expect(
                        TerminalWindowController.surface(forSessionIdentity: surface.drive.sessionIdentity) == nil,
                        desc: "unbinding removes the consent destination before terminal disposal"
                    )
                    t.expect(
                        !surface.drive.hasAdoptedModelClients,
                        desc: "and takes the pane's window, banner and trigger clients back out"
                    )
                }
            }
        }

        UBUITestRegister("swift_clipboard_store_preserves_binary_buffers_and_history") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let store = ClipboardStore.shared()
                let bytes = Data([65, 0, 255, 66])
                store.setBytes(bytes, forBuffer: 1)
                t.expect(store.bytes(forBuffer: 1) == bytes, desc: "the Core store preserves NUL and non-UTF8 bytes")
                store.setBytes(Data(), forBuffer: 1)
                t.expect(store.bytes(forBuffer: 1) == nil, desc: "empty writes clear selection buffers")
                store.setBytes(bytes, forBuffer: -1)
                store.setBytes(bytes, forBuffer: 999)
                t.expect(
                    store.bytes(forBuffer: -1) == nil && store.bytes(forBuffer: 999) == nil,
                    desc: "invalid selectors never reach Core indexing"
                )
                store.recordRecentCopy("copy-first")
                store.recordRecentCopy("copy-second")
                store.recordRecentCopy("copy-first")
                t.expect(store.text(for: .Recent, index: 0) == "copy-first", desc: "a duplicate copy moves to the front")
                t.expect(store.text(for: .Recent, index: 1) == "copy-second", desc: "history retains the other copy")
                t.expect(store.textForEntryKind(999, index: 0) == nil, desc: "unknown picker kinds cannot select history")
            }
        }

        UBUITestRegister("swift_clipboard_typed_roundtrip_and_capture_bounds") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let service = SessionClipboard()
                let name = "org.ubiquitty.test.clipboard.\(UUID().uuidString)"
                let pasteboard = NSPasteboard(name: .init(name))
                defer { pasteboard.releaseGlobally() }
                let text = Data("hello λ".utf8)
                let binary = Data([0, 255, 1, 128, 0])
                service.apply(["TEXT/PLAIN;charset=utf-8", "image/png"], payloads: [text, binary], pasteboardName: name)
                t.expect(pasteboard.string(forType: .string) == "hello λ", desc: "plain MIME parameters preserve native text interop")
                service.capture(name, bound: 4) { names, payloads in
                    t.expect(Array(names.prefix(2)) == ["text/plain", "image/png"], desc: "capture preserves MIME order")
                    t.expect(
                        Array(payloads.prefix(2)) == [Data(text.prefix(4)), Data(binary.prefix(4))],
                        desc: "each typed payload is independently bounded"
                    )
                }
                service.apply(["text/plain"], payloads: [Data([255])], pasteboardName: name)
                t.expect(pasteboard.string(forType: .string) == nil, desc: "invalid UTF-8 is not silently replaced")
                service.apply([], payloads: [], pasteboardName: name)
                service.capture(name, bound: 10) { names, payloads in
                    t.expect(names.isEmpty && payloads.isEmpty, desc: "an empty write clears stale typed content")
                }
            }
        }

        UBUITestRegister("swift_clipboard_grants_follow_requesting_session") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "creates a Swift session")
                    return
                }
                defer {
                    ClipboardReadPrompt.uiTestSetInjectedAnswer(0)
                    ClipboardReadPrompt.uiTestClearSessionGrants()
                    shell.window?.close()
                }
                t.pump(0.1)
                let first = SessionClipboard()
                first.write(Data("primary-test".utf8), buffer: 1)
                let second = SessionClipboard()
                ClipboardReadPrompt.uiTestClearSessionGrants()
                ClipboardReadPrompt.uiTestResetPresentCount()
                ClipboardReadPrompt.uiTestSetInjectedAnswer(2)
                var answers: [Bool] = []
                first.requestRead(surface.drive.sessionIdentity, buffer: 1, setSpec: "p", requiresConfirmation: true, bound: 32) {
                    allowed,
                    _,
                    _,
                    _ in answers.append(allowed)
                }
                t.pump(0.05)
                ClipboardReadPrompt.uiTestSetInjectedAnswer(3)
                first.requestRead(surface.drive.sessionIdentity, buffer: 1, setSpec: "p", requiresConfirmation: true, bound: 32) {
                    allowed,
                    _,
                    _,
                    _ in answers.append(allowed)
                }
                second.requestRead(surface.drive.sessionIdentity, buffer: 1, setSpec: "p", requiresConfirmation: true, bound: 32) {
                    allowed,
                    _,
                    _,
                    _ in answers.append(allowed)
                }
                t.pump(0.05)
                t.expect(answers == [true, true, false], desc: "a remembered grant belongs only to its client")
                first.requestRead(UInt.max, buffer: 1, setSpec: "p", requiresConfirmation: true, bound: 32) {
                    allowed,
                    _,
                    _,
                    _ in t.expect(!allowed, desc: "a missing origin is denied even with a remembered grant")
                }
                ClipboardReadPrompt.uiTestSetInjectedAnswer(0)
                let unrelated = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                unrelated.isReleasedWhenClosed = false
                defer { unrelated.close() }
                unrelated.makeKeyAndOrderFront(nil)
                second.requestRead(surface.drive.sessionIdentity, buffer: 1, setSpec: "p", requiresConfirmation: true, bound: 32) {
                    _,
                    _,
                    _,
                    _ in
                }
                guard let window = shell.window, let sheet = waitForSheet(on: window, pumpingWith: t) else {
                    t.expect(false, desc: "the sheet is attached to the requesting window")
                    return
                }
                t.expect(unrelated.attachedSheet == nil, desc: "the key window never receives another session's consent")
                t.expect(pressDefaultButton(of: sheet), desc: "the request can be denied")
                t.pump(0.1)
            }
        }

        // "Allow for this session" is one pane's grant. Two split panes of one
        // window are separate trust origins: a read in the sibling of a granted
        // pane asks again, and a pane that replaces a closed one starts with no
        // grant. Driven through the panes' own terminals, so the grant is keyed
        // by whatever each pane's clipboard client hands the prompt.
        UBUITestRegister("osc52_session_grant_stays_with_the_pane_that_was_granted") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = t.configureAppending("[security]\nclipboard_read = \"prompt\"\n")
                ClipboardReadPrompt.uiTestClearSessionGrants()
                ClipboardReadPrompt.uiTestResetPresentCount()
                defer {
                    t.restoreConfiguration(saved)
                    ClipboardReadPrompt.uiTestSetInjectedAnswer(0)
                    ClipboardReadPrompt.uiTestClearSessionGrants()
                }
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a window opens")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)
                shell.splitRight(nil)
                t.expect(t.wait(until: { shell.paneSurfacesForTesting.count == 2 }, timeout: 8), desc: "the window splits")
                let panes = shell.paneSurfacesForTesting
                guard panes.count == 2 else { return }
                let granted = panes[0]
                let sibling = panes[1]
                let read = Data("\u{1b}]52;p;?\u{1b}\\".utf8)
                let asked = { (count: Int) in t.wait(until: { ClipboardReadPrompt.uiTestPresentCount() == count }, timeout: 4) }

                ClipboardReadPrompt.uiTestSetInjectedAnswer(2) // Allow for this session
                granted.feed(read)
                t.expect(asked(1), desc: "the first read in a pane asks")

                ClipboardReadPrompt.uiTestSetInjectedAnswer(3) // Deny
                granted.feed(read)
                t.pump(0.3)
                t.expect(ClipboardReadPrompt.uiTestPresentCount() == 1, desc: "the granted pane reads again without asking")

                sibling.feed(read)
                t.expect(asked(2), desc: "the sibling pane asks: it does not inherit the granted pane's grant")
                sibling.feed(read)
                t.expect(asked(3), desc: "and a denial there remembers nothing")

                shell.closePane(nil)
                t.expect(t.wait(until: { shell.paneSurfacesForTesting.count == 1 }, timeout: 8), desc: "a pane closes")
                shell.splitRight(nil)
                t.expect(t.wait(until: { shell.paneSurfacesForTesting.count == 2 }, timeout: 8), desc: "and a new one opens")
                guard let replacement = shell.paneSurfacesForTesting.first(where: { $0 !== granted && $0 !== sibling }) else {
                    t.expect(false, desc: "the new pane is a new surface")
                    return
                }
                let before = ClipboardReadPrompt.uiTestPresentCount()
                replacement.feed(read)
                t.expect(asked(before + 1), desc: "a pane that replaces a closed one starts with no grant")
            }
        }

        UBUITestRegister("swift_shell_capability_consent_names_the_effect_and_actual_grant_lifetime") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let clipboard = Ubiquitty.Capability.ClipboardRead.rawValue
                let question = TerminalSurface.consentQuestion(.grantCapability, capabilityCode: clipboard)
                t.expect(question.contains("read your clipboard"), desc: "the question names the requested effect")
                t.expect(
                    !question.contains("an agent"),
                    desc: "the capability request does not attribute its emitter to the attached principal"
                )
                let unrecognized = TerminalSurface.consentQuestion(.grantCapability, capabilityCode: 0xBEEF)
                t.expect(
                    unrecognized.contains("48879") && unrecognized.contains("0xbeef"),
                    desc: "a capability this build cannot name shows its code"
                )
                let detail = TerminalSurface.capabilityConsentDetail(
                    peerProcess: "/usr/bin/agent",
                    agentLabel: "Friendly",
                    foregroundProcesses: "zsh › node",
                    window: "Build",
                    tab: "src",
                    workspace: "Remote",
                    pane: "2",
                    capabilityCode: clipboard
                )
                t.expect(
                    detail.contains("/usr/bin/agent") && detail.contains("not verified"),
                    desc: "verified identity is separate from the claimed name"
                )
                t.expect(
                    detail.contains("window “Build”") && detail.contains("tab “src”"),
                    desc: "the prompt names where the asking session sits"
                )
                t.expect(detail.contains("zsh › node"), desc: "the prompt names the session's foreground chain")
                t.expect(
                    detail.contains("workspace “Remote”") && detail.contains("pane “2”"),
                    desc: "the prompt names the requesting pane and its workspace"
                )
                t.expect(
                    !detail.contains("cannot tell which program"),
                    desc: "a prompt that named a principal does not disown its own attribution"
                )
                t.expect(
                    detail.contains("each time") && detail.contains("isn’t remembered"),
                    desc: "clipboard-read grants disclose their per-use lifetime"
                )
                t.expect(
                    TerminalSurface.consentScopes(.grantCapability, isPerUse: true) == ["Allow Once"],
                    desc: "per-use capabilities offer no persistent grant"
                )
                let persistent = TerminalSurface.capabilityConsentDetail(
                    peerProcess: "agent",
                    agentLabel: "",
                    foregroundProcesses: "",
                    window: "",
                    tab: "",
                    capabilityCode: Ubiquitty.Capability.SetWorkingDirectory.rawValue
                )
                t.expect(persistent.contains("persists across restarts"), desc: "rememberable capabilities disclose disk persistence")
                t.expect(
                    TerminalSurface.consentScopes(.grantCapability, isPerUse: false).last == "Always Allow",
                    desc: "the persistent option matches the disclosed lifetime"
                )
                t.expect(
                    TerminalSurface.consentScopes(.terminate, isPerUse: false) == ["Close Session"],
                    desc: "termination offers a single action"
                )
                // A remote owner's own clipboard write may be remembered; every
                // other host-escaping capability over Remote is still asked each
                // time, and the agent origin's clipboard write is unchanged.
                let remote = Ubiquitty.CapabilityOrigin.Remote
                let clipboardWrite = Ubiquitty.Capability.ClipboardWrite
                t.expect(
                    !Ubiquitty.capabilityGrantIsPerUse(clipboardWrite, remote)
                        && Ubiquitty.capabilityGrantIsPerUse(Ubiquitty.Capability.ExecuteTrigger, remote)
                        && Ubiquitty.capabilityGrantIsPerUse(clipboardWrite, Ubiquitty.CapabilityOrigin.Agent),
                    desc: "only a remote owner's clipboard write and notification outlive one use"
                )
                let remoteDetail = TerminalSurface.capabilityConsentDetail(
                    peerProcess: "",
                    agentLabel: "",
                    foregroundProcesses: "",
                    window: "",
                    tab: "",
                    capabilityOrigin: remote.rawValue,
                    capabilityCode: clipboardWrite.rawValue
                )
                t.expect(remoteDetail.contains("persists across restarts"), desc: "a remote clipboard write discloses a remembered grant")
                let ownQuestion = TerminalSurface.ownDeviceConsentQuestion(
                    capabilityCode: clipboardWrite.rawValue,
                    capabilityOrigin: remote.rawValue
                )
                t.expect(
                    ownQuestion == "Your Mac (remote) asks to write to your clipboard",
                    desc: "a request from this device's own program names this device, got \(ownQuestion)"
                )
                // A question this client asks of its own policy keeps nothing,
                // so it never says "Always" or promises a saved grant.
                t.expect(
                    TerminalSurface.hostEffectConsentScopes(isPerUse: false) == ["Allow Once", "Allow for This Connection"],
                    desc: "a client-held question's widest allow lasts for the connection"
                )
                t.expect(
                    TerminalSurface.hostEffectConsentScopes(isPerUse: true) == ["Allow Once"],
                    desc: "a client-held question about a per-use capability offers one use"
                )
                let heldQuestion = TerminalSurface.hostEffectConsentQuestion(capabilityCode: clipboardWrite.rawValue)
                t.expect(
                    heldQuestion == "A program on a remote host asks to write to your clipboard",
                    desc: "a client-held question names the remote program, got \(heldQuestion)"
                )
                let heldDetail = TerminalSurface.hostEffectConsentDetail(capabilityCode: clipboardWrite.rawValue)
                t.expect(
                    heldDetail.contains("until the connection ends") && heldDetail.contains("Nothing is saved")
                        && !heldDetail.contains("persists across restarts") && !heldDetail.contains("Always"),
                    desc: "a client-held question discloses the connection lifetime, got \(heldDetail)"
                )
            }
        }

        UBUITestRegister("swift_shell_a_permission_prompt_refuses_on_return") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.3)

                var answered: ConsentDecision?
                let alert = NSAlert()
                alert.messageText = "Let something happen?"
                ConsentAlert.ask(
                    alert,
                    refusing: "Deny",
                    allowing: ConsentAlert.onceOrSession,
                    on: window
                ) { decision in
                    answered = decision
                }
                guard let sheet = waitForSheet(on: window, pumpingWith: t) else {
                    t.expect(false, desc: "the prompt appears as a sheet")
                    return
                }

                // Which button Return picks, asked of AppKit rather than of the
                // source. The defect was exactly this button being an allowing
                // one, and it read as correct code at the call site.
                t.expect(
                    defaultButton(of: sheet)?.title == "Deny",
                    desc: "the key Return presses is the refusing button, not an allowing one"
                )

                t.expect(pressDefaultButton(of: sheet), desc: "the prompt has a default button at all")
                t.pump(0.3)
                t.expect(window.attachedSheet == nil, desc: "pressing it dismissed the prompt")
                t.expect(answered == .deny, desc: "and what Return would press refuses")
            }
        }

        UBUITestRegister("swift_shell_a_permission_prompt_still_grants_when_asked") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.3)

                // The control the refusal case needs. Without it, a presenter
                // that answered `.deny` to everything — the other way to be
                // wrong about a permission dialog — passes the case above.
                for (title, expected) in [("Allow Once", ConsentDecision.allowOnce), ("Allow This Session", .allowSession)] {
                    var answered: ConsentDecision?
                    let alert = NSAlert()
                    alert.messageText = "Let something happen?"
                    ConsentAlert.ask(
                        alert,
                        refusing: "Deny",
                        allowing: ConsentAlert.onceOrSession,
                        on: window
                    ) { decision in
                        answered = decision
                    }
                    guard let sheet = waitForSheet(on: window, pumpingWith: t),
                        let pressed = button(titled: title, of: sheet)
                    else {
                        t.expect(false, desc: "the prompt appears with a “\(title)” button")
                        return
                    }
                    pressed.performClick(nil)
                    t.pump(0.3)
                    t.expect(answered == expected, desc: "“\(title)” grants \(expected)")
                }
            }
        }

        UBUITestRegister("swift_shell_a_grant_scope_nobody_offered_is_a_refusal") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.3)

                // A prompt offering one allowing button, ended with the response
                // code of a THIRD button it never had — the shape a dismissed
                // sheet, a stale response or a reordered dialog produces. The
                // prior defect's sibling: a consent dialog here once answered a
                // non-answer with the widest grant it knew.
                var answered: ConsentDecision?
                let alert = NSAlert()
                alert.messageText = "Let something happen once?"
                ConsentAlert.ask(alert, refusing: "Not Now", allowing: ["Install"], on: window) { decision in
                    answered = decision
                }
                guard let sheet = waitForSheet(on: window, pumpingWith: t) else {
                    t.expect(false, desc: "the prompt appears as a sheet")
                    return
                }
                window.endSheet(sheet, returnCode: .alertThirdButtonReturn)
                t.pump(0.3)
                t.expect(answered == .deny, desc: "a response naming a button the prompt never offered refuses")
            }
        }

        UBUITestRegister("swift_shell_a_cancel_titled_refusal_still_takes_return") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.3)

                // AppKit gives a button titled "Cancel" the Escape key and
                // leaves the panel with no default button at all — measured on
                // this system, and the reason a prompt cannot be trusted to
                // keep Return on its refusal just because it added it first.
                var answered: ConsentDecision?
                let alert = NSAlert()
                alert.messageText = "Let something happen?"
                ConsentAlert.ask(alert, refusing: "Cancel", allowing: ["Do It"], on: window) { decision in
                    answered = decision
                }
                guard let sheet = waitForSheet(on: window, pumpingWith: t) else {
                    t.expect(false, desc: "the prompt appears as a sheet")
                    return
                }
                t.expect(
                    defaultButton(of: sheet)?.title == "Cancel",
                    desc: "a refusal AppKit would make the escape route keeps Return anyway"
                )
                t.expect(pressDefaultButton(of: sheet), desc: "and there is a default button to press")
                t.pump(0.3)
                t.expect(answered == .deny, desc: "and it refuses")
            }
        }

        UBUITestRegister("osc52_read_prompt_refuses_on_return") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                ClipboardReadPrompt.uiTestClearSessionGrants()
                ClipboardReadPrompt.uiTestSetInjectedAnswer(0) // the real alert, not the seam
                window.makeKeyAndOrderFront(nil)
                t.pump(0.3)

                // The real prompt, not a stand-in: this one is presented by both
                // shells, so ordered the other way a stray Return handed the
                // clipboard to the asking program on either. The injected-answer
                // seam the other OSC 52 scenarios use never builds the alert, so
                // its button order was untested by construction.
                var isServed: Bool?
                ClipboardReadPrompt.present(setSpec: "c", pane: nil, window: window) { approved in
                    isServed = approved
                }
                guard let sheet = waitForSheet(on: window, pumpingWith: t) else {
                    t.expect(false, desc: "the clipboard-read prompt appears as a sheet")
                    return
                }
                t.expect(
                    defaultButton(of: sheet)?.title == "Deny",
                    desc: "the clipboard prompt's Return button refuses"
                )
                t.expect(pressDefaultButton(of: sheet), desc: "the prompt has a default button at all")
                t.pump(0.3)
                t.expect(window.attachedSheet == nil, desc: "pressing it dismissed the prompt")
                t.expect(isServed == false, desc: "and the clipboard is not served")
            }
        }
    }
}
