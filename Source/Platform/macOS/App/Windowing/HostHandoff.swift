// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Carbon
import CoreImage.CIFilterBuiltins
import SwiftUI
import UbiquittyCore
import UbiquittyKit

/// Names an existing session without conveying permission to access it.
struct HostHandoffLocator: Equatable {
    let host: String
    let daemonInstanceID: UInt64
    let sessionID: UInt32

    init?(host: String, daemonInstanceID: UInt64, sessionID: UInt32) {
        guard host.utf8.count <= 255, host.withCxxStringView({ Ubiquitty.Transport.validateSSHHost($0) }),
            daemonInstanceID != 0, sessionID != 0, sessionID != UInt32.max
        else { return nil }
        self.host = host
        self.daemonInstanceID = daemonInstanceID
        self.sessionID = sessionID
    }

    init?(url: URL) {
        guard url.absoluteString.utf8.count <= 4096,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "ubiquitty", components.host == "session", components.path.isEmpty,
            components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
            let items = components.queryItems, items.count == 3,
            Set(items.map(\.name)) == Set(["host", "daemon", "session"]),
            let host = items.first(where: { $0.name == "host" })?.value,
            let daemonText = items.first(where: { $0.name == "daemon" })?.value,
            let sessionText = items.first(where: { $0.name == "session" })?.value,
            let daemon = UInt64(daemonText), let session = UInt32(sessionText)
        else { return nil }
        self.init(host: host, daemonInstanceID: daemon, sessionID: session)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "ubiquitty"
        components.host = "session"
        components.queryItems = [
            URLQueryItem(name: "host", value: host), URLQueryItem(name: "daemon", value: String(daemonInstanceID)),
            URLQueryItem(name: "session", value: String(sessionID)),
        ]
        return components.url!
    }
}

/// Receives AppKit URL events and requires destination review before using SSH.
@MainActor
@objc(UBSessionHandoff)
final class SessionHandoff: NSObject {
    private static let shared = SessionHandoff()

    @objc
    static func install() {
        // The door back into Connect from a terminal window's refusal sheet,
        // installed with the other session links this app answers.
        TerminalWindowController.showConnectForHost = { hostKey in
            ConnectWindowController.show(place: ConnectModel.shared.place(forHostKey: hostKey))
        }
        TerminalWindowController.showManagementForHost = { hostKey in
            let model = ConnectModel.shared
            guard let server = model.server(for: model.place(forHostKey: hostKey)) else { return }
            HostManagementWindows.shared.show(server: server)
        }
        NSAppleEventManager.shared()
            .setEventHandler(
                shared,
                andSelector: #selector(receive(_:reply:)),
                forEventClass: AEEventClass(kInternetEventClass),
                andEventID: AEEventID(kAEGetURL)
            )
    }

    @objc
    private func receive(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: text), let locator = HostHandoffLocator(url: url)
        else {
            let alert = NSAlert()
            alert.messageText = "Can’t Open the Session Link"
            alert.informativeText = "The link must name an SSH host and an existing Ubiquitty session. Check the link, then try again."
            alert.runModal()
            return
        }
        let alert = Self.reviewAlert(locator)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Self.open(locator)
    }

    static func reviewAlert(_ locator: HostHandoffLocator) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Continue the session \(locator.sessionID) on \(locator.host)?"
        alert.informativeText =
            "Ubiquitty connects using this Mac’s SSH authentication. This link contains no access token. If the host restarted or the session ended, the connection is refused."
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: "Connect").keyEquivalent = ""
        return alert
    }

    static func open(_ locator: HostHandoffLocator) {
        let server = HostServer(
            id: UUID(),
            name: locator.host,
            host: locator.host,
            workspaceName: ""
        )
        guard case .success(let plan) = HostTransport.plan(for: server) else { return }
        _ = TerminalWindowController.spawnRemoteWindow(
            shellCommand: plan.shellCommand,
            hostLabel: locator.host,
            quicHost: plan.quicHost,
            quicBootstrapCommand: plan.quicBootstrapCommand,
            deploySSHHost: plan.deploySSHHost,
            deployBinaries: HostTransport.deployBinaries(forDeploySSHHost: plan.deploySSHHost),
            reattachSessionID: locator.sessionID,
            workspaceName: "",
            // The review sheet promises a refusal when the session ended, so
            // the attach asks for one rather than for a fresh shell.
            reattachPolicy: .attachOnly,
            hostKey: server.pairingKey,
            workspaceID: 0,
            daemonSocketName: "",
            daemonInstanceID: locator.daemonInstanceID
        )
    }
}

/// Shares a reviewed locator as a selectable link or scannable code.
struct HostHandoffView: View {
    let sessionID: UInt32
    let daemonInstanceID: UInt64
    @State
    var host: String
    @Environment(\.dismiss)
    private var dismiss
    private var locator: HostHandoffLocator? { HostHandoffLocator(host: host, daemonInstanceID: daemonInstanceID, sessionID: sessionID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Continue on Another Device").font(.headline)
            TextField("SSH address, such as user@host", text: $host)
            Text("The receiving device needs its own SSH access to this host. Sharing this link grants no access.")
                .foregroundStyle(.secondary)
            if let locator {
                if let code = qrCode(locator.url.absoluteString) {
                    Image(nsImage: code).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220)
                        .accessibilityLabel("Session link for \(host)")
                }
                Text(locator.url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Copy Link") {
                    guard let locator else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(locator.url.absoluteString, forType: .string)
                }
                .disabled(locator == nil)
            }
        }
        .padding(24).frame(width: 460)
    }

    private func qrCode(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            let image = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
