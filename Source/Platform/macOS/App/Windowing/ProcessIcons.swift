// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
internal import CxxStdlib
internal import UbiquittyCore
internal import UbiquittyRenderKit

// ProcessIcons.swift — programs' icons a title draws before their names.
//
// Core's catalog (Title/ProcessIconCatalog.h) says which program a pane runs, which
// file its icon is in, how it is painted and when it needs a plate; this reads
// the file from the shipped resources' process-icons/ once and draws it at a
// title's size. A template icon takes the title's ink, so it reads on any theme like
// the words beside it; a drawn icon keeps its owner's colours, on a plate in
// the title's ink when Core finds them too close to the ground.

/// A program's icon in a title, saying which program it draws.
///
/// The image alone cannot say whose icon it is, and a scenario asking what a
/// title shows reads what was drawn rather than deciding it again.
package final class ProcessIconAttachment: NSTextAttachment {
    /// The program's catalog key.
    package let key: String
    /// The icon's side, without the gap after it.
    package let iconSide: CGFloat

    /// Makes an attachment for one program's icon.
    ///
    /// - Parameters:
    ///   - key: The program's catalog key.
    ///   - iconSide: The icon's side.
    package init(key: String, iconSide: CGFloat) {
        self.key = key
        self.iconSide = iconSide
        super.init(data: nil, ofType: nil)
    }

    /// Decodes an attachment, which keeps none of what was drawn.
    ///
    /// - Parameter coder: The archive.
    required init?(coder: NSCoder) {
        key = ""
        iconSide = 0
        super.init(coder: coder)
    }
}

/// The bundled process icons, drawn for a title.
@MainActor
package enum ProcessIcons {
    /// A leading icon's side: the size Safari draws a site's icon at in its
    /// tab, the same as a tab's tag icon.
    package static let side: CGFloat = 16
    /// The air between the icon and the text after it.
    package static let gap: CGFloat = 5

    /// Each icon's file as read, by catalog key; nil where the bundle lacks it.
    private static var sources: [String: NSImage?] = [:]

    /// Whether a title draws programs' icons: `[appearance] process_icons`.
    package static var isShown: Bool {
        Ubiquitty.Preferences.Effective.processIcons(Ubiquitty.Preferences.values().pointee)
    }

    /// The program's name as its owner writes it, for a tooltip or a spoken label.
    ///
    /// - Parameter key: A catalog key.
    /// - Returns: The name, empty for an unknown key.
    package static func title(forKey key: String) -> String {
        String(Ubiquitty.Title.processIconTitle(std.string(key)))
    }

    /// A program's icon at a title's size.
    ///
    /// - Parameters:
    ///   - key: The program's catalog key, as `RuntimeDrive.processIconKey()` gives it.
    ///   - side: The icon's side, in points.
    ///   - ink: The title's ink, which a template icon and a plate are drawn in.
    ///   - ground: The title's ground, which decides whether a drawn icon needs a plate.
    /// - Returns: The image, or nil for an empty or unknown key or a bundle without the file.
    package static func image(forKey key: String, side: CGFloat, ink: NSColor, ground: NSColor) -> NSImage? {
        guard !key.isEmpty, side > 0, let source = source(forKey: key) else { return nil }
        let isTemplate = Ubiquitty.Title.isProcessIconTemplate(std.string(key))
        let needsPlate = !isTemplate && Ubiquitty.App.processIconNeedsPlate(std.string(key), packedRGB(ground))
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            var mark = bounds
            if needsPlate {
                ink.setFill()
                squircle(in: bounds).fill()
                mark = bounds.insetBy(dx: side * 0.18, dy: side * 0.18)
            }
            let fitted = fit(source.size, in: mark)
            if isTemplate {
                // Drawn alone first, so the ink covers the icon and nothing behind it.
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                source.draw(in: fitted)
                ink.setFill()
                fitted.fill(using: .sourceAtop)
                context.endTransparencyLayer()
            } else {
                source.draw(in: fitted)
            }
            return true
        }
        image.accessibilityDescription = title(forKey: key)
        return image
    }

    /// A title with a program's icon before it, or the title as it was for no
    /// program or with `process_icons` off. A template icon wears the colour of
    /// the title's own words, its last run, rather than a dimmed lead's.
    ///
    /// - Parameters:
    ///   - baked: The title.
    ///   - key: The program's catalog key, empty for none.
    ///   - ground: The title's ground.
    /// - Returns: The title the surface wears.
    package static func title(_ baked: NSAttributedString, leadingWith key: String, ground: NSColor) -> NSAttributedString {
        guard isShown, !key.isEmpty, baked.length > 0 else { return baked }
        var leading = baked.attributes(at: 0, effectiveRange: nil)
        let font = leading[.font] as? NSFont ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let ink = baked.attribute(.foregroundColor, at: baked.length - 1, effectiveRange: nil) as? NSColor ?? .labelColor
        guard let attachment = attachment(forKey: key, font: font, ink: ink, ground: ground) else { return baked }
        leading[.attachment] = attachment
        let titled = NSMutableAttributedString(string: "\u{FFFC}", attributes: leading)
        titled.append(baked)
        return titled
    }

    /// A program's icon as an attachment, centred on a face's cap band, with
    /// the gap after it drawn into its image: a text field ignores kern on an
    /// attachment.
    ///
    /// - Parameters:
    ///   - key: The program's catalog key.
    ///   - font: The face of the text beside it.
    ///   - ink: The ink a template icon wears.
    ///   - ground: The ground it is drawn on.
    /// - Returns: The attachment, or nil for an unknown key or a missing file.
    package static func attachment(forKey key: String, font: NSFont, ink: NSColor, ground: NSColor) -> ProcessIconAttachment? {
        guard let icon = image(forKey: key, side: side, ink: ink, ground: ground) else { return nil }
        let width = side + gap
        let image = NSImage(size: NSSize(width: width, height: side), flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        image.accessibilityDescription = icon.accessibilityDescription
        let attachment = ProcessIconAttachment(key: key, iconSide: side)
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: ((font.capHeight - side) / 2).rounded(), width: width, height: side)
        return attachment
    }

    /// The icon's file, read once.
    private static func source(forKey key: String) -> NSImage? {
        if let cached = sources[key] { return cached }
        let file = String(Ubiquitty.Title.processIconFile(std.string(key)))
        let url = ShippedResources.directory(named: "process-icons")?.appendingPathComponent(file)
        let image = file.isEmpty ? nil : url.flatMap { NSImage(contentsOf: $0) }
        sources[key] = image
        return image
    }

    /// The largest rect of an image's proportions centred in a box.
    private static func fit(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }

    /// A squircle filling a rect: a superellipse, whose corners blend into its
    /// sides the way a continuous-corner app icon's do.
    private static func squircle(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let exponent = 5.0
        let steps = 96
        let rx = rect.width / 2
        let ry = rect.height / 2
        for step in 0..<steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            let c = cos(angle)
            let s = sin(angle)
            let x = rect.midX + rx * CGFloat(copysign(pow(abs(c), 2 / exponent), c))
            let y = rect.midY + ry * CGFloat(copysign(pow(abs(s), 2 / exponent), s))
            step == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
        }
        path.close()
        return path
    }

    /// A colour as Core's 0xRRGGBB.
    private static func packedRGB(_ color: NSColor) -> UInt32 {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        let byte = { (channel: CGFloat) in UInt32(UInt8(clamping: Int((channel * 255).rounded()))) }
        return (byte(rgb.redComponent) << 16) | (byte(rgb.greenComponent) << 8) | byte(rgb.blueComponent)
    }
}
