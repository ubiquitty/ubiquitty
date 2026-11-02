// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyCore
import UbiquittyKit

/// Runs one offscreen snapshot inside the iOS simulator application.
enum IOSSnapshotLaunch {
    /// The stable file the host-side launcher copies from the app container.
    static let outputName = "ubiquitty-ios-snapshot.png"

    /// Parses the host launch arguments, renders, and writes the PNG.
    ///
    /// - Returns: Whether every argument and render stage succeeded.
    @MainActor
    static func run() -> Bool {
        guard let rows = integer(after: "--rows"),
            let columns = integer(after: "--columns"),
            let feedBase64 = string(after: "--feed-base64"),
            let encoded = Data(base64Encoded: feedBase64),
            let configPath = string(after: "--config")
        else {
            SmokeLaunch.report("ios-snapshot: malformed launch arguments")
            return false
        }
        // The configuration flags (--bg-opacity, --tek-glow, --tek-color-mode
        // and the rest) are the document's own keys, written into it through
        // Core's helper as every other driver writes them, so the fold reads
        // them with the rest. Strict: a case whose file misspells a key fails
        // rather than drawing with the key missing.
        guard let document = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            SmokeLaunch.report("ios-snapshot: config could not be read: \(configPath)")
            return false
        }
        var words = Ubiquitty.Preferences.SnapshotLaunchWords()
        for word in CommandLine.arguments { words.push_back(std.string(word)) }
        guard let stated = Ubiquitty.Preferences.stateSnapshotConfigurationWords(words, std.string(document)).value else {
            SmokeLaunch.report("ios-snapshot: a configuration flag did not parse")
            return false
        }
        let configured = Ubiquitty.Preferences.configure(stated, .Strict)
        guard configured.isApplied else {
            for skipped in configured.diagnostics {
                SmokeLaunch.report("ios-snapshot: \(configPath): \(String(Ubiquitty.Preferences.diagnosticSentence(skipped)))")
            }
            SmokeLaunch.report("ios-snapshot: config refused: \(configPath)")
            return false
        }
        let isFeedEscaped = flag("--feed-is-escaped")
        let feed = isFeedEscaped ? decodedEscapes(encoded) : encoded
        // The backing scale a comparison renders at, in the arm's own spelling.
        let contentScale = number(after: "--scale") ?? 2.0
        // The OSC 66 sizing gate a window declares at session start.
        let drawsSizedText = flag("--draws-sized-text")
        // An unfocused pane, as the other arms' `--unfocused` asks for.
        let isFocused = !flag("--unfocused")
        // The post-feed actions the macOS driver applies, through the same
        // Core calls (IOSSurfaceSnapshot.Actions).
        var actions = IOSSurfaceSnapshot.Actions()
        actions.shouldClearToMark = flag("--clear-to-mark")
        actions.shouldClearPreservingInput = flag("--clear-preserve-input")
        actions.viewOffset = integer(after: "--view-offset")
        actions.searchLiteral = string(after: "--search")
        if let rect = string(after: "--select-rect") {
            let corners = rect.split(separator: ",").compactMap { Int32($0) }
            guard corners.count == 4 else {
                SmokeLaunch.report("ios-snapshot: --select-rect takes r0,c0,r1,c1")
                return false
            }
            actions.selection = (corners[0], corners[1], corners[2], corners[3])
        }
        guard
            let png = IOSSurfaceSnapshot.renderPNG(
                rows: rows,
                columns: columns,
                feed: feed,
                contentScale: contentScale,
                drawsSizedText: drawsSizedText,
                isFocused: isFocused,
                actions: actions
            )
        else {
            SmokeLaunch.report("ios-snapshot: render refused")
            return false
        }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            SmokeLaunch.report("ios-snapshot: no documents directory")
            return false
        }
        do {
            try png.write(to: documents.appendingPathComponent(outputName), options: .atomic)
        } catch {
            SmokeLaunch.report("ios-snapshot: write failed: \(error.localizedDescription)")
            return false
        }
        print("ubiquitty-render-path: builder=core compositor=metal encoder=swift platform=ios")
        return true
    }

    /// Whether a bare flag is present.
    ///
    /// - Parameter name: The flag, dashes included.
    /// - Returns: True when the launch carries it.
    private static func flag(_ name: String) -> Bool {
        CommandLine.arguments.contains(name)
    }

    /// The bytes an escaped feed stands for, through Core's own decoder.
    ///
    /// - Parameter escaped: The value as the driver was given it.
    /// - Returns: The decoded bytes.
    private static func decodedEscapes(_ escaped: Data) -> Data {
        let text = String(decoding: escaped, as: UTF8.self)
        let decoded = text.withCString { pointer in
            String(Ubiquitty.Diagnostics.decodeEscapes(std.string_view(pointer)))
        }
        return Data(decoded.utf8)
    }

    /// Returns the argument following `name`.
    private static func string(after name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name) else {
            return nil
        }
        let valueIndex = CommandLine.arguments.index(after: index)
        guard valueIndex < CommandLine.arguments.endIndex else {
            return nil
        }
        return CommandLine.arguments[valueIndex]
    }

    /// Returns an integer argument.
    private static func integer(after name: String) -> Int? {
        string(after: name).flatMap(Int.init)
    }

    /// Returns a floating-point argument.
    private static func number(after name: String) -> Double? {
        string(after: name).flatMap(Double.init)
    }
}
