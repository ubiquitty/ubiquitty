// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CoreText
import Foundation

@main
struct RichTextNativeGeometryTests {
    static func main() {
        precondition(RichTextGeometry.units(0) == 0)
        precondition(RichTextGeometry.units(0.5) == 2048)
        precondition(RichTextGeometry.units(-1) == nil)
        precondition(RichTextGeometry.units(.nan) == nil)
        precondition(RichTextGeometry.units(.infinity) == nil)
        precondition(RichTextGeometry.units(.greatestFiniteMagnitude) == nil)
        precondition(RichTextGeometry.units(Double(Int32.max) / 4096) == nil)
        precondition(RichTextGeometry.units(Double(Int32.max - 1) / 4096) == UInt32(Int32.max - 1))

        // A valid maximum-size RTF run can produce both representable and
        // unrepresentable long clip lines. Preserve the first; refuse the
        // second without pretending its width stopped at a convenient cap.
        let font = CTFontCreateWithName("Menlo" as CFString, 500, nil)
        func width(_ count: Int) -> Double {
            let source = NSAttributedString(
                string: String(repeating: "W", count: count),
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(source), nil, nil, nil)
        }
        let count = Int(ceil((Double(1 << 30) + 4096) / (width(1) * 4096)))
        precondition(count > 0 && count < 4096)
        let representable = width(count)
        precondition(representable * 4096 > Double(1 << 30))
        precondition(RichTextGeometry.units(representable) == UInt32((representable * 4096).rounded()))
        let oversized = width(4096)
        precondition(oversized * 4096 > Double(Int32.max))
        precondition(RichTextGeometry.units(oversized) == nil)
        print("rich-text-native-geometry: real CoreText long lines and numeric boundaries pass")
    }
}
