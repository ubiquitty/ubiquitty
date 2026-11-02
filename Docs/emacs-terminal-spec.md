<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Emacs terminal client contract

The Emacs frontend attaches through `ubiquitty-host --attach` and renders the
host's screen. The host owns the terminal model and process lifetime; Emacs
loads no C++ terminal module. The [client guide](../Source/Platform/Emacs/README.md)
describes setup, configuration, key bindings, and image rendering.

## Admission and framing

Wire identifiers and bounds come from the generated
`Source/Platform/Emacs/ubiquitty-sync-wire.el` table. The client declares that
table's version as both its current and minimum version. Refusals preserve the
host's reason rather than attempting an older grammar.

The screen greeting requests echo context. It requests no history retention or
backfill and supplies no resume request. The viewport states rows and columns;
pixel dimensions are zero because the client does not measure them.

The decoder must reject unknown kinds and host-sent client-only kinds.
Recognized unsolicited kinds for features the client does not consume are
skipped by their frame length. They include workspace structure, host pane
listings, history notifications, and program-status records.

## Screen state

A checkpoint is assembled from bounded chunks and verified against its SHA-256
before replacing the client's primary and alternate screens. Updates apply to
the held generation. A generation gap or invalid update requests a fresh
checkpoint rather than publishing a partial update.

The client acknowledges applied state. Frames delivered in one read are applied
as a batch; rendering and acknowledgement are coalesced. Palette, reverse-video,
or text-size changes invalidate row presentation even when text is unchanged.

The screen-state digest is not recomputed by this client. Field validation and
checkpoint SHA-256 verification are not substitutes for that digest.

## Pane facts and title

`PaneFacts` is a whole record, not a title prefix. The client validates all its
fields, bounds, flags, optional branches, and final length before adopting it.
Only facts on the bound pane's channel may change that buffer.

The program title becomes the buffer header. An empty whole record clears the
title inputs. Malformed facts leave the previous facts and header unchanged.
Once facts have supplied the title, an older title message must not overwrite
it. Pane unbind clears pane facts along with the attachment state.

`StatusRecords` does not produce a program-status UI in this client.

## Input and viewport

Input events are numbered on the pane's handle:

| Event | Meaning |
|---|---|
| `Raw` | Encoded text bytes |
| `Keys` | Named key and modifiers, encoded by the host under live terminal modes |
| `Pointer` | Mouse action, encoded by the host under live mouse modes |
| `Focus` | Buffer focus state |
| `Viewport` | Pane rows and columns at bind and on resize |
| `Facts` | Window geometry, focus, and selected theme palette |

Paste is sent in pieces of at most 8 KiB, within the host's advertised receipt
window. An interrupt during an unfinished paste sends `PasteAbort` first.
The pane's echo context defines the interrupt characters; it is not used to
predict local echo. `InputDiscarded` updates the discarded-event count and
stops any paste it identifies.

A connection loss does not replay in-flight input or resume an attachment.
Reopening a terminal is a new attachment operation.

## Presentation boundaries

Text properties carry terminal colors and attributes. The client displays the
current screen rather than a host scrollback view. Graphical Emacs can render
inline image slices; terminal Emacs cannot. Double-width and double-height rows
use the approximations documented in the client guide.

The client provides neither OSC 8 link activation nor a consent UI or direct
QUIC transport. It uses the local host bridge. It does not advertise deflated
checkpoints or span/scroll update operations, so the host sends the corresponding
uncompressed checkpoint and full-row forms.

## Decoder and interoperability checks

`Scripts/run-tests.sh emacs_sync_decode` requires Emacs and feeds a
C++-encoded host stream to the actual client. The checks cover screen contents,
cursor and modes, acknowledgement and resync, whole-record title adoption,
image encoding, and outgoing input, paste, focus, viewport, and theme messages.
The native fixture decodes outgoing messages against
`Tests/Platform/emacs-sync-upstream.expected`.

`Tests/Platform/emacs-live-check.el` exercises a live daemon separately.
`Scripts/gen-wire-tables.py` generates the shared constants; generated tables
must not be edited independently of their authoritative headers.

The [Neovim client](../Source/Platform/Neovim/README.md) uses the same bridge
with its own rendering and input contract.
