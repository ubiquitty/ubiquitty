// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The sign-in negotiation against scripted servers. Each case names what the
// server does and asserts what the person is asked, which is the contract:
// nobody is asked for a credential the server did not ask for.
//
// The negotiation cases drive the delegate the way NIOSSH's state machine
// does: one call with every method before the server has said anything, then
// one call per refusal with the server's list. The wire cases put NIOSSH's own
// server on the other end of a pair of embedded channels, so `none`, the
// method lists and the success event cross the real protocol.

import CryptoKit
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

@testable import UbiquittySSH

/// Records what the person was asked and shown, and answers as scripted.
final class ScriptedPerson: SSHAuthenticationPerson, @unchecked Sendable {
    init(answer: String?) {
        self.answer = answer
    }

    func askForPassword(_ request: SSHPasswordRequest, answer: @escaping @Sendable (String?) -> Void) {
        lock.withLock { passwordRequests.append(request) }
        answer(self.answer)
    }

    func show(_ banner: SSHAuthenticationBanner) {
        lock.withLock { banners.append(banner) }
    }

    func bannerWaitEnded() {
        lock.withLock { bannerWaitEndCount += 1 }
    }

    var askedRequests: [SSHPasswordRequest] { lock.withLock { passwordRequests } }
    var shownBanners: [SSHAuthenticationBanner] { lock.withLock { banners } }
    var endedBannerWaits: Int { lock.withLock { bannerWaitEndCount } }

    private let answer: String?
    private let lock = NSLock()
    private var passwordRequests: [SSHPasswordRequest] = []
    private var banners: [SSHAuthenticationBanner] = []
    private var bannerWaitEndCount = 0
}

/// What a scripted server answers one request with.
enum ScriptedAnswer {
    case accept
    case refuse(NIOSSHAvailableUserAuthenticationMethods)
}

/// One request the client made, as the server saw it.
enum SeenRequest: Equatable {
    case none
    case password(String)
    case publicKey
}

/// Plays the server's half of the negotiation against the delegate, as
/// NIOSSH's user-authentication state machine calls it.
final class ScriptedServer {
    init(answer: @escaping (SeenRequest) -> ScriptedAnswer) {
        self.answer = answer
    }

    /// Signs in, and returns the requests made and how the sign-in ended.
    func signIn(with delegate: SSHUserAuthenticationDelegate) -> (requests: [SeenRequest], outcome: Result<Void, Error>) {
        var requests: [SeenRequest] = []
        var methods = NIOSSHAvailableUserAuthenticationMethods.all
        for _ in 0..<10 {
            let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
            delegate.nextAuthenticationType(availableMethods: methods, nextChallengePromise: promise)
            loop.run()
            var offered: Result<NIOSSHUserAuthenticationOffer?, Error>?
            promise.futureResult.whenComplete { offered = $0 }
            loop.run()
            guard let offered else { return (requests, .failure(ScriptError.noAnswer)) }
            switch offered {
            case .failure(let error):
                return (requests, .failure(error))
            case .success(nil):
                return (requests, .failure(ScriptError.noAnswer))
            case .success(.some(let offer)):
                let seen: SeenRequest
                switch offer.offer {
                case .none: seen = .none
                case .password(let password): seen = .password(password.password)
                case .privateKey: seen = .publicKey
                case .hostBased: return (requests, .failure(ScriptError.unexpected))
                }
                requests.append(seen)
                switch answer(seen) {
                case .accept:
                    delegate.endSignIn()
                    return (requests, .success(()))
                case .refuse(let listed):
                    methods = listed
                }
            }
        }
        return (requests, .failure(ScriptError.unexpected))
    }

    enum ScriptError: Error {
        case noAnswer
        case unexpected
    }

    let loop = EmbeddedEventLoop()
    private let answer: (SeenRequest) -> ScriptedAnswer
}

final class SSHAuthenticationNegotiationTests: XCTestCase {
    private let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())

    /// A Tailscale node accepts `none`: the saved password is never sent, and
    /// nobody is asked.
    func testNoneAcceptedAsksNothingAndSendsNothing() {
        let person = ScriptedPerson(answer: "typed")
        let delegate = SSHUserAuthenticationDelegate(
            username: "ada",
            host: "tailnet-host",
            credentials: SSHAuthentication(
                offers: [.password("saved"), .askedPassword],
                interaction: SSHAuthenticationInteraction(person: person)
            )
        )
        let server = ScriptedServer { $0 == .none ? .accept : .refuse([]) }
        let (requests, outcome) = server.signIn(with: delegate)
        XCTAssertEqual(requests, [.none])
        XCTAssertNoThrow(try outcome.get())
        XCTAssertTrue(person.askedRequests.isEmpty)
    }

    /// A server that lists `publickey` and `keyboard-interactive` gets the
    /// saved key, and the person is not asked for a password it never listed.
    /// NIOSSH drops `keyboard-interactive` from the list it hands the delegate,
    /// so the list arrives as `publickey` alone.
    func testPublicKeyAndKeyboardInteractiveOffersTheKeyAndAsksNothing() {
        let person = ScriptedPerson(answer: "typed")
        let delegate = SSHUserAuthenticationDelegate(
            username: "ada",
            credentials: SSHAuthentication(
                offers: [.privateKey(key), .askedPassword],
                interaction: SSHAuthenticationInteraction(person: person)
            )
        )
        let server = ScriptedServer { $0 == .publicKey ? .accept : .refuse(.publicKey) }
        let (requests, outcome) = server.signIn(with: delegate)
        XCTAssertEqual(requests, [.none, .publicKey])
        XCTAssertNoThrow(try outcome.get())
        XCTAssertTrue(person.askedRequests.isEmpty)
    }

    /// The same server with no key saved refuses for want of a method, and
    /// still nobody is asked.
    func testKeyboardInteractiveOnlyRefusesWithoutAsking() {
        let person = ScriptedPerson(answer: "typed")
        var refused = false
        let delegate = SSHUserAuthenticationDelegate(
            username: "ada",
            credentials: SSHAuthentication(
                offers: [.askedPassword],
                interaction: SSHAuthenticationInteraction(person: person)
            ),
            authenticationRefused: {}
        )
        let server = ScriptedServer { _ in .refuse([]) }
        let (requests, outcome) = server.signIn(with: delegate)
        if case .failure(let error) = outcome, case SSHCarrierError.noAcceptedMethod = error { refused = true }
        XCTAssertEqual(requests, [.none])
        XCTAssertTrue(refused, "a server listing nothing offerable is reported as such")
        XCTAssertTrue(person.askedRequests.isEmpty)
    }

    /// A Tailscale check holds `none` and sends a banner with the page to
    /// approve. The person is shown the server's text with the link, the
    /// interaction waits on them until the server answers, and nobody is asked
    /// for a password.
    func testCheckBannerShowsTheLinkAndHoldsUntilTheServerAnswers() {
        let person = ScriptedPerson(answer: "typed")
        let interaction = SSHAuthenticationInteraction(person: person)
        let delegate = SSHUserAuthenticationDelegate(
            username: "ada",
            credentials: SSHAuthentication(offers: [.askedPassword], interaction: interaction)
        )
        let checkText =
            "# Tailscale SSH requires an additional check.\n# To authenticate, visit: https://login.tailscale.com/a/abc123\n"
        let server = ScriptedServer { seen in
            if seen == .none {
                delegate.receiveBanner(checkText)
                XCTAssertTrue(interaction.isWaitingOnPerson, "a shown link holds the connection open")
                return .accept
            }
            return .refuse([])
        }
        let (requests, outcome) = server.signIn(with: delegate)
        XCTAssertEqual(requests, [.none])
        XCTAssertNoThrow(try outcome.get())
        XCTAssertEqual(person.shownBanners.count, 1)
        XCTAssertEqual(person.shownBanners.first?.link?.absoluteString, "https://login.tailscale.com/a/abc123")
        XCTAssertTrue(person.shownBanners.first?.message.hasPrefix("# Tailscale SSH requires an additional check.") == true)
        XCTAssertFalse(interaction.isWaitingOnPerson, "the server's answer releases the hold")
        XCTAssertEqual(person.endedBannerWaits, 1)
        XCTAssertTrue(person.askedRequests.isEmpty)
    }

    /// A server that lists only `password`, with nothing saved: the person is
    /// asked once, with the server's banner, and the answer is what is sent.
    func testPasswordOnlyAsksOnceWithTheServerText() {
        let person = ScriptedPerson(answer: "typed")
        let delegate = SSHUserAuthenticationDelegate(
            username: "ada",
            host: "example.net",
            credentials: SSHAuthentication(
                offers: [.privateKey(key), .askedPassword],
                interaction: SSHAuthenticationInteraction(person: person)
            )
        )
        let server = ScriptedServer { seen in
            if seen == .none { delegate.receiveBanner("Authorized use only.") }
            return seen == .password("typed") ? .accept : .refuse(.password)
        }
        let (requests, outcome) = server.signIn(with: delegate)
        XCTAssertEqual(requests, [.none, .password("typed")], "the key is never offered to a server that excludes publickey")
        XCTAssertNoThrow(try outcome.get())
        XCTAssertEqual(person.askedRequests.count, 1)
        XCTAssertEqual(person.askedRequests.first?.username, "ada")
        XCTAssertEqual(person.askedRequests.first?.host, "example.net")
        XCTAssertEqual(person.askedRequests.first?.banner?.message, "Authorized use only.")
    }

    /// A saved password answers a password-only server without asking.
    func testSavedPasswordIsOfferedOnlyWhenListed() {
        let person = ScriptedPerson(answer: "typed")
        let delegate = SSHUserAuthenticationDelegate(
            username: "ada",
            credentials: SSHAuthentication(
                offers: [.password("saved"), .askedPassword],
                interaction: SSHAuthenticationInteraction(person: person)
            )
        )
        let server = ScriptedServer { $0 == .password("saved") ? .accept : .refuse(.password) }
        let (requests, outcome) = server.signIn(with: delegate)
        XCTAssertEqual(requests, [.none, .password("saved")])
        XCTAssertNoThrow(try outcome.get())
        XCTAssertTrue(person.askedRequests.isEmpty)
    }

    /// A declined ask ends the sign-in as cancelled, sends nothing, and is not
    /// asked again by the session's next connection.
    func testDeclinedAskIsCancelledAndNotRepeated() {
        let person = ScriptedPerson(answer: nil)
        let interaction = SSHAuthenticationInteraction(person: person)
        for _ in 0..<2 {
            let delegate = SSHUserAuthenticationDelegate(
                username: "ada",
                credentials: SSHAuthentication(offers: [.askedPassword], interaction: interaction)
            )
            let server = ScriptedServer { _ in .refuse(.password) }
            let (requests, outcome) = server.signIn(with: delegate)
            XCTAssertEqual(requests, [.none])
            guard case .failure(SSHCarrierError.authenticationCancelled) = outcome else {
                return XCTFail("a declined ask is a cancelled sign-in, not a refused one")
            }
        }
        XCTAssertEqual(person.askedRequests.count, 1)
    }

    /// Every connection of one session shares the one answer: the bootstrap
    /// ask and the carrier after it do not ask twice.
    func testOneSessionAsksOnceAcrossConnections() {
        let person = ScriptedPerson(answer: "typed")
        let interaction = SSHAuthenticationInteraction(person: person)
        for _ in 0..<3 {
            let delegate = SSHUserAuthenticationDelegate(
                username: "ada",
                credentials: SSHAuthentication(offers: [.askedPassword], interaction: interaction)
            )
            let server = ScriptedServer { $0 == .password("typed") ? .accept : .refuse(.password) }
            XCTAssertNoThrow(try server.signIn(with: delegate).outcome.get())
        }
        XCTAssertEqual(person.askedRequests.count, 1)
    }

    /// With nobody to ask, as in a background refresh, an asked password is
    /// skipped rather than waited on.
    func testNobodyToAskIsNeverAsked() {
        let delegate = SSHUserAuthenticationDelegate(username: "ada", credentials: [.askedPassword])
        let server = ScriptedServer { _ in .refuse(.password) }
        let (requests, outcome) = server.signIn(with: delegate)
        XCTAssertEqual(requests, [.none])
        guard case .failure(SSHCarrierError.noAcceptedMethod) = outcome else {
            return XCTFail("nothing offerable without a person")
        }
    }

    /// A refused saved credential is reported as refused, the case the
    /// interface tells apart from a server with no usable method.
    func testRefusedKeyIsExhausted() {
        let delegate = SSHUserAuthenticationDelegate(username: "ada", credentials: [.privateKey(key)])
        let server = ScriptedServer { _ in .refuse(.publicKey) }
        let (requests, outcome) = server.signIn(with: delegate)
        XCTAssertEqual(requests, [.none, .publicKey])
        guard case .failure(SSHCarrierError.authenticationExhausted) = outcome else {
            return XCTFail("a refused key exhausts the offers")
        }
    }

    /// A server that closes the connection during sign-in, which is how sshd
    /// ends the attempt past MaxAuthTries, is reported as that and not as a
    /// network fault.
    func testCloseDuringSignInIsNotAReachFailure() {
        XCTAssertEqual(classifySSHClose(.unexpectedClose, phase: .signingIn), .closedDuringSignIn)
        XCTAssertEqual(classifySSHClose(.unexpectedClose, phase: .signedIn), .interruptedBeforeSession)
        XCTAssertEqual(classifySSHClose(.failure, error: SSHCarrierError.noAcceptedMethod, phase: .signingIn), .noAcceptedMethod)
        XCTAssertEqual(
            classifySSHClose(.failure, error: SSHCarrierError.authenticationCancelled, phase: .signingIn),
            .authenticationCancelled
        )
    }

    /// Banner text is untrusted: controls are removed, length is bounded, and
    /// only an `https` link is offered to open.
    func testBannerIsSanitizedAndOnlyOffersSecureLinks() {
        let hostile = SSHAuthenticationBanner(serverText: "visit\u{1B}[31m \u{202E}http://evil.example/x and nothing else")
        XCTAssertNil(hostile.link)
        XCTAssertFalse(hostile.message.unicodeScalars.contains("\u{1B}"))
        XCTAssertFalse(hostile.message.unicodeScalars.contains("\u{202E}"))
        let long = SSHAuthenticationBanner(serverText: String(repeating: "a", count: 100_000))
        XCTAssertEqual(long.message.count, SSHAuthenticationBanner.maxMessageLength)
    }
}
