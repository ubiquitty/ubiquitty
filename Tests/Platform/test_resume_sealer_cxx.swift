// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

internal import CxxStdlib

/// Compiles after the production sealer in the same whole-module invocation.
/// Foundation's formatted String initializer must not hide the C++ overlay's
/// String initializer in other files, including files that import it directly.
@main
struct ResumeSealerCxxTests {
    static func main() {
        for value in ["", "resume", "café 🚀", "before\0after"] {
            precondition(String(std.string(value)) == value)
        }
        print("resume_sealer_cxx: whole-module C++ string conversion passed")
    }
}
