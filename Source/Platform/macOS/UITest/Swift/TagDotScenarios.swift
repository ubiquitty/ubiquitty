// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// TagDotScenarios.swift — the tag as a dot: an untitled rule in the title row,
// a rule written without a title through Settings, every window's tags leading
// its tab's title, three at most with a count of the rest, the tag's icon in
// either place, and the title popover showing the tags rules give.
//
// Each assertion is anchored to what the feature determines — the dot's size
// against the capsule's, a tab mark's size against its label's cap height and
// x-height and its place on the label's cap band, the title text after it, the
// words a screen reader hears, the colour an icon is drawn in and the strength
// it is drawn at — so taking the behaviour away turns it red. The scenarios
// that read a drawn colour back pin the strength at full, so the colour painted
// is the tag's own.
//
// The title-row scenarios report a host from a plain shell, which stands the
// host chip; the chip wears the first coloured rule as its capsule, so each
// leads with a rule for the chip and puts the tag under test second.

/// Registers the tag-dot scenarios with the UI-test runner.
@objc(UBTagDotScenarios)
public final class TagDotScenarios: NSObject {
    /// Registers every scenario in this file.
    @objc
    public static func register() {
        registerTitleBarDot()
        registerSettingsWriteBack()
        registerTabDot()
        registerPopoverRuleTags()
        registerPictures()
    }

    // MARK: - Title bar

    private static func registerTitleBarDot() {
        UBUITestRegister("tag_title_bar_draws_an_untitled_rule_as_a_dot") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = configureAppendingToLiveDocument(
                    "[[tags]]\nname = \"dot host\"\ncolor = \"green\"\nmatch_host = \"ubq-dot-*\"\n\n"
                        + "[[tags]]\ncolor = \"blue\"\nmatch_host = \"ubq-dot-host\"\n\n"
                        + "[[tags]]\nname = \"home\"\ncolor = \"red\"\nmatch_host = \"ubq-dot-titled\"\n\n"
                        + "[appearance]\ntag_color_opacity = 1.0\n"
                )
                defer { restoreLiveDocument(saved) }
                guard let (controller, window) = openShell(t), let strip = titlebarStrip(of: window) else { return }
                defer { window.close() }

                report(host: "ubq-dot-host", from: controller)
                t.expect(
                    t.wait(
                        until: { titleField(in: strip)?.accessibilityLabel()?.hasPrefix("Tagged dot host, Blue") == true },
                        timeout: 6
                    ),
                    desc:
                        "an untitled rule is spoken by its colour's name, not as nothing (\(titleField(in: strip)?.accessibilityLabel() ?? "nil"))"
                )
                t.expect(
                    hostChip(over: titleField(in: strip))?.tagTitleForTesting == "dot host",
                    desc: "the host chip wears the first rule"
                )
                let markers = titleMarks(titleField(in: strip))
                t.expect(markers.count, equals: 1, desc: "the untitled rule draws one marker")
                guard let field = titleField(in: strip), let titleFont = field.font, let dot = markers.first else {
                    t.expect(false, desc: "the title leads with the dot")
                    return
                }
                let geometry = TitlebarCapsuleGeometry(titleFont: titleFont)
                t.expect(
                    abs(dot.bounds.height - geometry.height) <= 0.01 && dot.isTucked
                        && abs(dot.visibleWidth - geometry.crescentWidth) <= 0.01,
                    desc:
                        "the dot is a circle as tall as the capsule beside it, a crescent of it showing before the chip (\(dot.bounds), showing \(dot.visibleWidth))"
                )
                t.expect(
                    abs(dot.frame.width - geometry.crescentWidth - geometry.overlap) <= 0.01,
                    desc: "reaching the stack's overlap under the chip that follows it (\(dot.frame.width))"
                )
                t.expect(dot.fillOpacity == 1, desc: "the dot is laid down at the configured strength (\(dot.fillOpacity))")
                t.expect(
                    abs(dot.bounds.midY - titleFont.capHeight / 2) <= 0.01,
                    desc: "the dot centres on the title's cap band as the capsule does (\(dot.bounds.midY) vs \(titleFont.capHeight / 2))"
                )
                t.expect(dot.image.accessibilityDescription == "Blue", desc: "the dot's image is described by its colour")
                t.expect(dot.iconName.isEmpty, desc: "a rule with no icon draws the dot itself")
                t.expect(
                    dot.textFrame == nil && dot.ink == nil,
                    desc: "the dot draws a circle, not an empty capsule around no text"
                )

                report(host: "ubq-dot-titled", from: controller)
                t.expect(
                    t.wait(
                        until: { titleField(in: strip)?.accessibilityLabel()?.hasPrefix("Tagged dot host, home") == true },
                        timeout: 6
                    ),
                    desc: "a titled rule is spoken by its title"
                )
                let capsule = titleMarks(titleField(in: strip)).first
                t.expect(
                    abs((capsule?.bounds.height ?? 0) - 22) <= 0.01,
                    desc: "a rule with a title keeps the 22-point capsule (\(capsule?.bounds ?? .zero))"
                )
            }
        }

        UBUITestRegister("tag_title_bar_draws_a_rules_icon_in_its_marker") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = configureAppendingToLiveDocument(
                    "[[tags]]\nname = \"icon host\"\ncolor = \"green\"\nmatch_host = \"ubq-icon-*\"\n\n"
                        + "[[tags]]\ncolor = \"blue\"\nicon = \"star\"\nmatch_host = \"ubq-icon-dot\"\n\n"
                        + "[[tags]]\nname = \"home\"\ncolor = \"red\"\nicon = \"house\"\nicon_weight = \"regular\"\n"
                        + "match_host = \"ubq-icon-titled\"\n\n"
                        + "[appearance]\ntag_color_opacity = 1.0\n"
                )
                defer { restoreLiveDocument(saved) }
                guard PhosphorIcons.icon(named: "star") != nil else {
                    t.expect(false, desc: "the app bundle carries the Phosphor catalog")
                    return
                }
                guard let (controller, window) = openShell(t), let strip = titlebarStrip(of: window) else { return }
                defer { window.close() }

                // Untitled: the icon on a circle of the tag's colour, in the
                // circle's ink.
                report(host: "ubq-icon-dot", from: controller)
                t.expect(
                    t.wait(until: { titleMarks(titleField(in: strip)).first?.iconName == "star" }, timeout: 6),
                    desc:
                        "an untitled rule with an icon draws the icon in its dot's place (\(titleField(in: strip)?.accessibilityLabel() ?? "nil"))"
                )
                guard let field = titleField(in: strip), let titleFont = field.font, let mark = titleMarks(field).first else {
                    t.expect(false, desc: "the title leads with the icon")
                    return
                }
                let geometry = TitlebarCapsuleGeometry(titleFont: titleFont)
                t.expect(
                    abs(mark.bounds.height - geometry.height) <= 0.01 && abs(mark.bounds.midY - titleFont.capHeight / 2) <= 0.01
                        && mark.isTucked && mark.visibleWidth > geometry.crescentWidth
                        && (mark.iconFrame.map {
                            $0.maxX + TitlebarCapsuleGeometry.knockout + TitlebarCapsuleGeometry.contentClearance <= mark.visibleWidth
                                + 0.01
                                && abs($0.minX - (geometry.height - $0.width) / 2 - geometry.tuckedIconShift) <= 0.01
                        } == true),
                    desc:
                        "the icon stands on the dot's circle, right of centre, which shows more than a crescent to hold it whole (\(mark.bounds), showing \(mark.visibleWidth), icon \(mark.iconFrame ?? .zero))"
                )
                t.expect(
                    isSameColor(mark.fill, paletteBlue) && mark.ink == TitlebarTagChip.labelColor(on: paletteBlue),
                    desc: "the circle is the tag's colour, and the icon the ink Core picks for it (\(String(describing: mark.ink)))"
                )
                let iconInk = mark.iconFrame.map { solidPixels(of: mark.image, in: $0).map(\.color) } ?? []
                t.expect(
                    iconInk.contains { isSameSRGBColor($0, mark.ink, tolerance: 0.03) },
                    desc: "and the icon is drawn in that ink (\(iconInk.count) solid pixels)"
                )
                t.expect(mark.image.accessibilityDescription == "Blue", desc: "and is still described by its colour")
                t.expect(
                    field.accessibilityLabel()?.hasPrefix("Tagged icon host, Blue") == true,
                    desc: "a screen reader hears the same tags it did for the dot (\(field.accessibilityLabel() ?? "nil"))"
                )

                // Titled: the icon leads the title inside its capsule.
                report(host: "ubq-icon-titled", from: controller)
                t.expect(
                    t.wait(until: { titleMarks(titleField(in: strip)).first?.iconName == "house" }, timeout: 6),
                    desc: "a titled rule with an icon draws it in its capsule"
                )
                let capsule = titleMarks(titleField(in: strip)).first
                t.expect(
                    abs((capsule?.bounds.height ?? 0) - 22) <= 0.01 && capsule?.image.accessibilityDescription == "home",
                    desc: "inside the 22-point capsule that carries the title (\(capsule?.bounds ?? .zero))"
                )
            }
        }
    }

    // MARK: - Settings

    private static func registerSettingsWriteBack() {
        UBUITestRegister("tag_settings_saves_a_rule_without_a_title_by_position") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let delegate = SettingsBridge.app else {
                    t.expect(false, desc: "the app delegate answers")
                    return
                }
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { restoreLiveDocument(saved) }
                let untitled: [String: Any] = [
                    "name": "", "color": "blue", "matchHost": "ubq-settings-a", "matchProfile": "", "prominence": "",
                ]
                t.expect(delegate.settingsIsValidTag(untitled), desc: "a colour and a host pattern make a rule without a title")
                t.expect(
                    !delegate.settingsIsValidTag(["name": "", "color": "", "matchHost": "ubq-settings-a"]),
                    desc: "neither a title nor a colour is refused"
                )
                t.expect(
                    !delegate.settingsIsValidTag(["name": "  ", "color": "blue", "matchHost": "", "matchProfile": ""]),
                    desc: "an untitled colour that matches nothing is refused: nothing could ever wear it"
                )

                let before = delegate.settingsTags().count
                delegate.settingsSaveTag(untitled, at: -1)
                delegate.settingsSaveTag(["name": "", "color": "blue", "matchHost": "ubq-settings-b"], at: -1)
                var tags = delegate.settingsTags()
                t.expect(tags.count, equals: before + 2, desc: "both untitled rules are written, though they share a colour and no name")
                guard tags.count == before + 2 else { return }
                t.expect(
                    (tags[before]["name"] as? String) == "" && (tags[before]["matchHost"] as? String) == "ubq-settings-a",
                    desc: "the first reads back untitled, at its position"
                )
                let document = String(Ubiquitty.Preferences.liveDocument().pointee)
                t.expect(
                    !document.contains("name = \"\""),
                    desc: "an untitled rule is written without a name line"
                )

                // The second is edited by its position; the first is untouched.
                delegate.settingsSaveTag(["name": "", "color": "green", "matchHost": "ubq-settings-b"], at: before + 1)
                tags = delegate.settingsTags()
                t.expect(
                    (tags[before]["color"] as? String) == "blue" && (tags[before + 1]["color"] as? String) == "green",
                    desc: "a save addresses the rule at its position, not the first of the same name"
                )
                delegate.settingsDeleteTag(at: before)
                tags = delegate.settingsTags()
                t.expect(
                    tags.count == before + 1 && (tags[before]["matchHost"] as? String) == "ubq-settings-b",
                    desc: "a delete removes the rule at its position alone"
                )
            }
        }
    }

    // MARK: - Tabs

    private static func registerTabDot() {
        UBUITestRegister("tag_tab_title_leads_with_its_tags_dot") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // At full strength, so the colour the mark paints is the tag's own.
                let saved = configureAppendingToLiveDocument("[appearance]\ntag_color_opacity = 1.0\n")
                defer { restoreLiveDocument(saved) }
                guard let (first, second) = openTabPair(t) else { return }
                defer { closeGroup(first) }
                let untaggedViews = TabStripStyling.tabPills(inGroupOf: first).map { $0.content.subviews.count }
                t.expect([first, second].allSatisfy { tabTagMark(of: $0) == nil }, desc: "an untagged group's titles lead with no mark")

                setManualTags(["blue"], on: first)
                setManualTags(["red"], on: second)
                t.expect(
                    t.wait(until: { tabTagMark(of: first) != nil && tabTagMark(of: second) != nil }, timeout: 4),
                    desc: "every tagged tab's title leads with a mark"
                )
                for (index, window) in [first, second].enumerated() {
                    guard let mark = tabTagMark(of: window), let title = window.tab.attributedTitle, title.length > 1,
                        let font = title.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
                    else {
                        t.expect(false, desc: "tab \(index)'s title has a mark and a face")
                        continue
                    }
                    let side = TabTagMarks.markSide(for: font, hasIcon: false)
                    t.expect(
                        mark.iconName.isEmpty && abs(mark.markSide - side) <= 0.01 && side >= 6 && side <= 8,
                        desc:
                            "tab \(index)'s dot is a bullet about the label's x-height (\(mark.markSide) for x-height \(font.xHeight))"
                    )
                    t.expect(
                        abs(mark.bounds.midY - font.capHeight / 2) <= 0.01,
                        desc: "tab \(index)'s dot centres on the label's cap band (\(mark.bounds.midY) vs \(font.capHeight / 2))"
                    )
                    t.expect(
                        mark.gap >= 5 && mark.gap <= 6 && abs(mark.bounds.width - mark.markSide - mark.gap) <= 0.01,
                        desc: "tab \(index)'s dot keeps five to six points before the text (\(mark.gap))"
                    )
                    t.expect(
                        String(title.string.dropFirst()) == window.tab.title,
                        desc: "tab \(index)'s text follows the mark unchanged ('\(title.string)' vs '\(window.tab.title ?? "")')"
                    )
                    let paragraph = title.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                    t.expect(
                        paragraph?.lineBreakMode == .byTruncatingMiddle,
                        desc: "tab \(index)'s long title truncates in its middle, keeping the mark and the tail"
                    )
                    t.expect(mark.opacity == 1, desc: "tab \(index)'s dot is drawn at the configured strength (\(mark.opacity))")
                    let color = index == 0 ? paletteBlue : paletteColor("red")
                    t.expect(mark.image.map { isInked($0, in: color) } == true, desc: "tab \(index)'s dot is its tag's colour")
                }
                t.expect(
                    t.wait(until: { drawnTabTagMarks(inGroupOf: first).allSatisfy { $0 != nil } }, timeout: 4),
                    desc: "the strip draws each mark as the first run of its tab's title"
                )
                t.expect(
                    TabStripStyling.tabPills(inGroupOf: first).map { $0.content.subviews.count } == untaggedViews,
                    desc: "the mark adds no view to the pill, so the close control is AppKit's alone"
                )
                t.expect(
                    !(first.tab.title.contains("\u{25CF}")) && !(second.tab.title.contains("\u{25CF}")),
                    desc: "the tag is not text in the tab's plain title"
                )
                t.expect(
                    tabTagMark(of: first)?.image?.accessibilityDescription == "Tagged blue",
                    desc: "the mark is spoken by its tag as soon as it appears"
                )
                setManualTags(["blue", "production"], on: first)
                t.expect(
                    t.wait(until: { tabTagMark(of: first)?.image?.accessibilityDescription == "Tagged blue, production" }, timeout: 4),
                    desc: "a name change updates the mark's spoken names even when its colour stays blue"
                )

                setManualTags([], on: first)
                t.expect(
                    t.wait(until: { tabTagMark(of: first) == nil }, timeout: 4),
                    desc: "removing the tag removes its tab's mark"
                )
                t.expect(
                    first.tab.attributedTitle?.string == first.tab.title,
                    desc: "and the title is its text alone"
                )
            }
        }

        UBUITestRegister("tag_tab_title_leads_with_its_tags_icon") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // A rule with no match declares what the name means: a hand-set
                // tag of that name wears its colour and its icon.
                let saved = configureAppendingToLiveDocument(
                    "[[tags]]\nname = \"rocket\"\ncolor = \"blue\"\nicon = \"rocket\"\n\n[appearance]\ntag_color_opacity = 1.0\n"
                )
                defer { restoreLiveDocument(saved) }
                guard PhosphorIcons.icon(named: "rocket") != nil else {
                    t.expect(false, desc: "the app bundle carries the Phosphor catalog")
                    return
                }
                guard let (first, second) = openTabPair(t) else { return }
                defer { closeGroup(first) }
                setManualTags(["rocket"], on: first)
                setManualTags(["blue"], on: second)
                guard
                    t.wait(until: { tabTagMark(of: first) != nil && tabTagMark(of: second) != nil }, timeout: 4),
                    let iconMark = tabTagMark(of: first), let plainMark = tabTagMark(of: second),
                    let title = first.tab.attributedTitle, title.length > 1,
                    let font = title.attribute(.font, at: 1, effectiveRange: nil) as? NSFont,
                    let iconImage = iconMark.image, let plainImage = plainMark.image
                else {
                    t.expect(false, desc: "both tagged tabs' titles lead with a mark")
                    return
                }
                t.expect(iconMark.iconName == "rocket", desc: "a tag with an icon leads its tab's title with the icon")
                t.expect(plainMark.iconName.isEmpty, desc: "a tag without one leads with the dot")
                t.expect(
                    abs(iconMark.markSide - 16) <= 0.01 && iconMark.markSide > plainMark.markSide,
                    desc:
                        "the icon is 16 points, as Safari draws a site's icon in its tab, well over the dot (\(iconMark.markSide) vs \(plainMark.markSide))"
                )
                t.expect(
                    abs(iconMark.bounds.midY - font.capHeight / 2) <= 0.01,
                    desc: "and centres on the label's cap band as the dot does"
                )
                let iconCoverage = inkCoverage(of: iconImage, side: iconMark.markSide)
                let discCoverage = inkCoverage(of: plainImage, side: plainMark.markSide)
                t.expect(
                    iconCoverage > 0.05 && iconCoverage < 0.7 && discCoverage > 0.7,
                    desc: "the icon is drawn rather than a filled disc (icon covers \(iconCoverage), dot \(discCoverage))"
                )
                t.expect(isInked(iconImage, in: paletteBlue), desc: "and drawn in the tag's colour")
                t.expect(
                    titleMarks(titlebarStrip(of: first).flatMap(titleField(in:))).first?.iconName == "rocket",
                    desc: "the title's capsule for the tag leads with the same icon"
                )

                // The icon alone changes: the colour and the names are what they
                // were, and the title is baked again all the same.
                restoreLiveDocument(saved)
                _ = configureAppendingToLiveDocument("[[tags]]\nname = \"rocket\"\ncolor = \"blue\"\nicon = \"truck\"\n")
                t.expect(
                    t.wait(until: { tabTagMark(of: first)?.iconName == "truck" }, timeout: 4),
                    desc: "a change of icon alone leads the title with the new one"
                )
            }
        }

        UBUITestRegister("tag_tab_title_draws_every_tag_and_counts_past_three") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = configureAppendingToLiveDocument("[appearance]\ntag_color_opacity = 1.0\n")
                defer { restoreLiveDocument(saved) }
                guard let (_, window) = openShell(t) else { return }
                defer { window.close() }

                // Two tags are two marks, in the order set, the second no
                // longer hidden behind the first.
                setManualTags(["blue", "red"], on: window)
                t.expect(
                    t.wait(until: { tabTagMark(of: window)?.iconNames.count == 2 }, timeout: 4),
                    desc: "a tab draws a mark for each of its tags (\(tabTagMark(of: window)?.iconNames ?? []))"
                )
                if let mark = tabTagMark(of: window), let title = window.tab.attributedTitle, title.length > 1,
                    let font = title.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
                {
                    t.expect(mark.overflowCount == 0, desc: "and counts none past them")
                    let side = TabTagMarks.markSide(for: font, hasIcon: false)
                    // Two dots, the air between them, and the air before the text.
                    t.expect(
                        mark.bounds.width > 2 * side + mark.gap && mark.bounds.width < 2 * side + mark.gap + 6,
                        desc: "the run is two dots wide and the gap (\(mark.bounds.width) for dots of \(side))"
                    )
                    t.expect(
                        String(title.string.dropFirst()) == window.tab.title,
                        desc: "the run is one attachment before the unchanged title ('\(title.string)')"
                    )
                    t.expect(
                        mark.image?.accessibilityDescription == "Tagged blue, red",
                        desc: "spoken in the order set (\(mark.image?.accessibilityDescription ?? "nil"))"
                    )
                }

                // Past three, the first three are drawn and the rest counted;
                // every tag is still named.
                setManualTags(["blue", "red", "green", "purple", "orange"], on: window)
                t.expect(
                    t.wait(until: { tabTagMark(of: window)?.overflowCount == 2 }, timeout: 4),
                    desc: "five tags draw three marks and count two (\(tabTagMark(of: window)?.overflowCount ?? -1))"
                )
                t.expect(tabTagMark(of: window)?.iconNames.count == TabTagMarks.maxDrawnMarks, desc: "three marks are drawn")
                t.expect(
                    tabTagMark(of: window)?.image?.accessibilityDescription == "Tagged blue, red, green, purple, orange",
                    desc: "and every tag is spoken (\(tabTagMark(of: window)?.image?.accessibilityDescription ?? "nil"))"
                )
                t.expect(
                    (window.tab.toolTip ?? "").contains("Tagged blue, red, green, purple, orange"),
                    desc: "and named in the tooltip ('\(window.tab.toolTip ?? "")')"
                )
            }
        }
    }

    // MARK: - Popover

    private static func registerPopoverRuleTags() {
        UBUITestRegister("tag_popover_shows_the_tags_a_rule_gives_the_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = configureAppendingToLiveDocument(
                    "[[tags]]\nname = \"home\"\ncolor = \"blue\"\nmatch_host = \"ubq-popover-host\"\n\n"
                        + "[[tags]]\ncolor = \"green\"\nmatch_host = \"ubq-popover-*\"\n"
                )
                defer { restoreLiveDocument(saved) }
                guard let (controller, window) = openShell(t), let strip = titlebarStrip(of: window) else { return }
                defer {
                    dismissEditSheet(t)
                    settingsPanelWindow()?.close()
                    window.close()
                }
                report(host: "ubq-popover-host", from: controller)
                guard t.wait(until: { titleChipCount(titleField(in: strip)) == 2 }, timeout: 6) else {
                    t.expect(false, desc: "both rules mark the window (\(titleField(in: strip)?.accessibilityLabel() ?? "nil"))")
                    return
                }
                guard openIdentityPopover(in: strip, t), let field = popoverTagsField(), let blue = popoverTagDot("blue"),
                    let green = popoverTagDot("green"), let red = popoverTagDot("red")
                else {
                    t.expect(false, desc: "the popover opens with its tag field and palette")
                    return
                }
                let shown = field.objectValue as? [Any] ?? []
                t.expect(shown.count, equals: 2, desc: "the field lists the two tags the rules give, rather than None")
                t.expect(field.placeholderString == nil && !field.stringValue.isEmpty, desc: "the field does not read None")
                t.expect(
                    (blue.accessibilityValue() as? Int) == 2 && (green.accessibilityValue() as? Int) == 2,
                    desc: "the rules' colours read as set by a rule — mixed — not as set by hand"
                )
                t.expect(!tagDotIsSet(red) && (red.accessibilityValue() as? Int) == 0, desc: "a colour no tag wears stays unset")
                t.expect(
                    blue.toolTip == "Blue. From rule: ubq-popover-host" && green.toolTip == "Green. From rule: ubq-popover-*",
                    desc: "each rule colour's tooltip names its rule (\(blue.toolTip ?? "nil"); \(green.toolTip ?? "nil"))"
                )
                t.expect(
                    green.accessibilityLabel() == "Green tag. From rule: ubq-popover-*",
                    desc: "and so does what a screen reader hears, the untitled rule included"
                )

                // A press on a colour a rule gives does not fight the rule.
                _ = blue.accessibilityPerformPress()
                t.pump(0.3)
                t.expect(manualTags(of: window).isEmpty, desc: "a press on a rule's colour adds no hand-set tag")
                t.expect(Int(titleChipCount(titleField(in: strip))), equals: 2, desc: "and the window still wears the rules' two tags")

                guard shown.count == 2,
                    let menu = field.delegate?.tokenField?(field, menuForRepresentedObject: shown[1]),
                    let edit = menu.items.last, let action = edit.action
                else {
                    t.expect(false, desc: "the second rule token offers Edit Rule…")
                    return
                }
                _ = NSApp.sendAction(action, to: edit.target, from: edit)
                t.pump(1.2)
                t.expect(settingsPanelWindow() != nil, desc: "Edit Rule… opens Settings")
                t.expect(TagRulePrefill.takePendingRuleIndex() == nil, desc: "and the Tags pane took the chosen rule")
                let opened = t.wait(until: { anythingOnScreenReports("ubq-popover-*") }, timeout: 3)
                t.expect(
                    opened,
                    desc: "the chosen second rule opens in the editor"
                        + (opened ? "" : " (on screen: \(visibleStrings().joined(separator: " / ")))")
                )
            }
        }
    }

    // MARK: - Pictures

    private static func registerPictures() {
        UBUITestRegister("tag_dot_pictures") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = configureAppendingToLiveDocument(
                    "[[tags]]\ncolor = \"blue\"\nmatch_host = \"ubq-picture-dot\"\n\n"
                        + "[[tags]]\nname = \"\u{1F3E0}\"\ncolor = \"blue\"\nmatch_host = \"ubq-picture-titled\"\n"
                )
                defer { restoreLiveDocument(saved) }
                guard let (first, second) = openTabPair(t),
                    let firstController = first.windowController as? TerminalWindowController,
                    let secondController = second.windowController as? TerminalWindowController
                else { return }
                defer { closeGroup(first) }
                for isDark in [false, true] {
                    let name = isDark ? "dark" : "light"
                    let restoreLook = showLook(isDark: isDark, on: [first, second])
                    defer { restoreLook() }
                    for (variant, host) in [("untitled", "ubq-picture-dot"), ("titled", "ubq-picture-titled")] {
                        report(host: host, from: firstController)
                        report(host: host, from: secondController)
                        _ = t.wait(until: { tabTagMark(of: first) != nil && tabTagMark(of: second) != nil }, timeout: 6)
                        t.pump(0.8)
                        capture(first, "tag-\(variant)-\(name)")
                    }
                }
                t.expect(true, desc: "pictures drawn under /tmp/tag-dot")
            }
        }

        UBUITestRegister("tag_tab_mark_pictures") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = configureAppendingToLiveDocument("[[tags]]\nname = \"rocket\"\ncolor = \"blue\"\nicon = \"rocket\"\n")
                defer { restoreLiveDocument(saved) }
                guard let (first, second) = openTabPair(t), let (_, third) = openShell(t) else { return }
                first.addTabbedWindow(third, ordered: .above)
                first.tabGroup?.selectedWindow = first
                defer { closeGroup(first) }
                // An icon tag, a dot tag, and no tag, side by side.
                setManualTags(["rocket"], on: first)
                setManualTags(["red"], on: second)
                _ = t.wait(until: { tabTagMark(of: first) != nil && tabTagMark(of: second) != nil }, timeout: 6)
                for isDark in [false, true] {
                    let look = isDark ? "dark" : "light"
                    let restoreLook = showLook(isDark: isDark, on: [first, second, third])
                    defer { restoreLook() }
                    for strength in [0.5, 1.0] {
                        configureAppendingToLiveDocument("[appearance]\ntag_color_opacity = \(strength)\n")
                        _ = t.wait(until: { tabTagMark(of: first)?.opacity == CGFloat(strength) }, timeout: 6)
                        t.pump(0.8)
                        capture(first, "tab-marks-\(look)-\(Int(strength * 100))")
                    }
                }
                t.expect(true, desc: "pictures of an icon tag, a dot tag and no tag drawn under /tmp/tag-dot")
            }
        }
    }

    // MARK: - Support

    /// Puts the app in a light or dark look for a picture: the system
    /// appearance and the matching built-in theme, which is what a reader in
    /// that mode sees.
    ///
    /// - Parameters:
    ///   - isDark: Whether the look is dark.
    ///   - windows: The windows to dress.
    /// - Returns: What puts the look back.
    @MainActor
    static func showLook(isDark: Bool, on windows: [NSWindow]) -> () -> Void {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        let hadAppearance = NSApp.appearance
        NSApp.appearance = appearance
        for window in windows {
            window.appearance = appearance
        }
        let saved = configureAppendingToLiveDocument("[appearance]\ntheme = \"\(isDark ? "Noir" : "Noir Clair")\"\n")
        return {
            restoreLiveDocument(saved)
            NSApp.appearance = hadAppearance
            for window in windows {
                window.appearance = nil
            }
        }
    }

    /// Opens one small shell window.
    @MainActor
    static func openShell(_ t: UBUITestContext) -> (TerminalWindowController, NSWindow)? {
        guard
            let controller = TerminalWindowController.spawn(
                arguments: ["/bin/sh"],
                localePolicy: .auto,
                sessionLifetime: .outlivesChild
            ), let window = controller.window
        else {
            t.expect(false, desc: "a shell opens")
            return nil
        }
        window.setContentSize(NSSize(width: 620, height: 220))
        t.pump(0.3)
        return (controller, window)
    }

    /// Opens two shells in one small tab group, the first selected.
    @MainActor
    static func openTabPair(_ t: UBUITestContext) -> (NSWindow, NSWindow)? {
        guard let (_, first) = openShell(t), let (_, second) = openShell(t) else { return nil }
        first.addTabbedWindow(second, ordered: .above)
        first.tabGroup?.selectedWindow = first
        guard
            t.wait(
                until: { first.tabGroup?.isTabBarVisible == true && TabStripStyling.tabPills(inGroupOf: first).count == 2 },
                timeout: 8
            )
        else {
            print(TabStripStyling.describeStrip(inGroupOf: first))
            t.expect(false, desc: "the two shells share a strip of two pills")
            closeGroup(first)
            return nil
        }
        t.pump(0.4)
        return (first, second)
    }

    /// Closes every window of a group.
    @MainActor
    static func closeGroup(_ window: NSWindow) {
        for member in window.tabGroup?.windows ?? [window] {
            member.close()
        }
    }

    /// Has a shell report the machine it is on, as a remote shell's
    /// integration does.
    @MainActor
    static func report(host: String, from controller: TerminalWindowController) {
        controller.shellSendProbe("printf '\\033]7;file://\(host)/tmp\\007'\r")
    }

    /// The blue a `color = "blue"` tag resolves to, by Core's palette.
    static var paletteBlue: NSColor { paletteColor("blue") }

    /// The colour a `color = "<name>"` tag resolves to, by Core's palette.
    ///
    /// - Parameter name: The palette's name for it.
    /// - Returns: The colour, opaque.
    static func paletteColor(_ name: String) -> NSColor {
        var color = Ubiquitty.Preferences.ColorEntry()
        _ = name.withCString { Ubiquitty.Session.tagColorFromName(std.string_view($0), &color) }
        return NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1)
    }

    /// Whether two colours carry the same components, to within the rounding a
    /// drawn and read-back pixel picks up.
    ///
    /// Compared as stored rather than converted, for the reason
    /// HostLabelScenarios gives: a pixel read back is tagged with a calibrated
    /// space but holds the bytes it was drawn with.
    static func isSameColor(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let a = a?.usingType(.componentBased), let b = b?.usingType(.componentBased),
            a.numberOfComponents >= 3, b.numberOfComponents >= 3
        else { return false }
        return abs(a.redComponent - b.redComponent) < 0.1 && abs(a.greenComponent - b.greenComponent) < 0.1
            && abs(a.blueComponent - b.blueComponent) < 0.1
    }

    /// Whether an image's solid ink, its fully opaque pixels, is all one colour.
    ///
    /// - Parameters:
    ///   - image: The image.
    ///   - color: The colour the ink should be.
    /// - Returns: True when it has ink and every solid pixel is that colour.
    @MainActor
    static func isInked(_ image: NSImage, in color: NSColor) -> Bool {
        guard let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else { return false }
        var solid = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let pixel = rep.colorAt(x: x, y: y), pixel.alphaComponent > 0.95 else { continue }
                guard isSameColor(pixel, color) else { return false }
                solid += 1
            }
        }
        return solid > 0
    }

    /// The share of a mark's square its image paints, the gap after it left
    /// out, drawn at four times its size so a small dot's edge does not
    /// decide the answer.
    ///
    /// - Parameters:
    ///   - image: The mark's image, its square at the leading end.
    ///   - side: The square's side, in points.
    /// - Returns: The share of the square's pixels painted more than half.
    @MainActor
    static func inkCoverage(of image: NSImage, side: CGFloat) -> CGFloat {
        let scale: CGFloat = 4
        let pixels = Int((side * scale).rounded())
        guard pixels > 0,
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels,
                pixelsHigh: pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let graphics = NSGraphicsContext(bitmapImageRep: rep)
        else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: pixels, height: pixels).fill(using: .copy)
        image.draw(in: NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale))
        NSGraphicsContext.restoreGraphicsState()
        var painted = 0
        for y in 0..<pixels {
            for x in 0..<pixels {
                if let pixel = rep.colorAt(x: x, y: y), pixel.alphaComponent > 0.5 {
                    painted += 1
                }
            }
        }
        return CGFloat(painted) / CGFloat(pixels * pixels)
    }

    /// Writes a picture of a window's frame view, as AppKit draws it, each
    /// text field drawn once as the window shows it, under `/tmp/tag-dot`.
    @MainActor
    static func capture(_ window: NSWindow, _ name: String) {
        let directory = "/tmp/tag-dot"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = "\(directory)/\(name).png"
        try? FileManager.default.removeItem(atPath: path)
        window.displayIfNeeded()
        guard let frame = window.contentView?.superview, let rep = drawnBitmap(of: frame) else {
            return
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
