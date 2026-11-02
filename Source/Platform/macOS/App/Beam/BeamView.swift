// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// BeamView.swift — Beam's chrome: the input field (AppKit, for caret +
// key routing), the SwiftUI card/list/rows, and the host view that owns
// the cursor while Beam is shown. System font on live theme colors.
//

import AppKit
import SwiftUI
import UbiquittyCore

// MARK: - Palette

// The live theme's surface, plus the terminal's own font. Colors arrive from
// the renderer (foreground/background/cursor + an ANSI accent) so Beam matches
// the terminal accent while native materials own the hierarchy of UI ink.
struct BeamPalette {
    let foreground: Color
    let background: Color
    let accent: Color
    let caret: NSColor
    let isDark: Bool
}

// Beam is CHROME (a tool), not terminal content — so it wears the SYSTEM UI font,
// like Spotlight / Raycast / Linear ⌘K. Only the COLORS come from the terminal
// theme; the typeface is native. (The terminal grid itself stays JetBrains Mono.)
@MainActor
enum BeamFont {
    // The mono family Beam wears when [appearance] beam_terminal_font is on;
    // nil = the system UI font. Resolved once per summon
    // (BeamController.present) — the SHIPPED default lives in Core
    // (Settings Defaults::beamTerminalFont), one line to flip.
    private static var terminalFamily: String?

    static func configure(terminalFamily family: String?) {
        terminalFamily = family
    }

    private static func resolved(size: CGFloat, weight: Font.Weight) -> Font {
        guard let family = terminalFamily else { return .system(size: size, weight: weight) }
        return Font.custom(family, size: size).weight(weight)
    }

    static var inputAppKit: NSFont { // query line (AppKit field)
        guard let family = terminalFamily, let font = NSFont(name: family, size: 16) else {
            return NSFont.systemFont(ofSize: 16, weight: .regular)
        }
        return font
    }

    static var labelAppKit: NSFont { // row metrics (see rowHeight)
        guard let family = terminalFamily, let font = NSFont(name: family, size: 13.5) else {
            return NSFont.systemFont(ofSize: 13.5, weight: .regular)
        }
        return font
    }

    static var label: Font { resolved(size: 13.5, weight: .regular) } // command rows
    static var labelMatch: Font { resolved(size: 13.5, weight: .semibold) } // matched run
    static var detail: Font { resolved(size: 12, weight: .regular) } // path / shortcut
    static var scope: Font { resolved(size: 15, weight: .semibold) } // the "›" mark
}

// MARK: - Input field (AppKit, for caret + key routing on macOS 13)

// A borderless field in the system font with a theme-accent caret. Routes
// arrows / Enter / Esc to the model through doCommandBySelector so the palette
// navigates while the field keeps focus (macOS 13 has no SwiftUI .onKeyPress).
final class BeamTextField: NSTextField {
    var caretColor: NSColor = .textColor
    var onTextChange: ((String) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = caretColor
            // NSTextField selects all on focus; collapse the selection to the END
            // so even a redundant re-focus can't replace what the user just typed
            // (that ate the first character). Typing always appends.
            let end = (editor.string as NSString).length
            editor.selectedRange = NSRange(location: end, length: 0)
        }
        return ok
    }

    // The field editor calls this on every edit. Overriding it directly is more
    // reliable than the NSTextFieldDelegate when the field lives inside an
    // NSHostingView, so the query never goes stale (which left "100%" selected).
    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?(stringValue)
    }

    // The SINGLE focus path: pull first responder to the field once it enters
    // the window, so Beam owns the keyboard. A subview is not first responder
    // merely by being added. Guarded so re-entry never re-focuses (a redundant
    // makeFirstResponder re-selected the text and ate the first typed char).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let window = self.window else { return }
            if window.firstResponder === self || window.firstResponder === self.currentEditor() {
                return // already focused — do not re-focus
            }
            window.makeFirstResponder(self)
        }
    }
}

struct BeamInputField: NSViewRepresentable {
    @ObservedObject
    var model: BeamModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> BeamTextField {
        let field = BeamTextField()
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = BeamFont.inputAppKit
        field.textColor = .labelColor
        field.caretColor = model.palette.caret
        field.delegate = context.coordinator
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.allowsEditingTextAttributes = false
        // The SOLE query path: the field reports its text on every edit, and
        // handleFieldInput recognizes a leading scope prefix. It must fire exactly
        // once per edit — the delegate's controlTextDidChange is not
        // wired to it, because a second call for the same edit would arrive after
        // the prefix was stripped (scope already switched, field still reading the
        // prefix) and re-insert it into the query. textDidChange is the reliable
        // path inside an NSHostingView (the delegate can go stale), so it stands
        // alone.
        field.onTextChange = { [weak model] text in model?.handleFieldInput(text) }
        return field
    }

    func updateNSView(_ field: BeamTextField, context: Context) {
        // Focus is the field's single viewDidMoveToWindow path, and re-writing
        // stringValue on a bare SwiftUI update would fight the user's typing — so
        // push text only on a bumped sync token (the model entering / leaving a
        // drill), then place the caret (select-all when prefilling a value so
        // typing replaces it; otherwise collapse to the end).
        if context.coordinator.lastSyncToken != model.fieldSyncToken {
            context.coordinator.lastSyncToken = model.fieldSyncToken
            // A click on the breadcrumb / a row may have moved first responder off
            // the field; re-grab it so the keyboard keeps driving the palette.
            if let window = field.window,
                window.firstResponder !== field,
                window.firstResponder !== field.currentEditor()
            {
                window.makeFirstResponder(field)
            }
            if field.stringValue != model.fieldText {
                field.stringValue = model.fieldText
            }
            if let editor = field.currentEditor() {
                let length = (editor.string as NSString).length
                editor.selectedRange =
                    model.fieldSelectAll
                    ? NSRange(location: 0, length: length)
                    : NSRange(location: length, length: 0)
            }
        }
        field.placeholderString = model.fieldPlaceholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: BeamModel
        var lastSyncToken = 0 // matches model.fieldSyncToken's initial value
        init(model: BeamModel) { self.model = model }

        // controlTextDidChange is not implemented — text edits
        // flow only through BeamTextField.textDidChange → onTextChange, so a scope
        // prefix strips exactly once. Adding it back double-fires each edit.

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                return model.handleArrow(up: true)
            case #selector(NSResponder.moveDown(_:)):
                return model.handleArrow(up: false)
            case #selector(NSResponder.insertNewline(_:)):
                // ⌘⏎ opens the selected row's secondary actions (Raycast); a
                // plain ⏎ runs the row. ⌘⏎ falls through to submit when the
                // row has no secondary actions.
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true,
                    model.enterRowActions()
                {
                    return true
                }
                model.submit()
                return true
            case #selector(NSResponder.moveRight(_:)):
                // → opens secondary actions only when the caret is at the end of
                // the field (nothing to the right to move onto) and the row has
                // them; otherwise it's an ordinary caret move.
                let caret = textView.selectedRange()
                let atEnd =
                    caret.length == 0
                    && caret.location == (textView.string as NSString).length
                return atEnd && model.enterRowActions()
            case #selector(NSResponder.cancelOperation(_:)):
                model.cancel()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                // Consumed only when it steps a sub-scope back to actions; else
                // the field deletes a character as usual.
                return model.handleDeleteBackward()
            // Long lists (find returns up to 200 rows) page and jump like any
            // list: PgUp/PgDn step by a screenful, Home/End take the edges.
            // Tab/⇧Tab step the selection (the field is the only focusable, so
            // Tab has no traversal job here).
            case #selector(NSResponder.scrollPageUp(_:)):
                model.moveSelection(-BeamModel.selectionPageStep)
                return true
            case #selector(NSResponder.scrollPageDown(_:)):
                model.moveSelection(BeamModel.selectionPageStep)
                return true
            case #selector(NSResponder.moveToBeginningOfDocument(_:)),
                #selector(NSResponder.scrollToBeginningOfDocument(_:)):
                model.selectFirst()
                return true
            case #selector(NSResponder.moveToEndOfDocument(_:)),
                #selector(NSResponder.scrollToEndOfDocument(_:)):
                model.selectLast()
                return true
            case #selector(NSResponder.insertTab(_:)):
                model.moveSelection(1)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                model.moveSelection(-1)
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Views

// The results area's frame in SwiftUI global space — published up from the
// ScrollView so hover can be confined to it (a pointer over the scrim or
// off-window can't highlight a row).
private struct BeamResultsFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct BeamView: View {
    @ObservedObject
    var model: BeamModel
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @State
    private var appeared = false

    // The list shows at least this many rows before scrolling (also the span the
    // Ctrl+1–9 quick-select covers). It's a MAX, not a fixed height — a shorter
    // list stays short.
    private static let minVisibleRows = 9

    // BeamRow's single-line height at BeamFont.label — a FIXED system-font size
    // Derived from the RESOLVED row font (system, or the terminal family when
    // beam_terminal_font is on) so the fixed row math stays exact from frame
    // one; no live measurement, no post-appear resize.
    fileprivate static var rowHeight: CGFloat {
        let font = BeamFont.labelAppKit
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return lineHeight + 14 // BeamRow's 7pt top + 7pt bottom padding
    }

    private var palette: BeamPalette { model.palette }

    // Cap the results list at `minVisibleRows` rows: that many row heights, the
    // gaps between them (LazyVStack spacing 2), and the ScrollView's content
    // inset (padding 8, both sides). Content shorter than the cap stays short
    // (it's a maxHeight).
    private var listMaxHeight: CGFloat {
        let rows = CGFloat(Self.minVisibleRows)
        let spacing: CGFloat = 2
        let contentInset: CGFloat = 8 * 2
        return rows * Self.rowHeight + (rows - 1) * spacing + contentInset
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Only a FAINT dim for focus — the glass material does the real
            // separation. A tap outside the card dismisses.
            Color.black
                .opacity(appeared ? 0.14 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.dismiss() }

            // Scaling the embedded native scroll view changes its initial clip origin.
            card
                .opacity(appeared ? 1 : 0)
                .padding(.top, 92)
        }
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.10)) { appeared = true }
            }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            inputRow
            cardBody
            scopeHintFooter
        }
        .frame(width: 580)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(palette.foreground.opacity(palette.isDark ? 0.14 : 0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: .black.opacity(0.40), radius: 28, x: 0, y: 16)
    }

    // A number/text drill shows a hint (no list); otherwise the result list, or
    // an empty note once the query/filter has no matches.
    @ViewBuilder
    private var cardBody: some View {
        if model.isEditorDrill {
            hairline
            editorHintRow
        } else if !model.results.isEmpty {
            hairline
            resultsList
        } else if let note = model.emptyNote {
            emptyRow(note)
        }
    }

    // A quiet one-line hint teaching the scope prefixes — shown only in the
    // actions scope (a sub-scope's breadcrumb already names it, and a drill is
    // mid-edit). The prefix char rides in the accent, its label in the dim
    // foreground; low contrast, below the results, a teach not a toolbar.
    @ViewBuilder
    private var scopeHintFooter: some View {
        if let status = model.findStatus {
            hairline
            HStack {
                Text(status)
                    .font(BeamFont.detail)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        } else if model.scope == .Actions, model.drill == nil {
            hairline
            HStack(spacing: 16) {
                scopeHint("@", "blocks")
                scopeHint("/", "find")
                scopeHint(":", "go to")
                scopeHint("#", "settings")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private func scopeHint(_ prefix: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(prefix)
                .font(BeamFont.detail)
                .foregroundColor(palette.accent.opacity(0.85))
            Text(label)
                .font(BeamFont.detail)
                .foregroundStyle(.tertiary)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(palette.foreground.opacity(0.10))
            .frame(height: 1)
    }

    // Under a number editor: the allowed range on the left, the apply/cancel keys
    // on the right. The current value sits in the prefilled field above.
    private var editorHintRow: some View {
        HStack(spacing: 12) {
            if !model.editorRangeHint.isEmpty {
                Text(model.editorRangeHint)
                    .font(BeamFont.detail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text("↩ apply   ⎋ cancel")
                .font(BeamFont.detail)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            scopeIndicator
            BeamInputField(model: model)
                .frame(height: 26)
            if model.scope == .Find, model.drill == nil, model.findLastBlockAvailable {
                lastOutputChip
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // Find-only: cycles the search between the whole scrollback and just the
    // newest command's output. The active ("Last output") state rides the
    // accent; the default (whole scrollback) is dim.
    private var lastOutputChip: some View {
        let on = model.findScopedToLastBlock
        return Button {
            model.toggleFindBlockScope()
        } label: {
            Text(on ? "Last output" : "Scrollback")
                .font(BeamFont.detail)
                .foregroundStyle(on ? AnyShapeStyle(palette.accent) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            (on ? palette.accent : palette.foreground)
                                .opacity(on ? 0.5 : 0.20),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help("Search only the last command’s output")
    }

    // The leading mark: a bare accent › for the actions scope; a "‹ <scope>"
    // chip in the accent for a terminal scope (find / blocks / go to / settings),
    // whose ‹ (or Esc) steps back to actions; or a "‹ <Setting>" breadcrumb when
    // drilled into a settings editor. Drill wins (it sits inside a scope).
    // One back-chip shape for both the drill breadcrumb and a scope chip:
    // accent ‹ plus a one-line label; the action steps one level back.
    private func backChip(
        _ label: String,
        tint: AnyShapeStyle,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(BeamFont.scope)
                    .foregroundColor(palette.accent)
                Text(label)
                    .font(BeamFont.detail)
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            .frame(height: 26)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var scopeIndicator: some View {
        if let drill = model.drill {
            backChip(
                drill.title,
                tint: AnyShapeStyle(.secondary),
                help: "Back to commands"
            ) { model.exitDrill() }
        } else if model.scope != .Actions {
            backChip(
                model.scope.chipLabel,
                tint: AnyShapeStyle(palette.accent),
                help: "Back to actions"
            ) { model.resetToActions() }
        } else {
            Image(systemName: "chevron.right")
                .font(BeamFont.scope)
                .foregroundColor(palette.accent)
                .frame(width: 16, height: 26)
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        Button {
                            // Click anywhere on the row runs / drills it (a value
                            // applies and steps back; never dismisses mid-drill).
                            model.clickRow(index)
                        } label: {
                            BeamRow(
                                result: result,
                                selected: index == model.selectedIndex,
                                quickSelectDigit: index < 9 ? index + 1 : nil,
                                palette: palette
                            )
                        }
                        .buttonStyle(.plain)
                        // Hover moves the shared highlight here (no scroll).
                        .onContinuousHover(coordinateSpace: .global) { phase in
                            if case .active(let location) = phase {
                                model.hover(index: index, at: location)
                            }
                        }
                        .id(result.id) // STABLE per-command id (matches ForEach identity + scroll target)
                    }
                }
                .padding(8)
                .id("beam-results-top")
            }
            .frame(maxHeight: listMaxHeight)
            // Publish the results area's global frame so hover is confined to it
            // (a pointer over the scrim / off-window can't highlight a row). Same
            // global space the row hover reports use, so contains() is apples-to-apples.
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: BeamResultsFrameKey.self,
                        value: geometry.frame(in: .global)
                    )
                }
            )
            .onPreferenceChange(BeamResultsFrameKey.self) { model.hoverBounds = $0 }
            // Scroll only on the keyboard/query token — never on a bare selection
            // change — so hover highlights without scrolling the list.
            .onChangeCompatibility(of: model.scrollToken) {
                guard model.results.indices.contains(model.selectedIndex) else { return }
                let identifier = model.results[model.selectedIndex].id
                if model.selectedIndex == 0 {
                    proxy.scrollTo("beam-results-top", anchor: .top)
                } else if reduceMotion {
                    proxy.scrollTo(identifier, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.10)) {
                        proxy.scrollTo(identifier, anchor: .center)
                    }
                }
            }
            // VoiceOver: speak the row the user arrowed onto. Only on explicit
            // keyboard moves (selectionAnnounceToken, not the query refresh) so
            // typing isn't narrated per keystroke, and only when VO is running.
            .onChangeCompatibility(of: model.selectionAnnounceToken) {
                guard NSWorkspace.shared.isVoiceOverEnabled,
                    let announcement = model.selectionAnnouncement
                else { return }
                Self.announce(announcement)
            }
        }
    }

    // Post a VoiceOver announcement (macOS 14+ uses the typed API; 13 uses the
    // NSAccessibility notification with an explicit priority).
    private static func announce(_ text: String) {
        if #available(macOS 14.0, *) {
            var announcement = AttributedString(text)
            announcement.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(announcement).post()
        } else {
            NSAccessibility.post(
                element: NSApp.mainWindow as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: text,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }

    private func emptyRow(_ note: String) -> some View {
        Text(note)
            .font(BeamFont.label)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
    }
}

private struct BeamRow: View {
    let result: BeamResult
    let selected: Bool
    // 1…9 for the first nine rows (Ctrl+n quick-select), nil past that — a dim
    // badge teaching the shortcut inline rather than a separate legend.
    let quickSelectDigit: Int?
    let palette: BeamPalette

    var body: some View {
        HStack(spacing: 12) {
            // Leading check gutter for an options drill: a ✓ on the current value,
            // an empty gutter on the rest so every label aligns. Commands have none.
            if result.checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.accent)
                    .frame(width: 14)
            } else if result.isOption {
                Color.clear.frame(width: 14)
            }

            highlightedTitle
                .lineLimit(1)

            Spacer(minLength: 12)

            if !result.group.isEmpty {
                Text(result.group)
                    .font(BeamFont.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // The live setting value, previewed before the disclosure.
            if !result.value.isEmpty {
                Text(result.value)
                    .font(BeamFont.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !result.shortcut.isEmpty {
                Text(result.shortcut)
                    .font(BeamFont.detail)
                    .foregroundStyle(.secondary)
            } else if let digit = quickSelectDigit {
                // Only when the row has no shortcut of its own — showing both
                // would read as two competing bindings for the same row.
                Text("⌃\(digit)")
                    .font(BeamFont.detail)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true) // decorative; VO reads the row label
            }
            // The selected row's "more actions" hint (→ / ⌘⏎ open them). Only
            // the selected row shows it — an all-rows badge would be noise.
            if result.hasSecondaryActions, selected {
                Text("⌘⏎")
                    .font(BeamFont.detail)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            // Disclosure for a drill command — selecting it opens a value editor.
            if result.drillable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: BeamView.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading) // fill the row width
        // Neutral elevation from the theme FOREGROUND (not the accent): reads as
        // a crisp lift that reads on any theme. The accent is reserved for
        // semantic accent only — the matched chars, the scope glyph, the ✓.
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(selected ? 0.25 : 0))
        )
        .contentShape(Rectangle()) // the WHOLE row (incl. the blank middle) is clickable
        // VoiceOver: one element per row (title + group + value read together),
        // with the arrow-driven highlight surfaced as selection — without this
        // the selection is invisible to VO (focus never leaves the field).
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // The label in the SYSTEM font, with matched query characters carried in the
    // theme accent and rendered semibold (the only emphasis — not monospace bold).
    // matchedIndices are Unicode-SCALAR ordinals (Core's FuzzyMatcher decodes
    // UTF-8 to code points), but the pieces stay GRAPHEME-atomic: a cluster is
    // highlighted when any of its scalars matched. Per-scalar pieces would split
    // base + combining mark across attribute runs and break shaping; naive
    // per-Character indexing shifts the highlight after any multi-scalar cluster.
    private var highlightedTitle: Text {
        var attributed = AttributedString()
        var scalarOffset = 0
        var runText = ""
        var runMatched = false
        func flush() {
            guard !runText.isEmpty else { return }
            var piece = AttributedString(runText)
            piece.font = runMatched ? BeamFont.labelMatch : BeamFont.label
            if runMatched { piece.foregroundColor = palette.accent }
            attributed.append(piece)
        }
        // Coalesce same-attribute runs: match indices are contiguous ranges in
        // practice (tiers 1-3 always, tier 4 mostly), so a title becomes 2-3
        // pieces instead of one AttributedString append per character.
        for character in result.title {
            let scalarCount = character.unicodeScalars.count
            let matched = (scalarOffset..<(scalarOffset + scalarCount))
                .contains { result.matchedIndices.contains($0) }
            if matched != runMatched {
                flush()
                runText = ""
                runMatched = matched
            }
            runText.append(character)
            scalarOffset += scalarCount
        }
        flush()
        return Text(attributed)
    }
}

// MARK: - Host view (owns the cursor while Beam is shown)

// The full-window overlay container. It forces the ARROW pointer over the scrim
// and card (the terminal's I-beam cursor rect sits below and must not bleed
// through); the embedded text field keeps its own I-beam within its bounds.
final class BeamHostView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .inVisibleRect, .cursorUpdate],
                owner: self,
                userInfo: nil
            )
        )
    }
}
