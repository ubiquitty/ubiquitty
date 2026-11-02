// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Renderer.swift — the macOS renderer's Core-facing half.
//
// `UBRenderer` reaches Core through one seam: it assembles a `CellMetrics` and a
// `TerminalSnapshotOptions`, hands both to `buildCellInstances`, and encodes what
// comes back. Nothing in that assembly is Metal, AppKit or CoreText — it is
// arithmetic over the renderer's own scalars, which is why it can live here while
// the encoder cannot.
//
// Every quantity this produces is consumed by portable code. The types are Core's
// own (`Ubiquitty::Rendering::CellMetrics`), reached through
// `-cxx-interoperability-mode=default` with no ObjC facade, so a field added in
// Core arrives here as a compile error rather than as an unset default.
//
// What this file cannot take:
//
//   Per-cell and per-row work. Swift here gets neither PGO nor ThinLTO —
//   Scripts/build-macos.sh applies both only to the C-family flags — so code the
//   frame walks over stays in Core, where the profile reaches it.
//
//   Any float expression shaped `a * b + c`. Clang contracts it to an FMA under
//   -ffp-contract=on, the tree's default; Swift does not contract. The two arms
//   would then disagree in the last bit with no way to attribute the pixel. Every
//   expression below was checked against that shape: they are multiply/divide
//   chains, or an add whose SUM is multiplied, which is not the contractable form.
//
//   A `SIMD2`/`SIMD4` parameter. One makes the whole function `Unavailable in
//   C++` in the generated header, so C++ cannot call it. Extents cross as
//   paired scalars.
//
//   Core's own `Vec4` is not one of those, and crosses as a parameter: the
//   generated header renders it `const Ubiquitty::Rendering::Vec4&` with nothing
//   marked unavailable. A colour therefore crosses as one value. Scalars here
//   mean a component the caller does not get to choose, not a limit of the seam.

import UbiquittyCore

/// The renderer scalars the cell metrics are derived from.
///
/// A parameter object rather than a long argument list: the derivation reads
/// sixteen values that are meaningless apart, and a caller filling some of them
/// gets geometry that is wrong rather than a diagnostic. Grouping them also means
/// adding an input is a change the compiler routes to every call site.
///
/// Points where the name says points, device pixels where it says pixels, and
/// atlas pixels for the rasterised metrics — the three are not interchangeable
/// and the ratios between them are what this type exists to apply.
@frozen
public struct CellMetricsInputs {
    /// The resolved cell width in device pixels, as drawn.
    public var cellWidthInPixels: Double
    /// The resolved cell height in device pixels, as drawn.
    ///
    /// The resolved height rather than the natural advance: DECCOLM compression
    /// and the line-height snap both move it, and the rules must land on the cell
    /// the frame drew rather than the one the font asked for.
    public var cellHeightInPixels: Double
    /// The cell height in points, before the atlas scale.
    public var cellHeightInPoints: Double
    /// Device pixels per point for this frame.
    public var deviceScale: Double
    /// Atlas pixels per point — the scale the glyph sheet was rasterised at.
    public var atlasScale: Double
    /// The face's em size in points.
    public var fontSizeInPoints: Double
    /// The face's ascent, in atlas pixels.
    public var ascentInAtlasPixels: Double
    /// The part of the line spacing above the ascent, in atlas pixels.
    public var lineGapTopInAtlasPixels: Double
    /// The x-height, in atlas pixels.
    public var xHeightInAtlasPixels: Double
    /// Underline stroke weight for the regular face, in atlas pixels.
    public var underlineThicknessInAtlasPixels: Double
    /// Underline drop below the baseline for the regular face, in atlas pixels.
    public var underlineDropInAtlasPixels: Double
    /// Underline stroke weight for the bold face, in atlas pixels.
    public var underlineThicknessBoldInAtlasPixels: Double
    /// Underline drop below the baseline for the bold face, in atlas pixels.
    public var underlineDropBoldInAtlasPixels: Double
    /// Curl stroke weight, in atlas pixels.
    ///
    /// Carried beside the solid weights rather than derived from the em at the
    /// resolve, because the shader scales the wave's period and its skip-ink
    /// band by this value: a weight that falls below Core's floor there reads
    /// as a different curl than the one every other backend draws at the same
    /// size, while the solid rules the floor also guards look identical.
    public var underlineCurlyThicknessInAtlasPixels: Double
    /// Strikethrough stroke weight for the regular face, in atlas pixels.
    public var strikeThicknessInAtlasPixels: Double
    /// Strikethrough stroke weight for the bold face, in atlas pixels.
    public var strikeThicknessBoldInAtlasPixels: Double

    @inlinable
    @inline(__always)
    public init(
        cellWidthInPixels: Double,
        cellHeightInPixels: Double,
        cellHeightInPoints: Double,
        deviceScale: Double,
        atlasScale: Double,
        fontSizeInPoints: Double,
        ascentInAtlasPixels: Double,
        lineGapTopInAtlasPixels: Double,
        xHeightInAtlasPixels: Double,
        underlineThicknessInAtlasPixels: Double,
        underlineDropInAtlasPixels: Double,
        underlineThicknessBoldInAtlasPixels: Double,
        underlineDropBoldInAtlasPixels: Double,
        underlineCurlyThicknessInAtlasPixels: Double,
        strikeThicknessInAtlasPixels: Double,
        strikeThicknessBoldInAtlasPixels: Double
    ) {
        self.cellWidthInPixels = cellWidthInPixels
        self.cellHeightInPixels = cellHeightInPixels
        self.cellHeightInPoints = cellHeightInPoints
        self.deviceScale = deviceScale
        self.atlasScale = atlasScale
        self.fontSizeInPoints = fontSizeInPoints
        self.ascentInAtlasPixels = ascentInAtlasPixels
        self.lineGapTopInAtlasPixels = lineGapTopInAtlasPixels
        self.xHeightInAtlasPixels = xHeightInAtlasPixels
        self.underlineThicknessInAtlasPixels = underlineThicknessInAtlasPixels
        self.underlineDropInAtlasPixels = underlineDropInAtlasPixels
        self.underlineThicknessBoldInAtlasPixels = underlineThicknessBoldInAtlasPixels
        self.underlineDropBoldInAtlasPixels = underlineDropBoldInAtlasPixels
        self.underlineCurlyThicknessInAtlasPixels = underlineCurlyThicknessInAtlasPixels
        self.strikeThicknessInAtlasPixels = strikeThicknessInAtlasPixels
        self.strikeThicknessBoldInAtlasPixels = strikeThicknessBoldInAtlasPixels
    }
}

/// The two ratios every rule metric is scaled by.
///
/// They coincide only while the cell keeps its natural height, which is why they
/// are derived together and named apart — a line-height setting or a snapped row
/// moves one and not the other.
@frozen
public struct MetricScales {
    /// Atlas pixels to device pixels, for geometry the atlas already holds.
    public let atlasToDevice: Double
    /// The live cell measured against the REFERENCE cell the atlas was built at.
    ///
    /// The rules scale by this rather than by ``atlasToDevice``: a rule drawn at
    /// the atlas ratio on a stretched cell sits at a weight the glyphs beside it
    /// were not drawn to.
    public let rule: Double

    /// Derives both ratios, falling back where a denominator is unusable.
    ///
    /// A non-positive atlas scale or reference height means the caller has no
    /// rasterised face to measure against, and 1 leaves the atlas geometry at the
    /// size it was rasterised — the only answer that does not scale a glyph by an
    /// arbitrary factor.
    ///
    /// - Parameter inputs: The frame's scalars.
    @inlinable
    @inline(__always)
    public init(_ inputs: borrowing CellMetricsInputs) {
        atlasToDevice = inputs.atlasScale > 0.0 ? inputs.deviceScale / inputs.atlasScale : 1.0
        let referenceCellHeight = inputs.cellHeightInPoints * inputs.atlasScale
        rule = referenceCellHeight > 0.0 ? inputs.cellHeightInPixels / referenceCellHeight : atlasToDevice
    }
}

/// Returns the per-cell metrics the decoration pass lays a frame out with.
///
/// The baseline is measured DOWN from the cell top through the line gap and the
/// ascent, which is where the rule pass puts it. Deriving it from the cell height
/// and the atlas baseline instead agrees only while the cell keeps its natural
/// height, and disagrees by exactly the line spacing once it does not.
///
/// The curly weight keeps its fraction where the solid rules do not. Those floor
/// to whole device pixels so their edges stay crisp, and that same rounding makes
/// the wave's weight jump a full pixel between adjacent point sizes; the curl is
/// anti-aliased, so nothing is gained by snapping it.
///
/// `underlineStrokeLift` comes back from Core rather than being spelled here,
/// which is what keeps the four backends drawing the same rule — the constant is
/// `em / 24` however a given backend spells it.
///
/// - Parameter inputs: The frame's scalars, in the units their names give.
/// - Returns: Metrics in device pixels, ready for the portable builder.
@inlinable
public func resolveCellMetrics(_ inputs: borrowing CellMetricsInputs) -> Ubiquitty.Rendering.CellMetrics {
    let scales = MetricScales(inputs)
    let rule = scales.rule

    var metrics = Ubiquitty.Rendering.CellMetrics()
    metrics.cellWidth = Float(inputs.cellWidthInPixels)
    metrics.cellHeight = Float(inputs.cellHeightInPixels)
    metrics.baselineFromTop = Float((inputs.lineGapTopInAtlasPixels + inputs.ascentInAtlasPixels) * rule)
    metrics.underlineThickness = Float(inputs.underlineThicknessInAtlasPixels * rule)
    metrics.underlineDrop = Float(inputs.underlineDropInAtlasPixels * rule)
    metrics.underlineThicknessBold = Float(inputs.underlineThicknessBoldInAtlasPixels * rule)
    metrics.underlineDropBold = Float(inputs.underlineDropBoldInAtlasPixels * rule)
    metrics.underlineCurlyThickness = Float(inputs.underlineCurlyThicknessInAtlasPixels * rule)
    metrics.strikeThickness = Float(inputs.strikeThicknessInAtlasPixels * rule)
    metrics.strikeThicknessBold = Float(inputs.strikeThicknessBoldInAtlasPixels * rule)
    metrics.xHeight = Float(inputs.xHeightInAtlasPixels * rule)
    metrics.deviceScale = Float(inputs.deviceScale)
    metrics.atlasToDevicePixels = Float(scales.atlasToDevice > 0.0 ? scales.atlasToDevice : 1.0)
    metrics.underlineStrokeLift = Ubiquitty.Rendering.underlineStrokeLiftForEm(
        Float(inputs.fontSizeInPoints * inputs.deviceScale)
    )
    return metrics
}

/// The renderer scalars the frame's pen and rule styling is derived from.
///
/// The two underline lengths arrive in points because that is the unit the
/// settings are stored in; the backing scale is applied here rather than by the
/// caller, so a frontend cannot hand the builder a length in the wrong space.
@frozen
public struct FrameStyleInputs {
    /// Whether a bold cell brightens its palette colour.
    public var shouldBrightenBold: Bool
    /// Whether braille draws as the renderer's 2x4 dot lattice rather than
    /// from the face.
    public var shouldDrawBrailleGrid: Bool
    /// Alpha of the terminal's default foreground, 0-255.
    ///
    /// The per-index palette alphas are not here. The builder takes those as a
    /// borrowed array whose storage belongs to the frame, so the pointer is
    /// attached on the side that owns it rather than copied through a value type.
    public var defaultForegroundAlpha: UInt8
    /// The user's underline weight multiplier.
    ///
    /// At or below zero means unset, and the rules then draw at the face's own
    /// weight — a zero multiplier would erase them rather than leave them alone.
    public var underlineThicknessScale: Double
    /// The user's `underline_offset`, in points.
    public var underlineOffsetInPoints: Double
    /// Whether a rule breaks around descender ink.
    public var shouldUnderlineSkipInk: Bool
    /// Whether a run's outer rule reaches the letter's ink past the cell.
    public var shouldUnderlineFollowInk: Bool
    /// The dilation around crossing ink, in points.
    public var underlineSkipInkPaddingInPoints: Double
    /// Device pixels per point for this frame.
    public var deviceScale: Double
    /// The whole-pass cell-background alpha the frame uniforms carry.
    public var uniformBackgroundOpacity: Double
    /// The terminal default background, sRGB 0..1; `.w` is the default-bg-only
    /// opacity factor.
    public var uniformDefaultBackground: Ubiquitty.Rendering.Vec4

    @inlinable
    @inline(__always)
    public init(
        shouldBrightenBold: Bool,
        shouldDrawBrailleGrid: Bool,
        defaultForegroundAlpha: UInt8,
        underlineThicknessScale: Double,
        underlineOffsetInPoints: Double,
        shouldUnderlineSkipInk: Bool,
        shouldUnderlineFollowInk: Bool,
        underlineSkipInkPaddingInPoints: Double,
        deviceScale: Double,
        uniformBackgroundOpacity: Double,
        uniformDefaultBackground: Ubiquitty.Rendering.Vec4
    ) {
        self.shouldBrightenBold = shouldBrightenBold
        self.shouldDrawBrailleGrid = shouldDrawBrailleGrid
        self.defaultForegroundAlpha = defaultForegroundAlpha
        self.underlineThicknessScale = underlineThicknessScale
        self.underlineOffsetInPoints = underlineOffsetInPoints
        self.shouldUnderlineSkipInk = shouldUnderlineSkipInk
        self.shouldUnderlineFollowInk = shouldUnderlineFollowInk
        self.underlineSkipInkPaddingInPoints = underlineSkipInkPaddingInPoints
        self.deviceScale = deviceScale
        self.uniformBackgroundOpacity = uniformBackgroundOpacity
        self.uniformDefaultBackground = uniformDefaultBackground
    }
}

/// Returns the frame's pen and rule styling for the portable builder.
///
/// Both products are a lone multiply, exact in Swift and in clang alike. The
/// contractable `a * b + c` shape is the one the two disagree about, and none is
/// written here.
///
/// Written by reference rather than returned, so a caller layering further
/// style writes around this one keeps them: a returned struct assigned
/// wholesale would clear whatever the caller had already set, leaving the
/// order of two lines to decide it. The borrowed storage that once also
/// forced this shape lives on the options now, not the style.
///
/// - Parameters:
///   - style: The style block to write into.
///   - inputs: The frame's scalars, in the units their names give.
/// Both underline lengths arrive in device pixels.
@inlinable
public func applyFrameStyle(
    to style: inout Ubiquitty.Rendering.TerminalSnapshotStyle,
    _ inputs: borrowing FrameStyleInputs
) {
    style.shouldBrightenBold = inputs.shouldBrightenBold
    style.shouldDrawBrailleGrid = inputs.shouldDrawBrailleGrid
    style.defaultForegroundAlpha = inputs.defaultForegroundAlpha
    style.underlineThicknessScale = Float(inputs.underlineThicknessScale > 0.0 ? inputs.underlineThicknessScale : 1.0)
    style.underlineOffsetInPixels = Float(inputs.underlineOffsetInPoints * inputs.deviceScale)
    style.shouldUnderlineSkipInk = inputs.shouldUnderlineSkipInk
    style.shouldUnderlineFollowInk = inputs.shouldUnderlineFollowInk
    style.underlineSkipInkPaddingInPixels = Float(inputs.underlineSkipInkPaddingInPoints * inputs.deviceScale)
    style.uniformBackgroundOpacity = Float(inputs.uniformBackgroundOpacity)
    style.uniformDefaultBackground = inputs.uniformDefaultBackground
}

/// The renderer state the frame's OSC 8 link presentation is derived from.
///
/// Hovered rows arrive as absolute buffer rows — pointer tracking records one,
/// and it stays put while the view scrolls — where the builder wants visible. The
/// conversion needs this frame's scrollback depth and offset, so it belongs with
/// the rows rather than at the site that recorded them.
@frozen
public struct FrameLinkInputs {
    /// Whether link cells take an underline of their own.
    public var shouldUnderlineLinks: Bool
    /// The user's `link_style`, stored as an index.
    ///
    /// Zero means solid. The mapping from index to VT underline code is applied
    /// here; which SCHEME reads dotted or dashed stays Core's, and a frontend
    /// repeating that table is a second copy that drifts on the first edit.
    public var linkStyleIndex: Int32
    /// Whether the capture resolves each resting link's kind from the terminal
    /// it reads, so file and mailto links take their own underline styles.
    /// Which scheme reads dotted or dashed stays Core's.
    public var shouldResolveLinkKindsPerKind: Bool
    /// Link foreground, straight RGBA.
    public var linkColor: Ubiquitty.Rendering.Vec4
    /// Hovered-link foreground, straight RGBA.
    public var hoverColor: Ubiquitty.Rendering.Vec4
    /// Whether a link is under the pointer this frame.
    public var isHoverLinkActive: Bool
    /// The hovered link's identifier.
    public var hoverLinkID: UInt16
    /// First and last buffer rows of the hovered run, absolute.
    public var hoverRowAbsoluteFirst: Int32
    public var hoverRowAbsoluteLast: Int32
    /// First and last columns of the hovered run.
    public var hoverColumnFirst: Int32
    public var hoverColumnLast: Int32
    /// The pane span the run was resolved inside; middle rows clip to it.
    /// spanLast < 0 means the screen's own width.
    public var hoverSpanColumnFirst: Int32
    public var hoverSpanColumnLast: Int32
    /// Rows of scrollback above the viewport this frame.
    public var scrollbackCount: Int32
    /// The digest of the hovered run's text at the resolve; zero when the
    /// frontend took none, which draws the run by its rows alone.
    public var hoverTextDigest: UInt64
    /// How far the viewport is scrolled back this frame.
    public var viewOffset: Int32

    @inlinable
    @inline(__always)
    public init(
        shouldUnderlineLinks: Bool,
        linkStyleIndex: Int32,
        shouldResolveLinkKindsPerKind: Bool,
        linkColor: Ubiquitty.Rendering.Vec4,
        hoverColor: Ubiquitty.Rendering.Vec4,
        isHoverLinkActive: Bool,
        hoverLinkID: UInt16,
        hoverRowAbsoluteFirst: Int32,
        hoverRowAbsoluteLast: Int32,
        hoverColumnFirst: Int32,
        hoverColumnLast: Int32,
        hoverSpanColumnFirst: Int32,
        hoverSpanColumnLast: Int32,
        scrollbackCount: Int32,
        viewOffset: Int32,
        hoverTextDigest: UInt64 = 0
    ) {
        self.shouldUnderlineLinks = shouldUnderlineLinks
        self.linkStyleIndex = linkStyleIndex
        self.shouldResolveLinkKindsPerKind = shouldResolveLinkKindsPerKind
        self.linkColor = linkColor
        self.hoverColor = hoverColor
        self.isHoverLinkActive = isHoverLinkActive
        self.hoverLinkID = hoverLinkID
        self.hoverRowAbsoluteFirst = hoverRowAbsoluteFirst
        self.hoverRowAbsoluteLast = hoverRowAbsoluteLast
        self.hoverColumnFirst = hoverColumnFirst
        self.hoverColumnLast = hoverColumnLast
        self.hoverSpanColumnFirst = hoverSpanColumnFirst
        self.hoverSpanColumnLast = hoverSpanColumnLast
        self.scrollbackCount = scrollbackCount
        self.viewOffset = viewOffset
        self.hoverTextDigest = hoverTextDigest
    }
}

/// Writes the frame's link presentation into `options`.
///
/// Takes the block by reference rather than returning one: the surrounding
/// assembly fills other fields before and after, and a returned copy would have
/// to be merged field by field — which is the shape that loses one silently.
///
/// - Parameters:
///   - options: The frame options to write into.
///   - inputs: The renderer's link state, with hovered rows still absolute.
@inlinable
public func applyFrameLinks(
    to options: inout Ubiquitty.Rendering.TerminalSnapshotOptions,
    _ inputs: borrowing FrameLinkInputs
) {
    options.shouldUnderlineLinks = inputs.shouldUnderlineLinks
    options.linkUnderlineStyle = Ubiquitty.Preferences.Effective.linkUnderlineVTStyle(inputs.linkStyleIndex)
    options.shouldResolveLinkKindsFromSource = inputs.shouldResolveLinkKindsPerKind
    options.linkColor = inputs.linkColor
    options.linkHoverColor = inputs.hoverColor
    // Absolute to visible, against the offset this frame is drawing at:
    // `Rendering::applyFrameHoverLink`, because the boundary capture converts
    // the same run and a second spelling is what let the two disagree.
    var hover = Ubiquitty.Rendering.FrameHoverLink()
    hover.isActive = inputs.isHoverLinkActive
    hover.linkID = inputs.hoverLinkID
    hover.rowAbsoluteFirst = inputs.hoverRowAbsoluteFirst
    hover.rowAbsoluteLast = inputs.hoverRowAbsoluteLast
    hover.columnFirst = inputs.hoverColumnFirst
    hover.columnLast = inputs.hoverColumnLast
    hover.spanColumnFirst = inputs.hoverSpanColumnFirst
    hover.spanColumnLast = inputs.hoverSpanColumnLast
    hover.textDigest = inputs.hoverTextDigest
    Ubiquitty.Rendering.applyFrameHoverLink(&options, hover, inputs.scrollbackCount, inputs.viewOffset)
}

/// The renderer state the frame's cursor presentation is derived from.
///
/// Focus and blink are separate questions here for a reason the field names do
/// not carry on their own: a backgrounded tab bakes its cursor as solidly as a
/// focused one, because the hollow outline is what a stale frame would leave
/// behind on reselection.
@frozen
public struct FrameCursorInputs {
    /// Whether this pane holds focus.
    public var isCursorFocused: Bool
    /// Whether this pane is a backgrounded tab.
    public var isCursorBackgrounded: Bool
    /// The blink weight this frame resolved.
    ///
    /// Taken from the snapshot the walk gates on, never re-read: the alpha steps
    /// between five levels, so a second reading a frame later shows a quarter of
    /// the ink missing on every blinking cell and nothing else moved.
    public var cursorMixAlpha: Float
    /// Whether the cursor inverts the text under it.
    public var shouldCursorInvertText: Bool
    /// The monotonic tick the encode resolved blink against.
    public var blinkTicks: UInt32
    /// Whether the cursor is mid-slide this frame.
    ///
    /// False leaves the fractional position alone rather than writing a stale
    /// one: the builder reads it only while sliding, and a position written when
    /// the animation is off pins the cursor to wherever it last moved from.
    public var isCursorSliding: Bool
    /// The cursor's fractional column and visible row, meaningful while sliding.
    public var cursorColumnFractional: Float
    public var cursorRowFractional: Float

    @inlinable
    @inline(__always)
    public init(
        isCursorFocused: Bool,
        isCursorBackgrounded: Bool,
        cursorMixAlpha: Float,
        shouldCursorInvertText: Bool,
        blinkTicks: UInt32,
        isCursorSliding: Bool,
        cursorColumnFractional: Float,
        cursorRowFractional: Float
    ) {
        self.isCursorFocused = isCursorFocused
        self.isCursorBackgrounded = isCursorBackgrounded
        self.cursorMixAlpha = cursorMixAlpha
        self.shouldCursorInvertText = shouldCursorInvertText
        self.blinkTicks = blinkTicks
        self.isCursorSliding = isCursorSliding
        self.cursorColumnFractional = cursorColumnFractional
        self.cursorRowFractional = cursorRowFractional
    }
}

/// Writes the frame's cursor presentation into `options`.
///
/// `shouldResolveBlink` is set rather than passed: this backend always resolves
/// blink from the tick it already holds, so a caller offering a value could only
/// disagree with what the encode does. The slide is different — it is off
/// unless the motion mode is on and an animation is running, and writing a
/// fractional position outside that window pins the cursor where it last moved
/// from.
///
/// - Parameters:
///   - options: The frame options to write into.
///   - inputs: The renderer's cursor state for this frame.
@inlinable
public func applyFrameCursor(
    to options: inout Ubiquitty.Rendering.TerminalSnapshotOptions,
    _ inputs: borrowing FrameCursorInputs
) {
    // Bound before the disjunction: `||` takes its right operand as an
    // autoclosure, which escapes, and a borrowed parameter cannot be captured by
    // one. Reading both is free here and says the same thing.
    let isFocused = inputs.isCursorFocused
    let isBackgrounded = inputs.isCursorBackgrounded
    options.isFocused = isFocused || isBackgrounded
    options.cursorMixAlpha = inputs.cursorMixAlpha
    options.shouldCursorInvertText = inputs.shouldCursorInvertText
    options.shouldResolveBlink = true
    options.blinkTicks = inputs.blinkTicks
    guard inputs.isCursorSliding else { return }
    options.isCursorSliding = true
    options.cursorColumnFractional = inputs.cursorColumnFractional
    options.cursorVRowFractional = inputs.cursorRowFractional
}

/// The renderer state the frame's grid placement and prompt-mark geometry come
/// from.
///
/// The prompt-mark bracket is a fraction of the point size and is centred on the
/// glyph ink box, so it needs the FACE's ascent and descent rather than the
/// cell's baseline and its complement — those have the line spacing folded in and
/// coincide with the face's own pair only while that spacing is zero.
@frozen
public struct FramePlacementInputs {
    /// How far the viewport is scrolled back.
    public var viewOffset: Int32
    /// The grid's top-left corner inside the drawable, in device pixels.
    public var originX: Float
    public var originY: Float
    /// The drawable's extent in device pixels.
    public var viewportWidth: Float
    public var viewportHeight: Float
    /// The cell height and line spacing, in points.
    ///
    /// Points rather than pixels: the bracket's thickness and inset are a
    /// fraction of the type size, so a device-pixel height would thicken the mark
    /// with the backing scale.
    public var cellHeightInPoints: Double
    public var lineSpacingInPoints: Double
    /// The face's em size, in points, fractions included.
    public var fontSizeInPoints: Double
    /// The face's own ascent and descent, in atlas pixels.
    public var fontAscentInAtlasPixels: Float
    public var fontDescentInAtlasPixels: Float
    /// The part of the line spacing above the ascent, in atlas pixels.
    public var lineGapTopInAtlasPixels: Float
    /// The face's `[` ink above and below the baseline, in atlas pixels; the
    /// mark centres on it. Zero when unmeasured.
    public var bracketInkTopInAtlasPixels: Float
    public var bracketInkBottomInAtlasPixels: Float
    /// The face's x-height in atlas pixels; zero when the face reported none.
    public var xHeightInAtlasPixels: Float
    /// The face's cap height in atlas pixels; zero when the face reported none.
    public var capHeightInAtlasPixels: Float
    /// Atlas pixels per point.
    public var atlasScale: Float

    @inlinable
    @inline(__always)
    public init(
        viewOffset: Int32,
        originX: Float,
        originY: Float,
        viewportWidth: Float,
        viewportHeight: Float,
        cellHeightInPoints: Double,
        lineSpacingInPoints: Double,
        fontSizeInPoints: Double,
        fontAscentInAtlasPixels: Float,
        fontDescentInAtlasPixels: Float,
        lineGapTopInAtlasPixels: Float,
        bracketInkTopInAtlasPixels: Float,
        bracketInkBottomInAtlasPixels: Float,
        xHeightInAtlasPixels: Float,
        capHeightInAtlasPixels: Float,
        atlasScale: Float
    ) {
        self.viewOffset = viewOffset
        self.originX = originX
        self.originY = originY
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.cellHeightInPoints = cellHeightInPoints
        self.lineSpacingInPoints = lineSpacingInPoints
        self.fontSizeInPoints = fontSizeInPoints
        self.fontAscentInAtlasPixels = fontAscentInAtlasPixels
        self.fontDescentInAtlasPixels = fontDescentInAtlasPixels
        self.lineGapTopInAtlasPixels = lineGapTopInAtlasPixels
        self.bracketInkTopInAtlasPixels = bracketInkTopInAtlasPixels
        self.bracketInkBottomInAtlasPixels = bracketInkBottomInAtlasPixels
        self.xHeightInAtlasPixels = xHeightInAtlasPixels
        self.capHeightInAtlasPixels = capHeightInAtlasPixels
        self.atlasScale = atlasScale
    }
}

/// Writes the frame's grid placement and prompt-mark geometry into `options`.
///
/// Pure marshalling — every value crosses in the unit it arrived in. The origin
/// is fed rather than recomputed because glyph instances carry absolute
/// positions, and the builder must inset by the same amount the encode wrote
/// into its uniforms; a second derivation here would be a second chance to
/// disagree about where the grid starts.
///
/// - Parameters:
///   - options: The frame options to write into.
///   - inputs: The renderer's placement state for this frame.
@inlinable
public func applyFramePlacement(
    to options: inout Ubiquitty.Rendering.TerminalSnapshotOptions,
    _ inputs: borrowing FramePlacementInputs
) {
    options.viewOffset = inputs.viewOffset
    options.originInPixels = Ubiquitty.FloatPoint(x: inputs.originX, y: inputs.originY)
    options.viewportSizeInPixels = Ubiquitty.FloatSize(
        width: inputs.viewportWidth,
        height: inputs.viewportHeight
    )
    options.cellHeightPoints = inputs.cellHeightInPoints
    options.lineSpacingPoints = inputs.lineSpacingInPoints
    options.promptMarkFontSize = inputs.fontSizeInPoints
    options.promptMarkFontAscent = inputs.fontAscentInAtlasPixels
    options.promptMarkFontDescent = inputs.fontDescentInAtlasPixels
    options.promptMarkLineGapTopInPixels = inputs.lineGapTopInAtlasPixels
    options.promptMarkBracketInkTopInPixels = inputs.bracketInkTopInAtlasPixels
    options.promptMarkBracketInkBottomInPixels = inputs.bracketInkBottomInAtlasPixels
    options.promptMarkFontXHeight = inputs.xHeightInAtlasPixels
    options.promptMarkFontCapHeight = inputs.capHeightInAtlasPixels
    options.promptMarkAtlasScale = inputs.atlasScale
}

/// The renderer state deciding how the frame is composited over its window.
///
/// The letterbox alpha is 1 rather than the colour's own: DECSET 7402 paints the
/// area outside the grid opaquely, and a translucent letterbox would show the
/// desktop through the part of the window the terminal is not using.
@frozen
public struct FrameCompositingInputs {
    /// Whether the phased glyph stream is wanted this frame.
    ///
    /// The atlas margins say the pass is POSSIBLE; this says it is wanted. A
    /// frame that reads the margins alone emits the phased stream for a user who
    /// turned subpixel text off, because turning it off leaves the atlas as it
    /// was.
    public var shouldUseSubpixelGlyphs: Bool
    /// Whether OSC 19 overrides the foreground of selected cells.
    public var shouldOverrideSelectionForeground: Bool
    /// The selection foreground, RGBA.
    public var selectionForeground: Ubiquitty.Rendering.Vec4

    @inlinable
    @inline(__always)
    public init(
        shouldUseSubpixelGlyphs: Bool,
        shouldOverrideSelectionForeground: Bool,
        selectionForeground: Ubiquitty.Rendering.Vec4
    ) {
        self.shouldUseSubpixelGlyphs = shouldUseSubpixelGlyphs
        self.shouldOverrideSelectionForeground = shouldOverrideSelectionForeground
        self.selectionForeground = selectionForeground
    }
}

/// The atlas facts the builder keys a frame's glyphs under.
///
/// Owned by the atlas rather than the frame: the phase count is the pen grid
/// CoreText quantises onto at the faces' device size, and the tier keying
/// exists only because the sheets rasterise per tier. Both arms build one of these from the atlas they are
/// about to draw with, so the builder's keys are the rasteriser's.
@frozen
public struct FrameRasterInputs: Equatable {
    /// How many subpixel phases the atlas keys and draws.
    public var subpixelPhaseCount: Int32
    /// How many its wide sheet keys and draws, or 0 for the same count.
    public var widePhaseCount: Int32
    /// Whether the sheets are CoreText rasters: floored phases and tiers.
    public var isCoreTextRaster: Bool
    /// The integer upscale of a face Core rasterises itself, or 0 for a
    /// CoreText face — the atlas's own routing verdict, carried to the frame
    /// style so Core, not the frontend, decides the bitmap tier.
    public var unifontScale: Int32

    @inlinable
    @inline(__always)
    public init(subpixelPhaseCount: Int32, isCoreTextRaster: Bool, unifontScale: Int32 = 0, widePhaseCount: Int32 = 0) {
        self.subpixelPhaseCount = subpixelPhaseCount
        self.widePhaseCount = widePhaseCount
        self.isCoreTextRaster = isCoreTextRaster
        self.unifontScale = unifontScale
    }

    /// The inputs for an atlas.
    package init(atlas: GlyphAtlas) {
        self.init(
            subpixelPhaseCount: Int32(atlas.subpixelPhaseCount),
            isCoreTextRaster: atlas.isCoreTextRaster,
            unifontScale: Int32(atlas.unifontScale),
            widePhaseCount: Int32(atlas.widePhaseCount)
        )
    }
}

/// Writes the atlas's raster facts into `options`.
///
/// Floored phases and tiered rasters are what a CoreText sheet is, so they
/// follow from the atlas being one; a bitmap family's sheet keys on the
/// portable grid like the portable renderer it agrees with.
///
/// - Parameters:
///   - options: The frame options to write into.
///   - inputs: The atlas's facts for this frame.
@inlinable
public func applyFrameRaster(
    to options: inout Ubiquitty.Rendering.TerminalSnapshotOptions,
    _ inputs: borrowing FrameRasterInputs
) {
    // Core's rule, not a second spelling of it: the boundary capture assembles
    // its own options on the ingest thread and calls the same entry, and the
    // two routes alternate frames while a reader types.
    var facts = Ubiquitty.Rendering.FrameRasterFacts()
    facts.subpixelPhaseCount = inputs.subpixelPhaseCount
    facts.widePhaseCount = inputs.widePhaseCount
    facts.isCoreTextRaster = inputs.isCoreTextRaster
    facts.unifontScale = inputs.unifontScale
    Ubiquitty.Rendering.applyFrameRaster(&options, facts)
}

/// Writes the frame's compositing decisions into `options`.
///
/// The selection SPANS are not written here. They are borrowed storage the frame
/// owns, so the caller attaches the pointer and its count; this settles only
/// whether the override applies and what colour it uses.
///
/// - Parameters:
///   - options: The frame options to write into.
///   - inputs: The renderer's compositing state for this frame.
@inlinable
public func applyFrameCompositing(
    to options: inout Ubiquitty.Rendering.TerminalSnapshotOptions,
    _ inputs: borrowing FrameCompositingInputs
) {
    options.shouldUseSubpixelGlyphs = inputs.shouldUseSubpixelGlyphs
    guard inputs.shouldOverrideSelectionForeground else { return }
    options.shouldOverrideSelectionForeground = true
    options.selectionForeground = inputs.selectionForeground
}
