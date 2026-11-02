// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore

/// How loudly a tag announces itself, mirroring `Session::TagProminence`.
@objc(TitlebarTagProminence)
public enum TitlebarTagProminence: Int {
    case quiet
    case loud
}

/// Draws a tag's icon in one colour on a clear square.
///
/// The icons are the app's own Phosphor fonts, which this module cannot reach,
/// so the module that owns them hands the drawing in. A nil result, for a name
/// the catalog does not carry, draws what the marker draws without an icon.
/// The icon is drawn in the colour given, never as a template: its pill's
/// text beside it is that colour, and a template's tint can resolve to
/// another.
///
/// - Parameters:
///   - name: The icon's name, as the tag spells it.
///   - weight: Which of its weights.
///   - side: The square's side, in points.
///   - color: The ink.
/// - Returns: The image, or nil when the name draws nothing.
package typealias TitlebarTagIconDrawing =
    @MainActor (_ name: String, _ weight: Ubiquitty.Session.TagIconWeight, _ side: CGFloat, _ color: NSColor) -> NSImage?

/// One tag as the title bar wears it.
///
/// A tag says what a window *is* — the host it is on, the environment it
/// touches — as opposed to the tab dots, which say what just *happened* in a
/// pane. A titled tag is a pill carrying its name, led by its icon when it
/// has one. An untitled one, which only a rule with a colour can supply, is a
/// circle of that colour, holding its icon when it has one: the reader who
/// wrote the rule chose colour alone, and the spoken name keeps the mark
/// legible to a screen reader. A titled tag whose rule hides its name is drawn
/// as that circle too, and spoken by its name.
@objc(TitlebarTagMarker)
@MainActor
public final class TitlebarTagMarker: NSObject {
    /// The title the marker draws: empty for a circle, which an untitled tag
    /// draws, and a titled one whose rule hides its name
    /// (`Session::ResolvedTag::drawsName`).
    @objc
    public let name: String
    /// What a screen reader speaks for the tag: its title, or for an untitled
    /// tag Core's `Session::tagSpokenName`.
    @objc
    public let spokenName: String
    /// Unset for a tag that names something without claiming a colour.
    @objc
    public let color: NSColor?
    @objc
    public let prominence: TitlebarTagProminence
    /// The Phosphor icon the marker wears, empty for none.
    package let iconName: String
    /// The weight the icon is drawn in.
    package let iconWeight: Ubiquitty.Session.TagIconWeight
    /// Whether the host chip wears this tag as its capsule while it stands,
    /// so the marker run leaves it out rather than draw it twice.
    package let isHostTag: Bool

    /// Whether the tag draws as a circle rather than a titled pill.
    public var isUntitled: Bool { name.isEmpty }

    /// Makes a marker with no icon that the host chip does not wear.
    ///
    /// - Parameters:
    ///   - name: The title, empty for an untitled tag.
    ///   - spokenName: The spoken name; nil speaks the title.
    ///   - color: The marker's colour, nil for none.
    ///   - prominence: Whether the tag also tints the title bar.
    @objc
    public convenience init(name: String, spokenName: String? = nil, color: NSColor?, prominence: TitlebarTagProminence) {
        self.init(
            name: name,
            spokenName: spokenName,
            color: color,
            prominence: prominence,
            iconName: "",
            iconWeight: .Fill,
            isHostTag: false
        )
    }

    /// Makes a marker.
    ///
    /// - Parameters:
    ///   - name: The title, empty for an untitled tag.
    ///   - spokenName: The spoken name; nil speaks the title.
    ///   - color: The marker's colour, nil for none.
    ///   - prominence: Whether the tag also tints the title bar.
    ///   - iconName: The Phosphor icon, empty for none.
    ///   - iconWeight: The weight the icon is drawn in.
    ///   - isHostTag: Whether the host chip wears the tag while it stands.
    package init(
        name: String,
        spokenName: String?,
        color: NSColor?,
        prominence: TitlebarTagProminence,
        iconName: String,
        iconWeight: Ubiquitty.Session.TagIconWeight,
        isHostTag: Bool
    ) {
        self.name = name
        self.spokenName = spokenName ?? name
        self.color = color
        self.prominence = prominence
        self.iconName = iconName
        self.iconWeight = iconWeight
        self.isHostTag = isHostTag
    }

    /// What tells two marker lists apart for a restyle: every title, spoken
    /// name, colour and icon, and which of them the host chip wears, so two
    /// untitled tags of different colours differ.
    @MainActor
    package static func signature(of markers: [TitlebarTagMarker]) -> String {
        markers
            .map { marker in
                let color = marker.color?.usingColorSpace(.sRGB)
                    .map {
                        String(format: "%.3f,%.3f,%.3f", $0.redComponent, $0.greenComponent, $0.blueComponent)
                    }
                return [
                    marker.name, marker.spokenName, color ?? "", String(marker.prominence.rawValue), marker.iconName,
                    String(marker.iconWeight.rawValue), marker.isHostTag ? "host" : "",
                ]
                .joined(separator: "\u{1F}")
            }
            .joined(separator: "\u{0}")
    }
}

/// How the title row lays a tag's colour down: the strength the colour is
/// drawn at, and the row it is drawn over.
///
/// A pill's fill is the tag's colour at ``opacity`` over the row, so its ink
/// is chosen against that composite rather than against the colour alone,
/// which keeps a label legible at any strength. The wash a loud tag lays over
/// the whole row is not drawn through this, and keeps its own strength.
package struct TitlebarTagStyle: Equatable {
    /// The opacity a tag's colour is drawn at: `[appearance] tag_color_opacity`.
    package var opacity: CGFloat
    /// What the row shows beneath its text, as one colour. A dynamic system
    /// colour resolves under the appearance the tag is drawn in.
    package var ground: NSColor

    /// Makes a style.
    ///
    /// - Parameters:
    ///   - opacity: The opacity a tag's colour is drawn at, 0 to 1.
    ///   - ground: What the row shows beneath its text.
    package init(opacity: CGFloat, ground: NSColor) {
        self.opacity = opacity
        self.ground = ground
    }

    /// Full strength over the system's window background: how a tag is drawn
    /// before its window has described its row.
    package static var fullStrength: TitlebarTagStyle {
        TitlebarTagStyle(opacity: 1, ground: .windowBackgroundColor)
    }
}

/// Where an icon stands beside a line of the title row's text.
package enum TitleIconPlacement {
    /// The height of an icon's bottom above the text's baseline that centres
    /// the icon's cap band on the text's.
    ///
    /// An image's alignment rect is its cap band: a system symbol's runs from
    /// its baseline to its cap line, and a drawn icon's is its whole square.
    /// A symbol configured from the text's font then stands on the text's
    /// baseline, as AppKit sets one in a line of text. The height is a whole
    /// number of backing pixels, so the icon is drawn at the text's own pixel
    /// phase rather than a fraction off it.
    ///
    /// - Parameters:
    ///   - image: The icon, drawn at its own size.
    ///   - capHeight: The text's cap height.
    ///   - backingScale: The pixels per point the line is drawn at.
    /// - Returns: The height, negative for an icon that reaches below the
    ///   baseline.
    package static func bottomAboveBaseline(of image: NSImage, capHeight: CGFloat, backingScale: CGFloat) -> CGFloat {
        let pixel = max(backingScale, 1)
        return ((capHeight / 2 - image.alignmentRect.midY) * pixel).rounded() / pixel
    }
}

/// The one typography and geometry every pill in the title row shares: the
/// tag markers', drawn as an attachment image, and the host chip's, drawn as
/// a view.
///
/// Both read it from the title's own font, so a pill's text is set in the
/// title's face and stands on the title's baseline, and every pill is one
/// height centred on one line, the middle of the title's cap band. Two
/// drawings that each kept a number of their own would set their text in two
/// sizes and sit at two heights.
///
/// The pills stack: each tucks under the next one's rounded start, the later
/// on top, and reaches past what shows of it by ``overlap``, square at that
/// end. The lower pill is cut away under the upper one's start, grown by
/// ``knockout``, rather than painted over: two translucent fills never
/// composite over each other, and the gap between them shows the row as one
/// even crescent, which a rounded end pulling away above and below would
/// widen into wedges.
package struct TitlebarCapsuleGeometry {
    /// A pill's height beside the system's title type.
    package static let standardHeight: CGFloat = 22
    /// The air between each rounded end and what it holds: the icon at the
    /// leading end, the text at the trailing one.
    package static let endPadding: CGFloat = 9
    /// The air between a pill's icon and its text.
    package static let iconGap: CGFloat = 5
    /// The side of the icon a pill leads with.
    package static let iconSide: CGFloat = 15
    /// The band of row left showing between a pill and the one tucked under
    /// it, cut out of the lower one.
    package static let knockout: CGFloat = 1.5
    /// The air between the stack and the title's words when no host chip
    /// follows it.
    package static let gapAfterStack: CGFloat = 8
    /// The least air between a tucked pill's content and the knockout over
    /// it, whatever its ink.
    package static let contentClearance: CGFloat = 1
    /// How much of a circle holding nothing shows when tucked, as a share of
    /// the height: a crescent, as stacked avatars show, since all it carries
    /// is its colour.
    private static let crescentShare: CGFloat = 0.64
    /// How much less air a tucked pill's ink keeps before the next pill than
    /// after its own rounded start, as a share of the height.
    private static let hollowAllowanceShare: CGFloat = 0.22
    /// How far right of the circle's centre a tucked circle stands its icon,
    /// as a share of the height.
    private static let tuckedIconShiftShare: CGFloat = 0.09

    /// The face every pill's text is set in: the title's.
    package let font: NSFont
    /// A pill's height: the standard one, or the title's line where larger
    /// type needs more, so no accent or descender is cut off.
    package let height: CGFloat
    /// From a pill's bottom to its text's baseline, which centres the title's
    /// cap band in the pill.
    package let baselineAboveBottom: CGFloat
    /// How far a tucked pill reaches under the next one: half the height, so
    /// its square end stands under the next pill's rounded start, the end's
    /// corners inside the knockout where that start curves away.
    package let overlap: CGFloat
    /// How much of a tucked circle holding nothing shows before the next
    /// pill's start.
    package let crescentWidth: CGFloat
    /// How much less air a tucked pill's ink keeps before the next pill's
    /// start than after its own: the hollow that start cuts into the end
    /// leaves more fill showing above and below the line than a rounded start
    /// does, so equal air reads wider there.
    package let hollowAllowance: CGFloat
    /// How far right of the circle's centre a tucked circle stands its icon:
    /// the small circle's rounded start hugs the icon's corners, where the
    /// hollow at its end opens away from them.
    package let tuckedIconShift: CGFloat

    /// The geometry for a title set in one font.
    ///
    /// - Parameter titleFont: The title field's font.
    package init(titleFont: NSFont) {
        font = titleFont
        height = max(Self.standardHeight, ceil(titleFont.ascender - titleFont.descender))
        baselineAboveBottom = (height - titleFont.capHeight) / 2
        overlap = (height / 2).rounded(.up)
        crescentWidth = (height * Self.crescentShare).rounded()
        hollowAllowance = height * Self.hollowAllowanceShare
        tuckedIconShift = (height * Self.tuckedIconShiftShare).rounded()
    }

    /// How much of a tucked pill shows before the next one's start, its ink
    /// balanced between its own rounded start and the hollow that start cuts
    /// into its end.
    ///
    /// The ink keeps ``hollowAllowance`` less air before the knockout than
    /// after the pill's start, and never comes nearer the knockout than
    /// ``contentClearance``.
    ///
    /// - Parameters:
    ///   - inkStart: Where the content's ink begins, from the pill's start.
    ///   - inkEnd: Where the content's ink ends.
    ///   - contentEnd: Where the content's frames end.
    /// - Returns: The width that shows, in whole points.
    package func tuckedWidth(inkFrom inkStart: CGFloat, to inkEnd: CGFloat, contentEnd: CGFloat) -> CGFloat {
        let balanced = inkEnd + max(inkStart - hollowAllowance, 0) + Self.knockout
        return max(balanced.rounded(), (contentEnd + Self.knockout + Self.contentClearance).rounded(.up))
    }

    /// Where a pill's bottom stands, measured up from the title's baseline,
    /// as an attachment's bounds are: below it, so the cap band is centred.
    package var bottomFromTitleBaseline: CGFloat { -baselineAboveBottom }

    /// A pill's outline: a rect whose ends are half circles, which a rect as
    /// wide as it is tall makes a circle.
    ///
    /// - Parameter rect: The pill's rect.
    /// - Returns: The outline.
    package static func pillPath(_ rect: NSRect) -> NSBezierPath {
        let radius = rect.height / 2
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    /// A tucked pill's outline: a half circle at its start, and square at the
    /// end the next pill covers, so its fill meets the knockout the whole way
    /// round the next pill's start.
    ///
    /// - Parameter rect: The pill's rect, its reach under the next included.
    /// - Returns: The outline.
    package static func tuckedPillPath(_ rect: NSRect) -> NSBezierPath {
        let radius = rect.height / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
        path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.midY), radius: radius, startAngle: 90, endAngle: 270)
        path.close()
        return path
    }

    /// Clips a context to what a lower pill keeps of itself under an upper
    /// one: everything but the upper pill's shape grown by ``knockout``.
    ///
    /// Only the upper pill's rounded start reaches the lower one, so any width
    /// at least as large as the height clips the same.
    ///
    /// - Parameters:
    ///   - context: The context drawing the lower pill, its pills' bottoms at
    ///     zero.
    ///   - leadingEdge: Where the upper pill starts.
    ///   - width: The upper pill's width.
    ///   - bounds: What the context draws into.
    package func clipOutPill(in context: CGContext, startingAt leadingEdge: CGFloat, width: CGFloat, within bounds: NSRect) {
        let grown = NSRect(
            x: leadingEdge - Self.knockout,
            y: -Self.knockout,
            width: max(width, height) + 2 * Self.knockout,
            height: height + 2 * Self.knockout
        )
        let radius = grown.height / 2
        let path = CGMutablePath()
        path.addRect(bounds.union(grown))
        path.addRoundedRect(in: grown, cornerWidth: radius, cornerHeight: radius)
        context.addPath(path)
        context.clip(using: .evenOdd)
    }
}

/// One tag as the stack drew it.
///
/// An image cannot say whether it holds a circle or a pill, at what strength
/// its colour was laid down or in what ink, and a scenario asking what the
/// row shows has to read what was drawn rather than decide it again.
package struct TitlebarTagMark {
    /// The tag's title, empty for an untitled tag's circle.
    package let name: String
    /// The icon the pill drew, empty when it drew none.
    package let iconName: String
    /// The colour the pill was filled with, before its strength: the tag's
    /// own, the row's dim ink for a tag with none, or the colour an inverted
    /// pill takes against the wash.
    package let fill: NSColor
    /// The opacity the tag's colour was drawn at; 1 for a fill in a colour
    /// other than its tag's.
    package let fillOpacity: CGFloat
    /// The one colour its text and icon are drawn in; nil for a circle that
    /// holds neither.
    package let ink: NSColor?
    /// The pill drawn alone, as wide as ``frame``, before the next pill cut
    /// into it.
    package let image: NSImage
    /// The pill's rect in the stack's image, its reach under the next pill
    /// included.
    package let frame: NSRect
    /// The same rect measured from the title's baseline, as an attachment's
    /// bounds are.
    package let bounds: NSRect
    /// How much of the pill shows before the next one's start: tucked, its
    /// ink balanced against the next pill's hollow, or a crescent for a
    /// circle holding nothing; standing alone, its whole width.
    package let visibleWidth: CGFloat
    /// Whether the pill tucks under the next, square at that end.
    package let isTucked: Bool
    /// Where its icon stands in ``image``; nil without one.
    package let iconFrame: NSRect?
    /// Where its text stands in ``image``, the baseline at the rect's bottom;
    /// nil for a circle.
    package let textFrame: NSRect?

    /// Whether the tag drew as a circle rather than a titled pill.
    package var isUntitled: Bool { name.isEmpty }
}

/// The tag stack's attachment in the title, which keeps what it drew.
///
/// One attachment holds the whole stack: text layout does not let one
/// attachment overlap the next, and a stack drawn piecewise across several
/// would split a pill's fill along their seams.
package final class TitlebarTagAttachment: NSTextAttachment {
    /// The tags the stack drew, in order.
    package let marks: [TitlebarTagMark]
    /// Whether the stack's last pill reaches under the host chip, which the
    /// title then places that far over it.
    package let isTuckedUnderHostChip: Bool

    /// Makes the attachment for one stack.
    ///
    /// - Parameters:
    ///   - marks: The tags the stack drew, in order.
    ///   - isTuckedUnderHostChip: Whether its last pill reaches under the chip.
    package init(marks: [TitlebarTagMark], isTuckedUnderHostChip: Bool) {
        self.marks = marks
        self.isTuckedUnderHostChip = isTuckedUnderHostChip
        super.init(data: nil, ofType: nil)
    }

    /// Decodes an attachment, which keeps none of what was drawn: those are
    /// readings of one drawing, and an archived copy is not that drawing.
    ///
    /// - Parameter coder: The archive.
    required init?(coder: NSCoder) {
        marks = []
        isTuckedUnderHostChip = false
        super.init(coder: coder)
    }
}

/// Renders a window's tags as one stack of overlapping pills at the head of
/// the window title.
///
/// A titled tag is a pill carrying its name, led by its icon when it has one;
/// an untitled one is a circle as tall as a pill, holding its icon when it has
/// one. Each pill tucks under the next, and the last under the host chip when
/// the chip wears a capsule, by ``TitlebarCapsuleGeometry``'s rules. One inline
/// attachment keeps the stack beside the title without a leading accessory
/// shifting its horizontal placement; the title field grows vertically to
/// contain it.
package enum TitlebarTagChip {
    /// One pill before it is placed: its fill, what it holds, and where.
    private struct Pill {
        /// The tag's colour as it is laid down, at its strength.
        let fill: NSColor
        /// The text, in the title's face and the pill's ink; nil for a circle.
        let label: NSAttributedString?
        /// The icon, drawn in the pill's ink; nil for none.
        let icon: NSImage?
        /// How much of it shows: its whole width standing alone, or what shows
        /// before the next pill's start when tucked.
        let visibleWidth: CGFloat
        /// Where its icon stands, from its own leading edge and bottom.
        let iconFrame: NSRect?
        /// Where its text stands, from its own leading edge, the baseline at
        /// the rect's bottom.
        let textFrame: NSRect?
    }

    /// The stack as an attributed run, empty when there are no tags.
    ///
    /// - Parameters:
    ///   - markers: The tags to draw, in resolved order.
    ///   - titleFont: The title's font, whose face the pills' text is set in
    ///     and whose cap band they are centred on.
    ///   - uncoloredFill: The fill a tag with no colour of its own borrows.
    ///   - tint: The title bar's tint, if a loud tag supplies one.
    ///   - omitsHostTag: Whether the host chip stands and wears the marker
    ///     flagged ``TitlebarTagMarker/isHostTag``, which the run then leaves
    ///     out. The tint is still decided over every marker, so a loud host tag
    ///     that washed the row does not hand its inversion to another.
    ///   - isTuckedUnderHostChip: Whether the host chip follows the run as a
    ///     capsule, so the stack's last pill reaches under it, cut by its
    ///     start, with no air after it.
    ///   - iconDrawing: What draws a marker's icon; nil draws none.
    ///   - style: How the row lays tag colours down: the strength a tag's
    ///     colour is drawn at, and what a pill's ink is chosen against.
    ///   - appearance: The title's appearance, which a dynamic colour resolves
    ///     under; nil takes the app's.
    /// - Returns: The run to prefix the title with.
    @MainActor
    package static func attributedRun(
        for markers: [TitlebarTagMarker],
        titleFont: NSFont,
        uncoloredFill: NSColor,
        tint: NSColor?,
        omitsHostTag: Bool = false,
        isTuckedUnderHostChip: Bool = false,
        iconDrawing: TitlebarTagIconDrawing? = nil,
        style: TitlebarTagStyle = .fullStrength,
        appearance: NSAppearance? = nil
    ) -> NSAttributedString {
        let drawn = omitsHostTag ? markers.filter { !$0.isHostTag } : markers
        guard !drawn.isEmpty else {
            return NSAttributedString()
        }
        let rowAppearance = appearance ?? NSApp.effectiveAppearance
        let tintingMarker = tintingMarker(among: markers)
        let geometry = TitlebarCapsuleGeometry(titleFont: titleFont)
        let height = geometry.height

        var pills: [Pill] = []
        var marks: [TitlebarTagMark] = []
        var origins: [CGFloat] = []
        var widths: [CGFloat] = []
        var x: CGFloat = 0
        for (index, marker) in drawn.enumerated() {
            // The tag that tinted the bar cannot also be a pill of that colour
            // ON that bar — it would be invisible. It inverts instead: the pill
            // takes the colour that reads against the tint, and the ink takes
            // the tint. The name survives, which is the point. The inverted
            // colours are not the tag's, so the strength leaves them whole: a
            // dimmed pill would sink back into the wash.
            let isInverted = marker === tintingMarker && tint != nil
            // The strength dims a tag's own colour; a tag with none borrows
            // the row's dim ink, which carries its own alpha already.
            let opacity = isInverted || marker.color == nil ? 1 : style.opacity
            let fill: NSColor
            let ink: NSColor
            if isInverted, let tint {
                fill = labelColor(on: tint)
                ink = tint
            } else {
                fill = marker.color ?? uncoloredFill
                var laid = style
                laid.opacity = opacity
                ink = self.ink(onFill: fill, style: laid, appearance: rowAppearance)
            }
            let icon = iconImage(for: marker, color: ink, drawing: iconDrawing)
            let isTucked = index < drawn.count - 1 || isTuckedUnderHostChip
            let pill =
                marker.isUntitled
                ? circle(fill: laidDown(fill, opacity: opacity), icon: icon, geometry: geometry, isTucked: isTucked)
                : capsule(
                    name: marker.name,
                    fill: laidDown(fill, opacity: opacity),
                    ink: ink,
                    icon: icon,
                    geometry: geometry,
                    isTucked: isTucked
                )
            let visibleWidth = pill.visibleWidth
            let width = visibleWidth + (isTucked ? geometry.overlap : 0)
            let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
                draw(pill, at: 0, width: width, height: height, isTucked: isTucked)
                return true
            }
            image.accessibilityDescription = marker.isUntitled ? marker.spokenName : marker.name
            let frame = NSRect(x: x, y: 0, width: width, height: height)
            marks.append(
                TitlebarTagMark(
                    name: marker.name,
                    iconName: icon == nil ? "" : marker.iconName,
                    fill: fill,
                    fillOpacity: opacity,
                    ink: icon == nil && marker.isUntitled ? nil : ink,
                    image: image,
                    frame: frame,
                    bounds: frame.offsetBy(dx: 0, dy: geometry.bottomFromTitleBaseline),
                    visibleWidth: visibleWidth,
                    isTucked: isTucked,
                    iconFrame: pill.iconFrame,
                    textFrame: pill.textFrame
                )
            )
            pills.append(pill)
            origins.append(x)
            widths.append(width)
            x += visibleWidth
        }
        // A tucked last pill ends where the chip's own reach does; a free one
        // keeps the air before the title inside the image, since text layout
        // is free to drop the trailing kern of a run.
        let lastEnd = origins[origins.count - 1] + widths[widths.count - 1]
        let stackWidth = isTuckedUnderHostChip ? lastEnd : lastEnd + TitlebarCapsuleGeometry.gapAfterStack
        let chipStart = x
        let stackBounds = NSRect(x: 0, y: 0, width: stackWidth, height: height)
        // Each pill is cut by the start of the one above it, the last by the
        // chip's, before it is drawn: a lower fill never lies under an upper
        // one, so translucent fills do not composite over each other.
        let image = NSImage(size: stackBounds.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            for index in pills.indices {
                context.saveGState()
                if index + 1 < pills.count {
                    geometry.clipOutPill(in: context, startingAt: origins[index + 1], width: widths[index + 1], within: stackBounds)
                } else if isTuckedUnderHostChip {
                    geometry.clipOutPill(in: context, startingAt: chipStart, width: height, within: stackBounds)
                }
                draw(pills[index], at: origins[index], width: widths[index], height: height, isTucked: marks[index].isTucked)
                context.restoreGState()
            }
            return true
        }
        image.accessibilityDescription = drawn.map(\.spokenName).joined(separator: ", ")
        let attachment = TitlebarTagAttachment(marks: marks, isTuckedUnderHostChip: isTuckedUnderHostChip)
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: geometry.bottomFromTitleBaseline, width: stackWidth, height: height)
        return NSAttributedString(attachment: attachment)
    }

    /// The sentence a screen reader hears in place of the stack.
    ///
    /// Every tag is named, an untitled one by its spoken name, so a circle is
    /// never announced as nothing.
    @MainActor
    package static func accessibilityDescription(for markers: [TitlebarTagMarker]) -> String? {
        guard !markers.isEmpty else {
            return nil
        }
        return "Tagged " + markers.map(\.spokenName).joined(separator: ", ")
    }

    /// The tag that decides the title bar's tint, if any.
    ///
    /// Only a loud tag tints, and only the first one: two tints cannot both be
    /// the background, and a window where everything shouts says nothing.
    @MainActor
    package static func tintingMarker(among markers: [TitlebarTagMarker]) -> TitlebarTagMarker? {
        markers.first { $0.prominence == .loud && $0.color != nil }
    }

    /// A tag's colour as it is drawn at a strength: its own alpha scaled by
    /// the opacity, and the colour untouched at full strength, so a dynamic
    /// colour a tag borrows stays dynamic.
    ///
    /// - Parameters:
    ///   - color: The colour.
    ///   - opacity: The strength it is drawn at, 0 to 1.
    /// - Returns: The colour to fill with.
    package static func laidDown(_ color: NSColor, opacity: CGFloat) -> NSColor {
        opacity >= 1 ? color : color.withAlphaComponent(color.alphaComponent * opacity)
    }

    /// A tag's fill as the eye meets it: the fill at the style's opacity, laid
    /// over the row's ground.
    ///
    /// Mixed on the encoded components, as Core Animation composites the
    /// row's layers, so the colour the ink is chosen against is the one drawn.
    ///
    /// - Parameters:
    ///   - fill: The tag's colour; its own alpha is scaled by the opacity.
    ///   - style: How the row lays tag colours down.
    ///   - appearance: The appearance a dynamic ground resolves under.
    /// - Returns: The composite, opaque sRGB; the fill itself when either
    ///   colour has no sRGB form.
    @MainActor
    package static func compositedFill(_ fill: NSColor, style: TitlebarTagStyle, appearance: NSAppearance) -> NSColor {
        var resolvedFill: NSColor?
        var resolvedGround: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedFill = fill.usingColorSpace(.sRGB)
            resolvedGround = style.ground.usingColorSpace(.sRGB)
        }
        guard let top = resolvedFill, let ground = resolvedGround else {
            return fill
        }
        let alpha = (top.alphaComponent * style.opacity).clamped(to: 0...1)
        let mix = { (over: CGFloat, under: CGFloat) -> CGFloat in over * alpha + under * (1 - alpha) }
        return NSColor(
            srgbRed: mix(top.redComponent, ground.redComponent),
            green: mix(top.greenComponent, ground.greenComponent),
            blue: mix(top.blueComponent, ground.blueComponent),
            alpha: 1
        )
    }

    /// The ink a pill of one fill takes on one row: Core's contrast choice
    /// against the fill as it composites over the row.
    ///
    /// One concrete colour for everything the pill holds — its text, its icon
    /// and its hairlines — so they cannot disagree. A system label colour
    /// would take the row's vibrancy, which pulls the desktop's colour into
    /// text on a coloured fill and washes it out over a blurred window, and a
    /// template icon beside that text would not follow it.
    ///
    /// - Parameters:
    ///   - fill: The tag's colour.
    ///   - style: How the row lays tag colours down.
    ///   - appearance: The row's appearance, which a dynamic colour resolves
    ///     under.
    /// - Returns: The ink, opaque sRGB.
    @MainActor
    package static func ink(onFill fill: NSColor, style: TitlebarTagStyle, appearance: NSAppearance) -> NSColor {
        labelColor(on: compositedFill(fill, style: style, appearance: appearance))
    }

    /// The label colour Core picks for this fill, so a pill's text is legible
    /// on it by the same rule the tmux pill uses rather than by a second guess.
    ///
    /// - Parameter fill: The colour the label is drawn on.
    /// - Returns: The readable ink, opaque.
    @MainActor
    package static func labelColor(on fill: NSColor) -> NSColor {
        guard let srgb = fill.usingColorSpace(.sRGB) else {
            return .white
        }
        let channel = { (value: CGFloat) -> UInt32 in
            UInt32((value.clamped(to: 0...1) * 255).rounded())
        }
        let packed =
            (channel(srgb.redComponent) << 16)
            | (channel(srgb.greenComponent) << 8)
            | channel(srgb.blueComponent)
        let label = Ubiquitty.Themes.Contrast.labelColorOnFill(packed)
        return NSColor(
            srgbRed: CGFloat((label >> 16) & 0xff) / 255,
            green: CGFloat((label >> 8) & 0xff) / 255,
            blue: CGFloat(label & 0xff) / 255,
            alpha: 1
        )
    }

    /// A marker's icon in its pill's ink, or nil when it has none or the
    /// drawing does not know its name.
    @MainActor
    private static func iconImage(for marker: TitlebarTagMarker, color: NSColor, drawing: TitlebarTagIconDrawing?) -> NSImage? {
        guard !marker.iconName.isEmpty, let drawing else { return nil }
        return drawing(marker.iconName, marker.iconWeight, TitlebarCapsuleGeometry.iconSide, color)
    }

    /// An untitled tag's circle: as tall as a pill, holding the icon when the
    /// tag has one. Tucked, one holding nothing shows a crescent, and one
    /// holding an icon stands it ``TitlebarCapsuleGeometry/tuckedIconShift``
    /// right of centre and shows as much as balances the icon's ink.
    @MainActor
    private static func circle(fill: NSColor, icon: NSImage?, geometry: TitlebarCapsuleGeometry, isTucked: Bool) -> Pill {
        let side = TitlebarCapsuleGeometry.iconSide
        let inset = (geometry.height - side) / 2
        let iconX = inset + (isTucked ? geometry.tuckedIconShift : 0)
        let iconFrame = icon == nil ? nil : NSRect(x: iconX, y: inset, width: side, height: side)
        var visibleWidth = isTucked ? geometry.crescentWidth : geometry.height
        if isTucked, let icon, let iconFrame {
            let ink = inkShare(of: icon) ?? 0...1
            visibleWidth = geometry.tuckedWidth(
                inkFrom: iconFrame.minX + ink.lowerBound * side,
                to: iconFrame.minX + ink.upperBound * side,
                contentEnd: iconFrame.maxX
            )
        }
        return Pill(fill: fill, label: nil, icon: icon, visibleWidth: visibleWidth, iconFrame: iconFrame, textFrame: nil)
    }

    /// A titled tag's pill: the icon at the leading end when it has one, then
    /// the title in the title's face, each end padded alike.
    @MainActor
    private static func capsule(
        name: String,
        fill: NSColor,
        ink: NSColor,
        icon: NSImage?,
        geometry: TitlebarCapsuleGeometry,
        isTucked: Bool
    ) -> Pill {
        let label = NSAttributedString(string: name, attributes: [.font: geometry.font, .foregroundColor: ink])
        let advance = ceil(label.size().width)
        let padding = TitlebarCapsuleGeometry.endPadding
        let side = TitlebarCapsuleGeometry.iconSide
        let textX = icon == nil ? padding : padding + side + TitlebarCapsuleGeometry.iconGap
        // The icon is centred in the pill, which is centred on the title's cap
        // band, so the icon and the capitals beside it share one middle.
        let iconFrame = icon == nil ? nil : NSRect(x: padding, y: (geometry.height - side) / 2, width: side, height: side)
        // A tucked pill balances ink rather than advances: each glyph's side
        // bearings, and an icon's air inside its square, differ.
        let glyphs = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(label), .useGlyphPathBounds)
        let textInk = glyphs.isNull || glyphs.width <= 0 ? 0...advance : glyphs.minX...glyphs.maxX
        let inkStart: CGFloat
        if let icon, let iconFrame {
            inkStart = iconFrame.minX + (inkShare(of: icon)?.lowerBound ?? 0) * side
        } else {
            inkStart = textX + textInk.lowerBound
        }
        return Pill(
            fill: fill,
            label: label,
            icon: icon,
            visibleWidth: isTucked
                ? geometry.tuckedWidth(inkFrom: inkStart, to: textX + textInk.upperBound, contentEnd: textX + advance)
                : textX + advance + padding,
            iconFrame: iconFrame,
            textFrame: NSRect(x: textX, y: geometry.baselineAboveBottom, width: advance, height: geometry.font.capHeight)
        )
    }

    /// Where an image's ink spans across it, as shares of its width: the
    /// columns holding a pixel more than faintly opaque; nil for an image with
    /// none.
    ///
    /// - Parameter image: The image, such as an icon on its clear square.
    /// - Returns: The span, within 0 to 1.
    @MainActor
    private static func inkShare(of image: NSImage) -> ClosedRange<CGFloat>? {
        let scale: CGFloat = 4
        let columns = Int((image.size.width * scale).rounded(.up))
        let rows = Int((image.size.height * scale).rounded(.up))
        guard columns > 0, rows > 0,
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: columns,
                pixelsHigh: rows,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(bitmapImageRep: bitmap), let data = bitmap.bitmapData
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(columns), height: CGFloat(rows)))
        NSGraphicsContext.restoreGraphicsState()
        var first = columns
        var last = -1
        for row in 0..<rows {
            for column in 0..<columns where data[row * bitmap.bytesPerRow + column * 4 + 3] > 32 {
                first = min(first, column)
                last = max(last, column)
            }
        }
        guard last >= first else { return nil }
        return CGFloat(first) / CGFloat(columns)...CGFloat(last + 1) / CGFloat(columns)
    }

    /// Draws one pill into the current context, its bottom at zero.
    ///
    /// The text is drawn from its baseline, which the rect's origin names when
    /// the line-fragment option is left off, so it stands where the title's
    /// does.
    ///
    /// - Parameters:
    ///   - pill: The pill.
    ///   - x: Where its leading edge stands.
    ///   - width: Its width, its reach under the next pill included.
    ///   - height: Its height.
    ///   - isTucked: Whether it tucks under the next, square at that end.
    private static func draw(_ pill: Pill, at x: CGFloat, width: CGFloat, height: CGFloat, isTucked: Bool) {
        pill.fill.setFill()
        let rect = NSRect(x: x, y: 0, width: width, height: height)
        (isTucked ? TitlebarCapsuleGeometry.tuckedPillPath(rect) : TitlebarCapsuleGeometry.pillPath(rect)).fill()
        if let icon = pill.icon, let frame = pill.iconFrame {
            icon.draw(in: frame.offsetBy(dx: x, dy: 0))
        }
        if let label = pill.label, let frame = pill.textFrame {
            label.draw(with: NSRect(x: x + frame.minX, y: frame.minY, width: width, height: 0), options: [], context: nil)
        }
    }
}

extension CGFloat {
    fileprivate func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
