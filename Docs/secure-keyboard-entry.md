<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Secure Keyboard Entry (macOS)

A **View ▸ Secure Keyboard Entry** toggle that calls macOS's
`EnableSecureEventInput` to request macOS protection against other processes
observing keyboard events while Ubiquitty is frontmost. Default on; persisted as `[security] secure_keyboard_entry`.

`EnableSecureEventInput` / `DisableSecureEventInput` (HIToolbox) is the only macOS
API for this — AppKit/SwiftUI have no system-wide equivalent (`SecureField` only
protects a focused masked text field, which a terminal view is not). That lone
Carbon dependency is quarantined in `Source/Platform/macOS/App/SecureInput.swift`
(class `SecureInput`, exported to ObjC as `@objc(UBSecureInput)`), which drives the
two functions forward-declared in `Source/Platform/macOS/App/SecureInputCarbon.h`
and pulled into Swift through the bridging header — so no Carbon umbrella or legacy
Carbon types enter the frontend. (The forward-declare also dodges `import Carbon`,
whose legacy headers don't build under `-cxx-interoperability-mode=default`.)

`SecureInput` owns the **balanced** enable/disable of the process-wide resource,
which is a *counted* system input: each enable must be matched by exactly one
disable. The type is `@MainActor` (AppKit lifecycle is main-thread only), so its
single static held-state flag is race-free by construction; `apply(_:)` is
idempotent and reconciles the held state against intent (enable if wanted and not
held, disable if held and no longer wanted), letting callers express only "should
it be on right now?" `UBAppDelegate` holds the policy (pref on **and** app
frontmost) via `applySecureKeyboardEntry` and releases it on `resignActive` /
terminate.

## Password prompts

Core flags a password prompt two ways: private mode 7401, which an application
sets around a secret, and the `[security] password_detect` heuristic (default
on), which fires when output settles on a line ending in a password prompt —
on the pty path (`processBytesUpToSyncClear`) as well as a direct feed. Frontends read the flag from the model: the pane shows a
lock glyph after the caret (`PasswordPromptBadge`, one type for both shells;
the caret keeps its place and its blink, the lock stands still beside it the
way a password field carries its affordance at the trailing edge), local echo
under SRM reset is masked, and — under
`[security] secure_keyboard_entry_at_password_prompts`, default on — the app
delegate holds Secure Keyboard Entry for as long as any pane
is at a prompt and the app is frontmost.

While the app holds Secure Keyboard Entry a lock shows at the trailing edge of
every window's title bar
(`SecureKeyboardEntryLock`, installed in each window's `ChromeAccessoryBar`):
it speaks for the process, the glyph beside the caret speaks for the prompt.
The bar lays a window's indicators out from the edge inward by priority —
the lock, the broadcast and tmux pills, a development build's identity — so
one appearing moves the others rather than covering them. The panes report into
`PasswordPromptRegistry` (held weakly, so a pane closed mid-prompt releases
the hold by itself); the delegate's one policy reads it beside the standing
preference and reconciles on every change.

`password_detect` is seeded per terminal by Core's launch fold
(`seedTerminalConfiguration`), so a frontend that seeds through it runs the
heuristic without remembering to; a live toggle in Settings reaches every
open window. Both switches sit in Settings ▸ Privacy & Security ▸
Security beside the standing toggle.

## Not password no-echo

Secure Keyboard Entry is a cross-process anti-snoop protection at the HID layer.
It is **orthogonal** to a hidden `sudo`/`su` password, which is the program
clearing the `termios` `ECHO` bit on the PTY. Enabling Secure Keyboard Entry does
not change what is drawn on screen. A detected prompt is a presentation hint,
not proof that a program has disabled echo. Secure input does not protect
terminal output, scrollback, clipboard contents, remote peers, or a compromised
process running with the user's privileges.

## Preferences sync

`[security]` settings have no Profile slot, so `secure_keyboard_entry` is excluded
from the `CONFIG` sync frame by construction (see
[platform-config-and-sync](platform-config-and-sync.md)) — it never travels to a
client.
