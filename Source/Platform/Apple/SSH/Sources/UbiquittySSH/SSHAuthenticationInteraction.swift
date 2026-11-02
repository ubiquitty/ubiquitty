// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// What a connection asks of the person while it signs in, and what it shows
// them.
//
// A server may need the person in two ways. It may list `password`, which
// nothing saved answers, so the person is asked once; or it may hold a
// request open while the person approves the sign-in somewhere else, which
// is how Tailscale's check mode works: it holds the `none` request and sends
// an auth banner carrying a URL to open. Both are waits on the person, and a
// deadline that would end the connection while one is open would end it
// for the person being slow rather than the server being gone.
//
// One interaction belongs to one session, not one connection: a session opens
// several SSH connections — a QUIC bootstrap ask, the Sync carrier, every
// reconnect — and the person answers once for all of them.

import Foundation

/// A banner the server sent while the connection was signing in.
public struct SSHAuthenticationBanner: Sendable, Equatable {
    /// The server's text, with control characters removed and its length
    /// bounded.
    public let message: String

    /// The first `https` link in the text, when there is one.
    ///
    /// A link in a banner is an instruction, such as the page that approves a
    /// Tailscale check, and the server holds the sign-in until it is answered.
    public let link: URL?

    /// The longest message kept, in characters.
    ///
    /// The banner is untrusted text arriving before authentication; a server
    /// that sends megabytes of it gets the start of it.
    public static let maxMessageLength = 2048

    /// Reads a banner from the server's text.
    ///
    /// - Parameter text: The banner as the server sent it.
    public init(serverText text: String) {
        let kept = text.unicodeScalars.filter(Self.isDisplayable)
        var message = String(String.UnicodeScalarView(kept))
        if message.count > Self.maxMessageLength {
            message = String(message.prefix(Self.maxMessageLength))
        }
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = message
        self.link = Self.firstSecureLink(in: message)
    }

    /// Whether a scalar is shown: printable text, line breaks and tabs, and
    /// not a control that reorders or hides what surrounds it.
    private static func isDisplayable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned:
            return false
        default:
            return true
        }
    }

    private static func firstSecureLink(in message: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(message.startIndex..., in: message)
        for match in detector.matches(in: message, range: range) {
            if let url = match.url, url.scheme?.lowercased() == "https", url.host != nil {
                return url
            }
        }
        return nil
    }
}

/// What the person is asked when the server lists `password` and nothing
/// saved answered it.
public struct SSHPasswordRequest: Sendable, Equatable {
    /// The account being signed in to.
    public let username: String

    /// The host as it was dialled.
    public let host: String

    /// The last banner the server sent before asking, which is the only text
    /// of its own the `password` method carries.
    public let banner: SSHAuthenticationBanner?

    public init(username: String, host: String, banner: SSHAuthenticationBanner?) {
        self.username = username
        self.host = host
        self.banner = banner
    }
}

/// The person on the other side of a session's sign-in.
///
/// Every call can arrive on any thread; an implementation marshals to its UI.
public protocol SSHAuthenticationPerson: AnyObject, Sendable {
    /// Asks the person for a password.
    ///
    /// Called at most once per interaction, whatever the number of connections
    /// that need it.
    ///
    /// - Parameters:
    ///   - request: Who is signing in where, and what the server said.
    ///   - answer: Takes the password, or nil when the person declined. Called
    ///     once.
    func askForPassword(_ request: SSHPasswordRequest, answer: @escaping @Sendable (String?) -> Void)

    /// Shows a banner the server sent.
    ///
    /// A banner with a link holds the sign-in until the server answers; one
    /// without is text the server wanted read.
    func show(_ banner: SSHAuthenticationBanner)

    /// No connection is held on a banner's link any longer: the server
    /// answered, or the connection ended.
    func bannerWaitEnded()
}

/// Asks the person at most once for one session, and says whether any of its
/// connections is waiting on them.
public final class SSHAuthenticationInteraction: @unchecked Sendable {
    /// Creates an interaction that reaches the person through `person`.
    ///
    /// - Parameter person: Held strongly, for the session's life.
    public init(person: SSHAuthenticationPerson) {
        self.person = person
    }

    /// Whether a connection is waiting on the person: a password is being
    /// asked for, or a banner's link has not been answered yet.
    ///
    /// A deadline that guards a connection against a silent server reads this
    /// before it gives up, because the silence is the person's.
    public var isWaitingOnPerson: Bool {
        lock.withLock {
            if case .asking = passwordState { return true }
            return !heldConnections.isEmpty
        }
    }

    /// Hands back the session's password, asking the person only the first
    /// time.
    ///
    /// Concurrent callers share the one ask. A declined ask stays declined for
    /// the session, so a reconnect does not ask again for what the person
    /// refused to give.
    func password(for request: SSHPasswordRequest, answer: @escaping @Sendable (String?) -> Void) {
        enum Step {
            case ask
            case wait
            case answer(String?)
        }
        let step: Step = lock.withLock {
            switch passwordState {
            case .unasked:
                passwordState = .asking([answer])
                return .ask
            case .asking(var waiting):
                waiting.append(answer)
                passwordState = .asking(waiting)
                return .wait
            case .answered(let password):
                return .answer(password)
            }
        }
        switch step {
        case .ask:
            person.askForPassword(request) { [weak self] password in
                self?.settlePassword(password)
            }
        case .wait:
            break
        case .answer(let password):
            answer(password)
        }
    }

    private func settlePassword(_ password: String?) {
        let waiting: [@Sendable (String?) -> Void] = lock.withLock {
            guard case .asking(let waiting) = passwordState else { return [] }
            passwordState = .answered(password)
            return waiting
        }
        for answer in waiting { answer(password) }
    }

    /// Shows a banner one connection received.
    ///
    /// - Parameters:
    ///   - banner: The banner.
    ///   - connection: The connection it arrived on, held until it ends its
    ///     sign-in when the banner carries a link.
    func show(_ banner: SSHAuthenticationBanner, on connection: UUID) {
        if banner.link != nil {
            lock.withLock { _ = heldConnections.insert(connection) }
        }
        person.show(banner)
    }

    /// Releases a connection that signed in, was refused, or closed.
    func endSignIn(on connection: UUID) {
        let wasLastHold: Bool = lock.withLock {
            heldConnections.remove(connection) != nil && heldConnections.isEmpty
        }
        if wasLastHold { person.bannerWaitEnded() }
    }

    private enum PasswordState {
        case unasked
        case asking([@Sendable (String?) -> Void])
        case answered(String?)
    }

    private let person: SSHAuthenticationPerson
    private let lock = NSLock()
    private var passwordState = PasswordState.unasked
    private var heldConnections: Set<UUID> = []
}
