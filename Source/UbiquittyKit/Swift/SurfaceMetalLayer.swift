// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(AppKit)
import Foundation
import QuartzCore

/// The layer a surface presents into, whose `nextDrawable()` answers nil
/// rather than raising while a display link from ``makeDisplayLink()``
/// delivers its drawables.
///
/// Core Animation raises `CAMetalLayerInvalidOperation` from `nextDrawable()`
/// on a layer whose drawables a `CAMetalDisplayLink` delivers. The surface
/// publishes this layer, so a host can make that call, and an Objective-C
/// exception unwinding out of a host's main-actor task leaves the Swift
/// concurrency runtime's record of the running executor pointing into a frame
/// that is gone: the next main-actor isolation check anywhere in the process
/// reads it and faults. Nil is one of the documented answers of the call. A
/// link attached with `CAMetalDisplayLink(metalLayer:)` instead of
/// ``makeDisplayLink()`` is not seen, and the call raises under it.
///
/// No acquire overlaps a link from ``makeDisplayLink()``: an acquire that
/// finds such a link answers nil, and ``makeDisplayLink()`` attaches none
/// while an acquire waits for a drawable. Attaching does not stop an acquire
/// already waiting: one waiting on a pool run dry hands out a drawable when
/// its wait ends, under the link. The lock covers that state and never the
/// wait itself, which lasts up to a second, or without end once
/// `allowsNextDrawableTimeout` is false, so attaching or detaching a link on
/// the main thread never waits on an acquire on another thread.
internal final class SurfaceMetalLayer: CAMetalLayer {
    private let drawableDeliveryLock = NSLock()

    /// Whether a link from ``makeDisplayLink()`` delivers this layer's
    /// drawables; read and written under `drawableDeliveryLock`.
    private var isDrawableDeliveryLinked = false

    /// Acquires inside `super.nextDrawable()`; read and written under
    /// `drawableDeliveryLock`.
    private var waitingAcquireCount = 0

    override func nextDrawable() -> (any CAMetalDrawable)? {
        let mayAcquire = drawableDeliveryLock.withLock { () -> Bool in
            guard !isDrawableDeliveryLinked else { return false }
            waitingAcquireCount += 1
            return true
        }
        guard mayAcquire else { return nil }
        defer { drawableDeliveryLock.withLock { waitingAcquireCount -= 1 } }
        return super.nextDrawable()
    }

    /// Attaches a display link that delivers this layer's drawables.
    ///
    /// - Returns: The link, which ``invalidate(_:)`` detaches; nil while a
    ///   `nextDrawable()` call waits for a drawable, which a link attached now
    ///   would not stop.
    func makeDisplayLink() -> CAMetalDisplayLink? {
        drawableDeliveryLock.withLock {
            guard waitingAcquireCount == 0 else { return nil }
            isDrawableDeliveryLinked = true
            return CAMetalDisplayLink(metalLayer: self)
        }
    }

    /// Detaches a link made by ``makeDisplayLink()``, after which
    /// `nextDrawable()` vends drawables again.
    ///
    /// - Parameter link: The link to invalidate.
    func invalidate(_ link: CAMetalDisplayLink) {
        drawableDeliveryLock.withLock {
            link.invalidate()
            isDrawableDeliveryLinked = false
        }
    }

    /// Whether a `nextDrawable()` call is inside `super.nextDrawable()`, for a
    /// scenario starting and stopping the display link under one.
    var hasWaitingAcquireForTesting: Bool {
        drawableDeliveryLock.withLock { waitingAcquireCount > 0 }
    }
}
#endif
