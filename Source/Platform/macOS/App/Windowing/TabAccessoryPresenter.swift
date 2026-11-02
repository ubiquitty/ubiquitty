// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// TabAccessoryPresenter.swift — the one thing a tab's accessory slot shows.
//
// A tab has one slot and several things it might want to say: how far a job has
// got, that a bell rang with nobody there to hear it, a colour the program
// chose, that something asked for the reader by name, that output arrived
// unread, and which number selects it. Which of those wins is Core's ranking
// (`App::tabAccessory`); building the view for the winner and putting it in
// the slot is this, once, for both shells.

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

@MainActor
@objc(UBTabAccessoryPresenter)
public final class TabAccessoryPresenter: NSObject {
    /// Whether the tab-selecting modifier is down, application-wide.
    ///
    /// One fact for every window: the modifier is not a window's to observe,
    /// so the application sees it and stores it here for whoever asks.
    @objc
    public static var isCommandKeyHeld = false

    /// Called after every write into a tab's accessory slot.
    ///
    /// Installing an accessory view, or changing its string, makes AppKit
    /// rebuild the tab's stack view — and the rebuild re-derives the pill's
    /// title from the tab's attributed title, mapping an unselected one to its
    /// own dim grey. The controller writes its bake back over that, so it has
    /// to hear about the write.
    internal var onAccessoryWrite: (() -> Void)?

    private var hintLabel: NSTextField?
    private var attentionDots: TabAttentionDots?
    private var statusMark: TabStatusMark?

    /// The program status this tab last reported, what it waited for if it
    /// was blocked, and whether it is news: a status that arrives while its
    /// tab is not the one being looked at is unseen until the reader selects it.
    private var lastProgramStatus: HostOutlineStatus = .none
    private var lastBlockKind: HostOutlineBlockKind = .none
    private var isProgramStatusUnseen = false

    // What the hint was last built from. Re-setting `tab.accessoryView`, or even
    // its string, makes AppKit rebuild the tab's stack view and rerun a
    // key-view-loop and layout pass, and this runs for every tab of every
    // refresh with almost always the same hint — so a refresh that would put
    // back what is already there returns instead.
    private var shownHintText = ""
    private var shownHintColor: NSColor?
    private var shownHintFontSize: CGFloat = 0

    // A fade is in flight: the mark is on its way out and the slot belongs to
    // the animation until it finishes. Refreshing through it would put the mark
    // back at full opacity, which reads as a flicker rather than a fade.
    private var isFadingOut = false

    /// Which fade is the current one; a fade whose number has gone stale was
    /// overtaken by a mark or a ring and must not write the hint.
    private var fadeGeneration = 0

    /// Abandons the fade in flight, if any.
    private func endFade() {
        isFadingOut = false
        fadeGeneration += 1
    }

    /// The mark currently in the slot — the dots or the bell — for the fade to
    /// take out. One name for both, because which of them is showing is Core's
    /// answer and the leaving is the same gesture either way.
    private var installedMark: NSView?

    /// Puts one thing in this tab's accessory slot, or nothing.
    ///
    /// - Parameters:
    ///   - window: The window whose tab is being dressed.
    ///   - hintPosition: The shortcut number this tab answers to, or 0 for none.
    ///   - isSelected: Whether this is its group's selected tab.
    ///   - reportedProgressState: The panes' own OSC 9;4 reports, folded, 0
    ///     for none: what tells a working program's progress from a report.
    ///   - progressState: The aggregated OSC 9;4 state, with a working
    ///     program's status counted as progress of unknown length, 0 for none.
    ///   - progressValue: That state's percentage, where it has one.
    ///   - statusColor: The colour the program set for this tab, or nil.
    ///   - isStatusColorNeutral: Whether `statusColor` is the theme's neutral
    ///     slot, Core's colour for a status with nothing to say in colour.
    ///   - programStatusRaw: The semantic OSC program status, or 0 for none.
    ///   - programBlockKindRaw: What a blocked program waits for, or 0 for
    ///     none or a program that is not blocked.
    ///   - notificationColor: The colour an unseen notification's dot is
    ///     drawn in, as Core resolved it for this tab's theme.
    ///   - hasUnheardBell: Whether a bell rang here with the reader elsewhere.
    ///   - hasUnseenNotification: Whether something asked for the reader.
    ///   - hasUnseenActivity: Whether output arrived that nobody has read.
    ///   - foreground: The theme foreground, packed 0xRRGGBB.
    ///   - background: The theme background the band derives from, packed
    ///     0xRRGGBB.
    ///   - usesNativeColors: Whether accessories use semantic label roles.
    ///   - fontSize: The chrome font size, already scaled.
    @objc
    public func apply(
        to window: NSWindow,
        hintPosition: Int,
        isSelected: Bool,
        reportedProgressState: UInt8,
        progressState: UInt8,
        progressValue: UInt8,
        statusColor: NSColor?,
        isStatusColorNeutral: Bool = false,
        programStatusRaw: UInt8 = 0,
        programBlockKindRaw: UInt8 = 0,
        notificationColor: NSColor,
        hasUnheardBell: Bool,
        hasUnseenNotification: Bool,
        hasUnseenActivity: Bool,
        foreground: UInt32,
        background: UInt32,
        usesNativeColors: Bool,
        fontSize: CGFloat
    ) {
        let programStatus = HostOutlineStatus(rawValue: programStatusRaw) ?? .none
        let blockKind = HostOutlineBlockKind(rawValue: programBlockKindRaw) ?? .none
        // A blocked program that comes to wait for something else has news too.
        if programStatus != lastProgramStatus || blockKind != lastBlockKind {
            lastProgramStatus = programStatus
            lastBlockKind = blockKind
            isProgramStatusUnseen = programStatus != .none
        }
        if isSelected {
            isProgramStatusUnseen = false
        }
        var facts = Ubiquitty.App.TabAccessoryFacts()
        facts.isSelected = isSelected
        facts.hasProgress = progressState != 0
        facts.hasStatusColour = statusColor != nil
        facts.hasUnheardBell = hasUnheardBell
        facts.hasUnseenNotification = hasUnseenNotification
        facts.hasUnseenActivity = hasUnseenActivity
        facts.hasShortcut = hintPosition != 0
        let hintMode = Ubiquitty.Preferences.Effective.tabShortcutHints(Ubiquitty.Preferences.values().pointee)
        facts.isShortcutHintHeld = Ubiquitty.Runtime.areTabShortcutHintsVisible(hintMode, Self.isCommandKeyHeld)
        facts.isShortcutHintOff = hintMode == .Off

        let kind = Ubiquitty.App.tabAccessory(facts)
        defer {
            if Self.tracesDecisions {
                trace(window: window, facts: facts, kind: kind, progressState: progressState)
            }
        }
        let inks = Inks(
            foreground: foreground,
            background: background,
            isSelected: isSelected,
            usesNativeColors: usesNativeColors
        )
        let isWindowActive = WindowTabSelection.isGroupActive(window)
        let wasShowingMark = installedMark != nil && window.tab.accessoryView === installedMark

        switch kind {
        case .progressRing:
            // A pane's own report is the circular indicator, spinning for
            // progress of unknown length and filling to a percent, and so is a
            // working record's percent. A working program with neither shows
            // as its status, the ellipsis.
            let ink = inks.mark(.ProgressRing, isWindowActive: isWindowActive)
            let isWorkingAlone = reportedProgressState == 0 && progressState == UInt8(Ubiquitty.OSC.ProgressIndeterminate.rawValue)
            presentStatusMark(
                isWorkingAlone ? .working(ink: ink) : .progress(state: progressState, value: progressValue, ink: ink),
                isUnseen: false,
                in: window
            )
        case .statusDot where programStatus != .none:
            // A working program in the selected tab leaves its progress to the
            // bar in the tab's pill, as the indicator would.
            let content: TabStatusMark.Content =
                switch programStatus {
                case .working: isSelected ? .none : .working(ink: inks.mark(.ProgressRing, isWindowActive: isWindowActive))
                default:
                    // A status with no colour of its own wears a system label
                    // role, which the glass strip composites vibrantly.
                    .status(
                        programStatus,
                        blockKind: blockKind,
                        ink: (isStatusColorNeutral ? nil : statusColor)
                            ?? TabTitleStyling.neutralStatusInk(isAtRest: programStatus == .idle, isWindowActive: isWindowActive)
                    )
                }
            presentStatusMark(content, isUnseen: isProgramStatusUnseen, in: window)
        case .bell, .colouredBell:
            // A bell nobody heard is news until it is: it glows and wiggles as
            // an unseen question does. The colour is read off Core's answer
            // rather than off `statusColor` being non-nil, which would colour
            // a bell Core ranked as plain.
            let ink =
                kind == .colouredBell ? statusColor ?? inks.bell(isWindowActive: isWindowActive) : inks.bell(isWindowActive: isWindowActive)
            presentStatusMark(.bell(ink: ink), isUnseen: true, in: window)
        case .statusDot, .notificationDot, .activityDots:
            let dots = attentionDots ?? TabAttentionDots(frame: .zero)
            attentionDots = dots
            // One fat dot for a thing that was said, three dim ones for the
            // ellipsis that unread output reads as.
            dots.dotCount = kind == .activityDots ? 3 : 1
            dots.tintColor = tint(
                for: kind,
                statusColor: statusColor,
                notificationColor: notificationColor,
                inks: inks,
                isWindowActive: isWindowActive
            )
            present(dots, in: window)
        default:
            // Nothing to say but possibly a number to show. The mark leaves by
            // fading rather than vanishing, and the hint takes the slot once
            // it has gone.
            // Whether a number is wanted at all is Core's answer, not this
            // position: a tab has a position whether or not the reader asked
            // to see the shortcuts. Resolved once, so the write that happens
            // now and the write that happens when the dots finish fading
            // cannot disagree — they did, and a tab that had shown the
            // activity dots grew a hint the reader had switched off.
            let hintText = kind == .shortcutHint ? "⌘\(hintPosition)" : ""
            if wasShowingMark, !isFadingOut {
                fadeOutMark(in: window, thenHint: hintText, inks: inks, fontSize: fontSize)
                return
            }
            if isFadingOut {
                return
            }
            applyHint(text: hintText, inks: inks, fontSize: fontSize, in: window)
        }
    }

    /// Whether every accessory decision is written to standard error, one
    /// line each, for a report from a real session to carry the sequence.
    ///
    /// Read once: the variable is the person's (or the harness's) choice at
    /// launch, not something that changes under a running app.
    private static let tracesDecisions = ProcessInfo.processInfo.environment["UBIQUITTY_TAB_ACCESSORY_TRACE"] == "1"

    /// One line for one decision: which tab, the facts Core ranked, Core's
    /// answer, and what the slot holds once this write has run.
    private func trace(
        window: NSWindow,
        facts: Ubiquitty.App.TabAccessoryFacts,
        kind: Ubiquitty.App.TabAccessory,
        progressState: UInt8
    ) {
        let tabs = window.tabbedWindows ?? []
        let index = tabs.firstIndex(of: window).map { $0 + 1 } ?? 0
        let selectedIndex = window.tabGroup?.selectedWindow.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let line = String(
            format:
                "[tab-accessory] %.6f tab=%ld/%ld selected=%ld isSelected=%d isKey=%d appActive=%d unread=%d bell=%d notification=%d progress=%d status=%d held=%d hintOff=%d kind=%@ slot=%@%@\n",
            CACurrentMediaTime(),
            index,
            tabs.count,
            selectedIndex,
            facts.isSelected ? 1 : 0,
            window.isKeyWindow ? 1 : 0,
            NSApp.isActive ? 1 : 0,
            facts.hasUnseenActivity ? 1 : 0,
            facts.hasUnheardBell ? 1 : 0,
            facts.hasUnseenNotification ? 1 : 0,
            Int(progressState),
            facts.hasStatusColour ? 1 : 0,
            facts.isShortcutHintHeld ? 1 : 0,
            facts.isShortcutHintOff ? 1 : 0,
            Self.traceName(of: kind),
            describeSlot(of: window),
            isFadingOut ? " fading" : ""
        )
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Core's answer, spelled for the trace.
    private static func traceName(of kind: Ubiquitty.App.TabAccessory) -> String {
        switch kind {
        case .progressRing: "ring"
        case .bell: "bell"
        case .colouredBell: "colouredBell"
        case .statusDot: "statusDot"
        case .notificationDot: "notificationDot"
        case .activityDots: "dots"
        case .shortcutHint: "hint"
        default: "none"
        }
    }

    /// What the slot holds, spelled for the trace.
    private func describeSlot(of window: NSWindow) -> String {
        switch window.tab.accessoryView {
        case nil: "empty"
        case let view? where view === statusMark: "mark(\(statusMark?.symbolName ?? "ring"))"
        case let view? where view === attentionDots: "dots(\(attentionDots?.dotCount ?? 0))"
        case let view? where view === hintLabel: "hint'\(shownHintText)'"
        case let view?: "\(type(of: view))"
        }
    }

    /// What a tab's accessory inks are resolved from.
    ///
    /// The window's activation is not among them: it is read where each ink is
    /// made, so a hint written when a fade finishes wears the activation of that
    /// moment rather than the one the fade began under.
    private struct Inks {
        var foreground: UInt32
        var background: UInt32
        var isSelected: Bool
        var usesNativeColors: Bool

        /// The ink a neutral mark wears, at Core's coverage for it.
        @MainActor
        func mark(_ mark: Ubiquitty.Themes.TabAccessoryMark, isWindowActive: Bool) -> NSColor {
            TabTitleStyling.accessoryInk(
                mark,
                isSelected: isSelected,
                isWindowActive: isWindowActive,
                foreground: foreground,
                background: background,
                usesNativeColors: usesNativeColors
            )
        }

        /// The bell's ink: the title's own, so the bell recedes with the title
        /// beside it rather than holding a colour of its own.
        @MainActor
        func bell(isWindowActive: Bool) -> NSColor {
            guard !usesNativeColors else { return .secondaryLabelColor }
            return TabTitleStyling.titleInk(
                isSelected: isSelected,
                isWindowActive: isWindowActive,
                foreground: foreground,
                background: background,
                usesNativeColors: false
            )
        }
    }

    /// The colour a dot is drawn in, by what it is reporting.
    private func tint(
        for kind: Ubiquitty.App.TabAccessory,
        statusColor: NSColor?,
        notificationColor: NSColor,
        inks: Inks,
        isWindowActive: Bool
    ) -> NSColor {
        switch kind {
        case .statusDot:
            return statusColor ?? TabTitleStyling.neutralStatusInk(isAtRest: false, isWindowActive: isWindowActive)
        case .notificationDot:
            return notificationColor
        default:
            return inks.mark(.ActivityDots, isWindowActive: isWindowActive)
        }
    }

    /// Fades the mark out once, then puts the hint back in the slot it leaves.
    ///
    /// The hint arrives already resolved rather than as a position to spell:
    /// whether a number is shown at all is Core's decision, and a slot filled
    /// from the raw position here shows a hint the reader has switched off.
    ///
    /// - Parameters:
    ///   - window: The window whose tab is being dressed.
    ///   - hintText: The hint to put back, or empty for none.
    ///   - inks: What the hint's ink is resolved from.
    ///   - fontSize: The chrome font size, already scaled.
    private func fadeOutMark(in window: NSWindow, thenHint hintText: String, inks: Inks, fontSize: CGFloat) {
        guard let mark = installedMark else { return }
        // A mark with no layer, or no window to be drawn in, has nothing to
        // fade, and waiting on a completion that cannot fire would leave it in
        // the slot of a tab Core has already said shows the hint.
        guard let layer = mark.layer, mark.window != nil else {
            applyHint(text: hintText, inks: inks, fontSize: fontSize, in: window)
            return
        }
        isFadingOut = true
        fadeGeneration += 1
        let generation = fadeGeneration
        // Ends the fade once, whichever of the completion and the deadline
        // arrives first. A mark presented or a ring installed since the fade
        // began bumped the generation, so a late arrival writes nothing over
        // what Core wanted after it.
        let finish: @MainActor @Sendable (WeakWindow) -> Void = { [weak self] box in
            guard let self, let window = box.window, self.isFadingOut, self.fadeGeneration == generation else {
                return
            }
            self.isFadingOut = false
            guard window.tab.accessoryView === mark else { return }
            self.applyHint(text: hintText, inks: inks, fontSize: fontSize, in: window)
        }
        let box = WeakWindow(window)
        NSAnimationContext.runAnimationGroup { _ in
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated { finish(box) }
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.duration = Self.fadeDuration
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: "fade")
            CATransaction.commit()
        }
        // Core Animation does not run, or finish, an animation for a layer that
        // is not being drawn, and the completion goes with it.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration + 0.25) {
            MainActor.assumeIsolated { finish(box) }
        }
    }

    /// How long a leaving mark takes to fade.
    private static let fadeDuration: CFTimeInterval = 0.28

    /// A window held weakly across a scheduled hop.
    private final class WeakWindow: @unchecked Sendable {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    /// Writes the hint, or empties it, skipping a write that changes nothing.
    private func applyHint(text: String, inks: Inks, fontSize: CGFloat, in window: NSWindow) {
        let label = hintLabel ?? NSTextField(labelWithString: "")
        hintLabel = label
        let color = inks.mark(.ShortcutHint, isWindowActive: WindowTabSelection.isGroupActive(window))
        if window.tab.accessoryView === label, shownHintText == text, shownHintColor == color,
            shownHintFontSize == fontSize
        {
            return
        }
        shownHintText = text
        shownHintColor = color
        shownHintFontSize = fontSize
        if window.tab.accessoryView !== label {
            window.tab.accessoryView = label
        }
        // Semantic colors retain their catalog identity so AppKit resolves
        // their coverage and vibrancy under the tab's material.
        label.attributedStringValue =
            text.isEmpty
            ? NSAttributedString()
            : NSAttributedString(
                string: text + "  ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: color,
                ]
            )
        // After the text: the title's room is measured past the hint's width,
        // which is the text's.
        onAccessoryWrite?()
    }

    /// Puts the status mark in the slot showing `content`, so a status, a
    /// working program and progress trade places in one view and one frame.
    private func presentStatusMark(_ content: TabStatusMark.Content, isUnseen: Bool, in window: NSWindow) {
        let mark = statusMark ?? TabStatusMark(frame: .zero)
        statusMark = mark
        mark.show(content, isUnseen: isUnseen)
        present(mark, in: window)
    }

    /// Puts an attention mark in the slot at full strength.
    ///
    /// A mark arriving cancels a fade that was taking one out: the slot is
    /// wanted again, and a view left mid-animation would arrive part-way
    /// transparent and stay there, because the fade's `fillMode` holds its end
    /// state until the animation is removed.
    private func present(_ mark: NSView, in window: NSWindow) {
        mark.wantsLayer = true
        mark.layer?.removeAnimation(forKey: "fade")
        mark.layer?.opacity = 1.0
        endFade()
        install(mark, in: window)
        installedMark = mark
    }

    /// Puts a view in the slot, skipping a write that changes nothing.
    private func install(_ view: NSView, in window: NSWindow) {
        endFade()
        shownHintText = ""
        installedMark = nil
        guard window.tab.accessoryView !== view else { return }
        window.tab.accessoryView = view
        onAccessoryWrite?()
    }
}
