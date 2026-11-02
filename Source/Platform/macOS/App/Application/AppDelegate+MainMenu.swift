// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// AppDelegate+MainMenu.swift — the menu bar, and the submenus built from the
// configuration they list.
//
// An item with no target routes through the responder chain, so the key
// window's controller answers it, whichever shell drew the window; the
// application's own commands target this delegate. Submenus listing themes,
// profiles and copy styles are rebuilt when a reload changes the list; the
// session, macro, font, workspace and window lists are rebuilt as they open.
//

import AppKit
import UbiquittyCore
import UbiquittyKit

extension UBAppDelegate {
    // The bundle's display name, else its name, else the product's.
    private static func applicationDisplayName() -> String {
        let bundle = Bundle.main
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty { return name }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty { return name }
        return "Ubiquitty"
    }

    private static func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if let modifiers { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    /// Builds the menu bar.
    func installAppMenu() {
        let mainMenu = NSMenu(title: "")
        mainMenu.addItem(applicationMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())

        // Session: the consent surface the title bar's presence pill mirrors —
        // who is attached or authorized, and revoking an agent. Rebuilt as it
        // opens from the key window's roster.
        let sessionMenu = NSMenu(title: "Session")
        sessionMenu.delegate = self
        sessionMenu.autoenablesItems = false
        mainMenu.addItem(submenuItem("Session", sessionMenu))
        self.sessionMenu = sessionMenu

        // Macros: the configured [macros], each sending its body to the key
        // window's focused session. Rebuilt as it opens, so edits and reloads
        // show without a restart.
        let macrosMenu = NSMenu(title: "Macros")
        macrosMenu.delegate = self
        macrosMenu.autoenablesItems = false
        mainMenu.addItem(submenuItem("Macros", macrosMenu))
        self.macrosMenu = macrosMenu

        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(windowMenuItem())
        mainMenu.addItem(helpMenuItem())
        NSApp.mainMenu = mainMenu
    }

    private func submenuItem(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func applicationMenuItem() -> NSMenuItem {
        let appName = Self.applicationDisplayName()
        let menu = NSMenu(title: appName)
        // A Safari-style About panel.
        menu.addItem(withTitle: "About \(appName)", action: #selector(showAboutWindow(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        // ⌘, opens the settings window; editing the file stays reachable for
        // anyone who prefers it.
        menu.addItem(withTitle: "Settings…", action: #selector(showSettingsWindow(_:)), keyEquivalent: ",")
        menu.addItem(withTitle: "Edit Settings File…", action: #selector(openPreferences(_:)), keyEquivalent: "")
        // Only when Sparkle is compiled in. The item targets the updater, which
        // owns the check and greys the item out while one runs.
        if let updater {
            menu.addItem(.separator())
            let updateItem = NSMenuItem(title: "Check for Updates…", action: NSSelectorFromString("checkForUpdates:"), keyEquivalent: "")
            updateItem.target = updater
            menu.addItem(updateItem)
        }
        menu.addItem(.separator())
        // Behind the same question the Welcome screen's button asks.
        menu.addItem(withTitle: "Install Shell Integration…", action: #selector(installShellIntegration(_:)), keyEquivalent: "")
        let installCLI = menu.addItem(withTitle: "Install ubq CLI program…", action: #selector(installCLIProgram(_:)), keyEquivalent: "")
        installCLI.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Ubiquitty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return submenuItem("", menu)
    }

    private func fileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.delegate = self
        menu.addItem(withTitle: "New Local Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        let remoteWindowItem = menu.addItem(
            withTitle: "New Window on Remote Host",
            action: NSSelectorFromString("newRemoteWorkspaceWindow:"),
            keyEquivalent: ""
        )
        remoteWindowItem.isHidden = true
        self.remoteWindowItem = remoteWindowItem
        menu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        // Profile submenus: a fresh window, a tab of the key window, or the
        // current tab re-skinned in place, each from a [[profiles]] block
        // resolved over the global configuration. Rebuilt on reload.
        let profilesRoot = NSMenuItem(title: "New Window with Profile", action: nil, keyEquivalent: "")
        populateProfilesSubmenu(on: profilesRoot, action: #selector(newWindowWithProfile(_:)), menuTitle: "New Window with Profile")
        menu.addItem(profilesRoot)
        let newTabProfilesRoot = NSMenuItem(title: "New Tab with Profile", action: nil, keyEquivalent: "")
        populateProfilesSubmenu(on: newTabProfilesRoot, action: #selector(newTabWithProfile(_:)), menuTitle: "New Tab with Profile")
        menu.addItem(newTabProfilesRoot)
        let applyProfilesRoot = NSMenuItem(title: "Apply Profile to Tab", action: nil, keyEquivalent: "")
        populateProfilesSubmenu(on: applyProfilesRoot, action: #selector(applyProfileToTab(_:)), menuTitle: "Apply Profile to Tab")
        menu.addItem(applyProfilesRoot)
        self.profilesRoot = profilesRoot
        self.newTabProfilesRoot = newTabProfilesRoot
        self.applyProfilesRoot = applyProfilesRoot
        // ⌘W closes innermost first: a split pane, else the tab, else the
        // window, each with the running-process confirmation.
        menu.addItem(withTitle: "Close", action: NSSelectorFromString("closePane:"), keyEquivalent: "w")
        menu.addItem(.separator())
        // ⌘⇧K: the Connect window — saved sessions, then every kind of
        // connection, behind one shortcut.
        menu.addItem(Self.item("Connect…", #selector(showConnectWindow(_:)), "k", [.command, .shift]))
        // ⌃⌘K: Core's plan for the last host, without the Connect window when
        // the plan can act alone; titled and enabled by its target.
        let reattachItem = Self.item("Reattach", #selector(ConnectReattach.reattach(_:)), "k", [.command, .control])
        reattachItem.target = ConnectReattach.shared
        menu.addItem(reattachItem)
        menu.addItem(.separator())
        // Moves the window's running shell into the daemon so an agent can
        // attach (consent-gated), and back.
        menu.addItem(withTitle: "Share This Window with Agents", action: #selector(shareThisWindow(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Stop Sharing This Window", action: #selector(stopSharingWindow(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Set Up Ubiquitty on Remote Host…", action: #selector(installTerminfoOnRemote(_:)), keyEquivalent: "")
        menu.addItem(Self.item("Rename Tab…", NSSelectorFromString("renameTab:"), "i", [.command, .shift]))
        // ⌘⌥I: the title bar's identity editor.
        menu.addItem(Self.item("Edit Title…", NSSelectorFromString("showTitleActionsPopover:"), "i", [.command, .option]))
        menu.addItem(.separator())
        // Appends every byte the session receives to a file; checked while
        // logging, and choosing it again stops.
        menu.addItem(withTitle: "Log Session to File…", action: #selector(toggleSessionLog(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        // Registers, persists and applies a third-party color theme.
        menu.addItem(withTitle: "Import Theme…", action: #selector(importTheme(_:)), keyEquivalent: "")
        return submenuItem("File", menu)
    }

    @objc
    func installCLIProgram(_ sender: Any?) {
        CLIInstaller.askToInstall(from: NSApp.keyWindow)
    }

    private func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        // The standard selector: one Edit menu serves both shells and a focused
        // text field, and each answers `copy:`.
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")

        let copySpecial = NSMenu(title: "Copy Special")
        copySpecial.addItem(
            Self.item(
                "Copy Without Background Color",
                NSSelectorFromString("copySelectionWithoutBackground:"),
                "c",
                [.control, .shift, .command]
            )
        )
        copySpecial.addItem(
            withTitle: "Copy with Styles Only (No Color)",
            action: NSSelectorFromString("copySelectionStylesOnly:"),
            keyEquivalent: ""
        )
        copySpecial.addItem(Self.item("Copy Plain Text", NSSelectorFromString("copySelectionPlain:"), "c", [.option, .shift, .command]))
        copySpecial.addItem(.separator())
        let styleForCopy = NSMenuItem(title: "Style for Copy", action: nil, keyEquivalent: "")
        copyStyleRoot = styleForCopy
        populateCopyStyleSubmenu(on: styleForCopy)
        copySpecial.addItem(styleForCopy)
        menu.addItem(submenuItem("Copy Special", copySpecial))

        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        // The clipboard or the selection shell-escaped into one argument.
        menu.addItem(Self.item("Paste Escaped Text", NSSelectorFromString("pasteEscapedText:"), "v", [.control, .command]))
        menu.addItem(
            Self.item("Paste Escaped Selection", NSSelectorFromString("pasteEscapedSelection:"), "v", [.control, .shift, .command])
        )
        // ⌘⇧V: any OSC 52 buffer or a recent copy, into the focused terminal.
        menu.addItem(Self.item("Paste from Buffer…", #selector(showPasteBuffers(_:)), "v", [.command, .shift]))
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(Self.item("Select Last Command Output", NSSelectorFromString("selectLastCommandOutput:"), "a", [.command, .shift]))
        menu.addItem(.separator())
        // ⌘K takes the screen and the history behind it, then asks for the
        // prompt back; ⌥⌘K takes only the history the screen is not showing.
        menu.addItem(withTitle: "Clear Buffer", action: NSSelectorFromString("clearBuffer:"), keyEquivalent: "k")
        menu.addItem(Self.item("Clear Scrollback", NSSelectorFromString("clearScrollback:"), "k", [.command, .option]))
        // Clear Screen destroys nothing — it scrolls the prompt to the top — so
        // it carries no key equivalent to invite a reflex press.
        menu.addItem(withTitle: "Clear Screen", action: NSSelectorFromString("clearScreen:"), keyEquivalent: "")
        menu.addItem(withTitle: "Clear to Previous Mark", action: NSSelectorFromString("clearToPreviousMark:"), keyEquivalent: "l")
        menu.addItem(withTitle: "Reset Terminal", action: NSSelectorFromString("resetTerminal:"), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Find…", action: NSSelectorFromString("performFindAction:"), keyEquivalent: "f")
        menu.addItem(withTitle: "Find Next", action: NSSelectorFromString("findNext:"), keyEquivalent: "g")
        menu.addItem(Self.item("Find Previous", NSSelectorFromString("findPrevious:"), "g", [.command, .shift]))
        menu.addItem(withTitle: "Use Selection for Find", action: NSSelectorFromString("useSelectionForFind:"), keyEquivalent: "e")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy on Select", action: #selector(toggleCopyOnSelect(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Smart Double-Click Selection", action: #selector(toggleSmartDoubleClick(_:)), keyEquivalent: "")
        return submenuItem("Edit", menu)
    }

    private func viewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        // ⌘↩ toggles full screen through the key window.
        menu.addItem(Self.item("Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "\r", [.command]))
        menu.addItem(Self.item("Hide Title Bar", NSSelectorFromString("toggleHideTitleBar:"), "h", [.control, .command]))
        // ⌘I: targets this delegate, which picks the window's inspector or the
        // application's panel.
        let inspectorItem = Self.item("Show Inspector", #selector(toggleInspector(_:)), "i", [.command])
        inspectorItem.target = self
        menu.addItem(inspectorItem)
        menu.addItem(Self.item("Keep on Top", NSSelectorFromString("toggleKeepOnTop:"), "t", [.command, .control]))
        // The drop-down panel, with a checkmark; disabled while [quake] is off.
        let quakeItem = NSMenuItem(title: "Drop-Down Terminal", action: #selector(toggleQuakeTerminal(_:)), keyEquivalent: "")
        quakeItem.target = self
        menu.addItem(quakeItem)
        menu.addItem(Self.item("Broadcast Input to All Panes", NSSelectorFromString("toggleBroadcastInput:"), "b", [.command, .control]))
        // ⌃⌘Y: live Sync traffic for the frontmost remote session.
        menu.addItem(Self.item("Sync Debug…", #selector(showSyncDebugWindow(_:)), "y", [.command, .control]))
        // ⌃⌘S: the raw byte stream, both directions, for the frontmost local
        // session — what is actually crossing the PTY.
        menu.addItem(Self.item("Stream Debug…", #selector(showStreamDebugWindow(_:)), "s", [.command, .control]))
        menu.addItem(Self.item("Adaptive Drive…", #selector(showAdaptiveDriveDebugWindow(_:)), "a", [.command, .control]))
        menu.addItem(.separator())

        menu.addItem(Self.item("Split Right", NSSelectorFromString("splitRight:"), "d", [.command]))
        menu.addItem(Self.item("Split Down", NSSelectorFromString("splitDown:"), "D", [.command, .shift]))
        menu.addItem(Self.item("Close Pane", NSSelectorFromString("closePane:"), "W", [.command, .shift]))
        menu.addItem(Self.item("Expand / Collapse Pane", NSSelectorFromString("toggleZoomPane:"), "\r", [.command, .shift]))
        menu.addItem(withTitle: "Show Pane Title Bars", action: #selector(togglePaneTitleBars(_:)), keyEquivalent: "")
        menu.addItem(Self.item("Show Build Hash", #selector(toggleShowBuildHash(_:)), "h", [.control, .command, .shift]))

        // ⌘⌥ and an arrow moves focus between panes.
        let focusMoves: [(String, String, Int)] = [
            ("Focus Pane Left", "movePaneFocusLeft:", NSLeftArrowFunctionKey),
            ("Focus Pane Right", "movePaneFocusRight:", NSRightArrowFunctionKey),
            ("Focus Pane Up", "movePaneFocusUp:", NSUpArrowFunctionKey),
            ("Focus Pane Down", "movePaneFocusDown:", NSDownArrowFunctionKey),
        ]
        for (title, action, key) in focusMoves {
            menu.addItem(Self.item(title, NSSelectorFromString(action), Self.functionKey(key), [.command, .option]))
        }
        menu.addItem(.separator())
        let promptMoves: [(String, String, Int)] = [
            ("Jump to Previous Prompt", "scrollToPreviousPrompt:", NSUpArrowFunctionKey),
            ("Jump to Next Prompt", "scrollToNextPrompt:", NSDownArrowFunctionKey),
        ]
        for (title, action, key) in promptMoves {
            menu.addItem(Self.item(title, NSSelectorFromString(action), Self.functionKey(key), [.command, .shift]))
        }
        menu.addItem(.separator())

        // Theme: built-ins, configured themes, then Edit Current Theme…. The tag
        // is the theme's index across both.
        let themeRoot = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        self.themeRoot = themeRoot
        populateThemeSubmenu(on: themeRoot)
        menu.addItem(themeRoot)
        let followItem = NSMenuItem(
            title: "Follow System Appearance",
            action: #selector(toggleFollowSystemAppearance(_:)),
            keyEquivalent: ""
        )
        followItem.target = self
        menu.addItem(followItem)

        // Font: every installed monospace family, ligature-capable first. Filled
        // as it opens rather than here: the trait probes run over every family,
        // and here they would sit between launch and the first window for a
        // menu that may never open.
        let fontMenu = NSMenu(title: "Font")
        fontMenu.delegate = self
        self.fontMenu = fontMenu
        menu.addItem(submenuItem("Font", fontMenu))

        // Font Size: the tag is the point size.
        let sizeMenu = NSMenu(title: "Font Size")
        for size in [11, 12, 13, 14, 16, 18, 20, 24] {
            let item = NSMenuItem(title: String(size), action: #selector(chooseFontSize(_:)), keyEquivalent: "")
            item.tag = size
            sizeMenu.addItem(item)
        }
        menu.addItem(submenuItem("Font Size", sizeMenu))

        // Background Opacity: below 100% the desktop shows through behind the
        // text, which stays opaque. The tag is the opacity in percent.
        let opacityMenu = NSMenu(title: "Background Opacity")
        for percent in [100, 95, 90, 85, 80, 70, 60, 50, 40, 30] {
            let item = NSMenuItem(
                title: percent == 100 ? "100% (Opaque)" : "\(percent)%",
                action: #selector(chooseBackgroundOpacity(_:)),
                keyEquivalent: ""
            )
            item.tag = percent
            opacityMenu.addItem(item)
        }
        menu.addItem(submenuItem("Background Opacity", opacityMenu))

        // The cursor's default shape; a program's DECSCUSR overrides it for the
        // session, and blink, linger and alpha live in Settings.
        menu.addItem(.separator())
        let cursorMenu = NSMenu(title: "Cursor Shape")
        for (index, shape) in ["Block", "Underline", "Bar"].enumerated() {
            let item = NSMenuItem(title: shape, action: #selector(chooseCursorShape(_:)), keyEquivalent: "")
            item.tag = index
            cursorMenu.addItem(item)
        }
        menu.addItem(submenuItem("Cursor Shape", cursorMenu))

        menu.addItem(.separator())
        menu.addItem(withTitle: "Zoom In", action: NSSelectorFromString("growFontSize:"), keyEquivalent: "+")
        menu.addItem(withTitle: "Zoom Out", action: NSSelectorFromString("shrinkFontSize:"), keyEquivalent: "-")
        menu.addItem(withTitle: "Actual Size", action: NSSelectorFromString("resetFontSize:"), keyEquivalent: "0")

        // The standard ⌃⌘F full-screen toggle.
        menu.addItem(.separator())
        menu.addItem(Self.item("Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        // Drawing Debug and Paint Heatmap are developer diagnostics a shipping
        // build does not carry, so it shows neither them nor their separator.
        if Ubiquitty.Diagnostics.isPerfDiagnosticsBuild() {
            menu.addItem(.separator())
            menu.addItem(Self.item("Drawing Debug", NSSelectorFromString("toggleDrawingDebug:"), "d", [.command, .control]))
            menu.addItem(Self.item("Paint Heatmap", NSSelectorFromString("toggleHeatmap:"), "h", [.command, .shift]))
        }
        return submenuItem("View", menu)
    }

    private static func functionKey(_ key: Int) -> String {
        String(Character(Unicode.Scalar(UInt16(key))!))
    }

    private func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        // Keeps the tab leftmost and guards it against an accidental close; the
        // key window's controller answers it and checks it.
        menu.addItem(.separator())
        menu.addItem(withTitle: "Pin Tab", action: NSSelectorFromString("togglePinTab:"), keyEquivalent: "")

        // Workspaces: named window, tab and pane arrangements, also listed in
        // the Connect window. Restore and Delete are rebuilt as they open.
        menu.addItem(.separator())
        let workspacesMenu = NSMenu(title: "Workspaces")
        workspacesMenu.autoenablesItems = false
        let saveItem = NSMenuItem(title: "Save Arrangement…", action: #selector(saveWorkspace(_:)), keyEquivalent: "")
        saveItem.target = self
        workspacesMenu.addItem(saveItem)
        workspacesMenu.addItem(.separator())
        let restoreMenu = NSMenu(title: "Restore")
        restoreMenu.delegate = self
        restoreMenu.autoenablesItems = false
        workspacesMenu.addItem(submenuItem("Restore", restoreMenu))
        TerminalWindows.appendArrangementActions(to: workspacesMenu)
        let deleteMenu = NSMenu(title: "Delete")
        deleteMenu.delegate = self
        deleteMenu.autoenablesItems = false
        workspacesMenu.addItem(submenuItem("Delete", deleteMenu))
        workspacesRestoreMenu = restoreMenu
        workspacesDeleteMenu = deleteMenu
        menu.addItem(submenuItem("Workspaces", workspacesMenu))

        // ⌘1…⌘9 select a tab by position, ⌘9 the last. The items stay visible:
        // AppKit skips a hidden item when matching key equivalents. Core's
        // `tabPositionHasShortcut` names the range `selectTab(_:)` honours.
        menu.addItem(.separator())
        var position: Int32 = 1
        while Ubiquitty.Session.tabPositionHasShortcut(position) {
            let item = NSMenuItem(title: "Select Tab \(position)", action: #selector(selectTab(_:)), keyEquivalent: String(position))
            item.target = self
            item.keyEquivalentModifierMask = [.command]
            item.tag = Int(position)
            menu.addItem(item)
            position += 1
        }

        // AppKit owns the open-window entries, including tabs and minimized windows.
        let item = submenuItem("Window", menu)
        NSApp.windowsMenu = menu
        return item
    }

    private func helpMenuItem() -> NSMenuItem {
        // Registered as the help menu so AppKit adds its search field. The
        // targets are this delegate, so the items work whatever window is key.
        let appName = Self.applicationDisplayName()
        let menu = NSMenu(title: "Help")
        let welcomeItem = NSMenuItem(title: "Welcome…", action: #selector(showWelcomeScreen(_:)), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)
        // ⌘? is the macOS Help shortcut.
        let docsItem = NSMenuItem(title: "\(appName) Help", action: #selector(openHelpDocumentation(_:)), keyEquivalent: "?")
        docsItem.target = self
        menu.addItem(docsItem)
        menu.addItem(.separator())
        let shortcutsItem = NSMenuItem(title: "Keyboard Shortcuts…", action: #selector(showKeyboardShortcuts(_:)), keyEquivalent: "/")
        shortcutsItem.target = self
        menu.addItem(shortcutsItem)
        let reportItem = NSMenuItem(title: "Report an Issue…", action: #selector(reportAnIssue(_:)), keyEquivalent: "")
        reportItem.target = self
        menu.addItem(reportItem)
        NSApp.helpMenu = menu
        return submenuItem("Help", menu)
    }

    // MARK: - Configured submenus

    // Built-in themes, a separator when there are configured ones, the
    // configured themes, then Edit Current Theme….
    private func populateThemeSubmenu(on root: NSMenuItem) {
        let menu = NSMenu(title: "Theme")
        let builtInCount = Ubiquitty.Themes.builtInCount()
        let total = Ubiquitty.Themes.count()
        func add(_ index: Int32) {
            guard let theme = Ubiquitty.Themes.get(index), let name = theme.pointee.name else { return }
            let item = NSMenuItem(title: String(cString: name), action: #selector(chooseTheme(_:)), keyEquivalent: "")
            item.tag = Int(index)
            menu.addItem(item)
        }
        for index in 0..<builtInCount { add(index) }
        if total > builtInCount {
            menu.addItem(.separator())
            for index in builtInCount..<total { add(index) }
        }
        menu.addItem(.separator())
        let edit = NSMenuItem(title: "Edit Current Theme…", action: #selector(editCurrentTheme(_:)), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        root.submenu = menu
    }

    /// Rebuilds View ▸ Theme after a reload changed the configured themes.
    func rebuildThemeMenu() {
        if let root = themeRoot { populateThemeSubmenu(on: root) }
    }

    // Edit ▸ Copy Special ▸ Style for Copy: the live palette, plain text, then
    // every built-in theme. Each item carries its token; the configured choice
    // is checked.
    private func populateCopyStyleSubmenu(on root: NSMenuItem) {
        let current = String(Ubiquitty.Preferences.values().pointee.copyStyleTheme.value ?? std.string())
        // Empty and "default" both mean the live palette.
        let isDefault = current.isEmpty || current == "default"
        let menu = NSMenu(title: "Style for Copy")
        func add(_ title: String, _ token: String, _ isChecked: Bool) {
            let item = NSMenuItem(title: title, action: #selector(chooseCopyStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = token
            item.state = isChecked ? .on : .off
            menu.addItem(item)
        }
        add("Terminal’s Settings (Default)", "default", isDefault)
        add("Plain Text", "plain", current == "plain")
        menu.addItem(.separator())
        for index in 0..<Ubiquitty.Themes.builtInCount() {
            guard let theme = Ubiquitty.Themes.get(index), let cName = theme.pointee.name else { continue }
            let name = String(cString: cName)
            add(name, name, !isDefault && current != "plain" && current == name)
        }
        root.submenu = menu
    }

    /// Rebuilds Style for Copy after a reload changed the themes or the choice.
    func rebuildCopyStyleMenu() {
        if let root = copyStyleRoot { populateCopyStyleSubmenu(on: root) }
    }

    // Persists the chosen palette token and moves the checkmark.
    @objc
    private func chooseCopyStyle(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String else { return }
        setSetting(.SelectionCopyStyleTheme, text: token)
        if let root = copyStyleRoot { populateCopyStyleSubmenu(on: root) }
    }

    // "Default" first — tag -1, the bare global configuration — then one item
    // per named [[profiles]] entry, its tag the entry's index.
    private func populateProfilesSubmenu(on root: NSMenuItem, action: Selector, menuTitle: String) {
        let menu = NSMenu(title: menuTitle)
        let defaultItem = NSMenuItem(title: "Default", action: action, keyEquivalent: "")
        defaultItem.target = self
        defaultItem.tag = -1
        menu.addItem(defaultItem)
        let profiles = Ubiquitty.Preferences.values().pointee.profiles
        if !profiles.empty() { menu.addItem(.separator()) }
        for (index, profile) in profiles.enumerated() where !profile.name.empty() {
            let item = NSMenuItem(title: String(profile.name), action: action, keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        root.submenu = menu
    }

    /// Rebuilds the three profile submenus after a reload.
    func rebuildProfilesMenu() {
        if let root = profilesRoot {
            populateProfilesSubmenu(on: root, action: #selector(newWindowWithProfile(_:)), menuTitle: "New Window with Profile")
        }
        if let root = newTabProfilesRoot {
            populateProfilesSubmenu(on: root, action: #selector(newTabWithProfile(_:)), menuTitle: "New Tab with Profile")
        }
        if let root = applyProfilesRoot {
            populateProfilesSubmenu(on: root, action: #selector(applyProfileToTab(_:)), menuTitle: "Apply Profile to Tab")
        }
    }

    // The profile a profile-menu item names: the entry at its tag, or the
    // implicit Default — the name a resolved profile carries, since resolution
    // keeps the child's identity.
    private func profileName(for sender: Any?) -> String {
        let profiles = Ubiquitty.Preferences.values().pointee.profiles
        guard let item = sender as? NSMenuItem, item.tag >= 0, item.tag < profiles.count else { return "Default" }
        return String(profiles[item.tag].name)
    }

    /// A fresh window under the chosen profile.
    @objc
    func newWindowWithProfile(_ sender: Any?) {
        _ = TerminalWindowController.spawn(profileNamed: profileName(for: sender))
    }

    /// A tab of the key window under the chosen profile, or a window when there
    /// is no key terminal window.
    @objc
    func newTabWithProfile(_ sender: Any?) {
        let name = profileName(for: sender)
        if !TerminalWindows.openTabInKeySwiftTerminal(profileNamed: name) { _ = TerminalWindowController.spawn(profileNamed: name) }
    }

    /// The chosen profile's presentation, applied to the current tab in place.
    /// A startup host governs only a fresh session and is ignored here.
    @objc
    func applyProfileToTab(_ sender: Any?) {
        TerminalWindows.applyProfileToKeyTerminal(named: profileName(for: sender))
    }

    // MARK: - Font menu

    /// Classifies the installed font families, again only after CoreText
    /// reports a change to them.
    func refreshFontCatalogIfNeeded() {
        if !isObservingRegisteredFonts {
            isObservingRegisteredFonts = true
            NotificationCenter.default.addObserver(
                forName: Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFontCatalogClean = false }
            }
        }
        if isFontCatalogClean && fontFamilySnapshot != nil { return }
        let families = Self.sortedAvailableFontFamilyNames()
        isFontCatalogClean = true
        if fontFamilySnapshot == families { return }

        var ligature: [String] = []
        var monospace: [String] = []
        var settingsNames = ["System Monospaced"]
        var cjkNames: [String] = []
        var symbolNames: [String] = []
        var emojiNames: [String] = []
        for family in families {
            if FontInventory.familySupportsCJK(family) { cjkNames.append(family) }
            // Coverage, not pitch: the symbol and math faces are proportional,
            // and the monospace test below would keep them out of the picker.
            if FontInventory.familyCoversSymbolBlocks(family) { symbolNames.append(family) }
            if FontInventory.familyCoversEmoji(family) { emojiNames.append(family) }
            guard FontInventory.familyIsMonospace(family) else { continue }
            settingsNames.append(family)
            if FontInventory.familySupportsLigatures(family) {
                ligature.append(family)
            } else {
                monospace.append(family)
            }
        }
        fontFamilySnapshot = families
        fontMenuLigatureFamilies = ligature
        fontMenuMonospaceFamilies = monospace
        settingsMonospacedFontNamesCache = settingsNames
        settingsCJKFontNamesCache = cjkNames
        settingsSymbolFontNamesCache = symbolNames
        settingsEmojiFontNamesCache = emojiNames
    }

    private static func sortedAvailableFontFamilyNames() -> [String] {
        let families = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // View ▸ Font: ligature-capable monospace families, then the rest.
    func populateFontMenu(_ menu: NSMenu) {
        refreshFontCatalogIfNeeded()
        menu.removeAllItems()
        let action = #selector(chooseFontFamily(_:))
        if !fontMenuLigatureFamilies.isEmpty {
            let header = NSMenuItem(title: "Ligature Fonts", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for family in fontMenuLigatureFamilies { menu.addItem(NSMenuItem(title: family, action: action, keyEquivalent: "")) }
            menu.addItem(.separator())
        }
        let header = NSMenuItem(title: "Monospace", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if fontMenuMonospaceFamilies.isEmpty {
            let empty = NSMenuItem(title: "No Fixed-Pitch Fonts Found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for family in fontMenuMonospaceFamilies { menu.addItem(NSMenuItem(title: family, action: action, keyEquivalent: "")) }
    }

    // MARK: - Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let values = Ubiquitty.Preferences.values().pointee
        func state(_ isOn: Bool) -> NSControl.StateValue { isOn ? .on : .off }
        switch item.action {
        case #selector(toggleSessionLog(_:)):
            // The key terminal window's log, in the title and the checkmark.
            return TerminalWindows.validateSessionLogItem(item)
        case #selector(shareThisWindow(_:)), #selector(stopSharingWindow(_:)):
            // Only a plain in-process local shell can be handed to the daemon,
            // and only a window that went there can be reclaimed.
            return TerminalWindows.validateSharingItem(item)
        case #selector(editCurrentTheme(_:)):
            return TerminalWindows.canEditKeyTerminalTheme
        case #selector(toggleFollowSystemAppearance(_:)):
            item.state = state(Ubiquitty.Preferences.Effective.followSystemAppearance(values))
        case #selector(chooseTheme(_:)):
            // The theme painted in the key terminal window: the automatic switch
            // applies one without persisting it. With no window, the theme the
            // next one opens on, which is Core's launch ladder — a configured
            // name that no longer resolves still opens on the house default.
            let current: Int
            if let painted = TerminalWindows.keyTerminalThemeIndex() {
                current = painted.intValue
            } else if Ubiquitty.Preferences.Effective.followSystemAppearance(values) {
                current = Int(runtime?.autoThemeIndex(Self.colorScheme(of: NSApp.effectiveAppearance)) ?? -1)
            } else {
                current = Int(Ubiquitty.Runtime.launchThemeIndex(values))
            }
            item.state = state(item.tag == current)
        case #selector(chooseFontFamily(_:)):
            let current = values.fontFamily.value.map { String($0) } ?? ""
            item.state = state(!current.isEmpty && item.title == current)
        case #selector(chooseFontSize(_:)):
            let defaultSize = Ubiquitty.Preferences.Defaults.fontSize
            var current = values.fontSize.value ?? defaultSize
            if current <= 0 { current = defaultSize }
            item.state = state(item.tag == Int(current.rounded()))
        case #selector(toggleSmartDoubleClick(_:)):
            item.state = state(Ubiquitty.Preferences.Effective.smartDoubleClick(values))
        case #selector(toggleCopyOnSelect(_:)):
            item.state = state(Ubiquitty.Preferences.Effective.copyOnSelect(values))
        case #selector(togglePaneTitleBars(_:)):
            item.state = state(Ubiquitty.Preferences.Effective.paneTitleBars(values))
        case #selector(toggleShowBuildHash(_:)):
            item.state = state(Ubiquitty.Preferences.Effective.debugShowBuildHash(values))
        case #selector(chooseBackgroundOpacity(_:)):
            let current = values.backgroundOpacity.value ?? 1.0
            item.state = state(item.tag == Int((current * 100.0).rounded()))
        case #selector(chooseCursorShape(_:)):
            let current = Int(Ubiquitty.Preferences.cursorShapeToInt(values.cursorShape.value ?? .Bar))
            item.state = state(item.tag == current)
        case #selector(toggleQuakeTerminal(_:)):
            // Enabled while [quake] is on; checked while the panel is down.
            let quake = quakeController
            item.state = state(quake?.isVisible ?? false)
            return quake != nil
        default:
            break
        }
        return true
    }
}
