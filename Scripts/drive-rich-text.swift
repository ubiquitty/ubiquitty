// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CoreText
import Foundation
import Metal
import UbiquittyCore

func checkRichTextFrames(device: MTLDevice, check: (String, Bool, String) -> Void) {
    guard let grid = FontFaces(family: "Menlo", size: 12, pixelsPerPoint: 1) else {
        check("rich text grid faces", false, "Menlo would not load")
        return
    }
    let faces = RichTextFaces(grid: grid, proportionalFamilyName: "")
    let builder = faces.typographyFacts(
        cellWidthInPoints: 8,
        cellHeightInPoints: 16,
        baselineInPoints: 12,
        proportionalSizeInPoints: 12,
        monospaceSizeInPoints: 12
    )
    let facts = builder.facts().pointee
    var request = Ubiquitty.RichText.ShapeRequest()
    request.width = 12
    request.height = 100
    request.lineMode = .Terminal
    let samples = [
        "I’m here. Let’s try office affinity AV.",
        "العربية لغة جميلة — hello עולם",
        "कर्म क्षि नमस्ते বাংলা ภาษาไทย",
        "日本語の文章、中文标点。한글 문장입니다.",
        "e\u{301} 👩🏽‍💻 👨‍👩‍👧 ffi\nSecond line",
    ]
    for sample in samples {
        let scalars = sample.unicodeScalars.map(\.value)
        var style = Ubiquitty.RichText.DrawnStyle()
        style.end = UInt32(scalars.count)
        style.halfPoints = 24
        let typesetter = RichTextTypesetter(text: scalars, styles: [style], faces: faces, automaticColor: CGColor(gray: 1, alpha: 1))
        var shaped = Ubiquitty.RichText.ShapedText()
        check("native shaping \(sample)", typesetter.shape(request, facts: facts, into: &shaped), "")
        let lines = Array(shaped.lines)
        let spans = Array(shaped.spans)
        check("complete logical coverage", spans.first?.first == 0 && spans.last?.end == UInt32(scalars.count), sample)
        check("terminal baselines", lines.allSatisfy { $0.height == 16 * 4096 && $0.baseline == 12 * 4096 }, sample)
        check("wrap uses shaped widths", lines.count > 1 && lines.allSatisfy { $0.width <= 96 * 4096 }, sample)
        for line in lines {
            let native = typesetter.line(first: Int(line.first), end: Int(line.end))
            let width = CTLineGetTypographicBounds(native, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(native)
            check("render and measured line agree", abs(width - Double(line.width) / 4096) < 0.001, sample)
        }
        if sample.contains("العربية") {
            check("RTL caret order", spans.contains { $0.leading > $0.trailing }, sample)
        }
        if sample.contains("कर्म") || sample.contains("👩") {
            check("grapheme selection is indivisible", spans.contains { $0.end - $0.first > 1 }, sample)
        }
    }
    for sample in ["שלום עולם  \nשלום עולם  ", "العربية لغة جميلة  \nالعربية لغة جميلة  "] {
        let scalars = sample.unicodeScalars.map(\.value)
        var style = Ubiquitty.RichText.DrawnStyle()
        style.end = UInt32(scalars.count)
        style.halfPoints = 24
        let typesetter = RichTextTypesetter(text: scalars, styles: [style], faces: faces, automaticColor: CGColor(gray: 1, alpha: 1))
        for alignment in [Ubiquitty.RichText.Alignment.Left, .Center, .Right] {
            var alignedRequest = request
            alignedRequest.alignment = alignment
            var shaped = Ubiquitty.RichText.ShapedText()
            let detail = "\(sample) alignment=\(alignment)"
            check("RTL trailing whitespace shapes", typesetter.shape(alignedRequest, facts: facts, into: &shaped), detail)
            let spans = Array(shaped.spans)
            check(
                "RTL trailing whitespace keeps every source scalar",
                spans.first?.first == 0 && spans.last?.end == UInt32(scalars.count)
                    && zip(spans, spans.dropFirst()).allSatisfy { $0.end == $1.first },
                detail
            )
            for line in shaped.lines {
                let native = typesetter.line(first: Int(line.first), end: Int(line.end))
                let origin = Double(line.origin) / 4096
                for span in spans where span.first >= line.first && span.end <= line.end {
                    let leading = origin + CTLineGetOffsetForStringIndex(native, typesetter.utf16Offsets[Int(span.first)], nil)
                    let trailing = origin + CTLineGetOffsetForStringIndex(native, typesetter.utf16Offsets[Int(span.end)], nil)
                    check(
                        "RTL carets agree with native offsets inside the block",
                        abs(Double(span.leading) / 4096 - max(0, leading)) < 0.001
                            && abs(Double(span.trailing) / 4096 - max(0, trailing)) < 0.001,
                        "\(detail) scalar=\(span.first)"
                    )
                }
            }
        }
    }
    // A ligature must be shaped as one glyph while retaining insertion edges
    // for the source letters. A per-character rasterizer cannot pass this.
    var style = Ubiquitty.RichText.DrawnStyle()
    style.end = 6
    style.familyClass = .SansSerif
    style.halfPoints = 32
    let ligature = RichTextTypesetter(
        text: "office".unicodeScalars.map(\.value),
        styles: [style],
        faces: RichTextFaces(grid: grid, proportionalFamilyName: "Hoefler Text"),
        automaticColor: CGColor(gray: 1, alpha: 1)
    )
    check("Latin ligatures survive", CTLineGetGlyphCount(ligature.line(first: 0, end: 6)) < 6, "office")

    let shaper = RichTextShaper(faces: faces)
    var rtlFixture = FrameEncoderFixture(12)
    rtlFixture.installRichText(
        facts,
        { context, document, request, facts, output in
            guard let context, let document, let request, let facts, let output else { return false }
            return Unmanaged<RichTextShaper>.fromOpaque(context).takeUnretainedValue()
                .shape(document.pointee, request: request.pointee, facts: facts.pointee, into: &output.pointee)
        },
        Unmanaged.passUnretained(shaper).toOpaque()
    )
    let rtlSample = "العربية لغة جميلة — hello עולם"
    let rtlBlock = "\u{1B}[?1049h\u{1B}]7404;w=12:h=4:g=1:C=1:i=1;{\\rtf1\\fs24 \(rtlSample)}\u{1B}\\"
    rtlBlock.withCString { Ubiquitty.processBytes(rtlFixture.terminal(), std.string_view($0)) }
    if let capture = Ubiquitty.Rendering.FrameCapture.make(), rtlFixture.captureRichText(capture, 1), !capture.richTextQuads().isEmpty {
        let lines = Array(capture.richTextShapedLines(0))
        check("Core accepts complete RTL native geometry", lines.count > 1 && lines.last?.end == UInt32(rtlSample.unicodeScalars.count), "")
    } else {
        check("RTL native capture", false, "")
    }
    for scale: Float in [1, 1.25, 2] {
        var fixture = FrameEncoderFixture(40)
        fixture.installRichText(
            facts,
            { context, document, request, facts, output in
                guard let context, let document, let request, let facts, let output else { return false }
                return Unmanaged<RichTextShaper>.fromOpaque(context).takeUnretainedValue()
                    .shape(
                        document.pointee,
                        request: request.pointee,
                        facts: facts.pointee,
                        into: &output.pointee
                    )
            },
            Unmanaged.passUnretained(shaper).toOpaque()
        )
        let text =
            "\u{1B}[?1049h\u{1B}]7404;w=40:h=1:g=1:M=1:i=1:D=1;{\\rtf1{\\colortbl;\\red255\\green255\\blue255;\\red0\\green100\\blue200;}\\fs24\\cf1\\highlight2 iiiiiiiii office I’m Let’s}\u{1B}\\"
        text.withCString { Ubiquitty.processBytes(fixture.terminal(), std.string_view($0)) }
        guard let capture = Ubiquitty.Rendering.FrameCapture.make(), fixture.captureRichText(capture, scale) else {
            check("rich text capture", false, "scale=\(scale)")
            continue
        }
        let store = RichTextStore(device: device, faces: faces)
        guard let layer = store.layer(for: capture), let texture = layer.textures.last ?? nil,
            let buffer = layer.buffer
        else {
            check("rich text layer", false, "scale=\(scale)")
            continue
        }
        check("native line reaches drawing", capture.richTextShapedLines(0).count == 1, "scale=\(scale)")
        let quads = buffer.contents().assumingMemoryBound(to: Ubiquitty.Rendering.ImageInstance.self)
        for index in 0..<(layer.quadCount - 1) {
            let edges = [
                quads[index].topLeftInPixels.x, quads[index].topLeftInPixels.y,
                quads[index].bottomRightInPixels.x, quads[index].bottomRightInPixels.y,
            ]
            check("native selection edges are device pixels", edges.allSatisfy { $0 == $0.rounded() }, "scale=\(scale)")
        }
        var pixels = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!,
                bytesPerRow: texture.width * 8,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        let clusters = Array(capture.richTextClusters(0))
        let right = clusters.map { Float($0.x + $0.advance) / 4096 * scale }.max() ?? 0
        var background = [Float16](repeating: 0, count: pixels.count)
        if let backgroundTexture = layer.textures.first ?? nil {
            background.withUnsafeMutableBytes {
                backgroundTexture.getBytes(
                    $0.baseAddress!,
                    bytesPerRow: texture.width * 8,
                    from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                    mipmapLevel: 0
                )
            }
        }
        let covered = (0..<Int(right.rounded())).allSatisfy { background[$0 * 4 + 3] == 1 }
        check("RTF selection has no fractional seams", covered, "scale=\(scale) right=\(right)")
        check("RTF backgrounds are below native selection", layer.quadCount == capture.richTextHighlights().count + 2, "")
        check("rich-only selection retains its colour", capture.richTextHighlights().isEmpty || capture.selectionColor().w > 0, "")
        check("rich text raster contains glyphs", stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] > 0.1 }, "scale=\(scale)")
        let unchanged = RichTextPresentation(capture)
        let initialRasters = store.rasterCount
        _ = store.layer(for: capture)
        check("unchanged blocks keep their raster", store.rasterCount == initialRasters, "scale=\(scale)")
        let started = CFAbsoluteTimeGetCurrent()
        for length in 1...40 {
            let edit = "\u{1B}[3;1H\u{1B}]7404;w=40:h=1:g=1:P=1:C=1:i=2;{\\rtf1 \(String(repeating: "i", count: length))}\u{1B}\\"
            edit.withCString { Ubiquitty.processBytes(fixture.terminal(), std.string_view($0)) }
            check("editor frame capture", fixture.captureRichText(capture, scale), "")
            check("text changes invalidate presentation", RichTextPresentation(capture) != unchanged, "")
            _ = store.layer(for: capture)
            check("typing rasterizes only the edited block", store.rasterCount == initialRasters + length, "scale=\(scale)")
        }
        print("  rich-text editor: 40 updates in \((CFAbsoluteTimeGetCurrent() - started) * 1000) ms at scale=\(scale)")
        let beforeDelete = RichTextPresentation(capture)
        "\u{1B}]7404;a=d\u{1B}\\".withCString { Ubiquitty.processBytes(fixture.terminal(), std.string_view($0)) }
        check("empty block capture", fixture.captureRichText(capture, scale), "")
        check("deleting blocks invalidates presentation", RichTextPresentation(capture) != beforeDelete, "")
        check("deleted blocks leave no layer", store.layer(for: capture) == nil, "")
        let clipped = "\u{1B}[1;1H\u{1B}]7404;w=40:h=1:g=1:i=3:r=0,0,5,1,12,0,8,1;{\\rtf1 office affinity العربية}\u{1B}\\"
        clipped.withCString { Ubiquitty.processBytes(fixture.terminal(), std.string_view($0)) }
        check("clipped block capture", fixture.captureRichText(capture, scale), "")
        let beforeClip = store.rasterCount
        if let layer = store.layer(for: capture), let buffer = layer.buffer {
            check(
                "one texture for disjoint clips",
                layer.quadCount == capture.richTextHighlights().count + 2 && store.rasterCount == beforeClip + 1,
                "scale=\(scale)"
            )
            let quads = buffer.contents().assumingMemoryBound(to: Ubiquitty.Rendering.ImageInstance.self)
                .advanced(by: capture.richTextHighlights().count)
            check(
                "clips preserve paragraph coordinates",
                quads[0].bottomRightInPixels.x == (40 * scale).rounded() && quads[1].topLeftInPixels.x == (96 * scale).rounded(),
                ""
            )
            check(
                "clip edges share pixel grid",
                (0..<2)
                    .allSatisfy {
                        quads[$0].topLeftInPixels.x == quads[$0].topLeftInPixels.x.rounded()
                            && quads[$0].bottomRightInPixels.x == quads[$0].bottomRightInPixels.x.rounded()
                    },
                ""
            )
            _ = store.layer(for: capture)
            check("clipped idle frame reuses raster", store.rasterCount == beforeClip + 1, "")
        } else {
            check("clipped block layer", false, "")
        }
    }
    var mixedFacts = facts
    mixedFacts.proportionalSize = 20 * 64
    var mixedFixture = FrameEncoderFixture(40)
    mixedFixture.installRichText(
        mixedFacts,
        { context, document, request, facts, output in
            guard let context, let document, let request, let facts, let output else { return false }
            return Unmanaged<RichTextShaper>.fromOpaque(context).takeUnretainedValue()
                .shape(document.pointee, request: request.pointee, facts: facts.pointee, into: &output.pointee)
        },
        Unmanaged.passUnretained(shaper).toOpaque()
    )
    let mixed = "\u{1B}]7404;w=40:h=2:g=1:i=1;{\\rtf1{\\fonttbl{\\f0\\fswiss ;}{\\f1\\fmodern ;}}\\fs24\\f0 Read {\\f1 MMMM}}\u{1B}\\"
    mixed.withCString { Ubiquitty.processBytes(mixedFixture.terminal(), std.string_view($0)) }
    if let capture = Ubiquitty.Rendering.FrameCapture.make(), mixedFixture.captureRichText(capture, 1) {
        let styles = Array(capture.richTextStyles(0))
        check("prose uses its configured size", styles.first?.halfPoints == 40, "")
        check("inline monospace uses the grid size", styles.last?.halfPoints == 24, "")
        let clusters = Array(capture.richTextClusters(0)).filter { $0.first >= 5 }
        let mono = NSAttributedString(string: "MMMM", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): faces.grid])
        let expected = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(mono), nil, nil, nil)
        let measured = Double(clusters.reduce(UInt32(0)) { $0 + $1.advance }) / 4096
        check("inline monospace measures like the actual grid face", abs(measured - expected) < 0.01, "\(measured) != \(expected)")
        let store = RichTextStore(device: device, faces: faces)
        check("mixed sizes rasterize", store.layer(for: capture) != nil, "")
    } else {
        check("mixed size capture", false, "")
    }
    withExtendedLifetime(shaper) {}
}
