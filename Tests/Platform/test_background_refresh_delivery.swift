// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Exercises the production permission and asynchronous-delivery boundary without posting notifications.
@main
struct BackgroundRefreshDeliveryTests {
    @MainActor
    static func main() async throws {
        let original = identity()
        let record = "opaque\n日本語\u{0}"
        let framed = original.frame(record, limit: 64)!
        precondition(original.unframe(framed, limit: 64) == record)
        precondition(original.frame(String(repeating: "a", count: 65), limit: 64) == nil)
        precondition(original.unframe(framed, limit: 2) == nil)
        precondition(original.unframe(Data([0xff, 10]), limit: 64) == nil)
        precondition(original.unframe(Data(repeating: 65, count: 100), limit: 64) == nil)
        for changed in [
            identity(hostID: UUID()), identity(permissionID: UUID()), identity(hostName: "other.invalid"),
            identity(port: 2222), identity(username: "other"), identity(fingerprint: "changed"), identity(authentication: "key"),
        ] {
            precondition(changed.unframe(framed, limit: 64) == nil, "cached state must match every authority field")
        }
        let roundTrip = try JSONDecoder().decode(BackgroundRefreshAuthorization.self, from: JSONEncoder().encode(original))
        precondition(roundTrip == original)
        precondition(roundTrip.notificationPrefix == original.notificationPrefix, "ordinary refreshes retain the dedup namespace")
        let renewed = identity(permissionID: UUID())
        precondition(renewed.hasSameEndpoint(as: original))
        precondition(renewed.notificationPrefix != original.notificationPrefix)
        precondition(!identity(fingerprint: "changed").hasSameEndpoint(as: original))

        var current: BackgroundRefreshAuthorization? = original
        var posted: Set<String> = []
        let oldName = original.notificationPrefix + "42:1"
        let newName = renewed.notificationPrefix + "42:1"
        var releaseAdd: CheckedContinuation<Void, Never>?
        let delayed = Task { @MainActor in
            try await BackgroundRefreshDelivery.post(
                identifier: oldName,
                isCurrent: { current == original },
                add: {
                    await withCheckedContinuation { releaseAdd = $0 }
                    posted.insert(oldName)
                },
                remove: { posted.remove($0) }
            )
        }
        while releaseAdd == nil { await Task.yield() }
        current = nil
        posted = posted.filter { !$0.hasPrefix(original.notificationPrefix) }
        current = renewed
        posted.insert(newName)
        releaseAdd?.resume()
        do {
            try await delayed.value
            preconditionFailure("retired permission must not accept a late platform add")
        } catch is CancellationError {} catch { throw error }
        precondition(posted == [newName], "late cleanup must remove old delivery without touching renewed permission")

        var adds = 0
        do {
            try await BackgroundRefreshDelivery.post(
                identifier: oldName,
                isCurrent: { false },
                add: { adds += 1 },
                remove: { _ in }
            )
            preconditionFailure("retired permission must not start a platform add")
        } catch is CancellationError {} catch { throw error }
        precondition(adds == 0)

        releaseAdd = nil
        let cancelled = Task { @MainActor in
            try await BackgroundRefreshDelivery.post(
                identifier: newName,
                isCurrent: { current == renewed },
                add: {
                    await withCheckedContinuation { releaseAdd = $0 }
                    posted.insert(newName)
                },
                remove: { posted.remove($0) }
            )
        }
        while releaseAdd == nil { await Task.yield() }
        cancelled.cancel()
        releaseAdd?.resume()
        do {
            try await cancelled.value
            preconditionFailure("cancelled refresh must not commit its receipt")
        } catch is CancellationError {} catch { throw error }
        precondition(posted == [newName], "expiration must not erase an authorized stable-ID replacement")

        try await BackgroundRefreshDelivery.post(
            identifier: newName,
            isCurrent: { current == renewed },
            add: { posted.insert(newName) },
            remove: { posted.remove($0) }
        )
        precondition(posted == [newName])
        print("PASS background authorization, persisted owner, delayed revoke/re-enable, cancellation, and stable delivery")
    }

    private static func identity(
        hostID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        permissionID: UUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        hostName: String = "host.invalid",
        port: Int = 22,
        username: String = "test",
        fingerprint: String = "SHA256:fixture",
        authentication: String = "password"
    ) -> BackgroundRefreshAuthorization {
        BackgroundRefreshAuthorization(
            hostID: hostID,
            permissionID: permissionID,
            hostName: hostName,
            port: port,
            username: username,
            fingerprint: fingerprint,
            authentication: authentication
        )
    }
}
