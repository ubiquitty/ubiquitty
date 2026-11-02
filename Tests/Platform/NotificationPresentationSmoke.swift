// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyCore
import UserNotifications

/// Checks the app's reading of a banner request the system hands back: what
/// the payload says reaches Core intact, a lossy or mixed payload is refused,
/// and the foreground presentation follows the producer's currency.
enum NotificationPresentationSmoke {
    /// Runs the checks.
    ///
    /// - Returns: Whether every check passed.
    @MainActor
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ detail: String) {
            if !condition { failures.append(detail) }
        }
        let delegate = BackgroundRefreshApplicationDelegate()
        let selector = NSSelectorFromString("userNotificationCenter:willPresentNotification:withCompletionHandler:")
        check(delegate.responds(to: selector), "the delegate does not answer the foreground presentation selector")
        check(
            delegate.forwardingTarget(for: selector).map { ($0 as AnyObject).responds(to: selector) } == true,
            "the delegate's foreground presentation selector reaches nothing that implements it"
        )
        let tap = NSSelectorFromString("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:")
        check(delegate.responds(to: tap), "the delegate does not answer the tap selector")
        let hostID = UUID()
        let permissionID = UUID()
        let incarnationID = UUID()
        let retainedPrefix = String(Ubiquitty.OSC.retainedBannerPrefix(std.string(hostID.uuidString), std.string(permissionID.uuidString)))
        let information: [AnyHashable: Any] = [
            "hostID": hostID.uuidString, "permissionID": permissionID.uuidString,
            "sessionID": UInt32(42), "occasion": UInt8(0), "paneID": "1234",
        ]
        func request(_ identifier: String, _ information: [AnyHashable: Any]) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.userInfo = information
            return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        }
        func noAudience(_: UUID, _: UInt32) -> Ubiquitty.OSC.BannerAudience? { nil }
        func noLive(_: NotificationPresentationOrigin.Live) -> Ubiquitty.OSC.BannerAudience? { nil }

        let retained = request(retainedPrefix + "event", information)
        guard let retainedOrigin = NotificationPresentationOrigin(request: retained) else {
            print("notification-presentation: a retained request was refused")
            return false
        }
        check(retainedOrigin.origin == .Retained && retainedOrigin.permissionID == permissionID, "a retained request lost its permission")
        var lookups = 0
        let shown = retainedOrigin.options(
            isRetainedCurrent: {
                lookups += 1
                return $0 == hostID && $1 == permissionID
            },
            retainedAudience: noAudience,
            liveAudience: noLive
        )
        check(shown == [.banner, .list] && lookups == 1, "a current permission's event was not shown")
        check(
            retainedOrigin.options(isRetainedCurrent: { _, _ in false }, retainedAudience: noAudience, liveAudience: noLive).isEmpty,
            "a renewed permission's event was shown"
        )
        check(NotificationPresentationOrigin(request: request("foreign", information)) == nil, "a foreign identifier was accepted")
        check(NotificationPresentationOrigin(request: request(retainedPrefix, information)) == nil, "an empty event name was accepted")
        check(NotificationPresentationOrigin(request: request("unknown", [:])) == nil, "an untyped request was accepted")
        for malformed in [NSNumber(value: -1), NSNumber(value: 1.5), NSNumber(value: true), NSNumber(value: UInt64.max)] {
            var modified = information
            modified["sessionID"] = malformed
            check(
                NotificationPresentationOrigin(request: request(retained.identifier, modified)) == nil,
                "a lossy session \(malformed) was accepted"
            )
        }
        for malformed: Any in [UInt32(256), UInt8(3), "0", NSNumber(value: true)] {
            var modified = information
            modified["occasion"] = malformed
            check(
                NotificationPresentationOrigin(request: request(retained.identifier, modified)) == nil,
                "an invalid occasion \(malformed) became Always"
            )
        }
        var malformedPermission = information
        malformedPermission["permissionID"] = "not-a-uuid"
        check(
            NotificationPresentationOrigin(request: request(retained.identifier, malformedPermission)) == nil,
            "a malformed permission was accepted"
        )

        let live = NotificationPresentationOrigin.Live(
            hostID: hostID,
            incarnationID: incarnationID,
            daemonID: UInt64.max,
            sessionID: 42,
            occasion: .Unfocused
        )
        let liveRequest = request(live.prefix + "program", live.userInfo)
        guard let liveOrigin = NotificationPresentationOrigin(request: liveRequest), let read = liveOrigin.live else {
            print("notification-presentation: a live request was refused")
            return false
        }
        check(
            read.daemonID == UInt64.max && read.incarnationID == incarnationID && read.occasion == .Unfocused,
            "a live request lost its identity"
        )
        var audience = Ubiquitty.OSC.BannerAudience()
        audience.isAppActive = true
        audience.isWindowKey = true
        audience.isPaneFocused = true
        audience.isPaneVisible = true
        var isCurrent = true
        func liveAudience(_ candidate: NotificationPresentationOrigin.Live) -> Ubiquitty.OSC.BannerAudience? {
            guard isCurrent, candidate.hostID == hostID, candidate.incarnationID == incarnationID, candidate.daemonID == UInt64.max,
                candidate.sessionID == 42
            else { return nil }
            return audience
        }
        func liveOptions() -> UNNotificationPresentationOptions {
            liveOrigin.options(isRetainedCurrent: { _, _ in true }, retainedAudience: noAudience, liveAudience: liveAudience)
        }
        check(liveOptions().isEmpty, "a focused pane was shown its own Unfocused banner")
        audience.isPaneFocused = false
        check(liveOptions() == [.banner, .list], "a current live event lost its banner")
        isCurrent = false
        check(liveOptions().isEmpty, "a retired attachment's banner was shown")
        var mixed = live.userInfo
        mixed["permissionID"] = permissionID.uuidString
        check(NotificationPresentationOrigin(request: request(liveRequest.identifier, mixed)) == nil, "two producers were accepted")
        var foreign = live.userInfo
        foreign["liveModelID"] = UUID().uuidString
        check(
            NotificationPresentationOrigin(request: request(liveRequest.identifier, foreign)) == nil,
            "another incarnation matched this namespace"
        )
        if let data = try? PropertyListSerialization.data(fromPropertyList: live.userInfo, format: .binary, options: 0),
            let decoded = try? PropertyListSerialization.propertyList(from: data, options: 0, format: nil) as? [AnyHashable: Any]
        {
            check(
                NotificationPresentationOrigin(request: request(liveRequest.identifier, decoded)) != nil,
                "a property-list round trip lost the identity"
            )
        } else {
            failures.append("the live payload did not round-trip through a property list")
        }
        for failure in failures { print("notification-presentation: \(failure)") }
        return failures.isEmpty
    }
}
