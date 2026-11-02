// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// PaletteBridge.swift — the one place Beam adapts the portable C++ command
// palette (Ubiquitty::CommandPalette) to Swift. Imported directly through
// -cxx-interoperability-mode=default; there is no ObjC layer. All std::string /
// std::vector bridging lives here so the rest of Beam stays Swift-native.
//

import CxxStdlib
import Foundation
import UbiquittyCore

// The scope is the Core C++ `enum class` itself — a FROZEN Swift enum, so an
// exhaustive switch needs no @unknown default. The cases are PascalCase (.Actions
// / .Settings / .GoTo / .Blocks / .Find), matching the C++ member names.
typealias PaletteScope = Ubiquitty.CommandPalette.Scope

private typealias CorePalette = Ubiquitty.CommandPalette

// MARK: - Scope presentation

extension PaletteScope {
    // The chip mark: a Title-case word per terminal scope, or the bare › for
    // actions (the default handles Actions + any future case).
    var chipLabel: String {
        switch self {
        case .Settings: return "Settings"
        case .GoTo: return "Go to"
        case .Blocks: return "Blocks"
        case .Find: return "Find"
        default: return "›"
        }
    }

    var placeholder: String {
        switch self {
        case .Settings: return "Adjust an option…"
        case .GoTo: return "Switch tab or pane…"
        case .Blocks: return "Jump to a command…"
        case .Find: return "Search scrollback…"
        default: return "Run a command…"
        }
    }
}

// MARK: - Ranked result (only what Swift can't derive from the command by id)

struct PaletteRankedResult {
    let identifier: String
    let checked: Bool
    let matchedIndices: IndexSet
}

private func swiftResult(_ core: CorePalette.PaletteResult) -> PaletteRankedResult {
    var indices = IndexSet()
    for index in core.matchedIndices where index >= 0 {
        indices.insert(Int(index))
    }
    return PaletteRankedResult(
        identifier: String(core.id),
        checked: core.checked,
        matchedIndices: indices
    )
}

// MARK: - Command descriptor

// Build the portable descriptor the engine ranks from a Beam command. No closure
// crosses the boundary — the id round-trips and Beam holds the effect by id.
private func coreCommand(_ command: BeamCommand) -> CorePalette.PaletteCommand {
    var out = CorePalette.PaletteCommand()
    out.id = command.paletteID.cxxString
    out.title = command.title.cxxString
    out.group = command.group.cxxString
    out.shortcut = command.shortcut.cxxString
    out.value = command.value.cxxString
    for keyword in command.keywords {
        out.keywords.push_back(keyword.cxxString)
    }
    out.kind = command.paletteKind
    return out
}

private func coreCommandList(_ commands: [BeamCommand]) -> CorePalette.PaletteCommandList {
    var list = CorePalette.PaletteCommandList()
    list.reserve(commands.count)
    for command in commands {
        list.push_back(coreCommand(command))
    }
    return list
}

// MARK: - Engine

// Swift-native wrapper over Ubiquitty::CommandPalette::Engine. Holds the C++
// value; every method adapts the STL boundary in one place.
final class PaletteEngine {
    private var engine = CorePalette.Engine()

    func setActive(scope: PaletteScope, commands: [BeamCommand]) {
        engine.setActive(scope, coreCommandList(commands))
    }

    func setUsageScores(_ scores: [String: Double]) {
        var map = CorePalette.UsageScoreMap()
        for (id, score) in scores {
            map[id.cxxString] = score
        }
        engine.setUsageScores(map)
    }

    func rankedResults(_ query: String) -> [PaletteRankedResult] {
        query.withCxxStringView { view in
            engine.rankedResults(view).map(swiftResult)
        }
    }

    func rankedOptions(_ query: String, options: [String], current: Int) -> [PaletteRankedResult] {
        var coreOptions = CorePalette.PaletteOptionList()
        coreOptions.reserve(options.count)
        for label in options {
            var option = CorePalette.PaletteOption()
            option.label = label.cxxString
            coreOptions.push_back(option)
        }
        return query.withCxxStringView { view in
            engine.rankedOptions(view, coreOptions, Int32(current)).map(swiftResult)
        }
    }

    // The parsed field text: the scope a leading prefix selects and the query
    // with the prefix stripped exactly once.
    struct ParsedInput {
        let scope: PaletteScope
        let query: String
        let didSwitchScope: Bool
    }

    static func interpretInput(
        _ text: String,
        currentScope: PaletteScope,
        terminalAvailable: Bool
    ) -> ParsedInput {
        text.withCxxStringView { view in
            let parsed = CorePalette.Engine.interpretInput(
                view,
                currentScope,
                terminalAvailable
                    ? CorePalette.TerminalAvailability.Available
                    : CorePalette.TerminalAvailability.Unavailable
            )
            return ParsedInput(
                scope: parsed.scope,
                query: String(parsed.query),
                didSwitchScope: parsed.didSwitchScope
            )
        }
    }

    static func scopeIsLive(_ scope: PaletteScope) -> Bool {
        CorePalette.isLive(scope)
    }

    // The find scope's query mini-language ("re " = regex, "\re " escapes it).
    static func parseFindQuery(_ text: String) -> (pattern: String, isRegex: Bool) {
        text.withCxxStringView { view in
            let parsed = CorePalette.Engine.parseFindQuery(view)
            return (String(parsed.pattern), parsed.isRegex)
        }
    }
}

// MARK: - Registry (dedup owner is Core; only merged ids come back)

enum PaletteRegistry {
    // Register each provider's commands in order, then read the merged identifier
    // list — deduped by (title, identity) with earlier providers winning.
    static func mergedIdentifiers(_ providerCommands: [[BeamCommand]]) -> [String] {
        var registry = CorePalette.PaletteRegistry()
        for commands in providerCommands {
            registry.addCommands(coreCommandList(commands))
        }
        return registry.commands().map { String($0.id) }
    }
}

// MARK: - Settings number formatting

enum PaletteSettings {
    static func formatNumber(_ value: Double, step: Double) -> String {
        String(CorePalette.Settings.formatNumber(value, step))
    }

    static func sliderStep(from low: Double, to high: Double) -> Double {
        CorePalette.Settings.sliderStep(low, high)
    }

    static func valuePreview(_ value: Double, step: Double, unit: String) -> String {
        unit.withCxxStringView { view in
            String(CorePalette.Settings.valuePreview(value, step, view))
        }
    }

    static func rangeHint(from low: Double, to high: Double, step: Double, unit: String) -> String {
        unit.withCxxStringView { view in
            String(CorePalette.Settings.rangeHint(low, high, step, view))
        }
    }
}

// MARK: - Frecency

enum PaletteFrecency {
    static var maxStampsPerCommand: Int { Int(CorePalette.maxFrecencyStampsPerID) }

    // The decayed score of a command's use history at `now` (seconds).
    static func score(timestamps: [Int64], now: Int64) -> Double {
        var history = CorePalette.UsageHistory()
        for stamp in timestamps {
            history.timestamps.push_back(stamp)
        }
        return CorePalette.frecencyScore(history, now)
    }
}
