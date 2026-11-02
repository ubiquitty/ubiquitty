// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// ConnectOutlineScenarios.swift — the Connect window's outline of a host,
// driven over the showcase host held in the directory's own client.
//
// What is asserted is that the window reads Core: the rows are the client's,
// a fold and a search are handed to Core and the rows that come back are the
// ones drawn, a tree a watch left behind is drawn as that with Core's sentence
// over it, and a connect nothing picks puts Core's question in front of the
// person. A scenario that restated what a row should say would pass against a
// window that composed it.
//
// The same host is drawn to pictures when `UBQ_UI_PICTURES` names a directory:
// the rows through SwiftUI's renderer in both appearances, with no window
// ordered in. The window itself is pictured only in a run made visible, where
// it is small, ordered behind every other window and never made key, and the
// window server is asked for its picture by its number.

/// Registers the outline scenarios with the UI-test runner.
enum ConnectOutlineScenarios {
    /// The defaults keys these scenarios write, cleared around each one.
    private static let touchedDefaultsKeys = [
        "UBHostServers", "UBHostSessionPairings", "UBConnectRecents", "UBConnectLastPlace", "UBConnectLastHost",
    ]

    /// The tag rules the pictures are drawn under, so the showcase host's
    /// tags wear colours: one loud, two quiet, and one matched by host.
    private static let tagRules: [[String: String]] = [
        ["name": "production", "color": "red", "matchHost": "", "matchProfile": "", "prominence": "loud"],
        ["name": "staging", "color": "orange", "matchHost": "", "matchProfile": "", "prominence": "quiet"],
        ["name": "writing", "color": "blue", "matchHost": "", "matchProfile": "", "prominence": "quiet"],
        ["name": "builders", "color": "green", "matchHost": "build-*", "matchProfile": "", "prominence": "quiet"],
    ]

    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("host_management_outline_uses_cores_actions_and_details") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withShowcase(t, named: "Management Outline Box") { connect, server in
                    let management = HostManagementModel(server: server)
                    let directory = management.directory
                    directory.isDiallingSuppressedForTesting = true
                    directory.holdShowcaseHostForTesting(.live)
                    defer { management.stopFollowing() }
                    t.expect(
                        directory.outline.rows.map(\.key) == connect.directory.outline.rows.map(\.key),
                        desc: "management draws the same tree and row identities as Connect"
                    )
                    guard let workspace = directory.outline.rows.first(where: { $0.level == .workspace && $0.title == "api" }) else {
                        t.expect(false, desc: "management holds the api workspace")
                        return
                    }
                    directory.selection = workspace.key
                    let details = management.selectedSessionDetails
                    t.expect(!details.isEmpty, desc: "selecting a workspace exposes its process and lifetime details")
                    t.expect(
                        details.allSatisfy {
                            !$0.creationLabel.empty() && !$0.origin.empty() && !$0.sharing.empty() && !$0.lifetime.empty()
                        },
                        desc: "creation, adoption, sharing and lifetime all retain Core's wording"
                    )
                    management.confirmTerminateSelection()
                    guard let question = directory.destructiveQuestion else {
                        t.expect(false, desc: "management asks Core before ending anything")
                        return
                    }
                    t.expect(
                        question.token != 0 && question.request == .terminateWorkspace,
                        desc: "the question authorizes the selected workspace"
                    )
                    t.expect(
                        question.buttons.count == 2 && !question.buttons[0].isDestructive && question.buttons[1].isDestructive,
                        desc: "the safe button comes first, as in Connect"
                    )
                    let alert = HostDestructiveAlert.alert(for: question)
                    t.expect(
                        alert.buttons.count == 2 && alert.buttons[0].keyEquivalent == "\r" && !alert.buttons[0].hasDestructiveAction
                            && alert.buttons[1].hasDestructiveAction,
                        desc: "management's shared native alert keeps Return on the safe action"
                    )
                    t.expect(!HostDestructiveAlert.isConfirmed(.alertFirstButtonReturn), desc: "the safe response sends nothing")
                    t.expect(!HostDestructiveAlert.isConfirmed(.abort), desc: "dismissing the management window sends nothing")
                    directory.destructiveQuestion = nil
                    if let windowRow = directory.outline.rows.first(where: { $0.level == .window }),
                        let windowID = directory.window(of: windowRow)
                    {
                        directory.askToEnd(.closeWindow, windowID, named: windowRow.title)
                        t.expect(
                            directory.destructiveQuestion?.request == .closeWindow && directory.destructiveQuestion?.target == windowID,
                            desc: "Close Window asks about exactly the window row"
                        )
                        directory.destructiveQuestion = nil
                    } else {
                        t.expect(false, desc: "the management fixture has an unfolded window")
                    }
                    for row in directory.outline.rows where row.level == .pane || row.foldedPane != nil {
                        guard let ending = directory.terminateRequest(for: row), ending.request == .terminateSession else { continue }
                        directory.selection = row.key
                        management.confirmTerminateSelection()
                        t.expect(
                            directory.destructiveQuestion?.target == ending.target
                                && directory.destructiveQuestion?.sessionIDs == [row.open.sessionID],
                            desc: "a pane or folded pane asks about its one session, not its containing workspace"
                        )
                        directory.destructiveQuestion = nil
                    }
                    directory.outline.query = "no-such-management-row"
                    t.expect(directory.outline.isSearching && directory.outline.rows.isEmpty, desc: "management search is Core's")
                    directory.outline.query = ""
                    directory.holdShowcaseHostForTesting(.stale)
                    t.expect(
                        directory.outline.freshness == .stale && !directory.outline.watchError.isEmpty,
                        desc: "a lost watch keeps its rows with Core's stale warning"
                    )
                }
            }
        }

        UBUITestRegister("connect_outline_draws_cores_rows_and_folds_through_core") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withShowcase(t, named: "Outline Box") { model, _ in
                    let directory = model.directory
                    let outline = directory.outline
                    t.expect(
                        model.contentState == .sessions,
                        desc: "a host holding workspaces shows its outline (\(model.contentState.name))"
                    )
                    t.expect(directory.workspaceCount == 5, desc: "the showcase host holds five workspaces (\(directory.workspaceCount))")
                    t.expect(outline.freshness == .live, desc: "a followed tree is live (\(outline.freshness))")

                    // The rows are Core's, in Core's order, each indented as
                    // Core says.
                    let titles = outline.rows.map(\.title)
                    t.expect(outline.rows.first?.title == "api", desc: "the first row is the first workspace (\(titles.first ?? "none"))")
                    t.expect(
                        outline.rows.contains { $0.level == .pane && $0.depth == 3 },
                        desc: "a pane of a tab of a window sits three levels in"
                    )
                    guard let api = outline.rows.first(where: { $0.level == .workspace && $0.title == "api" }) else {
                        t.expect(false, desc: "the api workspace has a row (\(titles))")
                        return
                    }
                    t.expect(api.isExpandable && api.isExpanded, desc: "a workspace of several windows starts open")
                    t.expect(api.collapsedWords.isEmpty, desc: "an open row says nothing of what it hides")

                    // A fold is the store asking Core for the rows again with
                    // the row closed; the rows under it go and the row says
                    // what it hides in Core's words.
                    let openCount = outline.rows.count
                    outline.toggle(api)
                    guard let closed = outline.rows.first(where: { $0.key == api.key }) else {
                        t.expect(false, desc: "the closed row is still drawn")
                        return
                    }
                    t.expect(!closed.isExpanded, desc: "the row is closed")
                    t.expect(outline.rows.count < openCount, desc: "and the rows under it are gone (\(outline.rows.count) of \(openCount))")
                    t.expect(
                        closed.collapsedWords.contains("windows") && closed.collapsedWords.contains("panes"),
                        desc: "and it says what it hides (\(closed.collapsedWords))"
                    )

                    // What is closed is the person's, and outlives a refresh.
                    directory.holdShowcaseHostForTesting(.live)
                    t.expect(
                        outline.rows.first(where: { $0.key == api.key })?.isExpanded == false,
                        desc: "a closed row stays closed when the host reports again"
                    )
                    outline.toggle(closed)
                    t.expect(outline.rows.count == openCount, desc: "opening it brings its rows back (\(outline.rows.count))")

                    // A recorded row has no identity and is closed by its
                    // place in the record.
                    if let recorded = outline.rows.first(where: { $0.recordedKey != nil && $0.isExpandable }) {
                        let before = outline.rows.count
                        outline.toggle(recorded)
                        t.expect(outline.rows.count < before, desc: "a recorded window closes by its place (\(recorded.title))")
                        outline.toggle(outline.rows.first { $0.key == recorded.key } ?? recorded)
                        t.expect(outline.rows.count == before, desc: "and opens again")
                    } else {
                        t.expect(false, desc: "the restorable workspace has a recorded row that folds")
                    }
                }
            }
        }

        UBUITestRegister("connect_outline_search_is_cores") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withShowcase(t, named: "Search Box") { model, _ in
                    let outline = model.directory.outline
                    let allRows = outline.rows.count
                    t.expect(!outline.isSearching, desc: "nothing is searched for at first")

                    // The window's search field is the outline's query.
                    model.searchText = "nvim"
                    t.expect(outline.isSearching, desc: "typing in the field searches the outline")
                    t.expect(outline.matchCount >= 1, desc: "Core finds the editor (\(outline.matchCount))")
                    t.expect(outline.rows.count < allRows, desc: "and keeps only what matches and the way to it (\(outline.rows.count))")
                    t.expect(outline.rows.contains { $0.isMatch }, desc: "a matching row is marked as one")
                    t.expect(outline.rows.first?.level == .workspace, desc: "under its workspace")

                    // A tag is found on the row that earned it.
                    model.searchText = "staging"
                    t.expect(
                        outline.rows.contains { $0.isMatch && $0.title == "deploy" },
                        desc: "a workspace is found by a tag a person put on it (\(outline.rows.map(\.title)))"
                    )

                    // A fold has nothing to act on in a search.
                    if let parent = outline.rows.first(where: { $0.isExpandable }) {
                        let before = outline.rows.count
                        outline.toggle(parent)
                        t.expect(outline.rows.count == before, desc: "a fold does nothing while searching")
                    }

                    model.searchText = "no row says this"
                    t.expect(outline.rows.isEmpty && outline.matchCount == 0, desc: "a search nothing matches draws no rows")

                    // Escape clears the search, and the outline is whole again.
                    ConnectWindowController.shared.cancelOperation(nil)
                    t.expect(model.searchText.isEmpty && !outline.isSearching, desc: "Escape clears the search")
                    t.expect(outline.rows.count == allRows, desc: "and every row is back (\(outline.rows.count))")
                }
            }
        }

        UBUITestRegister("connect_outline_never_draws_a_stale_tree_as_live") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withShowcase(t, named: "Stale Box") { model, _ in
                    let directory = model.directory
                    t.expect(model.visibleBanner == nil, desc: "a followed host has no banner (\(model.visibleBanner?.message ?? "none"))")
                    let liveRows = directory.outline.rows.count

                    directory.holdShowcaseHostForTesting(.stale)
                    t.expect(
                        directory.outline.freshness == .stale,
                        desc: "a tree its watch left behind is stale (\(directory.outline.freshness))"
                    )
                    t.expect(directory.outline.rows.count == liveRows, desc: "its rows stay on screen (\(directory.outline.rows.count))")
                    t.expect(!directory.outline.watchError.isEmpty, desc: "Core says why the watch is not following")
                    t.expect(
                        model.visibleBanner?.message == directory.outline.watchError,
                        desc: "the banner is Core's sentence and nothing else (\(model.visibleBanner?.message ?? "none"))"
                    )
                    t.expect(model.visibleBanner?.action == .tryAgain, desc: "with Try Again")
                    // A tree nothing follows is not the host's answer: the
                    // rule waits rather than deciding on it.
                    t.expect(
                        directory.plannedConnectForTesting()?.plan == .awaitListing,
                        desc:
                            "Core does not decide a connect on a stale tree (\(String(describing: directory.plannedConnectForTesting()?.plan)))"
                    )

                    directory.holdShowcaseHostForTesting(.live)
                    t.expect(
                        directory.outline.freshness == .live && model.visibleBanner == nil,
                        desc: "and is live again when the watch is back"
                    )
                }
            }
        }

        UBUITestRegister("connect_outline_presents_cores_question") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withShowcase(t, named: "Question Box") { model, server in
                    let directory = model.directory
                    UbiquittyKit.HostDirectory.forget(host: server.pairingKey)
                    guard let decision = directory.plannedConnectForTesting() else {
                        t.expect(false, desc: "the directory planned a connect")
                        return
                    }
                    t.expect(
                        decision.plan == .chooseFromList,
                        desc: "several workspaces and nothing remembered asks the person (\(decision.plan))"
                    )
                    guard let question = directory.question else {
                        t.expect(false, desc: "Core worded a question")
                        return
                    }
                    t.expect(question.candidates.count == 5, desc: "every workspace may be picked (\(question.candidates.count))")
                    t.expect(
                        question.candidates.map(\.title) == ["api", "release", "deploy", "scratch", "notes"],
                        desc: "each under the title its row has (\(question.candidates.map(\.title)))"
                    )
                    t.expect(
                        question.candidates.first { $0.title == "release" }?.state == .restorable,
                        desc: "a workspace nothing runs in is offered as one the host would restore"
                    )
                    let action = directory.primaryActionForTesting()
                    t.expect(
                        action.sentence == question.shortText && question.shortText != question.text,
                        desc: "the action bar uses Core's short question (\(action.sentence))"
                    )
                    t.expect(action.isEnabled, desc: "and the default asks it")

                    t.expect(!directory.connect(), desc: "the connect opens no window")
                    t.expect(directory.presentedQuestion == question, desc: "it puts Core's question in front of the person")
                    guard let window = ConnectWindowController.shared.window else { return }
                    t.expect(t.wait(until: { window.attachedSheet != nil }, timeout: 3), desc: "as a sheet on the Connect window")
                    directory.presentedQuestion = nil
                    t.expect(t.wait(until: { window.attachedSheet == nil }, timeout: 3), desc: "which Cancel takes down")
                }
            }
        }

        UBUITestRegister("connect_outline_opens_what_core_says_a_row_opens") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withShowcase(t, named: "Open Box") { model, server in
                    let directory = model.directory
                    let outline = directory.outline
                    UbiquittyKit.HostDirectory.forget(host: server.pairingKey)

                    // A pane's row: Core's plan attaches to the session the
                    // row says opening it attaches to.
                    guard let pane = outline.rows.first(where: { $0.level == .pane && $0.open.how == .bySession }) else {
                        t.expect(false, desc: "a pane's row opens a session")
                        return
                    }
                    t.expect(pane.open.paneID != 0, desc: "and names the pane to show once attached")
                    directory.selection = pane.key
                    let chosen = directory.plannedConnectForTesting()
                    t.expect(
                        chosen?.plan == .attachByID && chosen?.sessionID == pane.open.sessionID,
                        desc: "Core plans an attach to the row's session (\(String(describing: chosen?.plan)), \(chosen?.sessionID ?? 0))"
                    )
                    t.expect(directory.namesOneSession(pane), desc: "a pane's row names one session")
                    t.expect(directory.terminateRequest(for: pane)?.request == .terminateSession, desc: "and offers to end it")

                    // Opening a row from the list selects it and runs the
                    // default.
                    model.recordedActionsForTesting = []
                    guard let deploy = outline.rows.first(where: { $0.level == .workspace && $0.title == "deploy" }) else { return }
                    t.expect(model.recordOpenForTesting(deploy), desc: "an open is recorded rather than dialled")
                    t.expect(directory.selection == deploy.key, desc: "and selects the row it opened")
                    t.expect(!directory.namesOneSession(deploy), desc: "a row over several panes names no one session")
                    t.expect(
                        directory.terminateRequest(for: deploy)?.request == .terminateWorkspace,
                        desc: "a workspace's row offers to end the workspace"
                    )

                    // A workspace nothing runs in opens by the name Core gives.
                    guard let release = outline.rows.first(where: { $0.level == .workspace && $0.workspaceState == .restorable }) else {
                        t.expect(false, desc: "the restorable workspace has a row")
                        return
                    }
                    t.expect(release.open.how == .byRestoring, desc: "its row opens by restoring (\(release.open.how))")
                    directory.selection = release.key
                    let restore = directory.primaryActionForTesting()
                    t.expect(
                        restore.isEnabled && restore.title == "Open “\(release.open.workspaceName)”",
                        desc: "the default opens it under the name Core states (\(restore.title))"
                    )

                    // A level of it cannot be opened, and the default says
                    // why in Core's sentence.
                    guard let recorded = outline.rows.first(where: { $0.workspaceState == .restorable && $0.level != .workspace }) else {
                        t.expect(false, desc: "the restorable workspace has rows under it")
                        return
                    }
                    t.expect(
                        recorded.open.how == .cannot && !recorded.open.obstacle.isEmpty,
                        desc: "a recorded level cannot be opened, and Core says why"
                    )
                    directory.selection = recorded.key
                    let refused = directory.primaryActionForTesting()
                    t.expect(!refused.isEnabled, desc: "the default is disabled on it")
                    t.expect(refused.sentence == recorded.open.obstacle, desc: "and its sentence is Core's (\(refused.sentence))")
                    t.expect(!directory.performPrimaryAction(), desc: "opening it opens nothing")
                    t.expect(directory.notice?.title == recorded.open.obstacle, desc: "and shows Core's sentence")
                    directory.notice = nil
                }
            }
        }

        UBUITestRegister("connect_outline_shows_cores_reason_for_a_change_not_made") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withShowcase(t, named: "Change Box") { model, _ in
                    let directory = model.directory
                    let outline = directory.outline
                    guard let api = outline.rows.first(where: { $0.level == .workspace && $0.title == "api" }) else { return }

                    // What an editor opens on is what the row states the
                    // level itself holds, apart from what the row wears.
                    t.expect(
                        api.own.first?.id == api.id && api.own.first?.label == "backend" && api.own.first?.tags == ["production", "eu"],
                        desc: "a workspace's row states its own label and tags (\(String(describing: api.own.first)))"
                    )
                    // Open, the row says only what is its own; closed, it
                    // wears what the rows under it earned too.
                    t.expect(
                        api.tags.map(\.name) == ["production", "eu"],
                        desc: "open, it wears its own tags alone (\(api.tags.map(\.name)))"
                    )
                    outline.toggle(api)
                    let closedTags = outline.rows.first { $0.key == api.key }?.tags.map(\.name) ?? []
                    t.expect(closedTags.count > 2, desc: "closed, it wears what is under it as well (\(closedTags))")
                    if let closed = outline.rows.first(where: { $0.key == api.key }) {
                        outline.toggle(closed)
                    }
                    t.expect(api.open.workspaceName == "api", desc: "and its name (\(api.open.workspaceName))")
                    guard let tab = outline.rows.first(where: { $0.tabPlace != nil && $0.level == .tab }), let place = tab.tabPlace else {
                        t.expect(false, desc: "a tab's row states where it stands")
                        return
                    }
                    t.expect(place.tabCount == 3 && place.index == 0, desc: "the first of three tabs (\(place.index) of \(place.tabCount))")
                    t.expect(!place.canMoveEarlier && place.canMoveLater, desc: "may move later and not earlier")

                    // No host is behind the showcase, so Core refuses the
                    // change itself, and the window shows Core's reason and
                    // adds nothing to it.
                    directory.notice = nil
                    directory.renameWorkspace(api, to: "api-2")
                    t.expect(
                        t.wait(until: { directory.notice != nil }, timeout: 3),
                        desc: "a change that was not made is reported"
                    )
                    t.expect(
                        directory.notice?.title.isEmpty == false && directory.notice?.message.isEmpty == true,
                        desc: "in Core's sentence alone (\(directory.notice?.title ?? "none"))"
                    )
                    t.expect(model.visibleBanner?.message == directory.notice?.title, desc: "which is what the banner says")
                    directory.notice = nil
                }
            }
        }

        UBUITestRegister("connect_outline_pictures") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { drawPictures(t) }
        }
    }

    // MARK: - Pictures

    /// Draws the showcase host to PNG files under `UBQ_UI_PICTURES`.
    @MainActor
    private static func drawPictures(_ t: UBUITestContext) {
        guard let directoryPath = ProcessInfo.processInfo.environment["UBQ_UI_PICTURES"], !directoryPath.isEmpty else {
            t.expect(true, desc: "no picture directory named; nothing drawn")
            return
        }
        try? FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        guard let delegate = SettingsBridge.app else { return }
        for rule in tagRules {
            delegate.settingsSaveTag(rule, at: -1)
        }
        defer {
            for rule in tagRules {
                deleteTagRules(named: rule["name"] ?? "")
            }
        }
        withShowcase(t, named: "build.example") { model, server in
            let directory = model.directory
            let outline = directory.outline
            UbiquittyKit.HostDirectory.forget(host: server.pairingKey)

            @MainActor
            func rows(_ name: String, width: CGFloat = 640, selected: HostOutlineRowKey? = nil, banner: String? = nil) {
                for scheme in [ColorScheme.light, .dark] {
                    let picture = OutlinePicture(
                        rows: outline.rows,
                        isSearching: outline.isSearching,
                        freshness: outline.freshness,
                        banner: banner,
                        selected: selected,
                        scheme: scheme,
                        width: width
                    )
                    let renderer = ImageRenderer(content: picture)
                    renderer.scale = 2
                    let path = "\(directoryPath)/rows-\(name)-\(scheme == .dark ? "dark" : "light").png"
                    let didWrite = write(renderer.nsImage, to: path)
                    t.expect(didWrite, desc: "drew \(path)")
                }
            }

            rows("live")
            rows("narrow", width: 460)
            if let build = outline.rows.first(where: { $0.level == .pane && $0.progressState != 0 }) {
                rows("selected", selected: build.key)
            }
            for title in ["api", "deploy", "release"] {
                if let row = outline.rows.first(where: { $0.level == .workspace && $0.title == title }) {
                    outline.toggle(row)
                }
            }
            rows("collapsed")
            for title in ["api", "deploy", "release"] {
                if let row = outline.rows.first(where: { $0.level == .workspace && $0.title == title }) {
                    outline.toggle(row)
                }
            }
            model.searchText = "cargo"
            rows("search")
            model.searchText = ""
            directory.holdShowcaseHostForTesting(.stale)
            rows("stale", banner: outline.watchError)

            // The window itself, in the appearance it has: the sidebar,
            // the list's own chrome, the banner and the bottom bar. Only the
            // window server has that picture, and it has none of a window
            // parked off every display, so this half needs a visible run.
            guard !WindowContainment.isOffscreen, let window = ConnectWindowController.shared.window else { return }
            let originalApplication = NSWorkspace.shared.frontmostApplication
            let originalPolicy = NSApp.activationPolicy()
            let isForegroundCapture = ProcessInfo.processInfo.environment["UBQ_UI_PICTURE_FOREGROUND"] == "1"
            if isForegroundCapture {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            defer {
                if isForegroundCapture {
                    NSApp.setActivationPolicy(originalPolicy)
                    originalApplication?.activate(options: [])
                }
            }
            t.pump(0.8)
            capture(window, to: "\(directoryPath)/window-stale.png", t)
            directory.holdShowcaseHostForTesting(.live)
            t.pump(0.8)
            capture(window, to: "\(directoryPath)/window-live.png", t)
            if let pane = outline.rows.first(where: { $0.level == .pane && $0.progressState != 0 }) {
                directory.selection = pane.key
                t.pump(0.5)
                capture(window, to: "\(directoryPath)/window-selected.png", t)
                directory.selection = nil
            }
            model.searchText = "staging"
            t.pump(0.8)
            capture(window, to: "\(directoryPath)/window-search.png", t)
            model.searchText = ""
            t.pump(0.5)
            _ = directory.connect()
            if t.wait(until: { window.attachedSheet != nil }, timeout: 3), let sheet = window.attachedSheet {
                t.pump(0.8)
                capture(sheet, to: "\(directoryPath)/window-question.png", t)
            } else {
                t.expect(false, desc: "the question sheet came up to be drawn")
            }
            directory.presentedQuestion = nil
            _ = t.wait(until: { window.attachedSheet == nil }, timeout: 3)
            if let scratch = outline.rows.first(where: { $0.level == .workspace && $0.title == "scratch" }),
                let ending = directory.terminateRequest(for: scratch)
            {
                directory.askToEnd(ending.request, ending.target, named: scratch.title)
                if t.wait(until: { window.attachedSheet != nil }, timeout: 3), let sheet = window.attachedSheet {
                    t.pump(0.8)
                    capture(sheet, to: "\(directoryPath)/window-terminate-question.png", t)
                    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                    _ = t.wait(until: { window.attachedSheet == nil }, timeout: 3)
                } else {
                    t.expect(false, desc: "Core's question before a terminate came up to be drawn")
                }
            }
        }
    }

    /// The rows as the list draws them, for SwiftUI's renderer: no window, so
    /// nothing is ordered in to make the picture.
    private struct OutlinePicture: View {
        let rows: [HostOutlineRow]
        let isSearching: Bool
        let freshness: HostOutlineFreshness
        let banner: String?
        let selected: HostOutlineRowKey?
        let scheme: ColorScheme
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                if let banner {
                    HostOutlineStaleBanner(message: banner, retry: {})
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.key) { row in
                        HostOutlineRowView(
                            row: row,
                            isSearching: isSearching,
                            toggle: {},
                            isCompact: width < HostOutlineMetrics.compactWidth,
                            accessory: { EmptyView() }
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(row.key == selected ? Color.accentColor : Color.clear)
                        .environment(\.backgroundProminence, row.key == selected ? .increased : .standard)
                    }
                }
                .modifier(HostOutlineFreshnessStyle(freshness: freshness))
            }
            .frame(width: width)
            .background(scheme == .dark ? Color(white: 0.12) : Color.white)
            .environment(\.colorScheme, scheme)
        }
    }

    /// Writes an image as a PNG file.
    @MainActor
    private static func write(_ image: NSImage?, to path: String) -> Bool {
        guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Takes a window's picture from the window server, by its number,
    /// without bringing it forward.
    @MainActor
    private static func capture(_ window: NSWindow, to path: String, _ t: UBUITestContext) {
        try? FileManager.default.removeItem(atPath: path)
        window.displayIfNeeded()
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l\(window.windowNumber)", path]
        try? capture.run()
        capture.waitUntilExit()
        t.expect(FileManager.default.fileExists(atPath: path), desc: "the window server pictured \(path)")
    }

    // MARK: - Helpers

    /// Runs a scenario with the Connect window open on a saved host whose
    /// directory holds the showcase host, followed by a watch.
    ///
    /// Nothing is dialled: the address resolves nowhere and the directory is
    /// told not to try, so the tree on screen is the one held here.
    @MainActor
    private static func withShowcase(_ t: UBUITestContext, named name: String, _ body: @MainActor (ConnectModel, HostServer) -> Void) {
        let restore = takeDefaults()
        defer { putBackDefaults(restore) }
        clearDefaults()
        let model = ConnectModel.shared
        model.shouldRecordActionsForTesting = true
        model.directory.isDiallingSuppressedForTesting = true
        defer {
            model.directory.presentedQuestion = nil
            model.directory.isDiallingSuppressedForTesting = false
            model.shouldRecordActionsForTesting = false
            model.searchText = ""
            ConnectWindowController.shared.window?.close()
        }
        let server = HostServer(
            id: UUID(),
            name: name,
            host: "uitest@\(name.lowercased().replacingOccurrences(of: " ", with: "-")).invalid",
            workspaceName: ""
        )
        model.setHostsForTesting([server])
        if WindowContainment.isOffscreen {
            ConnectWindowController.show(place: .host(server.id))
        } else {
            // A visible run: the window is small, in a corner, behind every
            // other window, and is never made key or brought forward.
            model.open(place: .host(server.id), intent: .none)
            if let window = ConnectWindowController.shared.window, let screen = NSScreen.main {
                window.setFrame(
                    NSRect(x: screen.visibleFrame.minX + 16, y: screen.visibleFrame.minY + 16, width: 860, height: 600),
                    display: true
                )
                window.orderBack(nil)
            }
        }
        t.pump(0.3)
        model.directory.holdShowcaseHostForTesting(.live)
        t.pump(0.2)
        body(model, server)
    }

    private static func takeDefaults() -> [String: Any] {
        var taken: [String: Any] = [:]
        for key in touchedDefaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                taken[key] = value
            }
        }
        return taken
    }

    private static func putBackDefaults(_ values: [String: Any]) {
        for key in touchedDefaultsKeys {
            if let value = values[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private static func clearDefaults() {
        for key in touchedDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
