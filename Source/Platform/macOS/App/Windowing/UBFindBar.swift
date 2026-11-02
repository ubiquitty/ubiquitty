// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// UBFindBar.swift — the native ⌘F find-bar view. It owns the AppKit chrome —
// search field, prev/next segmented control, status label, Done button,
// hairline separator, layout, the search-field menu (case / regex / recents),
// recents persistence, and the theme tint — and reports intent through
// UBFindBarDelegate. The window controller keeps the business logic
// (ScrollSearch, grid inset, selection handoff, the find-pop) and implements the
// delegate; the bar is a dumb, self-laying-out view.

import AppKit

/// Intent callbacks from the find bar to its owner (the window controller). All
/// terminal/search logic lives on the other side of this seam.
@objc
@MainActor
public protocol UBFindBarDelegate: AnyObject {
    /// The query text changed (live, per keystroke) — re-run the search.
    func findBarQueryDidChange(_ query: String)
    /// Advance to the next / previous match (segmented control, ⌘G, or Enter).
    func findBarFindNext()
    func findBarFindPrevious()
    /// Dismiss the bar (Done button or Esc).
    func findBarClose()
    /// A toggle flipped; the owner persists it and re-runs the search.
    func findBarSetRegex(_ on: Bool)
    func findBarSetCaseSensitive(_ on: Bool)
}

@objc(UBFindBar)
public final class UBFindBar: NSView, NSSearchFieldDelegate {
    @objc
    public weak var findDelegate: UBFindBarDelegate?

    private let field = NSSearchField(frame: .zero)
    private let steps: NSSegmentedControl
    private let status = NSTextField(labelWithString: "")
    private let done: NSButton
    private let hairline = NSBox(frame: NSRect(x: 0, y: 0, width: 10, height: 1))

    // Persisted, field-local recents (Feature B): survives relaunch via the
    // autosave name; most-recent-first, deduped, capped.
    private static let recentsAutosaveName = "UBFindRecents"
    private static let recentsMaxCount = 12

    /// Live toggle state, mirrored onto the search-field menu checkmarks. The
    /// owner holds the canonical persisted values and pushes them in via
    /// `setCaseSensitive` / `setRegex`.
    private var caseSensitive = false
    private var regex = false

    // MARK: - Construction

    @objc
    override public init(frame frameRect: NSRect) {
        steps = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous")
                    ?? NSImage(),
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next")
                    ?? NSImage(),
            ],
            trackingMode: .momentary,
            target: nil,
            action: nil
        )
        done = NSButton(title: "Done", target: nil, action: nil)
        super.init(frame: frameRect)
        wantsLayer = true
        buildControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private func buildControls() {
        hairline.boxType = .separator
        hairline.autoresizingMask = [.width, .maxYMargin]

        done.bezelStyle = .rounded
        done.controlSize = .small
        done.target = self
        done.action = #selector(doneClicked)
        done.sizeToFit()
        var doneFrame = done.frame
        doneFrame.size.width = max(52.0, doneFrame.size.width)
        done.frame = doneFrame
        done.autoresizingMask = .minXMargin

        steps.controlSize = .small
        steps.target = self
        steps.action = #selector(stepClicked(_:))
        steps.sizeToFit()
        steps.autoresizingMask = .minXMargin

        status.font = .monospacedDigitSystemFont(ofSize: 11.0, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.sizeToFit()
        status.autoresizingMask = .minXMargin

        field.controlSize = .regular
        field.delegate = self
        // Live search is driven by controlTextDidChange (NSControlTextEditingDelegate,
        // fires on every keystroke), not the field's own target/action — sendsWholeSearchString
        // = true confines `field.action` (fieldSubmit, a COMMIT handler: records to recents +
        // steps to the next match) to Return/magnifier-click. Clearing it would fire fieldSubmit
        // on every keystroke too, double-stepping the match and polluting recents with partial text.
        field.sendsWholeSearchString = true
        (field.cell as? NSSearchFieldCell)?.placeholderString = "Find"
        field.recentsAutosaveName = Self.recentsAutosaveName
        field.maximumRecents = Self.recentsMaxCount
        field.searchMenuTemplate = buildSearchMenuTemplate()
        field.target = self
        field.action = #selector(fieldSubmit)
        field.autoresizingMask = .width

        addSubview(hairline)
        addSubview(field)
        addSubview(status)
        addSubview(steps)
        addSubview(done)
    }

    // MARK: - Layout
    // Field fills from the left; status · prev/next · Done pinned right; hairline
    // is the bottom separator. Matches the former ub_layoutFindBarControls.

    override public func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutControls()
    }

    override public func layout() {
        super.layout()
        layoutControls()
    }

    /// The search field's height, and so the least height at which this bar has
    /// a layout: below it the controls would take negative origins.
    private static let fieldHeight: CGFloat = 22.0

    private func layoutControls() {
        let w = bounds.width
        let h = bounds.height
        let fieldHeight = Self.fieldHeight
        // A strip too short to hold the field shows nothing, and this is where
        // that is decided rather than in whoever sized it. Every control below
        // is centred on `h / 2`, so at h = 0 the field lands at y = -11 with
        // height 22 — and an NSView does not clip its subviews, so half of it
        // draws above the bar. A caller that collapses this to close it would
        // otherwise have to know to hide it too, and the one that did not left
        // a strip of controls over the terminal.
        isHidden = h < fieldHeight
        guard !isHidden else {
            return
        }
        let pad: CGFloat = 8.0
        let gap: CGFloat = 8.0
        hairline.frame = NSRect(x: 0, y: 0, width: w, height: 1)
        var x = w - pad

        x -= done.frame.width
        done.frame = NSRect(
            x: x,
            y: (h - done.frame.height) / 2.0,
            width: done.frame.width,
            height: done.frame.height
        )
        x -= gap + steps.frame.width
        steps.frame = NSRect(
            x: x,
            y: (h - steps.frame.height) / 2.0,
            width: steps.frame.width,
            height: steps.frame.height
        )
        status.sizeToFit()
        x -= gap + status.frame.width
        status.frame = NSRect(
            x: x,
            y: (h - status.frame.height) / 2.0,
            width: status.frame.width,
            height: status.frame.height
        )
        field.frame = NSRect(
            x: pad,
            y: (h - fieldHeight) / 2.0,
            width: max(80.0, x - gap - pad),
            height: fieldHeight
        )
    }

    // MARK: - Search-field menu (case / regex / recents)

    private func buildSearchMenuTemplate() -> NSMenu {
        let menu = NSMenu(title: "Find")

        // No keyEquivalent: this menu is a searchMenuTemplate — AppKit copies it into a
        // popup shown only from the magnifier icon, never installed in NSApp.mainMenu, so
        // a key equivalent here is never matched by the global dispatch chain and would
        // only mislead with a shortcut hint that does nothing.
        let caseItem = NSMenuItem(
            title: "Case Sensitive",
            action: #selector(toggleCaseSensitive),
            keyEquivalent: ""
        )
        caseItem.target = self
        caseItem.state = caseSensitive ? .on : .off
        menu.addItem(caseItem)

        let regexItem = NSMenuItem(
            title: "Regular Expression",
            action: #selector(toggleRegex),
            keyEquivalent: ""
        )
        regexItem.target = self
        regexItem.state = regex ? .on : .off
        menu.addItem(regexItem)

        menu.addItem(.separator())

        let recentsTitle = NSMenuItem(title: "Recent Searches", action: nil, keyEquivalent: "")
        recentsTitle.tag = Int(NSSearchField.recentsTitleMenuItemTag)
        menu.addItem(recentsTitle)

        let recentsItem = NSMenuItem(title: "Recents", action: nil, keyEquivalent: "")
        recentsItem.tag = Int(NSSearchField.recentsMenuItemTag)
        menu.addItem(recentsItem)

        let clearItem = NSMenuItem(title: "Clear Recents", action: nil, keyEquivalent: "")
        clearItem.tag = Int(NSSearchField.clearRecentsMenuItemTag)
        menu.addItem(clearItem)

        return menu
    }

    // MARK: - Owner-facing API (called by the window controller)

    /// The current query text.
    @objc
    public var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// Give the field first-responder focus and select any existing text
    /// (⌘F-again replaces). Returns the field so the owner can makeFirstResponder.
    @objc
    public func focusField(inWindow window: NSWindow?) {
        window?.makeFirstResponder(field)
        if !field.stringValue.isEmpty {
            field.selectText(nil)
        }
    }

    @objc
    public func setStatus(_ text: String) { status.stringValue = text }

    /// Fill the bar with the theme's chrome-band tint (matches the tab strip).
    @objc
    public func applyTint(_ color: NSColor) {
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    @objc
    public func setCaseSensitive(_ on: Bool) {
        caseSensitive = on
        field.searchMenuTemplate = buildSearchMenuTemplate()
    }

    @objc
    public func setRegex(_ on: Bool) {
        regex = on
        field.searchMenuTemplate = buildSearchMenuTemplate()
    }

    /// Commit the current query into the field's recents history (deduped, capped).
    /// Called on a real commit (Enter / blur), not on live keystrokes.
    @objc
    public func recordRecent() {
        let queryText = field.stringValue
        guard !queryText.isEmpty else { return }
        var recents = field.recentSearches
        recents.removeAll { $0.caseInsensitiveCompare(queryText) == .orderedSame }
        recents.insert(queryText, at: 0)
        if recents.count > Self.recentsMaxCount {
            recents = Array(recents.prefix(Self.recentsMaxCount))
        }
        field.recentSearches = recents
    }

    // MARK: - Control actions

    @objc
    private func doneClicked() { findDelegate?.findBarClose() }

    @objc
    private func stepClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            findDelegate?.findBarFindPrevious()
        } else {
            findDelegate?.findBarFindNext()
        }
    }

    @objc
    private func fieldSubmit() {
        recordRecent()
        findDelegate?.findBarFindNext()
    }

    // Rebuild the template (via set*) rather than mutating the invoked NSMenuItem's
    // .state directly — that item is a transient copy AppKit made to display the popup,
    // not the stored searchMenuTemplate, so a direct mutation is invisible the next time
    // the magnifier menu opens. Rebuilding keeps the stored template's checkmark current.
    @objc
    private func toggleCaseSensitive(_ sender: NSMenuItem) {
        setCaseSensitive(!caseSensitive)
        findDelegate?.findBarSetCaseSensitive(caseSensitive)
    }

    @objc
    private func toggleRegex(_ sender: NSMenuItem) {
        setRegex(!regex)
        findDelegate?.findBarSetRegex(regex)
    }

    // MARK: - NSSearchFieldDelegate / NSControlTextEditingDelegate

    public func controlTextDidChange(_ obj: Notification) {
        findDelegate?.findBarQueryDidChange(field.stringValue)
    }

    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy command: Selector
    ) -> Bool {
        if command == #selector(NSResponder.insertNewline(_:)) {
            recordRecent()
            findDelegate?.findBarFindNext()
            return true
        }
        if command == #selector(NSResponder.cancelOperation(_:)) { // Esc
            findDelegate?.findBarClose()
            return true
        }
        return false
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        recordRecent()
    }
}
