// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ScriptingBridge.swift — the Cocoa Scripting bridge: what `tell application
// "Ubiquitty"` reaches.
//
// The dictionary (Ubiquitty.sdef, bundled and named by Info.plist's
// OSAScriptingDefinition) binds its terminology to the classes here by their
// Objective-C names:
//
//   * `window` — ScriptableWindow, one terminal window: its terminal
//     properties and its `tab` elements.
//   * `tab` — ScriptableTab, one tab of a window. A tab is a window in a
//     native tab group, so every tab is also listed as a window.
//   * `do script` — DoScriptCommand, which types a command line into a
//     session.
//
// The application's `window` element is `NSApplication.scriptableWindows`, so
// `windows`, `window 1` and `front window` resolve to these rather than to raw
// NSWindows. Both shells' windows are listed, in one front-to-back order,
// behind one set of classes: a script asks for the terminal it can see, and
// which shell drew it is not the script's business.
//
// The wrappers hold a window number rather than a controller. It is the unique
// id the dictionary publishes, it is what an object specifier resolves by, and
// it stays true while the window restacks; the controller is looked up from it
// on each read.

import AppKit
import UbiquittyKit

/// A terminal window as a script reaches it, whichever shell drew it.
@MainActor
protocol ScriptableTerminal: NSWindowController {
    /// The focused pane's visible screen, one UTF-8 row per line with
    /// trailing blanks trimmed, read under the model lock.
    func scriptingScreenText() -> String

    /// Writes literal text to the focused pane's session, the one the script
    /// addressed; a remote pane's session forwards it to its host, and
    /// Broadcast Input does not widen it to sessions the dictionary gives the
    /// caller no way to name.
    ///
    /// - Parameter text: The characters to send.
    func scriptingSend(_ text: String)

    /// Names the window, or clears the name when `title` is empty.
    ///
    /// - Parameter title: The name.
    func scriptingRename(_ title: String)

    /// The name put on the window, or nil when it has none.
    var scriptingWindowName: String? { get }

    /// The name put on the window's tab, or nil when it has none.
    var scriptingTabName: String? { get }
}

extension TerminalWindowController: ScriptableTerminal {
    func scriptingScreenText() -> String {
        scriptScreenText()
    }

    func scriptingSend(_ text: String) {
        sendScriptText(text)
    }

    func scriptingRename(_ title: String) {
        setCustomTitles(window: title)
    }

    var scriptingWindowName: String? {
        customWindowTitle.isEmpty ? nil : customWindowTitle
    }

    var scriptingTabName: String? {
        customTabTitle.isEmpty ? nil : customTabTitle
    }
}

/// The open terminal windows a script can reach.
@MainActor
enum ScriptableTerminals {
    /// Every open terminal window's controller, front to back, each once.
    ///
    /// Front to back is what the dictionary publishes — `index`, `window 1`
    /// and `front window` all resolve through this list. It is the
    /// application's one list of terminal windows (``TerminalWindows/all()``),
    /// ordered by the on-screen stack: a miniaturized or ordered-out terminal
    /// keeps its place in it and still answers to the id a script is holding.
    /// A script naming the window the reader is typing in asks for the key
    /// window, which is what the menus act on and what `do script` with no
    /// target prefers; a window kept on top stands ahead of it here.
    static func all() -> [any ScriptableTerminal] {
        TerminalWindows.all().compactMap { $0 as? any ScriptableTerminal }
    }

    /// The terminal whose window carries a number, or nil when none is open.
    ///
    /// - Parameter windowNumber: The window's number.
    /// - Returns: Its controller.
    static func numbered(_ windowNumber: Int) -> (any ScriptableTerminal)? {
        all().first { $0.window?.windowNumber == windowNumber }
    }

    /// The window numbers of a terminal's tabs, in tab order: the window
    /// itself and its group's other terminal windows. A lone window is its
    /// own one tab.
    ///
    /// - Parameter windowNumber: Any window of the group.
    /// - Returns: The tabs' window numbers.
    static func tabNumbers(ofWindowNumbered windowNumber: Int) -> [Int] {
        guard let window = numbered(windowNumber)?.window else { return [] }
        return (window.tabGroup?.windows ?? [window])
            .filter { $0.windowController is any ScriptableTerminal }
            .map(\.windowNumber)
    }
}

/// One scriptable terminal window.
@MainActor
@objc(UBScriptableWindow)
final class ScriptableWindow: NSObject {
    /// The window's number: its scripting id and how it is found again.
    nonisolated let windowNumber: Int

    /// Wraps the window carrying a number.
    ///
    /// - Parameter windowNumber: The window's number.
    nonisolated init(windowNumber: Int) {
        self.windowNumber = windowNumber
        super.init()
    }

    private var terminal: (any ScriptableTerminal)? {
        ScriptableTerminals.numbered(windowNumber)
    }

    @objc
    var scriptName: String {
        terminal?.window?.title ?? ""
    }

    @objc
    var scriptID: Int {
        windowNumber
    }

    /// The 1-based front-to-back index among terminal windows, the
    /// AppleScript convention; 0 once the window is gone.
    @objc
    var scriptIndex: Int {
        let all = ScriptableTerminals.all()
        guard let index = all.firstIndex(where: { $0.window?.windowNumber == windowNumber }) else { return 0 }
        return index + 1
    }

    @objc
    var isScriptFrontmost: Bool {
        terminal?.window?.isKeyWindow ?? false
    }

    @objc
    var scriptContents: String {
        terminal?.scriptingScreenText() ?? ""
    }

    @objc
    var scriptTitle: String {
        get {
            guard let terminal else { return "" }
            return terminal.scriptingWindowName ?? terminal.window?.title ?? ""
        }
        set {
            terminal?.scriptingRename(newValue)
        }
    }

    @objc
    var scriptTabs: [ScriptableTab] {
        ScriptableTerminals.tabNumbers(ofWindowNumbered: windowNumber)
            .map {
                ScriptableTab(windowNumber: $0, containerWindowNumber: windowNumber)
            }
    }

    @objc
    func countOfScriptTabs() -> Int {
        ScriptableTerminals.tabNumbers(ofWindowNumbered: windowNumber).count
    }

    @objc(objectInScriptTabsAtIndex:)
    func objectInScriptTabs(at index: Int) -> ScriptableTab? {
        let tabs = ScriptableTerminals.tabNumbers(ofWindowNumbered: windowNumber)
        guard tabs.indices.contains(index) else { return nil }
        return ScriptableTab(windowNumber: tabs[index], containerWindowNumber: windowNumber)
    }

    /// Locates this window among the application's `windows` by its id.
    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let application = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(
            containerClassDescription: application,
            containerSpecifier: nil,
            key: "scriptableWindows",
            uniqueID: windowNumber
        )
    }

    nonisolated override func isEqual(_ object: Any?) -> Bool {
        (object as? ScriptableWindow)?.windowNumber == windowNumber
    }

    nonisolated override var hash: Int {
        windowNumber
    }
}

/// One scriptable tab of a terminal window.
@MainActor
@objc(UBScriptableTab)
final class ScriptableTab: NSObject {
    /// The tab's own window number, its scripting id.
    nonisolated let windowNumber: Int

    /// The number of the window the tab was reached through, which its
    /// object specifier names as its container.
    nonisolated let containerWindowNumber: Int

    /// Wraps a tab reached through a window.
    ///
    /// - Parameters:
    ///   - windowNumber: The tab's own window number.
    ///   - containerWindowNumber: The window it was reached through.
    nonisolated init(windowNumber: Int, containerWindowNumber: Int) {
        self.windowNumber = windowNumber
        self.containerWindowNumber = containerWindowNumber
        super.init()
    }

    private var terminal: (any ScriptableTerminal)? {
        ScriptableTerminals.numbered(windowNumber)
    }

    @objc
    var scriptID: Int {
        windowNumber
    }

    /// The 1-based index among the container window's tabs; 0 once the tab
    /// has left it.
    @objc
    var scriptIndex: Int {
        let tabs = ScriptableTerminals.tabNumbers(ofWindowNumbered: containerWindowNumber)
        guard let index = tabs.firstIndex(of: windowNumber) else { return 0 }
        return index + 1
    }

    @objc
    var isScriptSelected: Bool {
        guard let window = terminal?.window else { return false }
        return (window.tabGroup?.selectedWindow ?? window) === window
    }

    @objc
    var scriptContents: String {
        terminal?.scriptingScreenText() ?? ""
    }

    @objc
    var scriptTitle: String {
        get {
            guard let terminal else { return "" }
            return terminal.scriptingTabName ?? terminal.window?.title ?? ""
        }
        set {
            terminal?.scriptingRename(newValue)
        }
    }

    /// Locates this tab among its container window's `tabs` by its id.
    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let window = ScriptableWindow(windowNumber: containerWindowNumber).objectSpecifier,
            let windowDescription = window.keyClassDescription
        else {
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: windowDescription,
            containerSpecifier: window,
            key: "scriptTabs",
            uniqueID: windowNumber
        )
    }

    nonisolated override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ScriptableTab else { return false }
        return other.windowNumber == windowNumber && other.containerWindowNumber == containerWindowNumber
    }

    nonisolated override var hash: Int {
        windowNumber
    }
}

/// `do script "<text>" [in <window|tab>]`: types a command line into a
/// session and answers the tab it ran in.
///
/// `do script` stays outside the injection gate (Core/Security/InjectionGate.h).
/// An Apple Event carries the calling app's identity, and macOS asks the user —
/// per calling app, revocably, in System Settings › Automation — before that
/// app may control this one. That is a consent prompt keyed to the principal,
/// which the control socket cannot have, and it is why the socket is screened
/// in-process and this door is not.
@objc(UBDoScriptCommand)
final class DoScriptCommand: NSScriptCommand {
    /// Where the command line went, or that no terminal was open to take it.
    private enum Outcome: Sendable {
        case ran(tab: Int, window: Int)
        case noTerminal
    }

    override func performDefaultImplementation() -> Any? {
        let script = directParameter as? String
        let target = evaluatedArguments?["targetSession"]
        let targetTab = target as? ScriptableTab
        let targetWindowNumber = (target as? ScriptableWindow)?.windowNumber ?? targetTab?.windowNumber
        let outcome = MainActor.assumeIsolated { Self.run(script, inWindowNumbered: targetWindowNumber) }
        switch outcome {
        case .noTerminal:
            scriptErrorNumber = errAENoSuchObject
            scriptErrorString = "There’s no terminal window to run the command in."
            return nil
        case .ran(let tab, let window):
            return (targetTab ?? ScriptableTab(windowNumber: tab, containerWindowNumber: window)).objectSpecifier
        }
    }

    /// Types the command line into the target, or into the front terminal
    /// window when the script named none.
    ///
    /// A command line is the text and a return, which is the `do script`
    /// convention; the shell interprets it. An empty command runs nothing and
    /// still answers the tab, as the verb does in Terminal.
    ///
    /// - Parameters:
    ///   - script: The command text, or nil when the script gave none.
    ///   - windowNumber: The named window or tab, or nil for the front one.
    /// - Returns: Where the command ran.
    @MainActor
    private static func run(_ script: String?, inWindowNumbered windowNumber: Int?) -> Outcome {
        let terminal: (any ScriptableTerminal)?
        if let windowNumber {
            terminal = ScriptableTerminals.numbered(windowNumber)
        } else {
            terminal =
                NSApp.keyWindow?.windowController as? any ScriptableTerminal
                ?? ScriptableTerminals.all().first
        }
        guard let terminal, let window = terminal.window else { return .noTerminal }
        if let script, !script.isEmpty {
            terminal.scriptingSend(script + "\r")
        }
        return .ran(tab: window.windowNumber, window: window.windowNumber)
    }
}

extension NSApplication {
    /// The application's `window` element: every open terminal window, front
    /// to back.
    @objc
    var scriptableWindows: [ScriptableWindow] {
        ScriptableTerminals.all().compactMap { $0.window.map { ScriptableWindow(windowNumber: $0.windowNumber) } }
    }
}
