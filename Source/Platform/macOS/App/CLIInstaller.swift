// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

/// Installs a link to the bundled command without replacing an existing file.
enum CLIInstaller {
    enum InstallError: LocalizedError {
        case missingHelper
        case occupied(String)
        case authorization(String)

        var errorDescription: String? {
            switch self {
            case .missingHelper: "This copy of Ubiquitty does not include the ubq program. Install a complete app bundle."
            case .occupied(let path): "\(path) already exists and points somewhere else. It was left unchanged."
            case .authorization(let detail): "The installation could not be completed. \(detail)"
            }
        }
    }

    /// Creates a new link, or accepts the same link on a repeated install.
    static func installLink(source: URL, destination: URL) throws {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: source.path) else { throw InstallError.missingHelper }
        if let current = try? files.destinationOfSymbolicLink(atPath: destination.path) {
            guard current == source.path else { throw InstallError.occupied(destination.path) }
            return
        }
        guard !files.fileExists(atPath: destination.path) else { throw InstallError.occupied(destination.path) }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createSymbolicLink(at: destination, withDestinationURL: source)
    }

    /// Quotes data once for the shell; the AppleScript layer is quoted separately.
    private static func shellWord(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The privileged operation creates only the bin directory and the link.
    static func installCommand(source: URL, destination: URL) -> String {
        let target = shellWord(destination.path)
        let helper = shellWord(source.path)
        return """
            set -eu
            if [ -L \(target) ] && [ "$(/usr/bin/readlink \(target))" = \(helper) ]; then exit 0; fi
            if [ -e \(target) ] || [ -L \(target) ]; then echo 'The destination already exists; it was left unchanged.' >&2; exit 1; fi
            /bin/mkdir -p \(shellWord(destination.deletingLastPathComponent().path))
            /bin/ln -s -h \(helper) \(target)
            """
    }

    /// Uses the system authorization dialog without collecting a password.
    static func installWithAuthorization(source: URL, destination: URL) throws -> Bool {
        let command = installCommand(source: source, destination: destination)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // copy-ok: AppleScript source requires ASCII string delimiters.
        process.arguments = ["-e", "do shell script \"\(command)\" with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let detail = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("(-128)") { return false }
            throw InstallError.authorization(detail)
        }
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == source.path else {
            throw InstallError.occupied(destination.path)
        }
        return true
    }

    @MainActor
    static func askToInstall(from window: NSWindow?) {
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ubq")
        let destination = URL(fileURLWithPath: "/usr/local/bin/ubq")
        guard !Bundle.main.bundleURL.pathComponents.contains("AppTranslocation") else {
            showResult(
                "Move Ubiquitty to Applications",
                detail: "Move the app to your Applications folder and reopen it before installing ubq.",
                on: window
            )
            return
        }
        guard FileManager.default.isExecutableFile(atPath: source.path) else {
            showResult("ubq is not available", detail: InstallError.missingHelper.localizedDescription, on: window)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Install ubq CLI program?"
        alert.informativeText =
            "Create /usr/local/bin/ubq as a link to this app’s command-line program. App updates will update the command too. macOS may ask for administrator authorization."
        ConsentAlert.ask(alert, refusing: "Cancel", allowing: ["Install"], on: window) { decision in
            guard decision != .deny else { return }
            Task {
                let result =
                    await Task.detached { () -> Result<Bool, Error> in
                        do {
                            do {
                                try installLink(source: source, destination: destination)
                                return .success(true)
                            } catch {
                                let error = error as NSError
                                guard error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError else { throw error }
                                return .success(try installWithAuthorization(source: source, destination: destination))
                            }
                        } catch { return .failure(error) }
                    }
                    .value
                switch result {
                case .success(true):
                    showResult(
                        "ubq is installed",
                        detail: "Run ubq --help in a terminal. The command is at /usr/local/bin/ubq.",
                        on: window
                    )
                case .success(false): break
                case .failure(let error):
                    showResult("Could not install ubq", detail: error.localizedDescription, on: window)
                }
            }
        }
    }

    @MainActor
    private static func showResult(_ title: String, detail: String, on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
