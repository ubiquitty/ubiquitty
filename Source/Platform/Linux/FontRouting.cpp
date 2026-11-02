// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/FontRouting.h"
#include "Platform/Linux/Raster.h"

#include "Core/Preferences/FontRoutePreferences.h"
#include "Core/Preferences/PreferencesAccessors.h"
#include "Core/Rendering/Font/FontFallbackPolicy.h"
#include "Core/Rendering/Font/FontRouteDiagnostics.h"
#include "Core/Rendering/Font/FontRoutingSession.h"
#include "Core/Rendering/Font/ScriptClassifier.h"
#include "Platform/Linux/FontInventory.h"

#include <cstdint>
#include <optional>
#include <span>
#include <sstream>

namespace Ubiquitty::Linux {

std::string diagnoseCPUFontRoutes(std::string_view utf8Text) { return diagnoseFontRoutes(utf8Text, "cpu"); }

namespace {

struct RoutingState {
    std::optional<LinuxFontInventory> inventory;
    Preferences::FontRoutePreferences preferences;
    Rendering::Font::FontRoutingSession session;
};

RoutingState& routeState()
{
    static RoutingState state;
    return state;
}

bool decodeNextUTF8(std::string_view text, std::size_t& index, std::uint32_t& codePoint)
{
    if (index >= text.size())
        return false;
    const unsigned char lead = static_cast<unsigned char>(text[index++]);
    if (lead < 0x80) {
        codePoint = lead;
        return true;
    }
    int extra = 0;
    if ((lead & 0xE0) == 0xC0) {
        extra = 1;
        codePoint = lead & 0x1F;
    } else if ((lead & 0xF0) == 0xE0) {
        extra = 2;
        codePoint = lead & 0x0F;
    } else if ((lead & 0xF8) == 0xF0) {
        extra = 3;
        codePoint = lead & 0x07;
    } else {
        codePoint = 0xFFFD;
        return true;
    }
    for (int i = 0; i < extra; ++i) {
        if (index >= text.size()) {
            codePoint = 0xFFFD;
            return true;
        }
        const unsigned char continuation = static_cast<unsigned char>(text[index++]);
        if ((continuation & 0xC0) != 0x80) {
            codePoint = 0xFFFD;
            return true;
        }
        codePoint = (codePoint << 6) | (continuation & 0x3F);
    }
    return true;
}

Rendering::Font::CellWidthClass widthForScript(Rendering::Font::ScriptClass script)
{
    using Rendering::Font::CellWidthClass;
    using Rendering::Font::ScriptClass;
    return (script == ScriptClass::Han || script == ScriptClass::Kana || script == ScriptClass::Hangul || script == ScriptClass::Emoji) ? CellWidthClass::Wide : CellWidthClass::Narrow;
}

Rendering::Font::FontRouteAtlasFamily atlasFromRoute(const Rendering::Font::GlyphRoute& route)
{
    using namespace Rendering::Font;
    if (hasRouteFlag(route.flags, RouteFlag::MissingGlyph))
        return FontRouteAtlasFamily::Missing;
    if (hasRouteFlag(route.flags, RouteFlag::ColorAtlas))
        return FontRouteAtlasFamily::Color;
    if (hasRouteFlag(route.flags, RouteFlag::ShapedRun))
        return FontRouteAtlasFamily::Shaped;
    if (hasRouteFlag(route.flags, RouteFlag::WideAtlas))
        return FontRouteAtlasFamily::Wide;
    if (hasRouteFlag(route.flags, RouteFlag::SymbolPath))
        return FontRouteAtlasFamily::Procedural;
    return FontRouteAtlasFamily::Mono;
}

} // namespace

void configureFontRouting(int fontPixelSize, const Preferences::Values& config)
{
    RoutingState& state = routeState();
    state.inventory.emplace(fontPixelSize, config.fontFamily.value_or(std::string()), std::string(),
        Preferences::Effective::matchFallbackSize(config) ? Rendering::FontMetrics::FallbackSizing::MatchPrimary : Rendering::FontMetrics::FallbackSizing::Nominal);
    state.preferences = Preferences::buildFontRoutePreferences(config);
    state.session.reset();
}

std::string diagnoseFontRoutes(std::string_view utf8Text, const char* rendererName)
{
    RoutingState& state = routeState();
    if (!state.inventory)
        state.inventory.emplace(16, std::string());
    Rendering::Font::FontFallbackPolicy policy(*state.inventory, { state.session.han, state.session.script, state.session.generic, state.session.emoji, state.session.symbol, state.session.rangeMap, state.session.negative });
    std::ostringstream output;
    output << "renderer=" << (rendererName ? rendererName : "unknown") << '\n';
    std::size_t index = 0;
    while (index < utf8Text.size()) {
        std::uint32_t codePoint = 0;
        if (!decodeNextUTF8(utf8Text, index, codePoint))
            break;
        Rendering::Font::FontRequest request;
        request.codePoints = std::span<const std::uint32_t>(&codePoint, 1);
        request.script = Rendering::Font::classifyScript(codePoint);
        request.presentation = request.script == Rendering::Font::ScriptClass::Emoji ? Rendering::Font::Presentation::Emoji : Rendering::Font::Presentation::Default;
        request.width = widthForScript(request.script);
        request.preferenceGeneration = state.preferences.generation;
        Rendering::Font::GlyphRoute route = policy.route(request, state.preferences.view());

        Rendering::Font::FontRouteDiagnostic diagnostic;
        diagnostic.codePoints = std::span<const std::uint32_t>(&codePoint, 1);
        diagnostic.script = request.script;
        diagnostic.width = route.width;
        diagnostic.source = route.source;
        diagnostic.familyName = state.inventory->familyName(route.font);
        diagnostic.postScriptName = state.inventory->postScriptName(route.font);
        diagnostic.glyph = route.glyph;
        diagnostic.cacheState = Rendering::Font::FontRouteCacheState::Miss;
        diagnostic.atlas = atlasFromRoute(route);
        diagnostic.shapedRun = Rendering::Font::hasRouteFlag(route.flags, Rendering::Font::RouteFlag::ShapedRun);
        diagnostic.color = Rendering::Font::hasRouteFlag(route.flags, Rendering::Font::RouteFlag::ColorAtlas);
        diagnostic.missing = route.source == Rendering::Font::FontSource::Missing;
        diagnostic.lastResort = state.inventory->isLastResort(route.font);
        diagnostic.cascadeCalls = state.session.han.counters().nativeCascadeCalls + state.session.generic.counters().nativeCascadeCalls;
        char line[512];
        Rendering::Font::formatFontRouteDiagnostic(diagnostic, line, sizeof(line));
        output << line << '\n';
    }
    return output.str();
}

} // namespace Ubiquitty::Linux
