// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// BundledFontDirectory — where this binary's shipped font files are.
//
// One derivation, because every route to a bundled face has to agree about it:
// the primary face, the glyph-fallback face, the colour face and the font
// inventory all put a family through `Rendering::bundledFontFile` and open the
// answer beside the binary. A second spelling of "beside the binary" is a route
// that finds the file where the others do not, and the difference shows as a
// grid drawn in another face with nothing reported.

#include <string>
#include <string_view>

namespace Ubiquitty::Linux {

/// The directory this binary's bundled fonts were staged into, with no
/// trailing separator.
///
/// Read from `/proc/self/exe`, the way the Vulkan renderer locates its SPIR-V:
/// the build copies the files next to the executable and the AppImage stages
/// them there, so the executable's own directory is the answer on both. Empty
/// when the link cannot be read, which leaves every caller on its platform
/// matcher.
///
/// - Returns: The directory, or an empty string.
[[nodiscard]] std::string bundledFontDirectory();

/// The absolute path of a bundled file, or empty when this project does not
/// ship that family.
///
/// The lookup is `Rendering::bundledFontFile`, so a family absent from the
/// table answers empty and the caller falls to its platform matcher — which is
/// the right route for a face the user installed themselves.
///
/// - Parameter family: The family a configuration named.
/// - Parameter directory: The directory to resolve against; empty asks
///   ``bundledFontDirectory``. Named so a test can point it at the repository's
///   own `Resources/fonts` without a staged binary beside it.
/// - Returns: The absolute path, or an empty string.
[[nodiscard]] std::string bundledFontPath(std::string_view family, std::string_view directory = {});

} // namespace Ubiquitty::Linux
