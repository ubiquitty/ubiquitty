# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

if(TARGET UbiquittyPasteboard)
    return()
endif()
enable_language(Swift)

# The application's API floor.
#
# Without it swiftc takes the build machine's OS, so the module records whatever
# the runner happens to run and the application cannot import a module newer
# than itself: "compiling for macOS X, but module 'UbiquittyPasteboard' has a
# minimum deployment target of macOS Y". It agrees by accident on a machine
# whose OS matches the floor, and stops agreeing the moment one is upgraded.
#
# The app's floor rather than the C++ one, because the app is what links this.
set(_pasteboard_target "${CMAKE_SYSTEM_PROCESSOR}-apple-macos${UBIQUITTY_MACOS_APP_MIN}")
set(_pasteboard_source "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/TypedPasteboard.swift")
set(_pasteboard_directory "${CMAKE_BINARY_DIR}/pasteboard")
file(MAKE_DIRECTORY "${_pasteboard_directory}")
# No generated ObjC header: Swift callers import the module, and C++ callers
# reach the module's C entry points through Source/Platform/macOS/TypedPasteboard.h,
# which declares them itself. Nothing on this seam speaks Objective-C.
add_library(UbiquittyPasteboard STATIC "${_pasteboard_source}")
set_target_properties(UbiquittyPasteboard PROPERTIES
    Swift_MODULE_DIRECTORY "${_pasteboard_directory}"
    Swift_MODULE_NAME UbiquittyPasteboard
)
# Xcode takes the language mode from SWIFT_VERSION; a -swift-version word in
# OTHER_SWIFT_FLAGS is reported as overriding it.
if(CMAKE_GENERATOR MATCHES "Xcode")
    set_target_properties(UbiquittyPasteboard PROPERTIES XCODE_ATTRIBUTE_SWIFT_VERSION 6)
else()
    set_target_properties(UbiquittyPasteboard PROPERTIES Swift_LANGUAGE_VERSION 6)
endif()
target_compile_options(UbiquittyPasteboard PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-target ${_pasteboard_target}>")
# The module directory, which is how a consumer's Swift resolves the import.
target_include_directories(UbiquittyPasteboard PUBLIC "${_pasteboard_directory}")
target_link_libraries(UbiquittyPasteboard PUBLIC "-framework AppKit" "-framework UniformTypeIdentifiers")
