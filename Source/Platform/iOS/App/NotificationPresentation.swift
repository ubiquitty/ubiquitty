// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation
import UbiquittyCore
import UserNotifications

/// The facts a banner request carries, read from the platform's payload, and
/// the producer Core decides stands behind it.
///
/// Reading is this file's part: property-list scalars come back as NSNumber,
/// and one that is a Boolean, negative, fractional or past its width is refused
/// here so that no lossy conversion reaches Core. Whether the request names a
/// retained event or a live attachment, and whether it is shown, is Core's
/// (`OSC.decideBannerOrigin`, `OSC.isBannerPresented`).
nonisolated struct NotificationPresentationOrigin: Sendable {
    /// The payload key naming the saved host.
    static let hostKey = "hostID"
    /// The payload key naming a refresh permission.
    static let permissionKey = "permissionID"
    /// The payload key naming a live model incarnation.
    static let incarnationKey = "liveModelID"
    /// The payload key naming a live daemon instance.
    static let daemonKey = "daemonID"
    /// The payload key naming the host's session.
    static let sessionKey = "sessionID"
    /// The payload key carrying the program's occasion.
    static let occasionKey = "occasion"

    /// A live attachment's identity, as its model posts it.
    struct Live: Sendable {
        /// The saved host the model is attached for.
        let hostID: UUID
        /// The model's attachment incarnation, renewed on every detach.
        let incarnationID: UUID
        /// The daemon instance the session lives in.
        let daemonID: UInt64
        /// The host's session that raised the banner.
        let sessionID: UInt32
        /// When the program wanted it shown.
        let occasion: Ubiquitty.NotificationOccasion

        /// The identifier prefix Core assigns this attachment's banners.
        var prefix: String {
            String(Ubiquitty.OSC.liveBannerPrefix(std.string(hostID.uuidString), std.string(incarnationID.uuidString)))
        }

        /// The payload a live banner carries back to the app.
        var userInfo: [AnyHashable: Any] {
            [
                NotificationPresentationOrigin.hostKey: hostID.uuidString,
                NotificationPresentationOrigin.incarnationKey: incarnationID.uuidString,
                NotificationPresentationOrigin.daemonKey: String(daemonID),
                NotificationPresentationOrigin.sessionKey: sessionID,
                NotificationPresentationOrigin.occasionKey: occasion.rawValue,
            ]
        }
    }

    /// Who Core decided stands behind the request.
    let origin: Ubiquitty.OSC.BannerOrigin
    /// When the program wanted it shown.
    let occasion: Ubiquitty.NotificationOccasion
    /// The saved host the request names.
    let hostID: UUID
    /// The refresh permission, for a retained event.
    let permissionID: UUID?
    /// The model incarnation, for a live event.
    let incarnationID: UUID?
    /// The daemon instance, zero for a retained event.
    let daemonID: UInt64
    /// The host's session that raised the event.
    let sessionID: UInt32

    /// Reads a request handed back by the system; nil when Core refuses it.
    ///
    /// - Parameter request: The delivered or presented request.
    init?(request: UNNotificationRequest) {
        let information = request.content.userInfo
        guard let hostID = Self.identifier(information[Self.hostKey]) ?? nil,
            let permissionID = Self.identifier(information[Self.permissionKey]),
            let incarnationID = Self.identifier(information[Self.incarnationKey]),
            let daemonID = Self.daemon(information[Self.daemonKey]),
            let sessionID = Self.unsigned(information[Self.sessionKey]),
            let occasion = Self.unsigned(information[Self.occasionKey])
        else { return nil }
        var facts = Ubiquitty.OSC.BannerOriginFacts()
        facts.identifier = std.string(request.identifier)
        facts.host = std.string(hostID.uuidString)
        facts.permission = std.string(permissionID?.uuidString ?? "")
        facts.incarnation = std.string(incarnationID?.uuidString ?? "")
        facts.daemon = daemonID
        facts.session = sessionID
        facts.occasion = occasion
        let decision = Ubiquitty.OSC.decideBannerOrigin(facts)
        guard decision.origin != .Refused else { return nil }
        self.origin = decision.origin
        self.occasion = decision.occasion
        self.hostID = hostID
        self.permissionID = permissionID
        self.incarnationID = incarnationID
        self.daemonID = daemonID
        self.sessionID = sessionID
    }

    /// The live attachment the request names, for a live event.
    var live: Live? {
        guard origin == .Live, let incarnationID else { return nil }
        return Live(hostID: hostID, incarnationID: incarnationID, daemonID: daemonID, sessionID: sessionID, occasion: occasion)
    }

    /// How the system shows the request while the app is in front.
    ///
    /// - Parameters:
    ///   - isRetainedCurrent: Whether the named refresh permission is still the
    ///     host's.
    ///   - retainedAudience: The audience of the pane showing the named
    ///     session, or nil when no live model draws it.
    ///   - liveAudience: The audience of the named live attachment's pane, or
    ///     nil once that attachment is retired.
    /// - Returns: The presentation options.
    @MainActor
    func options(
        isRetainedCurrent: (_ hostID: UUID, _ permissionID: UUID) -> Bool,
        retainedAudience: (_ hostID: UUID, _ sessionID: UInt32) -> Ubiquitty.OSC.BannerAudience?,
        liveAudience: (Live) -> Ubiquitty.OSC.BannerAudience?
    ) -> UNNotificationPresentationOptions {
        let isCurrent: Bool
        let audience: Ubiquitty.OSC.BannerAudience?
        if let live {
            audience = liveAudience(live)
            isCurrent = audience != nil
        } else if let permissionID {
            isCurrent = isRetainedCurrent(hostID, permissionID)
            audience = retainedAudience(hostID, sessionID)
        } else {
            return []
        }
        var decision = Ubiquitty.OSC.BannerOriginDecision()
        decision.origin = origin
        decision.occasion = occasion
        let isPresented = Ubiquitty.OSC.isBannerPresented(decision, isCurrent, audience ?? Ubiquitty.OSC.BannerAudience())
        return isPresented ? [.banner, .list] : []
    }

    /// Reads an identifier field: an absent key is a present nil, a malformed
    /// one refuses the request.
    private static func identifier(_ value: Any?) -> UUID?? {
        guard let value else { return .some(nil) }
        guard let text = value as? String, let identifier = UUID(uuidString: text) else { return nil }
        return .some(identifier)
    }

    /// Reads the daemon field, zero when absent; a malformed one refuses.
    private static func daemon(_ value: Any?) -> UInt64? {
        guard let value else { return 0 }
        guard let text = value as? String, let daemon = UInt64(text) else { return nil }
        return daemon
    }

    /// Reads a scalar only when the property list kept it exactly.
    private static func unsigned(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt32(number.stringValue)
    }
}

/// Answers iOS's foreground presentation question for the app delegate.
///
/// With C++ interoperability on, Swift reads the requirement's options type
/// differently from the protocol's, so a method on the delegate only nearly
/// matches it, takes no selector, and iOS finds nothing to ask: every
/// foreground banner is dropped. This object owns the selector outright,
/// with the options at their Objective-C width, and the delegate forwards the
/// selector here. The request is read where it arrives; the decision is the
/// main actor's.
final class NotificationForegroundResponder: NSObject, Sendable {
    /// The Objective-C selector iOS sends for a foreground presentation.
    static let selector = NSSelectorFromString("userNotificationCenter:willPresentNotification:withCompletionHandler:")

    /// Decides how iOS shows a request while the app is in front.
    ///
    /// - Parameters:
    ///   - center: The notification center asking.
    ///   - notification: The notification about to be presented.
    ///   - completionHandler: Takes the presentation options' raw value.
    @objc(userNotificationCenter:willPresentNotification:withCompletionHandler:)
    nonisolated func present(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UInt) -> Void
    ) {
        let origin = NotificationPresentationOrigin(request: notification.request)
        Task { @MainActor in
            let options = origin.map { BackgroundRefreshCoordinator.shared.presentationOptions(for: $0) } ?? []
            completionHandler(options.rawValue)
        }
    }
}
