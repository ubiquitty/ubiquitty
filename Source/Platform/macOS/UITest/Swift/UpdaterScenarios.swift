// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CxxStdlib
import UbiquittyCore
import UbiquittyKit

// UpdaterScenarios.swift — the updater's contract with the person using it.
//
// - Automatic checks follow the preference. `[updates] check_automatically`,
//   on by default, decides whether Sparkle's daily schedule runs, and a change
//   to it reaches the running updater at once, from Settings or from the file.
// - A scheduled check never presents an error. No network, a 404 or a feed
//   that does not parse ends a scheduled check silently; it is logged and the
//   schedule tries again a full interval later. The failure this prevents is
//   an "Unable to Check For Updates" alert at launch on a laptop with no
//   network, which stays invisible until it happens to someone, so a scheduled
//   check is run here against a feed nothing answers.
// - The "Check for Updates…" item exists exactly when an updater exists, and
//   so does the Settings toggle. A build without Sparkle has neither, and a
//   build cannot offer an action nothing implements or hide one it does.
// - Nothing installs without the person. The bundle disallows automatic
//   downloads, so an update a check finds is shown and waits, and Sparkle's
//   alert offers no option to install future updates on its own.
//
// Both build configurations are asserted, because both ship: with Sparkle the
// menu carries the item and the updater answers for it, and without it there
// is no updater, no item and no toggle.

/// Registers the updater scenarios with the UI-test runner.
enum UpdaterScenarios {
    /// The app menu, which is the first item's submenu.
    @MainActor
    private static func applicationMenu() -> NSMenu? {
        NSApp.mainMenu?.items.first?.submenu
    }

    /// The updater the app menu's "Check for Updates…" item targets, or nil
    /// when the menu offers no such item.
    @MainActor
    private static func menuUpdater() -> Updater? {
        applicationMenu()?.items.first { $0.title == "Check for Updates…" }?.target as? Updater
    }

    /// `[updates] check_automatically` as Core resolves it, through the key's
    /// address as Settings and the file name it; nil when Core has no such
    /// preference.
    @MainActor
    private static func scheduledChecksPreference() -> Bool? {
        guard let key = Ubiquitty.Preferences.keyForAddress(std.string("updates.check_automatically")).value else {
            return nil
        }
        return Ubiquitty.Preferences.effectiveValue(key, Ubiquitty.Preferences.values().pointee).value?.boolean
    }

    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_update_checks_follow_the_preference") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The bundle's half. Sparkle reads these keys itself, so they
                // are read here rather than assumed.
                let info = Bundle.main.infoDictionary ?? [:]
                t.expect((info["SUFeedURL"] as? String)?.isEmpty == false, desc: "the bundle names the appcast every check reads")
                t.expect(
                    info["SUEnableAutomaticChecks"] as? Bool == true,
                    desc: "the bundle settles Sparkle's own question about automatic checks, so Sparkle never asks it"
                )
                t.expect(
                    (info["SUScheduledCheckInterval"] as? NSNumber)?.intValue == 86_400,
                    desc: "scheduled checks are a day apart"
                )
                t.expect(
                    info["SUAllowsAutomaticUpdates"] as? Bool == false,
                    desc: "the bundle disallows downloading or installing an update without the person"
                )

                guard let appMenu = Self.applicationMenu() else {
                    t.expect(false, desc: "the app menu is built")
                    return
                }
                let updateItem = appMenu.items.first { $0.title == "Check for Updates…" }
                t.expect(
                    (updateItem != nil) == Updater.isAvailable,
                    desc: "the update item is offered exactly when this build has an updater"
                )
                guard let updateItem else {
                    // No Sparkle in this build: there is no updater to schedule
                    // anything, and the menu correctly offers no way to ask.
                    return
                }
                guard let updater = updateItem.target as? Updater else {
                    t.expect(false, desc: "the item targets the updater rather than the responder chain")
                    return
                }
                t.expect(
                    updateItem.action == #selector(Updater.checkForUpdates(_:)),
                    desc: "choosing the item runs the check the person asked for"
                )
                t.expect(
                    updater.validateMenuItem(updateItem) == updater.canCheckForUpdates,
                    desc: "the item is enabled exactly while a check can start"
                )

                // The preference's half: on by default, and followed live.
                let preference = Self.scheduledChecksPreference()
                t.expect(preference == true, desc: "Core resolves [updates] check_automatically, on by default")
                t.expect(
                    updater.isAutomaticCheckScheduled == (preference ?? true),
                    desc: "the updater schedules checks exactly when the preference asks"
                )
                let saved = t.configureAppending("[updates]\ncheck_automatically = false\n")
                defer { t.restoreConfiguration(saved) }
                t.expect(
                    t.wait(until: { !updater.isAutomaticCheckScheduled }, timeout: 2),
                    desc: "turning the preference off stops the schedule in the running app"
                )
                t.configureAppending("[updates]\ncheck_automatically = true\n")
                t.expect(
                    t.wait(until: { updater.isAutomaticCheckScheduled }, timeout: 2),
                    desc: "turning it back on schedules checks again"
                )
                t.expect(
                    !updater.mayInstallWithoutAsking,
                    desc: "with checks scheduled, the updater can neither install on its own nor offer to"
                )
            }
        }

        UBUITestRegister("swift_a_failed_scheduled_update_check_presents_nothing") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let updater = Self.menuUpdater() else {
                    // No updater, so nothing is scheduled and nothing can fail
                    // on a schedule; the scenario above holds the menu to that.
                    return
                }
                let saved = t.configureAppending("[updates]\ncheck_automatically = true\n")
                defer { t.restoreConfiguration(saved) }
                // A fresh defaults domain has never checked, so the launch ran
                // a scheduled check of its own. Sparkle starts no second check
                // while one is in progress.
                t.expect(t.wait(until: { !updater.isSessionInProgress }, timeout: 20), desc: "no earlier update check is still running")

                let finishedBefore = updater.finishedCycleCount
                let schedulesBefore = updater.scheduleCount
                let windowsBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
                let alerts = ModalAlertGuard()
                defer { alerts.remove() }
                updater.runScheduledCheck()

                t.expect(
                    t.wait(until: { updater.finishedCycleCount > finishedBefore }, timeout: 20),
                    desc: "the scheduled check finishes"
                )
                t.expect(updater.didLastCycleFailAtFeed, desc: "the scheduled check ran, and failed fetching the feed")
                t.expect(alerts.presentedCount == 0, desc: "a scheduled check that failed presents no alert")
                let appeared = NSApp.windows.filter { $0.isVisible && !windowsBefore.contains(ObjectIdentifier($0)) }
                t.expect(appeared.isEmpty, desc: "a scheduled check that failed opens no window")
                t.expect(
                    t.wait(until: { updater.scheduleCount > schedulesBefore }, timeout: 10),
                    desc: "the failed check leaves another one scheduled"
                )
                let delay = updater.lastScheduledDelay ?? 0
                t.expect(abs(delay - 86_400) < 60, desc: "the next check comes a full interval later (scheduled after \(Int(delay)) s)")
            }
        }

        UBUITestRegister("settings_update_check_toggle_follows_the_updater") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                var found: (category: SettingsCategory, row: SettingsRow)?
                for category in SettingsCatalog.categories() {
                    guard case .pane(let pane) = category.content else { continue }
                    if let row = pane.cards.flatMap(\.rows).first(where: { $0.id == "updates.check_automatically" }) {
                        found = (category: category, row: row)
                    }
                }
                t.expect(
                    (found != nil) == Updater.isAvailable,
                    desc: "Settings offers the toggle exactly when this build has an updater"
                )
                guard let found else { return }
                t.expect(found.category.title == "Software Update", desc: "the toggle is on the Software Update page")
                t.expect(found.row.label == "Check for updates automatically", desc: "the toggle reads Check for updates automatically")
                guard case .toggle(let isOn, let setOn) = found.row.control else {
                    t.expect(false, desc: "the row is a toggle")
                    return
                }
                guard let updater = Self.menuUpdater() else {
                    t.expect(false, desc: "the build that shows the toggle has an updater")
                    return
                }
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }

                t.expect(isOn() == Self.scheduledChecksPreference(), desc: "the toggle shows the preference")
                setOn(false)
                t.expect(Self.scheduledChecksPreference() == false && !isOn(), desc: "turning the toggle off writes the preference")
                t.expect(
                    String(Ubiquitty.Preferences.liveDocument().pointee).contains("check_automatically = false"),
                    desc: "the toggle writes [updates] check_automatically"
                )
                t.expect(
                    t.wait(until: { !updater.isAutomaticCheckScheduled }, timeout: 2),
                    desc: "turning the toggle off stops the schedule"
                )
                setOn(true)
                t.expect(Self.scheduledChecksPreference() == true && isOn(), desc: "turning the toggle on writes the preference")
                t.expect(
                    t.wait(until: { updater.isAutomaticCheckScheduled }, timeout: 2),
                    desc: "turning the toggle on schedules checks again"
                )
            }
        }
    }
}

/// Answers any modal alert that opens while it is installed, and counts them.
///
/// An alert runs its own modal loop, which holds the run until someone answers
/// it. The guard answers it instead, so an updater that presented one fails
/// the scenario rather than stopping the run.
@MainActor
private final class ModalAlertGuard {
    /// How many modal alerts opened while the guard was installed.
    private(set) var presentedCount = 0
    private var timer: Timer?

    init() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSApp.modalWindow != nil else { return }
                self?.presentedCount += 1
                NSApp.abortModal()
            }
        }
        // Only the modal loop's mode: the scenario's own pumps run the default
        // mode, where there is no modal session to end.
        RunLoop.main.add(timer, forMode: .modalPanel)
        self.timer = timer
    }

    /// Stops answering alerts.
    func remove() {
        timer?.invalidate()
        timer = nil
    }
}
