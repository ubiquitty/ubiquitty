// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// SurfaceRenderer.swift — the TerminalSurfaceRenderer a host gets for free.
//
// One of these per font configuration serves every surface in a window, and
// what it holds is the measurement: the faces, the slot layout, the metrics and
// the sheet key. The frame path it adds is borrow the surface's terminal under
// its model lock, capture, build, encode, present. The surface owns its layer
// and its geometry; this is told where to draw and what to draw from.
//
// It holds no renderer. `TerminalRenderer` is one per view by
// its own declaration — the retained grid, the instance streams, the capture and
// the cursor animator are that view's — so each surface cuts its own from the
// measurement and keeps it. The sheets are the part that stays shared, keyed by
// `GlyphAtlas.shared(key:)`, so per-view renderers on one font still rasterise
// each glyph once between them. Per-view content, shared pixels.
//
// A configuration is measured once per backing scale, because the faces are
// rasterised at point size times that scale. Measured builds are kept rather
// than replaced: one of these serves surfaces on every display a window spans,
// so replacing would remeasure both fonts on every frame that alternates.

import Metal
import QuartzCore
internal import UbiquittyCore
internal import UbiquittyRenderKit

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The portable renderer's procedural Braille dot styles.
///
/// Declared in Swift rather than aliased to `Ubiquitty::Rendering::BrailleStyle`
/// because this framework ships a textual interface, and an interface naming a
/// C++ type cannot be read by a consumer that has no interop configured —
/// `Scripts/check-ubiquittykit.sh` compiles one with `-F` and nothing else, and
/// that compile is the assertion. Interop carries the type everywhere inside
/// the module; only the published surface has to speak Swift.
///
/// The raw values are the C++ enumerators' own, so the two orders cannot drift
/// silently: `Tests/Core/Rendering/test_braille_style_mirror.cpp` fails if a
/// case is added, removed or reordered on either side.
public enum BrailleStyle: UInt8, Sendable, CaseIterable {
    /// Round dots on the standard lattice.
    case regular = 0
    /// Hollow dots, six-dot lattice.
    case outline6Dot = 1
    /// Hollow dots, eight-dot lattice.
    case outline8Dot = 2
    /// Minimal dots with guides, six-dot lattice.
    case pinpoint6Dot = 3
    /// Minimal dots with guides, eight-dot lattice.
    case pinpoint8Dot = 4
    /// Square dots.
    case square = 5
    /// Dots drawn as raster cells.
    case raster = 6
}

extension BrailleStyle {
    /// The portable enumerator this style stands for.
    ///
    /// - Returns: The Core value to hand the renderer.
    var core: Ubiquitty.Rendering.BrailleStyle {
        switch self {
        case .regular: return Ubiquitty.Rendering.BrailleStyle.Regular
        case .outline6Dot: return Ubiquitty.Rendering.BrailleStyle.Outline6Dot
        case .outline8Dot: return Ubiquitty.Rendering.BrailleStyle.Outline8Dot
        case .pinpoint6Dot: return Ubiquitty.Rendering.BrailleStyle.Pinpoint6Dot
        case .pinpoint8Dot: return Ubiquitty.Rendering.BrailleStyle.Pinpoint8Dot
        case .square: return Ubiquitty.Rendering.BrailleStyle.Square
        case .raster: return Ubiquitty.Rendering.BrailleStyle.Raster
        }
    }

    /// The style a portable enumerator stands for.
    ///
    /// Internal because its parameter is a C++ type: a public spelling would
    /// put back in the published interface exactly what this enum exists to
    /// keep out. A consumer outside the framework converts through `rawValue`,
    /// which is Swift on both sides.
    ///
    /// - Parameter core: The Core value, from a preference or a snapshot.
    /// - Returns: The matching style, or the default for a value this build
    ///   does not know.
    static func from(_ core: Ubiquitty.Rendering.BrailleStyle) -> BrailleStyle {
        switch core {
        case Ubiquitty.Rendering.BrailleStyle.Regular: return .regular
        case Ubiquitty.Rendering.BrailleStyle.Outline6Dot: return .outline6Dot
        case Ubiquitty.Rendering.BrailleStyle.Outline8Dot: return .outline8Dot
        case Ubiquitty.Rendering.BrailleStyle.Pinpoint6Dot: return .pinpoint6Dot
        case Ubiquitty.Rendering.BrailleStyle.Pinpoint8Dot: return .pinpoint8Dot
        case Ubiquitty.Rendering.BrailleStyle.Square: return .square
        case Ubiquitty.Rendering.BrailleStyle.Raster: return .raster
        default: return .regular
        }
    }
}

/// How the shade glyphs ░ ▒ ▓ draw.
///
/// A Swift mirror of `Ubiquitty::Rendering::ShadeStyle` for the reason
/// ``BrailleStyle`` is one; `Tests/Core/Rendering/test_shade_style.cpp` fails
/// if a case is added, removed or reordered on either side.
public enum ShadeStyle: UInt8, Sendable, CaseIterable {
    /// Solid foreground pixels at the shade's density, on Core's grid-anchored field.
    case pattern = 0
    /// The foreground composited at the shade's density.
    case fill = 1
}

extension ShadeStyle {
    /// The portable enumerator this style stands for.
    var core: Ubiquitty.Rendering.ShadeStyle {
        switch self {
        case .pattern: return Ubiquitty.Rendering.ShadeStyle.Pattern
        case .fill: return Ubiquitty.Rendering.ShadeStyle.Fill
        }
    }

    /// The style a portable enumerator stands for.
    ///
    /// Internal for the reason ``BrailleStyle/from(_:)`` is.
    ///
    /// - Parameter core: The Core value, from a preference.
    /// - Returns: The matching style, or the pattern for a value this build
    ///   does not know.
    static func from(_ core: Ubiquitty.Rendering.ShadeStyle) -> ShadeStyle {
        switch core {
        case Ubiquitty.Rendering.ShadeStyle.Fill: return .fill
        default: return .pattern
        }
    }
}

/// Where a selection's colour is drawn.
public enum SelectionStyle: UInt8, Sendable, CaseIterable {
    /// The system's selection colour, opaque, under the text.
    case native = 0
    /// A translucent tint over the text.
    case tint = 1
}

/// How an independently sized non-owner displays the host's unchanged grid.
public enum RemoteViewportPresentation: UInt8, Sendable {
    case letterbox
    case pan
    case fit
}

extension SelectionStyle {
    /// The portable enumerator this style stands for.
    ///
    /// - Returns: The Core value to hand the renderer.
    var core: Ubiquitty.Rendering.SelectionStyle {
        switch self {
        case .native: return Ubiquitty.Rendering.SelectionStyle.Native
        case .tint: return Ubiquitty.Rendering.SelectionStyle.Tint
        }
    }
}

/// The font facts a surface's sheets are cut from, beyond family and size.
///
/// One value rather than eight arguments, because the sheet key and the renderer
/// are built from the same facts at two sites ninety lines apart. A key naming
/// fewer of them than the renderer uses is the failure worth designing against:
/// `GlyphAtlas.shared(key:)` hands two configurations one atlas when their keys
/// match, so an unnamed fact makes two surfaces that draw differently rasterise
/// into each other's sheets.
///
/// The defaults are the plainest build: no optical boost, no bitmap upscale, no
/// fallback families, no ligatures, so a host need set none of them.
public struct SurfaceTypography: Hashable, Sendable {
    /// One ordered fallback rule for a script or code-point range.
    public struct FallbackRule: Hashable, Sendable {
        /// The script token, such as `han`.
        public var script: String = ""
        /// The preferred language tag, or empty.
        public var language: String = ""
        /// The routing mode from the configuration.
        public var mode: String = ""
        /// The destination font family.
        public var family: String = ""
        /// The inclusive start of a range rule.
        public var firstCodePoint: UInt32 = 0
        /// The inclusive end of a range rule.
        public var lastCodePoint: UInt32 = 0
        /// Whether this range matches the primary size; nil inherits the default.
        public var shouldMatchSize: Bool?

        /// Creates an empty fallback rule.
        public init() {}
    }

    /// The emoji fallback family, or empty for the platform cascade.
    public var emojiFallbackFamily: String = ""
    /// Whether native fallback text matches the primary face’s visual size.
    public var shouldMatchFallbackSize = true
    /// The ordered script and language fallback rules.
    public var languageFallbacks: [FallbackRule] = []
    /// The ordered code-point fallback rules.
    public var rangeMaps: [FallbackRule] = []

    /// The complete routing identity used to share glyph sheets.
    internal var routingKey: String {
        var fields = [emojiFallbackFamily, String(shouldMatchFallbackSize), String(languageFallbacks.count), String(rangeMaps.count)]
        for rule in languageFallbacks + rangeMaps {
            fields += [
                rule.script, rule.language, rule.mode, rule.family,
                String(rule.firstCodePoint), String(rule.lastCodePoint), rule.shouldMatchSize.map { $0 ? "true" : "false" } ?? "inherit",
            ]
        }
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// Builds the routing configuration owned by this typography value.
    internal func routingConfiguration() -> Ubiquitty.Preferences.Values {
        var configuration = Ubiquitty.Preferences.Values()
        configuration.emojiFallbackFont = .init(std.string(emojiFallbackFamily))
        configuration.shouldMatchFallbackSize = .init(shouldMatchFallbackSize)
        for rule in languageFallbacks {
            var entry = Ubiquitty.Preferences.LanguageFallbackEntry()
            entry.script = std.string(rule.script)
            entry.language = std.string(rule.language)
            entry.mode = std.string(rule.mode)
            entry.family = std.string(rule.family)
            configuration.languageFallbacks.push_back(entry)
        }
        for rule in rangeMaps {
            var entry = Ubiquitty.Preferences.RangeMapEntry()
            entry.firstCodePoint = rule.firstCodePoint
            entry.lastCodePoint = rule.lastCodePoint
            if let shouldMatchSize = rule.shouldMatchSize { entry.shouldMatchSize = .init(shouldMatchSize) }
            entry.mode = std.string(rule.mode)
            entry.family = std.string(rule.family)
            configuration.rangeMap.push_back(entry)
        }
        return configuration
    }

    /// The wide-glyph optical multiplier, at most 1 for none.
    public var wideGlyphBoostCap: Double
    /// The bitmap family's upscale, zero when Core does not rasterise it.
    public var unifontScale: Int
    /// The configured CJK family, or empty.
    public var cjkFallbackFamily: String
    /// The Han disambiguation tag, or empty.
    public var cjkFallbackLanguage: String
    /// The symbol family, or empty.
    public var symbolFamilyName: String
    /// The bundled symbol font's path, or empty.
    public var symbolFontPath: String
    /// The probe's features, in Core's grammar.
    public var ligatureFeatureSpec: String
    /// The probe's verdict: whether the face is able to ligate at all.
    public var canLigate: Bool
    /// Extra leading in points, folded into the cell's splittable gap.
    ///
    /// A measurement fact, not a placement scalar: the spacing moves the cell
    /// height and with it the slot the sheets are cut to, so it rides the
    /// sheet key through the geometry rather than beside it.
    public var lineSpacingInPoints: Double
    /// Points added to the layout pitch, negative to tighten.
    ///
    /// The horizontal twin of `lineSpacingInPoints`: the cell widens around
    /// ink the face drew at one size, so nothing scales and nothing clips.
    public var characterSpacingInPoints: Double
    /// The `wght` axis upright text is drawn at, or zero for the face's own.
    ///
    /// Zero is the absence of a setting rather than a weight: a face whose
    /// upright instance is not 400 would be moved by a number, and a face with
    /// no `wght` axis cannot honour one.
    public var fontWeight: Int
    /// The `wght` axis bold text is drawn at, or zero for the face's own bold.
    public var boldFontWeight: Int
    /// The width percent text is drawn at, or zero for the face's own.
    ///
    /// A width redraws the letterforms — a family's SemiWide members or its
    /// `wdth` axis — where the character spacing only moves the pitch; the
    /// two compose.
    public var fontWidthPercent: Double
    /// The user's `font.variations` axes, in Core's grammar, or empty.
    ///
    /// A tag named here beats the axis a named setting derives, except
    /// `wght` on the bold face; the fold is Core's, shared with the other
    /// shell.
    public var fontVariationSpec: String
    /// The user's baseline nudge, in points.
    public var baselineOffsetInPoints: Double
    /// Whether the cell rounds to whole points and the baseline to whole
    /// pixels, trading exact metrics for rules that land on a pixel rather
    /// than across two.
    public var shouldSnapLineHeight: Bool
    /// The family proportional runs are set in, or empty for the platform's
    /// UI face.
    public var proportionalFamilyName: String
    /// The em size proportional runs are set at, or zero for one optical
    /// step over the grid's. Configured beside ``gridPointSize``: a zoom that
    /// moves the grid moves this by the same ratio.
    public var proportionalPointSize: Double
    /// The grid's configured em size, the one the proportional size was set
    /// beside; zero leaves the proportional size as configured at every zoom.
    public var gridPointSize: Double
    /// Builds a configuration, defaulting every field to "none".
    ///
    /// Spelled out rather than left to the memberwise initialiser, which is
    /// internal on a public struct: a host outside this module could name the
    /// type and not construct one.
    ///
    /// - Parameters:
    ///   - wideGlyphBoostCap: The wide-glyph optical multiplier.
    ///   - unifontScale: The bitmap family's upscale.
    ///   - cjkFallbackFamily: The CJK family to route Han to.
    ///   - cjkFallbackLanguage: The Han disambiguation tag.
    ///   - symbolFamilyName: The family symbols route to.
    ///   - symbolFontPath: The symbol font's path on disk.
    ///   - ligatureFeatureSpec: The feature spelling, in Core's grammar.
    ///   - canLigate: Whether the face is able to ligate at all.
    ///   - lineSpacingInPoints: Extra leading folded into the cell.
    ///   - characterSpacingInPoints: Tracking folded into the layout pitch.
    ///   - fontWeight: The upright `wght` axis, or zero for the face's own.
    ///   - boldFontWeight: The bold `wght` axis, or zero for the face's own.
    ///   - fontWidthPercent: The width percent, or zero for the face's own.
    ///   - fontVariationSpec: The user's variation axes, or empty for none.
    ///   - baselineOffsetInPoints: The user's baseline nudge.
    ///   - shouldSnapLineHeight: Whether the cell and baseline round to whole
    ///     units. True by default: a default of false would move every rule
    ///     the moment a host stopped passing it.
    ///   - proportionalFamilyName: The proportional face's family, or empty
    ///     for the platform's UI face.
    ///   - proportionalPointSize: The proportional face's em size, or zero
    ///     for one optical step over the grid's.
    ///   - gridPointSize: The grid's configured em size the proportional size
    ///     was set beside, or zero to keep that size at every zoom.
    public init(
        wideGlyphBoostCap: Double = 0,
        unifontScale: Int = 0,
        cjkFallbackFamily: String = "",
        cjkFallbackLanguage: String = "",
        symbolFamilyName: String = "",
        symbolFontPath: String = "",
        ligatureFeatureSpec: String = "",
        canLigate: Bool = false,
        lineSpacingInPoints: Double = 0,
        characterSpacingInPoints: Double = 0,
        fontWeight: Int = 0,
        boldFontWeight: Int = 0,
        fontWidthPercent: Double = 0,
        fontVariationSpec: String = "",
        baselineOffsetInPoints: Double = 0,
        shouldSnapLineHeight: Bool = true,
        proportionalFamilyName: String = "",
        proportionalPointSize: Double = 0,
        gridPointSize: Double = 0
    ) {
        self.wideGlyphBoostCap = wideGlyphBoostCap
        self.unifontScale = unifontScale
        self.cjkFallbackFamily = cjkFallbackFamily
        self.cjkFallbackLanguage = cjkFallbackLanguage
        self.symbolFamilyName = symbolFamilyName
        self.symbolFontPath = symbolFontPath
        self.ligatureFeatureSpec = ligatureFeatureSpec
        self.canLigate = canLigate
        self.lineSpacingInPoints = lineSpacingInPoints
        self.characterSpacingInPoints = characterSpacingInPoints
        self.fontWeight = fontWeight
        self.boldFontWeight = boldFontWeight
        self.fontWidthPercent = fontWidthPercent
        self.fontVariationSpec = fontVariationSpec
        self.baselineOffsetInPoints = baselineOffsetInPoints
        self.shouldSnapLineHeight = shouldSnapLineHeight
        self.proportionalFamilyName = proportionalFamilyName
        self.proportionalPointSize = proportionalPointSize
        self.gridPointSize = gridPointSize
    }
}

/// The frame styling a host chooses: pen policy, underline rules, blend
/// gammas, and the default background the letterbox and empty cells paint.
///
/// The defaults are plain literals — opaque black background, identity gammas,
/// plain underline rules — so a host need set none of them. Unlike
/// ``SurfaceTypography`` this cuts no sheets: a change takes effect on the
/// next frame without a rebuild, which is what lets a theme switch land live.
///
/// The default background is spelled as components rather than a vector so
/// the value stays hashable without reaching into the render types; the
/// frame assembly packs it once per frame.
public struct SurfaceStyle: Hashable, Sendable {
    /// Whether SGR bold also brightens the base palette colours.
    public var shouldBrightenBold: Bool
    /// Whether braille draws as the renderer's 2x4 dot lattice rather than
    /// from the face.
    public var shouldDrawBrailleGrid: Bool
    /// The procedural dot style, defaulting to Core's factory setting.
    public var brailleStyle: BrailleStyle = .regular
    /// How the shade glyphs draw, defaulting to Core's factory setting.
    public var shadeStyle: ShadeStyle = .pattern
    /// Where a selection's colour is drawn, defaulting to Core's factory setting.
    public var selectionStyle: SelectionStyle = .native
    /// Native-size cursor following is opt-in; it never resizes the host grid.
    public var nonOwnerPresentation: RemoteViewportPresentation = .letterbox
    /// The default foreground's opacity, 0–255.
    public var defaultForegroundAlpha: UInt8
    /// The user's multiplier on the face's underline thickness.
    public var underlineThicknessScale: Double
    /// The user's `underline_offset`, in points.
    public var underlineOffsetInPoints: Double
    /// Whether a rule breaks around descender ink.
    public var shouldUnderlineSkipInk: Bool
    /// Whether a run's outer rule reaches the letter's ink past the cell.
    public var shouldUnderlineFollowInk: Bool
    /// The dilation around crossing ink, in points.
    public var underlineSkipInkPaddingInPoints: Double
    /// The whole-pass cell-background alpha, 0–1.
    public var backgroundOpacity: Double
    /// A host's override for the terminal default background's red, sRGB 0–1,
    /// or nil to take the palette's.
    ///
    /// Optional because the palette is the answer almost every frame: it is
    /// what the theme moves, and what the letterbox and every
    /// default-background cell should paint. A non-optional field defaulting
    /// to zero is a colour nobody chose that every frame then paints, and a
    /// window then draws a dark frame around a light theme.
    public var defaultBackgroundRed: Double?
    /// The green half of that override, or nil for the palette's.
    public var defaultBackgroundGreen: Double?
    /// The blue half of that override, or nil for the palette's.
    public var defaultBackgroundBlue: Double?
    /// The opacity applied only where a cell's background is the default,
    /// 0–1, so SGR-coloured cells stay solid over a translucent window.
    public var defaultBackgroundOpacity: Double
    /// Applies a perceptual contrast floor to ordinary text against its cell background.
    public var shouldEnhanceTextContrast: Bool = false
    /// Requests a native text plane inside the host's visual effect material.
    public var usesTextVibrancy: Bool = false
    public var preservesBackgroundTints: Bool = false // bool-ok: predicate describing whether explicit background ramps survive zero theme opacity
    public var usesBackgroundVibrancy: Bool = false
    public var promptMarkInk: SIMD4<Float> = .zero
    public var vibrantPromptMarkInk: SIMD4<Float> = .zero
    /// Whether OSC 8 / regex link cells take an underline of their own.
    public var shouldUnderlineLinks: Bool
    /// The user's `link_style`, stored as an index; zero means solid. Which
    /// scheme reads dotted or dashed stays Core's.
    public var linkStyleIndex: Int
    /// Whether file and mailto links take their own underline styles. Which
    /// scheme reads dotted or dashed stays Core's.
    public var shouldStyleLinksPerKind: Bool = false
    /// Link foreground red, sRGB 0–1.
    public var linkColorRed: Double
    /// Link foreground green, sRGB 0–1.
    public var linkColorGreen: Double
    /// Link foreground blue, sRGB 0–1.
    public var linkColorBlue: Double
    /// Link foreground opacity, 0–1.
    public var linkColorAlpha: Double
    /// Hovered-link foreground red, sRGB 0–1.
    public var linkHoverColorRed: Double
    /// Hovered-link foreground green, sRGB 0–1.
    public var linkHoverColorGreen: Double
    /// Hovered-link foreground blue, sRGB 0–1.
    public var linkHoverColorBlue: Double
    /// Hovered-link foreground opacity, 0–1.
    public var linkHoverColorAlpha: Double
    /// The window padding around the grid, in points. The letterbox outside
    /// it paints the default background, and the grid fit subtracts it.
    public var paddingLeftPoints: Double = 0
    public var paddingRightPoints: Double = 0
    public var paddingTopPoints: Double = 0
    public var paddingBottomPoints: Double = 0
    /// Extra top inset a host reserves above the grid, beyond the padding.
    public var extraTopInsetPoints: Double = 0
    /// Whether the glyph under a block cursor takes the contrasting
    /// grey rather than keeping its own colour.
    public var shouldCursorInvertText: Bool = true
    /// Whether the layer is tagged Display P3 rather than sRGB.
    ///
    /// The tag decides how the window server colour-matches the frame. Left
    /// nil, a CAMetalLayer is shown without matching — in the panel's own
    /// gamut — so on a wide-gamut display every colour the theme named in sRGB
    /// came out more saturated than the same colour in any AppKit window. The
    /// config's `color_space` selects which space the 8-bit values are read in.
    public var usesDisplayP3: Bool = false

    /// Builds a styling, defaulting every field to the path's old literals.
    ///
    /// Spelled out rather than left to the memberwise initialiser, which is
    /// internal on a public struct: a host outside this module could name the
    /// type and not construct one.
    ///
    /// - Parameters:
    ///   - shouldBrightenBold: Whether SGR bold also brightens.
    ///   - defaultForegroundAlpha: The default foreground's opacity.
    ///   - underlineThicknessScale: The multiplier on rule thickness.
    ///   - underlineOffsetInPoints: The user's underline offset.
    ///   - shouldUnderlineSkipInk: Whether rules break around ink.
    ///   - underlineSkipInkPaddingInPoints: The dilation around crossing ink.
    ///   - backgroundOpacity: The whole-pass cell-background alpha.
    ///   - defaultBackgroundRed: An override for the default background's red,
    ///     or nil to take the palette's.
    ///   - defaultBackgroundGreen: Likewise for green.
    ///   - defaultBackgroundBlue: Likewise for blue.
    ///   - defaultBackgroundOpacity: The default-background-only opacity.
    ///   - shouldUnderlineLinks: Whether link cells take an underline.
    ///   - linkStyleIndex: The user's `link_style`, as an index; zero is solid.
    ///   - linkColorRed: The link foreground's red, sRGB 0–1.
    ///   - linkColorGreen: The link foreground's green, sRGB 0–1.
    ///   - linkColorBlue: The link foreground's blue, sRGB 0–1.
    ///   - linkColorAlpha: The link foreground's opacity, 0–1.
    ///   - linkHoverColorRed: The hovered-link foreground's red, sRGB 0–1.
    ///   - linkHoverColorGreen: The hovered-link foreground's green, sRGB 0–1.
    ///   - linkHoverColorBlue: The hovered-link foreground's blue, sRGB 0–1.
    ///   - linkHoverColorAlpha: The hovered-link foreground's opacity, 0–1.
    public init(
        shouldBrightenBold: Bool = true,
        shouldDrawBrailleGrid: Bool = true,
        defaultForegroundAlpha: UInt8 = 255,
        underlineThicknessScale: Double = 1,
        underlineOffsetInPoints: Double = 0,
        shouldUnderlineSkipInk: Bool = true,
        shouldUnderlineFollowInk: Bool = true,
        underlineSkipInkPaddingInPoints: Double = 0,
        backgroundOpacity: Double = 1,
        defaultBackgroundRed: Double? = nil,
        defaultBackgroundGreen: Double? = nil,
        defaultBackgroundBlue: Double? = nil,
        defaultBackgroundOpacity: Double = 1,
        shouldUnderlineLinks: Bool = false,
        linkStyleIndex: Int = 0,
        linkColorRed: Double = 0,
        linkColorGreen: Double = 0,
        linkColorBlue: Double = 0,
        linkColorAlpha: Double = 1,
        linkHoverColorRed: Double = 0,
        linkHoverColorGreen: Double = 0,
        linkHoverColorBlue: Double = 0,
        linkHoverColorAlpha: Double = 1
    ) {
        self.shouldBrightenBold = shouldBrightenBold
        self.shouldDrawBrailleGrid = shouldDrawBrailleGrid
        self.defaultForegroundAlpha = defaultForegroundAlpha
        self.underlineThicknessScale = underlineThicknessScale
        self.underlineOffsetInPoints = underlineOffsetInPoints
        self.shouldUnderlineSkipInk = shouldUnderlineSkipInk
        self.shouldUnderlineFollowInk = shouldUnderlineFollowInk
        self.underlineSkipInkPaddingInPoints = underlineSkipInkPaddingInPoints
        self.backgroundOpacity = backgroundOpacity
        self.defaultBackgroundRed = defaultBackgroundRed
        self.defaultBackgroundGreen = defaultBackgroundGreen
        self.defaultBackgroundBlue = defaultBackgroundBlue
        self.defaultBackgroundOpacity = defaultBackgroundOpacity
        self.shouldUnderlineLinks = shouldUnderlineLinks
        self.linkStyleIndex = linkStyleIndex
        self.linkColorRed = linkColorRed
        self.linkColorGreen = linkColorGreen
        self.linkColorBlue = linkColorBlue
        self.linkColorAlpha = linkColorAlpha
        self.linkHoverColorRed = linkHoverColorRed
        self.linkHoverColorGreen = linkHoverColorGreen
        self.linkHoverColorBlue = linkHoverColorBlue
        self.linkHoverColorAlpha = linkHoverColorAlpha
    }
}

extension SurfaceStyle {
    /// Returns the frame styling the process configuration names.
    ///
    /// What the shared renderer factory draws under unless a shell passes its
    /// own, so a pane, a snapshot and a smoke built without a window's facts
    /// still draw the configured terminal rather than the neutral defaults.
    /// Read from Core's fold of the live document, like every other host.
    ///
    /// - Returns: The styling a frame draws under now.
    public static func configured() -> SurfaceStyle {
        SurfaceStyle(configuration: Ubiquitty.Preferences.Effective.liveRenderConfiguration(), systemTransparency: .Allowed)
    }
}

/// Draws terminal surfaces through the Swift renderer, one font configuration
/// per instance.
///
/// The measurement, the sheets and the passes are the same ones the app's own
/// panes render with; a host embedding a ``TerminalSurface`` supplies this and
/// gets the shipping frame path rather than a second one.
@MainActor
final class SurfaceRenderer: TerminalSurfaceRenderer {
    /// Whether glyph placement uses the atlas's subpixel phases.
    var shouldUseSubpixelGlyphs = true

    /// The text baseline below the top of a cell, in points.
    var baselineFromTopInPoints: Double {
        current.font.cellHeightInPoints
            - (current.font.baselinePenInPixels - Double(current.font.geometry.glyphMarginInPixels.height)) / current.font.atlasScale
    }

    /// GPU wall and execution times from the most recent offscreen commit.
    private(set) var offscreenGPUSeconds = 0.0
    private(set) var offscreenGPUExecutionSeconds = 0.0

    /// One font configuration measured for one backing scale, and the recipe a
    /// view's renderer is cut from.
    ///
    /// The measurement and the metrics travel together because the second is
    /// read off the first: sheets cut for one scale beside metrics resolved for
    /// another place every glyph and every rule against different geometry.
    ///
    /// No renderer. A `TerminalRenderer` is one per view by its own declaration
    /// — the retained grid, the instance streams, the capture and the cursor
    /// animator are all this view's — so this holds what one is BUILT from and
    /// the surfaces hold the renderers. `sheetKey` is what keeps that cheap:
    /// every renderer cut from one recipe resolves to the same registry entry,
    /// so the glyph sheets are rasterised once between them.
    /// Moves with every adopt, so a surface can tell a renderer cut from the
    /// build before it from one cut from this one.
    private(set) var buildGeneration = 0

    private struct ScaledBuild {
        let font: FontGeometry
        let metrics: Ubiquitty.Rendering.CellMetrics
        let slotCapacity: Int
        /// The probed ligature features, which the strip font layers over the
        /// faces; measured once per build because the classification shapes a
        /// few dozen probes.
        let stripFeatureSpec: String
        /// Whether the face ligates and the reader wants it to.
        let doesLigate: Bool
        let sheetKey: String
    }

    /// The device this renderer draws with.
    ///
    /// Read by a host decoding a texture for it — a backdrop must be made on
    /// the device that will sample it.
    package let device: MTLDevice
    private let library: MTLLibrary
    private let pixelFormat: MTLPixelFormat
    /// Font changes replace atlases, but the device and drawable format keep their pipelines.
    private lazy var pipelines = MetalPipelines(device: device, pixelFormat: pixelFormat, library: library)
    /// The font family glyphs are drawn from.
    ///
    /// Replaceable for the same reason the size is: a reader changes the family
    /// in Settings, and an application asks for one with OSC 50, both while the
    /// window is open. Held rather than derived so a size-only change re-cuts
    /// the sheets for the face already in use.
    private(set) var familyName: String
    /// The font's em size in points. Replaceable for the same reason the
    /// typography is: a window's zoom is a size the reader changes while the
    /// window is open.
    private(set) var pointSize: Double
    /// The rest of the font configuration. Replaceable, because a setting a
    /// window was opened with is a setting the reader can change while it is
    /// open — and a renderer that only reads it at construction leaves every
    /// live window showing the configuration of the moment it was spawned.
    private(set) var typography: SurfaceTypography

    /// The frame styling every surface this renderer draws is styled by.
    ///
    /// A stored value read at each frame's assembly, so a host changes it and
    /// the next frame carries it — no sheet is keyed on any of its fields.
    var style: SurfaceStyle

    /// The cursor opacity the frame most recently assembled was handed.
    ///
    /// What the assembly was given rather than what the preference says: a
    /// caller asking whether a reader's translucent cursor reached the frame
    /// wants the number the frame carried, and a renderer that resolved one
    /// the capture never used would answer differently.
    package private(set) var lastFrameCursorAlpha: Float = 1

    /// The blink weight the frame most recently assembled handed the cursor.
    ///
    /// The phase Core resolved for the frame's tick, as the overlay tier
    /// receives it, so a blink can be observed on a target that cannot show
    /// the overlay's pixels.
    package private(set) var lastFrameCursorMixAlpha: Float = 1

    /// The flash strength the frame most recently assembled carried.
    ///
    /// The drawn value rather than the intended one: a caller asking whether
    /// the reader saw a flash wants what the assembly was handed, and a
    /// surface that resolved an alpha the capture never used would answer
    /// differently.
    package private(set) var lastFrameBellFlashAlpha: Float = 0

    /// The storage tube's settings, read at each Tek frame's assembly like
    /// ``style`` is at a grid frame's. The defaults are theme colours, the
    /// writing spot drawn, no glow — what an unconfigured host gets.
    public var tekSettings = SurfaceTekSettings()

    /// The pending backdrop for the next frame, held as framework values:
    /// this type cannot name the encoder's Backdrop, so it carries the parts
    /// and hands them to the frame renderer, which can.
    private var backdropTexture: (any MTLTexture)?
    private var backdropOpacity = 0.0
    private var backdropMode: Int32 = 0
    private var backdropPixelWidth: Int32 = 0
    private var backdropPixelHeight: Int32 = 0

    /// Hands this surface a decoded backdrop image, or clears it with nil.
    /// Whether a backdrop is installed, for a caller checking that the
    /// configured picture actually reached this renderer.
    package var isShowingBackdrop: Bool { backdropTexture != nil }

    public func setBackdrop(texture: (any MTLTexture)?, opacity: Double, mode: Int32, pixelWidth: Int32, pixelHeight: Int32) {
        backdropTexture = texture
        backdropOpacity = opacity
        backdropMode = mode
        backdropPixelWidth = pixelWidth
        backdropPixelHeight = pixelHeight
    }

    /// What each frame renderer's retained target was last drawn under.
    ///
    /// The damage drain tracks cell writes, and a restyle or a palette apply
    /// repaints every pixel while writing no cell — so the reuse verdict alone
    /// would Load a target whose clean rows still wear the replaced styling.
    /// A frame whose stamp differs plans as if the target were the wrong size:
    /// full rebuild, nothing Loaded.
    private struct RetainedStamp: Equatable {
        let style: SurfaceStyle
        let contentEpoch: Int
        let origin: CGPoint
        let paletteEpoch: UInt64
        /// Whether the frame was drawn edge to edge. A retained texture drawn
        /// at the padded origin describes no pixel of a frame drawn at zero,
        /// and the mode writes no cell, so nothing else would refuse it.
        let isEdgeToEdge: Bool
    }

    /// The tick the last frame's options carried, for the smoke: the fill
    /// crosses two seams before any capture a test can read, and this is the
    /// value the options really got rather than the one somebody meant.
    package private(set) var lastFrameBlinkTicks: UInt32 = 0
    /// Whether the focused search match's pill was mid-bounce on the last
    /// live frame, read off the frame renderer's capture.
    package private(set) var isFocusedMatchBouncing = false

    /// Whether UBIQUITTY_PHASE_LOG asked for the per-frame phase-input line.
    ///
    /// Read once: an environment lookup per frame is a dictionary hit on the
    /// hot path for a switch nobody flips mid-run.
    static let isPhaseLogEnabled = ProcessInfo.processInfo.environment["UBIQUITTY_PHASE_LOG"] != nil
    /// Whether DECSET 7402's opaque letterbox may skip the damage drain and
    /// the grid copy. UBIQUITTY_NO_OCCLUSION_SKIP keeps the full path for a
    /// pixel-parity A/B; read once at launch.
    static let isOcclusionSkipEnabled = ProcessInfo.processInfo.environment["UBIQUITTY_NO_OCCLUSION_SKIP"] == nil
    /// Live frames that skipped the drain and the copy, for a scenario
    /// checking the skip happened rather than inferring it from timing.
    private(set) var gridCaptureSkipCount = 0
    /// Live frames whose capture re-read every row rather than the dirty
    /// ones: the first frame after a skip is one, and a scenario reading the
    /// last frame's census alone misses it when a settled frame follows.
    private(set) var gridFullRereadCount = 0
    /// Whether UBIQUITTY_PERFLOG asked for the per-step resize cost split;
    /// read once at launch.
    static let isPerflogEnabled = ProcessInfo.processInfo.environment["UBIQUITTY_PERFLOG"] != nil
    /// Arms the present handler without the perflog, for a scenario that
    /// reads the slip accounting off a Swift surface.
    package static var shouldArmPresentSlipForTesting = false
    /// Whether presents arm the slip accounting's presented handler.
    ///
    /// The handler is a per-frame heap allocation, which a release frame does
    /// not pay for a number nobody reads, so only the perflog or a scenario
    /// asks for it. While this is false ``presentSlip`` counts nothing, and a
    /// reader shows its slips as unmeasured rather than as a clean zero.
    static var isPresentSlipArmed: Bool {
        PresentSlipAccounting.canMeasurePresents && (isPerflogEnabled || shouldArmPresentSlipForTesting)
    }

    /// The presents that latched a vsync late — the Kit's shared
    /// component. Fed by the presented handler this renderer arms under
    /// the perflog, and by the clock's refresh period.
    package let presentSlip = PresentSlipAccounting()

    /// The slip field of the UBIQUITTY_PHASE_LOG line: the refreshes presents
    /// have latched late by, or `unmeasured` while no handler counts them.
    var phaseLogSlipField: String {
        Self.isPresentSlipArmed ? "slip=\(presentSlip.slippedVsyncs)" : "slip=unmeasured"
    }

    /// The UBIQUITTY_PERFLOG aggregator every surface feeds — Core's.
    /// One per process: the log reads the process's frames, not one window's.
    static var framePerfLog = Ubiquitty.Diagnostics.FramePerfLog()

    /// The felt-latency present leg of the frames this renderer presents,
    /// armed while the perf log is on.
    var presentLeg = Ubiquitty.Runtime.PresentLegMeter()
    private let deliveryTrace: FrameDeliveryTrace? =
        ProcessInfo.processInfo.environment["UBIQUITTY_TRACE_FRAME_LINK"] == "1"
        ? FrameDeliveryTrace() : nil

    package var frameDeliverySummary: String {
        "glassSkips=\(skippedAsReproducingGlassCount) " + (deliveryTrace?.summary ?? "")
    }
    /// Frames the phase log has stamped, so its lines order without timestamps.
    private var phaseLogFrameCount = 0

    /// The stamps, keyed by frame-renderer identity — the object that owns
    /// the retained target the stamp describes.
    private var retainedStamps: [ObjectIdentifier: RetainedStamp] = [:]

    /// The measured builds, keyed by ``scaleKey(_:)``.
    ///
    /// Populated by the scales surfaces have been shown at, so it holds one
    /// entry per distinct backing scale among the displays in use.
    private var builds: [Int: ScaledBuild]

    /// The build the next frame draws from.
    private var current: ScaledBuild

    /// Whether the frames this renderer draws are the bitmap tier.
    ///
    /// The tier is Core's routing verdict for the configured family, carried
    /// by the typography or, when the host named none, by the face; a headless
    /// export asks it to declare its bytes straight rather than premultiplied.
    package var isBitmapTier: Bool {
        (typography.unifontScale > 0 ? typography.unifontScale : current.font.unifontScale) > 0
    }

    /// The regular face's family after CoreText resolves the configured font.
    package var resolvedFontFamily: String {
        CTFontCopyFamilyName(current.font.faces[bold: false, italic: false]) as String
    }

    /// The backing scale the last encoded frame resolved its geometry against.
    ///
    /// Reported because nothing downstream can be asked: the frame's scale
    /// reaches Core inside an options block and leaves as pixels, so a harness
    /// comparing it to the layer's own scale is the only way to observe that the
    /// two agree. Zero before the first frame.
    private(set) var lastFrameDeviceScale: Double = 0

    /// The scale the faces the last encoded frame drew from were cut at.
    ///
    /// Separate from ``lastFrameDeviceScale`` because the two are separate
    /// facts: geometry that follows the display still draws a 2.0 raster until
    /// the faces are remeasured, and only a reader holding both can tell a
    /// remeasured frame from a resampled one. Zero before the first frame.
    private(set) var lastFrameAtlasScale: Double = 0

    /// Whether the last encoded live frame Loaded its retained target.
    ///
    /// Reported because a partial frame is indistinguishable from a full one by
    /// looking at it — that is the property, the pixels are meant to match — so
    /// the only way to observe that the reuse path runs at all is to ask. False
    /// before the first frame, and for a frame that took the boundary-capture
    /// route, which carries no plan.
    /// How many more frames report their retained plan.
    ///
    /// A font change that repaints nothing and a font change that repaints
    /// wrongly look identical from outside the process, and the frame after an
    /// adopt is the one that separates them: it has to paint every row, since
    /// the cells did not change and the faces did.
    var framesToReportAfterAdopt = 0

    private(set) var didReuseLastFrame = false

    /// How many rows the last plan marked dirty, of how many it walked.
    ///
    /// Beside the verdict because the verdict alone cannot tell a steady frame
    /// from a rebuilt one: a plan may Load the target and still mark every row,
    /// which is correct and buys nothing. Zero before the first frame.
    private(set) var lastFrameDirtyRows = 0
    private(set) var lastFramePlannedRows = 0

    /// Whether the last frame's builder was allowed to re-read only the rows
    /// in the dirty set.
    ///
    /// The other half of the retained verdict, and the half an oracle needs:
    /// the row census says how many rows were marked, not whether the build
    /// was permitted to skip the rest. Trusting the set on a frame that did
    /// not Load the retained target draws the marked rows onto a texture about
    /// to be cleared, which is the vanishing text; the pair is the claim, and
    /// neither number alone can state it.
    private(set) var didTrustDirtySetLastFrame = false

    /// Frames whose encode refused a retained target the plan had trusted.
    ///
    /// The pair above reads Core's plan, and the encode is what can overrule
    /// it: the cell the retained pixels sit on is a fact the plan is handed
    /// rather than one it derives, so a caller asking with the wrong one gets a
    /// capture built to skip the clean rows and an encode that clears them. By
    /// the time this counts, the rows were never read and the frame cannot be
    /// repaired — an oracle asserts it stays at zero.
    private(set) var cellRefusalsAfterTrust = 0

    /// Returns the shaping work and retention of this surface's live atlas.
    package func shapingStatisticsForTesting(for surface: TerminalSurface) -> (lines: Int, segments: Int)? {
        frameRenderer(for: surface)?.measuringAtlas.shapingStatisticsForTesting
    }

    /// The em size proportional runs are set at by the atlas this surface draws with.
    package func proportionalPointSizeForTesting(for surface: TerminalSurface) -> Double? {
        frameRenderer(for: surface)?.measuringAtlas.proportionalPointSizeForTesting
    }

    /// Returns the fallback face from the atlas this surface draws with.
    package func routedFamilyForTesting(_ codePoint: UInt32, for surface: TerminalSurface) -> String? {
        frameRenderer(for: surface)?.measuringAtlas.routedFamilyForTesting(codePoint)
    }

    /// The atlas slot geometry the surface's frame renderer draws with; see
    /// `TerminalSurface.glyphSlotForTesting`.
    package func glyphSlotForTesting(for surface: TerminalSurface) -> Ubiquitty.Rendering.GlyphSlotGeometry? {
        frameRenderer(for: surface)?.atlasSlotGeometry
    }

    /// Returns the cursor handed to the builder after presentation filtering.
    package func drawnCursorForTesting(for surface: TerminalSurface) -> (row: Int, column: Int, mixAlpha: Float)? {
        frameRenderer(for: surface)?.drawnCursorForTesting
    }

    /// Pins cursor presentation time while the smoke walks synthetic redraws.
    package var cursorPresentationTimeForTesting: Double?

    /// Returns the history offset captured by the surface's last frame.
    package func lastCapturedViewOffsetForTesting(for surface: TerminalSurface) -> Int? {
        frameRenderer(for: surface)?.lastCapturedViewOffsetForTesting
    }

    /// The foreground alpha the last frame's cell instance at a cell drew
    /// with, or nil without one; see `TerminalSurface.drawnForegroundAlphaForTesting`.
    package func drawnForegroundAlphaForTesting(for surface: TerminalSurface, row: Int, column: Int) -> Float? {
        frameRenderer(for: surface)?.cellForegroundAlphaForTesting(row: row, column: column)
    }

    /// Reads the live native background without invalidating its retained frame.
    package func nativeBackgroundPixelsForTesting(for surface: TerminalSurface) -> Data? {
        frameRenderer(for: surface)?.nativeBackgroundPixelsForTesting()
    }

    package func retainedGridPixelsForTesting(for surface: TerminalSurface) -> Data? {
        frameRenderer(for: surface)?.retainedGridPixelsForTesting()
    }

    /// Returns the live frame's native terminal mark ink.
    package func nativeTerminalMarkInkForTesting(for surface: TerminalSurface) -> SIMD4<Float>? {
        frameRenderer(for: surface)?.nativeTerminalMarkInkForTesting()
    }

    /// Overlay quads the surface's last frame drew in its padding gutters;
    /// see `TerminalSurface.gutterOverlayCountForTesting`.
    package func gutterOverlayCountForTesting(for surface: TerminalSurface) -> Int? {
        frameRenderer(for: surface)?.gutterOverlayCountForTesting()
    }

    /// The background alpha and colour the last frame was drawn with, off
    /// the capture's uniforms; nil before a frame renderer exists.
    package func drawnBackgroundForTesting(for surface: TerminalSurface) -> (alpha: Float, color: Ubiquitty.Rendering.Vec4)? {
        guard let renderer = frameRenderer(for: surface) else { return nil }
        let uniforms = renderer.lastCaptureUniformsForTesting
        return (uniforms.backgroundOpacity, uniforms.defaultBackground)
    }

    #if canImport(AppKit)
    /// The surface's frame as it stands, drawn into an offscreen target the
    /// size of its drawable and read back; see
    /// `TerminalSurface.renderedFrameForTesting`.
    ///
    /// The encode is the one the window presents, into a texture instead of a
    /// drawable. A frame built here spends the rows the next live frame is
    /// owed, so the retained frame is declared gone on both sides of it: the
    /// build before draws every row rather than reproducing glass this target
    /// never held, and the live frame after presents every row again.
    ///
    /// - Parameter surface: The surface to draw.
    /// - Returns: The target's size in device pixels and its BGRA rows, top
    ///   row first; nil while the layer has no size, for a drawable format of
    ///   other than four bytes a pixel, or when Metal refuses a stage.
    package func renderedFrameForTesting(for surface: TerminalSurface) -> (width: Int, height: Int, pixels: Data)? {
        let width = Int(surface.metalLayer.drawableSize.width)
        let height = Int(surface.metalLayer.drawableSize.height)
        guard width > 0, height > 0, pixelFormat == .bgra8Unorm_srgb || pixelFormat == .bgra8Unorm,
            let live = frameRenderer(for: surface)
        else {
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        // Read back, so not framebuffer-only, and managed so a blit can
        // synchronise it to host memory on a discrete device.
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        noteFrameNotPresented(for: surface, renderer: live)
        let didDraw = render(surface, into: texture, contentScale: Double(surface.metalLayer.contentsScale))
        if let after = frameRenderer(for: surface) {
            noteFrameNotPresented(for: surface, renderer: after)
        }
        surface.needsDisplay = true
        guard didDraw,
            let queue = device.makeCommandQueue(),
            let commands = queue.makeCommandBuffer(),
            let blit = commands.makeBlitCommandEncoder()
        else {
            return nil
        }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(
                base,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return (width, height, pixels)
    }
    #endif

    /// Every stream count the last live frame's builder emitted.
    ///
    /// The snapshot command reports them, so a frame that built nothing cannot
    /// pass for one that built the scene it was fed.
    private(set) var lastFrameCounts = Ubiquitty.Rendering.InstanceCounts()

    /// Cell instances the last live frame's builder emitted.
    ///
    /// What reached the screen, against what the frame was permitted to do. A
    /// frame that Loaded the retained target and drew two rows is a steady
    /// frame; one that drew two rows onto a target it did not get is a screen
    /// with two rows on it, and the verdict pair reads the same for both.
    var lastFrameDrawnCells: Int { Int(lastFrameCounts.cells) }

    /// Which terms of the last frame's retained-target verdict were false,
    /// assembled only under `UBIQUITTY_PHASE_LOG`.
    ///
    /// The verdict alone says a frame rebuilt without saying what asked it to,
    /// and the three that a reader can act on live on opposite sides of the
    /// seam: this arm's own refusal (a full-rebuild grant, a stale stamp, a
    /// grid that no longer matches the drawable) and Core's, which the plan
    /// reports. Empty while the frame reused.
    /// How the last frame was composed, as the phase log spells it: empty for a
    /// frame drawn whole, the reuse terms for one that loaded the target, and
    /// `skipped` for one that reproduced the glass and presented nothing.
    package private(set) var phaseLogReuseTerms = ""

    /// Frames handed to a drawable; an offscreen or a skipped frame is not one.
    package private(set) var presentedFrameCount = 0

    /// Passes that built nothing because the frame reproduced the glass.
    ///
    /// The one verdict that ends a pass without presenting and without asking
    /// again, so a reader watching a pane that never paints can tell this from
    /// a pass that was refused a drawable.
    package private(set) var skippedAsReproducingGlassCount = 0
    private var phaseLogRowSignature = ""

    /// The rows of the live grid as Core's one-line signature (see
    /// Core/Screen/RowSignature.h), the line every arm's phase log prints, so
    /// a resize census reads them with one rule. Phase log only.
    private static func rowSignature(of terminal: Ubiquitty.Terminal, rows: Int, columns: Int) -> String {
        String(Ubiquitty.Screen.rowSignature(terminal))
    }

    /// Whether the last live frame's options carried a status row — the
    /// smoke's oracle for the fill wiring, since the plan's reuse refusal
    /// reads the model directly and passes whether or not the cells arrived.
    private(set) var lastFrameHadStatusRow = false

    /// The grid origin the last live frame's options carried, in device pixels.
    ///
    /// Captured exactly as fed — unrounded — because the subpixel phase of
    /// every glyph is a function of its pen x, and the pen inherits this
    /// origin's fraction. A probe comparing consecutive frames' values is the
    /// oracle for spacing that shifts with no content cause: the quads stay on
    /// the pixel grid, so only these inputs can move the ink inside them.
    private(set) var lastFrameOriginXInPixels: Float = 0
    private(set) var lastFrameOriginYInPixels: Float = 0
    /// One cell's advance as the last frame's builder measured it, atlas pixels.
    private(set) var lastFrameCellWidthInAtlasPixels: Float = 0

    /// Whether the last frame drew the storage tube rather than the grid —
    /// the smoke's oracle for the Tek gate, whose pixels no headless arm
    /// compares.
    private(set) var didDrawTekFrame = false

    /// How many distinct scales have been measured.
    ///
    /// The scale a frame resolved against is the same either way, so this is
    /// what separates keeping the measurements from replacing them.
    var measuredScaleCount: Int { builds.count }

    /// The registry key the current build's sheets are shared under.
    ///
    /// Observable because the key is what decides SHARING: two renderers whose
    /// keys match are handed one set of glyph sheets. A field of the
    /// configuration the key omits is therefore not a cosmetic gap — it merges
    /// two configurations that draw differently, and nothing downstream can tell
    /// they were meant to be separate.
    var currentSheetKey: String { current.sheetKey }

    /// Builds the renderer for one font configuration.
    ///
    /// - Parameters:
    ///   - device: The device frames encode on.
    ///   - library: The compiled shader library.
    ///   - pixelFormat: The drawable format surfaces present in. sRGB, because
    ///     the shaders output linear coverage and the hardware does the encode
    ///     on write: against a plain `bgra8Unorm` target the same shader blends
    ///     glyph coverage in the wrong space, and text reads thinner and
    ///     differently weighted than the same face on the arm that pairs them.
    ///   - familyName: The font family glyphs are drawn from.
    ///   - pointSize: The font's em size in points.
    ///   - atlasScale: Atlas pixels per point for the first measurement; a
    ///     surface on a display of another scale measures its own. 2 is the
    ///     Retina raster the app's own panes use, and the scale the
    ///     two-renderer comparison certifies.
    ///   - typography: The rest of the font configuration. Its default is the
    ///     plainest build.
    ///   - style: The frame styling. Its default is plain literals, and unlike
    ///     the typography it may be replaced after construction.
    init?(
        device: MTLDevice,
        library: MTLLibrary,
        pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb,
        familyName: String,
        pointSize: Double,
        atlasScale: Double = 2.0,
        typography: SurfaceTypography = SurfaceTypography(),
        style: SurfaceStyle = SurfaceStyle()
    ) {
        guard
            let build = Self.measure(
                device: device,
                familyName: familyName,
                pointSize: pointSize,
                atlasScale: atlasScale,
                typography: typography
            )
        else {
            return nil
        }
        self.device = device
        self.library = library
        self.pixelFormat = pixelFormat
        self.familyName = familyName
        self.pointSize = pointSize
        self.typography = typography
        self.style = style
        self.current = build
        self.builds = [Self.scaleKey(atlasScale): build]
    }

    /// Adopts a new size and typography, discarding the builds measured
    /// under the old.
    ///
    /// The sheets are keyed by the configuration they were cut for, so a
    /// changed size or feature spelling has to drop them: kept, the window
    /// would draw the glyphs of the specification it opened with.
    ///
    /// - Parameters:
    ///   - pointSize: The font's em size in points.
    ///   - typography: The configuration to draw under.
    /// Redraws at a new em size, keeping the rest of the configuration.
    ///
    /// - Parameter pointSize: The em size to draw at.
    func adopt(pointSize: Double) {
        adopt(pointSize: pointSize, typography: typography)
    }

    func adopt(pointSize: Double, typography: SurfaceTypography) {
        _ = adopt(pointSize: pointSize, familyName: familyName, typography: typography)
    }

    /// Redraws at a new family, size and configuration.
    ///
    /// The general entry the two above delegate to. A family that cannot be
    /// measured leaves every field as it was and reports so, rather than
    /// leaving the renderer holding a name whose sheets it could not cut: the
    /// caller knows what to fall back to — the configured family, the house one
    /// — and the renderer does not.
    ///
    /// - Parameters:
    ///   - pointSize: The font's em size in points.
    ///   - familyName: The family to draw from.
    ///   - typography: The rest of the configuration to draw under.
    /// - Returns: Whether the configuration was adopted.
    @discardableResult
    func adopt(pointSize: Double, familyName: String, typography: SurfaceTypography) -> Bool {
        guard self.pointSize != pointSize || self.familyName != familyName || self.typography != typography
        else {
            return true
        }
        let scale = current.font.atlasScale
        guard
            let measured = Self.measure(
                device: device,
                familyName: familyName,
                pointSize: pointSize,
                atlasScale: scale,
                typography: typography
            )
        else {
            return false
        }
        self.pointSize = pointSize
        self.familyName = familyName
        self.typography = typography
        builds.removeAll()
        builds[Self.scaleKey(scale)] = measured
        current = measured
        // Every retained target was painted under the old sheets, so none of
        // them may be kept: a stamp left standing certifies a texture drawn
        // with glyphs this configuration no longer contains. The surfaces'
        // frame renderers were cut from the old build too — faces, sheets,
        // slot — and each is dropped on its next frame, where this
        // generation is compared: a renderer kept across an adopt draws the
        // old face at the old size into a grid the new metrics laid out.
        retainedStamps.removeAll()
        buildGeneration += 1
        if ProcessInfo.processInfo.environment["UBQ_FONTLOG"] != nil {
            framesToReportAfterAdopt = 2
        }
        return true
    }

    /// Measures the configuration at one scale.
    ///
    /// - Parameters:
    ///   - device: The device the sheets are keyed to.
    ///   - familyName: The font family glyphs are drawn from.
    ///   - pointSize: The font's em size in points.
    ///   - atlasScale: Atlas pixels per point.
    ///   - typography: The rest of the font configuration, every field of which
    ///     the key names — see ``SurfaceTypography``.
    /// - Returns: The build, or nil when the face refuses.
    private static func measure(
        device: MTLDevice,
        familyName: String,
        pointSize: Double,
        atlasScale: Double,
        typography: SurfaceTypography
    ) -> ScaledBuild? {
        guard
            let font = FontGeometry(
                familyName: familyName,
                pointSize: pointSize,
                atlasScale: atlasScale,
                maxTextureDimension: device.maximumTexture2DDimension,
                lineSpacingPoints: typography.lineSpacingInPoints,
                characterSpacingPoints: typography.characterSpacingInPoints,
                fontWeight: typography.fontWeight,
                boldFontWeight: typography.boldFontWeight,
                fontWidthPercent: typography.fontWidthPercent,
                featureSpec: typography.ligatureFeatureSpec,
                variationSpec: typography.fontVariationSpec,
                baselineOffsetPoints: typography.baselineOffsetInPoints,
                snapsLineHeight: typography.shouldSnapLineHeight,
                // The face the router adopts below, resolved the same way at
                // the atlas size: its box grows the slot, so a symbol family
                // change re-measures and re-cuts the sheet along with the
                // rest of the typography.
                symbolFallbackFace: FontRouter.symbolFallbackFace(
                    size: pointSize * atlasScale,
                    familyName: typography.symbolFamilyName,
                    fontPath: typography.symbolFontPath
                )
            )
        else {
            return nil
        }
        // Enough slots for every cell the largest screen can hold at this
        // size, which is the most one frame can reference at once. Below that
        // a sheet evicts a slot a live cell still samples, and the cell draws
        // whatever takes it next — the blanks, the wrong letters and the
        // doubled-sheet master at twice the size are all that one exhaustion.
        // The sheet clamps the grid to the device's texture limit afterwards,
        // so an unreachable size costs a smaller sheet rather than a refusal.
        // Points, not pixels: a window moves between displays, and a 1x
        // display of the same pixel extent holds twice the cells a 2x one
        // does. The cell's point size is what stays fixed across the move, so
        // counting in points gives one answer for every display; counting in
        // pixels would understate whichever display the atlas was not built
        // for. Each display is measured whole rather than a largest width
        // paired with a largest height, which no single display need have.
        // The widest display this machine has, for the atlas ceiling.
        //
        // macOS enumerates displays through CoreGraphics; iOS asks each
        // connected scene for the screen it is on, so each asks its own way
        // and the ceiling that comes out is the same fact.
        #if canImport(AppKit)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        let screenSizes = displays.prefix(Int(displayCount)).map { CGDisplayBounds($0).size }
        #else
        // A screen belongs to the scene showing it — UIScreen.main is
        // deprecated in iOS 26 — and a surface renders inside a scene's
        // window, so the list is never empty while a frame is drawn.
        let screenSizes = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }
        #endif
        let cell = resolveCellMetrics(font.metricsInputs)
        let cellInPoints = Ubiquitty.IntSize(
            width: Int32((Double(cell.cellWidth) / Double(atlasScale)).rounded(.up)),
            height: Int32((Double(cell.cellHeight) / Double(atlasScale)).rounded(.up))
        )
        var worstCase = 0
        var widestScreen = CGSize.zero
        for bounds in screenSizes {
            let cells = Int(
                Ubiquitty.Rendering.worstCaseGlyphSlotsForScreen(
                    Ubiquitty.IntSize(width: Int32(bounds.width), height: Int32(bounds.height)),
                    cellInPoints
                )
            )
            if cells > worstCase {
                worstCase = cells
                widestScreen = bounds
            }
        }
        // Core owns the rule, so the Vulkan atlas asks for the same shape from
        // its own screen rather than carrying a constant.
        let slotCapacity = Int(
            Ubiquitty.Rendering.glyphAtlasNominalCapacity(Int32(worstCase), font.geometry.columns)
        )
        if ProcessInfo.processInfo.environment["UBQ_PERFLOG"] != nil || ProcessInfo.processInfo.environment["UBIQUITTY_PERFLOG"] != nil {
            FileHandle.standardError.write(
                "[perf] atlas capacity=\(slotCapacity) worstCase=\(worstCase) screenPt=\(Int(widestScreen.width))x\(Int(widestScreen.height)) cellPt=\(cellInPoints.width)x\(cellInPoints.height)\n"
                    .data(using: .utf8)!
            )
        }
        // The classification runs on the face the strips will rasterise with
        // — user features already baked — and its verdict is what the sheets
        // shape under. The user's spec reached the faces above; feeding it to
        // the sheet as well would double-apply nothing, but feeding it alone
        // left Monaspace's stylistic-set ligatures off
        // while the other arm probed them on: one font, two feature sets,
        // caught by the first shared golden.
        let verdict = LigatureFeatureClassifier.classify(font.faces[bold: false, italic: false])
        // The reader's word beats the probe's: the two specs merge through
        // Core's one fold, where an override naming a probed tag wins — a
        // reader writing -ss19 turns a set the probe enabled back off. The
        // probed spec applied raw over the reader-featured faces re-enables
        // exactly what the reader disabled.
        let stripSpec = String(
            Ubiquitty.Rendering.serializeFontFeatureSettings(
                Ubiquitty.Rendering.mergeFontFeatureSettings(
                    Ubiquitty.Rendering.parseFontFeatureSpecification(std.string(verdict.featureSpec)),
                    Ubiquitty.Rendering.parseFontFeatureSpecification(std.string(typography.ligatureFeatureSpec))
                )
            )
        )
        let doesLigate = typography.canLigate && verdict.doesLigate
        guard
            let sheetKey = GlyphAtlas.sheetKey(
                device: device,
                familyName: familyName,
                pointSize: pointSize * atlasScale,
                pixelsPerPoint: atlasScale,
                geometry: font.geometry,
                slotCapacity: Int32(slotCapacity),
                baselinePenInPixels: font.baselinePenInPixels,
                wideGlyphBoostCap: typography.wideGlyphBoostCap,
                unifontScale: Int32(typography.unifontScale > 0 ? typography.unifontScale : font.unifontScale),
                cjkFallbackFamily: typography.cjkFallbackFamily,
                cjkFallbackLanguage: typography.cjkFallbackLanguage,
                symbolFamilyName: typography.symbolFamilyName,
                symbolFontPath: typography.symbolFontPath,
                ligatureFeatureSpec: stripSpec,
                userFeatureSpec: typography.ligatureFeatureSpec,
                userVariationSpec: typography.fontVariationSpec,
                fontWeight: Int32(typography.fontWeight),
                boldFontWeight: Int32(typography.boldFontWeight),
                fontWidthPercent: typography.fontWidthPercent,
                fontLigates: doesLigate,
                wantsLigatures: typography.canLigate,
                proportionalFamilyName: typography.proportionalFamilyName,
                proportionalPointSize: Ubiquitty.Preferences.Zoom.zoomedCompanionSize(
                    typography.gridPointSize,
                    pointSize,
                    typography.proportionalPointSize
                )
            )
        else {
            return nil
        }
        return ScaledBuild(
            font: font,
            metrics: resolveCellMetrics(font.metricsInputs),
            slotCapacity: slotCapacity,
            stripFeatureSpec: stripSpec,
            doesLigate: doesLigate,
            sheetKey: sheetKey + "|" + typography.routingKey
        )
    }

    /// The surface's own renderer for the current build, cut on first use.
    ///
    /// One per surface per scale, because a `TerminalRenderer` is one per view:
    /// the retained grid, its scroll partner, the instance streams, the capture,
    /// the Tek streams and the cursor animator are this view's. The animator is
    /// the one with cross-frame state and no size check to hide behind — it
    /// holds the in-flight slide, so a shared one is ticked toward each
    /// surface's cursor in turn and glides between two terminals.
    ///
    /// The sheets do not multiply with it. `sheetKey` is the same for every
    /// surface on one build, so `GlyphAtlas.shared(key:)` hands them all one
    /// registry entry and each glyph is rasterised once between them.
    ///
    /// - Parameter surface: The surface asking to draw.
    /// - Returns: Its renderer, or nil when Metal refuses one.
    /// Cuts the surface's frame renderer for the current build ahead of its
    /// first frame, which publishes the rich text table and adopts the
    /// proportional measurer.
    ///
    /// An offscreen snapshot cuts it before its feed, as a live pane has
    /// before its program runs, so a query in the feed (a block's fit or a
    /// proportional run's cells) is answered in the faces the frame draws.
    ///
    /// - Parameter surface: The surface the frame renderer draws.
    func prepareFrameRenderer(for surface: TerminalSurface) {
        _ = frameRenderer(for: surface)
    }

    private func frameRenderer(for surface: TerminalSurface) -> TerminalRenderer? {
        // A renderer cut from an earlier build is not this build's: after an
        // adopt every one the surface holds goes, whatever its scale, and
        // the one asked for is cut again from the current faces and sheets.
        if surface.frameRendererGeneration != buildGeneration {
            surface.frameRenderers.removeAll()
            surface.frameRendererGeneration = buildGeneration
        }
        let key = Self.scaleKey(current.font.atlasScale)
        if let existing = surface.frameRenderers[key] {
            return existing
        }
        let font = current.font
        guard
            let renderer = TerminalRenderer(
                device: device,
                pixelFormat: pixelFormat,
                pipelines: pipelines,
                faces: font.faces,
                geometry: font.geometry,
                slotCapacity: current.slotCapacity,
                baselinePenInPixels: font.baselinePenInPixels,
                wideGlyphBoostCap: typography.wideGlyphBoostCap,
                unifontScale: typography.unifontScale > 0 ? typography.unifontScale : font.unifontScale,
                router: FontRouter(
                    primary: font.faces,
                    cjkFamilyName: typography.cjkFallbackFamily,
                    cjkLanguage: typography.cjkFallbackLanguage,
                    symbolFamilyName: typography.symbolFamilyName,
                    symbolFontPath: typography.symbolFontPath,
                    configuration: typography.routingConfiguration()
                ),
                ligatureFeatureSpec: current.stripFeatureSpec,
                fontLigates: current.doesLigate,
                sheetKey: current.sheetKey,
                proportionalFamilyName: typography.proportionalFamilyName,
                proportionalPointSize: Ubiquitty.Preferences.Zoom.zoomedCompanionSize(
                    typography.gridPointSize,
                    pointSize,
                    typography.proportionalPointSize
                )
            )
        else {
            return nil
        }
        surface.frameRenderers[key] = renderer
        surface.proportionalMeasure.adopt(renderer.measuringAtlas)
        // Publish the renderer identity as well as its dense metrics: native
        // fallback and shaping can change while those advances stay equal.
        let richTextFaces = renderer.richTextFaces
        let rendererRevision = surface.proportionalMeasure.adoptRichText(RichTextShaper(faces: richTextFaces))
        var facts = richTextFaces.typographyFacts(
            cellWidthInPoints: font.cellWidthInPoints,
            cellHeightInPoints: font.cellHeightInPoints,
            baselineInPoints: font.cellHeightInPoints - (font.baselinePenInPixels - Double(font.geometry.glyphMarginInPixels.height))
                / font.atlasScale,
            proportionalSizeInPoints: Ubiquitty.Preferences.Zoom.zoomedCompanionSize(
                typography.gridPointSize,
                pointSize,
                typography.proportionalPointSize
            ),
            monospaceSizeInPoints: pointSize
        )
        facts.setRendererRevision(rendererRevision)
        surface.drive.publishTypography(facts)
        return renderer
    }

    /// The key a scale selects a build with.
    ///
    /// Quantised to a thousandth: an exact `Double` key lets float noise on a
    /// scale that never really changed cut a second set of sheets.
    ///
    /// - Parameter scale: Atlas pixels per point.
    /// - Returns: The key.
    private static func scaleKey(_ scale: Double) -> Int {
        Int((scale * 1000).rounded())
    }

    /// Makes the build for a backing scale current, measuring one if needed.
    ///
    /// Wanted before a host reads ``cellSize(for:)`` against a scale that just
    /// changed: the cell is measured off faces built at the scale, so a grid
    /// sized from the previous build is sized for the previous display.
    ///
    /// A scale the face refuses leaves the current build standing, so the frame
    /// it draws is resampled rather than absent.
    ///
    /// - Parameter scale: Atlas pixels per point, from the layer's backing scale.
    func prepare(forDeviceScale scale: Double) {
        let key = Self.scaleKey(scale)
        guard scale > 0, key != Self.scaleKey(current.font.atlasScale) else {
            return
        }
        if let measured = builds[key] {
            current = measured
            return
        }
        guard
            let measured = Self.measure(
                device: device,
                familyName: familyName,
                pointSize: pointSize,
                atlasScale: scale,
                typography: typography
            )
        else {
            return
        }
        builds[key] = measured
        current = measured
    }

    /// One cell's size in points, from the measured advance and line height.
    ///
    /// - Parameter surface: The surface asking.
    /// - Returns: The cell size.
    func cellSize(for surface: TerminalSurface) -> CGSize {
        CGSize(width: current.font.cellWidthInPoints, height: current.font.cellHeightInPoints)
    }

    /// The column under a point along a row the last frame laid out as
    /// proportional runs, or nil for a row on the grid.
    ///
    /// Core's answer from the frame it drew (LetterLayout.h): the shell never
    /// recomputes where a letter stands.
    ///
    /// - Parameters:
    ///   - surface: The surface asking.
    ///   - row: The visible row under the point.
    ///   - xInCells: The point along the row in drawn cells from the grid's left edge.
    /// - Returns: The column, or nil where the grid's own arithmetic answers.
    func letterColumn(for surface: TerminalSurface, row: Int32, xInCells: Double) -> Int32? {
        frameRenderer(for: surface)?.letterColumn(row: Int(row), xInCells: xInCells).map { Int32($0) }
    }

    /// Where a point is along such a row in cells — the column plus the
    /// fraction of its letter crossed — or nil for a row on the grid.
    ///
    /// - Parameters:
    ///   - surface: The surface asking.
    ///   - row: The visible row under the point.
    ///   - xInCells: The point along the row in drawn cells from the grid's left edge.
    /// - Returns: The position, or nil where the grid's own arithmetic answers.
    func letterXInCells(for surface: TerminalSurface, row: Int32, xInCells: Double) -> Double? {
        frameRenderer(for: surface)?.letterXInCells(row: Int(row), xInCells: xInCells)
    }

    /// Where a column's letter stands on a row of the last frame, in cells
    /// from the grid's left edge, for a scenario reading the layout drawn.
    ///
    /// - Parameters:
    ///   - surface: The surface asking.
    ///   - row: The visible row.
    ///   - column: The column.
    /// - Returns: The letter's left edge and advance in cells, and whether the
    ///   row was laid out as letters; nil before a frame was drawn.
    package func letterExtentForTesting(
        for surface: TerminalSurface,
        row: Int,
        column: Int
    ) -> (left: Double, advance: Double, isLetterRow: Bool)? {
        frameRenderer(for: surface)?.letterExtentForTesting(row: row, column: column)
    }

    /// Returns the geometry retained with this surface's last submitted frame.
    ///
    /// - Parameter surface: The surface whose frame is queried.
    /// - Returns: The submitted geometry, or nil before a grid frame.
    func presentedGeometry(for surface: TerminalSurface) -> TerminalSurfaceFrameGeometry? {
        surface.presentedFrameGeometry
    }

    /// Returns the submitted cell size, or zero before a grid frame was drawn.
    ///
    /// - Parameter surface: The surface whose frame is queried.
    /// - Returns: The drawn cell size in view points.
    func drawnCellSize(for surface: TerminalSurface) -> CGSize {
        presentedGeometry(for: surface)?.cellSize ?? .zero
    }

    /// The frame's geometry, resolved by Core's one resolver.
    ///
    /// Core's one resolver, fed the natural advance, the padding, the two mode
    /// facts and the grid: where a cell starts and how wide DECCOLM squeezes
    /// it are then the same numbers for every frontend, and a disagreement between
    /// them is a marshalling fault rather than a layout opinion.
    ///
    /// - Parameters:
    ///   - drawableSize: The target's size in device pixels.
    ///   - columns: The columns the frame lays out.
    ///   - rows: The rows the frame lays out.
    ///   - deviceScale: Device pixels per point.
    ///   - isEdgeToEdge: Whether DECSET 7402's colour letterbox drops the padding.
    ///   - isColumns132: Whether DECCOLM holds the column count, so the
    ///     advance compresses to fit rather than the columns overflowing.
    /// - Returns: The grid's origin and its cell, in device pixels.
    private func resolvedGeometry(
        drawableSize: CGSize,
        columns: Int32,
        rows: Int32,
        deviceScale: Double,
        isEdgeToEdge: Bool,
        isColumns132: Bool
    ) -> ResolvedFrameGeometry {
        resolveFrameGeometry(
            drawableSize: PixelExtent(width: Float(drawableSize.width), height: Float(drawableSize.height)),
            gridColumns: columns,
            gridRows: rows,
            naturalAdvance: PixelExtent(
                width: Float(current.font.cellWidthInPoints),
                height: Float(current.font.cellHeightInPoints)
            ),
            paddingLeftPoints: Float(style.paddingLeftPoints),
            paddingRightPoints: Float(style.paddingRightPoints),
            paddingTopPoints: Float(style.paddingTopPoints),
            paddingBottomPoints: Float(style.paddingBottomPoints),
            extraTopInsetPoints: Float(style.extraTopInsetPoints),
            backingScale: Float(deviceScale),
            edgeMode: isEdgeToEdge ? .edgeToEdge : .padded,
            isColumns132: isColumns132,
            snapsLineHeight: typography.shouldSnapLineHeight
        )
    }

    /// Resolves one surface's local presentation from authenticated ownership.
    /// The offset belongs to the surface, not this shared font renderer.
    /// - Parameters:
    ///   - surface: The independently sized view.
    ///   - snapshot: The published host picture and cursor.
    ///   - drawableSize: The drawable extent in device pixels.
    ///   - deviceScale: Device pixels per point.
    /// - Returns: The shared grid transform and optional padded viewport clip.
    private func presentationGeometry(
        for surface: TerminalSurface,
        snapshot: borrowing Ubiquitty.Runtime.RuntimeSnapshot,
        drawableSize: CGSize,
        deviceScale: Double
    ) -> (geometry: ResolvedFrameGeometry, clip: CGRect?, scale: Float, panOffset: CGPoint) {
        let isTekMode = snapshot.isTekModeActive
        let isFullscreenContent = snapshot.modes.isFullscreenContentActive
        let isCursorVisible = snapshot.isCursorVisible
        let shouldPresentNonOwner =
            style.nonOwnerPresentation != .letterbox
            && surface.drive.isRemoteGeometryOwnedElsewhere
            && !isTekMode && !isFullscreenContent
        var geometry = resolvedGeometry(
            drawableSize: drawableSize,
            columns: snapshot.columns,
            rows: snapshot.rows,
            deviceScale: deviceScale,
            isEdgeToEdge: snapshot.isEdgeToEdge,
            isColumns132: snapshot.isColumnCountHeld && !shouldPresentNonOwner
        )
        guard shouldPresentNonOwner, deviceScale > 0 else {
            return (geometry, nil, 1, .zero)
        }
        // The frame keeps the measured row pitch when an old atlas is scaled
        // onto a new display. Do not floor that pitch again for presentation.
        geometry.cellSizeInPixels.height = Float(current.font.cellHeightInPoints * deviceScale)
        let content = Ubiquitty.Rendering.resolveGridContentRect(
            Ubiquitty.FloatSize(width: Float(drawableSize.width), height: Float(drawableSize.height)),
            Ubiquitty.Rendering.EdgeInsets(
                left: Float(style.paddingLeftPoints * deviceScale),
                right: Float(style.paddingRightPoints * deviceScale),
                top: Float(style.paddingTopPoints * deviceScale),
                bottom: Float(style.paddingBottomPoints * deviceScale)
            ),
            Float(style.extraTopInsetPoints * deviceScale)
        )
        let clip = CGRect(
            x: Double(content.origin.x),
            y: Double(content.origin.y),
            width: Double(content.size.width),
            height: Double(content.size.height)
        )
        if style.nonOwnerPresentation == .fit {
            // Reuse the normal zoom minimum, not an independently chosen
            // readability threshold. A smaller viewport clips at that floor.
            let minScale = Float(min(1, Ubiquitty.Preferences.Zoom.clampFontZoom(0.0) / pointSize))
            let fitted = Ubiquitty.Rendering.remoteFitPlacement(
                content.size,
                Ubiquitty.FloatSize(width: geometry.cellSizeInPixels.width, height: geometry.cellSizeInPixels.height),
                Ubiquitty.GridSize(columns: snapshot.columns, rows: snapshot.rows),
                minScale
            )
            geometry.cellSizeInPixels.width *= fitted.scale
            geometry.cellSizeInPixels.height *= fitted.scale
            geometry.originInPixels = PixelExtent(
                width: Float(clip.minX) + fitted.origin.x,
                height: Float(clip.minY) + fitted.origin.y
            )
            return (geometry, clip, fitted.scale, .zero)
        }
        var request = Ubiquitty.Rendering.RemotePanRequest()
        request.viewport = Ubiquitty.FloatSize(width: Float(clip.width), height: Float(clip.height))
        request.cell = Ubiquitty.FloatSize(width: geometry.cellSizeInPixels.width, height: geometry.cellSizeInPixels.height)
        request.grid = Ubiquitty.GridSize(columns: snapshot.columns, rows: snapshot.rows)
        request.cursor = Ubiquitty.CellPosition(row: snapshot.cursorRow, column: snapshot.cursorColumn)
        request.previousOffset = Ubiquitty.FloatPoint(
            x: Float(surface.remotePanOffsetInPoints.x * deviceScale),
            y: Float(surface.remotePanOffsetInPoints.y * deviceScale)
        )
        request.shouldFollowCursor = surface.viewOffset == 0 && isCursorVisible
        let offset = Ubiquitty.Rendering.remotePanOffset(request)
        geometry.originInPixels = PixelExtent(width: Float(clip.minX) - offset.x, height: Float(clip.minY) - offset.y)
        return (geometry, clip, 1, CGPoint(x: Double(offset.x) / deviceScale, y: Double(offset.y) / deviceScale))
    }

    /// The padded visible viewport when non-owner Fit or Pan is active.
    /// - Parameter surface: The view whose host grid is presented.
    /// - Returns: A point-space clip, or nil for the unchanged local/letterbox path.
    func contentClip(for surface: TerminalSurface) -> CGRect? {
        presentedGeometry(for: surface)?.clip
    }

    /// How much of the natural advance the resolved cell keeps: one out of
    /// DECCOLM, less when 132 columns must fit a narrower width.
    ///
    /// A ratio rather than the resolved width itself, because the build's
    /// metrics are atlas pixels and the resolver answers device pixels — the
    /// two scales agree only between display moves. Out of the mode the
    /// resolver hands the natural advance back exactly, so the ratio is one
    /// and the metrics the frame builds with are the build's, bit for bit.
    ///
    /// - Parameters:
    ///   - geometry: The resolved frame geometry.
    ///   - deviceScale: The scale the geometry was resolved at.
    /// - Returns: The factor to compress the build's advance by.
    private func advanceCompression(of geometry: ResolvedFrameGeometry, deviceScale: Double) -> Float {
        let natural = Float(current.font.cellWidthInPoints) * Float(deviceScale)
        guard natural > 0, geometry.cellSizeInPixels.width < natural else { return 1 }
        return geometry.cellSizeInPixels.width / natural
    }

    /// The metrics this frame builds and draws with: the build's, with the
    /// advance DECCOLM compressed — the builder is fed
    /// the RESOLVED cell rather than the font's natural one, so the glyph
    /// positions and the cell backgrounds agree with the drawn advance.
    ///
    /// - Parameters:
    ///   - geometry: The resolved frame geometry.
    ///   - deviceScale: The scale the geometry was resolved at.
    ///   - presentationScale: The local Fit scale shared by placement and ink.
    /// - Returns: The metrics for this frame.
    private func metrics(
        compressedBy geometry: ResolvedFrameGeometry,
        deviceScale: Double,
        presentationScale: Float
    ) -> Ubiquitty.Rendering.CellMetrics {
        var metrics = Ubiquitty.Rendering.scaledCellMetrics(current.metrics, presentationScale)
        let ratio = advanceCompression(of: geometry, deviceScale: deviceScale)
        if ratio < 1 {
            metrics.cellWidth = current.metrics.cellWidth * ratio
        }
        return metrics
    }

    /// Returns the submitted grid origin and insets, without reading pending model state.
    ///
    /// - Parameter surface: The surface whose frame is queried.
    /// - Returns: The drawn insets in view points, or zero before a grid frame.
    func gridInsets(for surface: TerminalSurface) -> PlatformEdgeInsets {
        presentedGeometry(for: surface)?.insets ?? PlatformEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    /// Commits query geometry with the exact grid and uniforms submitted to Metal.
    ///
    /// - Parameters:
    ///   - surface: The surface receiving the frame.
    ///   - frame: The submitted grid and its uniforms.
    ///   - deviceScale: The frame's backing pixels per point.
    ///   - panOffset: The resolved pan offset in view points.
    private func notePresentedGeometry(
        for surface: TerminalSurface,
        frame: TerminalRenderer.PendingFrame,
        deviceScale: Double,
        panOffset: CGPoint
    ) {
        guard !isDrawingStill else { return }
        let origin = frame.originInPixels
        let cell = frame.cellSizeInPixels
        let keepsPadding = !frame.isEdgeToEdge && frame.viewportClipInPixels == nil
        surface.presentedFrameGeometry = TerminalSurfaceFrameGeometry(
            rows: frame.rows,
            columns: frame.columns,
            cellSize: CGSize(width: cell.width / deviceScale, height: cell.height / deviceScale),
            insets: PlatformEdgeInsets(
                top: origin.y / deviceScale,
                left: origin.x / deviceScale,
                bottom: keepsPadding ? style.paddingBottomPoints : 0,
                right: keepsPadding ? style.paddingRightPoints : 0
            ),
            clip: frame.viewportClipInPixels.map {
                CGRect(x: $0.minX / deviceScale, y: $0.minY / deviceScale, width: $0.width / deviceScale, height: $0.height / deviceScale)
            },
            deviceScale: deviceScale,
            isFullscreenContentActive: frame.isFullscreenContentActive
        )
        surface.remotePanOffsetInPoints = panOffset
    }

    /// The style's window padding, the top carrying the reserved band.
    ///
    /// What the grid is fitted inside whatever the mode: DECSET 7402 moves
    /// the origin and paints the padding, and it moves no column — an
    /// application entering the mode is not resized. The frame's own
    /// insets are ``gridInsets(for:)``.
    ///
    /// - Parameter surface: The surface asking.
    /// - Returns: The insets a grid is fitted inside.
    func gridFitInsets(for surface: TerminalSurface) -> PlatformEdgeInsets {
        PlatformEdgeInsets(
            top: style.paddingTopPoints + style.extraTopInsetPoints,
            left: style.paddingLeftPoints,
            bottom: style.paddingBottomPoints,
            right: style.paddingRightPoints
        )
    }

    /// Readies a layer this renderer will draw into.
    ///
    /// - Parameter layer: The layer to ready.
    func prepare(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = pixelFormat
        applyColorSpace(to: layer)
    }

    /// Adopts a colour-space setting, re-tagging `layer` when it changed.
    ///
    /// - Parameters:
    ///   - usesDisplayP3: Whether the frame is read as Display P3.
    ///   - layer: The surface's layer, re-tagged in place.
    func adopt(usesDisplayP3: Bool, relabeling layer: CAMetalLayer) {
        guard style.usesDisplayP3 != usesDisplayP3 else {
            return
        }
        style.usesDisplayP3 = usesDisplayP3
        applyColorSpace(to: layer)
    }

    /// Tags the layer with the configured colour space.
    ///
    /// Separate from ``prepare(_:)`` because the setting can change while the
    /// layer lives, and the tag is the only part of the layer it moves.
    func applyColorSpace(to layer: CAMetalLayer) {
        layer.colorspace = CGColorSpace(name: style.usesDisplayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)
    }

    /// Draws one frame of the surface's terminal into its layer.
    ///
    /// The model lock brackets the capture only: the build and the encode read
    /// the capture's own storage, so the terminal is released before the GPU
    /// is asked for anything.
    ///
    /// - Parameters:
    ///   - surface: The surface to draw.
    ///   - layer: The layer to present into.
    /// - Returns: Whether a frame was drawn.
    @discardableResult
    func encodeFrame(for surface: TerminalSurface, into layer: CAMetalLayer) -> Bool {
        #if canImport(AppKit)
        let hadSecondaryPlane = surface.secondaryTextPlane != nil
        let previousSecondaryInk = surface.secondaryTextPlane?.secondaryInk
        let previousTertiaryInk = surface.secondaryTextPlane?.tertiaryInk
        let hadBackgroundPlane = surface.backgroundVibrancyPlane != nil
        if style.usesTextVibrancy {
            let plane = surface.secondaryTextPlane ?? SecondaryTextPlane(frame: .zero)
            if plane.attach(to: surface, matching: layer) {
                surface.secondaryTextPlane = plane
            } else {
                surface.secondaryTextPlane = nil
            }
        } else {
            surface.secondaryTextPlane?.removeFromSuperview()
            surface.secondaryTextPlane = nil
        }
        if style.usesBackgroundVibrancy {
            let plane = surface.backgroundVibrancyPlane ?? SecondaryTextPlane(frame: .zero)
            surface.backgroundVibrancyPlane = plane.attach(to: surface, matching: layer, ordered: .below) ? plane : nil
        } else {
            surface.backgroundVibrancyPlane?.removeFromSuperview()
            surface.backgroundVibrancyPlane = nil
        }
        if hadSecondaryPlane != (surface.secondaryTextPlane != nil)
            || hadBackgroundPlane != (surface.backgroundVibrancyPlane != nil)
            || previousSecondaryInk != surface.secondaryTextPlane?.secondaryInk
            || previousTertiaryInk != surface.secondaryTextPlane?.tertiaryInk
        {
            surface.registeredSyncStyle = nil
            surface.invalidateRetainedBaseline()
        }
        #endif
        return encodeFrame(
            for: surface,
            drawableSize: layer.drawableSize,
            contentsScale: layer.contentsScale,
            presentsWithTransaction: layer.presentsWithTransaction,
            allowsFontPreparation: true
        ) {
            let drawable: CAMetalDrawable?
            #if canImport(AppKit)
            if let supplied = surface.frameLink?.currentDrawable {
                // The link acquires its drawables ahead of the tick, so one
                // in hand when the layer's size moves — a font or style
                // change resizes every window it reaches — is the old size,
                // and the layer's pool holds two or three of them. A frame
                // built for the layer's size and blitted into one presents a
                // picture the layer stretches to fit, one tick per stale
                // drawable, which reads as a flicker after the change.
                // Refused instead: the frame is declared unpresented and the
                // next tick draws it onto a drawable of the layer's size.
                let texture = supplied.texture
                guard texture.width == Int(layer.drawableSize.width.rounded()),
                    texture.height == Int(layer.drawableSize.height.rounded())
                else {
                    staleDrawableRefusals += 1
                    return nil
                }
                drawable = supplied
            } else if surface.frameLink?.ownsDrawableDelivery == true {
                return nil
            } else {
                drawablesRequested += 1
                drawable = layer.nextDrawable()
            }
            #else
            drawablesRequested += 1
            drawable = layer.nextDrawable()
            #endif
            guard let drawable else { return nil }
            var frame = FrameTarget(descriptor: Self.passDescriptor(for: drawable.texture), drawable: drawable)
            #if canImport(AppKit)
            if let plane = surface.secondaryTextPlane {
                guard let secondary = plane.metalLayer.nextDrawable(),
                    secondary.texture.width == drawable.texture.width,
                    secondary.texture.height == drawable.texture.height
                else { return nil }
                frame.secondaryDescriptor = Self.passDescriptor(for: secondary.texture)
                frame.secondaryDrawable = secondary
            }
            if let plane = surface.backgroundVibrancyPlane {
                guard let background = plane.metalLayer.nextDrawable(),
                    background.texture.width == drawable.texture.width,
                    background.texture.height == drawable.texture.height
                else { return nil }
                frame.backgroundDescriptor = Self.passDescriptor(for: background.texture)
                frame.backgroundDrawable = background
            }
            #endif
            return frame
        }
    }

    /// Where a frame is encoded and, for a layer, presented.
    struct FrameTarget {
        let descriptor: MTLRenderPassDescriptor
        let drawable: (any MTLDrawable)?
        var secondaryDescriptor: MTLRenderPassDescriptor?
        var secondaryDrawable: (any MTLDrawable)?
        var backgroundDescriptor: MTLRenderPassDescriptor?
        var backgroundDrawable: (any MTLDrawable)?
    }

    var forcesFontPreparationForTesting = false

    /// How many link-supplied drawables were refused for being a size the
    /// layer had left behind.
    package private(set) var staleDrawableRefusals = 0

    /// How many drawables frames asked a layer for on demand, link-supplied
    /// ones aside.
    package private(set) var drawablesRequested = 0

    /// Why a frame asked of ``encodeFrame(for:into:)`` drew nothing.
    ///
    /// A caller that retries a declined frame has to tell a hold, which lifts
    /// on its own, from a refusal that will not: the withhold is read again
    /// after the decline, by which time the ingest thread may have released
    /// it, so the state alone cannot say which the frame met.
    package enum FrameDecline: String {
        /// The last frame asked for was drawn, or reproduced the glass.
        case none
        case noRenderer
        case tek
        /// The coherence rule or a synchronized-output block held the frame.
        case withheld
        /// A block opened, or the screen was erased, between the published
        /// check and the capture's lock.
        case blockOpenUnderLock
        case drainSaturated
        /// A live resize's capture met a whole-screen erase whose redraw the
        /// drain had not yet parsed whole.
        case redrawArriving
        /// The capture took no frame from the model.
        case capture
        /// The capture built to nothing, without reproducing the glass.
        case build
        case drawable
        case encode
        case boundaryBuild
        case boundaryDrawable
        case boundaryEncode
    }

    /// The reason the last ``encodeFrame(for:into:)`` returned `false`.
    package private(set) var lastFrameDecline = FrameDecline.none

    private static func passDescriptor(for texture: any MTLTexture) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return descriptor
    }

    func lastFrameHadNetChange(for surface: TerminalSurface) -> Bool {
        frameRenderer(for: surface)?.lastFrameHadNetChange ?? false
    }

    /// Records that a frame was built and not shown.
    ///
    /// The build consumed the rows the capture owed and set the glass
    /// baseline, so a retry would read its own capture as reproducing the
    /// glass and load a retained target nothing wrote: the renderer forgets
    /// the baseline and the session's retained frame is declared gone, so the
    /// retry builds every row and presents them.
    ///
    /// - Parameters:
    ///   - surface: The surface whose frame was denied a drawable.
    ///   - renderer: Its frame renderer.
    private func noteFrameNotPresented(for surface: TerminalSurface, renderer: TerminalRenderer) {
        renderer.noteFrameNotPresented()
        _ = surface.drive.withTerminal { terminal in
            surface.drive.invalidateRetainedFrame(terminal)
        }
    }

    /// Draws one frame into `texture`, for a caller that reads pixels back.
    ///
    /// The same encode the window presents, with the present left off: a
    /// snapshot that rendered through a second path would compare a frame
    /// nobody sees against a golden that stands for one somebody does.
    ///
    /// - Parameters:
    ///   - surface: The surface whose terminal is drawn.
    ///   - texture: The target, which the caller synchronises and reads.
    ///   - contentScale: Device pixels per point.
    /// - Returns: Whether a frame was encoded.
    @discardableResult
    public func render(_ surface: TerminalSurface, into texture: any MTLTexture, contentScale: Double) -> Bool {
        offscreenGPUSeconds = 0
        offscreenGPUExecutionSeconds = 0
        return encodeFrame(
            for: surface,
            drawableSize: CGSize(width: texture.width, height: texture.height),
            contentsScale: CGFloat(contentScale),
            presentsWithTransaction: false
        ) {
            FrameTarget(descriptor: Self.passDescriptor(for: texture), drawable: nil)
        }
    }

    /// Draws one frame into `texture` for a still picture of everything the
    /// terminal has been fed, once the presentation holds that lift on their
    /// own have lifted.
    ///
    /// A feed that erases the whole screen arms Core's erase hold, which
    /// withholds frames until the stream has been quiet for its settle window
    /// or the hold's watchdog fires; a picture of the fed bytes is the frame
    /// drawn after that, not a refusal. Any other decline is answered at once.
    ///
    /// - Parameters:
    ///   - surface: The surface whose terminal is drawn.
    ///   - texture: The target, which the caller reads.
    ///   - contentScale: Device pixels per point.
    ///   - timeout: How long a hold may keep the frame back before the picture
    ///     is refused.
    /// - Returns: Whether a frame was encoded.
    package func renderStill(
        _ surface: TerminalSurface,
        into texture: any MTLTexture,
        contentScale: Double,
        timeout: TimeInterval = 1
    ) -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while !render(surface, into: texture, contentScale: contentScale) {
            guard lastFrameDecline == .withheld || lastFrameDecline == .blockOpenUnderLock || lastFrameDecline == .redrawArriving,
                CACurrentMediaTime() < deadline
            else { return false }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return true
    }

    /// Whether the frame being drawn is a still picture, whose cursor is drawn
    /// steady rather than at the blink's phase: a picture that changed with
    /// every blink would be drawn again for nothing each time it is looked at.
    private var isDrawingStill = false

    /// Draws one frame into `texture` for a picture of the pane that nobody
    /// presents, such as a thumbnail, and leaves the pane's next presented
    /// frame whole.
    ///
    /// The build consumes the rows the capture owed and moves the glass
    /// baseline, exactly as a drawable that never arrived does, so it is
    /// answered the same way: the next frame on the glass builds every row.
    /// The cursor is drawn steady.
    ///
    /// - Parameters:
    ///   - surface: The surface whose terminal is drawn.
    ///   - texture: The target, which the caller reads.
    ///   - contentScale: Device pixels per point.
    /// - Returns: Whether a frame was encoded.
    func renderDetached(_ surface: TerminalSurface, into texture: any MTLTexture, contentScale: Double) -> Bool {
        isDrawingStill = true
        defer { isDrawingStill = false }
        let didRender = render(surface, into: texture, contentScale: contentScale)
        if let renderer = frameRenderer(for: surface) {
            noteFrameNotPresented(for: surface, renderer: renderer)
        }
        return didRender
    }

    /// Commits the frame and presents it, by whichever of the two contracts
    /// the layer is under.
    ///
    /// Asynchronously, `MTLCommandBuffer.present` hands the drawable to the
    /// compositor whenever the GPU gets to it, which is the right trade for a
    /// steady stream of frames.
    ///
    /// Transactionally, the drawable has to appear in the same Core Animation
    /// transaction as the layer change that motivated it — a resize step's new
    /// bounds — so the caller presents it itself, once the work is known to be
    /// scheduled. Left on the command buffer, the present lands in some later
    /// transaction and the compositor makes that one frame out of the previous
    /// drawable, which is the artifact the whole arrangement exists to avoid.
    ///
    /// - Parameters:
    ///   - commands: The buffer the frame was encoded into.
    ///   - drawable: The drawable to present, or nil for an offscreen target.
    ///   - transactionally: Whether the layer presents with a transaction.
    private func commit(
        _ commands: any MTLCommandBuffer,
        presenting drawable: (any MTLDrawable)?,
        secondaryDrawable: (any MTLDrawable)? = nil,
        backgroundDrawable: (any MTLDrawable)? = nil,
        transactionally: Bool
    ) {
        guard let drawable else {
            let started = CACurrentMediaTime()
            commands.commit()
            // An offscreen caller reads the target as soon as this returns, and
            // its readback runs on a queue of its own: two queues carry no
            // ordering between them, so without this the pixels are whatever
            // the texture held before the pass wrote it.
            commands.waitUntilCompleted()
            offscreenGPUSeconds = CACurrentMediaTime() - started
            offscreenGPUExecutionSeconds = max(0, commands.gpuEndTime - commands.gpuStartTime)
            return
        }
        presentedFrameCount += 1
        deliveryTrace?.attach(to: commands, drawable: drawable, transactionally: transactionally)
        guard transactionally else {
            // The slip accounting rides a presented handler on the async
            // branch only: the transactional present has no presented time.
            if SurfaceRenderer.isPresentSlipArmed {
                presentSlip.attach(to: drawable)
            }
            attachPresentLeg(to: drawable)
            commands.present(drawable)
            if let secondaryDrawable { commands.present(secondaryDrawable) }
            if let backgroundDrawable { commands.present(backgroundDrawable) }
            commands.commit()
            return
        }
        // No presented time on this branch, so the arm is spent unused rather
        // than left for a later present to measure against a stale model time.
        _ = presentLeg.takeArmedPoster()
        commands.commit()
        commands.waitUntilScheduled()
        drawable.present()
        secondaryDrawable?.present()
        backgroundDrawable?.present()
    }

    /// Arms a drawable's presented handler to post the frame's present leg,
    /// when the frame was armed.
    ///
    /// The handler is a dead-end observer on the present thread: it holds the
    /// Core poster — the ring by reference count and the model time by value —
    /// and nothing of this renderer, so a handler pending at teardown posts
    /// into a live ring.
    ///
    /// - Parameter drawable: The drawable about to be presented.
    private func attachPresentLeg(to drawable: any MTLDrawable) {
        let poster = presentLeg.takeArmedPoster()
        guard poster.isArmed() else { return }
        #if !targetEnvironment(simulator)
        let post = PresentLegPost(poster: poster)
        drawable.addPresentedHandler { presented in
            post.poster.post(presented.presentedTime)
        }
        #endif
    }

    /// The renderer's half of the drawing-debug panel's facts for `surface`:
    /// the face, the cell, the mono sheet's fill and the last frame's counts.
    struct DrawingDebugRendererFacts {
        let fontName: String
        let pointSize: Double
        let cellSize: CGSize
        let atlasSlotsUsed: Int
        let atlasSlotCapacity: Int
        let cellsPerFrame: Int
        let overlaysPerFrame: Int
    }

    /// Reads the renderer's half of the drawing-debug facts.
    ///
    /// - Parameter surface: The surface the panel reports on.
    /// - Returns: The facts, read from the frame renderer that draws it.
    func drawingDebugRendererFacts(for surface: TerminalSurface) -> DrawingDebugRendererFacts {
        let renderer = surface.frameRenderers[Self.scaleKey(current.font.atlasScale)]
        let occupancy = renderer?.monoSheetOccupancy ?? (used: 0, capacity: 0)
        return DrawingDebugRendererFacts(
            fontName: familyName,
            pointSize: pointSize,
            cellSize: drawnCellSize(for: surface),
            atlasSlotsUsed: occupancy.used,
            atlasSlotCapacity: occupancy.capacity,
            cellsPerFrame: lastFrameDrawnCells,
            overlaysPerFrame: renderer.map { Int($0.counts.overlays) } ?? 0
        )
    }

    /// Records one presented frame in the perf log and collects the present
    /// legs the present thread posted since the last.
    ///
    /// - Parameters:
    ///   - sample: The frame's costs.
    ///   - surface: The surface that drew it, whose session supplies the pacing.
    ///   - renderer: The frame renderer, whose counts the frame built.
    private func notePerfFrame(
        _ sample: Ubiquitty.Diagnostics.PerfFrameSample,
        for surface: TerminalSurface,
        renderer: TerminalRenderer
    ) {
        var sample = sample
        let counts = renderer.counts
        sample.cells = UInt64(counts.cells)
        sample.overlays = UInt64(counts.overlays)
        sample.decorations = UInt64(counts.decorations)
        sample.boxFills = UInt64(counts.boxFills)
        let interval = surface.drive.presentationFrameIntervalSeconds
        sample.refreshSeconds = interval > 0 ? interval : 1.0 / 60.0
        presentSlip.noteRefreshSeconds(sample.refreshSeconds)
        Self.framePerfLog.notePacing(
            surface.drive.syncFramePromoteCount,
            surface.drive.syncFrameOverwriteCount,
            0,
            presentSlip.slippedVsyncs
        )
        Self.framePerfLog.noteFrame(sample, CACurrentMediaTime())
        let report = presentLeg.drainFrame()
        if report.count > 0 {
            Ubiquitty.Runtime.PresentLegMeter.printReport(report)
        }
    }

    /// Encodes one frame into a pass, presenting only when a caller has a
    /// drawable to present.
    ///
    /// The geometry arrives as values rather than as a layer because the
    /// offscreen caller has no layer: a snapshot renders into a texture it
    /// reads back, and asking it to invent a layer to carry two numbers would
    /// put the shipping path and the measured one on different code.
    ///
    /// The target is asked for after the frame is built from the grid and the
    /// model lock is released: a wait for a drawable never delays the
    /// capture, so a program's redraw arriving during that wait is not caught
    /// half-drawn, and the lock is never held across the wait.
    ///
    /// - Parameters:
    ///   - surface: The surface whose terminal is drawn.
    ///   - drawableSize: The target in device pixels.
    ///   - contentsScale: Device pixels per point.
    ///   - presentsWithTransaction: Whether the layer being presented into
    ///     presents with a transaction; false for an offscreen target.
    ///   - target: Yields the pass to encode into and the drawable to
    ///     present, or nil when none can be had; an offscreen target has no
    ///     drawable.
    /// - Returns: Whether a frame was encoded.
    private func encodeFrame(
        for surface: TerminalSurface,
        drawableSize: CGSize,
        contentsScale: CGFloat,
        presentsWithTransaction: Bool,
        allowsFontPreparation: Bool = false,
        target: () -> FrameTarget?
    ) -> Bool {
        // The layer's own scale, not the atlas's. Sourcing this from
        // `font.atlasScale` makes `atlasToDevice` the identity for every frame,
        // which is the one ratio that exists to express the two disagreeing.
        let encodeStartedAt = ProcessInfo.processInfo.systemUptime
        lastFrameDecline = .none
        let deviceScale = contentsScale > 0 ? Double(contentsScale) : current.font.atlasScale
        // Ahead of every read of `current` below, so the faces, the sheets, the
        // metrics and the placement all come from one build.
        prepare(forDeviceScale: deviceScale)
        let font = current.font
        // One snapshot copy serves the whole frame: the Tek gate, the grid
        // dimensions and the status fill all read this — a read per consumer
        // is a struct copy per consumer, paid every frame.
        let snapshot = surface.drive.readSnapshot()
        // The storage tube owns the frame ahead of every grid concern: Tek
        // mode draws no cells, so the capture, the boundary slot and the
        // retained plan all stand aside — the Metal arm's view orders its
        // frame the same way.
        didDrawTekFrame = false
        if snapshot.isTekModeActive {
            guard let renderer = frameRenderer(for: surface) else {
                lastFrameDecline = .noRenderer
                return false
            }
            guard let target = target(),
                let commands = encodeTekFrame(
                    for: surface,
                    renderer: renderer,
                    deviceScale: deviceScale,
                    into: target.descriptor
                )
            else {
                lastFrameDecline = .tek
                return false
            }
            if let secondary = target.secondaryDescriptor {
                secondary.colorAttachments[0].loadAction = .clear
                secondary.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                guard let clear = commands.makeRenderCommandEncoder(descriptor: secondary) else { return false }
                clear.endEncoding()
            }
            if let background = target.backgroundDescriptor {
                background.colorAttachments[0].loadAction = .clear
                background.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                guard let clear = commands.makeRenderCommandEncoder(descriptor: background) else { return false }
                clear.endEncoding()
            }
            didDrawTekFrame = true
            if !isDrawingStill {
                surface.presentedFrameGeometry = nil
                surface.remotePanOffsetInPoints = .zero
            }
            commit(
                commands,
                presenting: target.drawable,
                secondaryDrawable: target.secondaryDrawable,
                backgroundDrawable: target.backgroundDrawable,
                transactionally: presentsWithTransaction
            )
            return true
        }
        // The surface's own, not this object's: everything below that touches a
        // retained texture, an instance stream or the cursor animator is this
        // view's state.
        guard let renderer = frameRenderer(for: surface) else {
            lastFrameDecline = .noRenderer
            return false
        }
        // The surface's switch, re-applied per frame: a renderer cut after
        // the heatmap opened starts from a fresh baseline of its own.
        renderer.isPaintHeatmapEnabled = surface.isPaintHeatmapEnabled
        let isPerfLogged = Self.framePerfLog.isActive()
        var perfFrame = Ubiquitty.Diagnostics.PerfFrameSample()
        renderer.preparesVisibleFonts = forcesFontPreparationForTesting || (allowsFontPreparation && !surface.isDrawingResizeStep)
        renderer.cursorPresentationTimeForTesting = cursorPresentationTimeForTesting
        let displayInterval = surface.drive.presentationFrameIntervalSeconds
        renderer.configureCursorPresentation(
            interval: surface.window != nil && !surface.isDrawingResizeStep
                ? (displayInterval > 0 ? min(displayInterval, 0.016) : 0.016) : 0,
            bypassUntil: surface.cursorPresentationBypassUntil
        )
        defer { surface.cursorPresentationDeadline = renderer.cursorPresentationDeadline }

        lastFrameDeviceScale = deviceScale
        lastFrameAtlasScale = font.atlasScale

        // The capture resolves the whole frame from its options, so the
        // placement and style blocks must be filled before it runs: an empty
        // options block captures a zero-sized viewport, and the encode then
        // declines a frame that looks black rather than absent.
        var options = Ubiquitty.Rendering.TerminalSnapshotOptions()
        options.shouldUseSubpixelGlyphs = shouldUseSubpixelGlyphs
        // Core stands the lock in the frame for a surface with no badge view of
        // its own. The macOS surface carries one above the frame (AppKit's
        // symbol, PasswordPromptBadge) except on the bitmap tier; the UIKit
        // surface has none, so its frame is where the lock appears.
        #if canImport(AppKit)
        options.shouldDrawPasswordLock = isBitmapTier
        #else
        options.shouldDrawPasswordLock = true
        #endif
        // The frame's geometry and the cell it builds with, resolved once
        // through Core's resolver from the grid
        // the snapshot names and the two mode facts it carries. DECCOLM
        // compresses the advance here, so the builder, the retained plan, the
        // image layer and the pointer all see the cell that is drawn.
        let presentation = presentationGeometry(for: surface, snapshot: snapshot, drawableSize: drawableSize, deviceScale: deviceScale)
        renderer.prepareViewportClip(presentation.clip)
        let frameGeometry = presentation.geometry
        let frameMetrics = metrics(compressedBy: frameGeometry, deviceScale: deviceScale, presentationScale: presentation.scale)
        // The atlas's facts, so the builder keys what the sheets rasterise.
        applyFrameRaster(to: &options, renderer.frameRasterInputs)
        // The clock facts Core's capture refuses to sample itself: the tick
        // the blink curves read and the cursor's weight at it, resolved by
        // the session under its own lock — taken ahead of the capture's lock
        // below, because the session's mutex does not nest.
        let clock = surface.drive.frameClockFactsNow()
        // The cursor's whole presentation through the one applier both arms
        // call: a pane paints filled when it holds focus or its window is a
        // tab behind the group's front one, and each shell contributes only
        // those two facts. The slide is off here, since this arm ticks its
        // cursor animator against the capture after the capture runs, and a
        // fractional position written before that pins the cursor where it
        // last moved from.
        applyFrameCursor(
            to: &options,
            FrameCursorInputs(
                isCursorFocused: surface.isSurfaceFocused,
                isCursorBackgrounded: surface.isWindowBackgroundedTab,
                cursorMixAlpha: isDrawingStill ? 1 : clock.cursorMixAlpha,
                shouldCursorInvertText: style.shouldCursorInvertText,
                blinkTicks: isDrawingStill ? 0 : clock.blinkTicks,
                isCursorSliding: false,
                cursorColumnFractional: 0,
                cursorRowFractional: 0
            )
        )
        lastFrameBlinkTicks = options.blinkTicks
        lastFrameCursorMixAlpha = options.cursorMixAlpha
        // The reader's `[cursor] alpha`, read here rather than carried on the
        // palette: the model's colours are three channels and a translucent
        // cursor is display policy, so it arrives beside the colour. Asked of
        // the session, which is what the boundary capture asks: two routes
        // reading two spellings of one preference make the cursor pulse
        // between their answers on alternate frames.
        options.cursorAlpha = surface.drive.cursorAlphaUnit()
        lastFrameCursorAlpha = options.cursorAlpha
        // Measured at the tick this frame is being assembled at, because that
        // is the last point both arms pass through: an envelope read off a
        // second clock runs beside the frame instead of with it, and the flash
        // then fades in steps the frames never land on. The start and the peak
        // are the session's, so the boundary capture measures the same curve.
        options.bellFlashAlpha = surface.drive.bellFlashAlphaAt(options.blinkTicks)
        lastFrameBellFlashAlpha = options.bellFlashAlpha
        // The facts the glass comparison cannot read off a capture: the bell's
        // weight this frame, and whether the layer's transaction owes a present.
        renderer.frameBellFlashAlpha = options.bellFlashAlpha
        renderer.isEveryPresentOwed = presentsWithTransaction
        // Recorded from the frame's own options rather than from the surface's
        // two facts, the way the hover run is: it witnesses the applier as
        // well as the facts, so a fill the applier never wrote reads
        // differently here.
        surface.noteFrameCursorPresentation(
            TerminalSurface.FrameCursorPresentation(
                isCursorFilled: options.isFocused,
                isWindowBackgroundedTab: surface.isWindowBackgroundedTab,
                isPaneFocused: surface.isSurfaceFocused
            )
        )
        defer {
            let originMoved =
                lastFrameOriginXInPixels != options.originInPixels.x
                || lastFrameOriginYInPixels != options.originInPixels.y
            let advanceMoved = lastFrameCellWidthInAtlasPixels != Float(frameMetrics.cellWidth)
            lastFrameOriginXInPixels = options.originInPixels.x
            lastFrameOriginYInPixels = options.originInPixels.y
            lastFrameCellWidthInAtlasPixels = Float(frameMetrics.cellWidth)
            // One line per live frame under UBIQUITTY_PHASE_LOG, for a human
            // driving the app while another reads the stream: the inputs every
            // glyph's subpixel phase derives from, with a drift against the
            // previous frame flagged inline so a scan finds the event without
            // arithmetic. Env-gated and checked once; costs nothing off.
            if SurfaceRenderer.isPhaseLogEnabled {
                phaseLogFrameCount += 1
                let drift = (originMoved || advanceMoved) && phaseLogFrameCount > 1
                var line = "[phase] f=\(phaseLogFrameCount)"
                line += " origin=(\(options.originInPixels.x),\(options.originInPixels.y))"
                line += " advance=\(Float(frameMetrics.cellWidth))"
                line += " scale=\(deviceScale)/\(font.atlasScale)"
                line += " drawable=\(Int(drawableSize.width))x\(Int(drawableSize.height))"
                line += " reused=\(didReuseLastFrame ? 1 : 0)"
                line += " dirty=\(lastFrameDirtyRows)/\(lastFramePlannedRows)"
                line += " " + phaseLogSlipField
                // The cells the frame drew: a full-screen program's erase
                // caught mid-redraw presents a frame of almost none, which is
                // what a resize census counts as a cleared frame.
                line += " cells=\(lastFrameDrawnCells)"
                if !phaseLogRowSignature.isEmpty {
                    line += " rows=\(phaseLogRowSignature)"
                    phaseLogRowSignature = ""
                }
                if !phaseLogReuseTerms.isEmpty {
                    line += " rebuilt=\(phaseLogReuseTerms)"
                }
                if drift {
                    line += "  <<< DRIFT"
                }
                line += "\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
        applyFramePlacement(
            to: &options,
            FramePlacementInputs(
                viewOffset: Int32(surface.viewOffset),
                originX: frameGeometry.originInPixels.width,
                originY: frameGeometry.originInPixels.height,
                viewportWidth: Float(drawableSize.width),
                viewportHeight: Float(drawableSize.height),
                cellHeightInPoints: font.cellHeightInPoints,
                lineSpacingInPoints: typography.lineSpacingInPoints,
                fontSizeInPoints: font.metricsInputs.fontSizeInPoints,
                fontAscentInAtlasPixels: Float(font.ascentInAtlasPixels),
                fontDescentInAtlasPixels: Float(font.descentInAtlasPixels),
                lineGapTopInAtlasPixels: Float(font.metricsInputs.lineGapTopInAtlasPixels),
                bracketInkTopInAtlasPixels: Float(font.bracketInkTopInAtlasPixels),
                bracketInkBottomInAtlasPixels: Float(font.bracketInkBottomInAtlasPixels),
                xHeightInAtlasPixels: Float(font.metricsInputs.xHeightInAtlasPixels),
                capHeightInAtlasPixels: Float(font.capHeightInAtlasPixels),
                atlasScale: Float(font.atlasScale)
            )
        )
        // The palette's, not the style's. The style's three components are a
        // host-set copy that nothing outside a test ever set, so the letterbox
        // and every default-background cell painted black whatever theme was
        // live — a dark frame around the grid on any light theme. The palette
        // moves with the theme, and the snapshot carries it off the lock.
        // The pass clears to the same background the letterbox paints, not to
        // black: any pixel the frame does not cover — the rounding between a
        // grid of whole cells and a target of whole pixels — shows the clear,
        // and a black one draws a dark frame around the grid on a light theme.
        // The palette unless a host overrode it: the palette is what the theme
        // moves, and it reaches here off the model lock on the snapshot.
        // Under DECSET 7402's colour letterbox the ground is the letterbox,
        // off the same snapshot: the strip between the last whole cell and the
        // drawable's edge shows the clear, and a strip clearing to the theme
        // draws the theme around a frame the mode paints one colour. Opaque,
        // as the fill is — the letterbox is the window the terminal is not
        // using, and the desktop showing through it is what the mode removes.
        let isLetterboxed = snapshot.isEdgeToEdge
        let letterbox = snapshot.letterboxColor
        let backgroundRed =
            isLetterboxed
            ? Double((letterbox >> 16) & 0xFF) / 255
            : (style.defaultBackgroundRed ?? Double(snapshot.defaultBackgroundRed))
        let backgroundGreen =
            isLetterboxed
            ? Double((letterbox >> 8) & 0xFF) / 255
            : (style.defaultBackgroundGreen ?? Double(snapshot.defaultBackgroundGreen))
        let backgroundBlue =
            isLetterboxed
            ? Double(letterbox & 0xFF) / 255
            : (style.defaultBackgroundBlue ?? Double(snapshot.defaultBackgroundBlue))
        let groundOpacity = isLetterboxed ? 1.0 : style.backgroundOpacity
        // The pass clears to that same background at the frame's opacity,
        // rather than to black. The rounding between a grid of whole cells and
        // a target of whole pixels leaves a margin no quad covers, and a black
        // clear draws it as a border around the grid; an opaque clear under a
        // translucent frame is the desktop refused at the margin.
        var clearBackground = Ubiquitty.Rendering.Vec4()
        clearBackground.x = Float(backgroundRed)
        clearBackground.y = Float(backgroundGreen)
        clearBackground.z = Float(backgroundBlue)
        clearBackground.w = 1
        let passClearColor = TerminalRenderer.premultipliedClear(
            clearBackground,
            opacity: Float(groundOpacity),
            straight: options.style.unifontScale > 0
        )
        var defaultBackground = Ubiquitty.Rendering.Vec4()
        defaultBackground.x = Float(backgroundRed)
        defaultBackground.y = Float(backgroundGreen)
        defaultBackground.z = Float(backgroundBlue)
        defaultBackground.w = Float(isLetterboxed ? 1.0 : style.defaultBackgroundOpacity)
        applyFrameStyle(
            to: &options.style,
            FrameStyleInputs(
                shouldBrightenBold: style.shouldBrightenBold,
                shouldDrawBrailleGrid: style.shouldDrawBrailleGrid,
                defaultForegroundAlpha: style.defaultForegroundAlpha,
                underlineThicknessScale: style.underlineThicknessScale,
                underlineOffsetInPoints: style.underlineOffsetInPoints,
                shouldUnderlineSkipInk: style.shouldUnderlineSkipInk,
                shouldUnderlineFollowInk: style.shouldUnderlineFollowInk,
                underlineSkipInkPaddingInPoints: style.underlineSkipInkPaddingInPoints,
                deviceScale: deviceScale * Double(presentation.scale),
                uniformBackgroundOpacity: groundOpacity,
                uniformDefaultBackground: defaultBackground
            )
        )
        options.style.brailleStyle = style.brailleStyle.core
        options.style.shadeStyle = style.shadeStyle.core
        applyPlatformSelection(
            to: &options.style,
            selectionStyle: style.selectionStyle.core,
            isFocused: surface.isSurfaceFocused,
            hasSelection: Ubiquitty.Selection.hasSelection(surface.selectionModel.session.pointee)
        )
        options.style.shouldEnhanceTextContrast = style.shouldEnhanceTextContrast && !isLetterboxed
        options.style.preservesBackgroundTints = style.preservesBackgroundTints && !isLetterboxed
        options.style.promptMarkInk = .init(
            x: style.promptMarkInk.x,
            y: style.promptMarkInk.y,
            z: style.promptMarkInk.z,
            w: style.promptMarkInk.w
        )
        #if canImport(AppKit)
        options.style.usesNativeTextVibrancy =
            surface.secondaryTextPlane != nil && allowsFontPreparation && !isLetterboxed && !snapshot.isTekModeActive
        options.style.usesNativeBackgroundVibrancy =
            surface.backgroundVibrancyPlane != nil && allowsFontPreparation && !isLetterboxed && !snapshot.isTekModeActive
        if let plane = surface.secondaryTextPlane {
            options.style.nativeSecondaryInk = .init(
                x: plane.secondaryInk.x,
                y: plane.secondaryInk.y,
                z: plane.secondaryInk.z,
                w: plane.secondaryInk.w
            )
            options.style.nativeTertiaryInk = .init(
                x: plane.tertiaryInk.x,
                y: plane.tertiaryInk.y,
                z: plane.tertiaryInk.z,
                w: plane.tertiaryInk.w
            )
            if options.style.usesNativeTextVibrancy && style.vibrantPromptMarkInk.w > 0 {
                options.style.promptMarkInk = .init(
                    x: style.vibrantPromptMarkInk.x,
                    y: style.vibrantPromptMarkInk.y,
                    z: style.vibrantPromptMarkInk.z,
                    w: -style.vibrantPromptMarkInk.w
                )
            }
        }
        #endif
        // The link styling. The hovered run is the surface's — its pointer
        // tracking resolved it — and the conversion from absolute buffer rows
        // to this frame's visible ones is applyFrameLinks's, shared with the
        // Metal arm, which is why nothing here does arithmetic on it.
        //
        // The colour is the PALETTE's, off the snapshot, for the reason the
        // background above is: the style's components are a host-set copy that
        // nothing outside a test ever set, so every link cell drew black —
        // legible as text, wrong as a link, and wrong on every frame rather
        // than only the first. A host that sets one explicitly still wins,
        // which is what `link_color_blue` reaches this arm through.
        var linkColor = Ubiquitty.Rendering.Vec4()
        let hasHostLinkColor = style.linkColorRed > 0 || style.linkColorGreen > 0 || style.linkColorBlue > 0
        linkColor.x = Float(hasHostLinkColor ? style.linkColorRed : Double(snapshot.linkColorRed))
        linkColor.y = Float(hasHostLinkColor ? style.linkColorGreen : Double(snapshot.linkColorGreen))
        linkColor.z = Float(hasHostLinkColor ? style.linkColorBlue : Double(snapshot.linkColorBlue))
        linkColor.w = Float(style.linkColorAlpha)
        let hovered = surface.hoveredLinkRun
        // And the same for the hover, which had the same hole with a worse
        // ending: Core takes the hover colour whenever its ALPHA is above zero,
        // and the alpha defaulted to one while the components defaulted to
        // zero, so a hovered link drew black — the emphasis and the text the
        // same colour, which is a link that stops looking like one under the
        // pointer. The accent is `LinkAccentColor`, the one shared entry,
        // resolved for this surface's own appearance rather than whichever is
        // current while the frame is assembled.
        var linkHoverColor = Ubiquitty.Rendering.Vec4()
        let hasHostHoverColor =
            style.linkHoverColorRed > 0 || style.linkHoverColorGreen > 0
            || style.linkHoverColorBlue > 0
        #if canImport(AppKit)
        let accent = LinkAccentColor.components(under: surface.effectiveAppearance)
        #else
        let accent = LinkAccentColor.components
        #endif
        linkHoverColor.x = Float(hasHostHoverColor ? style.linkHoverColorRed : accent.red)
        linkHoverColor.y = Float(hasHostHoverColor ? style.linkHoverColorGreen : accent.green)
        linkHoverColor.z = Float(hasHostHoverColor ? style.linkHoverColorBlue : accent.blue)
        linkHoverColor.w = Float(style.linkHoverColorAlpha)
        var frameLinks = FrameLinkInputs(
            shouldUnderlineLinks: style.shouldUnderlineLinks,
            linkStyleIndex: Int32(style.linkStyleIndex),
            shouldResolveLinkKindsPerKind: style.shouldStyleLinksPerKind,
            linkColor: linkColor,
            hoverColor: linkHoverColor,
            isHoverLinkActive: hovered != nil,
            // The run's own id, so the per-cell test in `linkHoverContainsCell`
            // gates the band: an `id=` makes two runs separated by blanks one
            // link, and the blanks carry no id and stay unmarked. Zero for a run
            // the text scan found, which the same test reads as no gate at all.
            hoverLinkID: hovered?.linkID ?? 0,
            hoverRowAbsoluteFirst: hovered?.rowFirst ?? 0,
            hoverRowAbsoluteLast: hovered?.rowLast ?? 0,
            hoverColumnFirst: hovered?.columnFirst ?? 0,
            hoverColumnLast: hovered?.columnLast ?? 0,
            hoverSpanColumnFirst: hovered?.spanColumnFirst ?? 0,
            hoverSpanColumnLast: hovered?.spanColumnLast ?? -1,
            scrollbackCount: Int32(snapshot.scrollbackCount),
            viewOffset: Int32(surface.viewOffset),
            hoverTextDigest: hovered?.textDigest ?? 0
        )
        applyFrameLinks(to: &options, frameLinks)

        // Register the boundary-capture geometry whenever the drawable's
        // placement changed: the session captures each completed DECSET-2026
        // frame itself, and the registration is what steers that capture.
        // Keyed on the drawable size, scale, and atlas key, because the
        // registration carries the build's metrics and slot geometry; the model
        // lock inside it is taken on those edges, not per frame.
        // The style is part of the key: the registration stores the assembled
        // style whole, so a host that changed this renderer's style would
        // otherwise keep boundary captures on the style it replaced.
        let raster = renderer.frameRasterInputs
        let captureBackground = SIMD4(defaultBackground.x, defaultBackground.y, defaultBackground.z, defaultBackground.w)
        let captureOrigin = CGPoint(x: CGFloat(options.originInPixels.x), y: CGFloat(options.originInPixels.y))
        if surface.registeredSyncGeometryOrigin != captureOrigin
            || surface.registeredSyncGeometrySize != drawableSize
            || surface.registeredSyncGeometryScale != font.atlasScale
            || surface.registeredSyncStyle != style
            || surface.registeredSyncBackground != captureBackground
            || surface.registeredSyncBackgroundOpacity != groundOpacity
            || surface.isRegisteredSyncCursorFilled != options.isFocused
            || surface.registeredSyncViewOffset != surface.viewOffset
            || surface.registeredSyncRaster != raster
            || surface.registeredSyncCellWidth != frameMetrics.cellWidth
            || surface.registeredSyncSheetKey != currentSheetKey
        {
            // The placement and style are the ones the live path below
            // applies — copied from the same assembled options, so the two
            // capture routes cannot drift a field apart.
            var geometry = Ubiquitty.Runtime.SyncFrameCaptureGeometry()
            geometry.viewOffset = options.viewOffset
            // Focus rides the same assembled options as the style, so the
            // boundary route's cursor and the live route's agree.
            geometry.isFocused = options.isFocused
            geometry.shouldCursorInvertText = options.shouldCursorInvertText
            geometry.originInPixels = options.originInPixels
            geometry.viewportSizeInPixels = options.viewportSizeInPixels
            geometry.cellHeightPoints = options.cellHeightPoints
            geometry.lineSpacingPoints = options.lineSpacingPoints
            geometry.promptMarkFontSize = options.promptMarkFontSize
            geometry.promptMarkFontAscent = options.promptMarkFontAscent
            geometry.promptMarkFontDescent = options.promptMarkFontDescent
            geometry.promptMarkLineGapTopInPixels = options.promptMarkLineGapTopInPixels
            geometry.promptMarkBracketInkTopInPixels = options.promptMarkBracketInkTopInPixels
            geometry.promptMarkBracketInkBottomInPixels = options.promptMarkBracketInkBottomInPixels
            geometry.promptMarkFontXHeight = options.promptMarkFontXHeight
            geometry.promptMarkFontCapHeight = options.promptMarkFontCapHeight
            geometry.promptMarkAtlasScale = options.promptMarkAtlasScale
            // The style stores whole: the borrow that made it nonescapable
            // lives on the options now.
            geometry.style = options.style
            // The link styling's durable half, from the same assembled
            // options as the style so the two capture routes cannot drift;
            // hover stays out of the registration on purpose — it would
            // outlive the pointer position it recorded.
            geometry.shouldUnderlineLinks = options.shouldUnderlineLinks
            geometry.linkUnderlineStyle = options.linkUnderlineStyle
            geometry.linkColor = options.linkColor
            geometry.linkHoverColor = options.linkHoverColor
            // The frame's metrics, DECCOLM's compression included, so the
            // boundary route lays its cells out on the advance the live
            // route draws.
            geometry.metrics = frameMetrics
            geometry.glyphSlot = renderer.atlasSlotGeometry
            // The atlas facts the live route applies above, so the boundary
            // route's own `applyFrameRaster` call lands on the same grid: a
            // phase bucket's difference between the two is text that shifts
            // sideways on alternate frames while a reader types.
            geometry.raster.subpixelPhaseCount = raster.subpixelPhaseCount
            geometry.raster.widePhaseCount = raster.widePhaseCount
            geometry.raster.isCoreTextRaster = raster.isCoreTextRaster
            geometry.raster.unifontScale = raster.unifontScale
            // The wheel policy's points-per-line rides the same resolve as the
            // frame it annotates.
            surface.scrollbackCellHeightPoints = CGFloat(frameMetrics.cellHeight) / contentsScale
            surface.drive.setSyncFrameCaptureGeometry(geometry)
            surface.registeredSyncGeometryOrigin = captureOrigin
            surface.registeredSyncGeometrySize = drawableSize
            surface.registeredSyncGeometryScale = font.atlasScale
            surface.registeredSyncStyle = style
            surface.registeredSyncBackground = captureBackground
            surface.registeredSyncBackgroundOpacity = groundOpacity
            surface.isRegisteredSyncCursorFilled = options.isFocused
            surface.registeredSyncViewOffset = surface.viewOffset
            surface.registeredSyncRaster = raster
            surface.registeredSyncCellWidth = frameMetrics.cellWidth
            surface.registeredSyncSheetKey = currentSheetKey
        }

        // A frame frozen at a DECSET-2026 boundary presents ahead of the live
        // read: the live capture below can catch a mid-frame state, which is
        // the artefact the boundary capture exists to exclude. A surface with
        // an active selection takes the live path, whose capture resolves the
        // selection tint from the terminal — the override path substitutes
        // every tier field it names, so routing a selection through it needs
        // the tint resolved on this side of the seam first.
        //
        // The frame after a selection ends takes the live path too. A selection
        // behind the text is in the retained cells, and the live capture is
        // the one that remembers it and repaints the rows it leaves; the
        // boundary capture reuses those rows without knowing they hold it.
        let hasSelection = Ubiquitty.Selection.hasSelection(surface.selectionModel.session.pointee)
        let didDrawSelection = surface.didLastFrameDrawSelection
        surface.didLastFrameDrawSelection = hasSelection
        // A surface showing search matches keeps the live path too: a
        // boundary frame is built without the search tiers, so the frame it
        // presents drops every match and leaves the focused match's cells in
        // the retained grid unfilled. Under a saturated drain the live route
        // draws nothing, so the boundary frame presents there, and the first
        // live frame after the flood paints the tiers back; Core's plan owes
        // it the focused match's rows.
        let keepsSearchLive = surface.didLastFrameDrawSearch && !surface.drive.isDrainSaturated
        if !hasSelection, !didDrawSelection, !keepsSearchLive,
            let syncFrame = surface.drive.takeSyncFrame()
        {
            surface.didLastFrameDrawSearch = false
            // Live changes can follow the captured boundary before this display
            // request is consumed. On-demand presentation needs another pass
            // to observe them even when no further output arrives.
            defer { surface.askForAnotherFrame() }
            let modelTakenAt = isPerfLogged ? CACurrentMediaTime() : 0
            renderer.notePaintHeat(of: syncFrame)
            // Content captures freeze the grid, while the cursor overlay follows
            // the same presentation clock as frames captured for this refresh.
            syncFrame.setCursorMixAlpha(options.cursorMixAlpha)
            // The window's picture belongs under this frame as under a live
            // one; a boundary frame drawn without it clears it off the glass.
            renderer.setBackdrop(
                texture: backdropTexture,
                opacity: backdropOpacity,
                mode: backdropMode,
                pixelWidth: backdropPixelWidth,
                pixelHeight: backdropPixelHeight
            )
            let view = Ubiquitty.Rendering.FrameCapture.ViewTierOverrides()
            guard var pending = renderer.buildFrame(captured: syncFrame, view: view)
            else {
                // A frame that reproduced the glass was consumed and not
                // composited: the drawable goes back unpresented, the verdict
                // reads as a reused frame of no rows, and no retry is asked.
                if renderer.didDeferForFontPreparation {
                    noteFrameNotPresented(for: surface, renderer: renderer)
                }
                if renderer.didLastFramePresentNothing {
                    didReuseLastFrame = true
                    lastFramePlannedRows = Int(snapshot.rows)
                    lastFrameDirtyRows = 0
                    didTrustDirtySetLastFrame = true
                    phaseLogReuseTerms = "skipped"
                    skippedAsReproducingGlassCount += 1
                    return true
                }
                lastFrameDecline = .boundaryBuild
                return false
            }
            // The boundary route's own verdict, restated here or the flags
            // keep an earlier live frame's for whichever caller follows a late
            // capture: a Delta that Loaded the retained grid reports the rows
            // its capture owned, a Full or refused one every row and no
            // trusted set. An oracle reading the pair sees this frame, not a
            // cleared target trusting a partial damage set.
            pending.viewportClipInPixels = presentation.clip
            surface.noteFrameImageQuads(Int32(pending.imageQuadCount))
            let didReuseBoundaryGrid = renderer.didBoundaryFrameReuseGrid
            didReuseLastFrame = didReuseBoundaryGrid
            lastFramePlannedRows = Int(snapshot.rows)
            lastFrameDirtyRows = didReuseBoundaryGrid ? renderer.boundaryFrameDirtyRows : lastFramePlannedRows
            didTrustDirtySetLastFrame = didReuseBoundaryGrid
            phaseLogReuseTerms = didReuseBoundaryGrid ? "" : "boundary"
            lastFrameCounts = renderer.counts
            let waitStartedAt = isPerfLogged ? CACurrentMediaTime() : 0
            guard let target = target() else {
                noteFrameNotPresented(for: surface, renderer: renderer)
                lastFrameDecline = .boundaryDrawable
                return false
            }
            target.descriptor.colorAttachments[0].clearColor = passClearColor
            let passEncodeStartedAt = isPerfLogged ? CACurrentMediaTime() : 0
            guard
                let commands = renderer.encode(
                    pending,
                    secondaryDescriptor: target.secondaryDescriptor,
                    backgroundDescriptor: target.backgroundDescriptor,
                    into: target.descriptor
                )
            else {
                noteFrameNotPresented(for: surface, renderer: renderer)
                lastFrameDecline = .boundaryEncode
                return false
            }
            let commitStartedAt = isPerfLogged ? CACurrentMediaTime() : 0
            if isPerfLogged {
                presentLeg.arm(modelTakenAt)
            }
            commit(
                commands,
                presenting: target.drawable,
                secondaryDrawable: target.secondaryDrawable,
                backgroundDrawable: target.backgroundDrawable,
                transactionally: presentsWithTransaction
            )
            notePresentedGeometry(for: surface, frame: pending, deviceScale: deviceScale, panOffset: presentation.panOffset)
            if isPerfLogged {
                let finishedAt = CACurrentMediaTime()
                perfFrame.drawSeconds = finishedAt - modelTakenAt
                perfFrame.drawableWaitSeconds = passEncodeStartedAt - waitStartedAt
                perfFrame.encodeSeconds = commitStartedAt - passEncodeStartedAt
                perfFrame.commitSeconds = finishedAt - commitStartedAt
                notePerfFrame(perfFrame, for: surface, renderer: renderer)
            }
            return true
        }

        // Resizing must not wait for quiet output: a busy program can keep
        // repainting throughout the drag. Explicit synchronized-output blocks
        // still hold the live capture, and so does a repaint still arriving
        // behind its erase, both checked under its model lock below.
        let isResizing = surface.isInLiveResizeGesture || surface.isDrawingResizeStep
        if !isResizing, surface.drive.shouldWithholdFrame(nowTicks: TerminalSurface.monotonicTicksNow()) {
            surface.deferHeldPresentation()
            lastFrameDecline = .withheld
            return false
        }

        // Under a saturated flood the drain publishes each full pass's frame
        // and the route above presents it. A tick that found the slot empty is
        // between two captures, and going to the model for it means waiting on
        // the lock the parser holds for the whole burst — measured as a third
        // of this thread's time, and the CPU the flood reader's spin band
        // loses to it. The tick is skipped; the next capture is at most one
        // publish window away, and the link fires again regardless.
        if surface.drive.isDrainSaturated {
            lastFrameDecline = .drainSaturated
            return false
        }

        let lockStartedAt = isPerfLogged ? CACurrentMediaTime() : 0
        surface.drive.lockForRead()
        var didCaptureFrame = false
        var lockedStamp: RetainedStamp?
        if let terminal = surface.drive.borrowTerminal() {
            // The parser can open a block or erase the screen after the
            // published snapshot check. Recheck under the capture's lock before
            // consuming damage or cursor state.
            let nowTicks = TerminalSurface.monotonicTicksNow()
            let shouldWithhold =
                isResizing
                ? Ubiquitty.Modes.SyncOutput.shouldWithholdFrame(terminal, Ubiquitty.Ticks(nowTicks))
                : surface.drive.shouldWithholdCapture(terminal, nowTicks: nowTicks)
            if shouldWithhold {
                surface.drive.unlockForRead()
                surface.deferHeldPresentation()
                lastFrameDecline = .blockOpenUnderLock
                return false
            }
            // A full-screen program answers each step's size with an erase and
            // a repaint that reaches the parser over many reads. A step drawn
            // between them would present the erased screen, so the previous
            // frame stays on the glass until the drain has caught up with the
            // repaint, which waits for no quiet output.
            if isResizing, surface.drive.isEraseRedrawArriving(terminal) {
                surface.drive.unlockForRead()
                surface.deferPresentationForArrivingRedraw()
                lastFrameDecline = .redrawArriving
                return false
            }
            // The frame's origin is Core's. Under DECSET 7402's colour
            // letterbox the padding is absent, and the capture zeroes whatever
            // origin it is handed; read here, under the lock the capture reads
            // under, so the retained plan's row mapping and the image layer's
            // origin describe the frame the capture will paint rather than the
            // one before the mode moved.
            let isEdgeToEdge = Ubiquitty.Rendering.isFrameEdgeToEdge(terminal)
            if isEdgeToEdge {
                options.originInPixels = Ubiquitty.FloatPoint(x: 0, y: 0)
            }
            // Link addresses and captured cells must use the same history depth.
            frameLinks.scrollbackCount = terminal.scrollbackCount
            frameLinks.viewOffset = Ubiquitty.Screen.resolvedViewOffset(terminal, options.viewOffset)
            applyFrameLinks(to: &options, frameLinks)
            surface.noteFrameHoverRun(
                isActive: options.isHoverLinkActive,
                rowFirst: options.hoverLinkRowFirst,
                rowLast: options.hoverLinkRowLast,
                columnFirst: options.hoverLinkColumnFirst,
                columnLast: options.hoverLinkColumnLast,
                color: (options.linkHoverColor.x, options.linkHoverColor.y, options.linkHoverColor.z)
            )
            // The highlight spans are resolved under the same lock the capture
            // reads under, into surface-owned scratch the options borrow only
            // for the capture call.
            let selection = surface.selectionModel
            let rows = Int(snapshot.rows)
            let metrics = frameMetrics
            // Core plans the retained frame under the same lock the capture
            // reads under, and the one plan decides both halves: which rows the
            // capture re-reads, and whether the encode Loads the target. Planned
            // here rather than in the renderer because the drain mutates the grid
            // and the lock is held exactly here.
            // The stamp joins the size in the target verdict: a retained
            // texture drawn under a replaced styling or a superseded palette
            // is wrong the way a wrong-sized one is — its pixels do not
            // describe this frame — and the full plan is the same cure.
            // The model epoch is read under the same lock the capture reads
            // under: OSC 4 moves it on the ingest thread, and this frame's
            // verdict must see the move the capture will paint.
            let stamp = RetainedStamp(
                style: style,
                contentEpoch: surface.retainedContentEpoch,
                origin: CGPoint(x: CGFloat(options.originInPixels.x), y: CGFloat(options.originInPixels.y)),
                paletteEpoch: terminal.paletteEpoch,
                isEdgeToEdge: isEdgeToEdge
            )
            let isRetainedContentCurrent = retainedStamps[ObjectIdentifier(renderer)] == stamp
            lockedStamp = stamp
            // A renderer whose sheets refused a slot, or whose pins have grown
            // to crowd the next frame, asks for a build that touches every
            // row: the retained set only re-baselines exactly against one, and
            // dropping the pins under a partial build would strip the clean
            // rows' protection while their quads still sample the sheets. The
            // grant is refusing the retained target for this frame, and the
            // re-baseline goes with it — a request nothing answers leaves the
            // pins to accumulate until the sheets refuse for good.
            // The backdrop is installed before the grant is read: a backdrop
            // removed or replaced asks for a whole frame, and this is it.
            renderer.setBackdrop(
                texture: backdropTexture,
                opacity: backdropOpacity,
                mode: backdropMode,
                pixelWidth: backdropPixelWidth,
                pixelHeight: backdropPixelHeight
            )
            let grantsFullRebuild = renderer.wantsFullRebuild
            let reusesRetainedContent =
                isRetainedContentCurrent
                && renderer.gridMatches(
                    widthInPixels: Int(drawableSize.width),
                    heightInPixels: Int(drawableSize.height),
                    // The numbers this frame's uniforms will carry, so the
                    // verdict and the encode cannot answer differently.
                    cellWidthInPixels: metrics.cellWidth,
                    cellHeightInPixels: metrics.cellHeight
                )
            // Under the opaque letterbox no pixel reads a cell: Core hands back
            // a plan that drains nothing and copies nothing, and leaves the
            // baseline gone so the first frame after the mode re-reads every
            // row. The builder paints the letterbox from the mode, so the
            // cells the capture keeps are never read.
            let skipsGridCapture = Ubiquitty.Rendering.canSkipGridCapture(
                terminal,
                SurfaceRenderer.isOcclusionSkipEnabled ? .Enabled : .Disabled
            )
            let plan: Ubiquitty.Rendering.RetainedFramePlan
            if skipsGridCapture {
                gridCaptureSkipCount += 1
                plan = surface.planSkippedGridFrame(terminal, rows: rows, columns: Int(snapshot.columns))
            } else {
                plan = surface.planRetainedFrame(
                    terminal,
                    rows: rows,
                    columns: Int(snapshot.columns),
                    target: !grantsFullRebuild && reusesRetainedContent,
                    hasBackdrop: backdropTexture != nil,
                    cellHeightInPixels: Int(metrics.cellHeight.rounded()),
                    originYInPixels: Int(options.originInPixels.y.rounded()),
                    textureHeightInPixels: Int(drawableSize.height)
                )
            }
            // The plan's verdict, not this side's guess: Core refuses the
            // retained target for reasons the two locals above cannot see — a
            // blink phase, a status row, a drain that lost the damage — and
            // every one of those frames rebuilds every row. A full rebuild
            // whose touches are ACCUMULATED instead of re-baselined pins the
            // whole screen's strips on top of the old set, which reaches the
            // sheet's crowding line in a handful of blinks.
            if !plan.shouldLoadRetainedTarget {
                renderer.rebaselineRetainedFrame()
            }
            didReuseLastFrame = plan.shouldLoadRetainedTarget
            didTrustDirtySetLastFrame = plan.refresh.canReuseRows
            if !plan.refresh.canReuseRows {
                gridFullRereadCount += 1
            }
            if SurfaceRenderer.isPhaseLogEnabled {
                var terms: [String] = []
                if skipsGridCapture { terms.append("letterbox") }
                if grantsFullRebuild { terms.append("sheets") }
                if !isRetainedContentCurrent { terms.append("stamp") }
                if !reusesRetainedContent && isRetainedContentCurrent { terms.append("grid") }
                if !plan.shouldLoadRetainedTarget && !grantsFullRebuild && reusesRetainedContent {
                    terms.append("core")
                }
                phaseLogReuseTerms = terms.joined(separator: "+")
            }
            lastFramePlannedRows = rows
            lastFrameDirtyRows = surface.rowDirtyScratch.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
            if SurfaceRenderer.isPhaseLogEnabled {
                phaseLogRowSignature = SurfaceRenderer.rowSignature(of: terminal, rows: rows, columns: Int(snapshot.columns))
            }
            if framesToReportAfterAdopt > 0 {
                framesToReportAfterAdopt -= 1
                NSLog(
                    "UBQ_FONTLOG frame reused=%@ planned=%d dirty=%d",
                    plan.shouldLoadRetainedTarget ? "1" : "0",
                    rows,
                    lastFrameDirtyRows
                )
            }
            // The status row rides the same lock the capture reads under,
            // into surface-owned stable bytes the options borrow for the
            // capture call — the highlight spans' pattern.
            let columns = Int(snapshot.columns)
            lastFrameHadStatusRow = false
            if columns > 0 {
                let scratch = surface.statusRowScratch(capacity: columns)
                if Ubiquitty.Rendering.fillStatusRow(
                    terminal,
                    Int32(rows),
                    Int32(columns),
                    Int32(surface.viewOffset),
                    Ubiquitty.Rendering.StatusRowCells(scratch)
                ) {
                    options.statusRowCells = UnsafePointer(scratch.baseAddress)
                    options.statusRowColumns = Int32(columns)
                    lastFrameHadStatusRow = true
                }
            }
            // The inline images, synced and resolved under the same lock the
            // capture reads under, so the layer and the cells are one frame.
            let images = renderer.imageStore.layer(
                for: terminal,
                cellSizeInPixels: Ubiquitty.FloatSize(width: metrics.cellWidth, height: metrics.cellHeight),
                origin: options.originInPixels,
                scale: metrics.deviceScale,
                presentationScale: presentation.scale,
                viewOffset: options.viewOffset,
                drawableSizeInPixels: options.viewportSizeInPixels,
                isHoldingForResize: surface.isHoldingImageGapsForResize
            )
            surface.noteFrameImageQuads(Int32(images?.quadCount ?? 0))
            // All overlay and selection borrows enclose the CAPTURE that consumes
            // them, under the terminal's model lock. The build does not run here:
            // the capture copies the rows into storage it owns, so the builder —
            // the expensive half — reads that copy instead, and holding the lock
            // across it would block the ingest thread for the whole frame rather
            // than for the copy.
            didCaptureFrame = selection.withOverlayTiers(
                terminal,
                viewOffset: Int32(surface.viewOffset),
                rows: rows,
                options: options
            ) { options in
                var options = options
                // The tiers this capture draws, resolved under its lock, are
                // what the next frame's route reads.
                surface.didLastFrameDrawSearch = options.searchMatchSpanCount > 0 || options.otherSearchMatchSpanCount > 0
                guard Ubiquitty.Selection.hasSelection(selection.session.pointee), rows > 0 else {
                    selection.visibleEnds = nil
                    return renderer.captureFrame(
                        terminal,
                        options: options,
                        metrics: metrics,
                        plan: plan,
                        images: images
                    )
                }
                // Room for every span and piece Core can make of the grid: a
                // rich text block cuts a row's span around its covered cells,
                // and a sized block adds a piece for each run of its cells.
                let spanCapacity = Int(Ubiquitty.Selection.viewportSpanCapacity(Int32(rows), Int32(columns)))
                if selection.spanScratch.count < spanCapacity {
                    selection.spanScratch = Array(repeating: Ubiquitty.Rendering.SelectionRowSpan(), count: spanCapacity)
                }
                if selection.blockScratch.isEmpty {
                    selection.blockScratch = Array(
                        repeating: Ubiquitty.RichText.BlockSelection(),
                        count: 2 * Int(Ubiquitty.RichText.maxBlocksPerScreen)
                    )
                }
                return selection.spanScratch.withUnsafeMutableBufferPointer { spans -> Bool in
                    var ends = Ubiquitty.Selection.ViewportEnds()
                    let count = Ubiquitty.Selection.viewportSpansAndEnds(
                        &selection.session.pointee,
                        terminal,
                        Int32(surface.viewOffset),
                        Ubiquitty.Selection.ViewportSpans(spans),
                        &ends
                    )
                    options.selectionSpans = UnsafePointer(spans.baseAddress)
                    options.selectionSpanCount = count
                    // The selection's own ends, which the highlight's spans are
                    // not: a sized block adds pieces that are neither.
                    selection.visibleEnds =
                        ends.isVisible
                        ? ((Int(ends.startRow), Int(ends.startColumn)), (Int(ends.endRow), Int(ends.endColumn)))
                        : nil
                    return selection.blockScratch.withUnsafeMutableBufferPointer { blocks -> Bool in
                        let selections = Ubiquitty.RichText.BlockSelections(blocks)
                        options.richTextSelectionCount = Ubiquitty.Selection.blockSelections(
                            &selection.session.pointee,
                            terminal,
                            selections
                        )
                        options.richTextSelections = selections
                        return renderer.captureFrame(
                            terminal,
                            options: options,
                            metrics: metrics,
                            plan: plan,
                            images: images
                        )
                    }
                }
            }
        }
        surface.drive.unlockForRead()
        // The model this frame shows is taken: the present leg runs from
        // here to the glass, and the snapshot share is what came before.
        let modelTakenAt = isPerfLogged ? CACurrentMediaTime() : 0
        // Off the lock, against the copy the capture owns: the ingest thread
        // runs through this, and the builder reads no model state.
        let pending = didCaptureFrame ? renderer.buildCapturedFrame() : nil
        cellRefusalsAfterTrust = renderer.retainedCellRefusalsAfterTrust
        lastFrameCounts = renderer.counts
        // The pixels the sync copied out of the model, moved to their textures
        // now that the parser is no longer waiting on this thread. Before the
        // commit below, so this frame draws them.
        renderer.imageStore.uploadStagedPixels()

        guard var pending else {
            if renderer.didDeferForFontPreparation {
                noteFrameNotPresented(for: surface, renderer: renderer)
            }
            // The frame reproduced the glass: nothing is composited, the
            // verdicts already read reused with no dirty row, and no retry is
            // asked.
            if renderer.didLastFramePresentNothing {
                phaseLogReuseTerms = "skipped"
                skippedAsReproducingGlassCount += 1
                return true
            }
            lastFrameDecline = didCaptureFrame ? .build : .capture
            return false
        }
        // The target this frame drew carries this frame's styling and palette;
        // stamped only on success, so a declined frame keeps forcing the full
        // plan rather than certifying a target it never wrote. The lock-time
        // stamp, not a fresh reading: an epoch that moved mid-encode belongs
        // to the next frame's verdict, and re-reading it here would certify
        // a target against colours it never painted.
        pending.viewportClipInPixels = presentation.clip
        if let lockedStamp {
            retainedStamps[ObjectIdentifier(renderer)] = lockedStamp
        }
        isFocusedMatchBouncing = renderer.isFocusedMatchBouncing
        // The drawable is asked for with the frame built and the lock
        // released: the wait for one never delays the capture. A frame denied
        // one was built and not shown, and the renderer must not count it as
        // what the glass holds.
        let waitStartedAt = isPerfLogged ? CACurrentMediaTime() : 0
        guard let target = target() else {
            noteFrameNotPresented(for: surface, renderer: renderer)
            lastFrameDecline = .drawable
            return false
        }
        target.descriptor.colorAttachments[0].clearColor = passClearColor
        let passEncodeStartedAt = isPerfLogged ? CACurrentMediaTime() : 0
        guard
            let commands = renderer.encode(
                pending,
                secondaryDescriptor: target.secondaryDescriptor,
                backgroundDescriptor: target.backgroundDescriptor,
                into: target.descriptor
            )
        else {
            noteFrameNotPresented(for: surface, renderer: renderer)
            lastFrameDecline = .encode
            return false
        }
        let commitStartedAt = isPerfLogged ? CACurrentMediaTime() : 0
        if isPerfLogged {
            presentLeg.arm(modelTakenAt)
        }
        commit(
            commands,
            presenting: target.drawable,
            secondaryDrawable: target.secondaryDrawable,
            backgroundDrawable: target.backgroundDrawable,
            transactionally: presentsWithTransaction
        )
        notePresentedGeometry(for: surface, frame: pending, deviceScale: deviceScale, panOffset: presentation.panOffset)
        if isPerfLogged {
            let finishedAt = CACurrentMediaTime()
            perfFrame.drawSeconds = finishedAt - modelTakenAt
            perfFrame.snapshotSeconds = modelTakenAt - lockStartedAt
            perfFrame.drawableWaitSeconds = passEncodeStartedAt - waitStartedAt
            perfFrame.encodeSeconds = commitStartedAt - passEncodeStartedAt
            perfFrame.commitSeconds = finishedAt - commitStartedAt
            notePerfFrame(perfFrame, for: surface, renderer: renderer)
        }
        // Counted where a frame is finished rather than where its options were
        // filled: the encode is nearly all of what follows that point, and a
        // stamp taken mid-build reports a prefix as a frame.
        surface.framesEncodedForTesting += 1
        let encodeSeconds = ProcessInfo.processInfo.systemUptime - encodeStartedAt
        surface.frameEncodeSecondsForTesting += encodeSeconds
        // The other half of a live-resize step's cost, paired with the reflow
        // the resize path timed, so a drag's cost is measured rather than
        // guessed.
        if let reflowSeconds = surface.lastLiveResizeReflowSeconds {
            surface.lastLiveResizeReflowSeconds = nil
            if SurfaceRenderer.isPerflogEnabled {
                FileHandle.standardError.write(
                    Data(
                        String(
                            format: "[resize] reflow=%6.2fms  draw=%6.2fms  %.0fx%.0f\n",
                            reflowSeconds * 1000,
                            encodeSeconds * 1000,
                            surface.bounds.width,
                            surface.bounds.height
                        )
                        .utf8
                    )
                )
            }
        }
        return true
    }

    /// Assembles and encodes one Tektronix frame, under the model lock.
    ///
    /// The platform inputs resolve here — the colours through Core's three
    /// resolvers, the beam thickness, the glyph baseline — and the pass
    /// strokes the display list through Core's one walk, so a disagreement
    /// with the Metal arm's view is geometry the pass owns rather than a
    /// setting read twice. Tek reads the live display list, which the ingest
    /// thread mutates, so the whole assembly brackets in the lock.
    ///
    /// - Parameters:
    ///   - surface: The surface whose terminal is in Tek mode.
    ///   - renderer: The surface's frame renderer, whose Tek pass encodes.
    ///   - deviceScale: Backing pixels per point, which sizes the beam, its
    ///     halo and the projection's edge inset through Core's beam geometry.
    ///   - descriptor: The pass to encode into.
    /// - Returns: The encoded, uncommitted command buffer, or nil.
    private func encodeTekFrame(
        for surface: TerminalSurface,
        renderer: TerminalRenderer,
        deviceScale: Double,
        into descriptor: MTLRenderPassDescriptor
    ) -> MTLCommandBuffer? {
        let font = current.font
        var preference = Ubiquitty.Tek.ColorPreference()
        preference.mode = tekSettings.usesCustomColors ? .Custom : .Theme
        preference.beam = Ubiquitty.Tek.tekColorFromPackedRGB(tekSettings.customBeamRGB)
        preference.background = Ubiquitty.Tek.tekColorFromPackedRGB(tekSettings.customBackgroundRGB)

        var uniforms = Ubiquitty.Rendering.FrameUniforms()
        if let target = descriptor.colorAttachments[0].texture {
            uniforms.viewportSizeInPixels = .init(x: Float(target.width), y: Float(target.height))
        }
        uniforms.cellSizeInPixels = .init(x: 1, y: 1)
        uniforms.backgroundOpacity = Float(style.backgroundOpacity)
        uniforms.bitmapTier = font.unifontScale > 0 ? 1 : 0

        surface.drive.lockForRead()
        defer { surface.drive.unlockForRead() }
        guard let terminal = surface.drive.borrowTerminal() else {
            return nil
        }
        // The model's palette carries 16-bit channels; the resolvers take the
        // 8-bit theme colour and widen, so the narrowing divides by the same
        // 257 the widening multiplies by — lossless for a theme that arrived
        // as 8-bit, which is every theme the config can express.
        let background = Ubiquitty.Tek.tekBackground(terminal, Self.narrowColor(terminal.palette.defaultBackground), preference)
        let beam = Ubiquitty.Tek.tekBeam(terminal, Self.narrowColor(terminal.palette.defaultForeground), preference)
        let cursor = Ubiquitty.Tek.tekCursor(terminal, beam)
        uniforms.defaultBackground = Self.tekFloat4(background)
        let spotSetting: Ubiquitty.Tek.WritingSpotSetting = tekSettings.drawsWritingSpot ? .Drawn : .Suppressed
        let drawsBrightPen = Ubiquitty.Tek.isWritingSpotDrawn(terminal, spotSetting)
        let primitives = Ubiquitty.tekVisiblePrimitives(terminal)
        return renderer.encodeTekFrame(
            uniforms: uniforms,
            primitives: primitives.size() > 0 ? primitives.__dataUnsafe() : nil,
            primitiveCount: Int32(primitives.size()),
            tekWidth: Int32(Ubiquitty.tekScreenWidth(terminal)),
            tekHeight: Int32(Ubiquitty.tekScreenHeight(terminal)),
            isGINActive: Ubiquitty.tekGINActive(terminal),
            ginX: Int32(Ubiquitty.tekGINX(terminal)),
            ginY: Int32(Ubiquitty.tekGINY(terminal)),
            drawsBrightPen: drawsBrightPen,
            beam: Self.tekFloat4(beam),
            cursor: Self.tekFloat4(cursor),
            deviceScale: Float(deviceScale),
            drawsGlow: tekSettings.drawsGlowVectors,
            into: descriptor
        )
    }

    /// The model's 16-bit palette channels as the resolvers' 8-bit theme
    /// colour; 257 is the widening factor, so the round trip is exact.
    private static func narrowColor(_ color: Ubiquitty.PaletteRGB) -> Ubiquitty.ColorRGBA {
        var narrowed = Ubiquitty.ColorRGBA()
        narrowed.red = UInt8(color.red / 257)
        narrowed.green = UInt8(color.green / 257)
        narrowed.blue = UInt8(color.blue / 257)
        return narrowed
    }

    /// Core's 16-bit channels as the pass's opaque colour: a storage tube has
    /// no transparency — the beam wrote a point or it did not.
    private static func tekFloat4(_ color: Ubiquitty.Tek.TekColor) -> Ubiquitty.Rendering.Vec4 {
        var vector = Ubiquitty.Rendering.Vec4()
        vector.x = Float(color.red) / 65535
        vector.y = Float(color.green) / 65535
        vector.z = Float(color.blue) / 65535
        vector.w = 1
        return vector
    }
}

/// The storage tube's per-renderer settings: the user's colour choice and
/// the two toggles. Plain values a host sets from config; the OSC overrides
/// outrank them inside Core's resolvers.
public struct SurfaceTekSettings: Hashable, Sendable {
    /// Whether the custom phosphor pair below stands in for the theme's.
    public var usesCustomColors: Bool
    /// The custom beam, packed 0xRRGGBB.
    public var customBeamRGB: UInt32
    /// The custom tube background, packed 0xRRGGBB.
    public var customBackgroundRGB: UInt32
    /// Whether the writing spot draws at the beam's rest.
    public var drawsWritingSpot: Bool
    /// Whether the additive bloom pass runs under the strokes.
    public var drawsGlowVectors: Bool

    /// Builds the settings, defaulting to theme colours, the spot drawn and
    /// no glow.
    ///
    /// - Parameters:
    ///   - usesCustomColors: Whether the custom pair replaces the theme's.
    ///   - customBeamRGB: The custom beam, packed 0xRRGGBB.
    ///   - customBackgroundRGB: The custom background, packed 0xRRGGBB.
    ///   - drawsWritingSpot: Whether the writing spot draws.
    ///   - drawsGlowVectors: Whether the bloom pass runs.
    public init(
        usesCustomColors: Bool = false,
        customBeamRGB: UInt32 = 0x33FF33,
        customBackgroundRGB: UInt32 = 0x001100,
        drawsWritingSpot: Bool = true,
        drawsGlowVectors: Bool = false
    ) {
        self.usesCustomColors = usesCustomColors
        self.customBeamRGB = customBeamRGB
        self.customBackgroundRGB = customBackgroundRGB
        self.drawsWritingSpot = drawsWritingSpot
        self.drawsGlowVectors = drawsGlowVectors
    }

    /// Returns the settings the process configuration names.
    ///
    /// - Returns: The styling a Tektronix frame draws under now.
    public static func configured() -> SurfaceTekSettings {
        SurfaceTekSettings(configuration: Ubiquitty.Preferences.Effective.liveRenderConfiguration())
    }
}

/// Carries a frame's present-leg poster onto the present thread.
///
/// Unchecked because the poster is a C++ value the importer marks nothing
/// about: its one method is const and posts into a lock-free single-producer
/// ring whose one producer is the present thread the handlers run on.
private struct PresentLegPost: @unchecked Sendable {
    let poster: Ubiquitty.Runtime.PresentLegMeter.Poster
}
