// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
internal import UbiquittyCore

// One theme snapshot read out of the live registry: 16 ANSI + foreground/background/cursor
// as packed 0xRRGGBBAA, plus name / darkness / built-in flag.
package struct ThemeSnapshot: Identifiable {
    package let id: Int // registry index
    package var name: String
    package var isDark: Bool
    package var isBuiltIn: Bool
    package var ansi: [UInt32] // 16
    package var foreground: UInt32
    package var background: UInt32
    package var cursor: UInt32

    /// Whether the frontend refreshes this palette when macOS appearance changes.
    package var usesSystemAppearance: Bool {
        Ubiquitty.Themes.get(Int32(id))?.pointee.usesSystemAppearance ?? false
    }

    package init(
        id: Int,
        name: String,
        isDark: Bool,
        isBuiltIn: Bool,
        ansi: [UInt32],
        foreground: UInt32,
        background: UInt32,
        cursor: UInt32
    ) {
        self.id = id
        self.name = name
        self.isDark = isDark
        self.isBuiltIn = isBuiltIn
        self.ansi = ansi
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
    }

    package static func load(_ index: Int, name: String, builtInCount: Int) -> ThemeSnapshot {
        let theme = Ubiquitty.Themes.get(Int32(index))
        var ansi = [UInt32](repeating: 0, count: 16)
        for slot in 0..<16 {
            ansi[slot] = theme?.pointee.packedColor(Int32(slot)) ?? 0
        }
        return ThemeSnapshot(
            id: index,
            name: name,
            isDark: theme != nil && Ubiquitty.Themes.isDark(Int32(index)),
            isBuiltIn: index < builtInCount,
            ansi: ansi,
            foreground: theme?.pointee.packedColor(16) ?? 0,
            background: theme?.pointee.packedColor(17) ?? 0,
            cursor: theme?.pointee.packedColor(18) ?? 0
        )
    }
}

// Packed-color <-> SwiftUI Color helpers, sRGB throughout (matches the
// theme TOML + the renderer's sRGB decode).
package enum ColorPack {
    package static func color(_ rgba: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((rgba >> 24) & 0xFF) / 255.0,
            green: Double((rgba >> 16) & 0xFF) / 255.0,
            blue: Double((rgba >> 8) & 0xFF) / 255.0,
            opacity: Double(rgba & 0xFF) / 255.0
        )
    }

    package static func pack(_ color: Color) -> UInt32 {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = UInt32((ns.redComponent * 255).rounded().clamped(0, 255))
        let g = UInt32((ns.greenComponent * 255).rounded().clamped(0, 255))
        let b = UInt32((ns.blueComponent * 255).rounded().clamped(0, 255))
        let a = UInt32((ns.alphaComponent * 255).rounded().clamped(0, 255))
        return (r << 24) | (g << 16) | (b << 8) | a
    }
}

extension Double {
    fileprivate func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}

/// Renders readable sample output using a theme's actual terminal colors.
package struct ThemeTerminalPreview: View {
    let theme: ThemeSnapshot

    package init(theme: ThemeSnapshot) { self.theme = theme }

    package var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3) { _ in Circle().fill(ColorPack.color(theme.foreground).opacity(0.3)).frame(width: 5, height: 5) }
                Spacer()
            }
            Text("\(Text("~ ").foregroundColor(ColorPack.color(theme.ansi[4])))$ ls")
                .foregroundStyle(ColorPack.color(theme.foreground))
            Text("\(Text("Documents  ").foregroundColor(ColorPack.color(theme.ansi[4])))notes.txt")
                .foregroundStyle(ColorPack.color(theme.foreground))
            Text("\(Text("✓ ").foregroundColor(ColorPack.color(theme.ansi[2])))Ready")
                .foregroundStyle(ColorPack.color(theme.foreground))
            HStack(spacing: 0) {
                Text("$ ")
                Rectangle().fill(ColorPack.color(theme.cursor)).frame(width: 6, height: 11)
            }
            .foregroundStyle(ColorPack.color(theme.foreground))
        }
        .font(.system(size: 10, design: .monospaced))
        .lineLimit(1)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorPack.color(theme.background))
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

/// Presents a palette sample and a persistent selection indicator as one keyboard-accessible choice.
package struct ThemeChoice: View {
    let theme: ThemeSnapshot
    let isSelected: Bool
    let action: () -> Void

    package init(theme: ThemeSnapshot, isSelected: Bool, action: @escaping () -> Void) {
        self.theme = theme
        self.isSelected = isSelected
        self.action = action
    }

    package var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ThemeTerminalPreview(theme: theme)
                    .modifier(SettingsChoiceFrame(isSelected: isSelected))
                HStack {
                    Text(theme.name).lineLimit(1)
                    Spacer(minLength: 0)
                    if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityValue(isSelected ? "Selected" : "")
        .help(theme.name)
    }
}
/// Separates a visual choice from its flat group and marks the selected option.
package struct SettingsChoiceFrame: ViewModifier {
    let isSelected: Bool
    @Environment(\.colorSchemeContrast)
    private var contrast

    package init(isSelected: Bool) { self.isSelected = isSelected }

    package func body(content: Content) -> some View {
        content
            .clipShape(.rect(cornerRadius: 8))
            .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
            .padding(3)
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(
                        isSelected ? Color.accentColor : .primary.opacity(contrast == .increased ? 0.5 : 0),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
    }
}
