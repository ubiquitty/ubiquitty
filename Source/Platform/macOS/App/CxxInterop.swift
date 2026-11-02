// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// CxxInterop.swift — small convenience converters for the Swift↔C++ boundary
// (-cxx-interoperability-mode=default). Extensions on the standard types so
// interop call sites read cleanly instead of spelling out std.string_view /
// std.string construction inline.
//

import CxxStdlib

extension String {
    // A std::string_view over this string, valid only for the synchronous call
    // inside `body`. Built over withCString's NUL-terminated UTF-8 buffer, which
    // outlives the closure — never let the view escape it.
    @inline(__always)
    func withCxxStringView<Result>(_ body: (std.string_view) -> Result) -> Result {
        withCString { body(std.string_view($0)) }
    }

    // This string as an owned std::string (a copy).
    var cxxString: std.string { std.string(self) }
}
