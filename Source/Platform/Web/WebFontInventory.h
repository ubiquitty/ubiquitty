// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

//
// Source/Platform/Web/WebFontInventory.h — the browser's half of Core's font
// routing seam.
//
// `Rendering::Font::FontFallbackPolicy` decides which family draws a code
// point; a backend answers only what the host can see — whether a family exists
// and whether it covers a code point. Core Text answers those for macOS and
// FreeType for Linux. A browser answers them by drawing.
//
// The browser cannot name the face its own cascade selected, so a cascade result
// here is the CSS font stack itself rather than the family behind it. That is
// enough: the stack re-resolves to the same face when the rasterizer draws with
// it, which is the only property a route has to have.
//

#include "Core/Rendering/Font/FontInventory.h"

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace Ubiquitty::Web {

/// Resolves families and glyph coverage through the embedder's text engine.
class WebFontInventory final : public Rendering::Font::FontInventory {
public:
    /// Creates an inventory over the font the embedder installed.
    ///
    /// - Parameter primaryFamily: The terminal face. Empty takes the family the
    ///   page set on the module, which is where the embedder normally puts it.
    explicit WebFontInventory(std::string primaryFamily = std::string());

    /// The generation every handle issued so far belongs to.
    ///
    /// - Returns: The current catalog generation.
    [[nodiscard]] std::uint32_t catalogGeneration() const override { return m_generation; }

    /// Invalidates every handle this inventory has issued.
    ///
    /// Core's caches key on the generation, so handles may be renumbered freely
    /// as long as this is called when the family mapping changes. Not calling it
    /// is the one way to make a stale route match.
    void bumpCatalogGeneration() override;

    /// Resolves the terminal face.
    ///
    /// Style and weight do not select a family in a browser — they are separate
    /// words in the CSS font shorthand, applied by whoever draws — so every
    /// style shares one handle and Core's cache key, which carries the style,
    /// keeps their routes apart.
    ///
    /// - Parameters:
    ///   - style: Ignored, for the reason above.
    ///   - variableWeight: Ignored, for the reason above.
    /// - Returns: The primary family's handle, invalid when none is installed.
    Rendering::Font::FontHandle primaryFont(Rendering::Font::FontStyle style, std::uint8_t variableWeight) override;

    /// Resolves a named family the policy wants to try.
    ///
    /// - Parameter request: The family to look for; style and weight are unused.
    /// - Returns: Its handle, or an invalid handle when the host has no such
    ///   family and would silently substitute its default.
    Rendering::Font::FontHandle validateFamily(const Rendering::Font::FontFamilyRequest& request) override;

    /// Whether a family draws its own glyph for a code point.
    ///
    /// Answered by drawing, because a browser exposes no coverage API.
    ///
    /// - Parameters:
    ///   - font: The family to ask about.
    ///   - codePoint: The code point to probe.
    /// - Returns: A probe carrying `font` when it covers the code point, and an
    ///   absent result otherwise.
    Rendering::Font::GlyphProbeResult glyphForCodePoint(Rendering::Font::FontHandle font, std::uint32_t codePoint) override;

    /// Probes a complete cluster and its requested text or emoji presentation.
    ///
    /// - Parameters:
    ///   - font: The candidate family or native cascade.
    ///   - codePoints: The complete cluster.
    ///   - presentation: The required text or emoji presentation.
    /// - Returns: The route when the candidate covers the complete cluster.
    Rendering::Font::GlyphProbeResult glyphForCluster(Rendering::Font::FontHandle font, std::span<const std::uint32_t> codePoints, Rendering::Font::Presentation presentation) override;

    /// Falls through to the browser's own cascade for a single code point.
    ///
    /// - Parameter request: Carries the code point; the base font is unused,
    ///   since a CSS stack names its own starting point.
    /// - Returns: The text cascade's handle when it covers the lead code point.
    Rendering::Font::CascadeResult cascadeForCodePoint(const Rendering::Font::CascadeRequest& request) override;

    /// Falls through to the browser's own cascade for a cluster.
    ///
    /// - Parameter request: Carries the cluster's code points.
    /// - Returns: The cascade handle that renders the cluster's presentation.
    Rendering::Font::CascadeResult cascadeForRun(const Rendering::Font::CascadeRequest& request) override;

    /// Resolves a code point through one CSS font stack.
    ///
    /// - Parameters:
    ///   - families: The stack to try.
    ///   - codePoint: The code point it must cover.
    /// - Returns: The stack's handle when it draws the code point, absent
    ///   otherwise.
    Rendering::Font::CascadeResult cascadeThroughStack(std::string_view families, std::uint32_t codePoint);

    /// Whether a handle names the host's last-resort face.
    ///
    /// - Parameter font: The handle to ask about.
    /// - Returns: True when the family is a last resort rather than a choice.
    [[nodiscard]] bool isLastResort(Rendering::Font::FontHandle font) const override;

    /// The family a handle names.
    ///
    /// - Parameter font: The handle to resolve.
    /// - Returns: Its CSS font-family list, empty when the handle is stale or
    ///   was issued by another inventory generation.
    [[nodiscard]] std::string_view familyName(Rendering::Font::FontHandle font) const override;

    /// Empty, as on macOS.
    ///
    /// Browsers expose no PostScript names, so diagnostics receive an empty value.
    ///
    /// - Parameter font: Unused.
    /// - Returns: An empty view, always.
    [[nodiscard]] std::string_view postScriptName(Rendering::Font::FontHandle font) const override
    {
        (void)font;
        return {};
    }

    /// The CSS font-family list a route resolves to, ready for a canvas.
    ///
    /// The rasterizer must draw with exactly the string that was probed: a probe
    /// answers a question about one font specification, and drawing with another
    /// answers a different one.
    ///
    /// - Parameter font: The handle a route resolved to.
    /// - Returns: The font-family list to set on a canvas context.
    [[nodiscard]] std::string_view fontSpecification(Rendering::Font::FontHandle font) const;

private:
    /// Whether a family was chosen or fallen back to when nothing else covered
    /// the code point.
    enum class FamilyStanding : std::uint8_t {
        Chosen,
        NativeCascade,
        LastResort,
    };

    /// Resolves a complete cluster through one native CSS font stack.
    ///
    /// - Parameters:
    ///   - families: The CSS font stack to probe.
    ///   - codePoints: The complete cluster.
    ///   - presentation: The required text or emoji presentation.
    /// - Returns: The native cascade handle when the cluster is covered.
    Rendering::Font::CascadeResult cascadeThroughCluster(std::string_view families, std::span<const std::uint32_t> codePoints, Rendering::Font::Presentation presentation);

    /// One interned family, addressed by its position in the catalog.
    struct FaceRecord {
        std::string family;
        FamilyStanding standing { FamilyStanding::Chosen };
    };

    /// Returns the handle for a family, adding it to the catalog if it is new.
    ///
    /// - Parameters:
    ///   - family: The CSS font-family list to intern.
    ///   - standing: Whether the family is a last resort rather than a choice.
    /// - Returns: Its handle in the current generation, invalid when `family` is
    ///   empty.
    Rendering::Font::FontHandle internFamily(std::string_view family, FamilyStanding standing);

    /// Resolves a handle against the current generation.
    ///
    /// - Parameter font: The handle to resolve.
    /// - Returns: Its record, or null when the handle is invalid or names a
    ///   generation that has been superseded.
    [[nodiscard]] const FaceRecord* recordFor(Rendering::Font::FontHandle font) const;

    std::string m_primaryFamily;
    std::uint32_t m_generation { 1 };
    std::vector<FaceRecord> m_faces;
};

#if UBIQUITTY_ENABLE_TEST_HOOKS
/// Test seam over the browser's probe entry points, the pair of
/// ``WebFontRasterizer``'s host seam: with both installed, the routing the
/// inventory feeds and the drawing the rasterizer maps run natively end to end.
namespace ForTest {
struct WebFontProbes {
    int (*probeCoverage)(const char* family, int codePoint) = nullptr;
    int (*familyIsPresent)(const char* family) = nullptr;
    int (*probeCluster)(const char* family, std::span<const std::uint32_t>, Rendering::Font::Presentation, bool requireOwnFace) = nullptr; // bool-ok: Mirrors the browser probe's named-face coverage predicate.
};
void installWebFontProbes(const WebFontProbes& probes);
} // namespace ForTest
#endif

} // namespace Ubiquitty::Web
