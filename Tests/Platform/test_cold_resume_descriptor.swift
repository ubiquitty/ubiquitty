// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

private final class SecurityMemory: ColdResumeSecurity {
    var items: [String: [String: Any]] = [:]
    var isUnavailable = false
    var shouldRefuseWrite = false
    var writes = 0
    func read(_ query: [String: Any]) -> (OSStatus, Any?) {
        if isUnavailable { return (errSecInteractionNotAllowed, nil) }
        guard let account = query[kSecAttrAccount as String] as? String, let item = items[account] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, item)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        if shouldRefuseWrite { return errSecInteractionNotAllowed }
        let account = attributes[kSecAttrAccount as String] as! String
        guard items[account] == nil else { return errSecDuplicateItem }
        writes += 1
        items[account] = attributes
        return errSecSuccess
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        if shouldRefuseWrite { return errSecInteractionNotAllowed }
        let account = query[kSecAttrAccount as String] as! String
        guard var item = items[account] else { return errSecItemNotFound }
        writes += 1
        item.merge(attributes) { _, new in new }
        items[account] = item
        return errSecSuccess
    }
}

@main
struct ColdResumeDescriptorTests {
    static func main() {
        let security = SecurityMemory()
        let store = ColdResumeDescriptors(security: security)
        let target = ColdResumeTarget(
            hostID: UUID(),
            endpoint: "example.invalid",
            port: 22,
            username: "alice",
            authentication: "privateKey",
            credentialDigest: Data(repeating: 7, count: 32),
            hostKeyFingerprint: "SHA256:fixture",
            workspace: "work"
        )
        let initial = ColdResumeDescriptor(target: target)
        precondition(target.shouldPersistHistory != true, "history persistence is off by default")
        var optedIn = target
        optedIn.shouldPersistHistory = true
        precondition(optedIn != target, "changing retention must retire the old protected identity")
        precondition(try! JSONDecoder().decode(ColdResumeTarget.self, from: JSONEncoder().encode(optedIn)) == optedIn)
        precondition(store.requireRetirement(target.hostID), "missing is not an old readable identity")
        precondition(store.write(initial))
        guard case .value(let loaded) = store.read(target.hostID) else { preconditionFailure("protected roundtrip") }
        precondition(loaded == initial && loaded.clientHalves != (0, 0))
        var bound = loaded
        bound.peer = .init(
            hostLow: 7,
            hostHigh: 8,
            principal: "token:actual-authenticated-id",
            certificatePin: Data(repeating: 9, count: 32),
            address: "192.0.2.1",
            port: 443
        )
        let legacy = try! JSONDecoder().decode(ColdResumeDescriptor.self, from: JSONEncoder().encode(bound))
        precondition(legacy.isValid && legacy.peer?.daemonSocketName == nil, "legacy metadata never invents a fallback owner")
        bound.peer?.daemonSocketName = "host-ABC_123.sock"
        precondition(bound.isValid)
        let pinned = try! JSONDecoder().decode(ColdResumeDescriptor.self, from: JSONEncoder().encode(bound))
        precondition(pinned == bound, "the authenticated daemon pin survives a cold restart")
        for name in ["", ".hidden/host.sock", "../host.sock", "host;other", "host\u{0}other.sock", String(repeating: "a", count: 65536)] {
            var malformed = bound
            malformed.peer?.daemonSocketName = name
            precondition(!malformed.isValid && !store.write(malformed), "a daemon pin must be a bounded safe basename")
        }
        precondition(store.write(bound))
        security.shouldRefuseWrite = true
        precondition(!store.requireRetirement(target.hostID), "failed initial denial must refuse the edit")
        guard case .value(let stillReady) = store.read(target.hostID) else { preconditionFailure() }
        precondition(stillReady == bound, "do not claim an impossible persisted denial")
        security.shouldRefuseWrite = false
        precondition(store.requireRetirement(target.hostID))
        let restarted = ColdResumeDescriptors(security: security)
        guard case .value(let retired) = restarted.read(target.hostID) else { preconditionFailure() }
        precondition(retired.state == .retirementRequired && retired.peer == bound.peer && retired.clientID == bound.clientID)
        let writes = security.writes
        precondition(restarted.requireRetirement(target.hostID) && security.writes == writes, "retirement retry is stable")
        security.isUnavailable = true
        guard case .refused = restarted.read(target.hostID) else { preconditionFailure("locked is not absent") }
        precondition(!restarted.requireRetirement(target.hostID) && !restarted.write(initial))
        security.isUnavailable = false
        let good = security.items[target.hostID.uuidString]!
        for mutation in [
            [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly],
            [kSecAttrSynchronizable as String: true],
            [kSecValueData as String: Data(repeating: 1, count: ColdResumeDescriptors.maxBytes + 1)],
            [kSecValueData as String: Data("not json".utf8)],
        ] as [[String: Any]] {
            security.items[target.hostID.uuidString] = good.merging(mutation) { _, new in new }
            guard case .refused = restarted.read(target.hostID) else { preconditionFailure("invalid protection or record accepted") }
            precondition(!restarted.write(initial), "never replace a weaker or malformed protected item")
        }
        security.items[target.hostID.uuidString] = good
        var invalid = bound
        invalid.peer = .init(
            hostLow: 7,
            hostHigh: 8,
            principal: "alice",
            certificatePin: Data(repeating: 0, count: 32),
            address: "192.0.2.1",
            port: 443
        )
        precondition(!store.write(invalid), "zero pin is not a pinned target")
        print(
            "PASS protected descriptor, stable identity, authenticated binding and daemon pin, legacy metadata, restart denial, refused retirement, locked storage, malformed/weak protection"
        )
    }
}
