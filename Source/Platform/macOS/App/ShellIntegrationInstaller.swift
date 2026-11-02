// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ShellIntegrationInstaller.swift — shell integration, installed into a home
// directory's shell startup files.
//
// What each file becomes is Core's (`App::ShellIntegrationInstall`), decided
// over the file's text. What is left here is the filesystem: telling a file
// that is absent from one that is present and cannot be read as text, which is
// left alone rather than replaced by a file holding the block and nothing else,
// and writing through a symbolic link to the file it names with the file's
// permissions kept, so a startup file kept in a dotfiles repository stays one.
//
// Both routes to an install end here — the Welcome screen's button and the
// application menu's item, each behind the same question — so the two cannot
// disagree about which files are written or what goes into them.
//

import AppKit
internal import UbiquittyCore

/// Shell integration, installed into a home directory's startup files.
@objc(UBShellIntegrationInstaller)
@MainActor
public final class ShellIntegrationInstaller: NSObject {
    /// One startup file an install writes.
    package struct Change: Equatable {
        /// The file's path, relative to the home directory.
        package let relativePath: String
        /// Whether the file does not exist yet, so the install creates it.
        package let isNew: Bool
        /// The whole file as the install leaves it.
        package let contents: String
    }

    /// The files an install into `homeDirectory` would write, in the order it
    /// writes them.
    ///
    /// A file already carrying this build's block, one that loads the script
    /// the way the guide shows, one whose block has lost its closing marker,
    /// and an absent one an install does not create are missing from the list,
    /// because the install leaves each of them as it is.
    ///
    /// - Parameter homeDirectory: The directory the startup files live in.
    /// - Returns: The changes, one per file written.
    package static func plannedChanges(homeDirectory: String) -> [Change] {
        var changes: [Change] = []
        for startupFile in Ubiquitty.App.ShellIntegrationInstall.startupFiles() {
            let relativePath = String(startupFile.relativePath)
            let path = (homeDirectory as NSString).appendingPathComponent(relativePath)
            let plan: Ubiquitty.App.ShellIntegrationInstall.PlannedEdit
            if FileManager.default.fileExists(atPath: path) {
                // A NUL would end the text Core is handed early and the write
                // would then drop everything after it, so a file carrying one
                // is left alone with the unreadable ones.
                guard let current = try? String(contentsOfFile: path, encoding: .utf8), !current.utf8.contains(0) else {
                    continue
                }
                plan = current.withCString {
                    Ubiquitty.App.ShellIntegrationInstall.planEdit(startupFile, std.string_view($0))
                }
            } else {
                plan = Ubiquitty.App.ShellIntegrationInstall.planAbsentFile(startupFile)
            }
            switch plan.edit {
            case .create, .append, .upgrade:
                changes.append(
                    Change(relativePath: relativePath, isNew: plan.edit == .create, contents: String(plan.contents))
                )
            case .alreadyCurrent, .readerWritten, .malformed, .leftAbsent:
                continue
            }
        }
        return changes
    }

    /// Writes the block into every startup file under `homeDirectory` that
    /// needs it.
    ///
    /// - Parameter homeDirectory: The directory the startup files live in.
    /// - Returns: The files written, as `~/`-prefixed paths, in the order they
    ///   were written. Empty when every file already had what it needs.
    @discardableResult
    package static func install(homeDirectory: String) -> [String] {
        var written: [String] = []
        for change in plannedChanges(homeDirectory: homeDirectory) {
            let path = (homeDirectory as NSString).appendingPathComponent(change.relativePath)
            do {
                try write(change.contents, to: path)
                written.append("~/" + change.relativePath)
            } catch {
                NSLog("shell integration: could not write %@: %@", path, String(describing: error))
            }
        }
        return written
    }

    /// Writes a startup file whole, through a symbolic link to the file it
    /// names, keeping the permissions the file had.
    ///
    /// The write is atomic, so a reader's file is never left half written, and
    /// an atomic write replaces the file it lands on: landing on the link would
    /// turn the link into a copy, and a fresh file takes the default
    /// permissions rather than the reader's.
    ///
    /// - Parameters:
    ///   - contents: The whole file.
    ///   - path: The startup file's path, which may be a symbolic link.
    private static func write(_ contents: String, to path: String) throws {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let permissions = try? FileManager.default.attributesOfItem(atPath: target)[.posixPermissions]
        if permissions == nil {
            try FileManager.default.createDirectory(
                atPath: (target as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
        }
        try contents.write(toFile: target, atomically: true, encoding: .utf8)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target)
        }
    }

    /// Asks before shell integration is installed, and installs it only when
    /// the reader says Install.
    ///
    /// The plan is read before the question so the question can name the
    /// files; the install reads them again once answered, so a file edited
    /// while the question stood is edited as it now is.
    ///
    /// - Parameters:
    ///   - homeDirectory: The home the install writes into.
    ///   - window: The window to attach the question to; app-modal when nil.
    package static func askToInstall(homeDirectory: String, from window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install shell integration?"
        alert.informativeText = consentDetail(for: plannedChanges(homeDirectory: homeDirectory))
        ConsentAlert.ask(alert, refusing: "Cancel", allowing: ["Install"], on: window) { decision in
            guard decision != .deny else {
                return
            }
            installTerminfo(homeDirectory: homeDirectory)
            install(homeDirectory: homeDirectory)
        }
    }

    /// Asks before shell integration is installed into the reader's home, for
    /// the application menu's item.
    ///
    /// - Parameter window: The window to attach the question to; app-modal
    ///   when nil.
    @objc(askToInstallFromWindow:)
    public static func askToInstall(from window: NSWindow?) {
        askToInstall(homeDirectory: NSHomeDirectory(), from: window)
    }

    /// What the question says will happen, from Core's wording.
    ///
    /// - Parameter changes: The install's plan, from ``plannedChanges(homeDirectory:)``.
    /// - Returns: The question's informative text.
    package static func consentDetail(for changes: [Change]) -> String {
        var planned = Ubiquitty.App.ShellIntegrationInstall.PlannedChanges()
        for change in changes {
            var entry = Ubiquitty.App.ShellIntegrationInstall.PlannedChange()
            entry.relativePath = std.string(change.relativePath)
            entry.isNew = change.isNew
            planned.push_back(entry)
        }
        return String(Ubiquitty.App.ShellIntegrationInstall.consentDetail(planned))
    }

    /// Compiles the xterm-ubiquitty entry into the terminfo database under the
    /// same home the startup files are written in, so one answer covers both
    /// halves of one install.
    ///
    /// - Parameter homeDirectory: The home the install writes into.
    private static func installTerminfo(homeDirectory: String) {
        let database = (homeDirectory as NSString).appendingPathComponent(".terminfo")
        _ = database.withCString { Ubiquitty.Terminfo.install($0) }
    }
}
