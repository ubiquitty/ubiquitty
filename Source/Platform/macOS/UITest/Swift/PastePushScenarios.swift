// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit

// PastePushScenarios.swift — the paste-push panel, driven as the user sees it.
// Swift UI-test scenarios live here, in the UI-test tree: new scenarios are
// written in Swift, and test code stays out of the product's Swift folder.
// Compiled only into the UI-test build (UBIQUITTY_UI_TESTS), where the app is
// really running and AppKit really lays the panel out.
//
// The wire and the landing are proven headless by remote_session_smoke; what
// only a running app can answer is whether the panel appears, says where the
// paste is going, and goes away again.

/// Registers the paste-push scenarios with the UI-test runner.
///
/// Called from the runner's registration sweep; a scenario is a C function
/// pointer, so each closure below carries no context.
@objc(UBPastePushScenarios)
public final class PastePushScenarios: NSObject {
    /// Registers every scenario in this file, and the other Swift files'
    /// scenarios: this class is the runner's one Swift entry, so each Swift
    /// scenario file joins the registry from here.
    @objc
    public static func register() {
        FontZoomScenarios.register()
        LocaleEnvironmentScenarios.register()
        BoxGlyphRouteScenarios.register()
        SymbolFallbackScenarios.register()
        FontRoutingScenarios.register()
        ProxyIconRevealScenarios.register()
        TitleDimensionsScenarios.register()
        PaneChromeScenarios.register()
        TagEditorScenarios.register()
        TagDotScenarios.register()
        SurfaceDrawableScenarios.register()
        ImageFrameScenarios.register()
        ImageFrameScenarios.registerRealChafa()
        PixelReportScenarios.register()
        RenderedFrameScenarios.register()
        TitleCompositionScenarios.register()
        TabTitleFittingScenarios.register()
        LocatorScenarios.register()
        ProportionalRunScenarios.register()
        FullscreenContentScenarios.register()
        ColumnModeScenarios.register()
        WindowOperationStormScenarios.register()
        ResizeParityScenarios.register()
        WindowFollowsFontScenarios.register()
        RenderPreferencesScenarios.register()
        FullscreenBracketScenarios.register()
        PaletteOpacityScenarios.register()
        TranslucencyScenarios.register()
        ChromeThemeScenarios.register()
        ChromeBadgeScenarios.register()
        WindowGroundScenarios.register()
        ProgressChromeScenarios.register()
        BellScenarios.register()
        TriggerScenarios.register()
        DropDownScenarios.register()
        SessionClipboardScenarios.register()
        TriggerScenarios.registerScriptingHook()
        BroadcastInputScenarios.register()
        WindowShapeScenarios.register()
        SettingsWindowScenarios.register()
        BackgroundImageSettingsScenarios.register()
        UpdaterScenarios.register()
        KeyRoutingScenarios.register()
        LayoutChordScenarios.register()
        ClearCommandScenarios.register()
        ScrollerChromeScenarios.register()
        PointerBehaviourScenarios.register()
        SelectionOutputFollowScenarios.register()
        RichTextScenarios.register()
        LinkScenarios.register()
        RemoteFileScenarios.register()
        WindowPlacementScenarios.register()
        FramePacingScenarios.register()
        PerfDiagnosticsScenarios.register()
        KeyBindingScenarios.register()
        BeamSummonScenarios.register()
        EditMenuScenarios.register()
        FindBarScenarios.register()
        HostDirectoryScenarios.register()
        RemoteWorkspaceScenarios.register()
        HostedTabScenarios.register()
        RemoteClearScenarios.register()
        RemoteGroundScenarios.register()
        RemoteViewScenarios.register()
        RemoteLifecycleScenarios.register()
        HostChipScenarios.register()
        CustomTitleScenarios.register()
        HostLabelScenarios.register()
        SessionExitScenarios.register()
        ShareSessionScenarios.register()
        CursorPresentationScenarios.register()
        TabStripChromeScenarios.register()
        FocusScenarios.register()
        ConsentPromptScenarios.register()
        WelcomeActionScenarios.register()
        MacroStoreScenarios.register()
        TmuxHostingScenarios.register()
        TerminalBehaviourScenarios.register()
        TextInputScenarios.register()
        ProfileLaunchScenarios.register()
        MenuRoutingScenarios.register()
        WindowOpScenarios.register()
        DisplayPowerScenarios.register()
        ScriptingScenarios.register()
        ControlSocketScenarios.register()
        SessionLogScenarios.register()
        SessionLayoutScenarios.register()
        RemoteResumeScenarios.register()
        SessionLayoutStoreScenarios.register()
        TabSurvivorScenarios.register()
        TabAccessoryTransitionScenarios.register()
        TabAccessorySelectionScenarios.register()
        TabStatusHintOffScenarios.register()
        OcclusionScenarios.register()
        QuietChromeScenarios.register()
        UBUITestRegister("paste_push_panel_reports_the_destination") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                defer { PastePushPanel.shared.dismissNow() }
                PastePushPanel.shared.dismissNow() // a previous scenario's panel is not this one's

                PastePushPanel.shared.showPasting(toDestination: "build-box", mime: "image/png", over: nil, progress: { 0.5 })
                t.pump(0.2)
                guard let panel = visiblePastePanel() else {
                    t.expect(false, desc: "the paste panel is on screen while the payload crosses")
                    return
                }
                t.expect(
                    panelText(panel).contains("Pasting to “build-box”"),
                    desc: "the panel names the machine the paste is going to"
                )
                t.expect(
                    panelText(panel).contains("Sending…"),
                    desc: "and says the payload is on its way"
                )

                // The host answers: the panel names the landed file, then goes.
                PastePushPanel.shared.finishLanded(atPath: "/tmp/ubiquitty-paste-ab12.png")
                t.pump(0.2)
                t.expect(
                    panelText(panel).contains("Pasted as ubiquitty-paste-ab12.png"),
                    desc: "the panel names the file the paste became"
                )
                t.expect(panel.isVisible, desc: "and stays up long enough to read")

                PastePushPanel.shared.dismissNow()
                t.pump(0.2)
                t.expect(!panel.isVisible, desc: "the panel goes when the paste is done")
            }
        }

        // A visual check: the panel on screen, active and key, the way a
        // user sees it mid-paste. Not an assertion — the eye is the oracle
        // here, and the two scenarios beside it are what a machine checks.
        UBUITestRegister("paste_push_panel_dwell") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let originalPolicy = NSApp.activationPolicy()
                let originalApplication = NSWorkspace.shared.frontmostApplication
                defer {
                    PastePushPanel.shared.dismissNow()
                    NSApp.setActivationPolicy(originalPolicy)
                    if !WindowContainment.isOffscreen, originalApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        originalApplication?.activate(options: [])
                    }
                }
                if !WindowContainment.isOffscreen {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                PastePushPanel.shared.showForVisualCheck(
                    title: "Pasting to “build-box”",
                    status: "2.1 MB of 6.4 MB",
                    mime: "image/png",
                    fraction: 2.1 / 6.4
                )
                // Key, so the panel shows the active appearance: coloured
                // buttons and an accent-tinted bar. The product never makes
                // it key on its own — a paste must not take focus off what
                // the user is typing into.
                if !WindowContainment.isOffscreen {
                    PastePushPanel.shared.makeKeyForVisualCheck()
                }
                t.pump(0.5) // let AppKit lay the panel out before it is looked at
                print("PASTE_PANEL_WINDOW \(PastePushPanel.shared.windowNumberForVisualCheck())")
                print("PASTE_PANEL_FOCUS \(PastePushPanel.shared.focusReportForVisualCheck())")
                if WindowContainment.isOffscreen {
                    guard let panel = visiblePastePanel() else {
                        t.expect(false, desc: "the offscreen paste panel is ordered and available for layout")
                        return
                    }
                    t.expect(
                        !NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }),
                        desc: "the paste panel stays entirely outside every attached display"
                    )
                    t.expect(NSApp.activationPolicy() == originalPolicy, desc: "the offscreen dwell preserves activation policy")
                    print("PASTE_PANEL_VISUAL_CHECK unavailable: offscreen mode does not prove active appearance")
                }
                fflush(stdout)
                t.pump(1.0) // the dwell: long enough for an eye or a capture
                PastePushPanel.shared.dismissNow()
            }
        }

        UBUITestRegister("paste_push_panel_reports_a_refusal") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                defer { PastePushPanel.shared.dismissNow() }
                PastePushPanel.shared.dismissNow()

                // A destination the command named nothing for reads as "the
                // host" rather than an empty quotation.
                PastePushPanel.shared.showPasting(toDestination: "", mime: "image/png", over: nil, progress: nil)
                t.pump(0.2)
                guard let panel = visiblePastePanel() else {
                    t.expect(false, desc: "the paste panel is on screen for an unnamed host")
                    return
                }
                t.expect(
                    panelText(panel).contains("Pasting to the host"),
                    desc: "an unnamed destination reads as the host"
                )

                // A refusal is the only place its reason is said, so it must
                // reach the panel rather than the log.
                PastePush.finish(status: 2 /* IOError */, path: "")
                t.pump(0.2)
                t.expect(
                    panelText(panel).contains("The host couldn’t save the pasted image. Try again."),
                    desc: "the panel says why the paste did not land"
                )

                PastePushPanel.shared.dismissNow()
                t.pump(0.2)
            }
        }
    }
}

/// The panel's window, if it is on screen.
///
/// Found by looking at what is on screen rather than through a handle the
/// panel hands out: the test asserts what a user can see, so it looks where a
/// user would. File scope because a scenario is a C function pointer, which
/// cannot capture the context a type's static member carries.
@MainActor
private func visiblePastePanel() -> NSWindow? {
    NSApp.windows.first { $0 is NSPanel && $0.isVisible && !panelText($0).isEmpty }
}

/// Every label's text in one window, joined.
///
/// - Parameter window: The window to read.
/// - Returns: The labels' strings, newline-separated.
@MainActor
private func panelText(_ window: NSWindow) -> String {
    guard let content = window.contentView else { return "" }
    return content.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
}
