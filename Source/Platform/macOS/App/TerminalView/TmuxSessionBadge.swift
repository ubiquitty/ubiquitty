// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// TmuxSessionBadge.swift — the "tmux <session>" pill a window wears while it
// shows a tmux -CC session's window.
//
// Every window of a session is one unit, so the pill's colour belongs to the
// session: keyed by its name, stored as a palette index, and handed to every
// window of the session the moment a reader picks one. Which fill a session
// takes before anyone picks, and which ink reads on a fill, are Core's
// (Source/Core/Runtime/TmuxSessionBadge.h); this view paints the answers and
// asks the reader for a pick.

@preconcurrency import AppKit
import UbiquittyCore

// The badge's colour rule, which both shells paint.
private typealias BadgePolicy = Ubiquitty.Runtime

/// The session pill in a tmux-hosted window's accessory bar.
///
/// One pill for every window kind: each names its session through this
/// entry, so a session's colour cannot differ between windows.
@objc(UBTmuxSessionBadge)
public final class TmuxSessionBadge: NSView {
    /// Left of the broadcast pill and right of the teaching hint: the pill says
    /// what the window is, which outranks a lesson and yields to a mode the
    /// reader turned on.
    public static let priority = 50

    /// The defaults key picks are stored under: a dictionary from session
    /// name to palette index. Every pill reads and writes this one key, so a
    /// pick made in one window holds in all.
    public static let colorsDefaultsKey = "UBTmuxBadgeColors"

    /// Posted when a reader picks a session's colour, carrying the session's
    /// name under "identity" and the palette index under "index". Every pill
    /// posts and answers this name.
    public static let colorDidChangeNotification = Notification.Name("UBTmuxBadgeColorChanged")

    private enum Metrics {
        /// The "tmux" marker's type; the name beside it is a step larger and
        /// heavier, so the pair reads as a hierarchy without a separator.
        static let markerPointSize: CGFloat = 9.5
        static let namePointSize: CGFloat = 10
        /// How much of the ink the marker keeps.
        static let markerAlpha: CGFloat = 0.7
        static let paddingBesideText: CGFloat = 7
        static let paddingAboveText: CGFloat = 2
        /// The capsule sits a little above the row's centre, where the eye puts
        /// the middle of a title next to the traffic lights.
        static let liftAboveCentre: CGFloat = 2
        /// The picker's swatches.
        static let swatchSide: CGFloat = 22
        static let swatchGap: CGFloat = 6
        static let pickerInset: CGFloat = 8
    }

    /// The session the pill names.
    public private(set) var sessionName: String

    /// The palette index the pill is painted with.
    public private(set) var colorIndex: Int

    private let label = NSTextField(frame: .zero)
    private var picker: NSPopover?

    /// Names a window's session in its bar, making the pill the first time.
    ///
    /// The bar owns its accessories, so the pill is found there rather than
    /// remembered beside it. A renamed session re-typesets the pill and keeps
    /// its colour: the session is the same unit under a new name. An empty
    /// name hides the pill.
    ///
    /// - Parameters:
    ///   - sessionName: The tmux session's name.
    ///   - bar: The window's accessory bar.
    /// - Returns: The pill, or nil when there is no session to name.
    @discardableResult
    @objc(setSession:inBar:)
    public static func setSession(_ sessionName: String, in bar: ChromeAccessoryBar) -> TmuxSessionBadge? {
        let name = sessionName.trimmingCharacters(in: .whitespaces)
        let existing = badge(in: bar)
        guard !name.isEmpty else {
            if let existing {
                bar.setShown(existing, false)
            }
            return nil
        }
        guard let existing else {
            let badge = TmuxSessionBadge(sessionName: name)
            bar.add(badge, priority: priority)
            return badge
        }
        if existing.sessionName != name {
            existing.sessionName = name
            existing.typeset()
            bar.relayout()
        }
        bar.setShown(existing, true)
        return existing
    }

    /// The pill a bar holds, if any.
    ///
    /// - Parameter bar: A window's accessory bar.
    /// - Returns: The pill, or nil for a window that never named a session.
    public static func badge(in bar: ChromeAccessoryBar) -> TmuxSessionBadge? {
        bar.subviews.compactMap { $0 as? TmuxSessionBadge }.first
    }

    /// The index a session's pill shows: the stored pick, or Core's default
    /// for the name when none is stored.
    ///
    /// - Parameter sessionName: The session.
    /// - Returns: A palette index.
    public static func colorIndex(forSession sessionName: String) -> Int {
        let picks = UserDefaults.standard.dictionary(forKey: colorsDefaultsKey)
        let stored = (picks?[sessionName] as? NSNumber)?.intValue ?? -1
        return sessionName.withCString { bytes in
            Int(BadgePolicy.resolveTmuxSessionBadgeColorIndex(std.string_view(bytes), Int32(clamping: stored)))
        }
    }

    /// The fill at a palette index, as the pill paints it.
    ///
    /// - Parameter index: A palette index.
    /// - Returns: The sRGB colour.
    public static func fill(at index: Int) -> NSColor {
        color(BadgePolicy.tmuxSessionBadgeFill(Int32(clamping: index)))
    }

    /// The ink that reads on the fill at a palette index.
    ///
    /// - Parameter index: A palette index.
    /// - Returns: The sRGB colour.
    public static func ink(at index: Int) -> NSColor {
        color(BadgePolicy.tmuxSessionBadgeLabel(Int32(clamping: index)))
    }

    /// How many fills the picker offers.
    public static var paletteCount: Int {
        Int(BadgePolicy.tmuxSessionBadgePaletteCount)
    }

    private static func color(_ packed: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((packed >> 16) & 0xFF) / 255,
            green: CGFloat((packed >> 8) & 0xFF) / 255,
            blue: CGFloat(packed & 0xFF) / 255,
            alpha: 1
        )
    }

    private init(sessionName: String) {
        self.sessionName = sessionName
        colorIndex = Self.colorIndex(forSession: sessionName)
        super.init(frame: .zero)
        wantsLayer = true
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.isBezeled = false
        label.drawsBackground = false
        addSubview(label)
        // Selector-based, so the registration ends with the view.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionColorDidChange(_:)),
            name: Self.colorDidChangeNotification,
            object: nil
        )
        typeset()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TmuxSessionBadge is built in code")
    }

    /// The text the pill shows, for a caller checking what it names.
    public var text: String {
        label.stringValue
    }

    /// The ink the pill's name is set in.
    public var nameInk: NSColor? {
        let attributed = label.attributedStringValue
        guard attributed.length > 0 else { return nil }
        return attributed.attribute(.foregroundColor, at: attributed.length - 1, effectiveRange: nil) as? NSColor
    }

    /// Paints a palette index and re-sets the text in the ink that reads on it.
    private func applyColorIndex(_ index: Int) {
        colorIndex = index
        typeset()
    }

    /// Sets the text, sizes the capsule around it, and paints the fill.
    private func typeset() {
        let scale = CGFloat(ChromeTypography.scaled(1.0))
        let ink = Self.ink(at: colorIndex)
        let text = NSMutableAttributedString(
            string: "tmux ",
            attributes: [
                .font: NSFont.systemFont(ofSize: Metrics.markerPointSize * scale, weight: .regular),
                .foregroundColor: ink.withAlphaComponent(Metrics.markerAlpha),
            ]
        )
        text.append(
            NSAttributedString(
                string: sessionName,
                attributes: [
                    .font: NSFont.systemFont(ofSize: Metrics.namePointSize * scale, weight: .semibold),
                    .foregroundColor: ink,
                ]
            )
        )
        label.attributedStringValue = text
        label.sizeToFit()
        let textSize = label.frame.size
        let pillSize = NSSize(
            width: textSize.width + Metrics.paddingBesideText * 2,
            height: textSize.height + Metrics.paddingAboveText * 2
        )
        label.frame = NSRect(
            x: Metrics.paddingBesideText,
            y: Metrics.paddingAboveText,
            width: textSize.width,
            height: textSize.height
        )
        frame = NSRect(
            x: frame.origin.x,
            y: (ChromeAccessoryBar.titleRowHeightInPoints - pillSize.height) / 2 + Metrics.liftAboveCentre,
            width: pillSize.width,
            height: pillSize.height
        )
        layer?.cornerRadius = pillSize.height / 2
        layer?.backgroundColor = Self.fill(at: colorIndex).cgColor
    }

    /// Stores a pick for the session, tells every window of the session, and
    /// paints it here.
    ///
    /// - Parameter index: The palette index the reader chose.
    public func pickColor(_ index: Int) {
        guard index >= 0, index < Self.paletteCount else { return }
        var picks = UserDefaults.standard.dictionary(forKey: Self.colorsDefaultsKey) ?? [:]
        picks[sessionName] = index
        UserDefaults.standard.set(picks, forKey: Self.colorsDefaultsKey)
        applyColorIndex(index)
        NotificationCenter.default.post(
            name: Self.colorDidChangeNotification,
            object: nil,
            userInfo: ["identity": sessionName, "index": index]
        )
        picker?.close()
    }

    @objc
    private func sessionColorDidChange(_ notification: Notification) {
        guard let identity = notification.userInfo?["identity"] as? String, identity == sessionName,
            let index = (notification.userInfo?["index"] as? NSNumber)?.intValue,
            index != colorIndex
        else {
            return
        }
        applyColorIndex(index)
    }

    override public func mouseDown(with event: NSEvent) {
        togglePicker()
    }

    // A press on the pill opens the picker; the title row around it still
    // drags the window.
    override public var mouseDownCanMoveWindow: Bool { false } // bool-ok: AppKit override

    /// Opens the swatch picker under the pill, or closes it when it stands.
    public func togglePicker() {
        if let picker, picker.isShown {
            picker.close()
            return
        }
        let count = Self.paletteCount
        let width = Metrics.pickerInset * 2 + CGFloat(count) * Metrics.swatchSide + CGFloat(count - 1) * Metrics.swatchGap
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.pickerInset * 2 + Metrics.swatchSide))
        for index in 0..<count {
            let swatch = NSButton(
                frame: NSRect(
                    x: Metrics.pickerInset + CGFloat(index) * (Metrics.swatchSide + Metrics.swatchGap),
                    y: Metrics.pickerInset,
                    width: Metrics.swatchSide,
                    height: Metrics.swatchSide
                )
            )
            swatch.isBordered = false
            swatch.title = ""
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = Metrics.swatchSide / 2
            swatch.layer?.backgroundColor = Self.fill(at: index).cgColor
            if index == colorIndex {
                // The current pick wears a ring.
                swatch.layer?.borderWidth = 2
                swatch.layer?.borderColor = NSColor.labelColor.cgColor
            }
            swatch.tag = index
            swatch.target = self
            swatch.action = #selector(swatchPressed(_:))
            content.addSubview(swatch)
        }
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.contentSize = content.frame.size
        picker = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    /// The open picker's swatches, for a caller choosing the way a reader
    /// does. Empty until the pill has been asked for its picker.
    public var pickerSwatches: [NSButton] {
        guard let content = picker?.contentViewController?.view else { return [] }
        return content.subviews.compactMap { $0 as? NSButton }
    }

    @objc
    private func swatchPressed(_ sender: NSButton) {
        pickColor(sender.tag)
    }
}
