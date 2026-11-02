// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

/// Checked conversion into Core's signed caret coordinate representation.
enum RichTextGeometry {
    /// Quantizes points to 1/4096 point, declining unrepresentable geometry.
    /// Saturating a coordinate would falsely describe a native measurement.
    static func units(_ points: Double) -> UInt32? {
        let rounded = (points * 4096).rounded()
        guard rounded.isFinite, rounded >= 0, rounded < Double(Int32.max) else { return nil }
        return UInt32(rounded)
    }
}
