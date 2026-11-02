<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Session handoff to another device

A session handoff shares a locator, not a credential. It identifies an existing
session on a particular daemon incarnation. The receiving device reviews that
destination and authenticates independently; possession of the link grants no
access.

The host remains the owner of the PTY and terminal state. Opening the session
on another device attaches another client; it does not move the program to that
device or terminate the sender's attachment.

## Locator

`HostHandoffLocator` in
`Source/Platform/macOS/App/Windowing/HostHandoff.swift` defines the URL:

```text
ubiquitty://session?host=<percent-encoded-SSH-authority>&daemon=<uint64>&session=<uint32>
```

The three query keys must occur exactly once. The URL must have no user,
password, port, fragment, or path. Unknown keys are refused. The complete URL
is bounded to 4,096 UTF-8 bytes; the SSH authority is bounded to 255 bytes and
must pass `Transport::validateSSHHost`. The daemon identifier is nonzero.
The session identifier is neither zero nor `UINT32_MAX`.

A link or QR code must not contain an access token, resume secret, private key,
or bootstrap credential. Copying a link therefore grants no more authority than
knowing the destination. Host and session identifiers can still be sensitive
metadata; a sharing surface should make the destination visible.

## Receiver

The receiver must:

1. Parse and validate the whole locator before using any field.
2. Show the destination and require an explicit Connect action; cancellation
   has no side effects.
3. Authenticate the SSH host and user using the receiver's own credentials.
   Host-key mismatch is a refusal, not a request to silently replace the pin.
4. Request the exact daemon incarnation and existing session with attach-only
   semantics. A restarted daemon or ended session must be refused, never
   replaced with a new shell.
5. Apply the same token scopes, person/agent classification, and consent rules
   as any other attachment.

A QR scan, URL open, or same-account device transfer is not proof of host
authority or consent. Neither a local process nor an editor client becomes
trusted merely because it runs on the same machine. Kernel-verified peer
identity and the trusted-binary rule remain applicable.

If QUIC is selected, the receiver obtains its one-time token and certificate
pin over its authenticated SSH bootstrap. Those credentials travel through
that channel, not through the locator. See [QUIC trust](quic-trust.md).

## Session lifetime

A hosted program continues to run independently of the windows displaying it.
A locally owned PTY must be admitted and adopted by the host before a handoff
can name it as a hosted session; descriptor transfer remains restricted to
the local authenticated IPC path.

An attachment can be closed without terminating the session. A move operation
must establish and confirm the receiving attachment before detaching the
sender, and failure must leave the sender usable. Closing or terminating the
program is a separate operation with its own authority and confirmation.

These rules apply equally to native windows, editor clients, browser clients,
and device-discovery transports. The transport carrying a locator does not
change its meaning.

## Validation

`HostDirectoryScenarios.swift` exercises locator round trips, extra or
credential-bearing query keys, command-like SSH authorities, and invalid
daemon identity. Receiver tests must also cover cancellation, host-key
mismatch, daemon replacement, missing sessions, attach-only behavior, and
independent authentication. Link parsing alone does not prove the complete
handoff path.

See [Host management](host-management.md), [Session model](session-model.md),
and [Agent token authentication](agent-token-auth.md).
