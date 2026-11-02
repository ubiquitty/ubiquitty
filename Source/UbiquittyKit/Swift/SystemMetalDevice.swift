// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// SystemMetalDevice.swift — the process's Metal device, started ahead of the
// first surface that draws with it.
//
// Creating the system device is a wait on the driver rather than work this
// process does, and nothing the fonts or the window need depends on its result.
// Asked for in the order a launch happens to want it, that wait is added to the
// launch. Started ahead of it, the wait is spent on whatever the launch was
// going to do next, and the surface that asks for it finds it already made.
//
// One device serves the process. Metal's default device is the same GPU for
// every caller, and the renderers built from it share their glyph sheets per
// configuration, so a second creation buys a second wait and nothing else.
//
// The shader library every renderer draws with is read on the same queue once
// the device exists, so a process that begins at launch holds the library of
// the bundle it launched from, and no window it opens later depends on that
// bundle still being in place.

import Metal
internal import UbiquittyRenderKit

/// The system Metal device, created once and shared.
///
/// The two entry points differ only in whether they wait: ``begin()`` starts the
/// creation and returns, ``resolve()`` returns the device and waits when the
/// creation is still in flight. A caller that resolves without anyone having
/// begun starts it there and waits the whole of it, which is correct and merely
/// unaccelerated.
public enum SystemMetalDevice {
    // Written once, on the queue below, and read after `ready` has been
    // signalled — which `collectOnce` is what guarantees.
    nonisolated(unsafe) private static var created: (any MTLDevice)?
    private static let ready = DispatchSemaphore(value: 0)

    // Swift's lazy static initialisation is the once-token: the initialiser
    // body runs on exactly one thread however many arrive.
    private static let startOnce: Void = {
        DispatchQueue.global(qos: .userInitiated)
            .async {
                let device = MTLCreateSystemDefaultDevice()
                created = device
                ready.signal()
                // After the signal, so a caller waiting for the device does not
                // also wait for the library. A renderer that asks for the
                // library meanwhile shares this one load: the library is read
                // under a lock, and whichever request takes it first reads the
                // file while the other finds the result.
                if let device {
                    _ = MetalPipelines.moduleShaderLibrary(for: device)
                }
            }
    }()

    private static let collectOnce: Void = {
        _ = startOnce
        ready.wait()
    }()

    /// Begins creating the device, and then reading the module's shader
    /// library for it, on a background queue.
    ///
    /// Idempotent and non-blocking: repeated calls do nothing, and the device
    /// belongs to no caller until ``resolve()`` hands it over. Call as early in
    /// a launch as there is anything to overlap the driver's wait with, which
    /// is also before anything can replace the bundle the library is read from.
    public static func begin() {
        _ = startOnce
    }

    /// Returns the device, waiting for it when its creation is still in flight.
    ///
    /// - Returns: The default system device, or nil on a machine that offers none.
    public static func resolve() -> (any MTLDevice)? {
        _ = collectOnce
        return created
    }
}
