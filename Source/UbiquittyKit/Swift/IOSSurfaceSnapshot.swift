// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(UIKit)

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// Renders the shared terminal surface offscreen on a UIKit system.
///
/// The iOS snapshot launcher calls this entry from the simulator application,
/// so font resolution, CoreText rasterisation, Metal shaders, and the surface
/// frame are the same components the shipping view uses.
public enum IOSSurfaceSnapshot {
    /// What the macOS snapshot driver does to the terminal after the feed, so
    /// a case reaches the same state on this arm.
    public struct Actions {
        /// Clears back to the last prompt mark (Cmd-L).
        public var shouldClearToMark = false
        /// Clears the buffer and keeps the input line (Cmd-K).
        public var shouldClearPreservingInput = false
        /// A character selection over visible cells: row0, column0, row1, column1.
        public var selection: (Int32, Int32, Int32, Int32)?
        /// Rows to scroll the viewport up by.
        public var viewOffset: Int?
        /// A case-sensitive literal to search the scrollback for.
        public var searchLiteral: String?

        public init() {}
    }

    /// Renders one terminal frame as PNG data.
    ///
    /// - Parameters:
    ///   - rows: The grid height.
    ///   - columns: The grid width.
    ///   - feed: The bytes to parse before drawing.
    ///   - contentScale: Device pixels per point.
    ///   - drawsSizedText: Whether OSC 66 text sizing is enabled.
    ///   - isFocused: Whether the surface draws as the focused pane.
    ///   - actions: The post-feed actions.
    /// - Returns: PNG data, or nil when a required resource or render stage
    ///   refuses the frame.
    @MainActor
    public static func renderPNG(
        rows: Int,
        columns: Int,
        feed: Data,
        contentScale: Double = 2.0,
        drawsSizedText: Bool = false,
        isFocused: Bool = true,
        actions: Actions = Actions()
    ) -> Data? {
        guard rows > 0, rows <= Int(Ubiquitty.maxRows),
            columns > 0, columns <= Int(Ubiquitty.maxColumns),
            contentScale.isFinite, contentScale > 0,
            let device = MTLCreateSystemDefaultDevice()
        else {
            return nil
        }
        // The renderer every iOS pane is built with, from Core's fold of the
        // case's document: the font, the typography, the padding per edge and
        // the frame style all come with it, so a golden shows what a pane shows.
        guard let surface = TerminalSurface(rows: rows, columns: columns),
            let renderer = TerminalSurface.makeRenderer(
                device: device,
                configuration: Ubiquitty.Preferences.Effective.liveRenderConfiguration(),
                systemTransparency: .Allowed
            ) as? SurfaceRenderer
        else {
            return nil
        }
        surface.renderer = renderer
        surface.setSurfaceFocused(isFocused)
        // The terminal seeded from the case's document through the same seed
        // the macOS snapshot calls: the `[cursor]` block, the clipboard and
        // sequence policy, the encodings and the rest a session would carry.
        // The configured theme only, as there; the theme block below refuses a
        // name that does not resolve.
        if let terminal = surface.drive.borrowTerminal() {
            _ = Ubiquitty.Runtime.seedTerminalConfiguration(
                terminal,
                Ubiquitty.Preferences.values().pointee,
                .ConfiguredOnly
            )
            surface.drive.republishSnapshot()
        }
        // The configured theme only. An empty name is the common case — no
        // `[appearance] theme` — and leaves the palette a fresh Terminal is
        // constructed with, the frame the coretext golden holds. A named
        // theme that does not resolve is refused, the way Core's seed refuses
        // it on every other arm, rather than drawn on the wrong palette.
        let themeName = Ubiquitty.Preferences.values().pointee.themeName.value.map { String($0) } ?? ""
        if !themeName.isEmpty {
            guard let themeIndex = TerminalSurface.themeNames.firstIndex(of: themeName),
                surface.applyTheme(at: themeIndex)
            else {
                return nil
            }
        }

        renderer.prepare(forDeviceScale: contentScale)
        let cell = renderer.cellSize(for: surface)
        let insets = renderer.gridFitInsets(for: surface)
        let widthInPoints = Double(columns) * cell.width + insets.left + insets.right
        let heightInPoints = Double(rows) * cell.height + insets.top + insets.bottom
        // Rounded to the nearest pixel, as the macOS snapshot sizes its
        // target: rounding a fractional advance up made this frame a pixel
        // wider than every other arm's, so no comparison could pass.
        let pixelWidth = (widthInPoints * contentScale).rounded()
        let pixelHeight = (heightInPoints * contentScale).rounded()
        let textureLimit = Double(device.maximumTexture2DDimension)
        guard pixelWidth.isFinite, pixelHeight.isFinite,
            pixelWidth >= 1, pixelHeight >= 1,
            pixelWidth <= textureLimit, pixelHeight <= textureLimit
        else {
            return nil
        }
        let widthInPixels = Int(pixelWidth)
        let heightInPixels = Int(pixelHeight)

        surface.metalLayer.contentsScale = contentScale
        surface.frame = CGRect(
            x: 0,
            y: 0,
            width: Double(widthInPixels) / contentScale,
            height: Double(heightInPixels) / contentScale
        )
        // UIKit defers layout, but pixel-sized image requests need the cell
        // metrics before the feed is parsed. Restore the requested grid after
        // publishing geometry so fractional cells cannot shrink its dimensions.
        surface.resizeGridToBounds()
        surface.drive.resize(rows: rows, columns: columns)
        // What a window declares at session start, so a golden shows what a
        // window shows: a case that prints OSC 66 renders sized only where the
        // driver was asked for it, as on every other arm.
        surface.drive.withTerminal {
            $0.drawsSizedText = drawsSizedText
            $0.drawsProportionalText = drawsSizedText
        }
        if !feed.isEmpty {
            let bytes = feed.map { CChar(bitPattern: $0) }
            surface.drive.feed(bytes.span)
        }
        // The macOS driver's post-feed actions, through the same Core calls
        // (SurfaceSnapshot.swift).
        if let terminal = surface.drive.borrowTerminal() {
            if actions.shouldClearToMark {
                _ = Ubiquitty.Screen.clearToMarkOrFull(terminal, nil)
            } else if actions.shouldClearPreservingInput {
                Ubiquitty.clearBufferPreserveInput(terminal)
            }
            if let selection = actions.selection {
                var bounds = Ubiquitty.SelectionBounds()
                bounds.row0 = selection.0
                bounds.column0 = selection.1
                bounds.row1 = selection.2
                bounds.column1 = selection.3
                surface.selectionModel.session.pointee.state = Ubiquitty.Selection.characterSelectionOverVisibleRows(terminal, bounds)
            }
        }
        if let viewOffset = actions.viewOffset { surface.viewOffset = viewOffset }
        if let search = actions.searchLiteral {
            // The search is the session's; the reveal it answers is where
            // the macOS find bar moves the viewport too.
            let outcome = surface.drive.searchScrollbackAndWait(search, form: .literal, sensitivity: .Sensitive)
            if outcome.revealViewOffset >= 0 { surface.viewOffset = Int(outcome.revealViewOffset) }
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: widthInPixels,
            height: heightInPixels,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
            renderer.renderStill(surface, into: texture, contentScale: contentScale)
        else {
            return nil
        }

        var pixels = Data(count: widthInPixels * heightInPixels * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!,
                bytesPerRow: widthInPixels * 4,
                from: MTLRegionMake2D(0, 0, widthInPixels, heightInPixels),
                mipmapLevel: 0
            )
        }
        return encodePNG(&pixels, width: widthInPixels, height: heightInPixels, straightAlpha: renderer.isBitmapTier)
    }

    /// Encodes top-down BGRA texture bytes as an sRGB PNG.
    ///
    /// - Parameters:
    ///   - pixels: The texture bytes; inout because CGContext draws through a
    ///     mutable view of them, though nothing here rewrites a byte.
    ///   - width: The image width in pixels.
    ///   - height: The image height in pixels.
    /// - Returns: PNG data, or nil when Core Graphics refuses the buffer.
    /// `straightAlpha`: the bitmap tier's frame stores straight colour with the
    /// CPU's alpha mix; declaring it premultiplied would have ImageIO divide by
    /// the alpha on export.
    private static func encodePNG(_ pixels: inout Data, width: Int, height: Int, straightAlpha: Bool) -> Data? {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        // An image over the bytes directly, not a bitmap context: a context
        // only holds premultiplied alpha, so it cannot describe the straight
        // bytes and refuses to be created, whereas an image takes either
        // declaration and ImageIO writes the samples as declared.
        let alpha: CGImageAlphaInfo = straightAlpha ? .first : .premultipliedFirst
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: pixels as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}

#endif
