// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// BackgroundImageSettingsScenarios — the Settings › Appearance Background Image
// card writes Core's three keys, every open terminal window installs the
// result, and the card itself renders in light and dark appearance in every
// state it can show.

import AppKit
import SwiftUI
import UbiquittyAppBridge
import UbiquittyKit

enum BackgroundImageSettingsScenarios {
    static func register() {
        UBUITestRegister("settings_background_image_reaches_open_windows") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ubq-background-image-\(ProcessInfo.processInfo.processIdentifier)")
                defer {
                    t.restoreConfiguration(saved)
                    try? FileManager.default.removeItem(at: directory)
                }
                guard let image = writeLandscape(to: directory, width: 640, height: 400) else {
                    t.expect(false, desc: "a test picture can be written")
                    return
                }
                t.configureAppending("[appearance]\nbackground_image = \"\"\nbackground_opacity = 0.8\n")

                guard let shell = t.newWindowRunning(["/bin/sh", "-c", "exec sleep 1000"]), let window = shell.window else {
                    t.expect(false, desc: "a terminal opens for the background image")
                    return
                }
                defer { window.close() }
                window.setContentSize(NSSize(width: 480, height: 300))

                let controller = SettingsWindowController()
                defer { controller.close() }
                controller.window?.setContentSize(NSSize(width: 720, height: 460))
                controller.showWindow(nil)
                controller.select(category: "appearance")
                t.expect(t.wait(until: { controller.window?.title == "Appearance" }, timeout: 4), desc: "Settings opens Appearance")

                let categories = SettingsCatalog.categories()
                let hits = categories.settingsSearchHits()
                for query in ["Background Image", "Wallpaper", "wallpaper"] {
                    t.expect(
                        hits.contains { $0.rowID == "appearance.background_image" && $0.categoryID == "appearance" && $0.matches(query) },
                        desc: "search for \(query) finds the background image"
                    )
                }
                t.expect(
                    hits.contains { $0.rowID == "appearance.background_image_mode" && $0.matches("Wallpaper") },
                    desc: "search for Wallpaper finds the placement mode"
                )

                guard case .pane(let pane) = categories.first(where: { $0.id == "appearance" })?.content,
                    let card = pane.cards.first(where: { $0.title == "Background Image" }),
                    let imageRow = card.rows.first(where: { $0.id == "appearance.background_image" }),
                    case .backgroundImage(let getPath, let setPath) = imageRow.control,
                    let modeRow = card.rows.first(where: { $0.id == "appearance.background_image_mode" }),
                    case .menu(let modeOptions, _, let getMode, let setMode) = modeRow.control,
                    let opacityRow = card.rows.first(where: { $0.id == "appearance.background_image_opacity" }),
                    case .slider(let minimum, let maximum, _, let getOpacity, let setOpacity) = opacityRow.control
                else {
                    t.expect(false, desc: "Appearance carries the Background Image card with its three rows")
                    return
                }
                t.expect(
                    pane.cards.firstIndex(where: { $0.title == "Background" }).map { $0 + 1 }
                        == pane.cards.firstIndex(where: { $0.title == "Background Image" }),
                    desc: "the Background Image card follows the Background card"
                )
                t.expect(minimum == 0 && maximum == 1, desc: "the opacity slider reads the schema's 0–1")
                t.expect(modeOptions == ["Fill", "Fit", "Stretch", "Tile", "Center"], desc: "the mode menu offers Core's vocabulary")
                t.expect(
                    modeRow.isEnabled?() == false && opacityRow.isEnabled?() == false,
                    desc: "Mode and Opacity are disabled while no image is set"
                )

                setPath(image.path)
                setMode(SettingsCatalog.terms("appearance", "background_image_mode").firstIndex(of: "tile") ?? -1)
                setOpacity(0.4)
                t.expect(getPath() == image.path, desc: "the chosen path is stored as a plain path")
                t.expect(settingText(.AppearanceBackgroundImageMode) == "tile", desc: "the mode token reaches Core")
                t.expect(getMode() == 3, desc: "the menu reads Tile back")
                t.expect(abs(getOpacity() - 0.4) < 1e-9, desc: "the opacity reaches Core")
                t.expect(
                    modeRow.isEnabled?() == true && opacityRow.isEnabled?() == true,
                    desc: "Mode and Opacity enable once an image is set"
                )
                t.expect(
                    modeRow.currentDetail?() == BackgroundImageSettings.modeDescription(.Tile),
                    desc: "the mode's detail describes Tile"
                )

                let installed = t.wait(
                    until: {
                        let backdrop = shell.backdropImageForTesting
                        return backdrop.path == image.path && backdrop.pixelWidth == 640 && backdrop.mode == 3
                            && abs(backdrop.opacity - 0.4) < 1e-6
                    },
                    timeout: 3
                )
                let backdrop = shell.backdropImageForTesting
                t.expect(
                    installed,
                    desc:
                        "the open window installs the image (path \(backdrop.path), width \(backdrop.pixelWidth), mode \(backdrop.mode), opacity \(backdrop.opacity))"
                )

                setOpacity(1.7)
                t.expect(getOpacity() == 1, desc: "an out-of-range opacity is clamped by the schema")

                let model = BackgroundImagePreviewModel()
                model.load(image.path)
                t.expect(
                    t.wait(
                        until: {
                            if case .picture(let picture) = model.outcome { return picture.pixelWidth == 640 }
                            return false
                        },
                        timeout: 3
                    ),
                    desc: "the preview decodes the chosen picture at its own pixel size"
                )
                let missing = directory.appendingPathComponent("moved-away.png").path
                setPath(missing)
                model.load(missing)
                t.expect(
                    t.wait(
                        until: {
                            if case .missing = model.outcome { return true }
                            return false
                        },
                        timeout: 3
                    ),
                    desc: "a path that no longer resolves reads as missing"
                )
                t.expect(getPath() == missing, desc: "a missing file keeps the setting")

                setPath("")
                t.expect(settingText(.AppearanceBackgroundImage).isEmpty, desc: "Remove clears the image")
                t.expect(
                    t.wait(until: { shell.backdropImageForTesting.pixelWidth == 0 }, timeout: 3),
                    desc: "the open window takes the image down"
                )
                t.expect(modeRow.isEnabled?() == false, desc: "Mode disables again once the image is removed")
            }
        }

        UBUITestRegister("settings_background_image_card_renders") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ubq-background-render-\(ProcessInfo.processInfo.processIdentifier)")
                SystemDisplayOptions.pinForTesting(reduceMotion: false, reduceTransparency: false)
                defer {
                    SystemDisplayOptions.unpinForTesting()
                    t.restoreConfiguration(saved)
                    try? FileManager.default.removeItem(at: directory)
                }
                let output = ProcessInfo.processInfo.environment["UBQ_SETTINGS_RENDER_DIR"].map(URL.init(fileURLWithPath:))
                if let output { try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
                let picture =
                    ProcessInfo.processInfo.environment["UBQ_SETTINGS_RENDER_IMAGE"].map(URL.init(fileURLWithPath:))
                    ?? writeLandscape(to: directory, width: 2400, height: 1600)
                guard let picture, let pattern = writePattern(to: directory) else {
                    t.expect(false, desc: "test pictures can be written")
                    return
                }
                BackgroundImagePreviewModel.prime(picture.path)
                BackgroundImagePreviewModel.prime(pattern.path)

                struct Case {
                    let name: String
                    let toml: String
                }
                let modes = ["fill", "fit", "stretch", "tile", "center"]
                var cases = [Case(name: "empty", toml: "background_image = \"\"\nbackground_opacity = 0.8\n")]
                for mode in modes {
                    cases.append(
                        Case(
                            name: "mode-\(mode)",
                            toml: "background_image = \(tomlLiteral(picture.path))\nbackground_image_mode = \"\(mode)\"\n"
                                + "background_image_opacity = 1.0\nbackground_opacity = 0.8\n"
                        )
                    )
                }
                cases.append(
                    Case(
                        name: "tile-pattern",
                        toml: "background_image = \(tomlLiteral(pattern.path))\nbackground_image_mode = \"tile\"\n"
                            + "background_image_opacity = 0.6\nbackground_opacity = 0.7\n"
                    )
                )
                cases.append(
                    Case(
                        name: "opaque-background",
                        toml:
                            "background_image = \(tomlLiteral(picture.path))\nbackground_image_mode = \"fill\"\nbackground_opacity = 1.0\n"
                    )
                )
                cases.append(
                    Case(
                        name: "missing",
                        toml: "background_image = \(tomlLiteral(directory.appendingPathComponent("Moved Away.heic").path))\n"
                            + "background_opacity = 0.8\n"
                    )
                )

                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    for item in cases {
                        t.restoreConfiguration(saved)
                        t.configureAppending("[appearance]\n" + item.toml)
                        guard
                            case .pane(let pane) = SettingsCatalog.categories().first(where: { $0.id == "appearance" })?.content,
                            let card = pane.cards.first(where: { $0.title == "Background Image" })
                        else {
                            t.expect(false, desc: "the card exists")
                            return
                        }
                        let name = (appearance == .darkAqua ? "dark" : "light") + "-" + item.name
                        guard let bitmap = render(PaneView(pane: SettingsPane(cards: [card]), pulseTarget: nil), appearance: appearance, t)
                        else {
                            t.expect(false, desc: "\(name) renders")
                            continue
                        }
                        t.expect(
                            bitmap.pixelsWide >= 1300 && bitmap.pixelsHigh > 600,
                            desc: "\(name) renders at 2x (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh))"
                        )
                        if let output, let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: output.appendingPathComponent("background-image-\(name).png"))
                        }
                    }
                }
            }
        }
    }

    /// Hosts `view` in an off-screen window under `appearance`, at the
    /// content width of a settings page, and draws it at 2x.
    @MainActor
    private static func render(_ view: some View, appearance: NSAppearance.Name, _ t: UBUITestContext) -> NSBitmapImageRep? {
        let width = SettingsStyle.contentWidth
        let hosting = NSHostingView(
            rootView:
                view
                .frame(width: width)
                .background(Color(nsColor: .controlBackgroundColor))
        )
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: width, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        defer { window.close() }
        t.pump(0.2)
        let fitting = hosting.fittingSize
        window.setContentSize(NSSize(width: width, height: fitting.height))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: fitting.height))
        hosting.layoutSubtreeIfNeeded()
        // The decode is primed, so the preview's first refresh hits the cache;
        // the pump lets onAppear run and the view settle.
        t.pump(0.4)
        let pixelsWide = Int(width * 2)
        let pixelsHigh = Int(fitting.height * 2)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return nil }
        bitmap.size = hosting.bounds.size
        var drawn = false
        NSAppearance(named: appearance)?
            .performAsCurrentDrawingAppearance {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                drawn = true
            }
        return drawn ? bitmap : nil
    }

    private static func tomlLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Writes a dusk landscape — sky gradient, sun, three ridges — as a PNG.
    @MainActor
    private static func writeLandscape(to directory: URL, width: Int, height: Int) -> URL? {
        draw(to: directory.appendingPathComponent("Dusk.png"), width: width, height: height) { context, w, h in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let sky = CGGradient(
                colorsSpace: space,
                colors: [
                    CGColor(srgbRed: 0.98, green: 0.72, blue: 0.47, alpha: 1),
                    CGColor(srgbRed: 0.85, green: 0.45, blue: 0.55, alpha: 1),
                    CGColor(srgbRed: 0.27, green: 0.22, blue: 0.48, alpha: 1),
                ] as CFArray,
                locations: [0, 0.45, 1]
            )!
            // CoreGraphics' origin is bottom-left: the warm horizon is low.
            context.drawLinearGradient(
                sky,
                start: CGPoint(x: 0, y: h * 0.3),
                end: CGPoint(x: 0, y: h),
                options: [.drawsAfterEndLocation, .drawsBeforeStartLocation]
            )
            context.setFillColor(CGColor(srgbRed: 1, green: 0.9, blue: 0.7, alpha: 0.95))
            context.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.38, width: w * 0.12, height: w * 0.12))
            let ridges: [(CGFloat, CGFloat, CGColor)] = [
                (0.42, 0.09, CGColor(srgbRed: 0.42, green: 0.27, blue: 0.45, alpha: 1)),
                (0.30, 0.07, CGColor(srgbRed: 0.27, green: 0.18, blue: 0.36, alpha: 1)),
                (0.17, 0.05, CGColor(srgbRed: 0.14, green: 0.10, blue: 0.22, alpha: 1)),
            ]
            for (index, ridge) in ridges.enumerated() {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: 0))
                let steps = 48
                for step in 0...steps {
                    let x = w * CGFloat(step) / CGFloat(steps)
                    let phase = CGFloat(step) / CGFloat(steps) * .pi * CGFloat(2 + index)
                    let y = h * ridge.0 + h * ridge.1 * (sin(phase + CGFloat(index)) + 0.5 * sin(phase * 2.3))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: w, y: 0))
                path.closeSubpath()
                context.addPath(path)
                context.setFillColor(ridge.2)
                context.fillPath()
            }
        }
    }

    /// Writes a small two-tone motif that shows tiling plainly.
    @MainActor
    private static func writePattern(to directory: URL) -> URL? {
        draw(to: directory.appendingPathComponent("Motif.png"), width: 120, height: 120) { context, w, h in
            context.setFillColor(CGColor(srgbRed: 0.16, green: 0.42, blue: 0.55, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.setFillColor(CGColor(srgbRed: 0.93, green: 0.76, blue: 0.40, alpha: 1))
            context.fillEllipse(in: CGRect(x: w * 0.3, y: h * 0.3, width: w * 0.4, height: h * 0.4))
            context.setFillColor(CGColor(srgbRed: 0.10, green: 0.30, blue: 0.42, alpha: 1))
            for corner in [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: 0, y: h), CGPoint(x: w, y: h)] {
                context.fillEllipse(in: CGRect(x: corner.x - w * 0.15, y: corner.y - h * 0.15, width: w * 0.3, height: h * 0.3))
            }
        }
    }

    @MainActor
    private static func draw(to url: URL, width: Int, height: Int, _ paint: (CGContext, CGFloat, CGFloat) -> Void) -> URL? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        paint(context, CGFloat(width), CGFloat(height))
        guard let image = context.makeImage(),
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
            (try? data.write(to: url)) != nil
        else { return nil }
        return url
    }
}
