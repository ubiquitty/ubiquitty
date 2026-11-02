// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// EditMenuScenarios.swift — the Edit menu against a Kit-hosted window.
//
// Thirteen items reached no responder here, which AppKit expresses by greying
// them out: the menu described a terminal that could not reset itself or paste
// a path with spaces in it. So the assertions are of two kinds — whether the
// selector lands at all, and whether the items scoped to a selection know
// there is one.
//
// The second kind is the one worth having. An item that stays enabled without
// a selection tells the user it will do something and then does nothing, which
// is worse than the item being missing.

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let surface = view as? TerminalSurface {
        return surface
    }
    for subview in view.subviews {
        if let found = terminalSurface(under: subview) {
            return found
        }
    }
    return nil
}

/// An Edit-menu item carrying a selector, as the app installed it.
///
/// - Parameter selector: The action to find.
/// - Returns: The item, or nil when the Edit menu has none.
@MainActor
private func editMenuItem(_ selector: Selector) -> NSMenuItem? {
    guard let edit = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu else {
        return nil
    }
    return edit.items.first { $0.action == selector }
}

/// The Copy Special item carrying `selector`.
///
/// A separate walk because Copy Special is a submenu: the Edit menu's own
/// items do not include it, so a top-level search answers nil for an item
/// that is on screen.
///
/// - Parameter selector: The action to find.
/// - Returns: The item, or nil when Copy Special has none.
@MainActor
private func copySpecialItem(_ selector: Selector) -> NSMenuItem? {
    guard let edit = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu,
        let special = edit.items.first(where: { $0.submenu?.items.contains { $0.action == selector } ?? false })?.submenu
    else {
        return nil
    }
    return special.items.first { $0.action == selector }
}

/// Runs `body` with the general pasteboard's string saved and put back, so a
/// copy the scenario makes does not outlive it on the runner's clipboard.
///
/// - Parameter body: The scenario's copy and its assertions.
@MainActor
private func preservingGeneralPasteboard(_ body: () -> Void) {
    let saved = NSPasteboard.general.string(forType: .string)
    defer {
        NSPasteboard.general.clearContents()
        if let saved {
            NSPasteboard.general.setString(saved, forType: .string)
        }
    }
    body()
}

/// A right-click event over a cell of the surface.
///
/// - Parameters:
///   - surface: The surface to click.
///   - row: A zero-based visible row.
///   - column: A zero-based column.
/// - Returns: The event, or nil when AppKit refuses it or the cell has no
///   place yet.
@MainActor
private func rightClick(on surface: TerminalSurface, row: Int, column: Int) -> NSEvent? {
    guard let window = surface.window, let point = surface.viewPoint(forRow: row, column: column) else {
        return nil
    }
    return NSEvent.mouseEvent(
        with: .rightMouseDown,
        location: surface.convert(point, to: nil),
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )
}

/// Feeds two OSC 133-marked commands, the way a shell integration marks them.
///
/// Row 0 is the first command's prompt, row 1 its output, row 3 the second
/// command's prompt and row 4 its output. Fed as escape sequences rather than
/// scripted onto the model, so the marks land where the parser puts them.
///
/// - Parameter surface: The surface to feed.
@MainActor
private func feedTwoMarkedCommands(_ surface: TerminalSurface) {
    surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
    surface.feed(Data("\u{1b}]133;A\u{1b}\\$ echo one\r\n".utf8))
    surface.feed(Data("\u{1b}]133;C\u{1b}\\one\r\n".utf8))
    surface.feed(Data("\u{1b}]133;D;0\u{1b}\\".utf8))
    surface.feed(Data("\u{1b}]133;A\u{1b}\\$ echo two\r\n".utf8))
    surface.feed(Data("\u{1b}]133;C\u{1b}\\two\r\n".utf8))
    surface.feed(Data("\u{1b}]133;D;0\u{1b}\\".utf8))
}

/// Feeds enough marked commands to push several prompts into history.
///
/// One `C` mark per command is what `stepToPrompt` navigates by, and there
/// have to be more of them than the screen holds or every prompt is already
/// visible and a step up has nowhere to go.
///
/// - Parameters:
///   - surface: The surface to feed.
///   - count: How many marked commands to run past the screen.
@MainActor
private func feedMarkedCommands(_ surface: TerminalSurface, count: Int) {
    surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
    for index in 0..<count {
        surface.feed(Data("\u{1b}]133;A\u{1b}\\$ command \(index)\r\n".utf8))
        surface.feed(Data("\u{1b}]133;C\u{1b}\\output \(index)\r\n".utf8))
        surface.feed(Data("\u{1b}]133;D;0\u{1b}\\".utf8))
    }
}

/// Records the input released by a paste confirmation.
@MainActor
private final class PasteTransmitRecorder: TerminalSurfaceObserver {
    private(set) var bytes: [UInt8] = []

    nonisolated func terminalSurface(_ surface: TerminalSurface, didTransmit bytes: [CChar], count: Int) {
        let sent = bytes.prefix(count).map { UInt8(bitPattern: $0) }
        MainActor.assumeIsolated { self.bytes.append(contentsOf: sent) }
    }
}

/// Registers the Edit-menu scenarios with the UI-test runner.
enum EditMenuScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_multiline_paste_previews_and_remembers_confirmation") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate,
                    let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift shell and its settings writer are available")
                    return
                }
                let configuration = Ubiquitty.Preferences.values().pointee
                let savedConfirmation = Ubiquitty.Preferences.Effective.confirmMultilinePaste(configuration)
                let savedThreshold = Ubiquitty.Preferences.Effective.confirmMultilinePasteThreshold(configuration)
                defer {
                    app.settingsSetConfirmMultilinePaste(savedConfirmation)
                    app.settingsSetConfirmMultilinePasteThreshold(Int(savedThreshold))
                    window.close()
                }
                app.settingsSetConfirmMultilinePaste(true)
                app.settingsSetConfirmMultilinePasteThreshold(1)
                t.pump(0.3)
                surface.feed(Data("\u{1b}[?2004h".utf8))
                t.pump(0.1)
                let recorder = PasteTransmitRecorder()
                surface.observer = recorder

                @MainActor
                func descendants(_ view: NSView) -> [NSView] {
                    [view] + view.subviews.flatMap { descendants($0) }
                }
                @MainActor
                func pasteSheet(_ text: String) -> NSWindow? {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    shell.pasteFromPasteboard(nil)
                    for _ in 0..<40 {
                        if let sheet = window.attachedSheet { return sheet }
                        t.pump(0.05)
                    }
                    return nil
                }
                @MainActor
                func button(_ title: String, in sheet: NSWindow) -> NSButton? {
                    guard let root = sheet.contentView else { return nil }
                    return descendants(root).compactMap { $0 as? NSButton }.first { $0.title == title }
                }
                preservingGeneralPasteboard {
                    let text = "# preview first\n# preview last"
                    guard let sheet = pasteSheet(text), let root = sheet.contentView,
                        let preview = descendants(root).compactMap({ $0 as? NSTextView }).first,
                        let cancel = button("Cancel", in: sheet)
                    else {
                        t.expect(false, desc: "multiline paste opens a sheet with a text preview")
                        return
                    }
                    t.expect(preview.string == text && !preview.isEditable, desc: "the preview is complete and read-only")
                    t.expect(preview.enclosingScrollView != nil, desc: "the preview can scroll")
                    t.expect(recorder.bytes.isEmpty, desc: "no input is sent before confirmation")
                    cancel.performClick(nil)
                    t.pump(0.3)
                    t.expect(recorder.bytes.isEmpty, desc: "Cancel sends no input")

                    guard let confirmed = pasteSheet(text), let paste = button("Paste", in: confirmed) else {
                        t.expect(false, desc: "a second paste still asks")
                        return
                    }
                    paste.performClick(nil)
                    t.pump(0.3)
                    let expected = Array("\u{1b}[200~# preview first\r# preview last\u{1b}[201~".utf8)
                    t.expect(recorder.bytes == expected, desc: "confirmation sends the complete bracketed payload once")

                    let large = String(repeating: "# preview\n", count: 4_000)
                    guard let suppressed = pasteSheet(large), let largeRoot = suppressed.contentView,
                        let largePreview = descendants(largeRoot).compactMap({ $0 as? NSTextView }).first,
                        let checkbox = button("Don’t ask again", in: suppressed),
                        let cancelLarge = button("Cancel", in: suppressed)
                    else {
                        t.expect(false, desc: "a large paste has a preview and suppression checkbox")
                        return
                    }
                    t.expect(
                        largePreview.string.utf16.count < 16_500 && largePreview.string.contains("preview truncated"),
                        desc: "large preview layout is bounded and visibly truncated"
                    )
                    checkbox.performClick(nil)
                    cancelLarge.performClick(nil)
                    t.pump(0.3)
                    t.expect(
                        !Ubiquitty.Preferences.Effective.confirmMultilinePaste(Ubiquitty.Preferences.values().pointee),
                        desc: "suppression reaches the application's settings writer"
                    )
                    t.expect(recorder.bytes == expected, desc: "suppressing a cancelled paste sends nothing")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    shell.pasteFromPasteboard(nil)
                    t.pump(0.3)
                    t.expect(
                        window.attachedSheet == nil && recorder.bytes == expected + expected,
                        desc: "the next paste uses the saved choice and sends the unchanged payload"
                    )

                    let beforeEscaped = recorder.bytes.count
                    shell.pasteEscapedText(nil)
                    t.pump(0.2)
                    let escaped = Array("\u{1b}[200~\\#\\ preview\\ first\\\r\\#\\ preview\\ last\u{1b}[201~".utf8)
                    t.expect(
                        Array(recorder.bytes.dropFirst(beforeEscaped)) == escaped,
                        desc: "escaped paste still applies the terminal's bracketed-paste policy"
                    )

                    app.settingsSetConfirmMultilinePaste(true)
                    let beforePanel = recorder.bytes.count
                    PasteBufferActions.captureTarget(window)
                    defer { PasteBufferActions.captureTarget(nil) }
                    PasteBufferActions.pasteText(text)
                    t.pump(0.2)
                    guard let panelSheet = window.attachedSheet, let panelPaste = button("Paste", in: panelSheet) else {
                        t.expect(false, desc: "the paste-buffer destination uses multiline confirmation")
                        return
                    }
                    t.expect(recorder.bytes.count == beforePanel, desc: "the paste-buffer panel sends nothing before approval")
                    panelPaste.performClick(nil)
                    t.pump(0.2)
                    t.expect(
                        Array(recorder.bytes.dropFirst(beforePanel)) == expected,
                        desc: "the paste-buffer action reaches its captured Swift window"
                    )
                }
            }
        }

        UBUITestRegister("swift_shell_prompt_jumps_walk_the_marks") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)
                // Twice the rows, so several prompts sit above the top edge
                // whatever height this window opened at.
                feedMarkedCommands(surface, count: Int(surface.drive.readSnapshot().rows) * 2)
                t.pump(0.3)
                t.expect(surface.viewOffset == 0, desc: "the view starts on the live tail")
                t.expect(
                    shell.focusedSurfaceForTesting === surface,
                    desc: "the menu action's target pane is this surface"
                )
                let history = Int(surface.drive.readSnapshot().scrollbackCount)
                t.expect(
                    history > 0,
                    desc: "the marked commands left history to walk (\(history) rows)"
                )

                // The early steps land on prompts still on screen: only a
                // prompt above the viewport's top moves the viewport, and this
                // screen holds one every two rows. The walk is what has to
                // reach history, not the first press — so it is walked far
                // enough to climb past the top edge.
                var offsets: [Int] = []
                var anchors: [Int] = []
                for _ in 0..<48 {
                    shell.scrollToPreviousPrompt(nil)
                    t.pump(0.1)
                    offsets.append(surface.viewOffset)
                    anchors.append(surface.promptNavigationAnchorRow)
                }
                t.expect(
                    anchors.contains { $0 >= 0 },
                    desc: "a step found a marked prompt at all (anchors \(anchors), history \(history))"
                )
                t.expect(
                    offsets.contains { $0 > 0 },
                    desc: "stepping back reaches a prompt in history (offsets \(offsets))"
                )
                // Monotone, and it moves more than once: the anchor is what
                // buys both. Re-derived from the viewport each time, the walk
                // sticks on the prompt nearest the top edge and every later
                // step returns the same offset.
                let distinct = Set(offsets.filter { $0 > 0 })
                t.expect(
                    distinct.count > 1,
                    desc: "and keeps going rather than sticking on one prompt (offsets \(offsets))"
                )
                t.expect(
                    offsets == offsets.sorted(),
                    desc: "the walk only ever goes further back (offsets \(offsets))"
                )

                // Forward, until the walk snaps to the tail. Bounded so a walk
                // that refuses to move fails rather than hangs.
                for _ in 0..<64 where surface.viewOffset > 0 {
                    shell.scrollToNextPrompt(nil)
                    t.pump(0.05)
                }
                t.expect(
                    surface.viewOffset == 0,
                    desc: "stepping forward returns to the live tail (offset \(surface.viewOffset))"
                )
            }
        }

        UBUITestRegister("swift_shell_edit_menu_reaches_the_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.2)

                // Each of these is dead when no responder answers it: the
                // item is then permanently grey. Asked through the responder
                // chain the way the menu asks.
                for name in ["resetTerminal:", "pasteEscapedText:", "pasteEscapedSelection:", "selectLastCommandOutput:"] {
                    let selector = NSSelectorFromString(name)
                    t.expect(
                        shell.responds(to: selector),
                        desc: "the window controller answers \(name)"
                    )
                }

                // Reset Terminal is the one with a consequence a scenario can
                // read without a selection or a clipboard: DECSTR clears the
                // application-keypad mode an app may have left on.
                surface.feed(Data("\u{1b}[?1h".utf8))
                t.pump(0.2)
                t.expect(
                    surface.drive.readSnapshot().modes.applicationCursorKeys,
                    desc: "application cursor keys are on before the reset"
                )
                shell.resetTerminal(nil)
                t.pump(0.2)
                t.expect(
                    !surface.drive.readSnapshot().modes.applicationCursorKeys,
                    desc: "and the reset turned them off"
                )
            }
        }

        UBUITestRegister("swift_shell_edit_menu_copy_writes_the_selection") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "sleep 60"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)

                // The one Edit menu's Copy item names the standard selector, which
                // is the only way a Kit-hosted window can answer it: a private
                // name is answerable by the shell that declares it alone.
                guard let copyItem = editMenuItem(#selector(NSText.copy(_:))) else {
                    t.expect(false, desc: "the Edit menu's Copy item names copy:")
                    return
                }
                t.expect(surface.responds(to: copyItem.action!), desc: "the surface answers the Copy item's selector")

                // Validation is the surface's, since the responder chain stops at
                // it; the pair is the assertion, because a validator that
                // answered one way always would pass one half on its own.
                t.expect(!surface.hasSelection, desc: "a fresh window has no selection")
                t.expect(!surface.validateMenuItem(copyItem), desc: "Copy is disabled without a selection")
                surface.feed(Data("copy me please\r\n".utf8))
                t.pump(0.2)
                surface.selectAll(nil)
                t.pump(0.2)
                t.expect(surface.hasSelection, desc: "select-all made a selection")
                t.expect(surface.validateMenuItem(copyItem), desc: "and Copy enables with one")

                // The witness is the pasteboard's applied contents, sent the way
                // the menu sends: the item's action, to the responder that answers
                // it.
                preservingGeneralPasteboard {
                    NSPasteboard.general.clearContents()
                    NSApp.sendAction(copyItem.action!, to: surface, from: copyItem)
                    t.pump(0.2)
                    let copied = NSPasteboard.general.string(forType: .string) ?? ""
                    t.expect(copied.contains("copy me please"), desc: "the Copy item wrote the selection (\(copied.debugDescription))")
                    t.expect(
                        ClipboardStore.shared().text(for: .Recent, index: 0) == copied,
                        desc: "the same plain text becomes the newest recent-copy entry"
                    )
                }
            }
        }

        UBUITestRegister("swift_shell_copy_without_background_writes_the_rich_flavours") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)

                guard let item = copySpecialItem(NSSelectorFromString("copySelectionWithoutBackground:")) else {
                    t.expect(false, desc: "the Copy Special submenu carries Copy Without Background Color")
                    return
                }
                t.expect(shell.responds(to: item.action!), desc: "the window controller answers the Copy Special selector")
                t.expect(!shell.validateMenuItem(item), desc: "Copy Special is disabled without a selection")

                // Styling to carry: a bold red run, which a plain write cannot
                // reproduce and a styled one must.
                surface.feed(Data("\u{1b}[1;31;44mBOLDREDMARK\u{1b}[0m\r\n".utf8))
                t.pump(0.2)
                surface.selectAll(nil)
                t.pump(0.2)
                t.expect(shell.validateMenuItem(item), desc: "and enables with one")

                preservingGeneralPasteboard {
                    NSPasteboard.general.clearContents()
                    NSApp.sendAction(item.action!, to: shell, from: item)
                    t.pump(0.2)
                    let plain = NSPasteboard.general.string(forType: .string) ?? ""
                    t.expect(plain.contains("BOLDREDMARK"), desc: "the plain flavour carries the selection")
                    let rtf = String(decoding: NSPasteboard.general.data(forType: .rtf) ?? Data(), as: UTF8.self)
                    t.expect(rtf.hasPrefix("{\\rtf"), desc: "the RTF flavour is a whole document (\(rtf.prefix(12)))")
                    t.expect(rtf.contains("\\colortbl;"), desc: "and carries a colour table, which a plain copy cannot")
                    let html = String(decoding: NSPasteboard.general.data(forType: .html) ?? Data(), as: UTF8.self)
                    t.expect(html.contains("font-weight:bold"), desc: "the HTML flavour carries the weight")
                    t.expect(html.contains("color:#"), desc: "and the run's colour")
                    t.expect(!html.contains("background-color:"), desc: "and no background, which is the flavour's whole point")
                }

                // The control: the everything flavour of the same selection carries
                // the run's blue background, so the assertion above is reading the
                // mode and not a generator that never writes one.
                let scratch = NSPasteboard(name: NSPasteboard.Name("ubiquitty-uitest-copy-control"))
                defer { scratch.releaseGlobally() }
                t.expect(surface.copySelection(style: .everything, to: scratch), desc: "the everything flavour copies the same selection")
                let everythingHTML = String(decoding: scratch.data(forType: .html) ?? Data(), as: UTF8.self)
                t.expect(everythingHTML.contains("background-color:"), desc: "and carries the run's background the other flavour dropped")
            }
        }

        UBUITestRegister("swift_shell_edit_menu_greys_out_without_a_selection") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)

                guard let pasteEscapedSelection = editMenuItem(NSSelectorFromString("pasteEscapedSelection:")) else {
                    t.expect(false, desc: "the Edit menu carries Paste Escaped Selection")
                    return
                }

                // Nothing selected: the item must say so.
                t.expect(!surface.hasSelection, desc: "a fresh window has no selection")
                t.expect(
                    !shell.validateMenuItem(pasteEscapedSelection),
                    desc: "Paste Escaped Selection is disabled without a selection"
                )

                // Select something, and it enables. The pair is the assertion:
                // a validator that answers false always would pass the first
                // half on its own.
                surface.feed(Data("selectable text here\r\n".utf8))
                t.pump(0.2)
                surface.selectAll(nil)
                t.pump(0.2)
                t.expect(surface.hasSelection, desc: "select-all made a selection")
                t.expect(
                    shell.validateMenuItem(pasteEscapedSelection),
                    desc: "and the item enables with one"
                )
            }
        }

        UBUITestRegister("swift_shell_context_menu_copies_the_command_under_the_click") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                feedTwoMarkedCommands(surface)
                t.pump(0.3)

                // The second command's PROMPT row. Its output is a row below,
                // so a search that started from the click would find the first
                // command's output instead.
                guard let event = rightClick(on: surface, row: 3, column: 2),
                    let menu = surface.menu(for: event)
                else {
                    t.expect(false, desc: "a right-click over the grid opens a menu")
                    return
                }
                let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
                t.expect(
                    titles == ["Copy", "Paste", "Select All", "Copy Command Output", "Copy Command", "Clear Scrollback", "Reset Terminal"],
                    desc: "the menu carries what the classic shell's does (\(titles))"
                )

                guard let output = menu.items.first(where: { $0.title == "Copy Command Output" }),
                    let command = menu.items.first(where: { $0.title == "Copy Command" })
                else {
                    t.expect(false, desc: "the menu carries the two command items")
                    return
                }
                t.expect(
                    surface.validateMenuItem(output) && surface.validateMenuItem(command),
                    desc: "both items enable over a marked command"
                )

                preservingGeneralPasteboard {
                    NSPasteboard.general.clearContents()
                    _ = NSApp.sendAction(output.action!, to: output.target, from: output)
                    t.pump(0.2)
                    let copied = NSPasteboard.general.string(forType: .string) ?? ""
                    t.expect(
                        copied == "two",
                        desc: "a click on the prompt row copies that command's own output (copied \(copied.debugDescription))"
                    )

                    NSPasteboard.general.clearContents()
                    _ = NSApp.sendAction(command.action!, to: command.target, from: command)
                    t.pump(0.2)
                    let line = NSPasteboard.general.string(forType: .string) ?? ""
                    t.expect(
                        line == "$ echo two",
                        desc: "and Copy Command copies the line that was typed (copied \(line.debugDescription))"
                    )
                }
            }
        }

        UBUITestRegister("swift_shell_context_menu_greys_out_and_stands_off") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // A late login prompt would scroll the last-row link away.
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                // No shell integration, which is most shells: the two command
                // items are offered and grey rather than beeping at a pick.
                surface.feed(Data("\u{1b}[H\u{1b}[2Jplain output, nothing marked\r\n".utf8))
                t.pump(0.3)
                guard let event = rightClick(on: surface, row: 0, column: 2),
                    let menu = surface.menu(for: event),
                    let command = menu.items.first(where: { $0.title == "Copy Command" })
                else {
                    t.expect(false, desc: "a right-click over unmarked output opens a menu")
                    return
                }
                t.expect(
                    !surface.validateMenuItem(command),
                    desc: "Copy Command greys out where no command is marked"
                )

                // A link under the click adds its own item, carrying the
                // target resolved at build time. On the LAST visible row, so
                // the padding below it is padding beside a link — which is
                // what the off-grid case below asks about.
                let lastRow = Int(surface.publishedGrid.rows) - 1
                surface.feed(Data("\u{1b}[999;1H\u{1b}]8;;https://example.com/menu\u{1b}\\LINK\u{1b}]8;;\u{1b}\\".utf8))
                t.pump(0.3)
                if let overLink = rightClick(on: surface, row: lastRow, column: 1),
                    let linkMenu = surface.menu(for: overLink),
                    let item = linkMenu.items.first(where: { $0.title == "Copy Link" })
                {
                    t.expect(
                        item.representedObject as? String == "https://example.com/menu",
                        desc: "the link item carries the resolved target"
                    )
                } else {
                    t.expect(false, desc: "a right-click over a link offers Copy Link")
                }

                // Below the grid there is no cell, so there is no link — even
                // with one on the row the pointer is nearest to. The command
                // items are still offered, because they answer for a row and
                // the nearest row is the one the pointer is beside.
                if let window = surface.window {
                    let belowTheGrid = surface.convert(
                        CGPoint(x: 8, y: surface.bounds.height + 40),
                        to: nil
                    )
                    if let padded = NSEvent.mouseEvent(
                        with: .rightMouseDown,
                        location: belowTheGrid,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        eventNumber: 0,
                        clickCount: 1,
                        pressure: 1
                    ), let paddedMenu = surface.menu(for: padded) {
                        let paddedTitles = paddedMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
                        t.expect(
                            !paddedTitles.contains("Copy Link"),
                            desc: "a click off the grid offers no link (\(paddedTitles))"
                        )
                        t.expect(
                            paddedTitles.contains("Copy Command"),
                            desc: "and still offers the command items"
                        )
                    }
                }

                // A program reading the mouse owns the right button, so there
                // is no menu at all — the same rule that keeps a click from
                // becoming a selection.
                surface.feed(Data("\u{1b}[?1000h".utf8))
                t.pump(0.3)
                if let reported = rightClick(on: surface, row: 0, column: 2) {
                    t.expect(
                        surface.menu(for: reported) == nil,
                        desc: "no menu pops over a program that is reading the mouse"
                    )
                }
                surface.feed(Data("\u{1b}[?1000l".utf8))
            }
        }

        UBUITestRegister("swift_shell_pasted_text_drops_the_selection") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)
                surface.feed(Data("\u{1b}[H\u{1b}[2JSELECT ME\r\n".utf8))
                t.pump(0.3)

                surface.selectAll(nil)
                t.pump(0.2)
                t.expect(surface.hasSelection, desc: "there is a selection to drop")

                // Text the user causes drops it, whichever route it took: a
                // keystroke, a paste, an input method's commit. The highlight
                // described where the reader was looking, and typing is the
                // moment that stops being true.
                surface.transmitAsUserInputForTesting("x")
                t.pump(0.2)
                t.expect(
                    !surface.hasSelection,
                    desc: "and the user's own text drops it"
                )
            }
        }
    }
}
