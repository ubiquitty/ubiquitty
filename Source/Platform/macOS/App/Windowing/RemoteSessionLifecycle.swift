// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// RemoteSessionLifecycle.swift — tells every remote session what the Mac did.
//
// Core decides what a moved network path or a wake means for the carrier a
// session holds; this shell only reports the facts. Without them a session
// that dropped while the lid was shut would wait out a backoff of up to 30 s on a
// network that was already up, and an attempt still dialling the old path would
// never be told it had gone.

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// Reports network moves and wakes to every remote session in the app.
@MainActor
package final class RemoteSessionLifecycle {
    /// The one watcher, started by the first window that attaches remotely.
    package static let shared = RemoteSessionLifecycle()

    private var pathWatch: NetworkPathWatch?
    private var observers: [NSObjectProtocol] = []
    private var sleptAt: ContinuousClock.Instant?

    private init() {}

    /// Starts watching once; later calls do nothing.
    func start() {
        guard pathWatch == nil else { return }
        let watch = NetworkPathWatch(
            onMove: { RemoteSessionLifecycle.eachRemoteSurface { $0.networkPathChanged() } },
            onCost: { cost in RemoteSessionLifecycle.eachRemoteSurface { $0.setNetworkCost(cost) } }
        )
        pathWatch = watch
        watch.start()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RemoteSessionLifecycle.shared.willSleep() }
            }
        )
        observers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RemoteSessionLifecycle.shared.didWake() }
            }
        )
    }

    /// Tells a surface that is starting a remote session the path's cost as
    /// last observed: the watch reports a cost only when it changes, and this
    /// surface was not there to hear it.
    ///
    /// - Parameter surface: The surface about to attach.
    func reportNetworkCost(to surface: TerminalSurface) {
        guard let cost = pathWatch?.cost else { return }
        surface.setNetworkCost(cost)
    }

    /// Notes when the Mac went to sleep, and tells each session's host that
    /// its client is about to stop reading, so the host holds the attachment
    /// rather than sending into a machine that is asleep.
    private func willSleep() {
        sleptAt = ContinuousClock.now
        Self.eachRemoteSurface { $0.drive.suspendRemote() }
    }

    /// Whether the app is quitting: a remote window closing now keeps its
    /// record, which the next launch resumes, rather than retiring it.
    package private(set) var isTerminating = false

    /// Suspends every remote session as the app quits. Each writes its
    /// resume record while its connection is still open and then says
    /// goodbye as a suspended client, which leaves the attachment for the
    /// next launch to resume.
    package func suspendForTermination() {
        isTerminating = true
        Self.eachRemoteSurface { $0.drive.suspendRemote() }
    }

    /// A postponed installation that aborts leaves the old app serving its
    /// windows, so its suspended connections resume under that app.
    package func resumeAfterCancelledTermination() {
        guard isTerminating else { return }
        isTerminating = false
        Self.eachRemoteSurface { $0.drive.resumeAfterSuspension(secondsSuspended: 0) }
    }

    /// Hands each session the time the Mac slept, which Core weighs against
    /// how long the host keeps an idle connection.
    private func didWake() {
        let secondsSlept = sleptAt.map { (ContinuousClock.now - $0) / .seconds(1) } ?? -1
        sleptAt = nil
        Self.eachRemoteSurface { $0.drive.resumeAfterSuspension(secondsSuspended: secondsSlept) }
    }

    /// Runs `body` on every window's remote root surface. The windows of one
    /// workspace share a connection, and Core acts once on a fact every one of
    /// them relays in the same turn.
    private static func eachRemoteSurface(_ body: (TerminalSurface) -> Void) {
        for window in NSApp.windows {
            guard let controller = window.windowController as? TerminalWindowController,
                let surface = controller.remoteSurface, surface.isRemoteAttached
            else { continue }
            body(surface)
        }
    }
}
