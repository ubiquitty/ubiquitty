// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// BeamController.swift — the ⌘⇧P entry point: presents/dismisses the
// overlay, owns the per-window lifecycle (responder save/restore, the
// quick-select monitor, focus-loss dismissal), and builds the per-summon
// sources. The terminal-scope command builders live in
// BeamCommands.swift.
//

import AppKit
import SwiftUI
import UbiquittyAppBridge
import UbiquittyCore
import UbiquittyKit

// MARK: - Controller (ObjC entry point)

@MainActor
@objc(UBBeamController)
public final class BeamController: NSObject {
    // One overlay per window; ⌘⇧P toggles. Strong while presented (cleared on
    // dismiss); the window reference is weak so a closed window can't pin it.
    private static var controllers: [ObjectIdentifier: BeamController] = [:]

    // Whether Beam currently owns `window` — UBTerminalView gates keyDown /
    // performKeyEquivalent / cursor handling on this so Beam owns the keyboard
    // and the pointer while shown.
    @objc(isActiveInWindow:)
    public static func isActive(in window: NSWindow?) -> Bool {
        guard let window = window else { return false }
        return controllers[ObjectIdentifier(window)] != nil
    }

    private weak var window: NSWindow?
    // The controllers-map key, captured at present time. The weak `window`
    // can die before dismiss() runs; re-deriving the key from it would then
    // strand the map entry — which both pins this controller forever and
    // swallows the keyboard of any future NSWindow allocated at the same
    // address (ObjectIdentifier is the raw pointer).
    private var windowKey: ObjectIdentifier?
    private weak var previousResponder: NSResponder?
    private var model: BeamModel?
    private var terminalContext: BeamTerminalContext?
    private var hostView: NSView?

    /// Refreshes an open palette from its originating pane's search publication.
    ///
    /// - Parameter surface: The pane whose search changed.
    static func searchDidChange(_ surface: TerminalSurface) {
        guard let window = surface.window,
            let controller = controllers[ObjectIdentifier(window)],
            controller.terminalContext?.ownsSearchPublication(from: surface) == true
        else { return }
        controller.model?.refreshSearchPublication()
    }

    // Beam is transient (like Spotlight): when its window stops being key —
    // switching tabs, windows, or apps — it dismisses. Armed after present so the
    // in-window focus handoff can't trip it; torn down on dismiss so it fires once.
    private var resignKeyObserver: NSObjectProtocol?

    // Ctrl+1…9 quick-select. Not a BeamTextField.keyDown override: once the field
    // becomes first responder, AppKit hands live key events to its FIELD EDITOR
    // (an NSTextView — see becomeFirstResponder's currentEditor() reach-in
    // above), so keyDown on the NSTextField subclass itself never fires once
    // typing starts. A local monitor intercepts before the responder chain,
    // regardless of who currently holds first-responder status. keyCode (not
    // charactersIgnoringModifiers) so it's the physical number-row position,
    // matching on every keyboard layout — AZERTY's Ctrl+1 key reports
    // characters like "&", not "1", but its keyCode is still 18.
    // Dims the title bar while Beam is up, matching the card's own scrim.
    private var titlebarScrimLayer: CALayer?

    private var quickSelectMonitor: Any?
    private static let quickSelectDigits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    // Summon or dismiss Beam over `window`. Colors are the live on-screen theme
    // (packed by the caller from the renderer). Beam wears the SYSTEM font, so it
    // takes no terminal font — only the theme colors.
    @objc(toggleInWindow:foreground:background:accent:cursor:)
    public static func toggle(
        in window: NSWindow,
        foreground: NSColor,
        background: NSColor,
        accent: NSColor,
        cursor: NSColor
    ) {
        let key = ObjectIdentifier(window)
        if let existing = controllers[key] {
            existing.dismiss()
            return
        }
        let controller = BeamController()
        controllers[key] = controller
        controller.present(
            in: window,
            foreground: foreground,
            background: background,
            accent: accent,
            cursor: cursor
        )
    }

    // One settings walk serves both actions and #. Installed-font choices are
    // resolved only after a query reaches them; an empty summon stays cheap.
    private static func commandSources(
        in window: NSWindow,
        includeFontCatalog: Bool
    ) -> (actions: [BeamCommand], settings: [BeamCommand]) {
        let settingsCommands = SettingsCommandProvider(resolveDeferred: includeFontCatalog).commands()
        let registry = BeamCommandRegistry([
            MenuCommandProvider(includeFontMenu: includeFontCatalog),
            PrebuiltCommandProvider(prebuilt: settingsCommands),
            TmuxSSHRemoteCommandProvider(),
            KeysActionCommandProvider(windowController: window.windowController),
            AgentSurfaceCommandProvider(windowController: window.windowController),
            TmuxContextCommandProvider(target: window.windowController as? any BeamTerminalHost),
        ])
        return (registry.commands(), settingsCommands)
    }

    private func present(
        in window: NSWindow,
        foreground: NSColor,
        background: NSColor,
        accent: NSColor,
        cursor: NSColor
    ) {
        // The dim scrim must cover the ENTIRE window — title bar included — so
        // attach to the window's frame view (contentView.superview, the theme
        // frame), not contentView, which excludes the title bar. The frame view
        // hosts the title bar + traffic lights, so the overlay sits above them.
        guard let frameView = window.contentView?.superview ?? window.contentView else {
            BeamController.controllers[ObjectIdentifier(window)] = nil
            return
        }
        let perflog = ProcessInfo.processInfo.environment["UBIQUITTY_PERFLOG"] != nil
        let summonStart = perflog ? CFAbsoluteTimeGetCurrent() : 0

        // Typeface per config: system UI font (chrome) by default; the
        // terminal's family when [appearance] beam_terminal_font is on. The
        // bundled house face is the fallback when no [font] family is set.
        let useTerminalFont = settingBool(.AppearanceBeamTerminalFont)
        let terminalFamily = (NSApp.delegate as? UBAppDelegate)?.settingsFontFamily()
        BeamFont.configure(
            terminalFamily: useTerminalFont
                ? (terminalFamily ?? "JetBrains Mono") : nil
        )

        let luminance = relativeLuminance(background)
        let palette = BeamPalette(
            foreground: Color(nsColor: foreground),
            background: Color(nsColor: background),
            accent: Color(nsColor: accent),
            caret: cursor,
            isDark: luminance < 0.5
        )

        // Commands retain this context through dismissal; it weakly references
        // the window and the terminal that opened the palette.
        let scopeController = BeamTerminalContext(window.windowController)
        terminalContext = scopeController
        let initialCommands = Self.commandSources(in: window, includeFontCatalog: false)
        let sources = BeamSources(
            actions: initialCommands.actions,
            settings: initialCommands.settings,
            goTo: { [scopeController] in BeamController.goToCommands(scopeController) },
            blocks: { [scopeController] in BeamController.blockCommands(scopeController) },
            find: { [scopeController] query, lastBlock in
                BeamController.findCommands(scopeController, query: query, lastBlockOnly: lastBlock)
            },
            findLastBlockAvailable: { [scopeController] in
                BeamController.lastBlockRange(scopeController) != nil
            },
            terminalScopesAvailable: scopeController != nil,
            findStatusText: { [scopeController] in scopeController?.findStatusText },
            loadCompleteCommands: { [weak window] in
                guard let window else { return ([], []) }
                return Self.commandSources(in: window, includeFontCatalog: true)
            }
        )
        let sourcesBuilt = perflog ? CFAbsoluteTimeGetCurrent() : 0
        let model = BeamModel(palette: palette, sources: sources)
        let modelBuilt = perflog ? CFAbsoluteTimeGetCurrent() : 0
        model.onExitFindScope = { [scopeController] in
            scopeController.map { BeamTerminalProviders.clearFind($0) }
        }
        // Teardown funnels through dismiss(), which drops the find highlight — so
        // a ⌘⇧P re-toggle (which calls dismiss() directly, bypassing this) still
        // clears it.
        model.onDismiss = { [weak self] in self?.dismiss() }

        // Autoresizing (not Auto Layout) against the private frame view, so we
        // never inject constraints into AppKit's title-bar layout.
        let host = BeamHostView(frame: frameView.bounds)
        host.autoresizingMask = [.width, .height]
        // Pin the appearance to the THEME's darkness, not the window's. The
        // pre-26 card material pins itself (VisualEffectBackground's
        // appearanceName), but the macOS 26 Liquid Glass branch renders in the
        // host's effective appearance — which, under titlebar_style = "native"
        // (window.appearance = nil → system), can be light-glass while every
        // Beam text color was computed for a dark theme: the washed-out
        // gray-on-gray palette. One pin here covers glass and any other
        // vibrancy inside the card, for both OS generations.
        host.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)

        let hosting = NSHostingView(rootView: BeamView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: host.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        // NSThemeFrame owns the title and the tab bar's container, and re-lays
        // out both when a foreign subview joins it — the title walks under the
        // traffic lights and the tab strip is rebuilt out of view. So the card
        // hosts in the content view, and the title bar is dimmed by a LAYER:
        // layout is view-based, so a sublayer is never laid out, and zPosition
        // holds it above AppKit's own sublayers however they are reordered.
        if let contentView = window.contentView {
            host.frame = contentView.bounds
            contentView.addSubview(host)
            titlebarScrimLayer = Self.installTitlebarScrim(in: frameView, contentView: contentView)
        } else {
            frameView.addSubview(host)
        }

        self.window = window
        self.windowKey = ObjectIdentifier(window)
        self.previousResponder = window.firstResponder
        self.model = model
        self.hostView = host

        // Force a layout so the field enters the window now; the field then
        // focuses itself exactly once (BeamTextField.viewDidMoveToWindow). The
        // controller does not also makeFirstResponder: a second focus call
        // re-selects the text and eats the first typed character.
        hosting.layoutSubtreeIfNeeded()
        if perflog {
            let layoutDone = CFAbsoluteTimeGetCurrent()
            let line = String(
                format: "[perf] beam summon: sources=%.2fms model=%.2fms layout=%.2fms total=%.2fms\n",
                (sourcesBuilt - summonStart) * 1000,
                (modelBuilt - sourcesBuilt) * 1000,
                (layoutDone - modelBuilt) * 1000,
                (layoutDone - summonStart) * 1000
            )
            fputs(line, stderr)
        }

        // Arm the focus-loss dismissal on the NEXT runloop turn — after the
        // field's own focus has landed — so presenting (an in-window first-
        // responder change, which does not resign window key) can't trip it.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.hostView != nil else { return }
            // The arming-gap turn is unobserved: if the window died or lost
            // key during it (programmatic orderOut, a panel going key), an
            // observer would arm dead or never fire — dismiss instead, which
            // also releases the quick-select monitor and the map entry.
            guard let window = self.window, window.isKeyWindow else {
                self.dismiss()
                return
            }
            self.resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                // queue: .main guarantees this runs synchronously on the main
                // thread already; assumeIsolated tells the compiler that without
                // an async hop (which would change dismiss's next-runloop-turn
                // timing the comment above relies on).
                MainActor.assumeIsolated {
                    self?.dismiss() // same teardown: overlay + responder + find highlight
                }
            }
        }

        // Ctrl+1…9 quick-select — see quickSelectMonitor's declaration for why
        // this must be a local event monitor, not a key-view override. isARepeat
        // is excluded so a held key can't re-fire submit() on a dismissed/
        // reused palette; the exact-mod-set check (contains .control, excludes
        // command/option/shift) tolerates capsLock/numericPad/function riding
        // along, unlike a bare == comparison against the full modifier set.
        quickSelectMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.hostView != nil, event.window === self.window,
                !event.isARepeat
            else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.control), !modifiers.contains(.command),
                !modifiers.contains(.option), !modifiers.contains(.shift),
                let digit = Self.quickSelectDigits[event.keyCode],
                self.model?.quickSelect(digit - 1) == true
            else { return event }
            return nil // consumed
        }
    }

    // MARK: terminal-scope command builders

    // Go-to (`:`) — the open tabs then the split panes; selecting one switches to
    // it. The window controller exposes the enumeration + focus seam.
    private static func goToCommands(_ controller: BeamTerminalContext?) -> [BeamCommand] {
        guard let controller else { return [] }
        var out: [BeamCommand] = []
        for tab in controller.beamTabs() {
            let index = tab.index
            out.append(
                BeamCommand(
                    title: tab.title.isEmpty ? "Tab \(index + 1)" : tab.title,
                    group: tab.isCurrent ? "Tab · current" : "Tab",
                    identity: "beam.goto.tab.\(index)",
                    run: { [controller] in controller.beamSelectTab(at: index) }
                )
            )
        }
        for pane in controller.beamPanes() {
            let paneID = pane.paneID
            out.append(
                BeamCommand(
                    title: pane.title.isEmpty ? "Pane \(paneID)" : pane.title,
                    group: pane.isCurrent ? "Pane · current" : "Pane",
                    identity: "beam.goto.pane.\(paneID)",
                    run: { [controller] in controller.beamFocusPane(paneID) }
                )
            )
        }
        // Saved sessions/workspaces are destinations too: selecting one
        // reopens that whole layout alongside what's already open (the same
        // entries + open path as the ⌘⇧K Sessions pane).
        let delegate = NSApp.delegate as? UBAppDelegate
        for entry in delegate?.sessionPickerEntries() ?? [] {
            guard let id = entry["id"], !id.isEmpty, let name = entry["name"] else { continue }
            let source = entry["source"] ?? "workspace"
            out.append(
                BeamCommand(
                    title: name,
                    group: "Session",
                    keywords: ["session", "workspace", "layout"],
                    identity: "beam.goto.session.\(source).\(id)",
                    run: {
                        (NSApp.delegate as? UBAppDelegate)?
                            .openPickerEntry(fromSource: source, identifier: id)
                    }
                )
            )
        }
        return out
    }

    // Copy text to the general pasteboard — the shared effect behind the
    // "Copy …" secondary actions. Empty strings are ignored so an emptyish
    // block/line doesn't clear the clipboard.
    private static func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // Blocks (`@`) — the focused terminal's OSC 133 command blocks, most-recent
    // first; selecting one scrolls the viewport to that block. Secondary
    // actions (→ / ⌘⏎) copy the command line or its captured output.
    static func blockCommands(_ controller: BeamTerminalContext?) -> [BeamCommand] {
        guard let controller else { return [] }
        return BeamTerminalProviders.commandBlocks(controller).enumerated()
            .map { offset, block in
                let absoluteRow = block.absoluteRow
                let command = block.command
                return BeamCommand(
                    title: command,
                    group: block.statusGlyph,
                    identity: "beam.block.\(offset).\(absoluteRow)",
                    secondaryActions: [
                        BeamOption(
                            label: "Jump to Block",
                            apply: { [controller] in controller.beamScroll(toAbsoluteRow: absoluteRow) }
                        ),
                        BeamOption(
                            label: "Copy Command",
                            apply: { copyToPasteboard(command) }
                        ),
                        BeamOption(
                            label: "Copy Output",
                            apply: { [controller] in
                                copyToPasteboard(BeamTerminalProviders.blockOutput(controller, absoluteRow: absoluteRow))
                            }
                        ),
                    ],
                    run: { [controller] in controller.beamScroll(toAbsoluteRow: absoluteRow) }
                )
            }
    }

    // Find (`/`) — scrollback search hits for the live query; selecting one
    // scrolls to the match. The "re " regex mini-language parses in Core
    // (parseFindQuery) so a second frontend can't diverge. Matches arrive in
    // scan order — shown as-is, never fuzzy-ranked.
    // The newest command block's output row span, or nil when there is no
    // shell-integration block. Drives both the "Last output" chip's presence
    // and the scoped search's range.
    private static func lastBlockRange(_ controller: BeamTerminalContext?) -> (from: Int, to: Int)? {
        guard let controller else { return nil }
        return BeamTerminalProviders.lastBlockRange(controller)
    }

    private static func findCommands(
        _ controller: BeamTerminalContext?,
        query: String,
        lastBlockOnly: Bool
    ) -> [BeamCommand] {
        guard let controller else { return [] }
        let (pattern, regex) = PaletteEngine.parseFindQuery(query)
        guard !pattern.trimmingCharacters(in: .whitespaces).isEmpty else {
            controller.beginFind("", isRegex: false, limit: 0, range: nil)
            return []
        }
        // Scope to the last block's output when the chip is on and a block
        // exists; otherwise whole scrollback (nil range).
        let range = lastBlockOnly ? lastBlockRange(controller) : nil
        let matches = BeamTerminalProviders.findMatches(
            controller,
            query: pattern,
            isRegex: regex,
            limit: 200,
            range: range.map { $0.from...$0.to }
        )
        return matches.enumerated()
            .map { index, match in
                let absoluteRow = match.absoluteRow
                let line = match.line
                let position = match.position
                return BeamCommand(
                    title: line.isEmpty ? "(blank line)" : line,
                    group: "L\(absoluteRow + 1)",
                    identity: "beam.find.\(position.line.value).\(position.cell).\(position.revision).\(index)",
                    secondaryActions: [
                        BeamOption(
                            label: "Jump to Match",
                            apply: { [controller] in controller.beamScroll(to: position) }
                        ),
                        BeamOption(label: "Copy Line", apply: { copyToPasteboard(line) }),
                    ],
                    run: { [controller] in controller.beamScroll(to: position) }
                )
            }
    }

    private func dismiss() {
        // Drop the map entry FIRST, from the stored key — not the weak window,
        // which can already be nil. Runs even when the overlay is already gone
        // (stale-entry recovery via a ⌘⇧P re-toggle), so a dead window's entry
        // can never permanently swallow a reused-address window's keyboard.
        if let key = windowKey {
            BeamController.controllers[key] = nil
            windowKey = nil
        }
        guard let host = hostView else { return }
        // Stop observing focus loss first, so tearing down (which moves first
        // responder back to the terminal) can't re-enter dismiss().
        if let observer = resignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            resignKeyObserver = nil
        }
        if let monitor = quickSelectMonitor {
            NSEvent.removeMonitor(monitor)
            quickSelectMonitor = nil
        }
        // The find scope paints a live scrollback highlight; clear it on every
        // teardown path (Esc, click-out, commit, focus loss, or a ⌘⇧P re-toggle)
        // so it never strands behind the closed palette.
        if model?.scope == .Find { model?.onExitFindScope() }
        hostView = nil
        model = nil
        terminalContext = nil
        if let window = window {
            // Restore the saved responder only while it still lives in this
            // window — a pane torn down under Beam (remote kill-pane) leaves a
            // dead or re-parented responder; restoring it would strand or
            // misroute the keyboard. The fallback asks the window controller
            // for its terminal view: the content view is a plain container
            // whose acceptsFirstResponder is no, so it can't be the target.
            let restorable: NSResponder? = {
                guard let responder = previousResponder else { return nil }
                if let view = responder as? NSView { return view.window === window ? view : nil }
                return responder
            }()
            if let restorable {
                window.makeFirstResponder(restorable)
            } else {
                (window.windowController as? any BeamTerminalHost)?.restoreFocusAfterBeam()
            }
            // The terminal re-resolves its own I-beam/arrow on the next mouse
            // move once Beam no longer owns the pointer.
        }
        // Beam sits above the title bar as a subview of the frame view, so the
        // window never resigns key while it is up and no selection-driven
        // repaint fires. Re-derive the titlebar once Beam is gone: the tab strip
        // is a system view Beam covered, and nothing else restores its themed
        // paint afterwards.
        let restoreChrome: @MainActor @Sendable () -> Void = { [weak window] in
            guard let window else { return }
            (window.windowController as? any BeamTerminalHost)?.restoreChromeAfterBeam()
        }

        removeTitlebarScrim()

        let reduceMotion = SystemDisplayOptions.shouldReduceMotion
        if reduceMotion {
            host.removeFromSuperview()
            restoreChrome()
        } else {
            // The card leaves whether or not the fade finishes. An animation
            // group's completion is not owed to anyone: something that relayouts
            // the window while it runs — setting a tab accessory forces an
            // AppKit key-view-loop pass, and a tab marked for unseen activity
            // does exactly that — can leave it unfired, and the card then sits
            // over the terminal with nothing owning it, because the controller
            // has already let go of the map entry. So the removal is booked for
            // just past the fade as well as inside it, and both are idempotent.
            let fadeSeconds = 0.10
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeSeconds + 0.05) { [weak host] in
                MainActor.assumeIsolated {
                    guard let host, host.superview != nil else { return }
                    host.removeFromSuperview()
                    restoreChrome()
                }
            }
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = fadeSeconds
                    host.animator().alphaValue = 0
                },
                completionHandler: {
                    // runAnimationGroup requires the main thread, and its completion
                    // handler is the CATransaction completion block, fired on the
                    // thread that committed the transaction — always main here.
                    // assumeIsolated tells the compiler that without an actor hop,
                    // which would defer the removal and titlebar repaint a runloop
                    // turn past the animation's actual end. Same guarantee as the
                    // didResignKeyNotification observer above.
                    MainActor.assumeIsolated {
                        host.removeFromSuperview()
                        restoreChrome()
                    }
                }
            )
        }
    }

    /// The scrim opacity, shared with the card's own so the two read as one.
    private static let scrimOpacity: Float = 0.14

    /// Covers the title bar with a dimming layer for the duration of a summon.
    ///
    /// - Parameters:
    ///   - frameView: The window's frame view, which owns the title bar.
    ///   - contentView: The content view, whose top edge bounds the region.
    /// - Returns: The installed layer, or nil when the frame view is unlayered.
    private static func installTitlebarScrim(in frameView: NSView, contentView: NSView) -> CALayer? {
        frameView.wantsLayer = true
        guard let hostLayer = frameView.layer else { return nil }
        let contentTop = contentView.frame.maxY
        let titlebarHeight = frameView.bounds.height - contentTop
        guard titlebarHeight > 0 else { return nil }

        let scrim = CALayer()
        scrim.frame = NSRect(x: 0, y: contentTop, width: frameView.bounds.width, height: titlebarHeight)
        scrim.backgroundColor = NSColor.black.cgColor
        scrim.zPosition = .greatestFiniteMagnitude
        scrim.autoresizingMask = [.layerWidthSizable, .layerMinYMargin]
        hostLayer.addSublayer(scrim)

        scrim.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = scrimOpacity
        fade.duration = 0.10
        scrim.opacity = scrimOpacity
        scrim.add(fade, forKey: "opacity")
        return scrim
    }

    private func removeTitlebarScrim() {
        guard let scrim = titlebarScrimLayer else { return }
        titlebarScrimLayer = nil
        CATransaction.begin()
        CATransaction.setCompletionBlock { scrim.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = scrim.opacity
        fade.toValue = 0
        fade.duration = 0.10
        scrim.opacity = 0
        scrim.add(fade, forKey: "opacity")
        CATransaction.commit()
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        return 0.2126 * resolved.redComponent
            + 0.7152 * resolved.greenComponent
            + 0.0722 * resolved.blueComponent
    }
}

// MARK: - UI-test seam (driven by the UBIQUITTY_UI_TESTS harness)

extension BeamController {
    /// Returns the presented model for the UI harness to drive and observe.
    ///
    /// - Parameter window: The palette's window.
    /// - Returns: Its live model, or nil when no palette is presented.
    static func modelForTesting(in window: NSWindow) -> BeamModel? {
        controllers[ObjectIdentifier(window)]?.model
    }

    // Drives a REAL BeamModel (no window, no mock) through its state
    // transitions: drill-from-empty-query shows the value list, exit-drill
    // restores the command list with the selection reset, Enter on an option
    // applies that option's value, and a scope switch never carries the
    // previous list's selection. Pumps the runloop internally for the commit
    // path's next-turn effect. Returns human-readable failures; empty = pass.
    @MainActor
    public static func uiTestStateMachineFailures() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ what: String) {
            if !condition { failures.append(what) }
        }

        var applied: Int?
        var ran = false
        let palette = BeamPalette(
            foreground: .white,
            background: .black,
            accent: .blue,
            caret: .white,
            isDark: true
        )
        func makeModel() -> BeamModel {
            let drill = BeamCommand(
                title: "Cursor Style",
                group: "Test",
                identity: "test.drill",
                drill: .options(
                    current: 1,
                    options: [
                        BeamOption(label: "Block", apply: { applied = 0 }),
                        BeamOption(label: "Bar", apply: { applied = 1 }),
                        BeamOption(label: "Underline", apply: { applied = 2 }),
                    ]
                )
            )
            let sources = BeamSources(
                actions: [
                    BeamCommand(
                        title: "Do Thing",
                        group: "Test",
                        identity: "test.run",
                        run: { ran = true }
                    ),
                    drill,
                ],
                settings: [],
                goTo: { [] },
                blocks: { [] },
                find: { _, _ in [] },
                findLastBlockAvailable: { false },
                terminalScopesAvailable: false
            )
            return BeamModel(palette: palette, sources: sources)
        }

        // The blank-query list is engine-ranked (alphabetical), not
        // registration-ordered — locate rows by title, never by index.
        func rowIndex(_ model: BeamModel, _ title: String) -> Int? {
            model.results.firstIndex { $0.title == title }
        }

        // Drill entry from an EMPTY query (the didSet same-value skip class):
        // the value list must replace the command list, with the current
        // value checked and selected.
        let model = makeModel()
        expect(model.results.count == 2, "initial list shows both commands")
        model.selectedIndex = rowIndex(model, "Cursor Style") ?? -1
        model.submit()
        expect(model.drill != nil, "Enter on a drill command enters the drill")
        expect(model.results.count == 3, "options drill lists its 3 values (got \(model.results.count))")
        expect(model.results.first?.isOption == true, "drill rows are option rows, not commands")
        expect(model.selectedIndex == 1, "the current value is pre-selected")

        // Enter applies the SELECTED option's value (commit fires next turn).
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.selectedIndex = rowIndex(model, "Underline") ?? -1
        model.submit()
        expect(dismissed, "applying a value dismisses like running a command")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(applied == 2, "Enter applied the selected option (got \(String(describing: applied)))")

        // Exit-drill restore: back at the command list, selection reset —
        // an options-row index means nothing there (Enter must not run an
        // unrelated command).
        let second = makeModel()
        second.selectedIndex = rowIndex(second, "Cursor Style") ?? -1
        second.submit()
        second.selectedIndex = 2
        second.cancel() // Esc inside the drill = exitDrill, never dismiss
        expect(second.drill == nil, "Esc leaves the drill")
        expect(
            second.results.count == 2 && second.results.first?.isOption == false,
            "exit-drill restores the command list, not stranded option rows"
        )
        expect(second.selectedIndex == 0, "exit-drill resets the selection")

        // Cross-scope selection reset: row 1 of actions means nothing in the
        // settings list.
        let third = makeModel()
        third.selectedIndex = 1
        third.handleFieldInput("#")
        expect(third.scope == .Settings, "'#' enters the settings scope")
        expect(third.selectedIndex == 0, "scope entry resets the selection")
        expect(third.handleDeleteBackward(), "backspace at empty sub-scope query returns to actions")
        expect(
            third.scope == .Actions && third.selectedIndex == 0,
            "scope exit restores actions with the selection reset"
        )

        expect(!ran, "no command ran as a side effect of drill/scope navigation")

        // VoiceOver announcement: an explicit keyboard move bumps the
        // announce token and the announcement names the row + its position.
        let voModel = makeModel()
        let tokenBefore = voModel.selectionAnnounceToken
        voModel.moveSelection(1)
        expect(
            voModel.selectionAnnounceToken == tokenBefore + 1,
            "a keyboard move bumps the announce token"
        )
        expect(
            voModel.selectionAnnouncement?.contains("2 of 2") == true,
            "the announcement carries the 1-based position (got \(String(describing: voModel.selectionAnnouncement)))"
        )

        // Secondary actions: → / ⌘⏎ on a row with them drills into an
        // actions list; running one applies that action and dismisses.
        var actionRan: String?
        let withActions = BeamCommand(
            title: "Block Row",
            group: "Test",
            identity: "test.actions",
            secondaryActions: [
                BeamOption(label: "Jump", apply: { actionRan = "jump" }),
                BeamOption(label: "Copy Command", apply: { actionRan = "copy" }),
            ],
            run: { actionRan = "primary" }
        )
        let plain = BeamCommand(
            title: "Plain Row",
            group: "Test",
            identity: "test.plain",
            run: {}
        )
        let actionsModel = BeamModel(
            palette: palette,
            sources: BeamSources(
                actions: [withActions, plain],
                settings: [],
                goTo: { [] },
                blocks: { [] },
                find: { _, _ in [] },
                findLastBlockAvailable: { false },
                terminalScopesAvailable: false
            )
        )
        actionsModel.selectedIndex = rowIndex(actionsModel, "Block Row") ?? -1
        expect(
            actionsModel.results[actionsModel.selectedIndex].hasSecondaryActions,
            "the row reports its secondary actions"
        )
        expect(actionsModel.enterRowActions(), "a row with actions enters the actions drill")
        expect(
            actionsModel.drill != nil && actionsModel.results.count == 2,
            "the actions drill lists both actions"
        )
        var actionsDismissed = false
        actionsModel.onDismiss = { actionsDismissed = true }
        actionsModel.selectedIndex = rowIndex(actionsModel, "Copy Command") ?? -1
        actionsModel.submit()
        expect(actionsDismissed, "running a secondary action dismisses")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(actionRan == "copy", "the SELECTED secondary action ran (got \(String(describing: actionRan)))")

        // A row without secondary actions doesn't enter the drill.
        let plainModel = BeamModel(
            palette: palette,
            sources: BeamSources(
                actions: [plain],
                settings: [],
                goTo: { [] },
                blocks: { [] },
                find: { _, _ in [] },
                findLastBlockAvailable: { false },
                terminalScopesAvailable: false
            )
        )
        plainModel.selectedIndex = 0
        expect(!plainModel.results[0].hasSecondaryActions, "a plain row has no secondary actions")
        expect(!plainModel.enterRowActions(), "a plain row does not enter an actions drill")

        // A DRILL command can also carry secondary actions (the settings
        // "Reveal in Settings" row): → opens the actions list, distinct from the
        // primary drill-in on Enter.
        var revealed = false
        let drillWithActions = BeamCommand(
            title: "Cursor Blink",
            group: "Test",
            identity: "test.drillactions",
            secondaryActions: [BeamOption(label: "Reveal", apply: { revealed = true })],
            drill: .options(current: 0, options: [BeamOption(label: "On", apply: {})])
        )
        let drillActionsModel = BeamModel(
            palette: palette,
            sources: BeamSources(
                actions: [drillWithActions],
                settings: [],
                goTo: { [] },
                blocks: { [] },
                find: { _, _ in [] },
                findLastBlockAvailable: { false },
                terminalScopesAvailable: false
            )
        )
        drillActionsModel.selectedIndex = 0
        expect(
            drillActionsModel.results[0].hasSecondaryActions,
            "a drill row reports its secondary actions"
        )
        expect(
            drillActionsModel.enterRowActions(),
            "→ on a drill row opens its actions, not its value drill"
        )
        expect(
            drillActionsModel.drill != nil && drillActionsModel.results.count == 1,
            "the actions drill lists the one reveal action"
        )
        drillActionsModel.onDismiss = {}
        drillActionsModel.selectedIndex = 0
        drillActionsModel.submit()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(revealed, "running the drill row's secondary action fired it")

        // Find "Last output" chip: toggling re-runs the query through
        // the find source with scopeToLastBlock flipped, and every scope entry
        // resets it to whole-scrollback.
        var lastFindScoped: Bool?
        let findModel = BeamModel(
            palette: palette,
            sources: BeamSources(
                actions: [],
                settings: [],
                goTo: { [] },
                blocks: { [] },
                find: { _, lastBlock in
                    lastFindScoped = lastBlock
                    return []
                },
                findLastBlockAvailable: { true },
                terminalScopesAvailable: true
            )
        )
        findModel.handleFieldInput("/")
        expect(findModel.scope == .Find, "'/' enters the find scope")
        expect(!findModel.findScopedToLastBlock, "find starts whole-scrollback")
        findModel.handleFieldInput("err") // seeds a query so find() runs
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        expect(lastFindScoped == false, "the first scan is whole-scrollback")
        findModel.toggleFindBlockScope()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        expect(findModel.findScopedToLastBlock, "toggle scopes find to the last block")
        expect(lastFindScoped == true, "the re-run scan is block-scoped")
        // Leaving and re-entering find resets the scope.
        findModel.cancel() // find → actions
        findModel.handleFieldInput("/")
        expect(!findModel.findScopedToLastBlock, "re-entering find resets to whole-scrollback")

        return failures
    }
}
