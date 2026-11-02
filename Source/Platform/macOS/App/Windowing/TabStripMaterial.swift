// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Keeps the native tab track translucent without changing tab contents.
@MainActor
@available(macOS 26.0, *)
package final class TabStripMaterial {
    private weak var glassBand: NSGlassEffectView?
    private weak var filterHost: CALayer?
    private var originalGlassStyle: NSGlassEffectView.Style?
    private var materialObservation: NSKeyValueObservation?
    private var suppressedFills: [ObjectIdentifier: SuppressedFill] = [:]

    package init(glassBand: NSGlassEffectView) {
        self.glassBand = glassBand
        originalGlassStyle = glassBand.style
        materialObservation = glassBand.observe(\.style, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.clearGlassStyle() }
        }
        clearGlassStyle()
    }

    package init(filterHost: CALayer) {
        self.filterHost = filterHost
        // AppKit replaces the material layer on focus and appearance changes.
        // Observe that replacement inside its transaction, before it is shown.
        materialObservation = filterHost.observe(\.sublayers, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshFills() }
        }
        refreshFills()
    }

    func matches(glassBand: NSGlassEffectView?, filterHost: CALayer?) -> Bool {
        self.glassBand === glassBand && self.filterHost === filterHost
    }

    package func restore() {
        materialObservation?.invalidate()
        materialObservation = nil
        for fill in suppressedFills.values { fill.restore() }
        suppressedFills.removeAll()
        if let glassBand, let originalGlassStyle {
            Self.withoutAnimation { glassBand.style = originalGlassStyle }
        }
    }

    private func clearGlassStyle() {
        guard let glassBand, glassBand.style != .clear else { return }
        Self.withoutAnimation { glassBand.style = .clear }
    }

    private func refreshFills() {
        // The macOS 27 subdued track separates its solid content fill from
        // blur, vibrancy, tab labels, and the selected pill. Only the fill is
        // suppressed; hiding its host would also remove native blending.
        let fills = filterHost?.sublayers?.filter { $0.name == "kCUIVariantContentBackgroundMaterial" } ?? []
        let current = Set(fills.map(ObjectIdentifier.init))
        for key in Array(suppressedFills.keys) where !current.contains(key) {
            suppressedFills.removeValue(forKey: key)?.restore()
        }
        for layer in fills {
            let key = ObjectIdentifier(layer)
            if suppressedFills[key] == nil { suppressedFills[key] = SuppressedFill(layer) }
        }
    }

    /// Finds the subdued track's decoration without entering any tab button.
    package static func filterHost(in strip: NSView) -> CALayer? {
        if NSStringFromClass(type(of: strip)) == "NSTabButton" { return nil }
        if strip.layer?.name == "NSTabBarTrackFilterHost" { return strip.layer }
        for child in strip.subviews {
            if let layer = filterHost(in: child) { return layer }
        }
        return nil
    }

    private static func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    @MainActor
    private final class SuppressedFill {
        private weak var layer: CALayer?
        private let wasHidden: Bool
        private var observation: NSKeyValueObservation?

        init(_ layer: CALayer) {
            self.layer = layer
            wasHidden = layer.isHidden
            observation = layer.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.suppress() }
            }
            suppress()
        }

        private func suppress() {
            guard let layer, !layer.isHidden else { return }
            TabStripMaterial.withoutAnimation { layer.isHidden = true }
        }

        func restore() {
            observation?.invalidate()
            observation = nil
            guard let layer else { return }
            TabStripMaterial.withoutAnimation { layer.isHidden = wasHidden }
        }
    }
}
