// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once
// What the Linux frontend tells assistive technology about a terminal: the
// visible text as one string, and the maps from that string back to the grid
// and from the grid back to it, so a caret, a selection and a hit test all
// name the same characters.

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace Ubiquitty {
struct SelectionState;
struct Terminal;
}

namespace Ubiquitty::Linux::Accessibility {

/// One projected character's span in terminal-cell coordinates.
struct CharacterCells {
    int row = 0;
    int column = 0;
    int columns = 1;
};

/// The visible rows as a reader hears them, with the offsets that tie the
/// text to the cells it came from. Offsets count projected characters, which
/// is what a reader's cursor moves by, not columns and not bytes.
struct Snapshot {
    std::string text;
    /// UTF-8 boundaries for each scalar, including the final text boundary.
    std::vector<std::size_t> byteOffsets;
    /// Projected character offset at each grid cell boundary, including row ends.
    std::vector<uint32_t> cellOffsets;
    /// Cell spans for projected scalars, including a final insertion position.
    std::vector<CharacterCells> characterCells;
    int rows = 0;
    int columns = 0;
    /// Where the caret stands in `text`, as a character offset.
    std::uint32_t caretOffset = 0;
    /// The selected characters, `selectionStart` up to `selectionEnd`; equal
    /// when nothing is selected.
    std::uint32_t selectionStart = 0;
    std::uint32_t selectionEnd = 0;

    /// Whether the selected range holds at least one character.
    [[nodiscard]] bool hasSelection() const { return selectionStart < selectionEnd; }
};

/// Projects a terminal's visible rows for assistive technology.
///
/// - Parameters:
///   - term: The terminal, or null for an empty snapshot.
///   - viewOffset: How far the view is scrolled back into history.
///   - selection: The live selection, or null for none.
/// - Returns: The text, its grid maps, the caret and the selection.
[[nodiscard]] Snapshot snapshot(const Terminal* term, int viewOffset, const SelectionState* selection);

} // namespace Ubiquitty::Linux::Accessibility
