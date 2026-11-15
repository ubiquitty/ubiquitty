// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

namespace Ubiquitty::Linux::Diagnostics {

/// Compares padded native frames and retained edge restoration across backends.
///
/// Uses contextual Monaspace ink at the actual reported size, without a window,
/// subprocess, user configuration or benchmark workload.
/// - Returns: Zero on success, one on a failed oracle, or 77 without Vulkan.
int smokePadding();

} // namespace Ubiquitty::Linux::Diagnostics
