// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// AccessibilityValueSmoke.swift — the UIKit surface's text projection, read
// the way a reader reads it.
//
// The projection has two halves that fail separately. The value can be absent
// — a surface that publishes nothing to UIAccessibility answers every query
// with nil while drawing perfectly. Or it can be STALE: the projection is
// cached until a screen delivery marks it dirty, and an assistive query
// arrives before the first byte does, so a cache invalidated on the wrong
// arm serves that first empty screen forever. Both read as "the value is
// wrong" from outside; the second leg here is what tells them apart.

#if canImport(UIKit)

import Foundation
import UIKit
internal import UbiquittyCore

/// The launch-argument entry point.
public enum AccessibilityValueSmokeEntry {
    /// Runs the accessibility-value smoke.
    ///
    /// - Returns: Whether both legs passed.
    @MainActor
    public static func run() -> Bool { AccessibilityValueSmoke.run() }
}

enum AccessibilityValueSmoke {
    @MainActor
    static func run() -> Bool {
        guard let surface = TerminalSurface(rows: 24, columns: 80, fontFamily: "Menlo", pointSize: 13)
        else {
            return failed("Core declined a surface, or the renderer could not be built")
        }
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first
        else {
            return failed("no window scene, so no delivery ever reaches the main thread")
        }
        let window = UIWindow(windowScene: scene)
        surface.frame = window.bounds
        window.addSubview(surface)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        surface.feed(Data("first-probe\r\n".utf8))
        guard pump(surface, until: { (surface.accessibilityValue ?? "").contains("first-probe") }) else {
            return failed(
                "the fed text never became the element's value; it reads: "
                    + (surface.accessibilityValue ?? "nil")
            )
        }
        // The read above cached the projection. The second feed must stale
        // that cache through the screen delivery itself — the invalidation
        // this leg holds to the shared arm — or every read after the first
        // answers an old screen.
        surface.feed(Data("second-probe\r\n".utf8))
        guard pump(surface, until: { (surface.accessibilityValue ?? "").contains("second-probe") }) else {
            return failed(
                "a second feed left the value stale; it reads: "
                    + (surface.accessibilityValue ?? "nil")
            )
        }
        report(
            "accessibility-value smoke: ok — the grid's text is the element's value, and a later feed re-projects it"
        )
        return true
    }

    /// Pumps deliveries until the condition holds, bounded.
    ///
    /// The service call is driven directly, the way the drain signal's
    /// main-queue hop drives it in a live session: an embedded feed queues
    /// events but hops nothing, and the hop itself is the pipeline leg's
    /// business, not this smoke's.
    ///
    /// - Parameters:
    ///   - surface: The surface whose deliveries are pumped.
    ///   - condition: What must become true.
    /// - Returns: Whether it did.
    @MainActor
    private static func pump(_ surface: TerminalSurface, until condition: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            surface.serviceIngestEvents()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private static func failed(_ reason: String) -> Bool {
        report("accessibility-value smoke: FAIL: \(reason)")
        return false
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

#endif
