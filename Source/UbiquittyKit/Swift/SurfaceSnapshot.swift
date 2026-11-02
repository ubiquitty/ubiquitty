// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(AppKit)
import AppKit
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers
internal import CxxStdlib
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// Runs the native snapshot command through the application's surface renderer.
@MainActor
enum SurfaceSnapshotEntry {
    /// Renders the requested frame, and any `--also-feed` frames after it, to
    /// their PNG paths.
    ///
    /// - Parameters:
    ///   - arguments: The snapshot's arguments, already normalised.
    ///   - settings: The configuration the snapshot renders from.
    /// - Returns: Whether every frame was written.
    static func render(_ arguments: Ubiquitty.Diagnostics.SnapshotArguments, configuration settings: Ubiquitty.Preferences.Values) -> Bool {
        let output = String(arguments.outPath)
        guard arguments.alsoFeeds.size() == arguments.alsoSnapshots.size(),
            !output.isEmpty,
            let capture = SurfaceSnapshot(
                rows: Int(arguments.rows),
                columns: Int(arguments.columns),
                contentScale: arguments.scale,
                configuration: settings,
                paddingX: arguments.havePaddingX ? arguments.paddingX : nil,
                paddingY: arguments.havePaddingY ? arguments.paddingY : nil
            )
        else { return false }
        let surface = capture.surface
        capture.renderer.shouldUseSubpixelGlyphs = !arguments.disableSubpixelText
        surface.setSurfaceFocused(!arguments.isUnfocused)
        if let terminal = surface.drive.borrowTerminal() {
            // One flag declares both OSC 66 facts: this renderer draws sized
            // blocks and proportional runs alike.
            terminal.drawsSizedText = arguments.drawsSizedText
            terminal.drawsProportionalText = arguments.drawsSizedText
            if arguments.haveBeamColor {
                terminal.palette.defaultForeground = Self.color(arguments.beamColor)
            }
            if arguments.haveBackgroundColor {
                terminal.palette.defaultBackground = Self.color(arguments.backgroundColor)
            }
            Ubiquitty.Themes.rethemeDefaults(terminal)
        }
        if arguments.reflowFromColumns > 0 {
            surface.drive.resize(rows: Int(arguments.rows), columns: Int(arguments.reflowFromColumns))
        }
        capture.feed(arguments.feed)
        if arguments.reflowFromColumns > 0 {
            surface.drive.resize(rows: Int(arguments.rows), columns: Int(arguments.columns))
        }
        capture.reportReplies()
        if let terminal = surface.drive.borrowTerminal() {
            if arguments.shouldClearToMark {
                _ = Ubiquitty.Screen.clearToMarkOrFull(terminal, nil)
            } else if arguments.shouldClearPreservingInput {
                Ubiquitty.clearBufferPreserveInput(terminal)
            }
            if arguments.haveSelectRect {
                var bounds = Ubiquitty.SelectionBounds()
                bounds.row0 = arguments.selectRow0
                bounds.column0 = arguments.selectColumn0
                bounds.row1 = arguments.selectRow1
                bounds.column1 = arguments.selectColumn1
                surface.selectionModel.session.pointee.state = Ubiquitty.Selection.characterSelectionOverVisibleRows(terminal, bounds)
            }
            if arguments.haveSelectPoints {
                Ubiquitty.Selection.selectBetweenPoints(
                    &surface.selectionModel.session.pointee,
                    terminal,
                    arguments.selectPointX0,
                    arguments.selectPointY0,
                    arguments.selectPointX1,
                    arguments.selectPointY1
                )
            }
        }
        if arguments.haveViewOffset { surface.viewOffset = Int(arguments.viewOffset) }
        if !arguments.searchLiteral.empty() {
            _ = surface.searchScrollbackAndWait(String(arguments.searchLiteral), isRegex: false, isCaseSensitive: true)
        }
        if arguments.haveHoverRect {
            let history = Int32(surface.drive.readSnapshot().scrollbackCount)
            surface.hoveredLinkRun = RuntimeDrive.ResolvedLink(
                uri: "",
                isHyperlink: arguments.hoverLinkIdentifier != 0,
                isFilePath: false,
                rowFirst: history + arguments.hoverRow0,
                rowLast: history + arguments.hoverRow1,
                columnFirst: arguments.hoverColumn0,
                columnLast: arguments.hoverColumn1,
                spanColumnFirst: 0,
                spanColumnLast: -1,
                textDigest: 0,
                linkID: UInt16(clamping: arguments.hoverLinkIdentifier)
            )
        }
        let requestedFont = capture.renderer.familyName
        if capture.renderer.isBitmapTier {
            print("snapshot: font \"\(requestedFont)\" resolved (embedded rasterizer)")
        } else {
            let resolvedFont = capture.renderer.resolvedFontFamily
            if requestedFont == resolvedFont {
                print("snapshot: font \"\(requestedFont)\" resolved")
            } else {
                print("snapshot: font \"\(requestedFont)\" -> FALLBACK \"\(resolvedFont)\"")
            }
        }
        if arguments.shouldPrintMetrics {
            let cell = capture.renderer.cellSize(for: surface)
            let style = capture.renderer.style
            print(
                String(
                    format:
                        "metrics scale=%g cellWidthPoints=%.6f cellHeightPoints=%.6f paddingLeftPoints=%.6f paddingTopPoints=%.6f baselineFromTopPoints=%.6f",
                    arguments.scale,
                    cell.width,
                    cell.height,
                    style.paddingLeftPoints,
                    style.paddingTopPoints,
                    capture.renderer.baselineFromTopInPoints
                )
            )
        }
        guard capture.writePNG(to: output) else { return false }
        for index in 0..<Int(arguments.alsoFeeds.size()) {
            capture.feed(arguments.alsoFeeds[index])
            capture.reportReplies()
            guard capture.writePNG(to: String(arguments.alsoSnapshots[index])) else { return false }
        }
        return true
    }

    private static func color(_ rgb: UInt32) -> Ubiquitty.PaletteRGB {
        Ubiquitty.PaletteRGB(
            red: Ubiquitty.channel8To16(UInt8((rgb >> 16) & 255)),
            green: Ubiquitty.channel8To16(UInt8((rgb >> 8) & 255)),
            blue: Ubiquitty.channel8To16(UInt8(rgb & 255))
        )
    }
}

/// Owns the surface, atlas, and retained grid across an offscreen frame sequence.
@MainActor
final class SurfaceSnapshot {
    let surface: TerminalSurface
    let renderer: SurfaceRenderer
    let texture: any MTLTexture
    let contentScale: Double
    private let queue: any MTLCommandQueue

    init?(
        rows: Int,
        columns: Int,
        contentScale: Double,
        configuration: Ubiquitty.Preferences.Values,
        paddingX: Double? = nil,
        paddingY: Double? = nil
    ) {
        guard rows > 0, rows <= Int(Ubiquitty.maxRows), columns > 0, columns <= Int(Ubiquitty.maxColumns),
            contentScale.isFinite, contentScale > 0,
            let device = SystemMetalDevice.resolve(), let queue = device.makeCommandQueue(),
            let renderer = TerminalSurface.makeRenderer(
                configuration: Ubiquitty.Preferences.Effective.renderConfiguration(configuration),
                systemTransparency: TerminalWindowController.systemTransparency
            ) as? SurfaceRenderer,
            let surface = TerminalSurface(rows: rows, columns: columns)
        else { return nil }
        self.surface = surface
        self.renderer = renderer
        self.contentScale = contentScale
        self.queue = queue
        surface.renderer = renderer
        if let terminal = surface.drive.borrowTerminal() {
            _ = Ubiquitty.Runtime.seedTerminalConfiguration(terminal, configuration, .ConfiguredOnly)
            surface.drive.republishSnapshot()
        }
        var style = renderer.style
        if let paddingX {
            style.paddingLeftPoints = paddingX
            style.paddingRightPoints = paddingX
        }
        if let paddingY {
            style.paddingTopPoints = paddingY
            style.paddingBottomPoints = paddingY
        }
        renderer.style = style
        // The backdrop the configuration names. The decode is the Kit
        // component every arm calls, so an offscreen frame and a live window
        // sample the same bytes rather than two readings of one file.
        if let backdrop = BackdropImage.load(
            path: String(Ubiquitty.Preferences.Effective.backgroundImage(configuration)),
            usesDisplayP3: Ubiquitty.Preferences.Effective.imagePresentationColorSpace(configuration)
                == Ubiquitty.Image.PresentationColorSpace.DisplayP3,
            device: device
        ) {
            renderer.setBackdrop(
                texture: backdrop.texture,
                opacity: Double(Ubiquitty.Preferences.Effective.backgroundImageOpacity(configuration)),
                mode: Int32(Ubiquitty.Preferences.Effective.backgroundImageMode(configuration).rawValue),
                pixelWidth: Int32(backdrop.pixelWidth),
                pixelHeight: Int32(backdrop.pixelHeight)
            )
        }

        renderer.prepare(forDeviceScale: contentScale)
        renderer.prepareFrameRenderer(for: surface)
        let cell = renderer.cellSize(for: surface)
        let width = (Double(columns) * cell.width + style.paddingLeftPoints + style.paddingRightPoints) * contentScale
        let height = (Double(rows) * cell.height + style.paddingTopPoints + style.paddingBottomPoints) * contentScale
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
            width <= Double(device.maximumTexture2DDimension), height <= Double(device.maximumTexture2DDimension)
        else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: Int(width.rounded()),
            height: Int(height.rounded()),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
        surface.metalLayer.contentsScale = contentScale
        surface.frame = NSRect(x: 0, y: 0, width: Double(texture.width) / contentScale, height: Double(texture.height) / contentScale)
        surface.resizeGridToBounds()
        surface.drive.resize(rows: rows, columns: columns)
    }

    func feed(_ bytes: std.string) {
        let feed: [CChar] = (0..<bytes.size()).map { bytes[$0] }
        surface.drive.feed(feed.span)
    }

    /// Prints what the terminal answered the bytes fed so far, for a case's
    /// stdout contract.
    func reportReplies() {
        guard let replies = surface.drive.withTerminal({ String(Ubiquitty.Diagnostics.drainRepliesForReport($0)) }), !replies.isEmpty
        else { return }
        print("snapshot: replies \(replies)")
    }

    /// Draws the frame, then stands the password badge on it.
    ///
    /// The badge's cell is the submitted frame's: `drawnCellSize(for:)`
    /// answers zero until a grid frame has been submitted, and a capture
    /// submits its first with this call. A prompt fed before that frame — the
    /// whole of a snapshot case — has a cell to stand in only once the frame
    /// is drawn, so the badge is laid out after it; `pixels()` composites it
    /// over the frame afterwards. Core's own lock, on the tiers that draw one
    /// in the frame, reads the model and takes nothing from this order.
    ///
    /// - Returns: Whether a frame was encoded.
    func render() -> Bool {
        surface.drive.republishSnapshot()
        guard renderer.renderStill(surface, into: texture, contentScale: contentScale) else { return false }
        surface.updatePasswordPromptBadge()
        return true
    }

    func pixels() -> Data? {
        guard render(), let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }
        var pixels = Data(count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(
                base,
                bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
            if surface.isPasswordPromptShown && !renderer.isBitmapTier {
                Self.compositePasswordBadge(
                    of: surface,
                    over: base,
                    widthInPixels: texture.width,
                    heightInPixels: texture.height,
                    contentScale: contentScale
                )
            }
        }
        return pixels
    }

    func writePNG(to path: String) -> Bool {
        guard let pixels = pixels() else { return false }
        if renderer.isBitmapTier {
            // The bitmap tier stores straight BGRA samples. The portable PNG
            // encoder writes those samples without a Core Graphics alpha
            // conversion on the snapshot path.
            var rgba = [UInt8](pixels)
            for offset in stride(from: 0, to: rgba.count, by: 4) {
                rgba.swapAt(offset, offset + 2)
            }
            let encoded = rgba.withUnsafeBufferPointer { buffer in
                Ubiquitty.Rendering.encodePNG(
                    Ubiquitty.Rendering.PNGPixels(buffer),
                    Ubiquitty.IntSize(width: Int32(texture.width), height: Int32(texture.height))
                )
            }
            guard !encoded.empty() else { return false }
            do {
                try Data((0..<Int(encoded.size())).map { encoded[$0] }).write(to: URL(fileURLWithPath: path))
            } catch {
                return false
            }
            reportFrameBuild()
            return true
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: texture.width,
                height: texture.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: texture.width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ),
            let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        reportFrameBuild()
        return true
    }

    private func reportFrameBuild() {
        print("ubiquitty-render-path: builder=core compositor=metal encoder=swift")
        // What Core's builder emitted for this frame, so a check can tell a frame
        // that built the scene from one that wrote a PNG of nothing.
        let counts = renderer.lastFrameCounts
        let glyphs =
            counts.glyphs + counts.wideGlyphs + counts.colorGlyphs + counts.ligatureGlyphs
            + counts.doubleGlyphs + counts.proportionalGlyphs
        print(
            "surface-frame-build: cells=\(counts.cells) glyphs=\(glyphs) decorations=\(counts.decorations) "
                + "boxFills=\(counts.boxFills)"
        )
    }

    private static func compositePasswordBadge(
        of surface: TerminalSurface,
        over base: UnsafeMutableRawPointer,
        widthInPixels: Int,
        heightInPixels: Int,
        contentScale: Double
    ) {
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: base,
                width: widthInPixels,
                height: heightInPixels,
                bitsPerComponent: 8,
                bytesPerRow: widthInPixels * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { return }
        let badgeFrame = surface.passwordBadge.frame
        let heightInPoints = Double(heightInPixels) / contentScale
        context.scaleBy(x: contentScale, y: contentScale)
        context.translateBy(x: badgeFrame.minX, y: heightInPoints - badgeFrame.maxY)
        surface.passwordBadge.drawAsShown(into: context, contentScale: contentScale)
    }
}
#endif
