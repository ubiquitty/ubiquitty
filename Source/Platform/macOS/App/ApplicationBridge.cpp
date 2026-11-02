// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "ApplicationBridge.h"

#include "Core/Preferences/AppearanceMode.h"
#include "Core/Preferences/Preferences.h"
#include "Core/Preferences/Profile.h"
#include "Core/Preferences/TitleComposition.h"
#include "Core/Themes/ThemeDocumentEdit.h"
#include "Core/Themes/Themes.h"
#include "PAL/PAL.h"
#include "Platform/macOS/SessionClipboardClient.h"

#include "Core/Input/Keybindings.h"
#include "Core/Network/RemoteTerminfoInstall.h"
#include "Core/Preferences/Key.h"
#include "Core/Preferences/SelfWriteGuard.h"
#include "Core/Preferences/TOMLString.h"
#include "Core/Protocol/Sync/TokenRecord.h"
#include "Core/Rendering/FontFeatureSpecification.h"
#include "Core/Terminfo.h"
#include "Core/Themes/ThemeImport.h"
#include "Core/Themes/ThemeResolve.h"
#include "Core/Transport/SSHHost.h"
#include "PAL/Log.h"
#include "Platform/Apple/ImageDecode.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

// Defined in DECPSSound.cpp: the AudioToolbox synth behind the PAL context's
// playTones slot, internal to this frontend rather than part of PAL.h.
namespace Ubiquitty::PAL {
PlayTonesCallback decpsToneSynth();
SoundStatusCallback decpsSoundStatus();
void decpsApplySoundPreferences(SoundOutput setting, double volume);
}

namespace Ubiquitty::SwiftBridge {

void installPlatformContext()
{
    PAL::Context context;
    context.monotonicClock = &PAL::monotonicTicks;
    context.imageDecoder = &Apple::decodeImageRGBA;
    context.playTones = PAL::decpsToneSynth();
    context.soundStatus = PAL::decpsSoundStatus();
    PAL::installContext(context);
}

void applySoundPreferences(const Preferences::Values& values)
{
    const PAL::SoundOutput output = Preferences::Effective::soundAudible(values) ? PAL::SoundOutput::Audible : PAL::SoundOutput::Silenced;
    PAL::decpsApplySoundPreferences(output, Preferences::Effective::soundVolume(values));
}

void registerSessionClipboardInstaller() { SessionClients::registerAsDefaultInstaller(); }

void writeDiagnostic(const std::string& message) { PAL::diagWrite(message); }

std::string shellQuoted(const std::string& text) { return Transport::shellSingleQuote(text); }

TextLines terminalWords(int terminalArgumentCount, char** argv)
{
    TextLines words;
    words.reserve(static_cast<std::size_t>(std::max(terminalArgumentCount, 0)));
    for (int index = 0; index < terminalArgumentCount; ++index)
        words.emplace_back(argv[index] ? argv[index] : "");
    return words;
}

void execRemoteWrapperIfRequested(int terminalArgumentCount, char** argv)
{
    if (terminalArgumentCount < 3 || !argv[1])
        return;
    const bool wantsSSH = std::strcmp(argv[1], "ssh") == 0;
    const bool wantsMosh = std::strcmp(argv[1], "mosh") == 0;
    if (!wantsSSH && !wantsMosh)
        return;

    const char* host = argv[terminalArgumentCount - 1];
    if (!Transport::validateSSHHost(host ? host : "")) {
        PAL::logLine(stderr, "ubiquitty {}: refusing unsafe host '{}'.", argv[1], host ? host : "");
        std::exit(2);
    }

    // The subcommand names the program, which execvp resolves off the caller's
    // PATH; the reader's own arguments follow verbatim.
    std::vector<std::string> tokens;
    tokens.emplace_back(argv[1]);
    for (int index = 2; index < terminalArgumentCount - 1; ++index)
        tokens.emplace_back(argv[index]);
    if (wantsSSH) {
        // A remote pty for the login shell the install command ends in.
        tokens.emplace_back("-t");
        tokens.emplace_back(host);
        tokens.emplace_back(Network::buildRemoteTerminfoInstallCommand(Terminfo::sourceText()));
    } else {
        // mosh connects plainly; it has no terminfo leg.
        tokens.emplace_back(host);
    }

    std::vector<char*> execArguments;
    execArguments.reserve(tokens.size() + 1);
    for (std::string& token : tokens)
        execArguments.push_back(token.data());
    execArguments.push_back(nullptr);
    execvp(execArguments[0], execArguments.data());
    // Reached only when ssh or mosh is not on PATH.
    std::perror("ubiquitty: exec");
    std::exit(1);
}

int appearanceMode(const Preferences::Values& values)
{
    const bool isThemePinned = values.themeName && !values.themeName->empty();
    const int themeIndex = isThemePinned ? Themes::indexForName(values.themeName->c_str()) : -1;
    const bool shouldFollowSystem = Preferences::Effective::followSystemAppearance(values);
    return static_cast<int>(Preferences::appearanceModeFromValues(shouldFollowSystem, isThemePinned, themeIndex, Themes::count(), [](int index) { return Themes::isDark(index); }));
}

int firstThemeOfDarkness(ThemeDarkness darkness)
{
    const Preferences::ColorScheme scheme = darkness == ThemeDarkness::Dark ? Preferences::ColorScheme::Dark : Preferences::ColorScheme::Light;
    return Themes::firstThemeOfDarkness(scheme, Themes::count(), [](int index) { return Themes::isDark(index); });
}

std::string effectiveTitleText(const Preferences::Values& values, int surface)
{
    using Preferences::TitleComposition::Surface;
    const Surface resolved = surface == 1 ? Surface::Tab : surface == 2 ? Surface::Pane
                                                                        : Surface::Window;
    return std::string(Preferences::TitleComposition::effectiveText(values, resolved));
}

bool fontFeaturesEnableSlashedZero(const Preferences::Values& values)
{
    if (!values.fontFeatures.has_value())
        return false;
    for (const Rendering::FontFeatureSetting& setting : Rendering::parseFontFeatureSpecification(*values.fontFeatures)) {
        if (setting.tag == "zero")
            return setting.value != 0;
    }
    return false;
}

std::optional<std::string> fontFeaturesWithSlashedZero(const Preferences::Values& values, SlashedZero zero)
{
    Rendering::FontFeatureSettings settings = Rendering::parseFontFeatureSpecification(values.fontFeatures.value_or(""));
    auto existing = std::ranges::find_if(settings, [](const Rendering::FontFeatureSetting& setting) { return setting.tag == "zero"; });
    const bool isPresent = existing != settings.end();
    if (zero == SlashedZero::Enabled) {
        if (isPresent && existing->value != 0)
            return std::nullopt;
        if (isPresent)
            existing->value = 1;
        else
            settings.push_back({ "zero", 1 });
    } else {
        if (!isPresent || existing->value == 0)
            return std::nullopt;
        settings.erase(existing);
    }
    return Rendering::serializeFontFeatureSettings(settings);
}

bool isValidKeyBinding(const std::string& spec, const std::string& action)
{
    std::vector<Input::KeyChord> chords;
    if (!Input::parseKeySpec(spec, chords) || chords.empty())
        return false;
    return Input::parseAction(action).valid();
}

std::string keyBindingLine(const std::string& spec, const std::string& action)
{
    return "\"" + Preferences::escapeTOMLBasicString(spec) + "\" = \"" + Preferences::escapeTOMLBasicString(action) + "\"";
}

bool editPlatformOverride(PlatformSection platform, const std::string& field, PlatformOverrideEdit edit, const std::string& text, double number)
{
    const char* section = platform == PlatformSection::Mac ? "mac" : "linux";
    const Preferences::PlatformOverrideField* descriptor = Preferences::platformOverrideFieldForToken(field.c_str());
    if (!descriptor)
        return false;
    const std::string key = descriptor->tomlKey;
    if (edit == PlatformOverrideEdit::Remove) {
        static_cast<void>(Preferences::removeConfiguredSectionKey(section, key));
        return true;
    }
    // The table's kind, not the key's name, chooses the serializer: font_size
    // reads as a whole number, the other numbers as fractions, the rest as
    // quoted text.
    std::string toml;
    switch (descriptor->kind) {
    case Preferences::PlatformFieldKind::Integer:
        toml = Preferences::tomlInt(std::llround(number));
        break;
    case Preferences::PlatformFieldKind::Number:
        toml = Preferences::tomlDouble(number);
        break;
    case Preferences::PlatformFieldKind::String:
        toml = Preferences::tomlString(text);
        break;
    }
    return Preferences::configureOwnSectionKey(section, key, toml).has_value();
}

ImportedThemeSummary importTheme(const std::string& bytes)
{
    const Themes::ImportedTheme imported = Themes::importThemeFromBytes(bytes);
    ImportedThemeSummary summary;
    summary.ok = imported.ok;
    summary.name = imported.name;
    summary.isDark = Themes::importedThemeIsDark(imported);
    for (std::size_t index = 0; index < summary.ansi.size(); ++index)
        summary.ansi[index] = Themes::PackedThemeColors::pack(imported.ansi[index]);
    summary.foreground = Themes::PackedThemeColors::pack(imported.foreground);
    summary.background = Themes::PackedThemeColors::pack(imported.background);
    summary.cursor = Themes::PackedThemeColors::pack(imported.cursor);
    return summary;
}

AgentTokenRows listAgentTokens(const TextLines& lines, std::uint64_t nowUnix)
{
    std::vector<Protocol::Sync::TokenRecord> records;
    for (const std::string& line : lines)
        Protocol::Sync::parseTokenLine(line, records);
    AgentTokenRows rows;
    rows.reserve(records.size());
    for (const Protocol::Sync::TokenRecord& record : records) {
        rows.push_back({
            .identifier = record.hashHex,
            .label = record.label,
            .scope = Protocol::Sync::scopeMaskToString(Protocol::Sync::ScopeSet::fromRaw(record.scope.toRaw())),
            .expiry = Protocol::Sync::tokenExpiryName(Protocol::Sync::tokenExpiry(record, nowUnix)),
        });
    }
    return rows;
}

} // namespace Ubiquitty::SwiftBridge
