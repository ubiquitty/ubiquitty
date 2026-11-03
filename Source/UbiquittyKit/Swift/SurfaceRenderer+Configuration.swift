// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// SurfaceRenderer+Configuration.swift — the one adapter from Core's
// `RenderConfiguration` to the Swift renderer's settings.
//
// Every value here is read from the struct Core folds out of the configuration
// document; nothing is defaulted on this side. A host that builds its renderer
// through ``TerminalSurface/makeRenderer(device:configuration:systemTransparency:)``
// draws what the document says, the same on either shell, and an unset key draws
// as its default because the fold resolved it before it crossed.

import Foundation
import Metal
import QuartzCore
internal import UbiquittyCore
internal import UbiquittyRenderKit

extension SurfaceTypography {
    /// The font configuration a document names.
    ///
    /// - Parameter configuration: Core's fold of the live document.
    package init(configuration: borrowing Ubiquitty.Rendering.RenderConfiguration) {
        self.init()
        cjkFallbackFamily = String(configuration.cjkFallbackFamily.string())
        emojiFallbackFamily = String(configuration.emojiFallbackFamily.string())
        shouldMatchFallbackSize = configuration.shouldMatchFallbackSize
        // Loops rather than `map`: a borrowed parameter cannot be captured.
        for index in 0..<Int(configuration.languageFallbackCount) {
            languageFallbacks.append(SurfaceTypography.rule(configuration.languageFallbackAt(index)))
        }
        for index in 0..<Int(configuration.rangeMapCount) {
            rangeMaps.append(SurfaceTypography.rule(configuration.rangeMapAt(index)))
        }
        lineSpacingInPoints = configuration.lineSpacingPoints
        canLigate = configuration.hasLigatures
        ligatureFeatureSpec = String(configuration.fontFeatures.string())
        symbolFamilyName = String(configuration.symbolFallbackFamily.string())
        wideGlyphBoostCap = configuration.shouldBoostWideGlyphs ? configuration.wideGlyphScale : 1
        characterSpacingInPoints = configuration.characterSpacingPoints
        fontWeight = Int(configuration.fontWeight)
        boldFontWeight = Int(configuration.boldFontWeight)
        fontWidthPercent = configuration.fontWidthPercent
        fontVariationSpec = String(configuration.fontVariations.string())
        baselineOffsetInPoints = configuration.baselineOffsetPoints
        proportionalFamilyName = String(configuration.proportionalFontFamily.string())
        proportionalPointSize = configuration.proportionalFontSizePoints
        gridPointSize = configuration.fontSizePoints
    }

    private static func rule(_ core: Ubiquitty.Rendering.FallbackRule) -> FallbackRule {
        var rule = FallbackRule()
        rule.script = String(core.script.string())
        rule.language = String(core.language.string())
        rule.mode = String(core.mode.string())
        rule.family = String(core.family.string())
        rule.firstCodePoint = core.firstCodePoint
        rule.lastCodePoint = core.lastCodePoint
        rule.shouldMatchSize = core.sizing == .Inherit ? nil : core.sizing == .MatchPrimary
        return rule
    }
}

extension SurfaceStyle {
    /// The frame styling a document names.
    ///
    /// The ground goes through Core's `backgroundEffects`, which is where an
    /// opaque window draws opaque and Reduce Transparency wins; the host
    /// reports the system's switch and nothing else.
    ///
    /// - Parameters:
    ///   - configuration: Core's fold of the live document.
    ///   - systemTransparency: Whether the system asks for translucency to be
    ///     given up.
    package init(
        configuration: borrowing Ubiquitty.Rendering.RenderConfiguration,
        systemTransparency: Ubiquitty.Preferences.Effective.SystemTransparency
    ) {
        self.init()
        var request = Ubiquitty.Preferences.Effective.BackgroundRequest()
        request.backgroundOpacity = configuration.backgroundOpacity
        request.blurRadius = configuration.blurRadiusPoints
        request.defaultBackgroundOpacity = configuration.defaultBackgroundOpacity
        request.shouldEnhanceTextOnBlur = configuration.shouldEnhanceTextOnBlur
        request.usesBackgroundVibrancy = configuration.usesBackgroundVibrancy
        let effects = Ubiquitty.Preferences.Effective.backgroundEffects(request, systemTransparency)
        backgroundOpacity = effects.rendererOpacity
        defaultBackgroundOpacity = effects.defaultBackgroundOpacity
        usesTextVibrancy = effects.shouldEnhanceTextOnBlur
        usesBackgroundVibrancy = effects.usesBackgroundVibrancy
        shouldEnhanceTextContrast = configuration.shouldEnhanceTextContrast
        usesDisplayP3 = configuration.usesDisplayP3
        shouldUnderlineLinks = configuration.shouldUnderlineLinks
        linkStyleIndex = Int(configuration.linkUnderlineStyle)
        shouldStyleLinksPerKind = configuration.shouldStyleLinksPerKind
        if configuration.shouldUseSystemBlueLinkColor {
            let blue = LinkAccentColor.components
            linkColorRed = blue.red
            linkColorGreen = blue.green
            linkColorBlue = blue.blue
        }
        shouldBrightenBold = configuration.shouldBrightenBold
        shouldDrawBrailleGrid = configuration.shouldDrawBrailleGrid
        brailleStyle = BrailleStyle.from(configuration.brailleStyle)
        shadeStyle = ShadeStyle.from(configuration.shadeStyle)
        selectionStyle = configuration.selectionStyle == Ubiquitty.Rendering.SelectionStyle.Tint ? .tint : .native
        switch configuration.nonOwnerPresentation {
        case .Pan: nonOwnerPresentation = .pan
        case .Fit: nonOwnerPresentation = .fit
        default: nonOwnerPresentation = .letterbox
        }
        shouldCursorInvertText = configuration.shouldCursorInvertText
        underlineThicknessScale = configuration.underlineThicknessScale
        underlineOffsetInPoints = configuration.underlineOffsetPoints
        shouldUnderlineSkipInk = configuration.shouldUnderlineSkipInk
        shouldUnderlineFollowInk = configuration.shouldUnderlineFollowInk
        underlineSkipInkPaddingInPoints = configuration.underlineSkipInkPaddingPoints
        paddingLeftPoints = configuration.paddingLeftPoints
        paddingRightPoints = configuration.paddingRightPoints
        paddingTopPoints = configuration.paddingTopPoints
        paddingBottomPoints = configuration.paddingBottomPoints
    }
}

extension SurfaceTekSettings {
    /// The storage tube's settings a document names.
    ///
    /// - Parameter configuration: Core's fold of the live document.
    package init(configuration: borrowing Ubiquitty.Rendering.RenderConfiguration) {
        self.init(
            usesCustomColors: configuration.usesCustomTekColors,
            customBeamRGB: configuration.tekBeamRGB,
            customBackgroundRGB: configuration.tekBackgroundRGB,
            drawsWritingSpot: configuration.drawsTekWritingSpot,
            drawsGlowVectors: configuration.drawsTekGlowVectors
        )
    }
}

extension TerminalSurface {
    /// Builds a renderer configured from Core's fold of the live document.
    ///
    /// The configuration-driven front door: the family, the size, the
    /// typography, the frame styling and the storage tube all come from one
    /// `RenderConfiguration`, so two hosts configured from one document build
    /// the same renderer.
    ///
    /// - Parameters:
    ///   - device: The Metal device to draw with; the system default when nil.
    ///   - configuration: Core's fold, normally
    ///     `Preferences.Effective.liveRenderConfiguration()`.
    ///   - systemTransparency: Whether the system asks for translucency to be
    ///     given up.
    /// - Returns: The renderer, or nil when the device, the shader library or
    ///   the font cannot be resolved.
    @MainActor
    package static func makeRenderer(
        device: (any MTLDevice)? = nil,
        configuration: borrowing Ubiquitty.Rendering.RenderConfiguration,
        systemTransparency: Ubiquitty.Preferences.Effective.SystemTransparency
    ) -> (any TerminalSurfaceRenderer)? {
        try? buildRenderer(device: device, configuration: configuration, systemTransparency: systemTransparency).get()
    }

    /// Builds a renderer configured from Core's fold, or names what it could
    /// not be built without.
    ///
    /// - Parameters: As ``makeRenderer(device:configuration:systemTransparency:)``.
    /// - Returns: The renderer, or the first requirement that was missing.
    @MainActor
    package static func buildRenderer(
        device: (any MTLDevice)? = nil,
        configuration: borrowing Ubiquitty.Rendering.RenderConfiguration,
        systemTransparency: Ubiquitty.Preferences.Effective.SystemTransparency
    ) -> Result<any TerminalSurfaceRenderer, RendererRefusal> {
        let built = buildRenderer(
            device: device,
            fontFamily: family(of: configuration),
            pointSize: configuration.fontSizePoints,
            typography: SurfaceTypography(configuration: configuration),
            style: SurfaceStyle(configuration: configuration, systemTransparency: systemTransparency)
        )
        if case .success(let renderer) = built {
            (renderer as? SurfaceRenderer)?.tekSettings = SurfaceTekSettings(configuration: configuration)
        }
        return built
    }

    /// The family a configuration draws in: the one it names, or the
    /// preferred family when it names none.
    ///
    /// - Parameter configuration: Core's fold of the live document.
    /// - Returns: The family name to adopt.
    package static func family(of configuration: borrowing Ubiquitty.Rendering.RenderConfiguration) -> String {
        configuration.fontFamily.isEmpty() ? preferredFontFamily() : String(configuration.fontFamily.string())
    }

    /// Dresses this surface in a configuration: its renderer — built when it
    /// has none — takes the family and the size (through the surface's own
    /// zoom), the typography, the frame style, the storage tube and the
    /// background picture; the layer takes the colour space and the pacing.
    ///
    /// The one call a host makes when a configuration arrives, so every host
    /// that dresses its panes from Core's fold draws them alike.
    ///
    /// - Parameters:
    ///   - configuration: Core's fold, normally the live one.
    ///   - systemTransparency: Whether the system asks for translucency to be
    ///     given up.
    /// - Returns: Whether the renderer took the configured faces.
    @discardableResult
    package func adopt(
        configuration: borrowing Ubiquitty.Rendering.RenderConfiguration,
        systemTransparency: Ubiquitty.Preferences.Effective.SystemTransparency
    ) -> Bool {
        configuredPointSize = Ubiquitty.Preferences.Zoom.clampFontZoom(configuration.fontSizePoints)
        // A surface with no renderer yet is built in the configuration whole
        // and has no laid-out grid to re-fit; one already drawing re-adopts.
        guard let existing = renderer else {
            renderer = Self.makeRenderer(configuration: configuration, systemTransparency: systemTransparency)
            guard let built = renderer as? SurfaceRenderer else { return false }
            applyRenderPreferences(configuration)
            adoptBackdrop(configuration, on: built)
            return true
        }
        guard let renderer = existing as? SurfaceRenderer else { return false }
        let family = Self.family(of: configuration)
        let typography = SurfaceTypography(configuration: configuration)
        let pointSize = zoomedPointSize
        var didAdopt = false
        let change = {
            didAdopt =
                renderer.adopt(pointSize: pointSize, familyName: family, typography: typography)
                || renderer.adopt(pointSize: pointSize, familyName: Self.preferredFontFamily(), typography: typography)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let host = cellMetricChangeHost {
            host(change)
        } else {
            change()
            resizeGridToBounds()
        }
        CATransaction.commit()
        renderer.style = SurfaceStyle(configuration: configuration, systemTransparency: systemTransparency)
        renderer.tekSettings = SurfaceTekSettings(configuration: configuration)
        renderer.applyColorSpace(to: metalLayer)
        applyRenderPreferences(configuration)
        adoptBackdrop(configuration, on: renderer)
        drive.publishActualFont(family: renderer.familyName, sizePoints: renderer.pointSize)
        discardRetainedFrames()
        needsDisplay = true
        return didAdopt
    }

    /// Installs the configured background picture, decoding the file only when
    /// its path or colour space moved.
    private func adoptBackdrop(_ configuration: borrowing Ubiquitty.Rendering.RenderConfiguration, on renderer: SurfaceRenderer) {
        let path = String(configuration.backgroundImagePath.string())
        let usesDisplayP3 = configuration.usesDisplayP3
        if configuredBackdrop.path != path || configuredBackdrop.usesDisplayP3 != usesDisplayP3 {
            configuredBackdrop = (
                path, usesDisplayP3, BackdropImage.load(path: path, usesDisplayP3: usesDisplayP3, device: renderer.device)
            )
        }
        let image = configuredBackdrop.image
        renderer.setBackdrop(
            texture: image?.texture,
            opacity: configuration.backgroundImageOpacity,
            mode: Int32(configuration.backgroundImageMode.rawValue),
            pixelWidth: Int32(image?.pixelWidth ?? 0),
            pixelHeight: Int32(image?.pixelHeight ?? 0)
        )
    }

    /// The family Ubiquitty's windows draw in when the configuration names
    /// none: the first of Ubiquitty's preferred families that this process
    /// can draw.
    ///
    /// The preference order is Core's, best first, and includes a family the
    /// framework ships. Whether a family can be drawn is asked of CoreText by
    /// name. The framework registers the fonts it ships for the process before
    /// it asks, as building a surface or a renderer does, so a shipped family
    /// is found on a system that has no copy of it, and from then on the
    /// process's own font lookups find the shipped families too.
    ///
    /// ``init(rows:columns:fontFamily:pointSize:typography:style:device:)``
    /// and ``makeRenderer(device:fontFamily:pointSize:typography:style:)``
    /// draw in Menlo when given no family; pass this as the family to draw in
    /// the one Ubiquitty's own windows default to.
    ///
    /// - Returns: The first preferred family CoreText resolves by name, or the
    ///   last of them when none resolves.
    public static func preferredFontFamily() -> String {
        let count = Ubiquitty.Preferences.Defaults.houseFontFamilyCount()
        let candidates = (0..<count).map { String(cString: Ubiquitty.Preferences.Defaults.houseFontFamilyAt($0)) }
        return ShippedFonts.firstFamilyFoundByName(in: candidates)
            ?? String(cString: Ubiquitty.Preferences.Defaults.houseFontFamilyAt(count - 1))
    }
}
