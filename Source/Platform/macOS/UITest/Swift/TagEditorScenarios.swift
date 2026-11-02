// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit
import UbiquittyRenderKit

// TagEditorScenarios.swift — the window's tags, driven through the editor a
// user actually reaches: the row inside the title popover.
//
// What a Core test cannot answer, and these do: whether a press on a palette
// dot reaches the window's resolved markers, whether a name typed in one case
// and a rule declared in another arrive as ONE tag rather than two, whether the
// chips a window wears survive being saved and reopened as a workspace,
// whether the jump to the rule editor carries the host the window is connected
// to, whether the icon, weight and custom colour chosen in that editor are the
// lines Save writes into the rule's block, whether its Show name and Show in
// boxes change what the title bar and the tab draw and nothing else, and
// whether moving a rule moves its tag on the window and its block in the file.
// Every assertion here is anchored
// to something the feature determines — the exact chip count, the exact name
// the title speaks, the wash the loud tag paints, the line in the file — so
// deleting the behaviour turns it red.

/// Registers the tag-editor scenarios with the UI-test runner.
@objc(UBTagEditorScenarios)
public final class TagEditorScenarios: NSObject {
    /// Registers every scenario in this file.
    @objc
    public static func register() {
        UBUITestRegister("tag_rules_reload_on_an_existing_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let controller = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ), let window = controller.window, let strip = titlebarStrip(of: window), let surface = controller.hostSurface
                else {
                    t.expect(false, desc: "the shell opens with a title strip")
                    return
                }
                defer { window.close() }
                controller.shellSendProbe("printf '\\033]7;file://ubq-tag-reload/tmp\\007'\r")
                let hostReported = t.wait(
                    until: {
                        String(controller.paneHost(of: surface).machine) == "ubq-tag-reload"
                    },
                    timeout: 4
                )
                t.expect(hostReported, desc: "the window observes its host before the tag rule changes")
                guard hostReported else { return }
                t.expect(Int(titleChipCount(titleField(in: strip))), equals: 0, desc: "the existing host starts untagged")

                let saved = configureAppendingToLiveDocument(
                    "[[tags]]\nname = \"Reload test\"\ncolor = \"purple\"\nmatch_host = \"ubq-tag-reload\"\n"
                )
                defer { restoreLiveDocument(saved) }
                t.expect(
                    t.wait(
                        until: {
                            titleField(in: strip)?.accessibilityLabel()?.hasPrefix("Tagged Reload test") == true
                        },
                        timeout: 4
                    ),
                    desc: "a new rule tags the existing window without another host report"
                )
                t.expect(Int(titleChipCount(titleField(in: strip))), equals: 1, desc: "the rule creates exactly one chip")

                restoreLiveDocument(saved)
                t.expect(
                    t.wait(until: { titleChipCount(titleField(in: strip)) == 0 }, timeout: 4),
                    desc: "removing the rule removes the existing chip without reopening the window"
                )
            }
        }

        for swiftShell in [false, true] {
            let name = swiftShell ? "swift_shell_tags_follow_a_reported_host" : "classic_window_tags_follow_a_reported_host"
            UBUITestRegister(name) { context in
                guard let t = context else { return }
                MainActor.assumeIsolated {
                    guard let delegate = SettingsBridge.app else { return }
                    delegate.settingsSaveTag(
                        [
                            "name": "Location test", "color": "red", "matchHost": "ubq-tag-host", "matchProfile": "",
                            "prominence": "quiet",
                        ],
                        at: -1
                    )
                    defer { deleteTagRules(named: "Location test") }
                    let modern =
                        swiftShell
                        ? TerminalWindowController.spawn(arguments: ["/bin/sh"], localePolicy: .auto, sessionLifetime: .outlivesChild)
                        : nil
                    let classic = swiftShell ? nil : t.newWindowRunning(["/bin/sh"])
                    guard let window = modern?.window ?? classic?.window else {
                        t.expect(false, desc: "the test shell opens")
                        return
                    }
                    defer { window.close() }
                    t.pump(0.5)
                    guard let strip = titlebarStrip(of: window) else {
                        t.expect(false, desc: "the shell has a title strip")
                        return
                    }
                    for (host, count) in [("ubq-tag-host", 1), ("ubq-other-host", 0)] {
                        let command = "printf '\\033]7;file://\(host)/tmp\\007'\r"
                        if let modern { modern.shellSendProbe(command) }
                        if let classic { t.sendText(command, to: classic) }
                        t.expect(
                            t.wait(until: { titleChipCount(titleField(in: strip)) == count }, timeout: 8),
                            desc: "a host-only change updates the visible tags"
                        )
                    }
                }
            }
        }

        UBUITestRegister("tag_editor_dot_sets_and_clears_the_windows_tag") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window)
                else {
                    t.expect(false, desc: "a window with a titlebar came up")
                    return
                }
                defer { t.closeAllWindows() }
                guard openIdentityPopover(in: strip, t), let dot = popoverTagDot("red") else {
                    t.expect(false, desc: "the popover opened carrying the red palette dot")
                    return
                }
                t.expect(
                    !tagDotIsSet(dot),
                    desc: "an untagged window shows the dot unset"
                )

                _ = dot.accessibilityPerformPress()
                t.pump(0.4)
                t.expect(
                    manualTags(of: window) == ["red"],
                    desc: "the press sets the hand-set tag named for the dot's colour"
                )
                t.expect(
                    tagDotIsSet(dot),
                    desc: "and the dot now reports itself set"
                )
                t.expect(
                    Int(titleChipCount(titleField(in: strip))),
                    equals: 1,
                    desc: "the title wears exactly one chip"
                )
                t.expect(
                    titleField(in: strip)?.accessibilityLabel()?.hasPrefix("Tagged red") == true,
                    desc: "and speaks the tag it wears"
                )

                _ = dot.accessibilityPerformPress()
                t.pump(0.4)
                t.expect(
                    manualTags(of: window).isEmpty,
                    desc: "a second press clears the tag"
                )
                t.expect(
                    Int(titleChipCount(titleField(in: strip))),
                    equals: 0,
                    desc: "and the title carries no chip"
                )
                closeIdentityPopover(in: strip, t)
            }
        }

        UBUITestRegister("tag_editor_typed_names_reach_the_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window)
                else {
                    t.expect(false, desc: "a window with a titlebar came up")
                    return
                }
                defer { t.closeAllWindows() }
                guard openIdentityPopover(in: strip, t), let field = popoverTagsField() else {
                    t.expect(false, desc: "the popover opened carrying the tag-names field")
                    return
                }

                typeTags(["staging", "eu-west"], into: field, t)
                t.expect(
                    manualTags(of: window) == ["staging", "eu-west"],
                    desc: "the typed names reach the window in the order they were typed"
                )
                t.expect(
                    Int(titleChipCount(titleField(in: strip))),
                    equals: 2,
                    desc: "the title wears one chip per name, not one for the pair"
                )
                t.expect(
                    titleField(in: strip)?.accessibilityLabel()?.hasPrefix("Tagged staging, eu-west") == true,
                    desc: "and speaks both names"
                )
                closeIdentityPopover(in: strip, t)
            }
        }

        UBUITestRegister("tag_editor_escape_leaves_the_tags_untouched") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window)
                else {
                    t.expect(false, desc: "a window with a titlebar came up")
                    return
                }
                defer { t.closeAllWindows() }
                setManualTags(["keeper"], on: window)
                t.pump(0.2)

                guard openIdentityPopover(in: strip, t), let field = popoverTagsField() else {
                    t.expect(false, desc: "the popover opened carrying the tag-names field")
                    return
                }
                field.window?.makeFirstResponder(field)
                field.stringValue = "typed-then-escaped"
                sendKey(53, characters: "\u{1b}", to: field.window)
                t.pump(0.4)

                t.expect(
                    !popoverIsShown(),
                    desc: "escape closes the popover"
                )
                t.expect(
                    manualTags(of: window) == ["keeper"],
                    desc: "and the typed-but-unconfirmed tag is discarded — the window keeps the tag it had"
                )
                t.expect(
                    Int(titleChipCount(titleField(in: strip))),
                    equals: 1,
                    desc: "so the title still wears the one chip it had"
                )
            }
        }

        UBUITestRegister("tag_editor_lights_the_dot_for_a_typed_name_caselessly") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window)
                else {
                    t.expect(false, desc: "a window with a titlebar came up")
                    return
                }
                defer { t.closeAllWindows() }
                guard openIdentityPopover(in: strip, t), let field = popoverTagsField() else {
                    t.expect(false, desc: "the popover opened carrying the tag-names field")
                    return
                }

                typeTags(["RED"], into: field, t)
                t.expect(
                    tagDotIsSet(popoverTagDot("red")),
                    desc: "a name typed in another case lights its palette dot — the dot answers to the name, not to the spelling"
                )

                // Pressing the lit dot must REMOVE the tag the other spelling
                // set. A dot that matched by spelling would add a second one.
                _ = popoverTagDot("red")?.accessibilityPerformPress()
                t.pump(0.4)
                t.expect(
                    manualTags(of: window).isEmpty,
                    desc: "and pressing that dot clears the differently-spelled tag rather than adding a duplicate"
                )
                t.expect(
                    Int(titleChipCount(titleField(in: strip))),
                    equals: 0,
                    desc: "so no chip is left behind"
                )
                closeIdentityPopover(in: strip, t)
            }
        }

        UBUITestRegister("tag_editor_reopens_showing_the_windows_tags") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window)
                else {
                    t.expect(false, desc: "a window with a titlebar came up")
                    return
                }
                defer { t.closeAllWindows() }
                setManualTags(["blue", "ledger"], on: window)
                t.pump(0.2)

                guard openIdentityPopover(in: strip, t), let field = popoverTagsField() else {
                    t.expect(false, desc: "the popover opened carrying the tag-names field")
                    return
                }
                let shown = (field.objectValue as? [Any])?.compactMap { $0 as? String } ?? []
                t.expect(
                    shown == ["blue", "ledger"],
                    desc: "the editor opens showing the tags the window already wears"
                )
                t.expect(
                    tagDotIsSet(popoverTagDot("blue")),
                    desc: "with the palette dot for the colour among them set"
                )
                t.expect(
                    !tagDotIsSet(popoverTagDot("green")),
                    desc: "and a colour the window does not wear left unset"
                )
                closeIdentityPopover(in: strip, t)
            }
        }

        UBUITestRegister("tag_editor_rule_and_hand_set_name_resolve_as_one_loud_tag") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window), let delegate = SettingsBridge.app
                else {
                    t.expect(false, desc: "a window with a titlebar came up")
                    return
                }
                defer {
                    deleteTagRules(named: "production")
                    t.closeAllWindows()
                }
                // A rule that constrains neither host nor profile marks nothing
                // by itself; it declares what the name means when it is applied.
                delegate.settingsSaveTag(
                    [
                        "name": "production", "color": "red", "matchHost": "",
                        "matchProfile": "", "prominence": "loud",
                    ],
                    at: -1
                )
                t.pump(0.4)
                t.expect(
                    Int(titleChipCount(titleField(in: strip))),
                    equals: 0,
                    desc: "the declaration alone marks no window — it constrains no host"
                )

                setManualTags(["PRODUCTION"], on: window)
                t.pump(0.4)
                t.expect(
                    Int(titleChipCount(titleField(in: strip))),
                    equals: 1,
                    desc: "the hand-set name and the rule that declares it resolve as one tag, not two"
                )
                t.expect(
                    titleField(in: strip)?.accessibilityLabel()?.hasPrefix("Tagged PRODUCTION") == true,
                    desc: "and the window keeps the spelling the user typed"
                )
                // The row wears the declared colour mixed into its ground; the
                // colour it mixed is the declaration's own.
                let colors = (window.windowController as? TerminalWindowController)?.loudTagColorsForTesting
                let declared = colors?.color?.usingColorSpace(.sRGB)
                let washed = colors?.wash?.usingColorSpace(.sRGB)
                let wash = titlebarWash(of: window)
                let isSame = { (first: NSColor?, second: NSColor?) -> Bool in
                    guard let first, let second else { return false }
                    return abs(first.redComponent - second.redComponent) < 0.04 && abs(first.greenComponent - second.greenComponent) < 0.04
                        && abs(first.blueComponent - second.blueComponent) < 0.04
                }
                t.expect(
                    declared.map { abs($0.redComponent - 252.0 / 255) < 0.04 && abs($0.blueComponent - 107.0 / 255) < 0.04 } == true
                        && isSame(wash, washed),
                    desc:
                        "the loud declaration washes the whole title row in the colour it declared (declared \(String(describing: declared)), row \(String(describing: wash)), wash \(String(describing: washed)))"
                )
            }
        }

        UBUITestRegister("tag_editor_marks_a_name_no_rule_declares") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window)
                else {
                    t.expect(false, desc: "a window with a titlebar came up")
                    return
                }
                defer { t.closeAllWindows() }

                let restingWash = titlebarWash(of: window)
                setManualTags(["experiments"], on: window)
                t.pump(0.4)
                t.expect(
                    Int(titleChipCount(titleField(in: strip))),
                    equals: 1,
                    desc: "a name no rule declares and no palette names still marks the window"
                )
                t.expect(
                    titleField(in: strip)?.accessibilityLabel()?.hasPrefix("Tagged experiments") == true,
                    desc: "and is spoken by name"
                )
                // The row is always painted — by the theme. What a quiet tag
                // must not do is repaint it: only a loud one washes.
                t.expect(
                    titlebarWash(of: window) == restingWash,
                    desc: "a quiet tag leaves the title row the colour the theme gave it"
                )
            }
        }

        UBUITestRegister("tag_editor_tags_survive_a_workspace_round_trip") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t), let delegate = SettingsBridge.app else {
                    t.expect(false, desc: "a window came up")
                    return
                }
                defer { t.closeAllWindows() }
                setManualTags(["shipping", "blue"], on: window)
                t.pump(0.3)

                let workspace = "uitest-tag-workspace"
                t.expect(
                    delegate.saveCurrentLayout(withName: workspace),
                    desc: "the arrangement saves as a named workspace"
                )
                t.closeAllWindows()
                t.pump(0.5)

                let entry = delegate.sessionPickerEntries().first { $0["name"] == workspace }
                guard let identifier = entry?["id"] else {
                    t.expect(false, desc: "the saved workspace is offered back by the picker")
                    return
                }
                delegate.openSession(withIdentifier: identifier)
                let reopened = t.wait(until: { !liveTerminalWindows().isEmpty }, timeout: 6.0)
                t.expect(reopened, desc: "the workspace reopens its window")
                guard reopened, let restored = liveTerminalWindows().first else { return }
                t.pump(0.8)

                t.expect(
                    manualTags(of: restored) == ["shipping", "blue"],
                    desc: "and the window comes back wearing the tags it was saved with"
                )
                t.expect(
                    Int(titlebarStrip(of: restored).flatMap(titleField(in:)).map(titleChipCount) ?? -1),
                    equals: 2,
                    desc: "so its title wears both chips again"
                )
            }
        }

        UBUITestRegister("tag_editor_rules_button_opens_the_rule_editor_for_the_host") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window)
                else {
                    t.expect(false, desc: "a window with a titlebar came up")
                    return
                }
                defer {
                    dismissEditSheet(t)
                    settingsPanelWindow()?.close()
                    t.closeAllWindows()
                }
                // The window is reached over ssh, so the rule the jump offers to
                // write is the one that would mark this machine.
                markRemoteSSHHost("prod-1.example", on: window)
                t.pump(0.2)

                guard openIdentityPopover(in: strip, t),
                    let rules = popoverView("titlebarDocumentActions.tagRules") as? NSButton
                else {
                    t.expect(false, desc: "the popover opened carrying the Rules… button")
                    return
                }
                rules.performClick(nil)
                t.pump(1.2)

                t.expect(
                    settingsPanelWindow() != nil,
                    desc: "the jump opens the Settings window"
                )
                t.expect(
                    TagRulePrefill.takePendingHost() == nil,
                    desc: "and the Tags pane took the stashed host, so a later reload cannot reopen the editor"
                )
                let opened = t.wait(until: { anythingOnScreenReports("prod-1.example") }, timeout: 3.0)
                t.expect(
                    opened,
                    desc: "the new rule opens prefilled with the host the window is connected to"
                        + (opened ? "" : " (on screen: \(visibleStrings().joined(separator: " / ")))")
                )
            }
        }
        UBUITestRegister("swift_shell_rules_button_opens_the_rule_editor_for_the_host") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer {
                    dismissEditSheet(t)
                    settingsPanelWindow()?.close()
                    window.close()
                }
                window.orderFront(nil)
                t.pump(0.4)
                guard let strip = titlebarStrip(of: window) else {
                    t.expect(false, desc: "the window has a titlebar strip")
                    return
                }
                // The window is reached over ssh, so the rule the jump offers to
                // write is the one that would mark this machine. Set directly
                // on the controller, which is where a remote spawn stamps it.
                shell.remoteHostKey = "prod-2.example"

                guard openIdentityPopover(in: strip, t),
                    let rules = popoverView("titlebarDocumentActions.tagRules") as? NSButton
                else {
                    t.expect(false, desc: "the popover opened carrying the Rules… button")
                    return
                }
                rules.performClick(nil)
                t.pump(1.2)

                t.expect(
                    settingsPanelWindow() != nil,
                    desc: "the jump opens the Settings window"
                )
                t.expect(
                    TagRulePrefill.takePendingHost() == nil,
                    desc: "and the Tags pane took the stashed host, so a later reload cannot reopen the editor"
                )
                let opened = t.wait(until: { anythingOnScreenReports("prod-2.example") }, timeout: 3.0)
                t.expect(
                    opened,
                    desc: "the new rule opens prefilled with the host the window is connected to"
                        + (opened ? "" : " (on screen: \(visibleStrings().joined(separator: " / ")))")
                )
            }
        }
        UBUITestRegister("swift_shell_titlebar_identity_writes_the_names") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.orderFront(nil)
                t.pump(0.4)
                guard let strip = titlebarStrip(of: window) else {
                    t.expect(false, desc: "the window has a titlebar strip")
                    return
                }
                // A name already on the window, so the fields below are asked
                // whether they SHOW what it wears rather than only whether
                // they write.
                shell.setCustomTitles(window: "standing name")
                t.pump(0.2)

                // The row opens the popover, which is the whole affordance:
                // without it the per-tab and per-window names have no way in on
                // this shell.
                t.expect(
                    openIdentityPopover(in: strip, t),
                    desc: "the title row opens the identity popover"
                )
                defer { closeIdentityPopover(in: strip, t) }

                guard let windowField = popoverView("titlebarDocumentActions.windowTitle") as? NSTextField,
                    let tabField = popoverView("titlebarDocumentActions.tabTitle") as? NSTextField
                else {
                    t.expect(false, desc: "the popover carries both name fields")
                    return
                }
                t.expect(
                    windowField.stringValue == "standing name",
                    desc: "and shows the name the window already wears (\(windowField.stringValue.debugDescription))"
                )

                // An edit reaches the window: the name is held where the
                // composition already reads it, so Core's ranking decides what
                // it does rather than the popover.
                windowField.stringValue = "named window"
                windowField.sendAction(windowField.action, to: windowField.target)
                tabField.stringValue = "named tab"
                tabField.sendAction(tabField.action, to: tabField.target)
                t.pump(0.4)
                t.expect(
                    shell.customWindowTitle == "named window",
                    desc: "the window name reaches the controller (\(shell.customWindowTitle.debugDescription))"
                )
                t.expect(
                    shell.customTabTitle == "named tab",
                    desc: "and so does the tab name (\(shell.customTabTitle.debugDescription))"
                )
                t.expect(
                    window.title.contains("named window"),
                    desc: "and the window wears it (\(window.title.debugDescription))"
                )
                let tabTitle = window.tab.attributedTitle?.string
                t.expect(
                    tabTitle?.contains("named tab") == true
                        && window.tab.title == tabTitle && window.tab.toolTip == tabTitle,
                    desc: "the tab label and untruncated tooltip share the tab name instead of the window name"
                )

                // The grid fields resize the window rather than reporting it:
                // a reader who types 100x30 means the terminal to become that.
                if let columnsField = popoverView("titlebarDocumentActions.columns") as? NSTextField,
                    let rowsField = popoverView("titlebarDocumentActions.rows") as? NSTextField
                {
                    let before = window.frame.size
                    columnsField.stringValue = "100"
                    columnsField.sendAction(columnsField.action, to: columnsField.target)
                    rowsField.stringValue = "30"
                    rowsField.sendAction(rowsField.action, to: rowsField.target)
                    t.pump(0.5)
                    t.expect(
                        window.frame.size != before,
                        desc: "a typed grid size resizes the window (\(before) -> \(window.frame.size))"
                    )
                } else {
                    t.expect(false, desc: "the popover carries the grid fields")
                }

                // A tag set through the popover's dot strip lands on the
                // window, which is what the markers are drawn from.
                if let dot = popoverTagDot("red") {
                    // Pressed the way a screen reader presses it.
                    _ = dot.accessibilityPerformPress()
                    t.pump(0.4)
                }
                t.expect(
                    shell.manualTags == ["red"],
                    desc: "a palette dot tags the window (\(shell.manualTags))"
                )
            }
        }

        UBUITestRegister("tag_chip_matches_native_indicator_height_without_clipping") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t) else {
                    t.expect(false, desc: "a window came up")
                    return
                }
                defer { t.closeAllWindows() }
                // A name with a descender, because a capsule that hangs below
                // the line takes the p with it when the field clips.
                setManualTags(["purple"], on: window)
                t.pump(0.8)
                guard let strip = titlebarStrip(of: window), let field = titleField(in: strip),
                    let titleFont = field.font
                else {
                    t.expect(false, desc: "the window has a title field carrying a font")
                    return
                }
                let title = field.attributedStringValue
                guard title.length > 0,
                    let chip = title.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
                else {
                    t.expect(false, desc: "the title leads with a tag chip")
                    return
                }
                let capsule = chip.bounds
                let used = title.boundingRect(with: NSSize(width: 4000, height: 4000), options: [.usesLineFragmentOrigin])
                let geometry =
                    "capsule \(capsule.minY)..\(capsule.maxY) of \(capsule.height)pt, "
                    + "line \(titleFont.descender)..\(titleFont.ascender), "
                    + "field \(field.frame.height)pt, laid out \(used.height)pt"
                t.expect(
                    abs(capsule.height - 22) <= 0.01 && abs(capsule.height - TitlebarCapsuleGeometry.standardHeight) <= 0.01,
                    desc: "the tag uses the title row's 22-point capsule height — \(geometry)"
                )
                if let row = field.superview {
                    // The attachment's bounds are measured from the title's
                    // baseline, upward.
                    let baselineInField =
                        field.isFlipped ? field.firstBaselineOffsetFromTop : field.bounds.height - field.firstBaselineOffsetFromTop
                    let baseline = field.convert(NSPoint(x: 0, y: baselineInField), to: row).y
                    let edges = [capsule.minY, capsule.maxY].map { baseline + (row.isFlipped ? -$0 : $0) }
                    let span = (edges.min() ?? 0)...(edges.max() ?? 0)
                    t.expect(
                        span.lowerBound >= row.bounds.minY + 1 && span.upperBound <= row.bounds.maxY - 1,
                        desc: "the capsule clears the title row's top and bottom edges (\(span) in \(row.bounds))"
                    )
                }
                t.expect(
                    abs(capsule.midY - titleFont.capHeight / 2) <= 0.01,
                    desc: "the tag and title share a cap-height center — \(geometry)"
                )
                t.expect(
                    field.bounds.height >= ceil(used.height),
                    desc: "the title field contains the full tag instead of clipping it — \(geometry)"
                )
                let taggedHeight = field.frame.height
                let taggedCenter = field.frame.midY
                var resetFrame = field.frame
                resetFrame.origin.y += (resetFrame.height - 16) / 2
                resetFrame.size.height = 16
                field.frame = resetFrame
                t.pump(0.3)
                t.expect(
                    field.frame.height == taggedHeight,
                    desc: "a same-width native title-height reset is repaired without changing the tag"
                )
                setManualTags([], on: window)
                t.pump(0.5)
                t.expect(field.frame.height < taggedHeight, desc: "removing the tag restores the ordinary title height")
                t.expect(abs(field.frame.midY - taggedCenter) <= 0.5, desc: "adding a tag does not move the title row's center")
            }
        }

        UBUITestRegister("tag_labels_keep_accents_and_descenders_inside_scaled_capsules") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }
                for scale in [0.5, 1.0, 1.75, 2.0] {
                    t.restoreConfiguration(saved)
                    t.configureAppending("[appearance]\nui_font_scale = \(scale)\n")
                    let run = TitlebarTagChip.attributedRun(
                        for: [TitlebarTagMarker(name: "Épgy", color: .white, prominence: .quiet)],
                        titleFont: .systemFont(ofSize: 13, weight: .semibold),
                        uncoloredFill: .white,
                        tint: nil
                    )
                    guard let attachment = run.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment,
                        let image = attachment.image,
                        let bitmap = NSBitmapImageRep(
                            bitmapDataPlanes: nil,
                            pixelsWide: Int(ceil(image.size.width * 2)),
                            pixelsHigh: Int(image.size.height * 2),
                            bitsPerSample: 8,
                            samplesPerPixel: 4,
                            hasAlpha: true,
                            isPlanar: false,
                            colorSpaceName: .deviceRGB,
                            bytesPerRow: 0,
                            bitsPerPixel: 0
                        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
                    else {
                        t.expect(false, desc: "the tag has a rasterizable image at scale \(scale)")
                        continue
                    }
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = graphics
                    let bounds = NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
                    NSColor.clear.setFill()
                    bounds.fill(using: .copy)
                    image.draw(in: bounds)
                    NSGraphicsContext.restoreGraphicsState()
                    var ink = NSRect.null
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            guard let pixel = bitmap.colorAt(x: x, y: y),
                                pixel.alphaComponent > 0.9, pixel.redComponent < 0.4
                            else { continue }
                            ink = ink.union(NSRect(x: x, y: y, width: 1, height: 1))
                        }
                    }
                    t.expect(
                        !ink.isNull && ink.minY >= 2 && ink.maxY <= CGFloat(bitmap.pixelsHigh - 2),
                        desc: "accented and descending glyphs keep clear pixels above and below at scale \(scale): \(ink)"
                    )
                    t.expect(image.size.height == 22, desc: "UI font scaling preserves the 22-point capsule height")
                }
            }
        }

        UBUITestRegister("tag_editor_icon_found_by_search_is_written_to_the_rule") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let delegate = SettingsBridge.app else { return }
                delegate.settingsSaveTag(
                    [
                        "name": "Icon test", "color": "blue", "matchHost": "ubq-icon-test", "matchProfile": "",
                        "prominence": "",
                    ],
                    at: -1
                )
                defer {
                    dismissEditSheet(t)
                    settingsPanelWindow()?.close()
                    deleteTagRules(named: "Icon test")
                }
                guard let picker = openRuleEditor(titled: "Icon test", t) else {
                    t.expect(false, desc: "the rule's editor opens carrying the icon picker")
                    return
                }
                t.expect(picker.title == "No Icon", desc: "a rule without an icon says so (\(picker.title.debugDescription))")
                t.expect(
                    (popoverView("tagEditor.iconWeight") as? NSSegmentedControl)?.isEnabled == false,
                    desc: "and offers no weight while there is no icon to draw in it"
                )

                picker.performClick(nil)
                t.pump(0.4)
                guard let search = popoverView("tagIconPicker.search") as? NSSearchField else {
                    t.expect(false, desc: "the picker opens its grid under a search field")
                    return
                }
                // Editing ends before the query is set, so the field editor the
                // grid opened with cannot write its empty text back over it.
                search.window?.makeFirstResponder(nil)
                search.stringValue = "rocket launch"
                search.sendAction(search.action, to: search.target)
                t.pump(0.3)
                t.expect(
                    popoverView("tagIconPicker.icon.rocket-launch")?.accessibilityLabel() == "rocket launch",
                    desc: "the best match is in the grid, spoken with spaces for its hyphens"
                )
                // Return from the search field, the key a reader who typed the
                // query presses next.
                search.window?.makeFirstResponder(search)
                sendKey(36, characters: "\r", to: search.window)
                t.pump(0.4)
                t.expect(
                    picker.iconName == "rocket-launch",
                    desc: "Return picks the best match (\(picker.iconName.debugDescription))"
                )
                t.expect(!popoverIsShown(), desc: "and closes the grid")
                t.expect(
                    (popoverView("tagEditor.iconWeight") as? NSSegmentedControl)?.isEnabled == true,
                    desc: "the weight is offered once there is an icon"
                )

                saveRuleEditor(t)
                let block = tagBlock(titled: "Icon test") ?? []
                t.expect(block.contains("icon = \"rocket-launch\""), desc: "Save writes the icon into the rule's block (\(block))")
                t.expect(
                    !block.contains { $0.hasPrefix("icon_weight") },
                    desc: "and writes no weight for the default fill"
                )
            }
        }

        UBUITestRegister("tag_editor_regular_weight_is_written_to_the_rule") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let delegate = SettingsBridge.app else { return }
                delegate.settingsSaveTag(
                    [
                        "name": "Weight test", "color": "green", "matchHost": "ubq-weight-test", "matchProfile": "",
                        "prominence": "", "icon": "database",
                    ],
                    at: -1
                )
                defer {
                    dismissEditSheet(t)
                    settingsPanelWindow()?.close()
                    deleteTagRules(named: "Weight test")
                }
                t.expect(
                    tagBlock(titled: "Weight test")?.contains("icon = \"database\"") == true,
                    desc: "the rule starts with its icon written and no weight"
                )
                guard let picker = openRuleEditor(titled: "Weight test", t),
                    let weight = popoverView("tagEditor.iconWeight") as? NSSegmentedControl
                else {
                    t.expect(false, desc: "the rule's editor opens carrying the icon picker and its weight")
                    return
                }
                t.expect(picker.iconName == "database", desc: "the editor opens on the rule's icon")
                t.expect(
                    weight.isEnabled && weight.selectedSegment == 0,
                    desc: "in the default fill (segment \(weight.selectedSegment))"
                )

                weight.selectedSegment = 1
                weight.sendAction(weight.action, to: weight.target)
                t.pump(0.3)
                t.expect(
                    PhosphorIcons.spelling(of: picker.iconWeight) == "regular",
                    desc: "the picker draws the icon in the weight chosen"
                )

                saveRuleEditor(t)
                let block = tagBlock(titled: "Weight test") ?? []
                t.expect(block.contains("icon_weight = \"regular\""), desc: "Save writes the regular weight (\(block))")
                t.expect(block.contains("icon = \"database\""), desc: "beside the icon it is the weight of")
            }
        }

        UBUITestRegister("tag_editor_custom_color_is_written_as_rrggbb") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let delegate = SettingsBridge.app else { return }
                delegate.settingsSaveTag(
                    [
                        "name": "Color test", "color": "red", "matchHost": "ubq-color-test", "matchProfile": "",
                        "prominence": "",
                    ],
                    at: -1
                )
                defer {
                    NSColorPanel.shared.orderOut(nil)
                    dismissEditSheet(t)
                    settingsPanelWindow()?.close()
                    deleteTagRules(named: "Color test")
                }
                guard openRuleEditor(titled: "Color test", t) != nil,
                    let swatch = popoverView("tagEditor.customColor") as? TagCustomColorSwatch
                else {
                    t.expect(false, desc: "the rule's editor opens carrying the custom swatch")
                    return
                }
                t.expect(swatch.accessibilityValue() == nil, desc: "a palette colour leaves the custom swatch unchosen")

                _ = swatch.accessibilityPerformPress()
                t.pump(0.3)
                t.expect(NSColorPanel.shared.isVisible, desc: "a press on the custom swatch opens the colour panel")
                swatch.takeColorForTesting(NSColor(srgbRed: 0x3a / 255.0, green: 0x7b / 255.0, blue: 0xd5 / 255.0, alpha: 1))
                t.pump(0.3)
                NSColorPanel.shared.orderOut(nil)

                saveRuleEditor(t)
                let block = tagBlock(titled: "Color test") ?? []
                t.expect(block.contains("color = \"#3a7bd5\""), desc: "Save writes the chosen colour as #rrggbb (\(block))")

                // Reopened, the rule's literal is the custom swatch's colour,
                // chosen, rather than no swatch at all.
                guard openRuleEditor(titled: "Color test", t) != nil,
                    let reopened = popoverView("tagEditor.customColor") as? TagCustomColorSwatch
                else {
                    t.expect(false, desc: "the rule's editor opens again")
                    return
                }
                t.expect(
                    (reopened.accessibilityValue() as? String) == "#3a7bd5",
                    desc: "a rule whose colour is a literal opens with the custom swatch chosen in that colour"
                )
            }
        }

        UBUITestRegister("tag_editor_cleared_icon_leaves_the_rule") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let delegate = SettingsBridge.app else { return }
                delegate.settingsSaveTag(
                    [
                        "name": "Clear test", "color": "purple", "matchHost": "ubq-clear-test", "matchProfile": "",
                        "prominence": "", "icon": "flame", "iconWeight": "regular",
                    ],
                    at: -1
                )
                defer {
                    dismissEditSheet(t)
                    settingsPanelWindow()?.close()
                    deleteTagRules(named: "Clear test")
                }
                let before = tagBlock(titled: "Clear test") ?? []
                t.expect(
                    before.contains("icon = \"flame\"") && before.contains("icon_weight = \"regular\""),
                    desc: "the rule starts with an icon and its weight (\(before))"
                )
                guard let picker = openRuleEditor(titled: "Clear test", t) else {
                    t.expect(false, desc: "the rule's editor opens carrying the icon picker")
                    return
                }
                picker.performClick(nil)
                t.pump(0.4)
                guard let none = popoverView("tagIconPicker.none") as? NSButton else {
                    t.expect(false, desc: "the picker's grid offers No Icon")
                    return
                }
                none.performClick(nil)
                t.pump(0.4)
                t.expect(picker.iconName.isEmpty && picker.title == "No Icon", desc: "No Icon clears the picker")
                t.expect(
                    (popoverView("tagEditor.iconWeight") as? NSSegmentedControl)?.isEnabled == false,
                    desc: "and withdraws the weight"
                )

                saveRuleEditor(t)
                let block = tagBlock(titled: "Clear test") ?? []
                t.expect(!block.isEmpty, desc: "the rule itself stays")
                t.expect(
                    !block.contains { $0.hasPrefix("icon") },
                    desc: "Save removes the icon line, and the weight's with it (\(block))"
                )
            }
        }

        registerShowName()
        registerPlacement()
        registerReorder()
    }

    // MARK: - Show name

    private static func registerShowName() {
        UBUITestRegister("tag_editor_show_name_draws_the_icon_alone") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let delegate = SettingsBridge.app else { return }
                guard PhosphorIcons.icon(named: "buildings") != nil else {
                    t.expect(false, desc: "the app bundle carries the Phosphor catalog")
                    return
                }
                // A rule with no match declares how a hand-set tag of its name
                // is drawn, so the window needs no host to wear it.
                delegate.settingsSaveTag(
                    [
                        "name": "Show test", "color": "blue", "matchHost": "", "matchProfile": "", "prominence": "",
                        "icon": "buildings",
                    ],
                    at: -1
                )
                defer {
                    dismissEditSheet(t)
                    settingsPanelWindow()?.close()
                    deleteTagRules(named: "Show test")
                    t.closeAllWindows()
                }
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window) else {
                    t.expect(false, desc: "a window with a titlebar came up")
                    return
                }
                setManualTags(["Show test"], on: window)
                let marker = { titleMarks(titleField(in: strip)).first }
                let spoken = { titleField(in: strip)?.accessibilityLabel() ?? "" }
                t.expect(
                    t.wait(until: { marker()?.iconName == "buildings" }, timeout: 4),
                    desc: "the window's marker wears the rule's icon (\(marker()?.iconName ?? "no marker"))"
                )
                t.expect(
                    marker()?.name == "Show test" && marker()?.textFrame != nil,
                    desc: "with the name shown, the marker is the icon and the name ('\(marker()?.name ?? "")')"
                )

                guard openRuleEditor(titled: "Show test", t) != nil,
                    let checkbox = popoverView("tagEditor.showName") as? NSButton
                else {
                    t.expect(false, desc: "the rule's editor opens carrying the Show name check box")
                    return
                }
                t.expect(checkbox.state == .on && checkbox.isEnabled, desc: "a titled rule opens with Show name checked")
                checkbox.performClick(nil)
                t.pump(0.3)
                t.expect(checkbox.state == .off, desc: "a press clears it")
                saveRuleEditor(t)
                let hidden = tagBlock(titled: "Show test") ?? []
                t.expect(hidden.contains("show_name = false"), desc: "Save writes show_name = false into the rule (\(hidden))")
                t.expect(
                    t.wait(until: { marker()?.name.isEmpty == true }, timeout: 4),
                    desc: "unchecked, the marker draws no name ('\(marker()?.name ?? "no marker")')"
                )
                t.expect(
                    marker()?.iconName == "buildings" && marker()?.textFrame == nil,
                    desc: "it is the icon alone, in a circle"
                )
                // The name is still the tag's, for a screen reader above all.
                t.expect(
                    marker()?.image.accessibilityDescription == "Show test",
                    desc: "the icon is spoken by the tag's name (\(marker()?.image.accessibilityDescription ?? "nil"))"
                )
                t.expect(spoken().hasPrefix("Tagged Show test"), desc: "and the title still names the tag ('\(spoken())')")
                t.expect(manualTags(of: window) == ["Show test"], desc: "the hand-set name still matches the rule")

                // Without an icon, a hidden name leaves the colour's dot.
                guard let picker = openRuleEditor(titled: "Show test", t) else {
                    t.expect(false, desc: "the rule's editor opens again")
                    return
                }
                picker.performClick(nil)
                t.pump(0.4)
                guard let noIcon = popoverView("tagIconPicker.none") as? NSButton else {
                    t.expect(false, desc: "the picker's grid offers No Icon")
                    return
                }
                noIcon.performClick(nil)
                t.pump(0.4)
                t.expect(picker.iconName.isEmpty, desc: "No Icon clears the picker")
                saveRuleEditor(t)
                t.expect(
                    t.wait(until: { marker()?.iconName.isEmpty == true }, timeout: 4),
                    desc: "a rule with no icon draws no icon ('\(marker()?.iconName ?? "no marker")')"
                )
                t.expect(
                    marker()?.name.isEmpty == true && marker()?.textFrame == nil && marker()?.ink == nil,
                    desc: "and with its name hidden draws the colour's dot alone"
                )
                t.expect(marker()?.image.accessibilityDescription == "Show test", desc: "spoken by the tag's name")

                // Checked again, the name comes back and the line goes.
                guard openRuleEditor(titled: "Show test", t) != nil,
                    let again = popoverView("tagEditor.showName") as? NSButton
                else {
                    t.expect(false, desc: "the rule's editor opens a third time")
                    return
                }
                t.expect(again.state == .off, desc: "the editor opens on the hidden name")
                again.performClick(nil)
                t.pump(0.3)
                saveRuleEditor(t)
                t.expect(
                    !(tagBlock(titled: "Show test") ?? []).contains { $0.hasPrefix("show_name") },
                    desc: "Save writes no show_name line for the default"
                )
                t.expect(
                    t.wait(until: { marker()?.name == "Show test" && marker()?.textFrame != nil }, timeout: 4),
                    desc: "the marker draws the name again"
                )
            }
        }
    }

    // MARK: - Placement

    private static func registerPlacement() {
        UBUITestRegister("tag_editor_show_in_tabs_off_leaves_the_title_bar_mark") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let delegate = SettingsBridge.app else { return }
                // Every window matches `*`, a local one included, so the rule
                // marks the window by itself.
                delegate.settingsSaveTag(
                    ["name": "Place test", "color": "green", "matchHost": "*", "matchProfile": "", "prominence": ""],
                    at: -1
                )
                defer {
                    dismissEditSheet(t)
                    settingsPanelWindow()?.close()
                    deleteTagRules(named: "Place test")
                    t.closeAllWindows()
                }
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window) else {
                    t.expect(false, desc: "a window with a titlebar came up")
                    return
                }
                let inTitleBar = { titleMarks(titleField(in: strip)).contains { $0.name == "Place test" } }
                let inTab = { (tabTagMark(of: window)?.image?.accessibilityDescription ?? "").contains("Place test") }
                t.expect(
                    t.wait(until: { inTitleBar() && inTab() }, timeout: 4),
                    desc:
                        "the rule's tag is in the title bar and on the tab ('\(titleField(in: strip)?.accessibilityLabel() ?? "")', tab '\(tabTagMark(of: window)?.image?.accessibilityDescription ?? "none")')"
                )

                guard openRuleEditor(titled: "Place test", t) != nil,
                    let tabs = popoverView("tagEditor.showInTabs") as? NSButton,
                    let titleBar = popoverView("tagEditor.showInTitleBar") as? NSButton,
                    let paneHeaders = popoverView("tagEditor.showInPaneHeaders") as? NSButton
                else {
                    t.expect(false, desc: "the rule's editor opens carrying the three Show in check boxes")
                    return
                }
                t.expect(
                    tabs.state == .on && titleBar.state == .on && paneHeaders.state == .on,
                    desc: "a rule is shown everywhere until it says otherwise"
                )
                tabs.performClick(nil)
                t.pump(0.3)
                saveRuleEditor(t)
                let block = tagBlock(titled: "Place test") ?? []
                t.expect(block.contains("show_in_tabs = false"), desc: "Save writes show_in_tabs = false (\(block))")
                t.expect(
                    !block.contains { $0.hasPrefix("show_in_title_bar") || $0.hasPrefix("show_in_pane_headers") },
                    desc: "and no line for the places left on"
                )
                t.expect(
                    t.wait(until: { !inTab() }, timeout: 4),
                    desc: "the tag's mark is gone from the tab ('\(tabTagMark(of: window)?.image?.accessibilityDescription ?? "none")')"
                )
                t.expect(inTitleBar(), desc: "and still in the title bar ('\(titleField(in: strip)?.accessibilityLabel() ?? "")')")
                t.expect(
                    !(window.tab.toolTip ?? "").contains("Place test"),
                    desc: "the tab's tooltip names only what the tab draws ('\(window.tab.toolTip ?? "")')"
                )
            }
        }
    }

    // MARK: - Order

    private static func registerReorder() {
        UBUITestRegister("tag_rules_reorder_moves_the_tab_marks_and_the_file") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let delegate = SettingsBridge.app else { return }
                guard PhosphorIcons.icon(named: "star") != nil else {
                    t.expect(false, desc: "the app bundle carries the Phosphor catalog")
                    return
                }
                delegate.settingsSaveTag(
                    ["name": "Order alpha", "color": "red", "matchHost": "*", "matchProfile": "", "prominence": ""],
                    at: -1
                )
                delegate.settingsSaveTag(
                    ["name": "Order beta", "color": "blue", "matchHost": "*", "matchProfile": "", "prominence": "", "icon": "star"],
                    at: -1
                )
                defer {
                    deleteTagRules(named: "Order alpha")
                    deleteTagRules(named: "Order beta")
                    t.closeAllWindows()
                }
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window) else {
                    t.expect(false, desc: "a window with a titlebar came up")
                    return
                }
                let position = { (name: String) -> Int in
                    let rule = delegate.settingsTags().first { ($0["name"] as? String) == name }
                    return (rule?["index"] as? Int) ?? -1
                }
                // The two rules' marks, in the order the tab draws them.
                let tabOrder = { () -> [String] in
                    guard let mark = tabTagMark(of: window) else { return [] }
                    let spoken = (mark.image?.accessibilityDescription ?? "").dropFirst("Tagged ".count)
                    return spoken.components(separatedBy: ", ").filter { $0.hasPrefix("Order ") }
                }
                let titleOrder = { titleMarks(titleField(in: strip)).map(\.name).filter { $0.hasPrefix("Order ") } }
                t.expect(
                    t.wait(until: { tabOrder() == ["Order alpha", "Order beta"] }, timeout: 4),
                    desc: "the tab draws the rules in file order (\(tabOrder()))"
                )
                t.expect(titleOrder() == ["Order alpha", "Order beta"], desc: "and so does the title bar (\(titleOrder()))")
                let alpha = position("Order alpha")
                let beta = position("Order beta")
                t.expect(alpha >= 0 && beta == alpha + 1, desc: "the rules stand one after the other (\(alpha), \(beta))")
                if let mark = tabTagMark(of: window), mark.iconNames.count >= 2 {
                    let drawn = Array(mark.iconNames.suffix(2))
                    t.expect(drawn == ["", "star"], desc: "the tab draws alpha's dot, then beta's star (\(mark.iconNames))")
                }

                // The move every reorder in Settings makes: a drop, Move Up
                // or Move Down all write it through this one call.
                delegate.settingsMoveTag(from: beta, to: alpha)
                t.expect(
                    t.wait(until: { tabOrder() == ["Order beta", "Order alpha"] }, timeout: 4),
                    desc: "moved ahead, beta's mark comes first on the tab (\(tabOrder()))"
                )
                t.expect(titleOrder() == ["Order beta", "Order alpha"], desc: "and in the title bar (\(titleOrder()))")
                if let mark = tabTagMark(of: window), mark.iconNames.count >= 2 {
                    t.expect(
                        Array(mark.iconNames.suffix(2)) == ["star", ""],
                        desc: "the tab draws beta's star, then alpha's dot (\(mark.iconNames))"
                    )
                }
                t.expect(
                    position("Order beta") == alpha && position("Order alpha") == alpha + 1,
                    desc: "Settings lists the rules in their new order"
                )
                let document = String(Ubiquitty.Preferences.liveDocument().pointee)
                let betaAt = document.range(of: "name = \"Order beta\"")?.lowerBound
                let alphaAt = document.range(of: "name = \"Order alpha\"")?.lowerBound
                t.expect(
                    betaAt != nil && alphaAt != nil && betaAt! < alphaAt!,
                    desc: "the file holds beta's block ahead of alpha's"
                )
                t.expect(
                    tagBlock(titled: "Order beta")?.contains("icon = \"star\"") == true,
                    desc: "and the moved block keeps its keys (\(tagBlock(titled: "Order beta") ?? []))"
                )
            }
        }
    }
}

/// Opens the rule editor on the `[[tags]]` rule titled `name`, the way a
/// window's jump to the rule it matched does, and waits for its icon picker.
///
/// - Parameters:
///   - name: The rule's title.
///   - t: The running context.
/// - Returns: The editor's icon picker, or nil when the editor did not open.
@MainActor
private func openRuleEditor(titled name: String, _ t: UBUITestContext) -> TagIconPicker? {
    let rule = SettingsBridge.app?.settingsTags().first { ($0["name"] as? String) == name }
    guard let index = rule?["index"] as? Int else { return nil }
    TagRulePrefill.open(ruleIndex: index)
    _ = t.wait(until: { popoverView("tagEditor.icon") is TagIconPicker }, timeout: 3)
    return popoverView("tagEditor.icon") as? TagIconPicker
}

/// Saves the open rule editor as its Save button does, and waits for the
/// sheet to go, so the next lookup cannot find the controls of this one.
///
/// - Parameter t: The running context.
@MainActor
private func saveRuleEditor(_ t: UBUITestContext) {
    TagsPane.saveEditorForTesting?()
    _ = t.wait(until: { popoverView("tagEditor.icon") == nil }, timeout: 3)
    t.pump(0.2)
}

/// The lines of the `[[tags]]` block titled `name`, as the live document
/// spells them, trimmed.
///
/// Read from the document rather than from Core's parsed values: what these
/// scenarios assert is the text Save writes, and a line the parser ignores
/// would pass a check of the values.
///
/// - Parameter name: The rule's title.
/// - Returns: The block's lines, or nil when no block carries that title.
@MainActor
private func tagBlock(titled name: String) -> [String]? {
    let lines = String(Ubiquitty.Preferences.liveDocument().pointee)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    var block: [String] = []
    var isInTags = false
    // A closing header flushes the last block like any other.
    for line in lines + ["["] {
        if line.hasPrefix("[") {
            if isInTags, block.contains("name = \"\(name)\"") {
                return block
            }
            isInTags = line == "[[tags]]"
            block = []
        } else if isInTags {
            block.append(line)
        }
    }
    return nil
}

/// Whether any view the app is showing carries this string.
///
/// The rule editor arrives as a SwiftUI sheet, which is a window of its own
/// rather than a subview of the Settings window, and its fields publish their
/// contents through the accessibility value rather than through
/// `NSTextField.stringValue`. Both are swept, over every window, so the
/// assertion is about what is on screen and not about how SwiftUI builds it.
///
/// - Parameter needle: The string to look for.
/// - Returns: Whether some visible view reports it.
@MainActor
func anythingOnScreenReports(_ needle: String) -> Bool {
    visibleStrings().contains { $0.contains(needle) }
}

/// Every string the app is showing, swept the way the lookup above sweeps.
///
/// A refusal about a string that is missing has to say what stood in its
/// place, or the reader cannot tell an empty pane from a pane showing the
/// wrong thing.
///
/// - Returns: The field contents and spoken values of every visible view.
@MainActor
func visibleStrings() -> [String] {
    var found: [String] = []
    var stack: [NSView] = NSApp.windows.filter(\.isVisible).compactMap(\.contentView)
    while let view = stack.popLast() {
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            found.append(field.stringValue)
        }
        if let spoken = view.accessibilityValue() as? String, !spoken.isEmpty {
            found.append(spoken)
        }
        stack.append(contentsOf: view.subviews)
    }
    return found
}
