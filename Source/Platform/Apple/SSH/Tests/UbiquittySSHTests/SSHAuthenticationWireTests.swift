// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The negotiation over the real protocol: the carrier's own pipeline as the
// client and NIOSSH's server role on the far end of a pair of embedded
// channels, the bytes shuttled between them by hand.

import CryptoKit
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

@testable import UbiquittySSH

/// A server that accepts what its script accepts and lists what it lists.
final class ScriptedServerAuthentication: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    init(listed: NIOSSHAvailableUserAuthenticationMethods, accepts: @escaping (NIOSSHUserAuthenticationRequest.Request) -> Bool) {
        self.supportedAuthenticationMethods = listed
        self.accepts = accepts
    }

    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        switch request.request {
        case .none: seen.append("none")
        case .password(let password): seen.append("password:\(password.password)")
        case .publicKey: seen.append("publickey")
        case .hostBased: seen.append("hostbased")
        }
        responsePromise.succeed(accepts(request.request) ? .success : .failure)
    }

    private(set) var seen: [String] = []
    private let accepts: (NIOSSHUserAuthenticationRequest.Request) -> Bool
}

/// Records the sign-in's success as the client's pipeline raises it.
final class SignInRecorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    private(set) var hasSignedIn = false

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { hasSignedIn = true }
        context.fireUserInboundEventTriggered(event)
    }
}

/// A carrier that is never started: its pipeline is what is under test.
final class SilentCarrierDelegate: SSHCarrierDelegate {
    func sshCarrierDidConnect(_ carrier: SSHCarrier) {}
    func sshCarrier(_ carrier: SSHCarrier, didReceive bytes: UnsafeRawBufferPointer) {}
    func sshCarrier(_ carrier: SSHCarrier, didReceiveStandardError bytes: UnsafeRawBufferPointer) {}
    func sshCarrier(_ carrier: SSHCarrier, didCloseWithFailure isFailure: Bool, reason: String, reachFailure: SSHReachFailure?) {}
}

final class SSHAuthenticationWireTests: XCTestCase {
    /// Signs the carrier's pipeline in against `server`, and reports whether it
    /// signed in.
    private func signIn(
        credentials: SSHAuthentication,
        server: ScriptedServerAuthentication
    ) throws -> Bool {
        let delegate = SilentCarrierDelegate()
        let carrier = SSHCarrier(
            host: "wire.test",
            port: 22,
            username: "ada",
            credentials: credentials,
            hostKeyValidator: { _ in },
            sessionKind: .exec(command: "true"),
            delegate: delegate
        )
        let client = EmbeddedChannel()
        let serverChannel = EmbeddedChannel()
        let authentication = SSHUserAuthenticationDelegate(username: "ada", host: "wire.test", credentials: credentials)
        let configuration = SSHClientConfiguration(
            userAuthDelegate: authentication,
            serverAuthDelegate: SSHHostKeyValidationDelegate(validator: { _ in })
        )
        let recorder = SignInRecorder()
        try client.pipeline.syncOperations.addHandlers(
            carrier.orderedHandlers(for: client, configuration: configuration, authentication: authentication)
        )
        try client.pipeline.syncOperations.addHandler(recorder)
        try serverChannel.pipeline.syncOperations.addHandler(
            NIOSSHHandler(
                role: .server(
                    SSHServerConfiguration(
                        hostKeys: [NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())],
                        userAuthDelegate: server
                    )
                ),
                allocator: serverChannel.allocator,
                inboundChildChannelInitializer: nil
            )
        )
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 22)
        try serverChannel.connect(to: address).wait()
        try client.connect(to: address).wait()
        for _ in 0..<64 {
            client.embeddedEventLoop.run()
            serverChannel.embeddedEventLoop.run()
            var moved = false
            while let bytes = try client.readOutbound(as: ByteBuffer.self) {
                _ = try? serverChannel.writeInbound(bytes)
                moved = true
            }
            while let bytes = try serverChannel.readOutbound(as: ByteBuffer.self) {
                _ = try? client.writeInbound(bytes)
                moved = true
            }
            if !moved { break }
        }
        _ = try? client.finish()
        _ = try? serverChannel.finish()
        return recorder.hasSignedIn
    }

    /// `none` crosses the wire first, and a server that accepts it signs the
    /// client in with nothing else sent and nobody asked.
    func testNoneAcceptedOverTheWire() throws {
        let person = ScriptedPerson(answer: "typed")
        let server = ScriptedServerAuthentication(listed: [.publicKey, .password]) {
            if case .none = $0 { return true }
            return false
        }
        let signedIn = try signIn(
            credentials: SSHAuthentication(
                offers: [.password("saved"), .askedPassword],
                interaction: SSHAuthenticationInteraction(person: person)
            ),
            server: server
        )
        XCTAssertTrue(signedIn)
        XCTAssertEqual(server.seen, ["none"])
        XCTAssertTrue(person.askedRequests.isEmpty)
    }

    /// A password-only server's list reaches the delegate over the wire, the
    /// key is withheld, and the person's one answer signs in.
    func testPasswordOnlyOverTheWire() throws {
        let person = ScriptedPerson(answer: "typed")
        let server = ScriptedServerAuthentication(listed: .password) {
            if case .password(let password) = $0 { return password.password == "typed" }
            return false
        }
        let signedIn = try signIn(
            credentials: SSHAuthentication(
                offers: [.privateKey(NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())), .askedPassword],
                interaction: SSHAuthenticationInteraction(person: person)
            ),
            server: server
        )
        XCTAssertTrue(signedIn)
        XCTAssertEqual(server.seen, ["none", "password:typed"])
        XCTAssertEqual(person.askedRequests.count, 1)
    }
}
