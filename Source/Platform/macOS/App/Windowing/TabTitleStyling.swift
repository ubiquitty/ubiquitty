// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// TabTitleStyling.swift — the attributed title a tab wears.
//
// A tab title is baked as an attributed string, colours included, and handed
// to AppKit as the tab's `attributedTitle`. The ink is the theme foreground at
// the coverage Core names for the tab (`Themes::tabTitleCoverage`): the
// system's own numbers by default, lifted to the legibility floors only when
// the system's Increase Contrast switch is on. Both shells bake through this
// one builder, so a tab reads the same whichever shell opened it.
//

import AppKit
internal import UbiquittyCore

@MainActor
@objc(UBTabTitleStyling)
public final class TabTitleStyling: NSObject {
    /// Bakes a tab's attributed title.
    ///
    /// The selected tab is semibold and every other tab regular weight. The
    /// runs that only place or join the title, the leading "[folder] — ", each
    /// separator and the size, wear the system's secondary and tertiary label
    /// colours on every strip (``dimInk(_:isSelected:isWindowActive:usesNativeColors:)``).
    ///
    /// - Parameters:
    ///   - title: The tab's text.
    ///   - lead: The leading directory segment, dimmed on the selected tab
    ///     when the label starts with it; empty for none.
    ///   - markPrefix: What the marks put before the label (the pin, the
    ///     host), which the folder run is measured past; empty for none.
    ///   - isSelected: Whether the tab is its group's selected one.
    ///   - isWindowActive: Whether the strip's tab group holds the key or main
    ///     window of the active application.
    ///   - foreground: The theme foreground, packed 0xRRGGBB.
    ///   - background: The theme background the band derives from, packed
    ///     0xRRGGBB.
    ///   - usesNativeColors: Whether the native title bar is in use, where the
    ///     system's own label colours apply and AppKit does the dimming.
    ///   - fontSize: The chrome font size, already scaled.
    /// - Returns: The baked title.
    @objc
    public static func attributedTitle(
        _ title: String,
        lead: String,
        markPrefix: String = "",
        isSelected: Bool,
        isWindowActive: Bool,
        foreground: UInt32,
        background: UInt32,
        usesNativeColors: Bool,
        fontSize: CGFloat,
        dimensions: String = ""
    ) -> NSAttributedString {
        // Truncation from the head, so the trailing process name stays visible
        // — and from the middle once the label carries marks, which lead it
        // and are the part that says which machine the tab is on.
        let hasMarks = !markPrefix.isEmpty && title.hasPrefix(markPrefix)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = hasMarks ? .byTruncatingMiddle : .byTruncatingHead
        // The selected tab is told by weight as well as coverage, semibold so
        // it leads without shouting; every other tab is regular.
        let font = NSFont.systemFont(ofSize: fontSize, weight: isSelected ? .semibold : .regular)

        let ink = titleInk(
            isSelected: isSelected,
            isWindowActive: isWindowActive,
            foreground: foreground,
            background: background,
            usesNativeColors: usesNativeColors
        )
        let leadInk = dimInk(.lead, isSelected: isSelected, isWindowActive: isWindowActive, usesNativeColors: usesNativeColors)
        let detailInk = dimInk(.detail, isSelected: isSelected, isWindowActive: isWindowActive, usesNativeColors: usesNativeColors)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph, .foregroundColor: ink]
        // The dim run is "[folder] — ": the leading segment plus its joining
        // separator. Where it ends is Core's answer, not a search here.
        //
        // A tab label is always woven with the spaced form, so it passes that
        // form and Core answers for it; no spelling is guessed here.
        //
        // Measured past the marks, which lead the label: a pinned tab or one
        // naming its host opens with them, and the folder run starts after.
        let text = title as NSString
        let label = hasMarks ? String(title.dropFirst(markPrefix.count)) : title
        let markLength = hasMarks ? (markPrefix as NSString).length : 0
        let runBytes = Ubiquitty.Title.joinedLeadingPartLength(
            std.string(label),
            std.string(lead),
            Ubiquitty.PAL.Process.TitleSeparator.Spaced
        )
        // Core counts UTF-8 bytes; NSString indexes UTF-16 units. Convert by
        // measuring the prefix rather than assuming the two agree, because for
        // a path with any non-ASCII in it they do not.
        var folderLength = 0
        if runBytes > 0 {
            let prefix = String(decoding: Array(label.utf8.prefix(Int(runBytes))), as: UTF8.self)
            folderLength = (prefix as NSString).length
        }
        let baked = NSMutableAttributedString(string: title, attributes: attributes)
        if folderLength > 0, markLength + folderLength < text.length {
            baked.addAttribute(.foregroundColor, value: leadInk, range: NSRange(location: markLength, length: folderLength))
        }
        if !dimensions.isEmpty {
            let range = text.range(of: dimensions, options: .backwards)
            if range.location != NSNotFound {
                baked.addAttribute(.foregroundColor, value: detailInk, range: range)
            }
        }
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let separator = text.range(of: " — ", options: [], range: search)
            guard separator.location != NSNotFound else { break }
            baked.addAttribute(.foregroundColor, value: detailInk, range: separator)
            search = NSRange(location: NSMaxRange(separator), length: text.length - NSMaxRange(separator))
        }
        return baked
    }

    /// A run of a tab's title that only places or joins it.
    enum DimRun {
        /// The folder the title opens with, and the separator after it.
        case lead
        /// A separator, or the size the title closes with.
        case detail
    }

    /// The ink a dimmed run of a tab's title wears.
    ///
    /// A system label colour on every strip, never the theme's foreground at
    /// a lower alpha: the strip is AppKit's glass whether the title row is
    /// themed or not, the glass composites a system label colour vibrantly as
    /// it does AppKit's own titles, and the window's appearance follows the
    /// theme's lightness, so the colour resolves to the polarity legible on
    /// it. A native strip maps these colours by selection and main window
    /// itself; a themed strip writes the bake back over that map, so its bake
    /// takes the step the map takes: one fainter for a tab that is not
    /// selected, and the faintest in a window that is not active.
    ///
    /// - Parameters:
    ///   - run: Which run.
    ///   - isSelected: Whether the tab is its group's selected one.
    ///   - isWindowActive: Whether the strip's tab group holds the key or main
    ///     window of the active application.
    ///   - usesNativeColors: Whether AppKit maps the title's colours itself.
    /// - Returns: The system label colour for the run.
    static func dimInk(_ run: DimRun, isSelected: Bool, isWindowActive: Bool, usesNativeColors: Bool) -> NSColor {
        let roles: [NSColor] = [.secondaryLabelColor, .tertiaryLabelColor, .quaternaryLabelColor]
        let base = run == .lead ? 0 : 1
        let step = usesNativeColors ? 0 : !isWindowActive ? 2 : isSelected ? 0 : 1
        return roles[min(base + step, roles.count - 1)]
    }

    /// Whether a title field shows a label whole in a width: at its own
    /// spacing, or tightened, as a field whose paragraph style allows it
    /// tightens a line before it truncates one.
    ///
    /// Asked of the text system that draws the field, with the label's own
    /// paragraph style, rather than read off the label's width: how far a
    /// line may tighten depends on its font and its letters, between two and
    /// five percent of its width in the strip's fonts, so no one allowance
    /// answers for every label. The layout is a quarter point narrower than
    /// the width, the most a field was measured to need beyond the text
    /// system at the edge.
    ///
    /// A field does not tighten a label whose paragraph style does not allow
    /// it, though the text system's own layout does, so such a label is
    /// answered by its width alone.
    ///
    /// - Parameters:
    ///   - label: The label, with the paragraph style it is drawn with.
    ///   - width: The width its text may take.
    /// - Returns: Whether every glyph of the label is drawn.
    package static func drawsWhole(_ label: NSAttributedString, width: CGFloat) -> Bool {
        let natural = label.size().width
        guard natural > width else { return true }
        guard width > 0,
            (label.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.allowsDefaultTighteningForTruncation
                == true
        else { return false }
        let storage = NSTextStorage(attributedString: label)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: natural + 1, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 1
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        // A truncated line hides the glyphs its ellipsis stands for; a label
        // can hide some of its own anyway, so the count is compared with the
        // line laid out at its full width.
        func hiddenGlyphs() -> Int {
            layout.ensureLayout(for: container)
            return (0..<layout.numberOfGlyphs).reduce(0) { $0 + (layout.notShownAttribute(forGlyphAt: $1) ? 1 : 0) }
        }
        let unconstrained = hiddenGlyphs()
        container.size = NSSize(width: width - 0.25, height: .greatestFiniteMagnitude)
        return hiddenGlyphs() == unconstrained
    }

    /// The ink a tab's title text is drawn in.
    ///
    /// One function for the title and for anything that has to read as part of
    /// it, so the two cannot drift: the unread-bell mark wears exactly this,
    /// where a second spelling of the colour stays bright while the title
    /// beside it recedes with its window. The coverage is Core's
    /// (`Themes::tabTitleCoverage`), which is where a backgrounded window, the
    /// selection and Increase Contrast are all answered.
    ///
    /// - Parameters:
    ///   - isSelected: Whether the tab is its group's selected one.
    ///   - isWindowActive: Whether the strip's tab group holds the key or main
    ///     window of the active application.
    ///   - foreground: The theme foreground, packed 0xRRGGBB.
    ///   - background: The theme background the band derives from, packed
    ///     0xRRGGBB.
    ///   - usesNativeColors: Whether the native title bar is in use, where the
    ///     system's own label colours apply and AppKit does the dimming.
    /// - Returns: The ink, at the coverage the title wears.
    @objc
    public static func titleInk(
        isSelected: Bool,
        isWindowActive: Bool,
        foreground: UInt32,
        background: UInt32,
        usesNativeColors: Bool
    ) -> NSColor {
        if usesNativeColors {
            // Native controls apply their own inactive treatment. Semantic
            // roles describe title components, not a second focus dimming.
            return .labelColor
        }
        let coverage = Ubiquitty.Themes.tabTitleCoverage(
            color(foreground),
            color(background),
            facts(isSelected: isSelected, isWindowActive: isWindowActive)
        )
        return NSColor(packedRGB: foreground, alpha: CGFloat(coverage))
    }

    /// The ink a tab's accessory mark is drawn in.
    ///
    /// The ring and the dots are images on AppKit's glass, which composites a
    /// system label colour vibrantly, the backdrop showing through it as it
    /// does through AppKit's own tab controls, so they wear one on every
    /// strip: secondary for the ring and the working ellipsis, tertiary for
    /// the dots, and a step fainter in a window that is not active. The window's
    /// appearance follows the theme's lightness, so the colour resolves to the
    /// polarity legible on the strip. The shortcut hint is text set beside the
    /// title and inks as the title does: a system label role on a native strip,
    /// and on a themed one the terminal's foreground at the coverage Core names
    /// for it (`Themes::tabAccessoryCoverage`).
    ///
    /// - Parameters:
    ///   - mark: The mark being drawn.
    ///   - isSelected: Whether the mark's tab is its group's selected one.
    ///   - isWindowActive: Whether the strip's tab group holds the key or main
    ///     window of the active application.
    ///   - foreground: The theme foreground, packed 0xRRGGBB.
    ///   - background: The theme background the band derives from, packed
    ///     0xRRGGBB.
    ///   - usesNativeColors: Whether the strip is AppKit's own.
    /// - Returns: The ink the mark wears.
    static func accessoryInk(
        _ mark: Ubiquitty.Themes.TabAccessoryMark,
        isSelected: Bool,
        isWindowActive: Bool,
        foreground: UInt32,
        background: UInt32,
        usesNativeColors: Bool
    ) -> NSColor {
        if mark == .ProgressRing || mark == .ActivityDots {
            return markRole(isFaint: mark == .ActivityDots, isWindowActive: isWindowActive)
        }
        if usesNativeColors {
            return .secondaryLabelColor
        }
        let coverage = Ubiquitty.Themes.tabAccessoryCoverage(
            mark,
            color(foreground),
            color(background),
            facts(isSelected: isSelected, isWindowActive: isWindowActive)
        )
        return NSColor(packedRGB: foreground, alpha: CGFloat(coverage))
    }

    /// The ink a program's status mark wears when its status has no colour
    /// of its own, which is Core's neutral slot: the system label role the
    /// ring and the dots wear, tertiary for a program at rest.
    ///
    /// - Parameters:
    ///   - isAtRest: Whether the program reports itself idle.
    ///   - isWindowActive: Whether the strip's tab group holds the key or main
    ///     window of the active application.
    /// - Returns: The system label colour.
    static func neutralStatusInk(isAtRest: Bool, isWindowActive: Bool) -> NSColor {
        markRole(isFaint: isAtRest, isWindowActive: isWindowActive)
    }

    /// A mark's system label colour: secondary, or tertiary for a faint one,
    /// and a step fainter in a window that is not active.
    private static func markRole(isFaint: Bool, isWindowActive: Bool) -> NSColor {
        let roles: [NSColor] = [.secondaryLabelColor, .tertiaryLabelColor, .quaternaryLabelColor]
        return roles[(isFaint ? 1 : 0) + (isWindowActive ? 0 : 1)]
    }

    /// Whether a colour is one of the system's dynamic ones, which a vibrant
    /// view composites with its backdrop rather than painting flat.
    ///
    /// - Parameter color: The colour.
    /// - Returns: True for a catalog colour such as `secondaryLabelColor`.
    package static func isSystemColor(_ color: NSColor) -> Bool {
        color.type == .catalog
    }

    /// The facts Core decides a tab's coverages from, the system's contrast
    /// request included.
    private static func facts(isSelected: Bool, isWindowActive: Bool) -> Ubiquitty.Themes.TabTitleFacts {
        var facts = Ubiquitty.Themes.TabTitleFacts()
        facts.isSelected = isSelected
        facts.isWindowActive = isWindowActive
        facts.shouldIncreaseContrast = SystemDisplayOptions.shouldIncreaseContrast
        return facts
    }

    /// A packed 0xRRGGBB as Core's byte triple.
    private static func color(_ packed: UInt32) -> Ubiquitty.ColorRGBA {
        Ubiquitty.ColorRGBA(
            red: UInt8((packed >> 16) & 0xff),
            green: UInt8((packed >> 8) & 0xff),
            blue: UInt8(packed & 0xff),
            alpha: 255
        )
    }
}
