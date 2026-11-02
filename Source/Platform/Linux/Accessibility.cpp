// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Accessibility.cpp — the projection Core builds, with the caret and the
// selection resolved onto it, in the offsets AT-SPI counts by.

#include "Platform/Linux/Accessibility.h"

#include "Core/Accessibility/TextProjection.h"
#include "Core/Cell.h"
#include "Core/CellPen.h"
#include "Core/Screen/Addressing.h"
#include "Core/Selection/Selection.h"
#include "Core/Terminal.h"
#include "Core/TerminalOperations.h"

#include <algorithm>
#include <cassert>
#include <vector>

namespace Ubiquitty::Linux::Accessibility {
namespace {

// The terminal the selection's cell callbacks read, carried as their context.
struct SelectionContext {
    const Terminal* terminal;
};

const Cell& selectionCell(void* context, int row, int column)
{
    const auto* terminal = static_cast<SelectionContext*>(context)->terminal;
    return *(terminal->screens.isUsingAlternateScreen ? Screen::visibleCell(terminal, 0, row, column) : Screen::absoluteCell(terminal, row, column));
}

uint32_t selectionCellAt(void* context, int row, int column)
{
    return selectionCell(context, row, column).codePoint;
}

uint16_t selectionAttributesAt(void* context, int row, int column)
{
    return cellPen(selectionCell(context, row, column)).attributes.toRaw();
}

} // namespace

Snapshot snapshot(const Terminal* term, int viewOffset, const SelectionState* selection)
{
    // No terminal, or one with no cells, projects nothing: no text, no caret,
    // and a selection that is empty rather than invalid.
    if (!term || term->rows <= 0 || term->columns <= 0)
        return {};
    Snapshot result;
    auto projection = Ubiquitty::Accessibility::projectVisibleText(*term, viewOffset);
    result.rows = term->rows;
    result.columns = term->columns;
    std::vector<uint32_t> utf16Offsets;
    uint32_t utf16Offset = 0;
    for (std::size_t byte = 0; byte < projection.text.size(); ++byte) {
        const auto leading = static_cast<unsigned char>(projection.text[byte]);
        if ((leading & 0xc0u) == 0x80u)
            continue;
        result.byteOffsets.push_back(byte);
        utf16Offsets.push_back(utf16Offset);
        utf16Offset += leading >= 0xf0u ? 2u : 1u;
    }
    result.byteOffsets.push_back(projection.text.size());
    utf16Offsets.push_back(utf16Offset);
    const auto characterOffset = [&](uint32_t location) {
        return static_cast<uint32_t>(std::lower_bound(utf16Offsets.begin(), utf16Offsets.end(), location) - utf16Offsets.begin());
    };
    result.cellOffsets.reserve(projection.cellBoundaries.size());
    for (const auto& boundary : projection.cellBoundaries)
        result.cellOffsets.push_back(characterOffset(boundary.location));
    result.characterCells.resize(result.byteOffsets.size());
    for (int row = 0; row < term->rows; ++row) {
        const auto rowStart = static_cast<std::size_t>(row) * (static_cast<std::size_t>(term->columns) + 1);
        int textEndColumn = 0;
        for (int column = 0; column < term->columns; ++column) {
            const auto cell = rowStart + static_cast<std::size_t>(column);
            assert(cell + 1 < result.cellOffsets.size());
            const uint32_t start = result.cellOffsets[cell];
            const uint32_t end = result.cellOffsets[cell + 1];
            if (start == end)
                continue;
            int endColumn = column + 1;
            while (endColumn < term->columns && Ubiquitty::isTextContinuation(*Screen::visibleCell(term, viewOffset, row, endColumn)))
                ++endColumn;
            for (uint32_t character = start; character < end; ++character) {
                assert(character < result.characterCells.size());
                result.characterCells[character] = { row, column, endColumn - column };
            }
            textEndColumn = endColumn;
        }
        const auto end = result.cellOffsets[rowStart + static_cast<std::size_t>(term->columns)];
        assert(end < result.characterCells.size());
        result.characterCells[end] = { row, textEndColumn, 1 };
    }
    const auto caret = Ubiquitty::Accessibility::caretInProjection(projection, *term, viewOffset);
    if (caret.isValid)
        result.caretOffset = characterOffset(caret.location);
    SelectionBounds bounds;
    const int history = Screen::scrollableRowCount(term);
    SelectionContext context { term };
    if (selection && Selection::getBoundsWide(selection, history + term->rows, term->columns, selectionCellAt, &context, selectionAttributesAt, &context, &bounds)) {
        SelectionState resolved = *selection;
        resolved.anchorRow = bounds.row0;
        resolved.anchorColumn = bounds.column0;
        resolved.headRow = bounds.row1;
        resolved.headColumn = bounds.column1;
        resolved.startSubColumn = bounds.subColumn0;
        resolved.endSubColumn = bounds.subColumn1;
        const auto range = Selection::selectionInProjection(projection, resolved, history, Screen::resolvedViewOffset(term, viewOffset));
        if (range.isValid) {
            result.selectionStart = characterOffset(range.location);
            result.selectionEnd = characterOffset(range.location + range.length);
        }
    }
    // Taken last: the offsets above were computed against it in place.
    result.text = std::move(projection.text);
    return result;
}

} // namespace Ubiquitty::Linux::Accessibility
