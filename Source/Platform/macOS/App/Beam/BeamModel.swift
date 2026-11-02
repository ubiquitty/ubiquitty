// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// BeamModel.swift — the palette's state machine: scopes, sources, the
// ranked results, drills, and submit routing. The Core engine ranks;
// this dispatches by id.
//

import AppKit
import SwiftUI
import UbiquittyCore

// MARK: - Scopes

// A leading prefix retargets Beam at a different source. The default (no prefix)
// is the action registry; the rest are terminal-aware. Typing the prefix as the
// first character switches scope — the chip updates in the accent and the prefix
// is stripped from the query; deleting back past it returns to actions.
// The prefix parse/strip, availability, and the live / order flags live in the
// Core CommandPalette engine; this enum is the presentation face (chip +
// The per-scope command sources. Actions and settings start with searchable
// placeholders for installed-font pickers; the complete lists are built only
// when a query reaches one. Go-to and blocks snapshot their live state when
// entered; find runs per query.
struct BeamSources {
    let actions: [BeamCommand]
    let settings: [BeamCommand]
    let goTo: () -> [BeamCommand]
    let blocks: () -> [BeamCommand]
    let find: (_ query: String, _ scopeToLastBlock: Bool) -> [BeamCommand]
    // Whether the focused terminal has an OSC-133 command block to scope find
    // to — gates the "Last output" chip (no blocks = whole-scrollback only).
    let findLastBlockAvailable: () -> Bool
    let terminalScopesAvailable: Bool
    var findStatusText: () -> String? = { nil }
    var loadCompleteCommands: @MainActor () -> (actions: [BeamCommand], settings: [BeamCommand]) = { ([], []) }
}

// MARK: - Model

// One rendered list row — a filtered command (the list level) or a value (an
// options drill). `payload` carries the source for submit routing.
struct BeamResult: Identifiable {
    let id: UUID
    let title: String // matched + highlighted
    let group: String // dim right label (commands)
    let shortcut: String // ⌘ glyphs (commands)
    let value: String // live value preview (drill commands)
    let drillable: Bool // shows a › disclosure
    let checked: Bool // ✓ current value (options drill)
    let matchedIndices: IndexSet
    let payload: Payload

    enum Payload {
        case command(BeamCommand)
        case option(BeamOption)
    }

    // Options reserve a leading check gutter so labels align; commands don't.
    var isOption: Bool {
        if case .option = payload { return true }
        return false
    }

    // A command row with Raycast-style secondary actions (→ / ⌘⏎). Drives the
    // "⌘⏎" affordance on the selected row.
    var hasSecondaryActions: Bool {
        if case .command(let command) = payload { return !command.secondaryActions.isEmpty }
        return false
    }
}

@MainActor
final class BeamModel: ObservableObject {
    // The active drill, or nil at the command list. Selecting a drill command
    // enters it; Esc or the breadcrumb's back affordance returns here without
    // dismissing Beam.
    struct ActiveDrill {
        let title: String
        let kind: BeamDrill
    }

    // While a number/text drill is open, `query` is the VALUE being edited, not
    // a filter. No didSet-refresh: handleFieldInput guards its two independent
    // field-update paths itself, and setField() refreshes unconditionally — one
    // refresh per transition, never zero (a same-value didSet skip once left
    // drills showing the previous list) and never two.
    @Published
    var query: String = ""
    @Published
    private(set) var results: [BeamResult] = []
    @Published
    var selectedIndex: Int = 0

    // Bumped only when the selection moves by KEYBOARD (or the query changes);
    // the list scrolls on this token, never on a bare selectedIndex change — so
    // hover-driven selection highlights without scrolling and can't feed the
    // scroll⇄hover loop.
    @Published
    private(set) var scrollToken: Int = 0

    // Bumped only on an explicit keyboard selection move (arrows / paging /
    // Home-End) — not on a query-driven refresh — so VoiceOver announces the
    // row the user stepped onto without narrating every keystroke's top match.
    @Published
    private(set) var selectionAnnounceToken: Int = 0

    @Published
    private(set) var drill: ActiveDrill?

    // The find scope's count and progress, independent of its bounded row list.
    // Nil outside find or for an empty query.
    @Published
    private(set) var findStatus: String?

    // Find scope: whether the search is scoped to the newest command block's
    // output ("Last output") vs the whole scrollback. The chip toggles it;
    // entering find fresh resets it to false.
    @Published
    private(set) var findScopedToLastBlock = false

    // Whether the "Last output" chip should show — find scope with a resolvable
    // command block. Read by the view.
    var findLastBlockAvailable: Bool { sources.findLastBlockAvailable() }

    // Programmatic field text: bumping the token pushes `fieldText` into the
    // NSTextField (entering a drill prefills it, leaving restores the filter);
    // `fieldSelectAll` selects the prefilled value so typing replaces it.
    @Published
    private(set) var fieldText: String = ""
    @Published
    private(set) var fieldSyncToken: Int = 0
    @Published
    private(set) var fieldSelectAll: Bool = false

    // Last pointer location (GLOBAL space) at which a hover was honored. Used to
    // ignore hover re-entries caused by the list scrolling under a stationary
    // pointer, which report the same point.
    private var lastHoverLocation: CGPoint?

    // The results area's frame in the same global space the hover reports use.
    // Hover only moves the selection when the pointer is physically inside it, so
    // a hover report over the scrim or off-window can't drive the highlight. Plain
    // state (not @Published) — the view writes it from a geometry read; reading it
    // in hover() must not republish. .zero (default) admits nothing until measured.
    var hoverBounds: CGRect = .zero

    // The command-list filter, saved on drill-in and restored on drill-out.
    private var savedListQuery: String = ""

    private static let perflogEnabled =
        ProcessInfo.processInfo.environment["UBIQUITTY_PERFLOG"] != nil

    let palette: BeamPalette
    private let sources: BeamSources

    // The active scope and its current static command list (actions / settings /
    // go-to / blocks). The find scope is live — driven per query — and leaves
    // this empty. The chip shows the scope; a prefix switches it.
    @Published
    private(set) var scope: PaletteScope = .Actions
    private var scopeCommands: [BeamCommand]
    private var completeActions: [BeamCommand]?
    private var completeSettings: [BeamCommand]?

    // The portable Core pipeline: it holds the active scope's command set and
    // ranks it per query. Swift keeps the closure-bearing commands keyed by the
    // engine's stable id so a ranked result routes back to its effect.
    private let engine = PaletteEngine()
    private var commandsByID: [String: BeamCommand] = [:]

    // Tears down the overlay + restores the terminal's first responder.
    var onDismiss: () -> Void = {}

    // Drops the terminal's live find highlight when the find scope is torn down
    // (back to actions, or Beam closing) so it never outlives the palette.
    var onExitFindScope: () -> Void = {}

    init(palette: BeamPalette, sources: BeamSources) {
        self.palette = palette
        self.sources = sources
        self.scopeCommands = sources.actions
        engine.setUsageScores(BeamUsageStore.scores()) // one decay pass per summon
        activateScopeCommands()
        refresh()
    }

    // Feed the active scope's command set to the engine and index it by id for
    // result → command dispatch. Called on every scope entry.
    private func activateScopeCommands() {
        commandsByID = Dictionary(
            scopeCommands.map { ($0.paletteID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        engine.setActive(scope: scope, commands: scopeCommands)
    }

    private func loadCompleteCommands(activateCurrentScope: Bool = true) {
        guard completeActions == nil else { return }
        let complete = sources.loadCompleteCommands()
        guard !complete.actions.isEmpty else { return }
        completeActions = complete.actions
        completeSettings = complete.settings
        guard activateCurrentScope else { return }
        switch scope {
        case .Actions: scopeCommands = complete.actions
        case .Settings: scopeCommands = complete.settings
        case .GoTo, .Blocks, .Find: return
        }
        activateScopeCommands()
    }

    // MARK: drill state queries (for the view)

    // A number or text editor (the field is the value; no list, just a hint).
    var isEditorDrill: Bool {
        guard let kind = drill?.kind else { return false }
        switch kind {
        case .number, .text: return true
        case .options: return false
        }
    }

    // The dim range hint under a number editor ("1.0–3.0 lines"); empty otherwise.
    var editorRangeHint: String {
        guard let kind = drill?.kind, case .number(_, let lo, let hi, let step, let unit, _) = kind else {
            return ""
        }
        return PaletteSettings.rangeHint(from: lo, to: hi, step: step, unit: unit)
    }

    var fieldPlaceholder: String {
        guard let kind = drill?.kind else { return scope.placeholder }
        switch kind {
        case .options: return "Filter values…"
        case .number(_, _, _, _, let unit, _):
            return unit.isEmpty ? "Enter a value" : "Enter a value (\(unit))"
        case .text(_, let placeholder, _): return placeholder
        }
    }

    // The note shown when there are no result rows. nil means show nothing — an
    // empty find query waiting for input, or a fresh actions/settings filter.
    var emptyNote: String? {
        guard results.isEmpty, !isEditorDrill else { return nil }
        if drill != nil { return query.isEmpty ? nil : "No matching values" }
        switch scope {
        case .Find:
            return query.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : "No matches in scrollback"
        case .Blocks:
            return scopeCommands.isEmpty
                ? "Command blocks appear once shell integration is installed. Choose Ubiquitty ▸ Install Shell Integration."
                : "No matching blocks"
        case .GoTo:
            return scopeCommands.isEmpty
                ? "Open a tab (⌘T) or split a pane (⌘D) to jump between them here."
                : "No matching destinations"
        case .Settings:
            return query.isEmpty ? nil : "No matching settings"
        case .Actions:
            return query.isEmpty ? nil : "No matching commands"
        }
    }

    // MARK: refresh + ranking

    /// Refreshes available find rows while preserving the current selection.
    func refreshSearchPublication() {
        guard scope == .Find, drill == nil else { return }
        refreshFindResults()
    }

    private func refreshFindResults() {
        results = sources.find(query, findScopedToLastBlock).map { Self.row(for: $0, matchedIndices: []) }
        selectedIndex = min(selectedIndex, max(0, results.count - 1))
        findStatus =
            query.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil
            : sources.findStatusText() ?? String(Ubiquitty.Runtime.searchCounterText(results.count, -1, false, true))
    }

    private func refresh() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if scope != .Find { findStatus = nil }
        if let kind = drill?.kind {
            switch kind {
            case .options(let current, let options):
                results = rankedOptions(options, current: current, query: trimmed)
                selectedIndex =
                    trimmed.isEmpty
                    ? (results.firstIndex { $0.checked } ?? 0)
                    : 0
            case .number, .text:
                results = [] // editor mode: the field is the value, no list
                selectedIndex = 0
            }
        } else if PaletteEngine.scopeIsLive(scope) {
            selectedIndex = 0
            refreshFindResults()
        } else {
            // The Core engine ranks the active scope's command set (empty query →
            // all rows in the scope's order); map each ranked id back to its
            // closure-bearing command for the row + submit routing. Feed the
            // Swift-trimmed query so Unicode whitespace (e.g. Option-Space) is
            // stripped the same way the empty-query gate above sees it.
            var ranked = engine.rankedResults(trimmed)
            // A matching deferred picker needs its real options. An otherwise
            // empty result may still name an installed font family from the
            // lazy View menu, so resolve that catalog before saying no match.
            if completeActions == nil && !trimmed.isEmpty
                && (ranked.isEmpty || ranked.contains { commandsByID[$0.identifier]?.isDeferred == true })
            {
                loadCompleteCommands()
                ranked = engine.rankedResults(trimmed)
            }
            results = ranked.compactMap { result in
                commandsByID[result.identifier]
                    .map { Self.row(for: $0, matchedIndices: result.matchedIndices) }
            }
            if results.isEmpty {
                selectedIndex = 0
            } else if trimmed.isEmpty {
                selectedIndex = min(max(selectedIndex, 0), results.count - 1)
            } else {
                selectedIndex = 0 // a query always re-selects the top match
            }
        }
        scrollToken &+= 1 // a new result set scrolls the top match into view
    }

    // The options drill's value list, ranked by the engine (empty query → natural
    // order). Each ranked result carries its ORIGINAL option index as its id, so
    // the row routes back to the option that owns the apply closure.
    private func rankedOptions(_ options: [BeamOption], current: Int, query: String) -> [BeamResult] {
        let ranked = engine.rankedOptions(
            query,
            options: options.map { $0.label },
            current: current
        )
        return ranked.compactMap { result -> BeamResult? in
            guard let index = Int(result.identifier), options.indices.contains(index) else {
                return nil
            }
            let option = options[index]
            return BeamResult(
                id: option.id,
                title: option.label,
                group: "",
                shortcut: "",
                value: "",
                drillable: false,
                checked: result.checked,
                matchedIndices: result.matchedIndices,
                payload: .option(option)
            )
        }
    }

    private static func row(for command: BeamCommand, matchedIndices: IndexSet) -> BeamResult {
        BeamResult(
            id: command.id,
            title: command.title,
            group: command.group,
            shortcut: command.shortcut,
            value: command.value,
            drillable: command.isDrill,
            checked: false,
            matchedIndices: matchedIndices,
            payload: .command(command)
        )
    }

    // MARK: navigation

    // Vertical arrows: step a number drill, move the list/options selection, or
    // (text drill) defer to the field so the caret moves. Returns whether handled.
    func handleArrow(up: Bool) -> Bool {
        guard let kind = drill?.kind else {
            moveSelection(up ? -1 : 1)
            return true
        }
        switch kind {
        case .number:
            stepNumber(up: up)
            return true
        case .text: return false // free-text entry: let the field move the caret
        case .options:
            moveSelection(up ? -1 : 1)
            return true
        }
    }

    // Move the selection and scroll it into view (command list / options list).
    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
        scrollToken &+= 1
        selectionAnnounceToken &+= 1
    }

    // One PgUp/PgDn stride — the visible-row count the card shows.
    static let selectionPageStep = 8

    func selectFirst() {
        guard !results.isEmpty else { return }
        selectedIndex = 0
        scrollToken &+= 1
        selectionAnnounceToken &+= 1
    }

    func selectLast() {
        guard !results.isEmpty else { return }
        selectedIndex = results.count - 1
        scrollToken &+= 1
        selectionAnnounceToken &+= 1
    }

    // The VoiceOver announcement for the current selection: the row's title
    // plus its 1-based position, or nil when there's nothing selected.
    var selectionAnnouncement: String? {
        guard results.indices.contains(selectedIndex) else { return nil }
        return "\(results[selectedIndex].title), \(selectedIndex + 1) of \(results.count)"
    }

    private func stepNumber(up: Bool) {
        guard let kind = drill?.kind,
            case .number(let current, let minimum, let maximum, let step, _, _) = kind
        else { return }
        let base = Double(query.trimmingCharacters(in: .whitespaces)) ?? current
        let next = Swift.min(Swift.max(base + (up ? step : -step), minimum), maximum)
        setField(PaletteSettings.formatNumber(next, step: step), selectAll: false)
    }

    // Pointer hover: move the selection to the row without scrolling, so mouse and
    // keyboard share one highlight. Honored only when the pointer is physically
    // inside the results area and on REAL pointer movement:
    //   - Outside the results bounds (over the scrim, or off-window): ignored, and
    //     lastHoverLocation is left untouched so returning to a row still registers.
    //     onContinuousHover keeps reporting .active with the pointer's global point
    //     after it leaves a row (the scrim overlay swallows the .ended), so the
    //     bounds gate is what stops an outside pointer from driving the selection.
    //   - Same global point as last (the list scrolled under a stationary mouse):
    //     ignored, so scroll-under-mouse never steals keyboard selection.
    func hover(index: Int, at location: CGPoint) {
        guard hoverBounds.contains(location) else { return }
        if let last = lastHoverLocation,
            abs(last.x - location.x) < 0.5, abs(last.y - location.y) < 0.5
        {
            return
        }
        lastHoverLocation = location
        guard results.indices.contains(index), selectedIndex != index else { return }
        // The != guard matters: @Published republishes on every set, and
        // onContinuousHover fires per mouse-move — without it, wiggling the
        // pointer INSIDE one row re-diffs the whole results list at 60+ Hz.
        selectedIndex = index
    }

    // MARK: scope switching

    // The field's text changed. Outside a drill, the Core engine interprets the
    // text: from the actions scope a leading prefix (#/:/@//) retargets the scope
    // and is stripped exactly once; otherwise the text is the live query / filter
    // for the active scope. During a drill the field is the value being edited.
    func handleFieldInput(_ text: String) {
        // Same-value guard: the field's textDidChange override and its delegate
        // both deliver each edit — collapse them to one refresh per real change.
        guard drill == nil else {
            if query != text {
                query = text
                refresh()
            }
            return
        }
        let parsed = PaletteEngine.interpretInput(
            text,
            currentScope: scope,
            terminalAvailable: sources.terminalScopesAvailable
        )
        if parsed.didSwitchScope {
            enterScope(parsed.scope, query: parsed.query)
            return
        }
        if query != parsed.query {
            query = parsed.query
            refresh()
        }
    }

    // Backspace at the empty start of a sub-scope returns to actions; otherwise
    // the field deletes a character normally. Returns whether it was handled.
    func handleDeleteBackward() -> Bool {
        guard drill == nil, scope != .Actions, query.isEmpty else { return false }
        resetToActions()
        return true
    }

    // Toggle the find scope between whole-scrollback and the last block's
    // output, then enqueue the current query with its new scope.
    func toggleFindBlockScope() {
        guard scope == .Find else { return }
        findScopedToLastBlock.toggle()
        refresh()
    }

    private func enterScope(_ next: PaletteScope, query newQuery: String) {
        scope = next
        if next == .Settings { loadCompleteCommands(activateCurrentScope: false) }
        switch next {
        case .Actions: scopeCommands = completeActions ?? sources.actions
        case .Settings: scopeCommands = completeSettings ?? sources.settings
        case .GoTo: scopeCommands = sources.goTo()
        case .Blocks: scopeCommands = sources.blocks()
        case .Find: scopeCommands = [] // live per query
        }
        findScopedToLastBlock = false // any scope entry (incl. fresh find) = whole scrollback
        activateScopeCommands()
        // Selection restarts at the top before setField's refresh — the
        // empty-query branch PRESERVES the index, which is right within a
        // scope but wrong across one (row 5 of actions means nothing in
        // go-to). setField strips the prefix from the field and refreshes.
        selectedIndex = 0
        setField(newQuery, selectAll: false)
    }

    // Back to the actions scope (the chip's back affordance, Esc, or a
    // backspace past the prefix). Clears any find highlight first.
    func resetToActions() {
        guard scope != .Actions else { return }
        if scope == .Find { onExitFindScope() }
        enterScope(.Actions, query: "")
    }

    // MARK: submit / drill

    // Enter (or a click) COMMITS: applying a drill value is executing the command
    // (drill → set), so it dismisses Beam exactly like running one — the user is
    // returned to the terminal and sees the result, not the palette. Only drilling
    // into a command stays open; cancel/back (Esc, breadcrumb) is the nav stack.
    func submit() {
        guard let kind = drill?.kind else {
            invokeSelected()
            return
        }
        switch kind {
        case .options:
            guard results.indices.contains(selectedIndex),
                case .option(let option) = results[selectedIndex].payload
            else {
                exitDrill()
                return // nothing selected (filtered to empty): just step back
            }
            commit(option.apply)
        case .number(let current, let minimum, let maximum, _, _, let apply):
            let value = Double(query.trimmingCharacters(in: .whitespaces)) ?? current
            let clamped = Swift.min(Swift.max(value, minimum), maximum)
            commit { apply(clamped) }
        case .text(_, _, let apply):
            let text = query
            commit { apply(text) }
        }
    }

    // A click selects then submits the row (run/drill a command, or apply a value).
    func clickRow(_ index: Int) {
        selectedIndex = index
        submit()
    }

    // Ctrl+1…9 quick-select: run/apply the nth VISIBLE result immediately, same
    // effect as arrowing to it and pressing Return. Only meaningful over a
    // results list — a number/text editor drill shows no list, so it's a no-op
    // there (the key falls through to the field as ordinary input). Returns
    // whether it was consumed, so the field can decide whether to swallow the key.
    func quickSelect(_ index: Int) -> Bool {
        guard !isEditorDrill, results.indices.contains(index) else { return false }
        clickRow(index)
        return true
    }

    private func invokeSelected() {
        guard results.indices.contains(selectedIndex),
            case .command(let command) = results[selectedIndex].payload
        else {
            onDismiss()
            return
        }
        if command.isDeferred {
            loadCompleteCommands()
            refresh()
            guard
                let resolvedIndex = results.firstIndex(where: {
                    if case .command(let resolved) = $0.payload {
                        return resolved.paletteID == command.paletteID && !resolved.isDeferred
                    }
                    return false
                })
            else { return }
            selectedIndex = resolvedIndex
            invokeSelected()
            return
        }
        BeamUsageStore.record(command.paletteID) // frecency: a run or a drill is a use
        switch command.action {
        case .run(let run):
            if command.needsConfirm {
                commitWithConfirm(title: command.title, run)
            } else {
                commit(run)
            }
        case .drill:
            enterDrill(command)
        }
    }

    // → or ⌘⏎ on a row with secondary actions: drill into that row's actions
    // list (Raycast-style), reusing the options-drill machinery. Returns
    // whether it was handled (so the field can swallow the key). No-op — key
    // falls through — for a row with no secondary actions or mid-drill.
    @discardableResult
    func enterRowActions() -> Bool {
        guard drill == nil, results.indices.contains(selectedIndex),
            case .command(let command) = results[selectedIndex].payload,
            !command.secondaryActions.isEmpty
        else { return false }
        savedListQuery = query
        selectedIndex = 0
        // current: -1 marks no checked row (Core check-marks only a valid
        // index); the applies run the effect, so a real command usage is
        // recorded at apply time, not here.
        drill = ActiveDrill(
            title: command.title,
            kind: .options(current: -1, options: command.secondaryActions)
        )
        setField("", selectAll: false)
        return true
    }

    // Commit an effect like any command: dismiss FIRST (restores the terminal as
    // first responder), then fire on the NEXT runloop so the responder chain is
    // settled — a menu command's run sends its action with the REAL NSMenuItem
    // sender, so actions that dispatch on sender.tag / sender.state still work.
    private func commit(_ effect: @escaping () -> Void) {
        onDismiss()
        DispatchQueue.main.async { effect() }
    }

    // Same as commit, but interposes a confirmation alert before firing —
    // A fuzzy match plus Enter can land on a command the typist never read,
    // which a menu click cannot, so a needsConfirm command (write/share/attach/
    // kick a live connection) gets one extra step naming what it will do, even
    // when its menu equivalent has none.
    // Dismiss first (same ordering as commit), then alert on the next runloop —
    // the alert must not compete with Beam's own window for key status.
    // Voice rules: the default button repeats the command's own verb (never a
    // generic "Confirm"/"OK"), and the body states when it takes effect.
    private func commitWithConfirm(title: String, _ effect: @escaping () -> Void) {
        onDismiss()
        DispatchQueue.main.async {
            // The default button carries only the command's own verb phrase —
            // the part before any ':' — never the target suffix: agent
            // commands embed the agent's self-reported label there, and
            // untrusted text on a destructive default button is a steering
            // vector ("Disconnect Agent: me — press Cancel to keep"). The
            // full title (target included) stays in the message line.
            var verb = title.hasSuffix("…") ? String(title.dropLast()) : title
            if let colon = verb.firstIndex(of: ":") {
                verb = String(verb[..<colon])
            }
            verb = verb.trimmingCharacters(in: .whitespaces)
            let alert = NSAlert()
            alert.messageText = "\(title.hasSuffix("…") ? String(title.dropLast()) : title)?"
            alert.informativeText = "This takes effect immediately."
            alert.alertStyle = .warning
            alert.addButton(withTitle: verb)
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                effect()
            }
        }
    }

    private func enterDrill(_ command: BeamCommand) {
        guard case .drill(let kind) = command.action else { return }
        savedListQuery = query
        drill = ActiveDrill(title: command.title, kind: kind)
        switch kind {
        case .options:
            setField("", selectAll: false) // filter fresh; all values show
        case .number(let current, _, _, let step, _, _):
            setField(PaletteSettings.formatNumber(current, step: step), selectAll: true)
        case .text(let current, _, _):
            setField(current, selectAll: true)
        }
    }

    // Back to the command list (the breadcrumb's ‹, or Esc) — never dismisses.
    func exitDrill() {
        guard drill != nil else { return }
        drill = nil
        // Reset the selection before setField's refresh: the empty-query
        // branch preserves the index, and an options-drill row index means
        // nothing in the restored command list (Enter would run the wrong
        // command).
        selectedIndex = 0
        setField(savedListQuery, selectAll: false)
    }

    // Esc: leave a drill, step a sub-scope back to actions, or (in the actions
    // list) dismiss Beam.
    func cancel() {
        if drill != nil { exitDrill() } else if scope != .Actions { resetToActions() } else { onDismiss() }
    }

    // Push text into the NSTextField (programmatic, so no textDidChange fires),
    // mirror it into `query`, and refresh — UNCONDITIONALLY. Every programmatic
    // transition (scope switch, drill enter/exit, number step) must recompute
    // even when the text is unchanged (empty → empty is the common case); a
    // same-value skip here once left drills showing the previous scope's list.
    private func setField(_ text: String, selectAll: Bool) {
        fieldText = text
        fieldSelectAll = selectAll
        fieldSyncToken &+= 1
        query = text
        refresh()
    }

    func dismiss() { onDismiss() }
}
