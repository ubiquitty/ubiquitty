// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CxxStdlib
import Security
import UbiquittyAppBridge
import UbiquittyAppleCallbacks
import UbiquittyCore
import UbiquittyKit
import UbiquittyLocalHostInstall

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
// The delegate holds installation while the app adopts local panes and proves
// that the updated host took their sessions. The later relaunch notice names
// the quit; it is not the gate that preserves process ownership.
//
// No Sparkle type appears in this file's @objc surface, and that is a
// requirement rather than a preference: the generated interop header is
// imported by every Objective-C++ translation unit in the app, and a Sparkle
// protocol named there would ask each of them to find a framework only this
// file knows about. The delegate is a private object for that reason.

#if canImport(Sparkle)
/// The standard sheet still owns the person's choice. Preparation runs before
/// its Install reply, so Dismiss retains Sparkle's install-on-quit path.
private final class UpdateUserDriver: SPUStandardUserDriver {
    weak var owner: Updater?

    override func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        let choice = await super.showReadyToInstallAndRelaunch()
        guard choice == .install else { return choice }
        return await owner?.prepareUpdateRelaunch() ?? .dismiss
    }
}

/// Preparation owns no nested modal loop: attachments and the transfer keep
/// advancing while the person can see which part of the update is pending.
@MainActor
private final class UpdatePreparationProgress {
    private let panel: NSPanel
    private let status = NSTextField(wrappingLabelWithString: "")
    private let indicator = NSProgressIndicator()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 148),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Preparing Update"
        panel.identifier = NSUserInterfaceItemIdentifier("updatePreparationProgress")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let content = NSView()
        panel.contentView = content
        status.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        status.setAccessibilityIdentifier("updatePreparationStatus")
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.setAccessibilityLabel("Preparing update")
        let detail = NSTextField(wrappingLabelWithString: "Ubiquitty will restart after your sessions are ready.")
        detail.textColor = .secondaryLabelColor
        for view in [status, indicator, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            status.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            indicator.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            indicator.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            indicator.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 16),
            detail.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            detail.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 16),
            detail.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])
        panel.center()
    }

    func show(_ message: String) {
        status.stringValue = message
        panel.orderFront(nil)
        indicator.startAnimation(nil)
        panel.displayIfNeeded()
    }

    #if UBIQUITTY_UI_TESTS
    var isVisible: Bool { panel.isVisible }
    #endif

    func close() {
        indicator.stopAnimation(nil)
        panel.close()
    }
}

/// A host extracted from a separately downloaded appcast archive, retained
/// until takeover finishes. This copy is admitted by its release team
/// signature and checked version; Sparkle validates its own archive.
private struct UpdateHostCandidate: Sendable {
    let path: String
    let directory: URL
    let version: String

    static func stage(from url: URL, expectedBuild: String, expectedVersion: String, contentLength: UInt64) async -> Self? {
        guard url.scheme == "https", contentLength > 0, contentLength <= 256 * 1024 * 1024,
            url.pathExtension.lowercased() == "zip"
        else { return nil }
        guard let (archive, response) = try? await URLSession.shared.download(from: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: archive) }
        guard response.expectedContentLength <= 256 * 1024 * 1024 else { return nil }
        return stage(archive: archive, expectedBuild: expectedBuild, expectedVersion: expectedVersion)
    }

    static func stage(archive: URL, expectedBuild: String, expectedVersion: String) -> Self? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size]) as? NSNumber,
            size.uint64Value <= 256 * 1024 * 1024,
            let info = readEntry("Ubiquitty.app/Contents/Info.plist", from: archive, maxBytes: 1 * 1024 * 1024),
            let dictionary = (try? PropertyListSerialization.propertyList(from: info, options: 0, format: nil)) as? [String: Any],
            dictionary["CFBundleVersion"] as? String == expectedBuild,
            dictionary["CFBundleShortVersionString"] as? String == expectedVersion,
            let binary = readEntry("Ubiquitty.app/Contents/Helpers/ubiquitty-host", from: archive, maxBytes: 64 * 1024 * 1024)
        else { return nil }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ubq-update-\(UUID().uuidString)")
        let host = directory.appendingPathComponent("ubiquitty-host")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try binary.write(to: host, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        guard isTrustedReleaseHost(at: host) else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return Self(path: host.path, directory: directory, version: expectedVersion)
    }

    private static func readEntry(_ name: String, from archive: URL, maxBytes: Int) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, name]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        var bytes = Data()
        while true {
            let chunk = output.fileHandleForReading.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            if bytes.count > maxBytes - chunk.count {
                process.terminate()
                process.waitUntilExit()
                return nil
            }
            bytes.append(chunk)
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 && !bytes.isEmpty ? bytes : nil
    }

    private static func isTrustedReleaseHost(at url: URL) -> Bool {
        var requirement: SecRequirement?
        let expression = String(Ubiquitty.Host.trustedHostSignatureRequirement())
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

/// Why a scheduled check was declined, for the error Sparkle reports.
private struct ScheduledCheckDeclined: LocalizedError {
    var errorDescription: String? { "Automatic update checks are turned off." }
}

/// What the updater may do without the person, what its checks report, and
/// whether it is about to relaunch the app.
private final class UpdatePolicy: NSObject, SPUUpdaterDelegate {
    weak var owner: Updater?
    private(set) var selectedItem: SUAppcastItem?
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

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        selectedItem = item
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        selectedItem = item
    }

    /// A relaunch without the completed ownership gate cannot close the app.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        owner?.mayTerminateAfterUpdatePreparation == true
    }

    func clearPendingRelaunch() {
        isRelaunchPending = false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor [weak owner] in
            await owner?.cancelPreparedUpdateAfterAbort()
        }
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
    // Sparkle reads SUFeedURL / SUPublicEDKey and the schedule keys from the
    // bundle. The standard user driver keeps its native update interface.
    private let userDriver: UpdateUserDriver
    private let sparkleUpdater: SPUUpdater

    // Sparkle holds its delegate weakly, so the policy lives as long as the
    // updater that installed it.
    private let policy: UpdatePolicy
    private var isPreparingUpdateRelaunch = false
    private var isUpdateTerminationAuthorized = false
    private var preparedCapture: TerminalWindows.PreparedUpdateCapture?
    private var previousCurrentLayout: LayoutSession?
    private var didCommitCaptureForInstallation = false

    /// Core's registration; the schedule follows every configuration change
    /// for as long as the updater lives.
    private var subscription: Ubiquitty.Preferences.ConfigurationSubscription?

    private override init() {
        let policy = UpdatePolicy()
        let userDriver = UpdateUserDriver(hostBundle: Bundle.main, delegate: nil)
        self.policy = policy
        self.userDriver = userDriver
        sparkleUpdater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: policy
        )
        super.init()
        policy.owner = self
        userDriver.owner = self
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
        if sparkleUpdater.automaticallyChecksForUpdates != shouldCheck {
            sparkleUpdater.automaticallyChecksForUpdates = shouldCheck
        }
    }

    /// Whether a check can begin now — no while one is already running.
    public var canCheckForUpdates: Bool { sparkleUpdater.canCheckForUpdates }

    /// Whether the updater runs Sparkle's daily schedule, which it does
    /// exactly while the preference asks for it.
    public var isAutomaticCheckScheduled: Bool { sparkleUpdater.automaticallyChecksForUpdates }

    /// Whether the updater could download or install an update without the
    /// person, or offer to. Always false: the bundle disallows it.
    public var mayInstallWithoutAsking: Bool {
        sparkleUpdater.automaticallyDownloadsUpdates || sparkleUpdater.allowsAutomaticUpdates
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

    /// The app has already captured its panes and either proved takeover or
    /// received explicit permission to restart despite a failed preparation.
    public var mayTerminateAfterUpdatePreparation: Bool { isUpdateTerminationAuthorized }

    /// A quit cannot discard a prepared local owner while Sparkle is held.
    public var isUpdatePreparationInProgress: Bool { isPreparingUpdateRelaunch }

    /// Publishes the already proved arrangement at Sparkle's actual quit.
    public func commitPreparedUpdateAtQuit() {
        guard !didCommitCaptureForInstallation, let preparedCapture else { return }
        TerminalWindows.commitUpdateCapture(preparedCapture)
        didCommitCaptureForInstallation = true
    }

    fileprivate func cancelPreparedUpdateAfterAbort() async {
        guard isUpdateTerminationAuthorized else { return }
        isPreparingUpdateRelaunch = true
        isUpdateTerminationAuthorized = false
        policy.clearPendingRelaunch()
        if let preparedCapture { await TerminalWindows.reclaimUpdateAdoptions(preparedCapture) }
        if didCommitCaptureForInstallation {
            RemoteSessionLifecycle.shared.resumeAfterCancelledTermination()
            if let previousCurrentLayout {
                SessionLayout.saveCurrentLayout(previousCurrentLayout.groups, keptFor: previousCurrentLayout.keptFor)
            } else {
                SessionLayout.saveCurrentLayout([])
            }
        }
        preparedCapture = nil
        didCommitCaptureForInstallation = false
        previousCurrentLayout = nil
        isPreparingUpdateRelaunch = false
    }

    fileprivate func prepareUpdateRelaunch() async -> SPUUserUpdateChoice {
        guard !isPreparingUpdateRelaunch else { return .dismiss }
        isPreparingUpdateRelaunch = true
        let progress = UpdatePreparationProgress()
        progress.show("Preparing your terminals…")
        #if UBIQUITTY_UI_TESTS
        didShowUpdatePreparationForTesting = progress.isVisible
        #endif
        defer { progress.close() }
        // Let AppKit present the progress window before synchronous adoption.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        previousCurrentLayout = SessionLayout.allSessions().first { $0.identifier == SessionLayout.currentIdentifier }
        let capture = TerminalWindows.prepareUpdateCapture()
        preparedCapture = capture
        var facts = Ubiquitty.Session.UpdateRelaunchFacts()
        facts.localPaneCount = .init(capture.localPanes.count)
        facts.adoptedLocalPaneCount = .init(capture.adoptedLocalPaneCount)
        facts.unresolvedAdoptionCount = .init(Ubiquitty.Runtime.TerminalSession.unresolvedLocalAdoptionCount())
        progress.show("Connecting to your running sessions…")
        let predecessors =
            facts.localPaneCount == facts.adoptedLocalPaneCount && facts.unresolvedAdoptionCount == 0
            ? await TerminalWindows.settledUpdateAdoptions(capture) : nil
        facts.attachedLocalPaneCount = .init(predecessors?.count ?? 0)

        var candidate: UpdateHostCandidate?
        if facts.localPaneCount == facts.adoptedLocalPaneCount,
            facts.attachedLocalPaneCount == facts.localPaneCount,
            facts.unresolvedAdoptionCount == 0
        {
            progress.show("Checking the update…")
            #if UBIQUITTY_UI_TESTS
            if let testArchive {
                candidate = UpdateHostCandidate.stage(
                    archive: testArchive.url,
                    expectedBuild: testArchive.build,
                    expectedVersion: testArchive.version
                )
            }
            #endif
            if candidate == nil, let item = policy.selectedItem, let address = item.fileURL {
                candidate = await UpdateHostCandidate.stage(
                    from: address,
                    expectedBuild: item.versionString,
                    expectedVersion: item.displayVersionString,
                    contentLength: item.contentLength
                )
            }
        }
        if let candidate {
            facts.isNewHostVerified = true
            progress.show("Moving your running sessions…")
            let takeover = await LocalHostUpgrade.beforeUpdate(using: candidate.path, version: candidate.version)
            facts.isNewHostInstalled = takeover.isInstalled
            facts.isNewHostAnswering = takeover.isAnswering
            facts.olderHostCount = .init(takeover.olderHostCount)
            facts.pendingSessionCount = .init(takeover.olderHostCount)
            if let predecessors, facts.isNewHostAnswering {
                progress.show("Checking your sessions are ready…")
                facts.movedLocalPaneCount = .init(
                    await TerminalWindows.movedUpdateAdoptionCount(capture, from: predecessors)
                )
            }
            try? FileManager.default.removeItem(at: candidate.directory)
        }
        for (index, pane) in capture.localPanes.enumerated() {
            let reason: String
            if !pane.drive.isSharedIntoLocalDaemon {
                reason = "local handoff did not commit"
            } else if pane.drive.remoteState != .Connected {
                reason = "host attachment \(pane.drive.remoteState); \(pane.drive.lastRemoteTransitionDetail)"
            } else if pane.drive.remoteSessionID != pane.drive.sharedSessionID {
                reason = "host attachment names another session"
            } else if let predecessors, pane.drive.remoteDaemonInstanceID == predecessors[index],
                facts.isNewHostAnswering
            {
                reason = "new host has not taken over the adopted session"
            } else if !facts.isNewHostVerified {
                reason = "new host binary could not be verified"
            } else if !facts.isNewHostInstalled || !facts.isNewHostAnswering {
                reason = "new host did not start and answer"
            } else {
                reason = "handoff and attachment confirmed"
            }
            Ubiquitty.SwiftBridge.writeDiagnostic(
                std.string("Update pane \(index + 1) (\(capture.foregroundPrograms[index])): \(reason)")
            )
        }
        if Ubiquitty.Session.updateRelaunchAction(facts, .Unasked) == .InstallNow {
            progress.show("Restarting Ubiquitty…")
            isPreparingUpdateRelaunch = false
            isUpdateTerminationAuthorized = true
            return .install
        }

        let namedPane =
            capture.localPanes.firstIndex {
                !$0.drive.isSharedIntoLocalDaemon || $0.drive.remoteState != .Connected
            } ?? 0
        let foregroundProgram =
            capture.foregroundPrograms.indices.contains(namedPane)
            ? capture.foregroundPrograms[namedPane] : ""
        progress.show("Returning to your terminals…")
        await TerminalWindows.reclaimUpdateAdoptions(capture)
        progress.close()
        isPreparingUpdateRelaunch = false
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = String(Ubiquitty.Session.updateRelaunchRiskTitle())
        alert.informativeText = String(
            Ubiquitty.Session.updateRelaunchRiskDetail(facts.localPaneCount, std.string(foregroundProgram))
        )
        alert.addButton(withTitle: String(Ubiquitty.Session.updateRelaunchProceedTitle()))
        alert.addButton(withTitle: String(Ubiquitty.Session.updateRelaunchPostponeTitle()))
        let acceptedRisk = alert.runModal() == .alertFirstButtonReturn
        facts.unresolvedAdoptionCount = .init(Ubiquitty.Runtime.TerminalSession.unresolvedLocalAdoptionCount())
        let choice: Ubiquitty.Session.UpdateRiskChoice = acceptedRisk ? .RestartAnyway : .NotNow
        if Ubiquitty.Session.updateRelaunchAction(facts, choice) == .InstallNow {
            let reply = TerminalWindows.terminationReply(for: .UpdateRelaunch) { _ in .alertFirstButtonReturn }
            if reply == .terminateNow {
                didCommitCaptureForInstallation = true
                isUpdateTerminationAuthorized = true
                return .install
            }
        }
        preparedCapture = nil
        previousCurrentLayout = nil
        return .dismiss
    }

    /// Target/action for the "Check for Updates…" menu item.
    ///
    /// - Parameter sender: The menu item, passed through to Sparkle.
    @objc
    public func checkForUpdates(_ sender: Any?) {
        sparkleUpdater.checkForUpdates()
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
        do {
            try updater.sparkleUpdater.start()
            return updater
        } catch {
            Ubiquitty.SwiftBridge.writeDiagnostic(std.string("Updater could not start: \(error.localizedDescription)"))
            return nil
        }
    }

    #if UBIQUITTY_UI_TESTS
    // Test-only seams, not compiled into a shipping build: a scenario runs the
    // check the schedule runs and reads what Sparkle reported back.

    /// Runs the check Sparkle's schedule runs, now.
    func runScheduledCheck() {
        sparkleUpdater.checkForUpdatesInBackground()
    }

    /// Whether Sparkle has a check, or its own scheduling, under way.
    var isSessionInProgress: Bool { sparkleUpdater.sessionInProgress }

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
        policy.updaterWillRelaunchApplication(sparkleUpdater)
    }

    /// Exercises the same preparation the Install button awaits, without a
    /// release feed or an installer that would replace the test application.
    private(set) var didShowUpdatePreparationForTesting = false
    private var testArchive: (url: URL, build: String, version: String)?

    func prepareUpdateRelaunchForTesting() async -> Bool {
        await prepareUpdateRelaunch() == .install
    }

    /// Uses a local signed release archive while retaining the version and
    /// signature checks, adoption, takeover and rollback of the Install path.
    func prepareUpdateRelaunchForTesting(archive: URL, build: String, version: String) async -> Bool {
        testArchive = (archive, build, version)
        defer { testArchive = nil }
        return await prepareUpdateRelaunch() == .install
    }

    func cancelPreparedUpdateForTesting() async {
        await cancelPreparedUpdateAfterAbort()
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

    public var mayTerminateAfterUpdatePreparation: Bool { false }

    public var isUpdatePreparationInProgress: Bool { false }

    public func commitPreparedUpdateAtQuit() {}

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
    var didShowUpdatePreparationForTesting: Bool { false }
    func prepareUpdateRelaunchForTesting() async -> Bool { false }
    func prepareUpdateRelaunchForTesting(archive: URL, build: String, version: String) async -> Bool { false }
    func cancelPreparedUpdateForTesting() async {}
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
