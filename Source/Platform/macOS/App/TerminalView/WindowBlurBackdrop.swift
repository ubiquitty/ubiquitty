// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// WindowBlurBackdrop.swift — the blurred desktop behind a translucent window.
//
// A behind-window visual effect view at the bottom of the window's content:
// the system blurs whatever lies behind the window into a HUD material, and
// the translucent frame above it — the theme background at
// [appearance] background_opacity, ink solid — tints it. Public API, so it
// ships in every build; the window-server radius the private CGS call sets
// is an extra a build may opt into on top, not the thing blur depends on.
//
import AppKit
import QuartzCore

#if UBIQUITTY_BACKGROUND_BLUR
// The private window-server call, in a build that opted into it: not App
// Store safe, which is why it is a CMake option and off by default.
@_silgen_name("CGSMainConnectionID")
private func windowServerConnection() -> Int32
@_silgen_name("CGSSetWindowBackgroundBlurRadius")
private func setWindowServerBlurRadius(_ connection: Int32, _ window: Int32, _ radius: Int32) -> Int32
#endif

/// The material behind a blurred window.
@objc(UBWindowBlurBackdrop)
public final class WindowBlurBackdrop: NSVisualEffectView {
    private var tintView: NSView?

    /// Places ordinary theme tint above the material and below title content.
    package func setTintColor(_ color: NSColor) {
        if tintView == nil {
            let tint = NSView(frame: bounds)
            tint.autoresizingMask = [.width, .height]
            tint.wantsLayer = true
            addSubview(tint)
            tintView = tint
        }
        tintView?.layer?.backgroundColor = color.cgColor
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The radius last asked of the window server per window number, for a
    /// scenario: the call itself cannot be read back.
    package static var lastRequestedRadiusForTesting: [Int: Int] = [:]

    /// Sets the window server's behind-window blur radius for a window.
    ///
    /// Both shells call this: the backdrop above is the blur every build has,
    /// and the radius is the extra a build with the private call opted into
    /// applies on top. Zero tears it down. Safe before the window is on
    /// screen — a window without a number is left alone.
    ///
    /// - Parameters:
    ///   - radius: The radius in points, 0 for none.
    ///   - window: The window.
    @objc(applyWindowServerRadius:to:)
    public static func applyWindowServerRadius(_ radius: Double, to window: NSWindow) {
        let number = window.windowNumber
        guard number > 0 else { return }
        let rounded = Int(max(0, min(50, radius)) + 0.5)
        lastRequestedRadiusForTesting[number] = rounded
        #if UBIQUITTY_BACKGROUND_BLUR
        _ = setWindowServerBlurRadius(windowServerConnection(), Int32(number), Int32(rounded))
        #endif
    }

    /// Puts a backdrop at the bottom of a content view, filling it.
    ///
    /// - Parameter host: The view the panes live in; the backdrop goes under
    ///   every subview it has or gains.
    /// - Returns: The installed backdrop, hidden until shown.
    @objc(installUnder:)
    @discardableResult
    public static func install(under host: NSView) -> WindowBlurBackdrop {
        let backdrop = WindowBlurBackdrop(frame: host.bounds)
        backdrop.autoresizingMask = [.width, .height]
        if let first = host.subviews.first {
            host.addSubview(backdrop, positioned: .below, relativeTo: first)
        } else {
            host.addSubview(backdrop)
        }
        return backdrop
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .behindWindow
        material = .hudWindow
        state = .active
        isEmphasized = false
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WindowBlurBackdrop is built in code")
    }

    /// Shows or hides the blur.
    ///
    /// - Parameter isShown: Whether the window blurs what lies behind it.
    @objc
    public func setShown(_ isShown: Bool) {
        isHidden = !isShown
    }
}

/// Presents a GPU glyph mask as vibrant content of the window's native material.
@MainActor
public final class SecondaryTextPlane: NSView {
    public let metalLayer = CAMetalLayer()
    package private(set) var secondaryInk = SIMD4<Float>(repeating: 0)
    package private(set) var tertiaryInk = SIMD4<Float>(repeating: 0)
    public override var allowsVibrancy: Bool { true }
    public override var isFlipped: Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(metalLayer)
        metalLayer.isOpaque = false
        metalLayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SecondaryTextPlane is built in code") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Places native ink above the terminal tint, inside the same material host.
    public func attach(to source: NSView, matching sourceLayer: CAMetalLayer, ordered placement: NSWindow.OrderingMode = .above) -> Bool {
        func backdrop(above view: NSView) -> NSVisualEffectView? {
            guard let parent = view.superview else { return nil }
            if let effect = parent as? NSVisualEffectView, !effect.isHidden { return effect }
            return backdrop(above: parent)
        }
        guard let effect = backdrop(above: source) else {
            removeFromSuperview()
            return false
        }
        if superview !== effect { effect.addSubview(self, positioned: placement, relativeTo: nil) }
        let isDark = source.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        appearance = NSAppearance(named: isDark ? .vibrantDark : .vibrantLight)
        appearance?
            .performAsCurrentDrawingAppearance {
                func ink(_ semantic: NSColor) -> SIMD4<Float> {
                    guard let color = semantic.usingColorSpace(.sRGB) else { return .zero }
                    return SIMD4(
                        Float(color.redComponent),
                        Float(color.greenComponent),
                        Float(color.blueComponent),
                        Float(color.alphaComponent)
                    )
                }
                secondaryInk = ink(.secondaryLabelColor)
                tertiaryInk = ink(.tertiaryLabelColor)
            }
        synchronizeGeometry(to: source, matching: sourceLayer)
        metalLayer.device = sourceLayer.device
        metalLayer.pixelFormat = sourceLayer.pixelFormat
        metalLayer.colorspace = sourceLayer.colorspace
        metalLayer.contentsScale = sourceLayer.contentsScale
        metalLayer.drawableSize = sourceLayer.drawableSize
        metalLayer.presentsWithTransaction = sourceLayer.presentsWithTransaction
        isHidden = source.isHiddenOrHasHiddenAncestor
        return true
    }

    /// Follows layout and elastic motion without waiting for another terminal frame.
    public func synchronizeGeometry(to source: NSView, matching sourceLayer: CAMetalLayer) {
        guard let superview else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = source.convert(source.bounds, to: superview)
        metalLayer.frame = sourceLayer.frame
        CATransaction.commit()
    }
}
