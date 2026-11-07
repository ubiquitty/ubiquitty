<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Development tools

Commands for building, testing, and reviewing a change. Start with the
[contributor guide](../.github/contributing.md), then use the smallest relevant
test set while iterating. A focused pass does not replace the required checks
for a pull request.

## Build locations and compiler cache

Build output lives outside the checkout in its own build root. Resolve that
path with `Scripts/build-root.sh` or `Scripts/build_root.py`; do not hardcode a
DerivedData path.

```sh
. Scripts/build-root.sh
echo "$UBQ_BUILD_ROOT"
```

The build scripts configure `ccache` through `Scripts/ccache-env.sh`. Shared
cache entries reduce repeated work across checkouts. Size the cache for the
working set and inspect `ccache -s` for misses and eviction pressure.

Shared objects can contain the original compilation directory in their debug
information. When debugging different uncommitted trees, account for those
source paths. Setting `hash_dir=true` trades cross-directory cache reuse for
directory-specific entries.

A new worktree's root is empty, so building the app or the UI-test bundle there
starts from nothing. Build in a lane instead: a long-lived worktree whose root
stays warm. `Libraries/ubiquitty-core/Scripts/build-lane.py` takes a free lane, brings it to your
worktree's HEAD and uncommitted changes, runs the command there, and lets it go:

```sh
python3 Libraries/ubiquitty-core/Scripts/build-lane.py run --wait 3600 --from "$PWD" -- \
  sh -c 'git submodule update --init --recursive && Scripts/run-ui-tests.sh "$@"' sh <scenario>
python3 Libraries/ubiquitty-core/Scripts/build-lane.py run --wait 3600 --from "$PWD" -- \
  sh -c 'git submodule update --init --recursive && Libraries/ubiquitty-core/Scripts/build-tests.sh'
python3 Libraries/ubiquitty-core/Scripts/build-lane.py status
```

The command runs in the lane, so name scripts relative to the checkout root.
`UBQ_BUILD_ROOT` is the lane's root inside the command; `build-lane.py root`
prints it outside. Details are in
[building and releasing](building-and-releasing.md#build-lanes).

## Build

| Target | Command |
| --- | --- |
| macOS app | `./Scripts/build-macos.sh` |
| iOS simulator | `./Scripts/build-ios.sh --sdk iphonesimulator` |
| iOS device | `./Scripts/build-ios.sh --sdk iphoneos` |
| iOS UI-test bundle | Add `--ui-tests` to the iOS build |

A real iOS device requires a suitable signing identity. A Core header used
through Swift interop must rebuild the consuming Swift targets; recompiling
only changed Swift files is not sufficient.

Simulator tools use `Scripts/ios-simulator.sh`, which manages one device per
checkout. Its `--boot` and `--shutdown` options support a caller that owns a
multi-step session. `--prune` removes devices for checkouts that no longer exist.

## Focused tests

| Question | Tool |
| --- | --- |
| Which tests cover changed files? | `./Tools/covering-tests.py` |
| Run those selected tests | `./Tools/covering-tests.py --run` |
| Select host tests by CTest expression | `./Tools/host-tests.py <expression>` |
| List the host-test selection | `./Tools/host-tests.py --list <expression>` |
| Run one iOS UI case | `./Tools/ios-ui-test.py <TestCaseName>` |
| Run matching macOS UI scenarios from one build | `./Tools/ui-scenarios.py <pattern>` |

The coverage index reports its age. An empty or short selection is not proof
that no other tests are needed. Host-test builds reuse the checkout's test
build root; `--build-only` prepares selected binaries without running them.

`Tools/ios-ui-test.py --setup` builds the test runner, while `--full` runs the
full UI suite. `Tools/ui-scenarios.py --list` lists scenarios, `--regex`
selects by expression, and `--no-build` uses an existing build. macOS scenarios
use an isolated configuration home.

## Integration and rendering checks

- `./Scripts/run-ios-smokes.sh` runs in-process UIKit smokes. Judge the printed
  verdict: `simctl launch` returning success does not establish a smoke result.
- `./Scripts/run-ios-ui-tests.sh` runs the external iOS UI suite and verifies
  the executed-case count. Live SSH/QUIC cases require `UBQ_LIVE_SSH_HOST`,
  `UBQ_LIVE_SSH_USER`, and `UBQ_LIVE_SSH_KEY_FILE`; missing credentials are
  reported as skipped, not as successful remote verification.
- `Tests/Snapshots/run.py --backend <backend> [filters]` compares rendered
  cases with their goldens. Use `--update` only for reviewed visual
  changes. `UBIQUITTY_SNAPSHOT_FAILURE_DIR` retains actual and diff images.
- `Tests/Snapshots/gen_folio.py` generates type-specimen cases; its `--check`
  option detects stale generated input.
- `python3 Tests/Snapshots/coretext_parity.py --backend <backend>` compares
  proportional-text output with CoreText. `--keep <directory>` retains the
  images for inspection.
- `./Tools/remint-fingerprint.py [versionConstant]` records wire fingerprints
  after a version change. It refuses changed bytes under an
  unchanged version; a fingerprint refresh must not conceal a wire change.

A regression test should fail when the behavior it covers is removed. Security
changes need negative tests that prove unauthorized operations are refused, in
addition to successful-operation controls.

## Style and review

`./Scripts/check-style.py --since origin/main` runs the scoped style suite.
The scoped checks read the index, so stage intended changes before invoking
them. A worktree-only deletion can otherwise appear as a missing indexed file.

Use an individual `Scripts/check-*.py` when iterating on one rule.
`python3 Scripts/run-gate-self-tests.py` checks that the gates reject their
own planted defects. Gates share `gate_report` and `gate_corpus`; new gates
should use the existing framework.

Run load-sensitive performance checks on an otherwise quiet machine. Reuse one
build for a coherent test batch and keep heavy test runs from competing with
each other.

Follow the contributor guide for branches, contribution terms, pull requests, and
required reviews. `Tools/merge-pr.py` is a maintainer tool for merging an
approved pull request and cancelling obsolete branch runs; `--cancel-only`
does only the cancellation.

## Where tools belong

Put reusable developer tools in `Tools/`. A script specific to one behavior
belongs with its tests and should call a shared tool when one exists. The
[architecture](architecture.md), [coding conventions](coding-conventions.md), and
[naming conventions](naming-conventions.md) define the source rules.
