// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

/*
 * Tests/Platform/test_macos_pal.cpp
 *
 * Host-side coverage of the three macOS PAL backends that carry no window and
 * no Objective-C: the diagnostics sink, the bell and the clipboard.
 *
 * Diag: the stderr half is captured through a pipe, because it is the half a
 * person reads (Scripts/run-macos.sh --console streams it) and the half a view
 * without a terminator can get wrong. The unified-log half is not observable
 * from a test process and is not asserted here.
 *
 * Bell: the mode gate, through the backend's test-hook counter. Under
 * UBIQUITTY_ENABLE_TEST_HOOKS the backend counts every request and, once this
 * suite silences playback, returns ahead of the AudioToolbox call it still
 * compiles, so the four modes are separable without the suite sounding an alert
 * on every run.
 *
 * Clipboard: the PAL half against a recording stand-in for the Swift seam. What
 * is provable here is the contract the C++ file owns — the two guards, the byte
 * range handed over verbatim, the capacity and count that cross unchanged. The
 * pasteboard routing and the clamp on it are the Swift file's and are pinned in
 * the app, where AppKit exists
 * (Tests/Platform/test_ui_pasteboard_isolation.swift).
 *
 * Darwin-only: Tests/CMakeLists.txt keeps every test_macos_* out of a Linux
 * configure.
 */

#include "Assertions.h"

#include "PAL/PAL.h"
#include "Platform/macOS/Bell.h"
#include "Platform/macOS/ClipboardPasteboard.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <unistd.h>

namespace {

// ---- the Swift seam, recorded rather than performed -----------------
//
// Definitions rather than a link against the Swift module: this binary asserts
// what Clipboard.cpp does with the seam, and a real pasteboard would make the
// answers the machine's.

std::string s_lastSetText;
int s_setCalls = 0;
std::string s_pasteboardText = "clipboard";
bool s_hasPasteboardText = true;
int s_getCalls = 0;

// The stderr half of diagWrite, read back through a pipe.
//
// - Parameter write: What to run with stderr redirected.
// - Returns: Everything the call wrote to stderr.
std::string captureStandardError(void (*write)())
{
    int pipeEnds[2] = { -1, -1 };
    if (::pipe(pipeEnds) != 0)
        return {};
    const int savedStandardError = ::dup(STDERR_FILENO);
    std::fflush(stderr);
    (void)::dup2(pipeEnds[1], STDERR_FILENO);
    (void)::close(pipeEnds[1]);

    write();

    std::fflush(stderr);
    (void)::dup2(savedStandardError, STDERR_FILENO);
    (void)::close(savedStandardError);

    std::string captured;
    char buffer[256];
    for (;;) {
        const ssize_t got = ::read(pipeEnds[0], buffer, sizeof(buffer));
        if (got <= 0)
            break;
        captured.append(buffer, static_cast<std::size_t>(got));
    }
    (void)::close(pipeEnds[0]);
    return captured;
}

void writeOneDiagnostic() { Ubiquitty::PAL::diagWrite("parser: one miss"); }

void writeUnterminatedDiagnostic()
{
    // A slice of a larger buffer, the shape Core hands over when it dumps part
    // of the halt-journal ring: the bytes after the view are not the message.
    static const char ring[] = "ring: kept discarded";
    Ubiquitty::PAL::diagWrite(std::string_view(ring, 10));
}

void writeEmptyDiagnostic() { Ubiquitty::PAL::diagWrite({}); }

} // namespace

extern "C" void ubiquittyClipboardSetText(const char* utf8, std::size_t byteCount)
{
    ++s_setCalls;
    s_lastSetText.assign(utf8 ? utf8 : "", utf8 ? byteCount : 0);
}

extern "C" int ubiquittyClipboardGetText(char* outputBuffer, int outputCapacity)
{
    ++s_getCalls;
    if (!s_hasPasteboardText)
        return -1;
    const int count = static_cast<int>(s_pasteboardText.size()) < outputCapacity
        ? static_cast<int>(s_pasteboardText.size())
        : outputCapacity;
    std::memcpy(outputBuffer, s_pasteboardText.data(), static_cast<std::size_t>(count));
    return count;
}

int main()
{
    // ---- Diag ------------------------------------------------------
    CHECK(captureStandardError(writeOneDiagnostic) == "parser: one miss\n");
    // The view's length bounds the write; the terminator is this backend's.
    CHECK(captureStandardError(writeUnterminatedDiagnostic) == "ring: kept\n");
    // An empty message is a no-op rather than a bare newline, which is what
    // keeps a silent subsystem silent in the console stream.
    CHECK(captureStandardError(writeEmptyDiagnostic).empty());

    // ---- Bell ------------------------------------------------------
    using Ubiquitty::PAL::BellMode;
    // Before the first ring: every request below counts, and none of them is
    // heard.
    Ubiquitty::macOS::ForTest::silenceAlertPlayback();
    const int before = Ubiquitty::macOS::ForTest::alertSoundRequestCount();
    Ubiquitty::PAL::bellRing(BellMode::Off);
    Ubiquitty::PAL::bellRing(BellMode::Visual);
    CHECK(Ubiquitty::macOS::ForTest::alertSoundRequestCount() == before);
    Ubiquitty::PAL::bellRing(BellMode::Audio);
    CHECK(Ubiquitty::macOS::ForTest::alertSoundRequestCount() == before + 1);
    Ubiquitty::PAL::bellRing(BellMode::Both);
    CHECK(Ubiquitty::macOS::ForTest::alertSoundRequestCount() == before + 2);

    // ---- Clipboard -------------------------------------------------
    // The byte range crosses verbatim, terminator or not: the seam takes a
    // pointer and a count, and a text with an interior NUL keeps its length.
    const char payload[] = "one\0two";
    Ubiquitty::PAL::clipboardSetText(std::string_view(payload, sizeof(payload) - 1));
    CHECK(s_setCalls == 1);
    CHECK(s_lastSetText == std::string(payload, sizeof(payload) - 1));

    // An empty write reaches the seam, because clearing the clipboard is what
    // OSC 52 with an empty payload asks for.
    Ubiquitty::PAL::clipboardSetText({});
    CHECK(s_setCalls == 2);
    CHECK(s_lastSetText.empty());

    char buffer[32];
    std::memset(buffer, 'x', sizeof(buffer));
    CHECK(Ubiquitty::PAL::clipboardGetText(buffer, static_cast<int>(sizeof(buffer))) == 9);
    CHECK(std::string(buffer, 9) == "clipboard");

    // The capacity crosses the seam unchanged and the count crosses back: this
    // half neither clamps nor rewrites either. The clamp itself belongs to the
    // Swift seam — here the stand-in above performs it, so what a short read
    // pins on this side is only the pass-through.
    std::memset(buffer, 'x', sizeof(buffer));
    CHECK(Ubiquitty::PAL::clipboardGetText(buffer, 4) == 4);
    CHECK(std::string(buffer, 4) == "clip");
    CHECK(buffer[4] == 'x');

    // The two guards the PAL half owns: neither reaches the seam, and each
    // answers -1, so a caller cannot read a count out of a refusal.
    const int callsBeforeGuards = s_getCalls;
    CHECK(Ubiquitty::PAL::clipboardGetText(nullptr, 16) == -1);
    CHECK(Ubiquitty::PAL::clipboardGetText(buffer, 0) == -1);
    CHECK(Ubiquitty::PAL::clipboardGetText(buffer, -1) == -1);
    CHECK(s_getCalls == callsBeforeGuards);

    // An empty pasteboard is -1 and not zero, which is what lets Core tell "no
    // clipboard" from "the clipboard holds nothing".
    s_hasPasteboardText = false;
    CHECK(Ubiquitty::PAL::clipboardGetText(buffer, static_cast<int>(sizeof(buffer))) == -1);

    return UBIQUITTY_TEST_SUMMARY();
}
