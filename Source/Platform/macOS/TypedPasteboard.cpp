// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "TypedPasteboard.h"

#include "Core/Protocol/Sync/NativeAttachment.h"

#include <string>
#include <vector>

// The Swift module's C entry points (Source/Platform/macOS/TypedPasteboard.swift).
// Declared here rather than in the header: the mapping is Swift's, and a C++
// caller of this component names the C++ API above, never the seam.
//
// Names and payloads cross as pointer and length, because a pasteboard name or
// a MIME name may hold bytes that are not UTF-8 and a C string cannot carry a
// length anyway. Swift decodes, and a range that does not decode addresses
// nothing.
extern "C" {

void ubiquittyTypedPasteboardClear(const char* pasteboardName, std::size_t pasteboardNameLength);

void ubiquittyTypedPasteboardSetItem(const char* pasteboardName, std::size_t pasteboardNameLength,
    const char* mime, std::size_t mimeLength, const void* bytes, std::size_t byteCount);

void ubiquittyTypedPasteboardSetTypeData(const char* pasteboardName, std::size_t pasteboardNameLength,
    const char* typeIdentifier, std::size_t typeIdentifierLength, const void* bytes, std::size_t byteCount);

void ubiquittyTypedPasteboardCapture(const char* pasteboardName, std::size_t pasteboardNameLength,
    std::size_t perItemBound, void* context,
    void (*receive)(void* context, const char* mime, std::size_t mimeLength, const void* bytes, std::size_t byteCount));

void ubiquittyTypedPasteboardRelease(const char* pasteboardName, std::size_t pasteboardNameLength);

} // extern "C"

namespace Ubiquitty::TypedPasteboard {

namespace {

// A view's bytes as a pointer Swift can always dereference. An empty view
// carries a null pointer, and the length says the range is empty, but the
// parameter is non-optional on the Swift side.
const char* begin(std::string_view view)
{
    return view.empty() ? "" : view.data();
}

// C linkage, because the capture below hands this across as a function
// pointer and Swift receives it as `@convention(c)`. The unnamed namespace
// keeps the name this translation unit's own.
extern "C" {

// One captured payload, appended to the snapshot the capture is building.
void receiveItem(void* context, const char* mime, std::size_t mimeLength, const void* bytes, std::size_t byteCount)
{
    auto* snapshot = static_cast<Snapshot*>(context);
    std::vector<char> owned;
    if (byteCount > 0) {
        const auto* first = static_cast<const char*>(bytes);
        owned.assign(first, first + byteCount);
    }
    snapshot->add(std::string(mime, mimeLength), std::move(owned));
}

} // extern "C"

} // namespace

void apply(std::string_view pasteboardName, std::span<const ClipboardItem> items)
{
    ubiquittyTypedPasteboardClear(begin(pasteboardName), pasteboardName.size());
    for (const ClipboardItem& item : items) {
        ubiquittyTypedPasteboardSetItem(begin(pasteboardName), pasteboardName.size(),
            begin(item.mime), item.mime.size(), item.bytes.data(), item.bytes.size());
    }
}

Snapshot capture(std::string_view pasteboardName, std::size_t perItemBound)
{
    Snapshot snapshot;
    ubiquittyTypedPasteboardCapture(begin(pasteboardName), pasteboardName.size(), perItemBound, &snapshot, receiveItem);
    return snapshot;
}

void applyDataForType(std::string_view pasteboardName, std::string_view typeIdentifier, std::span<const char> bytes)
{
    ubiquittyTypedPasteboardSetTypeData(begin(pasteboardName), pasteboardName.size(),
        begin(typeIdentifier), typeIdentifier.size(), bytes.data(), bytes.size());
}

bool captureForRemote(const std::function<void(std::span<const ClipboardItem>)>& sink)
{
    const Snapshot snapshot = capture({}, Protocol::Sync::maxClipboardServeBytes);
    std::vector<ClipboardItem> views;
    views.reserve(snapshot.items().size());
    for (const Clipboard::SnapshotItem& item : snapshot.items())
        views.push_back({ item.mime, { item.bytes.data(), item.bytes.size() } });
    sink(views);
    return true;
}

void releaseNamed(std::string_view pasteboardName)
{
    ubiquittyTypedPasteboardRelease(begin(pasteboardName), pasteboardName.size());
}

} // namespace Ubiquitty::TypedPasteboard
