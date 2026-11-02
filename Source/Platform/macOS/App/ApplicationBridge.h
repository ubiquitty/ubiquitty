// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

//
// ApplicationBridge.h — what the Swift application delegate needs from C++
// that a Swift caller cannot reach directly: the process platform context and
// the DECPS synth this frontend links, the ssh and mosh wrappers' exec, and the
// settings window's edits that walk C++ structures.
//
// Names no Core header: a header reached through this module and the shared
// Core module both would be parsed into each and defined twice. A Core type
// crosses here only by reference, forward-declared, or as a primitive.
//

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace Ubiquitty::Preferences {
struct Values;
}

namespace Ubiquitty::SwiftBridge {

/// Whether `font.features` is to enable the `zero` tag.
enum class SlashedZero : std::uint8_t {
    Disabled, ///< The tag is dropped.
    Enabled, ///< The tag is set to 1.
};

/// The darkness `firstThemeOfDarkness` looks for.
enum class ThemeDarkness : std::uint8_t {
    Light, ///< A light theme.
    Dark, ///< A dark theme.
};

/// The platform section `editPlatformOverride` writes.
enum class PlatformSection : std::uint8_t {
    Mac, ///< The [mac] section.
    Linux, ///< The [linux] section.
};

/// What `editPlatformOverride` does to its field.
enum class PlatformOverrideEdit : std::uint8_t {
    Set, ///< The field takes the given value.
    Remove, ///< The field is deleted from the section.
};

/// Lines of text, named so Swift can make one.
using TextLines = std::vector<std::string>;

/// Installs the process platform context, once, before any window opens.
///
/// The monotonic clock, the inline-image decoder and the DECPS synth: the
/// hooks every worker thread reads, which is why they must be in place before
/// a session can start one.
void installPlatformContext();

/// Hands the DECPS synth its `[sound]` settings.
///
/// Pushed rather than read: the synth's threads must not touch the
/// configuration a reload is rewriting.
///
/// - Parameter values: The configuration whose sound settings are pushed.
void applySoundPreferences(const Preferences::Values& values);

/// Makes this shell's session clipboard client the default installer, ahead
/// of any window: the workspace model copies the default at construction.
void registerSessionClipboardInstaller();

/// Writes one line to the diagnostic log; see `PAL::diagWrite`.
///
/// - Parameter message: The line.
void writeDiagnostic(const std::string& message);

/// Single-quotes `text` for /bin/sh through `Transport::shellSingleQuote`, the
/// one quoting rule the ssh paths share.
///
/// - Parameter text: The word to quote.
/// - Returns: The quoted word.
[[nodiscard]] std::string shellQuoted(const std::string& text);

// MARK: - Launch

/// The terminal's own words: the arguments before the child's command.
///
/// - Parameters:
///   - terminalArgumentCount: Where the terminal's command line ends.
///   - argv: The process's arguments, borrowed for the call.
/// - Returns: The words, the program first.
[[nodiscard]] TextLines terminalWords(int terminalArgumentCount, char** argv);

/// `ubiquitty ssh [ssh-args] [user@]host` and `ubiquitty mosh …`: replaces the
/// process with ssh or mosh, and for ssh runs the terminfo install on the
/// remote first so xterm-ubiquitty resolves there and OSC 52 survives a remote
/// tmux.
///
/// The last word is the host, refused unless `Transport::validateSSHHost`
/// accepts it; the words between the subcommand and the host pass through.
/// Runs off the caller's PATH, before any AppKit setup. Returns only when the
/// command line names neither subcommand; exits 2 on an unsafe host and 1 when
/// the program cannot be run.
///
/// - Parameters:
///   - terminalArgumentCount: Where the terminal's command line ends.
///   - argv: The process's arguments.
void execRemoteWrapperIfRequested(int terminalArgumentCount, char** argv);

// MARK: - Settings

/// The appearance picker's row; see `Preferences::appearanceModeFromValues`.
///
/// A pinned theme is a name; an unknown one resolves to no index, and the rule
/// then answers System.
///
/// - Parameter values: The configuration.
/// - Returns: 0 System, 1 Light or 2 Dark.
[[nodiscard]] int appearanceMode(const Preferences::Values& values);

/// The registry's first theme of the darkness asked for, or -1.
///
/// - Parameter darkness: The darkness wanted.
/// - Returns: The theme's registry index, or -1 when none matches.
[[nodiscard]] int firstThemeOfDarkness(ThemeDarkness darkness);

/// The effective title template of one surface: 0 window, 1 tab, 2 pane.
[[nodiscard]] std::string effectiveTitleText(const Preferences::Values& values, int surface);

/// Whether `font.features` enables the `zero` tag.
[[nodiscard]] bool fontFeaturesEnableSlashedZero(const Preferences::Values& values);

/// `font.features` with the `zero` tag enabled, or dropped entirely so the
/// canonical string stays minimal.
///
/// - Parameters:
///   - values: The configuration.
///   - zero: Whether the tag is wanted.
/// - Returns: The new specification, or nothing when the tag is already as
///   wanted.
[[nodiscard]] std::optional<std::string> fontFeaturesWithSlashedZero(const Preferences::Values& values, SlashedZero zero);

/// Whether `spec` parses to a chord sequence and `action` to a binding action.
[[nodiscard]] bool isValidKeyBinding(const std::string& spec, const std::string& action);

/// One [keys] table line binding `spec` to `action`, both TOML-escaped.
[[nodiscard]] std::string keyBindingLine(const std::string& spec, const std::string& action);

/// Writes one field of a platform section, or removes it.
///
/// The field's TOML key and kind come from Core's platform-override table: a
/// whole-number field rounds `number`, a fractional one keeps it, a text field
/// takes `text`.
///
/// - Parameters:
///   - platform: The section, [mac] or [linux].
///   - field: The field's token.
///   - edit: Whether the field is set or removed.
///   - text: The value of a text field.
///   - number: The value of a numeric field.
/// - Returns: False when the field is unknown or the configuration refused the
///   value.
[[nodiscard]] bool editPlatformOverride(PlatformSection platform, const std::string& field, PlatformOverrideEdit edit, const std::string& text, double number);

/// A theme file, read; colors are packed 0xRRGGBBAA.
struct ImportedThemeSummary {
    /// Whether at least the 16 ANSI colors parsed.
    bool ok = false;
    /// The file's own name for the theme; empty when it names none.
    std::string name;
    /// Whether the theme is dark; see `Themes::importedThemeIsDark`.
    bool isDark = false;
    /// The foreground color.
    std::uint32_t foreground = 0;
    /// The background color.
    std::uint32_t background = 0;
    /// The cursor color.
    std::uint32_t cursor = 0;

    /// One ANSI color; 0 for an index outside 0…15.
    [[nodiscard]] std::uint32_t ansiColor(int index) const
    {
        return index >= 0 && index < static_cast<int>(ansi.size()) ? ansi[static_cast<std::size_t>(index)] : 0;
    }

    /// The 16 ANSI colors.
    std::array<std::uint32_t, 16> ansi {};
};

/// Reads a Ubiquitty, iTerm2 or Ghostty theme file's bytes.
[[nodiscard]] ImportedThemeSummary importTheme(const std::string& bytes);

// MARK: - Agent tokens

/// One capability token, as the Agents pane lists it.
struct AgentTokenRow {
    /// The token's digest, 64 hexadecimal characters.
    std::string identifier;
    /// Its label.
    std::string label;
    /// Its scopes, named.
    std::string scope;
    /// Its expiry, named.
    std::string expiry;
};

/// The rows the Agents pane lists.
using AgentTokenRows = std::vector<AgentTokenRow>;

/// Reads the daemon's tokens file, one record per line.
///
/// - Parameters:
///   - lines: The file's lines.
///   - nowUnix: The current time, for each token's expiry.
/// - Returns: One row per valid record.
[[nodiscard]] AgentTokenRows listAgentTokens(const TextLines& lines, std::uint64_t nowUnix);

} // namespace Ubiquitty::SwiftBridge
