// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// The Linux ClipboardClient (OSC 52). Bridges Core's per-Terminal ClipboardClient
// hooks to GDK's clipboard. The write path also RECORDS the last UTF-8 string it
// was handed (the capture seam) so headless self-tests — where the real gdk write
// is a no-op — can assert the SET path's bytes.
//
// Two threads reach an instance. The parser calls the reads and writes on
// whichever thread drains the Terminal — Core's ingest thread in the window, the
// GTK thread in a headless run — and the GTK thread stages what an asynchronous
// read captured. The staging and the internal buffers sit under one mutex; a
// GDK write made off the UI thread hops to it with its bytes.

#include "PAL/TerminalClients.h"

#include <glib.h>

#include <mutex>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace Ubiquitty::Linux {

class LinuxClipboardClient;

namespace Clipboard {

// Store the most recent text passed to the system clipboard. UI thread only.
void recordLastSetText(const std::string& text);
const std::string& lastSetText();

struct RecordedItem {
    std::string mime;
    std::string bytes;
};
// Store the most recent typed set passed to the system clipboard. UI thread only.
void recordLastSetItems(std::vector<RecordedItem> items);
const std::vector<RecordedItem>& lastSetItems();

// The frontend's OSC 52 read handler. Called on the parser's thread with the
// client's requester context, which the handler carries to the UI thread.
using ReadRequestHandler = bool (*)(LinuxClipboardClient* client, void* requester, Ubiquitty::ClipboardBuffer buffer, std::string_view setSpec, Ubiquitty::ClipboardReadConfirmation confirmation);
void setReadRequestHandler(ReadRequestHandler);
ReadRequestHandler readRequestHandler();

} // namespace Clipboard

class LinuxClipboardClient final : public Ubiquitty::ClipboardClient {
public:
    /// Makes a client whose UI thread is the constructing one.
    ///
    /// A system-clipboard write from any other thread hops to it.
    LinuxClipboardClient();

    /// Names the pane this client answers for.
    ///
    /// The read handler receives it opaque, on the parser's thread, and
    /// carries it to the UI thread as a weak reference.
    ///
    /// - Parameter requester: The pane, as the handler expects it.
    void setRequester(void* requester) { m_requester = requester; }

    /// Whether the caller runs on the thread that constructed this client.
    ///
    /// - Returns: True on the UI thread.
    [[nodiscard]] bool isOnUIThread() const { return g_thread_self() == m_uiThread; }

    // Clipboard and Primary route to GDK; secondary and cut buffers stay internal.
    void writeClipboard(Ubiquitty::ClipboardBuffer buffer, std::span<const char> bytes) override;

    // GDK reads are async on the UI thread; Core must route even Allow through
    // requestClipboardRead so the frontend stages the bytes first (true keeps a
    // single code path for internal buffers too).
    [[nodiscard]] bool requiresAsynchronousClipboardRead() override { return true; }

    // OSC 52 READ ('?'): under Prompt, ask the user; on allow async-read + stage +
    // complete; on deny complete with approved=false. Returns true (handled async).
    [[nodiscard]] bool requestClipboardRead(Ubiquitty::ClipboardBuffer buffer, std::string_view setSpec, Ubiquitty::ClipboardReadConfirmation confirmation) override;

    // Serve the bytes most recently staged by provideClipboardReadBytes.
    // Returns the byte count, or -1 if nothing was staged (read refused).
    [[nodiscard]] int readClipboard(Ubiquitty::ClipboardBuffer buffer, std::span<char> outputBuffer) override;

    // Stage approved clipboard bytes for the next readClipboard.
    void provideClipboardReadBytes(Ubiquitty::ClipboardBuffer buffer, std::span<const char> bytes) override;

    /// Writes typed data to the system clipboard or primary selection.
    /// Secondary and cut buffers use the untyped adapter.
    ///
    /// - Parameters:
    ///   - buffer: The destination buffer.
    ///   - items: The payloads, one per MIME; empty clears.
    void writeClipboardItems(Ubiquitty::ClipboardBuffer buffer, std::span<const Ubiquitty::ClipboardItem> items) override;

    /// Stages the approval's typed capture beside the bytes.
    ///
    /// - Parameters:
    ///   - buffer: The buffer the capture belongs to.
    ///   - items: The capture; empty clears the typed staging.
    void provideClipboardReadItems(Ubiquitty::ClipboardBuffer buffer, std::span<const Ubiquitty::ClipboardItem> items) override;

    /// Serves names from the last capture of this clipboard location.
    ///
    /// - Parameters:
    ///   - buffer: The buffer whose types are asked.
    ///   - out: Receives the space-separated list.
    /// - Returns: The count, or -1 outside the captured location or with
    ///   nothing staged.
    [[nodiscard]] int readClipboardTypes(Ubiquitty::ClipboardBuffer buffer, std::span<char> out) override;

    /// Serves one staged payload, under the same buffer scope.
    ///
    /// - Parameters:
    ///   - buffer: The buffer to read.
    ///   - mime: The requested name.
    ///   - out: Receives the bytes.
    /// - Returns: The count, or -1 when nothing staged serves the name.
    [[nodiscard]] int readClipboardItem(Ubiquitty::ClipboardBuffer buffer, std::string_view mime, std::span<char> out) override;

    // An internal (non-Clipboard) buffer's current contents, copied out from
    // under the lock — what requestClipboardRead stages for such a read.
    [[nodiscard]] std::string internalBuffer(Ubiquitty::ClipboardBuffer buffer) const;

private:
    GThread* m_uiThread;
    void* m_requester = nullptr;
    mutable std::mutex m_lock;
    std::string m_readBytes;
    bool m_readBytesStaged = false;
    Ubiquitty::ClipboardReadItemStaging m_typedStaged;
    Ubiquitty::ClipboardBuffer m_typedStagedBuffer = Ubiquitty::ClipboardBuffer::Clipboard;
    // Secondary and cut buffers.
    std::string m_buffers[static_cast<int>(Ubiquitty::ClipboardBuffer::Count)];
};

} // namespace Ubiquitty::Linux
