<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Settings, profiles, and workspaces

Settings configure terminal defaults. Profiles provide named overrides. Saved
arrangements describe what to open. Live workspaces contain running terminals.
These concepts have different owners and lifetimes.

The [Settings catalogue](../settings-catalog.md) describes navigation and controls;
the [user guides](../guides/README.md) provide operating instructions.

## Vocabulary and ownership

| Concept | Meaning | Owner |
|---|---|---|
| App defaults | Configuration used when no more specific value is set | Local preferences |
| Profile | Named presentation and launch overrides, optionally inherited from a parent | Preferences |
| Terminal | One shell or program with its screen and history | The local runtime or host holding its PTY |
| Pane | A terminal's position in a tab layout | Workspace layout |
| Tab | An ordered page containing one or more panes | Workspace layout |
| Saved arrangement | A recipe for reopening windows, tabs, panes, origins, and profiles | Saved-session store |
| Live workspace | Running terminal processes and their topology | The workspace's runtime or host |
| Connection | The address and options used to reach a host | The connection store shared by Connect |
| Temporary override | Presentation applied only to the current window | That window's session state |

Deleting a saved arrangement removes a recipe; it does not end running work.
Detaching a client and ending a workspace are separate operations. UI labels
and confirmation text must identify which operation is being requested.

## Configuration rules

1. Every configurable value has one schema entry, validator, default, and resolver.
   Frontends display the resolved value rather than implementing a second resolver.
2. An absent override means inherit. Explicit false, zero, and empty values remain
   distinct from absence wherever the field permits them.
3. App chrome, credentials, OS accessibility settings, and permissions are local.
   Applying a profile must not grant clipboard access or agent authority.
4. Commands, directories, environment, encoding, and process lifecycle belong to
   the machine owning the PTY. A remote path must not be interpreted as local.
5. Font and theme names express intent. Available fonts, rasterization, display
   geometry, and native window placement are resolved on the viewing device.
6. A launch preference applies when opening a terminal; changing it must not
   restart an existing process. Temporary presentation changes remain scoped to
   their window.

## Profiles

A profile is a `[[profiles]]` TOML block identified by `name`. Its optional
fields cover parent profile, scope, theme, font family, symbol fallback, font
size, line spacing, four titled padding edges, a separate titleless top padding,
title-bar visibility, startup host, and
local process-exit behavior. Omitted fields inherit; numeric values use the
shared preference schema's ranges.

`resolvedProfile` resolves the selected profile through its parent chain over
app defaults. Parent traversal stops at a missing parent, a cycle, or the
32-profile depth limit. An unknown profile name resolves to the default.

For session presentation, `resolvedSessionProfile` combines reviewed shared
values, local defaults, platform overrides, the parent and selected profiles,
and temporary overrides. Later explicit values take precedence; temporary
values apply last. Shared values do not displace explicit local defaults.
The resulting profile is overlaid on configuration before renderer settings
are derived.
`padding_top` changes the top inset with a title bar; `titleless_padding_top`
changes it without one. An omitted titleless inset follows `padding_bottom`.

An explicitly empty startup host selects a local shell; an absent startup host
inherits. The process-exit choices are Keep Output, Close on Clean Exit, Close
Always, and Restart Process. They apply to local processes, not to a remote
host's session-retention policy.

### Editing

Settings ▸ Sessions ▸ Profiles provides creation, editing, duplication, and
deletion. An Override control distinguishes a saved value from inheritance.
The editor displays inherited values and their source. Parent choices exclude
cycles. Opening or cancelling an editor must not change the active configuration.

Profiles remain references by name. Name changes and deletion must account for
parent references and launch selections rather than silently substituting a
different profile.

### Transfer and review

Allow Export makes a profile eligible for explicit transfer. It is not
automatic device synchronization. Export includes presentation values and
shared-parent values, not local parent values, commands, startup hosts, or
credentials.

An imported `.ubqprofile` is a bounded presentation proposal, not a device
configuration file. The parser accepts one shared profile, rejects embedded
NUL and input over 65,536 bytes, and sanitizes fields through
`presentationProfile`.

The review sheet shows current and proposed values. **Apply to Window** changes
only the selected window until it closes. **Save on This Mac** creates a
uniquely named local copy without replacing an existing profile. **Cancel**
applies nothing. Disabling Allow Export prevents subsequent exports; it does
not revoke copies already transferred.

## Arrangements and live workspaces

An arrangement records logical layout and launch or attachment intent. Opening
it is additive: existing windows remain. A terminal that starts a new process
must be presented as a fresh launch, not as recovery of the old process.
Restoring an attachment requires confirmation that the host connection exists;
an unavailable host must produce an actionable failure, not silent success.

The live workspace owner is authoritative for topology. Frontends send an
operation and reconcile the returned layout. Labels, tags, profiles, and saved
arrangements do not confer authority to rename, move, or terminate host-owned
work. Those operations retain their host-side permission and consent checks.

See [session restoration](../guides/session-resurrection.md),
[remote sessions](../guides/remote-sessions-and-agents.md), and the
[session model](../session-model.md).

## UI requirements

Use native navigation, concise grouped controls, keyboard traversal, and
accessible labels. Status uses text or a symbol as well as color. Previewing a
choice must not modify another window. Drafts and failed operations retain the
user's input and explain what can be retried.

Configuration round trips must preserve absence versus explicit values.
Profile, window, and session changes must remain isolated to their owner.
Restoration must preserve layout intent while distinguishing retained sessions
from fresh processes.

## Source contracts

- [Profile schema and resolver](../../Source/Core/Preferences/Profile.h)
- [Profile resolution and transfer](../../Source/Core/Preferences/Profile.cpp)
- [Profile editor](../../Source/Platform/macOS/App/ProfilesPane.swift)
- [Window capture and restoration](../../Source/Platform/macOS/App/Windowing/TerminalWindows.swift)
