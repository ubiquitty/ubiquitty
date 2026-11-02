// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Web/WebFontInventory.h"

#include "Core/Rendering/Font/ScriptClassifier.h"
#include "Core/Unicode/Width.h"

#include <algorithm>

#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#endif

namespace Ubiquitty::Web {

namespace {

using Rendering::Font::CascadeResult;
using Rendering::Font::FontHandle;
using Rendering::Font::GlyphProbeResult;
using Rendering::Font::Presentation;

// The families a route falls through to when the terminal face has no glyph.
// One list, named once: it is the value of a route rather than a string built at
// a draw site, so the policy decides when it is reached instead of it applying
// to every draw.
constexpr std::string_view textCascadeFamilies = R"("Apple Symbols", "Segoe UI Symbol", "Noto Sans Symbols 2", sans-serif)";
constexpr std::string_view emojiCascadeFamilies = R"("Apple Color Emoji", "Noto Color Emoji", "Segoe UI Emoji", sans-serif)";
// Han lands here rather than on `textCascadeFamilies`: a symbol-oriented stack
// carries no CJK coverage, and a Latin `sans-serif` tail draws Unicode's
// replacement glyph shapes for it rather than the intended ideographs. Every
// name here is a CJK-capable system face on one platform this frontend ships
// on, and `sans-serif` is last so a machine with none of them still reaches
// the browser's own CJK-capable default rather than tofu.
constexpr std::string_view cjkCascadeFamilies = R"("PingFang SC", "Hiragino Sans", "Noto Sans CJK SC", "Microsoft YaHei", "SimSun", sans-serif)";

#ifdef __EMSCRIPTEN__

// Does `family` — a CSS font-family list — draw its own glyph for `codePoint`?
//
// A browser exposes no coverage API, so the question is answered by drawing:
//
//   1. the code point in `family, serif`
//   2. the same code point in a family that cannot exist, `serif`
//
// (2) is what the host draws when the named family contributes nothing at all,
// because
// a family no system has resolves exactly where an absent glyph falls to. Equal
// hashes mean the family added nothing and the answer is absent; different
// hashes mean the family drew.
//
// Comparing two sentinels instead — `family, serif` against `family, monospace`
// — cannot answer this, and fails on the most common case there is. A browser
// has a single system emoji font, so both sentinels fall through to it, the
// rasters agree, and every emoji reads as covered by the terminal face. Routing then
// hands the colour path a family with no colour glyph and the cell comes out
// empty.
//
// Drawing is compared by hashing the alpha channel rather than by measuring an
// advance: a face whose glyph happens to advance like the sentinel's is a false
// positive that costs a wrong font for the rest of the atlas slot's life, and
// width was the cheap answer to a question that is about shape.
//
// The probe owns a canvas of its own. It must never share the raster context:
// every property set here would otherwise persist into the next glyph the
// terminal draws, which is the defect
// `Tests/Core/Rendering/test_rasterizer_interleaving.cpp` guards against.
// clang-format off
EM_JS(int, webFontProbeCoverage, (const char* familyPtr, int codePoint), {
    const family = UTF8ToString(familyPtr);
    if (!family || typeof document === 'undefined')
        return 0;
    const quoted = (family.charCodeAt(0) === 34 || family.charCodeAt(0) === 39) && family.charCodeAt(family.length - 1) === family.charCodeAt(0);
    const familyKey = (quoted ? family.slice(1, -1) : family).toLowerCase();
    const coverage = Module.ubiquittyFontCoverage?.get(familyKey);
    if (coverage)
        return coverage(codePoint) ? 1 : 0;
    if (!Module.ubiquittyProbeContext) {
        const canvas = document.createElement('canvas');
        canvas.width = 48;
        canvas.height = 48;
        const context = canvas.getContext('2d', { alpha : true, willReadFrequently : true });
        // A canvas that cannot be read back cannot answer this. Returning absent
        // sends every code point down the cascade, which is the safe direction:
        // the rasterizer still draws, through the fallback face.
        if (!context || typeof context.getImageData !== 'function')
            return 0;
        Module.ubiquittyProbeCanvas = canvas;
        Module.ubiquittyProbeContext = context;
        Module.ubiquittyProbeNotdef = new Map();
        Module.ubiquittyProbeCoverage = new Map();
        Module.ubiquittyFamilyNotdef = new Map();
    }
    const context = Module.ubiquittyProbeContext;
    // One answer per family and code point, kept here rather than in Core.
    // `GlyphProbeMemo` asks a coarser question — one bool per 256-code-point
    // page — which cannot answer whether one given code point is covered, so it
    // cannot stand in for this. Three canvas readbacks is far too much to repeat
    // per cache miss on a screen of text.
    const memoKey = `${family}::${codePoint}`;
    const memoised = Module.ubiquittyProbeCoverage.get(memoKey);
    if (memoised !== undefined)
        return memoised;
    const hashOf = function(specification, text) {
        context.font = specification;
        context.textBaseline = 'alphabetic';
        context.textAlign = 'left';
        context.clearRect(0, 0, 48, 48);
        context.fillStyle = '#fff';
        context.fillText(text, 4, 36);
        const data = context.getImageData(0, 0, 48, 48).data;
        // FNV-1a over the alpha channel. The fill is opaque white, so alpha is
        // the shape and the colour channels carry nothing a probe needs.
        let hash = 2166136261;
        let ink = 0;
        for (let i = 3; i < data.length; i += 4) {
            hash ^= data[i];
            hash = Math.imul(hash, 16777619);
            if (data[i] > 8)
                ++ink;
        }
        return { hash : hash >>> 0, ink : ink };
    };
    const remember = function(present) {
        Module.ubiquittyProbeCoverage.set(memoKey, present);
        return present;
    };
    const text = String.fromCodePoint(codePoint);
    const privateUse = (codePoint >= 0xe000 && codePoint <= 0xf8ff) || (codePoint >= 0xf0000 && codePoint <= 0xffffd) || (codePoint >= 0x100000 && codePoint <= 0x10fffd);
    // Firefox's missing-glyph boxes include the scalar's hex digits, and
    // different families draw different boxes. Compare against a real known
    // fallback instead: an absent primary glyph resolves to this exact icon.
    if (privateUse && Module.ubiquittyFontCoverage?.get('symbols nerd font mono')?.(codePoint)) {
        const fallback = '"Symbols Nerd Font Mono"';
        const candidate = hashOf(`32px ${family}, ${fallback}`, text);
        return remember(candidate.hash !== hashOf(`32px ${fallback}`, text).hash ? 1 : 0);
    }
    const subject = hashOf(`32px ${family}, serif`, text);
    // Nothing drawn at all is not coverage. A face that declines a code point
    // silently draws blank in some browsers rather than a notdef box, and a
    // blank raster in an atlas slot is an invisible cell rather than a wrong one.
    if (!subject.ink)
        return remember(0);
    // Private-use misses can draw the requested face's own .notdef instead of
    // the generic fallback's. A different tofu box is still missing coverage.
    let familyNotdef = Module.ubiquittyFamilyNotdef.get(family);
    if (familyNotdef === undefined) {
        familyNotdef = hashOf(`32px ${family}, serif`, String.fromCodePoint(0x10ffff)).hash;
        Module.ubiquittyFamilyNotdef.set(family, familyNotdef);
    }
    if (subject.hash === familyNotdef)
        return remember(0);
    // What this code point looks like with no contribution from any named
    // family. Cached per code point rather than per family: the answer does not
    // depend on which family is being asked about.
    let withoutAnyFamily = Module.ubiquittyProbeNotdef.get(codePoint);
    if (withoutAnyFamily === undefined) {
        withoutAnyFamily = hashOf(`32px "ubiquitty no such family", serif`, text).hash;
        Module.ubiquittyProbeNotdef.set(codePoint, withoutAnyFamily);
    }
    return remember(subject.hash === withoutAnyFamily ? 0 : 1);
});
// clang-format on

// Is `family` installed, as distinct from resolving to the browser's default?
//
// Compared against a name no system can have. `document.fonts.check` cannot
// answer this: it reports whether the text can be rendered at all, and a family
// the machine does not have renders through the fallback, so it answers true
// for every name ever passed to it. A font list built from it shows every
// candidate as present, and choosing one draws the face already on screen.
//
// The comparison is of rasters, not of advances: a family absent on this
// machine draws the sample identically to a family that never existed, while
// one that happens to advance like the fallback does not.
// clang-format off
EM_JS(int, webFontFamilyIsPresent, (const char* familyPtr), {
    const family = UTF8ToString(familyPtr);
    if (!family || typeof document === 'undefined')
        return 0;
    // A loaded page face is an exact registration, even when it contains no
    // Latin letters for the system-font probe below to distinguish.
    if (document.fonts && typeof document.fonts[Symbol.iterator] === 'function') {
        const unquote = value => {
            const first = value.charCodeAt(0);
            const quoted = (first === 34 || first === 39) && value.charCodeAt(value.length - 1) === first;
            return (quoted ? value.slice(1, -1) : value).toLowerCase();
        };
        const unquoted = unquote(family);
        for (const face of document.fonts) {
            if (face.status === 'loaded' && unquote(face.family) === unquoted)
                return 1;
        }
    }
    if (!Module.ubiquittyFamilyProbeContext) {
        const canvas = document.createElement('canvas');
        canvas.width = 128;
        canvas.height = 48;
        const context = canvas.getContext('2d', { alpha : true, willReadFrequently : true });
        // Unreadable canvas: answer present, which is what this asked before and
        // routes the family to the rasterizer rather than hiding it. A false
        // present shows a font that does not change anything; a false absent
        // removes one that works.
        if (!context || typeof context.getImageData !== 'function')
            return 1;
        Module.ubiquittyFamilyProbeCanvas = canvas;
        Module.ubiquittyFamilyProbeContext = context;
        Module.ubiquittyFamilyProbe = new Map();
    }
    const memoised = Module.ubiquittyFamilyProbe.get(family);
    if (memoised !== undefined)
        return memoised;
    const context = Module.ubiquittyFamilyProbeContext;
    // Letters, digits and punctuation, because two monospace faces differ in
    // their letterforms rather than in their advances, and a sample of one
    // character can match by accident.
    const sample = 'ABCgjpq0189@#&';
    const hashOf = function(specification) {
        context.font = specification;
        context.textBaseline = 'alphabetic';
        context.textAlign = 'left';
        context.clearRect(0, 0, 128, 48);
        context.fillStyle = '#fff';
        context.fillText(sample, 2, 36);
        const data = context.getImageData(0, 0, 128, 48).data;
        let hash = 2166136261;
        for (let i = 3; i < data.length; i += 4) {
            hash ^= data[i];
            hash = Math.imul(hash, 16777619);
        }
        return hash >>> 0;
    };
    let absent = Module.ubiquittyFamilyProbeAbsent;
    if (absent === undefined) {
        absent = hashOf(`32px "ubiquitty no such family", serif`);
        Module.ubiquittyFamilyProbeAbsent = absent;
    }
    const present = hashOf(`32px ${family}, serif`) === absent ? 0 : 1;
    Module.ubiquittyFamilyProbe.set(family, present);
    return present;
});
// clang-format on

// The browser cannot expose a cluster's resolved font. A named candidate must
// contribute its own raster; a native cascade only needs to render the requested
// presentation. Equal candidate/cascade rasters conservatively use the cascade.
// clang-format off
EM_JS(int, webFontProbeCluster, (const char* familyPtr, const std::uint32_t* codePoints, int count, int presentation, int requireOwnFace), {
    const family = UTF8ToString(familyPtr);
    if (!family || count <= 0 || typeof document === 'undefined')
        return 0;
    let text = "";
    for (let index = 0; index < count; ++index)
        text += String.fromCodePoint(HEAPU32[(codePoints >> 2) + index]);
    if (!Module.ubiquittyClusterProbeContext) {
        const canvas = document.createElement('canvas');
        canvas.width = 256;
        canvas.height = 64;
        const context = canvas.getContext('2d', { alpha : true, willReadFrequently : true });
        if (!context || typeof context.getImageData !== 'function')
            return 0;
        Module.ubiquittyClusterProbeContext = context;
        Module.ubiquittyClusterProbeMemo = new Map();
    }
    const memo = Module.ubiquittyClusterProbeMemo;
    const key = JSON.stringify([family, text, presentation, requireOwnFace]);
    if (memo.has(key))
        return memo.get(key);
    const context = Module.ubiquittyClusterProbeContext;
    const raster = (specification, content = text) => {
        context.font = specification;
        context.textBaseline = 'alphabetic';
        context.textAlign = 'left';
        context.clearRect(0, 0, 256, 64);
        context.fillStyle = '#fff';
        context.fillText(content, 4, 46);
        const data = context.getImageData(0, 0, 256, 64).data;
        let hash = 2166136261;
        let ink = false;
        let color = false;
        for (let index = 0; index < data.length; index += 4) {
            for (let channel = 0; channel < 4; ++channel) {
                hash ^= data[index + channel];
                hash = Math.imul(hash, 16777619);
            }
            if (data[index + 3] > 16) {
                ink = true;
                if (data[index] < 248 || data[index + 1] < 248 || data[index + 2] < 248)
                    color = true;
            }
        }
        return { hash, ink, color };
    };
    const subject = raster(`32px ${family}, serif`);
    const notdef = raster(`32px ${family}, serif`, String.fromCodePoint(0x10ffff));
    const matchesPresentation = presentation === 2 ? subject.color : presentation !== 1 || !subject.color;
    const quoted = (family.charCodeAt(0) === 34 || family.charCodeAt(0) === 39) && family.charCodeAt(family.length - 1) === family.charCodeAt(0);
    const familyKey = (quoted ? family.slice(1, -1) : family).toLowerCase();
    const knownCoverage = Module.ubiquittyFontCoverage?.has(familyKey);
    const contributes = !requireOwnFace || knownCoverage || subject.hash !== raster('32px "ubiquitty no such family", serif').hash;
    const present = subject.ink && subject.hash !== notdef.hash && matchesPresentation && contributes ? 1 : 0;
    if (memo.size >= 4096)
        memo.clear();
    memo.set(key, present);
    return present;
});
// clang-format on

// Discards the memoised coverage.
//
// Family strings normally answer the same question forever, but a web font that
// finishes loading after the first probe changes what its family covers, and the
// generation bump is the moment the embedder says the mapping moved.
// clang-format off
EM_JS(void, webFontForgetProbes, (), {
    if (Module.ubiquittyProbeCoverage)
        Module.ubiquittyProbeCoverage.clear();
    if (Module.ubiquittyProbeNotdef)
        Module.ubiquittyProbeNotdef.clear();
    if (Module.ubiquittyFamilyNotdef)
        Module.ubiquittyFamilyNotdef.clear();
    if (Module.ubiquittyFamilyProbe)
        Module.ubiquittyFamilyProbe.clear();
    if (Module.ubiquittyClusterProbeMemo)
        Module.ubiquittyClusterProbeMemo.clear();
    delete Module.ubiquittyFamilyProbeAbsent;
});
// clang-format on

#else

// Off-target: no host text engine. Every probe answers absent, which routes
// every code point to the cascade and, past that, to the caller's fallback
// rasterizer — the same path a browser with no usable canvas takes.
#if UBIQUITTY_ENABLE_TEST_HOOKS
// Null hooks keep the absent-host default; an installed set is the stand-in
// engine the ForTest seam in the header describes.
ForTest::WebFontProbes webFontProbes {};
int webFontProbeCoverage(const char* family, int codePoint) { return webFontProbes.probeCoverage ? webFontProbes.probeCoverage(family, codePoint) : 0; }
int webFontFamilyIsPresent(const char* family) { return webFontProbes.familyIsPresent ? webFontProbes.familyIsPresent(family) : 0; }
int webFontProbeCluster(const char* family, const std::uint32_t* codePoints, int count, int presentation, int requireOwnFace)
{
    return webFontProbes.probeCluster ? webFontProbes.probeCluster(family, { codePoints, static_cast<std::size_t>(count) }, static_cast<Presentation>(presentation), requireOwnFace != 0) : 0;
}
#else
int webFontProbeCoverage(const char*, int) { return 0; }
int webFontFamilyIsPresent(const char*) { return 0; }
int webFontProbeCluster(const char*, const std::uint32_t*, int, int, int) { return 0; }
#endif
void webFontForgetProbes() { }

#endif

} // namespace

WebFontInventory::WebFontInventory(std::string primaryFamily)
    : m_primaryFamily(std::move(primaryFamily))
{
    webFontForgetProbes();
}

void WebFontInventory::bumpCatalogGeneration()
{
    ++m_generation;
    m_faces.clear();
    webFontForgetProbes();
}

FontHandle WebFontInventory::internFamily(std::string_view family, FamilyStanding standing)
{
    if (family.empty())
        return {};
    const auto existing = std::ranges::find_if(m_faces,
        [family](const FaceRecord& record) { return record.family == family; });
    if (existing != m_faces.end())
        return { static_cast<std::uint32_t>(std::distance(m_faces.begin(), existing)) + 1, m_generation };
    m_faces.push_back({ std::string(family), standing });
    return { static_cast<std::uint32_t>(m_faces.size()), m_generation };
}

const WebFontInventory::FaceRecord* WebFontInventory::recordFor(FontHandle font) const
{
    // A handle from a previous generation names a slot that has been reused, so
    // the generation is checked before the index rather than trusted with it.
    if (!font.isValid() || font.generation != m_generation || font.value > m_faces.size())
        return nullptr;
    return &m_faces[font.value - 1];
}

FontHandle WebFontInventory::primaryFont(Rendering::Font::FontStyle, std::uint8_t)
{
    // Style and weight do not select a family in a browser: they are separate
    // words in the CSS font shorthand, applied by whoever draws. The rasterizer
    // sets them per glyph, so every style shares this handle and Core's cache
    // key — which carries the style itself — keeps their routes apart.
    return internFamily(m_primaryFamily, FamilyStanding::Chosen);
}

FontHandle WebFontInventory::validateFamily(const Rendering::Font::FontFamilyRequest& request)
{
    if (request.family.empty())
        return {};
    const std::string family(request.family);
    if (!webFontFamilyIsPresent(family.c_str()))
        return {};
    return internFamily(request.family, FamilyStanding::Chosen);
}

GlyphProbeResult WebFontInventory::glyphForCodePoint(FontHandle font, std::uint32_t codePoint)
{
    const FaceRecord* record = recordFor(font);
    if (!record)
        return {};
    if (record->standing == FamilyStanding::NativeCascade) {
        return glyphForCluster(font, std::span(&codePoint, 1), Presentation::Default);
    }
    // A code point that draws no ink is absent, space included: the policy then
    // cascades to `Missing` and the caller's fallback face draws the blank.
    if (!webFontProbeCoverage(record->family.c_str(), static_cast<int>(codePoint)))
        return {};
    // Browsers expose no glyph identifier. Core routes by face and leaves
    // glyph lookup to the rasterizer, so this field can remain empty.
    return { font, {}, true, record->standing == FamilyStanding::LastResort };
}

GlyphProbeResult WebFontInventory::glyphForCluster(FontHandle font, std::span<const std::uint32_t> codePoints, Presentation presentation)
{
    const FaceRecord* record = recordFor(font);
    if (!record || codePoints.empty()) {
        return {};
    }
    const bool requireOwnFace = record->standing != FamilyStanding::NativeCascade;
    for (const std::uint32_t codePoint : codePoints) {
        if (!requireOwnFace) {
            break;
        }
        if (codePoint == 0x200D || (codePoint >= 0xFE00 && codePoint <= 0xFE0F) || (codePoint >= 0xE0100 && codePoint <= 0xE01EF)) {
            continue;
        }
        if (!webFontProbeCoverage(record->family.c_str(), static_cast<int>(codePoint))) {
            return {};
        }
    }
    if (!webFontProbeCluster(record->family.c_str(), codePoints.data(), static_cast<int>(codePoints.size()), static_cast<int>(presentation), requireOwnFace)) {
        return {};
    }
    return { font, {}, true, record->standing == FamilyStanding::LastResort };
}

CascadeResult WebFontInventory::cascadeThroughStack(std::string_view families, std::uint32_t codePoint)
{
    return cascadeThroughCluster(families, std::span(&codePoint, 1), Presentation::Default);
}

CascadeResult WebFontInventory::cascadeForCodePoint(const Rendering::Font::CascadeRequest& request)
{
    return cascadeForRun(request);
}

CascadeResult WebFontInventory::cascadeForRun(const Rendering::Font::CascadeRequest& request)
{
    if (request.codePoints.empty()) {
        return {};
    }
    const std::uint32_t lead = request.codePoints.front();
    const bool wantsEmoji = request.presentation == Presentation::Emoji
        || (request.presentation == Presentation::Default && Unicode::Width::isEmojiPresentation(lead));
    if (wantsEmoji) {
        return cascadeThroughCluster(emojiCascadeFamilies, request.codePoints, Presentation::Emoji);
    }
    const std::string_view families = Rendering::Font::classifyScript(lead) == Rendering::Font::ScriptClass::Han
        ? cjkCascadeFamilies
        : textCascadeFamilies;
    return cascadeThroughCluster(families, request.codePoints, request.presentation);
}

CascadeResult WebFontInventory::cascadeThroughCluster(std::string_view families, std::span<const std::uint32_t> codePoints, Presentation presentation)
{
    const FontHandle font = internFamily(families, FamilyStanding::NativeCascade);
    const GlyphProbeResult probe = glyphForCluster(font, codePoints, presentation);
    return { probe.font, probe.glyph, probe.present, probe.lastResort };
}

bool WebFontInventory::isLastResort(FontHandle font) const
{
    const FaceRecord* record = recordFor(font);
    return record != nullptr && record->standing == FamilyStanding::LastResort;
}

std::string_view WebFontInventory::familyName(FontHandle font) const
{
    const FaceRecord* record = recordFor(font);
    return record ? std::string_view(record->family) : std::string_view();
}

std::string_view WebFontInventory::fontSpecification(FontHandle font) const { return familyName(font); }

#if !defined(__EMSCRIPTEN__) && UBIQUITTY_ENABLE_TEST_HOOKS
namespace ForTest {
void installWebFontProbes(const WebFontProbes& probes) { webFontProbes = probes; }
} // namespace ForTest
#endif

} // namespace Ubiquitty::Web
