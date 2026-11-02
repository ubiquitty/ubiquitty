// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Security

/// Exercises production AEAD with owned test keys, never the user's keychain.
private final class TestKeys: ResumeSealingKeys {
    var values: [Data: SymmetricKey] = [:]
    var isAvailable = true
    var creates = 0

    func key(scope: Data, create: Bool) -> SymmetricKey? {
        guard isAvailable else { return nil }
        if let key = values[scope] { return key }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        values[scope] = key
        creates += 1
        return key
    }

    func forget(scope: Data) -> Bool {
        guard isAvailable else { return false }
        values.removeValue(forKey: scope)
        return true
    }
}

/// Owns synthetic protected items; no operation reaches the user's keychain.
private final class TestAuthorizationSecurity: RestoreAuthorizationSecurity {
    var item: [String: Any]?
    var readStatus: OSStatus = errSecSuccess
    var writeStatus: OSStatus = errSecSuccess
    var writes = 0

    private func checkQuery(_ query: [String: Any]) {
        precondition(query[kSecAttrService as String] as? String == "org.ubiquitty.restore-authorization.v1")
        precondition(query[kSecAttrSynchronizable as String] as? Bool == false)
        #if os(macOS)
        precondition(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #endif
    }
    func read(_ query: [String: Any]) -> (OSStatus, Any?) {
        checkQuery(query)
        if readStatus != errSecSuccess { return (readStatus, nil) }
        return item.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        checkQuery(attributes)
        if writeStatus != errSecSuccess { return writeStatus }
        guard item == nil else { return errSecDuplicateItem }
        precondition(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        item = attributes
        writes += 1
        return errSecSuccess
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        checkQuery(query)
        if writeStatus != errSecSuccess { return writeStatus }
        guard item != nil else { return errSecItemNotFound }
        for (key, value) in attributes { item?[key] = value }
        writes += 1
        return errSecSuccess
    }
}

@main
struct ResumeSealerTests {
    static func main() {
        precondition(
            KeychainResumeSealingKeys.account(for: Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        precondition(
            KeychainResumeSealingKeys.account(for: Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let keyBytes = Data(repeating: 0x71, count: 32)
        let protectedItem: [String: Any] = [
            kSecValueData as String: keyBytes,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        precondition(KeychainResumeSealingKeys.protectedKeyData(from: protectedItem) == keyBytes)
        precondition(KeychainResumeSealingKeys.protectedKeyData(from: keyBytes) == nil)
        precondition(KeychainResumeSealingKeys.protectedKeyData(from: nil) == nil)
        for attribute in [kSecValueData, kSecAttrAccessible, kSecAttrSynchronizable] {
            var missing = protectedItem
            missing.removeValue(forKey: attribute as String)
            precondition(KeychainResumeSealingKeys.protectedKeyData(from: missing) == nil)
        }
        for weaker in [
            kSecAttrAccessibleWhenUnlocked, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccessibleAfterFirstUnlock,
        ] {
            var attributes = protectedItem
            attributes[kSecAttrAccessible as String] = weaker
            precondition(KeychainResumeSealingKeys.protectedKeyData(from: attributes) == nil)
        }
        var synchronized = protectedItem
        synchronized[kSecAttrSynchronizable as String] = true
        precondition(KeychainResumeSealingKeys.protectedKeyData(from: synchronized) == nil)
        for count in [0, 31, 33] {
            var invalid = protectedItem
            invalid[kSecValueData as String] = Data(repeating: 0x71, count: count)
            precondition(KeychainResumeSealingKeys.protectedKeyData(from: invalid) == nil)
        }
        // The C boundary rejects malformed lengths before dereferencing input
        // or consulting any production keychain item.
        precondition(sealRecord(nil, 65, nil, 1, nil, 30) == -1)
        precondition(openRecord(nil, 65, nil, 28, nil, 0) == -1)
        precondition(!forgetRecordKey(nil, 65))
        let keys = TestKeys()
        let sealer = ResumeSealer(keys: keys)
        var scope = Data(repeating: 7, count: 65)
        scope[64] = 1
        testAuthorization(scope: scope)
        let secret = Data("SYNTHETIC-SECRET-RESUME-ONLY".utf8)
        guard let sealed = sealer.seal(secret, scope: scope) else { fatalError("seal") }
        precondition(sealed.count == secret.count + ResumeSealer.overhead)
        precondition(sealed.range(of: secret) == nil)
        precondition(sealer.open(sealed, scope: scope) == secret)
        var prefixedScope = Data([0, 0, 0])
        prefixedScope.append(scope)
        precondition(sealer.open(sealed, scope: prefixedScope.suffix(65)) == secret)
        precondition(keys.creates == 1)
        let second = sealer.seal(secret, scope: scope)
        precondition(second != sealed, "a fresh random nonce is required")
        precondition(keys.creates == 1, "rewrites retain the existing key")

        for index in sealed.indices {
            var changed = sealed
            changed[index] ^= 1
            precondition(sealer.open(changed, scope: scope) == nil)
        }
        for count in 0..<sealed.count {
            precondition(sealer.open(sealed.prefix(count), scope: scope) == nil)
        }
        var extra = sealed
        extra.append(0)
        precondition(sealer.open(extra, scope: scope) == nil)

        // Even possession of the same key is insufficient in another scope:
        // host, verified principal, window record and purpose are authenticated.
        for index in [0, 16, 48, 64] {
            var other = scope
            other[index] = index == 64 ? 2 : other[index] ^ 1
            keys.values[other] = keys.values[scope]
            precondition(sealer.open(sealed, scope: other) == nil)
        }
        for malformed in [Data(), Data(repeating: 0, count: 65), scope.prefix(64)] {
            precondition(sealer.seal(secret, scope: malformed) == nil)
            precondition(sealer.open(sealed, scope: malformed) == nil)
        }
        precondition(sealer.forget(scope: scope))
        precondition(sealer.open(sealed, scope: scope) == nil)
        precondition(keys.creates == 1, "open must never recreate a deleted key")
        guard let rewritten = sealer.seal(secret, scope: scope) else { fatalError("rewrite") }
        precondition(sealer.open(rewritten, scope: scope) == secret)
        precondition(sealer.open(sealed, scope: scope) == nil)
        keys.isAvailable = false
        precondition(sealer.seal(secret, scope: scope) == nil)
        precondition(sealer.open(rewritten, scope: scope) == nil)
        precondition(!sealer.forget(scope: scope))
        print("resume_sealer: authenticated scope, tampering, key retirement and unavailable-store cases passed")
    }

    private static func testAuthorization(scope: Data) {
        let security = TestAuthorizationSecurity()
        let first = ProtectedRestoreAuthorization(security: security)
        let digest = Data(repeating: 0x63, count: 32)
        let zero = Data(repeating: 0, count: 32)
        precondition(first.read(scope: scope).0 == 1)
        precondition(!first.write(scope: scope, active: true, digest: digest))
        precondition(security.writes == 0, "activation without durable deny intent")
        precondition(first.write(scope: scope, active: false, digest: zero))
        let restarted = ProtectedRestoreAuthorization(security: security)
        precondition(restarted.read(scope: scope).0 == 2)
        precondition(restarted.write(scope: scope, active: true, digest: digest))
        precondition(first.read(scope: scope).0 == 3 && first.read(scope: scope).1 == digest)
        precondition(!first.write(scope: scope, active: true, digest: digest), "replacement omitted blocked transition")
        security.writeStatus = errSecInteractionNotAllowed
        precondition(!first.write(scope: scope, active: false, digest: zero))
        precondition(first.read(scope: scope).0 == 3, "refused intent changed the prior state")
        security.writeStatus = errSecSuccess
        precondition(first.write(scope: scope, active: false, digest: zero))
        security.writeStatus = errSecInteractionNotAllowed
        precondition(!restarted.write(scope: scope, active: true, digest: digest))
        precondition(first.read(scope: scope).0 == 2, "failed activation lost persistent deny")
        security.readStatus = errSecInteractionNotAllowed
        precondition(first.read(scope: scope).0 == 0, "locked must not become missing")
        precondition(!first.write(scope: scope, active: false, digest: zero))
        security.readStatus = errSecSuccess
        security.writeStatus = errSecSuccess
        let protectedItem = security.item
        for attribute in [kSecAttrAccessible, kSecAttrSynchronizable, kSecValueData] {
            security.item = protectedItem
            security.item?.removeValue(forKey: attribute as String)
            precondition(first.read(scope: scope).0 == 0)
            precondition(!first.write(scope: scope, active: false, digest: zero))
        }
        for bytes in [Data(), Data(repeating: 0, count: 33), Data([2, 0]) + zero, Data([1, 2]) + zero, Data([1, 0]) + digest] {
            security.item = protectedItem
            security.item?[kSecValueData as String] = bytes
            precondition(first.read(scope: scope).0 == 0)
        }
        security.item = protectedItem
        security.item?[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        precondition(first.read(scope: scope).0 == 0)
        precondition(!first.write(scope: scope, active: false, digest: zero))
        precondition(readRestoreAuthorization(nil, 65, nil, 32) == 0)
        precondition(!writeRestoreAuthorization(nil, 65, 2, nil, 32))
    }
}
