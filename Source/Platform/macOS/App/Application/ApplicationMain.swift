// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ApplicationMain.swift — the macOS bundle's entry point.
//
// The command line is read first, and each headless mode runs before any
// AppKit setup and exits: the ssh and mosh wrappers, the terminfo installer,
// the smokes and benches, the snapshot and the render profiler, and in the
// harness build the UI scenarios. Otherwise it creates the application and its
// delegate and runs the loop; there is no main nib.
//

import AppKit
import CxxStdlib
import UbiquittyAppBridge
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

@main
enum ApplicationMain {
    @MainActor
    static func main() {
        #if UBIQUITTY_UI_TESTS
        UITestRunner.prepareControlDirectory()
        #endif

        // UBIQUITTY_METAL_HUD=1 turns on the driver's per-frame overlay. Only the
        // driver's own variable engages it on a managed MTKView layer, and only
        // when it is set before any Metal device or layer exists.
        if let hud = ProcessInfo.processInfo.environment["UBIQUITTY_METAL_HUD"], let first = hud.first, first != "0",
            ProcessInfo.processInfo.environment["MTL_HUD_ENABLED"] == nil
        {
            setenv("MTL_HUD_ENABLED", "1", 1)
        }

        // `-e <program> [args…]` and `--`, read before every scanner below. The
        // words after the marker are the child's, and each scanner looks for its
        // own flag: reading the whole command line would let `-e /bin/sh -c …
        // --snapshot x` render a frame instead of running the program. The
        // terminal argument count is where the terminal's own command line ends,
        // and every scanner stops there.
        let request = Ubiquitty.Runtime.parseProcessLaunchArguments(CommandLine.argc, CommandLine.unsafeArgv)
        if request.status == .Error {
            standardError("ubiquitty: \(String(request.error))")
            exit(2)
        }
        let terminalArgumentCount = request.terminalArgumentCount

        // Replaces the process and never returns, so it precedes all setup.
        Ubiquitty.SwiftBridge.execRemoteWrapperIfRequested(terminalArgumentCount, CommandLine.unsafeArgv)

        let words = Ubiquitty.SwiftBridge.terminalWords(terminalArgumentCount, CommandLine.unsafeArgv).map { String($0) }
        let flags = words.dropFirst()

        // The terminfo entry, compiled into ~/.terminfo through tic.
        if flags.contains("--install-terminfo") {
            exit(Ubiquitty.Terminfo.exitCodeFor(Ubiquitty.Terminfo.install(nil)))
        }

        runHeadlessModeIfRequested(flags)

        // One offscreen frame written as a PNG.
        SnapshotRunner.runIfRequested(words)

        // The representative scenes rendered offscreen many times, with their
        // per-frame latency.
        SurfaceRenderProfile.runIfRequested(words)

        #if UBIQUITTY_UI_TESTS
        // The real app booted, the named scenarios run, and the process exits.
        UITestRunner.runIfRequested(words)
        #endif

        autoreleasepool {
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            let delegate = UBAppDelegate()
            // Applied here rather than parsed here: the delegate owns window
            // creation, and the parse had to precede the headless modes above.
            if request.status == .Command {
                delegate.launchCommandArguments = request.command.map { String($0) }
                delegate.sessionEndsWithLaunchCommand = Ubiquitty.Runtime.launchEndsWithChild(request)
            }
            // The application holds its delegate weakly; this scope holds it for
            // the life of the loop.
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        }
    }

    // The smokes and benches: one live session or measurement each, the exit
    // status the verdict. They print nothing on success, so a flag in these two
    // families that matched none of them is a typo, refused with an exit status
    // rather than falling through to a GUI a headless caller would wait on.
    @MainActor
    private static func runHeadlessModeIfRequested(_ flags: ArraySlice<String>) {
        for flag in flags {
            let verdict: Bool
            switch flag {
            case "--smoke-swift-runtime": verdict = SwiftRuntimeSmokeEntry.run()
            case "--smoke-surface": verdict = SurfaceSmokeEntry.run()
            case "--smoke-shell": verdict = ShellSmokeEntry.run()
            case "--smoke-draw-entry": verdict = DrawEntrySmokeEntry.run()
            case "--smoke-grid-cache": verdict = GridCacheSmokeEntry.run()
            case "--smoke-shipped-faces": verdict = ShippedFacesSmokeEntry.run()
            case "--smoke-shipped-icons": verdict = ShippedIconsSmokeEntry.run()
            case "--smoke-proportional-faces": verdict = ProportionalFacesSmokeEntry.run()
            case "--smoke-frame-clock": verdict = FrameClockSmokeEntry.run()
            case "--bench-swift-drain": verdict = SwiftDrainBenchEntry.run()
            case "--bench-swift-frames": verdict = SwiftFrameBenchEntry.run()
            case "--bench-deliveries": verdict = DeliveryBenchEntry.run()
            case "--bench-grid-cache-scroll": verdict = GridCacheScrollBenchEntry.run()
            default:
                guard flag.hasPrefix("--smoke-") || flag.hasPrefix("--bench-") else { continue }
                standardError("ubiquitty: no such headless mode: \(flag)")
                standardError(
                    "  --smoke-swift-runtime  --smoke-surface  --smoke-shell  --smoke-frame-clock  --smoke-grid-cache  --smoke-shipped-faces  --smoke-shipped-icons  --smoke-proportional-faces"
                )
                standardError("  --bench-swift-drain    --bench-swift-frames  --bench-deliveries  --bench-grid-cache-scroll")
                exit(2)
            }
            exit(verdict ? 0 : 1)
        }
    }

    private static func standardError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
