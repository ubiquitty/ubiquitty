// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// AboutView.swift — the SwiftUI content of the About panel: app
// icon, name, version, copyright and license, and a button that opens the
// license texts the bundle carries, centered on a plain window backdrop
// (Safari's About layout). The version string is supplied by the controller (it
// carries the build hash, a C macro Swift can't read).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AboutView: View {
    let appName: String
    let versionString: String

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .padding(.top, 30)
                .padding(.bottom, 12)

            Text(appName)
                .font(.system(size: 26, weight: .bold))

            Text(versionString)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            VStack(spacing: 2) {
                Text("Copyright © 2026 Stanislav Yaglo.")
                Text("Licensed under Apache-2.0.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 24)

            Button("Licenses") { Self.openLicenses() }
                .controlSize(.small)
                .padding(.top, 12)
                .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Opens `LICENSE` and `third-party-notices.md` from the bundle's resources,
    /// where the build copies every notice, in the app that opens plain text.
    ///
    /// `LICENSE` has no extension, so opening it by its own type finds no app;
    /// naming the plain-text app opens both. With no such app, Finder shows them.
    private static func openLicenses() {
        guard let resources = Bundle.main.resourceURL else {
            return
        }
        let documents = ["LICENSE", "third-party-notices.md"]
            .map { resources.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !documents.isEmpty else {
            return
        }
        guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else {
            NSWorkspace.shared.activateFileViewerSelecting(documents)
            return
        }
        NSWorkspace.shared.open(documents, withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}
