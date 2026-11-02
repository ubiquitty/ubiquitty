// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Observation
import SwiftUI
import UIKit
import UbiquittyCore

/// The terminal's keyboard: every keystroke reaches the shell as it is typed.
///
/// A text field would be the wrong shape. A terminal has no line to edit and no
/// point at which a line is committed — the shell echoes what it chooses, a
/// password echoes nothing, and Ctrl-C is not text at all. What this answers is
/// keystrokes, plus the one thing a keystroke is not: a composition, which an
/// input method builds over several keys before handing back a string.
///
/// The view is invisible and sits behind the grid. Tapping the grid makes it
/// first responder, which is what raises the keyboard. It is a separate view
/// from the surface on purpose — the surface takes first responder to show the
/// selection menu, and a menu must not raise the keyboard.
///
/// No composition state is held here. What is being composed, what a commit
/// does and where the candidates belong are the surface's, shared with the
/// AppKit arm, and this is the adapter that spells them in UIKit's protocol.
struct TerminalKeyboardInput: UIViewRepresentable {
    /// The session this types into.
    let session: TerminalSessionModel
    /// Whether the keyboard should be up.
    @Binding
    var isFirstResponder: Bool

    func makeUIView(context: Context) -> TerminalKeyInputView {
        let view = TerminalKeyInputView()
        view.session = session
        return view
    }

    /// Records the wanted responder state and applies it after this update.
    ///
    /// Changing first responder inside a view-graph update re-enters that
    /// update: UIKit tells the hosting view its responder changed, the hosting
    /// view reads its responder node from the graph being updated, and the
    /// graph walks a cycle that holds the main thread at full load.
    func updateUIView(_ view: TerminalKeyInputView, context: Context) {
        view.session = session
        view.wantsFirstResponder = isFirstResponder
        guard view.wantsFirstResponder != view.isFirstResponder else { return }
        Task { @MainActor [weak view] in view?.applyWantedFirstResponder() }
    }
}

/// A position in the composition, which is the only document a terminal has.
///
/// Offsets count characters of the text being composed. Outside a composition
/// the document is empty, so every position is zero — which is the truth: there
/// is nothing to navigate, and the shell owns everything already sent.
private final class CompositionPosition: UITextPosition {
    let offset: Int

    init(_ offset: Int) {
        self.offset = offset
        super.init()
    }
}

/// A range of the composition.
private final class CompositionRange: UITextRange {
    let startPosition: CompositionPosition
    let endPosition: CompositionPosition

    init(from startPosition: CompositionPosition, to endPosition: CompositionPosition) {
        self.startPosition = startPosition
        self.endPosition = endPosition
        super.init()
    }

    override var start: UITextPosition { startPosition }
    override var end: UITextPosition { endPosition }
    override var isEmpty: Bool { startPosition.offset == endPosition.offset }
}

/// The responder behind ``TerminalKeyboardInput``.
final class TerminalKeyInputView: UIView, UITextInput {
    weak var session: TerminalSessionModel?

    /// Whether the screen last asked for the keyboard; read when the deferred
    /// change runs, so a request superseded before then is not applied.
    var wantsFirstResponder = false

    // UIKit restores the previous responder after dismissing an alert. A
    // hidden terminal keyboard must refuse that restoration until requested.
    override var canBecomeFirstResponder: Bool { wantsFirstResponder }

    /// Takes or gives up first responder to match ``wantsFirstResponder``.
    func applyWantedFirstResponder() {
        guard window != nil else { return }
        if wantsFirstResponder, !isFirstResponder {
            becomeFirstResponder()
        } else if !wantsFirstResponder, isFirstResponder {
            resignFirstResponder()
        }
    }

    // A terminal keyboard must not autocapitalise, autocorrect or offer
    // predictions: each of those rewrites what was typed, and the shell
    // receives the rewrite rather than the keystroke.
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    // Grammar checking rewrites typed text as the others do. Settable because
    // the protocol says so; it stays off.
    @available(iOS 27.0, *)
    var grammarCheckingType: UITextGrammarCheckingType {
        get { .no }
        set {}
    }
    var allowsNumberPadPopover = false
    // Not `.asciiCapable`: that keyboard offers no input method, and a person
    // typing Japanese or Chinese would have no way to compose at all.
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    var inputDelegate: UITextInputDelegate?

    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    /// The style UIKit offers for drawing marked text, unused: the input method
    /// draws its own candidate window over the grid.
    var markedTextStyle: [NSAttributedString.Key: Any]?

    /// The composition in flight, empty when none is.
    private var composedText: String { session?.composedText ?? "" }

    /// Always false: there is no text here to delete, only keys to report.
    ///
    /// UIKit consults this to decide whether the delete key is meaningful, and
    /// a false answer still delivers `deleteBackward()` — which is what a
    /// terminal wants, since the shell decides what a delete means.
    var hasText: Bool { false }

    func insertText(_ text: String) {
        // Return arrives as a newline and has to leave as a carriage return:
        // the shell's line discipline ends a line on CR, and LF alone moves the
        // cursor down without submitting anything.
        session?.insertKeyboardText(text)
    }

    func deleteBackward() {
        // A delete during a composition shortens it, and the input method says
        // so by marking the shorter text. Nothing reaches the host until it
        // commits, so a delete that reached the shell here would erase a
        // character the shell never received.
        guard session?.isComposing != true else { return }
        session?.sendAccessoryKey(.Backspace)
    }

    // MARK: - Standard editing actions

    override var keyCommands: [UIKeyCommand]? {
        Self.editingCommands + Self.modifiedArrowCommands + TerminalTabCommands.commands + TerminalFindCommands.commands
    }

    /// UITextInput otherwise handles Shift-arrows as selection in its empty
    /// composition document before the terminal receives a hardware press.
    static var modifiedArrowCommands: [UIKeyCommand] {
        [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow]
            .map {
                let command = UIKeyCommand(input: $0, modifierFlags: .shift, action: #selector(performModifiedArrow(_:)))
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
    }

    @objc
    func performModifiedArrow(_ command: UIKeyCommand) {
        guard let session, !session.isComposing else { return }
        let key: Ubiquitty.Keys.VirtualKey
        switch command.input {
        case UIKeyCommand.inputLeftArrow: key = .LeftArrow
        case UIKeyCommand.inputRightArrow: key = .RightArrow
        case UIKeyCommand.inputUpArrow: key = .UpArrow
        case UIKeyCommand.inputDownArrow: key = .DownArrow
        default: return
        }
        var press = TerminalKeyTranslation.keyPress(for: key)
        press.modifiers = TerminalKeyTranslation.modifierBits(command.modifierFlags)
        press.wasModified = true
        session.sendKey(press)
    }

    @objc
    func performFindCommand(_ command: UIKeyCommand) {
        guard let session else { return }
        TerminalFindCommands.perform(command, on: session)
    }

    @objc
    func performTabCommand(_ command: UIKeyCommand) {
        guard let session else { return }
        TerminalTabCommands.perform(command, on: session)
    }

    @objc
    func performWorkspaceCommand(_ command: UIKeyCommand) {
        guard let session else { return }
        TerminalWorkspaceCommands.perform(command, on: session)
    }

    /// Standard editing shortcuts shared with the grid's responder-chain host.
    static var editingCommands: [UIKeyCommand] {
        [
            UIKeyCommand(title: "Paste", action: #selector(paste(_:)), input: "v", modifierFlags: .command),
            UIKeyCommand(title: "Copy Selection", action: #selector(copy(_:)), input: "c", modifierFlags: .command),
            UIKeyCommand(title: "Select All", action: #selector(selectAll(_:)), input: "a", modifierFlags: .command),
        ]
        .map { command in
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(performWorkspaceCommand(_:)):
            guard let session, let command = sender as? UIKeyCommand else { return false }
            return TerminalWorkspaceCommands.isEnabled(command, on: session)
        case #selector(paste(_:)): return session?.canPasteClipboard == true
        case #selector(copy(_:)): return session?.hasSelection == true
        case #selector(selectAll(_:)): return session != nil
        default: return super.canPerformAction(action, withSender: sender)
        }
    }

    override func paste(_ sender: Any?) {
        session?.requestClipboardPaste()
    }

    override func copy(_ sender: Any?) { session?.copySelection() }

    override func selectAll(_ sender: Any?) { session?.selectAll() }

    // MARK: - The composition

    var markedTextRange: UITextRange? {
        guard session?.isComposing == true else { return nil }
        return CompositionRange(from: CompositionPosition(0), to: CompositionPosition(composedText.count))
    }

    func setMarkedText(_ markedText: String?, selectedRange _: NSRange) {
        session?.compose(markedText ?? "")
    }

    func unmarkText() {
        session?.cancelComposition()
    }

    // MARK: - The document, which is the composition and nothing else

    var beginningOfDocument: UITextPosition { CompositionPosition(0) }

    var endOfDocument: UITextPosition { CompositionPosition(composedText.count) }

    /// The caret, which a terminal keeps at the end of what is being composed.
    ///
    /// Settable because the protocol says so; there is nowhere else for it to
    /// go, so a set is answered by leaving it where it is.
    var selectedTextRange: UITextRange? {
        get {
            let end = CompositionPosition(composedText.count)
            return CompositionRange(from: end, to: end)
        }
        set {}
    }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? CompositionRange else { return nil }
        let characters = Array(composedText)
        let lower = min(max(0, range.startPosition.offset), characters.count)
        let upper = min(max(lower, range.endPosition.offset), characters.count)
        return String(characters[lower..<upper])
    }

    /// Commits the text rather than editing.
    ///
    /// The terminal has no editable document: what a replacement means here is
    /// that the input method settled on this string, which is a commit.
    func replace(_: UITextRange, withText text: String) {
        session?.commitComposition(text)
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let fromPosition = fromPosition as? CompositionPosition,
            let toPosition = toPosition as? CompositionPosition
        else {
            return nil
        }
        return CompositionRange(from: fromPosition, to: toPosition)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? CompositionPosition else { return nil }
        let moved = position.offset + offset
        guard moved >= 0, moved <= composedText.count else { return nil }
        return CompositionPosition(moved)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left, .up: return self.position(from: position, offset: -offset)
        case .right, .down: return self.position(from: position, offset: offset)
        @unknown default: return nil
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let position = position as? CompositionPosition,
            let other = other as? CompositionPosition
        else {
            return .orderedSame
        }
        if position.offset < other.offset { return .orderedAscending }
        if position.offset > other.offset { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let from = from as? CompositionPosition,
            let toPosition = toPosition as? CompositionPosition
        else {
            return 0
        }
        return toPosition.offset - from.offset
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let range = range as? CompositionRange else { return nil }
        switch direction {
        case .left, .up: return range.startPosition
        case .right, .down: return range.endPosition
        @unknown default: return nil
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? CompositionPosition,
            let other = self.position(from: position, in: direction, offset: 1) as? CompositionPosition
        else {
            return nil
        }
        return compare(position, to: other) == .orderedAscending
            ? CompositionRange(from: position, to: other)
            : CompositionRange(from: other, to: position)
    }

    /// Left to right, always: the composition is drawn by the input method, and
    /// the grid itself is laid out by the terminal, not by this view.
    func baseWritingDirection(for _: UITextPosition, in _: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_: NSWritingDirection, for _: UITextRange) {}

    // MARK: - Where the candidates belong

    /// The cursor cell, so the candidate window appears under the text being
    /// composed rather than in the corner where this one-point view sits.
    func firstRect(for _: UITextRange) -> CGRect {
        session?.compositionAnchorRect(in: self) ?? .zero
    }

    func caretRect(for _: UITextPosition) -> CGRect {
        session?.compositionAnchorRect(in: self) ?? .zero
    }

    /// None: the terminal draws its own selection, and the composition is the
    /// input method's to draw.
    func selectionRects(for _: UITextRange) -> [UITextSelectionRect] { [] }

    func closestPosition(to _: CGPoint) -> UITextPosition? { beginningOfDocument }

    func closestPosition(to _: CGPoint, within range: UITextRange) -> UITextPosition? {
        (range as? CompositionRange)?.startPosition
    }

    func characterRange(at _: CGPoint) -> UITextRange? { nil }

    // MARK: - The iPad shortcuts bar

    /// The bar's modifier items, refreshed as the modifiers change.
    private var modifierItems: [TerminalKeyboardModifiers.Modifier: UIBarButtonItem] = [:]
    private var isCommandModifierShown: Bool?
    /// The continuous observation of the modifiers, held for as long as the
    /// bar shows them; replacing or dropping it ends the observation.
    private var modifierObservation: AnyObject?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installShortcutsBar()
        // SwiftUI may request focus before UIKit attaches this view, or keep
        // the request while navigation temporarily removes it from a window.
        if window != nil {
            Task { @MainActor [weak self] in self?.applyWantedFirstResponder() }
        }
    }

    /// Puts the accessory's keys in the shortcuts bar on iPad, where Pages
    /// and Numbers put theirs.
    ///
    /// The bar is the system's: it sits in the keyboard, and with a hardware
    /// keyboard attached the system shrinks it to a small floating bar on its
    /// own. Escape, Tab, the modifiers and the arrows lead; the symbols and
    /// the function keys trail. Every item reads the one key table, so a key
    /// sends the same press from here as from the iPhone row.
    private func installShortcutsBar() {
        guard window != nil, modifierItems.isEmpty, traitCollection.userInterfaceIdiom == .pad else { return }
        for modifier in TerminalKeyboardModifiers.Modifier.allCases {
            let item = UIBarButtonItem(
                primaryAction: UIAction(title: modifier.capTitle) { [weak self] _ in
                    self?.session?.keyboardModifiers.toggle(modifier)
                }
            )
            item.accessibilityLabel = modifier.spokenName
            item.accessibilityIdentifier = modifier.accessibilityIdentifier
            item.accessibilityHint = "Tap for the next key, or twice to lock."
            modifierItems[modifier] = item
        }
        let arrows = TerminalAccessoryKey.arrows.map(barItem)
        let arrowPad = UIBarButtonItem(title: nil, image: UIImage(systemName: "dpad"), primaryAction: nil, menu: nil)
        arrowPad.accessibilityLabel = "Arrow Keys"
        let shouldShowCommand = session?.shouldShowCommandAccessory == true
        isCommandModifierShown = shouldShowCommand
        let modifiers = TerminalKeyboardModifiers.Modifier.allCases
            .filter { $0 != .command || shouldShowCommand }
            .compactMap { modifierItems[$0] }
        inputAssistantItem.leadingBarButtonGroups = [
            UIBarButtonItemGroup(barButtonItems: [barItem(.escape), barItem(.tab)], representativeItem: nil),
            UIBarButtonItemGroup(barButtonItems: modifiers, representativeItem: nil),
            UIBarButtonItemGroup(barButtonItems: arrows, representativeItem: arrowPad),
        ]
        observeModifiers()
    }

    private var shownSymbols: [String]?

    private func updateSymbolItems() {
        guard let session else { return }
        let symbols = session.accessorySymbols
        let names = symbols.map(\.id)
        guard shownSymbols != names else { return }
        shownSymbols = names
        let functionKeys = UIBarButtonItem(title: "fn", image: nil, primaryAction: nil, menu: menu(TerminalAccessoryKey.functionPage))
        functionKeys.accessibilityLabel = "Function Keys"
        functionKeys.accessibilityIdentifier = "terminal-function-keys"
        var overflow = [functionKeys]
        if symbols.count > 5 {
            let more = UIBarButtonItem(
                title: nil,
                image: UIImage(systemName: "ellipsis"),
                primaryAction: nil,
                menu: menu(Array(symbols.dropFirst(5)))
            )
            more.accessibilityLabel = "More Symbols"
            overflow.insert(more, at: 0)
        }
        inputAssistantItem.trailingBarButtonGroups = [
            UIBarButtonItemGroup(barButtonItems: symbols.prefix(5).map(barItem), representativeItem: nil),
            UIBarButtonItemGroup(barButtonItems: overflow, representativeItem: nil),
        ]
    }

    private func barItem(_ key: TerminalAccessoryKey) -> UIBarButtonItem {
        let image = key.symbol.flatMap { UIImage(systemName: $0) }
        let item = UIBarButtonItem(
            primaryAction: UIAction(title: key.capTitle, image: image) { [weak self] _ in
                self?.session?.sendAccessory(key)
            }
        )
        item.accessibilityLabel = key.spokenName
        item.accessibilityIdentifier = key.accessibilityIdentifier
        return item
    }

    private func menu(_ keys: [TerminalAccessoryKey]) -> UIMenu {
        UIMenu(
            children: keys.map { key in
                let action = UIAction(title: key.showsPopUp ? key.capTitle : key.spokenName) { [weak self] _ in
                    self?.session?.sendAccessory(key)
                }
                action.accessibilityLabel = key.spokenName
                return action
            }
        )
    }

    /// Shows each modifier's state on its item: selected for the next key,
    /// and underlined as well when locked, as the iPhone row's cap carries a
    /// bar.
    private func observeModifiers() {
        guard session != nil else { return }
        if #available(iOS 27.0, *) {
            modifierObservation = ContinuousObservation(
                withContinuousObservation(options: .didSet) { [weak self] _ in
                    MainActor.assumeIsolated { self?.showModifierState() }
                }
            )
            return
        }
        withObservationTracking {
            showModifierState()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeModifiers() }
        }
    }

    /// Draws each modifier's state on its bar item: selected while it applies,
    /// underlined while it is locked.
    private func showModifierState() {
        guard let session else { return }
        updateSymbolItems()
        let shouldShowCommand = session.shouldShowCommandAccessory
        if isCommandModifierShown != shouldShowCommand {
            isCommandModifierShown = shouldShowCommand
            var groups = inputAssistantItem.leadingBarButtonGroups
            if groups.count > 1 {
                let modifiers = TerminalKeyboardModifiers.Modifier.allCases
                    .filter { $0 != .command || shouldShowCommand }
                    .compactMap { modifierItems[$0] }
                groups[1] = UIBarButtonItemGroup(barButtonItems: modifiers, representativeItem: nil)
                inputAssistantItem.leadingBarButtonGroups = groups
            }
        }
        let modifiers = session.keyboardModifiers
        for (modifier, item) in modifierItems {
            let state = modifiers.state(of: modifier)
            item.isSelected = state != .off
            let underline: [NSAttributedString.Key: Any] =
                state == .locked ? [.underlineStyle: NSUnderlineStyle.thick.rawValue] : [:]
            item.setTitleTextAttributes(underline, for: .normal)
            item.setTitleTextAttributes(underline, for: .selected)
            item.accessibilityValue = modifiers.spokenState(of: modifier)
        }
    }

    // MARK: - Hardware keys

    /// Keys a hardware keyboard sends that carry an identity of their own.
    ///
    /// Reported to the terminal rather than encoded here: which bytes a key
    /// becomes depends on modes this view cannot see, and a view that spelled
    /// them sent CSI cursor keys to a program that had asked for SS3.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, routeKeyPress(key) else { continue }
            handled = true
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key, let input = TerminalKeyTranslation.keyPress(for: key, eventType: .Release) else { continue }
            _ = session?.sendKey(input)
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key, let input = TerminalKeyTranslation.keyPress(for: key, eventType: .Release) else { continue }
            _ = session?.sendKey(input)
        }
        super.pressesCancelled(presses, with: event)
    }

    /// Routes one hardware key between the encoder and the input method.
    ///
    /// A composition in flight owns every key until it commits or cancels. A
    /// key with an identity of its own — an arrow, Escape, a function key —
    /// encodes, because no input method composes with those. So does a chord
    /// Core classes as terminal input, and a Control chord: UIKit reports no
    /// "the input method ignored this" the way AppKit's editor commands do, so
    /// a Control chord handed to the keyboard would be dropped rather than
    /// falling through to the encoder. Everything else is text, and reaches
    /// the input method through `insertText` or `setMarkedText`.
    ///
    /// - Parameter key: The key UIKit reported.
    /// - Returns: Whether the terminal took it.
    private func routeKeyPress(_ key: UIKey) -> Bool {
        guard let session, session.shouldReportKeyPositions || !session.isComposing else { return false }
        // Command editing belongs to UIKit's responder chain, not the shell.
        if key.modifierFlags.intersection([.command, .control, .alternate]) == .command {
            let input = key.charactersIgnoringModifiers.lowercased()
            let commands = TerminalWorkspaceCommands.commands + TerminalTabCommands.commands + TerminalFindCommands.commands
            if ["c", "v", "a"].contains(input)
                || commands.contains(where: { $0.input?.lowercased() == input && $0.modifierFlags == key.modifierFlags })
            {
                return false
            }
        }
        guard let press = TerminalKeyTranslation.keyPress(for: key) else { return false }
        if session.shouldReportKeyPositions || Ubiquitty.Keys.keyFamily(press.virtualKey) != .None {
            return session.sendKey(press)
        }
        // UIKit reports one Alternate bit with no side, so an Option chord is
        // Meta whenever `[keys] option_as_alt` names any side, and otherwise
        // reaches the keyboard as the layout's character.
        let modifiers = key.modifierFlags
        let policy = Ubiquitty.Preferences.Effective.optionAsAlternate(Ubiquitty.Preferences.values().pointee)
        let alternate: Ubiquitty.Input.AlternateModifier = modifiers.contains(.alternate) ? .Held : .Up
        let command: Ubiquitty.Input.SuperModifier = modifiers.contains(.command) ? .Held : .Up
        let bypasses = Ubiquitty.Input.eventShouldBypassTextInputForTerminalEncoding(policy, alternate, command)
        if bypasses || modifiers.contains(.control) {
            // A Control chord on an Option key that is not Meta encodes here
            // too, and Core reads its Option the way the macOS shells do.
            return session.sendKey(Ubiquitty.Runtime.pressUnderOptionAsAlternate(press, policy, alternate, command))
        }
        return false
    }
}

/// The hardware keyboard's tab commands, which the iPad's tab strip and the
/// overview answer to: Command-Shift-Backslash shows every tab, Command-1 to
/// Command-9 pick one, and Command-Shift-[ and ] step through them.
@MainActor
enum TerminalTabCommands {
    static var commands: [UIKeyCommand] {
        let action = #selector(TerminalKeyInputView.performTabCommand(_:))
        var made = [
            UIKeyCommand(title: "Show All Tabs", action: action, input: "\\", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Show Previous Tab", action: action, input: "[", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Show Next Tab", action: action, input: "]", modifierFlags: [.command, .shift]),
        ]
        for number in 1...9 {
            made.append(
                UIKeyCommand(
                    title: number == 9 ? "Show Last Tab" : "Show Tab \(number)",
                    action: action,
                    input: "\(number)",
                    modifierFlags: .command
                )
            )
        }
        return made
    }

    /// Does what one of the commands asks.
    ///
    /// - Parameters:
    ///   - command: The command pressed.
    ///   - session: The workspace it acts on.
    static func perform(_ command: UIKeyCommand, on session: TerminalSessionModel) {
        switch command.input {
        case "\\": session.showTabOverview()
        case "[": session.stepTab(.previous)
        case "]": session.stepTab(.next)
        case let digit?: if let number = Int(digit) { session.selectTab(number: number) }
        case nil: break
        }
    }
}

/// Holds a continuous observation's token, which cannot be copied, where a
/// reference is kept; the observation ends when the holder goes.
@available(iOS 27.0, *)
private final class ContinuousObservation {
    private var token: ObservationTracking.Token?

    init(_ token: consuming ObservationTracking.Token) {
        self.token = consume token
    }
}

/// File-menu commands use the focused terminal's responder, including with the software keyboard hidden.
@MainActor
enum TerminalWorkspaceCommands {
    static var commands: [UIKeyCommand] {
        let action = #selector(TerminalKeyInputView.performWorkspaceCommand(_:))
        return [
            UIKeyCommand(title: "New Tab", action: action, input: "t", modifierFlags: .command),
            UIKeyCommand(title: "Split Right", action: action, input: "d", modifierFlags: .command),
            UIKeyCommand(title: "Split Down", action: action, input: "d", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Close Pane", action: action, input: "w", modifierFlags: .command),
            UIKeyCommand(title: "Close Tab", action: action, input: "w", modifierFlags: [.command, .shift]),
        ]
    }

    static func isEnabled(_ command: UIKeyCommand, on session: TerminalSessionModel) -> Bool {
        guard session.keyboardCloseRequest == nil, session.consentRequest == nil else { return false }
        switch command.input {
        case "t": return session.canChangePanes && session.supportsWorkspace
        case "d": return session.canChangePanes
        case "w": return session.canChangeTabs && session.activeTab != nil
        default: return false
        }
    }

    static func perform(_ command: UIKeyCommand, on session: TerminalSessionModel) {
        guard isEnabled(command, on: session) else { return }
        switch command.input {
        case "t": session.addTab()
        case "d": session.performPaneAction(command.modifierFlags.contains(.shift) ? .splitBelow : .splitBeside)
        case "w": session.requestKeyboardClose(wholeTab: command.modifierFlags.contains(.shift))
        default: break
        }
    }
}

private struct TerminalWorkspaceFocus: FocusedValueKey {
    typealias Value = TerminalSessionModel
}

extension FocusedValues {
    var terminalWorkspace: TerminalSessionModel? {
        get { self[TerminalWorkspaceFocus.self] }
        set { self[TerminalWorkspaceFocus.self] = newValue }
    }
}

/// SwiftUI owns the scene's menu tree and routes commands to that scene's terminal.
struct TerminalWorkspaceMenu: Commands {
    @FocusedValue(\.terminalWorkspace)
    private var session

    var body: some Commands {
        CommandGroup(after: .newItem) {
            ForEach(Array(TerminalWorkspaceCommands.commands.enumerated()), id: \.offset) { _, command in
                Button(command.title) {
                    if let session { TerminalWorkspaceCommands.perform(command, on: session) }
                }
                .keyboardShortcut(
                    KeyEquivalent(command.input?.first ?? " "),
                    modifiers: command.modifierFlags.contains(.shift) ? [.command, .shift] : .command
                )
                .disabled(session.map { TerminalWorkspaceCommands.isEnabled(command, on: $0) } != true)
            }
        }
    }
}
