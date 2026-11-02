// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// WindowCornerMask.swift — builds the NSWindow._cornerMask image with continuous
// (squircle) TOP corners and SQUARE bottom corners.
//
// AppKit/NSBezierPath has no continuous-corner style, so we take the path from
// SwiftUI's RoundedCornerStyle.continuous — the same superellipse curve macOS
// uses for window corners and app icons — and union it with a bottom rectangle
// to square the bottom corners. The result is returned as a 9-slice stretchable
// mask image (capInsets + .stretch) that AppKit clips the window frame to.
//

import AppKit
import SwiftUI

@objc(UBWindowCornerMask)
public final class WindowCornerMask: NSObject {
    // Continuous top corners of `radius` points, square bottom corners.
    //
    // The corner cap is sized to 2*radius: a continuous corner's curve reaches
    // further along the edges than a circular arc (which is what the
    // squircle), so the fixed 9-slice caps must be large enough to contain the
    // full transition — otherwise the stretch region truncates it and the frame
    // detaches from the content at the corner. The 1pt middle row/column stretch
    // to any window size.
    @objc
    public static func topRoundedSquareBottom(radius: CGFloat) -> NSImage {
        let r = max(0, radius)
        let cap = ceil(r * 2.0)
        let side = cap * 2.0 + 1.0
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            var path = Path()
            path.addRoundedRect(
                in: rect,
                cornerSize: CGSize(width: r, height: r),
                style: .continuous
            )
            // Square the bottom: union a full-width strip over the bottom cap.
            // The image is unflipped (origin bottom-left, y grows up), so the
            // bottom corners are at y = 0.
            path.addRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cap))
            cg.addPath(path.cgPath)
            cg.setFillColor(NSColor.black.cgColor)
            cg.fillPath() // nonzero winding → union of the rounded rect and the strip
            return true
        }
        image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        image.resizingMode = .stretch
        return image
    }
}
