<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Ubiquitty User Guides

These guides cover the macOS app: configuration, terminal features, local and
remote sessions, and agent access. Other frontends have different capabilities;
see the [platform overview](../../README.md).

## Guides

- **[Getting Started](getting-started.md)** — windows, tabs, the Settings window, and the config file.
- **[Appearance & Fonts](appearance-and-fonts.md)** — themes, colors, fonts, ligatures, the cursor, opacity, padding.
- **[Tabs, Splits & Windows](tabs-splits-and-windows.md)** — tabs, split panes, window/tab titles, profiles.
- **[Selection, Clipboard & Search](selection-clipboard-and-search.md)** — copy/paste, smart & rectangular selection, Find, OSC 52.
- **[Shell Integration](shell-integration.md)** — prompt marks, prompt navigation, command-output selection (OSC 133).
- **[Images, Links & Escape Sequences](images-links-and-escape-sequences.md)** — inline images, hyperlinks, true color, text effects, sound.
- **[tmux Integration](tmux.md)** — attach `tmux -CC` sessions locally or over SSH; native split rendering.
- **[Remote Sessions & AI Agents](remote-sessions-and-agents.md)** — Connect (⌘⇧K) to a remote Ubiquitty Host over SSH, Share This Window, the `ubq` CLI + MCP server.
- **[Accessibility](accessibility.md)** — screen-reader support and current limits.
- **[Session Resurrection](session-resurrection.md)** — restore windows/tabs/panes across a quit (Experimental); Sessions in the ⌘⇧K Connect window.
- **[Terminal Identity](terminal-identity.md)** — `TERM_PROGRAM`, `TERM`, and identity settings.
- **[Keyboard Shortcuts](keyboard-shortcuts.md)** — the full reference.

## Settings & the config file

Most behavior is configurable in **Settings** (⌘,). Its sidebar categories are:

<!-- settings-sidebar:start -->
Appearance; Fonts; Cursor; Windows & Tabs; Selection & Clipboard; Mouse & Trackpad;
Keyboard; Sessions; Terminal; Notifications; Accessibility; Privacy & Security;
Software Update.
<!-- settings-sidebar:end -->

Themes is under Appearance and Profiles is under Sessions. See the
[Settings overview](getting-started.md#the-settings-window) for what each category contains.
Everything Settings changes is written to
`~/.config/ubiquitty/config.toml`. You can also edit that file directly (**Edit Settings
File…**) — Ubiquitty watches it and live-reloads on save, so changes apply without a
restart. Settings reads the live config, so the window always reflects the current state.

> Shortcuts in these guides are the defaults; the authoritative source is the menu bar —
> every command shows its shortcut next to it.
