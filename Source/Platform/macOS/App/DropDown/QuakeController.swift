// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// QuakeController.swift — the drop-down ("quake") terminal: one window toggled
// by a global hotkey that slides down from the top of the active screen, floats
// above other apps, and hides when it loses key focus.
//
// It owns a global Carbon hotkey (RegisterEventHotKey, so it fires even when
// another app is frontmost and needs no Accessibility permission) and a single
// lazily made terminal window restyled as a borderless floating panel. The app
// delegate makes one at launch when `[quake] enabled` is set and hands it a
// configuration reload.
//

import AppKit
import Carbon
internal import UbiquittyCore

/// The drop-down terminal and its global hotkey.
@objc(UBQuakeController)
@MainActor
public final class QuakeController: NSObject {
    /// The single hotkey identity the app registers; the handler routes the
    /// press back here through its user data.
    private static let hotkeySignature: OSType = 0x5542_716B // 'UBqk'

    private var windowControllerStorage: NSWindowController?
    private var hotkey: EventHotKeyRef?
    private var hotkeyHandler: EventHandlerRef?
    private var registeredChord: QuakeHotkey?
    private var heightFraction = 0.0
    private var animates = true
    private var isShown = false
    /// Set during this controller's own slide-out, so the resign-key auto-hide
    /// does not answer it.
    private var isAnimatingHide = false

    /// Brings the application forward before the panel shows, so the panel
    /// takes key focus over whatever app was frontmost.
    ///
    /// A UI scenario replaces it with nothing: a run must not bring the app in
    /// front of the machine it runs on.
    public var activateApplication: @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }

    /// The visible frame of the screen the panel drops onto: the screen under
    /// the mouse, where the reader is looking, else the main screen. Nil when no
    /// screen is attached.
    ///
    /// A UI scenario replaces it with a frame off every screen.
    public var dropScreenFrame: @MainActor () -> NSRect? = {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSPointInRect(mouse, $0.frame) } ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame
    }

    /// Makes the controller and registers the toggle hotkey from the live
    /// `[quake]` configuration.
    ///
    /// - Returns: Nil when `[quake] enabled` is off, or the configured hotkey
    ///   cannot be read or registered; the delegate then owns no controller.
    @objc(controllerIfEnabled)
    public static func controllerIfEnabled() -> QuakeController? {
        let values = Ubiquitty.Preferences.values().pointee
        guard Ubiquitty.Preferences.Effective.quakeEnabled(values) else { return nil }
        let controller = QuakeController()
        controller.heightFraction = Ubiquitty.Preferences.Effective.quakeHeight(values)
        controller.animates = Ubiquitty.Preferences.Effective.quakeAnimate(values)
        return controller.registerHotkeyFromPreferences() ? controller : nil
    }

    private override init() {
        super.init()
    }

    isolated deinit {
        unregisterHotkey()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Hotkey registration

    private func registerHotkeyFromPreferences() -> Bool {
        let spec = String(Ubiquitty.Preferences.Effective.quakeHotkey(Ubiquitty.Preferences.values().pointee))
        guard let chord = QuakeHotkey(spec: spec) else { return false }
        if hotkey != nil, chord == registeredChord {
            return true
        }
        unregisterHotkey()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let controller = Unmanaged<QuakeController>.fromOpaque(userData).takeUnretainedValue()
            // On the main queue, asynchronously: AppKit window work is main-thread
            // work, and the handler can already be running inside the main run loop.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller.toggle() }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotkeyHandler)

        let identity = EventHotKeyID(signature: Self.hotkeySignature, id: 1)
        let status = RegisterEventHotKey(chord.keyCode, chord.modifiers, identity, GetApplicationEventTarget(), 0, &hotkey)
        guard status == noErr else {
            hotkey = nil
            if let hotkeyHandler {
                RemoveEventHandler(hotkeyHandler)
                self.hotkeyHandler = nil
            }
            return false
        }
        registeredChord = chord
        return true
    }

    private func unregisterHotkey() {
        if let hotkey {
            UnregisterEventHotKey(hotkey)
            self.hotkey = nil
        }
        if let hotkeyHandler {
            RemoveEventHandler(hotkeyHandler)
            self.hotkeyHandler = nil
        }
        registeredChord = nil
    }

    /// Reads `[quake]` again: registers the hotkey anew when it changed,
    /// derives the panel height, and places a showing panel again.
    ///
    /// - Returns: False when `[quake] enabled` turned off; the hotkey is gone
    ///   and the delegate drops the controller.
    @objc
    public func reloadFromPreferences() -> Bool {
        let values = Ubiquitty.Preferences.values().pointee
        guard Ubiquitty.Preferences.Effective.quakeEnabled(values) else {
            unregisterHotkey()
            return false
        }
        heightFraction = Ubiquitty.Preferences.Effective.quakeHeight(values)
        animates = Ubiquitty.Preferences.Effective.quakeAnimate(values)
        _ = registerHotkeyFromPreferences()
        if isShown {
            placePanel(in: dropScreenFrame(), visible: true)
        }
        return true
    }

    // MARK: - Panel lifecycle

    /// The panel's controller, or nil before it is first shown.
    @objc
    public var windowController: NSWindowController? { windowControllerStorage }

    /// Whether the panel is on screen, not mid-hide. The menu item's checkmark.
    @objc
    public var isVisible: Bool { isShown }

    /// Builds the panel on first show, restyled as a borderless, full-width
    /// floating drop-down that joins every Space.
    private func ensureWindowController() {
        guard windowControllerStorage == nil else { return }
        guard let controller = TerminalWindowController.spawnUnshownPanel(), let window = controller.window else { return }
        windowControllerStorage = controller
        // Above ordinary windows even when another app is frontmost, and on
        // every Space and beside a full-screen app. Joining every Space already
        // brings it to the active one; AppKit refuses moveToActiveSpace beside
        // canJoinAllSpaces with an assertion, which ended the app on the
        // panel's first show.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        // Not part of the roster: out of the Window menu and the tab group.
        window.isExcludedFromWindowsMenu = true
        window.tabbingMode = .disallowed
        window.title = "Quake Terminal"
        // Losing key focus hides the panel, which is what a drop-down is.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResignedKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        // A panel the reader closes is forgotten, so the next toggle makes a
        // fresh one instead of reaching for a dead window.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    /// The panel's on-screen frame: the screen's full width, `heightFraction`
    /// of its visible height, flush below the menu bar.
    ///
    /// - Parameter screenFrame: The screen's visible frame.
    /// - Returns: The frame.
    public func shownFrame(in screenFrame: NSRect?) -> NSRect {
        let visible = screenFrame ?? .zero
        let height = visible.size.height * heightFraction
        return NSRect(x: visible.origin.x, y: visible.maxY - height, width: visible.size.width, height: height)
    }

    /// The panel's parked frame: wholly above the screen's top edge.
    ///
    /// - Parameter screenFrame: The screen's visible frame.
    /// - Returns: The frame.
    public func parkedFrame(in screenFrame: NSRect?) -> NSRect {
        var frame = shownFrame(in: screenFrame)
        frame.origin.y += frame.size.height
        return frame
    }

    private func placePanel(in screenFrame: NSRect?, visible: Bool) {
        guard let window = windowControllerStorage?.window else { return }
        window.setFrame(visible ? shownFrame(in: screenFrame) : parkedFrame(in: screenFrame), display: true)
    }

    /// Shows a hidden panel and hides a showing one; the hotkey's action.
    @objc
    public func toggle() {
        if isShown {
            hidePanel()
        } else {
            showPanel()
        }
    }

    /// Slides the panel down from the active screen's top and makes it key.
    @objc
    public func showPanel() {
        ensureWindowController()
        guard let window = windowControllerStorage?.window else { return }
        let screen = dropScreenFrame()
        activateApplication()
        if animates {
            window.setFrame(parkedFrame(in: screen), display: false)
            window.makeKeyAndOrderFront(nil)
            let target = shownFrame(in: screen)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().setFrame(target, display: true)
            }
        } else {
            window.setFrame(shownFrame(in: screen), display: true)
            window.makeKeyAndOrderFront(nil)
        }
        isShown = true
    }

    /// Slides the panel back up and orders it out.
    @objc
    public func hidePanel() {
        guard let window = windowControllerStorage?.window, isShown else { return }
        isShown = false
        guard animates else {
            window.orderOut(nil)
            return
        }
        isAnimatingHide = true
        let parked = parkedFrame(in: dropScreenFrame())
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.12
                window.animator().setFrame(parked, display: true)
            },
            completionHandler: { [weak self] in
                // AppKit runs the group's completion on the main thread.
                MainActor.assumeIsolated {
                    window.orderOut(nil)
                    self?.isAnimatingHide = false
                }
            }
        )
    }

    @objc
    private func windowResignedKey(_ notification: Notification) {
        // Neither this controller's own slide-out nor a stray resign while hidden.
        guard isShown, !isAnimatingHide else { return }
        hidePanel()
    }

    @objc
    private func windowWillClose(_ notification: Notification) {
        guard let window = windowControllerStorage?.window, (notification.object as? NSWindow) === window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        windowControllerStorage = nil
        isShown = false
    }
}
