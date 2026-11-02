// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import UbiquittyCore
import UbiquittyKit

import struct UbiquittyRenderKit.HostOutlineIdentity

// The workspace's tabs as the tab overview and the tab strip draw them, and the
// requests a person makes of them. Every request is the host's to perform: the
// host owns the layout, so a rename, a reorder or a close is asked of it and
// shows once the host's structure says so. What a tab and a pane are called is
// Core's composition over the facts the host sends for each pane, the rule the
// macOS tab strip names its tabs by.

/// One pane of a tab, where the tab's split tree puts it.
struct TerminalTabPane: Identifiable, Equatable {
    let id: UInt32
    /// Where the pane sits in its tab, as fractions of the tab's area.
    let frame: CGRect
}

/// One tab of the host's workspace.
struct TerminalTab: Identifiable, Equatable {
    /// The host's identity for the tab.
    let id: UInt32
    /// The host's identity for the window holding it.
    let windowID: UInt32
    /// The window's position among the workspace's windows.
    let windowIndex: Int
    /// The tab's position in its window.
    let tabIndex: Int
    /// The name a person gave the tab; empty when it is named automatically.
    let customTitle: String
    /// The pane the tab focuses.
    let focusedPaneID: UInt32
    /// The pane filling the tab, or zero when none is zoomed.
    let zoomedPaneID: UInt32
    /// The tab's panes, in the split tree's order.
    let panes: [TerminalTabPane]
    /// What the tab is called, as Core composes it; set from the panes' facts.
    var title = ""
    /// What each pane is called, as Core composes it.
    var paneTitles: [UInt32: String] = [:]
    /// What runs in each pane other than its shell, by the host's report.
    var runningPrograms: [UInt32: String] = [:]

    /// Lays a split tree out as fractions of the tab's area.
    ///
    /// - Parameter tree: The tab's split tree.
    /// - Returns: Each pane and its frame, in the tree's order.
    static func layout(of tree: Ubiquitty.Panes.Tree) -> [TerminalTabPane] {
        var result: [TerminalTabPane] = []
        var pending: [(Int32, CGRect)] = [(tree.root(), CGRect(x: 0, y: 0, width: 1, height: 1))]
        while let (index, frame) = pending.popLast() {
            guard index >= 0, index < Ubiquitty.Panes.maxNodes else { continue }
            let node = tree.node(index)
            if tree.isLeaf(index) {
                result.append(TerminalTabPane(id: UInt32(truncatingIfNeeded: node.paneID), frame: frame))
                continue
            }
            let ratio = CGFloat(min(max(node.ratio, 0), 1))
            let first: CGRect
            let second: CGRect
            if node.orientation == .Vertical {
                first = CGRect(x: frame.minX, y: frame.minY, width: frame.width * ratio, height: frame.height)
                second = CGRect(x: first.maxX, y: frame.minY, width: frame.width - first.width, height: frame.height)
            } else {
                first = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height * ratio)
                second = CGRect(x: frame.minX, y: first.maxY, width: frame.width, height: frame.height - first.height)
            }
            pending.append((node.second, second))
            pending.append((node.first, first))
        }
        return result
    }
}

extension TerminalSessionModel {
    /// The focused pane's tab.
    var activeTab: TerminalTab? {
        tabs.first { tab in tab.panes.contains { $0.id == activePaneID } }
    }

    /// Whether requests about tabs can be made now: a host is listening, or
    /// the seeded workspace answers them itself.
    var canChangeTabs: Bool { isSeededWorkspace || canChangePanes }

    // MARK: - Names

    /// Composes every tab's and pane's name again from the panes' facts.
    ///
    /// Cheap enough to run whenever the overview looks: the facts are read off
    /// each pane's mirror, and the rule is Core's.
    func refreshTabTitles() {
        for index in tabs.indices {
            var tab = tabs[index]
            var paneTitles: [UInt32: String] = [:]
            var running: [UInt32: String] = [:]
            for (ordinal, pane) in tab.panes.enumerated() {
                guard let view = surface(forPane: pane.id) else { continue }
                let composed = Self.composedTitle(of: view, surface: .pane, customTabTitle: "")
                paneTitles[pane.id] = composed.isEmpty ? "Pane \(ordinal + 1)" : composed
                let program = view.drive.foregroundProcessName
                if !program.isEmpty, program != view.drive.shellCommandName {
                    running[pane.id] = program
                }
            }
            let named = tab.panes.first { $0.id == tab.focusedPaneID } ?? tab.panes.first
            let tabTitle =
                named.flatMap { surface(forPane: $0.id) }.map { Self.composedTitle(of: $0, surface: .tab, customTabTitle: tab.customTitle) }
                ?? ""
            tab.title = tabTitle.isEmpty ? (tab.customTitle.isEmpty ? "Tab \(index + 1)" : tab.customTitle) : tabTitle
            tab.paneTitles = paneTitles
            tab.runningPrograms = running
            if tab != tabs[index] { tabs[index] = tab }
        }
    }

    /// What Core calls one pane on one surface, from the facts its host sent.
    ///
    /// The host is the one this screen is on, and every tab of the workspace
    /// lives there, so no label repeats it.
    ///
    /// - Parameters:
    ///   - view: The pane's surface.
    ///   - surface: The tab or the pane.
    ///   - customTabTitle: The tab's custom title, for a tab.
    /// - Returns: The composed title; empty when nothing wove.
    private static func composedTitle(of view: TerminalSurface, surface: Ubiquitty.Session.TitleSurface, customTabTitle: String) -> String {
        let composition =
            surface == .tab
            ? Ubiquitty.Preferences.Effective.tabTitleComposition()
            : Ubiquitty.Preferences.Effective.paneTitleComposition()
        let snapshot = view.drive.readSnapshot()
        var facts = Ubiquitty.App.PaneTitleFacts()
        let viewer = Ubiquitty.App.TitleViewerFacts()
        facts.programTitle = std.string(view.drive.currentTitle() ?? "")
        if composition.showsDirectory, let directory = view.drive.titleDirectory() {
            facts.currentDirectory = std.string(directory)
            facts.homeDirectory = std.string(view.drive.remoteHomeDirectory)
        }
        if composition.showsProcessArguments {
            facts.processChainWithArguments = std.string(view.drive.processChainWithArguments)
        } else {
            facts.processChain = std.string(view.drive.processChain)
        }
        facts.shellCommandName = std.string(view.drive.shellCommandName)
        facts.programStatus = snapshot.tabStatusLabel()
        facts.columns = Int32(snapshot.columns)
        facts.rows = Int32(snapshot.rows)
        facts.end = view.drive.sessionEnd
        facts.tabTitle = std.string(customTabTitle)
        let composed = Ubiquitty.App.composeTitle(facts, viewer, composition, surface)
        return composed.usesFallbackName ? "" : String(composed.title)
    }

    /// Core's question before a tab's or a pane's sessions end.
    ///
    /// - Parameters:
    ///   - scope: A tab or a pane.
    ///   - programs: What runs there besides the shell, in pane order.
    /// - Returns: The title and the body; the body is empty when nothing runs.
    static func closeQuestion(_ scope: Ubiquitty.Session.CloseScope, programs: [String]) -> (title: String, body: String) {
        var names = Ubiquitty.Session.CloseProcessNames()
        for program in programs { names.append(std.string(program)) }
        return (String(Ubiquitty.Session.closeConfirmationTitle(scope)), String(Ubiquitty.Session.closeConfirmationBody(scope, names)))
    }

    /// The button that ends the sessions, in Core's word.
    static var closeVerb: String { String(Ubiquitty.Session.closeConfirmationVerb()) }

    // MARK: - Moving between tabs

    /// Focuses a tab's focused pane.
    ///
    /// - Parameter id: The host's tab.
    func selectTab(_ id: UInt32) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let target = tab.panes.first { $0.id == tab.focusedPaneID } ?? tab.panes.first
        if let target { selectPane(target.id) }
    }

    /// Focuses the tab at a position across the workspace's windows, as
    /// Command-1 to Command-9 do; Command-9 is the last tab.
    ///
    /// - Parameter number: The tab's number, from one.
    func selectTab(number: Int) {
        guard !tabs.isEmpty, number >= 1 else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard index < tabs.count else { return }
        selectTab(tabs[index].id)
    }

    /// Focuses the next or previous tab, wrapping at either end.
    ///
    /// - Parameter step: Which neighbour.
    func stepTab(_ step: SwipeStep) {
        guard tabs.count > 1, let current = tabs.firstIndex(where: { $0.id == activeTab?.id }) else { return }
        let offset = step == .next ? 1 : tabs.count - 1
        selectTab(tabs[(current + offset) % tabs.count].id)
    }

    /// Opens the tab overview.
    func showTabOverview() {
        refreshTabTitles()
        isShowingTabOverview = true
    }

    // MARK: - Requests

    /// Gives a tab a name, or takes its name away with an empty one.
    ///
    /// - Parameters:
    ///   - id: The host's tab.
    ///   - title: The name.
    func renameTab(_ id: UInt32, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if isSeededWorkspace {
            replaceSeededTab(tab, customTitle: trimmed)
            return
        }
        guard canChangeTabs, let drive = workspaceAnchor?.drive,
            let tabID = Ubiquitty.Session.Layout.TabID(rawValue: id)
        else {
            tabProblems[id] = Self.waitForConnectionProblem
            return
        }
        tabProblems[id] = nil
        if !drive.remoteWorkspaceRenameTab(tabID, title: trimmed) {
            tabProblems[id] = "The new name couldn’t be sent. Try again when connected."
        }
    }

    /// Ends a tab and the sessions in its panes.
    ///
    /// - Parameter id: The host's tab.
    func closeTab(_ id: UInt32) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if isSeededWorkspace {
            removeSeededPanes(Set(tab.panes.map(\.id)))
            return
        }
        guard canChangeTabs, pendingTabClose == nil,
            let view = tab.panes.lazy.compactMap({ self.surface(forPane: $0.id) }).first,
            let tabID = Ubiquitty.Session.Layout.TabID(rawValue: id)
        else {
            tabProblems[id] = Self.waitForConnectionProblem
            return
        }
        tabProblems[id] = nil
        guard view.drive.remoteWorkspaceCloseTab(tabID) else {
            tabProblems[id] = "The host refused to close this tab."
            return
        }
        pendingTabIDs.insert(id)
        pendingTabClose = (id, view)
    }

    /// Ends one pane's session; its tab's other panes stay.
    ///
    /// - Parameter id: The pane.
    func closeTabPane(_ id: UInt32) {
        if isSeededWorkspace {
            removeSeededPanes([id])
            return
        }
        closePane(id)
    }

    /// Puts a tab at a place among its window's tabs.
    ///
    /// The host's tab-order call, made through the workspace listing; the
    /// order changes when the host's structure says so.
    ///
    /// - Parameters:
    ///   - id: The host's tab.
    ///   - destination: The tab whose place it takes.
    func moveTab(_ id: UInt32, toPlaceOf destination: UInt32) {
        guard id != destination, let moving = tabs.first(where: { $0.id == id }),
            let target = tabs.first(where: { $0.id == destination }), moving.windowID == target.windowID
        else { return }
        let siblings = tabs.filter { $0.windowID == moving.windowID }
        requestTabMove(moving, toIndex: siblings.firstIndex(of: target) ?? target.tabIndex)
    }

    /// Asks the host to put a tab at a place among its window's tabs.
    ///
    /// - Parameters:
    ///   - moving: The tab.
    ///   - index: Its place in the window once moved, from zero.
    private func requestTabMove(_ moving: TerminalTab, toIndex index: Int) {
        let id = moving.id
        if isSeededWorkspace {
            reorderSeededTab(moving, toIndex: index)
            return
        }
        guard canChangeTabs, let drive = workspaceAnchor?.drive else {
            tabProblems[id] = Self.waitForConnectionProblem
            return
        }
        tabProblems[id] = nil
        let request = drive.moveHostTab(
            HostOutlineIdentity(kind: .tab, number: UInt64(id)),
            to: HostOutlineIdentity(kind: .window, number: UInt64(moving.windowID)),
            at: UInt32(index)
        )
        guard request != 0 else {
            tabProblems[id] = "Tabs can be reordered once the host has listed its workspaces. Open Workspaces, then try again."
            return
        }
        pendingTabIDs.insert(id)
        Task { [weak self] in
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                guard let result = drive.lastHostStructureResult, result.requestID == request else { continue }
                self.pendingTabIDs.remove(id)
                if result.outcome != .served { self.tabProblems[id] = result.reason }
                return
            }
            self?.pendingTabIDs.remove(id)
        }
    }

    /// Moves a tab to stand before another of its window's tabs, or last, as a
    /// drag that reorders the tabs reports it.
    ///
    /// - Parameters:
    ///   - id: The host's tab.
    ///   - next: The tab it is to stand before; nil for the last place.
    func moveTab(_ id: UInt32, before next: UInt32?) {
        guard let moving = tabs.first(where: { $0.id == id }), id != next else { return }
        let others = tabs.filter { $0.windowID == moving.windowID && $0.id != id }
        let place = next.flatMap { target in others.firstIndex { $0.id == target } } ?? others.count
        let siblings = tabs.filter { $0.windowID == moving.windowID }
        guard let from = siblings.firstIndex(of: moving), from != place else { return }
        requestTabMove(moving, toIndex: place)
    }

    /// Moves a tab one place earlier or later among its window's tabs.
    ///
    /// - Parameters:
    ///   - id: The host's tab.
    ///   - offset: -1 for earlier, 1 for later.
    func moveTab(_ id: UInt32, by offset: Int) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let siblings = tabs.filter { $0.windowID == tab.windowID }
        guard let place = siblings.firstIndex(of: tab), siblings.indices.contains(place + offset) else { return }
        moveTab(id, toPlaceOf: siblings[place + offset].id)
    }

    /// Whether a tab can move one place that way among its window's tabs.
    func canMoveTab(_ id: UInt32, by offset: Int) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }) else { return false }
        let siblings = tabs.filter { $0.windowID == tab.windowID }
        return siblings.firstIndex(of: tab).map { siblings.indices.contains($0 + offset) } ?? false
    }

    /// Makes a pane fill its tab, or gives the tab back its split.
    ///
    /// - Parameter id: The pane.
    func zoomPane(_ id: UInt32) {
        guard !isSeededWorkspace, canChangePanes, let view = surface(forPane: id) else { return }
        _ = view.drive.requestPaneVerb(.zoom)
    }

    /// Moves a pane out of its tab into a tab of its own.
    ///
    /// - Parameter id: The pane.
    func movePaneToNewTab(_ id: UInt32) {
        guard !isSeededWorkspace, canChangePanes, let view = surface(forPane: id) else { return }
        _ = view.drive.requestExtraction(wholeTab: false, newWindow: false)
    }

    /// Splits a pane; the new pane takes focus once the host confirms it.
    ///
    /// - Parameters:
    ///   - id: The pane to split.
    ///   - verb: Side by side or one above the other.
    func split(pane id: UInt32, _ verb: Ubiquitty.Runtime.TerminalSession.PaneVerb) {
        guard !isSeededWorkspace else { return }
        if id != activePaneID { selectPane(id) }
        performPaneAction(verb)
    }

    /// Reads back the host's answer to a tab close.
    func settleTabRequests() {
        guard let pending = pendingTabClose else { return }
        switch pending.surface.drive.takeRemoteWorkspaceCloseOutcome() {
        case .Pending: return
        case .Refused: tabProblems[pending.tab] = "The host refused to close this tab."
        case .Accepted, .Idle: break
        @unknown default: break
        }
        pendingTabIDs.remove(pending.tab)
        pendingTabClose = nil
    }

    private static let waitForConnectionProblem = "Wait for the connection before changing tabs."

    // MARK: - The seeded workspace

    private func replaceSeededTab(_ tab: TerminalTab, customTitle: String) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        tabs[index] = TerminalTab(
            id: tab.id,
            windowID: tab.windowID,
            windowIndex: tab.windowIndex,
            tabIndex: tab.tabIndex,
            customTitle: customTitle,
            focusedPaneID: tab.focusedPaneID,
            zoomedPaneID: tab.zoomedPaneID,
            panes: tab.panes
        )
        refreshTabTitles()
    }

    private func reorderSeededTab(_ tab: TerminalTab, toIndex destination: Int) {
        guard let from = tabs.firstIndex(of: tab) else { return }
        var reordered = tabs
        let moved = reordered.remove(at: from)
        reordered.insert(moved, at: min(destination, reordered.count))
        tabs = reordered.enumerated()
            .map { place, each in
                TerminalTab(
                    id: each.id,
                    windowID: each.windowID,
                    windowIndex: each.windowIndex,
                    tabIndex: place,
                    customTitle: each.customTitle,
                    focusedPaneID: each.focusedPaneID,
                    zoomedPaneID: each.zoomedPaneID,
                    panes: each.panes
                )
            }
        refreshTabTitles()
    }

    private func removeSeededPanes(_ removed: Set<UInt32>) {
        let survivors = panes.filter { !removed.contains($0.id) }
        var surfaces: [UInt32: TerminalSurface] = [:]
        for pane in survivors { surfaces[pane.id] = surface(forPane: pane.id) }
        tabs = tabs.compactMap { tab in
            let kept = tab.panes.filter { !removed.contains($0.id) }
            guard !kept.isEmpty else { return nil }
            // A closed pane's neighbour takes the room it leaves, as the
            // host's tree gives it back.
            let frames = kept.count == tab.panes.count ? kept : Self.evenlySpread(kept.map(\.id))
            return TerminalTab(
                id: tab.id,
                windowID: tab.windowID,
                windowIndex: tab.windowIndex,
                tabIndex: tab.tabIndex,
                customTitle: tab.customTitle,
                focusedPaneID: kept.contains { $0.id == tab.focusedPaneID } ? tab.focusedPaneID : kept[0].id,
                zoomedPaneID: 0,
                panes: frames
            )
        }
        adoptSeededPanes(survivors, surfaces: surfaces)
        if removed.contains(activePaneID), let next = survivors.first { selectPane(next.id) }
        refreshTabTitles()
    }

    /// Panes side by side in equal columns.
    static func evenlySpread(_ ids: [UInt32]) -> [TerminalTabPane] {
        let width = 1 / CGFloat(max(ids.count, 1))
        return ids.enumerated()
            .map { index, id in
                TerminalTabPane(id: id, frame: CGRect(x: CGFloat(index) * width, y: 0, width: width, height: 1))
            }
    }

    /// Stands a workspace of three tabs in for a host, with a program in each
    /// pane, for the screen tour and the overview's cases.
    ///
    /// Each pane is a real surface fed what a shell and its programs print, so
    /// the cards show real frames and Core names each tab from the titles and
    /// directories those programs report.
    func seedShowcaseWorkspace() {
        func make(_ id: UInt32, tab: Int, tabID: UInt32) -> TerminalPane {
            TerminalPane(id: id, title: "", windowIndex: 0, tabIndex: tab, tabTitle: "", tabID: tabID)
        }
        let listed = [
            make(1, tab: 0, tabID: 101), make(2, tab: 0, tabID: 101), make(3, tab: 1, tabID: 102), make(4, tab: 2, tabID: 103),
            make(5, tab: 2, tabID: 103), make(6, tab: 2, tabID: 103),
        ]
        var surfaces: [UInt32: TerminalSurface] = [:]
        for pane in listed {
            guard let made = makePaneSurface() else { continue }
            made.feed(Data(Self.showcaseOutput(for: pane.id).utf8))
            surfaces[pane.id] = made
        }
        isSeededWorkspace = true
        adoptSeededPanes(listed, surfaces: surfaces)
        let half: CGFloat = 0.5
        tabs = [
            TerminalTab(
                id: 101,
                windowID: 1,
                windowIndex: 0,
                tabIndex: 0,
                customTitle: "",
                focusedPaneID: 1,
                zoomedPaneID: 0,
                panes: Self.evenlySpread([1, 2])
            ),
            TerminalTab(
                id: 102,
                windowID: 1,
                windowIndex: 0,
                tabIndex: 1,
                customTitle: "",
                focusedPaneID: 3,
                zoomedPaneID: 0,
                panes: Self.evenlySpread([3])
            ),
            TerminalTab(
                id: 103,
                windowID: 1,
                windowIndex: 0,
                tabIndex: 2,
                customTitle: "deploy",
                focusedPaneID: 4,
                zoomedPaneID: 0,
                panes: [
                    TerminalTabPane(id: 4, frame: CGRect(x: 0, y: 0, width: half, height: 1)),
                    TerminalTabPane(id: 5, frame: CGRect(x: half, y: 0, width: half, height: half)),
                    TerminalTabPane(id: 6, frame: CGRect(x: half, y: half, width: half, height: half)),
                ]
            ),
        ]
        selectPane(1)
        refreshTabTitles()
    }

    /// What each seeded pane's program prints: a title, a directory and a screen.
    private static func showcaseOutput(for pane: UInt32) -> String {
        let escape = "\u{1b}"
        let bell = "\u{7}"
        func titled(_ title: String, _ directory: String) -> String {
            "\(escape)]2;\(title)\(bell)\(escape)]7;file://localhost\(directory)\(bell)"
        }
        let prompt = "\(escape)[32muser@host\(escape)[0m:\(escape)[34m~/src/ubiquitty\(escape)[0m$ "
        switch pane {
        case 1:
            return titled("vim notes.md", "/home/user/src/ubiquitty")
                + "\(escape)[1m# Release notes\(escape)[0m\r\n\r\n- Tab overview with live thumbnails\r\n- Find in scrollback\r\n- \(escape)[33mTODO\(escape)[0m captures for iPad\r\n~\r\n~\r\n~\r\n\(escape)[7m notes.md [+] \(escape)[0m"
        case 2:
            return titled("cargo watch", "/home/user/src/ubiquitty")
                + "\(escape)[32m   Compiling\(escape)[0m ubiquitty-core v0.9.0\r\n\(escape)[32m    Finished\(escape)[0m dev profile in 4.21s\r\n\(escape)[32m     Running\(escape)[0m 412 tests\r\ntest result: \(escape)[32mok\(escape)[0m. 412 passed; 0 failed\r\n"
        case 3:
            return titled("htop", "/home/user")
                + "  CPU [\(escape)[32m|||||||\(escape)[31m||\(escape)[0m      38.2%]\r\n  Mem [\(escape)[32m||||||||||\(escape)[0m   5.1G/16G]\r\n\r\n\(escape)[30;42m  PID USER  CPU% COMMAND        \(escape)[0m\r\n 4211 user  31.0 ubq-daemon\r\n 4380 user  12.4 cargo\r\n 1022 root   2.1 sshd\r\n"
        case 4:
            return titled("", "/srv/deploy") + prompt
                + "git log --oneline -3\r\n\(escape)[33m9d8dec0\(escape)[0m Hold the corpus gates\r\n\(escape)[33m0b336b1\(escape)[0m Leave a replica's queries\r\n\(escape)[33m50e128f\(escape)[0m Tick each session clock\r\n"
                + prompt
        case 5:
            return titled("tail -f deploy.log", "/srv/deploy")
                + "12:01:04 \(escape)[32mINFO\(escape)[0m rollout started\r\n12:01:09 \(escape)[32mINFO\(escape)[0m 3/6 hosts healthy\r\n12:01:15 \(escape)[33mWARN\(escape)[0m retrying web-4\r\n"
        default:
            return titled("", "/srv/deploy") + prompt
        }
    }
}

/// A close confirmation keeps its exact panes even if focus moves while it is shown.
@MainActor
struct KeyboardCloseRequest: Identifiable {
    let id = UUID()
    let tabID: UInt32
    let paneID: UInt32
    let surfaces: [UInt32: TerminalSurface]
    let sessionIDs: [UInt32: UInt32]
    let isWholeTab: Bool
    let title: String
    let body: String
}

extension TerminalSessionModel {
    func requestKeyboardClose(wholeTab: Bool) {
        guard keyboardCloseRequest == nil, canChangeTabs, let tab = activeTab else { return }
        refreshTabTitles()
        let paneIDs = wholeTab ? tab.panes.map(\.id) : [activePaneID]
        var surfaces: [UInt32: TerminalSurface] = [:]
        for id in paneIDs {
            guard let surface = surface(forPane: id) else { return }
            surfaces[id] = surface
        }
        let question = Self.closeQuestion(wholeTab ? .tab : .pane, programs: paneIDs.compactMap { activeTab?.runningPrograms[$0] })
        keyboardCloseRequest = KeyboardCloseRequest(
            tabID: tab.id,
            paneID: activePaneID,
            surfaces: surfaces,
            sessionIDs: surfaces.mapValues(\.remoteSessionID),
            isWholeTab: wholeTab,
            title: question.title,
            body: question.body
        )
    }

    func confirmKeyboardClose(_ request: KeyboardCloseRequest) {
        // SwiftUI can clear the sheet's binding before invoking the button.
        // Validate against the live workspace, rather than whichever pane has focus.
        guard canChangeTabs, let tab = tabs.first(where: { $0.id == request.tabID }),
            !request.isWholeTab || Set(tab.panes.map(\.id)) == Set(request.surfaces.keys),
            request.surfaces.allSatisfy({ id, surface in
                self.surface(forPane: id) === surface && surface.remoteSessionID == request.sessionIDs[id]
            })
        else { return }
        keyboardCloseRequest = nil
        if request.isWholeTab { closeTab(request.tabID) } else { closeTabPane(request.paneID) }
    }
}
