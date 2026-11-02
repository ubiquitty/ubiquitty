// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// MetalPipelines.swift — the render pipeline states one drawable format needs.
//
// The GPU half of the renderer, separated from the frame logic. Ten states built
// from one shader library, each pairing a vertex and fragment function with the
// blending its pass composites under. They are immutable once built and rebuilt
// only when the drawable's pixel format changes.
//
// Owning them here rather than as ten ivars is what makes the set a set: the
// pixel format reaches every state through one parameter, a pass added later
// cannot forget its blend mode because the initialiser names all of them
// together, and ARC releases them without a matching teardown to maintain.
//
// Metal types are Swift-native, so nothing crosses an interop seam to build
// these. The ObjC++ that still owns the frame reaches the class as
// `Ubiquitty::MetalPipelines` through -cxx-interoperability-mode=default — no
// `@objc`, no NSObject, no message send on the path.

import Metal
import Synchronization
import os

/// How a pass composites over what is already in the attachment.
///
/// A closed set rather than a descriptor each call site fills. The factors are
/// not interchangeable and the difference between two of them is a frame that
/// looks nearly right, so the choice is named where it can be read against the
/// pass rather than spelled out ten times.
public enum BlendMode {
    /// Opaque. The pass owns its pixels outright.
    case replace
    /// Straight (non-premultiplied) source-over, for coverage-shaded passes.
    case straightAlphaOver
    /// Premultiplied source-over with a coverage per channel, read from the
    /// fragment's second output. Text needs it: the byte each channel must
    /// land on is an encoded-space mix, and one alpha cannot carry three
    /// channels whose transfer slopes differ through a linear blend.
    case perChannelCoverageOver
    /// Premultiplied source-over, for anything already multiplied through.
    case premultipliedOver
    /// Source-under-destination, for the background image beneath the grid.
    case destinationOver
    /// Component-wise maximum, for the Tektronix glow: overlapping halos form
    /// one bloom around the polyline instead of doubling where runs meet.
    case maximum

    /// Applies this mode to a colour attachment.
    ///
    /// - Parameter attachment: The attachment to configure.
    @inlinable
    func apply(to attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        guard case .replace = self else {
            attachment.isBlendingEnabled = true
            switch self {
            case .replace:
                break
            case .straightAlphaOver:
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .premultipliedOver:
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .perChannelCoverageOver:
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSource1Color
                attachment.destinationAlphaBlendFactor = .oneMinusSource1Alpha
            case .destinationOver:
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .oneMinusDestinationAlpha
                attachment.sourceAlphaBlendFactor = .oneMinusDestinationAlpha
                attachment.destinationRGBBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            case .maximum:
                attachment.rgbBlendOperation = .max
                attachment.alphaBlendOperation = .max
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            return
        }
        attachment.isBlendingEnabled = false
    }
}

/// The render pipeline states the terminal draws its passes with.
///
/// Every state is optional and independently so. A shader that fails to compile
/// costs its own pass and nothing else — the encode guards on each — which is
/// why a partial set is a usable object rather than a failed initialisation.
public final class MetalPipelines {
    /// The cell background quads.
    public let cell: MTLRenderPipelineState?
    let secondaryCell: MTLRenderPipelineState?
    let vibrantBackground: MTLRenderPipelineState?
    let backgroundTransition: MTLRenderPipelineState?
    let nativeBackgroundTransition: MTLRenderPipelineState?
    let secondaryCursorClear: MTLRenderPipelineState?
    let secondaryGlyph: MTLRenderPipelineState?
    /// The cursor and selection overlays, drawn over cells and decorations.
    public let overlay: MTLRenderPipelineState?
    /// Floating highlights blend the drawable's encoded premultiplied bytes.
    let encodedOverlay: MTLRenderPipelineState?
    let encodedOverlayFormat: MTLPixelFormat?
    /// The overlay pass for the bitmap tier: the same shaders, blending off. The
    /// fragment composites in the software renderer's integer domain itself.
    public let overlayBitmap: MTLRenderPipelineState?
    /// Whether the bitmap tier's overlay and rule states read the target.
    /// When they cannot, those passes draw through the encoded states below
    /// instead, into a linear-format view of the target.
    let isBitmapTargetReadable: Bool
    /// The bitmap tier's floating overlays and rules for a target that cannot
    /// be read, blending the stored sRGB bytes through a linear-format view.
    let encodedBitmapOverlay: MTLRenderPipelineState?
    let encodedBitmapOverlayShadow: MTLRenderPipelineState?
    let encodedBitmapDecoration: MTLRenderPipelineState?
    let encodedBitmapTekLine: MTLRenderPipelineState?
    public let secondaryOverlay: MTLRenderPipelineState?
    /// The margin-restore pass, blending off, because a restore writes the
    /// clear value rather than blending over it — rounded to the code the
    /// clear stores, so a restored margin and a cleared one are one byte.
    public let marginRestore: MTLRenderPipelineState?
    let secondaryMarginRestore: MTLRenderPipelineState?
    /// The margin-restore pass for the bitmap tier, which does read the target:
    /// a strip carries the background's own opacity as its alpha, so below one
    /// the fragment composites the clear over what is there in the software
    /// renderer's integer domain rather than replacing it outright.
    public let marginRestoreBitmap: MTLRenderPipelineState?
    /// Monochrome glyphs, foreground-tinted from the coverage sheet.
    public let glyph: MTLRenderPipelineState?
    /// The shaped-glyph pass for the bitmap tier: the same shaders, blending
    /// off; the fragment replaces the pixel as the software renderer does and
    /// its second colour output goes unread.
    public let glyphBitmap: MTLRenderPipelineState?
    /// Colour glyphs, sampled straight from the colour sheet.
    public let colorGlyph: MTLRenderPipelineState?
    /// Underlines, strikethroughs and the rest of the rule pass.
    public let decoration: MTLRenderPipelineState?
    /// The rule pass for the bitmap tier: the same shaders, blending off. The
    /// fragment composites in the software renderer's encoded domain itself and
    /// returns the finished byte, so a hardware blend would mix it a second time.
    /// Its fragment reads the colour attachment (`[[color(0)]]`), as do the
    /// overlay and image fragments: that forces tile residency and rules out
    /// multisampling on these passes, on the Apple GPUs that offer the read.
    public let decorationBitmap: MTLRenderPipelineState?
    /// Inline images.
    public let image: MTLRenderPipelineState?
    /// The inline-image pass for the bitmap tier: the same shaders, blending off;
    /// the fragment composites in the software renderer's integer domain itself.
    public let imageBitmap: MTLRenderPipelineState?
    /// Rich text blocks and their selection highlights, premultiplied, over
    /// the blitted grid.
    public let richText: MTLRenderPipelineState?
    /// The window's background image, composited beneath the grid.
    public let backgroundImage: MTLRenderPipelineState?
    /// Tektronix vectors, blended in linear light.
    public let tektronixLine: MTLRenderPipelineState?
    /// Tektronix vectors on the bitmap tier, mixed into the target's bytes as
    /// the software compositor mixes them.
    public let tektronixLineBitmap: MTLRenderPipelineState?
    /// The Tektronix glow, which brightens rather than covers.
    public let tektronixGlow: MTLRenderPipelineState?
    /// The full-screen blit the retained grid texture is presented through.
    public let fullscreenBlit: MTLRenderPipelineState?
    /// The `vertex/fragment` pair of every state that did not build, in the
    /// order they were attempted, empty when all of them did.
    ///
    /// A state that fails costs its own pass and nothing else, and the encoder
    /// skips a nil pipeline without a word — which is the right behaviour for a
    /// window, and the wrong one for a harness, where the frame it compares was
    /// drawn by fewer passes than the frame it is compared against. The log
    /// line the failure writes is not something a test can read. This is.
    public let unbuiltPipelines: [String]

    /// Builds every pipeline for one drawable pixel format.
    ///
    /// Returns nil only when the shader library itself is missing, which happens
    /// when the Metal Toolchain was unavailable at build time. The renderer then
    /// paints backgrounds and no glyphs rather than failing to start, so the
    /// absence is reported and survivable rather than fatal.
    ///
    /// - Parameters:
    ///   - device: The device the states are built for.
    ///   - pixelFormat: The drawable's colour format; every state must match it.
    public convenience init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let library = MetalPipelines.moduleShaderLibrary(for: device) else {
            os_log(.error, "UBRenderer: default Metal library missing; build with the Metal Toolchain to enable glyph rendering")
            return nil
        }
        self.init(device: device, pixelFormat: pixelFormat, library: library)
    }

    /// The module's own compiled shaders, read from the bundle once per device.
    ///
    /// Resolved against the bundle this class lives in rather than the main
    /// bundle: linked statically into an app the two are the same, and packaged
    /// as a framework only this spelling finds the library — `Bundle.main` is
    /// the host application, which carries no metallib of ours.
    ///
    /// The first library a device loads is the one every later caller gets, so
    /// a window opened after launch does not read the bundle again. An update or
    /// a rebuild that replaces the application while it runs takes the file away
    /// for as long as the replacement lasts, and a window that read it then
    /// would have no shaders to draw with. A load that fails is not kept: the
    /// next caller reads the bundle again.
    ///
    /// - Parameter device: The device the library is built for.
    /// - Returns: The library, or nil when the bundle carries none: the Metal
    ///   Toolchain was unavailable at build time, or the file is missing.
    public static func moduleShaderLibrary(for device: MTLDevice) -> MTLLibrary? {
        loadedLibraries.withLock { libraries -> (any MTLLibrary)? in
            if let loaded = libraries.first(where: { $0.device === device }) {
                return loaded
            }
            guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: MetalPipelines.self)) else {
                return nil
            }
            libraries.append(library)
            return library
        }
    }

    /// Every library ``moduleShaderLibrary(for:)`` has loaded, one per device.
    ///
    /// A library holds its device, so a device's entry is found by identity
    /// and the identity cannot be reused while the entry stands.
    private static let loadedLibraries = Mutex<[any MTLLibrary]>([])

    /// Builds every pipeline from a named shader library.
    ///
    /// Separate from the bundle-loading initialiser rather than a defaulted
    /// argument on it: the ObjC++ that still owns the frame calls the two-argument
    /// form through the generated header, and a Swift default argument is not a
    /// C++ default argument.
    ///
    /// - Parameters:
    ///   - device: The device the states are built for.
    ///   - pixelFormat: The drawable's colour format; every state must match it.
    ///   - library: The compiled shaders, from somewhere other than the bundle.
    public init(device: MTLDevice, pixelFormat: MTLPixelFormat, library: MTLLibrary) {
        var unbuilt: [String] = []
        func state(_ vertex: String, _ fragment: String, _ blend: BlendMode, format: MTLPixelFormat? = nil) -> MTLRenderPipelineState? {
            // Both halves resolved before the descriptor is filled. A name the
            // library does not carry comes back nil, and a descriptor whose
            // fragment function is nil is one Metal accepts: the state builds,
            // the pass encodes, and it writes no colour. That is a pipeline
            // reporting success while drawing nothing, which no caller can tell
            // from a pass that had nothing to draw.
            guard let vertexFunction = library.makeFunction(name: vertex),
                let fragmentFunction = library.makeFunction(name: fragment)
            else {
                os_log(
                    .error,
                    "UBRenderer: shader %{public}s/%{public}s is not in the library",
                    vertex,
                    fragment
                )
                unbuilt.append("\(vertex)/\(fragment)")
                return nil
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = format ?? pixelFormat
            blend.apply(to: descriptor.colorAttachments[0])
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                os_log(
                    .error,
                    "UBRenderer: pipeline %{public}s/%{public}s build failed: %{public}s",
                    vertex,
                    fragment,
                    String(describing: error)
                )
                unbuilt.append("\(vertex)/\(fragment)")
                return nil
            }
        }
        // The bitmap tier's passes read the target and return the finished byte.
        // Where framebuffer reads are refused (the iOS simulator), that state
        // never builds; the pass then takes its `*Unread` entry point instead,
        // which hands the hardware the colour and coverage to blend, rather
        // than leaving the pass out of every frame. Only a fallback that also
        // fails stays in the unbuilt list.
        var didFallBack = false
        func bitmapState(_ vertex: String, _ fragment: String, unread: String) -> MTLRenderPipelineState? {
            let recorded = unbuilt.count
            if let reading = state(vertex, fragment, .replace) { return reading }
            didFallBack = true
            guard let blended = state(vertex, unread, .straightAlphaOver) else { return nil }
            unbuilt.removeSubrange(recorded...)
            return blended
        }
        cell = state("termVertex", "termFragment", .replace)
        secondaryCell = state("termVertex", "secondaryCellFragment", .replace)
        vibrantBackground = state("termVertex", "vibrantBackgroundFragment", .replace)
        backgroundTransition = state("overlayVertex", "backgroundTransitionFragment", .replace)
        nativeBackgroundTransition = state("overlayVertex", "nativeBackgroundTransitionFragment", .replace)
        secondaryCursorClear = state("termVertex", "secondaryCursorClearFragment", .replace)
        secondaryGlyph = state("glyphVertex", "secondaryGlyphFragment", .premultipliedOver)
        // A blending pipeline takes the entry point that declares no colour
        // attachment, because it never reads one: only the bitmap tier's
        // branches touch the destination, and those have their own `*Bitmap`
        // state that replaces rather than blends. Declaring a read the pass
        // does not perform costs the pass itself wherever framebuffer reads
        // are refused: `state` resolves to nil, the encoder skips a pass whose
        // pipeline is nil without reporting it, and the frame arrives missing
        // its overlays, decorations and images while the render reports
        // success. The iOS simulator refuses such reads.
        overlay = state("overlayVertex", "overlayFragmentBlended", .straightAlphaOver)
        encodedOverlayFormat =
            switch pixelFormat {
            case .bgra8Unorm_srgb: .bgra8Unorm
            case .rgba8Unorm_srgb: .rgba8Unorm
            default: nil
            }
        encodedOverlay = encodedOverlayFormat.flatMap {
            state("overlayVertex", "encodedOverlayFragment", .straightAlphaOver, format: $0)
        }
        overlayBitmap = bitmapState("overlayVertex", "overlayFragment", unread: "overlayFragmentUnread")
        // The rule and overlay states share the read, so where one falls back
        // the other does.
        isBitmapTargetReadable = !didFallBack
        if isBitmapTargetReadable {
            encodedBitmapOverlay = nil
            encodedBitmapOverlayShadow = nil
            encodedBitmapDecoration = nil
            encodedBitmapTekLine = nil
        } else {
            encodedBitmapOverlayShadow = encodedOverlayFormat.flatMap {
                state("overlayVertex", "encodedOverlayFragmentUnreadShadow", .straightAlphaOver, format: $0)
            }
            encodedBitmapTekLine = encodedOverlayFormat.flatMap {
                state("tekLineVertex", "tekLineFragmentUnreadEncoded", .straightAlphaOver, format: $0)
            }
            encodedBitmapOverlay = encodedOverlayFormat.flatMap {
                state("overlayVertex", "encodedOverlayFragmentUnread", .straightAlphaOver, format: $0)
            }
            encodedBitmapDecoration = encodedOverlayFormat.flatMap {
                state("decorationVertex", "decorationFragmentUnreadEncoded", .straightAlphaOver, format: $0)
            }
        }
        secondaryOverlay = state("overlayVertex", "secondaryOverlayFragment", .premultipliedOver)
        secondaryMarginRestore = state("overlayVertex", "secondaryMarginFragment", .replace)
        marginRestore = state("overlayVertex", "marginRestoreFragment", .replace)
        marginRestoreBitmap = state("overlayVertex", "overlayFragment", .replace)
        glyph = state("glyphVertex", "glyphFragment", .perChannelCoverageOver)
        glyphBitmap = state("glyphVertex", "glyphFragment", .replace)
        colorGlyph = state("glyphVertex", "colorGlyphFragment", .straightAlphaOver)
        decoration = state("decorationVertex", "decorationFragmentBlended", .straightAlphaOver)
        decorationBitmap = bitmapState("decorationVertex", "decorationFragment", unread: "decorationFragmentUnread")
        image = state("imageVertex", "imageFragmentBlended", .straightAlphaOver)
        imageBitmap = bitmapState("imageVertex", "imageFragment", unread: "imageFragmentUnread")
        richText = state("imageVertex", "richTextFragment", .premultipliedOver)
        backgroundImage = state("backgroundImageVertex", "backgroundImageFragment", .destinationOver)
        tektronixLine = state("tekLineVertex", "tekLineFragmentBlended", .straightAlphaOver)
        tektronixLineBitmap = bitmapState("tekLineVertex", "tekLineFragment", unread: "tekLineFragmentUnread")
        tektronixGlow = state("tekLineGlowVertex", "tekLineGlowFragment", .maximum)
        // Replace, not over: the retained grid is the whole frame, its own
        // clear included, and its alpha is the background opacity. Blending
        // it over the drawable's clear adds that clear's alpha back — over an
        // opaque clear a translucent frame lands opaque, the theme darkened
        // towards black, on either shell.
        fullscreenBlit = state("fullscreenTriangleVertex", "fullscreenBlit", .replace)
        unbuiltPipelines = unbuilt
    }
}
