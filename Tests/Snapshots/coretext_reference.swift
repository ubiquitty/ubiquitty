// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// coretext_reference.swift — draws a page of proportional text the way
// CoreText draws it, for coretext_parity.py to hold the renderer to.
//
// Each line is one CTLineDraw of the system UI face at the point size, scaled
// by the backing scale through the font matrix (the face the renderer's
// proportional runs are set in), at the pen the renderer uses: the cell's
// left edge and the row's baseline. Every CoreGraphics text setting is the
// context's default, which is what an AppKit text view draws with, and what
// the renderer's atlas is measured against.
//
//   coretext_reference <out.png> <width> <height> <scale> <pointSize>
//       <cellWidthPx> <cellHeightPx> <originXPx> <originYPx> <baselineFromTopPx>
//       <fg #rrggbb> <bg #rrggbb> <lines.txt>

import AppKit
import CoreText
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 14 else {
    FileHandle.standardError.write(
        "usage: coretext_reference <out.png> <width> <height> <scale> <pointSize> <cellWidthPx> <cellHeightPx> <originXPx> <originYPx> <baselineFromTopPx> <fg> <bg> <lines.txt>\n"
            .data(using: .utf8)!
    )
    exit(2)
}
let outputPath = arguments[1]
let width = Int(arguments[2])!
let height = Int(arguments[3])!
let scale = Double(arguments[4])!
let pointSize = Double(arguments[5])!
let cellWidth = Double(arguments[6])!
let cellHeight = Double(arguments[7])!
let originX = Double(arguments[8])!
let originY = Double(arguments[9])!
let baselineFromTop = Double(arguments[10])!
func color(_ hex: String) -> CGColor {
    let value = UInt32(hex.dropFirst(), radix: 16)!
    return CGColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}
let foreground = color(arguments[11])
let background = color(arguments[12])
let lines = try! String(contentsOfFile: arguments[13], encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    .map(String.init)

let base = CTFontCreateUIFontForLanguage(.system, pointSize, nil)!
var matrix = CGAffineTransform(scaleX: scale, y: scale)
let traits: [CFString: Any] = [kCTFontWeightTrait: 0.0]
let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
let font = CTFontCreateCopyWithAttributes(base, pointSize, &matrix, descriptor)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
context.setFillColor(background)
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.setFillColor(foreground)
let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
]
for (row, text) in lines.enumerated() where !text.isEmpty {
    // The renderer's pen: the run's first cell's left edge, the row's
    // baseline; the context is bottom-up, so the row counts from the top.
    let baselineY = Double(height) - (originY + Double(row) * cellHeight + baselineFromTop)
    context.textPosition = CGPoint(x: originX, y: baselineY)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    CTLineDraw(line, context)
}
let image = context.makeImage()!
let representation = NSBitmapImageRep(cgImage: image)
let png = representation.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outputPath))
