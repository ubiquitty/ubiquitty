// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

// test_web_font_inventory — the browser backend's half of Core's font seam.
//
// Two halves, and only one is testable here. Coverage comes from drawing on a
// canvas, so off-target every probe answers absent and a case asserting "the
// terminal face has 'a'" would assert the stub rather than the backend. Those
// belong in the browser, where there is a font.
//
// The bookkeeping is what remains decidable natively, and that is where the
// seam can be got wrong. Core's caches key on `catalogGeneration`
// (FontFallbackCache.h's FontFallbackCacheKey) and `FontHandle::operator==`
// compares both value and generation, so a backend may renumber handles freely
// on one condition: it bumps the generation when the mapping changes. A backend that
// skips the bump lets a cached entry match a reused slot, which routes to a font
// the catalog no longer holds and surfaces as the wrong glyph rather than as a
// crash.
//
// So the cases below are about identity and invalidation, not about pixels.

#include "Platform/Web/WebFontInventory.h"

#include <string>

namespace {

using Ubiquitty::Rendering::Font::FontStyle;
using Ubiquitty::Web::WebFontInventory;

constexpr std::uint8_t noVariableWeight = 0;

} // namespace

TEST(theSameFamilyInternsToTheSameHandle)
{
    WebFontInventory inventory("Menlo");

    const auto first = inventory.primaryFont(FontStyle::Regular, noVariableWeight);
    const auto again = inventory.primaryFont(FontStyle::Regular, noVariableWeight);

    CHECK(first.isValid());
    CHECK(first == again);
    CHECK(inventory.familyName(first) == "Menlo");
}

TEST(styleDoesNotSelectAFamilyInABrowser)
{
    WebFontInventory inventory("Menlo");

    // Weight and slant are separate words in the CSS font shorthand, applied by
    // whoever draws rather than by choosing a face. Every style therefore shares
    // one handle, and Core keeps their routes apart through the cache key, which
    // carries the style itself.
    CHECK(inventory.primaryFont(FontStyle::Regular, noVariableWeight)
        == inventory.primaryFont(FontStyle::Bold, noVariableWeight));
}

TEST(bumpingTheGenerationInvalidatesEveryHandleItIssued)
{
    WebFontInventory inventory("Menlo");

    const auto before = inventory.primaryFont(FontStyle::Regular, noVariableWeight);
    CHECK(inventory.familyName(before) == "Menlo");

    inventory.bumpCatalogGeneration();

    // The old handle names a slot that has been reused. Resolving it must fail
    // rather than answer with whatever now sits at that index — the failure Core
    // relies on to keep a stale cache entry from routing to a dead font.
    CHECK(inventory.familyName(before).empty());
    CHECK(!inventory.isLastResort(before));

    const auto after = inventory.primaryFont(FontStyle::Regular, noVariableWeight);
    CHECK(after.isValid());
    CHECK(inventory.familyName(after) == "Menlo");

    // Same family, same index, and still not equal: the generation is what makes
    // them distinct, which is the property Core's defaulted operator== rests on.
    CHECK(before.value == after.value);
    CHECK(!(before == after));
}

TEST(aHandleCarriesNoIdentityOfTheInventoryThatIssuedIt)
{
    WebFontInventory first("Menlo");
    WebFontInventory second("Monaco");

    const auto handle = first.primaryFont(FontStyle::Regular, noVariableWeight);

    // Interning is lazy, so an inventory that has resolved nothing has no slot
    // to confuse and a foreign handle finds nothing there.
    CHECK(second.familyName(handle).empty());

    // Once it has interned its own primary the indices collide, and the same
    // handle answers with the wrong family. Stated because it is a hazard rather
    // than a guarantee: nothing in the seam prevents it — `FontHandle` is a pair
    // of integers naming no owner — so "a route never crosses inventories" holds
    // because there is one inventory, not because anything checks.
    (void)second.primaryFont(FontStyle::Regular, noVariableWeight);
    CHECK(second.familyName(handle) == "Monaco");
    CHECK(first.familyName(handle) == "Menlo");
}

TEST(anUnsetFamilyYieldsNoHandle)
{
    WebFontInventory inventory;

    // The embedder installed nothing. A backend that answered with a valid
    // handle over an empty family would send the policy to a font specification
    // of "", which the browser resolves to its default — a silent substitution
    // where Core expects a decline.
    CHECK(!inventory.primaryFont(FontStyle::Regular, noVariableWeight).isValid());
    CHECK(!inventory.validateFamily({ "", FontStyle::Regular, noVariableWeight }).isValid());
}

TEST(postScriptNameIsEmptyAsOnMacOS)
{
    WebFontInventory inventory("Menlo");
    const auto handle = inventory.primaryFont(FontStyle::Regular, noVariableWeight);

    // Browsers expose no PostScript name; diagnostics receive an empty value.
    CHECK(inventory.postScriptName(handle).empty());
}

UBIQUITTY_TEST_MAIN()
