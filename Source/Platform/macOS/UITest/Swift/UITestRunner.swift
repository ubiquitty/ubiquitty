// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit

// UITestRunner.swift — the in-process UI integration harness: the scenario
// registry, the context a scenario asserts through, and the runner that boots
// the real app and runs them.
//
// It drives the real AppKit app from code: NSApplication and UBAppDelegate are
// brought up through finishLaunching (no NSApplication.run), then named
// scenarios create windows, type into panes, split, resize and attach tmux
// through the same controller methods the menus and keys use, asserting on
// observable model state. The run loop is pumped inside the wait and pump
// helpers, so PTY output and queued main-thread work advance between steps.
//
// Compiled only under the UBIQUITTY_UI_TESTS CMake option, absent from release
// builds. Invoked as `Ubiquitty --ui-test <name|names|all|list>`.

/// A scenario's body, run on the main actor with the run's context.
typealias UBUITestScenario = @MainActor (UBUITestContext?) -> Void

/// The registered scenarios, in registration order until the run sorts them.
///
/// Written only by the registrations the runner asks for and read only by the
/// runner, both on the main thread before any scenario runs; a scenario
/// file's `register()` is not itself main-actor code.
nonisolated(unsafe) private var registeredScenarios: [(name: String, isInDefaultSuite: Bool, body: UBUITestScenario)] = []

/// What the runner prints before each reason a scenario failed or was
/// refused, one reason a line under the scenario's result.
///
/// Indented, so the line a reason starts never reads as a result or a tally
/// to a gate that parses the run; a scenario relaying a child application's
/// reasons finds them by it.
let uiTestFailureLinePrefix = "        - "

/// Registers a scenario under its name.
///
/// - Parameters:
///   - name: The name `--ui-test` selects it by.
///   - isInDefaultSuite: Whether `--ui-test all` selects it without the environment it needs.
///   - body: The scenario.
func UBUITestRegister(_ name: String, isInDefaultSuite: Bool = true, _ body: @escaping UBUITestScenario) {
    registeredScenarios.append((name, isInDefaultSuite, body))
}

/// Records assertions and advances AppKit between native integration-test steps.
///
/// Not main-actor isolated: a scenario asserts from nested helpers that are not
/// main-actor code. Every call is on the main thread, where the runner runs the
/// scenarios.
@objc(UBUITestContext)
final class UBUITestContext: NSObject, @unchecked Sendable {
    private(set) var scenarioFailures: [String] = []
    /// Why this scenario could not run, or nil when it ran. A scenario whose
    /// shell never spawned has nothing to assert about, so the runner reports
    /// the refusal rather than the assertions that follow from it.
    private(set) var scenarioRefusal: String?

    fileprivate func beginScenario() {
        scenarioFailures.removeAll()
        scenarioRefusal = nil
    }

    /// Reports that this machine cannot give the scenario what it needs, so
    /// the run says nothing about its cases; the first reason stands.
    ///
    /// - Parameter reason: What was missing.
    func refuse(_ reason: String) {
        if scenarioRefusal == nil { scenarioRefusal = reason }
    }

    /// Runs the main run loop for `seconds`, in short slices.
    ///
    /// - Parameter seconds: How long to run it.
    func pump(_ seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        repeat {
            autoreleasepool {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
        } while deadline.timeIntervalSinceNow > 0
    }

    /// Pumps until `condition` holds or the timeout passes.
    ///
    /// - Parameters:
    ///   - condition: What to wait for, asked before each pump.
    ///   - seconds: The longest wait.
    /// - Returns: Whether the condition held, asked once more at the end.
    @discardableResult
    func wait(until condition: () -> Bool, timeout seconds: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        repeat {
            if condition() {
                return true
            }
            pump(0.05)
        } while deadline.timeIntervalSinceNow > 0
        return condition()
    }

    /// Records a failure named `desc` when `condition` does not hold.
    ///
    /// - Parameters:
    ///   - condition: The assertion.
    ///   - desc: What failed, as the run reports it.
    func expect(_ condition: Bool, desc: String) {
        if !condition {
            scenarioFailures.append(desc)
        }
    }

    /// Records a failure when `got` is not `want`, with both in the report.
    ///
    /// - Parameters:
    ///   - got: The value read.
    ///   - want: The value expected.
    ///   - desc: What failed.
    func expect(_ got: Int, equals want: Int, desc: String) {
        if got != want {
            scenarioFailures.append("\(desc) (got \(got), want \(want))")
        }
    }

    /// Closes every window and lets the closes settle.
    func closeAllWindows() {
        MainActor.assumeIsolated {
            for window in NSApp.windows {
                window.close()
            }
        }
        pump(0.15)
    }
}

/// Runs the UI integration scenarios when the command line asks for them.
@objc(UBUITestRunner)
@MainActor
public final class UITestRunner: NSObject {
    /// Boots the app, runs the scenarios `--ui-test` names, prints a line
    /// each and a tally, and exits: 0 when every one passed, 1 on a failure or
    /// a name that matches nothing, 2 when a scenario was refused and none
    /// failed, or the pasteboard could not be isolated. Returns when the flag is absent, so
    /// the normal launch proceeds.
    ///
    /// - Parameter words: The terminal's own command line, the program first.
    @objc
    public static func runIfRequested(_ words: [String]) {
        guard let flag = words.dropFirst().firstIndex(of: "--ui-test") else { return }
        let want = flag + 1 < words.count ? words[flag + 1] : "all"

        guard PasteboardIsolation.install() else {
            FileHandle.standardError.write(Data("UI test run refused: \(PasteboardIsolation.failureDescription)\n".utf8))
            exit(2)
        }
        if PasteboardIsolation.usesRealGeneralPasteboard {
            print("UI test pasteboard: REAL system-wide board in a marked disposable GUI session")
        } else {
            print("UI test pasteboard: private native board; cross-process system integration NOT RUN")
        }
        fflush(stdout)

        // The test build shares the real app's defaults domain, and the product
        // writes there as scenarios run (the window frame on every close, keep
        // on top, first-run markers), so an unguarded run overwrites the
        // operator's saved geometry. The domain is copied before any window
        // exists and put back at every exit; a crashed run skips the restore,
        // and the next completed run restores its own boot-time copy.
        let defaultsDomain = Bundle.main.bundleIdentifier
        let operatorDefaults = defaultsDomain.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        let restoreOperatorDefaults = {
            guard let defaultsDomain else { return }
            if let operatorDefaults {
                UserDefaults.standard.setPersistentDomain(operatorDefaults, forName: defaultsDomain)
            } else {
                UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)
            }
        }

        let app = NSApplication.shared
        WindowContainment.install()
        // Accessory: no Dock icon and no focus taken from the operator's
        // session, while real windows can still be made and keyed.
        app.setActivationPolicy(.accessory)
        let delegate = UBAppDelegate()
        app.delegate = delegate
        app.finishLaunching()
        // finishLaunching alone never delivers applicationDidFinishLaunching:
        // that rides the open-application Apple Event, which only run()'s
        // event loop processes, and this harness pumps the run loop instead.
        // The delegate's launch path is called directly, installing the
        // application services and the default window the run closes below.
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification, object: app))

        // The scenarios join the registry here: a Swift type has no static
        // constructor to ride, so the runner asks once.
        PastePushScenarios.register()
        ShellIntegrationScenarios.register()
        let scenarios = registeredScenarios.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }

        if want == "list" {
            for scenario in scenarios {
                print(scenario.name)
            }
            fflush(stdout)
            restoreOperatorDefaults()
            WindowContainment.restore()
            PasteboardIsolation.finish()
            exit(0)
        }

        let context = UBUITestContext()
        context.pump(0.3) // startup settles
        context.closeAllWindows() // the default window the launch opened

        // One name, a comma-separated list of them, or "all". Every listed name
        // must match a scenario: one that matches nothing is named below and
        // fails the run, so a misspelling cannot ride out as a green earned by
        // the names beside it.
        let runsAll = want == "all"
        let wanted = runsAll ? [] : want.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        var matched = Array(repeating: false, count: wanted.count)
        var total = 0
        var passed = 0
        var refused = 0
        for scenario in scenarios {
            if runsAll {
                if !scenario.isInDefaultSuite {
                    print("NOT SELECTED  \(scenario.name) (opt-in)")
                    continue
                }
            } else {
                guard let index = wanted.firstIndex(of: scenario.name) else { continue }
                matched[index] = true
            }
            // A scenario can remember a resized frame even as its windows
            // close. Restore the entry value after cleanup for the next one.
            let rememberedWindowFrame = UserDefaults.standard.object(forKey: "UbiquittyWindowFrame")
            total += 1
            PasteboardIsolation.reset()
            context.beginScenario()
            scenario.body(context)
            // A refusal outranks the assertions: a scenario whose shell never
            // spawned failed every check that needed one, and reporting those
            // names twenty product regressions for one exhausted machine.
            if let refusal = context.scenarioRefusal {
                refused += 1
                print("REFUSED  \(scenario.name)")
                print(uiTestFailureLinePrefix + refusal)
            } else if context.scenarioFailures.isEmpty {
                passed += 1
                print("PASS  \(scenario.name)")
            } else {
                print("FAIL  \(scenario.name)")
                for failure in context.scenarioFailures {
                    print(uiTestFailureLinePrefix + failure)
                }
            }
            fflush(stdout)
            context.closeAllWindows()
            if let rememberedWindowFrame {
                UserDefaults.standard.set(rememberedWindowFrame, forKey: "UbiquittyWindowFrame")
            } else {
                UserDefaults.standard.removeObject(forKey: "UbiquittyWindowFrame")
            }
        }

        // Printed before the teardown below and the tally after it, so a
        // crash in the teardown reads differently from a crash inside the
        // loop: present means every scenario ran and the cleanup is the
        // defect; absent means the run stopped with some never executed.
        print("scenarios complete: \(total) executed")
        fflush(stdout)

        PasteboardIsolation.finish()
        // And the defaults domain: everything the scenarios wrote goes.
        restoreOperatorDefaults()
        WindowContainment.restore()

        var unmatched = 0
        for (index, name) in wanted.enumerated() where !matched[index] {
            unmatched += 1
            print("no scenario named \"\(name)\"")
        }
        print("\n\(passed)/\(total) scenarios passed")
        if refused > 0 {
            print(
                "\(refused) scenario(s) REFUSED: the machine could not give them what they need. This run says nothing about those cases."
            )
        }
        fflush(stdout)
        // A refused run is no verdict on the product: 2, apart from a real
        // failure, so a gate can tell a broken tree from a machine that could
        // not run the suite.
        if refused > 0 && passed + refused == total && unmatched == 0 {
            exit(2)
        }
        exit(total > 0 && passed == total && unmatched == 0 ? 0 : 1)
    }
}
