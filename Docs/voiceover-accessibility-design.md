<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Terminal accessibility specification

The accessibility interface presents the same terminal content as the renderer.
It must expose readable text, caret and selection, navigation, and controlled
notification of new output through the platform's accessibility API.
Visual contrast, color remapping, and reduced motion are separate presentation
settings.

For operating instructions and the reader-facing behavior, see the
[accessibility guide](guides/accessibility.md).

## Shared text projection

Core's `Accessibility::projectVisibleText` is the source of accessible text and
row ranges. Frontends must not keep an independently interpreted terminal model.

The projection must:

- read the pane's active screen at its viewport offset;
- distinguish primary and alternate screens;
- preserve grapheme clusters and omit continuation-cell duplication;
- trim trailing blank cells and join soft-wrapped rows according to the shared
  copy and selection rules;
- map caret and selection into the same projected text;
- represent an off-screen or unavailable caret without inventing a position.

Platform adapters convert indices to the units required by their API. AppKit
uses UTF-16 ranges; these must remain consistent for character count, line
lookup, range lookup, selected text, and string extraction.

A cached projection is derived data. Screen delivery or viewport changes must
invalidate it; rebuilding occurs under the terminal's read discipline.

## Platform elements

Each pane must expose its own terminal accessibility element. Focus follows
the focused pane, and its accessible identity must distinguish the session
from surrounding window controls.

On macOS, `TerminalSurface` uses an NSAccessibility text-area element. The
interface supplies the visible value, character count, visible range,
line-to-range and index-to-line mapping, caret line, selected text, and selected
range. All answers must describe the same projection.

The GTK adapter exposes corresponding text, character offsets, caret,
selection, and line information through the widget accessibility interface.
UIKit exposes projected text through the terminal element's accessibility
value. Native adapters do not change the terminal model to satisfy an
accessibility request.

## Output notifications

Changes to accessible text require coalesced value-change notifications.
A value-change notification and a spoken announcement are different events.

Spoken output must be enabled only for an active screen reader and must be
bounded and rate-limited. Streaming output must not create an unbounded speech
queue. Coalescing keeps recent complete lines and summarizes omitted lines;
it must not repeatedly announce unchanged screen content.

Focus changes, alternate-screen transitions, and explicit navigation must
retain enough context for the reader to identify the active pane. Notifications
must not steal keyboard focus.

## Semantic navigation

OSC 133 prompt marks define command boundaries for prompt-to-prompt navigation.
A prompt rotor or equivalent action must use those same marks as visual prompt
navigation, including failed commands and scrollback positions.

OSC 8 hyperlinks must expose their visible label and target as actionable
accessible content. Activation follows the same URL policy and confirmation
rules as pointer activation. Link appearance alone is not an accessible action.

## Contract validation

Read projection checks cover primary and alternate screens, viewport offsets,
soft wraps, wide and combining characters, clipped selections, and off-screen
carets. Platform checks query the actual accessibility element for role, value,
ranges, selection, and focus across multiple panes.

Notification checks must cover rapid output, idle intervals, screen-reader
activation changes, and bounded announcement counts. Keyboard and screen-reader
navigation must work without relying on color or pointer hover. Pixel snapshots
alone do not validate accessibility behavior.

## Source contracts

- Apple accessibility adapter: [Source/UbiquittyKit/Swift/TerminalSurface+Accessibility.swift](../Source/UbiquittyKit/Swift/TerminalSurface%2BAccessibility.swift)
- [GTK accessibility adapter](../Source/Platform/Linux/Accessibility.cpp)
- [Core text projection](../Source/Core/Accessibility/TextProjection.h)
