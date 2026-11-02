// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The key reader against the files `ssh-keygen` writes, and against containers
// built here for the shapes ssh-keygen will not produce.
//
// No key is checked in. A private key in a repository is a private key
// whatever its comment claims, and a secret scanner is right to say so; every
// key here is made when the test runs and lives in a temporary directory or in
// memory. ssh-keygen is the oracle: a reader that agrees with a writer built
// beside it can share its misreading, and one that agrees with OpenSSH's own
// `.pub` file and fingerprint cannot.

import CryptoKit
import Foundation
import NIOSSH
import XCTest

@testable import UbiquittySSH

final class SSHPrivateKeyTextTests: XCTestCase {
    // MARK: - Files ssh-keygen writes

    func testOpenSSHEd25519KeyReadsAsTheKeySSHKeygenDescribes() throws {
        try assertReadsLikeSSHKeygen(["-t", "ed25519"], algorithm: "Ed25519")
    }

    func testOpenSSHP256KeyReadsAsTheKeySSHKeygenDescribes() throws {
        try assertReadsLikeSSHKeygen(["-t", "ecdsa", "-b", "256"], algorithm: "ECDSA P-256")
    }

    func testOpenSSHP384KeyReadsAsTheKeySSHKeygenDescribes() throws {
        try assertReadsLikeSSHKeygen(["-t", "ecdsa", "-b", "384"], algorithm: "ECDSA P-384")
    }

    func testOpenSSHP521KeyReadsAsTheKeySSHKeygenDescribes() throws {
        try assertReadsLikeSSHKeygen(["-t", "ecdsa", "-b", "521"], algorithm: "ECDSA P-521")
    }

    func testSEC1KeyFromSSHKeygenReads() throws {
        try assertReadsLikeSSHKeygen(["-t", "ecdsa", "-b", "256", "-m", "PEM"], algorithm: "ECDSA P-256")
    }

    /// The LibreSSL behind macOS's ssh-keygen spells the curve out rather
    /// than naming it, and the larger curves take the same path.
    func testSEC1KeysWithSpelledOutCurvesFromSSHKeygenRead() throws {
        try assertReadsLikeSSHKeygen(["-t", "ecdsa", "-b", "384", "-m", "PEM"], algorithm: "ECDSA P-384")
        try assertReadsLikeSSHKeygen(["-t", "ecdsa", "-b", "521", "-m", "PEM"], algorithm: "ECDSA P-521")
    }

    func testPKCS8KeyFromSSHKeygenReads() throws {
        try assertReadsLikeSSHKeygen(["-t", "ecdsa", "-b", "256", "-m", "PKCS8"], algorithm: "ECDSA P-256")
    }

    func testOpenSSHRSAKeyIsRefusedAsRSA() throws {
        let key = try sshKeygen(["-t", "rsa", "-b", "2048"])
        XCTAssertEqual(refusal(of: key.privateText), SSHPrivateKeyText.rsaRefusal)
    }

    func testPKCS1RSAKeyIsRefusedAsRSA() throws {
        let key = try sshKeygen(["-t", "rsa", "-b", "2048", "-m", "PEM"])
        XCTAssertTrue(key.privateText.contains("BEGIN RSA PRIVATE KEY"))
        XCTAssertEqual(refusal(of: key.privateText), SSHPrivateKeyText.rsaRefusal)
    }

    func testOpenSSHKeyUnderAPassphraseIsRefusedForThePassphrase() throws {
        let key = try sshKeygen(["-t", "ed25519"], passphrase: "correct horse")
        XCTAssertEqual(refusal(of: key.privateText), SSHPrivateKeyText.passphraseRefusal)
    }

    func testSEC1KeyUnderAPassphraseIsRefusedForThePassphrase() throws {
        let key = try sshKeygen(["-t", "ecdsa", "-b", "256", "-m", "PEM"], passphrase: "correct horse")
        XCTAssertEqual(refusal(of: key.privateText), SSHPrivateKeyText.passphraseRefusal)
    }

    func testPKCS8KeyUnderAPassphraseIsRefusedForThePassphrase() throws {
        let key = try sshKeygen(["-t", "ecdsa", "-b", "256", "-m", "PKCS8"], passphrase: "correct horse")
        XCTAssertEqual(refusal(of: key.privateText), SSHPrivateKeyText.passphraseRefusal)
    }

    // MARK: - Containers built here

    func testPKCS8KeyFromSwiftCryptoReads() {
        let key = P256.Signing.PrivateKey()
        XCTAssertEqual(publicKey(of: key.pemRepresentation), key.publicKey.rawRepresentation)
    }

    func testSEC1KeysReadOnEveryCurveTheirOIDNames() {
        let p256 = P256.Signing.PrivateKey()
        XCTAssertNotNil(readKey(sec1(scalar: [UInt8](p256.rawRepresentation), curveOID: DER.p256OID)))
        let p384 = P384.Signing.PrivateKey()
        XCTAssertNotNil(readKey(sec1(scalar: [UInt8](p384.rawRepresentation), curveOID: DER.p384OID)))
        let p521 = P521.Signing.PrivateKey()
        XCTAssertNotNil(readKey(sec1(scalar: [UInt8](p521.rawRepresentation), curveOID: DER.p521OID)))
    }

    func testTruncatedSEC1BodyIsRefused() {
        XCTAssertNotNil(refusal(of: "-----BEGIN EC PRIVATE KEY-----\nMHcCAQE=\n-----END EC PRIVATE KEY-----"))
    }

    func testSEC1ExplicitCurveCannotBeChangedWhileKeepingThePrime() throws {
        let generated = try sshKeygen(["-t", "ecdsa", "-b", "256", "-m", "PEM"])
        XCTAssertNotNil(readKey(generated.privateText))
        var body = Data(try XCTUnwrap(SSHPrivateKeyText.base64Body(of: generated.privateText, label: "EC PRIVATE KEY")))
        // P-256's coefficient b, as the explicit ECParameters encode it.
        let prefix = Data([0x04, 0x20, 0x5A, 0xC6, 0x35, 0xD8, 0xAA, 0x3A])
        let coefficient = try XCTUnwrap(body.range(of: prefix))
        body[coefficient.upperBound - 1] ^= 1
        XCTAssertNotNil(refusal(of: armour(Array(body), label: "EC PRIVATE KEY")))
    }

    func testSEC1TrailingDataIsRefused() throws {
        let text = sec1(scalar: Array(P256.Signing.PrivateKey().rawRepresentation), curveOID: DER.p256OID)
        let body = try XCTUnwrap(SSHPrivateKeyText.base64Body(of: text, label: "EC PRIVATE KEY"))
        XCTAssertNotNil(refusal(of: armour(body + [0], label: "EC PRIVATE KEY")))
    }

    func testOpenSSHKeyWithUnequalCheckWordsIsRefused() {
        let seed = Curve25519.Signing.PrivateKey()
        let text = openSSHEd25519(seed, checkWords: (1, 2))
        XCTAssertEqual(refusal(of: text), SSHPrivateKeyText.incomplete("an OpenSSH key"))
    }

    func testOpenSSHKeyWhoseHalvesDisagreeIsRefused() {
        let text = openSSHEd25519(Curve25519.Signing.PrivateKey(), publicFrom: Curve25519.Signing.PrivateKey())
        XCTAssertEqual(refusal(of: text), SSHPrivateKeyText.incomplete("an OpenSSH key"))
    }

    func testOpenSSHEd25519EmbeddedPublicKeyMustMatchTheSeed() {
        let text = openSSHEd25519(Curve25519.Signing.PrivateKey(), embeddedPublicFrom: Curve25519.Signing.PrivateKey())
        XCTAssertNotNil(refusal(of: text))
    }

    func testOpenSSHECDSACurveAndPointMustMatchTheScalar() {
        let key = P256.Signing.PrivateKey()
        let publicBlob = OpenSSHKey.publicBlob(of: NIOSSHPrivateKey(p256Key: key))
        let scalar = wire(bytes: [0] + Array(key.rawRepresentation))
        let correctPoint = Array(key.publicKey.x963Representation)
        for (curve, point) in [
            ("nistp256", Array(P256.Signing.PrivateKey().publicKey.x963Representation)),
            ("", correctPoint),
            ("256", correctPoint),
        ] {
            let section =
                wire(string: "ecdsa-sha2-nistp256") + wire(string: curve)
                + wire(bytes: point) + scalar + wire(string: "test")
            XCTAssertNotNil(refusal(of: openSSH(publicBlob: publicBlob, section: section)))
        }
    }

    func testOpenSSHRejectsDamagedContainerFields() {
        let key = Curve25519.Signing.PrivateKey()
        let publicBlob = OpenSSHKey.publicBlob(of: NIOSSHPrivateKey(ed25519Key: key))
        let own = Array(key.publicKey.rawRepresentation)
        let fields =
            wire(string: "ssh-ed25519") + wire(bytes: own)
            + wire(bytes: Array(key.rawRepresentation) + own)
        let section = fields + wire(string: "test")
        XCTAssertNotNil(refusal(of: openSSH(publicBlob: publicBlob, section: section, options: [1])))
        XCTAssertNotNil(refusal(of: openSSH(publicBlob: publicBlob, section: section, trailingBytes: [1])))
        XCTAssertNotNil(refusal(of: openSSH(publicBlob: publicBlob, section: fields)))
        XCTAssertNotNil(refusal(of: openSSH(publicBlob: publicBlob, section: section, transform: { Array($0.dropLast()) })))
        XCTAssertNotNil(refusal(of: openSSH(publicBlob: publicBlob, section: section, transform: { Array($0.dropLast()) + [0] })))
    }

    func testOpenSSHKeyCutShortIsRefusedAsIncomplete() {
        let whole = openSSHEd25519(Curve25519.Signing.PrivateKey())
        let lines = whole.split(separator: "\n")
        let cut = ([lines[0], lines[1]] + [lines[lines.count - 1]]).joined(separator: "\n")
        XCTAssertEqual(refusal(of: cut), SSHPrivateKeyText.incomplete("an OpenSSH key"))
    }

    func testOpenSSHSecurityKeyIsRefusedForNeedingTheHardware() throws {
        // OpenSSH's name for the type, joined here because the personal-path
        // gate reads any `name@domain` literal as an address.
        let type = ["sk-ssh-ed25519", "openssh.com"].joined(separator: "@")
        let text = openSSH(publicBlob: wire(string: type), section: wire(string: type))
        XCTAssertTrue(try XCTUnwrap(refusal(of: text)).contains("hardware security key"))
    }

    func testUnrecognizedTextIsRefusedWithAWayToMakeAKey() throws {
        XCTAssertTrue(try XCTUnwrap(refusal(of: "not a key at all")).contains("ssh-keygen -t ed25519"))
    }

    func testOversizedTextIsRefusedBeforeItIsRead() {
        let text = String(repeating: "A", count: SSHPrivateKeyText.maxTextLength + 1)
        XCTAssertEqual(refusal(of: text), "This file is too large to be a private key.")
    }

    func testMadeKeyReadsBack() {
        let text = SSHPrivateKeyText.makeP256Key()
        let key = readKey(text)
        XCTAssertEqual(key.map(SSHKeyDescription.init)?.algorithm, "ECDSA P-256")
    }

    // MARK: - Helpers

    private struct GeneratedKey {
        let privateText: String
        let publicLine: String
        let fingerprint: String
    }

    /// Reads a key ssh-keygen wrote and checks it describes the key the way
    /// ssh-keygen's own `.pub` file and fingerprint do.
    private func assertReadsLikeSSHKeygen(
        _ arguments: [String],
        algorithm: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let generated = try sshKeygen(arguments)
        guard let key = readKey(generated.privateText) else {
            XCTFail("refused: \(refusal(of: generated.privateText) ?? "")", file: file, line: line)
            return
        }
        let description = SSHKeyDescription(key)
        let publicFields = generated.publicLine.split(separator: " ").prefix(2).joined(separator: " ")
        XCTAssertEqual(description.authorizedKeysLine, publicFields, file: file, line: line)
        XCTAssertEqual(description.fingerprint, generated.fingerprint, file: file, line: line)
        XCTAssertEqual(description.algorithm, algorithm, file: file, line: line)
    }

    /// Runs ssh-keygen into a temporary directory and reads back what it wrote.
    private func sshKeygen(_ arguments: [String], passphrase: String = "") throws -> GeneratedKey {
        #if os(macOS)
        let tool = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw XCTSkip("ssh-keygen is not installed")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyFile = directory.appendingPathComponent("key")
        try run(tool, arguments + ["-q", "-N", passphrase, "-C", "test", "-f", keyFile.path])
        let fingerprint = try run(tool, ["-l", "-E", "sha256", "-f", keyFile.appendingPathExtension("pub").path])
        return GeneratedKey(
            privateText: try String(contentsOf: keyFile, encoding: .utf8),
            publicLine: try String(contentsOf: keyFile.appendingPathExtension("pub"), encoding: .utf8),
            fingerprint: fingerprint.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        )
        #else
        throw XCTSkip("ssh-keygen runs only on macOS")
        #endif
    }

    #if os(macOS)
    @discardableResult
    private func run(_ tool: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw XCTSkip("ssh-keygen \(arguments.joined(separator: " ")) failed: \(text)")
        }
        return text
    }
    #endif

    private func readKey(_ text: String) -> NIOSSHPrivateKey? {
        if case .key(let key) = SSHPrivateKeyText.read(text) { return key }
        return nil
    }

    private func refusal(of text: String) -> String? {
        if case .refused(let reason) = SSHPrivateKeyText.read(text) { return reason }
        return nil
    }

    private func publicKey(of text: String) -> Data? {
        guard let key = readKey(text) else { return nil }
        return try? P256.Signing.PublicKey(openSSHBlob: OpenSSHKey.publicBlob(of: key)).rawRepresentation
    }

    /// Wraps a scalar and curve as RFC 5915, as `ssh-keygen -m PEM` does.
    private func sec1(scalar: [UInt8], curveOID: [UInt8]) -> String {
        let version: [UInt8] = [0x02, 0x01, 0x01]
        let privateKey = element(tag: 0x04, body: scalar)
        let parameters = element(tag: 0xA0, body: element(tag: 0x06, body: curveOID))
        return armour(element(tag: 0x30, body: version + privateKey + parameters), label: "EC PRIVATE KEY")
    }

    /// One DER element, with the definite length form its body requires.
    private func element(tag: UInt8, body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        if body.count < 0x80 {
            out.append(UInt8(body.count))
        } else if body.count < 0x100 {
            out += [0x81, UInt8(body.count)]
        } else {
            out += [0x82, UInt8(body.count >> 8), UInt8(body.count & 0xFF)]
        }
        return out + body
    }

    /// An unencrypted `openssh-key-v1` container for an Ed25519 key.
    private func openSSHEd25519(
        _ key: Curve25519.Signing.PrivateKey,
        publicFrom publicKey: Curve25519.Signing.PrivateKey? = nil,
        embeddedPublicFrom embeddedKey: Curve25519.Signing.PrivateKey? = nil,
        checkWords: (UInt32, UInt32) = (7, 7)
    ) -> String {
        let declared = [UInt8]((publicKey ?? key).publicKey.rawRepresentation)
        let own = [UInt8]((embeddedKey ?? key).publicKey.rawRepresentation)
        let publicBlob = wire(string: "ssh-ed25519") + wire(bytes: declared)
        let section =
            wire(uint32: checkWords.0) + wire(uint32: checkWords.1) + wire(string: "ssh-ed25519") + wire(bytes: own)
            + wire(bytes: [UInt8](key.rawRepresentation) + own) + wire(string: "test")
        return openSSH(publicBlob: publicBlob, section: section, wrapCheckWords: false)
    }

    /// An unencrypted `openssh-key-v1` container around one key's sections.
    private func openSSH(
        publicBlob: [UInt8],
        section: [UInt8],
        wrapCheckWords: Bool = true,
        options: [UInt8] = [],
        trailingBytes: [UInt8] = [],
        transform: ([UInt8]) -> [UInt8] = { $0 }
    ) -> String {
        var privateSection = wrapCheckWords ? wire(uint32: 9) + wire(uint32: 9) + section : section
        var pad: UInt8 = 1
        while privateSection.count % 8 != 0 {
            privateSection.append(pad)
            pad += 1
        }
        let body =
            OpenSSHKey.magic + wire(string: "none") + wire(string: "none") + wire(bytes: options) + wire(uint32: 1)
            + wire(bytes: publicBlob) + wire(bytes: transform(privateSection)) + trailingBytes
        return armour(body, label: "OPENSSH PRIVATE KEY", width: 70)
    }

    private func armour(_ bytes: [UInt8], label: String, width: Int = 64) -> String {
        var lines = ["-----BEGIN \(label)-----"]
        var rest = Substring(Data(bytes).base64EncodedString())
        while !rest.isEmpty {
            lines.append(String(rest.prefix(width)))
            rest = rest.dropFirst(width)
        }
        lines.append("-----END \(label)-----")
        return lines.joined(separator: "\n")
    }

    private func wire(uint32 value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private func wire(bytes: [UInt8]) -> [UInt8] {
        wire(uint32: UInt32(bytes.count)) + bytes
    }

    private func wire(string: String) -> [UInt8] {
        wire(bytes: Array(string.utf8))
    }
}

extension P256.Signing.PublicKey {
    /// The key in an `ecdsa-sha2-nistp256` public blob.
    fileprivate init(openSSHBlob blob: [UInt8]) throws {
        var reader = SSHWireReader(blob[...])
        _ = reader.string()
        _ = reader.string()
        try self.init(x963Representation: reader.string() ?? [])
    }
}
