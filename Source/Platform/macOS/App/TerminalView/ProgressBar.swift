// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ProgressBar.swift — OSC 9;4 progress band: a thin rounded bar, placed by its
// owner where it moves no text: along the bottom edge of chrome that already
// has its height, or over a pane's top edge as an overlay that reserves
// nothing. It is a display and nothing more, so a click on it lands on
// whatever it is drawn over. One tint color drives five states:
//   0 hidden · 1 determinate (value%) · 2 error (full-width) · 3 indeterminate
//   · 4 paused (static fill). State 3 is a stretch/squash comet faithful to
// AppKit's NSProgressIndicator: a pill that bolts off each turn growing wide,
// holds elongated mid-travel, contracts into the far wall, and mirrors at the
// half-cycle so its cap leads in both directions.
//
// State 1 travels between two percents rather than stepping: a quarter-second
// ease on the fill's width, whichever way the percent moved. Only a percent
// that moved earns it — a resize, a pause, an error and the comet's own
// geometry each set the length outright, so the bar animates what the program
// reported and nothing else.
//
// Self-contained layer tree (track · clip · pill · gradient). The owner places
// it and feeds it state/value/tint; height and the track border are tunable.
//

import AppKit
import QuartzCore

@objc(UBProgressBar)
public final class ProgressBar: NSView {
    // The system NSProgressIndicator indeterminate recipe, in points. The comet
    // pill travels a 1000pt reference span from x=-44 to x=996 (anchor at its
    // left edge); we scale the endpoints to the live width. Its gradient grows
    // 80→200 off the turn and contracts back; the whole container mirrors at the
    // half-cycle so the solid cap leads both legs.
    private static let pillBase: CGFloat = 48.0 // pill bounds width (cosmetic; it doesn't clip)
    private static let gradMin: CGFloat = 80.0 // squashed comet width
    private static let gradMax: CGFloat = 200.0 // stretched comet width
    private static let sweepFrom: CGFloat = -44.0 / 1000.0 // left-edge start, fraction of width
    private static let sweepTo: CGFloat = 996.0 / 1000.0 // left-edge end, fraction of width

    private static let indetKey = "overallIndeterminate"
    private static let indetPeriodSecs: CFTimeInterval = 1.9 // full mirror cycle (overall group)

    // The determinate sweep. One string serves as both the key path animated and
    // the key it hangs under, so the fill carries at most one length animation
    // and a second report replaces the first rather than racing it.
    private static let lengthKey = "bounds.size.width"
    private static let lengthSweepSecs: CFTimeInterval = 0.25

    // Tunables — relayout on change.
    /// The height every band in this app stands at, in points.
    ///
    /// Named because a caller lays out the strip a band stands in, and the
    /// strip has to fit inside the room that caller already has.
    @objc
    public static let bandHeightInPoints: CGFloat = 3.0

    @objc
    public var barHeight: CGFloat = ProgressBar.bandHeightInPoints {
        didSet {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    @objc
    public var borderWidth: CGFloat = 0.5 { didSet { needsLayout = true } }
    @objc
    public var capRadius: CGFloat = -1.0 { didSet { needsLayout = true } } // <0 ⇒ pill
    @objc
    public var trackColor: NSColor? { didSet { needsLayout = true } } // nil ⇒ tint @0.18
    @objc
    public var borderColor: NSColor? { didSet { needsLayout = true } } // nil ⇒ tint @0.40
    @objc
    public var tintColor: NSColor = .controlAccentColor { didSet { needsLayout = true } }

    private let track = CALayer() // faint groove + hairline border
    private let clip = CALayer() // animated container (gets the mirror flip)
    private let pill = CALayer() // positioned/squashed node
    private let fill = CAGradientLayer() // the comet gradient (width + color pulse)
    private var state: UInt8 = 0
    private var value: UInt8 = 0
    private var builtWidth: CGFloat = 0 // width the running comet was built for
    private var builtTint: NSColor? // tint the running comet was built for
    private var indetBeginTime: CFTimeInterval = 0 // layer-local begin, for phase-preserving rebuilds
    private var determinateLength: CGFloat? // fill width the last determinate pass set; nil when the bar drew anything else
    private var determinateValue: UInt8 = 0 // the percent that width stands for

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        // clip[0] must be the pill and pill[0] the gradient: the indeterminate
        // animation reaches them through indexed sublayer keyPaths.
        track.anchorPoint = .zero
        layer?.addSublayer(track)

        clip.anchorPoint = .zero
        clip.masksToBounds = true
        clip.zPosition = 1
        layer?.addSublayer(clip)

        pill.anchorPoint = CGPoint(x: 0, y: 0.5)
        clip.addSublayer(pill)

        fill.anchorPoint = .zero
        fill.type = .axial
        pill.addSublayer(fill)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    // state: 0 hidden · 1 determinate · 2 error · 3 indeterminate · 4 paused.
    // value: 0..100 percent (determinate/paused only).
    //
    // A band a cleared report hid is shown again here rather than on layout,
    // so the pass that draws the next report runs on a visible view.
    @objc
    public func setState(_ state: UInt8, value: UInt8) {
        self.state = state
        self.value = value
        if state != 0 {
            isHidden = false
        }
        needsLayout = true
    }

    /// Answers no hit, so a press on the band reaches the view it is drawn
    /// over: the grid's first row, a pane's header, or the title row a window
    /// is dragged by.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// The layer whose width is the bar's length.
    ///
    /// Handed out because the sweep a moved percent adds is the whole of that
    /// claim and a layer hands its animations to nobody else: one frame later a
    /// bar that stepped and a bar that swept stand at the same length, so only
    /// the animation separates them.
    package var fillLayerForTesting: CALayer { fill }

    public override func layout() {
        super.layout()
        applyState()
    }

    private func applyState() {
        let h = barHeight
        let w = bounds.width
        let r = h / 2.0 // pill caps for the moving fill
        let cap = (capRadius < 0.0) ? r : capRadius // configurable track/groove caps

        if state == 0 {
            isHidden = true
            clip.removeAnimation(forKey: Self.indetKey)
            fill.removeAnimation(forKey: Self.lengthKey)
            determinateLength = nil
            return
        }
        isHidden = false

        // Container geometry shared by every state (no implicit animations).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let trackFill = trackColor ?? tintColor.withAlphaComponent(0.18)
        let border = borderColor ?? tintColor.withAlphaComponent(0.40)
        track.frame = CGRect(x: 0, y: 0, width: w, height: h)
        track.cornerRadius = cap
        track.backgroundColor = trackFill.cgColor
        track.borderColor = border.cgColor
        track.borderWidth = borderWidth
        clip.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        clip.position = .zero
        clip.cornerRadius = cap
        fill.cornerRadius = r
        CATransaction.commit()

        let solid = tintColor.cgColor

        if state == 3 {
            fill.removeAnimation(forKey: Self.lengthKey)
            determinateLength = nil
            applyIndeterminate(width: w, height: h, solid: solid)
            return
        }

        // Determinate / error / paused: a solid fill from the left.
        clip.removeAnimation(forKey: Self.indetKey)
        builtWidth = 0
        builtTint = nil // force a rebuild when the comet resumes
        let frac: CGFloat = (state == 2) ? 1.0 : (min(CGFloat(value), 100.0) / 100.0)
        let length = w * frac

        // A determinate percent that moved travels to its new length; every
        // other arrival is a step. `standing` is nil unless the pass before this
        // one drew a determinate fill, so the first percent after the bar
        // appears, after the comet, after an error and after a pause each set
        // the length outright — as does a resize, which moves the length with
        // the percent unchanged. A decrease reads the same way as a rise: the
        // percent differs, so the bar travels back.
        let standing = determinateLength
        let travels = state == 1 && determinateValue != value && standing != nil && standing != length
        determinateLength = (state == 1) ? length : nil
        determinateValue = value
        if state != 1 {
            // An error or a pause takes the bar somewhere the percent did not
            // ask for, so a sweep still in flight would land it at the wrong
            // length after the colour had already changed.
            fill.removeAnimation(forKey: Self.lengthKey)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.transform = CATransform3DIdentity
        pill.transform = CATransform3DIdentity
        pill.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        pill.position = CGPoint(x: 0, y: h / 2.0)
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.colors = [solid, solid]
        fill.locations = [0.0, 1.0]
        // Square the left (it sits flush at the window edge); round only the
        // leading (right) cap.
        fill.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        fill.bounds = CGRect(x: 0, y: 0, width: length, height: h)
        fill.position = .zero
        CATransaction.commit()

        // The model already stands at the new length; the sweep is what the
        // presentation shows on the way there. The fill's anchor is its left
        // edge, so a width that grows or shrinks moves only the leading cap.
        guard travels, let standing else { return }
        let sweep = CABasicAnimation(keyPath: Self.lengthKey)
        sweep.fromValue = standing
        sweep.toValue = length
        sweep.duration = Self.lengthSweepSecs
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fill.add(sweep, forKey: Self.lengthKey)
    }

    // Build (or rebuild) the indeterminate comet. The whole animation is one
    // nested group attached to `clip`, reaching the pill and gradient through
    // indexed sublayer keyPaths — verbatim to AppKit's recipe.
    private func applyIndeterminate(width w: CGFloat, height h: CGFloat, solid: CGColor) {
        // Rebuild only on geometry/tint change; else a running comet would snap
        // back to its start on every layout pass.
        let wasRunning = clip.animation(forKey: Self.indetKey) != nil
        if wasRunning && builtWidth == w && builtTint == tintColor {
            return
        }
        builtWidth = w
        builtTint = tintColor

        let clear = tintColor.withAlphaComponent(0.0).cgColor

        // Base comet: axial gradient right→left — solid cap at the right (leads
        // rightward motion), fading to clear on the left. Starts squashed at the
        // left turn.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.transform = CATransform3DIdentity
        pill.transform = CATransform3DIdentity
        pill.bounds = CGRect(x: 0, y: 0, width: Self.pillBase, height: h)
        pill.position = CGPoint(x: w * Self.sweepFrom, y: h / 2.0)
        fill.startPoint = CGPoint(x: 1, y: 0)
        fill.endPoint = CGPoint(x: 0, y: 0)
        fill.colors = [solid, clear]
        fill.locations = [0.4, 1.0]
        fill.maskedCorners = [
            .layerMinXMinYCorner, .layerMinXMaxYCorner,
            .layerMaxXMinYCorner, .layerMaxXMaxYCorner,
        ] // full pill
        fill.bounds = CGRect(x: 0, y: 0, width: Self.gradMin, height: h)
        fill.position = .zero
        CATransaction.commit()

        let linear = CAMediaTimingFunction(controlPoints: 0, 0, 1, 1)

        // Every node holds its end value through the 0.12s dwell past the 0.83s
        // sweep (Apple's "fill=forwards keepOnComplete"). Without this the pill's
        // position reverts to its model value (the left start) mid-cycle, flashing
        // a ghost on the near side just as the comet reaches the far wall.
        let hold: (CAAnimation) -> Void = { a in
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
        }

        // [0] flip: mirror the container horizontally at the half-cycle turn
        // (x' = -x + w) so the cap leads the return leg too — bounce + cap convert.
        let mirror = CATransform3DMakeAffineTransform(
            CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        )
        let flip = CAKeyframeAnimation(keyPath: "transform")
        flip.values = [
            NSValue(caTransform3D: CATransform3DIdentity),
            NSValue(caTransform3D: mirror),
        ]
        flip.keyTimes = [0.0, 0.5, 1.0]
        flip.calculationMode = .discrete
        flip.duration = 1.9

        // [1][0] pill squash: narrow → wide → neutral → narrow. Horizontal only —
        // the system bar's vertical pinch (scaleY 0.7) reads as a top/bottom gap on
        // a thin bar, so we keep full height throughout.
        let pillT = CAKeyframeAnimation(keyPath: "sublayers.@index(0).transform")
        pillT.values = [
            NSValue(caTransform3D: CATransform3DMakeScale(0.6, 1.0, 1)),
            NSValue(caTransform3D: CATransform3DIdentity),
            NSValue(caTransform3D: CATransform3DIdentity),
            NSValue(caTransform3D: CATransform3DIdentity),
            NSValue(caTransform3D: CATransform3DMakeScale(0.6, 1.0, 1)),
        ]
        pillT.keyTimes = [0.0, 0.05, 0.58, 0.8181818181818181, 1.0]
        pillT.duration = 0.83

        // [1][1] pill travel: full sweep, eased in/out (0.42,0,0.58,1).
        let pillP = CABasicAnimation(keyPath: "sublayers.@index(0).position.x")
        pillP.fromValue = w * Self.sweepFrom
        pillP.toValue = w * Self.sweepTo
        pillP.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.58, 1.0)
        pillP.duration = 0.83

        // [1][2] gradient width: grow fast off the turn, hold, contract into the wall.
        let grow = CABasicAnimation(keyPath: "sublayers.@index(0).sublayers.@index(0).bounds.size.width")
        grow.fromValue = Self.gradMin
        grow.toValue = Self.gradMax
        grow.beginTime = 0.008
        grow.duration = 0.166
        grow.timingFunction = linear

        let shrink = CABasicAnimation(keyPath: "sublayers.@index(0).sublayers.@index(0).bounds.size.width")
        shrink.fromValue = Self.gradMax
        shrink.toValue = Self.gradMin
        shrink.beginTime = 0.747
        shrink.duration = 0.083
        shrink.timingFunction = linear

        // [1][2][2] tail: present mid-pass, collapsed to a solid dot at the ends.
        let columns = CAKeyframeAnimation(keyPath: "sublayers.@index(0).sublayers.@index(0).colors")
        columns.values = [
            [solid, solid], [solid, solid], [solid, clear],
            [solid, clear], [solid, solid], [solid, solid],
        ]
        columns.keyTimes = [0.0, 0.1, 0.35, 0.55, 0.85, 1.0]
        columns.duration = 0.83

        let fillGroup = CAAnimationGroup()
        fillGroup.animations = [grow, shrink, columns]
        fillGroup.duration = 0.83

        let inner = CAAnimationGroup()
        inner.animations = [pillT, pillP, fillGroup]
        inner.duration = 0.95 // a touch of dwell past the 0.83 sweep
        inner.repeatCount = 2.0 // two passes per 1.9s cycle (mirrored by [0])

        for a in [flip, pillT, pillP, grow, shrink, columns, fillGroup, inner] as [CAAnimation] {
            hold(a)
        }

        let overall = CAAnimationGroup()
        overall.animations = [flip, inner]
        overall.duration = Self.indetPeriodSecs
        overall.repeatCount = .infinity
        hold(overall)

        // Resume the comet at the phase it had reached rather than restarting it. A
        // rebuild fires on a tint flip (accent⇄gray as the window goes in/active) or
        // a width change (resize); without back-dating beginTime by the live phase,
        // each rebuild would snap the comet back to its start. beginTime sits in the
        // layer's local time, so derive "now" via convertTime and offset it back.
        let localNow = clip.convertTime(CACurrentMediaTime(), from: nil)
        let phase =
            wasRunning
            ? fmod(localNow - indetBeginTime, Self.indetPeriodSecs)
            : 0.0
        overall.beginTime = localNow - phase
        indetBeginTime = overall.beginTime

        clip.removeAnimation(forKey: Self.indetKey)
        clip.add(overall, forKey: Self.indetKey)
    }
}
