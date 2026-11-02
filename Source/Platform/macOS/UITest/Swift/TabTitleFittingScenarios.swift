// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// TabTitleFittingScenarios.swift — a tab's label against the room its pill
// has: whole whenever it fits, tightened before it is shortened, and shortened
// by Core's versions before it is truncated in its middle.
//
// Seven tabs share a strip about as wide as a reader's, each running a program
// that names itself whatever line it is sent, so every title is chosen against
// the room the strip measured for its tab. The shortcut hints are on, which
// puts a text accessory in every pill: AppKit stretches that accessory toward
// a short title, which is the frame a room must not be read from.

/// A program that sets the terminal's title to each line it reads.
private let titleEchoProgram = ["/usr/bin/perl", "-e", "$|=1; while (my $line = <STDIN>) { chomp $line; print \"\\e]2;$line\\a\"; }"]

/// Registers the tab-title fitting scenarios with the UI-test runner.
enum TabTitleFittingScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_tab_titles_fit_the_room_their_pills_have") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { titlesFitTheirRooms(t) }
        }
        UBUITestRegister("tab_marks_and_dim_title_runs_wear_dynamic_system_colours") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { marksAndDimRunsWearSystemColours(t) }
        }
    }

    // MARK: - The scenario

    @MainActor
    private static func titlesFitTheirRooms(_ t: UBUITestContext) {
        guard #available(macOS 26.0, *) else { return }
        let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
        defer {
            t.restoreConfiguration(saved)
            TerminalWindowController.applyTitleCompositionToOpenWindows()
        }
        // The program's own title is the label's only part, and no icon leads
        // it, so the label is exactly the line the program was sent.
        let titleKeys: Set<String> = [
            "tab_app_title", "tab_directory", "tab_process", "tab_dimensions", "tab_tty_name",
            "tab_profile_name", "tab_program_status", "tab_shell_command", "tab_text",
        ]
        var document = documentDroppingKeys(titleKeys, inSection: "title", of: saved)
        document = documentDroppingKeys(["show_shortcuts"], inSection: "tabs", of: document)
        document = documentDroppingKeys(["process_icons", "titlebar_style", "background_opacity"], inSection: "appearance", of: document)
        t.restoreConfiguration(
            document
                + "\n[title]\ntab_app_title = true\ntab_directory = false\ntab_process = false\ntab_dimensions = false\n"
                + "tab_tty_name = false\ntab_profile_name = false\ntab_program_status = false\ntab_shell_command = false\n"
                + "[tabs]\nshow_shortcuts = \"always\"\n"
                // A themed strip: a native one keeps AppKit's own titles, which
                // the write-back that measures the rooms leaves alone.
                + "[appearance]\nprocess_icons = false\ntitlebar_style = \"themed\"\nbackground_opacity = 1.0\n"
        )
        TerminalWindowController.applyTitleCompositionToOpenWindows()

        guard let first = openStrip(of: 7, t) else { return }
        defer {
            for window in first.tabGroup?.windows ?? [first] {
                window.close()
            }
        }
        let tabs = { first.tabGroup?.windows ?? [first] }
        guard tabs().count == 7, waitUntilFitted(tabs(), in: first, t) else {
            t.expect(false, desc: "seven tabs are fitted to the rooms their pills have")
            print(describeRooms(of: tabs(), in: first))
            return
        }
        print(describeRooms(of: tabs(), in: first))

        // A label typed short first, as a shell names a tab before the
        // program it starts does: the room it is then fitted to must not be
        // its own width.
        let growing = tabs()[1]
        send("zsh", to: growing)
        _ = t.wait(until: { (growing.tab.attributedTitle?.string ?? "") == "zsh" && isFitted(growing, in: first) }, timeout: 6)
        t.pump(0.4)

        // A background tab that prints is marked unread, and the mark,
        // narrower than the shortcut hint, takes its place, so the room
        // widens. Every other tab prints once first, so each label is chosen
        // against the room it is judged in.
        let others = tabs().filter { $0 !== growing }
        for window in others {
            send("Printed once", to: window)
        }
        _ = t.wait(
            until: { others.allSatisfy { ($0.tab.attributedTitle?.string ?? "") == "Printed once" && isFitted($0, in: first) } },
            timeout: 10
        )
        t.pump(0.4)

        // Every tab's title, chosen against its own room and face.
        var expectations: [(window: NSWindow, title: String, what: String)] = []
        for (index, window) in tabs().enumerated() {
            guard let room = TabStripStyling.titleRoomForTesting(inGroupOf: first, at: index), let font = labelFont(of: window) else {
                t.expect(false, desc: "tab \(index) has a measured room and a face")
                return
            }
            var title = words(fitting: room * 0.6, in: font)
            var what = "a label well inside its room"
            switch index {
            case 1:
                title = words(fitting: room * 0.85, in: font)
                what = "a label that grew after a short one"
            case 2:
                guard let tight = tightOnly(room: room, font: font) else {
                    t.expect(false, desc: "a label a few points wider than room \(room) is constructible")
                    return
                }
                title = tight
                what = "a label that fits only tightened"
            case 3:
                title = words(fitting: room * 2.6, in: font)
                what = "a label far wider than its room"
            case 4:
                title = "web-pages-demo.py"
                what = "a script's name"
            case 5:
                title = "serve-web.py"
                what = "a short script's name"
            case 6:
                title = "ssh build-host"
                what = "a login"
            default:
                break
            }
            expectations.append((window, title, what))
            send(title, to: window)
        }
        let sent = expectations
        _ = t.wait(
            until: {
                sent.allSatisfy { expectation in
                    controller(of: expectation.window)?.tabTitleFittingForTesting?.whole.string == expectation.title
                        && isFitted(expectation.window, in: first)
                }
            },
            timeout: 10
        )
        t.pump(0.5)
        print(describeRooms(of: tabs(), in: first))
        for expectation in expectations {
            judge(expectation.window, in: first, what: expectation.what, t)
        }
        if let tight = expectations.first(where: { $0.what == "a label that fits only tightened" }),
            let index = tabs().firstIndex(of: tight.window),
            let room = TabStripStyling.titleRoomForTesting(inGroupOf: first, at: index), let shown = tight.window.tab.attributedTitle
        {
            let paragraph = shown.length > 0 ? shown.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
            t.expect(
                shown.string == tight.title && shown.size().width > room && paragraph?.allowsDefaultTighteningForTruncation == true,
                desc: "a label \(shown.size().width - room) points too wide shows whole and tightened, not shortened"
                    + " ('\(shown.string)' in \(room))"
            )
        }

        // A tab closed while every program is quiet: the rest widen with no
        // screen update behind them, and each is fitted to its new room.
        let closing = tabs()[6]
        let roomsBefore = (0..<6).map { TabStripStyling.titleRoomForTesting(inGroupOf: first, at: $0) ?? 0 }
        closing.close()
        t.expect(
            t.wait(until: { tabs().count == 6 && tabs().allSatisfy { isFitted($0, in: first) } }, timeout: 6),
            desc: "after a tab closes, every tab is fitted to the room it has now"
        )
        t.pump(0.6)
        let roomsAfter = (0..<tabs().count).map { TabStripStyling.titleRoomForTesting(inGroupOf: first, at: $0) ?? 0 }
        t.expect(
            zip(roomsBefore, roomsAfter).allSatisfy { $1 > $0 },
            desc: "closing a tab gave every other tab more room (\(roomsBefore) → \(roomsAfter))"
        )
        print(describeRooms(of: tabs(), in: first))
        for (window, expectation) in tabs().compactMap({ window in expectations.first { $0.window === window }.map { (window, $0) } }) {
            judge(window, in: first, what: expectation.what + " after a tab closed", t)
        }
    }

    /// The marks a tab's accessory shows and the dimmed runs of its title
    /// wear dynamic system colours, which the strip's glass composites
    /// vibrantly, on a themed strip as on a native one; a status with a
    /// colour of its own keeps it, painted flat.
    @MainActor
    private static func marksAndDimRunsWearSystemColours(_ t: UBUITestContext) {
        // Offscreen and never key: the harness application is never active,
        // so every ink here is the one an inactive window wears.
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 300, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let savedHeld = TabAccessoryPresenter.isCommandKeyHeld
        TabAccessoryPresenter.isCommandKeyHeld = false
        defer { TabAccessoryPresenter.isCommandKeyHeld = savedHeld }
        let failedRed = NSColor(srgbRed: 0.86, green: 0.2, blue: 0.18, alpha: 1)
        let workingOrange = NSColor(srgbRed: 0.95, green: 0.6, blue: 0.1, alpha: 1)
        let neutralGrey = NSColor(srgbRed: 0.55, green: 0.55, blue: 0.57, alpha: 1)
        for usesNativeColors in [false, true] {
            let strip = usesNativeColors ? "native strip" : "themed strip"
            @MainActor
            func dress(_ status: HostOutlineStatus, color: NSColor?, isNeutral: Bool, activity: Bool) -> NSView? {
                TabAccessoryPresenter()
                    .apply(
                        to: window,
                        hintPosition: 1,
                        isSelected: false,
                        reportedProgressState: 0,
                        progressState: 0,
                        progressValue: 0,
                        statusColor: color,
                        isStatusColorNeutral: isNeutral,
                        programStatusRaw: status.rawValue,
                        notificationColor: .systemBlue,
                        hasUnheardBell: false,
                        hasUnseenNotification: false,
                        hasUnseenActivity: activity,
                        foreground: 0xC8CCD4,
                        background: 0x15171C,
                        usesNativeColors: usesNativeColors,
                        fontSize: 11
                    )
                return window.tab.accessoryView
            }
            // A program at rest, whose status Core colours with the theme's
            // neutral grey, and one at work.
            for (status, color, isNeutral, what) in [
                (HostOutlineStatus.idle, neutralGrey, true, "an idle program's mark"),
                (HostOutlineStatus.working, workingOrange, false, "a working program's ellipsis"),
            ] {
                guard let mark = dress(status, color: color, isNeutral: isNeutral, activity: false) as? TabStatusMark,
                    let ink = mark.ink
                else {
                    t.expect(false, desc: "\(strip): \(what) is a status mark with an ink")
                    continue
                }
                let view = mark.symbolImageViewForTesting
                t.expect(
                    view.image?.isTemplate == true && view.contentTintColor == ink,
                    desc: "\(strip): \(what) is a template symbol tinted by its ink (\(String(describing: mark.symbolName)))"
                )
                t.expect(
                    TabTitleStyling.isSystemColor(ink),
                    desc: "\(strip): \(what) wears a dynamic system colour, not \(ink)"
                )
                t.expect(
                    mark.allowsVibrancy && view.allowsVibrancy,
                    desc: "\(strip): \(what) composites vibrantly with the strip"
                )
            }
            if let idle = dress(.idle, color: neutralGrey, isNeutral: true, activity: false) as? TabStatusMark {
                t.expect(
                    idle.ink == .quaternaryLabelColor,
                    desc: "\(strip): a program at rest wears the tertiary role, a step fainter in an inactive window"
                        + " (\(String(describing: idle.ink)))"
                )
            }
            // A failure keeps the theme's colour for it, and paints it flat.
            if let failed = dress(.failed, color: failedRed, isNeutral: false, activity: false) as? TabStatusMark {
                let view = failed.symbolImageViewForTesting
                t.expect(
                    failed.ink == failedRed && view.image?.isTemplate == true && !failed.allowsVibrancy && !view.allowsVibrancy,
                    desc: "\(strip): a failure's mark keeps its colour as a template symbol, not vibrant"
                )
            } else {
                t.expect(false, desc: "\(strip): a failure shows a status mark")
            }
            // Unread output: the dots, a template image in a vibrant view.
            if let dots = dress(HostOutlineStatus.none, color: nil, isNeutral: false, activity: true) as? TabAttentionDots {
                dots.frame = NSRect(origin: .zero, size: dots.intrinsicContentSize)
                dots.layoutSubtreeIfNeeded()
                let view = dots.imageViewForTesting
                t.expect(
                    view.image?.isTemplate == true && view.contentTintColor == dots.tintColor
                        && TabTitleStyling.isSystemColor(dots.tintColor) && dots.allowsVibrancy && view.allowsVibrancy,
                    desc: "\(strip): the activity dots are a template image in a dynamic system colour, composited vibrantly"
                        + " (\(dots.tintColor), template \(String(describing: view.image?.isTemplate)))"
                )
            } else {
                t.expect(false, desc: "\(strip): unread output shows the activity dots")
            }

            // The title's dimmed runs: the folder it opens with, each
            // separator and the size it closes with.
            let label = "~/src — vim — 80×24"
            for isSelected in [true, false] {
                let baked = TabTitleStyling.attributedTitle(
                    label,
                    lead: "~/src",
                    isSelected: isSelected,
                    isWindowActive: true,
                    foreground: 0xC8CCD4,
                    background: 0x15171C,
                    usesNativeColors: usesNativeColors,
                    fontSize: 11,
                    dimensions: "80×24"
                )
                let text = label as NSString
                let runs: [(String, Int)] = [
                    ("the folder", 0),
                    ("the first separator", text.range(of: " — ").location + 1),
                    ("the second separator", text.range(of: " — ", options: .backwards).location + 1),
                    ("the size", text.range(of: "80×24").location),
                ]
                for (run, location) in runs {
                    let ink = baked.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
                    t.expect(
                        ink.map(TabTitleStyling.isSystemColor) == true,
                        desc: "\(strip), \(isSelected ? "selected" : "unselected") tab: \(run) wears a dynamic system colour,"
                            + " not \(String(describing: ink))"
                    )
                }
            }
        }
    }

    // MARK: - Judging

    /// Holds a tab's label to the rules: whole when the whole fits; otherwise
    /// the longest of Core's versions that fits, truncated only when even the
    /// shortest does not; and drawn whole by its field whenever it was judged
    /// to fit.
    @MainActor
    private static func judge(_ window: NSWindow, in group: NSWindow, what: String, _ t: UBUITestContext) {
        guard #available(macOS 26.0, *) else { return }
        let tabs = group.tabGroup?.windows ?? [group]
        guard let index = tabs.firstIndex(of: window), let room = TabStripStyling.titleRoomForTesting(inGroupOf: group, at: index),
            let fitting = controller(of: window)?.tabTitleFittingForTesting, let shown = window.tab.attributedTitle,
            let field = TabStripStyling.testTitleField(inGroupOf: group, at: index)
        else {
            t.expect(false, desc: "\(what): the tab has a room, a fitting and a field")
            return
        }
        let whole = tightenable(fitting.whole)
        let fieldWidth = field.alignmentRect(forFrame: field.frame).width
        let drawn = field.attributedStringValue
        if TabTitleStyling.drawsWhole(whole, width: room) {
            t.expect(
                shown.string == whole.string,
                desc: "\(what): a label that fits its room \(room) shows whole ('\(shown.string)' for '\(whole.string)')"
            )
            t.expect(
                drawn.string == whole.string && TabTitleStyling.drawsWhole(drawn, width: fieldWidth),
                desc: "\(what): its field draws it whole ('\(drawn.string)' in \(fieldWidth))"
            )
            return
        }
        guard let chosen = fitting.steps.firstIndex(of: shown.string), chosen > 0 else {
            t.expect(false, desc: "\(what): a label too wide for room \(room) shows one of Core's shorter versions ('\(shown.string)')")
            return
        }
        let isLast = chosen == fitting.steps.count - 1
        if !isLast || TabTitleStyling.drawsWhole(shown, width: room) {
            t.expect(
                TabTitleStyling.drawsWhole(shown, width: room) && TabTitleStyling.drawsWhole(drawn, width: fieldWidth),
                desc: "\(what): the version chosen fits, with no middle truncation ('\(shown.string)' in \(room), field \(fieldWidth))"
            )
        }
        // The longest that fits: the version before it, as the bake draws it, does not.
        let longer = fitting.steps[chosen - 1]
        let longerLabel = NSMutableAttributedString(attributedString: shown)
        longerLabel.replaceCharacters(in: NSRange(location: 0, length: longerLabel.length), with: longer)
        t.expect(
            !TabTitleStyling.drawsWhole(longerLabel, width: room),
            desc: "\(what): the longer version '\(longer)' does not fit room \(room), so '\(shown.string)' is the longest that does"
        )
    }

    // MARK: - Helpers

    /// Opens a strip of tabs each running the title echo, in one window about
    /// as wide as a reader's.
    @MainActor
    private static func openStrip(of count: Int, _ t: UBUITestContext) -> NSWindow? {
        var windows: [NSWindow] = []
        for _ in 0..<count {
            guard
                let controller = TerminalWindowController.spawn(
                    arguments: titleEchoProgram,
                    localePolicy: .auto,
                    sessionLifetime: .outlivesChild
                ), let window = controller.window
            else {
                t.expect(false, desc: "a tab running the title echo opens")
                for window in windows {
                    window.close()
                }
                return nil
            }
            windows.append(window)
        }
        let first = windows[0]
        first.setContentSize(NSSize(width: 1480, height: 220))
        for window in windows.dropFirst() {
            first.addTabbedWindow(window, ordered: .above)
        }
        first.tabGroup?.selectedWindow = first
        guard
            t.wait(
                until: { first.tabGroup?.isTabBarVisible == true && TabStripStyling.tabPills(inGroupOf: first).count == count },
                timeout: 10
            )
        else {
            print(TabStripStyling.describeStrip(inGroupOf: first))
            t.expect(false, desc: "the \(count) tabs share a strip of \(count) pills")
            for window in windows {
                window.close()
            }
            return nil
        }
        t.pump(0.5)
        return first
    }

    @MainActor
    private static func controller(of window: NSWindow) -> TerminalWindowController? {
        window.windowController as? TerminalWindowController
    }

    /// Sends one line to the program running in a tab.
    @MainActor
    private static func send(_ title: String, to window: NSWindow) {
        controller(of: window)?.focusedSurfaceForTesting?.send(title + "\r")
    }

    /// Whether a tab's label was fitted to the room its pill has now.
    @MainActor
    private static func isFitted(_ window: NSWindow, in group: NSWindow) -> Bool {
        guard #available(macOS 26.0, *), let index = (group.tabGroup?.windows ?? [group]).firstIndex(of: window),
            let room = TabStripStyling.titleRoomForTesting(inGroupOf: group, at: index),
            let label = window.tab.attributedTitle, label.length > 0,
            let fitted = label.attribute(TabStripStyling.fittedWidthKey, at: 0, effectiveRange: nil) as? CGFloat
        else { return false }
        return abs(fitted - room) <= 0.5
    }

    @MainActor
    private static func waitUntilFitted(_ windows: [NSWindow], in group: NSWindow, _ t: UBUITestContext) -> Bool {
        t.wait(until: { windows.allSatisfy { isFitted($0, in: group) } }, timeout: 10)
    }

    /// The face a tab's label is baked in: the selected tab's is heavier.
    @MainActor
    private static func labelFont(of window: NSWindow) -> NSFont? {
        guard let label = window.tab.attributedTitle, label.length > 0 else { return nil }
        return label.attribute(.font, at: label.length - 1, effectiveRange: nil) as? NSFont
    }

    /// A label as the bake leaves it to be drawn: tightened before it truncates.
    private static func tightenable(_ label: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: label)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.allowsDefaultTighteningForTruncation = true
        copy.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: copy.length))
        return copy
    }

    /// Words, as many as keep a label under a width in a face.
    private static func words(fitting width: CGFloat, in font: NSFont) -> String {
        let source = "Fitting probe naming a long running task in a project folder with more words to spare for every tab"
            .split(separator: " ")
        var label = ""
        for word in source {
            let next = label.isEmpty ? String(word) : label + " " + word
            if NSAttributedString(string: next, attributes: [.font: font]).size().width > width {
                break
            }
            label = next
        }
        return label
    }

    /// A label wider than a room by less than a field's tightening wins back,
    /// so it fits only tightened; nil when no such label is found.
    @MainActor
    private static func tightOnly(room: CGFloat, font: NSFont) -> String? {
        let base = words(fitting: room - 12, in: font)
        for filler in ["i", "l", "t", "r", "n", "e"] {
            var label = base + " " + filler
            while label.count < 200 {
                let candidate = tightenable(NSAttributedString(string: label, attributes: [.font: font]))
                let width = candidate.size().width
                if width > room + 0.5 {
                    if TabTitleStyling.drawsWhole(candidate, width: room) { return label }
                    break
                }
                label += filler
            }
        }
        return nil
    }

    /// Each tab's room beside what the pill's own frames would have said, for
    /// the run's log: the room AppKit lays the title out in, the frames of the
    /// close button and accessory, the field, and the labels.
    @MainActor
    private static func describeRooms(of windows: [NSWindow], in group: NSWindow) -> String {
        guard #available(macOS 26.0, *) else { return "" }
        var lines = ["tab rooms:"]
        let pills = TabStripStyling.tabPills(inGroupOf: group)
        for (index, window) in windows.enumerated() {
            let room = TabStripStyling.titleRoomForTesting(inGroupOf: group, at: index)
            let field = TabStripStyling.testTitleField(inGroupOf: group, at: index)
            let accessory = window.tab.accessoryView
            let pillWidth = index < pills.count ? pills[index].content.superview?.bounds.width ?? 0 : 0
            let accessoryFrame: NSRect? = index < pills.count ? accessory.map { $0.convert($0.bounds, to: pills[index].button) } : nil
            // The room as the pill's frames say it: the pill less twice the
            // wider of a 24-point close reach and the accessory's frame reach.
            var frameReach: CGFloat = 24
            if let accessoryFrame, index < pills.count {
                frameReach = max(frameReach, pills[index].button.bounds.maxX - accessoryFrame.minX)
            }
            let shown = window.tab.attributedTitle
            let whole = controller(of: window)?.tabTitleFittingForTesting?.whole
            let roomText = room.map { "\($0)" } ?? "none"
            let accessoryName = accessory.map { "\(type(of: $0))" } ?? "none"
            let accessoryText = accessoryFrame.map { "\($0)" } ?? "none"
            let fieldText = field.map { "\($0.frame)" } ?? "none"
            let parts: [String] = [
                "  tab \(index): room \(roomText) (by the pill's frames \(pillWidth - 2 * frameReach - 4)) pill \(pillWidth)",
                "accessory \(accessoryName) frame \(accessoryText) intrinsic \(accessory?.intrinsicContentSize.width ?? -1)",
                "field \(fieldText)",
                "whole '\(whole?.string ?? "")' \(whole?.size().width ?? 0) shown '\(shown?.string ?? "")' \(shown?.size().width ?? 0)",
            ]
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}
