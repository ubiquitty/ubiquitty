// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

namespace Ubiquitty::Linux::Diagnostics {

/// Compares native and bitmap skip-ink coverage across CPU and Vulkan rendering.
///
/// Exercises ordinary, ligature, proportional, wide, doubled, sized, and link
/// underlines without a GTK window or application-global pane state.
/// - Returns: Zero on success, one on a failed oracle, or 77 without Vulkan.
int smokeSkipInk();

} // namespace Ubiquitty::Linux::Diagnostics
