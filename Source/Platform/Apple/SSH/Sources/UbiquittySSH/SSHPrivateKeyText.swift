// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Reads a private key a person pasted or imported, and says which container it
// could not read.
//
// "PEM" names an armour, not a format. The same key ships in several containers
// that all begin with five dashes: OpenSSH's own (what `ssh-keygen` writes by
// default), PKCS#8, SEC1 and PKCS#1. swift-crypto reads exactly one of them,
// PKCS#8, and a refusal that names no cause reads to a person like a server
// rejecting a credential: they go reading sshd logs rather than looking at the
// file. The container is knowable from the armour line, so a refusal names it
// and says what to do.
//
// Every length here comes from the input, so every read is bounded by what is
// left of it, and the whole text by `maxTextLength`.

import Crypto
import Foundation
import NIOSSH

/// A private key read from text, or the sentence that says why it could not be.
public enum SSHPrivateKeyText {
    /// What reading a key produced.
    public enum Outcome: Sendable {
        case key(NIOSSHPrivateKey)
        /// A sentence naming the container and what to do about it.
        case refused(String)
    }

    /// The longest text read as a key. An OpenSSH RSA-4096 key, the largest a
    /// person is likely to hold, is under 4 KB.
    public static let maxTextLength = 64 * 1024

    /// Reads a key from text.
    ///
    /// - Parameter text: The pasted or imported text, with or without
    ///   surrounding whitespace.
    /// - Returns: The key, or a refusal naming the container that was found.
    public static func read(_ text: String) -> Outcome {
        guard text.utf8.count <= maxTextLength else {
            return .refused("This file is too large to be a private key.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch Container.of(trimmed) {
        case .openSSH:
            guard let body = base64Body(of: trimmed, label: "OPENSSH PRIVATE KEY") else {
                return .refused(incomplete("an OpenSSH key"))
            }
            return OpenSSHKey.read(body)
        case .pkcs8:
            if let key = readPKCS8(trimmed) { return .key(key) }
            return .refused(
                "This is a PKCS#8 key (BEGIN PRIVATE KEY), but Ubiquitty couldn’t read it. It may be incomplete, "
                    + "or it may not be an ECDSA key on the P-256, P-384, or P-521 curve."
            )
        case .sec1:
            if trimmed.contains("ENCRYPTED") { return .refused(passphraseRefusal) }
            if let key = readSEC1(trimmed) { return .key(key) }
            return .refused(
                "This is a SEC1 key (BEGIN EC PRIVATE KEY), but Ubiquitty couldn’t read it. It may be incomplete, "
                    + "or it may use a curve other than P-256, P-384, or P-521."
            )
        case .encryptedPKCS8:
            return .refused(passphraseRefusal)
        case .rsa:
            return .refused(rsaRefusal)
        case .unrecognized:
            return .refused(
                "This isn’t a private key Ubiquitty recognizes. Generate a new key, or create one on a computer with ssh-keygen -t ed25519."
            )
        }
    }

    /// Makes a new P-256 key, as the PKCS#8 text this reader reads back.
    ///
    /// P-256 because every SSH server in use accepts `ecdsa-sha2-nistp256`, and
    /// the text is what the keychain holds for a pasted key too, so a made key
    /// and an imported one take one path from there on.
    ///
    /// - Returns: The key's text.
    public static func makeP256Key() -> String {
        P256.Signing.PrivateKey().pemRepresentation
    }

    /// Which armour a key arrived in.
    enum Container {
        /// `BEGIN OPENSSH PRIVATE KEY`: OpenSSH's own container.
        case openSSH
        /// `BEGIN PRIVATE KEY`: what swift-crypto reads directly.
        case pkcs8
        /// `BEGIN ENCRYPTED PRIVATE KEY`: PKCS#8 under a passphrase.
        case encryptedPKCS8
        /// `BEGIN EC PRIVATE KEY`: RFC 5915, what `ssh-keygen -m PEM` writes.
        case sec1
        /// `BEGIN RSA PRIVATE KEY`: PKCS#1.
        case rsa
        /// No armour line this reader knows.
        case unrecognized

        /// The container a key's armour declares.
        ///
        /// - Parameter text: The key's text.
        /// - Returns: The container its BEGIN line names.
        static func of(_ text: String) -> Container {
            if text.contains("BEGIN OPENSSH PRIVATE KEY") { return .openSSH }
            if text.contains("BEGIN ENCRYPTED PRIVATE KEY") { return .encryptedPKCS8 }
            if text.contains("BEGIN EC PRIVATE KEY") { return .sec1 }
            if text.contains("BEGIN RSA PRIVATE KEY") { return .rsa }
            if text.contains("BEGIN PRIVATE KEY") { return .pkcs8 }
            return .unrecognized
        }
    }

    static let passphraseRefusal =
        "This key is protected by a passphrase, which Ubiquitty can’t use. On a computer, remove the passphrase from a copy of the key with ssh-keygen -p, then import the copy."

    static let rsaRefusal =
        "This is an RSA key, which Ubiquitty doesn’t support. Use an Ed25519 or ECDSA key: generate a new key, or create one on a computer with ssh-keygen -t ed25519."

    /// The sentence for a key whose container was recognized but whose body
    /// was not whole.
    static func incomplete(_ container: String) -> String {
        "This looks like \(container), but part of it is missing. Copy the whole key, including its BEGIN and END lines, and try again."
    }

    /// Reads the container swift-crypto parses itself.
    private static func readPKCS8(_ text: String) -> NIOSSHPrivateKey? {
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: text) {
            return NIOSSHPrivateKey(p256Key: key)
        }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: text) {
            return NIOSSHPrivateKey(p384Key: key)
        }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: text) {
            return NIOSSHPrivateKey(p521Key: key)
        }
        return nil
    }

    /// Reads RFC 5915, which swift-crypto does not.
    ///
    /// The scalar is taken from the structure rather than the file's length,
    /// and the curve from the OID rather than the scalar's size: a 32-byte
    /// scalar is a valid P-384 key with leading zeros, and guessing the curve
    /// from the length would silently read it as the wrong one.
    private static func readSEC1(_ text: String) -> NIOSSHPrivateKey? {
        guard let der = base64Body(of: text, label: "EC PRIVATE KEY"), let fields = DER.ecPrivateKey(der) else {
            return nil
        }
        // The point the file carries, when it carries one, must be the one the
        // scalar makes: a file whose halves disagree is damaged.
        func matches(_ point: Data) -> Bool { fields.publicKey.map { Data($0) == point } ?? true }
        switch fields.curveOID {
        case DER.p256OID:
            guard let scalar = fields.scalar(paddedTo: 32), let key = try? P256.Signing.PrivateKey(rawRepresentation: scalar),
                matches(key.publicKey.x963Representation)
            else { return nil }
            return NIOSSHPrivateKey(p256Key: key)
        case DER.p384OID:
            guard let scalar = fields.scalar(paddedTo: 48), let key = try? P384.Signing.PrivateKey(rawRepresentation: scalar),
                matches(key.publicKey.x963Representation)
            else { return nil }
            return NIOSSHPrivateKey(p384Key: key)
        case DER.p521OID:
            guard let scalar = fields.scalar(paddedTo: 66), let key = try? P521.Signing.PrivateKey(rawRepresentation: scalar),
                matches(key.publicKey.x963Representation)
            else { return nil }
            return NIOSSHPrivateKey(p521Key: key)
        default:
            return nil
        }
    }

    /// The base64 between a label's BEGIN and END lines, decoded.
    ///
    /// - Parameters:
    ///   - text: The armoured text.
    ///   - label: The label to take, without dashes.
    /// - Returns: The bytes, or nil when the armour does not match.
    static func base64Body(of text: String, label: String) -> [UInt8]? {
        guard let begin = text.range(of: "-----BEGIN \(label)-----"), let end = text.range(of: "-----END \(label)-----"),
            begin.upperBound <= end.lowerBound
        else { return nil }
        let body = text[begin.upperBound..<end.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: body) else { return nil }
        return [UInt8](data)
    }
}

/// What a person reads to tell one key from another: its algorithm, its
/// fingerprint, and the line a server's `authorized_keys` takes.
public struct SSHKeyDescription: Sendable, Equatable {
    /// The algorithm, as people name it: "Ed25519", "ECDSA P-256".
    public let algorithm: String
    /// The SHA-256 fingerprint as `ssh-keygen -l` prints it, `SHA256:` and
    /// unpadded base64.
    public let fingerprint: String
    /// The public key as one `authorized_keys` line, without a comment.
    public let authorizedKeysLine: String

    /// Describes a key by its public half.
    ///
    /// - Parameter key: The private key.
    public init(_ key: NIOSSHPrivateKey) {
        let line = String(openSSHPublicKey: key.publicKey)
        let fields = line.split(separator: " ", maxSplits: 2)
        let prefix = fields.first.map(String.init) ?? ""
        let blob = fields.count > 1 ? Data(base64Encoded: String(fields[1])) ?? Data() : Data()
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        authorizedKeysLine = line
        fingerprint = "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        algorithm = Self.algorithmNames[prefix] ?? prefix
    }

    /// The public key with a comment after it, as `ssh-keygen` writes a
    /// `.pub` file.
    ///
    /// - Parameter comment: What the line ends with, to tell keys apart in
    ///   `authorized_keys`; empty for none.
    /// - Returns: The line.
    public func authorizedKeysLine(comment: String) -> String {
        comment.isEmpty ? authorizedKeysLine : authorizedKeysLine + " " + comment
    }

    private static let algorithmNames = [
        "ssh-ed25519": "Ed25519",
        "ecdsa-sha2-nistp256": "ECDSA P-256",
        "ecdsa-sha2-nistp384": "ECDSA P-384",
        "ecdsa-sha2-nistp521": "ECDSA P-521",
    ]
}

/// OpenSSH's own private key container, `openssh-key-v1` (OpenSSH's
/// PROTOCOL.key).
///
/// The container holds a list of keys, each private half inside a section a
/// passphrase may encrypt. A key without a passphrase has cipher `none` and its
/// section in the clear, behind two equal check words that a wrong passphrase
/// would leave unequal.
enum OpenSSHKey {
    static let magic = Array("openssh-key-v1".utf8) + [0]

    /// Reads the decoded body of an `OPENSSH PRIVATE KEY` armour.
    ///
    /// - Parameter body: The base64-decoded container.
    /// - Returns: The key, or the refusal naming why not.
    static func read(_ body: [UInt8]) -> SSHPrivateKeyText.Outcome {
        let incomplete = SSHPrivateKeyText.Outcome.refused(SSHPrivateKeyText.incomplete("an OpenSSH key"))
        guard body.starts(with: magic) else { return incomplete }
        var reader = SSHWireReader(body[magic.count...])
        guard let cipher = reader.string(), let kdf = reader.string(), let options = reader.string(), let count = reader.uint32() else {
            return incomplete
        }
        guard cipher == Array("none".utf8), kdf == Array("none".utf8) else {
            return .refused(SSHPrivateKeyText.passphraseRefusal)
        }
        guard options.isEmpty else { return incomplete }
        guard count == 1 else {
            return .refused("This file holds \(count) keys. Import a file that holds one.")
        }
        guard let publicBlob = reader.string(), let section = reader.string(), reader.isEmpty,
            section.count.isMultiple(of: 8)
        else { return incomplete }
        var keys = SSHWireReader(section[...])
        guard let first = keys.uint32(), let second = keys.uint32(), first == second, let type = keys.string() else {
            return incomplete
        }
        let typeName = String(decoding: type, as: UTF8.self)
        let key: NIOSSHPrivateKey?
        switch typeName {
        case "ssh-ed25519":
            key = ed25519(&keys)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            key = ecdsa(&keys, type: typeName)
        case "ssh-rsa":
            return .refused(SSHPrivateKeyText.rsaRefusal)
        case "ssh-dss":
            return .refused(
                "This is a DSA key, which Ubiquitty doesn’t support. Use an Ed25519 or ECDSA key: generate a new key, or create one on a computer with ssh-keygen -t ed25519."
            )
        default:
            if typeName.hasPrefix("sk-") {
                return .refused(
                    "This key needs a hardware security key, which Ubiquitty can’t use. Use an Ed25519 or ECDSA key that doesn’t need one."
                )
            }
            return .refused("Ubiquitty doesn’t support this kind of key. Use an Ed25519 or ECDSA key.")
        }
        // The private half must belong to the public key the container
        // declares; a file whose two halves disagree is damaged, and signing
        // with it would fail at the server for no reason a person could see.
        guard let key, Self.publicBlob(of: key) == publicBlob,
            keys.string() != nil, keys.hasValidPadding
        else { return incomplete }
        return .key(key)
    }

    /// `string pub, string priv`, where `priv` is the 32-byte seed followed by
    /// the 32-byte public key.
    private static func ed25519(_ reader: inout SSHWireReader) -> NIOSSHPrivateKey? {
        guard let publicKey = reader.string(), publicKey.count == 32, let secret = reader.string(), secret.count == 64,
            Array(secret[32...]) == publicKey,
            let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret[..<32]),
            Array(key.publicKey.rawRepresentation) == publicKey
        else { return nil }
        return NIOSSHPrivateKey(ed25519Key: key)
    }

    /// `string curve, string Q, mpint d`.
    private static func ecdsa(_ reader: inout SSHWireReader, type: String) -> NIOSSHPrivateKey? {
        guard let curve = reader.string(), type == "ecdsa-sha2-" + String(decoding: curve, as: UTF8.self), let point = reader.string(),
            let scalar = reader.mpint()
        else { return nil }
        switch type {
        case "ecdsa-sha2-nistp256":
            guard let raw = padded(scalar, to: 32), let key = try? P256.Signing.PrivateKey(rawRepresentation: raw),
                Array(key.publicKey.x963Representation) == point
            else { return nil }
            return NIOSSHPrivateKey(p256Key: key)
        case "ecdsa-sha2-nistp384":
            guard let raw = padded(scalar, to: 48), let key = try? P384.Signing.PrivateKey(rawRepresentation: raw),
                Array(key.publicKey.x963Representation) == point
            else { return nil }
            return NIOSSHPrivateKey(p384Key: key)
        default:
            guard let raw = padded(scalar, to: 66), let key = try? P521.Signing.PrivateKey(rawRepresentation: raw),
                Array(key.publicKey.x963Representation) == point
            else { return nil }
            return NIOSSHPrivateKey(p521Key: key)
        }
    }

    /// An unsigned scalar at its curve's width: left-padded when an encoder
    /// dropped leading zeros, refused when longer than the curve allows.
    private static func padded(_ scalar: [UInt8], to width: Int) -> [UInt8]? {
        scalar.count > width ? nil : [UInt8](repeating: 0, count: width - scalar.count) + scalar
    }

    /// The public key's wire form, as the container's public section holds it.
    static func publicBlob(of key: NIOSSHPrivateKey) -> [UInt8] {
        let line = String(openSSHPublicKey: key.publicKey)
        let fields = line.split(separator: " ", maxSplits: 2)
        guard fields.count > 1, let data = Data(base64Encoded: String(fields[1])) else { return [] }
        return [UInt8](data)
    }
}

/// A cursor over SSH wire encoding (RFC 4251 §5): big-endian `uint32`, and
/// `string` and `mpint` as a `uint32` length and that many bytes.
struct SSHWireReader {
    private var bytes: ArraySlice<UInt8>

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
    }

    var isEmpty: Bool { bytes.isEmpty }

    /// Unencrypted OpenSSH sections pad to an eight-byte boundary with
    /// consecutive bytes starting at one. No key fields may follow them.
    var hasValidPadding: Bool {
        bytes.count < 8 && bytes.enumerated().allSatisfy { $0.element == UInt8($0.offset + 1) }
    }

    mutating func uint32() -> UInt32? {
        guard bytes.count >= 4 else { return nil }
        let value = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        bytes = bytes.dropFirst(4)
        return value
    }

    mutating func string() -> [UInt8]? {
        guard let length = uint32(), Int(length) <= bytes.count else { return nil }
        let value = Array(bytes.prefix(Int(length)))
        bytes = bytes.dropFirst(Int(length))
        return value
    }

    /// A non-negative `mpint`, without the zero byte that keeps its sign bit
    /// clear.
    mutating func mpint() -> [UInt8]? {
        guard let value = string(), value.first.map({ $0 & 0x80 == 0 }) ?? true else { return nil }
        return Array(value.drop { $0 == 0 })
    }
}
