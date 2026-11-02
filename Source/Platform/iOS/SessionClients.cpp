// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// SessionClients.cpp — the clipboard writer and the capability policy the iOS
// shell gives each pane's terminal.
//
// The shell is Swift, and Swift cannot derive from a C++ class, so the clients
// are made here and installed through Core's default-installer seam. A session
// owns its frontend's clients through `adoptClientOwnership`, which holds a
// clipboard client, so the two are one object: a clipboard client that writes
// the system clipboard's text through Core's own writer, carrying the policy
// beside it. The session destroys it after the terminal that references it.

#include "Platform/iOS/SessionClients.h"

#include "Core/Runtime/TerminalSession.h"
#include "Core/Runtime/WorkspaceSession.h"
#include "Core/Terminal.h"
#include "PAL/TerminalClients.h"
#include "Platform/iOS/CapabilityPolicy.h"

#include <memory>
#include <span>
#include <utility>

namespace Ubiquitty::IOS {

namespace {

/// One pane's clipboard writer and capability policy, owned by its session.
class SessionClients final : public ClipboardClient {
public:
    /// Writes the system clipboard's text; the other buffers have no system
    /// counterpart and are dropped, as Core's writer drops them.
    ///
    /// - Parameters:
    ///   - buffer: The OSC 52 buffer written.
    ///   - bytes: The text, UTF-8.
    void writeClipboard(ClipboardBuffer buffer, std::span<const char> bytes) override { m_writer.writeClipboard(buffer, bytes); }

    /// Installs the writer and the policy in whichever slots are empty.
    ///
    /// A slot another owner filled keeps its client.
    ///
    /// - Parameter terminal: The pane's terminal, under its model lock.
    void attach(Terminal& terminal)
    {
        if (!terminal.clipboardClient)
            terminal.clipboardClient = this;
        if (!terminal.capabilityPolicy.installed())
            terminal.capabilityPolicy = &m_capabilityPolicy;
    }

    /// Clears what one set installed on a terminal the session lets go.
    ///
    /// - Parameters:
    ///   - terminal: The terminal being released, under its model lock.
    ///   - client: The set installed on it.
    static void detach(Terminal& terminal, ClipboardClient& client)
    {
        auto& clients = static_cast<SessionClients&>(client);
        if (terminal.clipboardClient.get() == &clients)
            terminal.clipboardClient = nullptr;
        if (terminal.capabilityPolicy.isInstalled(&clients.m_capabilityPolicy))
            terminal.capabilityPolicy = nullptr;
    }

private:
    Runtime::TerminalSession::SystemClipboardWriter m_writer;
    IOSCapabilityPolicy m_capabilityPolicy;
};

/// Equips one pane's session, under its model lock.
///
/// A terminal that already holds both slots, from an earlier ask, is left
/// alone, so asking again after the pane attaches costs nothing.
///
/// - Parameter session: The pane's session.
void install(void*, Runtime::TerminalSession& session)
{
    Terminal* terminal = session.terminal();
    if (!terminal || (terminal->clipboardClient && terminal->capabilityPolicy.installed()))
        return;
    auto clients = std::make_unique<SessionClients>();
    clients->attach(*terminal);
    session.adoptClientOwnership(std::move(clients), &SessionClients::detach);
}

} // namespace

void registerSessionClients()
{
    Runtime::WorkspaceSession::setDefaultTerminalClientInstaller(&install, nullptr);
}

} // namespace Ubiquitty::IOS
