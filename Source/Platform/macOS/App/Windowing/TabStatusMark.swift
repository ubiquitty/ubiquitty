// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// TabStatusMark.swift — a program's status, or a tab's progress, in the
// tab's accessory slot.
//
// The status a program reports is an SF Symbol in the theme's colour for it,
// a blocked program's telling what it waits for; a bell nobody heard is a
// bell. Until its tab has been looked at, a question, a failure, done and a
// bell also wear
// a halo: a glow that follows the symbol's own outline, with spikes rising
// from it and travelling round, behind a gap the colour of the symbol's
// cutout. An unseen question and an unheard bell wiggle and an unseen
// failure bounces, every few seconds; the symbol and its gap move, the glow stays. A working program
// is an ellipsis whose dots light in turn; a pane's own OSC 9;4 progress is
// the app's circular indicator, spinning or filling. All of them share the indicator's
// frame, so one gives way to another, the old shrinking away and the new
// expanding into place, each in its own colour, and the tab's title stays
// where it was.

import AppKit
import CoreImage
import QuartzCore
internal import UbiquittyRenderKit

@MainActor
@objc(UBTabStatusMark)
public final class TabStatusMark: NSView {
    /// What the mark shows.
    enum Content: Equatable {
        case none
        /// A program's status, in its theme colour, and for a blocked one,
        /// what it waits for.
        case status(HostOutlineStatus, blockKind: HostOutlineBlockKind, ink: NSColor)
        /// A bell nobody heard, in the title's ink or the program's colour.
        case bell(ink: NSColor)
        /// A working program: the ellipsis, its dots lighting in turn.
        case working(ink: NSColor)
        /// A pane's own OSC 9;4 progress: the circular indicator, spinning
        /// for unknown length, filling to a percent, paused or failed.
        case progress(state: UInt8, value: UInt8, ink: NSColor)
    }

    private(set) var content: Content = .none
    /// Whether the status is news: its tab has not been looked at since it came.
    private(set) var isUnseen = false

    /// The symbol showing, for a scenario to read; nil for none and for the indicator.
    package var symbolName: String? { Self.symbol(for: content) }

    /// What the symbol or the indicator is drawn in, for a scenario to read.
    package var ink: NSColor? {
        switch content {
        case .none: nil
        case .status(_, _, let ink), .bell(let ink), .working(let ink), .progress(_, _, let ink): ink
        }
    }

    /// Whether the halo is lit, for a scenario to read.
    package var isGlowing: Bool { halo.isLit }

    /// The OSC 9;4 state the mark shows, for a scenario to read: progress
    /// of unknown length for a working program, the indicator's own state for
    /// a pane's report, and none for any other status.
    package var progressStateForTesting: UInt8 {
        switch content {
        case .working: 3
        case .progress(let state, _, _): state
        case .none, .status, .bell: 0
        }
    }

    /// Whether the mark shows progress, of either kind, for a scenario to read.
    package var isShowingProgress: Bool { progressStateForTesting != 0 }

    /// Shows a bell in `ink`, already heard, for a scenario to render.
    package func showBellForTesting(ink: NSColor) {
        show(.bell(ink: ink), isUnseen: false)
    }

    /// What a working program shows, in a tab and in a window's title alike.
    package static let workingSymbolName = "ellipsis"

    /// The circular indicator's own frame: its diameter, square.
    private static let side: CGFloat = 13

    private let halo = StatusHalo()
    /// The app's circular indicator, for a pane's own progress.
    private let ring = TabProgressIndicator(frame: .zero)
    /// An image view that composites its symbol vibrantly while its tint is
    /// a system label colour, and paints a theme's or a program's colour as
    /// that colour.
    private final class SymbolView: NSImageView {
        var isVibrant = false

        override var allowsVibrancy: Bool { isVibrant }

        /// Tints the symbol, and composites it vibrantly when the tint is a
        /// system label colour.
        func tint(_ ink: NSColor) {
            contentTintColor = ink
            isVibrant = TabTitleStyling.isSystemColor(ink)
        }
    }

    /// Two image views, so a replacement takes the old symbol away in its
    /// colour while the new one arrives in its own.
    private let views = [SymbolView(), SymbolView()]
    private var front = 0
    private var symbolView: SymbolView { views[front] }

    /// The view the showing symbol is drawn in, for a scenario to read.
    package var symbolImageViewForTesting: NSImageView { symbolView }

    /// Composites the mark with the strip's glass while its symbol wears a
    /// system label colour, as AppKit's own tab controls are; a coloured
    /// status, a bell or the indicator paints its colour flat.
    public override var allowsVibrancy: Bool {
        guard !isRingShown, let ink = symbolInk else { return false }
        return TabTitleStyling.isSystemColor(ink)
    }

    private var isRingShown = false
    /// When the symbol or indicator that is leaving will be gone, which the
    /// one arriving waits for.
    private var leavingUntil: CFTimeInterval = 0
    /// Which settle is the current one; a scheduled one whose number has gone
    /// stale was overtaken by a later change.
    private var generation = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        addSubview(halo)
        ring.isHidden = true
        addSubview(ring)
        for view in views {
            view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            view.isHidden = true
            addSubview(view)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: Self.side, height: Self.side)
    }

    public override func layout() {
        super.layout()
        for view in views { view.frame = bounds }
        ring.frame = bounds
        let reach = StatusHalo.reach
        let around = bounds.insetBy(dx: -reach, dy: -reach)
        if halo.frame != around {
            halo.frame = around
            retrace()
            // The turn and nudge pivot on the symbol's centre, which has just moved.
            startEffects()
        }
    }

    /// A mark made before its tab was shown starts moving once it is in a
    /// window, at its real size.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        retrace()
        startEffects()
    }

    @objc
    private func motionPreferenceChanged() {
        retrace()
        startEffects()
    }

    private var isMotionReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: - What is shown

    /// Shows `content`, trading places with what was there when it changes.
    ///
    /// - Parameters:
    ///   - content: What to show.
    ///   - isUnseen: Whether the status is news, which lights its halo and,
    ///     for a question or a failure, nudges it.
    func show(_ new: Content, isUnseen unseen: Bool) {
        let old = content
        content = new
        let isChange = Self.identity(of: old) != Self.identity(of: new)
        let wasUnseen = isUnseen
        isUnseen = unseen
        if case .progress(let state, let value, let ink) = new {
            ring.tintColor = ink
            ring.setState(state, value: value)
        }
        guard isChange else {
            // The same mark: a new ink, a new percent, or the reader having
            // looked. A refresh that changes none of them, which is most of
            // them, leaves the halo and its motion running as they are.
            if old != new { applyInk() }
            if wasUnseen != unseen {
                generation += 1
                halo.setLit(doesGlow && unseen, animated: !isMotionReduced)
                startEffects()
            }
            return
        }
        let moves = !isMotionReduced && window != nil
        // The old status's glow and nudge go at once, before its symbol is
        // replaced; the new one's come up as the new one expands.
        halo.setLit(false, animated: false)
        stopNudge()
        // Whichever is leaving goes first, and the other expands after it.
        if isRingShown, !wantsRing { showRing(animated: moves) }
        placeSymbol(animated: moves)
        if !isRingShown, wantsRing { showRing(animated: moves) }
        settle(after: moves ? max(0, leavingUntil - CACurrentMediaTime()) : 0)
    }

    /// What a change of content is a change of: the symbol or the indicator,
    /// not its ink or percent.
    private static func identity(of content: Content) -> String {
        switch content {
        case .none: ""
        case .progress: "progress"
        default: symbol(for: content) ?? ""
        }
    }

    private static func symbol(for content: Content) -> String? {
        switch content {
        case .status(let status, let blockKind, _): status.symbolName(blockKind: blockKind)
        case .bell: "bell.fill"
        case .working: workingSymbolName
        case .none, .progress: nil
        }
    }

    private var symbolInk: NSColor? {
        switch content {
        case .status(_, _, let ink), .bell(let ink), .working(let ink): ink
        case .none, .progress: nil
        }
    }

    private var status: HostOutlineStatus? {
        if case .status(let status, _, _) = content { return status }
        return nil
    }

    private var isBell: Bool {
        if case .bell = content { return true }
        return false
    }

    /// A question, a failure, done and a bell are news until seen, so they glow.
    private var doesGlow: Bool {
        switch status {
        case .blocked, .attention, .failed, .done: true
        default: isBell
        }
    }

    private var wantsRing: Bool {
        if case .progress = content { return true }
        return false
    }

    private func applyInk() {
        if let ink = symbolInk { symbolView.tint(ink) }
        if doesGlow { retrace() }
    }

    // MARK: - Trading places

    private func placeSymbol(animated: Bool) {
        let old = symbolView
        old.removeAllSymbolEffects(animated: false)
        let wasShowing = !old.isHidden && old.image != nil
        guard let name = Self.symbol(for: content), let ink = symbolInk,
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        else {
            if wasShowing, animated { leave(old) } else { old.isHidden = true }
            return
        }
        guard animated else {
            old.image = image
            old.tint(ink)
            old.isHidden = false
            return
        }
        // The new symbol waits in the other view and expands once the old one has gone.
        let new = views[1 - front]
        new.removeAllSymbolEffects(animated: false)
        new.image = image
        new.tint(ink)
        front = 1 - front
        if wasShowing { leave(old) } else { old.isHidden = true }
        expand(new)
    }

    private func showRing(animated: Bool) {
        guard wantsRing != isRingShown else { return }
        isRingShown = wantsRing
        if isRingShown {
            if animated {
                expand(ring)
            } else {
                ring.layer?.removeAnimation(forKey: "trade")
                ring.isHidden = false
            }
        } else if animated {
            leave(ring)
        } else {
            ring.isHidden = true
            ring.setState(0, value: 0)
        }
    }

    /// Takes a symbol or the indicator away, shrinking to a fifth and fading,
    /// then hides it, unless by then it has been asked back.
    private func leave(_ view: NSView) {
        guard let layer = view.layer else {
            view.isHidden = true
            return
        }
        let duration: CFTimeInterval = 0.16
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = Self.scaled(layer, 1)
        shrink.toValue = Self.scaled(layer, 0.2)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let away = CAAnimationGroup()
        away.animations = [shrink, fade]
        away.duration = duration
        away.timingFunction = CAMediaTimingFunction(name: .easeIn)
        away.fillMode = .forwards
        away.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak view] in
            guard let self, let view else { return }
            self.finishLeaving(view)
        }
        layer.add(away, forKey: "trade")
        CATransaction.commit()
        leavingUntil = CACurrentMediaTime() + duration
    }

    /// Hides what has finished leaving, unless it was asked back meanwhile.
    private func finishLeaving(_ view: NSView) {
        let isBack = view === ring ? isRingShown : view === symbolView && Self.symbol(for: content) != nil
        guard !isBack else { return }
        view.isHidden = true
        view.layer?.removeAnimation(forKey: "trade")
        if view === ring { ring.setState(0, value: 0) }
    }

    /// Brings a symbol or the indicator in once whatever is leaving has gone:
    /// from a fifth of its size, expanding on a spring that overshoots a little.
    private func expand(_ view: NSView) {
        view.isHidden = false
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: "trade")
        let grow = CASpringAnimation(keyPath: "transform")
        grow.fromValue = Self.scaled(layer, 0.2)
        grow.toValue = Self.scaled(layer, 1)
        grow.mass = 1
        grow.stiffness = 260
        grow.damping = 18
        grow.duration = grow.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        let arrive = CAAnimationGroup()
        arrive.animations = [grow, fade]
        arrive.duration = grow.duration
        // Held at its start, small and clear, until it begins.
        arrive.beginTime = layer.convertTime(max(CACurrentMediaTime(), leavingUntil), from: nil)
        arrive.fillMode = .backwards
        layer.add(arrive, forKey: "trade")
    }

    /// Lights the status's halo and starts what it does, `delay` seconds from now.
    private func settle(after delay: TimeInterval) {
        generation += 1
        let current = generation
        guard delay > 0 else { return start(current) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.start(current)
        }
    }

    private func start(_ settled: Int) {
        guard generation == settled else { return }
        // The view the last symbol left from is out of the way until the next one.
        views[1 - front].isHidden = true
        retrace()
        halo.setLit(doesGlow && isUnseen, animated: !isMotionReduced)
        startEffects()
    }

    /// Traces the status's symbol for its halo: from what the image view drew,
    /// or until it has drawn, from the symbol's vectors, and again once it has.
    private func retrace() {
        guard halo.bounds.width > 0 else { return }
        guard doesGlow, let name = Self.symbol(for: content), let ink = symbolInk else {
            halo.outline = nil
            halo.rebuild(isMotionReduced: isMotionReduced)
            return
        }
        let reach = StatusHalo.reach
        symbolView.displayIfNeeded()
        if let drawn = SymbolOutline(drawnBy: symbolView, reach: reach) {
            halo.outline = drawn
        } else {
            halo.outline = SymbolOutline(symbol: name, box: bounds.size, reach: reach)
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, generation == current, SymbolOutline(drawnBy: symbolView, reach: reach) != nil else { return }
                retrace()
            }
        }
        halo.color = ink
        halo.rebuild(isMotionReduced: isMotionReduced)
    }

    // MARK: - Motion

    /// Pause between one nudge and the next.
    private static let nudgeInterval: CFTimeInterval = 3

    private func startEffects() {
        symbolView.removeAllSymbolEffects(animated: false)
        stopNudge()
        guard !isMotionReduced else { return }
        // Working lights its dots in turn for as long as it lasts, seen or not, as a spinner turns.
        if case .working = content {
            symbolView.addSymbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeat(.continuous))
        }
        guard isUnseen else { return }
        switch isBell ? .attention : status {
        case .blocked, .attention:
            // A question, and a bell, wiggle.
            nudgeSymbol(
                [0, 0.18, -0.15, 0.1, -0.05, 0].map { CATransform3DMakeRotation($0, 0, 0, 1) },
                times: [0, 0.15, 0.4, 0.62, 0.82, 1],
                length: 0.7
            )
        case .failed:
            // A failure bounces.
            nudgeSymbol([1, 1.22, 0.94, 1.04, 1].map { CATransform3DMakeScale($0, $0, 1) }, times: [0, 0.28, 0.58, 0.8, 1], length: 0.55)
        default:
            break
        }
    }

    /// Moves the symbol and the gap round it as one, leaving the glow and
    /// spikes where they are: `values` are transforms about the symbol's
    /// centre at `times` through `length` seconds, repeated after a pause.
    private func nudgeSymbol(_ values: [CATransform3D], times: [Double], length: CFTimeInterval) {
        func animation(for layer: CALayer, around centre: CGPoint) -> CAAnimation {
            let duration = length + Self.nudgeInterval
            let move = CAKeyframeAnimation(keyPath: "transform")
            move.values = values.map { Self.about(layer, $0, centre: centre) } + [Self.about(layer, CATransform3DIdentity, centre: centre)]
            move.keyTimes = (times.map { $0 * length / duration } + [1]).map { NSNumber(value: $0) }
            move.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: values.count)
            move.duration = duration
            move.repeatCount = .infinity
            // Onto the expand, about the same centre, so the two can overlap.
            move.isAdditive = true
            return move
        }
        // In one transaction, so the symbol and its gap move in step.
        CATransaction.begin()
        if let layer = symbolView.layer {
            layer.add(animation(for: layer, around: CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)), forKey: "nudge")
        }
        halo.nudge(animation)
        CATransaction.commit()
    }

    private func stopNudge() {
        for view in views { view.layer?.removeAnimation(forKey: "nudge") }
        halo.stopNudge()
    }

    /// A scale about the centre of a layer's bounds, whatever its anchor point.
    private static func scaled(_ layer: CALayer, _ k: CGFloat) -> NSValue {
        about(layer, CATransform3DMakeScale(k, k, 1))
    }

    /// A transform about a point in a layer's bounds, its centre unless
    /// given, whatever the layer's anchor point.
    private static func about(_ layer: CALayer, _ transform: CATransform3D, centre: CGPoint? = nil) -> NSValue {
        let point = centre ?? CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        let pivot = CGPoint(x: point.x - layer.anchorPoint.x * layer.bounds.width, y: point.y - layer.anchorPoint.y * layer.bounds.height)
        return NSValue(
            caTransform3D: CATransform3DConcat(
                CATransform3DConcat(CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0), transform),
                CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
            )
        )
    }
}

/// The halo behind a status symbol: a soft glow round its silhouette, kept
/// outside it so the symbol's cutouts still show what is behind them; spikes
/// that rise from the outline, each brightest at its base and fading to
/// nothing at its tip, long and short ones alternating, travelling slowly
/// round while their lengths ripple; and a gap between the two and the
/// symbol, the colour of the symbol's cutouts.
@MainActor
private final class StatusHalo: NSView {
    // The look, settled in review.
    private static let spikes = 8 // main spikes; as many shorter ones sit between them
    private static let travel: CFTimeInterval = 25.04 // once round the outline
    private static let ripple: CFTimeInterval = 3.0
    private static let shortest: CGFloat = 0 // a main spike's length past the outline at its shortest
    private static let longest: CGFloat = 7.67 // and at its longest
    private static let between: CGFloat = 1.0 // the shorter spikes' length, against a main one's
    private static let baseWidth: CGFloat = 2.94
    private static let spikeBlur: CGFloat = 0.82
    private static let glowSpread: CGFloat = 2.57
    private static let glowStrength: Float = 0.93
    private static let gap: CGFloat = 1.0

    /// How far the halo reaches past the symbol's box, at its longest spikes
    /// and widest blur: whole points, so its layer, and the glow and gap
    /// drawn into it, sit on the same pixels as the symbol.
    static let reach = (longest + 3 * max(spikeBlur, glowSpread) + 1).rounded(.up)

    var outline: SymbolOutline?
    var color = NSColor.systemOrange
    private(set) var isLit = false
    private let halo = CALayer()
    private let glowLayer = CALayer()
    private let rays = CALayer()
    private let gapLayer = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = false
        halo.opacity = 0
        layer?.addSublayer(halo)
        halo.addSublayer(glowLayer)
        halo.addSublayer(rays)
        halo.mask = gapLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild(isMotionReduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Lights or dims the halo: fading when `animated`, at once when not, as
    /// when the status it showed has gone.
    func setLit(_ lit: Bool, animated: Bool) {
        let target: Float = lit ? 1 : 0
        let shown = halo.presentation()?.opacity ?? halo.opacity
        isLit = lit
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.removeAnimation(forKey: "lit")
        halo.opacity = target
        CATransaction.commit()
        guard animated, shown != target else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shown
        fade.toValue = target
        fade.duration = 0.35
        halo.add(fade, forKey: "lit")
    }

    /// Moves the gap with the symbol and leaves the glow and spikes where they are.
    func nudge(_ animation: (CALayer, CGPoint) -> CAAnimation) {
        gapLayer.add(animation(gapLayer, CGPoint(x: bounds.midX, y: bounds.midY)), forKey: "nudge")
    }

    func stopNudge() {
        gapLayer.removeAnimation(forKey: "nudge")
    }

    /// The colour at the halo's heart: a little whiter in the dark, and the
    /// tint itself in the light, where white would wash it out.
    private var heart: NSColor {
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? (color.blended(withFraction: 0.35, of: .white) ?? color) : color
    }

    private func canvas(pixelsPerPoint: CGFloat) -> CGContext? {
        let context = CGContext(
            data: nil,
            width: Int((bounds.width * pixelsPerPoint).rounded(.up)),
            height: Int((bounds.height * pixelsPerPoint).rounded(.up)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
        return context
    }

    /// One spike, its base at the bottom centre, pointing up; brightest and a
    /// little whiter at its base, clear at its tip, its sides curving in.
    private func spike(length: CGFloat, width: CGFloat, alpha: CGFloat, pixelsPerPoint: CGFloat) -> CGImage? {
        let w = Int((width * pixelsPerPoint).rounded(.up))
        let h = Int((length * pixelsPerPoint).rounded(.up))
        guard w > 0, h > 0,
            let context = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addQuadCurve(to: CGPoint(x: width / 2, y: length), control: CGPoint(x: width * 0.42, y: length * 0.22))
        path.addQuadCurve(to: CGPoint(x: width, y: 0), control: CGPoint(x: width * 0.58, y: length * 0.22))
        path.closeSubpath()
        context.addPath(path)
        context.clip()
        let colors =
            [heart.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(alpha * 0.5).cgColor, color.withAlphaComponent(0).cgColor]
            as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.4, 1]) else {
            return nil
        }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: length), options: [])
        return context.makeImage()
    }

    /// The filled silhouette in the heart's colour, blurred, with the
    /// silhouette itself cleared, so the glow lies outside the symbol.
    private func glowImage(_ outline: SymbolOutline, pixelsPerPoint: CGFloat) -> CGImage? {
        guard let canvas = canvas(pixelsPerPoint: pixelsPerPoint) else { return nil }
        let extent = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        canvas.addPath(outline.path)
        canvas.setFillColor(heart.cgColor)
        canvas.fillPath()
        guard let filled = canvas.makeImage() else { return nil }
        let blurred = CIImage(cgImage: filled).clampedToExtent().applyingGaussianBlur(sigma: Double(Self.glowSpread * pixelsPerPoint))
            .cropped(to: extent)
        guard let soft = CIContext().createCGImage(blurred, from: extent) else { return nil }
        canvas.clear(bounds)
        canvas.draw(soft, in: bounds)
        canvas.addPath(outline.path)
        canvas.setBlendMode(.clear)
        canvas.fillPath()
        return canvas.makeImage()
    }

    /// The mask that clears the halo within the gap's width of the symbol's edge.
    private func gapImage(_ outline: SymbolOutline, pixelsPerPoint: CGFloat) -> CGImage? {
        guard let canvas = canvas(pixelsPerPoint: pixelsPerPoint) else { return nil }
        canvas.setFillColor(CGColor(gray: 0, alpha: 1))
        canvas.fill(bounds)
        canvas.setBlendMode(.clear)
        canvas.addPath(outline.path)
        canvas.fillPath()
        canvas.addPath(outline.path)
        canvas.setLineWidth(2 * Self.gap)
        canvas.setLineJoin(.round)
        canvas.strokePath()
        return canvas.makeImage()
    }

    func rebuild(isMotionReduced: Bool) {
        let pixelsPerPoint = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        halo.frame = bounds
        glowLayer.frame = halo.bounds
        rays.frame = halo.bounds
        // The same mask layer each time, so a nudge running on it carries on.
        gapLayer.frame = halo.bounds
        rays.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let outline else {
            glowLayer.contents = nil
            gapLayer.contents = nil
            return
        }
        var images: [CGImage?] = []
        var glow: CGImage?
        var gap: CGImage?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            glow = glowImage(outline, pixelsPerPoint: pixelsPerPoint)
            gap = gapImage(outline, pixelsPerPoint: pixelsPerPoint)
            images = [true, false]
                .map { isMain in
                    spike(
                        length: Self.longest * (isMain ? 1 : Self.between) + 1,
                        width: Self.baseWidth * (isMain ? 1 : 0.6),
                        alpha: isMain ? 1 : 0.75,
                        pixelsPerPoint: pixelsPerPoint
                    )
                }
        }
        glowLayer.contents = glow
        glowLayer.contentsScale = pixelsPerPoint
        glowLayer.opacity = Self.glowStrength
        gapLayer.contents = gap
        gapLayer.contentsScale = pixelsPerPoint
        rays.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: Self.spikeBlur * pixelsPerPoint / 2])]
            .compactMap { $0 }

        // Each spike starts a point under the symbol's edge, so it grows out from beneath it.
        let inset: CGFloat = 1
        let count = 2 * Self.spikes
        let points = outline.points
        for index in 0..<count {
            let isMain = index % 2 == 0
            let fraction = Double(index) / Double(count)
            let at = Int(fraction * Double(points.count)) % points.count
            let before = points[(at + points.count - 3) % points.count]
            let after = points[(at + 3) % points.count]
            let length = Self.longest * (isMain ? 1 : Self.between) + inset
            let shortest = (Self.shortest * (isMain ? 1 : Self.between) + inset) / length

            // The carrier sits on the outline with its x axis along it; moving
            // clockwise, outward is its +y, where the spike points.
            let carrier = CALayer()
            carrier.position = points[at]
            let ray = CALayer()
            ray.contents = images[isMain ? 0 : 1]
            ray.contentsScale = pixelsPerPoint
            ray.bounds = CGRect(x: 0, y: 0, width: Self.baseWidth * (isMain ? 1 : 0.6), height: length)
            ray.anchorPoint = CGPoint(x: 0.5, y: 0)
            ray.position = CGPoint(x: 0, y: -inset)
            carrier.addSublayer(ray)
            rays.addSublayer(carrier)

            if isMotionReduced {
                carrier.setAffineTransform(CGAffineTransform(rotationAngle: atan2(after.y - before.y, after.x - before.x)))
                ray.setAffineTransform(CGAffineTransform(scaleX: 1, y: (shortest + 1) / 2))
                continue
            }
            let travel = CAKeyframeAnimation(keyPath: "position")
            travel.path = outline.path
            travel.calculationMode = .paced
            travel.rotationMode = .rotateAuto
            travel.duration = Self.travel
            travel.repeatCount = .infinity
            travel.timeOffset = fraction * Self.travel
            carrier.add(travel, forKey: "travel")
            let pulse = CABasicAnimation(keyPath: "transform.scale.y")
            pulse.fromValue = shortest
            pulse.toValue = 1
            pulse.duration = Self.ripple / 2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Each spike a little over a third of a ripple behind the one before it.
            pulse.timeOffset = Double(index) * Self.ripple * 0.37
            ray.add(pulse, forKey: "ripple")
        }
    }
}

/// The outer edge of a status symbol: clockwise, evenly spaced, for the
/// spikes to travel along, in the points of a halo that reaches `reach` past
/// the symbol's box on every side.
private struct SymbolOutline {
    let points: [CGPoint]
    let path: CGPath

    /// Traced at a resolution that spans the symbol in about 240 pixels.
    private static let traceScale: CGFloat = 240 / 11

    /// The outer edge of the symbol as `view` last drew it, from its own
    /// layers, so the halo hugs the pixels the tab shows: an image view that
    /// scales a symbol down to fit draws it smaller than the image scaled.
    /// Nil until the view has drawn.
    @MainActor
    init?(drawnBy view: NSImageView, reach: CGFloat) {
        let box = view.bounds.size
        guard let layer = view.layer, let mask = Self.mask(box) else { return nil }
        mask.scaleBy(x: Self.traceScale, y: Self.traceScale)
        layer.render(in: mask)
        self.init(mask, box: box, reach: reach)
    }

    /// The outer edge drawn from the symbol's vectors, where an image view of
    /// `box`, scaling proportionally down, shows it, for before the view has drawn.
    @MainActor
    init?(symbol name: String, box: NSSize, reach: CGFloat) {
        guard
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)),
            let mask = Self.mask(box)
        else { return nil }
        mask.scaleBy(x: Self.traceScale, y: Self.traceScale)
        let fit = min(1, box.width / image.size.width, box.height / image.size.height)
        let size = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        let rect = NSRect(
            x: ((box.width - size.width) / 2).rounded(),
            y: ((box.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: mask, flipped: false)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        self.init(mask, box: box, reach: reach)
    }

    private static func mask(_ box: NSSize) -> CGContext? {
        CGContext(
            data: nil,
            width: Int((box.width * traceScale).rounded(.up)),
            height: Int((box.height * traceScale).rounded(.up)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private init?(_ mask: CGContext, box: NSSize, reach: CGFloat) {
        // Read through the drawn image's bytes: the context's own buffer is a raw pointer.
        guard let image = mask.makeImage(), let pixels = image.dataProvider?.data as Data?,
            let edge = Self.outerEdge([UInt8](pixels), width: image.width, height: image.height, row: image.bytesPerRow)
        else { return nil }
        let traced = edge.map {
            CGPoint(x: (CGFloat($0.x) + 0.5) / Self.traceScale + reach, y: box.height - (CGFloat($0.y) + 0.5) / Self.traceScale + reach)
        }
        points = Self.resampled(Self.smoothed(traced, radius: 10), count: 360)
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        self.path = path
    }

    /// The outer edge of a bitmap's ink, by Moore-neighbour tracing from its
    /// topmost, leftmost pixel, in the bitmap's rows (the first row on top).
    private static func outerEdge(_ bytes: [UInt8], width: Int, height: Int, row: Int) -> [(x: Int, y: Int)]? {
        func isInk(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height && bytes[y * row + x * 4 + 3] > 127 }
        var first: (x: Int, y: Int)?
        search: for y in 0..<height {
            for x in 0..<width where isInk(x, y) {
                first = (x, y)
                break search
            }
        }
        guard let start = first else { return nil }
        let around = [(-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1)]
        var edge = [start]
        var current = start
        var backtrack = 0 // west of the start, which the scan saw clear
        while edge.count < width * height {
            guard let k = (1...8).map({ (backtrack + $0) % 8 }).first(where: { isInk(current.x + around[$0].0, current.y + around[$0].1) })
            else { break }
            let next = (x: current.x + around[k].0, y: current.y + around[k].1)
            let clear = around[(k + 7) % 8]
            let fromNext = (current.x + clear.0 - next.x, current.y + clear.1 - next.y)
            backtrack = around.firstIndex { $0 == fromNext } ?? 0
            current = next
            if current == start { break }
            edge.append(current)
        }
        return edge.count > 2 ? edge : nil
    }

    private static func smoothed(_ points: [CGPoint], radius: Int) -> [CGPoint] {
        let n = points.count
        return (0..<n)
            .map { i in
                var sum = CGPoint.zero
                for j in -radius...radius {
                    let p = points[(i + j + n) % n]
                    sum.x += p.x
                    sum.y += p.y
                }
                let count = CGFloat(2 * radius + 1)
                return CGPoint(x: sum.x / count, y: sum.y / count)
            }
    }

    /// The closed outline as `count` points evenly spaced along it, clockwise.
    private static func resampled(_ points: [CGPoint], count: Int) -> [CGPoint] {
        var ring = points
        let area = zip(ring, ring.dropFirst() + [ring[0]]).reduce(0) { $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y) }
        if area > 0 { ring.reverse() }
        ring.append(ring[0])
        var lengths = [CGFloat(0)]
        for (a, b) in zip(ring, ring.dropFirst()) { lengths.append(lengths[lengths.count - 1] + hypot(b.x - a.x, b.y - a.y)) }
        let total = lengths[lengths.count - 1]
        var result: [CGPoint] = []
        var segment = 0
        for i in 0..<count {
            let distance = total * CGFloat(i) / CGFloat(count)
            while lengths[segment + 1] < distance { segment += 1 }
            let span = lengths[segment + 1] - lengths[segment]
            let t = span > 0 ? (distance - lengths[segment]) / span : 0
            let a = ring[segment]
            let b = ring[segment + 1]
            result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return result
    }
}
