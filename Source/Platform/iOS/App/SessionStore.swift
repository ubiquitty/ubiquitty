// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// The live sessions, held above the navigation stack.
///
/// A session held as `@State` on the screen that shows it would end with the screen:
/// popping a pushed view destroys it, the model goes with it, and the carrier is torn
/// down. That is the right lifetime for a view and the wrong one for a session — "go back
/// and come back" would cost a reconnect, a fresh shell and the scrollback.
///
/// So the session outlives the view that draws it. The screen becomes a projection of a model
/// this store owns, and going back is a navigation change rather than a disconnection.
///
/// It is not a cache. Nothing here evicts, because every entry is a real connection
/// to a real host and dropping one to save memory would end a session the person believes is
/// running. Sessions leave when they are ended — by the reader, or by the host — and
/// ``end(for:)`` is the only way out.
@Observable
@MainActor
final class SessionStore {
    /// One live session per host, keyed by the host's identifier.
    private var sessions: [UUID: TerminalSessionModel] = [:]
    private var isSystemAppearanceDark = true

    func setSystemAppearance(isDark: Bool) {
        isSystemAppearanceDark = isDark
        for session in sessions.values { session.setSystemAppearance(isDark: isDark) }
    }
    @ObservationIgnored
    private var suspendedAt: ContinuousClock.Instant?
    /// Whether the host list, which shows each connected host's outline, is
    /// on screen.
    @ObservationIgnored
    private var areHostOutlinesShown = false

    /// The session for a host, made on first ask and the same one after that.
    ///
    /// The identity is what matters: returning a fresh model on the second ask would look
    /// identical on screen for a moment and then reconnect, which is the bug this type exists to
    /// remove rather than a smaller version of it.
    ///
    /// - Parameter hostID: The host's identifier.
    /// - Returns: The live session, created if this is the first ask.
    func session(for hostID: UUID) -> TerminalSessionModel {
        if let existing = sessions[hostID] {
            return existing
        }
        let created = TerminalSessionModel()
        created.savedHostID = hostID
        created.setSystemAppearance(isDark: isSystemAppearanceDark)
        created.onPasswordAccepted = { [weak self] password in self?.onPasswordAccepted?(hostID, password) }
        created.setHostOutlineShown(areHostOutlinesShown)
        BackgroundRefreshCoordinator.shared.observe(created, for: hostID)
        sessions[hostID] = created
        return created
    }

    /// Says whether the host list is on screen, so each connected host's
    /// tree is followed exactly while its outline can be seen.
    ///
    /// - Parameter isShown: Whether it is.
    func setHostOutlinesShown(_ isShown: Bool) {
        areHostOutlinesShown = isShown
        for session in sessions.values {
            session.setHostOutlineShown(isShown)
        }
    }

    /// Whether a host already has a live session.
    ///
    /// Read by a caller deciding whether to connect: a session taken from ``session(for:)`` on a
    /// return visit is already connected, and dialling it again would open a second carrier to a
    /// host that already has one.
    ///
    /// - Parameter hostID: The host's identifier.
    /// - Returns: Whether a session exists for it.
    func hasSession(for hostID: UUID) -> Bool {
        sessions[hostID] != nil
    }

    /// The sign-in prompt a session is waiting on the person for, nil when no
    /// session is.
    var pendingSignInPrompt: SignInPrompt? {
        sessions.values.lazy.compactMap(\.signInPrompt).first
    }

    /// Answers the session that raised a sign-in prompt.
    ///
    /// - Parameters:
    ///   - prompt: The prompt the person answered.
    ///   - password: The password typed, or nil when the person cancelled.
    ///   - savesPassword: Whether to keep the password once the server accepts it.
    func answerSignIn(_ prompt: SignInPrompt, with password: String?, savesPassword: Bool = false) {
        sessions.values.first { $0.signInPrompt?.id == prompt.id }?.answerSignInPrompt(password, savesPassword: savesPassword)
    }

    /// Receives a password a session's server accepted that the person asked
    /// to save, with the host it was typed for.
    @ObservationIgnored
    var onPasswordAccepted: ((UUID, String) -> Void)?

    /// Ends a host's session and forgets it.
    ///
    /// The disconnect happens here rather than in a view's teardown: a view
    /// disappearing is not a reason to end a session, and this is.
    ///
    /// - Parameter hostID: The host's identifier. A host with no session is a no-op.
    func end(for hostID: UUID) {
        guard let session = sessions.removeValue(forKey: hostID) else { return }
        session.disconnect()
    }

    /// Records the moment the app went to the background, tells every
    /// session that none of its panes is shown, and tells each host its
    /// client is about to be suspended.
    func noteSuspension() {
        suspendedAt = ContinuousClock.now
        for session in sessions.values {
            session.noteApplicationBackgrounded(true)
            session.suspendForBackground()
        }
    }

    /// Resumes every retained workspace after the app returns from the background.
    ///
    /// The time away is measured on the continuous clock, which keeps counting
    /// while the device sleeps: a phone locked for an hour has been away an
    /// hour, whatever the process saw of it.
    func resumeAfterSuspension() {
        let secondsSuspended = suspendedAt.map { (ContinuousClock.now - $0) / .seconds(1) } ?? -1
        suspendedAt = nil
        for session in sessions.values {
            session.noteApplicationBackgrounded(false)
            session.resumeAfterSuspension(secondsSuspended: secondsSuspended)
        }
    }
}
