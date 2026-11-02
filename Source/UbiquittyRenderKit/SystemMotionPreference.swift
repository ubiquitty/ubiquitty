// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// SystemMotionPreference.swift — the system's Reduce Motion answer, as the
// render thread reads it.
//
// Reduce Motion is a fact about the process, not about a window or a
// terminal: one setting, read by every caret in every window. So it is held
// once, here, rather than copied onto each animator by an owner that has to
// remember to, and a store each owner fills is one that some owner leaves
// unfilled. The main thread samples it, because the accessibility answer is
// the UI layer's and changes on its notification; the render thread reads it
// at each tick, because a frame build that asked AppKit would tie itself to
// the main thread's settings cache.

import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The process's Reduce Motion answer, sampled on the main thread and readable
/// from any other.
@objc(UBSystemMotionPreference)
public final class SystemMotionPreference: NSObject {
    /// The answer, behind a lock because the writer is the main thread and
    /// the reader is whichever thread builds the frame.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answer = false
    @MainActor
    private static var observer: (any NSObjectProtocol)?

    /// Whether the system asks for motion to be reduced.
    ///
    /// False until ``beginObserving()`` has sampled it, which is the answer
    /// that keeps a configured glide rather than silently snapping it in a
    /// process that never installed the observer.
    @objc
    public static var isReduceMotionEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return answer
    }

    /// Samples the system's answer now and follows it thereafter.
    ///
    /// Once per process; a second call keeps the observer already installed.
    /// The application calls it at launch, ahead of any window, so the first
    /// frame any surface builds already reads the reader's setting.
    @objc
    @MainActor
    public static func beginObserving() {
        guard observer == nil else { return }
        sample()
        #if canImport(AppKit)
        observer = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { sample() }
        }
        #elseif canImport(UIKit)
        observer = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { sample() }
        }
        #endif
    }

    /// Reads the system's answer and publishes it.
    @MainActor
    private static func sample() {
        #if canImport(AppKit)
        let isEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #elseif canImport(UIKit)
        let isEnabled = UIAccessibility.isReduceMotionEnabled
        #else
        let isEnabled = false
        #endif
        publish(isEnabled)
    }

    private static func publish(_ isEnabled: Bool) {
        lock.lock()
        answer = isEnabled
        lock.unlock()
    }
}
