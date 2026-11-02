// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// WelcomeActions.swift — the Welcome screen's buttons, dispatched in-process.
//
// A button is an `OSC 8` link whose target is `ubiquitty:action/<name>`. Which
// names are buttons is Core's (`App::Welcome::actionForURI`), from the table the
// screen's own bytes are built from, and every target under the prefix is
// consumed here whatever its name, so none reaches a link handler or the system
// opener. `LinkOpener` asks this first, and both shells open links through
// `LinkOpener`, so a button works the same in either.
//
// Anything that can print can print one of these targets under any label, so a
// click is not consent to what a label claims. Three actions only open a
// window, which is what the menu item beside each already does; the worst a
// forged link achieves with one is a window nobody asked for. The fourth writes
// the reader's shell startup files, and it asks first: the question is a native
// alert terminal output can neither draw nor answer, it names the files it
// would write, and Return refuses.
//

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// The Welcome screen's buttons, as a click on one reaches them.
@MainActor
package enum WelcomeActions {
    /// Dispatches a Welcome screen action, when `uri` names one.
    ///
    /// - Parameters:
    ///   - uri: The link target the terminal resolved.
    ///   - window: The window the link was clicked in, which a question the
    ///     action asks is attached to.
    /// - Returns: Whether `uri` was in the action namespace — handled or not —
    ///   so the caller opens it no other way.
    @discardableResult
    package static func dispatch(_ uri: String, from window: NSWindow?) -> Bool {
        let isAction = uri.withCString { Ubiquitty.App.Welcome.isActionURI(std.string_view($0)) }
        guard isAction else {
            return false
        }
        let action = uri.withCString { Ubiquitty.App.Welcome.actionForURI(std.string_view($0)) }
        switch action {
        case .shellIntegration:
            ShellIntegrationInstaller.askToInstall(homeDirectory: installHomeDirectory, from: window)
        case .connect:
            // Sent rather than called: the Connect and Settings windows belong
            // to the app, which is above this module. Sent to the app's
            // delegate by name rather than down the responder chain, so the
            // button answers the same whichever window, if any, is key.
            NSApp.sendAction(NSSelectorFromString("showConnectWindow:"), to: NSApp.delegate, from: nil)
        case .settings:
            showSettings(category: "appearance")
        case .accessibility:
            showSettings(category: "accessibility")
        case .unrecognized:
            break
        }
        return true
    }

    /// Opens Settings on one of its categories.
    ///
    /// - Parameter category: The category's stable identifier.
    private static func showSettings(category: String) {
        NSApp.sendAction(
            NSSelectorFromString("showSettingsWindowForCategory:"),
            to: NSApp.delegate,
            from: category as NSString
        )
    }

    /// The home directory whose startup files an install writes.
    private static var installHomeDirectory: String {
        #if UBIQUITTY_UI_TESTS
        if let homeDirectory = homeDirectoryForTesting {
            return homeDirectory
        }
        #endif
        return NSHomeDirectory()
    }

    #if UBIQUITTY_UI_TESTS
    /// A directory an install writes into in place of the reader's home.
    ///
    /// A scenario that answers Install sets it, so the startup files and the
    /// terminfo database it writes are its own and never the reader's. Every
    /// other part of the path — the click, the question, the answer — is the
    /// one a reader takes.
    package static var homeDirectoryForTesting: String?
    #endif
}

extension TerminalWindowController {
    /// Opens a window that shows the Welcome screen, then the reader's login
    /// shell.
    ///
    /// The shell is launched as any window's is; its first output is held,
    /// unread, until the screen is written into the pane through the parser
    /// path the shell's bytes take, so the screen precedes the first prompt.
    /// The screen is made once the pane has published its geometry: which
    /// render of the icon it draws, and where in its box, is Core's decision
    /// from the pane's drawn cell, which exists only once the window does.
    ///
    /// - Returns: The window's controller, or nil when it cannot be opened.
    @objc(spawnWelcomeScreen)
    @discardableResult
    public static func spawnWelcomeScreen() -> TerminalWindowController? {
        guard let controller = spawn(inheritingDirectory: "", openingScreen: .held) else {
            return nil
        }
        WelcomeScreenDelivery.deliver(to: controller, attemptsLeft: WelcomeScreenDelivery.geometryAttempts)
        return controller
    }
}

/// Writes the Welcome screen into a window's pane once the pane can say what
/// it draws.
@MainActor
package enum WelcomeScreenDelivery {
    /// How many times, 50 ms apart, the geometry is looked for before the
    /// screen is written from the configured face's nominal cell. The shell's
    /// output waits that long at most.
    package static let geometryAttempts = 40

    /// The pane a surface is, from its own terminal and its window's scale.
    ///
    /// - Parameter surface: The window's surface.
    /// - Returns: The pane, or nil before the surface has a terminal.
    package static func pane(of surface: TerminalSurface) -> Ubiquitty.App.Welcome.Pane? {
        let scale = Double(surface.window?.backingScaleFactor ?? 1)
        let configuration = Ubiquitty.Preferences.values()
        return surface.drive.withTerminal { Ubiquitty.App.Welcome.paneOf($0, configuration.pointee, scale, .drawn) }
    }

    /// Writes the screen for the window's pane and releases the shell's
    /// output behind it, or tries again shortly when the pane has not
    /// published its geometry yet. Out of attempts, it writes the screen from
    /// the nominal cell the pane carries until then, so the icon appears
    /// either way and the shell's output is never held for longer than the
    /// attempts take.
    ///
    /// - Parameters:
    ///   - controller: The window the screen is for.
    ///   - attemptsLeft: How many more times to wait for the geometry.
    ///   - paneFacts: Where the pane is read from; a scenario stands in a
    ///     pane that never publishes.
    package static func deliver(
        to controller: TerminalWindowController,
        attemptsLeft: Int,
        paneFacts: @escaping @MainActor (TerminalSurface) -> Ubiquitty.App.Welcome.Pane? = pane(of:)
    ) {
        guard let surface = controller.projectedSurfaces.first else {
            return
        }
        let pane = paneFacts(surface)
        if !(pane?.isGeometryPublished ?? false), attemptsLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak controller] in
                guard let controller else { return }
                deliver(to: controller, attemptsLeft: attemptsLeft - 1, paneFacts: paneFacts)
            }
            return
        }
        var drawn = pane ?? Ubiquitty.App.Welcome.Pane()
        drawn.imageDrawing = .drawn
        surface.drive.finishOpeningScreen(String(Ubiquitty.App.Welcome.screenContent(drawn)).utf8.map { CChar(bitPattern: $0) })
    }
}
