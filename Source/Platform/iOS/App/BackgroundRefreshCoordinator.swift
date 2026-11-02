// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import BackgroundTasks
import CxxStdlib
import Foundation
import Observation
import UIKit
import UbiquittyCore
import UserNotifications

/// Cached host information that can be displayed without creating a terminal session.
struct BackgroundRefreshSummary {
    struct Pane: Identifiable {
        let id: String
        let sessionID: UInt32
        let title: String
        let status: String
        let screen: String
    }
    var refreshedAt: Date?
    var panes: [Pane] = []
    var failure: String?
    var hadRetentionGap = false
}

/// Adapts the same Core catch-up policy to foreground visits and opportunistic iOS wakes.
@Observable
@MainActor
final class BackgroundRefreshCoordinator {
    static let shared = BackgroundRefreshCoordinator()
    static let taskIdentifier = "org.ubiquitty.host-refresh"

    private(set) var summaries: [UUID: BackgroundRefreshSummary] = [:]
    var requestedHostID: UUID?
    @ObservationIgnored
    private let store = BackgroundRefreshStore()
    @ObservationIgnored
    private var activeRun: BackgroundRefreshRun?
    @ObservationIgnored
    private var activeConnection: BackgroundRefreshConnection?
    @ObservationIgnored
    private var isRegistered = false
    @ObservationIgnored
    private let notificationCenter = UNUserNotificationCenter.current()
    @ObservationIgnored
    private var liveModels: [UUID: WeakModel] = [:]
    @ObservationIgnored
    private var hasPendingForegroundRefresh = false

    private final class WeakModel {
        weak var model: TerminalSessionModel?
        init(_ model: TerminalSessionModel) { self.model = model }
    }

    /// Borrows an existing model's audience facts without creating a terminal attachment.
    func observe(_ model: TerminalSessionModel, for identifier: UUID) {
        liveModels[identifier] = WeakModel(model)
    }

    /// Routes opted-in live events through the same retained inbox as background delivery.
    func noteLiveNotification(for identifier: UUID) -> Bool {
        guard HostStore.shared.hosts.contains(where: { $0.id == identifier && $0.backgroundRefreshAuthorization != nil }) else {
            return false
        }
        hasPendingForegroundRefresh = true
        if UIApplication.shared.applicationState == .active { refreshInForeground() }
        return true
    }

    /// How iOS shows a banner request while the app is in front.
    ///
    /// Only a request Core accepts, for a producer still held: a retained event
    /// under the host's current permission, or a live attachment whose model,
    /// daemon and session are still the ones that posted it.
    ///
    /// - Parameter origin: The origin of the request about to be presented.
    /// - Returns: The presentation options.
    func presentationOptions(for origin: NotificationPresentationOrigin) -> UNNotificationPresentationOptions {
        origin.options(
            isRetainedCurrent: { hostID, permissionID in self.isPermissionCurrent(hostID: hostID, permissionID: permissionID) },
            retainedAudience: { hostID, sessionID in self.liveModels[hostID]?.model?.backgroundBannerAudience(sessionID: sessionID) },
            liveAudience: { self.liveModels[$0.hostID]?.model?.liveBannerAudience(for: $0) }
        )
    }

    /// The host a tapped banner opens, only for a producer still held.
    ///
    /// - Parameter origin: The tapped request's origin.
    /// - Returns: The saved host, or nil.
    func hostToOpen(for origin: NotificationPresentationOrigin) -> UUID? {
        if let live = origin.live {
            return liveModels[live.hostID]?.model?.liveBannerAudience(for: live) != nil ? live.hostID : nil
        }
        guard let permissionID = origin.permissionID, isPermissionCurrent(hostID: origin.hostID, permissionID: permissionID) else {
            return nil
        }
        return origin.hostID
    }

    private func isPermissionCurrent(hostID: UUID, permissionID: UUID) -> Bool {
        HostStore.shared.hosts.contains { $0.id == hostID && $0.backgroundRefreshAuthorization?.permissionID == permissionID }
    }

    /// Registers the launch handler synchronously before application launch finishes.
    func register() {
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let refresh = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                Self.shared.begin(task: refresh)
            }
        }
        for host in HostStore.shared.hosts {
            guard let authorization = host.backgroundRefreshAuthorization else { continue }
            let state = restoredState(for: authorization)
            publish(state, for: authorization)
        }
    }

    /// Cancels foreground-only work before suspension and requests the next opportunistic wake.
    func applicationBackgrounded() {
        if let activeRun, !activeRun.isBackground { activeRun.cancel() }
        scheduleNext()
    }

    /// Uses the same persisted cursors when a foreground visit can catch up sooner.
    func refreshInForeground() {
        guard activeRun == nil else { return }
        begin(task: nil)
    }

    /// Reconciles a saved opt-in and revokes any operation using obsolete host settings.
    func settingsChanged() {
        activeRun?.cancel()
        scheduleNext()
        if UIApplication.shared.applicationState == .active { refreshInForeground() }
    }

    /// Requests notification permission only following the reader's foreground opt-in.
    func requestNotificationPermission() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Removes background material and banners without changing an interactive session.
    @discardableResult
    func revoke(_ host: HostRecord) -> Bool {
        activeRun?.cancel()
        let didRemoveCache: Bool
        if let authorization = host.backgroundRefreshAuthorization {
            didRemoveCache = retire(authorization)
        } else {
            didRemoveCache = store.remove(for: host.id)
        }
        summaries.removeValue(forKey: host.id)
        let didRemoveSecret = BackgroundRefreshSecretStore.remove(for: host.id)
        return didRemoveCache && didRemoveSecret
    }

    /// Retires one permission's visible data without touching a replacement credential.
    @discardableResult
    func retire(_ authorization: BackgroundRefreshAuthorization) -> Bool {
        activeRun?.cancel()
        let didRemoveCache = store.remove(for: authorization.hostID)
        summaries.removeValue(forKey: authorization.hostID)
        Task {
            let delivered = await notificationCenter.deliveredNotifications()
            let names = delivered.filter { $0.request.identifier.hasPrefix(authorization.notificationPrefix) }
                .map { $0.request.identifier }
            notificationCenter.removeDeliveredNotifications(withIdentifiers: names)
            let pending = await notificationCenter.pendingNotificationRequests()
            let pendingNames = pending.filter { $0.identifier.hasPrefix(authorization.notificationPrefix) }
                .map(\.identifier)
            notificationCenter.removePendingNotificationRequests(withIdentifiers: pendingNames)
        }
        return didRemoveCache
    }

    private func scheduleNext() {
        guard isRegistered else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        guard HostStore.shared.hosts.contains(where: { $0.backgroundRefreshAuthorization != nil }) else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request) } catch {
            // Refusal does not block foreground catch-up; iOS may disable background execution.
        }
    }

    private func begin(task: BGAppRefreshTask?) {
        activeRun?.cancel()
        scheduleNext()
        guard HostStore.shared.hosts.contains(where: { $0.backgroundRefreshAuthorization != nil }) else {
            task?.setTaskCompleted(success: true)
            return
        }
        let run = BackgroundRefreshRun(
            isBackground: task != nil,
            cancelOperation: { [weak self] in self?.activeConnection?.cancel() },
            completion: { [weak self] success in
                task?.expirationHandler = nil
                task?.setTaskCompleted(success: success)
                self?.activeRun = nil
                self?.activeConnection = nil
                if self?.hasPendingForegroundRefresh == true {
                    Task { @MainActor [weak self] in
                        if UIApplication.shared.applicationState == .active { self?.refreshInForeground() }
                    }
                }
            }
        )
        activeRun = run
        hasPendingForegroundRefresh = false
        task?.expirationHandler = { [weak run] in
            Task { @MainActor in run?.cancel() }
        }
        run.start { [weak self] in await self?.refreshHosts() ?? false }
    }

    private func refreshHosts() async -> Bool {
        let hosts = HostStore.shared.hosts.filter { $0.backgroundRefreshAuthorization != nil }
        guard !hosts.isEmpty else { return true }
        let positionKey = "backgroundRefreshNextHost"
        let first = max(0, UserDefaults.standard.integer(forKey: positionKey)) % hosts.count
        var succeeded = true
        for offset in 0..<hosts.count {
            guard !Task.isCancelled else { return false }
            let index = (first + offset) % hosts.count
            UserDefaults.standard.set((index + 1) % hosts.count, forKey: positionKey)
            if !(await refresh(hosts[index])) { succeeded = false }
        }
        return succeeded
    }

    private func refresh(_ host: HostRecord) async -> Bool {
        guard let authorization = host.backgroundRefreshAuthorization, isCurrent(authorization) else { return false }
        guard let secret = BackgroundRefreshSecretStore.secret(for: host) else {
            summaries[host.id, default: BackgroundRefreshSummary()].failure =
                "The background credential isn’t available. Turn background refresh off and on again in this host’s settings."
            return false
        }
        var state = restoredState(for: authorization)
        state.beginRefresh()
        do {
            for _ in 0..<3 {
                try Task.checkCancellation()
                guard isCurrent(authorization) else { throw CancellationError() }
                guard let connection = BackgroundRefreshConnection(host: host, secret: secret) else { return false }
                activeConnection = connection
                let response = try await connection.request(String(state.makeRequest(std.string())))
                try Task.checkCancellation()
                guard isCurrent(authorization) else { throw CancellationError() }
                if activeConnection === connection { activeConnection = nil }
                guard state.applyResponse(std.string(response)) else { throw BackgroundRefreshConnection.Failure.invalidReply }
                try store.save(String(state.saveRecord()), for: authorization)
                publish(state, for: authorization)
                try await deliverPending(&state, for: host, authorization: authorization)
                if !state.hasMore() { break }
            }
            return true
        } catch {
            if !Task.isCancelled, isCurrent(authorization) {
                summaries[host.id, default: BackgroundRefreshSummary()].failure =
                    "The refresh didn’t finish. Showing the last saved status."
            }
            return false
        }
    }

    private func deliverPending(
        _ state: inout Ubiquitty.Session.BackgroundRefreshState,
        for host: HostRecord,
        authorization: BackgroundRefreshAuthorization
    ) async throws {
        let permission = (await notificationCenter.notificationSettings()).authorizationStatus
        try Task.checkCancellation()
        guard isCurrent(authorization) else { throw CancellationError() }
        let isAuthorized = permission == .authorized || permission == .provisional || permission == .ephemeral
        let count = Int(state.pendingNotificationCount())
        // Core may erase a retired entry, so identifiers are copied before delivery begins.
        let notifications = (0..<count).map { state.notificationAt($0) }
        for notification in notifications {
            try Task.checkCancellation()
            guard isCurrent(authorization) else { throw CancellationError() }
            let audience =
                liveModels[host.id]?.model?.backgroundBannerAudience(sessionID: notification.sessionID)
                ?? Ubiquitty.OSC.BannerAudience()
            guard isAuthorized, Ubiquitty.OSC.isBannerWanted(audience, notification.occasion) else {
                state.markDelivered(notification.identifier)
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = String(notification.title)
            content.subtitle = host.displayName
            content.body = String(notification.body)
            content.threadIdentifier = "host.\(host.id.uuidString)"
            content.userInfo = [
                NotificationPresentationOrigin.hostKey: host.id.uuidString,
                NotificationPresentationOrigin.permissionKey: authorization.permissionID.uuidString, "paneID": String(notification.paneID),
                NotificationPresentationOrigin.sessionKey: notification.sessionID,
                NotificationPresentationOrigin.occasionKey: notification.occasion.rawValue,
            ]
            let identifier = String(notification.identifier)
            let request = UNNotificationRequest(identifier: authorization.notificationPrefix + identifier, content: content, trigger: nil)
            try await BackgroundRefreshDelivery.post(
                identifier: request.identifier,
                isCurrent: { self.isCurrent(authorization) },
                add: { try await self.notificationCenter.add(request) },
                remove: { name in
                    self.notificationCenter.removeDeliveredNotifications(withIdentifiers: [name])
                    self.notificationCenter.removePendingNotificationRequests(withIdentifiers: [name])
                }
            )
            state.markDelivered(std.string(identifier))
            try store.save(String(state.saveRecord()), for: authorization)
        }
        if !notifications.isEmpty { try store.save(String(state.saveRecord()), for: authorization) }
    }

    private func isCurrent(_ authorization: BackgroundRefreshAuthorization) -> Bool {
        HostStore.shared.hosts.contains { $0.backgroundRefreshAuthorization == authorization }
    }

    private func restoredState(for authorization: BackgroundRefreshAuthorization) -> Ubiquitty.Session.BackgroundRefreshState {
        var state = Ubiquitty.Session.BackgroundRefreshState()
        if let record = store.load(for: authorization) { _ = state.restoreRecord(std.string(record)) }
        return state
    }

    private func publish(_ state: borrowing Ubiquitty.Session.BackgroundRefreshState, for authorization: BackgroundRefreshAuthorization) {
        var panes: [BackgroundRefreshSummary.Pane] = []
        for index in 0..<Int(state.paneCount()) {
            let pane = state.paneAt(index)
            panes.append(
                BackgroundRefreshSummary.Pane(
                    id: String(pane.paneID),
                    sessionID: pane.sessionID,
                    title: String(pane.title),
                    status: String(pane.statusText),
                    screen: String(String(pane.cachedScreenText).prefix(4000))
                )
            )
        }
        summaries[authorization.hostID] = BackgroundRefreshSummary(
            refreshedAt: store.modifiedAt(for: authorization),
            panes: panes,
            hadRetentionGap: state.hadRetentionGap()
        )
    }
}

/// Installs background launches and routes notification taps to cached host context.
@MainActor
final class BackgroundRefreshApplicationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundRefreshCoordinator.shared.register()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Carries the foreground presentation selector this class cannot (see
    /// `NotificationForegroundResponder`).
    private nonisolated let foregroundResponder = NotificationForegroundResponder()

    nonisolated override func responds(to selector: Selector!) -> Bool {
        selector == NotificationForegroundResponder.selector || super.responds(to: selector)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        selector == NotificationForegroundResponder.selector ? foregroundResponder : super.forwardingTarget(for: selector)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // The request stays on the caller's side; only what Core decided
        // from it crosses to the main actor.
        let origin = NotificationPresentationOrigin(request: response.notification.request)
        Task { @MainActor in
            guard let origin, let identifier = BackgroundRefreshCoordinator.shared.hostToOpen(for: origin) else { return }
            BackgroundRefreshCoordinator.shared.requestedHostID = identifier
        }
        completionHandler()
    }
}
