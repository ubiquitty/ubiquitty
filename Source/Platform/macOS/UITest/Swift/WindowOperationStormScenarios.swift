// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// WindowOperationStormScenarios — a program's window ops cannot drive
// unbounded allocation.
//
// The showcase's "Window & title" entry writes CSI 6 t, CSI 9 ; 1 t,
// CSI 9 ; 0 t and two CSI 8 t resizes in one burst. A frame change per
// request resizes the drawable, which discards the layer's pool, and draws
// its step synchronously into a fresh allocation; a program repeating the
// burst has the app hold gigabytes of drawables until the run loop's pool
// pops, and the pop is a hang. These scenarios run the burst as a storm and
// bound what it costs, and check that no op sizes the window past the
// screen. What each op does is WindowOpScenarios'.
//
// Sizes are compared rather than frames: the harness parks its windows off
// every display by moving them sideways, which changes origins and nothing
// else. A parked window is handed no drawable, so the drawable, retained-grid
// and footprint figures bound only the draws a window on a display makes
// (Scripts/run-ui-tests.sh --visible); the frame-change and drawable-size
// counts hold either way.

import AppKit
import Darwin
import UbiquittyKit

@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let surface = view as? TerminalSurface {
        return surface
    }
    for subview in view.subviews {
        if let found = terminalSurface(under: subview) {
            return found
        }
    }
    return nil
}

/// The process's physical footprint, the figure a hang report quotes; GPU
/// drawables and their IOSurfaces count in it.
private func physicalFootprint() -> UInt64 {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return result == 0 ? usage.ri_phys_footprint : 0
}

/// The IOSurface and GPU-accelerator regions mapped into the process, by
/// count and by bytes. A drawable is one of each until it is released, so
/// the pair reads the storm's allocations directly, beside the footprint
/// they end up in.
private func mappedGPURegions() -> (count: Int, bytes: UInt64) {
    let ioSurfaceTag: UInt32 = 88
    let acceleratorTag: UInt32 = 100
    var address: mach_vm_address_t = 0
    var count = 0
    var bytes: UInt64 = 0
    while true {
        var size: mach_vm_size_t = 0
        var depth: natural_t = 0
        var info = vm_region_submap_info_64()
        var infoCount = mach_msg_type_number_t(
            MemoryLayout<vm_region_submap_info_64>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                mach_vm_region_recurse(mach_task_self_, &address, &size, &depth, $0, &infoCount)
            }
        }
        guard result == KERN_SUCCESS else { break }
        if info.user_tag == ioSurfaceTag || info.user_tag == acceleratorTag {
            count += 1
            bytes += UInt64(size)
        }
        address += size
    }
    return (count, bytes)
}

/// Counts a window's frame changes as AppKit announces them: the figure a
/// burst of geometry requests is bounded by, whatever applied them.
@MainActor
private final class WindowResizeCounter {
    private(set) var count = 0
    private var token: NSObjectProtocol?

    init(window: NSWindow) {
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }

    /// Stops counting; the window may outlive the scenario's interest in it.
    func stop() {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
        token = nil
    }
}

/// One reading of what the process holds, taken every 100 ms of the storm.
private struct StormSample {
    let footprint: UInt64
    let gpuRegions: Int
    let gpuBytes: UInt64

    static func take() -> StormSample {
        let regions = mappedGPURegions()
        return StormSample(footprint: physicalFootprint(), gpuRegions: regions.count, gpuBytes: regions.bytes)
    }
}

enum WindowOperationStormScenarios {
    /// Bursts the storm sends.
    private static let bursts = 40

    /// The footprint the storm may add, in bytes.
    ///
    /// One drawable of a filled 5K screen is about 60 MB, so this holds the
    /// layer's pool and the retained grid at the largest size and not a
    /// burst's worth more.
    private static let footprintBound: UInt64 = 512 << 20

    static func register() {
        UBUITestRegister("swift_shell_window_op_storm_allocates_once_per_final_size") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                let opening = surface.drive.readSnapshot()
                let rows = Int(opening.rows)
                let columns = Int(opening.columns)
                t.expect(rows > 2 && columns > 3, desc: "the window opens on a grid (\(columns)x\(rows))")
                // Put the window on its grid first, so a burst that ends on
                // the opening grid names the frame the storm started from.
                surface.feed(Data("\u{1b}[8;\(rows);\(columns)t".utf8))
                t.pump(0.3)
                let startFrame = window.frame

                // The showcase's burst, CSI 5 t left out so the window is never
                // raised over the reader's, then the two resizes twice over.
                // Alternate bursts end a row and two columns smaller, so every
                // burst ends at a size the previous one did not and a frame
                // change per final size is what the bound measures; the last
                // ends on the opening grid.
                func burst(endingSmaller isSmaller: Bool) -> Data {
                    let smaller = "\u{1b}[8;\(rows - 1);\(columns - 2)t"
                    let openingGrid = "\u{1b}[8;\(rows);\(columns)t"
                    let resizeRun =
                        isSmaller ? openingGrid + smaller + openingGrid + smaller : smaller + openingGrid + smaller + openingGrid
                    return Data(("\u{1b}[6t\u{1b}[9;1t\u{1b}[9;0t" + resizeRun).utf8)
                }

                let resizes = WindowResizeCounter(window: window)
                defer { resizes.stop() }
                let base = StormSample.take()
                let baseDrawables = surface.drawablesRequestedForTesting
                let baseSizeChanges = surface.drawableSizeChangeCount
                let baseGrids = surface.gridTextureAllocationsForTesting
                var peakFootprint = base.footprint
                var peakRegions = base.gpuRegions
                var samples: [StormSample] = []
                var nextSample = Date()
                for index in 0..<bursts {
                    surface.feed(burst(endingSmaller: index % 2 == 0))
                    let until = Date(timeIntervalSinceNow: 0.025)
                    repeat {
                        t.pump(0.005)
                        if Date() >= nextSample {
                            let sample = StormSample.take()
                            samples.append(sample)
                            peakFootprint = max(peakFootprint, sample.footprint)
                            peakRegions = max(peakRegions, sample.gpuRegions)
                            nextSample = Date(timeIntervalSinceNow: 0.1)
                        }
                    } while until.timeIntervalSinceNow > 0
                }
                t.pump(0.5)
                let settled = StormSample.take()
                peakFootprint = max(peakFootprint, settled.footprint)
                peakRegions = max(peakRegions, settled.gpuRegions)

                let drawables = surface.drawablesRequestedForTesting - baseDrawables
                let sizeChanges = surface.drawableSizeChangeCount - baseSizeChanges
                let grids = surface.gridTextureAllocationsForTesting - baseGrids
                let frameChanges = resizes.count
                let growth = peakFootprint > base.footprint ? peakFootprint - base.footprint : 0
                let isOnScreen = window.occlusionState.contains(.visible)
                let sampled = samples.map { "\($0.footprint >> 20)/\($0.gpuRegions)/\($0.gpuBytes >> 20)" }
                    .joined(separator: ",")
                NSLog(
                    "%@",
                    "window-op-storm bursts=\(bursts) onScreen=\(isOnScreen) frameChanges=\(frameChanges) "
                        + "drawables=\(drawables) sizeChanges=\(sizeChanges) grids=\(grids) "
                        + "footprintMB base=\(base.footprint >> 20) peak=\(peakFootprint >> 20) "
                        + "gpuRegions base=\(base.gpuRegions)/\(base.gpuBytes >> 20)MB peak=\(peakRegions) "
                        + "samples(footprintMB/gpuRegions/gpuMB)=[\(sampled)]"
                )
                // A drain's burst folds into one frame change for where it
                // ends, applied at most once per display frame; a burst split
                // across two drains may land twice. A frame change per request
                // would be six per burst.
                t.expect(
                    frameChanges <= 2 * bursts,
                    desc: "at most two frame changes per burst (\(frameChanges) for \(bursts) bursts)"
                )
                t.expect(sizeChanges <= 2 * bursts + 2, desc: "at most two drawable sizes per burst (\(sizeChanges))")
                t.expect(grids <= 2 * bursts + 2, desc: "the retained grid reallocates at most twice per burst (\(grids))")
                t.expect(drawables <= 3 * bursts + 16, desc: "drawables asked for stay under \(3 * bursts + 16) (\(drawables))")
                t.expect(
                    growth <= footprintBound,
                    desc: "the footprint grows at most \(footprintBound >> 20) MB (\(growth >> 20) MB, peak \(peakFootprint >> 20) MB)"
                )
                t.expect(
                    window.frame.size == startFrame.size,
                    desc: "the storm ends at the size it started from (\(window.frame.size) for \(startFrame.size))"
                )
            }
        }

        UBUITestRegister("swift_shell_window_ops_stay_inside_the_screen") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content),
                    let screen = window.screen ?? NSScreen.main
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface on a screen")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                let opening = surface.drive.readSnapshot()
                let rows = Int(opening.rows)
                let columns = Int(opening.columns)
                let visible = screen.visibleFrame

                // Neither CSI 8 t nor CSI 4 t sizes the window past the screen,
                // so no program reaches a drawable larger than it.
                let scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 1
                let screenPixels = CGSize(width: visible.width * scale, height: visible.height * scale)
                for request in ["\u{1b}[8;9999;9999t", "\u{1b}[4;999999;999999t"] {
                    surface.feed(Data(request.utf8))
                    t.pump(0.4)
                    let drawable = surface.metalLayer.drawableSize
                    t.expect(
                        window.frame.width <= visible.width + 0.5 && window.frame.height <= visible.height + 0.5,
                        desc: "\(request.dropFirst()) keeps the window inside the visible screen (\(window.frame))"
                    )
                    t.expect(
                        drawable.width <= screenPixels.width + 1 && drawable.height <= screenPixels.height + 1,
                        desc: "and the drawable inside the screen's pixels (\(drawable))"
                    )
                }
                surface.feed(Data("\u{1b}[8;\(rows);\(columns)t".utf8))
                t.pump(0.3)
            }
        }
    }
}
