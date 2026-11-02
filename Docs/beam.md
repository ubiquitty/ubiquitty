<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Beam — the command palette

Beam is Ubiquitty's command palette for commands, settings, and terminal
navigation. It appears as a native panel over the dimmed terminal.

## Summoning

- **⌘⇧P** toggles Beam.
- A click outside the card, **⌘⇧P** again, or switching to another tab, window,
  or app dismisses it. **Esc** backs out of a value editor or scope, then dismisses
  the top-level palette.
- Type to filter, **↑/↓** to move the selection, **Enter** or a click anywhere on
  a row to run it. Hovering the pointer over a row highlights it.
- **⌃1 … ⌃9** runs or applies the corresponding visible result, using the same
  confirmation rules as Enter.

## Scopes

Type a prefix at the **start** of the input to retarget the query; the scope chip
switches, and the prefix is stripped. **Esc**, the **‹** chip, or backspacing past
the prefix returns to the default actions scope.

| Prefix | Scope | What it lists |
|---|---|---|
| *(none)* `›` | **Actions** | Registered commands and settings, fuzzy-ranked |
| `#` | **Settings** | Settings only |
| `:` | **Go to** | Switch to a tab or split pane |
| `@` | **Blocks** | Jump to a shell command block (needs OSC-133 shell integration) |
| `/` | **Find** | Search the scrollback |

The actions scope shows these prefixes in a hint footer so they are discoverable.

- **`@` Blocks** lists the focused terminal's OSC-133 command blocks, newest
  first; selecting one scrolls the viewport to that block. Requires shell
  integration (the shell emitting OSC-133 marks); without it, Beam says so.
- **`/` Find** searches the scrollback + live screen. Literal by default; prefix
  the query with `re ` for a regular expression. Matches are highlighted behind
  the card; selecting one scrolls to it. The highlight clears when you leave find.
- **`:` Go to** lists open tabs (with their live titles, including a rename) and
  the current tab's split panes; selecting switches to it.

## Settings

Beam surfaces every row of the Settings catalog, grouped by category:

- **Toggles** flip inline — the title shows the current On/Off state.
- **Enums / pickers** drill into a value list (the current value marked `✓`); pick
  one to apply.
- **Numerics** drill into a value editor: the current value is prefilled, **↑/↓**
  steps by the schema step, or type a value; the allowed range and unit are shown.

## Navigation model

- **Commit** — running a command, or applying a drill value — **closes Beam**, so
  you see the result on the terminal, not the palette.
- **Cancel / back** — **Esc** or the **‹** breadcrumb — steps back one level (a
  drill returns to its list; a scope returns to actions) without dismissing.

## Architecture (for contributors)

Beam lives in `Source/Platform/macOS/App/Beam/`. Its command source is a
provider registry combining menu commands, the Settings catalogue, remote
connection actions, key actions, agent controls, and tmux context commands.
Core's palette registry deduplicates by title and action identity; the first
provider wins a collision. Settings values use the same getters, setters, and
schema bounds as the Settings window.

Terminal scopes read live state through `BeamTerminalContext` and
`BeamTerminalProviders`, with `TerminalWindowController+Beam.swift` supplying
pane navigation and focus. Prompt blocks, scrollback search, and terminal actions
reuse the shared model; AppKit owns presentation and window navigation.

Palette invocation must retain the underlying action's permissions and
confirmation. Dismissing or cancelling must clear search highlights and restore
focus without executing the selected command.
