// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit
import UbiquittyCore

/// The terminal's keys above the iPhone software keyboard: one row of caps.
///
/// Escape, Tab, Control and Alt stay at the leading edge. The arrow pad, fn,
/// and controls hidden by the software keyboard stay at the trailing edge,
/// under the thumbs. The keys between them scroll: the shell's
/// symbols, or with fn the function and navigation keys, so the row never
/// grows a second line. On iPad the same keys go in the system's shortcuts
/// bar instead; see ``TerminalKeyInputView``.
struct TerminalKeyboardAccessory: View {
    enum Page {
        case symbols, function
    }

    let session: TerminalSessionModel
    /// Puts the keyboard away. Offered only where nothing else on screen
    /// does: the keyboard covers an iPhone's bottom bar, and a short window
    /// hides it, but iPhone Duo's side rail keeps its keyboard button.
    var hideKeyboard: (() -> Void)?
    /// Opens dictation when the keyboard covers the toolbar's microphone.
    var dictate: (() -> Void)?
    @State
    private var page: Page

    init(session: TerminalSessionModel, hideKeyboard: (() -> Void)? = nil, dictate: (() -> Void)? = nil, page: Page = .symbols) {
        self.session = session
        self.hideKeyboard = hideKeyboard
        self.dictate = dictate
        _page = State(initialValue: page)
    }

    /// The key under the finger, popped up above the row.
    @State
    private var poppedKey: PoppedKey?
    /// The finger on the Control key while its chords are offered.
    @State
    private var chordTouch: ChordTouch?
    @State
    private var controlFrame = CGRect.zero
    @State
    private var rowWidth: CGFloat = 0
    /// Counts presses, so each one plays the key haptic.
    @State
    private var keyStrokes = 0

    @ScaledMetric(relativeTo: .subheadline)
    private var rowHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline)
    private var widestKey: CGFloat = 48

    private nonisolated static let space = "terminal-key-row"
    private static let edgePadding: CGFloat = 3
    private static let dictationWidth: CGFloat = 44

    /// One column of the system keyboard's ten-key grid, or of eleven when
    /// the row carries Hide Keyboard too. Dictation keeps its own full tap
    /// target; the symbols use the remaining width and scroll when needed.
    private var keyWidth: CGFloat {
        guard rowWidth > 0 else { return 40 }
        let columns: CGFloat = hideKeyboard == nil ? 10 : 11
        let dictationWidth = dictate == nil ? 0 : Self.dictationWidth
        return min(max((rowWidth - dictationWidth - 2 * Self.edgePadding) / columns, 34), widestKey)
    }

    var body: some View {
        HStack(spacing: 0) {
            key(.escape, isPinned: true)
            key(.tab, isPinned: true)
            modifier(.control)
            modifier(.alternate)
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    switch page {
                    case .symbols:
                        ForEach(session.accessorySymbols) { key($0) }
                    case .function:
                        modifier(.shift)
                        ForEach(TerminalAccessoryKey.functionPage) { key($0) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .horizontal)
            // A cap cut by either edge fades rather than stopping at a hard
            // line, which is what says the row scrolls.
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 6)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                }
            }
            .id(page)
            ArrowPad(
                tap: { arrow in
                    keyStrokes += 1
                    session.sendAccessory(arrow)
                },
                step: { session.sendAccessory($0) }
            )
            .frame(width: keyWidth)
            functionToggle
            if let dictate {
                Button(action: dictate) {
                    KeyLabel(title: "", symbol: "mic")
                }
                .buttonStyle(KeyCapStyle { if $0 { keyStrokes += 1 } })
                .frame(width: Self.dictationWidth)
                .accessibilityLabel("Dictate")
                .accessibilityHint("Hides the keyboard and starts dictation into the terminal.")
                .accessibilityIdentifier("terminal-keyboard-dictate")
                .accessibilityShowsLargeContentViewer()
            }
            if let hideKeyboard {
                Button(action: hideKeyboard) {
                    KeyLabel(title: "", symbol: "keyboard.chevron.compact.down")
                }
                .buttonStyle(KeyCapStyle { if $0 { keyStrokes += 1 } })
                .frame(width: keyWidth)
                .accessibilityLabel("Hide Keyboard")
                .accessibilityIdentifier("terminal-hide-keyboard")
            }
        }
        .padding(.horizontal, Self.edgePadding)
        .frame(height: max(rowHeight, 44))
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            rowWidth = $0
        }
        .overlayPreferenceValue(KeyCapBounds.self) { anchors in
            GeometryReader { proxy in
                if let poppedKey, let anchor = anchors[poppedKey.id] {
                    KeyPopUp(title: poppedKey.title, keyFrame: proxy[anchor])
                }
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) { chordPicker }
        .sensoryFeedback(.press(.button), trigger: keyStrokes)
        .sensoryFeedback(.selection, trigger: selectedChord?.id)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-key-row")
    }

    // MARK: - Keys

    /// A key cap. A pinned key takes exactly one column of the grid; a key
    /// in the scrolling middle is at least one column and as wide as its word.
    private func key(_ key: TerminalAccessoryKey, isPinned: Bool = false) -> some View {
        Button {
            session.sendAccessory(key)
        } label: {
            KeyLabel(title: key.capTitle, symbol: key.symbol, isGlyph: key.showsPopUp)
        }
        .buttonStyle(
            KeyCapStyle { isPressed in
                if isPressed {
                    keyStrokes += 1
                    if key.showsPopUp { poppedKey = PoppedKey(id: key.id, title: key.capTitle) }
                } else if poppedKey?.id == key.id {
                    poppedKey = nil
                }
            }
        )
        .frame(minWidth: keyWidth, maxWidth: isPinned ? keyWidth : nil)
        .fixedSize(horizontal: !isPinned, vertical: false)
        .anchorPreference(key: KeyCapBounds.self, value: .bounds) { key.showsPopUp ? [key.id: $0] : [:] }
        .accessibilityLabel(key.spokenName)
        .accessibilityIdentifier(key.accessibilityIdentifier)
        .accessibilityShowsLargeContentViewer()
    }

    private func modifier(_ modifier: TerminalKeyboardModifiers.Modifier) -> some View {
        let modifiers = session.keyboardModifiers
        let state = modifiers.state(of: modifier)
        let symbol = modifier.symbol.map { state == .off ? $0 : $0 + ".fill" }
        return KeyCap(
            appearance: state == .locked ? .locked : state == .once ? .latched : .plain,
            isPressed: modifiers.isHeld(modifier)
        ) {
            KeyLabel(title: modifier.capTitle, symbol: symbol)
        }
        .frame(width: keyWidth)
        .accessibilityHidden(true)
        .overlay {
            TerminalModifierControl(
                session: session,
                modifier: modifier,
                onChord: modifier == .control ? { handleChord($0) } : nil
            )
        }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(Self.space))
        } action: { frame in
            if modifier == .control { controlFrame = frame }
        }
    }

    private var functionToggle: some View {
        Button {
            page = page == .symbols ? .function : .symbols
        } label: {
            KeyLabel(title: "fn", symbol: nil)
        }
        .buttonStyle(KeyCapStyle(appearance: page == .function ? .latched : .plain))
        .sensoryFeedback(.selection, trigger: page)
        .frame(width: keyWidth)
        .accessibilityLabel("Function Keys")
        .accessibilityValue(page == .function ? "Shown" : "Hidden")
        .accessibilityHint("Swaps the symbols for the function and navigation keys.")
        .accessibilityIdentifier("terminal-function-keys")
    }

    // MARK: - Control chords

    private var chordCellWidth: CGFloat { max(keyWidth, 40) }
    private var chordPickerWidth: CGFloat { CGFloat(TerminalControlChord.common.count) * chordCellWidth + 8 }

    /// Where the picker starts: over the Control key, kept on screen.
    private var chordPickerX: CGFloat {
        min(max(controlFrame.minX - 4, Self.edgePadding), max(Self.edgePadding, rowWidth - chordPickerWidth - Self.edgePadding))
    }

    /// The chord under the finger, once it has moved off where it pressed.
    private var selectedChord: TerminalControlChord? {
        guard let chordTouch, chordTouch.hasMoved else { return nil }
        let x = controlFrame.minX + chordTouch.location.x - chordPickerX - 4
        let index = min(max(Int((x / chordCellWidth).rounded(.down)), 0), TerminalControlChord.common.count - 1)
        return TerminalControlChord.common[index]
    }

    private func handleChord(_ gesture: ControlChordGesture) {
        switch gesture {
        case .began(let location):
            chordTouch = ChordTouch(start: location, location: location)
        case .moved(let location):
            chordTouch?.location = location
        case .ended(let location):
            chordTouch?.location = location
            if let chord = selectedChord {
                keyStrokes += 1
                session.sendControlChord(chord)
            }
            chordTouch = nil
        case .cancelled:
            chordTouch = nil
        }
    }

    @ViewBuilder
    private var chordPicker: some View {
        if chordTouch != nil {
            HStack(spacing: 0) {
                ForEach(TerminalControlChord.common) { chord in
                    KeyCap(appearance: chord.id == selectedChord?.id ? .latched : .plain, isPressed: false) {
                        KeyLabel(title: chord.capTitle, symbol: nil)
                    }
                    .frame(width: chordCellWidth)
                    .accessibilityLabel(chord.spokenName)
                    .accessibilityIdentifier(chord.accessibilityIdentifier)
                }
            }
            .padding(4)
            .frame(height: rowHeight + 8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .offset(x: chordPickerX, y: -(rowHeight + 14))
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

// MARK: - Key caps

/// How a cap is filled: plain, latched for the next key, or locked.
private enum KeyCapAppearance {
    case plain, latched, locked
}

/// A key cap drawn the way the system keyboard draws one: a continuous
/// rounded rectangle with a hairline shadow under it, inset so neighbouring
/// caps keep a gap while the touch target stays the whole cell.
private struct KeyCap<Label: View>: View {
    let appearance: KeyCapAppearance
    let isPressed: Bool
    @ViewBuilder
    let label: Label

    @Environment(\.colorSchemeContrast)
    private var contrast

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    private var fill: AnyShapeStyle {
        switch appearance {
        case .plain: AnyShapeStyle(Color(uiColor: isPressed ? .systemFill : .tertiarySystemFill))
        case .latched, .locked: AnyShapeStyle(.tint)
        }
    }

    var body: some View {
        label
            .foregroundStyle(appearance == .plain ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.white))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                shape.fill(fill).shadow(color: .black.opacity(0.3), radius: 0, y: 1)
            }
            .overlay {
                if contrast == .increased { shape.strokeBorder(.primary.opacity(0.6), lineWidth: 1) }
            }
            // A locked modifier carries a bar under its word, as Caps Lock
            // carries its light.
            .overlay(alignment: .bottom) {
                if appearance == .locked {
                    Capsule().fill(Color.white).frame(width: 12, height: 2).padding(.bottom, 4)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }
}

/// A cap's word or glyph: SF Pro for words, SF Mono for a character, whose
/// shape is the point — a grave accent is not an apostrophe.
private struct KeyLabel: View {
    let title: String
    let symbol: String?
    var isGlyph = false

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol)
            } else if isGlyph {
                Text(title).font(.system(.body, design: .monospaced, weight: .medium))
            } else {
                Text(title)
            }
        }
        .font(.system(.subheadline, weight: .medium))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
    }
}

private struct KeyCapStyle: ButtonStyle {
    var appearance = KeyCapAppearance.plain
    var onPressChange: (Bool) -> Void = { _ in }

    func makeBody(configuration: Configuration) -> some View {
        KeyCap(appearance: appearance, isPressed: configuration.isPressed) { configuration.label }
            .onChange(of: configuration.isPressed) { _, isPressed in onPressChange(isPressed) }
    }
}

private struct PoppedKey: Equatable {
    let id: TerminalAccessoryKey.ID
    let title: String
}

private struct KeyCapBounds: PreferenceKey {
    static var defaultValue: [TerminalAccessoryKey.ID: Anchor<CGRect>] { [:] }

    static func reduce(
        value: inout [TerminalAccessoryKey.ID: Anchor<CGRect>],
        nextValue: () -> [TerminalAccessoryKey.ID: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { $1 }
    }
}

/// The enlarged character over a pressed key, as the system keyboard shows
/// the letter under the finger.
private struct KeyPopUp: View {
    let title: String
    let keyFrame: CGRect

    @ScaledMetric(relativeTo: .title2)
    private var glyphSize: CGFloat = 26

    var body: some View {
        let width = keyFrame.width + 8
        let height = keyFrame.height + 12
        Text(title)
            .font(.system(size: glyphSize, weight: .regular, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(width: width, height: height)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .position(x: keyFrame.midX, y: keyFrame.minY - height / 2 + 4)
            .accessibilityHidden(true)
    }
}

// MARK: - The arrow pad

/// One cap for four arrows, used like a trackpad nub.
///
/// A tap sends the arrow of the quadrant it lands in, with the key press
/// haptic. A press that drags sends arrows by distance instead: one arrow,
/// with one selection click, for each step of travel away from where the
/// finger came down, in the direction of the drag, and the opposite arrow
/// for each step it comes back. A finger held still sends nothing, so a long
/// press never floods a program with repeats. Core's `Input::ArrowDrag` owns
/// that arithmetic: the dead zone, the axis lock and the steps.
private struct ArrowPad: View {
    /// Sends a tapped arrow, and plays the key press haptic.
    let tap: (TerminalAccessoryKey) -> Void
    /// Sends one arrow of a drag. The pad plays the drag's click itself.
    let step: (TerminalAccessoryKey) -> Void

    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass
    /// The arrow the finger points at, while it is down.
    @State
    private var pointedArrow: TerminalAccessoryKey.ID?

    private var symbol: String {
        switch pointedArrow {
        case TerminalAccessoryKey.leftArrow.id: "dpad.left.fill"
        case TerminalAccessoryKey.rightArrow.id: "dpad.right.fill"
        case TerminalAccessoryKey.upArrow.id: "dpad.up.fill"
        case TerminalAccessoryKey.downArrow.id: "dpad.down.fill"
        default: "dpad"
        }
    }

    var body: some View {
        KeyCap(appearance: .plain, isPressed: pointedArrow != nil) {
            KeyLabel(title: "", symbol: symbol)
        }
        .overlay {
            ArrowPadTouchArea(
                metrics: ArrowPadMetrics.metrics(for: horizontalSizeClass),
                tap: tap,
                step: step,
                showPointedArrow: { pointedArrow = $0?.id }
            )
        }
        .overlay { quadrants }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Arrow Keys")
    }

    /// The four arrows as VoiceOver and UI tests see them, laid over the
    /// quadrants a touch picks between. They take no touches themselves.
    private var quadrants: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            quadrant(.leftArrow).frame(width: width / 3, height: height).position(x: width / 6, y: height / 2)
            quadrant(.rightArrow).frame(width: width / 3, height: height).position(x: width * 5 / 6, y: height / 2)
            quadrant(.upArrow).frame(width: width / 3, height: height / 2).position(x: width / 2, y: height / 4)
            quadrant(.downArrow).frame(width: width / 3, height: height / 2).position(x: width / 2, y: height * 3 / 4)
        }
    }

    /// One arrow for VoiceOver. Activating it sends the arrow; swiping up or
    /// down sends one arrow of its axis per swipe, which is the drag's
    /// counterpart for a person who cannot drag: up and right on a swipe up,
    /// down and left on a swipe down.
    private func quadrant(_ key: TerminalAccessoryKey) -> some View {
        let isHorizontal = key.id == TerminalAccessoryKey.leftArrow.id || key.id == TerminalAccessoryKey.rightArrow.id
        let forward: TerminalAccessoryKey = isHorizontal ? .rightArrow : .upArrow
        let backward: TerminalAccessoryKey = isHorizontal ? .leftArrow : .downArrow
        return Rectangle()
            .fill(Color.clear)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(key.spokenName)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(key.accessibilityIdentifier)
            .accessibilityHint(isHorizontal ? "Swipe up or down to move right or left." : "Swipe up or down to move up or down.")
            .accessibilityAction { tap(key) }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: tap(forward)
                case .decrement: tap(backward)
                @unknown default: break
                }
            }
    }
}

/// The distances a drag on the arrow pad travels, by width class.
///
/// A step is one arrow: one cell of a shell line, one line of `less`, one
/// entry of history. These are the points the finger travels for it.
enum ArrowPadMetrics {
    /// The radius around touch-down that is still a tap.
    ///
    /// It matches the travel UIKit's pan recognizer waits for before it calls
    /// a touch a drag, so a tap that rolls under the thumb stays one arrow.
    static let deadZoneRadius: CGFloat = 10

    /// The step in a compact width: every iPhone in portrait.
    ///
    /// About a third of the key row's column, which the ten-key grid makes 34
    /// to 43 points. A thumb sweeps about 140 points across the keyboard
    /// without regripping, ten arrows, which is the length of a word or two;
    /// the steps stay far enough apart that each click is felt on its own.
    static let compactStepDistance: CGFloat = 14

    /// The step in a regular width: landscape on the largest iPhones and an
    /// unfolded display.
    ///
    /// The keyboard there is wider and the hand moves from the wrist rather
    /// than the thumb, so the same intent travels further; a longer step
    /// keeps a sweep across the keyboard at about the same count of arrows.
    static let regularStepDistance: CGFloat = 18

    /// The metrics for a width class, with compact as the default for an
    /// unknown one, since the key row exists only on iPhone.
    ///
    /// - Parameter sizeClass: The environment's horizontal size class.
    /// - Returns: The step and dead zone, in points.
    static func metrics(for sizeClass: UserInterfaceSizeClass?) -> Ubiquitty.Input.ArrowDragMetrics {
        var metrics = Ubiquitty.Input.ArrowDragMetrics()
        metrics.stepDistance = Double(sizeClass == .regular ? regularStepDistance : compactStepDistance)
        metrics.deadZoneRadius = Double(deadZoneRadius)
        return metrics
    }
}

/// Follows the finger on the arrow pad.
///
/// UIKit rather than a SwiftUI gesture because the pad needs the touch-down
/// itself, to prepare the haptic before the first step, and because a drag
/// event here does nothing but arithmetic on stored values: no gesture value,
/// no view update and no allocation unless the arrow under the finger changes.
private struct ArrowPadTouchArea: UIViewRepresentable {
    let metrics: Ubiquitty.Input.ArrowDragMetrics
    let tap: (TerminalAccessoryKey) -> Void
    let step: (TerminalAccessoryKey) -> Void
    /// Reports the arrow the finger points at, and nil when it lifts.
    let showPointedArrow: (TerminalAccessoryKey?) -> Void

    func makeUIView(context: Context) -> TouchView { TouchView() }

    func updateUIView(_ view: TouchView, context: Context) {
        view.metrics = metrics
        view.tap = tap
        view.step = step
        view.showPointedArrow = showPointedArrow
    }

    static func dismantleUIView(_ view: TouchView, coordinator: ()) {
        view.cancelTouch()
    }

    final class TouchView: UIView {
        var metrics = Ubiquitty.Input.ArrowDragMetrics()
        var tap: (TerminalAccessoryKey) -> Void = { _ in }
        var step: (TerminalAccessoryKey) -> Void = { _ in }
        var showPointedArrow: (TerminalAccessoryKey?) -> Void = { _ in }

        /// The touch being followed. The pad follows one finger.
        private weak var trackedTouch: UITouch?
        private var origin = CGPoint.zero
        private var drag: Ubiquitty.Input.ArrowDrag?
        /// The quadrant the finger came down in, which a tap sends.
        private var touchedKey = TerminalAccessoryKey.upArrow
        /// The arrow the cap shows, so the view updates only when it changes.
        private var pointedKey: TerminalAccessoryKey?
        /// One click per step. It follows the System Haptics setting, so a
        /// person who turned haptics off feels nothing.
        private lazy var clicks = UISelectionFeedbackGenerator(view: self)

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = false
            backgroundColor = .clear
            // The quadrants above this view are what VoiceOver reads.
            isAccessibilityElement = false
            accessibilityElementsHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("ArrowPadTouchArea.TouchView is not decoded") }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard trackedTouch == nil, let touch = touches.first else { return }
            trackedTouch = touch
            origin = touch.location(in: self)
            drag = Ubiquitty.Input.ArrowDrag(metrics)
            touchedKey = key(at: origin)
            clicks.prepare()
            show(touchedKey)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = trackedTouch, touches.contains(touch), var current = drag else { return }
            let location = touch.location(in: self)
            let steps = current.moveTo(Double(location.x - origin.x), Double(location.y - origin.y))
            drag = current
            guard steps.count > 0, let key = Self.accessoryKey(for: steps.arrow) else { return }
            // Steps crossed within one event click once per step; the
            // generator folds clicks closer together than it can play.
            for _ in 0..<steps.count {
                step(key)
                clicks.selectionChanged(at: location)
            }
            clicks.prepare()
            show(key)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = trackedTouch, touches.contains(touch) else { return }
            if drag?.hasLeftDeadZone() == false { tap(touchedKey) }
            finishTouch()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = trackedTouch, touches.contains(touch) else { return }
            finishTouch()
        }

        /// Forgets a touch the system took away, sending nothing for it.
        func cancelTouch() {
            guard trackedTouch != nil else { return }
            finishTouch()
        }

        private func finishTouch() {
            trackedTouch = nil
            drag = nil
            show(nil)
        }

        private func show(_ key: TerminalAccessoryKey?) {
            guard key?.id != pointedKey?.id else { return }
            pointedKey = key
            showPointedArrow(key)
        }

        /// The arrow whose quadrant holds a point: whichever axis it is
        /// further from the centre along, in proportion to the cap's shape.
        private func key(at point: CGPoint) -> TerminalAccessoryKey {
            let deltaX = (point.x - bounds.midX) / max(bounds.width / 2, 1)
            let deltaY = (point.y - bounds.midY) / max(bounds.height / 2, 1)
            if abs(deltaX) > abs(deltaY) { return deltaX < 0 ? .leftArrow : .rightArrow }
            return deltaY < 0 ? .upArrow : .downArrow
        }

        private static func accessoryKey(for arrow: Ubiquitty.Keys.VirtualKey) -> TerminalAccessoryKey? {
            switch arrow {
            case .LeftArrow: .leftArrow
            case .RightArrow: .rightArrow
            case .UpArrow: .upArrow
            case .DownArrow: .downArrow
            default: nil
            }
        }
    }
}

// MARK: - Modifiers

/// What the finger on the Control key does while its chords are offered,
/// in the key's own coordinates.
enum ControlChordGesture {
    case began(CGPoint)
    case moved(CGPoint)
    case ended(CGPoint)
    case cancelled
}

private struct ChordTouch {
    let start: CGPoint
    var location: CGPoint

    var hasMoved: Bool { hypot(location.x - start.x, location.y - start.y) > 8 }
}

/// Tracks a modifier before the neighbouring key's second finger reaches it.
///
/// UIKit rather than SwiftUI because a held modifier is one finger while
/// another types, and a SwiftUI button reports its press only as it ends.
private struct TerminalModifierControl: UIViewRepresentable {
    let session: TerminalSessionModel
    let modifier: TerminalKeyboardModifiers.Modifier
    let onChord: ((ControlChordGesture) -> Void)?

    func makeUIView(context: Context) -> ModifierButton {
        let button = ModifierButton(type: .custom)
        button.addTarget(button, action: #selector(ModifierButton.press), for: .touchDown)
        button.addTarget(button, action: #selector(ModifierButton.activate), for: .touchUpInside)
        button.addTarget(button, action: #selector(ModifierButton.cancel), for: [.touchUpOutside, .touchCancel])
        return button
    }

    func updateUIView(_ button: ModifierButton, context: Context) {
        button.session = session
        button.modifier = modifier
        button.onChord = onChord
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        button.accessibilityLabel = modifier.spokenName
        button.accessibilityValue = session.keyboardModifiers.spokenState(of: modifier)
        button.accessibilityIdentifier = modifier.accessibilityIdentifier
        button.accessibilityHint =
            modifier == .control
            ? "Tap for the next key, or twice to lock. Hold for common chords."
            : "Tap for the next key, or twice to lock. Hold while pressing another key."
        button.accessibilityCustomActions =
            modifier == .control
            ? TerminalControlChord.common.map { chord in
                UIAccessibilityCustomAction(name: chord.spokenName) { [weak session] _ in
                    session?.sendControlChord(chord) ?? false
                }
            }
            : nil
        button.largeContentTitle = modifier.spokenName
        button.showsLargeContentViewer = true
    }

    static func dismantleUIView(_ button: ModifierButton, coordinator: ()) {
        button.cancel()
    }

    final class ModifierButton: UIButton {
        weak var session: TerminalSessionModel?
        var modifier = TerminalKeyboardModifiers.Modifier.control
        var onChord: ((ControlChordGesture) -> Void)? {
            didSet { chordRecognizer.isEnabled = onChord != nil }
        }
        /// Whether this press brought the chords up, so its release neither
        /// latches nor toggles the modifier.
        private var offeredChords = false

        private lazy var chordRecognizer: UILongPressGestureRecognizer = {
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(chord(_:)))
            recognizer.minimumPressDuration = 0.5
            // The press stays held while the chords are up, so a key typed
            // with another finger still takes the modifier.
            recognizer.cancelsTouchesInView = false
            addGestureRecognizer(recognizer)
            return recognizer
        }()

        @objc
        func press() {
            offeredChords = false
            session?.keyboardModifiers.beginPress(modifier)
        }

        @objc
        func activate() {
            guard let session else { return }
            if offeredChords {
                releaseHold()
                return
            }
            // A toggle is a choice moving, so it ticks; a hold that chorded
            // changes no state and stays silent.
            let before = session.keyboardModifiers.state(of: modifier)
            session.keyboardModifiers.endPress(modifier, .activate)
            if session.keyboardModifiers.state(of: modifier) != before { InterfaceHaptics.selectionChanged() }
        }

        @objc
        func cancel() { releaseHold() }

        private func releaseHold() {
            guard session?.keyboardModifiers.isHeld(modifier) == true else { return }
            session?.keyboardModifiers.endPress(modifier, .cancel)
        }

        @objc
        func chord(_ recognizer: UILongPressGestureRecognizer) {
            let location = recognizer.location(in: self)
            switch recognizer.state {
            case .began:
                offeredChords = true
                onChord?(.began(location))
            case .changed:
                onChord?(.moved(location))
            case .ended:
                onChord?(.ended(location))
                releaseHold()
            default:
                onChord?(.cancelled)
                releaseHold()
            }
        }

        /// A hold that has already chorded with another key is that chord,
        /// not a request for the list.
        override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard recognizer === chordRecognizer else { return super.gestureRecognizerShouldBegin(recognizer) }
            return session?.keyboardModifiers.wasUsedWhileHeld(modifier) == false
        }

        override func accessibilityActivate() -> Bool {
            session?.keyboardModifiers.toggle(modifier)
            InterfaceHaptics.selectionChanged()
            return true
        }
    }
}
