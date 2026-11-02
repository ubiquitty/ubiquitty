// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(UIKit)

// TerminalSurface+Thumbnail.swift — a small picture of what a pane shows, for
// an overview of tabs that draws many panes at once.
//
// The picture is the pane's own frame: the renderer that draws the pane on
// the glass encodes the retained grid into an offscreen target, which is then
// scaled down. A card therefore shows the cells, colours, cursor and images
// the pane shows, and no card needs a Metal layer of its own.

import CoreGraphics
import Metal
import UIKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

extension TerminalSurface {
    /// Draws the pane as it stands into a picture at most `maxPixelWidth`
    /// wide, keeping its proportions.
    ///
    /// The frame is drawn at the scale the pane draws at on screen, so the
    /// glyph sheets it already holds serve it, and then scaled down. The
    /// pane's next frame on screen is drawn whole, because this one consumed
    /// the rows its capture owed.
    ///
    /// - Parameters:
    ///   - maxPixelWidth: The widest the picture may be, in pixels.
    ///   - contentScale: Device pixels per point; the screen's scale.
    /// - Returns: The picture, or nil when the pane has no grid or renderer
    ///   yet, or the device refuses the target.
    @MainActor
    public func thumbnail(maxPixelWidth: Int, contentScale: Double) -> CGImage? {
        let snapshot = drive.readSnapshot()
        guard maxPixelWidth > 0, contentScale.isFinite, contentScale > 0,
            snapshot.rows > 0, snapshot.columns > 0,
            let renderer = renderer as? SurfaceRenderer
        else {
            return nil
        }
        renderer.prepare(forDeviceScale: contentScale)
        let cell = renderer.cellSize(for: self)
        let insets = renderer.gridFitInsets(for: self)
        let width = (Double(snapshot.columns) * cell.width + insets.left + insets.right) * contentScale
        let height = (Double(snapshot.rows) * cell.height + insets.top + insets.bottom) * contentScale
        let limit = Double(renderer.device.maximumTexture2DDimension)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1, width <= limit, height <= limit else {
            return nil
        }
        let pixelWidth = Int(width.rounded())
        let pixelHeight = Int(height.rounded())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor),
            renderer.renderDetached(self, into: texture, contentScale: contentScale)
        else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(
                base,
                bytesPerRow: pixelWidth * 4,
                from: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight),
                mipmapLevel: 0
            )
        }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let full = CGImage(
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: pixelWidth * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            return nil
        }
        guard pixelWidth > maxPixelWidth else { return full }
        let scaledWidth = maxPixelWidth
        let scaledHeight = max(1, Int((Double(pixelHeight) * Double(maxPixelWidth) / Double(pixelWidth)).rounded()))
        guard
            let context = CGContext(
                data: nil,
                width: scaledWidth,
                height: scaledHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        else {
            return full
        }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
        return context.makeImage() ?? full
    }
}

#endif
