// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit
import UbiquittyRenderKit

// ChromeThemeScenarios.swift — a themed Swift-shell window is one surface with
// the grid it contains, title row included.
//
// `titlebarAppearsTransparent` plus a window background colour is not enough
// to make it so, and the difference is invisible to anything that only reads
// the window's own properties: AppKit's `NSVisualEffectView` lives inside the
// titlebar container, in front of the backing, and shows the desktop through
// the title row while the content rect below carries the theme. So what is
// asserted here is the container's own layer and that material's hidden state
// — the two facts a screenshot would show and a property read would not.

/// Registers the window-chrome scenarios with the UI-test runner.
enum ChromeThemeScenarios {
    /// Registers every scenario in this file.
    static func register() {
        // Every tab of a window restyles on the theme change itself, the tabs
        // behind the selected one included: a pick through the path Settings
        // takes, and a light or dark flip while the theme follows the system.
        UBUITestRegister("background_tabs_restyle_with_the_theme") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = SettingsBridge.app, let dark = catalogThemeIndex(named: "One Dark"),
                    let light = catalogThemeIndex(named: "One Light")
                else {
                    t.expect(false, desc: "the settings path and both comparison themes exist")
                    return
                }
                let unthemed = String(Ubiquitty.Preferences.liveDocument().pointee)
                let savedAppearance = NSApp.appearance
                defer {
                    NSApp.appearance = savedAppearance
                    t.restoreConfiguration(unthemed)
                    TerminalWindowController.applyThemeToOpenWindows()
                }
                app.settingsSelectTheme(dark)
                guard let shell = TerminalWindowController.spawn(), let first = shell.window,
                    let firstSurface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a window opens for the theme change")
                    return
                }
                defer { (first.tabGroup?.windows ?? [first]).forEach { $0.close() } }
                first.makeKeyAndOrderFront(nil)
                // The first tab's shell runs a program whose status names
                // OpenCode: the icon is drawn in the title's ink, and the working
                // mark wears a system label colour, which resolves under the
                // appearance the theme gives the window. A status names the icon
                // only while a program other than the shell holds the terminal.
                firstSurface.send("printf '\\033]7501;state=working:app=opencode\\a'; sleep 1000\r")
                t.expect(
                    t.wait(until: { templateIconInk(of: first) != nil }, timeout: 15),
                    desc: "the first tab leads with its program's icon"
                )
                shell.newWindowForTab(nil)
                t.expect(t.wait(until: { first.tabGroup?.windows.count == 2 }, timeout: 8), desc: "a second tab opens")
                (first.tabGroup?.windows.last?.windowController as? TerminalWindowController)?.newWindowForTab(nil)
                t.expect(t.wait(until: { first.tabGroup?.windows.count == 3 }, timeout: 8), desc: "a third tab opens")
                guard let group = first.tabGroup, let selected = group.selectedWindow, selected !== first,
                    let selectedSurface = (selected.windowController as? TerminalWindowController)?.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "three tabs stand in one group with the newest in front")
                    return
                }
                t.expect(
                    t.wait(until: { templateIconInk(of: first) != nil && statusMarkInk(of: first) != nil }, timeout: 10),
                    desc: "the first tab, behind the others, keeps its program's icon and shows its working mark"
                )
                // The two picks are of opposite darkness, so one of them always
                // opposes the system's appearance: chrome resolving its system
                // colours under the system rather than the theme fails that one
                // on any machine.
                let foreground = { (selected.windowController as? TerminalWindowController)?.themeForeground(of: selectedSurface) ?? 0 }
                let darkInk = foreground()
                expectBackgroundTabsWear(
                    t,
                    windows: group.windows,
                    foreground: darkInk,
                    isDark: true,
                    iconWindows: [first],
                    markWindows: [first],
                    state: "the dark theme"
                )

                app.settingsSelectTheme(light)
                t.expect(foreground() != darkInk, desc: "the light theme reached the selected tab")
                expectBackgroundTabsWear(
                    t,
                    windows: group.windows,
                    foreground: foreground(),
                    isDark: false,
                    iconWindows: [first],
                    markWindows: [first],
                    state: "a theme picked as Settings picks one"
                )

                app.settingsSetSystemLightTheme(light)
                app.settingsSetSystemDarkTheme(dark)
                app.settingsSetAppearanceMode(0)
                for (appearance, label) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    let isDark = appearance == .darkAqua
                    t.expect(
                        t.wait(until: { (foreground() == darkInk) == isDark }, timeout: 10),
                        desc: "the system's \(label) appearance reached the selected tab"
                    )
                    expectBackgroundTabsWear(
                        t,
                        windows: group.windows,
                        foreground: foreground(),
                        isDark: isDark,
                        iconWindows: [first],
                        markWindows: [first],
                        state: "the system turning \(label) under an automatic theme"
                    )
                }
            }
        }

        UBUITestRegister("tab_material_survives_focus_and_opacity_changes") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard #available(macOS 26.0, *) else { return }
                let band = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
                band.style = .regular
                let glassMaterial = TabStripMaterial(glassBand: band)
                t.expect(band.style == .clear, desc: "the macOS 26 glass-band path retains native clear material")
                band.style = .regular
                t.expect(band.style == .clear, desc: "a native style refresh cannot restore an opaque glass band")
                glassMaterial.restore()
                t.expect(band.style == .regular, desc: "releasing the adapter restores the original glass-band style")

                func glassChrome(opacity: Double) -> String {
                    "[appearance]\nbackground_opacity = \(opacity)\nblur_radius = 20.0\ntitlebar_style = \"themed\"\n"
                }
                let saved = t.configureAppending(glassChrome(opacity: 0.0))
                TerminalWindowController.systemTransparencyOverrideForTesting = .Allowed
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.systemTransparencyOverrideForTesting = nil
                }
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ), let first = shell.window
                else {
                    t.expect(false, desc: "a window opens for tab material transitions")
                    return
                }
                defer { (first.tabGroup?.windows ?? [first]).forEach { $0.close() } }
                first.makeKeyAndOrderFront(nil)
                shell.newWindowForTab(nil)
                t.expect(t.wait(until: { first.tabGroup?.windows.count == 2 }, timeout: 8), desc: "two native tabs open")
                guard let group = first.tabGroup else { return }
                let focusWindow = NSWindow(
                    contentRect: NSRect(x: -2000, y: -2000, width: 200, height: 100),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                focusWindow.isReleasedWhenClosed = false
                focusWindow.tabbingMode = .disallowed
                defer { focusWindow.close() }

                for theme in ["Glass Dark", "Glass", "Noir", "Noir Clair"] {
                    let themeIndex = theme.withCString { Ubiquitty.Themes.indexForName($0) }
                    t.expect(themeIndex >= 0, desc: "the \(theme) comparison theme exists")
                    for window in group.windows {
                        guard let controller = window.windowController as? TerminalWindowController,
                            let surface = controller.focusedSurfaceForTesting
                        else { continue }
                        t.expect(controller.applyInspectedTheme(Int(themeIndex), to: surface), desc: "\(theme) applies to each tab")
                    }
                    for opacity in [0.0, 0.5, 1.0, 0.0] {
                        t.restoreConfiguration(saved)
                        t.configureAppending(glassChrome(opacity: opacity))
                        for window in group.windows {
                            (window.windowController as? TerminalWindowController)?.refreshSessionAppearance()
                        }
                        for selected in group.windows {
                            group.selectedWindow = selected
                            selected.makeKeyAndOrderFront(nil)
                            t.pump(0.12)
                            for isActive in [false, true] {
                                if isActive { selected.makeKeyAndOrderFront(nil) } else { focusWindow.makeKeyAndOrderFront(nil) }
                                t.pump(0.12)
                                guard let strip = TabStripStyling.tabStripView(inGroupOf: selected),
                                    let root = selected.contentView?.superview,
                                    let container = TabStripStyling.titlebarContainer(searchingFrom: root)
                                else {
                                    t.expect(false, desc: "the native strip survives focus and tab transfers")
                                    continue
                                }
                                let state = "\(theme), opacity \(opacity), active \(isActive)"
                                if let host = TabStripMaterial.filterHost(in: strip) {
                                    let fills = host.sublayers?.filter { $0.name == "kCUIVariantContentBackgroundMaterial" } ?? []
                                    t.expect(!fills.isEmpty, desc: "AppKit supplies the rebuilt subdued-track material: \(state)")
                                    t.expect(
                                        fills.allSatisfy { $0.isHidden },
                                        desc: "the same native track survives focus changes at every opacity: \(state)"
                                    )
                                    t.expect(
                                        host.sublayers?.contains { $0.name == "NSTabBarTrackContentBlur" && !$0.isHidden } == true,
                                        desc: "the native track blur remains present: \(state)"
                                    )
                                    t.expect(
                                        host.sublayers?.contains { $0.name == "NSTabBarTrackVibrantColorMatrix" && !$0.isHidden } == true,
                                        desc: "the native track vibrancy remains present: \(state)"
                                    )
                                } else {
                                    t.expect(
                                        TabStripStyling.stripHasBand(in: container),
                                        desc: "the native glass-band hierarchy is supported: \(state)"
                                    )
                                }
                                t.expect(
                                    TabStripStyling.testPaint(in: container)?.styles == [.regular, .regular],
                                    desc: "selection pills retain their native style: \(state)"
                                )
                                if opacity == 1 {
                                    t.expect(
                                        container.layer?.backgroundColor.map { isSameColor($0, selected.backgroundColor) } == true,
                                        desc: "opaque themes retain their themed titlebar background: \(state)"
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        UBUITestRegister("glass_tabs_keep_native_titles_and_secondary_accessories") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = t.configureAppending("[appearance]\nbackground_opacity = 0.0\nblur_radius = 20.0\n")
                TerminalWindowController.systemTransparencyOverrideForTesting = .Allowed
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.systemTransparencyOverrideForTesting = nil
                }
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "exec sleep 1000"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ), let first = shell.window
                else {
                    t.expect(false, desc: "a transparent tabbed window opens")
                    return
                }
                defer { (first.tabGroup?.windows ?? [first]).forEach { $0.close() } }
                first.makeKeyAndOrderFront(nil)
                shell.setCustomTitles(tab: "First Glass Tab")
                t.pump(0.3)
                @MainActor
                func fields(in root: NSView) -> [NSTextField] {
                    var result: [NSTextField] = []
                    if let field = root as? NSTextField { result.append(field) }
                    for view in root.subviews { result += fields(in: view) }
                    return result
                }
                for count in 2...3 {
                    shell.newWindowForTab(nil)
                    t.expect(t.wait(until: { first.tabGroup?.windows.count == count }, timeout: 8), desc: "native tab \(count) opens")
                    guard let group = first.tabGroup else { return }
                    for (index, window) in group.windows.enumerated() {
                        guard let controller = window.windowController as? TerminalWindowController else { continue }
                        controller.setCustomTitles(tab: "Glass Tab \(index + 1)")
                    }
                    t.pump(0.5)
                    for selected in group.windows {
                        group.selectedWindow = selected
                        selected.makeKeyAndOrderFront(nil)
                        (selected.windowController as? TerminalWindowController)?.reconcileTabGroupChrome()
                        t.pump(0.3)
                        guard let strip = TabStripStyling.tabStripView(inGroupOf: selected) else {
                            t.expect(false, desc: "the selected window hosts the native strip")
                            return
                        }
                        let labels = fields(in: strip)
                        for (index, tabWindow) in group.windows.enumerated() {
                            let expected = "Glass Tab \(index + 1)"
                            t.expect(
                                labels.contains {
                                    $0.stringValue.contains(expected) && !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0
                                        && $0.bounds.width > 0
                                },
                                desc: "the native strip visibly contains \(expected) with \(count) tabs"
                            )
                            // The label's lead, the folder, is dimmed by the bake; the
                            // name's ink is what AppKit's own state dimming must own.
                            let attributed = tabWindow.tab.attributedTitle
                            let nameRange = ((attributed?.string ?? "") as NSString).range(of: expected)
                            let ink =
                                nameRange.location == NSNotFound
                                ? nil : attributed?.attribute(.foregroundColor, at: nameRange.location, effectiveRange: nil) as? NSColor
                            t.expect(
                                ink == .labelColor,
                                desc: "AppKit owns tab-state dimming without a second application color fade (\(expected))"
                            )
                        }
                    }
                }
                let presenter = TabAccessoryPresenter()
                let savedHeld = TabAccessoryPresenter.isCommandKeyHeld
                TabAccessoryPresenter.isCommandKeyHeld = true
                defer { TabAccessoryPresenter.isCommandKeyHeld = savedHeld }
                presenter.apply(
                    to: first,
                    hintPosition: 1,
                    isSelected: true,
                    reportedProgressState: 0,
                    progressState: 0,
                    progressValue: 0,
                    statusColor: nil,
                    notificationColor: .systemBlue,
                    hasUnheardBell: false,
                    hasUnseenNotification: false,
                    hasUnseenActivity: false,
                    foreground: 0xC0C0C0,
                    background: 0x101014,
                    usesNativeColors: true,
                    fontSize: 11
                )
                if let hint = first.tab.accessoryView as? NSTextField, hint.attributedStringValue.length > 0 {
                    let color = hint.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                    t.expect(color == .secondaryLabelColor, desc: "the shortcut retains the secondary catalog color")
                } else {
                    t.expect(false, desc: "the selected tab has a shortcut accessory")
                }
            }
        }

        UBUITestRegister("themed_tab_accessories_recede_with_an_inactive_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The harness application is never active, so every window here
                // reads as inactive, and each themed mark has to wear its
                // inactive ink rather than its active one: Core's coverage for
                // the hint, a fainter system label role for the ring and dots.
                let window = NSWindow(
                    contentRect: NSRect(x: -2000, y: -2000, width: 300, height: 120),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                defer { window.close() }
                t.expect(!WindowTabSelection.isGroupActive(window), desc: "the harness window reads as inactive")
                let savedHeld = TabAccessoryPresenter.isCommandKeyHeld
                TabAccessoryPresenter.isCommandKeyHeld = true
                defer { TabAccessoryPresenter.isCommandKeyHeld = savedHeld }
                let foreground: UInt32 = 0xC8CCD4
                let background: UInt32 = 0x15171C
                @MainActor
                func dress(isSelected: Bool, progress: UInt8, activity: Bool) -> NSView? {
                    TabAccessoryPresenter()
                        .apply(
                            to: window,
                            hintPosition: 1,
                            isSelected: isSelected,
                            reportedProgressState: progress,
                            progressState: progress,
                            progressValue: 40,
                            statusColor: nil,
                            notificationColor: .systemBlue,
                            hasUnheardBell: false,
                            hasUnseenNotification: false,
                            hasUnseenActivity: activity,
                            foreground: foreground,
                            background: background,
                            usesNativeColors: false,
                            fontSize: 11
                        )
                    return window.tab.accessoryView
                }
                @MainActor
                func expectCoverage(_ drawn: NSColor?, _ mark: Ubiquitty.Themes.TabAccessoryMark, isSelected: Bool, _ what: String) {
                    var facts = Ubiquitty.Themes.TabTitleFacts()
                    facts.isSelected = isSelected
                    facts.isWindowActive = false
                    facts.shouldIncreaseContrast = SystemDisplayOptions.shouldIncreaseContrast
                    let rgba = { (packed: UInt32) in
                        Ubiquitty.ColorRGBA(
                            red: UInt8((packed >> 16) & 0xFF),
                            green: UInt8((packed >> 8) & 0xFF),
                            blue: UInt8(packed & 0xFF),
                            alpha: 255
                        )
                    }
                    let inactive = Ubiquitty.Themes.tabAccessoryCoverage(mark, rgba(foreground), rgba(background), facts)
                    facts.isWindowActive = true
                    let active = Ubiquitty.Themes.tabAccessoryCoverage(mark, rgba(foreground), rgba(background), facts)
                    let alpha = drawn.map { Double($0.alphaComponent) } ?? -1
                    t.expect(inactive < active, desc: "Core recedes the \(what) in an inactive window")
                    t.expect(
                        abs(alpha - inactive) < 0.001,
                        desc: "the \(what) wears Core's inactive coverage \(inactive), not \(alpha)"
                    )
                }
                let hint = dress(isSelected: true, progress: 0, activity: false) as? NSTextField
                expectCoverage(
                    hint?.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                    .ShortcutHint,
                    isSelected: true,
                    "shortcut hint"
                )
                // The ring and the dots are images on the strip's glass, and
                // wear a system label role a step fainter than an active
                // window's, on a themed strip as on a native one.
                let ring = dress(isSelected: false, progress: 1, activity: false) as? TabStatusMark
                t.expect(
                    ring?.ink == .tertiaryLabelColor,
                    desc: "the progress ring wears the tertiary label colour in an inactive window, not \(String(describing: ring?.ink))"
                )
                let dots = dress(isSelected: false, progress: 0, activity: true) as? TabAttentionDots
                t.expect(
                    dots?.tintColor == .quaternaryLabelColor,
                    desc:
                        "the activity dots wear the quaternary label colour in an inactive window, not \(String(describing: dots?.tintColor))"
                )
            }
        }

        UBUITestRegister("swift_shell_themed_titlebar_carries_the_theme") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let wasNative =
                    Ubiquitty.Preferences.Effective.titlebarStyle(Ubiquitty.Preferences.values().pointee)
                    == Ubiquitty.Preferences.TitlebarStyle.Native
                defer { app.settingsSetTitlebarStyle(wasNative ? 1 : 0) }
                app.settingsSetTitlebarStyle(0) // themed

                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                shell.applyChromeTheme()
                t.pump(0.2)

                guard let container = titlebarContainer(of: shell) else {
                    t.expect(false, desc: "the window has a titlebar container to paint")
                    return
                }
                guard let painted = container.layer?.backgroundColor else {
                    t.expect(false, desc: "the titlebar container is painted at all")
                    return
                }
                // The paint is the terminal's own ground, which is what makes
                // the title row and the grid read as one surface. Compared
                // against the window's backing rather than against a literal:
                // the theme is whatever the sandboxed config says.
                guard let backing = shell.window?.backgroundColor else {
                    t.expect(false, desc: "the window carries a themed backing")
                    return
                }
                t.expect(
                    isSameColor(painted, backing),
                    desc: "the titlebar container is painted the window's own themed ground"
                )
                // Absent counts: a window whose title row carries no material
                // has nothing in front of the paint either. What must not
                // survive is a VISIBLE one.
                t.expect(
                    visualEffectView(in: container)?.isHidden != false,
                    desc: "no vibrancy material stands in front of the paint"
                )
                // The accessory bar is not the material: it draws nothing of
                // its own and carries the row's indicators, so the paint must
                // leave it standing.
                t.expect(
                    shell.windowAccessoryBar.map { !$0.isHiddenOrHasHiddenAncestor } == true,
                    desc: "and the accessory bar the row's indicators stand in survives the paint"
                )
                t.expect(
                    shell.window?.titlebarAppearsTransparent == true,
                    desc: "and the title row still composes over the backing"
                )

                // Native hands both back: the setting exists for people who
                // want the system's vibrant row, and a paint left behind would
                // be ignoring them.
                app.settingsSetTitlebarStyle(1) // native
                t.pump(0.2)
                t.expect(
                    Ubiquitty.Preferences.Effective.launchSettings().titlebarStyle
                        == Ubiquitty.Preferences.TitlebarStyle.Native,
                    desc: "the setting moved, so what follows is about the window and not the write"
                )
                t.expect(
                    container.layer?.backgroundColor == nil,
                    desc: "a native title bar clears the themed paint"
                )
                t.expect(
                    visualEffectView(in: container)?.isHidden != true,
                    desc: "and leaves the system's material showing"
                )
                t.expect(
                    shell.window?.titlebarAppearsTransparent == false,
                    desc: "and stops borrowing the backing"
                )
            }
        }

        UBUITestRegister("swift_shell_chromeless_titlebar_stays_clear") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let launch = Ubiquitty.Preferences.Effective.launchSettings()
                let wasHidden = launch.shouldHideTitleBar
                let wasNative = launch.titlebarStyle == Ubiquitty.Preferences.TitlebarStyle.Native
                defer {
                    app.settingsSetHideTitleBar(wasHidden)
                    app.settingsSetTitlebarStyle(wasNative ? 1 : 0)
                }
                app.settingsSetTitlebarStyle(0) // themed, so a titled window is painted
                app.settingsSetHideTitleBar(false)

                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { shell.window?.close() }
                shell.window?.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                shell.applyChromeTheme()
                t.pump(0.2)

                guard let container = titlebarContainer(of: shell) else {
                    t.expect(false, desc: "the window has a titlebar container")
                    return
                }
                // The comparison the case rests on: the same window, themed
                // throughout, painted while it has a title bar and clear once
                // it does not. Asserting only the clear would pass on a build
                // that paints nothing at all.
                t.expect(
                    isOpaquePaint(container.layer?.backgroundColor),
                    desc: "a titled themed window has an opaque title row"
                )

                app.settingsSetHideTitleBar(true)
                t.pump(0.3)
                t.expect(
                    shell.window?.styleMask.contains(.fullSizeContentView) == true,
                    desc: "hiding the title bar gives the window a full-size content view"
                )
                t.expect(
                    !isOpaquePaint(container.layer?.backgroundColor),
                    desc: "so the title row is left clear for the Metal body under it"
                )
                t.expect(
                    visualEffectView(in: container)?.isHidden != false,
                    desc: "and no material stands in front of that body"
                )

                // And back: a window that was chromeless once must not stay
                // chromeless when the setting is turned off again.
                app.settingsSetHideTitleBar(false)
                t.pump(0.3)
                t.expect(
                    shell.window?.styleMask.contains(.fullSizeContentView) == false,
                    desc: "turning it off restores the content view"
                )
                t.expect(
                    isOpaquePaint(container.layer?.backgroundColor),
                    desc: "and the themed title row comes back"
                )
            }
        }

        UBUITestRegister("swift_shell_settings_reach_an_open_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let savedSize = Ubiquitty.Preferences.Effective.fontSize(Ubiquitty.Preferences.values().pointee)
                defer { app.settingsSetFontSize(savedSize) }

                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content),
                    let before = surface.renderer?.cellSize(for: surface)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a renderer")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.2)

                // The font size, because it is the setting a user changes most
                // and the one whose effect is measurable rather than a colour:
                // a bigger point size is a bigger cell.
                app.settingsSetFontSize(savedSize + 4)
                t.pump(0.3)
                guard let after = surface.renderer?.cellSize(for: surface) else {
                    t.expect(false, desc: "the window still has a renderer")
                    return
                }
                t.expect(
                    after.height > before.height,
                    desc: "a font-size change reaches an OPEN Swift-shell window (cell was \(before.height), is \(after.height))"
                )

                // And the window facts, which are held per window rather than
                // per frame and so have nothing a redraw would pick them up
                // from.
                app.settingsSetSnapWindowResize(false)
                t.pump(0.2)
                t.expect(
                    shell.snapsWindowResizeForTesting == false,
                    desc: "the resize snap reaches it too"
                )
                app.settingsSetSnapWindowResize(true)
                t.pump(0.2)
                t.expect(
                    shell.snapsWindowResizeForTesting,
                    desc: "and back"
                )
            }
        }

        UBUITestRegister("swift_shell_cursor_settings_reach_the_model") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "live UBAppDelegate reachable")
                    return
                }
                let savedRate = Int(
                    Ubiquitty.Preferences.Effective.cursorBlinkRate(
                        Ubiquitty.Preferences.values().pointee
                    )
                )
                let savedLinger = Int(
                    Ubiquitty.Preferences.Effective.cursorLinger(
                        Ubiquitty.Preferences.values().pointee
                    )
                )
                defer {
                    app.settingsSetCursorBlinkRate(savedRate)
                    app.settingsSetCursorLinger(savedLinger)
                }

                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.2)

                // Read the MODEL, not a renderer field: these four are terminal
                // state, and the point of routing them through
                // applyTerminalPreferences is that one lock writes all of them.
                @MainActor
                func modelBlinkPeriod() -> UInt32? {
                    surface.drive.withTerminal { $0.cursorBlinkPeriodMilliseconds } ?? nil
                }
                @MainActor
                func modelHoldFrames() -> UInt32? {
                    surface.drive.withTerminal { $0.cursorHoldFrames } ?? nil
                }

                // Spawn seeds the configured cursor preferences into the
                // terminal, as every other spawn, split, restore and adopt route
                // does, so the window opens carrying the effective blink period
                // rather than the construction-default zero. Asserting the seeded
                // value, distinct from savedRate + 250 below, keeps the later
                // write a real change rather than a coincidence.
                t.expect(
                    modelBlinkPeriod() == UInt32(savedRate),
                    desc: "the shell's terminal opens with the configured blink period applied at spawn"
                )
                app.settingsSetCursorBlinkRate(savedRate + 250)
                app.settingsSetCursorLinger(savedLinger + 7)
                t.pump(0.3)

                t.expect(
                    modelBlinkPeriod() == UInt32(savedRate + 250),
                    desc: "the blink rate reaches an OPEN Swift-shell window's terminal (is \(String(describing: modelBlinkPeriod())))"
                )
                t.expect(
                    modelHoldFrames() == UInt32(savedLinger + 7),
                    desc: "and so does the linger (is \(String(describing: modelHoldFrames())))"
                )

                // Back down, so this asserts the model FOLLOWS the setting
                // rather than that it moved once.
                app.settingsSetCursorBlinkRate(savedRate)
                t.pump(0.3)
                t.expect(
                    modelBlinkPeriod() == UInt32(savedRate),
                    desc: "and follows it back down"
                )
            }
        }

        UBUITestRegister("objc_inactive_tab_strip_keeps_semantic_colors") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard #available(macOS 26.0, *), let first = t.newWindowRunning(nil),
                    let firstWindow = first.window, let second = t.newWindowRunning(nil),
                    let secondWindow = second.window
                else {
                    t.expect(false, desc: "Objective-C shell windows open")
                    return
                }
                defer { t.closeAllWindows() }
                firstWindow.addTabbedWindow(secondWindow, ordered: .above)
                guard t.wait(until: { firstWindow.tabGroup?.windows.count == 2 }, timeout: 8),
                    let group = firstWindow.tabGroup
                else {
                    t.expect(false, desc: "the Objective-C shell has two native tabs")
                    return
                }
                let focusWindow = NSWindow(
                    contentRect: NSRect(x: -2000, y: -2000, width: 200, height: 100),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                focusWindow.isReleasedWhenClosed = false
                focusWindow.tabbingMode = .disallowed
                defer { focusWindow.close() }
                for isDark in [true, false] {
                    let ground =
                        isDark
                        ? NSColor(srgbRed: 0x15 / 255.0, green: 0x17 / 255.0, blue: 0x1c / 255.0, alpha: 1)
                        : NSColor(srgbRed: 0xf4 / 255.0, green: 0xf5 / 255.0, blue: 0xf8 / 255.0, alpha: 1)
                    for window in group.windows {
                        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
                        window.backgroundColor = ground
                    }
                    for selected in group.windows {
                        group.selectedWindow = selected
                        selected.makeKeyAndOrderFront(nil)
                        t.pump(0.2)
                        guard let content = selected.contentView,
                            let container = TabStripStyling.titlebarContainer(searchingFrom: content.superview ?? content)
                        else {
                            t.expect(false, desc: "the selected tab has a titlebar strip")
                            continue
                        }
                        for isActive in [false, true] {
                            if isActive { selected.makeKeyAndOrderFront(nil) } else { focusWindow.makeKeyAndOrderFront(nil) }
                            t.pump(0.2)
                            for usesNativeTitleColors in [false, true, false] {
                                TabStripStyling.apply(container: container, window: selected, usesNativeTitleColors: usesNativeTitleColors)
                                guard let paint = TabStripStyling.testPaint(in: container) else {
                                    t.expect(false, desc: "tab paint is inspectable")
                                    continue
                                }
                                t.expect(
                                    paint.band == nil && TabStripStyling.testBandTint(in: container) == nil,
                                    desc: "opaque and translucent chrome both retain the native untinted track"
                                )
                                t.expect(
                                    paint.pills.count == 2 && paint.pills.allSatisfy { $0 == nil },
                                    desc: "neither tab receives a solid custom capsule"
                                )
                                t.expect(paint.tints.allSatisfy { $0 == nil }, desc: "no custom glass tint obscures selection")
                                t.expect(paint.styles == [.regular, .regular], desc: "AppKit owns the selection material")
                                t.expect(
                                    zip(paint.positions, paint.positions.dropFirst()).allSatisfy { $0 < $1 },
                                    desc: "native pills stay in tab order"
                                )
                                let appearance = TabStripStyling.testAppearanceNames(in: container)
                                t.expect(
                                    appearance?.strip == nil && appearance?.outer == nil
                                        && appearance?.pills.allSatisfy { $0 == nil } == true,
                                    desc: "track and pills inherit the window's appearance"
                                )
                                if !usesNativeTitleColors {
                                    expectTitlesCarryTheirBake(t, paint: paint, windows: group.windows, state: "opaque")
                                }
                            }
                        }
                    }
                }
            }
        }

        UBUITestRegister("tab_titles_take_cores_coverage_in_both_shells") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let first = t.newWindowRunning(nil), let firstWindow = first.window,
                    let second = t.newWindowRunning(nil), let secondWindow = second.window
                else {
                    t.expect(false, desc: "an Objective-C shell window opens")
                    return
                }
                defer { t.closeAllWindows() }
                t.pump(0.6)
                firstWindow.addTabbedWindow(secondWindow, ordered: .above)
                t.pump(1.2)
                let objcWindows = first.window?.tabGroup?.windows ?? []
                guard objcWindows.count == 2, let objcSelected = first.window?.tabGroup?.selectedWindow else {
                    t.expect(false, desc: "the Objective-C shell has two native tabs")
                    return
                }
                // The shell re-bakes on the focus change a selection brings in
                // use; the harness's windows never take focus, so the settled
                // selection is handed back to the shell's own walk.
                (objcSelected.windowController as? TerminalWindowController)?.refreshTabTitle()
                t.pump(0.3)
                expectTabTitlesTakeCoresCoverage(t, windows: objcWindows, shell: "Objective-C")

                guard let shell = TerminalWindowController.spawn(), let swiftWindow = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                swiftWindow.makeKeyAndOrderFront(nil)
                t.pump(0.6)
                shell.newWindowForTab(nil)
                t.pump(1.2)
                let swiftWindows = swiftWindow.tabGroup?.windows ?? []
                guard swiftWindows.count == 2 else {
                    t.expect(false, desc: "the Swift shell has two native tabs")
                    return
                }
                for tabWindow in swiftWindows {
                    (tabWindow.windowController as? TerminalWindowController)?.refreshTabTitle()
                }
                t.pump(0.3)
                expectTabTitlesTakeCoresCoverage(t, windows: swiftWindows, shell: "Swift")
            }
        }

        UBUITestRegister("tab_strip_appearance_follows_the_theme_fact_not_the_band") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard #available(macOS 26.0, *), let first = t.newWindowRunning(nil),
                    let delegate = NSApp.delegate as? UBAppDelegate
                else {
                    t.expect(false, desc: "an Objective-C shell window opens")
                    return
                }
                defer { t.closeAllWindows() }
                t.pump(0.6)
                delegate.newTab(nil)
                t.pump(1.2)
                guard let selected = first.window?.tabGroup?.selectedWindow,
                    let content = selected.contentView,
                    let container = TabStripStyling.titlebarContainer(searchingFrom: content.superview ?? content)
                else {
                    t.expect(false, desc: "the selected tab has a titlebar strip")
                    return
                }
                for name in [NSAppearance.Name.darkAqua, .aqua, .darkAqua] {
                    selected.appearance = NSAppearance(named: name)
                    TabStripStyling.apply(container: container, window: selected, usesNativeTitleColors: false)
                    t.pump(0.2)
                    guard let strip = TabStripStyling.tabStripView(inGroupOf: selected),
                        let appearance = TabStripStyling.testAppearanceNames(in: container)
                    else {
                        t.expect(false, desc: "the native strip has an inspectable appearance")
                        continue
                    }
                    t.expect(
                        appearance.container == nil && appearance.strip == nil && appearance.outer == nil
                            && appearance.pills.allSatisfy { $0 == nil },
                        desc: "no tab decoration pins a stale appearance"
                    )
                    t.expect(
                        strip.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == name,
                        desc: "native material resolves from the window's current theme"
                    )
                    TabStripStyling.clear(container: container)
                    if let host = TabStripMaterial.filterHost(in: strip) {
                        let fills = host.sublayers?.filter { $0.name == "kCUIVariantContentBackgroundMaterial" } ?? []
                        t.expect(
                            !fills.isEmpty && fills.allSatisfy { !$0.isHidden },
                            desc: "the native-titlebar setting restores AppKit's unmodified track"
                        )
                    }
                }
            }
        }

        UBUITestRegister("secure_lock_tint_follows_the_window_appearance") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let first = t.newWindowRunning(nil) else {
                    t.expect(false, desc: "an Objective-C shell window opens")
                    return
                }
                defer { t.closeAllWindows() }
                t.pump(0.6)

                guard let content = first.window?.contentView,
                    let lock = secureLock(in: content.superview ?? content)
                else {
                    t.expect(false, desc: "the accessory bar carries a secure-entry lock")
                    return
                }
                t.expect(
                    lock.alphaValue == 1,
                    desc: "the lock's semantic ink is not additionally faded"
                )
                t.expect(
                    lock.image?.isTemplate == true && lock.allowsVibrancy && lock.contentTintColor == .tertiaryLabelColor,
                    desc: "the noninteractive lock retains quiet semantic ink and native template vibrancy"
                )
                guard let tint = lock.contentTintColor else {
                    t.expect(false, desc: "the lock carries a tint at all")
                    return
                }
                // Resolved under each polarity in turn. A tint baked at install
                // resolves the same both ways, so it fails one of these arms
                // on any machine, whichever appearance did the baking.
                let underDark = resolvedBrightness(of: tint, under: .darkAqua)
                let underLight = resolvedBrightness(of: tint, under: .aqua)
                t.expect(underDark > 0.5, desc: "under a dark window the lock resolves light (is \(underDark))")
                t.expect(underLight < 0.5, desc: "under a light window the lock resolves dark (is \(underLight))")
            }
        }
    }
}

/// Asserts every tab title draws in the ink its tab baked.
///
/// AppKit copies a tab's attributed title into the strip with its colour mapped
/// by main-window and selection state, which is the dim grey that measured
/// under every floor; the strip paint writes the bake back. So what is read
/// here is the field's own first run — the colour that draws — against the
/// tab's `attributedTitle`, and the two must agree on every pill.
///
/// - Parameters:
///   - t: The running scenario.
///   - paint: The inspected strip paint.
///   - windows: The group's windows, in strip order.
///   - state: The strip state, named in each expectation.
@MainActor
private func expectTitlesCarryTheirBake(
    _ t: UBUITestContext,
    paint: (
        band: CGColor?, pills: [CGColor?], tints: [NSColor?], titleAlphas: [[CGFloat]],
        buttonAlphas: [[CGFloat]], styles: [NSGlassEffectView.Style], positions: [CGFloat],
        titleColors: [[CGColor?]]
    ),
    windows: [NSWindow],
    state: String
) {
    var measured = 0
    for (index, colors) in paint.titleColors.enumerated() {
        guard index < windows.count, let baked = windows[index].tab.attributedTitle, baked.length > 0,
            let bakedInk = baked.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        else {
            t.expect(false, desc: "\(state) tab \(index) has a baked title to compare against")
            continue
        }
        // The inspector returns the field whose string matches the tab's bake;
        // an accessory field can precede it in AppKit's private hierarchy.
        guard let drawn = colors.first ?? nil else {
            t.expect(false, desc: "\(state) tab \(index) title draws a colour")
            continue
        }
        measured += 1
        t.expect(
            isSameColor(drawn, bakedInk),
            desc:
                "\(state) tab \(index) title draws in the ink its tab baked, not AppKit's mapped grey "
                + "(drawn \(drawn), baked \(bakedInk))"
        )
    }
    t.expect(measured == windows.count, desc: "\(state) every tab title was measured")
}

/// Asserts every tab of a group bakes its title in one ink at Core's coverage.
///
/// The facts are read off the windows as the shells read them — selection from
/// the group, focus from the selected window, the switch from the workspace —
/// and Core is asked what coverage they give. The ink's opacity must be that
/// number, its colour one theme foreground across the group, and its weight
/// semibold on the selected tab and regular on the rest.
///
/// - Parameters:
///   - t: The running scenario.
///   - windows: The group's windows, in strip order.
///   - shell: Which shell baked them, named in each expectation.
@MainActor
private func expectTabTitlesTakeCoresCoverage(_ t: UBUITestContext, windows: [NSWindow], shell: String) {
    let selected = windows.first?.tabGroup?.selectedWindow
    var inks: [UInt32] = []
    for (index, tabWindow) in windows.enumerated() {
        guard let baked = tabWindow.tab.attributedTitle, baked.length > 0,
            let ink = (baked.attribute(.foregroundColor, at: baked.length - 1, effectiveRange: nil) as? NSColor)?
                .usingColorSpace(.sRGB),
            let font = baked.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        else {
            t.expect(false, desc: "\(shell) tab \(index) carries a baked title with an ink and a font")
            continue
        }
        // Under Increase Contrast the coverage depends on the theme's band, and
        // the bake carries only the foreground. Every built-in theme with that
        // foreground is asked; three pairs share one, and where the switch is
        // off they answer alike, so a match with any of them is the shell
        // agreeing with Core on the facts it had.
        var facts = Ubiquitty.Themes.TabTitleFacts()
        facts.isSelected = tabWindow === selected
        facts.isWindowActive = selected.map { WindowTabSelection.isGroupActive($0) } ?? false
        facts.shouldIncreaseContrast = SystemDisplayOptions.shouldIncreaseContrast
        let inkRGB = packed(rgba(ink))
        inks.append(inkRGB)
        let coverages = builtInThemes(withForeground: inkRGB)
            .map {
                Ubiquitty.Themes.tabTitleCoverage($0.defaultForeground, $0.defaultBackground, facts)
            }
        t.expect(!coverages.isEmpty, desc: "\(shell) tab \(index) ink #\(String(inkRGB, radix: 16)) is a built-in theme's foreground")
        t.expect(
            coverages.contains { abs(Double(ink.alphaComponent) - $0) < 0.005 },
            desc:
                "\(shell) tab \(index) (\(facts.isSelected ? "selected" : "unselected"), window \(facts.isWindowActive ? "active" : "inactive")) "
                + "is inked at Core's coverage \(coverages.map { String(format: "%.2f", $0) }.joined(separator: "/")), not \(String(format: "%.2f", ink.alphaComponent))"
        )
        let weight = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? Double ?? 0
        t.expect(
            facts.isSelected ? abs(weight - NSFont.Weight.semibold.rawValue) < 0.01 : abs(weight) < 0.01,
            desc: "\(shell) tab \(index) title is \(facts.isSelected ? "semibold" : "regular") weight (\(weight))"
        )
    }
    t.expect(inks.count == windows.count, desc: "\(shell) every tab was measured")
    t.expect(Set(inks).count == 1, desc: "\(shell) every tab shares the theme foreground as its ink")
}

/// The built-in themes whose default foreground is `packedRGB`.
private func builtInThemes(withForeground packedRGB: UInt32) -> [Ubiquitty.Themes.Theme] {
    var found: [Ubiquitty.Themes.Theme] = []
    for index in 0..<Ubiquitty.Themes.count() {
        guard let theme = Ubiquitty.Themes.get(index), packed(theme.pointee.defaultForeground) == packedRGB else { continue }
        found.append(theme.pointee)
    }
    return found
}

/// An opaque sRGB colour as Core's byte triple.
@MainActor
private func rgba(_ color: NSColor) -> Ubiquitty.ColorRGBA {
    let channel = { (value: CGFloat) -> UInt8 in UInt8(clamping: Int((Swift.min(Swift.max(value, 0), 1) * 255).rounded())) }
    return Ubiquitty.ColorRGBA(
        red: channel(color.redComponent),
        green: channel(color.greenComponent),
        blue: channel(color.blueComponent),
        alpha: 255
    )
}

/// Core's byte triple as an opaque sRGB colour.
private func nsColor(_ color: Ubiquitty.ColorRGBA) -> NSColor {
    NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1)
}

/// Core's byte triple packed as the contrast helpers take it.
private func packed(_ color: Ubiquitty.ColorRGBA) -> UInt32 {
    (UInt32(color.red) << 16) | (UInt32(color.green) << 8) | UInt32(color.blue)
}

/// Whether a layer colour is an actual opaque paint rather than unset or clear.
///
/// - Parameter color: The layer's background colour.
/// - Returns: Whether something opaque was painted.
@MainActor
private func isOpaquePaint(_ color: CGColor?) -> Bool {
    guard let color else { return false }
    return color.alpha > 0.5
}

/// The titlebar container of a Swift-shell window.
///
/// - Parameter shell: The window's controller.
/// - Returns: The container, or nil when AppKit has not built one.
@MainActor
private func titlebarContainer(of shell: TerminalWindowController) -> NSView? {
    guard let content = shell.window?.contentView else { return nil }
    return TabStripStyling.titlebarContainer(searchingFrom: content.superview ?? content)
}

/// The secure-keyboard-entry lock inside a window's accessory bar.
///
/// Found by its runtime class name so the search does not care which module
/// hosts the class; read through `NSImageView`, which carries everything the
/// scenario asserts.
///
/// - Parameter root: The view to search under.
/// - Returns: The lock, or nil when no bar carries one.
@MainActor
private func secureLock(in root: NSView) -> NSImageView? {
    if NSStringFromClass(type(of: root)) == "UBSecureKeyboardEntryLock", let lock = root as? NSImageView {
        return lock
    }
    for subview in root.subviews {
        if let found = secureLock(in: subview) {
            return found
        }
    }
    return nil
}

/// A colour's brightness as one appearance resolves it.
///
/// - Parameters:
///   - color: The colour, dynamic or already resolved.
///   - name: The appearance to resolve under.
/// - Returns: The mean sRGB component in 0...1, or -1 when unresolvable.
@MainActor
private func resolvedBrightness(of color: NSColor, under name: NSAppearance.Name) -> CGFloat {
    NSAppearance(named: name).map { resolvedBrightness(of: color, under: $0) } ?? -1
}

/// A colour's brightness as an appearance resolves it.
///
/// - Parameters:
///   - color: The colour, dynamic or already resolved.
///   - appearance: The appearance to resolve under, such as the one a view
///     draws with.
/// - Returns: The mean sRGB component in 0...1, or -1 when unresolvable.
@MainActor
private func resolvedBrightness(of color: NSColor, under appearance: NSAppearance) -> CGFloat {
    var brightness: CGFloat = -1
    appearance.performAsCurrentDrawingAppearance {
        if let resolved = color.usingColorSpace(.sRGB) {
            brightness = (resolved.redComponent + resolved.greenComponent + resolved.blueComponent) / 3
        }
    }
    return brightness
}

/// The vibrancy material inside a titlebar container.
///
/// AppKit's material only: the window's accessory bar is an effect view too,
/// and a helper that takes it for the material asserts the bar hidden, which
/// passes on a themed title row that has lost the host chip and the
/// secure-input lock.
///
/// - Parameter container: The container to search.
/// - Returns: The material view, or nil when the container carries none.
@MainActor
private func visualEffectView(in container: NSView) -> NSView? {
    if container is ChromeAccessoryBar {
        return nil
    }
    if container is NSVisualEffectView {
        return container
    }
    for subview in container.subviews {
        if let found = visualEffectView(in: subview) {
            return found
        }
    }
    return nil
}

/// Whether two colours name the same sRGB point.
///
/// - Parameters:
///   - lhs: A CGColor, as a layer holds one.
///   - rhs: An NSColor, as a window holds one.
/// - Returns: Whether they agree to within a rounding of one 8-bit step.
@MainActor
private func isSameColor(_ lhs: CGColor, _ rhs: NSColor) -> Bool {
    guard let left = NSColor(cgColor: lhs)?.usingColorSpace(.sRGB),
        let right = rhs.usingColorSpace(.sRGB)
    else {
        return false
    }
    let tolerance = 1.0 / 255.0
    return abs(left.redComponent - right.redComponent) <= tolerance
        && abs(left.greenComponent - right.greenComponent) <= tolerance
        && abs(left.blueComponent - right.blueComponent) <= tolerance
}

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let surface = view as? TerminalSurface {
        return surface
    }
    for subview in view.subviews {
        if let found = terminalSurface(under: subview) {
            return found
        }
    }
    return nil
}

/// Waits for every tab of a group to wear one theme, then asserts what each
/// tab behind the selected one draws from it.
///
/// A tab restyled only when it is selected, or when something else redraws
/// it, keeps the previous theme in each of these: the foreground its title is
/// baked in and its pill draws that title in, and a template program icon's
/// tint. A status mark and the runs that only place or join a title wear
/// system label colours instead, which the strip resolves under the
/// appearance the theme gives the window, so what a theme change has to
/// move for them is that appearance: light ink under a dark theme, dark ink
/// under a light one. The selection is read before the wait and after it,
/// so no tab can pass by having been brought to the front.
///
/// - Parameters:
///   - t: The running scenario.
///   - windows: The group's windows, in strip order.
///   - foreground: The foreground every tab is to wear, packed 0xRRGGBB.
///   - isDark: Whether the theme is dark, which makes the window's appearance
///     dark and every system label colour on its tabs resolve light.
///   - iconWindows: The tabs whose title leads with a template program icon.
///   - markWindows: The tabs whose accessory is a status mark.
///   - state: What changed, named in each expectation.
@MainActor
func expectBackgroundTabsWear(
    _ t: UBUITestContext,
    windows: [NSWindow],
    foreground: UInt32,
    isDark: Bool,
    iconWindows: [NSWindow] = [],
    markWindows: [NSWindow] = [],
    state: String
) {
    guard let group = windows.first?.tabGroup, let selected = group.selectedWindow else {
        t.expect(false, desc: "\(state): the tabs stand in one group with a selected tab")
        return
    }
    let behind = windows.filter { $0 !== selected }
    t.expect(!behind.isEmpty, desc: "\(state): a tab stands behind the selected one")
    let hex = { (packed: UInt32?) in packed.map { "#" + String(format: "%06x", $0) } ?? "none" }
    let polarity = isDark ? "light on the dark theme" : "dark on the light theme"
    let appearance: NSAppearance.Name = isDark ? .darkAqua : .aqua
    // The strip lives in the selected window's title row and resolves under
    // that window's appearance; a release without one has nothing to wait for.
    let isStripUnderTheTheme = {
        guard let strip = TabStripStyling.tabStripView(inGroupOf: selected) else { return true }
        return strip.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance
    }
    // What each pill behind the selected one draws, against its tab's bake.
    // A selection or main change hands the pills AppKit's own copy of every
    // title at once, and the shell re-bakes and writes its bakes back over it
    // on the turns after, so a pill is read once the strip has settled rather
    // than at the change.
    let pillFailures = { () -> [String] in
        guard #available(macOS 26.0, *), TabStripStyling.tabStripView(inGroupOf: selected) != nil else { return [] }
        return windows.enumerated()
            .filter { $0.element !== selected }
            .flatMap { index, window in
                drawnTitleFailures(of: window, at: index, inGroupOf: selected, isDark: isDark, state: state)
            }
    }
    _ = t.wait(
        until: {
            behind.allSatisfy { isNearPacked(bakedTitleInk(of: $0), foreground) }
                && iconWindows.allSatisfy { isTemplateIconTinted($0, with: foreground) }
                && isStripUnderTheTheme()
                && markWindows.allSatisfy { window in
                    guard let mark = window.tab.accessoryView as? TabStatusMark, let ink = mark.ink else { return false }
                    return isDrawn(ink, in: mark, withPolarityOf: isDark)
                }
                && pillFailures().isEmpty
        },
        timeout: 15
    )
    t.expect(group.selectedWindow === selected, desc: "\(state): no tab was brought to the front to restyle it")
    for (index, window) in windows.enumerated() where window !== selected {
        t.expect(
            isNearPacked(bakedTitleInk(of: window), foreground),
            desc: "\(state): background tab \(index)'s label wears \(hex(foreground)), not \(hex(bakedTitleInk(of: window)))"
        )
    }
    for window in iconWindows {
        let index = windows.firstIndex(of: window) ?? -1
        t.expect(
            isTemplateIconTinted(window, with: foreground),
            desc:
                "\(state): tab \(index)'s program icon draws \(hex(templateIconInk(of: window, wearing: foreground))) "
                + "as \(hex(foreground)) tints it, not \(hex(templateIconInk(of: window)))"
        )
    }
    for window in markWindows {
        let index = windows.firstIndex(of: window) ?? -1
        guard let mark = window.tab.accessoryView as? TabStatusMark, let ink = mark.ink else {
            t.expect(false, desc: "\(state): tab \(index) shows its status mark")
            continue
        }
        t.expect(
            TabTitleStyling.isSystemColor(ink),
            desc: "\(state): tab \(index)'s status mark wears a system label colour, not \(ink)"
        )
        t.expect(
            isDrawn(ink, in: mark, withPolarityOf: isDark),
            desc: "\(state): tab \(index)'s status mark draws \(polarity), not \(describeDrawn(ink, in: mark))"
        )
    }
    for failure in pillFailures() {
        t.expect(false, desc: failure)
    }
}

/// What a background tab's pill draws that its tab's bake does not say.
///
/// The pill's title words in the ink they were baked in; the pill resolving
/// system colours under the theme's appearance; and every system-coloured
/// run of the pill in the colour its bake gave that run, drawn with the
/// theme's polarity.
///
/// - Parameters:
///   - window: The background tab's window.
///   - index: The tab's place in the strip.
///   - selected: The group's selected window, whose title row holds the strip.
///   - isDark: Whether the theme is dark.
///   - state: What changed, named in each failure.
/// - Returns: One description per disagreement; empty when the pill draws its
///   bake as the theme asks.
@available(macOS 26.0, *)
@MainActor
private func drawnTitleFailures(
    of window: NSWindow,
    at index: Int,
    inGroupOf selected: NSWindow,
    isDark: Bool,
    state: String
) -> [String] {
    guard let field = TabStripStyling.testTitleField(inGroupOf: selected, at: index),
        let baked = window.tab.attributedTitle, baked.length > 0,
        field.attributedStringValue.string == baked.string
    else {
        return ["\(state): background tab \(index)'s pill draws its title to compare"]
    }
    let polarity = isDark ? "light on the dark theme" : "dark on the light theme"
    var failures: [String] = []
    let drawn = field.attributedStringValue
    let ink = { (title: NSAttributedString, location: Int) in
        title.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }
    // The title's own words close it, in the theme's foreground.
    let last = baked.length - 1
    let drawnWords = ink(drawn, last)
    if drawnWords.flatMap({ drawnInk in ink(baked, last).map { isSameInk(drawnInk, $0) } }) != true {
        failures.append(
            "\(state): background tab \(index)'s pill draws its title in the ink it baked (drawn \(String(describing: drawnWords)))"
        )
    }
    if field.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != (isDark ? .darkAqua : .aqua) {
        failures.append(
            "\(state): background tab \(index)'s pill resolves its title's system colours under the theme's appearance, "
                + "not \(field.effectiveAppearance.name.rawValue)"
        )
    }
    // The runs that only place or join it wear system label colours: the ones
    // it was baked with, drawn with the theme's polarity.
    var location = 0
    while location < drawn.length {
        var run = NSRange()
        let drawnInk = drawn.attribute(.foregroundColor, at: location, effectiveRange: &run) as? NSColor
        location = max(NSMaxRange(run), location + 1)
        guard let drawnInk, TabTitleStyling.isSystemColor(drawnInk) else { continue }
        if ink(baked, run.location) != drawnInk {
            failures.append(
                "\(state): background tab \(index)'s pill draws its run at \(run.location) in the system colour it baked, "
                    + "not \(drawnInk)"
            )
        }
        if !isDrawn(drawnInk, in: field, withPolarityOf: isDark) {
            failures.append(
                "\(state): background tab \(index)'s pill draws its run at \(run.location) \(polarity), "
                    + "not \(describeDrawn(drawnInk, in: field))"
            )
        }
    }
    return failures
}

/// Whether a colour draws in a view with the polarity a theme asks for:
/// resolved under the view's own appearance, as AppKit resolves a dynamic
/// system colour when it draws one, light for a dark theme and dark for a
/// light one.
///
/// - Parameters:
///   - ink: The colour the view draws.
///   - view: The view drawing it.
///   - isDark: Whether the theme is dark.
/// - Returns: Whether the view's appearance has the theme's darkness and the
///   colour resolves on the matching side of mid-grey under it.
@MainActor
private func isDrawn(_ ink: NSColor, in view: NSView, withPolarityOf isDark: Bool) -> Bool {
    guard view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (isDark ? .darkAqua : .aqua) else { return false }
    let brightness = resolvedBrightness(of: ink, under: view.effectiveAppearance)
    return brightness >= 0 && (brightness > 0.5) == isDark
}

/// What a colour draws as in a view, for a failure to name.
///
/// - Parameters:
///   - ink: The colour the view draws.
///   - view: The view drawing it.
/// - Returns: The appearance it resolves under and its brightness there.
@MainActor
private func describeDrawn(_ ink: NSColor, in view: NSView) -> String {
    let brightness = resolvedBrightness(of: ink, under: view.effectiveAppearance)
    return "brightness \(String(format: "%.2f", brightness)) under \(view.effectiveAppearance.name.rawValue)"
}

/// Whether a pill draws a run in the colour its tab baked it in: the same
/// system colour, or the same sRGB point for any other.
///
/// - Parameters:
///   - drawn: The colour the pill's field holds.
///   - baked: The colour the tab's title was baked in.
/// - Returns: Whether they agree.
@MainActor
private func isSameInk(_ drawn: NSColor, _ baked: NSColor) -> Bool {
    if TabTitleStyling.isSystemColor(drawn) || TabTitleStyling.isSystemColor(baked) {
        return drawn == baked
    }
    return isSameColor(drawn.cgColor, baked)
}

/// The ink a tab's title text was baked in: its last run, which the selected
/// tab's receded folder never covers.
///
/// - Parameter window: The tab's window.
/// - Returns: The ink packed 0xRRGGBB, or nil before a bake.
@MainActor
func bakedTitleInk(of window: NSWindow) -> UInt32? {
    guard let baked = window.tab.attributedTitle, baked.length > 0,
        let ink = (baked.attribute(.foregroundColor, at: baked.length - 1, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
    else {
        return nil
    }
    return packed(rgba(ink))
}

/// The ink a tab's status mark wears.
///
/// A system label colour is returned as itself: it has no one value until a
/// view resolves it under the appearance it draws with.
///
/// - Parameter window: The tab's window.
/// - Returns: The ink, or nil where the tab shows no mark.
@MainActor
func statusMarkInk(of window: NSWindow) -> NSColor? {
    (window.tab.accessoryView as? TabStatusMark)?.ink
}

/// The colour a template program icon leading a tab's title draws: the
/// colour of its most opaque pixel.
///
/// - Parameter window: The tab's window.
/// - Returns: The colour packed 0xRRGGBB, or nil where the title has no icon.
@MainActor
func templateIconInk(of window: NSWindow) -> UInt32? {
    guard let title = window.tab.attributedTitle, title.length > 0,
        let attachment = title.attribute(.attachment, at: 0, effectiveRange: nil) as? ProcessIconAttachment,
        let image = attachment.image
    else {
        return nil
    }
    return opaquestPixel(of: image)
}

/// The colour the icon leading a tab's title draws when it is tinted with a
/// foreground at the coverage the title wears: the same icon drawn afresh,
/// read as ``templateIconInk(of:)`` reads the tab's.
///
/// A template icon is the ink laid over its own shape, so its pixels are the
/// ink composited at the title's coverage rather than the ink itself.
///
/// - Parameters:
///   - window: The tab's window.
///   - foreground: The foreground, packed 0xRRGGBB.
/// - Returns: The colour packed 0xRRGGBB, or nil where the title has no icon.
@MainActor
func templateIconInk(of window: NSWindow, wearing foreground: UInt32) -> UInt32? {
    guard let title = window.tab.attributedTitle, title.length > 0,
        let attachment = title.attribute(.attachment, at: 0, effectiveRange: nil) as? ProcessIconAttachment,
        let coverage = (title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil) as? NSColor)?.alphaComponent
    else {
        return nil
    }
    let ink = NSColor(
        srgbRed: CGFloat((foreground >> 16) & 0xFF) / 255,
        green: CGFloat((foreground >> 8) & 0xFF) / 255,
        blue: CGFloat(foreground & 0xFF) / 255,
        alpha: coverage
    )
    return ProcessIcons.image(forKey: attachment.key, side: attachment.iconSide, ink: ink, ground: .black).flatMap(opaquestPixel(of:))
}

/// Whether the icon leading a tab's title draws as a foreground tints it.
///
/// - Parameters:
///   - window: The tab's window.
///   - foreground: The foreground, packed 0xRRGGBB.
/// - Returns: False where the title has no icon.
@MainActor
func isTemplateIconTinted(_ window: NSWindow, with foreground: UInt32) -> Bool {
    guard let expected = templateIconInk(of: window, wearing: foreground) else { return false }
    return isNearPacked(templateIconInk(of: window), expected)
}

/// An image's most opaque pixel, drawn into an sRGB bitmap and read without
/// its alpha.
///
/// - Parameter image: The image.
/// - Returns: The colour packed 0xRRGGBB, or nil for an image with no ink.
@MainActor
private func opaquestPixel(of image: NSImage) -> UInt32? {
    let width = Int(image.size.width.rounded(.up))
    let height = Int(image.size.height.rounded(.up))
    guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        return nil
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = context.data else { return nil }
    let pixels = data.assumingMemoryBound(to: UInt8.self)
    var opaquest = (alpha: 0, offset: 0)
    for pixel in 0..<(width * height) where Int(pixels[pixel * 4 + 3]) > opaquest.alpha {
        opaquest = (Int(pixels[pixel * 4 + 3]), pixel * 4)
    }
    guard opaquest.alpha > 0 else { return nil }
    let channel = { (index: Int) -> UInt32 in
        UInt32(Swift.min(255, (Int(pixels[opaquest.offset + index]) * 255 + opaquest.alpha / 2) / opaquest.alpha))
    }
    return (channel(0) << 16) | (channel(1) << 8) | channel(2)
}

/// Whether two packed colours agree within the rounding an alpha-weighted
/// draw leaves in each channel.
///
/// - Parameters:
///   - drawn: The colour read back; nil never agrees.
///   - expected: The colour it should be.
/// - Returns: Whether every channel is within three steps.
func isNearPacked(_ drawn: UInt32?, _ expected: UInt32) -> Bool {
    guard let drawn else { return false }
    return [16, 8, 0]
        .allSatisfy { shift in
            abs(Int((drawn >> UInt32(shift)) & 0xFF) - Int((expected >> UInt32(shift)) & 0xFF)) <= 3
        }
}

/// A catalog theme's index by its name.
///
/// - Parameter name: The theme's name.
/// - Returns: The index, or nil where the catalog holds no such theme.
func catalogThemeIndex(named name: String) -> Int? {
    let index = name.withCString { Ubiquitty.Themes.indexForName($0) }
    return index >= 0 ? Int(index) : nil
}
