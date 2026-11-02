// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Source/Platform/Linux/Clipboard.cpp — see Clipboard.h.

#include "Platform/Linux/Clipboard.h"

#include <cstring>
#include <memory>
#include <vector>

#include <gdk/gdk.h>

namespace Ubiquitty::Linux {
namespace Clipboard {

namespace {
std::string gLastSetText;
std::vector<RecordedItem> recordedSetItems;
ReadRequestHandler gReadRequestHandler = nullptr;
} // namespace

void recordLastSetText(const std::string& text) { gLastSetText = text; }

const std::string& lastSetText() { return gLastSetText; }

void recordLastSetItems(std::vector<RecordedItem> items) { recordedSetItems = std::move(items); }

const std::vector<RecordedItem>& lastSetItems() { return recordedSetItems; }

void setReadRequestHandler(ReadRequestHandler handler) { gReadRequestHandler = handler; }

ReadRequestHandler readRequestHandler() { return gReadRequestHandler; }

} // namespace Clipboard

namespace {

// The system clipboard's text write, on the UI thread.
void setSystemText(const std::string& text, ClipboardBuffer buffer)
{
    Clipboard::recordLastSetText(text); // headless test capture
    GdkDisplay* display = gdk_display_get_default();
    if (!display)
        return; // no display (headless self-test); the capture above still ran
    gdk_clipboard_set_text(buffer == ClipboardBuffer::Primary ? gdk_display_get_primary_clipboard(display) : gdk_display_get_clipboard(display), text.c_str());
}

// The system clipboard's typed write, on the UI thread.
void setSystemItems(std::vector<Clipboard::RecordedItem> recorded, ClipboardBuffer buffer)
{
    for (const Clipboard::RecordedItem& item : recorded) {
        if (Ubiquitty::mimeIsTextPlain(item.mime))
            Clipboard::recordLastSetText(item.bytes);
    }
    Clipboard::recordLastSetItems(std::move(recorded));
    GdkDisplay* display = gdk_display_get_default();
    if (!display)
        return; // no display (headless self-test); the capture above still ran
    std::vector<GdkContentProvider*> providers;
    providers.reserve(Clipboard::lastSetItems().size() + 1);
    for (const Clipboard::RecordedItem& item : Clipboard::lastSetItems()) {
        GBytes* bytes = g_bytes_new(item.bytes.data(), item.bytes.size());
        providers.push_back(gdk_content_provider_new_for_bytes(item.mime.c_str(), bytes));
        g_bytes_unref(bytes);
        if (Ubiquitty::mimeIsTextPlain(item.mime)) {
            GValue value = G_VALUE_INIT;
            g_value_init(&value, G_TYPE_STRING);
            g_value_set_string(&value, item.bytes.c_str());
            providers.push_back(gdk_content_provider_new_for_value(&value));
            g_value_unset(&value);
        }
    }
    if (providers.empty()) {
        gdk_clipboard_set_text(buffer == ClipboardBuffer::Primary ? gdk_display_get_primary_clipboard(display) : gdk_display_get_clipboard(display), "");
        return; // an empty set clears, as the untyped write's empty string does
    }
    GdkContentProvider* content = gdk_content_provider_new_union(providers.data(), providers.size());
    gdk_clipboard_set_content(buffer == ClipboardBuffer::Primary ? gdk_display_get_primary_clipboard(display) : gdk_display_get_clipboard(display), content);
    g_object_unref(content);
}

// A write that crossed from the parser's thread: the bytes travel, and the
// GDK call runs where GDK may be called. The main context owns the payload
// from the post to the destroy notify.
struct TextWrite {
    std::string text;
    ClipboardBuffer buffer;
};

struct ItemsWrite {
    std::vector<Clipboard::RecordedItem> items;
    ClipboardBuffer buffer;
};

gboolean applyTextWrite(gpointer data)
{
    setSystemText(static_cast<TextWrite*>(data)->text, static_cast<TextWrite*>(data)->buffer);
    return G_SOURCE_REMOVE;
}

gboolean applyItemsWrite(gpointer data)
{
    setSystemItems(std::move(static_cast<ItemsWrite*>(data)->items), static_cast<ItemsWrite*>(data)->buffer);
    return G_SOURCE_REMOVE;
}

} // namespace

LinuxClipboardClient::LinuxClipboardClient()
    : m_uiThread(g_thread_self())
{
}

void LinuxClipboardClient::writeClipboard(ClipboardBuffer buffer, std::span<const char> bytes)
{
    // An empty payload clears the buffer (sets the empty string).
    std::string text(bytes.data(), bytes.size());
    // Secondary and cut buffers have no GDK clipboard.
    if (buffer != ClipboardBuffer::Clipboard && buffer != ClipboardBuffer::Primary) {
        const std::scoped_lock hold(m_lock);
        m_buffers[static_cast<int>(buffer)] = std::move(text);
        return;
    }
    if (isOnUIThread()) {
        setSystemText(text, buffer);
        return;
    }
    auto write = std::make_unique<TextWrite>(TextWrite { std::move(text), buffer });
    g_main_context_invoke_full(nullptr, G_PRIORITY_DEFAULT, applyTextWrite, write.release(),
        [](gpointer data) { delete static_cast<TextWrite*>(data); });
}

std::string LinuxClipboardClient::internalBuffer(ClipboardBuffer buffer) const
{
    const std::scoped_lock hold(m_lock);
    return m_buffers[static_cast<int>(buffer)];
}

bool LinuxClipboardClient::requestClipboardRead(ClipboardBuffer buffer, std::string_view setSpec, ClipboardReadConfirmation confirmation)
{
    // The live GTK read needs the window + runtime (main.cpp); route through the
    // frontend-installed handler. None installed (headless) ⇒ decline so Core
    // drops the query cleanly (false → no reply).
    Clipboard::ReadRequestHandler handler = Clipboard::readRequestHandler();
    if (!handler)
        return false;
    return handler(this, m_requester, buffer, setSpec, confirmation);
}

int LinuxClipboardClient::readClipboard(ClipboardBuffer /*buffer*/, std::span<char> outputBuffer)
{
    if (outputBuffer.empty())
        return -1;
    const std::scoped_lock hold(m_lock);
    if (!m_readBytesStaged)
        return -1; // nothing staged (read refused) — Core sends no reply
    const std::size_t n = m_readBytes.size() < outputBuffer.size() ? m_readBytes.size() : outputBuffer.size();
    if (n > 0)
        std::memcpy(outputBuffer.data(), m_readBytes.data(), n);
    m_readBytesStaged = false; // consume this one-shot staging
    m_readBytes.clear();
    return static_cast<int>(n);
}

void LinuxClipboardClient::provideClipboardReadBytes(ClipboardBuffer /*buffer*/, std::span<const char> bytes)
{
    const std::scoped_lock hold(m_lock);
    if (!bytes.empty())
        m_readBytes.assign(bytes.data(), bytes.size());
    else
        m_readBytes.clear();
    m_readBytesStaged = true; // staged (even when empty) → a reply is owed
}

void LinuxClipboardClient::writeClipboardItems(ClipboardBuffer buffer, std::span<const Ubiquitty::ClipboardItem> items)
{
    if (buffer != ClipboardBuffer::Clipboard && buffer != ClipboardBuffer::Primary) {
        Ubiquitty::ClipboardClient::writeClipboardItems(buffer, items);
        return;
    }
    std::vector<Clipboard::RecordedItem> recorded;
    recorded.reserve(items.size());
    for (const Ubiquitty::ClipboardItem& item : items)
        recorded.push_back({ std::string { item.mime }, std::string(item.bytes.data(), item.bytes.size()) });
    if (isOnUIThread()) {
        setSystemItems(std::move(recorded), buffer);
        return;
    }
    auto write = std::make_unique<ItemsWrite>(ItemsWrite { std::move(recorded), buffer });
    g_main_context_invoke_full(nullptr, G_PRIORITY_DEFAULT, applyItemsWrite, write.release(),
        [](gpointer data) { delete static_cast<ItemsWrite*>(data); });
}

void LinuxClipboardClient::provideClipboardReadItems(ClipboardBuffer buffer, std::span<const Ubiquitty::ClipboardItem> items)
{
    if (buffer != ClipboardBuffer::Clipboard && buffer != ClipboardBuffer::Primary)
        return;
    const std::scoped_lock hold(m_lock);
    m_typedStaged.stage(items);
    m_typedStagedBuffer = buffer;
}

int LinuxClipboardClient::readClipboardTypes(ClipboardBuffer buffer, std::span<char> out)
{
    if (buffer != ClipboardBuffer::Clipboard && buffer != ClipboardBuffer::Primary)
        return -1;
    const std::scoped_lock hold(m_lock);
    return buffer == m_typedStagedBuffer ? m_typedStaged.serveTypes(out) : -1;
}

int LinuxClipboardClient::readClipboardItem(ClipboardBuffer buffer, std::string_view mime, std::span<char> out)
{
    if (buffer != ClipboardBuffer::Clipboard && buffer != ClipboardBuffer::Primary)
        return -1;
    const std::scoped_lock hold(m_lock);
    return buffer == m_typedStagedBuffer ? m_typedStaged.serveItem(mime, out) : -1;
}

} // namespace Ubiquitty::Linux
