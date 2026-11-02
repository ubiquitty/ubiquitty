// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TranslucencyScenarios — the Swift window's ground follows Core's fold.
//
// Reduce Transparency makes the window opaque, and an opaque window must draw
// its renderer opaque too: the compositor keeps a translucent frame's
// premultiplied colour and drops its alpha against an opaque backing, so a
// sub-unity tint there darkens the theme towards black. What these scenarios
// read is the frame's own alpha and colour, off the capture's uniforms, and
// the blur radius the window server was asked for.

import AppKit
import UbiquittyKit
import UbiquittyRenderKit

@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let surface = view as? TerminalSurface {
        return surface
    }
    for subview in view.subviews {
        if let found = terminalSurface(under: subview) {
            return found
        }
    }
    return nil
}

/// Pumps until a full frame has been drawn under the current ground.
@MainActor
private func drawFrame(_ t: UBUITestContext, of surface: TerminalSurface) {
    surface.invalidateRetainedBaseline()
    surface.needsDisplay = true
    t.pump(0.3)
}

enum TranslucencyScenarios {
    static func register() {
        UBUITestRegister("unblurred_titlebar_keeps_background_opacity") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                let savedTransparency = TerminalWindowController.systemTransparencyOverrideForTesting
                TerminalWindowController.systemTransparencyOverrideForTesting = .Allowed
                defer {
                    TerminalWindowController.systemTransparencyOverrideForTesting = savedTransparency
                    t.restoreConfiguration(saved)
                }
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a terminal opens for titlebar opacity")
                    return
                }
                defer { window.close() }
                let noir = "Noir".withCString { Ubiquitty.Themes.indexForName($0) }
                t.expect(shell.applyInspectedTheme(Int(noir), to: surface), desc: "Noir applies")
                for style in ["themed", "native"] {
                    for opacity in [0.5, 0.8, 0.0] {
                        for radius in [20, 0] {
                            t.configureAppending(
                                "[appearance]\nfollow_system = false\nhide_title_bar = false\n"
                                    + "background_opacity = \(opacity)\nblur_radius = \(radius)\ntitlebar_style = \"\(style)\"\n"
                            )
                            shell.refreshSessionAppearance()
                            t.pump(0.1)
                        }
                        guard let root = window.contentView,
                            let container = TabStripStyling.titlebarContainer(searchingFrom: root.superview ?? root),
                            let background = container.layer?.backgroundColor,
                            let color = NSColor(cgColor: background)?.usingColorSpace(.sRGB)
                        else {
                            t.expect(false, desc: "an unblurred titlebar retains its tint at opacity \(opacity)")
                            continue
                        }
                        t.expect(abs(color.alphaComponent - opacity) < 0.01, desc: "\(style) titlebar follows opacity \(opacity)")
                        t.expect(abs(color.redComponent - 21.0 / 255) < 0.01, desc: "the titlebar retains the theme background color")
                        t.expect(!container.subviews.contains { $0 is WindowBlurBackdrop }, desc: "turning blur off removes its material")
                    }
                }
            }
        }

        UBUITestRegister("translucent_theme_material_and_title_keep_the_theme_appearance") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                let savedAppearance = NSApp.appearance
                let savedTransparency = TerminalWindowController.systemTransparencyOverrideForTesting
                TerminalWindowController.systemTransparencyOverrideForTesting = .Allowed
                defer {
                    NSApp.appearance = savedAppearance
                    TerminalWindowController.systemTransparencyOverrideForTesting = savedTransparency
                    t.restoreConfiguration(saved)
                }
                @MainActor
                func configure(opacity: Double, titlebarStyle: String = "themed") {
                    t.configureAppending(
                        "[appearance]\nfollow_system = false\nhide_title_bar = false\n"
                            + "background_opacity = \(opacity)\nblur_radius = 20.0\ntitlebar_style = \"\(titlebarStyle)\"\n"
                    )
                }
                configure(opacity: 1)
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ), let surface = shell.focusedSurfaceForTesting, let window = shell.window
                else {
                    t.expect(false, desc: "a window opens for theme material appearance")
                    return
                }
                defer { window.close() }
                let themes: [(String, NSAppearance.Name, NSAppearance.Name)] = [
                    ("Noir", .darkAqua, .aqua),
                    ("Noir Clair", .aqua, .darkAqua),
                    ("Glass Dark", .darkAqua, .aqua),
                ]
                for (theme, expected, applicationAppearance) in themes {
                    NSApp.appearance = NSAppearance(named: applicationAppearance)
                    let index = theme.withCString { Ubiquitty.Themes.indexForName($0) }
                    t.expect(shell.applyInspectedTheme(Int(index), to: surface), desc: "\(theme) applies to the session")
                    for opacity in [1.0, 0.5, 0.0, 1.0] {
                        configure(opacity: opacity)
                        shell.refreshSessionAppearance()
                        t.pump(0.2)
                        let state = "\(theme) at opacity \(opacity)"
                        t.expect(surface.currentThemeName == theme, desc: "\(state) retains its palette")
                        t.expect(window.isOpaque == (opacity == 1), desc: "\(state) applies the requested opacity")
                        t.expect(
                            window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
                            desc: "\(state) keeps its native appearance against the opposite application appearance"
                        )
                        t.expect(
                            shell.paneHost.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
                            desc: "\(state) gives the background material the theme's polarity"
                        )
                        guard let strip = titlebarStrip(of: window), let field = titleField(in: strip) else {
                            t.expect(false, desc: "\(state) has a native title field")
                            continue
                        }
                        t.expect(
                            field.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
                            desc: "\(state) resolves native title ink against the theme's polarity"
                        )
                    }
                }
                NSApp.appearance = NSAppearance(named: .aqua)
                let noir = "Noir".withCString { Ubiquitty.Themes.indexForName($0) }
                t.expect(shell.applyInspectedTheme(Int(noir), to: surface), desc: "Noir applies for the native-titlebar setting")
                for opacity in [1.0, 0.5, 1.0] {
                    configure(opacity: opacity, titlebarStyle: "native")
                    shell.refreshSessionAppearance()
                    t.expect(
                        window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (opacity == 1 ? .aqua : .darkAqua),
                        desc: "opaque native titlebars follow the application; translucent material follows Noir"
                    )
                }
            }
        }

        UBUITestRegister("opaque_perceptual_text_contrast_toggles_without_blur") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else { return }
                let saved = t.configureAppending(
                    "[appearance]\nbackground_opacity = 1.0\nblur_radius = 0.0\ntext_contrast = true\n"
                )
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.applyAppearanceToOpenWindows()
                }
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ), let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "an opaque terminal opens for perceptual contrast")
                    return
                }
                defer { shell.window?.close() }
                surface.feed(
                    Data(
                        "\u{1b}[?25l\u{1b}[2J\u{1b}[H\u{1b}[48;2;20;20;20m\u{1b}[38;2;50;50;50mDark application text\r\n\u{1b}[38;2;80;40;10mOrange text\r\n\u{1b}[48;2;255;255;255m\u{1b}[30mReadable black on white\u{1b}[0m"
                            .utf8
                    )
                )
                drawFrame(t, of: surface)
                t.expect(settingBool(.AppearanceTextContrast), desc: "contrast is enabled on an opaque window")
                t.expect(shell.window?.isOpaque == true, desc: "contrast does not enable window transparency")
                let text = surface.gridTextForTesting()
                guard let enhanced = surface.renderedFrameForTesting() else {
                    t.expect(false, desc: "the contrast-corrected frame renders")
                    return
                }
                app.settingsSetTextContrast(false)
                drawFrame(t, of: surface)
                guard let original = surface.renderedFrameForTesting() else {
                    t.expect(false, desc: "the original colors render with contrast disabled")
                    return
                }
                t.expect(!settingBool(.AppearanceTextContrast), desc: "the live setting disables contrast")
                t.expect(original.pixels != enhanced.pixels, desc: "contrast changes low-contrast glyph pixels without blur")
                app.settingsSetTextContrast(true)
                drawFrame(t, of: surface)
                t.expect(
                    t.wait(until: { surface.renderedFrameForTesting()?.pixels == enhanced.pixels }, timeout: 3),
                    desc: "the live setting restores the contrast-corrected frame exactly"
                )
                t.expect(surface.gridTextForTesting() == text, desc: "contrast does not change terminal contents")
            }
        }

        UBUITestRegister("vibrant_tmux_status_tints_survive_zero_opacity_on_ordinary_themes") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let vibrantBlur = "[appearance]\nblur_radius = 20.0\ntext_contrast_on_blur = true\nbackground_vibrancy = true\n"
                let saved = t.configureAppending(vibrantBlur)
                TerminalWindowController.systemTransparencyOverrideForTesting = .Allowed
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.systemTransparencyOverrideForTesting = nil
                }
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ), let surface = shell.focusedSurfaceForTesting, let window = shell.window
                else {
                    t.expect(false, desc: "a window opens for the tmux status colors")
                    return
                }
                defer { window.close() }
                let scene =
                    "\u{1b}[2J\u{1b}[H\u{1b}[?25l\u{1b}[38;2;21;23;28m\u{1b}[48;2;114;163;232m tmux \u{1b}[48;2;227;190;124m 2 \u{1b}[0m"
                for theme in ["Noir", "Glass Dark"] {
                    let index = theme.withCString { Ubiquitty.Themes.indexForName($0) }
                    t.expect(shell.applyInspectedTheme(Int(index), to: surface), desc: "\(theme) applies to the status test")
                    surface.feed(Data(scene.utf8))
                    for tint in [0.0, 0.5, 1.0, 0.0] {
                        t.restoreConfiguration(saved)
                        t.configureAppending(vibrantBlur + "background_opacity = \(tint)\n")
                        shell.refreshSessionAppearance()
                        drawFrame(t, of: surface)
                        guard let ordinary = surface.retainedGridPixelsForTesting(),
                            let origin = surface.lastFrameOriginForTesting,
                            let cell = surface.drawnCellSizeForTesting
                        else {
                            t.expect(false, desc: "status background pixels and geometry are readable")
                            return
                        }
                        let native = surface.nativeBackgroundPixelsForTesting()
                        let scale = surface.metalLayer.contentsScale
                        let frameWidth = Int(surface.metalLayer.drawableSize.width)
                        func pixel(_ data: Data?, column: CGFloat) -> [UInt8] {
                            guard let data else { return [] }
                            let x = Int(CGFloat(origin.x) + (column + 0.5) * cell.width * scale)
                            let y = Int(CGFloat(origin.y) + 0.5 * cell.height * scale)
                            let offset = (y * frameWidth + x) * 4
                            guard offset >= 0, offset + 4 <= data.count else { return [] }
                            return Array(data[offset..<(offset + 4)])
                        }
                        let blue = pixel(tint < 1 ? native : ordinary, column: 0)
                        let yellow = pixel(tint < 1 ? native : ordinary, column: 6)
                        t.expect(blue.count == 4 && blue[3] > 0, desc: "\(theme) blue status fill survives opacity \(tint)")
                        t.expect(yellow.count == 4 && yellow[3] > 0, desc: "\(theme) yellow status fill survives opacity \(tint)")
                        t.expect(blue != yellow, desc: "status segments keep distinct tints")
                        if tint == 0 {
                            t.expect(pixel(ordinary, column: 10) == [0, 0, 0, 0], desc: "zero opacity leaves the default ground clear")
                        }
                    }
                }
            }
        }

        UBUITestRegister("selection_preserves_antialiased_edges_on_transparent_ground") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The byte blend below is the over-text tint style; native
                // fills behind glyphs and keeps their own colour.
                let tintStyle = "[selection]\nstyle = \"tint\"\n"
                let saved = t.configureAppending("[appearance]\ntext_contrast_on_blur = false\n" + tintStyle)
                TerminalWindowController.systemTransparencyOverrideForTesting = .Allowed
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.systemTransparencyOverrideForTesting = nil
                }
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let surface = shell.focusedSurfaceForTesting, let window = shell.window
                else {
                    t.expect(false, desc: "a selection-compositing window opens")
                    return
                }
                defer { window.close() }
                surface.feed(Data("\u{1b}[2J\u{1b}[H\u{1b}[?25l\u{1b}[38;2;220;220;220mMMMMMMMM\u{1b}[0m".utf8))
                let tint = Ubiquitty.Rendering.selectionHighlightColor()
                let color = [Double(tint.blue), Double(tint.green), Double(tint.red), 1.0]
                let alpha = Double(tint.alpha)
                for opacity in [0.0, 0.4, 1.0] {
                    t.restoreConfiguration(saved)
                    t.configureAppending("[appearance]\ntext_contrast_on_blur = false\nbackground_opacity = \(opacity)\n" + tintStyle)
                    shell.refreshSessionAppearance()
                    surface.clearSelection()
                    drawFrame(t, of: surface)
                    guard let plain = surface.renderedFrameForTesting(),
                        let origin = surface.lastFrameOriginForTesting,
                        let cell = surface.drawnCellSizeForTesting
                    else {
                        t.expect(false, desc: "the unselected antialiased frame is readable")
                        return
                    }
                    surface.selectAll(nil)
                    t.pump(0.1)
                    guard let selected = surface.renderedFrameForTesting() else {
                        t.expect(false, desc: "the selected antialiased frame is readable")
                        return
                    }
                    let scale = surface.metalLayer.contentsScale
                    let startX = Int(origin.x)
                    let startY = Int(origin.y)
                    let endX = min(plain.width, startX + Int(cell.width * scale * 8))
                    let endY = min(plain.height, startY + Int(cell.height * scale))
                    var worstError = 0.0
                    var edgePixels = 0
                    for y in startY..<endY {
                        for x in startX..<endX {
                            let offset = (y * plain.width + x) * 4
                            if Double(plain.pixels[offset + 3]) > opacity * 255 + 8 && plain.pixels[offset + 3] < 245 {
                                edgePixels += 1
                            }
                            for channel in 0..<4 {
                                let expected = Double(plain.pixels[offset + channel]) * (1 - alpha) + color[channel] * 255 * alpha
                                worstError = max(worstError, abs(Double(selected.pixels[offset + channel]) - expected))
                            }
                        }
                    }
                    t.expect(
                        worstError <= 2,
                        desc:
                            "selection blends stored premultiplied bytes without a bright glyph rim at opacity \(opacity) (error \(worstError))"
                    )
                    if opacity < 1 {
                        t.expect(edgePixels > 20, desc: "the comparison includes fractional glyph-edge coverage")
                    }
                }
            }
        }

        UBUITestRegister("glass_powerline_matches_backgrounds_at_every_opacity") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The blur and its text contrast are left unset, so each
                // reads as its default; the variants below append to that.
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                let unblurred = documentDroppingKeys(["blur_radius", "text_contrast_on_blur"], inSection: "appearance", of: saved)
                @MainActor
                func configureGlass(_ lines: String) {
                    t.restoreConfiguration(unblurred + "\n[appearance]\ntitlebar_style = \"themed\"\n" + lines)
                }
                configureGlass("")
                TerminalWindowController.systemTransparencyOverrideForTesting = .Allowed
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.systemTransparencyOverrideForTesting = nil
                }
                SystemTheme.refresh()
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let surface = shell.focusedSurfaceForTesting, let window = shell.window
                else {
                    t.expect(false, desc: "a window opens for Powerline compositing")
                    return
                }
                defer { window.close() }
                let separators: [(glyph: String, inside: CGPoint, outside: CGPoint)] = [
                    ("\u{e0b0}", CGPoint(x: 1.18, y: 0.5), CGPoint(x: 1.88, y: 0.08)),
                    ("\u{e0b2}", CGPoint(x: 1.82, y: 0.5), CGPoint(x: 1.12, y: 0.08)),
                    ("\u{e0b4}", CGPoint(x: 1.18, y: 0.5), CGPoint(x: 1.88, y: 0.08)),
                    ("\u{e0b6}", CGPoint(x: 1.82, y: 0.5), CGPoint(x: 1.12, y: 0.08)),
                    ("\u{2580}", CGPoint(x: 1.5, y: 0.2), CGPoint(x: 1.5, y: 0.8)),
                    ("\u{2584}", CGPoint(x: 1.5, y: 0.8), CGPoint(x: 1.5, y: 0.2)),
                    ("\u{258c}", CGPoint(x: 1.2, y: 0.5), CGPoint(x: 1.8, y: 0.5)),
                    ("\u{2590}", CGPoint(x: 1.8, y: 0.5), CGPoint(x: 1.2, y: 0.5)),
                    ("\u{2588}", CGPoint(x: 1.5, y: 0.5), CGPoint(x: 2.5, y: 0.5)),
                    ("\u{259b}", CGPoint(x: 1.2, y: 0.2), CGPoint(x: 1.8, y: 0.8)),
                    ("\u{259f}", CGPoint(x: 1.8, y: 0.8), CGPoint(x: 1.2, y: 0.2)),
                ]
                for theme in ["Glass Dark", "Glass"] {
                    let index = theme.withCString { Ubiquitty.Themes.indexForName($0) }
                    t.expect(shell.applyInspectedTheme(Int(index), to: surface), desc: "the Glass appearance applies")
                    var scene = "\u{1b}[2J\u{1b}[H\u{1b}[?25l"
                    for separator in separators {
                        scene += "\u{1b}[48;2;100;90;90m \u{1b}[38;2;100;90;90m\u{1b}[48;2;35;80;160m\(separator.glyph) \u{1b}[0m\r\n"
                    }
                    surface.feed(Data(scene.utf8))
                    for vibrant in [false, true] {
                        for tint in [0.0, 0.5, 1.0, 0.0] {
                            configureGlass("background_vibrancy = \(vibrant)\nbackground_opacity = \(tint)\n")
                            shell.refreshSessionAppearance()
                            drawFrame(t, of: surface)
                            let native = surface.nativeBackgroundPixelsForTesting()
                            guard let ordinary = surface.retainedGridPixelsForTesting(),
                                let origin = surface.lastFrameOriginForTesting,
                                let cell = surface.drawnCellSizeForTesting
                            else {
                                t.expect(false, desc: "Powerline pixels and grid geometry are readable")
                                return
                            }
                            let scale = surface.metalLayer.contentsScale
                            let frameWidth = Int(surface.metalLayer.drawableSize.width)
                            let width = cell.width * scale
                            let height = cell.height * scale
                            func pixel(_ data: Data, x: CGFloat, y: CGFloat) -> [UInt8] {
                                let column = Int(CGFloat(origin.x) + x * width)
                                let row = Int(CGFloat(origin.y) + y * height)
                                let offset = (row * frameWidth + column) * 4
                                guard offset >= 0, offset + 4 <= data.count else { return [] }
                                return Array(data[offset..<(offset + 4)])
                            }
                            func checkSeams(_ pixels: Data, plane: String) {
                                for row in separators.indices {
                                    let shape = separators[row]
                                    let inside = pixel(pixels, x: shape.inside.x, y: CGFloat(row) + shape.inside.y)
                                    let outside = pixel(pixels, x: shape.outside.x, y: CGFloat(row) + shape.outside.y)
                                    let left = pixel(pixels, x: 0.5, y: CGFloat(row) + 0.5)
                                    let right = pixel(pixels, x: 2.5, y: CGFloat(row) + 0.08)
                                    t.expect(
                                        inside.count == 4 && inside == left,
                                        desc:
                                            "\(theme) \(plane) separator \(row) joins its foreground block at opacity \(tint): \(inside) == \(left)"
                                    )
                                    t.expect(
                                        outside.count == 4 && outside == right,
                                        desc:
                                            "\(theme) \(plane) separator \(row) keeps the adjacent background at opacity \(tint): \(outside) == \(right)"
                                    )
                                }
                            }
                            checkSeams(ordinary, plane: "ordinary")
                            if vibrant && tint < 1 {
                                t.expect(native != nil, desc: "vibrant background pixels are available")
                                if let native { checkSeams(native, plane: "native") }
                            }
                            if tint == 1, let root = window.contentView?.superview,
                                let container = TabStripStyling.titlebarContainer(searchingFrom: root),
                                let painted = container.layer?.backgroundColor,
                                let color = NSColor(cgColor: painted)?.usingColorSpace(.sRGB),
                                let expected = shell.chromeBandColor()?.usingColorSpace(.sRGB)
                            {
                                t.expect(
                                    abs(color.redComponent - expected.redComponent) < 0.005
                                        && abs(color.greenComponent - expected.greenComponent) < 0.005
                                        && abs(color.blueComponent - expected.blueComponent) < 0.005
                                        && color.alphaComponent == 1,
                                    desc: "opaque Glass titlebar uses the terminal's theme background"
                                )
                            } else if tint == 1 {
                                t.expect(false, desc: "opaque Glass paints its titlebar instead of exposing native window color")
                            }
                        }
                    }
                }
            }
        }

        UBUITestRegister("native_glass_theme_routes_secondary_ink_and_restores_opaque") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The opacity, the blur, its text contrast and the background
                // vibrancy are left unset, so each reads as its default; the
                // steps below append to that.
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                let unglassed = documentDroppingKeys(
                    ["background_opacity", "blur_radius", "text_contrast_on_blur", "background_vibrancy"],
                    inSection: "appearance",
                    of: saved
                )
                @MainActor
                func configureGlass(_ lines: String) {
                    t.restoreConfiguration(unglassed + "\n[appearance]\n" + lines)
                }
                configureGlass("")
                defer { t.restoreConfiguration(saved) }
                SystemTheme.refresh()
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let surface = shell.focusedSurfaceForTesting, let window = shell.window
                else {
                    t.expect(false, desc: "a window opens for native glass")
                    return
                }
                defer {
                    TerminalWindowController.systemTransparencyOverrideForTesting = nil
                    window.close()
                }
                TerminalWindowController.systemTransparencyOverrideForTesting = .Allowed
                let glass = "Glass Dark".withCString { Ubiquitty.Themes.indexForName($0) }
                t.expect(glass >= 0, desc: "Glass Dark is offered without user configuration")
                t.expect(shell.applyInspectedTheme(Int(glass), to: surface), desc: "Glass Dark applies to the session")
                surface.feed(
                    Data(
                        "\u{1b}[2J\u{1b}[HPrimary  \u{1b}[38;2;130;130;130mSecondary  \u{1b}[38;2;70;70;70mTertiary\u{1b}[0m\r\n\u{1b}[36mSystem cyan \u{1b}[32mSystem green\u{1b}[0m\r\n\u{1b}[48;2;45;45;45m\u{1b}[38;2;100;100;100mAsk Codex to do anything\u{1b}[0m"
                            .utf8
                    )
                )
                drawFrame(t, of: surface)
                t.expect(surface.currentThemeName == "Glass Dark", desc: "equal system palettes retain their material identity")
                t.expect(!window.isOpaque && shell.isBlurBackdropShownForTesting, desc: "Glass shows a native material")
                t.expect(surface.drawnBackgroundForTesting()?.alpha == 0, desc: "Glass has no additional terminal tint")
                @MainActor
                func plane(in view: NSView) -> SecondaryTextPlane? {
                    if let ink = view as? SecondaryTextPlane { return ink }
                    return view.subviews.lazy.compactMap { plane(in: $0) }.first
                }
                if let root = window.contentView, let ink = plane(in: root) {
                    t.expect(ink.allowsVibrancy, desc: "the GPU ink participates in native vibrancy")
                    t.expect(ink.effectiveAppearance.allowsVibrancy, desc: "native ink has a vibrant appearance")
                    t.expect(ink.secondaryInk != ink.tertiaryInk, desc: "secondary and tertiary use distinct native semantic ink")
                    t.expect(
                        (surface.drawnForegroundAlphaForTesting(row: 0, column: 9) ?? 0) < 0,
                        desc: "secondary terminal text routes exclusively to the native plane"
                    )
                    t.expect(
                        (surface.drawnForegroundAlphaForTesting(row: 0, column: 20) ?? 0) < 0,
                        desc: "tertiary terminal text routes exclusively to the native plane"
                    )
                    t.expect(
                        (surface.drawnForegroundAlphaForTesting(row: 1, column: 0) ?? 0) < 0,
                        desc: "colored terminal text uses native blending with its RGB intact"
                    )
                    t.expect(
                        ink.metalLayer.contentsScale == surface.metalLayer.contentsScale,
                        desc: "native ink matches the terminal backing scale"
                    )
                    t.expect(
                        ink.metalLayer.drawableSize == surface.metalLayer.drawableSize,
                        desc: "native ink matches the terminal pixel dimensions"
                    )
                    t.expect(
                        (surface.drawnForegroundAlphaForTesting(row: 2, column: 0) ?? 0) < 0,
                        desc: "faint text remains vibrant over a shaded input field"
                    )
                    let originalDrawable = ink.metalLayer.drawableSize
                    for offset: CGFloat in [36, -24, 0] {
                        surface.applyVerticalOverscroll(offset)
                        t.expect(
                            ink.metalLayer.frame == surface.metalLayer.frame,
                            desc: "native ink follows bounce immediately without another rendered frame"
                        )
                    }
                    t.expect(ink.metalLayer.drawableSize == originalDrawable, desc: "bounce does not resample native ink")
                } else {
                    t.expect(false, desc: "the live rendered surface installs its native ink plane")
                }
                @MainActor
                func secureLock(in view: NSView) -> SecureKeyboardEntryLock? {
                    if let lock = view as? SecureKeyboardEntryLock { return lock }
                    return view.subviews.lazy.compactMap { secureLock(in: $0) }.first
                }
                if let root = window.contentView?.superview, let lock = secureLock(in: root) {
                    (lock.superview as? ChromeAccessoryBar)?.setShown(lock, true)
                    lock.wantsLayer = true
                    t.pump(0.2)
                    t.expect(lock.alphaValue == 1, desc: "native accessory ink is not faded twice")
                    t.expect(
                        lock.layer?.compositingFilter != nil,
                        desc: "the titlebar lock receives native vibrancy compositing"
                    )
                } else {
                    t.expect(false, desc: "the Glass titlebar includes its secure-entry accessory")
                }
                surface.feed(Data("\r\n\u{1b}]133;A\u{7}$ marked-command\r\n\u{1b}]133;C\u{7}output\r\n\u{1b}]133;D;0\u{7}".utf8))
                drawFrame(t, of: surface)
                if let root = window.contentView, let native = plane(in: root),
                    let ink = surface.nativeTerminalMarkInkForTesting()
                {
                    t.expect(
                        ink.x == native.tertiaryInk.x && ink.y == native.tertiaryInk.y
                            && ink.z == native.tertiaryInk.z && ink.w < 0,
                        desc: "Glass terminal marks use tertiary ink on the native plane"
                    )
                } else {
                    t.expect(false, desc: "an executed command emits a native terminal mark")
                }
                configureGlass("background_vibrancy = true\n")
                shell.refreshSessionAppearance()
                drawFrame(t, of: surface)
                @MainActor
                func planes(in view: NSView) -> [SecondaryTextPlane] {
                    if let ink = view as? SecondaryTextPlane { return [ink] }
                    return view.subviews.flatMap { planes(in: $0) }
                }
                if let root = window.contentView {
                    let nativePlanes = planes(in: root)
                    t.expect(nativePlanes.count == 2, desc: "background vibrancy has its own plane beneath ordinary ink")
                    for offset: CGFloat in [31, -19, 0] {
                        surface.applyVerticalOverscroll(offset)
                        t.expect(
                            nativePlanes.allSatisfy { $0.metalLayer.frame == surface.metalLayer.frame },
                            desc: "both native layers move with ordinary ink on each bounce event"
                        )
                    }
                }
                do {
                    let nativePixels = surface.nativeBackgroundPixelsForTesting()
                    t.expect(
                        nativePixels?.contains(where: { $0 != 0 }) == true,
                        desc: "shaded input backgrounds reach the native GPU target"
                    )
                    surface.feed(Data("\u{1b}[2;1H\u{1b}[48;2;30;70;150mBlue background\u{1b}[0m".utf8))
                    surface.needsDisplay = true
                    t.pump(0.3)
                    let partial = surface.nativeBackgroundPixelsForTesting()
                    t.expect(partial != nativePixels, desc: "partial damage updates the native background")
                    drawFrame(t, of: surface)
                    t.expect(
                        surface.nativeBackgroundPixelsForTesting() == partial,
                        desc: "retained native backgrounds match a complete repaint"
                    )
                    surface.feed(Data("\u{1b}[1S".utf8))
                    surface.needsDisplay = true
                    t.pump(0.3)
                    let scrolled = surface.nativeBackgroundPixelsForTesting()
                    drawFrame(t, of: surface)
                    let repainted = surface.nativeBackgroundPixelsForTesting()
                    t.expect(
                        repainted == scrolled,
                        desc: "scrolling shifts native backgrounds with the grid"
                    )
                    configureGlass("background_vibrancy = true\nbackground_opacity = 0.5\n")
                    shell.refreshSessionAppearance()
                    drawFrame(t, of: surface)
                    let tinted = surface.nativeBackgroundPixelsForTesting()
                    t.expect(
                        tinted != nil && tinted == repainted,
                        desc: "native background contribution stays continuous as ordinary tint opacity increases"
                    )
                    t.expect(
                        surface.drawnBackgroundForTesting()?.alpha == 0.5,
                        desc: "ordinary tint still overlays the blurred material"
                    )
                    configureGlass("background_vibrancy = true\n")
                    shell.refreshSessionAppearance()
                    drawFrame(t, of: surface)
                }
                configureGlass("background_vibrancy = false\n")
                shell.refreshSessionAppearance()
                drawFrame(t, of: surface)
                if let root = window.contentView {
                    t.expect(planes(in: root).count == 1, desc: "background vibrancy turns off independently of text")
                }
                TerminalWindowController.systemTransparencyOverrideForTesting = .Reduced
                shell.refreshSessionAppearance()
                drawFrame(t, of: surface)
                t.expect(window.isOpaque && !shell.isBlurBackdropShownForTesting, desc: "Reduce Transparency overrides theme glass")
                if let root = window.contentView {
                    t.expect(plane(in: root) == nil, desc: "turning native text off removes its compositor layer")
                }
            }
        }

        UBUITestRegister("blur_text_vibrancy_routes_native_ink_and_restores_ordinary") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else { return }
                let savedOpacity = settingDouble(.AppearanceBackgroundOpacity)
                let savedRadius = settingDouble(.AppearanceBlurRadius)
                let savedContrast = settingBool(.AppearanceTextContrastOnBlur)
                defer {
                    TerminalWindowController.systemTransparencyOverrideForTesting = nil
                    app.settingsSetTextContrastOnBlur(savedContrast)
                    app.settingsSetBlurRadius(savedRadius)
                    app.settingsSetBackgroundOpacity(savedOpacity)
                }
                TerminalWindowController.systemTransparencyOverrideForTesting = .Allowed
                app.settingsSetBackgroundOpacity(0.5)
                app.settingsSetBlurRadius(20)
                app.settingsSetTextContrastOnBlur(false)
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ), let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a terminal opens for the vibrancy check")
                    return
                }
                defer { shell.window?.close() }
                surface.feed(Data("\u{1b}[?25l\u{1b}[2J\u{1b}[H\u{1b}[38;2;70;70;70mLow contrast text".utf8))
                drawFrame(t, of: surface)
                t.expect(
                    (surface.drawnForegroundAlphaForTesting(row: 0, column: 0) ?? 0) > 0,
                    desc: "text uses ordinary ink with vibrancy disabled"
                )
                guard let original = surface.renderedFrameForTesting() else {
                    t.expect(false, desc: "the original frame renders")
                    return
                }
                let text = surface.gridTextForTesting()
                app.settingsSetTextContrastOnBlur(true)
                drawFrame(t, of: surface)
                t.expect(
                    (surface.drawnForegroundAlphaForTesting(row: 0, column: 0) ?? 0) < 0,
                    desc: "enabling vibrancy routes text exclusively to the native plane"
                )
                t.expect(text == surface.gridTextForTesting(), desc: "vibrancy preserves the terminal model")
                app.settingsSetTextContrastOnBlur(false)
                drawFrame(t, of: surface)
                t.expect(
                    (surface.drawnForegroundAlphaForTesting(row: 0, column: 0) ?? 0) > 0,
                    desc: "disabling vibrancy restores ordinary ink"
                )
                t.expect(
                    surface.renderedFrameForTesting()?.pixels == original.pixels,
                    desc: "disabling vibrancy restores the exact original frame"
                )
            }
        }

        UBUITestRegister("swift_shell_an_opaque_window_draws_its_frame_opaque") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let savedOpacity = settingDouble(.AppearanceBackgroundOpacity)
                let savedRadius = settingDouble(.AppearanceBlurRadius)
                defer {
                    TerminalWindowController.systemTransparencyOverrideForTesting = nil
                    app.settingsSetBlurRadius(savedRadius)
                    app.settingsSetBackgroundOpacity(savedOpacity)
                }

                // Reduce Transparency on, and a half-opaque ground asked for:
                // the window is opaque, so the frame must be drawn opaque too.
                TerminalWindowController.systemTransparencyOverrideForTesting = .Reduced
                app.settingsSetBlurRadius(0)
                app.settingsSetBackgroundOpacity(0.5)
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.5)
                drawFrame(t, of: surface)
                t.expect(window.isOpaque, desc: "under Reduce Transparency the window is opaque")
                t.expect(surface.metalLayer.isOpaque, desc: "and so is the surface's layer")
                guard let reduced = surface.drawnBackgroundForTesting() else {
                    t.expect(false, desc: "the frame reports the background it was drawn with")
                    return
                }
                t.expect(reduced.alpha == 1, desc: "the frame's background alpha is one on an opaque window (drawn \(reduced.alpha))")

                // The switch off, the same ground: the window turns
                // translucent and the frame carries the asked alpha, with the
                // colour unchanged — the darkening the opaque case avoids is a
                // colour change, not an alpha change.
                TerminalWindowController.systemTransparencyOverrideForTesting = .Allowed
                app.settingsSetBackgroundOpacity(0.5)
                t.pump(0.2)
                drawFrame(t, of: surface)
                t.expect(!window.isOpaque, desc: "with transparency allowed the window is translucent")
                guard let allowed = surface.drawnBackgroundForTesting() else {
                    t.expect(false, desc: "the frame reports the background it was drawn with, again")
                    return
                }
                t.expect(abs(allowed.alpha - 0.5) < 0.001, desc: "the frame's background alpha is the asked half (drawn \(allowed.alpha))")
                t.expect(
                    allowed.color.x == reduced.color.x && allowed.color.y == reduced.color.y && allowed.color.z == reduced.color.z,
                    desc:
                        "the background colour is the theme's in both cases (\(reduced.color.x),\(reduced.color.y),\(reduced.color.z) vs \(allowed.color.x),\(allowed.color.y),\(allowed.color.z))"
                )

                // Back to Reduce Transparency on the live window: the frame goes
                // opaque again without a reopen.
                TerminalWindowController.systemTransparencyOverrideForTesting = .Reduced
                app.settingsSetBackgroundOpacity(0.5)
                t.pump(0.2)
                drawFrame(t, of: surface)
                let again = surface.drawnBackgroundForTesting()
                t.expect(
                    again?.alpha == 1,
                    desc:
                        "the switch flipping on the live window draws the frame opaque again (drawn \(again.map { String($0.alpha) } ?? "nothing"))"
                )
            }
        }

        UBUITestRegister("swift_shell_the_blur_radius_reaches_the_window_server_through_one_helper") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let savedOpacity = settingDouble(.AppearanceBackgroundOpacity)
                let savedRadius = settingDouble(.AppearanceBlurRadius)
                defer {
                    TerminalWindowController.systemTransparencyOverrideForTesting = nil
                    app.settingsSetBlurRadius(savedRadius)
                    app.settingsSetBackgroundOpacity(savedOpacity)
                }
                TerminalWindowController.systemTransparencyOverrideForTesting = .Allowed
                app.settingsSetBackgroundOpacity(0.8)
                app.settingsSetBlurRadius(20)
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window
                else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.5)
                // The window has a number once ordered in; the radius is asked
                // for on the apply that finds one.
                app.settingsSetBlurRadius(20)
                t.pump(0.2)
                t.expect(shell.isBlurBackdropShownForTesting, desc: "a radius over a translucent window shows the backdrop")
                t.expect(
                    shell.lastRequestedBlurRadiusForTesting == 20,
                    desc:
                        "and asks the window server for the radius (asked \(shell.lastRequestedBlurRadiusForTesting.map { String($0) } ?? "nothing"))"
                )

                app.settingsSetBlurRadius(35)
                t.pump(0.2)
                t.expect(
                    shell.lastRequestedBlurRadiusForTesting == 35,
                    desc:
                        "moving the setting moves the radius asked for (asked \(shell.lastRequestedBlurRadiusForTesting.map { String($0) } ?? "nothing"))"
                )

                // Reduce Transparency flattens it: no backdrop, radius zero.
                TerminalWindowController.systemTransparencyOverrideForTesting = .Reduced
                app.settingsSetBlurRadius(35)
                t.pump(0.2)
                t.expect(!shell.isBlurBackdropShownForTesting, desc: "under Reduce Transparency the backdrop is hidden")
                t.expect(
                    shell.lastRequestedBlurRadiusForTesting == 0,
                    desc: "and the window server's radius is taken back to zero"
                )

                // And the radius off: the same, with transparency allowed.
                TerminalWindowController.systemTransparencyOverrideForTesting = .Allowed
                app.settingsSetBlurRadius(0)
                t.pump(0.2)
                t.expect(!shell.isBlurBackdropShownForTesting, desc: "a zero radius hides the backdrop")
                t.expect(shell.lastRequestedBlurRadiusForTesting == 0, desc: "and asks for none")
            }
        }

        UBUITestRegister("swift_shell_a_window_asks_again_for_its_blur_when_rehosted") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let savedOpacity = settingDouble(.AppearanceBackgroundOpacity)
                let savedRadius = settingDouble(.AppearanceBlurRadius)
                defer {
                    TerminalWindowController.systemTransparencyOverrideForTesting = nil
                    app.settingsSetBlurRadius(savedRadius)
                    app.settingsSetBackgroundOpacity(savedOpacity)
                }
                TerminalWindowController.systemTransparencyOverrideForTesting = .Allowed
                app.settingsSetBackgroundOpacity(0.8)
                app.settingsSetBlurRadius(20)
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window
                else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                t.expect(
                    shell.lastRequestedBlurRadiusForTesting == 20,
                    desc: "a window opened under a radius asks for it with nothing moved"
                )

                // Each edge on which AppKit re-hosts the window asks again. The
                // radius cannot be read back from the window server, so the ask
                // is forgotten first and the edge must make it anew. Called as
                // AppKit calls them: an accessory application's window cannot
                // be made main by the harness.
                shell.forgetRequestedBlurRadiusForTesting()
                shell.showWindow(nil)
                t.expect(shell.lastRequestedBlurRadiusForTesting == 20, desc: "ordering the window in asks for the radius again")

                shell.forgetRequestedBlurRadiusForTesting()
                shell.windowDidBecomeMain(Notification(name: NSWindow.didBecomeMainNotification, object: window))
                t.expect(
                    shell.lastRequestedBlurRadiusForTesting == 20,
                    desc: "becoming main, as a tab re-hosted by an attach or a detach does, asks again"
                )

                shell.forgetRequestedBlurRadiusForTesting()
                shell.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
                t.expect(shell.lastRequestedBlurRadiusForTesting == 20, desc: "leaving full screen asks again")

                // What is asked again is what the window wants now: with the
                // radius off, the edge takes it back to zero rather than
                // restoring a radius the reader turned off.
                app.settingsSetBlurRadius(0)
                t.pump(0.2)
                shell.forgetRequestedBlurRadiusForTesting()
                shell.windowDidBecomeMain(Notification(name: NSWindow.didBecomeMainNotification, object: window))
                t.expect(shell.lastRequestedBlurRadiusForTesting == 0, desc: "with the radius off, the edge asks for none")
            }
        }
    }
}
