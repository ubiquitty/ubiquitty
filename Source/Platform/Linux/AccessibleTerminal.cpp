// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/AccessibleTerminal.h"

#include "Core/Accessibility/TextProjection.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <memory>
#include <optional>
#include <vector>

namespace {

using Ubiquitty::Linux::Accessibility::Snapshot;

struct AccessibleState {
    Snapshot current;
    Snapshot announced;
    Ubiquitty::FloatPoint origin;
    Ubiquitty::FloatSize cell { 1.0f, 1.0f };
    Ubiquitty::Accessibility::NotifyThrottle throttle;
    std::vector<PangoLogAttr> boundaries;
    guint notifySource = 0;
    bool isRemovingText = false;
};

struct UbiquittyAccessibleTerminal {
    GtkWidget parent;
    std::unique_ptr<AccessibleState> state;
};

struct UbiquittyAccessibleTerminalClass {
    GtkWidgetClass parentClass;
};

void initializeTextInterface(GtkAccessibleTextInterface*);

G_DEFINE_TYPE_WITH_CODE(UbiquittyAccessibleTerminal, ubiquitty_accessible_terminal, GTK_TYPE_WIDGET,
    G_IMPLEMENT_INTERFACE(GTK_TYPE_ACCESSIBLE_TEXT, initializeTextInterface))

AccessibleState& stateOf(gpointer object)
{
    return *static_cast<UbiquittyAccessibleTerminal*>(object)->state;
}

const Snapshot& snapshotOf(gpointer object)
{
    auto& state = stateOf(object);
    return state.isRemovingText ? state.announced : state.current;
}

unsigned int characterCount(const Snapshot& snapshot)
{
    return snapshot.byteOffsets.empty() ? 0u : static_cast<unsigned int>(snapshot.byteOffsets.size() - 1);
}

GBytes* getContents(GtkAccessibleText* object, unsigned int start, unsigned int end)
{
    const auto& snapshot = snapshotOf(object);
    const unsigned int count = characterCount(snapshot);
    start = std::min(start, count);
    end = std::clamp(end, start, count);
    if (start == end)
        return g_bytes_new_static("", 0);
    assert(end < snapshot.byteOffsets.size());
    const auto first = snapshot.byteOffsets[start];
    return g_bytes_new(snapshot.text.data() + first, snapshot.byteOffsets[end] - first);
}

GBytes* getContentsAt(GtkAccessibleText* object, unsigned int offset, GtkAccessibleTextGranularity granularity, unsigned int* start, unsigned int* end)
{
    auto& state = stateOf(object);
    const auto& snapshot = snapshotOf(object);
    const unsigned int count = characterCount(snapshot);
    offset = std::min(offset, count);
    *start = *end = offset;
    if (offset == count)
        return getContents(object, offset, offset);
    if (granularity == GTK_ACCESSIBLE_TEXT_GRANULARITY_LINE || granularity == GTK_ACCESSIBLE_TEXT_GRANULARITY_PARAGRAPH) {
        while (*start > 0 && snapshot.text[snapshot.byteOffsets[*start - 1]] != '\n')
            --*start;
        while (*end < count && snapshot.text[snapshot.byteOffsets[*end]] != '\n')
            ++*end;
        if (*end < count)
            ++*end;
    } else {
        // Segmentation is queried by assistive clients; it never shapes glyphs
        // and is cached independently of the visual renderer's font machinery.
        std::vector<PangoLogAttr> removedBoundaries;
        auto& boundaries = state.isRemovingText ? removedBoundaries : state.boundaries;
        if (boundaries.empty()) {
            boundaries.resize(static_cast<std::size_t>(count) + 1);
            pango_get_log_attrs(snapshot.text.data(), static_cast<int>(snapshot.text.size()), -1,
                pango_language_get_default(), boundaries.data(), static_cast<int>(boundaries.size()));
        }
        const auto isBoundary = [&](unsigned int index) {
            assert(index < boundaries.size());
            if (!index || index == count)
                return true;
            if (granularity == GTK_ACCESSIBLE_TEXT_GRANULARITY_WORD)
                return boundaries[index].is_word_start != 0;
            if (granularity == GTK_ACCESSIBLE_TEXT_GRANULARITY_SENTENCE)
                return boundaries[index].is_sentence_start != 0;
            return boundaries[index].is_cursor_position != 0;
        };
        while (*start > 0 && !isBoundary(*start))
            --*start;
        ++*end;
        while (*end < count && !isBoundary(*end))
            ++*end;
    }
    return getContents(object, *start, *end);
}

unsigned int getCaretPosition(GtkAccessibleText* object)
{
    return snapshotOf(object).caretOffset;
}

gboolean getSelection(GtkAccessibleText* object, gsize* count, GtkAccessibleTextRange** ranges)
{
    const auto& snapshot = snapshotOf(object);
    *count = snapshot.hasSelection() ? 1 : 0;
    if (ranges) {
        *ranges = nullptr;
        if (*count) {
            *ranges = g_new(GtkAccessibleTextRange, 1);
            **ranges = { snapshot.selectionStart, snapshot.selectionEnd - snapshot.selectionStart };
        }
    }
    return *count != 0;
}

gboolean getAttributes(GtkAccessibleText*, unsigned int, gsize* count, GtkAccessibleTextRange** ranges, char*** names, char*** values)
{
    *count = 0;
    if (ranges)
        *ranges = nullptr;
    if (names)
        *names = nullptr;
    if (values)
        *values = nullptr;
    return FALSE;
}

void getDefaultAttributes(GtkAccessibleText*, char*** names, char*** values)
{
    if (names) {
        *names = g_new0(char*, 2);
        (*names)[0] = g_strdup("editable");
    }
    if (values) {
        *values = g_new0(char*, 2);
        (*values)[0] = g_strdup("false");
    }
}

gboolean getExtents(GtkAccessibleText* object, unsigned int start, unsigned int end, graphene_rect_t* extents)
{
    auto& state = stateOf(object);
    const auto& snapshot = snapshotOf(object);
    const unsigned int count = characterCount(snapshot);
    if (start > count || end < start || snapshot.characterCells.empty())
        return FALSE;
    end = std::min(end, count);
    assert(start < snapshot.characterCells.size());
    const auto& first = snapshot.characterCells[start];
    float left = static_cast<float>(first.column);
    float top = static_cast<float>(first.row);
    float right = left;
    float bottom = top + 1.0f;
    for (unsigned int index = start; index < end; ++index) {
        assert(index < snapshot.characterCells.size());
        const auto& cells = snapshot.characterCells[index];
        left = std::min(left, static_cast<float>(cells.column));
        top = std::min(top, static_cast<float>(cells.row));
        right = std::max(right, static_cast<float>(cells.column + cells.columns));
        bottom = std::max(bottom, static_cast<float>(cells.row + 1));
    }
    graphene_rect_init(extents, state.origin.x + left * state.cell.width,
        state.origin.y + top * state.cell.height, (right - left) * state.cell.width,
        (bottom - top) * state.cell.height);
    return TRUE;
}

gboolean getOffset(GtkAccessibleText* object, const graphene_point_t* point, unsigned int* offset)
{
    auto& state = stateOf(object);
    const auto& snapshot = snapshotOf(object);
    const float x = (point->x - state.origin.x) / state.cell.width;
    const float y = (point->y - state.origin.y) / state.cell.height;
    if (!std::isfinite(x) || !std::isfinite(y) || x < 0 || y < 0 || x >= snapshot.columns || y >= snapshot.rows)
        return FALSE;
    const auto row = static_cast<std::size_t>(y);
    const auto column = static_cast<std::size_t>(x);
    const auto cell = row * (static_cast<std::size_t>(snapshot.columns) + 1) + column;
    if (cell >= snapshot.cellOffsets.size())
        return FALSE;
    *offset = snapshot.cellOffsets[cell];
    // A wide continuation maps to the scalar drawn over both cells.
    while (*offset > 0) {
        const auto& previous = snapshot.characterCells[*offset - 1];
        if (previous.row != static_cast<int>(row) || previous.column > static_cast<int>(column)
            || previous.column + previous.columns <= static_cast<int>(column))
            break;
        --*offset;
    }
    return TRUE;
}

void initializeTextInterface(GtkAccessibleTextInterface* interface)
{
    interface->get_contents = getContents;
    interface->get_contents_at = getContentsAt;
    interface->get_caret_position = getCaretPosition;
    interface->get_selection = getSelection;
    interface->get_attributes = getAttributes;
    interface->get_default_attributes = getDefaultAttributes;
    interface->get_extents = getExtents;
    interface->get_offset = getOffset;
}

void notifyChanges(UbiquittyAccessibleTerminal* terminal)
{
    auto& state = *terminal->state;
    auto* accessible = GTK_ACCESSIBLE_TEXT(terminal);
    const bool didTextChange = state.announced.text != state.current.text;
    if (didTextChange) {
        state.isRemovingText = true;
        gtk_accessible_text_update_contents(accessible, GTK_ACCESSIBLE_TEXT_CONTENT_CHANGE_REMOVE, 0, characterCount(state.announced));
        state.isRemovingText = false;
        gtk_accessible_text_update_contents(accessible, GTK_ACCESSIBLE_TEXT_CONTENT_CHANGE_INSERT, 0, characterCount(state.current));
    }
    if (didTextChange || state.announced.caretOffset != state.current.caretOffset)
        gtk_accessible_text_update_caret_position(accessible);
    if (didTextChange || state.announced.selectionStart != state.current.selectionStart || state.announced.selectionEnd != state.current.selectionEnd)
        gtk_accessible_text_update_selection_bound(accessible);
    state.announced = state.current;
}

void disposeTerminal(GObject* object)
{
    auto& state = stateOf(object);
    if (state.notifySource) {
        g_source_remove(state.notifySource);
        state.notifySource = 0;
    }
    G_OBJECT_CLASS(ubiquitty_accessible_terminal_parent_class)->dispose(object);
}

void finalizeTerminal(GObject* object)
{
    std::destroy_at(&reinterpret_cast<UbiquittyAccessibleTerminal*>(object)->state);
    G_OBJECT_CLASS(ubiquitty_accessible_terminal_parent_class)->finalize(object);
}

void ubiquitty_accessible_terminal_class_init(UbiquittyAccessibleTerminalClass* terminalClass)
{
    auto* objectClass = G_OBJECT_CLASS(terminalClass);
    objectClass->dispose = disposeTerminal;
    objectClass->finalize = finalizeTerminal;
    gtk_widget_class_set_accessible_role(GTK_WIDGET_CLASS(terminalClass), GTK_ACCESSIBLE_ROLE_TERMINAL);
}

void ubiquitty_accessible_terminal_init(UbiquittyAccessibleTerminal* terminal)
{
    // GObject allocates the instance; explicitly begin its C++ member lifetime.
    std::construct_at(&terminal->state, std::make_unique<AccessibleState>());
    gtk_widget_set_can_target(GTK_WIDGET(terminal), FALSE);
    gtk_accessible_update_property(GTK_ACCESSIBLE(terminal), GTK_ACCESSIBLE_PROPERTY_LABEL, "Terminal",
        GTK_ACCESSIBLE_PROPERTY_READ_ONLY, TRUE, GTK_ACCESSIBLE_PROPERTY_MULTI_LINE, TRUE, -1);
}

} // namespace

namespace Ubiquitty::Linux::Accessibility {

GtkWidget* createTerminal()
{
    return GTK_WIDGET(g_object_new(ubiquitty_accessible_terminal_get_type(), nullptr));
}

void updateTerminal(GtkWidget* widget, Snapshot snapshot, FloatPoint origin, FloatSize cell)
{
    auto& state = stateOf(widget);
    state.origin = origin;
    state.cell = cell;
    const bool didTextChange = state.current.text != snapshot.text;
    const bool didChange = didTextChange || state.current.caretOffset != snapshot.caretOffset
        || state.current.selectionStart != snapshot.selectionStart || state.current.selectionEnd != snapshot.selectionEnd;
    if (didTextChange)
        state.boundaries.clear();
    state.current = std::move(snapshot);
    if (!didChange)
        return;
    const double now = static_cast<double>(g_get_monotonic_time()) / 1e6;
    const auto decision = state.throttle.noteChange(now);
    auto* terminal = reinterpret_cast<UbiquittyAccessibleTerminal*>(widget);
    if (decision.action == Ubiquitty::Accessibility::NotifyThrottle::Action::PostNow) {
        if (state.notifySource) {
            g_source_remove(state.notifySource);
            state.notifySource = 0;
        }
        state.throttle.noteTrailingFired(now);
        notifyChanges(terminal);
    } else if (decision.action == Ubiquitty::Accessibility::NotifyThrottle::Action::ScheduleTrailing) {
        state.notifySource = g_timeout_add(static_cast<guint>(std::ceil(decision.delaySeconds * 1000.0)), [](gpointer object) -> gboolean {
            auto& state = stateOf(object);
            state.notifySource = 0;
            state.throttle.noteTrailingFired(static_cast<double>(g_get_monotonic_time()) / 1e6);
            notifyChanges(static_cast<UbiquittyAccessibleTerminal*>(object));
            return G_SOURCE_REMOVE; }, terminal);
    }
}

} // namespace Ubiquitty::Linux::Accessibility
