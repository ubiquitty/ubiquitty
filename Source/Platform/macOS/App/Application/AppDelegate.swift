// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// AppDelegate.swift — the application delegate: startup, the application
// menus, the windows' shared state and the settings window's write-through.
//
// On launch it installs the process-wide platform context, reads the
// configuration, builds the menus and opens the first window: the `-e`
// program, the restored layout, the Welcome screen on a first launch, or a
// plain window. The menus are rebuilt from the configuration they list, and a
// save to the configuration file reloads it through Core's runtime.
//

import AppKit
import CxxStdlib
import UbiquittyAppBridge
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit
import UniformTypeIdentifiers
import UserNotifications

/// Core's Sync protocol namespace, whose name an expression cannot spell.
private typealias SyncWire = Ubiquitty.`Protocol`.Sync

/// The application delegate.
@objc(UBAppDelegate)
@MainActor
final class UBAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate {
    /// The program `-e` named on the command line, its path first, or nil when
    /// none was given.
    ///
    /// Set before launch finishes and consumed there: it opens one window
    /// running this instead of the login shell, ahead of session restore and
    /// the Welcome screen, because a caller that named a program is not asking
    /// for whatever was on screen last time.
    var launchCommandArguments: [String]?

    /// Whether this session ends when the program it was given does.
    ///
    /// Set once from `Runtime::launchEndsWithChild`, which owns the rule so
    /// that three frontends read one answer rather than each recombining `-e`
    /// and `--hold` themselves. What stays here is the mechanism: which window
    /// to close, and when AppKit may terminate.
    var sessionEndsWithLaunchCommand = false

    // Core's application orchestration, over this delegate as its host.
    var runtime: Ubiquitty.App.HostedAppRuntime?
    // The live-reload watch on the configuration file.
    private var configurationWatch: (any DispatchSourceFileSystemObject)?
    // AppKit posts the launch notification again when an Apple event reaches a
    // running process; the startup it drives installs process-wide state once.
    private var didFinishLaunching = false

    // Held so the submenus listing configured entries can be rebuilt after a
    // reload adds or removes them.
    var themeRoot: NSMenuItem?
    var profilesRoot: NSMenuItem?
    var newTabProfilesRoot: NSMenuItem?
    var applyProfilesRoot: NSMenuItem?
    var copyStyleRoot: NSMenuItem?
    // Names the active workspace connection when the File menu opens.
    var remoteWindowItem: NSMenuItem?
    // Menus rebuilt each time they open.
    var sessionMenu: NSMenu?
    var macrosMenu: NSMenu?
    var fontMenu: NSMenu?
    var workspacesRestoreMenu: NSMenu?
    var workspacesDeleteMenu: NSMenu?
    // The font families last classified for the menus and the settings window.
    // The catalog enumerates again only when CoreText reports a change: the
    // enumeration is milliseconds-class and sits on the Beam summon's path.
    var isFontCatalogClean = false
    var isObservingRegisteredFonts = false
    var fontFamilySnapshot: [String]?
    var fontMenuLigatureFamilies: [String] = []
    var fontMenuMonospaceFamilies: [String] = []
    var settingsMonospacedFontNamesCache: [String] = []
    var settingsCJKFontNamesCache: [String] = []
    var settingsSymbolFontNamesCache: [String] = []
    var settingsEmojiFontNamesCache: [String] = []

    // The ⌘ state the OnCommand tab-hint mode reveals the hints under.
    private var flagsMonitor: Any?
    private var isCommandHintHeld = false
    private var appearanceObservation: NSKeyValueObservation?

    // Nil when Sparkle is not compiled in.
    var updater: Updater?
    private var inspector: InspectorController?
    var quakeController: QuakeController?
    var settingsWindowController: SettingsWindowController?
    private var pasteBuffersWindowController: PasteBuffersWindowController?
    private var syncDebugWindowController: SyncDebugWindowController?
    private var streamDebugWindowController: StreamDebugWindowController?
    private var adaptiveDriveDebugWindowController: AdaptiveDriveDebugWindowController?
    private var aboutWindowController: AboutWindowController?

    /// Carries the foreground presentation selector this class cannot; see
    /// `NotificationForegroundPresenter`.
    private nonisolated let foregroundPresenter = NotificationForegroundPresenter()

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The startup below installs process-wide state that may be installed
        // once — the platform context aborts on a second install by design —
        // so the repeat AppKit posts for an Apple event is dropped here.
        guard !didFinishLaunching else { return }
        didFinishLaunching = true

        Ubiquitty.SwiftBridge.writeDiagnostic(std.string("Ubiquitty starting"))
        // First, while the bundle is the one that launched: every window's
        // renderer draws with the shader library read here, so an update or a
        // rebuild that replaces the application later cannot take a new
        // window's shaders away. The driver's wait overlaps the startup below.
        SystemMetalDevice.begin()
        // Ahead of any window: the Swift shell's workspace model copies the
        // default installer at construction, and the first spawn constructs it.
        Ubiquitty.SwiftBridge.registerSessionClipboardInstaller()
        // Likewise: the Kit's paste action asks for this shell's progress
        // panel, and a window spawned before it is installed would decline an
        // image paste.
        PastePush.installPastePushPresenter()
        SessionHandoff.install()
        // Likewise: ⌘⇧P asks for this shell's command palette.
        BeamBridge.installBeamPresenter()
        // Likewise: the caret's glide reads the system's Reduce Motion answer
        // at every tick, and a frame built before it was sampled would glide
        // for a reader who asked it not to.
        SystemMotionPreference.beginObserving()
        observePasswordPrompts()

        // The shell-integration directory, for the child to inherit. Passive:
        // no shell's startup-file lookup is redirected.
        exportTerminalEnvironment()

        // And the locale, before anything can spawn. A GUI process inherits none
        // from launchd, so without this a shell runs under C/POSIX. Set on this
        // process because that is what the PTY layer copies into each child.
        LocaleEnvironment.exportIfNeeded()

        // Heal the terminfo entry when it does not resolve, then name the
        // $TERM spawned shells take.
        runFirstRunSetup()

        // The clock, the inline-image decoder and the DECPS synth, before any
        // worker thread can read a hook.
        Ubiquitty.SwiftBridge.installPlatformContext()

        // Become the notification center's delegate so a banner click
        // reactivates the window that posted it, and banners still show while
        // the app is in front.
        UNUserNotificationCenter.current().delegate = self
        Notifications.requestAuthorization()

        // The configuration and the theme registry, before the menus are built
        // so configured themes appear under View ▸ Theme on first paint.
        loadPreferencesIntoDefaults()
        SystemTheme.refresh()

        // After the configuration, whose `[updates]` section the schedule
        // follows, and before the menus, so the app menu can target "Check for
        // Updates…" at it. Nil when Sparkle is not compiled in.
        updater = Updater.startedUpdater()

        installAppMenu()

        runtime = Ubiquitty.App.HostedAppRuntime.create(runtimeOperations())

        // Before any window is restored: a host this update replaced hands
        // its sessions to the bundled one, which a restored window then
        // reattaches on (`TerminalWindows.restoreArrangementGroups` waits).
        LocalHostUpgrade.beginAtLaunch()

        if let launchCommandArguments, !launchCommandArguments.isEmpty {
            // `-e` outranks restore and the Welcome screen: either would run
            // something other than the program that was asked for, and neither
            // reports it, which is how an ignored `-e` stays invisible. The
            // session carries Core's verdict on whether it ends with its child.
            _ = TerminalWindowController.spawn(
                arguments: launchCommandArguments,
                localePolicy: .auto,
                sessionLifetime: sessionEndsWithLaunchCommand ? .endsWithChild : .outlivesChild
            )
        } else if TerminalWindows.restoreLaunchArrangement() == nil {
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: "UBDidRunFirstLaunchSetup") {
                defaults.set(true, forKey: "UBDidRunFirstLaunchSetup")
                showWelcomeScreen(nil)
            } else {
                _ = TerminalWindowController.spawn()
            }
        }

        // The system appearance flips with System Settings and the scheduled
        // switch; a window's own appearance override would mask a per-window
        // observer, so the application's is watched.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: []) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applySystemAppearanceThemeIfEnabled() }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemColorsChanged(_:)),
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )

        // Once at launch, so a window restored with a stale manual theme matches
        // the current appearance when following it.
        applySystemAppearanceThemeIfEnabled()

        // Any save to the configuration file reloads it into every window.
        startWatchingConfigFile()

        // ⌘ held or released, app-wide, for the OnCommand tab-hint mode. Local:
        // it fires while the app is in front, the only time tab hints matter,
        // and never consumes the event.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.updateCommandHintHeld(event.modifierFlags.contains(.command))
            return event
        }

        NSApp.activate(ignoringOtherApps: true)

        // The remote-control socket binds only when [control] enable = true.
        ControlHost.startIfEnabled()

        // The drop-down terminal registers its hotkey when [quake] is enabled.
        reconfigureQuakeController()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // A requested Dock bounce cancels itself on activation.
        SessionAttention.clear()
        applySecureKeyboardEntry()
        // The pointer grab is process-wide; what returning to the front asks of
        // every grab is Core's, through the registry both shells report to.
        PointerLockRegistry.shared.applyRawEvent(Ubiquitty.Input.AppLifecycle.activated.rawValue)
    }

    func applicationDidResignActive(_ notification: Notification) {
        applySecureKeyboardEntry()
        // A ⌘-Tab away can swallow the key-up.
        updateCommandHintHeld(false)
        PointerLockRegistry.shared.applyRawEvent(Ubiquitty.Input.AppLifecycle.deactivated.rawValue)
    }

    func applicationWillTerminate(_ notification: Notification) {
        SecureInput.apply(false)
        PointerLockRegistry.shared.applyRawEvent(Ubiquitty.Input.AppLifecycle.terminating.rawValue)
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TerminalWindows.terminationReply(for: quitReason)
    }

    /// Why the app would quit now: to relaunch into an update the updater
    /// installed, once it has said so, and otherwise for an ordinary reason.
    var quitReason: Ubiquitty.Session.QuitReason {
        updater?.isRelaunchingForUpdate == true ? .UpdateRelaunch : .Ordinary
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // A `-e` process is one program's lifetime, not a terminal session: a
        // script that ran `ubiquitty -e cmd` would otherwise wait on a process
        // with nothing left to do. Otherwise the app stays running with no
        // windows, as macOS apps do.
        sessionEndsWithLaunchCommand
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Clicking the Dock icon with every window closed opens a fresh one.
        if !hasVisibleWindows { newWindow(sender) }
        return true
    }

    // A password prompt beginning or ending in any pane moves the secure-input
    // policy, the same way activation does.
    private func observePasswordPrompts() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name(PasswordPrompts.didChangeNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySecureKeyboardEntry() }
        }
    }

    /// Holds Secure Keyboard Entry while the app is in front and the policy
    /// asks for it.
    ///
    /// The decision is Core's, from the same facts on every platform; what
    /// stays here is the mechanism, which `SecureInput` balances.
    func applySecureKeyboardEntry() {
        let values = Ubiquitty.Preferences.values().pointee
        var facts = Ubiquitty.Security.SecureInputFacts()
        facts.isAlwaysPreferred = Ubiquitty.Preferences.Effective.secureKeyboardEntry(values)
        facts.isPreferredAtPasswordPrompts = Ubiquitty.Preferences.Effective.secureKeyboardEntryAtPasswordPrompts(values)
        facts.isAnyPaneAtPasswordPrompt = PasswordPrompts.hasActivePrompt
        facts.isApplicationActive = NSApp.isActive
        SecureInput.apply(Ubiquitty.Security.shouldHoldSecureInput(facts))
    }

    // Creates, reconfigures or drops the drop-down terminal to match [quake]:
    // built on first enable, handed new settings while still enabled, released
    // (unregistering its hotkey) when the feature turns off.
    func reconfigureQuakeController() {
        if let quakeController {
            if !quakeController.reloadFromPreferences() { self.quakeController = nil }
            return
        }
        quakeController = QuakeController.controllerIfEnabled()
    }

    /// View ▸ Drop-Down Terminal, and the configured hotkey; inert while [quake]
    /// is off, when the item validates disabled.
    @objc
    func toggleQuakeTerminal(_ sender: Any?) {
        quakeController?.toggle()
    }

    private func updateCommandHintHeld(_ held: Bool) {
        guard held != isCommandHintHeld else { return }
        isCommandHintHeld = held
        TerminalWindowController.isCommandKeyHeld = held
        let mode = Ubiquitty.Preferences.values().pointee.tabShortcutHints.value ?? .Always
        guard mode == .OnCommand else { return }
        TerminalWindowController.refreshTabAccessoriesForOpenWindows()
    }

    // MARK: - Notifications

    nonisolated override func responds(to selector: Selector!) -> Bool {
        selector == NotificationForegroundPresenter.selector || super.responds(to: selector)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        selector == NotificationForegroundPresenter.selector ? foregroundPresenter : super.forwardingTarget(for: selector)
    }

    /// A banner click: reactivates the app and the window that posted it,
    /// selects its tab, and focuses the pane that posted, so a bell from a
    /// background split lands the reader on that pane.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Read where the response arrives; only the two numbers cross to the
        // main actor.
        let windowNumber = Notifications.windowNumber(for: response.notification)
        let paneID = Notifications.paneID(for: response.notification)
        if Thread.isMainThread {
            MainActor.assumeIsolated { Self.raise(windowNumber: windowNumber, paneID: paneID) }
        } else {
            Task { @MainActor in Self.raise(windowNumber: windowNumber, paneID: paneID) }
        }
        completionHandler()
    }

    private static func raise(windowNumber: Int, paneID: Int) {
        guard windowNumber != NSNotFound, let target = NSApp.window(withWindowNumber: windowNumber) else { return }
        NSApp.activate(ignoringOtherApps: true)
        // Each tab is its own window in the group, so selecting the window
        // selects its tab.
        if let group = target.tabGroup { group.selectedWindow = target }
        target.makeKeyAndOrderFront(nil)
        if paneID != NSNotFound, let controller = target.windowController as? TerminalWindowController {
            _ = controller.focusPane(withIdentifier: paneID)
        }
    }

    // MARK: - Appearance

    @objc
    private func systemColorsChanged(_ notification: Notification) {
        TerminalWindowController.refreshSystemTheme()
    }

    /// Re-themes every window for the system appearance when following it.
    ///
    /// The runtime owns the decision — the follow-system gate and the theme it
    /// resolves — and calls back to apply one.
    func applySystemAppearanceThemeIfEnabled() {
        TerminalWindowController.refreshSystemTheme()
        runtime?.onSystemAppearanceChanged(Self.colorScheme(of: NSApp.effectiveAppearance))
    }

    /// Applies an automatic theme to every window, persisting nothing.
    func applyThemeToOpenWindows(at themeIndex: Int) {
        TerminalWindowController.applyThemeToOpenWindows(at: themeIndex)
    }

    /// View ▸ Follow System Appearance.
    ///
    /// Turning it on takes effect at once; turning it off leaves the current
    /// theme in place, now a manual one, until another is picked.
    @objc
    func toggleFollowSystemAppearance(_ sender: Any?) {
        let isOn = Ubiquitty.Preferences.Effective.followSystemAppearance(Ubiquitty.Preferences.values().pointee)
        setSetting(.AppearanceFollowSystem, bool: !isOn)
        if !isOn { applySystemAppearanceThemeIfEnabled() }
    }

    static func colorScheme(of appearance: NSAppearance?) -> Ubiquitty.Preferences.ColorScheme {
        appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .Dark : .Light
    }

    // MARK: - Menu actions

    /// A manual theme pick, which the runtime treats as an override: it turns
    /// off following the system appearance, persists the theme's name and
    /// applies it everywhere.
    @objc
    func chooseTheme(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        runtime?.selectTheme(Int32(item.tag), .Manual)
    }

    @objc
    func editCurrentTheme(_ sender: Any?) {
        SettingsWindowController.editCurrentTheme()
        showSettingsWindow(forCategory: "themes")
    }

    /// ⌘I: the key terminal window's own inspector, else the application's
    /// panel, which tracks the key terminal window of either shell.
    @objc
    func toggleInspector(_ sender: Any?) {
        if TerminalWindows.toggleInspectorOfKeySwiftTerminal() { return }
        let inspector = inspector ?? InspectorController()
        self.inspector = inspector
        inspector.toggle()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let remoteWindowItem, menu === remoteWindowItem.menu {
            if let target = NSApp.target(forAction: remoteWindowItem.action!) as? TerminalWindowController {
                remoteWindowItem.isEnabled = target.validateMenuItem(remoteWindowItem)
            } else {
                remoteWindowItem.isHidden = true
                remoteWindowItem.isEnabled = false
                remoteWindowItem.title = "New Window on Remote Host"
            }
            return
        }
        if let fontMenu, menu === fontMenu {
            populateFontMenu(fontMenu)
            return
        }
        if let macrosMenu, menu === macrosMenu {
            populateMacrosMenu(macrosMenu)
            return
        }
        if let workspacesRestoreMenu, menu === workspacesRestoreMenu {
            populateWorkspacesSubmenu(menu, action: #selector(restoreWorkspaceFromMenu(_:)))
            return
        }
        if let workspacesDeleteMenu, menu === workspacesDeleteMenu {
            populateWorkspacesSubmenu(menu, action: #selector(deleteWorkspaceFromMenu(_:)))
            return
        }
        guard let sessionMenu, menu === sessionMenu else { return }
        // The roster of the key terminal window's session, or a placeholder for
        // a window on no remote session.
        TerminalWindows.populateSessionMenu(menu)
    }

    // Rebuilt from the live [macros] configuration each time it opens. Each item
    // carries its macro's name, which the key terminal window's focused session
    // resolves and sends. New Macro… and Edit Macros… are always there, so the
    // menu is never a dead end.
    private func populateMacrosMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let values = Ubiquitty.Preferences.values().pointee
        let hasWindow = TerminalWindows.hasKeyTerminal
        for macro in values.macros where !macro.name.empty() {
            let title = String(macro.name)
            let item = NSMenuItem(title: title, action: #selector(invokeMacroFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = title
            item.isEnabled = hasWindow
            menu.addItem(item)
        }
        if !values.macros.empty() { menu.addItem(.separator()) }
        let newItem = NSMenuItem(title: "New Macro…", action: #selector(MacroMenuActions.showMacrosSettings(_:)), keyEquivalent: "")
        newItem.target = MacroMenuActions.shared
        menu.addItem(newItem)
        let editItem = NSMenuItem(title: "Edit Macros…", action: #selector(MacroMenuActions.showMacrosSettings(_:)), keyEquivalent: "")
        editItem.target = MacroMenuActions.shared
        menu.addItem(editItem)
    }

    @objc
    private func invokeMacroFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, !name.isEmpty else { return }
        MacroActions.invokeNamed(name)
    }

    /// File ▸ Log Session to File…, for the key terminal window's session.
    @objc
    func toggleSessionLog(_ sender: Any?) {
        _ = TerminalWindows.toggleSessionLogOfKeySwiftTerminal()
    }

    @objc
    func chooseFontFamily(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        settingsSetFontFamily(item.title)
    }

    @objc
    func chooseFontSize(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        // Clamped to the schema's own bound, so a menu size the schema would
        // refuse still lands on one the configuration accepts.
        settingsSetFontSize(Ubiquitty.Preferences.Schema.clampToRange(Double(item.tag), "font", "size"))
    }

    @objc
    func toggleSmartDoubleClick(_ sender: Any?) {
        setSetting(
            .SelectionSmartDoubleClick,
            bool: !Ubiquitty.Preferences.Effective.smartDoubleClick(Ubiquitty.Preferences.values().pointee)
        )
    }

    @objc
    func toggleCopyOnSelect(_ sender: Any?) {
        setSetting(.SelectionCopyOnSelect, bool: !Ubiquitty.Preferences.Effective.copyOnSelect(Ubiquitty.Preferences.values().pointee))
    }

    @objc
    func togglePaneTitleBars(_ sender: Any?) {
        setSetting(.AppearancePaneTitleBars, bool: !Ubiquitty.Preferences.Effective.paneTitleBars(Ubiquitty.Preferences.values().pointee))
    }

    @objc
    func toggleShowBuildHash(_ sender: Any?) {
        setSetting(.DebugShowBuildHash, bool: !Ubiquitty.Preferences.Effective.debugShowBuildHash(Ubiquitty.Preferences.values().pointee))
    }

    /// View ▸ Background Opacity: the item's tag is the opacity in percent,
    /// clamped to 20…100.
    @objc
    func chooseBackgroundOpacity(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let percent = min(max(item.tag, 20), 100)
        setSetting(.AppearanceBackgroundOpacity, double: Double(percent) / 100.0)
    }

    @objc
    func chooseCursorShape(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let shape = Ubiquitty.Preferences.cursorShapeFromInt(Int32(item.tag)).value else { return }
        setSetting(.CursorShape, text: String(cString: Ubiquitty.Preferences.cursorShapeToString(shape)))
        // A menu pick outranks whatever DECSCUSR a prompt-dressing shell left
        // standing.
        TerminalWindowController.applyPickedCursorShapeToOpenWindows()
    }

    /// The configuration file's path, or nil when no home resolves.
    func configFilePath() -> String? {
        configurationDirectoryPath().map { ($0 as NSString).appendingPathComponent("config.toml") }
    }

    /// Edit Settings File…: opens the configuration in $VISUAL or $EDITOR in a
    /// terminal, or in the default editor, writing the documented template on
    /// first use.
    @objc
    func openPreferences(_ sender: Any?) {
        guard let file = configFilePath() else {
            NSSound.beep()
            return
        }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: file) {
            try? fileManager.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? Self.defaultConfigurationContents().write(to: URL(fileURLWithPath: file), options: .atomic)
            // The file exists now; watch it.
            startWatchingConfigFile()
        }
        let environment = ProcessInfo.processInfo.environment
        let visual = environment["VISUAL"] ?? ""
        let editor = visual.isEmpty ? environment["EDITOR"] ?? "" : visual
        guard !editor.isEmpty else {
            NSWorkspace.shared.open(URL(fileURLWithPath: file))
            return
        }
        // Into the key tab's shell when it is at the prompt, else a new tab.
        // Only the path is quoted: the editor may carry arguments the reader
        // set ($EDITOR="code --wait").
        TerminalWindows.runEditorCommand(editor + " " + shellQuote(file) + "\n")
    }

    // The watch reopens on the file's current inode: editors save by rename, so
    // a descriptor kept across a save watches a deleted file.
    private func startWatchingConfigFile() {
        stopWatchingConfigFile()
        guard let path = configFilePath() else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source else { return }
                let events = source.data
                // The runtime owns the reload: the gate that skips the app's
                // own write, then the parse, the menus and the reapply. The
                // watch re-arms on an inode swap whether or not it ran.
                self.runtime?.onConfigFileChanged()
                if !events.isDisjoint(with: [.rename, .delete]) { self.startWatchingConfigFile() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        configurationWatch = source
        source.resume()
    }

    private func stopWatchingConfigFile() {
        configurationWatch?.cancel()
        configurationWatch = nil
    }

    /// What a configuration reload owes beyond the configuration itself.
    ///
    /// Every open window already heard the new document through its one
    /// subscription; this is the application's state: the synth, the theme the
    /// reload selects, the key bindings and the drop-down terminal.
    func applyAllPersistedSettings() {
        let values = Ubiquitty.Preferences.values().pointee
        Ubiquitty.SwiftBridge.applySoundPreferences(values)
        if Ubiquitty.Preferences.Effective.followSystemAppearance(values) {
            let index = runtime?.themeIndexForSystemAppearance(Self.colorScheme(of: NSApp.effectiveAppearance)) ?? -1
            if index >= 0 { TerminalWindowController.applyThemeToOpenWindows(at: Int(index)) }
        } else {
            TerminalWindowController.applyThemeToOpenWindows()
        }
        // Every live terminal view rebuilds its binding table.
        NotificationCenter.default.post(name: Notification.Name(KeyBindingNotice.didChangeNotificationName), object: nil)
        reconfigureQuakeController()
    }

    /// File ▸ New Local Window.
    @objc
    func newWindow(_ sender: Any?) {
        _ = TerminalWindowController.spawn()
    }

    /// File ▸ New Tab: a tab of the key terminal window, or a window when there
    /// is none.
    @objc
    func newTab(_ sender: Any?) {
        if !TerminalWindows.openTabInKeySwiftTerminal(profileNamed: "") { _ = TerminalWindowController.spawn() }
    }

    /// Window ▸ Select Tab N.
    ///
    /// A position past the last tab selects the last, and ⌘9 is always the
    /// last; Core's `tabIndexForShortcut` owns both rules so the menu that
    /// produces the items and this consumer cannot drift.
    @objc
    func selectTab(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let group = NSApp.keyWindow?.tabGroup else { return }
        let tabs = group.windows
        guard !tabs.isEmpty else { return }
        // AppKit bounds a group's tab count; bounded anyway, so no reader has to
        // check what the framework happens to do.
        let index = Ubiquitty.Session.tabIndexForShortcut(Int32(clamping: item.tag), Int32(clamping: tabs.count))
        if index >= 0 { group.selectedWindow = tabs[Int(index)] }
    }

    @objc
    func showConnectWindow(_ sender: Any?) {
        ConnectWindowController.show()
    }

    /// Help ▸ Welcome…, and the first launch's window: a local window whose
    /// pane renders the Welcome screen's bytes ahead of its shell's output.
    @objc
    func showWelcomeScreen(_ sender: Any?) {
        _ = TerminalWindowController.spawnWelcomeScreen()
    }

    /// File ▸ Stop Sharing This Window, for a key terminal window that is not
    /// in front of the responder chain.
    @objc
    func stopSharingWindow(_ sender: Any?) {
        _ = TerminalWindows.sendAction(toKeySwiftTerminal: #selector(stopSharingWindow(_:)))
    }

    /// File ▸ Share This Window with Agents, likewise.
    @objc
    func shareThisWindow(_ sender: Any?) {
        _ = TerminalWindows.sendAction(toKeySwiftTerminal: #selector(shareThisWindow(_:)))
    }

    // MARK: - Session layouts

    /// The saved workspaces as the Connect window and the command palette list
    /// them: `source`, `id`, `name` and `subtitle` each.
    func sessionPickerEntries() -> [[String: String]] {
        SessionLayout.namedWorkspaces()
            .map { session in
                [
                    "source": "workspace",
                    "id": session.identifier,
                    "name": session.name,
                    "subtitle": TerminalWindows.summary(for: session),
                ]
            }
    }

    /// Opens a saved session's windows and tabs beside the open ones.
    func openSession(withIdentifier identifier: String) {
        if let session = SessionLayout.allSessions().first(where: { $0.identifier == identifier }) {
            TerminalWindows.restoreGroups(session.groups)
        }
    }

    /// Opens a picker entry by its source: a saved workspace opens beside the
    /// open windows. A tmux entry names no provider in this shell and opens
    /// nothing.
    func openPickerEntry(fromSource source: String, identifier: String) {
        guard source != "tmux" else { return }
        openSession(withIdentifier: identifier)
    }

    /// Saves the current arrangement as a named workspace, leaving the windows
    /// as they are.
    ///
    /// - Returns: False when there is nothing to save.
    @discardableResult
    func saveCurrentLayout(withName name: String) -> Bool {
        TerminalWindows.saveArrangement(named: name)
    }

    /// Window ▸ Workspaces ▸ Save Arrangement….
    @objc
    func saveWorkspace(_ sender: Any?) {
        TerminalWindows.promptToSaveArrangement()
    }

    // Workspaces ▸ Restore: reopens the chosen workspace beside the open windows.
    @objc
    private func restoreWorkspaceFromMenu(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String, !identifier.isEmpty else { return }
        openSession(withIdentifier: identifier)
    }

    // Workspaces ▸ Delete: drops the chosen workspace after a confirmation.
    @objc
    private func deleteWorkspaceFromMenu(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String, !identifier.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the workspace “\(sender.title)”?"
        alert.informativeText = "Its saved arrangement is removed. Open windows aren’t affected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SessionLayout.deleteSession(withIdentifier: identifier)
    }

    // One item per named workspace, carrying its identifier; a disabled hint
    // when there are none.
    private func populateWorkspacesSubmenu(_ menu: NSMenu, action: Selector) {
        menu.removeAllItems()
        let workspaces = SessionLayout.namedWorkspaces()
        if workspaces.isEmpty {
            let none = NSMenuItem(title: "No Saved Workspaces", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for workspace in workspaces {
            let item = NSMenuItem(title: workspace.name.isEmpty ? workspace.identifier : workspace.name, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = workspace.identifier
            menu.addItem(item)
        }
    }

    // MARK: - Remote setup

    /// File ▸ Set Up Ubiquitty on Remote Host…: a self-contained command that
    /// compiles the terminfo entry in whatever shell it is pasted into. The
    /// entry overwrites cleanly, so pasting it again is safe.
    @objc
    func installTerminfoOnRemote(_ sender: Any?) {
        let command = "tic -x - <<'TERMINFO'\n" + String(cString: Ubiquitty.Terminfo.sourceText()) + "TERMINFO"
        let alert = NSAlert()
        alert.messageText = "Set Up Ubiquitty on a Remote Host"
        // Quoted, so the command still runs when pasted from a bundle whose path
        // holds a space.
        let executable = shellQuote(Bundle.main.executablePath ?? "/Applications/Ubiquitty.app/Contents/MacOS/Ubiquitty")
        alert.informativeText =
            "Paste this into any shell — including an already-open SSH session — "
            + "to compile the xterm-ubiquitty terminfo entry. It’s safe to run more than once and doesn’t need an internet connection.\n\n"
            + "To install it as you connect, run “\(executable) ssh host” in a terminal instead. "
            + "It installs the entry over SSH before your login shell starts. Its mosh form doesn’t install the entry."
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Done")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 160))
        let textView = NSTextView(frame: scroll.bounds)
        textView.string = command
        textView.font = NSFont.userFixedPitchFont(ofSize: 10)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        if alert.runModal() == .alertFirstButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
        }
    }

    // Wraps a string in single quotes for /bin/sh through Core's one quoting
    // rule, which the Linux ssh path shares.
    private func shellQuote(_ text: String) -> String {
        String(Ubiquitty.SwiftBridge.shellQuoted(std.string(text)))
    }

    // MARK: - Help menu

    /// Help ▸ Ubiquitty Help. There is no bundled help book; the documentation
    /// is on the website.
    @objc
    func openHelpDocumentation(_ sender: Any?) {
        if let url = URL(string: "https://ubiquitty.org/docs/getting-started/") { NSWorkspace.shared.open(url) }
    }

    /// Help ▸ Keyboard Shortcuts… (⌘/): the read-only overlay of every menu key
    /// equivalent and [keys] binding; toggles off when shown.
    @objc
    func showKeyboardShortcuts(_ sender: Any?) {
        CheatSheetController.toggle()
    }

    /// Help ▸ Report an Issue….
    @objc
    func reportAnIssue(_ sender: Any?) {
        if let url = URL(string: "https://github.com/ubiquitty/ubiquitty/issues/new") { NSWorkspace.shared.open(url) }
    }

    // MARK: - Panels

    /// ⌘, : the settings window, built on first use.
    @objc
    func showSettingsWindow(_ sender: Any?) {
        sharedSettingsWindowController().showWindow(self)
    }

    /// Opens the settings window on a category.
    ///
    /// Exposed by selector because the Tags jump and the welcome screen send it
    /// down the responder chain, with the category as the sender.
    @objc(showSettingsWindowForCategory:)
    func showSettingsWindow(forCategory categoryID: String) {
        let controller = sharedSettingsWindowController()
        // Shown first, which rebuilds the catalog, so the selection lands on it.
        controller.showWindow(self)
        controller.select(category: categoryID)
    }

    /// Opens the settings window on one row; a row's address stays valid when
    /// labels are translated or the catalog rebuilds.
    func revealSettingsRow(_ rowID: String, inCategory categoryID: String) {
        let controller = sharedSettingsWindowController()
        controller.showWindow(self)
        controller.reveal(rowID: rowID, inCategory: categoryID)
    }

    private func sharedSettingsWindowController() -> SettingsWindowController {
        if let settingsWindowController { return settingsWindowController }
        let controller = SettingsWindowController()
        settingsWindowController = controller
        return controller
    }

    /// Edit ▸ Paste from Buffer… (⌘⇧V).
    @objc
    func showPasteBuffers(_ sender: Any?) {
        // The paste target is the key window now, before the panel takes key.
        PasteBufferActions.captureTarget(NSApp.keyWindow)
        let controller = pasteBuffersWindowController ?? PasteBuffersWindowController()
        pasteBuffersWindowController = controller
        controller.showWindow(self)
    }

    /// The paste buffers the panel lists.
    func pasteBufferEntries() -> [[String: Any]] {
        ClipboardStore.shared().pasteBufferEntries()
    }

    /// Pastes one buffer into the captured target; an empty buffer pastes
    /// nothing.
    func pasteBufferEntry(ofKind kind: Int, index: Int) {
        guard let text = ClipboardStore.shared().textForEntryKind(kind, index: index), !text.isEmpty else { return }
        PasteBufferActions.pasteText(text)
    }

    func closePasteBuffersPanel() {
        pasteBuffersWindowController?.close()
    }

    /// View ▸ Sync Debug….
    @objc
    func showSyncDebugWindow(_ sender: Any?) {
        let controller = syncDebugWindowController ?? SyncDebugWindowController()
        syncDebugWindowController = controller
        controller.showWindow(self)
    }

    /// View ▸ Stream Debug….
    @objc
    func showStreamDebugWindow(_ sender: Any?) {
        let controller = streamDebugWindowController ?? StreamDebugWindowController()
        streamDebugWindowController = controller
        controller.showWindow(self)
    }

    /// View ▸ Adaptive Drive….
    @objc
    func showAdaptiveDriveDebugWindow(_ sender: Any?) {
        let controller = adaptiveDriveDebugWindowController ?? AdaptiveDriveDebugWindowController()
        adaptiveDriveDebugWindowController = controller
        controller.showWindow(self)
    }

    /// The About panel. The version line is Core's: the build's version and, in
    /// parentheses, its build identity.
    @objc
    func showAboutWindow(_ sender: Any?) {
        if aboutWindowController == nil {
            let version = String(SyncWire.appVersionWithIdentity())
            aboutWindowController = AboutWindowController(versionString: "Version \(version)")
        }
        aboutWindowController?.showWindow(self)
    }

    /// Install Shell Integration…: asks first; the question, the plan and the
    /// write are `ShellIntegrationInstaller`'s.
    @objc
    func installShellIntegration(_ sender: Any?) {
        ShellIntegrationInstaller.askToInstall(from: NSApp.keyWindow)
    }

    // MARK: - Runtime host

    private func runtimeOperations() -> Ubiquitty.App.AppRuntimeOperations {
        var operations = Ubiquitty.App.AppRuntimeOperations()
        // The delegate lives as long as the process, and holds the runtime that
        // calls back through this pointer.
        operations.context = Unmanaged.passUnretained(self).toOpaque()
        operations.applyThemeToAllWindows = { context, themeIndex in
            MainActor.assumeIsolated {
                Unmanaged<UBAppDelegate>.fromOpaque(context!).takeUnretainedValue().applyThemeToOpenWindows(at: Int(themeIndex))
            }
        }
        operations.reloadPreferencesFromFile = { _ in
            MainActor.assumeIsolated { loadPreferencesIntoDefaults() }
        }
        operations.rebuildConfigMenus = { context in
            MainActor.assumeIsolated {
                let delegate = Unmanaged<UBAppDelegate>.fromOpaque(context!).takeUnretainedValue()
                delegate.rebuildThemeMenu()
                delegate.rebuildProfilesMenu()
                delegate.rebuildCopyStyleMenu()
            }
        }
        operations.reapplyPersistedSettings = { context in
            MainActor.assumeIsolated { Unmanaged<UBAppDelegate>.fromOpaque(context!).takeUnretainedValue().applyAllPersistedSettings() }
        }
        return operations
    }

    // MARK: - Startup helpers

    // UBIQUITTY_INTEGRATION_DIR, for the child to inherit; users opt in to the
    // shell integration by sourcing a script from it in their own startup files.
    private func exportTerminalEnvironment() {
        guard let resourcePath = Bundle.main.resourcePath else { return }
        let directory = (resourcePath as NSString).appendingPathComponent("shell-integration")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue {
            setenv("UBIQUITTY_INTEGRATION_DIR", directory, 1)
        }
    }

    // Whether `xterm-ubiquitty` resolves in the terminfo database: `infocmp`'s
    // exit status, the lookup ncurses programs perform on $TERM.
    private func terminfoEntryResolves() -> Bool {
        let infocmp = "/usr/bin/infocmp"
        guard FileManager.default.isExecutableFile(atPath: infocmp) else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: infocmp)
        task.arguments = ["xterm-ubiquitty"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // Heals the terminfo entry and exports UBIQUITTY_TERM.
    //
    // The entry can be missing, or compiled by a newer off-PATH tic in a format
    // the system ncurses rejects; a reinstall through the system tic writes one
    // it reads, so tmux's OSC 52 clipboard (gated on the entry's `Ms`) works
    // without the reader reinstalling it by hand. It runs only when the entry
    // does not resolve, so the steady state does nothing. The shell startup
    // files are the Welcome screen's separate, explicit offer.
    private func runFirstRunSetup() {
        var resolves = terminfoEntryResolves()
        if !resolves {
            _ = Ubiquitty.Terminfo.install(nil)
            resolves = terminfoEntryResolves()
        }
        setenv("UBIQUITTY_TERM", resolves ? "xterm-ubiquitty" : "xterm-256color", 1)
    }

    // MARK: - Configuration file

    /// The preferences directory as Core resolves it, or nil when no home
    /// resolves.
    func configurationDirectoryPath() -> String? {
        Ubiquitty.Preferences.directoryPath().value.map { String($0) }
    }

    /// The documented template a first launch writes.
    static func defaultConfigurationContents() -> Data {
        Data(String(Ubiquitty.Preferences.defaultFileContents()).utf8)
    }
}

/// Answers the foreground presentation question for the application delegate.
///
/// With C++ interoperability on, Swift reads the requirement's options type
/// differently from the protocol's, so a method on the delegate only nearly
/// matches it, takes no selector, and every foreground banner would be dropped.
/// This object owns the selector outright, with the options at their
/// Objective-C width, and the delegate forwards the selector here.
final class NotificationForegroundPresenter: NSObject, Sendable {
    /// The Objective-C selector a foreground presentation arrives as.
    static let selector = NSSelectorFromString("userNotificationCenter:willPresentNotification:withCompletionHandler:")

    /// Shows a banner even while the app is in front: a background tab posting
    /// OSC 9, 99 or 777 deserves one whichever window is active.
    ///
    /// - Parameters:
    ///   - center: The notification center asking.
    ///   - notification: The notification about to be presented.
    ///   - completionHandler: Takes the presentation options' raw value.
    @objc(userNotificationCenter:willPresentNotification:withCompletionHandler:)
    func present(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UInt) -> Void
    ) {
        completionHandler(UNNotificationPresentationOptions([.banner, .list]).rawValue)
    }
}
