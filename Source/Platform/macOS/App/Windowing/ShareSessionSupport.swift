// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ShareSessionSupport.swift — AppKit-facing helpers for sharing a local
// terminal session with agents through the bundled host daemon.
//

import AppKit

@MainActor
@objc(UBShareSessionSupport)
public final class ShareSessionSupport: NSObject {
    /// What a share tells the person who asked for it.
    package enum Notice {
        /// No ubiquitty-host to reach the daemon through.
        case missingHost
        /// The share did not happen, in the words Core gives for why.
        case failed(title: String, detail: String)
        /// The session is shared, and agents may now ask for it.
        case started
    }

    @objc
    public static func localHostBinaryPath() -> String? {
        let fileManager = FileManager.default
        let bundle = Bundle.main
        let bundled = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("ubiquitty-host")
            .path
        if fileManager.isExecutableFile(atPath: bundled) {
            return bundled
        }

        guard isDevelopmentBundle(bundle) else {
            return nil
        }

        var directory = URL(fileURLWithPath: bundle.executablePath ?? bundle.bundlePath)
        let relatives = ["build/host/ubiquitty-host", "host/ubiquitty-host"]
        for _ in 0..<12 {
            directory.deleteLastPathComponent()
            for relative in relatives {
                let candidate = directory.appendingPathComponent(relative).path
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Tells the person what their share did.
    ///
    /// A sheet on the window the share was asked of, when there is one: the
    /// news is about that window, and an application-modal alert would hold
    /// every other window hostage to a notice with nothing to decide.
    ///
    /// - Parameters:
    ///   - notice: What happened.
    ///   - window: The window that was shared, or nil for an application-modal
    ///     alert.
    package static func present(_ notice: Notice, attachedTo window: NSWindow?) {
        let alert = NSAlert()
        switch notice {
        case .missingHost:
            if isDevelopmentBundle(Bundle.main) {
                alert.messageText = "ubiquitty-host Isn’t Built"
                alert.informativeText =
                    "Build the local host helper with ./Scripts/build-host.sh, or rebuild the app without --no-helpers so Contents/Helpers/ubiquitty-host is bundled."
            } else {
                alert.messageText = "The Ubiquitty Host Helper Is Missing"
                alert.informativeText =
                    "This app bundle doesn’t contain Contents/Helpers/ubiquitty-host. Reinstall Ubiquitty from a complete release bundle."
            }
        case .failed(let title, let detail):
            alert.messageText = title
            alert.informativeText = detail
        case .started:
            alert.messageText = "Window Shared"
            alert.informativeText =
                "All tabs and split panes are in the hosted workspace. Open this Mac from another device to connect to it. Agents can request access, and Ubiquitty asks for your consent before they attach."
        }
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Returns whether a bundle was built in a checkout rather than installed.
    ///
    /// A build tree holds a `CMakeCache.txt` within a few directories above the
    /// bundle, and an installed copy has none. A message that tells someone to
    /// rebuild is only an answer for the first.
    ///
    /// - Parameter bundle: The bundle to place.
    /// - Returns: `true` when a `CMakeCache.txt` sits within twelve directories
    ///   above the bundle.
    package static func isDevelopmentBundle(_ bundle: Bundle) -> Bool {
        let fileManager = FileManager.default
        var directory = bundle.bundleURL
        for _ in 0..<12 {
            directory.deleteLastPathComponent()
            if fileManager.fileExists(atPath: directory.appendingPathComponent("CMakeCache.txt").path) {
                return true
            }
        }
        return false
    }
}
