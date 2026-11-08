// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Metal
import UbiquittyCore
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
// The under-load probes additionally type while ASCII, SGR, Unicode and mixed
// output keep arriving. Their input marker occupies a protected row: its
// captured cell instance identifies the commit carrying the response, so an
// unrelated fresh flood frame cannot stand in for the key's echo.
// Those probes record own-surface net-change commits only: both boundary and
// live captures report that fact, and a callback that reused the glass cannot
// consume a sibling's serial. They measure fresh-content pacing, not a census
// of repeated or overlay-only commits.
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

/// A real-PTY producer that answers input without stopping its output.
///
/// The first row is outside the scroll region. Each q toggles a wide marker's
/// SGR hidden bit there; wide cells retain a cell instance even when hidden.
/// The response overwrites without erasing: a capture between control bytes
/// still sees the previous marker's opposite hidden state.
/// Separate h/r commands calibrate those states without advancing the q count.
/// Lower rows keep changing independently, including around each response.
/// Heavy work areas follow Core's public `Tools/sgr-profile/sgr_bench.cpp`
/// and `Tests/Core/bench_ingest.cpp` recipes, translated down one marker row.
private let floodOnInputSource = """
    import os, select, sys, termios
    attributes = termios.tcgetattr(0)
    attributes[3] &= ~(termios.ECHO | termios.ICANON)
    attributes[6][termios.VMIN] = 1
    attributes[6][termios.VTIME] = 0
    termios.tcsetattr(0, termios.TCSANOW, attributes)
    def write_all(data):
        while data:
            data = data[os.write(1, data):]
    marker = "界".encode("utf-8")
    mode = sys.argv[1]
    heavy = mode.startswith("heavy_")
    ascii = b"abcdefghijklmnopqrstuvwxyz0123456789" * 2
    sgr = b"".join(b"\\x1b[38;5;%d;48;5;%dmX" % (16 + n, 231 - n) for n in range(48)) + b"\\x1b[0m"
    unicode = ("界é🙂e\\u0301" * 10).encode("utf-8")
    if heavy:
        columns, work_rows = 202, 49
        attributes = (0, 1, 4, 7)
        sequences = ["👨‍👩‍👧‍👦", "👩‍👩‍👦‍👦", "🧑🏻‍🤝‍🧑🏽", "👨🏿‍💻", "👩🏼‍❤️‍👨🏾", "🏳️‍🌈", "🏴‍☠️", "🧑‍🦲"]
        sgr_frames = []
        unicode_frames = []
        if mode != "heavy_unicode":
            for frame in range(216):
                sgr_frames.append([
                    b"\\x1b[%d;1H" % (y + 2) + b"".join(
                        b"\\x1b[%d;38;5;%d;48;5;%dm%c" % (
                            attributes[(x + y + frame) & 3],
                            16 + (x * 3 + frame) % 216, 16 + (y * 5 + frame) % 216,
                            65 + (x + y) % 26)
                        for x in range(columns))
                    for y in range(work_rows)])
        if mode != "heavy_sgr":
            for frame in range(8):
                unicode_frames.append([
                    b"\\x1b[%d;1H" % (y + 2) + "".join(
                        sequences[(x + y + frame) % 8] for x in range(columns // 2)).encode("utf-8")
                    for y in range(work_rows)])
        cached_bytes = sum(len(row) for family in (sgr_frames, unicode_frames) for frame in family for row in frame)
        assert cached_bytes <= 64 * 1024 * 1024
        rows = work_rows + 1
    else:
        bodies = {"ascii": [ascii], "sgr": [sgr], "unicode": [unicode], "mixed": [ascii, sgr, unicode]}[mode]
        rows = max(3, os.get_terminal_size(1).lines)
    write_all(b"\\x1b[?25l\\x1b[H\\x1b[2J\\x1b[2;%dr\\x1b[H\\x1b[38;2;255;32;32m" % rows
              + marker + b"\\x1b[0m input-0 ready\\x1b[2;1H")
    received = 0
    def receive_input():
        global received
        if select.select([0], [], [], 0)[0]:
            for byte in os.read(0, 4096):
                if byte in (ord("h"), ord("r")):
                    visibility = b"8" if byte == ord("h") else b"28"
                    write_all(b"\\x1b7\\x1b[H\\x1b[0;38;2;32;255;32;" + visibility + b"m"
                              + marker + b"\\x1b[0m input-0 calibrated\\x1b8")
                elif byte == ord("q"):
                    received += 1
                    visibility = b"8" if received % 2 else b"28"
                    write_all(b"\\x1b7\\x1b[H\\x1b[0;38;2;255;32;32;" + visibility + b"m"
                              + marker + b"\\x1b[0m input-%d\\x1b8" % received)
    frame = 0
    while True:
        if heavy:
            write_all(b"\\x1b[2;1H")
            if mode == "heavy_sgr" or (mode == "heavy_mixed" and frame % 2 == 0):
                data = sgr_frames[(frame if mode == "heavy_sgr" else frame // 2) % 216]
            else:
                data = unicode_frames[(frame if mode == "heavy_unicode" else frame // 2) % 8]
            for row in data:
                receive_input()
                write_all(row)
            write_all(b"\\x1b[0m")
        else:
            receive_input()
            tick = frame + 1
            write_all(b"load-%d " % tick + bodies[tick % len(bodies)] + b"\\x1b[0m\\r\\n")
        frame += 1
    """

/// The parser and renderer work each continuous-output probe exercises.
private enum FloodPayload: String {
    case ascii
    case sgr
    case unicode
    case mixed
    case heavySGR = "heavy_sgr"
    case heavyUnicode = "heavy_unicode"
    case heavyMixed = "heavy_mixed"

    var isHeavy: Bool { self == .heavySGR || self == .heavyUnicode || self == .heavyMixed }
}

/// The probe and encode observer's marker state, confined to their main actor.
@MainActor
private final class FloodMarkerCapture {
    var shouldBeHidden: Bool?
    var frameIndex: Int?
    var lastAlpha: Float?
    var freshCommits = 0
}

/// Copies the body values these producers change, excluding the marker row.
///
/// Indexed SGR changes colors while keeping its glyphs fixed. Copy scalar
/// values under the model lock; no borrowed cells or cluster-pool IDs escape.
///
/// - Parameter surface: The producer's pane.
/// - Returns: Its bounded body glyphs and indexed colors, or nil without a model.
@MainActor
private func floodBodyState(of surface: TerminalSurface) -> [UInt32]? {
    surface.drive.withTerminal { terminal -> [UInt32] in
        let columns = min(Int(terminal.columns), 202)
        let rows = min(Int(terminal.rows), 50)
        guard columns > 0, rows > 1 else { return [] }
        var row = [Ubiquitty.Cell](repeating: Ubiquitty.Cell(), count: columns)
        var state: [UInt32] = []
        state.reserveCapacity((rows - 1) * columns * 3)
        row.withUnsafeMutableBufferPointer { cells in
            for index in 1..<rows {
                Ubiquitty.Screen.getDisplayRow(terminal, 0, Int32(index), cells.baseAddress, Int32(columns))
                for cell in cells {
                    state.append(cell.codePoint)
                    state.append(UInt32(cell.pen.foregroundIndex))
                    state.append(UInt32(cell.pen.backgroundIndex))
                }
            }
        }
        return state
    }
}

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

    /// Describes a recording containing only fresh-content commits.
    func freshContentSummary(interval: Double) -> String {
        String(
            format: "%.1f fresh/s (%d fresh frames, %.2fs, %d gaps); "
                + "fresh gap p50 %.1f p99 %.1f max %.1f intervals; content still at most %.1f ms",
            freshPerSecond,
            fresh,
            seconds,
            gaps.count,
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

        UBUITestRegister("swift_shell_echo_is_attributable_during_ascii_flood") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { measureInputDuringFlood(t, payload: .ascii) }
        }
        UBUITestRegister("swift_shell_echo_is_attributable_during_sgr_flood") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { measureInputDuringFlood(t, payload: .sgr) }
        }
        UBUITestRegister("swift_shell_echo_is_attributable_during_unicode_flood") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { measureInputDuringFlood(t, payload: .unicode) }
        }
        UBUITestRegister("swift_shell_echo_is_attributable_during_mixed_flood") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { measureInputDuringFlood(t, payload: .mixed) }
        }
        UBUITestRegister("swift_shell_echo_is_attributable_during_mixed_pane_floods") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { measureInputDuringFlood(t, payload: .sgr, alongsideMixedPane: true) }
        }
        UBUITestRegister("swift_shell_input_during_heavy_sgr_churn_202x49") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { measureInputDuringFlood(t, payload: .heavySGR) }
        }
        UBUITestRegister("swift_shell_input_during_heavy_unicode_202x49") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { measureInputDuringFlood(t, payload: .heavyUnicode) }
        }
        UBUITestRegister("swift_shell_input_during_heavy_mixed_202x49") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { measureInputDuringFlood(t, payload: .heavyMixed) }
        }
        UBUITestRegister("swift_shell_input_during_two_heavy_panes_202x49") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { measureInputDuringFlood(t, payload: .heavySGR, alongsideMixedPane: true) }
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

    /// Times input responses carried by identified frames while output flows.
    ///
    /// - Parameters:
    ///   - t: The run's context.
    ///   - payload: The output the producer keeps sending between inputs.
    ///   - alongsideMixedPane: Whether a second visible pane also floods.
    @MainActor
    private static func measureInputDuringFlood(_ t: UBUITestContext, payload: FloodPayload, alongsideMixedPane: Bool = false) {
        let configuration: String? =
            payload.isHeavy
            ? t.configureAppending(
                "[window]\ninitial_columns = \(alongsideMixedPane ? 406 : 202)\ninitial_rows = \(alongsideMixedPane ? 52 : 50)\n"
            ) : nil
        defer {
            if let configuration { t.restoreConfiguration(configuration) }
        }
        let program = NSTemporaryDirectory() + "ubq-input-during-\(payload.rawValue)-\(ProcessInfo.processInfo.processIdentifier).py"
        guard (try? floodOnInputSource.write(toFile: program, atomically: true, encoding: .utf8)) != nil else {
            t.expect(false, desc: "the input-responsive flood program is written")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: program) }
        let loadBefore = MachineLoad()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "timing input during output"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        guard
            let shell = TerminalWindowController.spawn(
                arguments: ["/usr/bin/python3", program, payload.rawValue],
                localePolicy: .auto,
                sessionLifetime: .outlivesChild
            ),
            let window = shell.window,
            let content = window.contentView,
            let surface = terminalSurface(under: content)
        else {
            t.expect(false, desc: "a Swift-shell window opens on the input-responsive flood")
            return
        }
        defer { window.close() }
        window.orderFrontRegardless()
        surface.setSurfaceFocused(true)
        guard WindowContainment.isOffscreen || window.screen != nil else {
            t.refuse("the visible under-load probe has no display for its window")
            return
        }
        let isOnDisplay = !WindowContainment.isOffscreen && window.screen != nil
        let panelRate = window.screen.map { max(1, $0.maximumFramesPerSecond) } ?? 60
        let interval = 1.0 / Double(panelRate)
        let preparationSeconds = payload.isHeavy ? 15.0 : 5.0
        guard t.wait(until: { surface.gridTextForTesting().hasPrefix("界 input-0 ready") }, timeout: preparationSeconds) else {
            t.expect(false, desc: "the producer reserves its input marker row")
            return
        }

        var sibling: TerminalSurface?
        var siblingCommitTimes: [Double] = []
        if alongsideMixedPane {
            shell.splitRight(nil)
            guard let other = shell.paneSurfacesForTesting.first(where: { $0 !== surface }) else {
                t.expect(false, desc: "the continuous-output probe has a second pane")
                return
            }
            sibling = other
            let quotedProgram = "'" + program.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let siblingPayload = payload.isHeavy ? FloodPayload.heavyMixed.rawValue : FloodPayload.mixed.rawValue
            other.send("exec /usr/bin/python3 \(quotedProgram) \(siblingPayload)\n")
            guard t.wait(until: { other.gridTextForTesting().hasPrefix("界 input-0 ready") }, timeout: preparationSeconds) else {
                t.expect(false, desc: "the sibling also runs continuous mixed output")
                return
            }
            window.makeFirstResponder(surface)
        }
        if !isOnDisplay {
            // A parked window is reported covered. Permit CPU-side commits
            // there while leaving visible runs subject to real occlusion.
            surface.isFullyOccludedForTesting = false
            sibling?.isFullyOccludedForTesting = false
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        let panes = sibling.map { [surface, $0] } ?? [surface]
        if payload.isHeavy {
            let grid = surface.drive.readSnapshot()
            if panes.contains(where: { $0.drive.readSnapshot().columns != 202 || $0.drive.readSnapshot().rows != 50 }),
                let renderer = surface.renderer, let content = window.contentView
            {
                // Pane headers and divider insets consume a few cells. Adjust
                // only the fixture's window, using the layout's own cell size.
                let cell = renderer.cellSize(for: surface)
                let missingColumns = panes.reduce(0) { $0 + 202 - Int($1.drive.readSnapshot().columns) }
                window.setContentSize(
                    NSSize(
                        width: content.bounds.width + CGFloat(missingColumns) * cell.width,
                        height: content.bounds.height + CGFloat(50 - Int(grid.rows)) * cell.height
                    )
                )
            }
            guard
                t.wait(
                    until: { panes.allSatisfy { $0.drive.readSnapshot().columns == 202 && $0.drive.readSnapshot().rows == 50 } },
                    timeout: 5
                )
            else {
                t.expect(false, desc: "every heavy pane has a 202x49 work area below its protected marker row")
                return
            }
        }
        let grids =
            panes.map {
                let grid = $0.drive.readSnapshot()
                return "\(grid.columns)x\(grid.rows)"
            }
            .joined(separator: ",")
        let contentSize = window.contentView?.bounds.size ?? .zero
        notePacing(
            "\(payload.rawValue) geometry: panes \(grids), content \(Int(contentSize.width))x\(Int(contentSize.height)) points,"
                + " scale \(window.backingScaleFactor), panel \(panelRate) Hz"
                + (payload.isHeavy ? "; public work area 202x49, CUP rows shifted +1 for marker" : "; scrolling work area below marker")
        )
        let siblingObserver = sibling?.frameEncodedObserverForTesting
        sibling?.frameEncodedObserverForTesting = { surface in
            siblingObserver?(surface)
            if surface.renderer?.lastFrameHadNetChange(for: surface) == true {
                siblingCommitTimes.append(CACurrentMediaTime())
            }
        }
        defer { sibling?.frameEncodedObserverForTesting = siblingObserver }

        let marker = FloodMarkerCapture()
        surface.beginRecordingPresentsForTesting()
        defer { surface.endRecordingPresentsForTesting() }
        let recordFrame = surface.frameEncodedObserverForTesting
        surface.frameEncodedObserverForTesting = { surface in
            // A boundary and a live capture both publish this own-surface
            // verdict. Reproducing the glass requires a clean mask, so that
            // callback cannot consume a sibling's serial from the shared ring.
            guard surface.renderer?.lastFrameHadNetChange(for: surface) == true else { return }
            marker.freshCommits += 1
            let needsMarker = marker.shouldBeHidden != nil && marker.frameIndex == nil
            let countBefore = needsMarker ? surface.recordedPresentsForTesting.count : 0
            recordFrame?(surface)
            guard needsMarker else { return }
            let countAfter = surface.recordedPresentsForTesting.count
            guard let alpha = surface.drawnForegroundAlphaForTesting(row: 0, column: 0) else { return }
            marker.lastAlpha = alpha
            guard countAfter > countBefore else { return }
            // This reads the instance stream left by this encode, not the
            // concurrently changing model. Native text can carry negative
            // alpha for its secondary plane; either sign still draws ink.
            let isHidden = abs(alpha) < 0.001
            if let shouldBeHidden = marker.shouldBeHidden, marker.frameIndex == nil, isHidden == shouldBeHidden {
                marker.frameIndex = countAfter - 1
            }
        }
        // A clean protected row can be absent from an incremental instance
        // stream. Calibrate with real producer writes after installing the
        // observer: visible → hidden → visible, without starting a timer or
        // incrementing the measured input counter. Nil never certifies either.
        for (command, hidden) in [("h", true), ("r", false)] {
            marker.shouldBeHidden = hidden
            marker.frameIndex = nil
            marker.lastAlpha = nil
            let commitsBefore = marker.freshCommits
            surface.send(command)
            guard t.wait(until: { marker.frameIndex != nil }, timeout: 2) else {
                t.expect(
                    false,
                    desc: "the calibration marker reaches its captured \(hidden ? "hidden" : "visible") state"
                        + " (fresh commits \(marker.freshCommits - commitsBefore),"
                        + " recorded \(surface.recordedPresentsForTesting.count), alpha \(String(describing: marker.lastAlpha)))"
                )
                return
            }
            notePacing(
                "\(payload.rawValue) untimed calibration \(hidden ? "hidden" : "visible"):"
                    + " commit \(marker.frameIndex ?? -1), alpha \(String(describing: marker.lastAlpha))"
            )
        }
        marker.shouldBeHidden = nil
        marker.frameIndex = nil

        func expectOutputProgress(_ phase: String, input: Int) {
            let panes = sibling.map { [surface, $0] } ?? [surface]
            let beforeBodies = panes.map { floodBodyState(of: $0) }
            let beforeCommits = [marker.freshCommits, siblingCommitTimes.count]
            let beforeCount = surface.recordedPresentsForTesting.count
            let end = CACurrentMediaTime() + 0.15
            var changed = panes.map { _ in false }
            _ = t.wait(
                until: {
                    for (index, pane) in panes.enumerated() where !changed[index] {
                        let commits = index == 0 ? marker.freshCommits : siblingCommitTimes.count
                        if commits > beforeCommits[index], let before = beforeBodies[index], let after = floodBodyState(of: pane) {
                            changed[index] = before != after
                        }
                    }
                    return changed.allSatisfy { $0 }
                },
                timeout: 0.15
            )
            // Keep the full observation stretch even when the first changed
            // body lands early; sampling also avoids a cyclic recipe aliasing
            // back to exactly its starting colors at the final instant.
            t.pump(max(0, end - CACurrentMediaTime()))
            for index in panes.indices {
                let commits = index == 0 ? marker.freshCommits : siblingCommitTimes.count
                t.expect(
                    changed[index] && commits > beforeCommits[index],
                    desc: "pane \(index) changes output and commits fresh content \(phase) input \(input) during \(payload.rawValue) flood"
                )
            }
            let fresh = surface.recordedPresentsForTesting.dropFirst(beforeCount).filter(\.showsNewContent).count
            t.expect(
                fresh > 0,
                desc: "the input pane commits fresh output frames \(phase) input \(input) during \(payload.rawValue) flood"
            )
        }

        let floodStart = CACurrentMediaTime()
        var missed: [String] = []
        for input in 1...3 {
            expectOutputProgress("before", input: input)
            guard let press = keyPress("q", keyCode: 12, in: window) else {
                t.expect(false, desc: "AppKit makes the under-load key press")
                return
            }
            marker.frameIndex = nil
            marker.shouldBeHidden = input % 2 == 1
            let keyAt = CACurrentMediaTime()
            surface.keyDown(with: press)
            var response: TerminalSurface.PresentedFrameForTesting?
            var responsePresentedAt: Double?
            _ = t.wait(
                until: {
                    guard let index = marker.frameIndex else { return false }
                    let frames = surface.recordedPresentsForTesting
                    guard index < frames.count else { return false }
                    response = frames[index]
                    // The protected marker persists until the next input.
                    // Subsequent retained frames carry it too, so a dropped
                    // first drawable need not hide the response's real arrival.
                    responsePresentedAt = frames.dropFirst(index).map(\.presentedSeconds).filter { $0 > 0 }.min()
                    return !isOnDisplay || responsePresentedAt != nil
                },
                timeout: 2
            )
            marker.shouldBeHidden = nil
            t.expect(
                surface.gridTextForTesting().hasPrefix("界 input-\(input)"),
                desc: "input \(input) reaches the \(payload.rawValue) producer while it writes"
            )
            if let response {
                let commitDelay = response.committedSeconds - keyAt
                let presentDelay = responsePresentedAt.map { $0 - keyAt }
                notePacing(
                    String(format: "%@ input %d during flood: commit %.1f ms", payload.rawValue, input, commitDelay * 1000)
                        + (presentDelay.map { String(format: ", present %.1f ms (%.1f intervals)", $0 * 1000, $0 / interval) }
                            ?? ", present unmeasured")
                )
                t.expect(response.showsNewContent && commitDelay >= 0, desc: "the marker identifies a fresh commit after input \(input)")
                if commitDelay > maxStillSeconds {
                    missed.append(String(format: "%@ input %d committed after %.1f ms", payload.rawValue, input, commitDelay * 1000))
                }
                if isOnDisplay, presentDelay.map({ $0 / interval > maxEchoIntervals }) ?? true {
                    missed.append("\(payload.rawValue) input \(input) did not reach the glass within \(maxEchoIntervals) intervals")
                }
            } else {
                missed.append("\(payload.rawValue) input \(input) had no attributable commit within 2 s")
            }
            expectOutputProgress("after", input: input)
        }
        let floodEnd = CACurrentMediaTime()
        t.pump(0.2)
        let record = surface.recordedPresentsForTesting
        let loadAfter = MachineLoad()
        let label = payload.rawValue + (alongsideMixedPane ? " with mixed sibling" : "")
        let committed = PacingReading(record, from: floodStart, to: floodEnd, byPresent: false)
        let presented = PacingReading(record, from: floodStart, to: floodEnd, byPresent: true)
        notePacing("\(label) during-input fresh content, by commit: " + committed.freshContentSummary(interval: interval))
        if sibling != nil {
            let times = [floodStart] + siblingCommitTimes.filter { $0 >= floodStart && $0 < floodEnd } + [floodEnd]
            let longestGap = zip(times.dropFirst(), times).map { $0 - $1 }.max() ?? 0
            notePacing(
                String(
                    format: "mixed sibling fresh content: %d commits, longest fresh gap %.1f ms",
                    times.count - 2,
                    longestGap * 1000
                )
            )
            if longestGap > maxStillSeconds {
                missed.append(String(format: "mixed sibling commits stood still for %.1f ms", longestGap * 1000))
            }
        }
        if isOnDisplay {
            notePacing("\(label) during-input fresh content, on glass: " + presented.freshContentSummary(interval: interval))
            guard record.contains(where: { $0.presentedSeconds > 0 }) else {
                t.refuse("the under-load commits never reached the glass: the display or visible window is unavailable")
                return
            }
            if presented.freshPerSecond < minFreshFractionOfPanelRate * Double(panelRate) {
                missed.append("\(payload.rawValue) fresh presentations fell below \(minFreshFractionOfPanelRate * 100)% of \(panelRate) Hz")
            }
            if percentile(presented.gaps, 0.99) / interval > maxPresentedGapIntervals {
                missed.append("\(payload.rawValue) p99 presented gap exceeded \(maxPresentedGapIntervals) intervals")
            }
            if presented.longestStillSeconds > maxStillSeconds {
                missed.append(
                    String(format: "%@ presented content stood still for %.1f ms", payload.rawValue, presented.longestStillSeconds * 1000)
                )
            }
        } else {
            notePacing("\(payload.rawValue) presented pacing and input-to-glass latency unmeasured: window parked")
        }
        if committed.longestStillSeconds > maxStillSeconds {
            missed.append(
                String(format: "%@ committed content stood still for %.1f ms", payload.rawValue, committed.longestStillSeconds * 1000)
            )
        }
        notePacing("\(payload.rawValue) machine before: \(loadBefore.description); after: \(loadAfter.description)")
        guard !missed.isEmpty else { return }
        let processorsNeeded = processorsTheFloodKeepsBusy + (alongsideMixedPane ? 2 : 0)
        if let busy = [loadBefore, loadAfter].first(where: { $0.isBusy(leaving: processorsNeeded) }) {
            t.refuse("the machine is too busy to time input during output (\(busy.description)): " + missed.joined(separator: "; "))
            return
        }
        for miss in missed {
            t.expect(false, desc: miss)
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
