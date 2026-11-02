// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Keeps revisable speech out of the terminal's irreversible input stream.
struct TerminalVoiceTranscript {
    private(set) var preview = ""
    private var finalizedThrough: Double = -.infinity

    mutating func accept(_ text: String, endingAt time: Double, isFinal: Bool) -> String? {
        guard time.isFinite, time > finalizedThrough else { return nil }
        let insertion = String(
            text.unicodeScalars.map { scalar -> Character in
                if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || CharacterSet.newlines.contains(scalar) { return " " }
                return Character(scalar)
            }
        )
        guard isFinal else {
            preview = insertion
            return nil
        }
        finalizedThrough = time
        preview = ""
        return insertion.isEmpty ? nil : insertion
    }
}
