# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Writes a Swift file whose only content is a hash of the C++ headers the Swift
# modules inline through interop, so those modules recompile when one moves.
#
# A hash and not a timestamp: the file is rewritten on every header change and
# on no other occasion, so an untouched tree rebuilds nothing and the build does
# not churn each time CMake reconfigures.
set(_digest "")
foreach(_header IN LISTS HEADERS)
    if(EXISTS "${_header}")
        file(SHA256 "${_header}" _one)
        string(APPEND _digest "${_one}")
    endif()
endforeach()
string(SHA256 _combined "${_digest}")
set(_body "// Generated. The C++ headers the Swift modules inline, as one hash.\n")
string(APPEND _body "// Regenerated when any of them changes, which is what makes this module\n")
string(APPEND _body "// recompile against the Core it is actually built against.\n")
string(APPEND _body "// See Source/Platform/macOS/CMakeLists.txt, UBIQUITTY_SWIFT_INTEROP_HEADERS.\n")
string(APPEND _body "enum UbiquittyInteropStamp { static let digest = \"${_combined}\" }\n")
if(EXISTS "${OUT}")
    file(READ "${OUT}" _existing)
    if(_existing STREQUAL "${_body}")
        return()
    endif()
endif()
file(WRITE "${OUT}" "${_body}")
