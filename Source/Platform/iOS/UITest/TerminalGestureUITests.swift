// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalGestureUITests.swift — the gestures, driven by fingers rather than by
// a stub.
//
// The in-process touch smokes call each recogniser's action method with a
// hand-made recogniser. That proves the handler's arithmetic and nothing about
// whether the recogniser is installed, whether it is on the view the reader
// touches, or whether UIKit would ever route two real touches to it. All three
// have to hold before any of the arithmetic runs, and none of them is visible
// from inside the process.
//
// So these cases drive the installed application from outside it: XCUITest
// synthesises the touches through the same path a finger takes, and the
// assertions read what the APP did — a sheet that came up, a screen that stayed.
//
// The route in is the route a person takes: add a host through the editor, tap
// its row, land on the terminal. A test that seeded a screen of its own would
// be back to proving its own scaffolding works.
//
// XCUITest's public gesture set has no two-finger pan: `twoFingerTap`,
// `tap(withNumberOfTaps:numberOfTouches:)`, `pinch` and `rotate` for
// multi-touch, and one finger for every swipe. The two-finger swipe is driven
// through the event synthesiser those gestures are built on — the runner's own
// `XCPointerEventPath` and `XCSynthesizedEventRecord`, reached by name, so a
// toolkit that renamed them fails `twoFingerSwipe` loudly rather than skipping
// the case. See `testATwoFingerSwipeWithOneConnectionSaysSoAndStays`.
//
// Every case here has been shown to fail, by breaking what it covers and
// watching it redden. That is not ceremony: a one-finger control can pass
// against a recogniser wired specifically to defeat it, and so fail to fail.
// A negative assertion on a surface with competing recognisers is
// satisfied by the platform far more often than it looks, so a case that says
// "nothing happened" earns its place only by being shown to bite.

import UIKit
import XCTest
import XCUIAutomation

// Main-actor as a type: XCUIApplication and every element query are
// main-actor in the Swift 6 SDK, and the XCUITest runner delivers test
// methods on the main thread — the attribute states the confinement the
// runner already provides.
@MainActor
final class TerminalGestureUITests: XCTestCase {
    private static let applicationBundleIdentifier = "org.ubiquitty.Ubiquitty"

    /// The host this suite opens. Named, so it is told apart from whatever the
    /// person running the simulator has saved.
    private static let hostName = "ui-test-host"
    /// The host the live QUIC case adds, kept apart from the offline one so the
    /// two cannot inherit each other's saved state.
    private static let liveHostName = "ui-live-quic"
    /// The host that names a workspace. A saved host is a file on the
    /// simulator and the cases share one, so the host that carries a workspace
    /// name is its own: a name on the shared host would send every other case
    /// down the connect that skips the session list.
    private static let workspaceHostName = "ui-workspace-host"
    /// The workspace that host names.
    private static let workspaceName = "review"
    /// The host the delete cases remove. Its own, so deleting it never takes
    /// the shared host or its secret from the other cases.
    private static let deletableHostName = "ui-deletable-host"
    /// The plain-SSH host the redial case edits. Its own, because the case
    /// changes its port and turns QUIC off, which the shared host must keep.
    private static let redialHostName = "ui-redial-host"
    /// The host the password case opens. Its own, and saving no password,
    /// so the seeded server's request is the one the alert answers.
    private static let promptHostName = "ui-prompt-host"
    /// The host the connecting case dials: an address no network routes.
    private static let slowHostName = "ui-unroutable-host"
    /// The second host the connection-switch case opens beside the first, so
    /// two connections are under way at once.
    private static let secondHostName = "ui-second-host"

    /// The app under test, constructed per access: XCUIApplication is a
    /// stateless proxy for its bundle identifier, and a computed property on
    /// the isolated class is what lets every main-actor test reach it without
    /// a stored value crossing setUp's nonisolated override.
    private var app: XCUIApplication {
        XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
    }

    override func setUp() {
        super.setUp()
        // A failed assertion leaves the app on whatever screen it was on, and
        // the next case starts from there. Each case relaunches instead.
        continueAfterFailure = false
        // The simulator keeps its orientation across app launches and smoke
        // runs. Each case starts in the phone layout it makes assertions about.
        MainActor.assumeIsolated {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    // MARK: - The screen tour

    /// Keeps primary terminal actions visible at phone width without overlapping touch targets.
    ///
    /// The system toolbar sizes each item, so what is held is that every item
    /// is on screen, hittable and clear of its neighbour, not a frame size the
    /// toolbar does not promise.
    func testPrimaryTerminalToolsFitWithoutOverflow() {
        _ = openTerminal()
        // More is the system's overflow menu, found by its label.
        let controls =
            ["terminal-leave", "terminal-tabs", "terminal-keyboard", "terminal-dictate"]
            .map { app.descendants(matching: .any)[$0].firstMatch }
            + [app.toolbars.buttons["More"].firstMatch]
        var previous: CGRect?
        for (index, button) in controls.enumerated() {
            let identifier = ["Back", "tabs", "keyboard", "dictation", "More"][index]
            XCTAssertTrue(button.waitForExistence(timeout: 5) && button.isHittable, "\(identifier) is not directly available")
            let frame = button.frame
            if let previous { XCTAssertGreaterThanOrEqual(frame.minX, previous.maxX - 0.5, "primary controls overlap") }
            previous = frame
        }
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picture.name = "terminal-primary-tools-\(Int(app.frame.width))pt"
        picture.lifetime = .keepAlways
        add(picture)
    }

    /// Walks every screen a person reaches on an iPhone and keeps a picture of
    /// each, for a review of the interface as it is rather than as it is
    /// remembered.
    ///
    /// Not an assertion about any screen: the pictures are the product, and a
    /// case that failed on one screen would leave the later ones untaken. Each
    /// is written under the runner's temporary directory, whose path the case
    /// prints — as a file rather than a result-bundle attachment, which costs
    /// the simulator a minute a picture.
    func testScreenTourKeepsAPictureOfEveryScreen() throws {
        try walkTheScreenTour(into: "ubq-tour")
    }

    /// The same tour at the largest accessibility text size, where a row of
    /// fixed height clips and a bar that cannot wrap loses its labels.
    func testScreenTourAtTheLargestTextSize() throws {
        // The host is added at the reading size: the tour is a picture of
        // each screen, and the editor's own pass at this size is its picture.
        app.launch()
        if !hostRow.waitForExistence(timeout: 5) { addTheTestHost() }
        app.terminate()
        try walkTheScreenTour(
            into: "ubq-tour-ax3",
            arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        )
    }

    /// Sheets finish, cancel and close by their system roles, where the
    /// system puts them: Cancel and Close are the system's glyph, leading,
    /// and a verb that starts an operation trails in its word.
    ///
    /// A glyph button in a bar is a circle as tall as it is wide; a word is
    /// wider than it is tall.
    func testSheetsUseTheSystemRoles() {
        app.launch()
        app.buttons["Add Host"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Host"].waitForExistence(timeout: 5))
        let cancel = cancelButton
        let save = saveButton
        XCTAssertTrue(cancel.exists && save.exists, "the editor's sheet buttons are not Cancel and Save")
        XCTAssertLessThan(cancel.frame.width, cancel.frame.height * 1.2, "Cancel is a word, not the system's glyph")
        XCTAssertLessThan(cancel.frame.midX, save.frame.midX, "Cancel does not lead")
        cancel.tap()

        _ = openTerminal()
        openTheOverflowMenu()
        app.buttons["Settings"].tap()
        let close = app.navigationBars["Settings"].buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Settings has no Close in its own bar")
        XCTAssertLessThan(close.frame.width, close.frame.height * 1.2, "Close is a word, not the system's glyph")
        XCTAssertFalse(app.navigationBars["Settings"].buttons["Done"].exists, "Settings, which saves as it goes, offers Done")
        close.tap()
    }

    /// The host editor finishes and cancels with the system's own buttons,
    /// where the system puts them: Cancel leading, Save trailing, each
    /// spoken by name.
    func testTheHostEditorConfirmsAndCancelsWithSystemButtons() {
        app.launch()
        app.buttons["Add Host"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Host"].waitForExistence(timeout: 5))
        let cancel = cancelButton
        let save = saveButton
        XCTAssertTrue(
            cancel.exists && save.exists,
            "the editor's sheet buttons are not the system's cancel and confirm. On screen instead:\n"
                + app.navigationBars["New Host"].debugDescription
        )
        XCTAssertLessThan(cancel.frame.midX, save.frame.midX, "Cancel does not lead")
        cancel.tap()
    }

    private func walkTheScreenTour(into directory: String, arguments: [String] = []) throws {
        let tour = FileManager.default.temporaryDirectory.appendingPathComponent(directory, isDirectory: true)
        try? FileManager.default.removeItem(at: tour)
        try FileManager.default.createDirectory(at: tour, withIntermediateDirectories: true)
        print("ubq-tour: \(tour.path)")
        func keep(_ name: String) {
            // A sheet is found as soon as it is presented, and it is still
            // fading its content in: a picture taken then shows a half-drawn
            // screen nobody sees.
            Thread.sleep(forTimeInterval: 0.8)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: tour.appendingPathComponent(name + ".png"))
        }

        // A device that has never saved a host shows the empty list first.
        let plain = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        plain.launchArguments = arguments
        plain.launch()
        if plain.staticTexts["No Hosts"].waitForExistence(timeout: 3) {
            keep("00-host-list-empty")
        }
        plain.terminate()

        let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        seeded.launchArguments = ["--seed-host-sessions"] + arguments
        seeded.launch()
        _ = hostRow.waitForExistence(timeout: 5)
        keep("01-host-list")

        let search = app.searchFields["Search Hosts"]
        if !search.exists { app.buttons["Search"].firstMatch.tap() }
        if search.waitForExistence(timeout: 5) {
            keep("01a-host-search")
        }
        // Relaunched rather than dismissed, so the rest of the tour starts
        // from the list as a person first sees it.
        seeded.terminate()
        seeded.launch()
        _ = hostRow.waitForExistence(timeout: 5)

        app.buttons["Add Host"].firstMatch.tap()
        if app.navigationBars["New Host"].waitForExistence(timeout: 5) {
            keep("02-host-editor-empty")
            app.textFields["Address"].tap()
            keep("03-host-editor-keyboard")
            putTheKeyboardAway()
            cancelButton.tap()
        }
        if !hostRow.waitForExistence(timeout: 5) {
            addTheTestHost()
        }
        hostRow.swipeLeft()
        keep("04-host-row-actions")
        // The editor can already be open after the row action is revealed.
        if !app.navigationBars["Edit Host"].exists {
            app.buttons["Edit"].firstMatch.tap()
        }
        if app.navigationBars["Edit Host"].waitForExistence(timeout: 5) {
            keep("05-host-editor-filled")
            cancelButton.tap()
        }
        settle(hostRow, workspace: "")
        hostRow.tap()
        answerThePasswordPromptIfItAppears()
        if workspacesScreen.waitForExistence(timeout: 15) {
            keep("06-session-list")
            let workspaceRow = outlineRow(Self.scratchRow)
            if workspaceRow.waitForExistence(timeout: 5) {
                workspaceRow.swipeLeft()
                keep("07-session-row-actions")
                workspaceRow.swipeRight()
                workspaceRow.tap()
            }
        }
        if app.otherElements["terminal-surface"].waitForExistence(timeout: 15) {
            if unreachedPickAlert.waitForExistence(timeout: 10) {
                keep("08a-unreached-pick")
                unreachedPickAlert.buttons["Open Login Shell"].tap()
                _ = unreachedPickAlert.waitForNonExistence(timeout: 5)
                _ = app.buttons["Try Again"].waitForExistence(timeout: 10)
            }
            keep("08-terminal")
            app.buttons["terminal-keyboard"].tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
                keep("09-terminal-keyboard")
                // iPhone's key row; iPad keeps these keys in the keyboard's
                // shortcuts bar, whose fn is a menu.
                if app.otherElements["terminal-key-row"].exists {
                    app.buttons["terminal-function-keys"].tap()
                    keep("09a-terminal-keyboard-function-keys")
                    app.buttons["terminal-function-keys"].tap()
                }
                let control = app.buttons["terminal-modifier-Ctrl"]
                if control.exists {
                    control.tap()
                    control.tap()
                    keep("09b-terminal-keyboard-control-locked")
                    control.tap()
                }
                putTheTerminalKeyboardAway()
                _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
            }
            // A wide window has no centre Tabs button; its tab strip and title
            // menu open the overview instead.
            let tabs = app.buttons["terminal-tabs"]
            if tabs.waitForExistence(timeout: 2) { tabs.tap() }
            if tabOverviewNavigationBar.waitForExistence(timeout: 5) {
                keep("10-tab-overview")
                app.buttons["tab-overview-done"].tap()
            }
            openTheOverflowMenu()
            keep("11-overflow-menu")
            let settings = app.buttons["Settings"]
            revealInTheMenu(settings)
            settings.tap()
            if app.navigationBars["Settings"].waitForExistence(timeout: 5) {
                keep("12-settings")
                dismissSheet()
            }
            openTheOverflowMenu()
            let files = filesMenuItem
            revealInTheMenu(files)
            _ = files.waitForExistence(timeout: 2)
            files.tap()
            if app.navigationBars["Files"].waitForExistence(timeout: 5) {
                keep("13-files")
                dismissSheet()
            }
            XCUIDevice.shared.orientation = .landscapeLeft
            defer { XCUIDevice.shared.orientation = .portrait }
            _ = app.otherElements["terminal-surface"].waitForExistence(timeout: 5)
            keep("14-terminal-landscape")
            // A short window keeps the bar away until a tap on the grid asks.
            revealTheBottomBar()
            keep("14a-terminal-landscape-bar")
            app.buttons["terminal-keyboard"].tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
                keep("15-terminal-landscape-keyboard")
                putTheTerminalKeyboardAway()
            }
        }
    }

    // MARK: - The cases

    /// Keeps a saved host's row to its name, address and state, without implying a live connection.
    func testSavedHostsShowAddressAndSearchEmptyState() {
        app.launch()
        if !hostRow.waitForExistence(timeout: 5) {
            addTheTestHost()
        }
        edit(hostRow, port: 1, prefersQUIC: false)
        XCTAssertTrue(app.staticTexts["Saved Hosts"].exists)
        XCTAssertEqual(hostRow.value as? String, "Saved host")
        XCTAssertTrue(hostRow.label.contains("ui@127.0.0.1:1"))
        XCTAssertFalse(hostRow.label.contains("Password"), "the row repeats the editor's authentication setting")
        XCTAssertFalse(hostRow.label.contains("Automatic"), "the row repeats the editor's authentication setting")
        XCTAssertFalse(hostRow.label.contains("Host key"), "the row repeats the editor's host-key setting")
        XCTAssertFalse(hostRow.label.contains("Connected"), "a saved record is presented as a live connection")

        let query = "no-host-" + UUID().uuidString
        let search = app.searchFields["Search Hosts"]
        // The search item minimizes to a button in the toolbar until it is tapped.
        if !search.exists {
            let item = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", "Search", "Search")).firstMatch
            if item.waitForExistence(timeout: 3) { item.tap() }
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the host list has no search field")
        search.tap()
        search.typeText(query)
        XCTAssertFalse(hostRow.exists)
        let explanation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", query)).firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 5), "an empty search has no explanation")
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: query.count))
        XCTAssertTrue(hostRow.waitForExistence(timeout: 5), "clearing search did not restore the saved hosts")
    }

    /// Returns to a real retained QUIC connection without presenting it as only a saved address.
    func testHostsIdentifyTheRetainedOpenConnection() throws {
        _ = try attachSeededLiveQUICSurface()
        leaveTheTerminalForTheHostList()
        let live = hostRow(named: Self.liveHostName)
        XCTAssertTrue(
            live.waitForExistence(timeout: 10),
            "the host list did not show the live host after leaving its terminal. On screen instead:\n"
                + app.debugDescription
        )
        let connected = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "Connected over QUIC"),
            evaluatedWith: live
        )
        wait(for: [connected], timeout: 30)
        XCTAssertTrue(app.staticTexts["Open Connections"].exists)
        XCTAssertEqual(live.value as? String, "Open connection")
        XCTAssertTrue(live.label.contains("Connected over QUIC"), "the row does not expose its actual carrier state")
    }

    /// Verifies essential tools can be reached without learning a gesture.
    func testTerminalToolsAreVisible() {
        _ = openTerminal()
        let tabs = app.buttons["terminal-tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 10), "the bar has no Tabs button")
        XCTAssertEqual(tabs.label, "Show All Tabs")
        XCTAssertGreaterThanOrEqual(tabs.frame.width, 44)
        XCTAssertGreaterThanOrEqual(tabs.frame.height, 44)
        XCTAssertTrue(app.buttons["terminal-leave"].isHittable, "the bar has no way back")
        XCTAssertTrue(app.toolbars.buttons["More"].exists, "the More menu left the bar")
        XCTAssertTrue(app.buttons["terminal-dictate"].isHittable, "dictation is not directly reachable from the bar")
        XCTAssertEqual(
            app.toolbars.buttons.matching(NSPredicate(format: "label == %@", "More")).count,
            1,
            "a second overflow menu appeared"
        )
        tabs.tap()
        XCTAssertTrue(tabOverviewNavigationBar.waitForExistence(timeout: 5), "Tabs does not open the overview")
        app.buttons["tab-overview-done"].tap()
        openTheOverflowMenu()
        XCTAssertTrue(filesMenuItem.exists, "the More menu lost Files")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        dismissSheet()
        app.buttons["terminal-keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["terminal-hide-keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    /// The tab overview draws each tab as a card named by Core, and a rename,
    /// a reorder and a close each change the cards; a tap on a card goes back
    /// to the terminal on that tab.
    ///
    /// Against the seeded workspace, whose requests the model answers itself:
    /// what is pinned is the overview, not the host's side of a request.
    func testTheTabOverviewRenamesReordersAndClosesTabs() {
        let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        seeded.launchArguments = ["--seed-workspace"]
        seeded.launch()
        if !hostRow.waitForExistence(timeout: 5) {
            addTheTestHost()
        }
        hostRow.tap()
        XCTAssertTrue(seededTerminal.waitForExistence(timeout: 15), "the terminal never appeared")
        let tabsButton = app.buttons["terminal-tabs"]
        if tabsButton.exists {
            XCTAssertEqual(tabsButton.value as? String, "Tab 1 of 3, pane 1 of 2")
            seededTerminal.swipeLeft()
            XCTAssertTrue(waitUntil(timeout: 5) { tabsButton.value as? String == "Tab 1 of 3, pane 2 of 2" })
            seededTerminal.swipeRight()
            XCTAssertTrue(waitUntil(timeout: 5) { tabsButton.value as? String == "Tab 1 of 3, pane 1 of 2" })
        }
        openTabsAndPanes()
        XCTAssertTrue(tabOverviewNavigationBar.waitForExistence(timeout: 5), "the overview did not open")
        XCTAssertTrue(app.navigationBars["3 Tabs"].exists, "the overview title does not count its tabs")
        let first = app.descendants(matching: .any)["tab-card-101"]
        let second = app.descendants(matching: .any)["tab-card-102"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { first.label.contains("vim") }, "the first tab is not named by its program: \(first.label)")
        XCTAssertTrue(first.label.hasPrefix("Tab 1 of 3"), "the card does not say where it stands: \(first.label)")
        XCTAssertTrue(first.label.contains("2 panes"), "the card does not count its panes: \(first.label)")
        XCTAssertTrue(first.isSelected, "the focused tab's card is not marked")
        keepCapture("tab-overview")

        second.tap()
        XCTAssertTrue(tabOverviewNavigationBar.waitForNonExistence(timeout: 5))
        if tabsButton.exists { XCTAssertEqual(tabsButton.value as? String, "Tab 2 of 3") }
        openTabsAndPanes()
        XCTAssertTrue(tabOverviewNavigationBar.waitForExistence(timeout: 5))

        second.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Rename Tab…"].waitForExistence(timeout: 5), "the card has no context menu")
        XCTAssertFalse(app.buttons["Move Tab Earlier"].exists, "drag reordering has a redundant menu item")
        XCTAssertFalse(app.buttons["Move Tab Later"].exists, "drag reordering has a redundant menu item")
        keepCapture("tab-overview-menu")
        app.buttons["Rename Tab…"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("monitor")
        app.buttons["Rename"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { second.label.contains("monitor") }, "the rename did not reach the card: \(second.label)")

        app.buttons["tab-card-close-103"].tap()
        XCTAssertTrue(app.buttons["Terminate"].waitForExistence(timeout: 5), "closing a tab did not ask first")
        app.buttons["Terminate"].tap()
        XCTAssertTrue(app.staticTexts["2 Tabs"].waitForExistence(timeout: 5), "the closed tab's card stayed")

        // Native reordering chooses before or after from the drop position.
        // The card's midpoint does not specify an earlier insertion.
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.15)))
        XCTAssertTrue(
            waitUntil(timeout: 5) { second.label.hasPrefix("Tab 1 of 2") },
            "dragging the tab earlier did not move its card: \(second.label)"
        )

        second.tap()
        XCTAssertTrue(tabOverviewNavigationBar.waitForNonExistence(timeout: 5), "a tap on a card did not go back to the terminal")
        XCTAssertTrue(seededTerminal.waitForExistence(timeout: 5))
        if tabsButton.exists { XCTAssertEqual(tabsButton.value as? String, "Tab 1 of 2") }
        if app.buttons["tab-strip-new-tab"].exists { keepCapture("tab-strip") }
    }

    /// Hardware close shortcuts ask about a pane or tab instead of closing the app window.
    func testWorkspaceKeyboardShortcutsConfirmTheIntendedScope() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Hardware-keyboard automation requires iPad.")
        let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        seeded.launchArguments = ["--seed-workspace"]
        seeded.launch()
        if !hostRow.waitForExistence(timeout: 5) { addTheTestHost() }
        hostRow.tap()
        XCTAssertTrue(seededTerminal.waitForExistence(timeout: 15))
        seededTerminal.tap()
        seeded.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Terminate"].waitForExistence(timeout: 5), "Command-W did not ask before closing the pane")
        XCTAssertTrue(app.staticTexts["Do you want to terminate running processes in this pane?"].exists)
        dismissTheConfirmation()
        XCTAssertTrue(app.buttons["Terminate"].waitForNonExistence(timeout: 5), "canceling left the pane confirmation open")
        XCTAssertTrue(seededTerminal.exists, "canceling the close lost the terminal")
        seeded.typeKey("w", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["Terminate"].waitForExistence(timeout: 5), "Command-Shift-W did not ask before closing the tab")
        XCTAssertTrue(app.staticTexts["Do you want to terminate running processes in this tab?"].exists, app.debugDescription)
        app.buttons["Terminate"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "closing restored a hidden keyboard")
        openTabsAndPanes()
        XCTAssertTrue(
            app.staticTexts["2 Tabs"].waitForExistence(timeout: 5),
            "the shortcut did not close exactly one tab:\n" + app.debugDescription
        )
    }

    /// The seeded workspace's grid: one pane at compact width, and at regular
    /// width the pair a wide window shows, each named for its pane. The seed
    /// asks for no password, since it stands in for the host before any
    /// credential is used.
    private var seededTerminal: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal-surface")).firstMatch
    }

    /// Find in Scrollback searches the focused pane, counts in Core's words,
    /// steps through the matches both ways, and goes away with Done.
    ///
    /// Against the seeded workspace, whose first pane shows a page of notes
    /// with "notes" on two of its rows.
    func testFindInScrollbackCountsAndStepsThroughMatches() {
        let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        seeded.launchArguments = ["--seed-workspace"]
        seeded.launch()
        if !hostRow.waitForExistence(timeout: 5) {
            addTheTestHost()
        }
        hostRow.tap()
        XCTAssertTrue(seededTerminal.waitForExistence(timeout: 15), "the terminal never appeared")
        openTheOverflowMenu()
        let find = findMenuItem
        XCTAssertTrue(find.waitForExistence(timeout: 5), "More offers no Find in Scrollback:\n" + app.debugDescription)
        find.tap()
        let field = app.textFields["find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the find bar did not come up")
        field.typeText("notes")
        let counter = app.staticTexts["find-counter"]
        XCTAssertTrue(waitUntil(timeout: 5) { counter.exists && counter.label.hasSuffix(" of 2") }, "the counter did not count two matches")
        let landed = counter.label
        keepCapture("find-in-scrollback")
        app.buttons["find-previous"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { counter.label != landed }, "Previous Match did not move: \(counter.label)")
        app.buttons["find-next"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { counter.label == landed }, "Next Match did not come back: \(counter.label)")
        field.typeText("zzz")
        XCTAssertTrue(waitUntil(timeout: 5) { counter.label == "No matches" }, "a query with no match said \(counter.label)")
        app.buttons["find-done"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Done left the find bar up")
    }

    /// A hold that selects shows the system loupe on the row under the
    /// finger, and the selection it makes is still offered to copy.
    ///
    /// The loupe is the system's and stays out of the accessibility tree, and
    /// a synthesised finger holds this runner until it lifts, so the case reads
    /// the record the UI-test build keeps of the loupe: the system began one
    /// session, closed it on the lift, and last tracked a caret on the row the
    /// finger lifted from, at the finger. Against the seeded workspace, whose
    /// first pane opens with a page of notes, so the drag crosses text.
    ///
    /// Shown able to fail by leaving the hold's loupe calls out: no record
    /// came up and the first assertion on it reddened.
    func testAHoldShowsTheLoupeAndStillSelects() {
        let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        seeded.launchArguments = ["--seed-workspace"]
        seeded.launch()
        if !hostRow.waitForExistence(timeout: 5) {
            addTheTestHost()
        }
        hostRow.tap()
        let surface = seededTerminal
        XCTAssertTrue(surface.waitForExistence(timeout: 15), "the terminal never appeared")
        XCTAssertTrue(
            waitUntil(timeout: 5) { self.gridText(surface).contains("Release notes") },
            "the seeded notes never drew, so the hold would select nothing. The grid read: \(gridText(surface))"
        )
        let record = app.otherElements["terminal-selection-loupe"]
        XCTAssertFalse(record.exists, "a loupe was recorded before any hold, so this case would assert nothing")

        // The surface runs under the status bar, and the notes fill its
        // first nine rows below the top inset. Starting a hundred and twenty
        // points down and ending two hundred down lands both ends inside them
        // whatever the device's safe area and the font's row height, so the
        // drag crosses text without this case knowing the grid's geometry.
        let origin = surface.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: 40, dy: 120))
        let to = origin.withOffset(CGVector(dx: 160, dy: 200))
        from.press(forDuration: 1.2, thenDragTo: to)

        XCTAssertTrue(record.waitForExistence(timeout: 5), "a hold that selected kept no record of a loupe")
        let reading = (record.value as? String) ?? ""
        XCTAssertTrue(reading.hasPrefix("begun 1, open no, caret "), "the loupe did not open once and close on the lift: \(reading)")
        let numbers = reading.components(separatedBy: "caret ").last?.split(separator: " ").compactMap { Double($0) } ?? []
        XCTAssertEqual(numbers.count, 4, "the record named no caret: \(reading)")
        if numbers.count == 4 {
            let caret = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            let lift = to.screenPoint
            XCTAssertGreaterThan(caret.height, 0, "the loupe tracked a caret with no height: \(reading)")
            XCTAssertTrue(
                caret.minY <= lift.y && lift.y < caret.maxY && abs(caret.minX - lift.x) < 4,
                "the loupe last tracked \(caret), not the row under the finger that lifted at \(lift)"
            )
        }
        let copy = app.menuItems["Copy"].exists ? app.menuItems["Copy"] : app.buttons["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the hold that showed the loupe selected nothing to copy")
    }

    /// Writes a picture of the screen under the runner's temporary directory,
    /// for the review captures; the path is printed so a run can collect it.
    private func keepCapture(_ name: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ubq-captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name + ".png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: file)
        print("ubq-capture: \(file.path)")
    }

    /// A failed connection says why on screen, in the product's words,
    /// without a sheet, and can be put away.
    func testAFailedConnectionShowsItsCause() {
        _ = openTerminal()
        let cause = app.staticTexts["terminal-failure-cause"]
        XCTAssertTrue(cause.waitForExistence(timeout: 20), "the failure shows no cause:\n" + app.debugDescription)
        XCTAssertTrue(cause.label.contains("refused the connection"), "the cause is not the refusal: \(cause.label)")
        XCTAssertFalse(cause.label.contains("Connection Details"), "the banner still sends the reader to a sheet")
        XCTAssertTrue(app.buttons["Try Again"].exists, "the banner offers no way to try again")
        app.buttons["terminal-failure-dismiss"].tap()
        XCTAssertTrue(cause.waitForNonExistence(timeout: 5), "Dismiss left the banner up")
    }

    /// Dictation opens from the bar on its own, with no keyboard in the way.
    ///
    /// The way a person talks to a program on the host: the bar comes up
    /// without the keyboard, carries a Send that puts the Return after the
    /// last spoken phrase, and closes from its own button. Offline, so the
    /// microphone is never asked for; what is pinned is the bar, not speech.
    func testDictationOpensWithoutTheKeyboard() {
        _ = openTerminal()
        XCTAssertFalse(app.buttons["terminal-dictation-send"].exists, "the dictation bar was up before it was asked for")

        let dictate = app.buttons["terminal-dictate"]
        XCTAssertTrue(dictate.isHittable, "dictation requires opening a menu")
        XCTAssertGreaterThanOrEqual(dictate.frame.width, 44)
        XCTAssertGreaterThanOrEqual(dictate.frame.height, 44)
        dictate.tap()

        XCTAssertTrue(
            app.buttons["terminal-dictation-send"].waitForExistence(timeout: 5),
            "the Dictate button did not open the dictation bar. On screen:\n" + app.debugDescription
        )
        XCTAssertFalse(app.keyboards.firstMatch.exists, "opening dictation summoned the keyboard")
        XCTAssertTrue(app.buttons["terminal-dictation-close"].exists, "a bar without the keyboard has no way to close")
        XCTAssertFalse(app.buttons["terminal-hide-keyboard"].exists, "a bar without the keyboard offered to hide one")

        app.buttons["terminal-dictation-close"].tap()
        XCTAssertTrue(app.buttons["terminal-dictation-send"].waitForNonExistence(timeout: 5), "closing the bar left it up")

        for _ in 0..<2 {
            app.buttons["terminal-keyboard"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let accessoryMicrophone = app.buttons["terminal-keyboard-dictate"]
            let microphone = accessoryMicrophone.waitForExistence(timeout: 2) ? accessoryMicrophone : dictate
            XCTAssertTrue(microphone.isHittable)
            XCTAssertGreaterThanOrEqual(microphone.frame.width, 44)
            XCTAssertGreaterThanOrEqual(microphone.frame.height, 44)
            microphone.tap()
            XCTAssertTrue(app.buttons["terminal-dictation-send"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "dictation left the keyboard covering the terminal")
        }
        app.buttons["terminal-dictation-close"].tap()
    }

    /// A short window gives the grid the bar's rows, and a tap brings the bar
    /// back.
    ///
    /// Landscape on a phone is the short window: the bar there costs a sixth
    /// of the grid. The bar must be gone, and one tap on the grid must bring
    /// it back with the keyboard button in it, or the keyboard is out of reach.
    ///
    /// Shown able to fail with the bar kept in landscape.
    func testAShortWindowGivesTheGridTheBarsRows() {
        let surface = openTerminal()
        XCTAssertTrue(app.buttons["terminal-keyboard"].waitForExistence(timeout: 5), "portrait lost the bar")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(
            app.buttons["terminal-keyboard"].waitForNonExistence(timeout: 5),
            "the bar stayed in landscape, over a sixth of the grid"
        )
        surface.tap()
        XCTAssertTrue(
            app.buttons["terminal-keyboard"].waitForExistence(timeout: 5),
            "a tap on the grid did not bring the bar back"
        )
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the tap that brought the bar back also raised the keyboard")
    }

    /// The More menu offers only what can be done, and Files is in it once.
    ///
    /// With nothing selected Copy Selection has nothing to copy, so it is
    /// dimmed; and Files lives in the menu alone, not also on the bar.
    ///
    /// Shown able to fail with Copy Selection enabled while nothing is
    /// selected, and with Files on the bar as well as in the menu.
    func testTheMoreMenuOffersOnlyWhatCanBeDone() {
        _ = openTerminal()
        XCTAssertTrue(app.toolbars.buttons["More"].waitForExistence(timeout: 10), "the bar has no More menu")
        XCTAssertFalse(
            app.toolbars.buttons["Files"].firstMatch.exists,
            "Files is on the bar as well as in the More menu"
        )
        openTheOverflowMenu()
        let copy = app.buttons["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the More menu offers no Copy")
        XCTAssertFalse(copy.isEnabled, "Copy is offered with nothing selected")
        XCTAssertTrue(filesMenuItem.exists, "the More menu lost its Files entry")
    }

    /// Verifies the file screen explains when its host channel is unavailable.
    func testTerminalFilesUseANativeSheet() {
        _ = openTerminal()
        openTheOverflowMenu()
        // The system redraws the overflow's items for a vertical bar and drops
        // their identifiers there, so the item is found by its title when the
        // identifier is gone. A vertical bar also carries a Files button of its
        // own, and a tap on it while the menu is open only closes the menu, so
        // the item taken is the one that is not the bar's.
        let identified = filesMenuItem
        let item: XCUIElement
        if identified.waitForExistence(timeout: 2) {
            item = identified
        } else {
            let titled = app.buttons.matching(NSPredicate(format: "label == %@", "Files"))
            let barButton = app.toolbars.buttons["Files"].firstMatch
            let barFrame = barButton.exists ? barButton.frame : .null
            item = (0..<titled.count).map { titled.element(boundBy: $0) }.first { $0.frame != barFrame } ?? titled.firstMatch
        }
        item.tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["File Transfer Unavailable"].exists)
        dismissSheet()
        XCTAssertTrue(app.otherElements["terminal-surface"].exists)
    }

    /// A change of width class keeps the terminal as it was.
    ///
    /// An iPhone that unfolds, a large iPhone turned sideways and a resized
    /// iPad window all move the app between compact and regular width under a
    /// live terminal. A layout rebuilt on that change takes the screen's state
    /// with it — the keyboard drops, an open sheet closes, and a permission
    /// request is dismissed mid-read — so what is asserted is that each is
    /// still there on the far side of the change, in both directions.
    ///
    /// Turning the device is the one width change XCUITest can drive, and it
    /// changes the width class only on a device whose landscape width is
    /// regular. On one that stays compact the case reports itself skipped:
    /// nothing it asserts would have been exercised. `UBQ_IOS_DEVICE_TYPE`
    /// picks the model Scripts/ios-simulator.sh makes the device as. The
    /// expanded split view is how the change is recognised — its host list
    /// stands beside the terminal.
    func testAWidthClassChangeKeepsTheTerminalAsItWas() throws {
        _ = openTerminal()
        defer { XCUIDevice.shared.orientation = .portrait }

        app.buttons["terminal-keyboard"].tap()
        XCTAssertTrue(app.buttons["terminal-key-Escape"].waitForExistence(timeout: 5))

        XCUIDevice.shared.orientation = .landscapeLeft
        guard app.navigationBars["Hosts"].waitForExistence(timeout: 5) else {
            throw XCTSkip(
                "this device keeps a compact width in landscape; set UBQ_IOS_DEVICE_TYPE to a Pro Max or Plus model"
            )
        }
        XCTAssertTrue(app.otherElements["terminal-surface"].exists, "widening the window lost the terminal")
        XCTAssertTrue(app.buttons["terminal-key-Escape"].exists, "widening the window dropped the keyboard")

        app.buttons["terminal-hide-keyboard"].tap()
        openTheOverflowMenu()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(
            app.navigationBars["Hosts"].waitForNonExistence(timeout: 5),
            "the window did not return to a compact width"
        )
        XCTAssertTrue(app.navigationBars["Settings"].exists, "narrowing the window closed the open sheet")
        dismissSheet()
        XCTAssertTrue(app.otherElements["terminal-surface"].exists, "narrowing the window lost the terminal")
    }

    /// A two-finger tap on the terminal opens the settings sheet.
    ///
    /// The gesture the item claimed, driven with two real touches. What is
    /// asserted is the sheet, not a flag the app set for the test: a recogniser
    /// that fired and reached nothing is the failure this exists to catch.
    func testATwoFingerTapOpensSettings() {
        let surface = openTerminal()
        XCTAssertFalse(settingsIsUp, "settings was already up before the gesture")

        twoFingerTap(on: surface)

        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 5),
            "a two-finger tap did not open settings"
        )
    }

    /// The font picker opens over settings and leaves back to it.
    ///
    /// It was a sheet asked for from inside the settings sheet, and that
    /// collapsed settings instead of standing over it: a tap on Font left
    /// the person on the bare terminal. It is pushed on the settings stack
    /// now, so both halves are pinned — the picker arrives, and going back
    /// lands on settings.
    func testTheFontPickerOpensOverSettingsAndLeavesBackToIt() {
        let surface = openTerminal()
        twoFingerTap(on: surface)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "settings did not open")

        app.buttons["terminal-font-picker"].firstMatch.tap()
        let picker = app.navigationBars["Font"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the font picker did not open. On screen:\n" + app.debugDescription)
        picker.buttons.firstMatch.tap()

        XCTAssertTrue(picker.waitForNonExistence(timeout: 5), "the font picker stayed up")
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 2),
            "leaving the font picker left settings too. On screen:\n" + app.debugDescription
        )
    }

    /// Settings is available before a terminal exists and keeps connection facts out of preferences.
    func testAppSettingsOpensBeforeConnecting() {
        app.launch()
        let open = app.buttons["app-settings"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Protocol"].exists)
        let follow = app.switches["Match System Appearance"]
        XCTAssertTrue(follow.exists)
        let wasEnabled = follow.value as? String == "1"
        set(follow, on: true)
        app.buttons["terminal-theme-picker-Light Theme"].tap()
        XCTAssertTrue(app.navigationBars["Light Theme"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "theme-choice-")).firstMatch.exists)
        app.navigationBars["Light Theme"].buttons["Settings"].tap()
        set(follow, on: wasEnabled)
        let spacing = app.steppers["terminal-line-spacing"]
        revealInTheForm(spacing)
        XCTAssertTrue(spacing.isHittable, "line spacing is not available beside the font size")
        let before = spacing.label
        spacing.buttons["terminal-line-spacing-Increment"].tap()
        XCTAssertNotEqual(spacing.label, before, "line spacing did not change")
        spacing.buttons["terminal-line-spacing-Decrement"].tap()
    }

    /// Title components are editable without connecting and persist across launches.
    func testSessionTitleComponentsPersist() {
        func openTitleSettings() {
            app.buttons["app-settings"].tap()
            let titles = app.buttons["session-title-settings"]
            revealInTheForm(titles)
            titles.tap()
            XCTAssertTrue(app.navigationBars["Session Titles"].waitForExistence(timeout: 5))
        }
        app.launch()
        openTitleSettings()
        let folder = app.switches["session-title-folder"]
        let wasEnabled = folder.value as? String == "1"
        set(folder, on: true)
        XCTAssertTrue(app.buttons["session-title-folder-format"].exists)
        set(folder, on: false)
        XCTAssertFalse(app.buttons["session-title-folder-format"].exists)
        XCTAssertTrue(app.switches["session-title-program"].exists)
        XCTAssertTrue(app.switches["session-title-process"].exists)
        app.terminate()
        app.launch()
        openTitleSettings()
        XCTAssertEqual(folder.value as? String, "0")
        set(folder, on: wasEnabled)
    }

    /// A retained workspace restores both its view and keyboard sizing on every visit.
    func testReturningToAWorkspaceRestoresKeyboardSizing() {
        let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        seeded.launchArguments = ["--seed-workspace"]
        seeded.launch()
        if !hostRow.waitForExistence(timeout: 5) { addTheTestHost() }
        for visit in 0..<3 {
            hostRow.tap()
            XCTAssertTrue(seededTerminal.waitForExistence(timeout: 10), "visit \(visit): no terminal")
            let height = seededTerminal.frame.height
            app.buttons["terminal-keyboard"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "visit \(visit): no keyboard")
            XCTAssertTrue(
                waitUntil(timeout: 5) { self.seededTerminal.frame.height < height - 100 },
                "visit \(visit): keyboard did not resize the grid"
            )
            putTheTerminalKeyboardAway()
            XCTAssertTrue(
                waitUntil(timeout: 5) { self.seededTerminal.frame.height > height - 20 },
                "visit \(visit): hiding the keyboard did not restore the grid"
            )
            app.buttons["terminal-leave"].tap()
            let back = app.navigationBars.buttons["Hosts"].firstMatch
            if back.waitForExistence(timeout: 3) { back.tap() }
            XCTAssertTrue(hostRow.waitForExistence(timeout: 5), "visit \(visit): Hosts did not return")
        }
    }

    /// Offline preferences and the range editor remain usable at accessibility sizes.
    func testAppSettingsAtLargeTextAndRangeEditsCanBeDiscarded() throws {
        let application = app
        application.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        application.launch()
        app.buttons["app-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let pictures = FileManager.default.temporaryDirectory.appendingPathComponent("ubq-app-settings", isDirectory: true)
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        Thread.sleep(forTimeInterval: 0.8)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: pictures.appendingPathComponent("large-settings.png"))
        let ranges = app.buttons["Fallback Ranges"]
        revealInTheForm(ranges)
        XCTAssertTrue(ranges.isHittable)
        ranges.tap()
        app.buttons["Add Range"].tap()
        XCTAssertTrue(app.navigationBars["New Font Range"].waitForExistence(timeout: 5))
        let characters = app.textFields["fallback-range"]
        characters.tap()
        characters.typeText("U+2426")
        cancelButton.tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5))
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.navigationBars["Fallback Ranges"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Font Ranges"].exists, "discarding created a font override")
        print("ubq-app-settings: \(pictures.path)")
    }

    /// Native list editing changes the persisted symbols and can restore the default order.
    func testKeyboardSettingsEditSymbolsAndOptionPolicy() {
        app.launch()
        app.buttons["app-settings"].tap()
        let keyboard = app.buttons["Keyboard"]
        revealInTheForm(keyboard)
        keyboard.tap()
        let option = app.switches["Option Sends Meta"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        let wasEnabled = option.value as? String == "1"
        set(option, on: !wasEnabled)
        app.buttons["Accessory Keys"].tap()
        let tilde = app.descendants(matching: .any)["accessory-symbol-Tilde"].firstMatch
        XCTAssertTrue(tilde.waitForExistence(timeout: 5))
        tilde.swipeLeft()
        app.buttons["Delete"].tap()
        let restore = app.buttons["Reset to Default"]
        revealInTheForm(restore)
        XCTAssertTrue(restore.isHittable)
        restore.tap()
        XCTAssertFalse(restore.exists)
        app.navigationBars["Accessory Keys"].buttons["Keyboard"].tap()
        XCTAssertEqual(option.value as? String, wasEnabled ? "0" : "1")
        set(option, on: wasEnabled)
    }

    /// A fallback-size choice remains selected when the settings sheet reopens.
    func testFallbackSizeMatchingSurvivesReopeningSettings() {
        let surface = openTerminal()
        twoFingerTap(on: surface)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let toggle = app.switches["terminal-match-fallback-size"]
        revealInTheForm(toggle)
        XCTAssertTrue(toggle.exists && toggle.isHittable, "fallback sizing is not reachable")
        let wasEnabled = toggle.value as? String == "1"
        set(toggle, on: !wasEnabled)
        cancelButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))
        twoFingerTap(on: surface)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        revealInTheForm(toggle)
        XCTAssertEqual(toggle.value as? String, wasEnabled ? "0" : "1")
        set(toggle, on: wasEnabled)
        cancelButton.tap()
    }

    /// Padding set in Settings moves the drawn grid, and Reset to Default
    /// puts it back.
    ///
    /// Read from pixels: the first ink on screen is the grid's origin as a
    /// reader sees it, which a value read back from the preferences would
    /// report even if no pane re-laid out its grid.
    func testPaddingInSettingsMovesTheGrid() {
        // The seeded workspace draws text without a host to answer.
        let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        seeded.launchArguments = ["--seed-workspace"]
        seeded.launch()
        if !hostRow.waitForExistence(timeout: 5) { addTheTestHost() }
        hostRow.tap()
        let surface = seededTerminal
        XCTAssertTrue(surface.waitForExistence(timeout: 10), "the seeded workspace did not open")
        openPaddingSettings(over: surface)
        if app.buttons["padding-reset"].exists { app.buttons["padding-reset"].tap() }
        let left = app.steppers["padding-left"]
        XCTAssertTrue(left.waitForExistence(timeout: 5) && left.label.contains("4 pt"), "the iOS default is not 4 pt: \(left.label)")
        closePaddingSettings()
        guard let before = waitForInkOrigin(in: surface) else {
            return XCTFail("the terminal drew no text to measure the grid by")
        }
        openPaddingSettings(over: surface)
        let allEdges = app.steppers["padding-all-edges"]
        XCTAssertTrue(allEdges.waitForExistence(timeout: 5), "the padding page has no All Edges control")
        let increment = allEdges.buttons["padding-all-edges-Increment"]
        for _ in 0..<20 { increment.tap() }
        XCTAssertTrue(allEdges.label.contains("24 pt"), "twenty steps from 4 pt did not reach 24 pt: \(allEdges.label)")
        XCTAssertTrue(app.buttons["padding-reset"].waitForExistence(timeout: 5), "a stated padding offers no way back")
        closePaddingSettings()
        guard let after = waitForInkOrigin(in: surface) else { return XCTFail("the padded terminal drew no text") }
        XCTAssertEqual(after.x - before.x, 20, accuracy: 2, "the grid's left edge moved \(after.x - before.x) pt for 20 pt more padding")
        XCTAssertEqual(after.y - before.y, 20, accuracy: 2, "the grid's top edge moved \(after.y - before.y) pt for 20 pt more padding")

        openPaddingSettings(over: surface)
        let reset = app.buttons["padding-reset"]
        revealInTheForm(reset)
        reset.tap()
        XCTAssertTrue(reset.waitForNonExistence(timeout: 5), "Reset to Default left a stated padding")
        closePaddingSettings()
        guard let restored = waitForInkOrigin(in: surface) else { return XCTFail("the reset terminal drew no text") }
        XCTAssertEqual(restored.x, before.x, accuracy: 1, "the default padding did not return the grid's left edge")
        XCTAssertEqual(restored.y, before.y, accuracy: 1, "the default padding did not return the grid's top edge")
    }

    /// Opens Settings over the terminal and goes to the padding page.
    private func openPaddingSettings(over surface: XCUIElement) {
        twoFingerTap(on: surface)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "settings did not open")
        let link = app.buttons["padding-settings"]
        revealInTheForm(link)
        link.tap()
        XCTAssertTrue(app.navigationBars["Padding"].waitForExistence(timeout: 5), "the padding page did not open")
    }

    /// Goes back from the padding page and closes Settings.
    private func closePaddingSettings() {
        app.navigationBars["Padding"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "leaving the padding page left settings")
        cancelButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5), "settings stayed up")
    }

    /// The leftmost and topmost ink inside the surface, in screen points, once
    /// the picture has held still.
    ///
    /// Ink is any point whose luminance differs from the ground's, which is
    /// read at the surface's top-left corner: that point is inside the
    /// padding at every value this suite sets.
    private func waitForInkOrigin(in surface: XCUIElement) -> CGPoint? {
        var previous: CGPoint?
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.6)
            let frame = surface.frame
            let pixels = ScreenPixels(XCUIScreen.main.screenshot(), screen: app.windows.firstMatch.frame)
            let ground = pixels.luminance(at: CGPoint(x: frame.minX + 1, y: frame.minY + 1))
            var origin: CGPoint?
            let rows = stride(from: frame.minY + 1, to: min(frame.maxY, frame.minY + 160), by: 0.5)
            let columns = stride(from: frame.minX + 1, to: min(frame.maxX, frame.minX + 160), by: 0.5)
            for y in rows {
                for x in columns where abs(pixels.luminance(at: CGPoint(x: x, y: y)) - ground) > 0.25 {
                    origin = CGPoint(x: min(origin?.x ?? x, x - frame.minX), y: min(origin?.y ?? y, y - frame.minY))
                    break
                }
            }
            if let origin, origin == previous { return origin }
            previous = origin
        }
        return nil
    }

    /// The bottom bar takes the scheme of the terminal's ground, the ground
    /// reaches the screen's edge around it, and the sheets keep the system's
    /// scheme — on a dark and a light theme, across a switch between them at
    /// run time, and on a screen opened with a light theme already chosen.
    ///
    /// Read from pixels because the scheme is a fact of what is drawn: a
    /// modifier that names the scheme and a bar that ignores it look the same
    /// to the accessibility tree. The system is held light, so a dark ground
    /// is the one that disagrees with it.
    ///
    /// Shown able to fail three ways: with the scheme left to the bar
    /// modifier, the glass on the dark ground read 0.56; with the theme
    /// applied but its snapshot left unpublished, the glass stayed dark
    /// (0.19) after the switch to the light theme; and with the scheme put on
    /// the window instead of the split view, the settings sheet's title was
    /// drawn in the dark scheme on a light system.
    func testTheBottomBarTakesTheGroundsScheme() {
        XCUIDevice.shared.appearance = .light
        let surface = openTerminal()
        chooseTheme("Noir", over: surface)
        assertTheBarAndItsSurroundings(areDark: true, theme: "Noir")
        chooseTheme("Noir Clair", over: surface)
        assertTheBarAndItsSurroundings(areDark: false, theme: "Noir Clair")

        // Opened afresh, the screen reads the ground of the theme the host
        // kept before anything has arrived to redraw it.
        let reopened = openTerminal()
        assertTheBarAndItsSurroundings(areDark: false, theme: "Noir Clair, reopened")

        // The host keeps its theme, and the other cases expect the house one.
        chooseTheme("Noir", over: reopened)
        assertTheBarAndItsSurroundings(areDark: true, theme: "Noir, switched back")
    }

    /// One finger in the same place summons the keyboard.
    ///
    /// The control for the case above, and it asserts what the tap does rather
    /// than what it does not do. That is not a stylistic preference: the
    /// negative form of this case — "a one-finger tap does not open settings" —
    /// was written first and proved unable to fail. A recogniser was installed
    /// that asked for settings on a one-finger tap, and the case still passed,
    /// because the zero-duration selection press claims that touch and cancels
    /// the tap recognisers competing for it. No configuration of this surface
    /// lets one finger reach settings, so asserting that it does not is
    /// satisfied by the platform and says nothing about the code.
    ///
    /// The keyboard is what one finger summons here, it is observable — the
    /// key accessory only exists while the keyboard is up — and breaking the tap
    /// path reddens it.
    func testAOneFingerTapSummonsTheKeyboard() {
        let surface = openTerminal()
        XCTAssertFalse(
            app.buttons["terminal-key-Escape"].exists,
            "the key accessory was up before the tap, so this case would assert nothing"
        )

        surface.tap()

        XCTAssertTrue(
            app.buttons["terminal-key-Escape"].waitForExistence(timeout: 5),
            "a one-finger tap did not summon the keyboard"
        )
    }

    /// A drag on the arrow pad moves a shell's cursor by distance: one arrow
    /// per step of travel, none for holding still.
    ///
    /// The press rests before it moves and again at its end, each longer than
    /// the system keyboard's repeat delay, so a pad that repeated a held arrow
    /// would put the inserted character somewhere else. The shell draws the
    /// line it edits, so where the character lands is the count of arrows
    /// that reached the program, in whatever encoding its modes asked for.
    func testALiveArrowDragMovesTheCursorOneArrowPerStep() throws {
        let surface = try attachSeededLiveQUICSurface()
        XCUIDevice.shared.orientation = .portrait
        surface.tap()
        XCTAssertTrue(
            app.buttons["terminal-key-Escape"].waitForExistence(timeout: 20),
            "the keyboard never came up, so nothing could be typed"
        )
        let up = app.buttons["terminal-key-Up Arrow"]
        XCTAssertTrue(up.waitForExistence(timeout: 5), "the arrow pad is missing")

        app.typeText("echo arrow-0123456789")
        XCTAssertTrue(
            waitForGrid(surface, toShow: "arrow-0123456789", timeout: 15),
            "the typed line never reached the shell. It shows:\n" + gridReport(surface)
        )
        // ArrowPadMetrics.compactStepDistance, an iPhone in portrait. Four and
        // a half steps, so the drag ends between two boundaries.
        let step: CGFloat = 14
        let arrows = 4
        let screen = app.coordinate(withNormalizedOffset: .zero)
        let center = screen.withOffset(CGVector(dx: up.frame.midX, dy: up.frame.maxY))
        let end = center.withOffset(CGVector(dx: -(CGFloat(arrows) + 0.5) * step, dy: 0))
        center.press(forDuration: 0.8, thenDragTo: end, withVelocity: XCUIGestureVelocity(120), thenHoldForDuration: 1.2)
        app.typeText("X\n")
        XCTAssertTrue(
            waitForGrid(surface, toShow: "arrow-012345X6789", timeout: 15),
            "\(arrows) steps of drag did not move the cursor \(arrows) cells. It shows:\n" + gridReport(surface)
        )
    }

    /// Keeps the terminal's keys to one row of caps over the keyboard, with
    /// Tab and dictation one tap away, the function keys
    /// a page of the same row, and modifiers that read their state.
    func testKeyboardAccessoryKeysAndModifiers() {
        _ = openTerminal()
        app.buttons["terminal-keyboard"].tap()
        XCTAssertTrue(app.buttons["terminal-key-Escape"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["terminal-dictation"].exists, "dictation replaced the terminal keys")
        let row = app.otherElements["terminal-key-row"]
        XCTAssertTrue(row.exists, "the key row is missing")
        XCTAssertLessThanOrEqual(row.frame.height, 44.5, "the key row is taller than one row")
        // The fixed controls remain directly reachable. Symbols keep their
        // key size and scroll through the space between those controls.
        for identifier in [
            "terminal-key-Escape", "terminal-key-Tab", "terminal-modifier-Ctrl", "terminal-modifier-Alt", "terminal-function-keys",
            "terminal-keyboard-dictate", "terminal-hide-keyboard", "terminal-key-Tilde",
        ] {
            let key = app.buttons[identifier]
            XCTAssertTrue(key.isHittable, "\(identifier) is not one tap away")
            XCTAssertGreaterThanOrEqual(key.frame.width, 33.5, "\(identifier) is narrower than a keyboard key")
            XCTAssertGreaterThanOrEqual(key.frame.height, 43.5, "\(identifier) has a short touch target")
        }
        for name in ["Slash", "Vertical Bar", "Hyphen"] {
            XCTAssertTrue(app.buttons["terminal-key-\(name)"].exists, "\(name) is missing from the scrolling symbols")
        }
        for name in ["Left Arrow", "Down Arrow", "Up Arrow", "Right Arrow"] {
            XCTAssertTrue(app.buttons["terminal-key-\(name)"].exists, "the arrow pad does not offer \(name)")
        }
        let control = app.buttons["terminal-modifier-Ctrl"]
        XCTAssertEqual(control.label, "Control")
        control.tap()
        XCTAssertEqual(control.value as? String, "Next key")
        control.tap()
        XCTAssertEqual(control.value as? String, "Locked")
        control.tap()
        XCTAssertEqual(control.value as? String, "Off")
        app.buttons["terminal-function-keys"].tap()
        XCTAssertTrue(app.buttons["terminal-modifier-Shift"].waitForExistence(timeout: 2), "the function page has no Shift")
        let shift = app.buttons["terminal-modifier-Shift"]
        shift.tap()
        XCTAssertEqual(shift.value as? String, "Next key")
        app.buttons["terminal-key-Left Arrow"].tap()
        XCTAssertEqual(shift.value as? String, "Off", "Shift + Left did not consume the latched modifier")
        XCTAssertTrue(app.buttons["terminal-key-F1"].isHittable, "F1 is not on the function page")
        for number in 1...12 {
            XCTAssertTrue(app.buttons["terminal-key-F\(number)"].exists, "F\(number) is missing from the function page")
        }
        for name in ["Home", "End", "Page Up", "Page Down"] {
            XCTAssertTrue(app.buttons["terminal-key-\(name)"].exists, "\(name) is missing from the function page")
        }
        XCTAssertLessThanOrEqual(row.frame.height, 44.5, "the function page grew a second row")
        app.buttons["terminal-function-keys"].tap()
        XCTAssertTrue(app.buttons["terminal-key-Tilde"].waitForExistence(timeout: 2), "fn did not return to the symbols")
        app.buttons["terminal-hide-keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    /// The host's Welcome platform decides whether the software keyboard
    /// offers Command; the same row is reached through a real saved host.
    func testCommandAccessoryFollowsTheHostPlatform() {
        _ = openTerminal(arguments: ["--seed-command-host-darwin"])
        app.buttons["terminal-keyboard"].tap()
        let command = app.buttons["terminal-modifier-Cmd"]
        XCTAssertTrue(command.waitForExistence(timeout: 5), "a Darwin host offers Command")
        XCTAssertEqual(command.label, "Command")
        command.tap()
        XCTAssertEqual(command.value as? String, "Next key")
        command.tap()
        XCTAssertEqual(command.value as? String, "Locked")
        command.tap()
        XCTAssertEqual(command.value as? String, "Off")
        app.terminate()

        _ = openTerminal(arguments: ["--seed-command-host-linux"])
        app.buttons["terminal-keyboard"].tap()
        XCTAssertFalse(app.buttons["terminal-modifier-Cmd"].exists, "a Linux host has no Command accessory")
    }

    /// A pinch is two real fingers, and it neither opens settings nor switches
    /// connections.
    ///
    /// This is the two-finger pan recogniser being reached by real touches. A
    /// pinch and the connection swipe both begin as two fingers down and are
    /// told apart by what the fingers do. With one connection open, a pinch
    /// misread as a connection swipe stays on the screen and only says there is
    /// nowhere to go, so the notice is what this watches: no notice at all may
    /// come up.
    ///
    /// Shown able to fail by having the pinch's lift ask for the next
    /// connection: "Only one connection" came up and the notice assertion
    /// reddened.
    func testAPinchIsTwoRealFingersAndSwitchesNothing() {
        let surface = openTerminal()
        XCTAssertFalse(toast.exists, "a notice was already up, so this case would assert nothing")

        surface.pinch(withScale: 2.0, velocity: 1.0)

        XCTAssertFalse(
            watchForAnyToast(timeout: 3),
            "a pinch raised a notice, so it was read as a swipe. On screen instead:\n" + app.debugDescription
        )
        XCTAssertFalse(app.navigationBars["Settings"].exists, "a pinch opened settings")
        XCTAssertTrue(surface.exists, "a pinch left the terminal screen, and a pinch is a zoom")
    }

    /// One finger swiped sideways asks for a pane, reports none available, and
    /// stays on the terminal.
    ///
    /// The suite's host cannot be reached, so its session has no listed panes
    /// — which is what makes the swipe assertable
    /// offline: the gesture must still answer, and the answer is the notice.
    /// Rightward, the direction "back" takes on this platform, so a swipe
    /// that reached the navigation instead would leave the screen.
    ///
    func testAOneFingerSwipeReportsNoAvailablePanesAndStays() {
        let surface = openTerminal()
        XCTAssertFalse(toast.exists, "a notice was already up, so this case would assert nothing")

        surface.swipeRight()

        XCTAssertTrue(
            watchForToast(saying: "No panes available", timeout: 3),
            "a one-finger sideways swipe before any panes were listed never reported that no panes are available, "
                + "so the pane gesture is not reaching the session. On screen instead:\n" + app.debugDescription
        )
        XCTAssertTrue(surface.exists, "a one-finger swipe left the terminal screen")
        XCTAssertFalse(app.navigationBars["Hosts"].exists, "a one-finger swipe went back to the host list")
        XCTAssertTrue(
            toast.waitForNonExistence(timeout: 5),
            "the notice never cleared itself, so it would stand over the grid for good"
        )
    }

    /// Two fingers swiped sideways ask for another connection, say there is
    /// only one, and stay on the terminal.
    ///
    /// The case relaunches the app, so the one terminal it opens is the only
    /// connection open — the condition under which the swipe's answer is the
    /// notice rather than another screen. Leftward and rightward both, because
    /// rightward must not leave the screen.
    ///
    /// Shown able to fail by dropping the connection ask from the two-finger
    /// pan's handler: no notice came up and the first assertion reddened.
    func testATwoFingerSwipeWithOneConnectionSaysSoAndStays() throws {
        let surface = openTerminal()
        XCTAssertFalse(toast.exists, "a notice was already up, so this case would assert nothing")

        try twoFingerSwipe(across: surface, leftward: false)

        XCTAssertTrue(
            watchForToast(saying: "Only one connection", timeout: 3),
            "a two-finger sideways swipe with one connection open never said there is only one, "
                + "so the connection gesture is not reaching the app. On screen instead:\n" + app.debugDescription
        )
        XCTAssertTrue(surface.exists, "a two-finger swipe left the terminal screen")
        XCTAssertFalse(app.navigationBars["Hosts"].exists, "a two-finger swipe went back to the host list")
        XCTAssertFalse(app.navigationBars["Settings"].exists, "a two-finger swipe opened settings, which is the tap's")

        XCTAssertTrue(toast.waitForNonExistence(timeout: 5), "the notice never cleared itself")
        try twoFingerSwipe(across: surface, leftward: true)
        XCTAssertTrue(
            watchForToast(saying: "Only one connection", timeout: 3),
            "a leftward two-finger swipe never said there is only one connection. On screen instead:\n"
                + app.debugDescription
        )
        XCTAssertTrue(surface.exists, "a leftward two-finger swipe left the terminal screen")
    }

    /// Two fingers swiped sideways, the second landing after the first has
    /// started to move, ask for a connection and not for a pane.
    ///
    /// The one-finger scroll pan has the first finger by the time the second
    /// lands, and takes no second touch, so the two-finger pan never sees the
    /// pair. The pan's delegate hears the second finger and its sideways answer
    /// becomes a connection.
    ///
    func testATwoFingerSwipeWithALateSecondFingerAsksForAConnection() throws {
        let surface = openTerminal()
        XCTAssertFalse(toast.exists, "a notice was already up, so this case would assert nothing")

        try twoFingerSwipe(across: surface, leftward: true, secondFingerDelay: 0.1)

        XCTAssertTrue(
            watchForToast(saying: "Only one connection", timeout: 3),
            "a two-finger swipe whose second finger landed late never asked for a connection. On screen instead:\n"
                + app.debugDescription
        )
        XCTAssertFalse(
            watchForToast(saying: "No panes available", timeout: 0.5),
            "a two-finger swipe whose second finger landed late asked for a pane"
        )
    }

    /// Two fingers swiped sideways with two connections open land on the other
    /// one, and the arriving screen names it.
    ///
    /// The route a person takes: open one host, go back to the list, open a
    /// second, and swipe. The notice is announced on the destination's model,
    /// which only the arriving screen draws, so a notice naming the first host
    /// is the switch having happened and having been told to the right screen.
    ///
    /// Shown able to fail twice: by announcing on the swiped connection's
    /// model, and by letting the detail column keep one navigation stack across
    /// hosts, which kept the screen swiped away from and dropped the arrival.
    /// Each time no notice naming the first host came up and the assertion
    /// reddened.
    func testATwoFingerSwipeWithTwoConnectionsLandsOnTheOther() throws {
        _ = openTerminal()
        let leave = app.buttons["terminal-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5), "the terminal offers no way back to the host list")
        leave.tap()
        // Leaving lands on the host's sessions screen when it has one to show,
        // and the host list is one back from there.
        if !hostRow.waitForExistence(timeout: 5), workspacesScreen.exists {
            app.navigationBars.firstMatch.buttons.firstMatch.tap()
        }
        XCTAssertTrue(
            hostRow.waitForExistence(timeout: 10),
            "leaving the terminal did not come back to the host list. On screen instead:\n" + app.debugDescription
        )

        let secondRow = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", Self.secondHostName))
            .firstMatch
        if !secondRow.waitForExistence(timeout: 3) {
            addHost(named: Self.secondHostName, workspace: "")
        }
        secondRow.tap()
        answerThePasswordPromptIfItAppears()
        let surface = app.otherElements["terminal-surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 15), "the second host's terminal never appeared")
        XCTAssertFalse(toast.exists, "a notice was already up, so this case would assert nothing")

        try twoFingerSwipe(across: surface, leftward: true)

        XCTAssertTrue(
            watchForToast(saying: Self.hostName, timeout: 4),
            "a two-finger swipe with two connections open never named the other host on arrival. On screen instead:\n"
                + app.debugDescription
        )
        XCTAssertTrue(
            app.otherElements["terminal-surface"].waitForExistence(timeout: 5),
            "the switch left no terminal on screen"
        )
    }

    /// Asking for QUIC is offered, and the session says what it actually got.
    ///
    /// What the row exists to show. A QUIC dial that fails falls back to SSH and
    /// the terminal works perfectly, so without something that SAYS which
    /// carrier is live, a reader who asked for QUIC cannot tell they did not get
    /// it — and neither can anyone judging whether this arm speaks QUIC at all.
    /// Not hypothetical: the bridge's QUIC factory was compiled out by a define
    /// that reached the core target and not the bridge, and the app fell back
    /// forever while looking correct.
    ///
    /// This host cannot reach a daemon, so SSH is the answer it must report. What is
    /// asserted is that an answer is SHOWN, not which one it is.
    func testTheSessionSaysWhichTransportItGot() {
        _ = openTerminal()
        XCTAssertFalse(
            app.navigationBars["Connection Details"].exists,
            "connection details was already up, so this case would assert nothing"
        )

        openConnectionDetails()
        XCTAssertTrue(
            app.navigationBars["Connection Details"].waitForExistence(timeout: 5),
            "connection details did not open, so the transport row could not be read"
        )

        // The NAME is not the answer — a row labelled "Transport" showing no
        // value would pass an existence check while saying nothing.
        //
        // Matched on containment rather than equality: SwiftUI composes a
        // LabeledContent's label and value into ONE accessibility label, so the
        // value is not a static text of its own. Asserting equality here failed
        // against a row that was rendering perfectly.
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", ", connecting…")).firstMatch.exists,
            "a failed connection still reports that its session is connecting"
        )
        let names = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "QUIC", "SSH")
        let named = app.descendants(matching: .any).matching(names).firstMatch
        revealInTheForm(named)
        if !named.waitForExistence(timeout: 5) {
            XCTFail(
                "the transport row named neither QUIC nor SSH. The sheet held:\n"
                    + app.debugDescription
            )
        }
    }

    /// The editor offers the QUIC choice at all.
    ///
    /// Separate from the row above because they fail for different reasons: a
    /// missing toggle is a host that can never ask, and a missing row is a
    /// session that never answers.
    func testTheEditorOffersQUIC() {
        app.launch()
        if !hostRow.waitForExistence(timeout: 5) {
            addTheTestHost()
        }
        hostRow.swipeLeft()
        app.buttons["Edit"].firstMatch.tap()
        let workspaces = app.switches["Use Workspaces"]
        revealInTheForm(workspaces)
        XCTAssertTrue(
            workspaces.waitForExistence(timeout: 5),
            "the host editor offers no way to ask for QUIC"
        )
    }

    /// A new host's editor says nothing is wrong before anything is typed,
    /// labels every field, keeps its title until it is saved, and judges a
    /// field only once it is left or Save is tapped.
    ///
    /// Shown able to fail by returning the address error whenever the address
    /// is empty: the first assertion reddened on the empty form.
    func testTheHostEditorJudgesFieldsOnlyAfterInput() {
        app.launch()
        app.buttons["Add Host"].firstMatch.tap()
        let bar = app.navigationBars["New Host"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the host editor did not open")
        XCTAssertFalse(app.staticTexts["Enter an address."].exists, "the empty form opened with an error")
        // Each row's label names its field, so a screen reader reaches the
        // field by the word the row shows.
        for label in ["Address", "User Name", "Port", "Name"] {
            XCTAssertTrue(app.textFields[label].exists, "no field is named \(label). On screen instead:\n" + app.debugDescription)
        }
        XCTAssertFalse(saveButton.isEnabled, "Save is offered with no address or user")

        typeInto(app.textFields["Address"], "build.example.net")
        XCTAssertTrue(bar.exists, "the title stopped saying New Host while the address was typed")
        typeInto(app.textFields["User Name"], "deploy")
        XCTAssertTrue(saveButton.isEnabled, "Save is not offered once an address and a user are there")

        // A port no server listens on is said as soon as the field is left.
        replacePort(with: "70000")
        XCTAssertFalse(app.staticTexts["Enter a port from 1 to 65535."].exists, "the port was judged while it was typed")
        keyboardDoneButton.tap()
        XCTAssertTrue(
            app.staticTexts["Enter a port from 1 to 65535."].waitForExistence(timeout: 3),
            "a port out of range was not reported when the field was left"
        )
        replacePort(with: "2222")
        let keyboardDone = keyboardDoneButton
        XCTAssertEqual(keyboardDone.label, "Done")
        XCTAssertGreaterThan(keyboardDone.frame.midX, bar.frame.midX, "keyboard Done is not at the trailing edge")
        keyboardDone.tap()
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 3), "Done left the keyboard on screen")
        XCTAssertTrue(bar.exists, "keyboard Done closed the host editor")
        XCTAssertEqual(app.textFields["Port"].value as? String, "2222")
        XCTAssertTrue(
            app.staticTexts["Enter a port from 1 to 65535."].waitForNonExistence(timeout: 3),
            "a corrected port kept its error"
        )

        // A saved password with nothing typed is reported on Save, under the
        // password, and the sheet stays.
        chooseSignIn("Saved Password")
        saveButton.tap()
        XCTAssertTrue(
            app.staticTexts["Enter a password, or choose Ask for Password."].waitForExistence(timeout: 3),
            "Save with no password said nothing"
        )
        XCTAssertTrue(bar.exists, "the editor closed with a field in error")
        cancelButton.tap()
    }

    /// Pasting `user@host:port` into Address fills the three fields it names.
    func testPastingAnAddressFillsUserHostAndPort() {
        app.launch()
        app.buttons["Add Host"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Host"].waitForExistence(timeout: 5), "the host editor did not open")
        UIPasteboard.general.string = "deploy@build.example.net:2222"
        let address = app.textFields["Address"]
        address.tap()
        address.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the address field offers no Paste")
        paste.tap()
        XCTAssertEqual(address.value as? String, "build.example.net")
        XCTAssertEqual(app.textFields["User Name"].value as? String, "deploy")
        XCTAssertEqual(app.textFields["Port"].value as? String, "2222")
        cancelButton.tap()
    }

    /// The sign-in choice is a menu of three, and SSH Key opens a screen that
    /// makes a key on the device and shows its public half to copy or share.
    func testTheEditorMakesAnSSHKeyAndShowsItsPublicKey() {
        app.launch()
        app.buttons["Add Host"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Host"].waitForExistence(timeout: 5), "the host editor did not open")
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sign In With")).firstMatch
        XCTAssertTrue(
            picker.waitForExistence(timeout: 5),
            "the editor has no Sign In With menu. On screen instead:\n" + app.debugDescription
        )
        picker.tap()
        for choice in ["Saved Password", "Ask for Password", "SSH Key"] {
            XCTAssertTrue(menuItem(choice).waitForExistence(timeout: 3), "the menu offers no \(choice)")
        }
        menuItem("SSH Key").tap()

        let keyRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Key")).firstMatch
        XCTAssertTrue(keyRow.waitForExistence(timeout: 5), "SSH Key shows no key row")
        XCTAssertTrue(label(of: keyRow).contains("No Key"), "a new host's key row does not say it has none: \(label(of: keyRow))")
        keyRow.tap()
        XCTAssertTrue(app.navigationBars["SSH Key"].waitForExistence(timeout: 5), "the key row did not open the key screen")
        for action in ["Paste Key", "Import from Files…", "Generate New Key"] {
            XCTAssertTrue(app.buttons[action].exists, "the key screen offers no \(action)")
        }
        app.buttons["Generate New Key"].tap()

        let sheet = app.navigationBars["New Public Key"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "making a key showed no public key")
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ecdsa-sha2-nistp256 ")).firstMatch
        XCTAssertTrue(line.exists, "the sheet does not show an ECDSA P-256 public key")
        XCTAssertTrue(app.buttons["Copy"].exists && app.buttons["Share"].exists, "the public key cannot be copied or shared")
        // The pasteboard is not read back here: the runner is another app,
        // and iOS answers its read with nothing rather than with what this
        // app wrote.
        app.buttons["Copy"].tap()
        cancelButton.tap()

        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ECDSA P-256")).firstMatch.waitForExistence(timeout: 5),
            "the key screen does not name the made key"
        )
        app.navigationBars["SSH Key"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            label(of: keyRow).contains("ECDSA P-256"),
            "the key row does not name the made key: \(label(of: keyRow))"
        )
        cancelButton.tap()
    }

    /// Writes the host editor's screens, for a person to look at.
    ///
    /// Not an assertion of what they show: the pictures are read by eye, on
    /// every device and appearance a change claims, into the directory the
    /// log names.
    func testCaptureTheHostEditor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ubq-host-editor", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("ubq-host-editor: \(directory.path)")
        func keep(_ name: String) {
            Thread.sleep(forTimeInterval: 0.8)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
        }
        app.launch()
        app.buttons["Add Host"].firstMatch.tap()
        let bar = app.navigationBars["New Host"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        keep("01-empty")
        typeInto(app.textFields["Address"], "build.example.net")
        typeInto(app.textFields["User Name"], "deploy")
        app.textFields["Port"].tap()
        keep("02a-number-pad")
        putTheKeyboardAway()
        keep("02-filled")
        saveButton.tap()
        keep("03-validation")
        chooseSignIn("Ask for Password")
        keep("04-ask")
        chooseSignIn("SSH Key")
        keep("05-key-choice")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Key")).firstMatch.tap()
        _ = app.navigationBars["SSH Key"].waitForExistence(timeout: 5)
        keep("06-key-screen")
        app.buttons["Generate New Key"].tap()
        _ = app.navigationBars["New Public Key"].waitForExistence(timeout: 5)
        keep("07-public-key")
        cancelButton.tap()
        keep("08-key-made")
        app.navigationBars["SSH Key"].buttons.element(boundBy: 0).tap()
        let form = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
        form.swipeUp()
        form.swipeUp()
        keep("09-lower")
        let learnMore = app.links.matching(NSPredicate(format: "label CONTAINS %@", "Learn More")).firstMatch
        if learnMore.exists {
            learnMore.tap()
            keep("10-learn-more")
            cancelButton.tap()
        }
        cancelButton.tap()
    }

    /// The editor keeps a workspace name, and gives it back on the next open.
    ///
    /// The name is what makes a saved host attach to the same session every
    /// time, so a name that is taken and not stored is a host that silently
    /// opens a different shell on every connect. Read back from a reopened
    /// editor rather than from the row: the row does not show it, and the field
    /// is the thing that has to hold it.
    ///
    /// Shown able to fail by dropping `workspaceName` from HostRecord's
    /// decoder: the field came back empty and the value assertion reddened.
    func testTheEditorKeepsAWorkspaceName() {
        app.launch()
        if !workspaceHostRow.waitForExistence(timeout: 5) {
            addHost(named: Self.workspaceHostName, workspace: Self.workspaceName)
        }
        XCTAssertTrue(
            workspaceHostRow.waitForExistence(timeout: 5),
            "the host that names a workspace was not saved"
        )
        settle(workspaceHostRow, workspace: Self.workspaceName)

        // Read back through a new process, so what is asserted is the saved
        // file rather than a value still sitting in the editor's own state.
        app.terminate()
        app.launch()
        XCTAssertTrue(workspaceHostRow.waitForExistence(timeout: 10), "the host is gone after a relaunch")
        workspaceHostRow.swipeLeft()
        app.buttons["Edit"].firstMatch.tap()
        let field = app.textFields["Workspace"]
        revealInTheForm(field)
        XCTAssertTrue(
            field.waitForExistence(timeout: 5),
            "the host editor offers no workspace field. On screen instead:\n" + app.debugDescription
        )
        XCTAssertEqual(
            field.value as? String,
            Self.workspaceName,
            "the workspace name did not come back. The editor held:\n" + app.debugDescription
        )
    }

    /// A host that names a workspace goes straight to a terminal.
    ///
    /// The name is the answer to the question the session list asks, so a host
    /// carrying one must never stop to ask it. Both halves are asserted: the
    /// terminal is reached, and the list was not on the way — the second is
    /// what a connect that quietly ignored the name would fail.
    ///
    /// Shown able to fail by routing every QUIC host through the list: the
    /// Sessions bar appeared and the negative assertion reddened.
    func testANamedWorkspaceSkipsTheSessionList() {
        app.launch()
        if !workspaceHostRow.waitForExistence(timeout: 5) {
            addHost(named: Self.workspaceHostName, workspace: Self.workspaceName)
        }
        settle(workspaceHostRow, workspace: Self.workspaceName)
        workspaceHostRow.tap()
        answerThePasswordPromptIfItAppears()

        let surface = app.otherElements["terminal-surface"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: 15),
            "a host naming a workspace did not reach a terminal. On screen instead:\n"
                + app.debugDescription
        )
        XCTAssertFalse(
            workspacesScreen.exists,
            "a host naming a workspace stopped to ask which session to open"
        )
        // Offline, the workspace is never reached, and the screen asks rather
        // than opening some other shell under its name. The host itself was
        // never reached, so a login shell would fail the same way and is not
        // offered; Cancel goes back to the hosts.
        let unreached = unreachedPickAlert
        XCTAssertTrue(
            unreached.waitForExistence(timeout: 15),
            "the unreached workspace raised no question. On screen:\n" + app.debugDescription
        )
        XCTAssertTrue(unreached.label.contains("“\(Self.workspaceName)”"), "the question does not name the workspace: \(unreached.label)")
        XCTAssertTrue(unreached.buttons["Try Again"].exists, "the question offers no Try Again")
        XCTAssertFalse(unreached.buttons["Open Login Shell"].exists, "a login shell is offered to a host that was never reached")
        unreached.buttons["Cancel"].tap()
        XCTAssertTrue(workspaceHostRow.waitForExistence(timeout: 5), "Cancel did not go back to the hosts")
    }

    /// The session list draws the host's outline, and offers to end a row.
    ///
    /// The rows are Core's outline of the showcase host every frontend is
    /// checked against: workspaces under their names, the one that ends when
    /// detached saying so, and the one nothing runs in saying it is
    /// restorable. Each assertion reads a row by its identity and a fact Core
    /// worded for it, so a row that drew a constant would fail against
    /// another.
    ///
    /// The tree is seeded through the launch argument rather than answered by
    /// a daemon — an offline run has no host to ask — so what this covers is
    /// the screen. That a listing crosses the wire at all is the live lane's
    /// box, `testALiveQUICSessionAttachesToASessionChosenFromTheList`.
    func testTheSessionListDrawsWhatTheHostAnswered() {
        openTheSeededSessionList()

        let api = outlineRow("host-outline-row-workspace-3")
        XCTAssertTrue(api.waitForExistence(timeout: 5), "the api workspace's row is not on screen. The list held:\n" + app.debugDescription)
        XCTAssertTrue(label(of: api).contains("api"), "the api row does not say api: \(label(of: api))")

        let scratch = outlineRow(Self.scratchRow)
        XCTAssertTrue(
            scratch.waitForExistence(timeout: 5),
            "the scratch workspace's row is not on screen. The list held:\n" + app.debugDescription
        )
        XCTAssertTrue(
            label(of: scratch).contains("ends when detached"),
            "the scratch row does not say it ends when detached: \(label(of: scratch))"
        )

        let release = outlineRow("host-outline-row-workspace-5")
        XCTAssertTrue(
            release.waitForExistence(timeout: 5),
            "the release workspace's row is not on screen. The list held:\n" + app.debugDescription
        )
        XCTAssertTrue(label(of: release).contains("restorable"), "the release row does not say it is restorable: \(label(of: release))")

        // The destructive action is a swipe, and it is named for what it asks
        // the host to do rather than for deleting a row on this device. The
        // row is found again: reading release scrolled it away.
        outlineRow(Self.scratchRow).swipeLeft()
        XCTAssertTrue(
            app.buttons["Terminate"].firstMatch.waitForExistence(timeout: 5),
            "a swipe on a workspace's row offered no way to terminate it"
        )
    }

    /// Tapping a seeded row reaches the session that row opens, not a fresh one.
    ///
    /// What makes it assertable offline is the settings sheet's Session row —
    /// the screen knows which session it was asked to reach the moment it is
    /// pushed, before a carrier exists, so a run with no daemon still says
    /// which one this is. The scratch row opens the session of its one pane,
    /// 49 in the showcase host.
    ///
    /// Shown able to fail by binding the row's tap to `.newSession` instead of
    /// the row's own opening: the sheet then reads "New workspace, connecting…" and
    /// the assertion reddens on the session number.
    func testTappingASeededRowReachesThatSession() {
        openTheSeededSessionList()
        let isSidebar = workspacesScreen.frame.width < app.frame.width * 0.8
        let scratch = outlineRow(Self.scratchRow)
        XCTAssertTrue(
            scratch.waitForExistence(timeout: 5),
            "the seeded scratch row is not on screen. The list held:\n" + app.debugDescription
        )
        scratch.tap()

        if !isSidebar {
            XCTAssertTrue(
                workspacesScreen.waitForNonExistence(timeout: 10),
                "tapping a row did not leave the list. On screen:\n" + app.debugDescription
            )
        }

        let surface = app.otherElements["terminal-surface"].firstMatch
        XCTAssertTrue(
            surface.waitForExistence(timeout: 15),
            "no terminal came up for the chosen session. On screen:\n" + app.debugDescription
        )

        // Offline the pick is never reached, and the screen says which pick
        // it could not reach rather than opening another shell in its place:
        // the question names the session the tap carried.
        let unreached = unreachedPickAlert
        if unreached.waitForExistence(timeout: 10) {
            if let shots = try? connectShotDirectory() { keepConnectShot("16-unreached-alert", in: shots) }
            // By the workspace's name, as the row was, never by its number.
            XCTAssertTrue(
                unreached.label.contains("“scratch”") && !unreached.label.contains("\(Self.scratchSession)"),
                "the unreached pick is not named scratch, so the tap reached some other session: \(unreached.label)"
            )
            return
        }

        openConnectionDetails()
        XCTAssertTrue(
            app.navigationBars["Connection Details"].waitForExistence(timeout: 5),
            "connection details did not open, so the session row could not be read"
        )
        // Containment, not equality: SwiftUI composes a LabeledContent's label
        // and value into one accessibility label.
        let saysTheSession = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS[c] %@", "Session \(Self.scratchSession)"))
            .firstMatch
        revealInTheForm(saysTheSession)
        XCTAssertTrue(
            saysTheSession.waitForExistence(timeout: 5),
            "the screen does not say it is on session \(Self.scratchSession), so the tap reached some other session. "
                + "Connection Details held:\n" + app.debugDescription
        )
    }

    /// A terminate the device never sent says so, rather than blaming the host.
    ///
    /// The question is Core's, and answering it yes on the offline lane sends
    /// nothing — there is no directory carrier to send with — so the report
    /// must say the device did not send it. The host saw nothing, so a person
    /// debugging "the host refused the request" would be sent to the wrong
    /// machine.
    ///
    /// Shown able to fail by reporting `.refused` for it: the alert returns to
    /// the host's name and this assertion reddens.
    func testATerminateThatWasNeverSentSaysSo() {
        openTheSeededSessionList()
        let scratch = outlineRow(Self.scratchRow)
        XCTAssertTrue(
            scratch.waitForExistence(timeout: 5),
            "the seeded scratch row is not on screen. The list held:\n" + app.debugDescription
        )
        scratch.swipeLeft()
        let terminate = app.buttons["Terminate"].firstMatch
        XCTAssertTrue(terminate.waitForExistence(timeout: 5), "a swipe offered no way to terminate")
        terminate.tap()

        // Core's question, answered yes.
        let question = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Terminate scratch")).firstMatch
        XCTAssertTrue(
            question.waitForExistence(timeout: 5),
            "Terminate did not ask Core's question first. On screen:\n" + app.debugDescription
        )
        let confirm = app.buttons.matching(identifier: "Terminate").allElementsBoundByIndex.last ?? app.buttons["Terminate"].firstMatch
        confirm.tap()

        let saysNotSent = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS[c] %@", "did not send"))
            .firstMatch
        XCTAssertTrue(
            saysNotSent.waitForExistence(timeout: 10),
            "an unsent terminate did not say it was unsent. On screen:\n" + app.debugDescription
        )
        let blamesTheHost = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS[c] %@", "host refused"))
            .firstMatch
        XCTAssertFalse(
            blamesTheHost.exists,
            "the alert blamed the host for a request this device never sent"
        )
    }

    /// A full swipe across a row asks nothing and sends nothing.
    ///
    /// What is asserted is the absence of Core's question and of the report
    /// every sent or unsent terminate raises.
    ///
    /// Shown able to fail with the full swipe allowed: the swipe ran Terminate
    /// and the question came up.
    func testAFullSwipeOnASessionRowSendsNothing() {
        openTheSeededSessionList()
        let scratch = outlineRow(Self.scratchRow)
        XCTAssertTrue(
            scratch.waitForExistence(timeout: 5),
            "the seeded scratch row is not on screen. The list held:\n" + app.debugDescription
        )

        fullSwipe(scratch)

        let question = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Terminate scratch")).firstMatch
        XCTAssertFalse(question.waitForExistence(timeout: 3), "a full swipe across a row asked to end it")
        let report = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "did not send")).firstMatch
        XCTAssertFalse(report.exists, "a full swipe across a row asked the host to end it")
        XCTAssertTrue(scratch.exists, "a full swipe took the row off the list")
    }

    /// Terminating a workspace with a program running asks first, in Core's
    /// words that name the program, and keeping it leaves the workspace alone.
    ///
    /// The notes workspace runs vim, which is the work a terminate would
    /// destroy. A confirmation that names no cost is one a person answers by
    /// reflex.
    ///
    /// Shown able to fail with a question that counts sessions and never
    /// names the program.
    func testTerminatingARunningProgramAsksFirstAndNamesIt() {
        openTheSeededSessionList()
        let notes = outlineRow("host-outline-row-workspace-11")
        XCTAssertTrue(
            notes.waitForExistence(timeout: 5),
            "the seeded notes row is not on screen. The list held:\n" + app.debugDescription
        )
        notes.swipeLeft()
        let terminate = app.buttons["Terminate"].firstMatch
        XCTAssertTrue(terminate.waitForExistence(timeout: 5), "a swipe offered no way to terminate")
        terminate.tap()

        let namesTheProgram = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "Running: vim"))
            .firstMatch
        XCTAssertTrue(
            namesTheProgram.waitForExistence(timeout: 5),
            "terminating a workspace running vim did not say vim is running. On screen:\n" + app.debugDescription
        )
        let keep = app.buttons["Keep Workspace"].firstMatch
        if keep.waitForExistence(timeout: 2), keep.isHittable {
            keep.tap()
        } else {
            dismissTheConfirmation()
        }

        let report = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "did not send")).firstMatch
        XCTAssertFalse(report.waitForExistence(timeout: 3), "keeping the workspace still asked the host")
        XCTAssertTrue(notes.exists, "keeping the workspace took its row off the list")
    }

    /// The workspaces screen is titled by the host, puts what needs the
    /// person first with the action that answers it, and draws each
    /// workspace on two lines at most.
    ///
    /// The showcase host's api workspace holds an agent blocked on a
    /// permission ("Approve the migration?"), which Core gives a second line;
    /// that pane is the Needs You row, opened by tapping the row. Two lines are
    /// held as a height: a third line would grow the row past a headline
    /// line, two subheadline lines and the cell's padding.
    ///
    /// Shown able to fail with the Needs You section left out (its row was
    /// not found).
    func testWorkspacesArePutTwoLinesEachUnderWhatNeedsYou() {
        openTheSeededSessionList()
        XCTAssertTrue(
            app.navigationBars[Self.hostName].waitForExistence(timeout: 5),
            "the screen is not titled by the host. On screen instead:\n" + app.debugDescription
        )
        let title = app.navigationBars[Self.hostName].staticTexts[Self.hostName].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5) && title.isHittable, "the host's title is not visible")
        let needsSection = app.staticTexts["Needs You"].firstMatch
        XCTAssertTrue(needsSection.waitForExistence(timeout: 5), "there is no Needs You section. On screen:\n" + app.debugDescription)
        let question = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "workspace-needs-", "Approve the migration?"))
            .firstMatch
        XCTAssertTrue(
            question.waitForExistence(timeout: 5),
            "the agent's question is not in Needs You. On screen:\n" + app.debugDescription
        )
        XCTAssertTrue(question.isHittable, "the request row is not tappable")
        XCTAssertFalse(app.buttons["Respond…"].firstMatch.exists, "the request has a redundant Respond button")
        XCTAssertLessThan(
            question.frame.minY,
            outlineRow("host-outline-row-workspace-3").frame.minY,
            "the question is not above the workspaces"
        )

        let api = outlineRow("host-outline-row-workspace-3")
        XCTAssertTrue(api.waitForExistence(timeout: 5), "the api workspace's row is not on screen")
        // A list cell pads its content by about eleven points above and
        // below, so a third line is what takes the row past the height of
        // three lines with that padding.
        let headline = UIFont.preferredFont(forTextStyle: .headline).lineHeight
        let subheadline = UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
        let threeLines = headline + subheadline * 2 + 22
        XCTAssertLessThan(api.frame.height, threeLines, "the api row is taller than two lines: \(api.frame.height) pt")
        XCTAssertTrue(label(of: api).contains("tabs"), "the api row does not count its tabs: \(label(of: api))")
        question.tap()
        XCTAssertTrue(app.otherElements["terminal-surface"].waitForExistence(timeout: 10), "tapping the request did not open its pane")
    }

    /// Leaving the first workspace on a fresh host comes back to that
    /// workspace on the list, never to "No Workspaces".
    ///
    /// The host answered empty before the first connect, so Core's plan
    /// started a workspace and the terminal came up. Back on the list, that
    /// answer no longer says what the host holds, and its directory is busy
    /// for the first ask, as a live one is while the errand before it is
    /// still out. The screen asks again rather than presenting the old
    /// answer as the host's word.
    ///
    /// Shown able to fail with the refused ask settled by closing it and
    /// leaving the rows as they were: the screen came back to "No Workspaces"
    /// and stayed there.
    func testLeavingTheFirstWorkspaceOnAFreshHostListsIt() {
        let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        seeded.launchArguments = ["--seed-host-filled-by-attach"]
        seeded.launch()
        if !hostRow.waitForExistence(timeout: 5) {
            addTheTestHost()
        }
        settle(hostRow, workspace: "")
        hostRow.tap()
        answerThePasswordPromptIfItAppears()
        let surface = app.otherElements["terminal-surface"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: 15),
            "an empty host did not go straight to a new workspace. On screen instead:\n" + app.debugDescription
        )
        leaveTheTerminal()

        let empty = app.descendants(matching: .any).matching(identifier: "workspace-list-empty").firstMatch
        let rows = app.descendants(matching: .any).matching(identifier: "host-outline-row-workspace-9").firstMatch
        let deadline = Date(timeIntervalSinceNow: 10)
        while Date() < deadline, !rows.exists {
            XCTAssertFalse(empty.exists, "the list said the host holds nothing while this device had just started a workspace on it")
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(rows.exists, "the list did not come back with the host's workspaces. On screen:\n" + app.debugDescription)
        XCTAssertFalse(empty.exists, "the list said the host holds nothing")
    }

    /// A host that answered with nothing says so and offers a new workspace;
    /// a host that could not be asked says that instead and offers to try
    /// again. The two are never the same sentence.
    ///
    /// Shown able to fail with both states drawn by the empty one: the
    /// unanswered host said "No Workspaces".
    func testAnEmptyHostAndAnUnansweredOneAreToldApart() {
        for (argument, identifier, action) in [
            ("--seed-empty-host", "workspace-list-empty", "New Workspace"),
            ("--seed-unanswered-host", "workspace-list-unanswered", "Try Again"),
        ] {
            let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
            seeded.launchArguments = [argument]
            seeded.launch()
            if !hostRow.waitForExistence(timeout: 5) {
                addTheTestHost()
            }
            settle(hostRow, workspace: "")
            hostRow.tap()
            answerThePasswordPromptIfItAppears()
            // Neither leaves a choice to make, so the first visit connects;
            // the state is the one the person comes back to.
            if app.otherElements["terminal-surface"].waitForExistence(timeout: 15) {
                leaveTheTerminal()
            }
            let state = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(
                state.waitForExistence(timeout: 10),
                "\(argument) did not come back to \(identifier). On screen:\n" + app.debugDescription
            )
            XCTAssertTrue(app.buttons[action].firstMatch.exists, "\(argument) offers no \(action)")
            app.terminate()
        }
    }

    /// Walks the workspaces screen through each of its states and keeps a
    /// picture of each, for a review of the screen as it is.
    ///
    /// Not an assertion: the pictures are the product. Written under the
    /// runner's temporary directory, whose path the case prints.
    func testWorkspacesTourKeepsAPictureOfEachState() throws {
        let tour = FileManager.default.temporaryDirectory.appendingPathComponent("ubq-workspaces", isDirectory: true)
        try? FileManager.default.removeItem(at: tour)
        try FileManager.default.createDirectory(at: tour, withIntermediateDirectories: true)
        print("ubq-tour: \(tour.path)")
        func keep(_ name: String) {
            Thread.sleep(forTimeInterval: 0.8)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: tour.appendingPathComponent(name + ".png"))
        }

        openTheSeededSessionList()
        _ = outlineRow("host-outline-row-workspace-3").waitForExistence(timeout: 5)
        keep("01-workspaces")
        let api = outlineRow("host-outline-row-workspace-3")
        if api.exists {
            // The disclosure's chevron trails the row.
            api.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 0.5)
            keep("02-disclosure")
            api.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        }
        let notes = outlineRow("host-outline-row-workspace-11")
        if notes.waitForExistence(timeout: 5) {
            notes.swipeLeft()
            keep("03-swipe")
            dismissTheRowActions()
            notes.press(forDuration: 1.2)
            keep("04-context-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            Thread.sleep(forTimeInterval: 0.6)
            notes.swipeLeft()
            let terminate = app.buttons["Terminate"].firstMatch
            if terminate.waitForExistence(timeout: 3) {
                terminate.tap()
                keep("05-terminate-confirm")
                dismissTheConfirmation()
            }
        }
        app.terminate()

        for (argument, name) in [("--seed-empty-host", "06-empty"), ("--seed-unanswered-host", "07-unanswered")] {
            let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
            seeded.launchArguments = [argument]
            seeded.launch()
            if !hostRow.waitForExistence(timeout: 5) { addTheTestHost() }
            settle(hostRow, workspace: "")
            hostRow.tap()
            answerThePasswordPromptIfItAppears()
            if app.otherElements["terminal-surface"].waitForExistence(timeout: 15) { leaveTheTerminal() }
            _ = workspacesScreen.waitForExistence(timeout: 10)
            keep(name)
            app.terminate()
        }
    }

    /// One tap on a pane under a connected host on the Hosts screen opens
    /// that pane: the terminal comes up attached to the pane's session, with
    /// no stop on the host's workspaces screen.
    ///
    /// The connection is the seeded one (`--seed-connected-host`): every
    /// connect settles as connected, and the showcase host is the tree its
    /// watch follows. The api workspace's server tab is split, and its
    /// second pane runs `tail -f api.log` in session 41, so a tap that
    /// opened the tab, the workspace or the first pane would name another
    /// session. The pane is reached through the toolbar search, which Core
    /// answers by opening the way to it. Pictures of the Hosts screen, and
    /// of it searched, are kept under the runner's temporary directory, whose
    /// path the case prints.
    func testOneTapFromHostsOpensAChosenPane() throws {
        let pictures = FileManager.default.temporaryDirectory.appendingPathComponent("ubq-hosts-outline", isDirectory: true)
        try? FileManager.default.removeItem(at: pictures)
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        print("ubq-tour: \(pictures.path)")

        let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        seeded.launchArguments = ["--seed-host-sessions", "--seed-connected-host"]
        seeded.launch()
        if !hostRow.waitForExistence(timeout: 5) {
            addTheTestHost()
        }
        settle(hostRow, workspace: "")
        let api = app.descendants(matching: .any).matching(identifier: "hosts-host-outline-row-workspace-3").firstMatch
        XCTAssertFalse(api.exists, "a host with no connection showed what it holds")

        // Connect once, through the host's workspaces, then come back.
        hostRow.tap()
        answerThePasswordPromptIfItAppears()
        XCTAssertTrue(
            workspacesScreen.waitForExistence(timeout: 15),
            "the session list never came up. On screen instead:\n" + app.debugDescription
        )
        let scratch = outlineRow(Self.scratchRow)
        XCTAssertTrue(scratch.waitForExistence(timeout: 5), "the scratch workspace is not on the list")
        scratch.tap()
        XCTAssertTrue(app.otherElements["terminal-surface"].waitForExistence(timeout: 15), "the terminal did not come up")
        leaveTheTerminal()
        let backToHosts = app.navigationBars.buttons["Hosts"].firstMatch
        if backToHosts.waitForExistence(timeout: 5) { backToHosts.tap() }

        XCTAssertTrue(
            api.waitForExistence(timeout: 10),
            "the connected host does not list its workspaces under its row. On screen:\n" + app.debugDescription
        )
        XCTAssertGreaterThan(api.frame.minY, hostRow.frame.minY, "the workspaces are not under the host's row")
        XCTAssertTrue(
            api.label.hasPrefix("Workspace, ") && api.label.hasSuffix("on \(Self.hostName)"),
            "VoiceOver does not hear the row as a workspace on the host: \(api.label)"
        )
        Thread.sleep(forTimeInterval: 0.8)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: pictures.appendingPathComponent("hosts-outline.png"))

        // The search reaches the rows: Core opens the way to the pane it
        // matches, whatever was closed.
        let search = app.searchFields["Search Hosts"]
        if !search.exists {
            let magnifier = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", "Search", "Search")).firstMatch
            if magnifier.waitForExistence(timeout: 3) { magnifier.tap() }
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the host list has no search field")
        search.tap()
        search.typeText("api.log")
        let pane = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Pane", "tail -f api.log"))
            .firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 5), "the search did not reach the pane. On screen:\n" + app.debugDescription)
        XCTAssertTrue(pane.label.contains("in "), "VoiceOver is not told the workspace the pane is in: \(pane.label)")
        XCTAssertTrue(pane.label.hasSuffix("on \(Self.hostName)"), "VoiceOver is not told the host: \(pane.label)")
        if UIDevice.current.userInterfaceIdiom == .phone {
            let line = UIFont.preferredFont(forTextStyle: .body).lineHeight
            XCTAssertGreaterThanOrEqual(pane.frame.height, 44, "the title and status row has no touch-sized height")
            XCTAssertLessThan(pane.frame.height, line * 2.2 + 16, "the title and status row grew beyond two lines: \(pane.frame.height) pt")
            XCTAssertLessThan(
                pane.frame.minX,
                app.windows.firstMatch.frame.width / 4,
                "tree indentation leaves too little room for the title"
            )
        }
        Thread.sleep(forTimeInterval: 0.8)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: pictures.appendingPathComponent("hosts-outline-search.png"))

        pane.tap()
        let surface = app.otherElements["terminal-surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 15), "tapping the pane did not open a terminal")
        XCTAssertFalse(workspacesScreen.exists, "the tap stopped on the workspaces screen")
        openConnectionDetails()
        let session = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Session 41")).firstMatch
        revealInTheForm(session)
        XCTAssertTrue(
            session.waitForExistence(timeout: 5),
            "the terminal is not on the tapped pane's session. On screen:\n" + app.debugDescription
        )
        dismissSheet()
    }

    /// A full swipe across a host row deletes nothing.
    ///
    /// Delete takes the host's keychain secret with it, and a stroke meant to
    /// reveal Edit must never be enough to lose a credential. The row and the
    /// stored secret are both read back afterwards; the secret through the
    /// editor, which says when one is stored without showing it.
    ///
    /// Shown able to fail with the full swipe allowed: the host was gone.
    func testAFullSwipeOnAHostDeletesNothing() {
        app.launch()
        let doomed = hostRow(named: Self.deletableHostName)
        if !doomed.waitForExistence(timeout: 5) {
            addHost(named: Self.deletableHostName, workspace: "")
        }
        XCTAssertTrue(editorSaysASecretIsStored(for: doomed), "the host was saved without its password")

        fullSwipe(doomed)

        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Delete “")).firstMatch
                .waitForExistence(timeout: 2),
            "a full swipe across a host row asked to delete it"
        )
        dismissTheRowActions()
        XCTAssertTrue(doomed.waitForExistence(timeout: 3), "a full swipe across a host row deleted the host")
        XCTAssertTrue(editorSaysASecretIsStored(for: doomed), "a full swipe across a host row deleted its password")
    }

    /// Deleting a host asks first, and Cancel keeps the host and its secret;
    /// confirming removes it.
    ///
    /// The negative half is the defense: the delete is reached, the question
    /// is answered no, and both the record and the keychain secret are still
    /// there. The positive half catches a Delete button that does nothing,
    /// which would pass the first half alone.
    ///
    /// Shown able to fail with Delete acting at once: the host was gone
    /// before any question was asked.
    func testDeletingAHostAsksAndCancelKeepsItsSecret() {
        app.launch()
        let doomed = hostRow(named: Self.deletableHostName)
        if !doomed.waitForExistence(timeout: 5) {
            addHost(named: Self.deletableHostName, workspace: "")
        }
        XCTAssertTrue(editorSaysASecretIsStored(for: doomed), "the host was saved without its password")

        doomed.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let question = app.staticTexts
            .containing(NSPredicate(format: "label BEGINSWITH %@", "Delete “\(Self.deletableHostName)”"))
            .firstMatch
        XCTAssertTrue(
            question.waitForExistence(timeout: 5),
            "Delete removed the host without asking. On screen:\n" + app.debugDescription
        )
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "password is deleted")).firstMatch.exists,
            "the question does not say the saved password goes with the host"
        )
        dismissTheConfirmation()
        dismissTheRowActions()
        XCTAssertTrue(doomed.waitForExistence(timeout: 3), "cancelling the delete removed the host")
        XCTAssertTrue(editorSaysASecretIsStored(for: doomed), "cancelling the delete removed the host's password")

        doomed.press(forDuration: 1.2)
        let menuDelete = app.buttons["Delete…"].firstMatch
        XCTAssertTrue(menuDelete.waitForExistence(timeout: 5), "the host row's menu offers no Delete")
        menuDelete.tap()
        let confirm = app.buttons["Delete Host"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the menu's Delete did not ask first")
        confirm.tap()
        XCTAssertTrue(doomed.waitForNonExistence(timeout: 5), "confirming the delete left the host in the list")
    }

    /// A host of another build is refused with which end is older and which
    /// to update, in the product's words.
    ///
    /// The refusal is held where the host's lands (`--seed-build-refusal`):
    /// the host states a build older than this app's, and the card is what
    /// Core writes from it. What is read is what a person reads: the card
    /// says it could not connect, that the host's build is the older one, and
    /// to update the host on the machine named in the list. It never says
    /// what the wire calls the refusal.
    func testAHostOfAnotherBuildIsRefusedWithWhichToUpdate() {
        let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        seeded.launchArguments = ["--seed-build-refusal"]
        seeded.launch()
        if !hostRow.waitForExistence(timeout: 5) {
            addTheTestHost()
        }
        hostRow.tap()
        answerThePasswordPromptIfItAppears()
        XCTAssertTrue(
            app.otherElements["terminal-surface"].waitForExistence(timeout: 15),
            "opening the host never reached the terminal. On screen instead:\n" + app.debugDescription
        )
        let status = app.descendants(matching: .any).matching(identifier: "terminal-connection-status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 15), "the refused connect showed no card")
        let update = "Update the host on \(Self.hostName)."
        let cause = status.descendants(matching: .any).matching(identifier: "terminal-failure-cause").firstMatch
        XCTAssertTrue(cause.waitForExistence(timeout: 5), "the banner states no cause:\n" + status.debugDescription)
        let fix = status.descendants(matching: .any).matching(identifier: "terminal-failure-fix").firstMatch
        let sentence = cause.label + (fix.exists ? " " + fix.label : "")
        XCTAssertTrue(sentence.hasSuffix(update), "the banner does not say which host to update: \(sentence)")
        XCTAssertTrue(sentence.contains("older"), "the card does not say the host's build is the older one: \(sentence)")
        for word in ["protocol", "body", "decode", "refused:"] {
            XCTAssertFalse(
                sentence.localizedCaseInsensitiveContains(word),
                "the card speaks the wire's words (\(word)): \(sentence)"
            )
        }
    }

    /// A failed connection says why, can be tried again, and a host edited
    /// after it fails dials what the editor now says.
    ///
    /// Port 1 on the loopback refuses at once, so the sentence is known: the
    /// host and the port, from the connect's own error code. The card over the
    /// grid names the failure and its recovery, and the sentence is under
    /// Connection Details, not on the card. The edit
    /// is the half that reaches the model behind the screen. A model kept from
    /// the failed attempt answers the reopened host with the old failure, so
    /// "port 2" is only reachable through a fresh dial.
    ///
    /// Shown able to fail with a status of "Unable to Connect" that gives no
    /// reason and no way to try again, and with the failed attempt's model
    /// kept, which shows the reopened host the attempt on port 1.
    func testAFailedConnectionSaysWhyAndDialsAgainAfterAnEdit() {
        app.launch()
        let redial = hostRow(named: Self.redialHostName)
        if !redial.waitForExistence(timeout: 5) {
            addHost(named: Self.redialHostName, workspace: "")
        }
        edit(redial, port: 1, prefersQUIC: false)
        redial.tap()
        answerThePasswordPromptIfItAppears()
        XCTAssertTrue(
            app.otherElements["terminal-surface"].waitForExistence(timeout: 15),
            "the terminal never came up. On screen instead:\n" + app.debugDescription
        )

        let refusedOnOne = "127.0.0.1 refused the connection on port 1."
        // The banner itself says what refused and what to do, with the
        // host's settings first: nothing sends the person to the details for
        // the cause.
        let cause = app.descendants(matching: .any).matching(identifier: "terminal-failure-cause").firstMatch
        XCTAssertTrue(cause.waitForExistence(timeout: 15), "the failure banner states no cause. On screen:\n" + app.debugDescription)
        XCTAssertEqual(cause.label, refusedOnOne, "the banner's cause is not the refusal")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "terminal-failure-fix").firstMatch.exists,
            "the failure banner says what happened and not what to do"
        )
        XCTAssertTrue(app.buttons["Edit Host"].exists, "a refused port does not offer the host's settings")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Check Connection Details")).firstMatch.exists,
            "the banner still sends the person to Connection Details"
        )
        XCTAssertTrue(
            connectionDetailsSay(refusedOnOne),
            "a refused connection did not say what refused it. On screen:\n" + app.debugDescription
        )
        let tryAgain = app.buttons["Try Again"].firstMatch
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 5), "a failed connection offers no way to try again")
        tryAgain.tap()
        XCTAssertTrue(
            connectionDetailsSay(refusedOnOne),
            "trying again did not settle on the refusal again. On screen:\n" + app.debugDescription
        )

        app.buttons["terminal-leave"].tap()
        XCTAssertTrue(redial.waitForExistence(timeout: 5), "leaving the terminal did not return to the hosts")
        edit(redial, port: 2, prefersQUIC: false)
        redial.tap()
        answerThePasswordPromptIfItAppears()
        XCTAssertTrue(
            connectionDetailsSay("refused the connection on port 2."),
            "the host reopened after an edit showed the attempt before it. On screen:\n" + app.debugDescription
        )
    }

    /// A server's password request is an alert with one secure field; a
    /// refused password says why on the banner with the host's settings first;
    /// Connection Details opens on that cause, lists the steps, folds the raw
    /// log away and offers Share Diagnostics.
    ///
    /// The server is the seeded one: it asks, and refuses whatever is typed.
    /// The host keeps no password, so the alert offers to save one.
    func testThePasswordPromptIsAnAlertAndARefusalSaysWhatToDo() throws {
        let shots = try connectShotDirectory()
        let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        seeded.launchArguments = ["--seed-sign-in-prompt"]
        seeded.launch()
        let row = hostRow(named: Self.promptHostName)
        if !row.waitForExistence(timeout: 5) {
            addHost(named: Self.promptHostName, workspace: "", savesPassword: false)
        }
        row.tap()

        let alert = passwordAlert
        XCTAssertTrue(
            alert.waitForExistence(timeout: 15),
            "the server's password request raised no alert. On screen:\n" + app.debugDescription
        )
        XCTAssertEqual(alert.label, "Password for “\(Self.promptHostName)”", "the alert does not name the host")
        XCTAssertTrue(alert.staticTexts["ui@127.0.0.1"].exists, "the alert does not say who signs in where")
        XCTAssertTrue(alert.secureTextFields.firstMatch.exists, "the alert has no secure field")
        for title in ["Connect", "Connect and Save Password", "Cancel"] {
            XCTAssertTrue(alert.buttons[title].exists, "the alert offers no \(title)")
        }
        XCTAssertFalse(
            app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Password")).firstMatch.exists,
            "the password is still asked in a sheet"
        )
        keepConnectShot("40-password-alert", in: shots)
        let field = alert.secureTextFields.firstMatch
        field.tap()
        field.typeText("wrong")
        alert.buttons["Connect"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "the alert stayed after Connect")

        let cause = app.descendants(matching: .any).matching(identifier: "terminal-failure-cause").firstMatch
        XCTAssertTrue(cause.waitForExistence(timeout: 15), "a refused password showed no cause. On screen:\n" + app.debugDescription)
        XCTAssertEqual(cause.label, "The server refused the password or key for this host.")
        XCTAssertTrue(app.buttons["Edit Host"].exists, "a refused password does not offer the host's settings")
        keepConnectShot("17-failure-banner", in: shots)

        app.buttons["terminal-connection-details"].firstMatch.tap()
        let bar = app.navigationBars["Connection Details"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "Connection Details did not open")
        XCTAssertTrue(bar.buttons["Close"].exists, "Connection Details has no Close")
        XCTAssertTrue(app.buttons["connection-details-share"].exists, "Connection Details offers no Share Diagnostics")
        let headline = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "The server refused the password")).firstMatch
        XCTAssertTrue(headline.exists, "Connection Details does not open on the cause")
        XCTAssertFalse(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Check Connection Details")).firstMatch
                .exists,
            "Connection Details repeats the generic sentence"
        )
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Reached 127.0.0.1")).firstMatch.exists,
            "the steps do not say the host was reached"
        )
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "The server asked for a password")).firstMatch.exists,
            "the raw log is open by default"
        )
        keepConnectShot("18-connection-details", in: shots)
        bar.buttons["Close"].tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "Close did not close Connection Details")

        // Try Again asks again, and Cancel ends the attempt as canceled.
        app.buttons["Try Again"].firstMatch.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "Try Again did not ask for the password again")
        alert.buttons["Cancel"].tap()
        let canceled = app.descendants(matching: .any).matching(identifier: "terminal-failure-cause").firstMatch
        XCTAssertTrue(canceled.waitForExistence(timeout: 10), "canceling the prompt left no cause on screen")
        XCTAssertEqual(canceled.label, "Sign-in was canceled.")
    }

    /// A connection still being made says how far it has got, covers nothing
    /// but its own words, and offers Cancel once it has taken a while; Cancel
    /// ends it as canceled with Try Again.
    ///
    /// The host is an address reserved for documentation, which no network
    /// routes, so the dial waits rather than failing at once.
    func testAConnectionBeingMadeShowsItsStepAndCanBeCanceled() throws {
        let shots = try connectShotDirectory()
        app.launch()
        let row = hostRow(named: Self.slowHostName)
        if !row.waitForExistence(timeout: 5) {
            addHost(named: Self.slowHostName, workspace: "", address: "192.0.2.1", prefersQUIC: false)
        }
        let started = ContinuousClock.now
        row.tap()
        let step = app.descendants(matching: .any).matching(identifier: "terminal-connecting-step").firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 10), "connecting showed no step. On screen:\n" + app.debugDescription)
        XCTAssertTrue(step.label.hasSuffix("…"), "the step is not a status in progress: \(step.label)")
        let cancel = app.buttons["terminal-connecting-cancel"]
        // Automation can wait for idle longer than the three-second delay.
        // Only an observation made before that delay can judge it premature.
        let isCancelVisible = cancel.exists
        XCTAssertFalse(
            isCancelVisible && started.duration(to: .now) < .seconds(3),
            "Cancel was offered before the connection had taken a while"
        )
        XCTAssertTrue(cancel.waitForExistence(timeout: 8), "a slow connection never offered Cancel")
        keepConnectShot("50-connecting", in: shots)
        cancel.tap()
        let cause = app.descendants(matching: .any).matching(identifier: "terminal-failure-cause").firstMatch
        XCTAssertTrue(cause.waitForExistence(timeout: 10), "Cancel left no cause on screen")
        XCTAssertEqual(cause.label, "The connection was canceled.")
        XCTAssertTrue(app.buttons["Try Again"].exists, "a canceled connection offers no Try Again")
    }

    /// Where this run's connect-flow pictures go, printed for the runner.
    private func connectShotDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ubq-connect", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("ubq-connect: \(directory.path)")
        return directory
    }

    /// Keeps a picture of the screen once a presentation has finished fading in.
    private func keepConnectShot(_ name: String, in directory: URL) {
        Thread.sleep(forTimeInterval: 0.8)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
    }

    /// Whether the failed connection's details name the reason, read from the
    /// Connection Details sheet the card opens, which is closed again after.
    ///
    /// - Parameter reason: Text the diagnostic sentence contains.
    /// - Returns: Whether the sheet showed it within the connect's settle time.
    private func connectionDetailsSay(_ reason: String) -> Bool {
        let details = app.buttons["terminal-connection-details"].firstMatch
        guard details.waitForExistence(timeout: 15) else { return false }
        details.tap()
        guard app.navigationBars["Connection Details"].waitForExistence(timeout: 5) else { return false }
        let sentence = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", reason)).firstMatch
        let isSaid = sentence.waitForExistence(timeout: 15)
        app.navigationBars["Connection Details"].buttons["Close"].tap()
        return isSaid && app.navigationBars["Connection Details"].waitForNonExistence(timeout: 5)
    }

    /// A session over a REAL QUIC carrier against a REAL daemon, driven:
    /// input, output, resize, scrollback.
    ///
    /// The box this item is actually about. Everything else here is reachable
    /// with no host at all — the toggle exists, the row answers — and none of it
    /// says the phone ever dialled QUIC. This does: it adds a host that prefers
    /// QUIC, opens it, and requires the transport row to read QUIC rather than
    /// the SSH fallback that a failed dial produces.
    ///
    /// The legs after the transport check read what the grid shows, through
    /// the surface's accessibility value — the same text projection VoiceOver
    /// reads. Each one asserts something the phone could not know without the
    /// daemon answering: a sum the shell computed, a width only the resized
    /// pty can report, a line that exists only in scrollback.
    ///
    /// Conditional, and it reports the condition. A live daemon and a real credential
    /// cannot be an unconditional gate — the case would pass on the one machine
    /// that has both and fail everywhere else. Absent the environment it reports
    /// itself skipped and passes, so the executed count stays a count of runs; what it
    /// must never do is quietly assert nothing while looking like coverage.
    func testALiveQUICSessionAttachesAndDrivesAShell() throws {
        let surface = try attachSeededLiveQUICSurface()

        // The transport, before anything else. A QUIC dial that failed leaves a
        // working SSH session, so asserting the shell works would pass either
        // way and prove nothing about the carrier.
        //
        // Matched on the protocol ROW, not a bare "QUIC": SwiftUI composes a
        // LabeledContent's label and value into one accessibility label, so
        // the row reads "Protocol, QUIC" while the connection log below it
        // carries lines like "Asking the host for QUIC connection details". A
        // contains-"QUIC" match found those and passed while the transport was
        // SSH — the exact environment-satisfied assertion this suite exists to
        // refuse. Pinning both words to one label excludes the log.
        // Connection Details is where the screen states its transport.
        openConnectionDetails()
        let transportSaysQUIC = NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@",
            "Protocol",
            "QUIC"
        )
        let quicRow = app.descendants(matching: .any).matching(transportSaysQUIC).firstMatch
        // The list builds rows lazily, so a row below the sheet's fold is not
        // in the tree until the list scrolls to it.
        _ = quicRow.waitForExistence(timeout: 5)
        revealInTheForm(quicRow)
        if !quicRow.waitForExistence(timeout: 15) {
            XCTFail("the transport row did not read QUIC. The sheet held:\n" + app.debugDescription)
        }
        let hostKey = app.descendants(matching: .any).matching(identifier: "terminal-host-key").firstMatch
        revealInTheForm(hostKey)
        XCTAssertTrue(hostKey.waitForExistence(timeout: 5), "QUIC did not expose the authenticated SSH host key")
        XCTAssertTrue(hostKey.label.contains("SHA256:"), "The host key row did not contain a fingerprint")
        dismissSheet()

        // And it is a working terminal, not merely a connected carrier.
        surface.tap()
        XCTAssertTrue(
            app.buttons["terminal-key-Escape"].waitForExistence(timeout: 10),
            "the keyboard never came up, so nothing could be typed"
        )

        // Input and output in one round trip, asserted on a value the typed
        // line does not contain: the command's echo shows "41000+1301", so
        // only the shell computing and answering can put the sum on the grid.
        app.typeText("echo $((41000+1301))\n")
        XCTAssertTrue(
            waitForGrid(surface, toShow: "42301", timeout: 15),
            "the shell's answer never reached the grid. It shows:\n" + gridReport(surface)
        )

        // Resize, proven by the pty rather than the view: tput asks the
        // terminal for its width, so the second answer can only differ if the
        // rotation re-fit reached the daemon's pty. The marker prefixes keep
        // the probes apart from their own echoes — the echo's next character
        // is `$`, which the digit match refuses.
        //
        // Portrait is set outright before the first probe rather than assumed:
        // the simulator boots in whichever orientation it was left, so a probe
        // that read the current width and then asked for landscape would
        // compare landscape against landscape on a device already turned.
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        settleKeyboard(surface)
        app.typeText("echo columns-$(tput cols)\n")
        guard let portraitColumns = waitForGridNumber(surface, after: "columns-", timeout: 15) else {
            XCTFail("the portrait width probe went unanswered. The grid shows:\n" + gridReport(surface))
            return
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        settleKeyboard(surface)
        app.typeText("echo width-$(tput cols)\n")
        guard let landscapeColumns = waitForGridNumber(surface, after: "width-", timeout: 15) else {
            XCTFail("the landscape width probe went unanswered. The grid shows:\n" + gridReport(surface))
            return
        }
        XCTAssertGreaterThan(
            landscapeColumns,
            portraitColumns,
            "rotation did not widen the pty: \(portraitColumns) portrait, \(landscapeColumns) landscape"
        )

        // SCROLLBACK: a marker is pushed off the top of the screen, shown
        // gone, and dragged back into view. Only history can answer it. Eighty
        // lines clear a 24-row screen the marker cannot still be on while
        // staying within reach of a bounded scroll; each drag pulls the
        // viewport back by most of a screen, which a flick-sized swipe does
        // not.
        //
        // Back to portrait first: landscape with the keyboard up leaves the
        // surface a handful of rows tall, and a drag across a strip that short
        // pulls back too few rows for twelve of them to reach the marker.
        XCUIDevice.shared.orientation = .portrait
        settleKeyboard(surface)
        app.typeText("echo scroll-top-marker; seq 1 80\n")
        XCTAssertTrue(
            waitForGrid(surface, toShow: "80", timeout: 20),
            "seq never finished on the grid. It shows:\n" + gridReport(surface)
        )
        XCTAssertFalse(
            gridText(surface).contains("scroll-top-marker"),
            "eighty lines left the marker on screen, so scrolling would prove nothing"
        )
        let dragTop = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let dragBottom = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        var draggedBack = false
        for _ in 0..<12 where !draggedBack {
            dragTop.press(forDuration: 0.05, thenDragTo: dragBottom)
            draggedBack = gridText(surface).contains("scroll-top-marker")
        }
        XCTAssertTrue(
            draggedBack,
            "the marker never came back from scrollback. The grid shows:\n" + gridReport(surface)
        )
    }

    /// An idle QUIC session stays on its first carrier and keeps answering.
    ///
    /// The failure this holds off reads Connected with a blank grid while the
    /// carrier redials every two minutes; an idle attachment whose
    /// probes go unanswered is dropped by the host after its silence bound,
    /// and an unacknowledged connection by the 90 s QUIC idle timeout. The
    /// hold outlasts all three. A redial takes the session out of Connected,
    /// which puts the connection status card on screen, so the hold watches
    /// for that card the whole time rather than only at its end; the closing
    /// round trip proves the carrier still carries.
    func testALiveQUICSessionStaysConnectedThroughAnIdleHold() throws {
        let surface = try attachSeededLiveQUICSurface()
        settleKeyboard(surface)
        app.typeText("echo $((50000+2401))\n")
        XCTAssertTrue(
            waitForGrid(surface, toShow: "52401", timeout: 15),
            "the shell's first answer never reached the grid. It shows:\n" + gridReport(surface)
        )
        let status = app.descendants(matching: .any).matching(identifier: "terminal-connection-status").firstMatch
        let holdEnd = Date(timeIntervalSinceNow: 150)
        while Date() < holdEnd {
            if status.exists {
                XCTFail("the idle session left Connected: \(status.label)")
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        app.typeText("echo $((60000+3502))\n")
        XCTAssertTrue(
            waitForGrid(surface, toShow: "63502", timeout: 15),
            "the shell's answer after the idle hold never reached the grid. It shows:\n" + gridReport(surface)
        )
        XCTAssertFalse(status.exists, "the session was not Connected after the idle hold")
    }

    /// A pinch changes the host's terminal width rather than scaling its pixels.
    func testALiveQUICPinchResizesTheShell() throws {
        let surface = try attachSeededLiveQUICSurface()
        settleKeyboard(surface)
        app.typeText("echo before-$(tput cols)\n")
        let before = try XCTUnwrap(waitForGridNumber(surface, after: "before-", timeout: 15))
        surface.pinch(withScale: 1.5, velocity: 1.0)
        settleKeyboard(surface)
        app.typeText("echo larger-$(tput cols)\n")
        let larger = try XCTUnwrap(waitForGridNumber(surface, after: "larger-", timeout: 15))
        XCTAssertLessThan(larger, before, "Larger text did not reduce the host's column count")
        surface.pinch(withScale: 0.65, velocity: -1.0)
        settleKeyboard(surface)
        app.typeText("echo smaller-$(tput cols)\n")
        let smaller = try XCTUnwrap(waitForGridNumber(surface, after: "smaller-", timeout: 15))
        XCTAssertGreaterThan(smaller, larger, "Smaller text did not increase the host's column count")
    }

    /// Selects a tab only after the host creates it and the surface can display it.
    func testALiveQUICNewTabReceivesInputInItsOwnShell() throws {
        let original = try attachSeededLiveQUICSurface()
        settleKeyboard(original)
        app.typeText("export UBQ_TAB_SOURCE=50000\n")
        putTheTerminalKeyboardAway()
        openTabsAndPanes()
        let newTab = app.buttons["tab-overview-new-tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab-card-"))
            .matching(NSPredicate(format: "NOT (identifier CONTAINS %@)", "-close-"))
        let originalCard = try XCTUnwrap(cards.allElementsBoundByIndex.first(where: { $0.isSelected })?.identifier)
        let before = cards.count
        newTab.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !self.tabOverviewNavigationBar.exists }, "New Tab did not open its terminal")
        let created = app.otherElements["terminal-surface"]
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        settleKeyboard(created)
        app.typeText("echo $(( ${UBQ_TAB_SOURCE:-41000} + 3 ))\n")
        XCTAssertTrue(waitForGrid(created, toShow: "41003", timeout: 15), "New Tab did not focus its own shell")
        putTheTerminalKeyboardAway()
        openTabsAndPanes()
        XCTAssertEqual(cards.count, before + 1, "New Tab drew no new card")
        let createdCard = try XCTUnwrap(
            cards.allElementsBoundByIndex.first(where: { $0.isSelected && $0.identifier != originalCard })?.identifier
        )
        let createdID = createdCard.replacingOccurrences(of: "tab-card-", with: "")
        XCTAssertTrue(app.buttons["tab-card-close-\(createdID)"].waitForExistence(timeout: 5))
        app.buttons["tab-card-close-\(createdID)"].tap()
        XCTAssertTrue(app.buttons["Terminate"].waitForExistence(timeout: 5))
        app.buttons["Terminate"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { cards.count == before }, "the closed tab's card stayed")
        app.descendants(matching: .any)[originalCard].tap()
        let restored = app.otherElements["terminal-surface"]
        settleKeyboard(restored)
        app.typeText("echo $(( ${UBQ_TAB_SOURCE:-41000} + 3 ))\n")
        XCTAssertTrue(waitForGrid(restored, toShow: "50003", timeout: 15), "The original shell did not survive creating and closing a tab")
        app.typeText("unset UBQ_TAB_SOURCE\n")
    }

    /// Every tab keeps its own picture and input after returning to the workspace.
    func testALiveWorkspaceRestoresEveryTabAndItsTheme() throws {
        XCUIDevice.shared.appearance = .light
        let environment = try liveDaemonEnvironment()
        launchAgainstTheLiveHost(environment, openingTheHost: true)
        let surface = terminalAnsweringTheSessionListWithANewSession(timeout: 30)
        chooseTheme("Noir Clair", over: surface)
        assertTheBarAndItsSurroundings(areDark: false, theme: "Noir Clair on the host")
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab-card-"))
            .matching(NSPredicate(format: "NOT (identifier CONTAINS %@)", "-close-"))
        func assertVisibleGridText() {
            Thread.sleep(forTimeInterval: 1.5)
            let pixels = ScreenPixels(XCUIScreen.main.screenshot(), screen: app.windows.firstMatch.frame)
            let grid = surface.frame.insetBy(dx: 8, dy: 8)
            var ink = 0
            var coloredInk = 0
            for y in stride(from: grid.minY, to: grid.maxY, by: 2) {
                for x in stride(from: grid.minX, to: grid.maxX, by: 2) {
                    let point = CGPoint(x: x, y: y)
                    if pixels.luminance(at: point) < 0.45 { ink += 1 }
                    if pixels.channelSpread(at: point) > 0.2 { coloredInk += 1 }
                }
            }
            XCTAssertGreaterThan(ink, 160, "the model has text but the displayed pane contains only a cursor")
            XCTAssertGreaterThan(coloredInk, 40, "the pane lost its ANSI colors")
        }
        var identities: [String] = []
        for index in 0..<4 {
            if index > 0 {
                openTabsAndPanes()
                app.buttons["tab-overview-new-tab"].tap()
                XCTAssertTrue(waitUntil(timeout: 15) { !self.tabOverviewNavigationBar.exists }, "New Tab did not open its terminal")
            }
            settleKeyboard(surface)
            app.typeText("export UBQ_PANE_NUMBER=\(index + 1); echo $((UBQ_PANE_NUMBER+76000))\n")
            XCTAssertTrue(waitForGrid(surface, toShow: String(76001 + index), timeout: 15))
            app.typeText("printf '\\033[31mRED RED RED\\033[32m GREEN GREEN\\033[34m BLUE BLUE\\033[0m\\n'\n")
            XCTAssertTrue(waitForGrid(surface, toShow: "BLUE BLUE", timeout: 15))
            putTheTerminalKeyboardAway()
            openTabsAndPanes()
            identities.append(try XCTUnwrap(cards.allElementsBoundByIndex.first(where: { $0.isSelected })?.identifier))
            app.buttons["tab-overview-done"].tap()
        }
        app.terminate()
        launchAgainstTheLiveHost(environment, openingTheHost: false)
        XCTAssertTrue(liveRow.waitForExistence(timeout: 15))
        liveRow.tap()
        XCTAssertTrue(workspacesScreen.waitForExistence(timeout: 30))
        let workspace = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "host-outline-row-workspace-"))
            .firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 30))
        func openThirdTabFromHosts() {
            leaveTheTerminal()
            let back = app.navigationBars.buttons["Hosts"].firstMatch
            if back.waitForExistence(timeout: 3) { back.tap() }
            XCTAssertTrue(liveRow.waitForExistence(timeout: 10))
            let tabID = identities[2].replacingOccurrences(of: "tab-card-", with: "")
            let row = app.descendants(matching: .any)["hosts-host-outline-row-tab-\(tabID)"].firstMatch
            if !row.exists {
                let fold = app.buttons
                    .matching(
                        NSPredicate(
                            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label == %@",
                            "host-outline-row-workspace-",
                            "-fold",
                            "Expand"
                        )
                    )
                    .firstMatch
                XCTAssertTrue(fold.waitForExistence(timeout: 10), "the live workspace has no disclosure: \(app.debugDescription)")
                fold.tap()
            }
            XCTAssertTrue(row.waitForExistence(timeout: 10), "the third tab is absent from Hosts: \(app.debugDescription)")
            row.tap()
            XCTAssertTrue(surface.waitForExistence(timeout: 15))
            XCTAssertTrue(
                waitForGrid(surface, toShow: "76003", timeout: 15),
                "Hosts opened another pane instead of the third tab:\n" + gridReport(surface)
            )
            assertVisibleGridText()
        }
        openThirdTabFromHosts()
        openTabsAndPanes()
        app.descendants(matching: .any)[identities[3]].firstMatch.tap()
        XCTAssertTrue(waitForGrid(surface, toShow: "76004", timeout: 15))
        openThirdTabFromHosts()
        for (index, identity) in identities.enumerated() {
            openTabsAndPanes()
            app.descendants(matching: .any)[identity].firstMatch.tap()
            XCTAssertTrue(waitForGrid(surface, toShow: String(76001 + index), timeout: 15), "tab \(index + 1) lost its picture")
            assertVisibleGridText()
            let height = surface.frame.height
            settleKeyboard(surface)
            XCTAssertTrue(waitUntil(timeout: 5) { surface.frame.height < height - 100 }, "the keyboard did not resize tab \(index + 1)")
            app.typeText("echo $((UBQ_PANE_NUMBER+87000))\n")
            XCTAssertTrue(waitForGrid(surface, toShow: String(87001 + index), timeout: 15), "input reached the wrong tab")
            app.typeText("trap 'echo expanded-$(stty size)' WINCH; echo compact-$(stty size)\n")
            let compactRows = try XCTUnwrap(waitForGridNumber(surface, after: "compact-", timeout: 15))
            putTheTerminalKeyboardAway()
            let expandedRows = try XCTUnwrap(waitForGridNumber(surface, after: "expanded-", timeout: 15))
            XCTAssertGreaterThan(expandedRows, compactRows, "the host PTY did not grow when the keyboard left tab \(index + 1)")
            assertTheBarAndItsSurroundings(areDark: false, theme: "Noir Clair in tab \(index + 1)")
        }
        surface.swipeRight()
        XCTAssertTrue(waitForGrid(surface, toShow: "76003", timeout: 15), "swiping right did not reveal the third tab")
        assertVisibleGridText()
        surface.swipeLeft()
        XCTAssertTrue(waitForGrid(surface, toShow: "76004", timeout: 15), "swiping left did not reveal the fourth tab")
        assertVisibleGridText()
        chooseTheme("Noir", over: surface)
        assertTheBarAndItsSurroundings(areDark: true, theme: "Noir on the host")
        settleKeyboard(surface)
        app.typeText("trap - WINCH; mode=$(stty -g); stty -echo -icanon min 1 time 0; od -An -tx1 -N6; stty \"$mode\"\n")
        app.buttons["terminal-function-keys"].tap()
        app.buttons["terminal-modifier-Shift"].tap()
        app.buttons["terminal-key-Left Arrow"].tap()
        XCTAssertTrue(
            waitUntil(timeout: 15) {
                self.gridText(surface).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    .contains("1b 5b 31 3b 32 44")
            },
            "Shift + Left did not reach the host. It shows:\n" + gridReport(surface)
        )
    }

    /// A live QUIC session survives the app being backgrounded and returns
    /// driveable, bound to the surviving daemon session rather than a new one.
    ///
    /// The reattach half of the continuity story, as far as the simulator
    /// reaches. What a device adds — iOS suspending a backgrounded app's
    /// sockets, so the carrier actually drops and the redial-by-sessionID path
    /// runs — the simulator does not reproduce: here the connection survives,
    /// so this proves the weaker but real property that backgrounding neither
    /// tears the session down nor loses its state and the shell still answers
    /// on return. The daemon-session reattach under a genuine drop is the
    /// hardware boxes.
    ///
    /// Marker before, marker after: a line printed before backgrounding is
    /// still on the grid after returning, which a session replaced by a fresh
    /// shell would not show; a fresh command answered afterwards proves input
    /// and output still cross the carrier.
    func testALiveQUICSessionSurvivesBackgrounding() throws {
        let surface = try attachSeededLiveQUICSurface()

        surface.tap()
        XCTAssertTrue(
            app.buttons["terminal-key-Escape"].waitForExistence(timeout: 10),
            "the keyboard never came up, so nothing could be typed"
        )
        app.typeText("echo before-background-marker\n")
        XCTAssertTrue(
            waitForGrid(surface, toShow: "before-background-marker", timeout: 15),
            "the marker never reached the grid before backgrounding. It shows:\n" + gridReport(surface)
        )

        // Home, a real pause, then back. The pause is long enough for iOS to
        // act on the transition on a device; on the simulator it is dead time,
        // and the session is expected to be intact either way.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "the app did not return to the foreground"
        )

        let returned = app.otherElements["terminal-surface"]
        XCTAssertTrue(
            returned.waitForExistence(timeout: 20),
            "the terminal did not come back after returning from the background"
        )
        XCTAssertTrue(
            waitForGrid(returned, toShow: "before-background-marker", timeout: 10),
            "the pre-background line is gone — a new session replaced the surviving one. The grid shows:\n"
                + gridReport(returned)
        )

        // And it still drives.
        settleKeyboard(returned)
        app.typeText("echo $((6*9))\n")
        XCTAssertTrue(
            waitForGrid(returned, toShow: "54", timeout: 15),
            "the session did not drive after returning from the background. It shows:\n" + gridReport(returned)
        )
    }

    /// A session the daemon is holding is listed, chosen, and attached to; a
    /// new session is a different one.
    ///
    /// The box this screen exists for. Everything the offline lane covers is
    /// reachable with rows nobody's host answered — the list draws, the swipe
    /// offers — and none of it says a listing crosses the wire or that a chosen
    /// row re-homes to the shell that was running. This does: a marker is typed
    /// into a session, the app is killed so nothing in this process carries the
    /// pairing, and the session is found in the host's own answer and picked. A
    /// fresh shell would not have the marker, so a picker that quietly opened
    /// one instead reddens on the same assertion.
    ///
    /// Nothing is set up for the session to survive the kill: every session a
    /// host holds outlives the client that opened it, named or unnamed, until
    /// it is terminated from the session list. The host editor offers no
    /// switch for it, and the case asks for none.
    ///
    /// Conditional, and it reports the condition, the way the other live cases
    /// are: a live daemon and a real credential cannot be an unconditional
    /// gate.
    func testALiveQUICSessionAttachesToASessionChosenFromTheList() throws {
        let environment = try liveDaemonEnvironment()

        launchAgainstTheLiveHost(environment, openingTheHost: false)
        XCTAssertTrue(
            liveRow.waitForExistence(timeout: 15),
            "the seeded live host is not in the list. On screen instead:\n" + app.debugDescription
        )

        // The marker, on a session the host will still hold once this app is
        // gone.
        liveRow.tap()
        let first = terminalAnsweringTheSessionListWithANewSession(timeout: 30)
        settleKeyboard(first)
        app.typeText("echo choose-me-marker\n")
        XCTAssertTrue(
            waitForGrid(first, toShow: "choose-me-marker", timeout: 20),
            "the marker never reached the grid. It shows:\n" + gridReport(first)
        )

        // A new process. What crosses is the host's own list and the pairing
        // Core kept in the saved host, and nothing else.
        app.terminate()
        launchAgainstTheLiveHost(environment, openingTheHost: false)
        XCTAssertTrue(liveRow.waitForExistence(timeout: 15), "the seeded live host is not in the list")
        liveRow.tap()
        XCTAssertTrue(
            workspacesScreen.waitForExistence(timeout: 30),
            "the host listed no sessions, so there was nothing to choose. On screen instead:\n"
                + app.debugDescription
        )
        // The first workspace's row: the host holds the one session this
        // case started, so its outline has one workspace.
        let listedSession = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "host-outline-row-workspace-"))
            .firstMatch
        XCTAssertTrue(
            listedSession.waitForExistence(timeout: 10),
            "the session list came up with no rows. It held:\n" + app.debugDescription
        )
        listedSession.tap()
        let chosen = app.otherElements["terminal-surface"]
        XCTAssertTrue(
            chosen.waitForExistence(timeout: 30),
            "choosing a session did not open a terminal. On screen instead:\n" + app.debugDescription
        )
        XCTAssertTrue(
            waitForGrid(chosen, toShow: "choose-me-marker", timeout: 25),
            "the chosen row did not re-home to the session that was running. It shows:\n"
                + gridReport(chosen)
        )

        // And a new session is a different session: the marker cannot be on it.
        app.terminate()
        launchAgainstTheLiveHost(environment, openingTheHost: false)
        XCTAssertTrue(liveRow.waitForExistence(timeout: 15), "the seeded live host is not in the list")
        liveRow.tap()
        XCTAssertTrue(
            workspacesScreen.waitForExistence(timeout: 30),
            "the host listed no sessions the second time. On screen instead:\n" + app.debugDescription
        )
        // New Workspace asks for a name on a host that holds one; the helper
        // answers it the way it answers the list.
        let fresh = terminalAnsweringTheSessionListWithANewSession(timeout: 30)
        settleKeyboard(fresh)
        app.typeText("echo fresh-session-marker\n")
        XCTAssertTrue(
            waitForGrid(fresh, toShow: "fresh-session-marker", timeout: 20),
            "the new session never answered. It shows:\n" + gridReport(fresh)
        )
        XCTAssertFalse(
            gridText(fresh).contains("choose-me-marker"),
            "New Workspace landed on the session that was already running. It shows:\n" + gridReport(fresh)
        )
    }

    /// A workspace the host already runs shows its screen the first time a
    /// fresh launch joins it, not only once the terminal is closed and opened
    /// again.
    ///
    /// The marker is written once, by the launch that starts the workspace,
    /// into both of its tabs, on a green bar; every later launch only joins,
    /// from the host's workspaces, alternately at the size it was started at
    /// and at another. Only the host's checkpoint can put the marker on a
    /// joined grid, and only a drawn frame of that checkpoint puts the bar on
    /// the glass, so each join reads both: the grid's text and the
    /// screenshot's. A prompt, a cursor or a frame drawn before the
    /// checkpoint landed has no run of ink as long as the bar.
    ///
    /// The workspace is terminated from the host's workspaces once the case
    /// ends, whether it passed or stopped at a failure, so a run leaves
    /// nothing on the host for the live cases after it to find.
    func testALiveWorkspaceJoinedOnAFreshLaunchShowsItsScreen() throws {
        var environment = try liveDaemonEnvironment()
        environment["UBQ_LIVE_WORKSPACE"] = "join-\(UUID().uuidString.prefix(8).lowercased())"
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        launchAgainstTheLiveHost(environment, openingTheHost: true)
        let started = app.otherElements["terminal-surface"]
        XCTAssertTrue(
            started.waitForExistence(timeout: 30),
            "the named workspace did not open a terminal. On screen instead:\n" + app.debugDescription
        )
        let workspaceName = environment["UBQ_LIVE_WORKSPACE"] ?? ""
        // Empty rather than unset, which would keep the stored name and open
        // the workspace straight away instead of from the list.
        environment["UBQ_LIVE_WORKSPACE"] = ""
        let joining = environment
        addTeardownBlock { @MainActor [self] in
            terminateTheLiveWorkspace(named: workspaceName, joining)
        }
        let unbarred = ScreenPixels(XCUIScreen.main.screenshot(), screen: app.windows.firstMatch.frame)
        XCTAssertLessThan(
            unbarred.longestInkRunFraction(in: Self.topThird(of: started.frame)),
            0.25,
            "a shell's own screen reads as the bar, so the drawn check below proves nothing"
        )
        settleKeyboard(started)
        let marker = "joined-\(Int.random(in: 100_000...999_999))"
        // The bar is the erased rest of the marker's row, in the green the
        // erase takes from the current background: as far from a dark ground
        // as from a light one.
        let barred = "printf '\\033[42m%s\\033[K\\033[0m\\n' \(marker)\n"
        app.typeText(barred)
        XCTAssertTrue(
            waitForGrid(started, toShow: marker, timeout: 20),
            "the marker never reached the grid. It shows:\n" + gridReport(started)
        )
        // A second tab, so the join binds a pane beside the one it opens.
        putTheTerminalKeyboardAway()
        openTabsAndPanes()
        let newTab = app.buttons["tab-overview-new-tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 5), "the tab overview offers no new tab")
        newTab.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !self.tabOverviewNavigationBar.exists }, "New Tab did not open its terminal")
        let second = app.otherElements["terminal-surface"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        settleKeyboard(second)
        app.typeText(barred)
        XCTAssertTrue(
            waitForGrid(second, toShow: marker, timeout: 20),
            "the second tab never showed the marker. It shows:\n" + gridReport(second)
        )
        for join in 1...4 {
            app.terminate()
            // Every other join at another size, as a workspace another device
            // opened is joined.
            XCUIDevice.shared.orientation = join.isMultiple(of: 2) ? .portrait : .landscapeLeft
            launchAgainstTheLiveHost(environment, openingTheHost: false)
            XCTAssertTrue(liveRow.waitForExistence(timeout: 15), "the seeded live host is not in the list")
            liveRow.tap()
            XCTAssertTrue(
                workspacesScreen.waitForExistence(timeout: 30),
                "join \(join) listed no workspaces. On screen instead:\n" + app.debugDescription
            )
            let row = app.descendants(matching: .any)
                .matching(
                    NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "host-outline-row-workspace-", workspaceName)
                )
                .firstMatch
            XCTAssertTrue(
                row.waitForExistence(timeout: 15),
                "join \(join) did not list the workspace. On screen instead:\n" + app.debugDescription
            )
            row.tap()
            let joined = app.otherElements["terminal-surface"]
            XCTAssertTrue(
                joined.waitForExistence(timeout: 30),
                "join \(join) did not open a terminal. On screen instead:\n" + app.debugDescription
            )
            XCTAssertTrue(
                waitForGrid(joined, toShow: marker, timeout: 20),
                "join \(join) showed the workspace without its screen. It shows:\n" + gridReport(joined)
            )
            // The grid is the model's; what the person sees is the drawn
            // frame, which has to carry the checkpoint too.
            XCTAssertTrue(
                waitForBar(on: joined, timeout: 10, naming: "join-\(join)-without-its-bar"),
                "join \(join) holds the screen but drew no frame of it. The grid holds:\n" + gridReport(joined)
            )
        }
    }

    /// Ends a workspace the case started, from the host's workspaces on a
    /// fresh launch, and waits for the host to stop listing it.
    ///
    /// - Parameters:
    ///   - workspaceName: The workspace's name.
    ///   - environment: The live host's launch environment.
    private func terminateTheLiveWorkspace(named workspaceName: String, _ environment: [String: String]) {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        launchAgainstTheLiveHost(environment, openingTheHost: false)
        XCTAssertTrue(liveRow.waitForExistence(timeout: 15), "the seeded live host is not in the list")
        liveRow.tap()
        XCTAssertTrue(workspacesScreen.waitForExistence(timeout: 30), "the host listed no workspaces to end")
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "host-outline-row-workspace-", workspaceName))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the workspace to end is not listed")
        row.swipeLeft()
        let terminate = app.buttons["Terminate"].firstMatch
        XCTAssertTrue(terminate.waitForExistence(timeout: 5), "the workspace's row offered no Terminate")
        terminate.tap()
        let question = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Terminate \(workspaceName)")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5), "Terminate asked nothing. On screen:\n" + app.debugDescription)
        // The question's own button, the last one so named: the row's swipe
        // action can stay behind it.
        let confirm = app.buttons.matching(identifier: "Terminate").allElementsBoundByIndex.last ?? terminate
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 30), "the host still lists the workspace the case ended")
    }

    /// Polls the drawn surface until it shows an unbroken run of ink a quarter
    /// of its width long, which only a bar draws: glyphs break every run at
    /// the gaps between them.
    ///
    /// Reads the top third of the surface, where a fresh shell's first rows
    /// put the bar, and which neither the keyboard nor the bottom bar covers.
    /// Keeps the last screenshot as an attachment when no frame shows one.
    ///
    /// - Parameters:
    ///   - surface: The terminal surface element.
    ///   - timeout: How long to keep polling.
    ///   - name: The attachment's name.
    /// - Returns: Whether a drawn frame carried the bar.
    private func waitForBar(on surface: XCUIElement, timeout: TimeInterval, naming name: String) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var screenshot = XCUIScreen.main.screenshot()
        repeat {
            screenshot = XCUIScreen.main.screenshot()
            let pixels = ScreenPixels(screenshot, screen: app.windows.firstMatch.frame)
            if pixels.longestInkRunFraction(in: Self.topThird(of: surface.frame)) > 0.25 { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        let picture = XCTAttachment(screenshot: screenshot)
        picture.name = name
        picture.lifetime = .keepAlways
        add(picture)
        return false
    }

    /// The top third of a frame.
    private static func topThird(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 3)
    }

    /// Seeds a QUIC-preferring live host and returns its terminal surface once
    /// it has appeared, or skips the case when no live daemon is configured.
    ///
    /// The shared front of the live cases: the host is handed in through the
    /// store under `--seed-live-host` and opened by its fixed identifier
    /// through the app's own UBIQUITTY_IOS_OPEN_HOST seam, so the key reaches
    /// the parser byte-for-byte rather than through the simulator keyboard and
    /// nothing taps a row that races the list settling. See LiveHostSeed; the
    /// identifier is its own, kept in step by hand.
    ///
    /// - Returns: The terminal surface, attached against the live host.
    private func attachSeededLiveQUICSurface() throws -> XCUIElement {
        let environment = try liveDaemonEnvironment()
        launchAgainstTheLiveHost(environment, openingTheHost: true)
        return terminalAnsweringTheSessionListWithANewSession(timeout: 30)
    }

    /// The live daemon's connection details, or a skip when there is none.
    ///
    /// - Returns: The host, the user and the key, all non-empty, and the port
    ///   when one is set.
    private func liveDaemonEnvironment() throws -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        guard let liveHost = environment["UBQ_LIVE_SSH_HOST"],
            let liveUser = environment["UBQ_LIVE_SSH_USER"],
            let liveKey = environment["UBQ_LIVE_SSH_KEY"],
            !liveHost.isEmpty, !liveUser.isEmpty, !liveKey.isEmpty
        else {
            throw XCTSkip(
                "no live daemon configured — set UBQ_LIVE_SSH_HOST, UBQ_LIVE_SSH_USER "
                    + "and UBQ_LIVE_SSH_KEY_FILE to run the real QUIC attach"
            )
        }
        var details = [
            "UBQ_LIVE_SSH_HOST": liveHost,
            "UBQ_LIVE_SSH_USER": liveUser,
            "UBQ_LIVE_SSH_KEY": liveKey,
        ]
        if let livePort = environment["UBQ_LIVE_SSH_PORT"], !livePort.isEmpty {
            details["UBQ_LIVE_SSH_PORT"] = livePort
        }
        return details
    }

    /// Launches with the live host seeded into the store.
    ///
    /// The host is handed in under `--seed-live-host` rather than typed, so the
    /// key reaches the parser byte-for-byte rather than through the simulator
    /// keyboard. See LiveHostSeed; the identifier below is its own, kept in
    /// step by hand.
    ///
    /// - Parameters:
    ///   - environment: The live daemon's details.
    ///   - openingTheHost: Whether to open the host on launch, which is what a
    ///     case wanting a shell asks for; a case that drives the host list taps
    ///     the row itself.
    private func launchAgainstTheLiveHost(_ environment: [String: String], openingTheHost: Bool) {
        let seedIdentifier = "00000000-0000-0000-0000-0000000C0DEC"
        let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        seeded.launchArguments = ["--seed-live-host"]
        var launchEnvironment = environment
        if openingTheHost {
            launchEnvironment["UBIQUITTY_IOS_OPEN_HOST"] = seedIdentifier
        }
        seeded.launchEnvironment = launchEnvironment
        seeded.launch()
    }

    /// Reveals the workspace action grouped in the narrow iPad sidebar.
    private func revealNewWorkspaceAction() {
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        guard !newWorkspace.exists || !newWorkspace.isHittable else { return }
        let actions = app.buttons["workspace-actions"].firstMatch
        if actions.exists, actions.isHittable {
            actions.tap()
        }
    }

    /// Waits for a terminal, answering the session list with a new session if
    /// one comes up on the way.
    ///
    /// A host already holding sessions asks which one to open, and the cases
    /// that want a shell to drive want any of them — so the question is
    /// answered rather than waited out. A host holding none never asks: Core's
    /// plan for an empty host is a new session, and the screen forwards without
    /// showing a list. From the list, New Workspace asks for a name; the
    /// question is answered with none, which names the workspace after its
    /// folder.
    ///
    /// - Parameter timeout: How long to keep answering and waiting.
    /// - Returns: The terminal surface.
    private func terminalAnsweringTheSessionListWithANewSession(timeout: TimeInterval) -> XCUIElement {
        let surface = app.otherElements["terminal-surface"]
        // A row the host answered with. An empty host's list can show for a
        // moment before Core forwards to a new session; a New Workspace tapped
        // in that moment raises an alert the forward then takes away.
        let workspaceRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "host-outline-row-workspace-")).firstMatch
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !surface.exists, Date() < deadline {
            let create = app.alerts["New Workspace"].buttons["Create"]
            if create.exists, create.isHittable {
                create.tap()
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            guard workspaceRow.exists else {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            revealNewWorkspaceAction()
            let newSession = app.buttons["New Workspace"].firstMatch
            if newSession.exists, newSession.isHittable {
                newSession.tap()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(
            surface.waitForExistence(timeout: 20),
            "the terminal never appeared against the live host. On screen instead:\n"
                + app.debugDescription
        )
        return surface
    }

    /// The grid's visible text, read through the surface's accessibility
    /// value — empty when the surface publishes none.
    private func gridText(_ surface: XCUIElement) -> String {
        (surface.value as? String) ?? ""
    }

    /// Makes sure the keyboard is up so the next typeText has a first responder.
    ///
    /// XCTest can report a hardware keyboard after injecting keys, making a
    /// surface tap a terminal click. The explicit keyboard control also works
    /// in that state; Escape in its accessory proves the software keyboard is up.
    private func settleKeyboard(_ surface: XCUIElement) {
        guard !app.buttons["terminal-key-Escape"].waitForExistence(timeout: 3) else { return }
        let keyboard = app.buttons["terminal-keyboard"]
        if keyboard.exists { keyboard.tap() } else { surface.tap() }
        XCTAssertTrue(
            app.buttons["terminal-key-Escape"].waitForExistence(timeout: 10),
            "the keyboard did not come up, so nothing could be typed"
        )
    }

    /// What a failed grid read has to say for itself: the text it saw, then
    /// the element as the accessibility tree presents it. An empty value can
    /// be an empty screen, a surface publishing no value at all, or a query
    /// resolving to a wrapper that carries the identifier and not the value,
    /// and only the tree's own description tells those apart.
    private func gridReport(_ surface: XCUIElement) -> String {
        "\"" + gridText(surface) + "\"\nas the tree presents it:\n" + surface.debugDescription
    }

    /// Polls the grid until it shows the needle.
    ///
    /// - Parameters:
    ///   - surface: The terminal surface element.
    ///   - needle: The text that must appear.
    ///   - timeout: How long to keep polling.
    /// - Returns: Whether the needle appeared.
    private func waitForGrid(_ surface: XCUIElement, toShow needle: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if gridText(surface).contains(needle) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return gridText(surface).contains(needle)
    }

    /// Polls the grid for a number directly following a marker.
    ///
    /// - Parameters:
    ///   - surface: The terminal surface element.
    ///   - marker: The text the digits must follow.
    ///   - timeout: How long to keep polling.
    /// - Returns: The first such number, or nil when none appeared.
    private func waitForGridNumber(_ surface: XCUIElement, after marker: String, timeout: TimeInterval) -> Int? {
        let pattern = NSRegularExpression.escapedPattern(for: marker) + "([0-9]+)"
        let expression = try? NSRegularExpression(pattern: pattern)
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            let text = gridText(surface)
            if let expression,
                let match = expression.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)
                ),
                let range = Range(match.range(at: 1), in: text),
                let number = Int(text[range])
            {
                return number
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    /// The row for the live host.
    private var liveRow: XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", Self.liveHostName))
            .firstMatch
    }

    // MARK: - Getting to a terminal, the way a person does

    /// Brings the bottom bar back where a short window has put it away, the
    /// way a person does: one tap on the grid.
    private func revealTheBottomBar() {
        guard !app.buttons["terminal-keyboard"].exists else { return }
        let surface = app.otherElements["terminal-surface"].firstMatch
        guard surface.exists else { return }
        surface.tap()
        _ = app.buttons["terminal-keyboard"].waitForExistence(timeout: 5)
    }

    /// Opens the menu holding the terminal's less-used actions.
    ///
    /// The system owns the overflow menu's label and its place: the navigation
    /// bar on a compact phone, a vertical bar beside the terminal on iPhone Duo.
    /// Its actions keep their own names.
    /// Leaves the sheet on screen by its finishing button: Done where it
    /// finishes something, the system's close button where it only shows.
    private func dismissSheet() {
        let button = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Close"])).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the sheet has no Done or close button:\n" + app.debugDescription)
        button.tap()
    }

    /// The More menu's Files item. A menu section does not carry an item's
    /// identifier into the tree on every toolkit, so its title answers too.
    private var filesMenuItem: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "terminal-files-menu", "Files…")).firstMatch
    }

    /// The More menu's Find in Scrollback item, found the same way.
    private var findMenuItem: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "terminal-find-menu", "Find in Scrollback…"))
            .firstMatch
    }

    /// The overview reached from Tabs, the wide title menu, or the side rail.
    private var tabOverviewNavigationBar: XCUIElement {
        app.navigationBars.matching(NSPredicate(format: "identifier MATCHES %@ OR label MATCHES %@", "[0-9]+ Tabs?", "[0-9]+ Tabs?"))
            .firstMatch
    }

    private func openTabsAndPanes() {
        let tabs = app.buttons["terminal-tabs"]
        let nativeTitle = app.navigationBars.buttons[Self.hostName].firstMatch
        if nativeTitle.exists && nativeTitle.isHittable {
            nativeTitle.tap()
            let overview = app.buttons["Show All Tabs"].firstMatch
            XCTAssertTrue(overview.waitForExistence(timeout: 5), "the title menu has no tab overview:\n" + app.debugDescription)
            overview.tap()
            return
        }
        if !tabs.waitForExistence(timeout: 2) {
            revealTheBottomBar()
        }
        if tabs.exists && tabs.isHittable {
            tabs.tap()
        } else {
            openTheOverflowMenu()
            let overview = app.buttons["Show All Tabs"].firstMatch
            XCTAssertTrue(overview.waitForExistence(timeout: 5), "the rail has no tab overview:\n" + app.debugDescription)
            overview.tap()
        }
    }

    /// The system menu scrolls when accessibility text makes it taller than
    /// its presentation. Its later items are created only as they approach.
    private func revealInTheMenu(_ item: XCUIElement) {
        guard !item.exists || !item.isHittable else { return }
        // The native overflow menu exposes its actions without a scroll-view
        // ancestor. Keep the gesture inside its first visible action's column.
        let first = app.buttons["Paste"]
        XCTAssertTrue(first.waitForExistence(timeout: 2), "the overflow menu is not open")
        let frame = first.frame
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let x = frame.midX - window.frame.minX
        let start = origin.withOffset(CGVector(dx: x, dy: min(frame.maxY + 160, window.frame.maxY - 40) - window.frame.minY))
        let end = origin.withOffset(CGVector(dx: x, dy: frame.minY + 10 - window.frame.minY))
        for _ in 0..<10 where !item.exists || !item.isHittable {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(item.exists && item.isHittable, "the menu item is not reachable:\n" + app.debugDescription)
    }

    private func openTheOverflowMenu() {
        let systemMenu = app.buttons["More"].firstMatch
        if !systemMenu.waitForExistence(timeout: 2) {
            revealTheBottomBar()
        }
        XCTAssertTrue(
            systemMenu.waitForExistence(timeout: 5),
            "the system overflow menu is not on screen:\n" + app.debugDescription
        )
        systemMenu.tap()
        let paste = app.buttons["Paste"]
        XCTAssertTrue(
            waitUntil(timeout: 5) { paste.exists && paste.isHittable },
            "the overflow menu did not finish presenting:\n" + app.debugDescription
        )
    }

    private func openConnectionDetails() {
        openTheOverflowMenu()
        let details = app.buttons["Connection Details"]
        revealInTheMenu(details)
        details.tap()
        XCTAssertTrue(app.navigationBars["Connection Details"].waitForExistence(timeout: 5))
    }

    /// Changes a host override while checking that its sheet keeps the system appearance.
    private func chooseTheme(_ name: String, over surface: XCUIElement) {
        openConnectionDetails()
        let details = app.navigationBars["Connection Details"]
        let title = details.staticTexts["Connection Details"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the sheet's title is missing")
        assertTheSheetKeepsTheSystemScheme(titledBy: title)
        let picker = app.buttons["terminal-host-theme"].firstMatch
        revealInTheForm(picker)
        picker.tap()
        let choice = app.buttons[name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        dismissSheet()
        XCTAssertTrue(details.waitForNonExistence(timeout: 5))
    }

    /// Asserts a sheet draws in the system's scheme, whatever the ground's.
    ///
    /// Read from its title, not its surface: a sheet at its middle height is
    /// glass, and its surface takes some of the ground through it, while the
    /// title's ink is black in the light scheme and white in the dark one.
    /// The ink is whichever extreme along the title's middle row lies further
    /// from the sheet's surface beside it.
    private func assertTheSheetKeepsTheSystemScheme(titledBy title: XCUIElement) {
        // The sheet rises into place; a picture taken while it moves reads
        // the ground through a sheet that is not there yet.
        Thread.sleep(forTimeInterval: 1)
        let pixels = ScreenPixels(XCUIScreen.main.screenshot(), screen: app.windows.firstMatch.frame)
        let frame = title.frame
        let surface = pixels.luminance(at: CGPoint(x: frame.minX - 12, y: frame.midY))
        let row = stride(from: frame.minX + 1, through: frame.maxX - 1, by: 0.5)
            .map { pixels.luminance(at: CGPoint(x: $0, y: frame.midY)) }
        let darkest = row.min() ?? .nan
        let lightest = row.max() ?? .nan
        let isInkDark = surface - darkest > lightest - surface
        let isSystemDark = XCUIDevice.shared.appearance == .dark
        XCTAssertEqual(
            isInkDark,
            !isSystemDark,
            "the sheet's title is drawn in the \(isInkDark ? "light" : "dark") scheme while the system is "
                + "\(isSystemDark ? "dark" : "light"): surface \(surface), ink from \(darkest) to \(lightest)"
        )
    }

    /// Reads the bar's glass and the band below it from a picture of the
    /// screen, and asserts both read as the ground's scheme.
    ///
    /// The glass is sampled between the way back and the keyboard button,
    /// where no glyph is drawn; the band halfway between the glass and the
    /// screen's bottom edge, where an opaque system bar would show.
    private func assertTheBarAndItsSurroundings(areDark: Bool, theme: String) {
        let leave = app.buttons["terminal-leave"]
        let keyboard = app.buttons["terminal-keyboard"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5) && keyboard.exists, "the bottom bar is not on screen")
        // The glass eases into its new tint; a picture taken mid-change reads
        // neither scheme.
        Thread.sleep(forTimeInterval: 1.5)
        let screen = app.windows.firstMatch.frame
        let glass = CGPoint(x: (leave.frame.maxX + keyboard.frame.minX) / 2, y: leave.frame.midY)
        let band = CGPoint(x: screen.midX, y: (leave.frame.maxY + 6 + screen.maxY) / 2)
        let pixels = ScreenPixels(XCUIScreen.main.screenshot(), screen: screen)
        for (place, point) in [("the bar's glass", glass), ("the band below the bar", band)] {
            let luminance = pixels.luminance(at: point)
            if areDark {
                XCTAssertLessThan(luminance, 0.35, "\(place) is light on the dark ground of \(theme): luminance \(luminance)")
            } else {
                XCTAssertGreaterThan(luminance, 0.65, "\(place) is dark on the light ground of \(theme): luminance \(luminance)")
            }
        }
    }

    /// Whether the settings sheet is currently up.
    private var settingsIsUp: Bool { app.navigationBars["Settings"].exists }

    /// The notice a swipe raises over the grid.
    private var toast: XCUIElement {
        app.descendants(matching: .any)["terminal-toast"].firstMatch
    }

    /// Watches for the notice saying something, and answers whether it did.
    ///
    /// Polled by hand rather than through `waitForExistence`, whose predicate
    /// waiter looks once a second: the notice stands for little more than a
    /// second, and a waiter whose first look lands after it has gone reads a
    /// notice that was shown as one that never was. The text is part of the
    /// query rather than read off the element afterwards, so a notice that
    /// clears between the two looks cannot fail the read.
    ///
    /// - Parameters:
    ///   - text: What the notice must contain.
    ///   - timeout: How long to watch.
    /// - Returns: Whether a notice containing the text came up.
    private func watchForToast(saying text: String, timeout: TimeInterval) -> Bool {
        let saying = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "terminal-toast", text))
            .firstMatch
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if saying.exists {
                return true
            }
        } while Date() < deadline
        return false
    }

    /// Watches for any notice at all, and answers whether one came up.
    ///
    /// - Parameter timeout: How long to watch.
    /// - Returns: Whether a notice appeared.
    private func watchForAnyToast(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if toast.exists {
                return true
            }
        } while Date() < deadline
        return false
    }

    /// Drags two fingers together across most of an element's width.
    ///
    /// Built on the synthesiser XCUITest's own multi-touch gestures use: one
    /// pointer path per finger, both in one event record so they land as one
    /// two-touch sequence. The fingers keep a fixed distance, so the pinch
    /// recogniser sees no change of scale, and they move over a third of a
    /// second — slow enough that UIKit reports a pan rather than losing the
    /// middle of it.
    ///
    /// The classes are private to the runner and reached by name, so their
    /// absence fails the case by name rather than leaving a gesture that did
    /// nothing.
    ///
    /// - Parameters:
    ///   - element: What to swipe across.
    ///   - leftward: Whether the fingers travel left; rightward otherwise.
    ///   - secondFingerDelay: How long after the first finger the second lands,
    ///     where the first has got to by then; zero lands both together.
    private func twoFingerSwipe(
        across element: XCUIElement,
        leftward: Bool,
        secondFingerDelay: Double = 0
    ) throws {
        let frame = element.frame
        let startX = frame.minX + frame.width * (leftward ? 0.85 : 0.15)
        let endX = frame.minX + frame.width * (leftward ? 0.15 : 0.85)
        let upperY = frame.midY - 40
        let lowerY = frame.midY + 40
        let duration = 0.35
        let steps = 12
        // Where finger `index` is at `time`: both travel together, a fixed distance apart.
        func point(finger index: Int, at time: Double) -> CGPoint {
            CGPoint(x: startX + (endX - startX) * CGFloat(time / duration), y: index == 0 ? upperY : lowerY)
        }
        let times = (1...steps).map { duration * Double($0) / Double(steps) }
        synthesizeTwoFingers(
            named: "two-finger swipe",
            landings: [0, secondFingerDelay],
            moves: times,
            liftAt: duration + 0.05,
            at: point(finger:at:)
        )
    }

    /// Two fingers resting together on an element, away from its edges.
    ///
    /// Not `XCUIElement.twoFingerTap()`, which lands its fingers five points
    /// inside the element's top and bottom edges. The terminal's bottom edge
    /// meets the floating bottom bar, and the bar answers touches some way
    /// above its glass: a tap at the surface's bottom edge reaches the bar,
    /// not the grid, so the surface saw one finger and summoned the keyboard.
    /// These fingers land 40 points either side of the middle, where only the
    /// surface is under them, and lift together.
    ///
    /// - Parameter element: The element to tap.
    private func twoFingerTap(on element: XCUIElement) {
        let frame = element.frame
        synthesizeTwoFingers(named: "two-finger tap", landings: [0, 0], moves: [], liftAt: 0.1) { finger, _ in
            CGPoint(x: frame.midX, y: finger == 0 ? frame.midY - 40 : frame.midY + 40)
        }
    }

    /// Sends one two-touch sequence through the runner's event synthesiser.
    ///
    /// One pointer path per finger, both in one event record so they land as
    /// one two-touch sequence. The classes are private to the runner and
    /// reached by name, so their absence fails the case by name rather than
    /// leaving a gesture that did nothing.
    ///
    /// - Parameters:
    ///   - name: The record's name, reported when it is refused.
    ///   - landings: When each finger lands, in seconds from the start.
    ///   - moves: When each finger moves on after landing.
    ///   - liftAt: When both fingers lift.
    ///   - point: Where a finger is at a time.
    private func synthesizeTwoFingers(
        named name: String,
        landings: [Double],
        moves: [Double],
        liftAt: Double,
        at point: (_ finger: Int, _ time: Double) -> CGPoint
    ) {
        guard let pathClass = NSClassFromString("XCPointerEventPath") as? NSObject.Type,
            let recordClass = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type
        else {
            XCTFail("this XCTest has no XCPointerEventPath or XCSynthesizedEventRecord to synthesise two fingers with")
            return
        }
        typealias PathInitializer = @convention(c) (AnyObject, Selector, CGPoint, Double) -> AnyObject
        typealias PathMove = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias PathLift = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias RecordInitializer = @convention(c) (AnyObject, Selector, NSString, Int) -> AnyObject
        typealias RecordAddPath = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias RecordSynthesize = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool

        func implementation<Function>(_ object: AnyObject, _ name: String, as _: Function.Type) -> (Selector, Function)? {
            let selector = NSSelectorFromString(name)
            guard let object = object as? NSObject, object.responds(to: selector), let method = object.method(for: selector)
            else {
                return nil
            }
            return (selector, unsafeBitCast(method, to: Function.self))
        }

        var paths: [AnyObject] = []
        for finger in 0..<2 {
            let landing = landings[finger]
            let allocated = pathClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
            guard let (initSelector, initialize) = implementation(allocated, "initForTouchAtPoint:offset:", as: PathInitializer.self)
            else {
                XCTFail("XCPointerEventPath no longer answers initForTouchAtPoint:offset:")
                return
            }
            let path = initialize(allocated, initSelector, point(finger, landing), landing)
            guard let (moveSelector, move) = implementation(path, "moveToPoint:atOffset:", as: PathMove.self),
                let (liftSelector, lift) = implementation(path, "liftUpAtOffset:", as: PathLift.self)
            else {
                XCTFail("XCPointerEventPath no longer answers moveToPoint:atOffset: and liftUpAtOffset:")
                return
            }
            for time in moves where time > landing {
                move(path, moveSelector, point(finger, time), time)
            }
            lift(path, liftSelector, liftAt)
            paths.append(path)
        }

        let allocatedRecord = recordClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
        guard
            let (recordSelector, initializeRecord) = implementation(
                allocatedRecord,
                "initWithName:interfaceOrientation:",
                as: RecordInitializer.self
            )
        else {
            XCTFail("XCSynthesizedEventRecord no longer answers initWithName:interfaceOrientation:")
            return
        }
        // Portrait, the orientation element frames are reported in for this suite's cases.
        let record = initializeRecord(allocatedRecord, recordSelector, name as NSString, 1)
        guard let (addPathSelector, addPath) = implementation(record, "addPointerEventPath:", as: RecordAddPath.self)
        else {
            XCTFail("XCSynthesizedEventRecord no longer answers addPointerEventPath:")
            return
        }
        for path in paths {
            addPath(record, addPathSelector, path)
        }
        guard let (synthesizeSelector, synthesize) = implementation(record, "synthesizeWithError:", as: RecordSynthesize.self)
        else {
            XCTFail("XCSynthesizedEventRecord no longer answers synthesizeWithError:")
            return
        }
        var error: NSError?
        guard synthesize(record, synthesizeSelector, &error) else {
            XCTFail("the \(name) was refused: \(error?.localizedDescription ?? "no reason given")")
            return
        }
    }

    /// The list row for this suite's host.
    ///
    /// Matched on the START of the label rather than the whole of it. A row is a
    /// button wrapping a name and a subtitle, and UIKit joins the two into one
    /// accessibility label — so the exact name matches nothing, and the subtitle
    /// carries the endpoint and the trust state, both of which change.
    private var hostRow: XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", Self.hostName))
            .firstMatch
    }

    /// The list row for a host, by the name it was saved under.
    private func hostRow(named name: String) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", name))
            .firstMatch
    }

    /// Leaves the terminal and goes on back to the host list.
    ///
    /// The sidebar is a stack, Hosts then a host's Workspaces, and the
    /// terminal is pushed over the screen it was opened from: a terminal
    /// chosen on the workspaces screen leaves to that screen, and the host
    /// list is one back from there. A terminal the host list opened without
    /// a stop leaves to the list itself, with nothing to go back from.
    private func leaveTheTerminalForTheHostList() {
        app.buttons["terminal-leave"].tap()
        let hosts = app.navigationBars.buttons["Hosts"].firstMatch
        if hosts.waitForExistence(timeout: 3), hosts.isHittable { hosts.tap() }
    }

    /// The question a screen asks when the session picked for it was not
    /// reached.
    private var unreachedPickAlert: XCUIElement {
        app.alerts.matching(NSPredicate(format: "label BEGINSWITH %@", "Couldn’t Reach")).firstMatch
    }

    /// Opens a host's editor and leaves it dialling this port, with QUIC on
    /// or off.
    ///
    /// - Parameters:
    ///   - row: The host's row in the list.
    ///   - port: The port to dial.
    ///   - prefersQUIC: Whether the host asks for QUIC.
    private func edit(_ row: XCUIElement, port: Int, prefersQUIC: Bool) {
        row.swipeLeft()
        app.buttons["Edit"].firstMatch.tap()
        let field = app.textFields["Port"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the host editor did not open")
        field.tap()
        // A number pad cannot select all, so the digits go one at a time.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6))
        field.typeText(String(port))
        keyboardDoneButton.tap()
        set(app.switches["Use Workspaces"], on: prefersQUIC)
        saveButton.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the editor did not close on Save")
    }

    /// Launches with the seeded session rows and opens the shared host's list.
    private func openTheSeededSessionList() {
        let seeded = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        seeded.launchArguments = ["--seed-host-sessions"]
        seeded.launch()
        if !hostRow.waitForExistence(timeout: 5) {
            addTheTestHost()
        }
        settle(hostRow, workspace: "")
        hostRow.tap()
        answerThePasswordPromptIfItAppears()
        XCTAssertTrue(
            workspacesScreen.waitForExistence(timeout: 15),
            "the session list never came up. On screen instead:\n" + app.debugDescription
        )
    }

    /// Leaves the terminal for the host's workspaces, answering an
    /// unreached pick first when the offline connect raised one.
    private func leaveTheTerminal() {
        if unreachedPickAlert.waitForExistence(timeout: 5) {
            unreachedPickAlert.buttons["Cancel"].firstMatch.tap()
        }
        // In an expanded split view the workspaces remain beside the terminal.
        if workspacesScreen.exists && workspacesScreen.isHittable { return }
        let leave = app.buttons["terminal-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "the terminal offers no way back. On screen:\n" + app.debugDescription)
        leave.tap()
    }

    /// Drags a row from its trailing edge to its leading one in one quick
    /// stroke, the gesture a list reads as a full swipe.
    private func fullSwipe(_ row: XCUIElement) {
        let trailing = row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        let leading = row.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        trailing.press(forDuration: 0.05, thenDragTo: leading, withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// Answers a confirmation dialog no.
    ///
    /// A dialog shown as an action sheet carries a Cancel button; one shown
    /// as a popover carries none and is dismissed by a touch on the region
    /// around it, which the touch reaches near the bottom of the screen,
    /// below a popover anchored at the top.
    private func dismissTheConfirmation() {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 2), cancel.isHittable {
            cancel.tap()
            return
        }
        let outside = app.otherElements["PopoverDismissRegion"].firstMatch
        XCTAssertTrue(outside.exists, "the confirmation offers neither Cancel nor a region to dismiss it")
        outside.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
    }

    /// Closes a row's revealed swipe actions with a touch on the empty list
    /// below the rows.
    private func dismissTheRowActions() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
    }

    /// Whether the editor says a secret is stored for a host.
    ///
    /// The editor never shows a stored password; it says one is there through
    /// the field's prompt. Reading that prompt is the one view of the
    /// keychain a test outside the process has.
    ///
    /// - Parameter row: The host's row in the list.
    /// - Returns: Whether the editor's password field reports a stored secret.
    private func editorSaysASecretIsStored(for row: XCUIElement) -> Bool {
        row.swipeLeft()
        app.buttons["Edit"].firstMatch.tap()
        let stored = app.secureTextFields
            .matching(NSPredicate(format: "label == %@ AND placeholderValue == %@", "Password", "Saved"))
            .firstMatch
        let isStored = stored.waitForExistence(timeout: 5)
        cancelButton.tap()
        _ = row.waitForExistence(timeout: 5)
        return isStored
    }

    /// The list row for the host that names a workspace.
    private var workspaceHostRow: XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", Self.workspaceHostName))
            .firstMatch
    }

    /// The host's workspaces screen, in whichever of its states it is: the
    /// list, the progress while the host is asked, or the sentence that
    /// stands in for an empty or unanswered list. Its title is the host's
    /// name, so it is found by what it holds.
    private var workspacesScreen: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace-list"))
            .firstMatch
    }

    /// The scratch workspace's row in the showcase host's outline, and the
    /// session its one pane runs.
    private static let scratchRow = "host-outline-row-workspace-9"
    private static let scratchSession = 49

    /// A row of the host's outline, by the identifier Core's identity gives
    /// it.
    ///
    /// The outline is a lazy list, so a row off screen is not there until
    /// the list scrolls to it: the list goes back to its top, then is swiped
    /// up until the row exists, a few times at most each way.
    private func outlineRow(_ identifier: String) -> XCUIElement {
        let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        let list = app.descendants(matching: .any).matching(identifier: "workspace-list").firstMatch
        guard !row.waitForExistence(timeout: 2), list.exists else { return row }
        for _ in 0..<4 where !row.exists {
            list.swipeDown()
        }
        for _ in 0..<10 where !row.waitForExistence(timeout: 1) {
            list.swipeUp()
        }
        return row
    }

    /// Everything a row says, as the labels of the text under it joined.
    private func label(of row: XCUIElement) -> String {
        ([row.label] + row.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label)).joined(separator: " ")
    }

    /// Launches, makes sure the test host exists, opens it, and returns the
    /// terminal surface.
    ///
    /// The host is added through the editor rather than written into the store,
    /// because the store is reached through the editor: a test that wrote the
    /// file directly would keep passing after the editor stopped saving.
    /// Polls a condition until it holds or the time runs out.
    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in condition() }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout) == .completed
    }

    private func openTerminal(arguments: [String] = []) -> XCUIElement {
        let application = app
        application.launchArguments = arguments
        application.launch()
        XCTAssertEqual(app.state, .runningForeground, "the app did not come up")

        if !hostRow.waitForExistence(timeout: 5) {
            addTheTestHost()
        }
        hostRow.tap()
        answerThePasswordPromptIfItAppears()

        let surface = app.otherElements["terminal-surface"]
        if !surface.waitForExistence(timeout: 15) {
            // What is on screen instead, because the interesting question when a named
            // element is missing is never "is it missing" — it is whether the app
            // reached this screen at all, and under what other name the thing is
            // sitting there.
            XCTFail(
                "the terminal surface never appeared — the gestures below "
                    + "would assert nothing. On screen instead:\n"
                    + app.debugDescription
            )
        }
        return surface
    }

    /// Puts the terminal's keyboard away with whichever control offers it:
    /// the key row's Hide Keyboard on iPhone, the bar's keyboard button where
    /// the row has none.
    private func putTheTerminalKeyboardAway() {
        let hide = app.buttons["terminal-hide-keyboard"]
        if hide.exists { hide.tap() } else { app.buttons["terminal-keyboard"].tap() }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
    }

    /// Answers the connect-time password prompt when the app asks for one.
    ///
    /// Whether it asks is not something this suite should pin down: it depends
    /// on the authentication method and on whether the keychain kept what the
    /// editor was given, and the keychain on a fresh simulator does not always.
    /// Both paths end on the terminal, so the prompt is answered when it is
    /// there and skipped when it is not, rather than being asserted either way.
    private func answerThePasswordPromptIfItAppears() {
        let destination = NSPredicate { [self] _, _ in
            passwordAlert.exists || app.otherElements["terminal-surface"].exists
                || workspacesScreen.exists
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: destination, object: nil)], timeout: 30),
            .completed,
            "opening the host reached neither a sign-in prompt nor a session screen"
        )
        let alert = passwordAlert
        guard alert.exists else { return }
        let field = alert.secureTextFields.firstMatch
        guard field.waitForExistence(timeout: 3) else {
            XCTFail("the password prompt came up with no password field")
            return
        }
        field.tap()
        field.typeText("ui-test")
        alert.buttons["Connect"].tap()
    }

    /// The alert a connect raises when the server asks for a password.
    private var passwordAlert: XCUIElement {
        app.alerts.matching(NSPredicate(format: "label BEGINSWITH %@", "Password for")).firstMatch
    }

    /// Fills the host editor for a host that cannot connect.
    ///
    /// Port 1 on the loopback, so the connection fails immediately and
    /// predictably. The terminal screen and its recognisers do not wait on a
    /// carrier — the surface is up and touchable while the status line says the
    /// link is down — and a host that connected would make every run depend on
    /// a server somebody remembered to leave running.
    private func addTheTestHost() {
        addHost(named: Self.hostName, workspace: "")
    }

    /// Fills the host editor, optionally naming a workspace.
    ///
    /// - Parameters:
    ///   - name: What the host is called in the list.
    ///   - workspace: The workspace the host connects to, empty for none.
    ///   - savesPassword: Whether the editor keeps a password for it; a host
    ///     without one asks at connect time and offers to save the answer.
    ///   - address: The host name or address to dial.
    ///   - prefersQUIC: Whether the host asks for workspaces over QUIC.
    private func addHost(
        named name: String,
        workspace: String,
        savesPassword: Bool = true,
        address: String = "127.0.0.1",
        prefersQUIC: Bool = true
    ) {
        // firstMatch: the empty list offers "Add Host" as its call to action, and
        // the toolbar carries one, so the name alone is ambiguous whenever the
        // list is empty — which is exactly when this runs.
        app.buttons["Add Host"].firstMatch.tap()
        XCTAssertTrue(
            app.navigationBars["New Host"].waitForExistence(timeout: 5),
            "the host editor did not open"
        )

        typeInto(app.textFields["Address"], address)
        typeInto(app.textFields["User Name"], "ui")
        typeInto(app.textFields["Name"], name)

        let port = app.textFields["Port"]
        port.tap()
        // The field arrives holding 22 and a number pad has no way to select
        // all, so the existing digits are deleted one at a time.
        port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6))
        port.typeText("1")
        // A number pad has no return key, and on a short display it covers
        // every row under the port; the editor's Done above it is how a
        // person gets back to the form, so the test leaves the same way.
        let done = keyboardDoneButton
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the number pad offers no way back to the form")
        done.tap()

        // A saved password, so a server that asks for one is answered without
        // the sign-in sheet. It is offered only when the server asks.
        if savesPassword {
            chooseSignIn("Saved Password")
            typeInto(app.secureTextFields["Password"], "ui-test")
        } else {
            chooseSignIn("Ask for Password")
        }

        // Asking for QUIC, so the transport row has something to answer. The
        // host cannot reach a daemon and SSH is the answer it must report; what matters
        // is that an answer is given.
        let quic = app.switches["Use Workspaces"]
        if quic.waitForExistence(timeout: 3) {
            set(quic, on: prefersQUIC)
        }

        // After the QUIC switch, because the workspace field is shown only
        // while this host can be asked what it is holding — a plain-SSH host
        // runs a login shell and has no sessions to name.
        if !workspace.isEmpty {
            typeTheWorkspace(workspace)
        }

        saveButton.tap()
        let saved = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", name))
            .firstMatch
        XCTAssertTrue(
            saved.waitForExistence(timeout: 5),
            "the host was not saved"
        )
    }

    /// Opens a saved host's editor and leaves it asking for QUIC under this
    /// workspace name.
    ///
    /// Written rather than assumed, because the saved list survives between
    /// runs: a host added by an earlier version of this suite carries whatever
    /// that version set, and a case that read those settings as its own would
    /// pass or fail on what ran yesterday.
    ///
    /// - Parameters:
    ///   - row: The host's row in the list.
    ///   - workspace: The workspace to name, empty to name none.
    private func settle(_ row: XCUIElement, workspace: String) {
        row.swipeLeft()
        app.buttons["Edit"].firstMatch.tap()
        let quic = app.switches["Use Workspaces"]
        XCTAssertTrue(
            app.navigationBars["Edit Host"].waitForExistence(timeout: 5),
            "the host editor did not open. On screen instead:\n" + app.debugDescription
        )
        set(quic, on: true)
        typeTheWorkspace(workspace)
        saveButton.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the editor did not close on Save")
    }

    /// The open sheet's confirm button: a role the system labels, so found
    /// by the names it may give it.
    private var saveButton: XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "Done", "Confirm"])).firstMatch
    }

    /// The open sheet's cancel or close button.
    private var cancelButton: XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"])).firstMatch
    }

    /// The button above the number pad that puts it away; in the keyboard's
    /// bar, so never the sheet's own confirm.
    private var keyboardDoneButton: XCUIElement {
        app.buttons["host-editor-keyboard-done"]
    }

    /// Replaces what the editor's Port field holds.
    ///
    /// The field selects its digits when it takes focus, so what is typed
    /// replaces them, as a person typing a port expects; the value is read
    /// back before the keyboard goes away.
    private func replacePort(with digits: String) {
        let port = app.textFields["Port"]
        port.tap()
        port.typeText(digits)
        XCTAssertEqual(port.value as? String, digits, "the Port field did not take \(digits)")
    }

    /// Chooses how the open editor's host signs in, from its menu.
    ///
    /// - Parameter title: The choice as the menu names it.
    private func chooseSignIn(_ title: String) {
        putTheKeyboardAway()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sign In With")).firstMatch
        revealInTheForm(picker)
        XCTAssertTrue(picker.exists, "the editor has no Sign In With menu. On screen instead:\n" + app.debugDescription)
        guard !picker.label.hasSuffix(", " + title) else { return }
        picker.tap()
        let item = menuItem(title)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the Sign In With menu offers no \(title)")
        item.tap()
    }

    /// An item of the menu on screen, which the system draws as a menu item
    /// or as a button depending on where the menu opened.
    private func menuItem(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label == %@ AND (elementType == %d OR elementType == %d)",
                    title,
                    XCUIElement.ElementType.menuItem.rawValue,
                    XCUIElement.ElementType.button.rawValue
                )
            )
            .element(boundBy: 0)
    }

    /// Replaces whatever the editor's workspace field holds.
    ///
    /// An empty field reports its placeholder as its value, which is how the
    /// unset case is told from a name that happens to be typed.
    ///
    /// - Parameter workspace: The name to leave in the field, empty to clear it.
    private func typeTheWorkspace(_ workspace: String) {
        putTheKeyboardAway()
        let field = app.textFields["Workspace"]
        revealInTheForm(field)
        XCTAssertTrue(
            field.exists,
            "the host editor offers no workspace field. On screen instead:\n" + app.debugDescription
        )
        let placeholder = field.placeholderValue ?? ""
        let held = (field.value as? String).flatMap { $0 == placeholder ? "" : $0 } ?? ""
        guard held != workspace else { return }
        field.tap()
        if !held.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: held.count + 2))
        }
        if !workspace.isEmpty {
            field.typeText(workspace)
        }
    }

    /// Moves a switch to a state, from the end of the row the control sits on.
    ///
    /// A tap at the element's centre lands on the label half of the row and
    /// leaves the switch where it was — which reads as a control the app
    /// ignores rather than as a tap that missed. The value is read back, so a
    /// tap that did nothing fails here instead of three assertions later.
    ///
    /// - Parameters:
    ///   - toggle: The switch.
    ///   - on: The state to leave it in.
    private func set(_ toggle: XCUIElement, on: Bool) {
        putTheKeyboardAway()
        revealInTheForm(toggle)
        for _ in 0..<3 where ((toggle.value as? String) == "1") != on {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(
            (toggle.value as? String) == "1",
            on,
            "the \(toggle.label) switch would not move. It sits at \(toggle.frame), "
                + "hittable \(toggle.isHittable), holding \(String(describing: toggle.value))"
        )
    }

    /// Puts the keyboard away, so a row the form keeps below it can be touched.
    ///
    /// A Form already scrolled to its end cannot move a row out from under the
    /// keyboard, so a switch near the bottom stays covered however far the form
    /// is swiped and reads as a control the app ignores. The number pad has its
    /// own Done; other fields can advance to it when Return is pressed.
    private func putTheKeyboardAway() {
        guard app.keyboards.element.exists else { return }
        if !keyboardDoneButton.exists {
            // A dismissed keyboard can remain in the accessibility tree
            // during its animation, after its field has relinquished focus.
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
            guard focused.exists else {
                _ = app.keyboards.element.waitForNonExistence(timeout: 2)
                return
            }
            app.typeText("\n")
        }
        if keyboardDoneButton.waitForExistence(timeout: 1) { keyboardDoneButton.tap() }
    }

    /// Scrolls the frontmost form until the element is in the tree and can be
    /// touched: the host editor, or Settings, which opens as a half-height
    /// sheet on iPhone Duo and leaves its later rows below the fold.
    ///
    /// A Form draws the rows it can show, so a control below the fold is not in
    /// the accessibility tree at all — it reads as a missing control rather
    /// than as one further down the form. Existence and hittability are waited
    /// for separately because they arrive separately: a row is realised as it
    /// nears the edge of the screen and becomes touchable only once it is on
    /// it.
    private func revealInTheForm(_ element: XCUIElement) {
        // The last collection view, not the first: the editor is a sheet over
        // the host list, and both are collection views — swiping the first one
        // scrolls the list underneath, which moves nothing and looks exactly
        // like a form that has no such field.
        let lists = app.collectionViews
        let editor = lists["host-editor-form"]
        let form =
            app.navigationBars["Edit Host"].exists || app.navigationBars["New Host"].exists
            ? editor : lists.element(boundBy: max(0, lists.count - 1))
        XCTAssertTrue(form.waitForExistence(timeout: 5), "the form is not on screen")
        for _ in 0..<6 where !element.exists {
            form.swipeUp()
        }
        for _ in 0..<4 where !element.isHittable {
            form.swipeUp()
        }
    }

    /// Taps a field and types into it, failing by name when it is not there.
    private func typeInto(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(
            field.waitForExistence(timeout: 5),
            "the editor has no field for \(text). On screen instead:\n" + app.debugDescription
        )
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 10), .completed)
        field.tap()
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 10), .completed, "the tapped editor field did not gain keyboard focus")
        field.typeText(text)
    }
}

/// A screenshot's pixels, read at points given in the screen's coordinates.
private struct ScreenPixels {
    private let bytes: [UInt8]
    private let width: Int
    private let height: Int
    private let scale: CGFloat
    /// Whether the picture stands upright while the screen is turned on its
    /// side: a screenshot of a landscape-left screen is the panel's own
    /// portrait raster, the screen's top edge along its right.
    private let isTurned: Bool
    /// The screen's height in points, which a turned picture lays across.
    private let screenHeight: CGFloat

    /// Reads the screenshot on the main actor, where XCTest keeps its image.
    @MainActor
    init(_ screenshot: XCUIScreenshot, screen: CGRect) {
        let image = screenshot.image.cgImage
        let width = image?.width ?? 0
        let height = image?.height ?? 0
        self.width = width
        self.height = height
        isTurned = height > width && screen.width > screen.height
        screenHeight = screen.height
        let across = isTurned ? screen.height : screen.width
        scale = across > 0 ? CGFloat(width) / across : 0
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        if let image {
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        self.bytes = bytes
    }

    /// The raster pixel under a point of the screen.
    private func pixel(at point: CGPoint) -> (Int, Int) {
        let upright = isTurned ? CGPoint(x: screenHeight - point.y, y: point.x) : point
        return (min(max(Int(upright.x * scale), 0), width - 1), min(max(Int(upright.y * scale), 0), height - 1))
    }

    /// The relative luminance at a point, from 0 for black to 1 for white,
    /// or NaN when the picture could not be read, which no comparison passes.
    func luminance(at point: CGPoint) -> Double {
        guard width > 0, height > 0 else { return .nan }
        let (x, y) = pixel(at: point)
        let offset = (y * width + x) * 4
        return (0.2126 * Double(bytes[offset]) + 0.7152 * Double(bytes[offset + 1]) + 0.0722 * Double(bytes[offset + 2])) / 255
    }

    /// The longest unbroken run of something other than the region's ground
    /// along any one of its lines, as a fraction of the region's width.
    ///
    /// The ground is the region's top-left corner, which a terminal's padding
    /// keeps clear of text. Text never runs unbroken past a glyph; a filled
    /// bar does.
    ///
    /// - Parameter region: The region, in the screen's coordinates.
    /// - Returns: The run's length over the region's width, from 0 to 1.
    func longestInkRunFraction(in region: CGRect) -> Double {
        guard region.width > 0, region.height > 0 else { return 0 }
        let ground = luminance(at: CGPoint(x: region.minX + 1, y: region.minY + 1))
        var longest: CGFloat = 0
        for y in stride(from: region.minY, to: region.maxY, by: 2) {
            var run: CGFloat = 0
            for x in stride(from: region.minX, to: region.maxX, by: 1) {
                run = abs(luminance(at: CGPoint(x: x, y: y)) - ground) > 0.2 ? run + 1 : 0
                longest = max(longest, run)
            }
        }
        return Double(longest / region.width)
    }

    /// Separates colored glyphs from the nearly neutral Noir backgrounds.
    func channelSpread(at point: CGPoint) -> Double {
        guard width > 0, height > 0 else { return .nan }
        let (x, y) = pixel(at: point)
        let offset = (y * width + x) * 4
        let channels = bytes[offset..<(offset + 3)]
        return Double((channels.max() ?? 0) - (channels.min() ?? 0)) / 255
    }
}
