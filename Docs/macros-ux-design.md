<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Macro interaction specification

A macro is a named byte sequence sent to the focused terminal. Creation,
editing, recording, and invocation use the same `[macros]` configuration store
and the same input path.

## Storage and invocation

A `[macros]` TOML entry maps a name to its body. The body supports the engine's
escape syntax, including `\e`, `\n`, `\t`, `\\`, and `\xNN`.
The editor must preserve that representation when loading and saving.

Invoke a macro from the Macros menu, its command-palette entry, or a
`macro:<name>` key binding. Invocation targets the focused session and retains
its normal input and permission rules. A macro does not acquire a separate
authority to send input.

Key bindings belong to `[keys]`, not to the macro record. The macro editor must
point to Settings ▸ Keyboard for assigning `macro:<name>` to a shortcut.

## Creation and management

**Macros ▸ New Macro…** and **Macros ▸ Edit Macros…** provide a route to the
Macros editor under Settings ▸ Keyboard. These actions remain present when
the list is empty.

The editor must provide:

- a list showing each name and a single-line body preview;
- New, Edit, and Delete actions;
- a draft sheet with a name and a monospace body field;
- an escape-syntax hint beside the body;
- Cancel and Save actions with normal keyboard shortcuts.

Opening or cancelling a draft must not change configuration. Saving or deleting
writes through to the shared preferences store and refreshes menu entries.
Validation must retain the draft and explain an invalid name or body.

## Recording contract

**Record Macro…** starts a recording for the focused terminal. A persistent,
accessible indicator identifies the recording and provides Stop without taking
keyboard focus from the terminal.

Recording captures user-generated terminal input after key-to-byte encoding.
The bytes continue to the live session, so recording executes the interaction;
it is not a dry run. App shortcuts and terminal-generated replies are not macro
input. The capture must not bypass input policy or capture another pane's input.

Stop is an explicit action on the indicator or the same Record Macro command.
Escape remains recordable and must not stop capture. App shortcuts such as
Close or Quit retain their normal meanings.

Stopping opens a Save sheet with the captured body available for editing.
Save creates a macro through the same store as manual creation; Cancel discards
the recording. Switching away or ending the source session must not silently
continue capture in a different terminal. The indicator must remain legible with
Reduce Motion enabled and must not rely on animation or color alone.

## Command palette

Macro invocation and recording use the same named actions in the menu and
[Beam](beam.md). Palette dismissal must restore terminal focus before input is
sent. Destructive changes and permission-sensitive actions retain their normal
confirmation rules.

## Data and interaction invariants

- The preferences store is authoritative; the editor has only an unsaved draft.
- A saved macro and its keyboard action resolve to the same decoded bytes.
- Editing one macro does not alter another macro or an unrelated binding.
- Recorded Escape, Control characters, and embedded NUL must survive the
  editable representation and replay.
- UI creation, cancellation, configuration reload, and session closure must
  leave no hidden recording active.

Parameterized macros, conditional execution, and macro chaining are outside
this byte-sequence contract.

## Source contracts

- [Macro editor](../Source/Platform/macOS/App/MacrosPane.swift)
- [Macro store](../Source/Platform/macOS/App/MacroStore.swift)
- [Keyboard actions](../Source/Core/Input/Keybindings.h)
