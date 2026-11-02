// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+Factory.swift — the front door, for either shell.
//
// A host reaches the concrete renderer through this factory as the protocol it
// conforms to, which is the API shape that lasts: a host binds to
// `TerminalSurfaceRenderer` and the concrete type stays free to change behind
// it. It imported AppKit and named no AppKit type — the front door was shut to
// one of the two shells by an import it did not use.

import Foundation
import Metal
internal import UbiquittyRenderKit

extension TerminalSurface {
    /// Builds a surface that is ready to draw.
    ///
    /// The one call an embedder needs: a surface with no renderer is a
    /// complete, correct terminal that paints nothing, and building it in two
    /// steps is an invitation to ship the half of it that shows black. What is
    /// left to the host is where to put the view and what to feed it.
    ///
    /// Use ``makeRenderer(device:fontFamily:pointSize:typography:style:)`` and
    /// assign instead when several surfaces are to share one renderer, which
    /// shares its glyph sheets between them.
    ///
    /// - Parameters:
    ///   - rows: The initial grid height.
    ///   - columns: The initial grid width.
    ///   - fontFamily: The family to draw in.
    ///   - pointSize: The em size in points.
    ///   - typography: The rest of the font configuration.
    ///   - style: The colour and decoration configuration; the
    ///     configuration's own unless given.
    ///   - device: The Metal device, or nil for the system's.
    /// - Returns: The surface, or nil when Core declines a session or the
    ///   renderer cannot be built.
    public convenience init?(
        rows: Int,
        columns: Int,
        fontFamily: String = "Menlo",
        pointSize: Double = 13,
        typography: SurfaceTypography = SurfaceTypography(),
        style: SurfaceStyle = .configured(),
        device: (any MTLDevice)? = nil
    ) {
        self.init(rows: rows, columns: columns)
        guard
            let renderer = TerminalSurface.makeRenderer(
                device: device,
                fontFamily: fontFamily,
                pointSize: pointSize,
                typography: typography,
                style: style
            )
        else {
            return nil
        }
        self.renderer = renderer
        // The size a zoom is an offset over. Set from what was asked for rather
        // than read back, so a renderer that rounded its own measurement cannot
        // move where "no zoom" lands.
        configuredPointSize = pointSize
    }

    /// Builds a renderer surfaces draw through, one per font configuration.
    ///
    /// One renderer serves every surface in a window — the glyph sheets
    /// behind it are shared per configuration, so a renderer per surface
    /// would rasterise the same glyphs once per pane. Assign the result to
    /// each surface's ``TerminalSurface/renderer``.
    ///
    /// - Parameters:
    ///   - device: The Metal device to draw with; the system default when nil.
    ///   - fontFamily: The monospaced family glyphs are drawn from.
    ///   - pointSize: The font's em size in points.
    ///   - typography: The rest of the font configuration — fallback families,
    ///     the optical boost, ligatures. Renderers built from configurations
    ///     that differ in any of it keep their own glyph sheets; two built from
    ///     equal ones share, which is why a host wanting one set of sheets
    ///     passes one value rather than two equal-looking ones.
    ///   - style: The frame styling — blend gammas, underline rules, the
    ///     background opacity. Unlike typography this cuts no sheets. The
    ///     configuration's own (``SurfaceStyle/configured()``) unless a shell
    ///     layers its window's facts over that.
    /// - Returns: The renderer, or nil when the device, the shader library or
    ///   the font cannot be resolved.
    @MainActor
    public static func makeRenderer(
        device: (any MTLDevice)? = nil,
        fontFamily: String = "Menlo",
        pointSize: Double = 13,
        typography: SurfaceTypography = SurfaceTypography(),
        style: SurfaceStyle = .configured()
    ) -> (any TerminalSurfaceRenderer)? {
        try? buildRenderer(device: device, fontFamily: fontFamily, pointSize: pointSize, typography: typography, style: style).get()
    }

    /// Builds a renderer, or names what it could not be built without.
    ///
    /// ``makeRenderer(device:fontFamily:pointSize:typography:style:)`` with the
    /// reason kept: a host that has to tell a person why no window opened reads
    /// it from the attempt that failed, not from a second look that may find a
    /// different answer.
    ///
    /// - Parameters: As ``makeRenderer(device:fontFamily:pointSize:typography:style:)``.
    /// - Returns: The renderer, or the first requirement that was missing.
    @MainActor
    package static func buildRenderer(
        device: (any MTLDevice)? = nil,
        fontFamily: String,
        pointSize: Double,
        typography: SurfaceTypography,
        style: SurfaceStyle
    ) -> Result<any TerminalSurfaceRenderer, RendererRefusal> {
        guard let device = device ?? SystemMetalDevice.resolve() else {
            return .failure(.noGraphicsDevice)
        }
        guard let library = MetalPipelines.moduleShaderLibrary(for: device) else {
            return .failure(.noShaderLibrary)
        }
        var resolvedTypography = typography
        if resolvedTypography.symbolFontPath.isEmpty,
            let bundledSymbols = Bundle.main.url(
                forResource: "SymbolsNerdFontMono-Regular",
                withExtension: "ttf",
                subdirectory: "fonts"
            )
        {
            resolvedTypography.symbolFontPath = bundledSymbols.path
        }
        // One format for both shells: the shaders write linear light and rely
        // on the target's sRGB encode. A plain Unorm target stores the linear
        // values raw, and every colour downstream reads over-bright.
        let pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb
        guard
            let renderer = SurfaceRenderer(
                device: device,
                library: library,
                pixelFormat: pixelFormat,
                familyName: fontFamily,
                pointSize: pointSize,
                typography: resolvedTypography,
                style: style
            )
        else {
            return .failure(.unusableFont)
        }
        // The Tektronix styling from the configuration, here because this is
        // every shell's renderer: one that skipped it drew the tube under the
        // type's defaults — no bloom, the theme's phosphor — on any shell
        // that did not set it afterwards.
        renderer.tekSettings = .configured()
        return .success(renderer)
    }
}

/// What a renderer could not be built without.
package enum RendererRefusal: Error, Equatable {
    /// The system offered no Metal device.
    case noGraphicsDevice
    /// The module's compiled shaders did not load from its bundle.
    case noShaderLibrary
    /// The family could not be measured at the size asked for.
    case unusableFont
}
