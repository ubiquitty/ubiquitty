// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import UbiquittyCore
import UbiquittyKit

/// The system tag palette as Swift consumers draw it, read from Core's one
/// table (`Session::tagPalette`) so a picker, the settings pane, and the
/// titlebar chips can never disagree about what "red" is.
@MainActor
enum TagPalette {
    /// One offered colour: its name and both framework representations.
    struct Entry {
        let name: String
        let nsColor: NSColor
        let color: Color
    }

    /// The offered colours, in the palette's own order.
    ///
    /// The Kit's palette with a SwiftUI colour added: the settings pane draws
    /// in SwiftUI and the title row in AppKit, and one list of colours serves
    /// both rather than two lists that can drift.
    static let entries: [Entry] = TitlebarTagPalette.entries.map { entry in
        let srgb = entry.nsColor.usingColorSpace(NSColorSpace.sRGB) ?? entry.nsColor
        return Entry(
            name: entry.name,
            nsColor: entry.nsColor,
            color: Color(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
        )
    }

    /// The swatch for a tag's colour value as the config spells it: a palette
    /// name (either spelling of grey) or a `#rrggbb` literal.
    ///
    /// Read through Core's `Session::tagColorFromValue`, so a value the title
    /// row would draw has a swatch and one it would not has none.
    ///
    /// - Parameter name: The colour value.
    /// - Returns: Its colour, or nil when the value names none.
    static func swatch(for name: String) -> Color? {
        TagColorValue.color(of: name).map { Color(nsColor: $0) }
    }
}
