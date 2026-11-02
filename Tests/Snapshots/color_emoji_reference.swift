// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Independent CoreText raster for the colour-emoji pixel comparison.
// Usage: color_emoji_reference <side-in-pixels> <output.png>

import CoreGraphics
import CoreText
import Foundation
import ImageIO

let side = Int(CommandLine.arguments[1])!
let output = CommandLine.arguments[2]
let context = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: side * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
)!
context.setShouldAntialias(true)
context.setShouldSmoothFonts(true)
let font = CTFontCreateWithName("Apple Color Emoji" as CFString, CGFloat(side) * 0.92, nil)
let text = NSAttributedString(string: "😀", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
let line = CTLineCreateWithAttributedString(text)
let run = (CTLineGetGlyphRuns(line) as! [CTRun])[0]
var glyph = CGGlyph(0)
CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
let resolvedFont = (CTRunGetAttributes(run) as! [CFString: Any])[kCTFontAttributeName] as! CTFont

var bounds = CGRect.zero
CTFontGetBoundingRectsForGlyphs(resolvedFont, .horizontal, &glyph, &bounds, 1)
var position = CGPoint(
    x: ((CGFloat(side) - bounds.width) / 2 - bounds.minX).rounded(),
    y: ((CGFloat(side) - bounds.height) / 2 - bounds.minY).rounded()
)
CTFontDrawGlyphs(resolvedFont, &glyph, &position, 1, context)
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
