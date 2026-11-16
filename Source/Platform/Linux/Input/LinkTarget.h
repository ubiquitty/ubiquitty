// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Platform/Linux/Input/LinkInteraction.h"

#include <cstdint>
#include <string>
#include <string_view>

namespace Ubiquitty::Runtime {
/// Identifies the host whose filesystem owns a session's paths.
enum class FilesystemLocation : std::uint8_t;
}

namespace Ubiquitty::Linux {

/// Converts a detected path to a native file URI, preserving existing URIs.
///
/// Core resolves literal paths against the requesting pane's directory and
/// the host's home, as on macOS. GLib supplies the native filename encoding;
/// existence and opening permission remain the file opener's decisions.
/// File targets require local provenance; external URLs retain their bytes.
///
/// - Parameters:
///   - target: The scanned target and its path classification.
///   - filesystemLocation: Whether the session's paths name this machine.
///   - baseDirectory: The requesting pane's absolute directory.
///   - homeDirectory: The host's home directory for a leading tilde.
/// - Returns: The URI, or empty when a file target is not local or its path
///   cannot be resolved or encoded.
[[nodiscard]] std::string linkTargetURI(const LinkTargetFacts& target, Runtime::FilesystemLocation filesystemLocation, std::string_view baseDirectory, std::string_view homeDirectory);

} // namespace Ubiquitty::Linux
