// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CxxStdlib
import Foundation
import UbiquittyCore

/// The endpoint, trust pin, and explicit permission that own one passive inbox.
struct BackgroundRefreshAuthorization: Codable, Equatable, Sendable {
    let hostID: UUID
    let permissionID: UUID
    let hostName: String
    let port: Int
    let username: String
    let fingerprint: String
    let authentication: String

    /// A stable namespace across refreshes, distinct after permission is renewed.
    var notificationPrefix: String {
        String(Ubiquitty.OSC.retainedBannerPrefix(std.string(hostID.uuidString), std.string(permissionID.uuidString)))
    }

    /// Whether an edited host still denotes the same authenticated endpoint.
    func hasSameEndpoint(as other: Self) -> Bool {
        hostID == other.hostID && hostName == other.hostName && port == other.port && username == other.username
            && fingerprint == other.fingerprint && authentication == other.authentication
    }

    /// Frames Core's opaque record with an exact authorization header.
    ///
    /// - Parameters:
    ///   - record: The uninterpreted Core record.
    ///   - limit: Core's maximum record size in UTF-8 bytes.
    /// - Returns: A bounded protected-file payload, or nil for invalid size.
    func frame(_ record: String, limit: Int) -> Data? {
        guard record.utf8.count <= limit, let header = try? JSONEncoder().encode(self), header.count <= Self.headerLimit else {
            return nil
        }
        var data = header
        data.append(10)
        data.append(contentsOf: record.utf8)
        return data
    }

    /// Reads a record only when its persisted owner exactly matches this permission.
    ///
    /// - Parameters:
    ///   - data: The bounded protected-file payload.
    ///   - limit: Core's maximum record size in UTF-8 bytes.
    /// - Returns: The opaque record, or nil for a foreign owner or malformed file.
    func unframe(_ data: Data, limit: Int) -> String? {
        guard data.count <= limit + Self.headerLimit + 1, let separator = data.firstIndex(of: 10), separator <= Self.headerLimit,
            let stored = try? JSONDecoder().decode(Self.self, from: data.prefix(upTo: separator)), stored == self
        else { return nil }
        let record = data.suffix(from: separator + 1)
        guard record.count <= limit else { return nil }
        return String(data: record, encoding: .utf8)
    }

    static let headerLimit = 16 * 1024
}

/// Pairs an asynchronous platform add with exact late-success cleanup after retirement.
@MainActor
enum BackgroundRefreshDelivery {
    /// Posts only for a current permission and removes any result that finishes after retirement.
    ///
    /// - Parameters:
    ///   - identifier: The permission-scoped stable event identifier.
    ///   - isCurrent: Rechecks endpoint and permission without suspending.
    ///   - add: Submits the platform notification and waits for acceptance.
    ///   - remove: Removes only this exact platform identifier.
    static func post(
        identifier: String,
        isCurrent: () -> Bool,
        add: () async throws -> Void,
        remove: (String) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        do {
            try await add()
        } catch {
            if !isCurrent() { remove(identifier) }
            throw error
        }
        guard isCurrent() else {
            remove(identifier)
            throw CancellationError()
        }
        // An expired run does not withdraw permission. Another run may already
        // have replaced this stable ID, so only permission retirement removes it.
        try Task.checkCancellation()
    }
}
