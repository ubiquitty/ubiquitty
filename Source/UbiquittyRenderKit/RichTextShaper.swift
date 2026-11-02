// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CoreText
import Foundation
import UbiquittyCore

/// One attributed paragraph source for both measurement and rasterization.
/// CoreText sees the complete source, so fallback, kerning, ligatures and bidi
/// context survive line breaks and changes of color.
package struct RichTextTypesetter {
    package let source: NSAttributedString
    package let typesetter: CTTypesetter
    package let utf16Offsets: [Int]
    private let scalarOffsets: [Int: Int]
    private let alignments: [(Int, Ubiquitty.RichText.Alignment)]
    private let codePoints: [UInt32]
    private let paragraphs: [(first: Int, end: Int, paragraph: Ubiquitty.RichText.Paragraph)]

    package init(
        text: [UInt32],
        styles: [Ubiquitty.RichText.DrawnStyle],
        faces: RichTextFaces,
        automaticColor: CGColor,
        tabWidth: CGFloat = 64
    ) {
        var scalars = String.UnicodeScalarView()
        var offsets = [0]
        for codePoint in text {
            let scalar = Unicode.Scalar(codePoint)!
            scalars.append(scalar)
            offsets.append(offsets.last! + (codePoint > 0xFFFF ? 2 : 1))
        }
        let string = NSMutableAttributedString(string: String(scalars))
        for style in styles {
            let font = faces.font(
                style.familyClass,
                familyName: String(style.familyName()),
                isBold: style.styles & 1 != 0,
                isItalic: style.styles & 2 != 0,
                size: CGFloat(style.halfPoints) / 2
            )
            let color =
                style.isAutomaticColor != 0
                ? automaticColor
                : CGColor(srgbRed: CGFloat(style.red) / 255, green: CGFloat(style.green) / 255, blue: CGFloat(style.blue) / 255, alpha: 1)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTLigatureAttributeName as String): 1,
            ]
            string.addAttributes(
                attributes,
                range: NSRange(location: offsets[Int(style.first)], length: offsets[Int(style.end)] - offsets[Int(style.first)])
            )
        }
        let paragraphs = styles.map { (first: Int($0.first), end: Int($0.end), paragraph: $0.paragraph) }
        // Tabs stop every eight cells from the box's left edge, which every line
        // is created at its indent from. A hanging first line's first tab stops
        // at the left indent instead, where the paragraph's other lines start.
        var paragraphStart = 0
        while paragraphStart < text.count {
            let end = Self.paragraphEnd(text, paragraphStart)
            let properties = paragraphs.last { $0.first <= paragraphStart }?.paragraph ?? Ubiquitty.RichText.Paragraph()
            var interval = tabWidth
            let hanging = Self.points(Ubiquitty.RichText.hangingTabStop(properties, Ubiquitty.RichText.LinePlace()))
            var stops = (hanging > 0 ? [CTTextTabCreate(.left, hanging, nil)] : []) as CFArray
            let style = withUnsafePointer(to: &interval) { intervalPointer in
                withUnsafePointer(to: &stops) { stopsPointer in
                    let settings = [
                        CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: intervalPointer),
                        CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: stopsPointer),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
            string.addAttribute(
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String),
                value: style,
                range: NSRange(location: offsets[paragraphStart], length: offsets[end] - offsets[paragraphStart])
            )
            paragraphStart = end
        }
        source = string
        typesetter = CTTypesetterCreateWithAttributedString(string)
        utf16Offsets = offsets
        scalarOffsets = Dictionary(uniqueKeysWithValues: offsets.enumerated().map { ($0.element, $0.offset) })
        alignments = styles.map { (offsets[Int($0.first)], $0.alignment) }
        codePoints = text
        self.paragraphs = paragraphs
    }

    /// The properties of the paragraph holding a scalar: its first character's.
    private func paragraph(at scalar: Int) -> Ubiquitty.RichText.Paragraph {
        var start = min(scalar, codePoints.count)
        while start > 0 && codePoints[start - 1] != 0x0A { start -= 1 }
        return paragraphs.last { $0.first <= start }?.paragraph ?? Ubiquitty.RichText.Paragraph()
    }

    private func startsParagraph(_ scalar: Int) -> Bool { scalar == 0 || codePoints[scalar - 1] == 0x0A }

    /// A shaped line `[first, end)`, in scalars, created at its indent so its
    /// tabs stop on the box's grid.
    package func line(first: Int, end: Int) -> CTLine {
        var place = Ubiquitty.RichText.LinePlace()
        place.startsParagraph = startsParagraph(first)
        let indent = Self.points(Ubiquitty.RichText.lineIndent(paragraph(at: first), place))
        return CTTypesetterCreateLineWithOffset(
            typesetter,
            CFRange(location: utf16Offsets[first], length: utf16Offsets[end] - utf16Offsets[first]),
            indent
        )
    }

    private static func points(_ units: UInt32) -> Double { Double(units) / 4096 }

    /// One past the U+000A that ends the paragraph holding `scalar`, or the
    /// text's end, as `RichText::paragraphEnd` answers it.
    private static func paragraphEnd(_ text: [UInt32], _ scalar: Int) -> Int {
        var index = scalar
        while index < text.count && text[index] != 0x0A { index += 1 }
        return min(index + 1, text.count)
    }

    /// Shapes whole runs and publishes logical grapheme ranges with visual
    /// carets. Right-to-left runs reverse the visual caret order.
    package func shape(
        _ request: Ubiquitty.RichText.ShapeRequest,
        facts: Ubiquitty.RichText.TypographyFacts,
        into result: inout Ubiquitty.RichText.ShapedText
    ) -> Bool {
        let text = source.string as NSString
        // The content box: the rectangle less its padding. Positions are the
        // box's; Core moves them inside the padding.
        let horizontalPadding = Double(request.padding.left) + Double(request.padding.right)
        let width = max(0, Double(request.width) * Double(facts.cellWidth) / 64 - horizontalPadding)
        guard let blockWidth = Self.units(width) else { return false }
        var first = 0
        var top: UInt32 = 0
        var row: UInt32 = 0
        while first < text.length {
            guard let scalarFirst = scalarOffsets[first] else { return false }
            let properties = paragraph(at: scalarFirst)
            var place = Ubiquitty.RichText.LinePlace()
            place.startsParagraph = startsParagraph(scalarFirst)
            let indent = Self.points(Ubiquitty.RichText.lineIndent(properties, place))
            let lineWidth = Self.points(Ubiquitty.RichText.lineWidth(properties, place, blockWidth))
            let count: Int
            if request.overflow == .Clip {
                let breaks = CharacterSet(charactersIn: "\n\u{2028}")
                let newline = text.rangeOfCharacter(from: breaks, range: NSRange(location: first, length: text.length - first))
                count = newline.location == NSNotFound ? text.length - first : newline.location + 1 - first
            } else {
                let suggested = CTTypesetterSuggestLineBreakWithOffset(typesetter, first, lineWidth, indent)
                count = suggested > 0 ? suggested : text.rangeOfComposedCharacterSequence(at: first).length
            }
            let end = first + count
            guard let scalarEnd = scalarOffsets[end] else { return false }
            place.endsParagraph = scalarEnd >= codePoints.count || codePoints[scalarEnd - 1] == 0x0A
            let line = CTTypesetterCreateLineWithOffset(typesetter, CFRange(location: first, length: count), indent)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let naturalHeight = request.lineMode == .Terminal ? Double(facts.cellHeight) / 64 : Double(ascent + descent + leading)
            let naturalBaseline = request.lineMode == .Terminal ? Double(facts.baseline) / 64 : Double(ascent)
            guard let measuredHeight = Self.units(naturalHeight),
                let measuredBaseline = Self.units(min(naturalHeight, naturalBaseline))
            else { return false }
            let box = Ubiquitty.RichText.lineBox(
                properties,
                measuredHeight,
                measuredBaseline,
                place,
                request.lineMode
            )
            let specified = alignments.last { $0.0 <= first }?.1 ?? .Unspecified
            let alignment = specified == .Unspecified ? request.alignment : specified
            let flush = alignment == .Center ? 0.5 : alignment == .Right ? 1.0 : 0.0
            let origin = indent + max(0, CTLineGetPenOffsetForFlush(line, flush, lineWidth))
            guard let originUnits = Self.units(origin),
                let widthUnits = Self.units(max(0, advance - CTLineGetTrailingWhitespaceWidth(line))),
                box.height < UInt32(Int32.max) - top,
                widthUnits < UInt32(Int32.max) - originUnits
            else { return false }
            var shapedLine = Ubiquitty.RichText.ShapedLine()
            shapedLine.first = UInt32(scalarFirst)
            shapedLine.end = UInt32(scalarEnd)
            shapedLine.top = top
            shapedLine.height = box.height
            shapedLine.baseline = box.baseline
            shapedLine.origin = originUnits
            shapedLine.width = widthUnits
            result.appendLine(shapedLine)
            var leadingCarets: [Int: Double] = [:]
            var trailingCarets: [Int: Double] = [:]
            CTLineEnumerateCaretOffsets(line) { position, index, isLeading, _ in
                if isLeading { leadingCarets[index] = position } else { trailingCarets[index] = position }
            }
            var whitespaceFirst = scalarEnd
            while whitespaceFirst > scalarFirst && Unicode.Scalar(codePoints[whitespaceFirst - 1])!.properties.isWhitespace {
                whitespaceFirst -= 1
            }
            var position = first
            while position < end {
                let range = text.rangeOfComposedCharacterSequence(at: position)
                let next = min(end, range.location + range.length)
                guard let startScalar = scalarOffsets[position], let endScalar = scalarOffsets[next] else { return false }
                let left = leadingCarets[position] ?? Double(CTLineGetOffsetForStringIndex(line, position, nil))
                let right =
                    (position..<next).reversed().compactMap { trailingCarets[$0] }.first
                    ?? Double(CTLineGetOffsetForStringIndex(line, next, nil))
                var span = Ubiquitty.RichText.ShapedSpan()
                span.first = UInt32(startScalar)
                span.end = UInt32(endScalar)
                span.line = row
                var leadingPosition = origin + left
                var trailingPosition = origin + right
                guard leadingPosition.isFinite, trailingPosition.isFinite else { return false }
                // CoreText hangs RTL trailing whitespace left of the line.
                // Keep its source span, clipping only the part outside the
                // content box; Core's caret coordinates are nonnegative.
                if startScalar >= whitespaceFirst {
                    leadingPosition = max(0, leadingPosition)
                    trailingPosition = max(0, trailingPosition)
                }
                guard let leading = Self.units(leadingPosition), let trailing = Self.units(trailingPosition) else { return false }
                span.leading = Int32(leading)
                span.trailing = Int32(trailing)
                result.appendSpan(span)
                position = next
            }
            top += shapedLine.height
            row += 1
            first = end
        }
        return true
    }

    private static func units(_ value: Double) -> UInt32? { RichTextGeometry.units(value) }
}

/// Immutable font handles may be used by the parser's worker under its model
/// lock. No view, GPU resource or main-thread hop participates in shaping.
package final class RichTextShaper: @unchecked Sendable {
    private let faces: RichTextFaces

    package init(faces: RichTextFaces) { self.faces = faces }

    package func queryFonts(
        _ query: Ubiquitty.RichText.FontCatalogQuery,
        into result: inout Ubiquitty.RichText.FontCatalogPage
    ) -> Bool {
        guard let catalog = faces.catalog else {
            result.status = .Stale
            result.scope = .System
            result.offset = query.offset
            result.rendererRevision = query.rendererRevision
            return true
        }
        let families = faces.familyNames(in: catalog)
        result.scope = .System
        result.offset = query.offset
        result.rendererRevision = query.rendererRevision
        guard Int(query.offset) <= families.count else {
            result.status = .Invalid
            return true
        }
        result.status = .Ready
        result.total = UInt32(families.count)
        let start = Int(query.offset)
        let end = min(start + Int(query.count), families.count)
        for family in families[start..<end] where !result.appendFamily(std.string(family)) {
            break
        }
        return true
    }

    package func shape(
        _ document: Ubiquitty.RichText.Document,
        request: Ubiquitty.RichText.ShapeRequest,
        facts: Ubiquitty.RichText.TypographyFacts,
        into result: inout Ubiquitty.RichText.ShapedText
    ) -> Bool {
        var styles: [Ubiquitty.RichText.DrawnStyle] = []
        let runCount = Int(document.runCount())
        styles.reserveCapacity(runCount)
        for index in 0..<runCount {
            let run = document.runAt(index)
            var style = Ubiquitty.RichText.DrawnStyle()
            style.alignment = run.alignment
            style.paragraph = run.paragraph
            style.first = run.start
            style.end = run.start + run.length
            if run.font != Ubiquitty.RichText.noFontEntry { style.setFont(document.fontAt(UInt32(run.font))) }
            let size = facts.terminalSize(style.familyClass)
            style.halfPoints = Float(run.halfPoints) * (request.lineMode == .Terminal && size > 0 ? Float(size) / 768 : 1)
            style.styles = run.styles
            if run.color != 0 {
                let color = document.colors[Int(run.color)]
                style.isAutomaticColor = 0
                style.red = color.red
                style.green = color.green
                style.blue = color.blue
            }
            styles.append(style)
        }
        let text = (0..<Int(document.codePointCount())).map { document.codePointAt($0) }
        return RichTextTypesetter(
            text: text,
            styles: styles,
            faces: faces,
            automaticColor: CGColor(gray: 1, alpha: 1),
            tabWidth: CGFloat(facts.cellWidth) / 8
        )
        .shape(request, facts: facts, into: &result)
    }
}
