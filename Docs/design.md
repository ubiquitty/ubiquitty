<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Interface design

These are design requirements for interface changes, not a list of implemented
features. The [user guides](guides/README.md) describe available behavior;
[architecture](architecture.md) defines ownership and terminal compatibility.

## Content and hierarchy

Terminal content takes priority over window controls. Keep pane identity,
focus, connection state, and permission state visible without duplicating them
in several title bars.

Use one baseline and spacing system for title-bar accessories. Status items
need a defined overflow order: shorten text, collapse to a recognizable symbol,
then offer the full information in a menu. Preserve the meaningful parts of
paths and process names when truncating.

A divider should remain visible against the theme without becoming a border
around the content. Its pointer hit region may be wider than its painted line.
Find bars and other persistent controls must not obscure the terminal rows
they act on.

## Typography and color

Use the system interface font for prose and controls, and a monospaced face for
machine identifiers. Terminal font controls should show a specimen rendered
through the actual terminal pipeline, including confusable characters,
ligatures, bold, and italic text.

Preserve the distinction between a font's real styles and synthesized ones.
Where a face supports optical sizing, select it from the effective point size.
Font, size, weight, and line-height changes must preserve cursor placement,
selection, and terminal cell geometry.

Color communicates state but must not be its only cue. Selection, focus,
connection health, and consent outcomes need a visible shape or text label.
Respect system accessibility settings and test both light and dark themes.
Do not reinterpret sRGB-authored theme colors as Display P3 colors; see
[wide-gamut rendering](wide-gamut.md).

Keep theme-derived colors consistent across dividers, focus cues, notifications,
and window controls. A terminal application's chosen colors are separate from
the interface's own colors and accessibility adjustments.

## Motion and attention

Motion should confirm an action or draw attention to a relevant state change.
Use consistent durations and easing for related controls, and route animations
through the system Reduce Motion policy. A reduced-motion alternative must
preserve the information: a static state change can replace a spin, trail, or
slide.

Avoid flashing patterns and large repeated luminance changes. The visual bell
uses the full-screen flash treatment; a corner pulse or border is not an
equivalent replacement. Notification placement is a separate design question.

An attention action must name its source. A notification that offers to reveal a
pane must navigate to that exact pane, including when the tab or window is not
currently active. In-app attention and operating-system notifications should
not duplicate one event unnecessarily.

## Commands and navigation

Beam uses Command-Shift-P by default; Command-K remains Clear. Both are
rebindable. Beam uses the system interface font by default, with terminal-font
presentation as a preference. See the [Beam reference](beam.md) for scopes and
behavior.

Keep the same action name, shortcut, and enabled state wherever an action
appears. Search results, menus, and context menus must resolve targets through
the shared model rather than copying backend-specific rules into the interface.

## Identity and consent

Show who is connected, what an agent is requesting, and whether a request is
waiting, allowed, refused, or expired. A count alone cannot explain an active
participant or permission request.

Present the operation and its target before technical identity details.
Permission prompts default to refusal; Return or dismissal must not accidentally
authorize an operation. A destructive action needs an explicit confirmation
appropriate to its scope. UI wording must not promise permissions that the host
has not granted.

Host authorization remains authoritative. The interface displays its result and
does not infer success from a sent request. For the policy contracts, see
[capability origin](capability-origin.md) and [host policy](capability-host-policy.md).

## Copy

Use sentence case and American spelling. Prefer specific action labels such as
“Attach,” “Copy command,” or “Quit” to “OK.” Name the actual operation and explain
its consequence before it runs.

Use established terms consistently: “terminfo entry,” “shell integration,”
“agent token,” and “participant.” Keep diagnostic paths and process identifiers
available without making them the headline.

Errors should state what failed and what the user can do next. Empty states
should explain the missing item and offer a relevant action. Do not imply a
feature works when it is unsupported, unverified, or still waiting for a reply.
