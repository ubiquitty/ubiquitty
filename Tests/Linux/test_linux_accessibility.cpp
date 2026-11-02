// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

#include "Core/Selection/Selection.h"
#include "Core/Terminal.h"
#include "Core/TerminalOperations.h"
#include "Platform/Linux/Accessibility.h"

#include <cstdio>
#include <string>
#include <string_view>

TEST(theSnapshotCarriesTheVisibleTextTheCaretAndTheSelection)
{
    // A letter, a two-column emoji and a letter, then the cursor. The
    // selection covers the first three cells, which project as two
    // characters: offsets count what a reader hears, not columns.
    Ubiquitty::Terminal terminal;
    Ubiquitty::resize(terminal, 2, 8, Ubiquitty::Modes::ReflowMode::Fixed);
    static constexpr std::string_view typed = "A\xF0\x9F\x98\x80"
                                              "B";
    Ubiquitty::processBytes(&terminal, typed);

    Ubiquitty::SelectionState selection;
    Ubiquitty::Selection::init(&selection);
    Ubiquitty::Selection::begin(&selection, 2, 8, 0, 0, Ubiquitty::SelectionMode::Character);
    Ubiquitty::Selection::update(&selection, 2, 8, 0, 2);

    const Ubiquitty::Linux::Accessibility::Snapshot snapshot = Ubiquitty::Linux::Accessibility::snapshot(&terminal, 0, &selection);
    CHECK_MSG(snapshot.text == std::string(typed) + "\n", "the visible text is the typed row and its line end");
    CHECK_EQ(snapshot.caretOffset, 3u);
    CHECK_EQ(snapshot.selectionStart, 0u);
    CHECK_EQ(snapshot.selectionEnd, 2u);
    CHECK(snapshot.hasSelection());
}

TEST(theCaretOffsetCountsTheCharactersTheProjectionEmitted)
{
    // The projection is Core's and it emits a sized block's glyph once, for
    // the row that owns it. The offsets here walk the grid instead, so they
    // have to skip the cells the projection skipped — a walk that counts a
    // block's lower rows puts the caret one character further along for every
    // band above it, and the screen reader reads from the wrong place.
    //
    // The caret sits on a row the block covers and that also carries text of
    // its own past the block's columns. On a row with nothing else the walk's
    // final clamp to the row's end hides the drift, which is why the obvious
    // fixture proves nothing here.
    Ubiquitty::Terminal terminal;
    Ubiquitty::resize(terminal, 6, 14, Ubiquitty::Modes::ReflowMode::Fixed);
    terminal.drawsSizedText = true;
    terminal.drawsProportionalText = true;
    Ubiquitty::processBytes(&terminal, "\x1b[H\x1b]66;s=3;A\x07");
    Ubiquitty::processBytes(&terminal, "\x1b[3;6Habcdef");
    terminal.screens.active->cursorY = 2;
    terminal.screens.active->cursorX = 8; // the 'd'

    Ubiquitty::SelectionState selection;
    Ubiquitty::Selection::init(&selection);
    const auto snapshot = Ubiquitty::Linux::Accessibility::snapshot(&terminal, 0, &selection);

    // The offset the caret reports has to land on the character the caret is
    // on. Asserting the character rather than the number keeps the case from
    // re-deriving the arithmetic it is checking.
    char ubqMessage[192];
    const char at = snapshot.caretOffset < snapshot.text.size() ? snapshot.text[snapshot.caretOffset] : '?';
    std::snprintf(ubqMessage, sizeof(ubqMessage), "caret %u lands on '%c', not the 'd' it sits on", snapshot.caretOffset, at);
    CHECK_MSG(at == 'd', ubqMessage);
}

TEST(projectedCharacterCoordinatesIncludeCompleteClustersAndWideCells)
{
    Ubiquitty::Terminal terminal;
    Ubiquitty::resize(terminal, 2, 8, Ubiquitty::Modes::ReflowMode::Fixed);
    Ubiquitty::processBytes(&terminal, "A\xF0\x9F\x98\x80"
                                       "e\xCC\x81\xCC\x82");
    const auto result = Ubiquitty::Linux::Accessibility::snapshot(&terminal, 0, nullptr);
    CHECK_EQ(result.caretOffset, 5u);
    REQUIRE(result.byteOffsets.size() == 7u);
    REQUIRE(result.characterCells.size() == 7u);
    REQUIRE(result.cellOffsets.size() >= 5u);
    CHECK_EQ(result.characterCells[1].column, 1);
    CHECK_EQ(result.characterCells[1].columns, 2);
    CHECK_EQ(result.characterCells[2].column, 3);
    CHECK_EQ(result.characterCells[3].column, 3);
    CHECK_EQ(result.characterCells[4].column, 3);
    CHECK_EQ(result.cellOffsets[4], 5u);
    CHECK_EQ(result.characterCells[5].row, 0);
    CHECK_EQ(result.characterCells[5].column, 4);
    CHECK_EQ(result.characterCells[6].row, 1);
    CHECK_EQ(result.characterCells[6].column, 0);
}

TEST(aSelectionOnAWideContinuationKeepsTheGlyphInTheProjection)
{
    Ubiquitty::Terminal terminal;
    Ubiquitty::resize(terminal, 2, 8, Ubiquitty::Modes::ReflowMode::Fixed);
    Ubiquitty::processBytes(&terminal, "A\xF0\x9F\x98\x80"
                                       "B");
    Ubiquitty::SelectionState selection;
    Ubiquitty::Selection::init(&selection);
    Ubiquitty::Selection::begin(&selection, 2, 8, 0, 2, Ubiquitty::SelectionMode::Character);
    Ubiquitty::Selection::update(&selection, 2, 8, 0, 2);
    const auto result = Ubiquitty::Linux::Accessibility::snapshot(&terminal, 0, &selection);
    CHECK_EQ(result.selectionStart, 1u);
    CHECK_EQ(result.selectionEnd, 2u);
}

UBIQUITTY_TEST_MAIN()