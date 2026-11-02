// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import SwiftUI
import UIKit
import UbiquittyCore
import UbiquittyIOSBridge
import UbiquittyKit

/// The configuration document this app keeps, handed to Core.
///
/// The bytes are the app's stored document — the PAL configuration blob, which
/// a settings write persists through Core — and Core parses them, applies its
/// default table to every key they leave unset and tells every subscriber. The
/// shell names no setting here.
enum StoredConfiguration {
    /// Configures Core from the stored document; an absent one is the
    /// default table.
    @MainActor
    static func load() {
        // iOS permits app data in Library, Documents and tmp, but does not
        // permit the desktop default ~/.config at the container root.
        // Keep Core's XDG path contract inside the app's supported data area.
        if ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] == nil,
            let support = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        {
            setenv("XDG_CONFIG_HOME", support.path, 1)
        }
        _ = Ubiquitty.Preferences.configureFromStoredDocument(.Permissive)
    }
}

/// The iOS shell.
///
/// Everything below the view layer is shared: the terminal model, the session
/// facade, the carrier contract and the host-key policy are all Core's, reached
/// through one C seam because Swift cannot derive from a C++ class. What is
/// here is the shell and nothing else, which is the whole shape of this
/// frontend.
@main
struct UbiquittyApp: App {
    @UIApplicationDelegateAdaptor(BackgroundRefreshApplicationDelegate.self)
    private var backgroundRefreshDelegate
    /// The app's phase across its scenes: background only when every scene
    /// is, active when any one is.
    @Environment(\.scenePhase)
    private var scenePhase

    /// Installs the pasteboard the terminal writes through, and the clients
    /// every pane's terminal is given.
    ///
    /// UIPasteboard is UIKit's, so the PAL entry point is a seam the shell
    /// fills — without this, OSC 52 and every copy reach a null sink and the
    /// terminal has no clipboard at all. The pane clients, a clipboard writer
    /// into that seam and the frontend's capability policy, are registered
    /// before the first pane exists; each pane asks for them as it is built.
    init() {
        Ubiquitty.PAL.installIOSClipboardWriter { utf8, byteCount in
            guard let utf8, byteCount > 0 else { return }
            let bytes = UnsafeRawBufferPointer(start: utf8, count: byteCount)
            UIPasteboard.general.string = String(decoding: bytes, as: UTF8.self)
        }
        Ubiquitty.IOS.registerSessionClients()
        // Before the window's content, so the host list reads a store the
        // seed has already written. Does nothing unless the launch asks; see
        // LiveHostSeed.
        MainActor.assumeIsolated {
            StoredConfiguration.load()
            LiveHostSeed.seedIfRequested()
            installTheSessionPairingStore()
        }
    }

    /// Gives Core somewhere to keep what each host was last attached on.
    ///
    /// The bytes are opaque here: their layout and their meaning belong to
    /// `Ubiquitty::Session::RememberedSessions`, and a shell that parsed them
    /// would be a second reader to keep in step with the one that writes them.
    /// They ride in the saved host beside the pinned key, which is where this
    /// app already keeps the non-secret half of a connection.
    ///
    /// Installed once, at launch, because Core's directory is the process's:
    /// the pairing has to be readable before the first host is opened, and the
    /// first connect can happen from the launch environment without a tap.
    @MainActor
    private func installTheSessionPairingStore() {
        HostDirectory.setPersistence(
            load: { hostKey in
                MainActor.assumeIsolated {
                    HostStore.shared.rememberedSessionRecord(forKey: hostKey).map { [UInt8]($0) }
                }
            },
            store: { hostKey, bytes in
                MainActor.assumeIsolated {
                    HostStore.shared.setRememberedSessionRecord(Data(bytes), forKey: hostKey)
                }
            }
        )
    }

    var body: some Scene {
        WindowGroup {
            HostListView()
                .task { SmokeLaunch.runIfRequested() }
        }
        .commands { TerminalWorkspaceMenu() }
        // From the scene life cycle, which iOS 27 requires: the application
        // delegate's foreground and background callbacks are deprecated.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: BackgroundRefreshCoordinator.shared.applicationBackgrounded()
            case .active: BackgroundRefreshCoordinator.shared.refreshInForeground()
            default: break
            }
        }
        // A workspace opened in a window of its own, from its row's menu,
        // where the device shows more than one window.
        WindowGroup(for: WorkspaceWindowRequest.self) { $request in
            HostListView(opening: request)
        }
    }
}
