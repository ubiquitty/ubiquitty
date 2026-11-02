// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

// test_typed_pasteboard.cpp — the MIME-typed NSPasteboard bridge both macOS
// shells share: the mapping, the typed apply, the bounded capture, and the
// snapshot a deferred read serves from. The mapping is Swift
// (Platform/macOS/TypedPasteboard.swift) and this drives it through the C++
// seam the app's own C++ calls (Platform/macOS/TypedPasteboard.cpp), so what
// is pinned here is what the shells run. Every case drives a uniquely named
// pasteboard, so the user's clipboard is never part of a test run.

#include "Platform/macOS/TypedPasteboard.h"

#include <cstdio>
#include <string>
#include <string_view>
#include <unistd.h>
#include <vector>

namespace {

// A per-process unique pasteboard, released on scope exit: two test runs
// must not see each other's leftovers.
struct ScopedPasteboard {
    std::string name;
    ScopedPasteboard()
    {
        char buffer[64];
        std::snprintf(buffer, sizeof buffer, "ubq-test-pasteboard-%d", static_cast<int>(::getpid()));
        name = buffer;
    }
    ~ScopedPasteboard() { Ubiquitty::TypedPasteboard::releaseNamed(name); }
};

// One item over owned bytes, because ClipboardItem is a view.
Ubiquitty::ClipboardItem item(std::string_view mime, std::string_view bytes)
{
    return { mime, { bytes.data(), bytes.size() } };
}

std::string typeList(const Ubiquitty::Clipboard::Snapshot& snapshot)
{
    char buffer[512];
    const int n = snapshot.typeList(buffer);
    return std::string(buffer, static_cast<std::size_t>(n > 0 ? n : 0));
}

std::string itemBytes(const Ubiquitty::Clipboard::Snapshot& snapshot, std::string_view mime)
{
    char buffer[4096];
    const int n = snapshot.item(mime, buffer);
    if (n < 0)
        return "<unserved>";
    return std::string(buffer, static_cast<std::size_t>(n));
}

} // namespace

TEST(testTypedApplyRoundTripsThroughCapture)
{
    ScopedPasteboard pasteboard;
    const std::vector<Ubiquitty::ClipboardItem> items = {
        item("text/plain", "Hi"),
        item("text/html", "<p>Hi</p>"),
    };
    Ubiquitty::TypedPasteboard::apply(pasteboard.name, items);

    const auto snapshot = Ubiquitty::TypedPasteboard::capture(pasteboard.name, 4096);
    CHECK(!snapshot.isEmpty());
    CHECK(itemBytes(snapshot, "text/plain") == "Hi");
    CHECK(itemBytes(snapshot, "text/html") == "<p>Hi</p>");
    // The requested name matches caselessly, parameters ignored, as on the
    // seam it serves.
    CHECK(itemBytes(snapshot, "TEXT/Plain;charset=utf-8") == "Hi");
    CHECK(itemBytes(snapshot, "image/png") == "<unserved>");
}

// A name written with its parameters lands where the bare type does.
//
// A write of "text/plain;charset=utf-8" that skipped the strip would go to a
// dynamic UTI of its own — readable by nothing, and invisible because the read
// side strips and would report the type missing rather than misfiled. The two
// sides strip separately, so covering one says nothing about the other.
TEST(testAppliedNameKeepsItsParametersOutOfTheMapping)
{
    ScopedPasteboard pasteboard;
    // text/html rather than text/plain: apply answers plain text before the
    // mapping is consulted at all, so a plain-text case exercises none of it.
    Ubiquitty::TypedPasteboard::apply(pasteboard.name, { { item("text/html;charset=utf-8", "<p>Hi</p>") } });

    const auto snapshot = Ubiquitty::TypedPasteboard::capture(pasteboard.name, 4096);
    CHECK(!snapshot.isEmpty());
    // Under the bare name, which is what a reader on the other side asks for.
    CHECK(itemBytes(snapshot, "text/html") == "<p>Hi</p>");
    CHECK(typeList(snapshot).find("text/html") != std::string::npos);
}

TEST(testCaptureListsEachMimeOnce)
{
    ScopedPasteboard pasteboard;
    Ubiquitty::TypedPasteboard::apply(pasteboard.name, { { item("text/plain", "once") } });

    const auto snapshot = Ubiquitty::TypedPasteboard::capture(pasteboard.name, 4096);
    const std::string list = typeList(snapshot);
    // A pasteboard lists plain text under several spellings; the capture
    // dedups to the one MIME the seam serves.
    CHECK(list.find("text/plain") != std::string::npos);
    CHECK(list.find("text/plain") == list.rfind("text/plain"));
}

TEST(testNonTextPayloadRoundTripsAsData)
{
    ScopedPasteboard pasteboard;
    // Binary bytes with a NUL inside: the data path must not treat the
    // payload as a string anywhere.
    const std::string png("\x89PNG\0\x1a", 6);
    Ubiquitty::TypedPasteboard::apply(pasteboard.name, { { item("image/png", png) } });

    const auto snapshot = Ubiquitty::TypedPasteboard::capture(pasteboard.name, 4096);
    CHECK(itemBytes(snapshot, "image/png") == png);
}

TEST(testCaptureBoundsEachItem)
{
    ScopedPasteboard pasteboard;
    const std::string big(1000, 'z');
    Ubiquitty::TypedPasteboard::apply(pasteboard.name, { { item("text/plain", big) } });

    const auto snapshot = Ubiquitty::TypedPasteboard::capture(pasteboard.name, 16);
    CHECK(itemBytes(snapshot, "text/plain") == std::string(16, 'z'));
}

TEST(testApplyReplacesThePreviousContents)
{
    ScopedPasteboard pasteboard;
    Ubiquitty::TypedPasteboard::apply(pasteboard.name, { { item("text/html", "<p>old</p>") } });
    Ubiquitty::TypedPasteboard::apply(pasteboard.name, { { item("text/plain", "new") } });

    const auto snapshot = Ubiquitty::TypedPasteboard::capture(pasteboard.name, 4096);
    CHECK(itemBytes(snapshot, "text/plain") == "new");
    CHECK(itemBytes(snapshot, "text/html") == "<unserved>");
}

TEST(testEmptyApplyClearsAndCaptureIsEmpty)
{
    ScopedPasteboard pasteboard;
    Ubiquitty::TypedPasteboard::apply(pasteboard.name, { { item("text/plain", "soon gone") } });
    Ubiquitty::TypedPasteboard::apply(pasteboard.name, {});

    const auto snapshot = Ubiquitty::TypedPasteboard::capture(pasteboard.name, 4096);
    CHECK(snapshot.isEmpty());
    CHECK(typeList(snapshot).empty());
}

TEST(testAppPrivateMimeRoundTripsThroughADynamicType)
{
    ScopedPasteboard pasteboard;
    // A MIME no fixed table names: the type database mints a dynamic
    // identifier for it, and the capture resolves the identifier back — an
    // app-private flavour survives the pasteboard whole.
    Ubiquitty::TypedPasteboard::apply(pasteboard.name,
        { { item("application/x-ubiquitty-probe", "private bytes") } });

    const auto snapshot = Ubiquitty::TypedPasteboard::capture(pasteboard.name, 4096);
    CHECK(itemBytes(snapshot, "application/x-ubiquitty-probe") == "private bytes");
}

TEST(testANameNoMappingAnswersIsDropped)
{
    ScopedPasteboard pasteboard;
    // Not a MIME shape at all: nothing can name it, so apply drops it and
    // the kept item is unaffected.
    Ubiquitty::TypedPasteboard::apply(pasteboard.name,
        { { item("text/plain", "kept"), item("no-slash-here", "dropped") } });

    const auto snapshot = Ubiquitty::TypedPasteboard::capture(pasteboard.name, 4096);
    CHECK(itemBytes(snapshot, "text/plain") == "kept");
    CHECK(itemBytes(snapshot, "no-slash-here") == "<unserved>");
}

TEST(testCaptureDedupsTheSpellingsARealPasteboardLists)
{
    ScopedPasteboard pasteboard;
    // Real applications leave plain text under several type spellings; the
    // raw writes build that shape into the generation the clear opened, and
    // the capture serves one text/plain.
    Ubiquitty::TypedPasteboard::apply(pasteboard.name, {});
    Ubiquitty::TypedPasteboard::applyDataForType(pasteboard.name, "public.utf8-plain-text", { "same", 4 });
    Ubiquitty::TypedPasteboard::applyDataForType(pasteboard.name, "public.plain-text", { "same", 4 });

    const auto snapshot = Ubiquitty::TypedPasteboard::capture(pasteboard.name, 4096);
    const std::string list = typeList(snapshot);
    CHECK(list.find("text/plain") != std::string::npos);
    CHECK(list.find("text/plain") == list.rfind("text/plain"));
    CHECK(itemBytes(snapshot, "text/plain") == "same");
}

TEST(testListedTextThatDoesNotDecodeClaimsNothing)
{
    ScopedPasteboard pasteboard;
    // Invalid UTF-8 under the text type: the string read answers nil, and a
    // type the capture cannot read as text is not claimed. The html item
    // proves the write generation took — the claim is about decoding, not
    // about an empty pasteboard.
    Ubiquitty::TypedPasteboard::apply(pasteboard.name, { { item("text/html", "<p>") } });
    Ubiquitty::TypedPasteboard::applyDataForType(pasteboard.name, "public.utf8-plain-text", { "\xff\xfe\xfd", 3 });

    const auto snapshot = Ubiquitty::TypedPasteboard::capture(pasteboard.name, 4096);
    CHECK(itemBytes(snapshot, "text/html") == "<p>");
    CHECK(itemBytes(snapshot, "text/plain") == "<unserved>");
}

TEST(testNamesThatAreNotUTF8AddressNothing)
{
    // A pasteboard name or MIME that is not UTF-8 resolves to no pasteboard
    // and no type: every operation answers by doing nothing, and the item
    // beside the bad one still lands.
    const std::string bad("\xff\xfe", 2);
    Ubiquitty::TypedPasteboard::apply(bad, { { item("text/plain", "lost") } });
    Ubiquitty::TypedPasteboard::applyDataForType(bad, "public.utf8-plain-text", { "lost", 4 });
    CHECK(Ubiquitty::TypedPasteboard::capture(bad, 16).isEmpty());
    Ubiquitty::TypedPasteboard::releaseNamed(bad);
    Ubiquitty::TypedPasteboard::releaseNamed({}); // the general pasteboard is nobody's to release

    ScopedPasteboard pasteboard;
    Ubiquitty::TypedPasteboard::apply(pasteboard.name, { { item(bad, "dropped"), item("text/plain", "kept") } });
    const auto snapshot = Ubiquitty::TypedPasteboard::capture(pasteboard.name, 4096);
    CHECK(itemBytes(snapshot, "text/plain") == "kept");
}

TEST(testTheEmptyNameAddressesTheGeneralPasteboard)
{
    // Read-only against the user's own pasteboard: one bounded capture,
    // nothing written, nothing asserted about what it holds.
    (void)Ubiquitty::TypedPasteboard::capture({}, 1);
}

UBIQUITTY_TEST_MAIN()
