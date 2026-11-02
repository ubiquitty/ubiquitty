// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
internal import UbiquittyCore

/// Ink for the titlebar's own text and chevron.
///
/// Public because the kit bakes tab titles with it (`TabTitleStyling`) and the
/// app's Objective-C shell reaches it through the kit's generated header.
extension NSColor {
    /// Builds a colour from one of Core's packed 0xRRGGBB sRGB triples.
    ///
    /// - Parameters:
    ///   - packedRGB: The triple, red in the high byte.
    ///   - alpha: The opacity to paint it at.
    convenience init(packedRGB: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            srgbRed: CGFloat((packedRGB >> 16) & 0xFF) / 255.0,
            green: CGFloat((packedRGB >> 8) & 0xFF) / 255.0,
            blue: CGFloat(packedRGB & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

@objc(TitlebarInk)
@MainActor
public final class TitlebarInk: NSObject {
    /// The system label colour at an opacity, still resolving per appearance.
    ///
    /// `colorWithAlphaComponent` answers a catalog colour by resolving it
    /// against whatever appearance is current at the call and freezing the
    /// result, so a titlebar inked that way keeps the appearance it was born
    /// in: ink computed under one and drawn under the other is the colour of
    /// the row it sits on. Applying the opacity inside a dynamic provider
    /// keeps the resolution where it belongs — at draw time, under the
    /// appearance actually being drawn.
    ///
    /// - Parameter alpha: The opacity to wear.
    /// - Returns: A colour that answers differently in each appearance.
    @objc(labelWithAlpha:)
    public static func label(alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor.labelColor.withAlphaComponent(alpha)
            }
            return resolved
        }
    }
}

/// Resolves the System terminal palette from the active macOS appearance.
@objc(UBSystemTheme)
@MainActor
public final class SystemTheme: NSObject {
    @objc
    public static func refresh() {
        register(name: "System", appearance: NSApp.effectiveAppearance, glass: false)
        register(name: "Glass", appearance: NSAppearance(named: .aqua)!, glass: true)
        register(name: "Glass Dark", appearance: NSAppearance(named: .darkAqua)!, glass: true)
    }

    private static func register(name: String, appearance: NSAppearance, glass: Bool) {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var theme = Ubiquitty.Themes.Theme()
        theme.isDark = isDark
        theme.appearance.usesSystemColors = true
        theme.usesSystemAppearance = !glass
        if glass { theme.appearance.useGlass() }
        appearance.performAsCurrentDrawingAppearance {
            let background = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .black
            let colors: [NSColor] = [
                isDark ? .textBackgroundColor : .labelColor,
                .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemCyan,
                isDark ? .labelColor : .textBackgroundColor,
                .secondaryLabelColor,
                .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemCyan,
                isDark ? .white : .textBackgroundColor,
                .labelColor, .textBackgroundColor, glass ? .white : .controlAccentColor,
            ]
            for (slot, semantic) in colors.enumerated() {
                guard let color = semantic.usingColorSpace(.sRGB) else { continue }
                let alpha = color.alphaComponent
                func channel(_ value: CGFloat, _ ground: CGFloat) -> UInt8 {
                    UInt8(clamping: Int(((value * alpha + ground * (1 - alpha)) * 255).rounded()))
                }
                theme.setColor(
                    Int32(slot),
                    Ubiquitty.ColorRGBA(
                        red: channel(color.redComponent, background.redComponent),
                        green: channel(color.greenComponent, background.greenComponent),
                        blue: channel(color.blueComponent, background.blueComponent),
                        alpha: 255
                    )
                )
            }
        }
        if isDark && !glass {
            let colors: [UInt32] = [
                0x353535, 0xFF8D7A, 0x00D9B2, 0xECA800,
                0x89BBFF, 0xD896FE, 0x00CAFA, 0xF9F1F3,
                0x9A9A9A, 0xFF8D7A, 0x00D9B2, 0xECA800,
                0x89BBFF, 0xD896FE, 0x00CAFA, 0xF9F1F3,
                0xF9F1F3, 0x252525, 0x007AFF,
            ]
            for (slot, color) in colors.enumerated() {
                theme.setColor(
                    Int32(slot),
                    Ubiquitty.ColorRGBA(
                        red: UInt8((color >> 16) & 0xFF),
                        green: UInt8((color >> 8) & 0xFF),
                        blue: UInt8(color & 0xFF),
                        alpha: 255
                    )
                )
            }
        }
        name.withCString { name in
            theme.name = name
            let existing = Ubiquitty.Themes.indexForName(name)
            if existing >= Ubiquitty.Themes.builtInCount() {
                _ = Ubiquitty.Themes.replaceCustom(existing, theme)
            } else {
                _ = Ubiquitty.Themes.registerCustom(theme)
            }
        }
    }
}
