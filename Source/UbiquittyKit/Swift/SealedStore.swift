// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Key ownership is injectable for deterministic crypto tests. Production uses
/// only the protected keychain; unavailable or locked storage refuses the work.
protocol ResumeSealingKeys {
    func key(scope: Data, create: Bool) -> SymmetricKey?
    func forget(scope: Data) -> Bool
}

struct KeychainResumeSealingKeys: ResumeSealingKeys {
    private let service = "org.ubiquitty.resume-sealing.v1"

    /// The stable lowercase SHA-256 account name for one sealing scope.
    ///
    /// - Parameter scope: The exact host, principal, window and purpose bytes.
    /// - Returns: The 64-character lowercase hexadecimal digest.
    static func account(for scope: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        let bytes = SHA256.hash(data: scope)
            .flatMap { byte in
                [digits[Int(byte >> 4)], digits[Int(byte & 15)]]
            }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func query(_ scope: Data) -> [String: Any] {
        let account = Self.account(for: scope)
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: authentication,
        ]
        #if os(macOS)
        // The file-based Mac keychain does not enforce this accessibility
        // class. Never retry against it if the protected keychain refuses.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    func key(scope: Data, create: Bool) -> SymmetricKey? {
        var read = query(scope)
        read[kSecReturnData as String] = true
        read[kSecReturnAttributes as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = Self.protectedKeyData(from: item) else { return nil }
            return SymmetricKey(data: data)
        }
        guard create, status == errSecItemNotFound else { return nil }
        let fresh = SymmetricKey(size: .bits256)
        var add = query(scope)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecValueData as String] = fresh.withUnsafeBytes { Data($0) }
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecSuccess { return fresh }
        // A simultaneous creator wins atomically; never delete an existing key
        // to replace it, which would destroy all ciphertext sealed with it.
        return added == errSecDuplicateItem ? key(scope: scope, create: false) : nil
    }

    /// Accepts key bytes only with the required device-local unlocked policy.
    ///
    /// - Parameter item: The keychain's combined attributes and data result.
    /// - Returns: Exactly 32 key bytes, or nil for missing or weaker protection.
    static func protectedKeyData(from item: Any?) -> Data? {
        protectedItemData(from: item, byteCount: 32)
    }

    /// Validates the exact protected-keychain attributes before returning data.
    ///
    /// - Parameters:
    ///   - item: Combined attributes and data returned by Security.
    ///   - byteCount: The exact size required by this item's schema.
    /// - Returns: Device-local unlocked data, or nil without weaker fallback.
    static func protectedItemData(from item: Any?, byteCount: Int) -> Data? {
        guard let attributes = item as? [String: Any],
            let accessibility = attributes[kSecAttrAccessible as String] as? String,
            accessibility == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
            let synchronizable = attributes[kSecAttrSynchronizable as String] as? Bool,
            !synchronizable,
            let data = attributes[kSecValueData as String] as? Data,
            data.count == byteCount
        else { return nil }
        return data
    }

    func forget(scope: Data) -> Bool {
        let status = SecItemDelete(query(scope) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Injectable Security operations; production never consults a fallback store.
protocol RestoreAuthorizationSecurity {
    func read(_ query: [String: Any]) -> (OSStatus, Any?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
}

private struct SystemRestoreAuthorizationSecurity: RestoreAuthorizationSecurity {
    func read(_ query: [String: Any]) -> (OSStatus, Any?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
}

/// A protected write-ahead deny record independent of the encryption key.
/// Active binds one exact plaintext digest; a missing item never authorizes a
/// read. An unavailable intent write refuses before any key/file mutation.
struct ProtectedRestoreAuthorization {
    let security: any RestoreAuthorizationSecurity

    private func query(_ scope: Data) -> [String: Any] {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.ubiquitty.restore-authorization.v1",
            kSecAttrAccount as String: KeychainResumeSealingKeys.account(for: scope),
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: authentication,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    /// Returns the PAL state number and exact digest, without creating an item.
    func read(scope: Data) -> (UInt8, Data) {
        guard ResumeSealer.accepts(scope: scope), scope.last == 1 else { return (0, Data()) }
        var read = query(scope)
        read[kSecReturnData as String] = true
        read[kSecReturnAttributes as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = security.read(read)
        if status == errSecItemNotFound { return (1, Data()) }
        guard status == errSecSuccess,
            let data = KeychainResumeSealingKeys.protectedItemData(from: item, byteCount: 34),
            data.first == 1, let state = data.dropFirst().first, state <= 1
        else { return (0, Data()) }
        let digest = Data(data.suffix(32))
        guard state == 1 || digest.allSatisfy({ $0 == 0 }) else { return (0, Data()) }
        return (state == 1 ? 3 : 2, digest)
    }

    /// Atomically writes only an admitted protected item. Activation requires a
    /// preceding Blocked state; callers serialize the complete file transaction.
    func write(scope: Data, active: Bool, digest: Data) -> Bool {
        guard digest.count == 32, active || digest.allSatisfy({ $0 == 0 }) else { return false }
        let (state, _) = read(scope: scope)
        guard state != 0, !active || state == 2 else { return false }
        var data = Data([1, active ? 1 : 0])
        data.append(digest)
        let query = query(scope)
        if state == 1 {
            var add = query
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecValueData as String] = data
            let result = security.add(add)
            if result == errSecSuccess { return true }
            // Validate a competing creator's policy before updating its item.
            guard result == errSecDuplicateItem, read(scope: scope).0 >= 2 else { return false }
        }
        return security.update(query, attributes: [kSecValueData as String: data]) == errSecSuccess
    }
}

#if UBIQUITTY_UI_TESTS
/// The protected keychain's stand-in for a UI-test run that names a scratch
/// directory in `UBIQUITTY_RESUME_TEST_KEYCHAIN`: an unsigned test build has
/// no keychain access group, and a restart scenario still needs the sealed
/// record to survive the process. Compiled into UI-test builds alone, and
/// unused unless the variable is set, so a signed test run reaches the real
/// keychain.
enum ResumeTestKeychain {
    /// The scratch directory, when the run names one.
    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["UBIQUITTY_RESUME_TEST_KEYCHAIN"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The file one item of `service` and `account` is kept in.
    static func file(in directory: URL, service: String, account: String) -> URL {
        directory.appendingPathComponent("\(service)-\(account)")
    }

    /// Writes an item privately and whole.
    static func write(_ data: Data, to file: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            return false
        }
    }
}

/// Sealing keys as files in the test keychain directory.
struct TestResumeSealingKeys: ResumeSealingKeys {
    let directory: URL

    func key(scope: Data, create: Bool) -> SymmetricKey? {
        let file = ResumeTestKeychain.file(in: directory, service: "resume-sealing", account: KeychainResumeSealingKeys.account(for: scope))
        if let data = try? Data(contentsOf: file), data.count == 32 { return SymmetricKey(data: data) }
        guard create else { return nil }
        let fresh = SymmetricKey(size: .bits256)
        return ResumeTestKeychain.write(fresh.withUnsafeBytes { Data($0) }, to: file) ? fresh : nil
    }

    func forget(scope: Data) -> Bool {
        let file = ResumeTestKeychain.file(in: directory, service: "resume-sealing", account: KeychainResumeSealingKeys.account(for: scope))
        do {
            try FileManager.default.removeItem(at: file)
            return true
        } catch CocoaError.fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }
}

/// Restore authorization items as files in the test keychain directory,
/// answering with the attributes the protected keychain would.
struct TestRestoreAuthorizationSecurity: RestoreAuthorizationSecurity {
    let directory: URL

    private func file(_ query: [String: Any]) -> URL? {
        guard let service = query[kSecAttrService as String] as? String, let account = query[kSecAttrAccount as String] as? String else {
            return nil
        }
        return ResumeTestKeychain.file(in: directory, service: service, account: account)
    }

    func read(_ query: [String: Any]) -> (OSStatus, Any?) {
        guard let file = file(query) else { return (errSecParam, nil) }
        guard let data = try? Data(contentsOf: file) else { return (errSecItemNotFound, nil) }
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data,
        ]
        return (errSecSuccess, attributes)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        guard let file = file(attributes), let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        if FileManager.default.fileExists(atPath: file.path) { return errSecDuplicateItem }
        return ResumeTestKeychain.write(data, to: file) ? errSecSuccess : errSecIO
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        guard let file = file(query), let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        guard FileManager.default.fileExists(atPath: file.path) else { return errSecItemNotFound }
        return ResumeTestKeychain.write(data, to: file) ? errSecSuccess : errSecIO
    }
}
#endif

/// The sealing keys the record entry points use: the protected keychain, or
/// in a UI-test run that names one, its scratch stand-in.
private func resumeSealingKeys() -> any ResumeSealingKeys {
    #if UBIQUITTY_UI_TESTS
    if let directory = ResumeTestKeychain.directory { return TestResumeSealingKeys(directory: directory) }
    #endif
    return KeychainResumeSealingKeys()
}

/// The restore authorization storage the record entry points use, chosen as
/// ``resumeSealingKeys()`` chooses.
private func restoreAuthorizationSecurity() -> any RestoreAuthorizationSecurity {
    #if UBIQUITTY_UI_TESTS
    if let directory = ResumeTestKeychain.directory { return TestRestoreAuthorizationSecurity(directory: directory) }
    #endif
    return SystemRestoreAuthorizationSecurity()
}

@_cdecl("ubiquittyReadRestoreAuthorization")
func readRestoreAuthorization(
    _ scope: UnsafePointer<UInt8>?,
    _ scopeSize: UInt,
    _ output: UnsafeMutablePointer<UInt8>?,
    _ capacity: UInt
) -> UInt8 {
    guard scopeSize == 65, capacity == 32, let output, let scope = recordBytes(scope, scopeSize) else { return 0 }
    let (state, digest) = ProtectedRestoreAuthorization(security: restoreAuthorizationSecurity()).read(scope: scope)
    if digest.count == 32 { digest.copyBytes(to: output, count: 32) }
    return state
}

@_cdecl("ubiquittyWriteRestoreAuthorization")
func writeRestoreAuthorization(
    _ scope: UnsafePointer<UInt8>?,
    _ scopeSize: UInt,
    _ active: UInt8,
    _ digest: UnsafePointer<UInt8>?,
    _ size: UInt
) -> Bool {
    guard scopeSize == 65, size == 32, active == 2 || active == 3, let scope = recordBytes(scope, scopeSize),
        let digest = recordBytes(digest, size)
    else { return false }
    return ProtectedRestoreAuthorization(security: restoreAuthorizationSecurity())
        .write(scope: scope, active: active == 3, digest: digest)
}

/// AEAD for one exact host/principal/window/purpose scope. No plaintext is
/// returned on authentication failure and opening never creates a missing key.
/// This component does not write files or choose a window's persistent identity.
struct ResumeSealer {
    let keys: any ResumeSealingKeys
    private static let version: UInt8 = 1
    static let overhead = 29

    static func accepts(scope: Data) -> Bool {
        guard scope.count == 65, scope.last == 1 || scope.last == 2 else { return false }
        return scope.prefix(16).contains(where: { $0 != 0 })
            && scope.dropFirst(16).prefix(32).contains(where: { $0 != 0 })
            && scope.dropFirst(48).prefix(16).contains(where: { $0 != 0 })
    }

    private func authenticatedData(_ scope: Data) -> Data {
        var data = Data("Ubiquitty sealed record".utf8)
        data.append(Self.version)
        data.append(scope)
        return data
    }

    func seal(_ plaintext: Data, scope: Data) -> Data? {
        guard Self.accepts(scope: scope), let key = keys.key(scope: scope, create: true),
            let box = try? ChaChaPoly.seal(plaintext, using: key, authenticating: authenticatedData(scope))
        else { return nil }
        var output = Data([Self.version])
        output.append(box.combined)
        return output
    }

    func open(_ ciphertext: Data, scope: Data) -> Data? {
        guard Self.accepts(scope: scope), ciphertext.count >= Self.overhead,
            ciphertext.first == Self.version,
            let key = keys.key(scope: scope, create: false),
            let box = try? ChaChaPoly.SealedBox(combined: ciphertext.dropFirst())
        else { return nil }
        return try? ChaChaPoly.open(box, using: key, authenticating: authenticatedData(scope))
    }

    func forget(scope: Data) -> Bool {
        Self.accepts(scope: scope) && keys.forget(scope: scope)
    }
}

private func recordBytes(_ pointer: UnsafePointer<UInt8>?, _ count: UInt) -> Data? {
    guard count <= UInt(Int.max), count == 0 || pointer != nil else { return nil }
    if count == 0 { return Data() }
    return Data(bytes: pointer!, count: Int(count))
}

@_cdecl("ubiquittySealRecord")
func sealRecord(
    _ scope: UnsafePointer<UInt8>?,
    _ scopeSize: UInt,
    _ input: UnsafePointer<UInt8>?,
    _ inputSize: UInt,
    _ output: UnsafeMutablePointer<UInt8>?,
    _ outputCapacity: UInt
) -> Int {
    guard scopeSize == 65, inputSize <= UInt(Int.max - ResumeSealer.overhead),
        outputCapacity == inputSize + UInt(ResumeSealer.overhead), let output,
        let scope = recordBytes(scope, scopeSize), ResumeSealer.accepts(scope: scope),
        let plaintext = recordBytes(input, inputSize),
        let sealed = ResumeSealer(keys: resumeSealingKeys()).seal(plaintext, scope: scope),
        sealed.count == Int(outputCapacity)
    else { return -1 }
    sealed.copyBytes(to: output, count: sealed.count)
    return sealed.count
}

@_cdecl("ubiquittyOpenRecord")
func openRecord(
    _ scope: UnsafePointer<UInt8>?,
    _ scopeSize: UInt,
    _ input: UnsafePointer<UInt8>?,
    _ inputSize: UInt,
    _ output: UnsafeMutablePointer<UInt8>?,
    _ outputCapacity: UInt
) -> Int {
    guard scopeSize == 65, inputSize >= UInt(ResumeSealer.overhead), inputSize <= UInt(Int.max),
        outputCapacity == inputSize - UInt(ResumeSealer.overhead), let output,
        let scope = recordBytes(scope, scopeSize), ResumeSealer.accepts(scope: scope),
        let ciphertext = recordBytes(input, inputSize),
        let plaintext = ResumeSealer(keys: resumeSealingKeys()).open(ciphertext, scope: scope),
        plaintext.count == Int(outputCapacity)
    else { return -1 }
    plaintext.copyBytes(to: output, count: plaintext.count)
    return plaintext.count
}

@_cdecl("ubiquittyForgetRecordKey")
func forgetRecordKey(_ scope: UnsafePointer<UInt8>?, _ scopeSize: UInt) -> Bool {
    guard scopeSize == 65, let scope = recordBytes(scope, scopeSize) else { return false }
    return ResumeSealer(keys: resumeSealingKeys()).forget(scope: scope)
}
