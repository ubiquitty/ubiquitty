// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Metal
import UbiquittyKit

// FramePacingScenarios.swift — what a Kit-hosted surface puts on the glass
// while output arrives, and how soon a keystroke's echo follows it.
//
// The flood scenario reads presented frames, not encoded ones. An encode is a
// frame the renderer built; whether anybody saw it is the compositor's answer,
// which a drawable's presented handler gives with the time the frame latched.
// The slip accounting already arms that handler for the perf log; the
// scenario has it keep each present's time, and pairs every commit with
// whether it showed new content: net change against the shadow baseline, so
// a frame that moved only the caret's blink phase is a repeat. A flood of
// distinct lines changes every row on every frame, so under it a repeat is a
// frame the content did not ask for.
//
// Five readings, each printed as a `[pacing]` line whatever the verdict:
//
// - The whole flood, both stretches below and the focus changes around them,
//   read by commit: the longest the content stood still. A commit is the
//   frame the CPU side finished, so a stall in the drain, the capture or the
//   main thread shows there with or without a display.
// - The pane unfocused, as the on-demand arm: no caret schedule asks it for
//   frames, so it must not present faster than its content changes.
// - The pane focused and the window frontmost, as a person watching a flood
//   has it: fresh frames a second against the panel's maximum rate, the
//   99th-percentile gap between presented frames, in refresh intervals, and
//   the longest the content stood still on the glass. A good average with a
//   stall in it still reads as a stutter, and one stall moves no percentile.
// - The prompt idle after the flood, which must present no new content: the
//   echo below is told apart from everything else by that alone.
// - One key, from the call that delivers it to the presented frame carrying
//   its echo.
//
// Only a window on a display reaches the glass. The harness parks its windows
// off every display unless `--ui-test-visible` is given, so a parked run reads
// commits in place of presents, asserts the on-demand rule and the whole
// flood's stillness, and says the rest is unmeasured; a run whose frames never
// reach the glass — a display asleep, a screen locked — is refused rather than
// read. The window is ordered to the front of its level and never activated,
// so a visible run takes no keyboard focus from the session it runs in.
//
// A timing reading on a machine already busy with other work says more about
// the machine than the terminal. A reading that misses a threshold while a
// build tool is running, the machine is thermally throttled, or the load
// average leaves fewer processors free than the flood keeps busy is refused
// with its numbers rather than failed; one that meets them passes whatever
// the load.

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
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

/// The program the resize probe drives through a real PTY.
///
/// It answers every line it reads by erasing the screen and printing the line
/// on the first row, and between lines it writes a counter to the last row
/// every millisecond, so its output never goes quiet for the erase hold's
/// settle. Echo is off, so the first row is only ever the program's.
private let repaintOnInputSource = """
    import os, select, termios
    attributes = termios.tcgetattr(0)
    attributes[3] &= ~termios.ECHO
    termios.tcsetattr(0, termios.TCSANOW, attributes)
    os.write(1, b"\\x1b[?25l\\x1b[H\\x1b[2Jready")
    pending = b""
    tick = 0
    while True:
        if select.select([0], [], [], 0.001)[0]:
            pending += os.read(0, 4096)
            while b"\\n" in pending:
                line, pending = pending.split(b"\\n", 1)
                os.write(1, b"\\x1b[H\\x1b[2J" + line)
        tick += 1
        os.write(1, b"\\x1b[999;1Htick %d" % tick)
    """

/// Expects a full-screen program's repaints, sent through a real PTY during a
/// live resize, to present as soon as the drain has caught up with each one.
///
/// The program keeps writing between repaints, so a hold that waited for its
/// bytes to go quiet would keep every repaint back until the erase hold's
/// watchdog. A repaint that never lands fails; a repaint held longer than half
/// that watchdog fails too, unless the machine is too busy to time it.
///
/// - Parameters:
///   - t: The scenario's context.
///   - texture: The render target the probe draws into.
@MainActor
private func expectPTYRepaintsWithoutWaitingForQuiet(_ t: UBUITestContext, texture: any MTLTexture) {
    let program = NSTemporaryDirectory() + "ubq-repaint-on-input-\(ProcessInfo.processInfo.processIdentifier).py"
    guard (try? repaintOnInputSource.write(toFile: program, atomically: true, encoding: .utf8)) != nil else {
        t.expect(false, desc: "the repainting program is written")
        return
    }
    defer { try? FileManager.default.removeItem(atPath: program) }
    guard
        let shell = TerminalWindowController.spawn(
            arguments: ["/usr/bin/python3", program],
            localePolicy: .auto,
            sessionLifetime: .outlivesChild
        ),
        let window = shell.window,
        let content = window.contentView,
        let surface = terminalSurface(under: content)
    else {
        t.expect(false, desc: "a Swift-shell window opens on the repainting program")
        return
    }
    defer { window.close() }
    t.expect(t.wait(until: { surface.gridTextForTesting().hasPrefix("ready") }, timeout: 4), desc: "the repainting program is ready")
    let loadBefore = MachineLoad()
    surface.viewWillStartLiveResize()
    defer { surface.viewDidEndLiveResize() }
    var missed: [String] = []
    for step in 0..<12 {
        let line = "pty repaint \(step)"
        let bytes = Array("\(line)\n".utf8).map { CChar(bitPattern: $0) }
        bytes.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                surface.drive.sendInput(base, count: buffer.count)
            }
        }
        // Read without pumping: the drain runs on its own thread, and the
        // repaint's landing is timed to the millisecond.
        let sentAt = ProcessInfo.processInfo.systemUptime
        var landedAt: TimeInterval?
        while landedAt == nil, ProcessInfo.processInfo.systemUptime - sentAt < 2 {
            if surface.gridTextForTesting().hasPrefix(line) {
                landedAt = ProcessInfo.processInfo.systemUptime
            } else {
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
        guard let landedAt else {
            t.expect(false, desc: "\(line) reaches the grid")
            continue
        }
        var heldFor: TimeInterval?
        while heldFor == nil, ProcessInfo.processInfo.systemUptime - landedAt < 0.045 {
            if surface.renderImmediatelyForTesting(into: texture, contentScale: 1) {
                heldFor = ProcessInfo.processInfo.systemUptime - landedAt
            } else {
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
        if let heldFor, heldFor < 0.025 {
            continue
        }
        missed.append(
            "\(line) was held "
                + (heldFor.map { String(format: "%.1f ms", $0 * 1000) } ?? "past 45 ms")
                + " after it landed, with its program still writing"
        )
    }
    guard !missed.isEmpty else { return }
    if let busy = [loadBefore, MachineLoad()].first(where: { $0.isBusy(leaving: 2) }) {
        t.refuse("the machine is too busy to time repaints (\(busy.description)): " + missed.joined(separator: "; "))
        return
    }
    for miss in missed {
        t.expect(false, desc: miss)
    }
}

/// Writes one `[pacing]` line to the run's log.
///
/// - Parameter text: The reading.
private func notePacing(_ text: String) {
    FileHandle.standardError.write(Data("[pacing] \(text)\n".utf8))
}

/// The value `fraction` of the way up `values`, by nearest rank.
///
/// - Parameters:
///   - values: The sample, in any order.
///   - fraction: The rank, from 0 to 1.
/// - Returns: The value, or zero for an empty sample.
private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
    return sorted[min(max(rank, 0), sorted.count - 1)]
}

/// What one stretch of a recording showed.
///
/// On a display the stretch is read by when frames reached the glass; parked,
/// by when they were committed, which is the closest a parked window comes.
private struct PacingReading {
    /// The stretch's length, in seconds.
    let seconds: Double
    /// Frames shown inside it, or committed when nothing is shown.
    let frames: Int
    /// Those frames that showed new content.
    let fresh: Int
    /// Frames committed inside it that the compositor never reported shown.
    let neverShown: Int
    /// Gaps between consecutive frames, in seconds.
    let gaps: [Double]
    /// The longest the content stood still inside the stretch, in seconds:
    /// between two frames that showed new content, or between either end of
    /// the stretch and the fresh frame nearest it, so a stretch that froze and
    /// never recovered reads as frozen.
    ///
    /// Counted between fresh frames rather than all frames, because a frame
    /// that moved only the caret leaves the content where it was.
    let longestStillSeconds: Double

    /// Reads the frames of `record` that fall inside a stretch.
    ///
    /// - Parameters:
    ///   - record: The surface's recording.
    ///   - start: The stretch's start, in `CACurrentMediaTime` seconds.
    ///   - end: Its end, on the same clock.
    ///   - byPresent: Whether frames are placed by their presented time
    ///     rather than their commit.
    init(_ record: [TerminalSurface.PresentedFrameForTesting], from start: Double, to end: Double, byPresent: Bool) {
        seconds = max(0, end - start)
        let times = record.map { (time: byPresent ? $0.presentedSeconds : $0.committedSeconds, frame: $0) }
            .filter { $0.time >= start && $0.time < end }
            .sorted { $0.time < $1.time }
        frames = times.count
        fresh = times.filter(\.frame.showsNewContent).count
        neverShown = record.filter { $0.presentedSeconds == 0 && $0.committedSeconds >= start && $0.committedSeconds < end }.count
        gaps = zip(times.dropFirst(), times).map { $0.time - $1.time }
        let freshTimes: [Double] = times.filter(\.frame.showsNewContent).map(\.time)
        let stills = [start] + freshTimes + [max(start, end)]
        longestStillSeconds = zip(stills.dropFirst(), stills).map { $0 - $1 }.max() ?? 0
    }

    var freshPerSecond: Double { seconds > 0 ? Double(fresh) / seconds : 0 }
    var framesPerSecond: Double { seconds > 0 ? Double(frames) / seconds : 0 }
    var repeats: Int { frames - fresh }

    /// The reading as one log line, its gaps in refresh intervals.
    ///
    /// - Parameter interval: The panel's refresh interval, in seconds.
    /// - Returns: The line, without the `[pacing]` prefix.
    func summary(interval: Double) -> String {
        String(
            format: "%.1f fresh/s, %.1f frames/s (%d frames, %d repeats, %d never shown, %.2fs); "
                + "gap p50 %.1f p99 %.1f max %.1f intervals; content still at most %.1f ms",
            freshPerSecond,
            framesPerSecond,
            frames,
            repeats,
            neverShown,
            seconds,
            percentile(gaps, 0.5) / interval,
            percentile(gaps, 0.99) / interval,
            (gaps.max() ?? 0) / interval,
            longestStillSeconds * 1000
        )
    }
}

/// How busy the machine is with work other than the scenario's.
private struct MachineLoad {
    /// Process names that mean a build is running beside the scenario.
    static let buildTools: Set<String> = [
        "cc1plus", "clang", "clang++", "ld", "ninja", "rustc", "swift-frontend", "swiftc", "xcodebuild",
    ]

    /// The one-minute load average.
    let average: Double
    /// The processors it is shared over.
    let processors: Int
    /// Whether the system is throttling for heat.
    let isThrottled: Bool
    /// The build tools running, by name, with how many of each.
    let builds: [String: Int]

    /// Samples the machine now.
    init() {
        var averages = [0.0, 0.0, 0.0]
        average = getloadavg(&averages, 3) > 0 ? averages[0] : 0
        processors = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let thermal = ProcessInfo.processInfo.thermalState
        isThrottled = thermal == .serious || thermal == .critical
        var pids = [pid_t](repeating: 0, count: 16_384)
        let listed = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        var name = [CChar](repeating: 0, count: 64)
        var found: [String: Int] = [:]
        for pid in pids.prefix(max(0, listed)) where pid > 0 && proc_name(pid, &name, UInt32(name.count)) > 0 {
            let tool = name.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
            if Self.buildTools.contains(tool) {
                found[tool, default: 0] += 1
            }
        }
        builds = found
    }

    /// Whether frames timed now say more about the machine than the terminal.
    ///
    /// The load average counts the threads waiting for a processor as well as
    /// those running, so a machine is busy once it leaves fewer processors free
    /// than the reading needs.
    ///
    /// - Parameter needed: The processors the reading keeps busy itself.
    /// - Returns: Whether a missed threshold is the machine's.
    func isBusy(leaving needed: Int) -> Bool {
        isThrottled || !builds.isEmpty || average > Double(processors - needed)
    }

    var description: String {
        var text = String(format: "load %.1f on %d processors", average, processors)
        if !builds.isEmpty {
            text += ", building (" + builds.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") + ")"
        }
        if isThrottled {
            text += ", thermally throttled"
        }
        return text
    }
}

/// A key press, synthesised as AppKit delivers one.
///
/// - Parameters:
///   - character: The character the key types.
///   - keyCode: Its hardware key code.
///   - window: The window it is addressed to.
/// - Returns: The event, or nil when AppKit refuses it.
@MainActor
private func keyPress(_ character: String, keyCode: UInt16, in window: NSWindow) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: character,
        charactersIgnoringModifiers: character,
        isARepeat: false,
        keyCode: keyCode
    )
}

/// Registers the frame-pacing scenarios with the UI-test runner.
enum FramePacingScenarios {
    /// Fresh frames a second the focused flood must show, as a fraction of the
    /// panel's maximum rate.
    ///
    /// The machine can show one every refresh: under the flood the display
    /// link ticks at the panel rate and a frame's GPU work is about a
    /// millisecond, so half the rate leaves scheduling a factor of two.
    static let minFreshFractionOfPanelRate = 0.5
    /// The longest 99th-percentile gap between presented frames, in refresh
    /// intervals: a picture held for more than three refreshes reads as a
    /// stall, whatever the average.
    static let maxPresentedGapIntervals = 3.0
    /// The longest the flood's content may stand still, in seconds, whether
    /// read by commit or on the glass.
    ///
    /// Core's frame driver reads this much silence from a program as its
    /// output having stopped (`FrameDriver::defaultIdleTimeoutSeconds`), so a
    /// screen that stands still this long while the flood still writes looks
    /// like a program that stopped. Core's own holds sit well inside it: the
    /// coherence rule takes a dirty pane two refreshes after it went dirty,
    /// whatever holds it, and a presented pane's drain pass ends at its frame
    /// interval. In seconds rather than refreshes, because a person sees a
    /// stall by its length whatever the panel's rate; a bound on the longest
    /// rather than a percentile, because with a hundred gaps or more a 99th
    /// percentile by nearest rank leaves the largest out.
    static let maxStillSeconds = 0.1
    /// The longest a key's echo may take to reach the glass, in refresh
    /// intervals.
    ///
    /// The compositor takes two to three of them from commit to glass, so on
    /// a 120 Hz panel this leaves the terminal about one refresh from the key
    /// to the commit carrying its echo.
    static let maxEchoIntervals = 3.0
    /// The processors the flood keeps busy itself.
    ///
    /// The shell's loop, the parser and the main thread each run flat out, and
    /// a reading times the terminal only while each has a processor nobody
    /// else wants.
    static let processorsTheFloodKeepsBusy = 3

    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_presents_frames_while_output_floods") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                measureFloodAndEcho(t)
            }
        }

        UBUITestRegister("swift_shell_live_resize_does_not_wait_for_output_to_settle") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let shellWindow = shell.window,
                    let content = shellWindow.contentView,
                    let renderer = terminalSurface(under: content)?.renderer,
                    let surface = TerminalSurface(rows: 24, columns: 80),
                    let device = MTLCreateSystemDefaultDevice()
                else {
                    t.expect(false, desc: "the resize probe has a surface and renderer")
                    return
                }
                defer { shellWindow.close() }
                // A streamless surface keeps a shell's startup output out of
                // the erase/repaint pairs and explicit synchronization blocks.
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                    styleMask: [.titled, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                surface.isFrameLinkHeldOffForTesting = true
                surface.renderer = renderer
                window.contentView = surface
                defer { window.close() }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: 640,
                    height: 480,
                    mipmapped: false
                )
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .shared
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    t.expect(false, desc: "the resize probe has a render target")
                    return
                }
                surface.feed(Data("\u{1b}[?25lresize repaint".utf8))
                t.expect(
                    t.wait(until: { surface.renderImmediatelyForTesting(into: texture, contentScale: 1) }, timeout: 2),
                    desc: "the initial frame is ready"
                )
                surface.viewWillStartLiveResize()
                defer { surface.viewDidEndLiveResize() }

                // Consecutive size changes in one turn must both reach the
                // program; a delayed callback can run much later under load.
                surface.setFrameSize(NSSize(width: 740, height: 480))
                let firstColumns = surface.drive.readSnapshot().columns
                surface.setFrameSize(NSSize(width: 840, height: 480))
                t.expect(
                    surface.drive.readSnapshot().columns > firstColumns,
                    desc: "the second size reaches the terminal without a timer"
                )
                for step in 0..<24 {
                    surface.feed(Data("\u{1b}[H\u{1b}[2Jresize repaint \(step)".utf8))
                    t.expect(
                        surface.renderImmediatelyForTesting(into: texture, contentScale: 1),
                        desc: "repaint \(step) presents without waiting for quiet output"
                    )
                }

                // Only the application's explicit block can defer a resize
                // frame. Check again after a size change's synchronous draw.
                surface.feed(Data("\u{1b}[?2026h\u{1b}[H\u{1b}[2Junfinished repaint".utf8))
                surface.setFrameSize(NSSize(width: 940, height: 480))
                t.expect(
                    !surface.renderImmediatelyForTesting(into: texture, contentScale: 1),
                    desc: "an explicit synchronized-output block still holds a resize frame"
                )
                surface.feed(Data(" completed\u{1b}[?2026l".utf8))
                t.expect(
                    surface.renderImmediatelyForTesting(into: texture, contentScale: 1),
                    desc: "the completed block presents immediately during resize"
                )

                // The repaints above are fed, and a feed carries its redraw
                // whole. A program's arrive through the drain, which is where
                // the resize's hold waits for a redraw still arriving.
                expectPTYRepaintsWithoutWaitingForQuiet(t, texture: texture)
            }
        }

        UBUITestRegister("swift_shell_a_resize_step_repaints_what_it_cleared") { context in
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
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)

                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                for row in 0..<30 {
                    surface.feed(Data("row-\(row) \(String(repeating: "x", count: 60))\r\n".utf8))
                }
                t.pump(0.5)
                surface.display()
                t.pump(0.2)
                surface.display()
                t.pump(0.2)

                // The drag's own branches, which a plain setFrameSize never
                // reaches: the surface keeps its own latch and only this pair
                // opens it.
                surface.viewWillStartLiveResize()
                defer { surface.viewDidEndLiveResize() }
                let base = surface.frame.size
                var refusingSteps = 0
                var blankSteps: [String] = []
                for step in 0..<26 {
                    surface.setFrameSize(NSSize(width: base.width, height: base.height + Double(step)))
                    surface.display()
                    guard let phase = surface.lastFramePhaseInputsForTesting else {
                        t.expect(false, desc: "step \(step) drew a frame")
                        return
                    }
                    // A step inside the slack band grows the drawable by a
                    // pixel or two without changing the row count, so the
                    // retained texture no longer matches and the frame has to
                    // paint the screen from the capture. A frame that refuses
                    // the target and emits nothing has cleared it and drawn
                    // nothing on it.
                    if !phase.didReuseLastFrame, phase.plannedRows > 0, phase.dirtyRows == 0 {
                        refusingSteps += 1
                        if phase.drawnCells == 0 {
                            blankSteps.append("step \(step) h=\(surface.bounds.height)")
                        }
                    }
                    t.pump(0.03)
                }
                // Said out loud: a sweep that never refused the target proves
                // nothing about a frame that does, and the band it walks is
                // narrow enough that a changed cell size or padding could carry
                // it past without one.
                t.expect(refusingSteps > 0, desc: "the sweep reached the refusing case (\(refusingSteps) step(s))")
                t.expect(
                    blankSteps.isEmpty,
                    desc: "and no refusing step drew an empty screen"
                        + (blankSteps.isEmpty ? "" : " — \(blankSteps.joined(separator: ", "))")
                )
            }
        }

        UBUITestRegister("swift_shell_a_font_step_never_paints_onto_a_cleared_target") { context in
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
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)

                // The window must HOLD its frame across the font step, or the
                // step resizes it and the case is about a resize: a drawable
                // that changed size is refused on size alone, which is the very
                // refusal this scenario asserts does not happen. Core classifies
                // a window whose content is the exact extent of its grid as
                // WindowFollowsGrid (Rendering::classifyCellMetricChange), and such a window
                // takes the extent the new cell gives it -- correct behaviour,
                // and what `a free-floating window follows its font` landed.
                //
                // Sizing the frame off the grid does not hold it: resizeGridToBounds
                // re-fits the grid to whatever bounds it is given, so the content
                // is an exact multiple again by the time the fit is classified.
                // classifyCellMetricChange short-circuits on isPinned || isSplit
                // ahead of that tolerance test, and isSplit is `surfaces.count > 1`,
                // a fact no re-fit can undo. So split the pane: the window then
                // keeps its frame and reflows, which is the documented
                // GridReflowsInWindow case. Split before the retained target is built, so
                // it perturbs nothing the assertions read.
                shell.splitRight(nil)
                t.pump(0.4)

                // A screenful, so a frame that paints only the dirty rows is a
                // frame that lost most of the screen.
                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                for row in 0..<30 {
                    surface.feed(Data("row-\(row) \(String(repeating: "x", count: 40))\r\n".utf8))
                }
                t.pump(0.4)

                // The retained target has to be in play, or the case is about a
                // frame that was going to rebuild anyway. A frame nobody asks
                // for is skipped, so owe each draw and drive until one reuses:
                // the first after the screenful rebuilds, and a later one, once
                // the retained target stands, reuses.
                var steady: TerminalSurface.FramePhaseInputs?
                for _ in 0..<40 {
                    surface.needsDisplay = true
                    surface.display()
                    t.pump(0.1)
                    if let inputs = surface.lastFramePhaseInputsForTesting, inputs.didReuseLastFrame {
                        steady = inputs
                        break
                    }
                }
                guard let steady else {
                    t.expect(false, desc: "a steady frame reuses the retained target before the font moves")
                    return
                }
                let baselineRefusals = steady.cellRefusalsAfterTrust
                let sizeBefore = surface.bounds.size

                // The font step owes a frame through its relayout; owe the draw
                // too, so the skip-unchanged-frames gate lets the step's frame
                // through rather than standing on the steady one.
                shell.growFontSize(nil)
                t.pump(0.5)
                surface.needsDisplay = true
                surface.display()
                t.pump(0.3)
                guard let after = surface.lastFramePhaseInputsForTesting else {
                    t.expect(false, desc: "the font step drew a frame")
                    return
                }

                // What the step did, asserted rather than assumed. A drawable
                // that changed size is refused on size alone, and a cell that
                // did not move is not the event this is about — either way the
                // assertion below would hold for a reason that has nothing to
                // do with it.
                t.expect(
                    surface.bounds.size == sizeBefore,
                    desc: "the font step held the surface's size (\(sizeBefore) -> \(surface.bounds.size))"
                )
                t.expect(
                    after.cellWidth != steady.cellWidth,
                    desc: "and moved the cell (\(steady.cellWidth) -> \(after.cellWidth))"
                )

                // The invariant. A frame counted here was built to skip the
                // clean rows and then had the ground cleared under them, which
                // is a screen holding whatever the shell wrote last and nothing
                // else.
                //
                // It does not discriminate today, and the measurement
                // says why. Under UBIQUITTY_PHASE_LOG the step's frame reads
                // `reused=0 dirty=46/46 rebuilt=stamp`: the styling stamp
                // refuses it first. Held open, the same frame reads
                // `rebuilt=core` — Core refuses it, because a font change
                // dirties every row and a full damage set cannot reuse. Held
                // open with the cell dropped from the verdict too, it still
                // reads `rebuilt=core`. Three locks, and no way found to move a
                // cell without dirtying the screen that moves with it.
                //
                // So this is an assertion on the invariant rather than a
                // reproduction of a defect: if any of the three locks is
                // removed, this is what notices.
                t.expect(
                    after.cellRefusalsAfterTrust == baselineRefusals,
                    desc: "no frame painted a trusted dirty set onto a target the encode refused"
                        + " (\(baselineRefusals) -> \(after.cellRefusalsAfterTrust))"
                )
            }
        }

        UBUITestRegister("swift_shell_drives_frames_while_output_flows") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let start = NSTemporaryDirectory() + "ubiquitty-frame-start-\(UUID().uuidString)"
                let stop = NSTemporaryDirectory() + "ubiquitty-frame-stop-\(UUID().uuidString)"
                defer {
                    try? FileManager.default.removeItem(atPath: start)
                    try? FileManager.default.removeItem(atPath: stop)
                }
                let script =
                    "import os, sys, time\n"
                    + "while not os.path.exists(sys.argv[1]): time.sleep(0.01)\n"
                    + "while not os.path.exists(sys.argv[2]):\n"
                    + "    os.write(1, b'flood-line\\r\\n' * 32)\n"
                    + "    time.sleep(0.01)\n"
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/usr/bin/python3", "-u", "-c", script, start, stop],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                window.orderFront(nil)
                t.pump(0.5)

                // Idle: nothing to present, so nothing is scheduled. A
                // terminal watching a prompt spends no wakeups.
                t.expect(
                    !surface.isDrivingFramesForTesting,
                    desc: "an idle surface drives no frames"
                )

                // Output starts. The idle-to-active edge is what resumes the
                // drive, and it is taken on the first delivery rather than on
                // every one.
                // Unbounded output rather than a counted loop: what is asserted
                // below is that the drive stays up WHILE output flows, and a
                // loop that finishes in half a second stops it for the right
                // reason at the wrong moment.
                _ = FileManager.default.createFile(atPath: start, contents: Data())
                t.expect(
                    t.wait(until: { surface.isDrivingFramesForTesting }, timeout: 5.0),
                    desc: "output starts the drive"
                )

                // While it runs, the drive stays up CONTINUOUSLY: the burst's
                // deliveries coalesce into clumps, and a drive that stopped
                // between them and was restarted by the next one would present
                // in clumps too. Sampled across the interval rather than at the
                // end of it, because a single read cannot tell a steady drive
                // from one flapping at the delivery rate.
                let startsBefore = surface.frameDriveStartsForTesting
                t.pump(0.5)
                let restarts = surface.frameDriveStartsForTesting - startsBefore
                t.expect(
                    surface.isDrivingFramesForTesting && restarts == 0,
                    desc: "and it stays up while the output keeps coming (\(restarts) restarts in 0.5s)"
                )

                // Output stops. Core's driver times out 0.1s later, and the
                // next tick reads that and stops the clock — a terminal that
                // kept a timer alive for a screen nobody is changing is the
                // cost this whole mechanism exists to avoid.
                _ = FileManager.default.createFile(atPath: stop, contents: Data())
                t.expect(
                    t.wait(until: { !surface.isDrivingFramesForTesting }, timeout: 5.0),
                    desc: "and silence stops it again"
                )
            }
        }

        // A program that writes once and then waits — a launcher printing its
        // banner, a benchmark's first report. Core's coherence rule holds the
        // burst until the read goes quiet, so the draw its delivery asks for
        // is refused; the rule lets go on the ingest loop's clock, once the
        // read has been quiet for its interval, and no further byte arrives
        // to ask again. Nothing but the
        // release can bring the burst to the glass, and with a steady caret
        // nothing else repaints the pane.
        UBUITestRegister("swift_shell_a_lone_burst_reaches_the_glass_without_more_output") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let trigger = NSTemporaryDirectory() + "ubiquitty-lone-burst-\(ProcessInfo.processInfo.processIdentifier)"
                try? FileManager.default.removeItem(atPath: trigger)
                defer { try? FileManager.default.removeItem(atPath: trigger) }
                let marker = "LONE-BURST-MARKER"
                // One process from first byte to last: a foreground change
                // after the burst would repaint the pane for its own reasons.
                let script =
                    "import os, sys, time\n"
                    + "os.write(1, b'\\033[2 q\\033[2J\\033[H')\n"
                    + "while not os.path.exists(sys.argv[1]): time.sleep(0.02)\n"
                    + "os.write(1, b'\(marker)')\n"
                    + "time.sleep(60)\n"
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/usr/bin/python3", "-c", script, trigger],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens over the one-shot writer")
                    return
                }
                defer { window.close() }
                window.orderFront(nil)
                // The harness parks its windows off every display, which reads
                // as covered; a covered pane withholds every frame by design.
                surface.isFullyOccludedForTesting = false
                NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
                t.expect(
                    t.wait(until: { surface.framesEncodedForTesting > 0 && !surface.isFrameOwedForTesting }, timeout: 5),
                    desc: "the pane draws its opening frame and settles"
                )
                t.pump(0.5)

                let framesBefore = surface.framesEncodedForTesting
                FileManager.default.createFile(atPath: trigger, contents: nil)
                t.expect(
                    t.wait(until: { surface.gridTextForTesting().contains(marker) }, timeout: 5),
                    desc: "the burst reaches the model"
                )
                t.expect(
                    t.wait(
                        until: {
                            surface.framesEncodedForTesting > framesBefore && !surface.isFrameOwedForTesting
                                && !surface.drive.isFrameHeld
                        },
                        timeout: 1
                    ),
                    desc: "a frame carrying the burst is drawn with no further output"
                        + " (encoded \(surface.framesEncodedForTesting - framesBefore),"
                        + " owed \(surface.isFrameOwedForTesting), held \(surface.drive.isFrameHeld))"
                )
            }
        }

        UBUITestRegister("swift_shell_tmux_pane_paints_when_its_output_lands") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.killTmuxServer(onSocket: "ubiquitty-uitest")
                defer { t.killTmuxServer(onSocket: "ubiquitty-uitest") }
                let before = TerminalWindowController.tmuxRepaintsForTesting
                guard t.launchTmuxArguments("-L ubiquitty-uitest -CC new-session -A -s pacing0") != nil else {
                    t.expect(false, desc: "a tmux -CC primary launched")
                    return
                }

                // The window tmux reports is hosted by this shell, and its pane
                // is render-only: it runs no ingest loop, so nothing repaints
                // it except the deliver flush's own hop.
                var hosted: TerminalWindowController?
                _ = t.wait(
                    until: {
                        hosted = NSApp.windows
                            .compactMap { $0.windowController as? TerminalWindowController }
                            .first { !$0.boundTmuxPaneIDs().isEmpty }
                        return hosted != nil
                    },
                    timeout: 10.0
                )
                t.expect(hosted != nil, desc: "a Swift-hosted tmux pane came up")

                // The attach itself delivers the pane's first output, so the
                // hop has to have found this shell by then. A zero is the
                // defect this closes: the hop looking for an Objective-C pane only,
                // finding none, and leaving the pane to repaint when something
                // else happens to ask.
                t.expect(
                    t.wait(
                        until: { TerminalWindowController.tmuxRepaintsForTesting > before },
                        timeout: 10.0
                    ),
                    desc:
                        "the deliver flush repainted the Swift-hosted pane (\(TerminalWindowController.tmuxRepaintsForTesting - before) times)"
                )
            }
        }
    }

    /// Floods a shell, reads what reached the glass with the pane unfocused
    /// and focused, then types one key into the idle prompt and reads how
    /// soon its echo reached the glass.
    ///
    /// - Parameter t: The run's context.
    @MainActor
    private static func measureFloodAndEcho(_ t: UBUITestContext) {
        let loadBefore = MachineLoad()
        // A foreground app is never napped. The harness's is an inactive
        // accessory whose windows AppKit reports covered — it reads no events,
        // so no occlusion report reaches it — which is what App Nap throttles;
        // the assertion is the one a frontmost app holds without asking.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "timing presented frames"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        // A plain /bin/sh rather than the login shell: the echo is timed
        // through whatever shell runs, and a prompt theme's cost is not the
        // terminal's latency.
        guard
            let shell = TerminalWindowController.spawn(
                arguments: ["/bin/sh"],
                localePolicy: .auto,
                sessionLifetime: .outlivesChild
            ),
            let window = shell.window,
            let content = window.contentView,
            let surface = terminalSurface(under: content)
        else {
            t.expect(false, desc: "a Swift-shell window opens with a surface over /bin/sh")
            return
        }
        defer { window.close() }
        window.orderFrontRegardless()
        let isOnDisplay = !WindowContainment.isOffscreen && window.screen != nil
        t.pump(0.5)
        surface.beginRecordingPresentsForTesting()
        defer { surface.endRecordingPresentsForTesting() }
        // A parked window has no screen; the frame clock then paces it as a
        // 60 Hz one, and so does the reading.
        let panelRate = window.screen.map { max(1, $0.maximumFramesPerSecond) } ?? 60
        let interval = 1.0 / Double(panelRate)
        notePacing(
            isOnDisplay
                ? "panel \(panelRate) Hz on \(window.screen?.localizedName ?? "an unnamed display"), \(loadBefore.description)"
                : "window parked off every display: frames are read as commits, \(loadBefore.description)"
        )

        // Unbounded, so the stretches never read an arm that has gone idle,
        // and every line distinct, so every frame of it shows new rows.
        surface.send("i=0; while :; do i=$((i+1)); echo flood-line-$i; done\n")
        t.expect(
            t.wait(until: { surface.gridTextForTesting().contains("flood-line-") }, timeout: 5),
            desc: "the flood reaches the screen"
        )
        t.pump(0.3)
        // The whole flood is read from here to the interrupt, focus changes
        // and all: a stall a person sees is one whatever the pane was doing.
        let floodStart = CACurrentMediaTime()

        // The on-demand arm: unfocused, only a delivery asks for a frame.
        surface.setSurfaceFocused(false)
        t.pump(0.2)
        let unfocusedStart = CACurrentMediaTime()
        t.pump(1.0)
        let unfocusedEnd = CACurrentMediaTime()

        // The foreground window's conditions: the pane focused, its caret's
        // schedule running as it does on screen.
        surface.setSurfaceFocused(true)
        t.pump(0.2)
        let focusedStart = CACurrentMediaTime()
        t.pump(2.0)
        let focusedEnd = CACurrentMediaTime()

        // The flood stops, and the prompt it leaves has to go quiet before a
        // key is timed: the first fresh frame after the key is its echo only
        // while nothing else is changing the screen.
        surface.send("\u{03}")
        let settled = t.wait(
            until: {
                let lastFresh = surface.recordedPresentsForTesting.last(where: \.showsNewContent)?.committedSeconds ?? 0
                return CACurrentMediaTime() - lastFresh > 0.5
            },
            timeout: 5
        )
        let idleStart = CACurrentMediaTime()
        t.pump(0.6)
        let idleEnd = CACurrentMediaTime()

        let echo = "q"
        guard let press = keyPress(echo, keyCode: 12, in: window) else {
            t.expect(false, desc: "AppKit makes a key press")
            return
        }
        let keyAt = CACurrentMediaTime()
        surface.keyDown(with: press)
        var echoFrame: TerminalSurface.PresentedFrameForTesting?
        _ = t.wait(
            until: {
                echoFrame = surface.recordedPresentsForTesting.first { $0.committedSeconds > keyAt && $0.showsNewContent }
                return echoFrame.map { !isOnDisplay || $0.presentedSeconds > 0 } ?? false
            },
            timeout: 2
        )
        // Long enough for the presented handlers of the last frames to run.
        t.pump(0.2)
        let record = surface.recordedPresentsForTesting
        let loadAfter = MachineLoad()
        let promptLine =
            surface.gridTextForTesting().split(separator: "\n")
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        t.expect(promptLine.hasSuffix(echo), desc: "the key's echo reached the screen (prompt line \(promptLine.debugDescription))")

        let flood = PacingReading(record, from: floodStart, to: focusedEnd, byPresent: false)
        let unfocused = PacingReading(record, from: unfocusedStart, to: unfocusedEnd, byPresent: isOnDisplay)
        let focused = PacingReading(record, from: focusedStart, to: focusedEnd, byPresent: isOnDisplay)
        let idle = PacingReading(record, from: idleStart, to: idleEnd, byPresent: isOnDisplay)
        notePacing("whole flood, by commit: " + flood.summary(interval: interval))
        notePacing("on-demand, pane unfocused: " + unfocused.summary(interval: interval))
        notePacing(
            "flood, pane focused\(isOnDisplay ? ", window frontmost" : ""): " + focused.summary(interval: interval)
                + String(format: "; %.0f%% of %d Hz", focused.freshPerSecond * interval * 100, panelRate)
        )
        notePacing("idle prompt\(settled ? "" : " (never went quiet)"): " + idle.summary(interval: interval))
        let echoSeconds = echoFrame.flatMap { frame -> Double? in
            let reached = isOnDisplay ? frame.presentedSeconds : frame.committedSeconds
            return reached > 0 ? reached - keyAt : nil
        }
        if let echoFrame, let echoSeconds {
            notePacing(
                String(
                    format: "key to echo %@: %.1f ms, %.1f intervals",
                    isOnDisplay ? "on the glass" : "committed",
                    echoSeconds * 1000,
                    echoSeconds / interval
                )
                    + (isOnDisplay ? String(format: " (committed at %.1f ms)", (echoFrame.committedSeconds - keyAt) * 1000) : "")
            )
        } else if let echoFrame {
            notePacing(
                String(format: "key to echo: committed at %.1f ms and not shown within 2 s", (echoFrame.committedSeconds - keyAt) * 1000)
            )
        } else {
            notePacing("key to echo: no frame showed new content within 2 s of the key")
        }
        notePacing("machine before: \(loadBefore.description); after: \(loadAfter.description)")

        // A reading of the glass needs frames that reached it.
        if isOnDisplay, !record.contains(where: { $0.presentedSeconds > 0 }) {
            t.refuse(
                "\(record.count) frames were committed and none reached the glass: the display is asleep, the screen is locked, or the window is on a space nobody is looking at"
            )
            return
        }
        // The instrument first: a flood that showed no new content, or an idle
        // prompt that did, means the fresh/repeat split is not reading what
        // changed, and nothing below can be judged by it.
        t.expect(focused.fresh > 0, desc: "the flood showed new content (\(focused.frames) frames, none fresh)")
        t.expect(
            idle.fresh == 0,
            desc: "the idle prompt showed no new content (\(idle.fresh) fresh frames): a caret blink would be read as an echo"
        )
        // The on-demand rule holds parked or not: a commit is what would be
        // presented.
        t.expect(
            unfocused.repeats == 0,
            desc:
                "the unfocused pane presents no faster than its content changes (\(unfocused.repeats) of \(unfocused.frames) frames repeated)"
        )
        var missed: [String] = []
        // Parked or not: commits are timed on the CPU side, so a parked run
        // reads a stall as surely as a visible one.
        if flood.longestStillSeconds > maxStillSeconds {
            missed.append(
                String(
                    format: "the flood's committed content stood still for %.1f ms (%.1f intervals) against a ceiling of %.0f ms",
                    flood.longestStillSeconds * 1000,
                    flood.longestStillSeconds / interval,
                    maxStillSeconds * 1000
                )
            )
        }
        if isOnDisplay {
            let minFreshPerSecond = minFreshFractionOfPanelRate * Double(panelRate)
            if focused.freshPerSecond < minFreshPerSecond {
                missed.append(
                    String(
                        format: "the focused flood showed %.1f fresh frames a second against a floor of %.1f (%.0f%% of %d Hz)",
                        focused.freshPerSecond,
                        minFreshPerSecond,
                        minFreshFractionOfPanelRate * 100,
                        panelRate
                    )
                )
            }
            let gapP99 = percentile(focused.gaps, 0.99) / interval
            if gapP99 > maxPresentedGapIntervals {
                missed.append(
                    String(
                        format: "the focused flood's p99 presented gap is %.1f intervals against a ceiling of %.0f",
                        gapP99,
                        maxPresentedGapIntervals
                    )
                )
            }
            // The glass can stall where the commits did not: a drawable
            // starved, a present held by the compositor.
            if focused.longestStillSeconds > maxStillSeconds {
                missed.append(
                    String(
                        format: "the focused flood's content stood still on the glass for %.1f ms (%.1f intervals)"
                            + " against a ceiling of %.0f ms",
                        focused.longestStillSeconds * 1000,
                        focused.longestStillSeconds / interval,
                        maxStillSeconds * 1000
                    )
                )
            }
            if let echoSeconds {
                if echoSeconds / interval > maxEchoIntervals {
                    missed.append(
                        String(
                            format: "the echo reached the glass %.1f intervals after the key (%.1f ms) against a ceiling of %.0f",
                            echoSeconds / interval,
                            echoSeconds * 1000,
                            maxEchoIntervals
                        )
                    )
                }
            } else {
                missed.append("no frame carrying the echo reached the glass within 2 s of the key")
            }
        } else {
            notePacing("presented pacing and key-to-glass latency unmeasured: the window is parked; run with --visible to measure them")
        }
        guard !missed.isEmpty else { return }
        if let busy = [loadBefore, loadAfter].first(where: { $0.isBusy(leaving: processorsTheFloodKeepsBusy) }) {
            t.refuse(
                "the machine is too busy to time frames (\(busy.description); the flood needs "
                    + "\(processorsTheFloodKeepsBusy) processors nobody else is using): "
                    + missed.joined(separator: "; ")
            )
            return
        }
        for miss in missed {
            t.expect(false, desc: miss)
        }
    }
}
