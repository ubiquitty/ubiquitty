// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// What the client offers the server, and the delegate that negotiates with it.
//
// Authentication is negotiated, never chosen in advance. The first request is
// `none` (RFC 4252 §5.2): a server that authenticates the connection by
// something other than a secret, such as a Tailscale node checking the tailnet
// identity, accepts it, and nobody is asked for anything. A server that
// refuses `none` answers with the methods it accepts, and only then is a
// credential offered, and only for a method on that list. The person is asked
// for a password only when the server lists `password` and nothing saved
// answered it.
//
// Each offer is made at most once: a server that rejects one asks again, and
// an offer repeated on that second ask authenticates nothing while spending
// one of the server's attempts.
//
// swift-nio-ssh implements publickey, password and hostbased, and drops every
// other method name from the server's list, keyboard-interactive among them. A
// server that accepts only keyboard-interactive is reported as accepting
// nothing this client offers, rather than asked for a password it never
// listed.

import Foundation
import NIOCore
import NIOSSH

/// One authentication offer.
public enum SSHCredential: Sendable {
    /// A saved password, offered through SSH's `password` method when the
    /// server lists it.
    case password(String)

    /// A saved private key, offered through `publickey` when the server lists
    /// it.
    case privateKey(NIOSSHPrivateKey)

    /// A password asked of the person, through the authentication's
    /// interaction, when the server lists `password`.
    ///
    /// Without an interaction this offer is skipped: a connection that runs
    /// with nobody to ask, such as a background refresh, never asks.
    case askedPassword
}

/// What one connection may offer the server, and how it reaches the person.
public struct SSHAuthentication: Sendable, ExpressibleByArrayLiteral {
    /// The offers, in the order they are tried against the server's list.
    public var offers: [SSHCredential]

    /// Who answers an asked password and reads the server's banners; nil when
    /// nobody is there to ask.
    public var interaction: SSHAuthenticationInteraction?

    /// Creates an authentication from its offers and interaction.
    public init(offers: [SSHCredential], interaction: SSHAuthenticationInteraction? = nil) {
        self.offers = offers
        self.interaction = interaction
    }

    /// Creates an authentication with these offers and nobody to ask.
    public init(arrayLiteral offers: SSHCredential...) {
        self.init(offers: offers)
    }
}

/// Negotiates one connection's sign-in: `none` first, then each offer the
/// server's list allows, once.
///
/// NIOSSH calls it on the connection's event loop; the person's answer is
/// hopped back there before it touches any state.
final class SSHUserAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    /// Creates the delegate for one connection.
    ///
    /// - Parameters:
    ///   - username: The account to sign in to.
    ///   - host: The host as dialled, which an asked password names.
    ///   - credentials: The offers and the interaction.
    ///   - signInBegan: Called once, when NIOSSH first asks for an offer, which
    ///     is when the key exchange has finished.
    ///   - authenticationRefused: Called when the sign-in ends without success,
    ///     before the refusal is reported.
    init(
        username: String,
        host: String = "",
        credentials: SSHAuthentication,
        signInBegan: @escaping @Sendable () -> Void = {},
        authenticationRefused: @escaping @Sendable () -> Void = {}
    ) {
        self.signInBegan = signInBegan
        self.username = username
        self.host = host
        self.remainingOffers = credentials.offers
        self.interaction = credentials.interaction
        self.authenticationRefused = authenticationRefused
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // NIOSSH asks first with every method it knows, before the server has
        // said anything; `none` is the request that makes it say.
        guard hasOfferedNone else {
            hasOfferedNone = true
            signInBegan()
            nextChallengePromise.succeed(makeOffer(.none))
            return
        }
        offerNext(allowedBy: availableMethods, promise: nextChallengePromise)
    }

    /// Records a banner the server sent while signing in, and shows it.
    ///
    /// - Parameter text: The banner as the server sent it.
    func receiveBanner(_ text: String) {
        guard bannerCount < Self.maxBannerCount else { return }
        bannerCount += 1
        let banner = SSHAuthenticationBanner(serverText: text)
        guard !banner.message.isEmpty else { return }
        lastBanner = banner
        interaction?.show(banner, on: connectionID)
    }

    /// Ends this connection's sign-in: the server accepted it, or the
    /// connection is gone. A person still being asked is answered into a
    /// connection that no longer listens.
    func endSignIn() {
        endLock.withLock { hasEnded = true }
        interaction?.endSignIn(on: connectionID)
    }

    /// The most banners one connection shows.
    ///
    /// Banners are untrusted and arrive before authentication; a server that
    /// sends one per request would otherwise drive the person's screen.
    static let maxBannerCount = 8

    private func offerNext(
        allowedBy methods: NIOSSHAvailableUserAuthenticationMethods,
        promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while !remainingOffers.isEmpty {
            let credential = remainingOffers.removeFirst()
            switch credential {
            case .password(let password):
                guard methods.contains(.password) else { continue }
                hasOfferedCredential = true
                promise.succeed(makeOffer(.password(.init(password: password))))
                return
            case .privateKey(let privateKey):
                guard methods.contains(.publicKey) else { continue }
                hasOfferedCredential = true
                promise.succeed(makeOffer(.privateKey(.init(privateKey: privateKey))))
                return
            case .askedPassword:
                guard methods.contains(.password), let interaction else { continue }
                let request = SSHPasswordRequest(username: username, host: host, banner: lastBanner)
                let loop = promise.futureResult.eventLoop
                interaction.password(for: request) { password in
                    loop.execute { self.answerAsked(password, allowedBy: methods, promise: promise) }
                }
                return
            }
        }
        // Nothing left to offer. Failing the promise ends authentication, which
        // is the only way to report it: succeeding with nil would leave the
        // connection waiting on an offer that never comes.
        let refusal: SSHCarrierError =
            hasPersonDeclined
            ? .authenticationCancelled
            : hasOfferedCredential ? .authenticationExhausted : .noAcceptedMethod
        authenticationRefused()
        promise.fail(refusal)
    }

    private func answerAsked(
        _ password: String?,
        allowedBy methods: NIOSSHAvailableUserAuthenticationMethods,
        promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !endLock.withLock({ hasEnded }) else {
            promise.fail(SSHCarrierError.authenticationCancelled)
            return
        }
        guard let password else {
            hasPersonDeclined = true
            offerNext(allowedBy: methods, promise: promise)
            return
        }
        hasOfferedCredential = true
        promise.succeed(makeOffer(.password(.init(password: password))))
    }

    private func makeOffer(_ offer: NIOSSHUserAuthenticationOffer.Offer) -> NIOSSHUserAuthenticationOffer {
        NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer)
    }

    private let username: String
    private let host: String
    private let interaction: SSHAuthenticationInteraction?
    private let authenticationRefused: @Sendable () -> Void
    private let signInBegan: @Sendable () -> Void
    private let connectionID = UUID()
    private var remainingOffers: [SSHCredential]
    private var hasOfferedNone = false
    private var hasOfferedCredential = false
    private var hasPersonDeclined = false
    private var bannerCount = 0
    private var lastBanner: SSHAuthenticationBanner?
    private let endLock = NSLock()
    private var hasEnded = false
}

/// What a carrier reports when it cannot proceed.
///
/// Host-key refusals are not here: the validator throws the app's own error,
/// because the verdict behind it is Core's and the wording around it is the
/// app's.
public enum SSHCarrierError: Error, Sendable {
    /// Every credential the server's list allowed was offered, and none was
    /// accepted.
    case authenticationExhausted

    /// The server asked for a password and the person declined to give one.
    case authenticationCancelled

    /// The server refused `none` and listed no method this connection has an
    /// offer for, so nothing was offered and nobody was asked.
    case noAcceptedMethod

    /// The presented host key did not decode, so there are no bytes to judge.
    /// Refused rather than passed on, since an unreadable key is not a trusted
    /// one.
    case hostKeyUnreadable

    /// The server presented a different key than the one pinned for this
    /// endpoint. Distinct from `hostKeyUnreadable` because the two call for
    /// opposite handling: an unreadable key is a transport fault, and a changed
    /// one is the case pinning exists to catch.
    case hostKeyMismatched
}

/// The carrier's close reason is a note for status UI, so these describe
/// themselves.
///
/// Without this a caller reaches `localizedDescription`, which for a plain
/// Swift error is "The operation couldn't be completed. (… error 0.)" — a
/// sentence that names the ordinal of a case instead of what went wrong, and
/// which a person reading a failed connection cannot act on.
extension SSHCarrierError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .authenticationExhausted:
            return "The server refused the password or key for this host."
        case .authenticationCancelled:
            return "Sign-in was canceled."
        case .noAcceptedMethod:
            return "The server doesn’t accept any sign-in method saved for this host."
        case .hostKeyUnreadable:
            return "The server sent a host key Ubiquitty can’t read, so its identity couldn’t be verified."
        case .hostKeyMismatched:
            return "The server’s host key doesn’t match the one saved for this host."
        }
    }

    public var errorDescription: String? { description }
}
