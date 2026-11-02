// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// QuarantinedDownload.swift — where bytes from somewhere else land on this
// disk.
//
// A file a remote host sent, or a ZMODEM sender pushed, did not come from a
// program the person here started: it is a download, and it lands like one.
// That means two things, and both are Core's so no frontend can be the loose
// one — the name it is written under is reduced to its last component
// (`Session::safeDownloadName`), so a suggestion carrying `..` cannot place
// the write outside the directory meant to hold it, and the file carries a
// `com.apple.quarantine` record in a browser download's shape
// (`Session::quarantineValue`), so Gatekeeper and LaunchServices still get a
// say over what happens when it is opened.
//
// Every write carries the tag, the one handed to the OS handler along with
// the one merely revealed. The extension allowlist deciding open-versus-reveal is
// spoofable — a double extension, no extension, a name a sender chose — so it
// narrows what is auto-opened and is never the last gate.

import AppKit
internal import UbiquittyCore

enum QuarantinedDownload {
    /// Tags a file the way a browser tags what it downloaded.
    ///
    /// - Parameter url: The file to tag.
    /// - Returns: Whether the attribute was written. A failure is the caller's
    ///   to weigh: an untagged file is one Gatekeeper will not stop.
    @discardableResult
    static func tag(_ url: URL) -> Bool {
        let value = Self.quarantineRecord()
        let name = String(Ubiquitty.Session.quarantineAttributeName)
        return url.path.withCString { path in
            name.withCString { attribute in
                value.withCString { bytes in
                    setxattr(path, attribute, bytes, strlen(bytes), 0, 0) == 0
                }
            }
        }
    }

    /// Writes bytes into a fresh directory of their own, tagged.
    ///
    /// A directory per landing rather than one shared folder: the name comes
    /// from the other end, and two fetches of `index.html` from two hosts are
    /// two different files that must not overwrite each other.
    ///
    /// - Parameters:
    ///   - bytes: What arrived.
    ///   - suggestedName: What to call it — the path this side asked for, for
    ///     a fetch. Reduced to its last component either way, because a
    ///     caller that passed the other end's string would otherwise let it
    ///     pick both the directory and the extension.
    /// - Returns: Where it landed, or nil when the write failed.
    static func land(bytes: [UInt8], suggestedName: String) -> URL? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Ubiquitty-RemoteFiles")
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let name = suggestedName.withCString { String(Ubiquitty.Session.safeDownloadName(std.string_view($0))) }
        let file = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: file.path, contents: Data(bytes)) else {
            return nil
        }
        tag(file)
        return file
    }

    /// Whether a landed file may be handed to the OS handler rather than
    /// revealed in Finder.
    ///
    /// Core's allowlist (`LinkRun::isSafeToAutoOpenFileExtension`): extensions
    /// a handler merely displays, never ones it can execute.
    ///
    /// - Parameter url: The landed file.
    /// - Returns: Whether opening it is what a click asked for.
    static func isSafeToOpen(_ url: URL) -> Bool {
        url.lastPathComponent.withCString {
            Ubiquitty.Attributes.LinkRun.isSafeToAutoOpenFileExtension(std.string_view($0))
        }
    }

    /// The `com.apple.quarantine` value for a landing happening now.
    ///
    /// The clock and the event id are this platform's; the four fields and
    /// their order are Core's.
    private static func quarantineRecord() -> String {
        let seconds = UInt64(max(0, Int(Date().timeIntervalSince1970)))
        return UUID().uuidString
            .withCString {
                String(Ubiquitty.Session.quarantineValue(seconds, std.string_view($0)))
            }
    }
}
