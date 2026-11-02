// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// TabProgressIndicator.swift — small circular progress indicator that occupies
// an inactive tab's accessory slot (replacing the ⌘N hint) while that tab has
// OSC 9;4 progress, so every tab's progress is visible at once.
// Determinate/paused/error states draw a ring filled to the percentage; the
// indeterminate state spins a short arc. One tint drives it (the owner passes
// red for the error state).
//

import AppKit
import QuartzCore

@objc(UBTabProgressIndicator)
public final class TabProgressIndicator: NSView {
    private static let spinKey = "spin"
    private static let lineWidth: CGFloat = 2.0

    private let track = CAShapeLayer() // faint full ring
    private let arc = CAShapeLayer() // the progressing / spinning arc
    /// What the ring is drawing, as a `Ubiquitty::OSC::ProgressState`.
    ///
    /// Readable because it is the answer a fold produced: a caller that folded
    /// several panes into one ring has no other way to see what came out.
    package private(set) var state: UInt8 = 0
    /// The percent behind that state, for the determinate ones.
    package private(set) var value: UInt8 = 0

    @objc
    public var diameter: CGFloat = 13.0 {
        didSet {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    @objc
    public var tintColor: NSColor = .controlAccentColor {
        didSet { needsLayout = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        track.fillColor = NSColor.clear.cgColor
        track.lineWidth = Self.lineWidth
        layer?.addSublayer(track)

        arc.fillColor = NSColor.clear.cgColor
        arc.lineWidth = Self.lineWidth
        arc.lineCap = .round
        arc.anchorPoint = CGPoint(x: 0.5, y: 0.5) // spin about centre
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: diameter, height: diameter)
    }

    // state: 0 hidden · 1 determinate · 2 error (full ring) · 3 indeterminate · 4 paused.
    // value: 0..100 percent (determinate/paused only).
    @objc
    public func setState(_ state: UInt8, value: UInt8) {
        self.state = state
        self.value = value
        needsLayout = true
    }

    /// Lays the ring out again, so a system label colour is resolved for the
    /// appearance the strip now has; layout resolves it, under the view's own.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        apply()
    }

    private func apply() {
        let w = bounds.width
        let h = bounds.height
        let r = (min(w, h) - Self.lineWidth) / 2.0

        if state == 0 || r <= 0 {
            isHidden = true
            arc.removeAnimation(forKey: Self.spinKey)
            return
        }
        isHidden = false

        // Full circle starting at the top, going clockwise; strokeEnd then carves
        // out the filled fraction (top-anchored, like a clock).
        let path = CGMutablePath()
        path.addArc(
            center: CGPoint(x: w / 2.0, y: h / 2.0),
            radius: r,
            startAngle: .pi / 2,
            endAngle: .pi / 2 - 2.0 * .pi,
            clockwise: true
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.path = path
        arc.frame = bounds
        arc.path = path
        track.strokeColor = tintColor.withAlphaComponent(0.22).cgColor
        arc.strokeColor = tintColor.cgColor
        CATransaction.commit()

        if state == 3 { // indeterminate — spin a short arc
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.isHidden = true
            arc.strokeStart = 0.0
            arc.strokeEnd = 0.28
            CATransaction.commit()
            if arc.animation(forKey: Self.spinKey) == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0.0
                spin.toValue = -2.0 * Double.pi // clockwise
                spin.duration = 0.9
                spin.repeatCount = .infinity
                arc.add(spin, forKey: Self.spinKey)
            }
        } else { // determinate / paused / error — fill to value
            arc.removeAnimation(forKey: Self.spinKey)
            let frac: CGFloat = (state == 2) ? 1.0 : (min(CGFloat(value), 100.0) / 100.0)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.isHidden = false
            arc.strokeStart = 0.0
            arc.strokeEnd = frac
            CATransaction.commit()
        }
    }
}
