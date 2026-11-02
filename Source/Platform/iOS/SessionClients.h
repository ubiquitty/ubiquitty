// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// The clients the iOS shell gives each pane's terminal. See SessionClients.cpp
// for why they are made in C++.

namespace Ubiquitty::IOS {

/// Registers the shell's pane clients as the process's default installer.
///
/// Call once, at startup, before the first pane exists. A pane's surface then
/// asks for them through `RuntimeDrive.installDefaultClients`, which runs the
/// installer under the pane's model lock: a clipboard writer that reaches the
/// system clipboard through the PAL seam, and `IOSCapabilityPolicy`, both
/// owned by the pane's session.
void registerSessionClients();

} // namespace Ubiquitty::IOS
