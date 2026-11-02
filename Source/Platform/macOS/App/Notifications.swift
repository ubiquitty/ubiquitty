// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Notifications.swift — the macOS post of a banner Core composed.
//
// Core decides everything a person reads or does not read: what the banner
// says and in which slot (`OSC::composeBanner`), where it says the session is
// (`Session::describeBannerPlace`), whether it is posted at all
// (`OSC::isBannerWanted`, `Modes::bellWantsNotification`) and which earlier
// banner it replaces (`OSC::bannerRequestIdentifier`). This translates the
// answer into a UNNotificationRequest, respecting the `[notifications]` config
// gate, a per-window rate bound and the OS authorization grant. Authorization
// is requested once at launch. Each request is tagged with the originating
// window and pane so a click returns to them.
//
// Thread-safety: `post` may be called off the main thread, so this type is not
// @MainActor — the config gate is sampled on the caller's thread (a benign
// Settings snapshot) and the UserNotifications work is marshalled to main
// internally.
//

import Foundation
internal import UbiquittyCore
import UserNotifications

@objc(UBNotifications)
public final class Notifications: NSObject {
    // userInfo key carrying the originating NSWindow.windowNumber so a banner
    // click can reactivate the right window.
    private static let windowNumberKey = "UBWindowNumber"

    // userInfo key carrying the originating pane id (UBPane.paneID) within that
    // window so a banner click can also select the pane's tab and focus the exact
    // split pane that posted — not just whatever pane happens to be frontmost.
    // Absent / Layout::invalidPane (0) means "no specific pane" and the click
    // handler falls back to raising the window only.
    private static let paneIdentifierKey = "UBPaneIdentifier"

    // Ask UNUserNotificationCenter for alert/sound authorization. Idempotent
    // and async; call once from applicationDidFinishLaunching. A denied or
    // undetermined grant makes `post` a silent no-op.
    @objc
    public static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(
                options: [.alert, .sound]
            ) { _, _ in
                // A denial just makes the OS drop the post; nothing to do here.
            }
    }

    /// What raised a banner; each kind keeps its own standing banner per pane.
    package enum Source: Sendable {
        /// A program's notification, or a trigger rule's.
        case program
        /// A bell nobody was looking at.
        case bell
        /// A consent request whose sheet nobody can see.
        case consent

        fileprivate var core: Ubiquitty.OSC.BannerSource {
            switch self {
            case .program: .Program
            case .bell: .Bell
            case .consent: .Consent
            }
        }
    }

    /// One banner as the system is asked for it: its three slots, where a
    /// click returns to, and the identifiers it is posted and grouped under.
    ///
    /// A value, so what would be posted can be read without posting it — a
    /// delivered banner is the notification centre's to read back, not this
    /// process's.
    package struct Request: Equatable, Sendable {
        /// The heading.
        package var title: String
        /// The line beneath the heading, or empty.
        package var subtitle = ""
        /// The running text, or empty.
        package var body = ""
        /// The window a click raises, as `NSWindow.windowNumber`.
        package var windowNumber: Int
        /// The pane a click focuses, or 0 (`Layout::invalidPane`) for an event
        /// of the window itself.
        package var paneID: Int
        /// What raised it.
        package var source: Source
        /// The program's own name for the notification (OSC 99 `i=`), or
        /// empty: one under a name used before replaces that one, and two
        /// under different names both stand.
        package var name = ""

        /// The identifier the request is posted under: Core's, stable per
        /// pane, source and name, so this banner replaces the pane's last one
        /// under that name.
        package var identifier: String {
            String(
                Ubiquitty.OSC.bannerRequestIdentifier(
                    source.core,
                    std.string(String(windowNumber)),
                    UInt64(max(0, paneID)),
                    std.string(name)
                )
            )
        }

        /// The identifier the system groups it under: Core's, per window.
        package var threadIdentifier: String {
            String(Ubiquitty.OSC.bannerThreadIdentifier(std.string(String(windowNumber))))
        }

        /// Creates a request.
        package init(
            title: String,
            subtitle: String = "",
            body: String = "",
            windowNumber: Int,
            paneID: Int,
            source: Source,
            name: String = ""
        ) {
            self.title = title
            self.subtitle = subtitle
            self.body = body
            self.windowNumber = windowNumber
            self.paneID = paneID
            self.source = source
            self.name = name
        }

        /// The content the system is handed for this request.
        ///
        /// - Parameter playsSound: Whether the banner plays the default sound.
        /// - Returns: The content, tagged with the window and pane.
        package func content(playsSound: Bool) -> UNMutableNotificationContent {
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = subtitle
            content.body = body
            if playsSound {
                content.sound = .default
            }
            content.userInfo = [Notifications.windowNumberKey: windowNumber, Notifications.paneIdentifierKey: paneID]
            content.threadIdentifier = threadIdentifier
            return content
        }
    }

    /// Posts a banner, replacing the one the same pane and source left standing.
    ///
    /// A request with no heading is dropped. No-ops when notifications are
    /// disabled in config. Safe on any thread.
    ///
    /// - Parameter request: The banner, as Core composed it.
    package static func post(_ request: Request) {
        guard Ubiquitty.Preferences.Effective.notifications(Ubiquitty.Preferences.values().pointee) else { return }

        // A notification is posted from the ingest thread for every OSC 9, 99 or
        // 777 in the byte stream, and nothing in the sequence bounds how often
        // one arrives. Anything the terminal displays can therefore ask for a
        // banner in a loop: a file catted to the screen, a compromised remote.
        // Without a bound that is thousands of main-queue blocks and notification
        // requests a second — the terminal's own main thread spent on it, and a
        // Notification Center the person has to empty by hand.
        //
        // The bound is per window, checked here on the calling thread, so a
        // flood costs one lock and a comparison rather than a hop. What is
        // dropped is not announced: a banner saying how many banners were
        // suppressed is another banner, which is what the sender wanted.
        guard allowPost(windowNumber: request.windowNumber) else { return }

        guard !request.title.isEmpty else { return }

        let playsSound = Ubiquitty.Preferences.Effective.notificationSound(Ubiquitty.Preferences.values().pointee)

        let deliver: @Sendable () -> Void = {
            // Adding a request under an identifier a delivered one holds
            // replaces that one, in the list and on screen.
            let posted = UNNotificationRequest(
                identifier: request.identifier,
                content: request.content(playsSound: playsSound),
                trigger: nil
            ) // deliver now
            UNUserNotificationCenter.current().add(posted)
        }

        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    /// Banners one window may post per second before the rest are dropped.
    ///
    /// High enough that a build finishing, a test suite ending and a message
    /// arriving together all land; low enough that a loop emitting the sequence
    /// gets one of them.
    private static let postsPerWindowPerSecond = 3.0

    /// The most a window can bank by staying quiet, so a burst after a long
    /// silence is delivered whole rather than trickled.
    private static let maxBankedPosts = 6.0

    private static let postBudgetLock = NSLock()
    // Every read and write of postBudget holds postBudgetLock; the compiler
    // cannot see that pairing across allowPost/forgetPostBudget.
    private nonisolated(unsafe) static var postBudget: [Int: (tokens: Double, at: Date)] = [:]

    /// Answers whether a window may post now, spending its allowance if so.
    ///
    /// Called on whichever thread the sequence arrived on, which is the ingest
    /// thread — before the main-queue hop, because the hop is most of what a
    /// flood costs.
    ///
    /// - Parameter windowNumber: The posting window.
    /// - Returns: Whether to deliver this one.
    private static func allowPost(windowNumber: Int) -> Bool {
        let now = Date()
        postBudgetLock.lock()
        defer { postBudgetLock.unlock() }
        var entry = postBudget[windowNumber] ?? (tokens: maxBankedPosts, at: now)
        let elapsed = max(0, now.timeIntervalSince(entry.at))
        entry.tokens = min(maxBankedPosts, entry.tokens + elapsed * postsPerWindowPerSecond)
        entry.at = now
        guard entry.tokens >= 1 else {
            postBudget[windowNumber] = entry
            return false
        }
        entry.tokens -= 1
        postBudget[windowNumber] = entry
        return true
    }

    /// Forgets a window's allowance once it is gone.
    ///
    /// - Parameter windowNumber: The window that closed.
    @objc
    public static func forgetPostBudget(windowNumber: Int) {
        postBudgetLock.lock()
        postBudget.removeValue(forKey: windowNumber)
        postBudgetLock.unlock()
    }

    // The window number embedded in a delivered notification's userInfo, or
    // NSNotFound when absent. The app delegate's UNUserNotificationCenterDelegate
    // click handler uses this to find and activate the target window.
    @objc
    public static func windowNumber(for notification: UNNotification) -> Int {
        if let number = notification.request.content.userInfo[windowNumberKey] as? Int {
            return number
        }
        return NSNotFound
    }

    // The originating pane id embedded in a delivered notification's userInfo, or
    // NSNotFound when absent (an older banner, or a window-level post that carried
    // none). The app delegate's click handler, after raising the window, uses this
    // to select the pane's tab and focus the exact split pane that posted; a
    // missing / 0 (Layout::invalidPane) id falls back to raising the window only.
    @objc
    public static func paneID(for notification: UNNotification) -> Int {
        if let identifier = notification.request.content.userInfo[paneIdentifierKey] as? Int {
            return identifier
        }
        return NSNotFound
    }
}
