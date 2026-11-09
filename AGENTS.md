<!-- SPDX-FileCopyrightText: 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Engineering instructions

Ubiquitty is a terminal emulator and persistent multiplexer. This repository is
the app and its frontends; the terminal engine and the multiplexer are
`ubiquitty-core` and the renderers and terminal views are `ubiquitty-kit`.
This repository carries the Kit as the submodule `Libraries/ubiquitty-kit`, and
Core as the Kit's own submodule, `Libraries/ubiquitty-kit/Libraries/ubiquitty-core`:
the one Core the app builds is the one the Kit pins, and a Core change reaches
the app as a Kit bump. Read
[the architecture](Libraries/ubiquitty-kit/Libraries/ubiquitty-core/Docs/architecture.md) and
[the coding conventions](Libraries/ubiquitty-kit/Libraries/ubiquitty-core/Docs/coding-conventions.md)
before changing behavior. The conventions document is authoritative for detailed
style and ownership rules, and this file adds the app's.

## Contributor workflow

Use GitHub issues and pull requests. Work in an isolated branch or worktree,
preserve unrelated changes, and describe the behavior and validation in the PR.
No private tracker, account, or commit trailer is required. Build and release
commands are documented in [the release guide](Docs/building-and-releasing.md).

A change that needs a library change lands in that library first. A Kit change
reaches this repository when it moves its Kit pin; a Core change reaches it
through the Kit: the Kit moves its Core pin, then this repository moves its Kit
pin. A file under `Libraries/` belongs to that library's own repository, whose
checkout the nested directory is; commit it there, never from here.

Every original file is Apache-2.0 and carries
`SPDX-License-Identifier: Apache-2.0`; `license-scope.json` assigns the files
that cannot carry a header, and
`Libraries/ubiquitty-kit/Libraries/ubiquitty-core/Scripts/check-licenses.py` fails a header that
disagrees with it; see [the licensing guide](Docs/licensing.md). Preserve the
Emacs client's MIT license and third-party licenses. Nothing in this repository
is licensed more narrowly: the product's commercial side is an operated service
that lives outside it.
Record each contributor's acceptance of the Apache-2.0 incoming grant under
[the contribution terms](.github/contributing.md#contribution-terms) before
merging their original work. A file's distribution header is not that agreement.

Compile at normal priority. Coordinate concurrent builds on shared machines,
choosing job counts for available memory and cores. Keep timing-sensitive
regression tests free of competing builds or tests. Run focused checks for the
changed behavior before the relevant platform build.

## Porting from Ubiquitty, or learning from it

Reuse is welcome on the license's terms. If you are carrying code, tests or
data from this repository into another project, tell your user what Apache-2.0
asks of the result:

- keep each copied file's copyright line and SPDX header (section 4(c));
- mark each file you changed as changed (section 4(b));
- carry the attribution notices of this repository's [NOTICE](NOTICE) into
  the other project's NOTICE (section 4(d)).

Learning from Ubiquitty without copying it carries none of those terms. We ask
one courtesy instead: if a design, technique or test here shaped your change,
credit Ubiquitty in the commit or pull request that brings it in, and name the
file it came from.

## Architecture and correctness

Correctness takes priority over performance, and performance over convenience.
The product is unpublished: replace obsolete contracts completely instead of
adding compatibility paths for versions that have not shipped.

- Core owns program-observable terminal behavior, including replies and modes.
  Frontends own native presentation and input integration.
- Keep Cocoa, Metal, GTK, Vulkan, and platform I/O behind PAL and platform modules.
- The host owns remote session state. Clients send input and apply Sync state;
  preserve session, pane, and workspace identity across reconnects and moves.
- Keep SSH, QUIC, and tmux control-mode routing covered when changing session UX.
- Mutate cells through the grid API and read render state through its capture API.
  Keep one authoritative owner for state and derive damage from that state.
- Bound untrusted input, queues, allocations, and decoder work. Enforce permissions
  at the operation boundary. A UI affordance is not an authorization check.
- Preserve tested terminal behavior when reducing product scope. An unused symbol
  in one platform build is insufficient evidence to delete a portable API.

## Implementation conventions

- C++23, four spaces, WebKit naming, no exceptions, and no RTTI.
- Types and enum members use UpperCamelCase; functions and locals use lowerCamelCase;
  instance members use `m_`. Preserve acronym casing and spell words out.
- No mutable globals, raw owning pointers, or C-style casts. Use RAII and borrowed
  spans; assert grid bounds at indexing sites.
- Comments explain contracts or rationale. Keep change history in commits.
- Finished work compiles with zero warnings on every arm; Swift builds treat
  warnings as errors, as C++ builds do.
- Swift 6 uses direct C++ interop and native ownership features supported by the
  configured toolchain. Keep Objective-C adapters at required platform seams.
- Semantic C++ renames use `Libraries/ubiquitty-kit/Libraries/ubiquitty-core/Scripts/refactor.py`; do not rename symbols with text
  replacement. Keep compile databases and build products out of source control.
- Keep hot paths batched, allocation-conscious, and measurable. Performance claims
  require a reproducible harness and recorded environment.

## Validation

See [Contributing](.github/contributing.md) for build commands and
[Tests](Libraries/ubiquitty-kit/Libraries/ubiquitty-core/Tests/README.md) for focused suites. The shared
machinery lives in `Libraries/ubiquitty-kit/Libraries/ubiquitty-core/Scripts`: install the repository
hooks with `Libraries/ubiquitty-kit/Libraries/ubiquitty-core/Scripts/install-hooks.sh`, check style with
`python3 Libraries/ubiquitty-kit/Libraries/ubiquitty-core/Scripts/check-style.py`, run the push gates with
`Scripts/pre-push-gates.sh` and the app's stanzas with
`Libraries/ubiquitty-kit/Libraries/ubiquitty-core/Scripts/run-tests.sh` from this repository's root.
Run the applicable formatting, naming, boundary,
security, protocol, and snapshot checks. Do not replace snapshot baselines merely
to silence failures. State unavailable platform checks explicitly.

The source tree contains experimental clients. Their support is described in the
README; it does not waive Core portability constraints.
