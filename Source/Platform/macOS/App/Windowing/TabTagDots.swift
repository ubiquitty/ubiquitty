// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// TabTagDots.swift — the window's tags, as marks before its tab's title, and
// before a pane header's.
//
// A tagged window's tab leads its title with every tag Core places on the tab,
// in the window's order: each as the tag's icon in its colour, or as a small dot
// of that colour when it has none, at the strength the configuration lays tag
// colours down at. A tag that claims no colour is drawn in the title's own ink.
// The marks are the first run of the tab's own attributed title, as a site's
// icon stands before its page's title in a browser's tab: AppKit lays the run
// and the title out and centres them in the pill as one, so the marks move with
// the title, leave the close control and the accessory to AppKit, and need no
// placing of their own when AppKit rebuilds the pills.
//
// A tab is narrow, so the run holds at most three marks. Past that it draws the
// first three and a count of the rest, "+2", in the title's ink; the tooltip and
// the spoken description name every tag.
//
// An icon is 16 points, the size of the site icon a browser tab leads with and
// of the process icon beside it, so the icons before a title read as one row. A
// plain dot is sized from the label's own face, about its x-height, a bullet
// beside the text. Each centres on the cap band. The gap to the text rides
// inside the image, on the side the text is: the title field does not apply a
// kern on an attachment.

import AppKit
internal import UbiquittyCore

/// One tag a tab's title leads with.
package struct TabTagMark: Equatable {
    /// The tag's colour, at full strength; nil for a tag that claims none,
    /// which is drawn in the title's ink.
    package var color: NSColor?
    /// The tag's Phosphor icon, drawn in place of the dot; empty for none.
    package var iconName: String
    /// The weight the icon is drawn in.
    package var iconWeight: Ubiquitty.Session.TagIconWeight

    /// Makes a mark.
    ///
    /// - Parameters:
    ///   - color: The tag's colour, at full strength; nil for none.
    ///   - iconName: The tag's icon, empty for a dot.
    ///   - iconWeight: The weight the icon is drawn in.
    package init(color: NSColor?, iconName: String, iconWeight: Ubiquitty.Session.TagIconWeight) {
        self.color = color
        self.iconName = iconName
        self.iconWeight = iconWeight
    }
}

/// The tags a title leads with, in the window's order.
package struct TabTagMarkRun: Equatable {
    /// One mark for each tag, first first.
    package var marks: [TabTagMark]
    /// The opacity the tags' colours are drawn at: `[appearance] tag_color_opacity`.
    package var opacity: CGFloat
    /// The names of every tag in the run, which the run is spoken by.
    package var spokenNames: String

    /// Makes a run.
    ///
    /// - Parameters:
    ///   - marks: The tags, in order.
    ///   - opacity: The opacity their colours are drawn at.
    ///   - spokenNames: Their names, for a screen reader.
    package init(marks: [TabTagMark], opacity: CGFloat, spokenNames: String) {
        self.marks = marks
        self.opacity = opacity
        self.spokenNames = spokenNames
    }
}

/// The attachment a title leads with, which keeps what it drew.
///
/// The image alone cannot say whether it holds dots or icons, how large the
/// marks in it are, or at what strength, and a scenario asking what the tab
/// shows has to read what was drawn rather than decide it again.
package final class TabTagMarkAttachment: NSTextAttachment {
    /// The icon each drawn mark holds, in drawing order; empty for a dot.
    package let iconNames: [String]
    /// How many of the run's tags are counted rather than drawn, after the
    /// marks; zero when every tag has its mark.
    package let overflowCount: Int
    /// The opacity the tags' colours were drawn at.
    package let opacity: CGFloat
    /// The side of the leading mark's dot or icon, without the air after it;
    /// zero for a run that draws no mark and only names its tags.
    package let markSide: CGFloat
    /// The air between the run and the title's text.
    package let gap: CGFloat

    /// The icon the leading mark drew, empty when it drew a dot.
    package var iconName: String { iconNames.first ?? "" }

    /// Makes an attachment for one run.
    ///
    /// - Parameters:
    ///   - iconNames: The icon each drawn mark holds, empty for a dot.
    ///   - overflowCount: How many tags are counted rather than drawn.
    ///   - opacity: The opacity the colours are drawn at.
    ///   - markSide: The leading mark's side.
    ///   - gap: The air after the run.
    package init(iconNames: [String], overflowCount: Int, opacity: CGFloat, markSide: CGFloat, gap: CGFloat) {
        self.iconNames = iconNames
        self.overflowCount = overflowCount
        self.opacity = opacity
        self.markSide = markSide
        self.gap = gap
        super.init(data: nil, ofType: nil)
    }

    /// Decodes an attachment, which keeps none of what was drawn: those are
    /// readings of one drawing, and an archived copy is not that drawing.
    ///
    /// - Parameter coder: The archive.
    required init?(coder: NSCoder) {
        iconNames = []
        overflowCount = 0
        opacity = 1
        markSide = 0
        gap = 0
        super.init(coder: coder)
    }
}

/// Leads a tab's baked title, or a pane header's, with the window's tag marks.
@MainActor
package enum TabTagMarks {
    private enum Metrics {
        /// An icon's side: the size Safari draws a site's icon at in its tab,
        /// so a tab's leading icon reads as a browser tab's does.
        static let iconSide: CGFloat = 16
        /// How far a plain dot's diameter exceeds the label's x-height, so it
        /// reads as a bullet beside the text and not as a control.
        static let dotBeyondXHeight: CGFloat = 1
        /// The air between the run and the title's text.
        static let gap: CGFloat = 5
        /// The air between two marks of the run, and before its count.
        static let spacing: CGFloat = 3
        /// The most marks a run draws before it counts the rest.
        static let maxDrawnMarks = 3
    }

    /// The most marks a title leads with; a run of more draws this many and
    /// a count of the rest.
    package static var maxDrawnMarks: Int { Metrics.maxDrawnMarks }

    /// The title with the run before it, or the title as it was for none.
    ///
    /// The run takes the attributes of the title's first run, its face, ink
    /// and paragraph among them, so the field reads the pair as one line and
    /// the title's first character still answers for the whole. A long title
    /// truncates in its middle once the run leads it, as a title the pin or
    /// the host leads does, so the marks and the title's tail both stay.
    ///
    /// A run that draws no mark but names tags, the ones a Sync window's chip
    /// carries, still leads the title, as an attachment no wider than nothing:
    /// its description is what a screen reader hears in the title's place.
    ///
    /// - Parameters:
    ///   - baked: The baked title.
    ///   - run: The tags, nil, or a run that neither draws nor names one, for
    ///     none.
    /// - Returns: The title the tab or the header wears.
    package static func title(_ baked: NSAttributedString, leadingWith run: TabTagMarkRun?) -> NSAttributedString {
        guard let run, !run.marks.isEmpty || !run.spokenNames.isEmpty, baked.length > 0 else { return baked }
        var leading = baked.attributes(at: 0, effectiveRange: nil)
        let font = leading[.font] as? NSFont ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let ink = leading[.foregroundColor] as? NSColor ?? .labelColor
        let paragraph =
            (leading[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        leading[.font] = font
        leading[.attachment] = attachment(for: run, font: font, ink: ink, isRightToLeft: isRightToLeft(baked.string))
        let titled = NSMutableAttributedString(string: "\u{FFFC}", attributes: leading)
        titled.append(baked)
        titled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: titled.length))
        return titled
    }

    /// A mark's side for a label set in one face: 16 points for an icon,
    /// whatever the face, and a dot's from the face's x-height.
    ///
    /// - Parameters:
    ///   - font: The label's face, which sizes a dot.
    ///   - hasIcon: Whether the mark is an icon.
    /// - Returns: The side, in points.
    package static func markSide(for font: NSFont, hasIcon: Bool) -> CGFloat {
        hasIcon ? Metrics.iconSide : ceil(font.xHeight + Metrics.dotBeyondXHeight)
    }

    /// One mark as it is drawn: its icon, if the catalog carries it, and its
    /// side.
    private struct Drawn {
        let mark: TabTagMark
        let icon: NSImage?
        let side: CGFloat
    }

    /// The run as one attachment centred on the label's cap band.
    ///
    /// One attachment for every mark, so a screen reader hears the run once
    /// and text layout cannot break the run across a truncation.
    ///
    /// - Parameters:
    ///   - run: The tags.
    ///   - font: The label's face.
    ///   - ink: The label's text colour, which a tag without a colour and the
    ///     count of the rest are drawn in.
    ///   - isRightToLeft: Whether the title runs right to left, which lays the
    ///     marks from the right and puts the text, and so the gap, on the
    ///     image's left.
    /// - Returns: The attachment.
    private static func attachment(for run: TabTagMarkRun, font: NSFont, ink: NSColor, isRightToLeft: Bool) -> TabTagMarkAttachment {
        let iconSide = markSide(for: font, hasIcon: true)
        let dotSide = markSide(for: font, hasIcon: false)
        let drawn = run.marks.prefix(Metrics.maxDrawnMarks)
            .map { mark -> Drawn in
                let icon =
                    mark.iconName.isEmpty
                    ? nil
                    : PhosphorIcons.image(named: mark.iconName, weight: mark.iconWeight, side: iconSide, color: mark.color ?? ink)
                return Drawn(mark: mark, icon: icon, side: icon == nil ? dotSide : iconSide)
            }
        let overflowCount = run.marks.count - drawn.count
        let overflow =
            overflowCount > 0
            ? NSAttributedString(string: "+\(overflowCount)", attributes: [.font: font, .foregroundColor: ink]) : nil
        let overflowWidth = overflow.map { ceil($0.size().width) } ?? 0

        // A run that draws nothing takes no room, not even the gap.
        let gap = drawn.isEmpty ? 0 : Metrics.gap
        let marksWidth = drawn.map(\.side).reduce(0, +) + Metrics.spacing * CGFloat(max(drawn.count - 1, 0))
        let contentWidth = marksWidth + (overflow == nil ? 0 : Metrics.spacing + overflowWidth)
        let height = max(drawn.map(\.side).max() ?? dotSide, overflow == nil ? 0 : ceil(font.capHeight) + 2)
        let width = contentWidth + gap
        let opacity = run.opacity
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            // Laid in reading order from the side the title starts on.
            var cursor: CGFloat = isRightToLeft ? width : 0
            func place(_ length: CGFloat) -> CGFloat {
                defer { cursor += isRightToLeft ? -(length + Metrics.spacing) : length + Metrics.spacing }
                return isRightToLeft ? cursor - length : cursor
            }
            for item in drawn {
                let square = NSRect(x: place(item.side), y: (height - item.side) / 2, width: item.side, height: item.side)
                // A tag's own colour takes the strength; the title's ink is
                // already the label's.
                let fraction = item.mark.color == nil ? 1 : opacity
                if let icon = item.icon {
                    icon.draw(in: square, from: .zero, operation: .sourceOver, fraction: fraction)
                    continue
                }
                let fill = item.mark.color ?? ink
                fill.withAlphaComponent(fill.alphaComponent * fraction).setFill()
                NSBezierPath(ovalIn: square).fill()
            }
            if let overflow {
                let x = place(overflowWidth)
                // On the cap band, as the title's own capitals are.
                overflow.draw(at: NSPoint(x: x, y: (height - font.capHeight) / 2))
            }
            return true
        }
        image.accessibilityDescription = run.spokenNames.isEmpty ? nil : "Tagged \(run.spokenNames)"
        let attachment = TabTagMarkAttachment(
            iconNames: drawn.map { $0.icon == nil ? "" : $0.mark.iconName },
            overflowCount: overflowCount,
            opacity: opacity,
            markSide: drawn.first?.side ?? 0,
            gap: gap
        )
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - height) / 2, width: width, height: height)
        return attachment
    }

    /// Whether a title's first strongly directional character is a
    /// right-to-left one, which is what sets the side its paragraph starts on.
    ///
    /// - Parameter text: The title.
    /// - Returns: True for a title that starts on the right.
    private static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                return true
            default:
                if scalar.properties.isAlphabetic {
                    return false
                }
            }
        }
        return false
    }
}
