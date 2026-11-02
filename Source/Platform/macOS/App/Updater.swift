// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CxxStdlib
import UbiquittyAppBridge
import UbiquittyAppleCallbacks
import UbiquittyCore

#if canImport(Sparkle)
import Sparkle
#endif

// Updater.swift — the app's update checks: on Sparkle's daily schedule while
// `[updates] check_automatically` asks for them, and whenever the person
// chooses Check for Updates.
//
// Sparkle is optional: the framework is fetched into the build (see
// Docs/auto-update.md), and a build that skipped the fetch compiles this file
// with `canImport(Sparkle)` false. That build has no updater — ``startedUpdater``
// answers nil and the caller leaves the "Check for Updates…" item out of the
// menu — so the app links and runs either way, and this is the only file in the
// application that names Sparkle.
//
// The schedule follows Core's effective preference, read when the updater is
// made and again after every configuration change, so Settings and an edited
// file move it the same way. Sparkle keeps its own copy of the switch in the
// app's user defaults; that copy is written from the preference and never read
// as one.
//
// What a scheduled check can do is bounded by Sparkle and by the bundle. The
// bundle disallows automatic downloads (`SUAllowsAutomaticUpdates`), so an
// update a check finds is shown and waits for the person, and the update alert
// offers no option to install later ones on its own. Sparkle's scheduled driver
// presents an error only once it has shown an update, so a feed that cannot be
// fetched, answers 404 or does not parse ends the check silently: the failure
// is logged and the next check comes a full interval later. A check the person
// chose reports its failure, as Sparkle always does.
//
// Sparkle's own permission question about automatic checks never comes up:
// the bundle declares `SUEnableAutomaticChecks`, which Sparkle reads as the
// question already answered, and the delegate declines if asked anyway.
//
// The delegate also reports when Sparkle is about to relaunch the app into an
// update it installed, which is how the quit that follows keeps the person's
// terminals (`Session::isSessionKeptByQuit`). The fact is Sparkle's, reported
// rather than inferred from the quit.
//
// No Sparkle type appears in this file's @objc surface, and that is a
// requirement rather than a preference: the generated interop header is
// imported by every Objective-C++ translation unit in the app, and a Sparkle
// protocol named there would ask each of them to find a framework only this
// file knows about. The delegate is a private object for that reason.

#if canImport(Sparkle)
/// Why a scheduled check was declined, for the error Sparkle reports.
private struct ScheduledCheckDeclined: LocalizedError {
    var errorDescription: String? { "Automatic update checks are turned off." }
}

/// What the updater may do without the person, what its checks report, and
/// whether it is about to relaunch the app.
private final class UpdatePolicy: NSObject, SPUUpdaterDelegate {
    /// Whether Sparkle has said it is about to relaunch the app.
    private(set) var isRelaunchPending = false

    /// Whether the updater may run this check.
    ///
    /// A scheduled check runs only while the preference asks for checks. The
    /// scheduler already follows the preference; this holds even when Sparkle's
    /// stored copy of the switch says otherwise.
    ///
    /// - Parameters:
    ///   - updater: The updater asking.
    ///   - updateCheck: The kind of check it would run.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updatesInBackground, !Updater.shouldCheckAutomatically {
            throw ScheduledCheckDeclined()
        }
    }

    /// Declines Sparkle's own question about automatic checks; the setting is
    /// the app's.
    ///
    /// - Parameter updater: The updater asking.
    /// - Returns: False.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    /// Logs a scheduled check that failed.
    ///
    /// Sparkle has already scheduled the next check a full interval on, and
    /// showed nothing; this line is what records the failure for the app.
    ///
    /// - Parameters:
    ///   - updater: The updater that ran the check.
    ///   - updateCheck: The kind of check it was.
    ///   - error: Why it ended, or nil when it ended normally.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        #if UBIQUITTY_UI_TESTS
        finishedCycleCount += 1
        didLastCycleFailAtFeed = updateCheck == .updatesInBackground && Self.isFeedFailure(error)
        #endif
        guard updateCheck == .updatesInBackground, let error = error as NSError? else { return }
        if error.domain == SUSparkleErrorDomain, error.code == SUError.noUpdateError.rawValue { return }
        var line = "Scheduled update check failed: \(error.localizedDescription)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            line += " (\(underlying.localizedDescription))"
        }
        Ubiquitty.SwiftBridge.writeDiagnostic(std.string(line))
    }

    /// Sparkle installed an update the person chose to install and relaunch
    /// into, and is about to ask the app to quit so it can open the new copy.
    ///
    /// - Parameter updater: The updater relaunching.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        isRelaunchPending = true
    }

    #if UBIQUITTY_UI_TESTS
    // Test-only seams, not compiled into a shipping build. A UI-test run never
    // reaches the release feed: every check, the schedule's included, reads an
    // address on this machine nothing answers, so a run stays on the machine
    // and each scheduled check it makes is one that fails.

    /// The feed a UI-test build checks.
    static let unansweredFeedURL = "https://127.0.0.1:9/appcast.xml"

    /// How many update cycles have finished since launch.
    var finishedCycleCount = 0
    /// Whether the last cycle to finish was a scheduled check that failed
    /// fetching or reading the feed.
    var didLastCycleFailAtFeed = false
    /// How many times Sparkle scheduled a check since launch.
    var scheduleCount = 0
    /// The delay Sparkle last scheduled a check after.
    var lastScheduledDelay: TimeInterval?

    /// Points every check at ``unansweredFeedURL``.
    ///
    /// - Parameter updater: The updater asking.
    /// - Returns: The feed address.
    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.unansweredFeedURL
    }

    /// Records the schedule Sparkle set.
    ///
    /// - Parameters:
    ///   - updater: The updater scheduling.
    ///   - delay: Seconds until the check.
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        scheduleCount += 1
        lastScheduledDelay = delay
    }

    /// Whether `error` is Sparkle's failure to fetch or read a feed.
    private static func isFeedFailure(_ error: (any Error)?) -> Bool {
        guard let error = error as NSError?, error.domain == SUSparkleErrorDomain else { return false }
        return error.code == SUError.downloadError.rawValue || error.code == SUError.appcastParseError.rawValue
            || error.code == SUError.appcastError.rawValue
    }
    #endif
}
#endif

/// The app's update checks: the daily schedule the preference controls, and
/// the "Check for Updates…" action.
@MainActor
@objc(UBUpdater)
public final class Updater: NSObject {
    /// Whether this build carries an updater at all.
    ///
    /// False when Sparkle was not compiled in, in which case the app surfaces
    /// no update interface.
    public static var isAvailable: Bool {
        #if canImport(Sparkle)
        return true
        #else
        return false
        #endif
    }

    /// Whether `[updates] check_automatically` asks for scheduled checks, as
    /// Core resolves it.
    static var shouldCheckAutomatically: Bool {
        Ubiquitty.Preferences.Effective.shouldCheckForUpdatesAutomatically(Ubiquitty.Preferences.values().pointee)
    }

    #if canImport(Sparkle)
    // SPUStandardUpdaterController bundles SPUUpdater with the standard UI user
    // driver. It reads SUFeedURL / SUPublicEDKey and the schedule keys from the
    // bundle's Info.plist and owns both kinds of check.
    private let controller: SPUStandardUpdaterController

    // Sparkle holds its delegate weakly, so the policy lives as long as the
    // updater that installed it.
    private let policy: UpdatePolicy

    /// Core's registration; the schedule follows every configuration change
    /// for as long as the updater lives.
    private var subscription: Ubiquitty.Preferences.ConfigurationSubscription?

    private override init() {
        let policy = UpdatePolicy()
        self.policy = policy
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: policy,
            userDriverDelegate: nil
        )
        super.init()
        followPreference()
        subscription = Ubiquitty.Preferences.ConfigurationSubscription.notifying(
            Ubiquitty.Apple.ownedCallback { [weak self] in
                // Core calls subscribers on the main thread, after the live
                // values are replaced.
                MainActor.assumeIsolated { self?.followPreference() }
            }
        )
    }

    /// Sets Sparkle's schedule to what the preference says.
    ///
    /// Compared first: every configuration change arrives here, and an
    /// assignment rewrites Sparkle's stored copy and restarts its cycle even
    /// when the value is the one it already holds.
    private func followPreference() {
        let shouldCheck = Self.shouldCheckAutomatically
        if controller.updater.automaticallyChecksForUpdates != shouldCheck {
            controller.updater.automaticallyChecksForUpdates = shouldCheck
        }
    }

    /// Whether a check can begin now — no while one is already running.
    public var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    /// Whether the updater runs Sparkle's daily schedule, which it does
    /// exactly while the preference asks for it.
    public var isAutomaticCheckScheduled: Bool { controller.updater.automaticallyChecksForUpdates }

    /// Whether the updater could download or install an update without the
    /// person, or offer to. Always false: the bundle disallows it.
    public var mayInstallWithoutAsking: Bool {
        controller.updater.automaticallyDownloadsUpdates || controller.updater.allowsAutomaticUpdates
    }

    /// Whether Sparkle has said it relaunches the app into an update once this
    /// process ends.
    ///
    /// Sparkle says so once, just before it asks the app to quit, and the
    /// answer holds for the rest of the process. The quit request is one the
    /// app may cancel: the installer then waits for this process to end,
    /// however it ends, and installs and relaunches when it does, so every
    /// quit after the report is the relaunch's.
    public var isRelaunchingForUpdate: Bool { policy.isRelaunchPending }

    /// Target/action for the "Check for Updates…" menu item.
    ///
    /// - Parameter sender: The menu item, passed through to Sparkle.
    @objc
    public func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    /// The started updater, or nil when this build has no Sparkle.
    ///
    /// Starting it arms the menu item's check and, while the preference asks
    /// for it, the schedule: Sparkle runs a scheduled check once a full
    /// interval has passed since the last check, at once when there has been
    /// none.
    @objc
    public static func startedUpdater() -> Updater? {
        let updater = Updater()
        updater.controller.startUpdater()
        return updater
    }

    #if UBIQUITTY_UI_TESTS
    // Test-only seams, not compiled into a shipping build: a scenario runs the
    // check the schedule runs and reads what Sparkle reported back.

    /// Runs the check Sparkle's schedule runs, now.
    func runScheduledCheck() {
        controller.updater.checkForUpdatesInBackground()
    }

    /// Whether Sparkle has a check, or its own scheduling, under way.
    var isSessionInProgress: Bool { controller.updater.sessionInProgress }

    /// How many update cycles have finished since launch.
    var finishedCycleCount: Int { policy.finishedCycleCount }

    /// Whether the last cycle to finish was a scheduled check that failed
    /// fetching or reading the feed.
    var didLastCycleFailAtFeed: Bool { policy.didLastCycleFailAtFeed }

    /// How many times Sparkle scheduled a check since launch.
    var scheduleCount: Int { policy.scheduleCount }

    /// The delay Sparkle last scheduled a check after, or nil before it has.
    var lastScheduledDelay: TimeInterval? { policy.lastScheduledDelay }

    /// Delivers Sparkle's relaunch notice through the delegate Sparkle calls,
    /// as Install and Relaunch does, without installing anything.
    func deliverRelaunchNoticeForTesting() {
        policy.updaterWillRelaunchApplication(controller.updater)
    }
    #endif
    #else
    private override init() {
        super.init()
    }

    /// Whether a check can begin now. Never, without Sparkle.
    public var canCheckForUpdates: Bool { false }

    /// Whether the updater schedules checks of its own. Nothing schedules a
    /// check in a build that cannot make one.
    public var isAutomaticCheckScheduled: Bool { false }

    /// Whether the updater could install without the person. A build without
    /// Sparkle installs nothing.
    public var mayInstallWithoutAsking: Bool { false }

    /// Whether an update relaunches the app once this process ends. Never,
    /// without Sparkle.
    public var isRelaunchingForUpdate: Bool { false }

    /// Target/action for the "Check for Updates…" menu item; inert here, and
    /// the caller surfaces no such item in this build.
    @objc
    public func checkForUpdates(_ sender: Any?) {
        _ = sender
    }

    /// The started updater, which a build without Sparkle does not have.
    @objc
    public static func startedUpdater() -> Updater? {
        nil
    }

    #if UBIQUITTY_UI_TESTS
    // The seams above, inert: there is no check to run or report.
    func runScheduledCheck() {}
    var isSessionInProgress: Bool { false }
    var finishedCycleCount: Int { 0 }
    var didLastCycleFailAtFeed: Bool { false }
    var scheduleCount: Int { 0 }
    var lastScheduledDelay: TimeInterval? { nil }
    func deliverRelaunchNoticeForTesting() {}
    #endif
    #endif

    /// Greys the "Check for Updates…" item out while a check is in flight.
    ///
    /// AppKit calls this on the item's target, which is this object.
    ///
    /// - Parameter item: The item being validated.
    /// - Returns: Whether the item is enabled.
    @objc
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(checkForUpdates(_:)) ? canCheckForUpdates : true
    }
}
