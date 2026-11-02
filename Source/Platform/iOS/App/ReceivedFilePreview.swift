// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Owns the protected temporary copy while Quick Look or the share sheet uses it.
final class ReceivedFilePreview {
    let url: URL
    private let directory: URL

    init(data: Data, name: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let component = URL(fileURLWithPath: name).lastPathComponent
        let fileName = component.isEmpty || component == "." || component == ".." ? "Download" : component
        url = directory.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
