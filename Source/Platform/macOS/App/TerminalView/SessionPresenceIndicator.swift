// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// SessionPresenceIndicator.swift — who else is on this session, and what the
// reader can do about it.
//
// A session can carry more than one client: another window of the user's own,
// a person the session was shared with, or an agent that was let in. All of
// them see the screen and can type into it, and none of them is visible from
// the screen itself. That is the same class of fact the clipboard badge exists
// for — something the user allowed, which they are still entitled to see.
//
// Unreviewed screen access keeps the badge amber after the reader leaves.
// Opening its activity list reviews only the records that list contained.
//
// The badge is a button wherever there is something to do: an agent can be
// disconnected, and the grant that let it in can be dropped, so a roster with
// an agent on it pops a menu and a roster of people alone does not. Every one
// of those items ships the same revoke the Session menu and Beam ship, because
// they are one call — the daemon's gates apply to it and not to the menu that
// sent it.

@preconcurrency import AppKit

/// The presence badge in a window's accessory bar or a pane's title.
@objc(UBSessionPresenceIndicator)
public final class SessionPresenceIndicator: NSButton {
    /// Posted when a window's roster changed.
    ///
    /// The object is the window, so a badge updates for its own session:
    /// presence is a property of one connection, and two windows on two hosts
    /// have two answers.
    @objc
    public static let didChangeNotification = Notification.Name("UBSessionPresenceDidChange")

    /// Left of the clipboard badge, which is left of the lock. The lock states
    /// the strongest fact and keeps the edge.
    @objc
    public static let priority = 80

    private weak var bar: ChromeAccessoryBar?
    private var observer: (any NSObjectProtocol)?

    /// A split pane's title can show the roster while the window menu keeps it.
    package var showsBadge = true {
        didSet {
            bar?.setShown(self, showsBadge && hasVisibleActivity)
            bar?.relayout()
        }
    }

    /// How many others are on this session, as last reported.
    public private(set) var otherAttendeeCount = 0

    /// How many of those others are agents rather than people.
    public private(set) var agentCount = 0

    /// Everyone on the session, in the host's order, as last reported.
    public private(set) var roster: [RuntimeDrive.Attendee] = []
    /// Recent host-reported reads, retained independently of the live roster.
    public private(set) var screenAccesses: [RuntimeDrive.ScreenAccess] = []
    /// Whether the user has yet to open the newest activity list.
    public private(set) var hasUnreadScreenAccess = false
    package var hasVisibleActivity: Bool { otherAttendeeCount > 0 || hasUnreadScreenAccess }
    /// Reviews only the cursor displayed when a list opens.
    public var acknowledgeScreenAccess: ((UInt64) -> Void)?

    /// Where a revoke chosen from the roster goes.
    ///
    /// Set by the window, which owns the session the roster describes. Every
    /// item in the menu — the three per-agent scopes and Disconnect All —
    /// arrives here, so the pill has one way to act and it is the way Beam and
    /// the Session menu act too.
    public var revoke: ((RuntimeDrive.RevokeAction, String, String) -> Void)?

    /// Puts a badge into a bar, hidden until a session says otherwise.
    ///
    /// - Parameter bar: The window's accessory bar.
    /// - Returns: The installed badge.
    @objc
    @discardableResult
    public static func install(in bar: ChromeAccessoryBar) -> SessionPresenceIndicator {
        let indicator = SessionPresenceIndicator(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        indicator.bar = bar
        indicator.isHidden = true
        bar.add(indicator, priority: priority)
        indicator.observer = NotificationCenter.default.addObserver(
            forName: didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak indicator] notification in
            // The notification stays out of the isolated block: only Sendable
            // values cross into it.
            let notificationObject = notification.object
            let isBroadcast = notificationObject == nil
            let notifiedWindowIdentifier = (notificationObject as? NSWindow).map(ObjectIdentifier.init)
            let attendees = notification.userInfo?[rosterKey] as? [RuntimeDrive.Attendee]
            let accesses = notification.userInfo?[screenAccessesKey] as? [RuntimeDrive.ScreenAccess] ?? []
            let hasUnread = notification.userInfo?[hasUnreadKey] as? Bool ?? false
            MainActor.assumeIsolated {
                guard let indicator, let bar = indicator.bar else { return }
                // This window's own notification only: showing one window's
                // user the other window's roster would be worse than showing
                // nothing, because they would act on it.
                guard isBroadcast || notifiedWindowIdentifier == indicator.window.map(ObjectIdentifier.init) else {
                    return
                }
                guard let attendees else { return }
                indicator.apply(attendees, screenAccesses: accesses, hasUnread: hasUnread)
                bar.setShown(indicator, indicator.showsBadge && indicator.hasVisibleActivity)
                bar.relayout()
            }
        }
        return indicator
    }

    /// Reports a window's roster to whichever badge is showing it.
    ///
    /// The roster whole rather than a count, because what the badge offers
    /// depends on who is on it: an agent carries revoke scopes keyed to the
    /// grant it holds, and a person carries nothing to do.
    ///
    /// - Parameters:
    ///   - attendees: Everyone attached, this client included, as Core reports
    ///     them.
    ///   - window: The window whose session changed.
    public static func report(
        _ attendees: [RuntimeDrive.Attendee],
        screenAccesses: [RuntimeDrive.ScreenAccess] = [],
        hasUnread: Bool = false,
        for window: NSWindow?
    ) {
        NotificationCenter.default.post(
            name: didChangeNotification,
            object: window,
            userInfo: [rosterKey: attendees, screenAccessesKey: screenAccesses, hasUnreadKey: hasUnread]
        )
    }

    /// The key the roster rides under.
    ///
    /// `nonisolated` because the notification block reads it before entering
    /// the isolated one — an actor-isolated constant read from a Sendable
    /// closure is a warning, and a second literal spelling of the key is worse
    /// than the warning.
    private nonisolated static let rosterKey = "roster"
    private nonisolated static let screenAccessesKey = "screenAccesses"
    private nonisolated static let hasUnreadKey = "hasUnreadScreenAccess"

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleProportionallyDown
        isBordered = false
        imagePosition = .imageLeft
        font = .systemFont(ofSize: 11, weight: .medium)
        title = ""
        target = self
        action = #selector(showRosterMenu)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        apply([])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SessionPresenceIndicator is built in code")
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Draws a roster, with words that say what it means rather than what it
    /// counts.
    ///
    /// - Parameter attendees: Everyone attached, this client included.
    package func apply(_ attendees: [RuntimeDrive.Attendee], screenAccesses: [RuntimeDrive.ScreenAccess] = [], hasUnread: Bool = false) {
        roster = attendees
        self.screenAccesses = screenAccesses
        hasUnreadScreenAccess = hasUnread
        let others = attendees.filter { !$0.isSelf }
        otherAttendeeCount = others.count
        agentCount = others.filter { !$0.isHuman }.count
        guard hasVisibleActivity else {
            image = nil
            title = ""
            toolTip = nil
            setAccessibilityLabel(nil)
            isEnabled = false
            sizeToFit()
            return
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        // Two people and a crowd read differently at a glance, which is the
        // only distinction worth drawing here.
        let symbol = otherAttendeeCount <= 1 ? "person.2.fill" : "person.3.fill"
        image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: hasUnread ? "Recent screen access" : "Others are attached to this session"
        )?
        .withSymbolConfiguration(configuration)
        // An agent's count is the number worth carrying, and the accent says
        // the badge can be acted on. A roster of people alone is a fact, not a
        // control: secondary, unlabelled, and with nothing to press — sharing
        // is a thing the user arranged, and a badge that shouts at every shared
        // session trains people past the one that matters.
        title = agentCount > 0 ? " \(agentCount)" : ""
        contentTintColor = hasUnread ? .systemOrange : agentCount > 0 ? .controlAccentColor : .secondaryLabelColor
        isEnabled = agentCount > 0 || !screenAccesses.isEmpty
        let who = otherAttendeeCount == 1 ? "One other client is" : "\(otherAttendeeCount) other clients are"
        let seeing = "\(who) attached to this session. They see this screen and can type into it."
        toolTip = agentCount > 0 ? "\(seeing) Click to manage the agents." : seeing
        if hasUnread {
            toolTip = "An agent read this screen. Open the activity list to review who accessed it."
        }
        setAccessibilityLabel(
            hasUnread
                ? "Unreviewed screen access"
                : otherAttendeeCount == 1 ? "One other client attached" : "\(otherAttendeeCount) other clients attached"
        )
        // A titlebar accessory lays out against its view's frame, and this one
        // changes width as the count appears, so it is measured on every show.
        sizeToFit()
    }

    /// The roster as a menu: everyone on the session, and for each agent the
    /// revoke scopes its grant makes real.
    ///
    /// Built fresh on every show, because a roster held from the last one
    /// would offer a scope the daemon has since dropped.
    ///
    /// - Parameter activitySubmenu: Keep review attached to a submenu when the application copies the roster items.
    /// - Returns: The menu.
    public func rosterMenu(activitySubmenu: Bool = false) -> NSMenu {
        let menu = ScreenActivityMenu(title: "Session")
        let activity = activitySubmenu ? ScreenActivityMenu(title: "Recent Screen Access") : menu
        let acknowledge = acknowledgeScreenAccess
        let displayedCursor = screenAccesses.last?.cursor
        activity.review = {
            if let displayedCursor { acknowledge?(displayedCursor) }
        }
        menu.autoenablesItems = false
        if !screenAccesses.isEmpty {
            let header = NSMenuItem(title: "Recent Screen Access", action: nil, keyEquivalent: "")
            header.isEnabled = false
            activity.addItem(header)
            for access in screenAccesses.reversed() {
                let name =
                    access.claimedLabel.isEmpty
                    ? (access.verifiedProcess.isEmpty ? "Agent" : (access.verifiedProcess as NSString).lastPathComponent)
                    : "\(access.claimedLabel) (claimed name)"
                let date = Date(timeIntervalSince1970: Double(access.unixMilliseconds) / 1000)
                let when = date.formatted(date: .abbreviated, time: .standard)
                let row = NSMenuItem(title: "\(name) — \(when)", action: nil, keyEquivalent: "")
                row.isEnabled = false
                activity.addItem(row)
            }
            if activitySubmenu {
                let item = NSMenuItem(title: "Recent Screen Access", action: nil, keyEquivalent: "")
                item.submenu = activity
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let header = NSMenuItem(title: "Connected to This Session", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for attendee in roster {
            let row = NSMenuItem(title: displayName(of: attendee), action: nil, keyEquivalent: "")
            row.image = NSImage(
                systemSymbolName: attendee.isHuman ? "person.fill" : "cpu",
                accessibilityDescription: nil
            )
            guard !attendee.isHuman else {
                // A person is not revocable: they hold the session, or they
                // were given it, and neither is undone from here.
                row.isEnabled = false
                menu.addItem(row)
                continue
            }
            let scopes = NSMenu(title: row.title)
            scopes.autoenablesItems = false
            scopes.addItem(scopeItem("Disconnect Now", .disconnectNow, attendee))
            // The two grant scopes are independent of the connection and of
            // each other, and each is offered only where the agent actually
            // holds it: an item that clears a grant nobody has says the reader
            // did something when they did not.
            if attendee.grant == .always {
                scopes.addItem(scopeItem("Stop Always Allowing This Agent", .stopAlwaysAllowing, attendee))
            }
            if attendee.grant == .session {
                scopes.addItem(scopeItem("Revoke Session Access", .clearSessionGrant, attendee))
            }
            row.submenu = scopes
            menu.addItem(row)
        }
        if agentCount > 0 {
            menu.addItem(.separator())
            let all = NSMenuItem(title: "Disconnect All Agents", action: #selector(disconnectAllAgents), keyEquivalent: "")
            all.target = self
            menu.addItem(all)
        } else {
            let none = NSMenuItem(title: "No Agents Connected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        return menu
    }

    /// One revoke scope, carrying the attendee it acts on.
    ///
    /// - Parameters:
    ///   - title: What the item says.
    ///   - action: What it revokes.
    ///   - attendee: Who it acts on.
    /// - Returns: The item.
    private func scopeItem(
        _ title: String,
        _ action: RuntimeDrive.RevokeAction,
        _ attendee: RuntimeDrive.Attendee
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(revokeFromMenu), keyEquivalent: "")
        item.target = self
        item.representedObject = RevokeRequest(action: action, attendee: attendee)
        item.isEnabled = action == .disconnectNow ? !attendee.attachmentID.isEmpty : !attendee.grantIdentity.isEmpty
        return item
    }

    /// What a chosen menu item asks for.
    private struct RevokeRequest {
        let action: RuntimeDrive.RevokeAction
        let attendee: RuntimeDrive.Attendee
    }

    /// A friendly name for a roster row.
    ///
    /// A person is named by their relation to this window. An agent prefers
    /// the label it chose, which is why the name is only ever a name here: the
    /// verified executable is what a revoke is keyed to, and it is what shows
    /// when an agent claimed nothing.
    ///
    /// The carrier follows the wire's precedence — QUIC
    /// first, then a person on the local socket, then nothing. A network peer
    /// called local would be the one surface saying who is watching this
    /// terminal telling the reader the opposite of where they are.
    ///
    /// - Parameter attendee: The row.
    /// - Returns: The name, with the carrier where it says something.
    private func displayName(of attendee: RuntimeDrive.Attendee) -> String {
        var name: String
        if attendee.isHuman {
            name = attendee.isSelf ? "You" : "Another window"
        } else if !attendee.label.isEmpty {
            name = attendee.label
        } else if !attendee.process.isEmpty {
            name = (attendee.process as NSString).lastPathComponent
        } else {
            name = "Agent"
        }
        if attendee.isQUIC {
            name += " (quic)"
        } else if attendee.isHuman {
            name += " (local)"
        }
        return name
    }

    @objc
    private func showRosterMenu() {
        let menu = rosterMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
    }

    @objc
    private func revokeFromMenu(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? RevokeRequest else { return }
        switch request.action {
        case .disconnectNow:
            revoke?(.disconnectNow, request.attendee.attachmentID, "")
        case .stopAlwaysAllowing, .clearSessionGrant:
            guard !request.attendee.grantIdentity.isEmpty else { return }
            revoke?(request.action, "", request.attendee.grantIdentity)
        case .disconnectAllAgents:
            revoke?(.disconnectAllAgents, "", "")
        }
    }

    @objc
    private func disconnectAllAgents() {
        revoke?(.disconnectAllAgents, "", "")
    }
}

/// A menu acknowledges its immutable displayed history only when it opens.
private final class ScreenActivityMenu: NSMenu, NSMenuDelegate {
    var review: (() -> Void)?

    override init(title: String) {
        super.init(title: title)
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ScreenActivityMenu is built in code")
    }

    func menuWillOpen(_ menu: NSMenu) {
        review?()
        review = nil
    }
}
