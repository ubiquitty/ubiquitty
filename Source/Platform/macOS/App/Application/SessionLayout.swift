// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SessionLayout.swift — persisted sessions for resurrection.
//
// A session is a whole workspace: every window (a native tab group) and its
// tabs. Sessions are stored in <controlDirectory>/sessions.json; the reserved
// `SessionLayout.currentIdentifier` session is the auto-saved last layout the
// Experimental auto-restore reads, and the one an update relaunch keeps for
// the launch it opens, while named sessions are browsed and opened through the
// Connect window and the Workspaces menu. Foundation value types and
// bounded, validated JSON I/O only — no window references. See
// Docs/session-model.md.
//

import Foundation
import UbiquittyCore

/// One terminal session inside a window's tab group.
///
/// A `sessionID` of 0 means no live daemon session: restore opens a fresh shell
/// in this tab.
final class LayoutTab {
    var sessionID: UInt32 = 0
    /// Exact pane sessions adopted only to carry local PTYs across an update.
    var reclaimSessionIDsAfterUpdate: [UInt32] = []
    /// The display name, such as "local".
    var hostLabel: String?
    /// The remote shell command that reaches the host.
    var bridgeCommand: String?
    /// The daemon socket's basename, pinned on reattach.
    var socketName: String?
    var columns: UInt16 = 0
    var rows: UInt16 = 0
    /// The opaque split-pane layout, or nil for a single-pane tab. A split tab
    /// restores its geometry with fresh local panes.
    var paneLayout: String?
    /// Tag names the user set on this window by hand, restored verbatim; the
    /// rule-derived tags are recomputed and never stored.
    var tags: [String]?
}

/// One window: a native tab group holding one or more tabs.
final class LayoutGroup {
    /// The window's frame; for a window in full screen, the frame it had
    /// before it went full screen.
    var frame: NSRect = .zero
    /// Whether the window was in full screen.
    var isFullScreen = false
    /// The selected tab's index within `tabs`.
    var activeTab: Int = 0
    var tabs: [LayoutTab] = []
}

/// A named session: a whole workspace, all its windows and tabs.
final class LayoutSession {
    /// Opaque, stable and filesystem-safe.
    var identifier: String = ""
    /// The name a picker shows.
    var name: String = ""
    var groups: [LayoutGroup] = []
    /// Why the quit that saved the reserved current session kept it; every
    /// named session is `.Ordinary`.
    var keptFor: Ubiquitty.Session.QuitReason = .Ordinary
}

/// The sessions store: <controlDirectory>/sessions.json.
enum SessionLayout {
    /// The reserved session the Experimental auto-restore reads and writes.
    static let currentIdentifier = "current"

    // The reserved session's record of why the quit kept it, written only for
    // an update relaunch: an absent key is an ordinary quit's.
    private static let keptForKey = "keptFor"
    private static let keptForUpdateRelaunch = "updateRelaunch"

    // Bounds so a corrupt or hostile store cannot drive a huge or pathological
    // restore. The file is refused outright above the size cap; counts are
    // clamped on parse.
    private static let maxFileSize: UInt64 = 8 * 1024 * 1024
    private static let maxSessions = 128
    private static let maxGroups = 256
    private static let maxTabsPerGroup = 256
    private static let maxTags = 32
    private static let maxReclaimSessionsPerTab = 256
    private static let maxTagNameLength = 128

    /// The store's path, under $UBIQUITTY_HOME when it is set and ~/.ubiquitty
    /// otherwise.
    static func sessionsFilePath() -> String {
        (controlDirectory() as NSString).appendingPathComponent("sessions.json")
    }

    /// Every persisted session, validated.
    ///
    /// Every field is type-checked and every count clamped, so a corrupt or
    /// hostile file degrades to fewer sessions, or none, rather than a crash.
    ///
    /// - Returns: The sessions; empty when the file is absent, empty, oversized
    ///   or malformed.
    static func allSessions() -> [LayoutSession] {
        let path = sessionsFilePath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
            fileSize != 0, fileSize <= maxFileSize,
            let data = FileManager.default.contents(atPath: path),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let sessionArray = root["sessions"] as? [Any]
        else { return [] }

        var sessions: [LayoutSession] = []
        for sessionObject in sessionArray {
            if sessions.count >= maxSessions { break }
            guard let sessionDictionary = sessionObject as? [String: Any],
                let identifier = string(sessionDictionary["id"]), !identifier.isEmpty
            else { continue }
            let groups = groups(fromJSON: sessionDictionary["groups"])
            if groups.isEmpty { continue }
            let session = LayoutSession()
            session.identifier = identifier
            session.name = string(sessionDictionary["name"]) ?? identifier
            session.groups = groups
            if identifier == currentIdentifier, string(sessionDictionary[keptForKey]) == keptForUpdateRelaunch {
                session.keptFor = .UpdateRelaunch
            }
            sessions.append(session)
        }
        return sessions
    }

    /// Replaces the whole store with `sessions`, atomically.
    ///
    /// An empty array removes the file. The control directory is created owner-only,
    /// and the file is made owner-only: it carries host labels, bridge commands and
    /// socket names.
    ///
    /// - Parameter sessions: The sessions to keep. One with no identifier or no
    ///   groups is skipped.
    static func save(_ sessions: [LayoutSession]) throws {
        let path = sessionsFilePath()
        if sessions.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        var sessionArray: [[String: Any]] = []
        for session in sessions where !session.identifier.isEmpty && !session.groups.isEmpty {
            var dictionary: [String: Any] = ["id": session.identifier, "name": session.name, "groups": jsonArray(of: session.groups)]
            if session.identifier == currentIdentifier, session.keptFor == .UpdateRelaunch {
                dictionary[keptForKey] = keptForUpdateRelaunch
            }
            sessionArray.append(dictionary)
        }
        let root: [String: Any] = ["version": 1, "sessions": sessionArray]
        let data = try JSONSerialization.data(withJSONObject: root, options: .prettyPrinted)
        guard Ubiquitty.Session.ensureControlDirectory() else { throw SessionLayoutError.controlDirectoryUnavailable }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        // An atomic write renames a temporary file into place, which inherits the
        // process umask; the store is owner-only.
        chmod(path, 0o600)
    }

    /// Writes the reserved current session's layout, or removes it when `groups`
    /// is empty, keeping every named session.
    ///
    /// - Parameters:
    ///   - groups: The windows the quit kept.
    ///   - reason: Why the quit kept them. An update relaunch's is recorded
    ///     with the layout, which is what lets the launch the update opens
    ///     restore it with session persistence off (`takeLayoutForLaunch`).
    static func saveCurrentLayout(_ groups: [LayoutGroup], keptFor reason: Ubiquitty.Session.QuitReason = .Ordinary) {
        var kept = allSessions().filter { $0.identifier != currentIdentifier }
        if !groups.isEmpty {
            let current = LayoutSession()
            current.identifier = currentIdentifier
            current.name = "Last Session"
            current.groups = groups
            current.keptFor = reason
            kept.insert(current, at: 0)
        }
        try? save(kept)
    }

    /// The reserved current session's groups, or nil when there are none.
    static func currentLayout() -> [LayoutGroup]? {
        allSessions().first { $0.identifier == currentIdentifier }?.groups
    }

    /// The reserved current session's groups if this launch restores them,
    /// taking them from the store as it does.
    ///
    /// Whether a launch restores them is Core's, asked of why the quit kept
    /// them (`Session::isSessionKeptByQuit`): every launch with session
    /// persistence on, and with it off only an update relaunch's.
    ///
    /// The update relaunch's mark is one-shot, and this is the launch that
    /// spends it. It records one quit's promise, that the updater kept these
    /// sessions for the copy it opens next, and that launch keeps the promise
    /// by restoring them. Left in place, the mark would reopen the same
    /// arrangement at every launch after it, with persistence off, long after
    /// the person had closed those windows and ended their sessions. So the
    /// store gives the mark up before anything is restored, and a launch that
    /// fails part way does not repeat the restore at the next. With
    /// persistence off the arrangement goes with the mark: no quit since has
    /// replaced it, and a launch after persistence is turned on would reopen
    /// it. With persistence on it stays, as every quit leaves it.
    ///
    /// - Parameter values: The preferences in effect.
    /// - Returns: The groups to restore, or nil when this launch restores
    ///   none.
    static func takeLayoutForLaunch(_ values: Ubiquitty.Preferences.Values) -> [LayoutGroup]? {
        let sessions = allSessions()
        guard let current = sessions.first(where: { $0.identifier == currentIdentifier }) else { return nil }
        let isRestored = Ubiquitty.Session.isSessionKeptByQuit(values, current.keptFor)
        if current.keptFor == .UpdateRelaunch {
            current.keptFor = .Ordinary
            let isKeptByPersistence = Ubiquitty.Session.isSessionKeptByQuit(values, .Ordinary)
            try? save(isKeptByPersistence ? sessions : sessions.filter { $0 !== current })
        }
        return isRestored ? current.groups : nil
    }

    /// Every persisted session except the reserved current one: the workspaces the
    /// Workspaces menu and the Connect window save, restore and delete.
    static func namedWorkspaces() -> [LayoutSession] {
        allSessions().filter { $0.identifier != currentIdentifier }
    }

    /// Drops the session with `identifier`; nothing happens when there is none.
    static func deleteSession(withIdentifier identifier: String) {
        guard !identifier.isEmpty else { return }
        let sessions = allSessions()
        let kept = sessions.filter { $0.identifier != identifier }
        if kept.count != sessions.count { try? save(kept) }
    }

    /// Removes the whole store.
    static func clear() {
        try? FileManager.default.removeItem(atPath: sessionsFilePath())
    }

    // MARK: - JSON

    private static func controlDirectory() -> String {
        if let home = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"], !home.isEmpty { return home }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".ubiquitty")
    }

    private static func number(_ value: Any?) -> NSNumber? { value as? NSNumber }

    private static func string(_ value: Any?) -> String? { value as? String }

    private static func reclaimSessionIDs(_ value: Any?) -> [UInt32] {
        guard let elements = value as? [Any] else { return [] }
        var sessions: [UInt32] = []
        for element in elements.prefix(maxReclaimSessionsPerTab) {
            guard let number = number(element), number.doubleValue.isFinite,
                number.doubleValue >= 1, number.doubleValue <= Double(UInt32.max),
                number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { continue }
            let session = UInt32(number.uint64Value)
            if !sessions.contains(session) { sessions.append(session) }
        }
        return sessions
    }

    /// A daemon socket basename, or nil.
    ///
    /// Restoring a tab feeds this into the reattach command's SOCK="<name>"
    /// substitution, which trusts it to be limited to [A-Za-z0-9._-] the way the
    /// live wire value is. A restored value never takes that wire path, so a
    /// crafted store could otherwise carry shell metacharacters into the command.
    /// Refusing clears only the pin; restore still works without one.
    private static func socketName(_ value: Any?) -> String? {
        guard let name = string(value), !name.isEmpty else { return nil }
        let allowed = name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-": true
            default: false
            }
        }
        return allowed ? name : nil
    }

    /// Tag names from untrusted JSON: strings only, each bounded and the list
    /// bounded, anything else dropped.
    private static func tagNames(_ value: Any?) -> [String]? {
        guard let elements = value as? [Any] else { return nil }
        var names: [String] = []
        for element in elements {
            if names.count >= maxTags { break }
            guard let name = string(element), !name.isEmpty, name.utf16.count <= maxTagNameLength else { continue }
            names.append(name)
        }
        return names.isEmpty ? nil : names
    }

    private static func jsonArray(of groups: [LayoutGroup]) -> [[String: Any]] {
        groups.map { group in
            let tabs: [[String: Any]] = group.tabs.map { tab in
                var dictionary: [String: Any] = ["sessionID": tab.sessionID]
                if !tab.reclaimSessionIDsAfterUpdate.isEmpty {
                    dictionary["reclaimSessionIDsAfterUpdate"] = tab.reclaimSessionIDsAfterUpdate
                }
                if let hostLabel = tab.hostLabel, !hostLabel.isEmpty { dictionary["hostLabel"] = hostLabel }
                if let bridgeCommand = tab.bridgeCommand, !bridgeCommand.isEmpty { dictionary["bridge"] = bridgeCommand }
                if let socketName = tab.socketName, !socketName.isEmpty { dictionary["socket"] = socketName }
                if let paneLayout = tab.paneLayout, !paneLayout.isEmpty { dictionary["paneLayout"] = paneLayout }
                if let tags = tab.tags, !tags.isEmpty { dictionary["tags"] = tags }
                dictionary["columns"] = tab.columns
                dictionary["rows"] = tab.rows
                return dictionary
            }
            let frame = group.frame
            var dictionary: [String: Any] = [
                "frame": [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height],
                "activeTab": group.activeTab,
                "tabs": tabs,
            ]
            if group.isFullScreen { dictionary["fullScreen"] = true }
            return dictionary
        }
    }

    private static func groups(fromJSON value: Any?) -> [LayoutGroup] {
        guard let groupArray = value as? [Any] else { return [] }
        var groups: [LayoutGroup] = []
        for groupObject in groupArray {
            if groups.count >= maxGroups { break }
            guard let groupDictionary = groupObject as? [String: Any], let tabArray = groupDictionary["tabs"] as? [Any] else { continue }

            var tabs: [LayoutTab] = []
            for tabObject in tabArray {
                if tabs.count >= maxTabsPerGroup { break }
                guard let tabDictionary = tabObject as? [String: Any] else { continue }
                let tab = LayoutTab()
                tab.sessionID = UInt32(truncatingIfNeeded: number(tabDictionary["sessionID"])?.uint64Value ?? 0)
                tab.reclaimSessionIDsAfterUpdate = reclaimSessionIDs(tabDictionary["reclaimSessionIDsAfterUpdate"])
                tab.hostLabel = string(tabDictionary["hostLabel"])
                tab.bridgeCommand = string(tabDictionary["bridge"])
                tab.socketName = socketName(tabDictionary["socket"])
                tab.paneLayout = string(tabDictionary["paneLayout"])
                tab.tags = tagNames(tabDictionary["tags"])
                tab.columns = UInt16(truncatingIfNeeded: number(tabDictionary["columns"])?.uint32Value ?? 0)
                tab.rows = UInt16(truncatingIfNeeded: number(tabDictionary["rows"])?.uint32Value ?? 0)
                tabs.append(tab)
            }
            // A group with no usable tabs restores nothing.
            if tabs.isEmpty { continue }

            let group = LayoutGroup()
            group.tabs = tabs
            let activeTab = number(groupDictionary["activeTab"])?.intValue ?? 0
            group.activeTab = activeTab >= 0 && activeTab < tabs.count ? activeTab : 0
            group.isFullScreen = (groupDictionary["fullScreen"] as? Bool) == true
            if let frame = groupDictionary["frame"] as? [Any], frame.count == 4,
                let x = number(frame[0]), let y = number(frame[1]), let width = number(frame[2]), let height = number(frame[3])
            {
                group.frame = NSRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
            }
            groups.append(group)
        }
        return groups
    }
}

/// Why the store could not be written.
enum SessionLayoutError: Error {
    /// The owner-only control directory could not be created.
    case controlDirectoryUnavailable
}
