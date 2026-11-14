// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// LocalHostUpgrade.swift — bringing this Mac's host up to the build the app
// bundles, so an app update carries the person's live sessions to the new
// host without a step of theirs.
//
// What is installed and when a host is started are decided behind the POSIX
// seam (`Session::upgradeLocalHost`), and what a person is told is Core's
// (`Session::localHostUpgradeTitle`); this file runs one upgrade at a time off
// the main thread, at launch and when a person asks to update This Mac's
// host, and writes what each did to the log.

internal import CxxStdlib
import Foundation
import OSLog
internal import UbiquittyCore
internal import UbiquittyLocalHostInstall

/// What an upgrade left undone, in Core's words; both empty when every
/// session moved.
package struct LocalHostUpgradeReport: Sendable {
    package let title: String
    package let sentence: String
}

@MainActor
package enum LocalHostUpgrade {
    nonisolated private static let log = Logger(subsystem: "org.ubiquitty.Ubiquitty", category: "LocalHost")

    /// The launch's upgrade, started once.
    private static var launch: Task<LocalHostUpgradeReport, Never>?
    /// The upgrade started last, which the next one waits for.
    private static var running: Task<LocalHostUpgradeReport, Never>?

    /// Whether this copy of the app updates This Mac's host: it bundles one,
    /// and is installed or upgrades only a private control directory.
    package static var isAvailable: Bool {
        guard ShareSessionSupport.localHostBinaryPath() != nil else { return false }
        return Ubiquitty.Session.isLocalHostUpgradable(ShareSessionSupport.isDevelopmentBundle(Bundle.main) ? .development : .release)
    }

    /// Starts the launch's upgrade, if it has not started.
    ///
    /// The app calls this before it restores any window, so a window saved on
    /// the older host reattaches on the host that took it over.
    package static func beginAtLaunch() {
        if launch == nil { launch = start() }
    }

    /// Waits for the launch's upgrade to finish, starting it if nothing has.
    package static func settledAtLaunch() async {
        beginAtLaunch()
        _ = await launch?.value
    }

    /// Runs the upgrade again, as the Update Host remedy for This Mac asks,
    /// after any upgrade already running.
    ///
    /// - Returns: What it left undone.
    package static func now() async -> LocalHostUpgradeReport {
        await start().value
    }

    private static func start() -> Task<LocalHostUpgradeReport, Never> {
        let previous = running
        let bundled = ShareSessionSupport.localHostBinaryPath()
        let isDevelopment = ShareSessionSupport.isDevelopmentBundle(Bundle.main)
        let task = Task.detached(priority: .userInitiated) { () -> LocalHostUpgradeReport in
            _ = await previous?.value
            guard let bundled else {
                Self.log.notice("This copy of Ubiquitty includes no host, so this Mac’s host was left as it is.")
                return LocalHostUpgradeReport(title: "", sentence: "")
            }
            let outcome = Ubiquitty.Session.upgradeLocalHost(std.string(bundled), isDevelopment ? .development : .release)
            Self.record(outcome, bundled: bundled)
            var facts = Ubiquitty.Session.LocalHostUpgradeFacts()
            facts.olderHostCount = outcome.olderHostCount
            facts.isMoveAdvised = outcome.refusingHostCount > 0 && outcome.install.isOnAnotherVolume
            facts.isNewerInstalled = outcome.install.kind == .newerInstalled
            return LocalHostUpgradeReport(
                title: String(Ubiquitty.Session.localHostUpgradeTitle(facts)),
                sentence: String(Ubiquitty.Session.localHostUpgradeSentence(facts))
            )
        }
        running = task
        return task
    }

    nonisolated private static func record(_ outcome: Ubiquitty.Session.LocalHostUpgradeOutcome, bundled: String) {
        let reason = String(outcome.install.reason)
        switch outcome.install.kind {
        case .notAttempted:
            log.notice("A development build leaves this Mac’s host as it is unless UBIQUITTY_HOME names a private one.")
        case .current:
            break
        case .linked:
            log.notice("Installed \(bundled, privacy: .public) as this Mac’s host.")
        case .copied:
            log.notice(
                "Installed a copy of \(bundled, privacy: .public) as this Mac’s host, because \(reason, privacy: .public). An older host installed at that path doesn’t hand its sessions to this app’s host."
            )
        case .newerInstalled:
            log.notice("This Mac’s installed host is from a newer build (\(reason, privacy: .public)), so it was left as it is.")
        case .refused:
            log.error("This Mac’s host could not be updated, because \(reason, privacy: .public).")
        @unknown default:
            break
        }
        if outcome.didStartSuccessor {
            if outcome.isBundledHostAnswering {
                log.notice(
                    "Started \(bundled, privacy: .public) to take over the sessions of an older host; its log says which sessions it took."
                )
            } else {
                log.error("\(bundled, privacy: .public) did not start, so an older host keeps its sessions.")
            }
        }
        if outcome.olderHostCount > 0 {
            log.notice(
                "\(outcome.olderHostCount, privacy: .public) host(s) of an older build still serve on this Mac; \(outcome.refusingHostCount, privacy: .public) of them run from a path where this app’s host isn’t installed."
            )
        }
    }
}
