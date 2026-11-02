// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

//
// SessionClipboardClient.h — the per-terminal clients a macOS session is
// equipped with: the clipboard (OSC 52 and its typed items), the capability
// policy and the gated file read.
//

#include "Core/Runtime/TerminalSession.h"

namespace Ubiquitty::SessionClients {

/// Installs a session's per-terminal clients on a freshly made session.
///
/// The workspace model calls this through its installer seam, before the
/// session's ingest starts. The clients are owned by the session, so their
/// life ends after the terminal that points at them.
///
/// - Parameters:
///   - context: Unused; the seam carries one for installers that need it.
///   - session: The session to equip.
void install(void* context, Runtime::TerminalSession& session);

/// Registers ``install`` as the process default, ahead of any window model.
void registerAsDefaultInstaller();

} // namespace Ubiquitty::SessionClients
