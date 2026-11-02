// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
internal import UbiquittyCore

/// Renders settings samples through the same terminal, font routing, and Metal renderer as a window.
///
/// The surface owns no process or transport. Sample bytes only enter its private model.
@MainActor
package final class TerminalSettingsPreview: NSView {
    package static var configuredFontFamily: String {
        TerminalSurface.family(of: Ubiquitty.Preferences.Effective.liveRenderConfiguration())
    }

    package private(set) var surface: TerminalSurface?
    package private(set) var renderedFamily = ""
    package private(set) var renderedPointSize = 0.0
    package var sample = "" {
        didSet { if sample != oldValue { drawSample() } }
    }
    package var familyOverride: String? {
        didSet { if familyOverride != oldValue { applyConfiguration() } }
    }
    package var featuresOverride: String? {
        didSet { if featuresOverride != oldValue { applyConfiguration() } }
    }
    package var showsCursor = false {
        didSet { if showsCursor != oldValue { drawSample() } }
    }
    package var isPreviewActive = true {
        didSet { surface?.setSurfaceFocused(isPreviewActive) }
    }
    private var configurationObserver: NSObjectProtocol?
    private var previousSize = NSSize.zero

    package override init(frame: NSRect) {
        super.init(frame: frame)
        surface = TerminalSurface(rows: 12, columns: 80)
        if let surface {
            addSubview(surface)
            surface.autoresizingMask = [.width, .height]
        } else {
            let label = NSTextField(labelWithString: "Terminal preview is unavailable.")
            addSubview(label)
            label.frame = bounds.insetBy(dx: 12, dy: 12)
            label.autoresizingMask = [.width, .height]
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .terminalAppearanceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyConfiguration() }
        }
        applyConfiguration()
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Terminal rendering preview")
    }

    package required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    /// Releases rendering resources when SwiftUI removes the representable.
    package func releaseSurface() {
        surface?.removeFromSuperview()
        surface = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    package override func hitTest(_ point: NSPoint) -> NSView? { nil }

    package override func layout() {
        super.layout()
        guard previousSize != bounds.size else { return }
        previousSize = bounds.size
        surface?.frame = bounds
        surface?.layoutSubtreeIfNeeded()
        drawSample()
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        surface?.setSurfaceFocused(isPreviewActive)
    }

    /// Re-reads the window's configuration fold without changing preferences.
    ///
    /// The specimen's own facts are overrides on a copy of Core's fold: it
    /// fits its container, so the window's padding has no meaning here, and it
    /// is drawn opaque whatever ground a window would take.
    package func applyConfiguration() {
        guard let surface else { return }
        let values = Ubiquitty.Preferences.values()
        var configuration = Ubiquitty.Preferences.Effective.liveRenderConfiguration()
        configuration.paddingLeftPoints = 12
        configuration.paddingRightPoints = 12
        configuration.paddingTopPoints = 10
        configuration.paddingBottomPoints = 10
        configuration.backgroundOpacity = 1
        configuration.defaultBackgroundOpacity = 1
        let family =
            familyOverride.flatMap { $0.isEmpty ? TerminalSurface.installedHouseFontFamily() : $0 }
            ?? TerminalSurface.family(of: configuration)
        var typography = SurfaceTypography(configuration: configuration)
        if let featuresOverride { typography.ligatureFeatureSpec = featuresOverride }
        let style = SurfaceStyle(configuration: configuration, systemTransparency: .Allowed)
        if let renderer = surface.renderer as? SurfaceRenderer {
            if !renderer.adopt(pointSize: configuration.fontSizePoints, familyName: family, typography: typography) {
                _ = renderer.adopt(
                    pointSize: configuration.fontSizePoints,
                    familyName: TerminalSurface.installedHouseFontFamily(),
                    typography: typography
                )
            }
            renderer.style = style
            renderer.adopt(usesDisplayP3: configuration.usesDisplayP3, relabeling: surface.metalLayer)
        } else {
            surface.renderer = TerminalSurface.makeRenderer(
                fontFamily: family,
                pointSize: configuration.fontSizePoints,
                typography: typography,
                style: style
            )
        }
        if let renderer = surface.renderer as? SurfaceRenderer {
            renderedFamily = renderer.familyName
            renderedPointSize = renderer.pointSize
            surface.drive.publishActualFont(family: renderedFamily, sizePoints: renderedPointSize)
        }
        surface.drive.applyPickedCursorPreferences(values.pointee)
        surface.drive.applyTerminalPreferences(values.pointee)
        _ = surface.drive.reseedLaunchTheme(values.pointee)
        surface.republishAfterPreferenceWrite()
        surface.invalidateRetainedBaseline()
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        drawSample()
    }

    private func drawSample() {
        guard let surface else { return }
        let visibility = showsCursor ? "\u{1b}[?25h" : "\u{1b}[?25l"
        surface.feed(Data(("\u{1b}[0m\u{1b}[2J\u{1b}[H" + visibility + sample).utf8))
        surface.setSurfaceFocused(isPreviewActive)
        surface.needsDisplay = true
    }

    /// Demonstrates both a short step and a long jump, including the post-input blink hold.
    package func moveCursor(to column: Int) {
        guard showsCursor, let surface else { return }
        surface.noteUserActivity()
        surface.feed(Data("\u{1b}[2;\(max(1, column))H".utf8))
    }
}
