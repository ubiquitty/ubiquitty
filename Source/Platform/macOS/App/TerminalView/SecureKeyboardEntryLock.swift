// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// SecureKeyboardEntryLock.swift — the title-bar lock that shows while the
// app holds Secure Keyboard Entry, the way Terminal does.
//
// The lock states a process-wide fact: while it shows, no other process can
// read what is typed into any window of the app — under the standing
// preference, or for a pane at a password prompt. The holder of the resource
// (`SecureInput`, in the app module) records the state here and posts the
// change; every window's lock follows.
//
@preconcurrency import AppKit

/// The lock in a window's accessory bar.
@objc(UBSecureKeyboardEntryLock)
public final class SecureKeyboardEntryLock: NSImageView {
    /// Posted by the holder when ``isHeld`` changed.
    @objc
    public static let didChangeNotification = Notification.Name("UBSecureKeyboardEntryDidChange")

    /// Whether the app holds Secure Keyboard Entry right now. Written by the
    /// holder before it posts ``didChangeNotification``; read by a lock when
    /// it is installed, so a window opened under a held lock shows it.
    ///
    /// Main-actor isolated through the class, which inherits it from
    /// NSImageView: the holder (`SecureInput`, itself main-actor) and every
    /// installed lock read and write it on the main thread, so the isolation
    /// the compiler checks is the confinement the callers already keep.
    @objc
    public static var isHeld = false

    /// The lock's place in the row: nearest the edge, where Terminal puts its own.
    @objc
    public static let priority = 100

    private weak var bar: ChromeAccessoryBar?

    /// Puts a lock into a bar and keeps it in step with ``isHeld``.
    ///
    /// - Parameter bar: The window's accessory bar.
    /// - Returns: The installed lock.
    @objc
    @discardableResult
    public static func install(in bar: ChromeAccessoryBar) -> SecureKeyboardEntryLock {
        let lock = SecureKeyboardEntryLock(frame: NSRect(origin: .zero, size: ChromeAccessorySymbol.viewSize))
        lock.bar = bar
        lock.isHidden = !isHeld
        bar.add(lock, priority: priority)
        NotificationCenter.default.addObserver(
            lock,
            selector: #selector(SecureKeyboardEntryLock.applyHeldState),
            name: didChangeNotification,
            object: nil
        )
        return lock
    }

    /// Shows or hides the lock in its bar according to ``isHeld``.
    ///
    /// The notification carries no payload: ``isHeld`` is a process-wide fact
    /// every window's lock reads for itself.
    @objc
    private func applyHeldState() {
        guard let bar else { return }
        bar.setShown(self, Self.isHeld)
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = ChromeAccessorySymbol.image(named: "lock.fill", description: "Secure Keyboard Entry is on")
        imageScaling = .scaleNone
        imageAlignment = .alignCenter
        // Ambient state uses quieter ink than the adjacent clipboard control.
        contentTintColor = .tertiaryLabelColor
        toolTip = "Secure Keyboard Entry is on: other apps can’t read what you type here."
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Secure Keyboard Entry is on")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SecureKeyboardEntryLock is built in code")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
