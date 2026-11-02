// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TitlebarTagPalette.swift — the seven colours a tag picker offers.
//
// Read from Core's own table rather than restated here, so the popover's dot
// strip, the settings pane's swatches and the markers drawn in the title row
// can never disagree about what "red" is.

import AppKit
internal import UbiquittyCore

/// The tag colours every picker in this app offers, in the palette's order.
@MainActor
public enum TitlebarTagPalette {
    /// One offered colour: the name a config would spell, and its swatch.
    public struct Entry {
        /// The name as `[[tags]]` spells it.
        public let name: String
        /// The colour that name resolves to.
        public let nsColor: NSColor
    }

    /// The offered colours, in the palette's own order.
    public static let entries: [Entry] = (0..<Int(Ubiquitty.Session.tagPaletteSize()))
        .map { index in
            let packed = Ubiquitty.Session.tagPaletteColorAt(Int32(index))
            return Entry(
                name: String(Ubiquitty.Session.tagPaletteNameAt(Int32(index))),
                nsColor: NSColor(packedRGB: packed)
            )
        }
}
