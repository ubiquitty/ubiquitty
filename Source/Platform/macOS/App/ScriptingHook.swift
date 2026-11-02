// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ScriptingHook.swift — the `[scripting]` hook: a program of the reader's that
// prints trigger, macro and character-class rules, folded into the
// configuration at every load.
//
// The decisions are Core's: which program runs, which is nothing until
// `enable = true` names the gate open (`Effective::scriptingHookProgram`); how
// much of its output counts (`scriptingOutputLimit`); and how what it printed
// joins what the file declared (`mergeScriptingRules`). This is the part that
// has to be a platform's — start the program, read its standard output up to
// the bound, end it when it goes past the bound or falls silent.
//
// Rules it prints are the configuration's from then on, so a trigger rule is
// compiled into each new pane by the launch seed and into each open one by the
// reload, exactly as one written in the file is.
//

import Foundation
internal import UbiquittyCore

/// Runs the `[scripting]` config script and hands Core what it prints.
@objc(UBScriptingHook)
public final class ScriptingHook: NSObject {
    /// Runs the configured script, if the gate is open, and hands its output
    /// to Core, which keeps it beside the live document and merges its rules.
    ///
    /// Runs on the caller's thread and returns when the script has ended: the
    /// load that calls this is about to read the rules it produces. Main-thread
    /// only, because the live configuration is.
    ///
    /// - Returns: How many directives were merged; zero when nothing ran.
    @discardableResult
    @objc
    public static func run() -> Int {
        let program = String(Ubiquitty.Preferences.Effective.scriptingHookProgram(Ubiquitty.Preferences.values().pointee))
        guard !program.isEmpty, FileManager.default.isExecutableFile(atPath: program) else { return 0 }
        guard let output = boundedOutput(of: program) else { return 0 }
        return Int(Ubiquitty.Preferences.configureScriptOutput(std.string(output)))
    }

    /// What a program writes to its standard output, up to the hook's bound.
    ///
    /// Its standard error goes nowhere rather than into this application's log.
    /// A program still writing at the bound is ended, and so is one that has
    /// gone quiet without closing its output: its output past the bound would
    /// not be read, a writer blocked on a full pipe would never exit, and this
    /// runs on the load that a launch or a reload is waiting for.
    ///
    /// - Parameter program: The executable's path.
    /// - Returns: The output as text, or nil when the program did not start.
    private static func boundedOutput(of program: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("[scripting] config_script failed to launch %@: %@", program, String(describing: error))
            return nil
        }
        let reader = pipe.fileHandleForReading
        let output = readOutput(from: reader.fileDescriptor, upTo: Int(Ubiquitty.Preferences.scriptingOutputLimit))
        // Ended whatever stopped the read: the program is past the bound, or
        // silent past the deadline, or gone already — in which case there is
        // nothing to signal and the wait below returns its status.
        if process.isRunning {
            process.terminate()
        }
        // Closed before the wait, so a writer that outlived the signal takes
        // SIGPIPE on its next write rather than filling the pipe again.
        try? reader.close()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }

    /// How long the hook reads a program's output before ending the program.
    ///
    /// The byte bound alone ends only a program that keeps writing. One that
    /// goes quiet with its output still open — a forked child inherits it —
    /// holds the read for as long as it lives, and this read is the one a
    /// launch or a reload waits on, so it ends on the clock as well.
    private static let outputDeadlineSeconds = 5.0

    /// Reads a descriptor until end of file, the byte bound, or the deadline.
    ///
    /// `read(2)` rather than `FileHandle.availableData`, which raises an
    /// Objective-C exception when the read on the pipe fails: the raise
    /// unwinds through Swift frames and ends the process, where a failed read
    /// here is the end of the output and nothing more.
    ///
    /// - Parameters:
    ///   - descriptor: The pipe's read end.
    ///   - limit: The most bytes worth keeping; the read stops once past it.
    /// - Returns: What the program wrote, ending at the first of the bounds.
    private static func readOutput(from descriptor: Int32, upTo limit: Int) -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = ProcessInfo.processInfo.systemUptime + outputDeadlineSeconds
        while output.count <= limit {
            let secondsLeft = deadline - ProcessInfo.processInfo.systemUptime
            guard secondsLeft > 0 else { break }
            var watched = pollfd()
            watched.fd = descriptor
            watched.events = Int16(POLLIN)
            let ready = withUnsafeMutablePointer(to: &watched) { poll($0, 1, Int32((secondsLeft * 1000).rounded(.up))) }
            if ready < 0 {
                guard errno == EINTR else { break }
                continue
            }
            guard ready > 0 else { break }
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                guard errno == EINTR else { break }
                continue
            }
            guard count > 0 else { break }
            output.append(contentsOf: buffer[0..<count])
        }
        return output
    }
}
