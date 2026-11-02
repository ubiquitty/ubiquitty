// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Tests/Platform/test_ios_protected_file_probe.swift — the one question
// test_ios_protected_file.cpp cannot ask in C++: which data-protection class a
// file carries. That is a Foundation resource value, so it is read here and
// handed to the C++ suite behind a C symbol, the way the creator under test
// (Source/UbiquittyKit/Swift/ProtectedFile.swift) is.
//

import Foundation

/// Whether the file at `path` carries Complete protection.
///
/// - Parameter path: A NUL-terminated file-system path.
/// - Returns: Whether its `fileProtection` resource value is `.complete`;
///   false when the value cannot be read.
@_cdecl("ubiquittyTestHasCompleteProtection")
func hasCompleteProtection(_ path: UnsafePointer<CChar>) -> Bool {
    let url = URL(fileURLWithFileSystemRepresentation: path, isDirectory: false, relativeTo: nil)
    guard let values = try? url.resourceValues(forKeys: [.fileProtectionKey]) else {
        return false
    }
    return values.fileProtection == .complete
}
