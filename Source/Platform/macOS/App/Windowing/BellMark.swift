// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// BellMark.swift — the glyph a bell nobody heard leaves behind.
//
// A bell that rings into a tab the reader is not on, or a window they are not
// in, has nowhere on screen to land. It leaves this instead, in whichever slot
// that surface has for saying one thing: an inactive tab's accessory, beside
// the ⌘N hint and the attention dots, or the trailing end of a window title.
// Both places want the same glyph at different sizes, so the image is built
// here once and neither draws its own bell.
//

import AppKit

@MainActor
enum BellMark {
    /// The name a screen reader announces the glyph by, in both slots.
    static let accessibilityDescription = "Unread bell"

    /// The bell, in the ink of the text it sits beside, or in the colour a
    /// program asked for where it asked for one.
    ///
    /// A program that set a tab status colour (OSC 21337) and then rang would
    /// otherwise have to pick which of the two the one slot showed; drawn in
    /// the colour, the bell says both, and Core ranks it as one thing
    /// (`App::TabAccessory::ColouredBell`).
    ///
    /// The whole bell takes the colour, not a badge on it. A badge was tried:
    /// at tab-strip size `bell.badge.fill` shows the colour on 52 pixels at 2x,
    /// under half the 113 the status dot it replaces showed, so ringing a bell
    /// made the agent's state harder to read than before it rang. The whole
    /// bell shows it on 334.
    ///
    /// - Parameters:
    ///   - pointSize: The glyph's size, matched to the text it sits beside.
    ///   - ink: The colour of the text the bell sits beside, at the coverage
    ///     that text wears. The bell takes no coverage of its own: one it chose
    ///     for itself stayed bright while the title receded with its window.
    ///   - statusColor: The colour the program asked for, or nil for a bell in
    ///     the text's own ink. Drawn exactly as asked, at full strength, as the
    ///     status dot it outranks is: the colour is the program's signal, and a
    ///     faded one reads as a different colour. Only the plain bell recedes.
    ///   - appearance: The appearance the glyph will be drawn under, which is
    ///     the caller's view's — not whatever happens to be current.
    /// - Returns: The image, or nil where the system has no such symbol.
    static func image(pointSize: CGFloat, ink: NSColor, statusColor: NSColor?, appearance: NSAppearance?) -> NSImage? {
        // A palette configuration bakes its colours into the image, so a
        // dynamic ink — the system label colour, which every native titlebar
        // uses — is frozen here rather than resolved at draw time. Frozen
        // under the WRONG appearance it is the colour of the row it sits on,
        // so the resolution happens under the caller's, and both callers
        // rebuild when theirs changes.
        var image: NSImage?
        let build = {
            let palette = NSImage.SymbolConfiguration(paletteColors: [statusColor ?? ink])
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
                .applying(palette)
            image = NSImage(
                systemSymbolName: "bell.fill",
                accessibilityDescription: accessibilityDescription
            )?
            .withSymbolConfiguration(configuration)
            // A palette symbol carries its own colour; left as a template,
            // AppKit would repaint it in whatever tint the host view carries.
            image?.isTemplate = false
        }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(build)
        } else {
            build()
        }
        return image
    }
}
