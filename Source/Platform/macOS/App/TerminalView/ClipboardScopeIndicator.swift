// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AppKit
import UbiquittyCore

/// Selects the clipboard that programs in the focused remote session can read.
@objc(UBClipboardScopeIndicator)
public final class ClipboardScopeIndicator: NSButton {
    /// Reports whether the focused session supports changing its clipboard source.
    public var canSelectLocal: (() -> Bool)?
    /// Reports whether the host has acknowledged the requested source.
    public var isChangingSource: (() -> Bool)?
    /// Describes why changing the source is unavailable.
    public var unavailableReason: (() -> String)?
    /// Requests client clipboard access when true, or revokes it when false.
    ///
    /// Returns whether Core accepted the request; the host acknowledgement updates ``scope``.
    public var selectLocal: ((Bool) -> Bool)?
    /// Announces an effective source change for the window carried as its object.
    @objc
    public static let didChangeNotification = Notification.Name("UBClipboardScopeDidChange")

    /// Places the selector beside the secure keyboard input indicator.
    @objc
    public static let priority = 90

    private weak var bar: ChromeAccessoryBar?
    private var observer: (any NSObjectProtocol)?

    /// Holds the effective source reported by Core for this window.
    public private(set) var scope: Ubiquitty.Clipboard.Scope = .local

    /// Exposes the Core enum to Objective-C callers.
    @objc
    public var scopeRawValue: Int { Int(scope.rawValue) }

    /// Installs a selector that becomes visible for remote sessions.
    @objc
    @discardableResult
    public static func install(in bar: ChromeAccessoryBar) -> ClipboardScopeIndicator {
        let indicator = ClipboardScopeIndicator(frame: NSRect(origin: .zero, size: ChromeAccessorySymbol.viewSize))
        indicator.bar = bar
        indicator.isHidden = true
        bar.add(indicator, priority: priority)
        indicator.observer = NotificationCenter.default.addObserver(
            forName: didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak indicator] notification in
            let notificationObject = notification.object
            let isBroadcast = notificationObject == nil
            let notifiedWindowIdentifier = (notificationObject as? NSWindow).map(ObjectIdentifier.init)
            let raw = notification.userInfo?["scope"] as? Int
            MainActor.assumeIsolated {
                guard let indicator, let bar = indicator.bar else { return }
                guard isBroadcast || notifiedWindowIdentifier == indicator.window.map(ObjectIdentifier.init) else {
                    return
                }
                guard let raw,
                    let scope = Ubiquitty.Clipboard.Scope(rawValue: UInt8(truncatingIfNeeded: raw))
                else {
                    return
                }
                indicator.apply(scope)
                bar.setShown(indicator, scope != .local)
            }
        }
        return indicator
    }

    /// Publishes the effective clipboard source for one window.
    public static func report(_ scope: Ubiquitty.Clipboard.Scope, for window: NSWindow?) {
        NotificationCenter.default.post(
            name: didChangeNotification,
            object: window,
            userInfo: ["scope": Int(scope.rawValue)]
        )
    }

    /// Publishes a Core scope supplied through the Objective-C boundary.
    @objc(reportRawScope:forWindow:)
    public static func reportRawScope(_ rawScope: Int, for window: NSWindow?) {
        guard let scope = Ubiquitty.Clipboard.Scope(rawValue: UInt8(truncatingIfNeeded: rawScope)) else {
            return
        }
        report(scope, for: window)
    }

    /// Creates a borderless, accessible clipboard source button.
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = ChromeAccessorySymbolButtonCell()
        imageScaling = .scaleNone
        isBordered = false
        imagePosition = .imageOnly
        title = ""
        target = self
        action = #selector(showScopeMenu)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        apply(.local)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClipboardScopeIndicator is built in code")
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc
    private func showScopeMenu() {
        let menu = NSMenu(title: "Clipboard Source")
        menu.autoenablesItems = false
        let remote = NSMenuItem(title: "Remote Machine", action: #selector(selectRemoteClipboard), keyEquivalent: "")
        remote.target = self
        remote.state = scope == .host ? .on : .off
        remote.isEnabled = selectLocal != nil
        menu.addItem(remote)
        let local = NSMenuItem(title: "This Mac — Text and Images", action: #selector(selectLocalClipboard), keyEquivalent: "")
        local.target = self
        local.state = scope == .client ? .on : .off
        local.isEnabled = scope == .client || canSelectLocal?() == true
        menu.addItem(local)
        menu.addItem(.separator())
        if isChangingSource?() == true {
            let pending = NSMenuItem(title: "Changing Clipboard Source…", action: nil, keyEquivalent: "")
            pending.isEnabled = false
            menu.addItem(pending)
        }
        let detail = NSMenuItem(title: "Used by clipboard tools in this session.", action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        if !local.isEnabled {
            let unavailable = NSMenuItem(
                title: unavailableReason?() ?? "Clipboard source controls are unavailable.",
                action: nil,
                keyEquivalent: ""
            )
            unavailable.isEnabled = false
            menu.addItem(unavailable)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
    }

    @objc
    private func selectRemoteClipboard() {
        if selectLocal?(false) != true { NSSound.beep() }
    }

    @objc
    private func selectLocalClipboard() {
        if selectLocal?(true) != true { NSSound.beep() }
    }

    private func apply(_ scope: Ubiquitty.Clipboard.Scope) {
        self.scope = scope
        switch scope {
        case .local:
            image = nil
            toolTip = nil
            setAccessibilityLabel(nil)
        case .host:
            image = ChromeAccessorySymbol.image(
                named: "clipboard",
                description: "Programs here read the remote machine’s clipboard"
            )
            contentTintColor = .secondaryLabelColor
            toolTip = "Clipboard source: Remote Machine. Click to change."
            setAccessibilityLabel("Remote programs read the remote clipboard")
        case .client:
            image = ChromeAccessorySymbol.image(
                named: "clipboard.fill",
                description: "Programs on the remote machine can read this Mac’s clipboard"
            )
            contentTintColor = .systemOrange
            toolTip = "Clipboard source: This Mac, including images. Click to change."
            setAccessibilityLabel("Remote programs can read this Mac’s clipboard")
        }
    }
}
