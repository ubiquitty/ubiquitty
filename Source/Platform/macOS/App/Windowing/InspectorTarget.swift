// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// Identifies the owning session and its selected pane without combining their identifiers.
package struct InspectorIdentity: Equatable {
    let owner: UInt
    let pane: Int
    package init(owner: UInt, pane: Int = 0) {
        self.owner = owner
        self.pane = pane
    }
}

/// Supplies session facts and actions to the shared native inspector.
@MainActor
package protocol InspectorTarget: AnyObject {
    var identity: InspectorIdentity { get }
    var windowTitle: String { get }
    var tabTitle: String { get }
    var fontFamily: String { get }
    var fontSize: Double { get }
    var canResetBackground: Bool { get }
    var canClearDirectory: Bool { get }
    func setObservation(_ observer: ObjectIdentifier, isActive: Bool)
    func information() -> Ubiquitty.Session.SessionInfo
    func setAnswerback(_ value: String) -> Bool
    func themeIndex() -> Int
    func clearDirectory() -> Bool
    func applyTitles(window: String, tab: String)
    func resize(columns: Int, rows: Int)
    func applyBackground(red: UInt8, green: UInt8, blue: UInt8) -> Bool
    func resetBackground() -> Bool
    func applyFont(family: String, size: Double) -> Bool
    func applyTheme(_ index: Int) -> Bool
    func sendSignal(process: UInt32, signal: Int32) -> Bool
}

extension InspectorTarget {
    package func setObservation(_ observer: ObjectIdentifier, isActive: Bool) {}
    package func setAnswerback(_ value: String) -> Bool { false }
}

/// Adapts the native workspace's selected pane to inspector actions.
@MainActor
final class SurfaceInspectorTarget: InspectorTarget {
    weak var controller: TerminalWindowController?
    weak var surface: TerminalSurface?

    init(controller: TerminalWindowController?, surface: TerminalSurface) {
        self.controller = controller
        self.surface = surface
    }

    var identity: InspectorIdentity { InspectorIdentity(owner: surface?.drive.sessionIdentity ?? 0) }
    var windowTitle: String { controller?.customWindowTitle ?? "" }
    var tabTitle: String { controller?.customTabTitle ?? "" }
    var fontFamily: String { (surface?.renderer as? SurfaceRenderer)?.familyName ?? "" }
    var fontSize: Double { (surface?.renderer as? SurfaceRenderer)?.pointSize ?? 12 }
    var canResetBackground: Bool { surface?.drive.canResetBackground ?? false }
    var canClearDirectory: Bool { surface?.drive.canClearReportedDirectory ?? false }

    func setObservation(_ observer: ObjectIdentifier, isActive: Bool) {
        surface?.setProcessInspector(observer, isActive: isActive)
    }

    func information() -> Ubiquitty.Session.SessionInfo {
        surface?.drive.inspectorInfo() ?? Ubiquitty.Session.SessionInfo()
    }

    func setAnswerback(_ value: String) -> Bool { surface?.drive.setInspectorAnswerback(value) ?? false }

    func themeIndex() -> Int {
        guard let surface else { return -1 }
        return Int(surface.drive.currentThemeIndex())
    }

    func clearDirectory() -> Bool { surface?.drive.clearReportedDirectory() ?? false }

    func applyTitles(window: String, tab: String) {
        controller?.setCustomTitles(window: window, tab: tab)
    }

    func resize(columns: Int, rows: Int) {
        controller?.resizeWindow(toColumns: columns, rows: rows)
    }

    func applyBackground(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        guard let surface else { return false }
        let accepted = surface.drive.setInspectorBackground(red: red, green: green, blue: blue)
        refreshAppearance()
        return accepted
    }

    func resetBackground() -> Bool {
        guard let surface, surface.drive.resetBackground() else { return false }
        refreshAppearance()
        return true
    }

    func applyFont(family: String, size: Double) -> Bool {
        guard let surface else { return false }
        return controller?.applyInspectedFont(on: surface, family: family, size: size) == true
    }

    func applyTheme(_ index: Int) -> Bool {
        guard let surface else { return false }
        return controller?.applyInspectedTheme(index, to: surface) == true
    }

    func sendSignal(process: UInt32, signal: Int32) -> Bool {
        surface?.drive.signalInspectedProcess(process, signal: signal) ?? false
    }

    private func refreshAppearance() {
        surface?.invalidateRetainedBaseline()
        surface?.republishAfterPreferenceWrite()
        controller?.refreshSessionAppearance()
    }
}
