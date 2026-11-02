<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Building & releasing Ubiquitty

For prerequisites and commands for every frontend and library, start with the
[platform build guide](platform-builds.md). This reference covers build metadata,
Apple projects, the iOS archive, packaging, and macOS/Linux releases. Update-mechanism specifics (Sparkle, AppImage
self-update, signing keys) live in [`auto-update.md`](auto-update.md); this is
the build/distribute overview. The [script index](../Scripts/README.md) lists
every script under `Scripts/` by purpose.

## Components

Resolve the external build directory with
`export UBQ_BUILD_ROOT="$(python3 Scripts/build_root.py .)"` from the checkout.
The default parent is Xcode DerivedData on macOS and
`$XDG_CACHE_HOME/ubiquitty/build` on Linux (`~/.cache/ubiquitty/build` when unset).
Each checkout has a distinct hashed directory; `UBQ_BUILD_ROOT` overrides it.

Nothing removes a checkout's root when the checkout goes, so the roots of
removed worktrees accumulate until the disk fills. `Scripts/clean-build-roots.py`
maps each root back to its worktree, through the same hash and the source
directory the root's CMake caches record, and prints a table of root, worktree,
class and size, with the space it would reclaim:

| Class | Meaning | Removed by |
|---|---|---|
| `ORPHAN` | the worktree is gone, or no checkout on the machine hashes to the root | `--delete` |
| `MERGED` | the worktree is clean and its `HEAD` is in its `origin/main` | `--delete` |
| `STALE` | nothing in the root has changed for `--days` days (7) | `--delete --stale` |
| `KEEP` | the main checkout, a build lane, a keep-list entry, uncommitted changes, a running build referencing the root, or unmerged work built recently | never |

Without `--delete` it is a dry run. The keep list is
`~/.config/ubiquitty/keep-build-roots`, one root name, root path or worktree
path per line. It removes only directories named like a root directly under the
parent, never a symbolic link and never a root that holds a worktree, and it
reads the running processes again just before removing.

```sh
python3 Scripts/clean-build-roots.py                   # the table
python3 Scripts/clean-build-roots.py --delete          # ORPHAN and MERGED
python3 Scripts/clean-build-roots.py --delete --stale  # and STALE
```

### Build lanes

A new worktree has an empty build root, so its first build compiles the app
from nothing: the Swift, the PGO-instrumented C++, ThinLTO and the link. ccache
covers only the C++ compiles. `Scripts/build-lane.py` keeps a few long-lived
worktrees, the lanes, whose roots stay warm, and runs a command in one of them:

```sh
python3 Scripts/build-lane.py run --wait 3600 --from "$PWD" -- Scripts/run-ui-tests.sh <scenario>
python3 Scripts/build-lane.py run --from origin/main -- Scripts/build-tests.sh
python3 Scripts/build-lane.py status          # each lane's holder, commit, root size and last write
python3 Scripts/build-lane.py root --lane 2   # a lane's build root
```

- **Lanes** are `lane-1` to `lane-N` in `ubq-lanes` beside the repository's
  main checkout; `--lanes-dir` or `UBQ_LANES_DIR` names another directory. N is
  two on macOS and three elsewhere, or `--lanes N`. Each lane is a detached
  worktree, created on first use.
- **Taking one.** A run locks a free lane with `flock`, trying first the lane
  its source used last; `--lane N` takes that lane only. While every lane is
  held it prints each holder's process, source and start time, waits up to
  `--wait` seconds (0 by default), and then exits 75. A lane whose lock is free
  while a build process still names it is passed over.
- **The tree.** `--from` names a worktree, by default the current directory, or
  a commit. A worktree brings its HEAD plus its staged, unstaged and untracked
  changes; `--no-untracked` leaves untracked files out. The lane becomes that
  tree exactly: the last user's edits, untracked files and unfinished merges go,
  and ignored files stay. Only files whose content differs are written, so
  ninja rebuilds what changed. HEAD is detached at the commit, with the changes
  staged.
- **The command** runs in the lane with `UBQ_BUILD_ROOT` set to the lane's
  root. To use that value in the command line, quote it for the lane's shell:
  `-- sh -c 'ninja -C "$UBQ_BUILD_ROOT/macos-uitest" Ubiquitty'`. SIGINT,
  SIGTERM and SIGHUP are passed on to the command. The lane is released when
  the command exits, whatever its status, and the run exits with that status.
  Status 70 means the lane could not be created or brought to the source.
- **Cleanup.** `clean-build-roots.py` keeps every lane's root, though a lane
  between runs is detached and clean on main.

| Component | Target | Build script | Output |
|---|---|---|---|
| macOS app | `Ubiquitty` (`.app`) | `Scripts/build-macos.sh` | `$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/Ubiquitty.app` |
| Linux frontend | `ubiquitty-linux` | `Scripts/build-linux-gtk.sh` | `$UBQ_BUILD_ROOT/linux/ubiquitty-linux` |
| Host daemon | `ubiquitty-host` | `Scripts/build-host.sh` | `$UBQ_BUILD_ROOT/host/ubiquitty-host` |
| Agent (MCP) | `ubq` | `Scripts/build-agent.sh` | `$UBQ_BUILD_ROOT/agent/ubq` |
| iOS app | `UbiquittyIOSApp` (`.app`) | `Scripts/build-ios.sh` | `$UBQ_BUILD_ROOT/ios-{iphonesimulator,iphoneos}/Ubiquitty.app` (plus Core archives) |
| Web / Wasm | `ubiquitty-web` | `Scripts/build-web.sh` | `$UBQ_BUILD_ROOT/web-dist/` |
| BSD console | `ubiquitty-wscons` | [Wscons CMake recipe](platform-builds.md#openbsd-and-netbsd-wscons) | `$UBQ_BUILD_ROOT/wscons/ubiquitty-wscons` |
| Core / Kit libraries | `ubiquitty-core`, `ubiquitty-kit`, `core-consumer` | [Core CMake recipe](platform-builds.md#libubiquittycore-and-ubiquittykit) | `$UBQ_BUILD_ROOT/core/` |
| Editor clients | Elisp / Lua | [Emacs](platform-builds.md#emacs), [Neovim](platform-builds.md#neovim) setup | Source clients plus a matching host binary |
| macOS + headless tools | — | `Scripts/build-all.sh` | macOS app, host, and ubq; `--headless` omits the app |

The build system is **CMake**; the frontend is selected with
`-DUBIQUITTY_FRONTEND=macOS|iOS|Linux|Host|Agent|Wscons|Core` (the scripts set this).
Web selects `Core` through Emscripten rather than a `Web` frontend value. iOS is
a cross build and needs three more flags — `-DCMAKE_SYSTEM_NAME=iOS`, a
`-DCMAKE_OSX_SYSROOT` naming the SDK, and `-DCMAKE_OSX_ARCHITECTURES=arm64` —
without which CMake compiles for the host and the arm answers a question about
macOS. `build-ios.sh` passes all three, and the frontend refuses to configure
without them rather than producing a green build that proves nothing. The portable
Core/Runtime/Sync is shared across targets. For a protocol change, rebuild the
affected host and clients together; `build-all.sh` covers the macOS app and
headless tools, not the other platform builds.

## Versioning

A **named version** is an annotated tag `vMAJOR.MINOR.PATCH` on `main`. The
version of any build is `MAJOR.MINOR.PATCH.N`, where `N` counts the commits the
build has that the nearest named version lacks. At the tag itself `N` is 0 and
is not printed, so the build of `v0.2.0` reads `0.2.0` and the build three
commits later reads `0.2.0.3`.

The number is a function of the commit: two machines building one commit print
the same version, and building twice changes nothing. It never counts builds
and never reads a clock.

| Tree | Version | `CFBundleShortVersionString` | `CFBundleVersion` | Build identity |
|---|---|---|---|---|
| At `v0.2.0` | `0.2.0` | `0.2.0` | `20000000` | `1a2b3c4d` |
| Three commits later | `0.2.0.3` | `0.2.0` | `20000003` | `5e6f7a8b` |
| The same, with a tracked file edited | `0.2.0.3` | `0.2.0` | `20000003` | `5e6f7a8b, modified` |
| A linked worktree on a branch, five commits past the tag | `0.2.0.5` | `0.2.0` | `20000005` | `9c0d1e2f` |
| No tag reachable (a shallow clone cut below it) | `0.2.0` | `0.2.0` | `20000000` | `9c0d1e2f, no version tag` |
| No repository (a source archive), or no `git` | `0.2.0` | `0.2.0` | `20000000` | `no git` |

- **The rule** is `Scripts/cmake/BuildVersion.cmake`. The build runs it, and
  `Scripts/build-version.sh [version|named|commits|bundle|identity]` prints its
  answers for a script. `./Scripts/run-tests.sh build_version` runs its tests
  against throwaway repositories.
- **The nearest tag** is the one `git describe --tags --match 'v[0-9]*' --long`
  picks, without `--first-parent`: a branch that merged `main` reaches `main`'s
  newest tag through the merge, and following first parents only would leave it
  on the version it branched from. `N` is describe's count, every commit
  reachable from the build and not from the tag, including merged branches.
- **The build identity** is a separate string for people: the commit's short
  hash, then what qualifies it (`modified` when a tracked file differs from the
  commit, `shallow clone`, `no version tag`, `no git`). About, `--version` and
  the logs print it beside the version. It is never part of the version and is
  never compared.
- **`VERSION`** at the repository root holds the last named version. It answers
  for a tree the repository cannot: a source archive, a shallow clone that does
  not reach a tag, a machine without `git`. The commit a tag names must carry
  the tag's number in `VERSION`, and the configure refuses one that does not.
- **Bounds.** A field is decimal with no leading zero; `MAJOR` is at most 999,
  `MINOR` and `PATCH` at most 99, `N` at most 99999. A tag matching `v[0-9]*`
  that is not `vMAJOR.MINOR.PATCH` within those bounds stops the configure with
  a message naming the tag, as does a build more than 99999 commits past its
  tag. The longest version is 15 bytes; the handshake's field holds 32.
- **Apple bundles.** `CFBundleShortVersionString` is `MAJOR.MINOR.PATCH`: the
  platform documents that key as exactly three integers. `CFBundleVersion` is
  one integer, `MAJOR × 10⁹ + MINOR × 10⁷ + PATCH × 10⁵ + N`. The platform reads
  at most three dotted fields of that key and ignores the rest, so a four-field
  build number would lose `N`; the updater compares the key's numeric fields as
  64-bit integers. The integer orders exactly as the versions do and never
  decreases from one tag to the next. An iOS build made for App Store Connect
  carries the upload's build number in that key instead
  ([Build numbers](#build-numbers)).
- **One generated file.** The version reaches a binary through one generated
  header in the build directory, which one translation unit (`Source/Core/BuildVersion.cpp`) includes. A
  build step rewrites it only when its text changes, so pulling one commit
  recompiles that file and relinks. Nothing passes the version on a compiler
  command line. Core's `buildVersion()` and `buildIdentity()` read it, for the
  terminal's own reports such as XTVERSION and for `Protocol::Sync::appVersion()`
  and `buildIdentity()`, which state it to a peer; `Protocol::Sync::compareAppVersions`
  (`AppVersion.h`) is the one place two versions are ordered.
- **A tree that cannot see its repository.** The Linux container builds are
  handed the checkout, and a linked worktree's repository is not inside it. The
  wrapper scripts derive the version outside and pass
  `UBIQUITTY_BUILD_VERSION` and `UBIQUITTY_BUILD_IDENTITY` in the environment,
  which replace the derivation and pass the same checks.
- **A build directory configured for another commit** reconfigures by itself:
  the configure depends on the worktree's `HEAD` and its log. A tag placed on
  the commit already configured moves the version without moving `HEAD`; the
  next build stops, says so, and the one after configures first. The build
  scripts configure on every run and never meet this.

### Naming a version

1. On `main`, set `VERSION` to the new number in a commit and land it.
2. Tag that commit, or any later one whose `VERSION` still holds the number,
   and push the tag:

   ```sh
   git tag -a v0.3.0 -m "Ubiquitty 0.3.0" <commit>
   git push origin v0.3.0
   ```

What changes: the tagged commit builds as `0.3.0`, and every commit after it as
`0.3.0.N` counted from the tag. Commits between the `VERSION` change and the tag
keep counting from the previous tag, so tag the commit that changes `VERSION`
when nothing else is meant. The bundle integer rises across the tag because the
named version's field is wider than any count.

## QUIC

The macOS and iOS app scripts and the static-musl Linux host script enable
QUIC (ngtcp2 + AWS-LC) by default. `build-host.sh` forces it on. The dependency
build needs Go and Perl; the static Linux build installs them in its container.
The Agent, Linux GTK, and Wscons targets do not link the native QUIC stack.
Standalone Core and Web examples configure `-DUBIQUITTY_QUIC=OFF`.

## Sync workspace web client

From the checkout, one command builds the client and opens a local connection:

```sh
Scripts/open-web.sh
```

Or connect to an SSH alias using your existing SSH configuration and keys:

```sh
Scripts/open-web.sh devbox
```

Leave that first launcher running. Run the command again in another terminal
with a different host (or `local`) to add it to the **same browser session**.
Choose the host below the workspace name in the sidebar. **Add host…** includes
copyable commands that target the running launcher, including its build root.
New hosts appear automatically without interrupting the active terminal. The
client remembers each host's selected workspace, group and pane while the page
is open. Switching detaches the browser, leaving host sessions running.

On macOS the launcher discovers listening hosts and pairs the selected daemon
with its own `ubiquitty-host --attach` executable. If none listens, it starts
the installed helper. SSH uses `~/.ubiquitty/ubiquitty-host` on the remote host
and starts its daemon if necessary. Install Ubiquitty there first; use
`--remote-binary /path/to/ubiquitty-host` for a different installation and
`--remote-socket host-<id>.sock` to select an exact compatible daemon. The
launcher does not install, replace or upgrade hosts. Client and host must use
compatible Sync builds.

For an exact local daemon, pass `--socket /absolute/path/host-<id>.sock
--host-binary /path/to/ubiquitty-host`. A native relay needs no token;
`--token-file` is available for a host that requires a capability token.
Authentication happens in the terminal running the command. The browser never
needs an SSH password or private key. Ctrl+C stops the web bridge; the host and
its sessions stay running. At most eight hosts can be registered per launcher.

Set `UBQ_BUILD_ROOT` to reuse a prepared build and add `--no-build` to skip the
initial build. For direct staging, `python3 Scripts/serve-web.py --stage
/path/to/web-dist [--ssh devbox]` provides the same launcher. A private registration
file in the build root allows later invocations to add hosts; its administrative
secret is never included in the browser configuration.

The workspace chooser lists the host's actual windows, tabs, panes, labels,
process chains and program status. A private Mac window must first be shared
from **File → Share This Window with Agents**. A connected host with no shared
windows also permits creating a workspace from the chooser. Sharing, access
decisions and layout changes remain host-authorized operations.

The sidebar presents multi-pane tabs as groups. Sessions can split on either
axis, move to any pane edge, move between groups or into their own tab, and
groups can move between windows. Drag previews move the entire projected layout
while retaining terminal pixel dimensions until release. The inspector reads
all processes in the selected PTY subtree through `pane.processes`, including
background jobs; an older host without this method reports it as unavailable.
The process snapshot is bounded to 128 records and 48 KB, with an explicit
incomplete flag when the host cannot return the whole tree.

Settings stores browser-local terminal and proportional font families and sizes,
OpenType features, ligatures, font weights, character and line spacing, underline
geometry, padding and theme. Rendering preferences use Core’s defaults and
bounds. The default family prefers SF Mono where the browser exposes it, with
system monospace fallbacks. SF Mono is not bundled. Themes come from Core;
the sidebar follows the selected terminal palette. People, agents and pending
access requests live in the workspace controls. Beam opens with Cmd+Shift+P
(Ctrl+Shift+P on other platforms). Browser-reserved shortcuts may remain with
the browser; every action is also reachable by a button or menu.

The browser presents Kitty images through the same WebGL canvas as text, loads
bundled Nerd glyph coverage before routing fonts, and uses Core’s bracket-piece
placement. Core parses and lays out rich-text blocks; the browser supplies native
shaping and a retained text layer, including selection, clipping and the caret.
Hidden panes can still answer host typography requests. Rich text is visual DOM
content over the canvas, so the low-level `snapshot()` pixel API contains the
canvas layers only; workspace drag previews retain the complete live viewport.
Hidden pane renderers release their WebGL contexts and rebuild the GPU atlases
when shown again, while Core retains the terminal state.

Browser renderer regressions are separate from the shipped workspace. To run
them against a build, copy `Tests/Web/renderer-features.html`,
`Tests/Web/rich-text-workspace.html`, `Tests/Web/rich-text-tabs.html` and
`Tests/Web/cpu-presentation-parity.html` into `web-dist`, then open each file
under the launcher's printed base URL. They report PASS or MATCH for real font
routing, rich-text appearance changes, per-pane measurement ownership,
hidden-tab layout, adapter cleanup, rich-text tab stops measured and presented
on one grid, and CPU/GPU image presentation. The build also runs the ABI and
page initialization checks.

The launcher admits only its secret path and explicit local page origin before
starting a native relay. Do not expose this development launcher on a public
interface. A remote deployment serves `web-dist` over HTTPS and supplies an
authenticated WSS bridge; the host must recognize its native relay to admit a
human workspace attachment. The old direct Python socket proxy is an agent
attachment and cannot attach a whole workspace.

The Web client supports OSC 66 sized/proportional text, Kitty inline images and
RTF rich-text blocks. Rich-text shaping and drawing use browser fonts and may
wrap differently from Apple and Linux; the shared source and cell placement
remain authoritative.

## Embedding the Web terminal

Build with `Scripts/build-web.sh`; the generated ES module exposes a standalone
terminal or a workspace carrier with independently selected pane views. The
workspace shell shares one module and one Sync connection; its retained iframe
views select their own native terminal before every synchronous ABI call.
Presentation code can retain a view while moving its canvas, and call
`ubiquittyWebResize` only when committing a new grid size.

The browser frontend in `Source/Platform/Web/index.html` and `terminal.js` can
also be embedded as a whole. This reuses its keyboard, IME, native clipboard,
Core pointer ladder, precision wheel, renderer, and Sync connection handling.
Keep each iframe connected when moving between layouts: removing or reparenting
an iframe destroys its browsing context. A parent can position retained frames
over its pane surfaces and use frozen snapshots during a drag.

After `await frame.contentWindow.ubiquitty.ready`, the page handle provides:

- `configure({fontFamily, fontSize, lineSpacing, padding, theme})`: apply presentation and
  refit the grid, sending a host resize when connected. Values are CSS pixels;
  font size accepts 6–100 and spacing/padding accept 0–100. Omitted values stay
  unchanged. These choices do not overwrite the page's saved defaults.
  An empty theme follows the host palette; a font family uses browser fonts.
- `focus()`: focus the page's IME target. Embedded pages do not claim focus at
  startup; the parent decides which pane receives typing.
- `metadata`: decoded program metadata, with the same schema below.
- `capture()`: diagnostic cell and palette capture.
- `snapshot()`: an owned `{width, height, scale, pixels}` RGBA raster, even when
  the visible canvas uses WebGL. Pixels remain valid after later paints.
- `clear()`: clear local scrollback or request the attached host's buffer clear.
- `setLocalProgram({input, paste})`: replace standalone key echo with a sample
  program or local backend. `input(Uint8Array)` receives Core-encoded key bytes
  and composition text; `paste(string)` receives a separate clipboard intent,
  as a Sync host does. The backend owns paste handling and program output.
  Passing `null` restores the standalone echo behavior.
- `feed(string)`: deliver a standalone program's output, then repaint.

`feed` and `setLocalProgram` reject a host mirror, including after detach:
local output must never modify a host-owned screen. `connect`, `detach`, search,
and outline APIs continue to use the page's existing implementation. Clipboard
copy and paste use native browser events for the standard Cmd chords, so an
embedded page does not need an asynchronous clipboard permission request to
receive a paste explicitly initiated by the user.

`ubiquittyWebProgramMetadataJSON` returns `null` before creation, then a
non-consuming JSON snapshot of the terminal's decoded program metadata:

- `programTitle` and `currentDirectory` are the raw program-provided values.
- `records` contains OSC 7501 records in oldest-to-newest update order: `id`,
  `app`, inherited `effectiveApp`, decoded `title` and `message`, `state`,
  `kind`, and nullable `progress`.
- `primaryRecord` is Core's selected record index, or `null` when absent.
- `progress` carries OSC 9;4 `state` (0–4) and `value`, separately from record
  progress. Reading it does not drain `ubiquittyWebTakeProgressReports`.
- `isReadingCommand` reflects OSC 133 shell integration. It does not claim a
  sampled foreground process identity. `exitStatus` is `null` until a command
  completion is reported.
- `host` is null for a standalone terminal. After a host reports pane facts,
  it contains the foreground name and PID (null when unknown), process chains
  with and without arguments, shell name, terminal name, host name, and the
  host's `isAtPrompt` and `didEnd` facts. These are the already-decoded facts
  the host authorized this client to receive; they do not sample browser-side
  processes or infer identities from program titles.

The returned string belongs to the terminal and remains valid until the next
metadata read. It contains no grid cells; use `ubiquittyWebCaptureProgramState`
for diagnostic cell capture. Metadata does not grant a program or agent any
input or workspace permissions. Remote host bytes still enter through the
Sync bridge, rather than the local `ubiquittyWebFeed` parser entry point.

`ubiquittyWebEncodeLocalKeyEvent` writes a standalone terminal's mode-aware
input bytes into a caller-owned buffer and returns their explicit length.
It accepts the same six key facts as `ubiquittyWebFeedKeyEvent`, followed by
the output pointer and capacity. It does not echo into the terminal. Deliver
those bytes to the local PTY or sample program; feed only that program's output
back through `ubiquittyWebFeed`. Tab, control characters (including NUL), and
application cursor modes therefore use Core's encoder. An absent terminal,
invalid buffer, suppressed event, or insufficient capacity returns zero.
Remote attachments use `ubiquittyWebBuildKeyEvent` instead: the host owns the
modes used to encode their input.

## macOS

### Prerequisites
- **Xcode** (full app, not just Command Line Tools — needed for the Metal
  shader compiler), `xcode-select -s /Applications/Xcode.app/...`.
- **Go** (`brew install go`) — required to build the AWS-LC QUIC dependency.
- **Ninja** (`brew install ninja`) — required for the Swift-enabled build.
- **OrbStack or Docker Desktop** — builds the static Linux hosts bundled for SSH installation.
  Verified hosts from the same source and build configuration are reused without Docker.
  Without Docker and without them, the build stops after the app and its helpers;
  `--no-linux-hosts` (or `UBIQUITTY_LINUX_HOSTS=0` for `install-macos.sh`) builds
  the app without them.
- For auto-update: follow the [Sparkle build instructions](auto-update.md#build)
  to fetch the pinned framework into `$UBQ_BUILD_ROOT/sparkle` and select it.

### Build
```sh
./Scripts/build-macos.sh            # RelWithDebInfo (default)
./Scripts/build-macos.sh --debug    # Debug
./Scripts/build-macos.sh --run      # build + launch
./Scripts/build-macos.sh --no-helpers   # skip bundling ubiquitty-host/agent (fast)
./Scripts/build-macos.sh --no-linux-hosts   # native helpers only; no Linux auto-install
./Scripts/build-macos.sh --app-name UbiquittyCanary   # build UbiquittyCanary.app
```
Signing: a self-signed `Ubiquitty Dev` cert is used if present, else ad-hoc;
override with `UBIQUITTY_SIGN_IDENTITY`. The build signs the bundled helpers and
(when present) `Sparkle.framework`'s nested code before sealing the app — never
`codesign --deep`.

### Xcode workspace

Generate the CMake-backed Xcode projects, then open the workspace:

```sh
./Scripts/generate-xcode-workspace.sh
open -a Xcode Ubiquitty.xcworkspace
```

The workspace contains separate projects for the macOS app, the host daemon,
the agent, and the iOS app. They use independent CMake caches under
`build/xcode/`, because each selects a different `UBIQUITTY_FRONTEND`.
Generation enables QUIC, matching the shipping transport configuration. Use
`./Scripts/generate-xcode-workspace.sh --without-quic` only for
dependency-free local work. The script ends by running
`Scripts/check-xcode-workspace.py`, which reads the generated projects and
refuses one that a destination Xcode offers could not build.

iOS details:

* `build/xcode/ios/UbiquittyIOS.xcodeproj` — the iOS app, one project for both
  SDKs. Select the `UbiquittyIOSApp` scheme and any destination: an iPhone or
  iPad builds against `iphoneos` (`arm64-apple-ios26.0`) and signs with the
  development team; a simulator builds against `iphonesimulator`
  (`arm64-apple-ios26.0-simulator`) and needs no signing identity.
* The project is configured for the `iphoneos` SDK and Xcode derives the
  simulator from it. What differs per SDK — the SwiftPM archive, the shader
  library, the icon and the QUIC archives — is built into a directory per SDK
  (`build/xcode/ios/iphoneos`, `build/xcode/ios/iphonesimulator`) that the
  project names through `$(PLATFORM_NAME)`.
* The Swift targets (`UbiquittyRenderKit`, `UbiquittyKitModule` and the app)
  compile whole-module in every configuration, Debug included. Across an
  import, an incremental compile on either side loses members whose
  signatures name imported C++ types, and the importer fails with
  "has no member".
* The iOS CMake arm is still the authority for what links: the Xcode project
  carries the same `ubiquitty-core-ios` + `UbiquittyRenderKit` +
  `UbiquittyKitModule` + `UbiquittyIOSApp` targets that `Scripts/build-ios.sh`
  proves via Ninja, plus a `libUbiquittySSH.a` built from
  `Source/Platform/Apple/SSH` via SwiftPM (first build fetches `swift-nio-ssh`).
* Minimum deployment target is 26.0 (`UBIQUITTY_IOS_MIN` in `CMakeLists.txt`),
  built against the 27.1 SDK or newer (`UBIQUITTY_IOS_SDK_MIN`), which declares
  the bar priorities and the Duo arrangement the app reaches through availability;
  the app's `UISupportedInterfaceOrientations` covers iPhone + iPad.

Useful selections:

```sh
./Scripts/generate-xcode-workspace.sh --without-ios   # macOS/host/agent only
./Scripts/generate-xcode-workspace.sh --ios-only       # the iOS project only
./Scripts/generate-xcode-workspace.sh --without-quic   # skip QUIC deps (faster)
```

`--ios-only` leaves `UbiquittyIOS.xcworkspace` to open. It is committed beside
`Ubiquitty.xcworkspace` and names the iOS project alone, because a workspace
naming a project that was not generated is one `xcodebuild` cannot list.

### iOS (app)

The iOS frontend is SwiftUI over the same portable Core and Apple-shared Swift
layer that the macOS app uses (`Source/Platform/iOS/App/`, `Source/UbiquittyKit`,
`Source/UbiquittyRenderKit`). There is no local PTY — the platform runs no
child process — so a session arrives over the delegated carrier (an SSH channel
to an ordinary `sshd`). See `Source/Platform/iOS/SessionBridge.h` for the C
seam Swift cannot derive from.

#### Prerequisites

* Xcode with the iOS 27.1 or newer SDKs (`iphoneos`, `iphonesimulator`),
  not Command Line Tools alone — `xcode-select -s /Applications/Xcode.app`.
* No extra hosting: the simulator build is `CODE_SIGNING_ALLOWED=NO`.

#### Build and test

```sh
./Scripts/build-ios.sh                         # simulator and device apps
./Scripts/build-ios.sh --sdk iphonesimulator --ui-tests
./Scripts/run-ios-smokes.sh
./Scripts/run-ios-ui-tests.sh
```

The Ninja build produces `Ubiquitty.app` directly, along with the Core archives
and an `-all_load` link probe. The test scripts install and launch the simulator
app on a simulator owned by this checkout. The UI suite drives the actual host
editor and terminal gestures. Live SSH/QUIC cases need the credentials described
in `Scripts/run-ios-ui-tests.sh`; without them those cases report skips.
CI includes `ios-build`, `ios-smokes`, and `ios-ui` in the Apple battery.

For interactive development, run `./Scripts/generate-xcode-workspace.sh --ios-only`,
open `UbiquittyIOS.xcworkspace`, and select `UbiquittyIOSApp` with an iPhone, an
iPad or a simulator as the destination. A physical device needs a development
signing team and provisioning profile in Xcode. The app requires iOS 26.0 or later.

See [iPhone and iPad interface](ios-interface.md) for navigation, panes, files,
and permission controls.

The iOS app connects to `ubiquitty-host` over SSH, stores credentials in
Keychain, and can upgrade an authenticated connection to QUIC. It does not
launch a local shell on the phone.

### Bundle identity
A plain `./Scripts/build-macos.sh` is a development build, `org.ubiquitty.Ubiquitty.dev`.
Only `--release` and `--release-signing` build the app people install,
`org.ubiquitty.Ubiquitty`, and the UI-test build is `org.ubiquitty.Ubiquitty.uitest`.
User defaults, saved window state and notification routing all key on the
identifier, and a notification click goes to whichever registered bundle
LaunchServices resolves it to, not to the process that posted it. So a
development build under the release identifier is one more copy a click can
launch instead of focusing the running app. `package-macos.sh`,

identifier.

### Install locally
`./Scripts/install-macos.sh` builds `--release`, checks the identifier, the
signature, the bundled `ubiquitty-host` and `--smoke-surface`, and moves the
build into `/Applications`. It keeps one previous version, outside
`/Applications` and out of LaunchServices. It never replaces the bundle of a
running Ubiquitty, because the running process would carry on from wherever its
bundle was moved to while the identifier names the new one. When the app is
running it stops and says so; with `--wait-for-quit` it installs the moment the
app quits, from a waiter that outlives the terminal it was started in. `--open`
opens the installed app afterwards; `--app PATH` installs a release bundle
built elsewhere.

### Package / distribute
- Quick share (zip): `./Scripts/build-macos.sh --release`, then `./Scripts/package-macos.sh` → `$UBQ_BUILD_ROOT/share/Ubiquitty.zip`.

  `UBIQUITTY_RELEASE_SIGNING=ON` makes the host accept as its successor, its app and its relay only code the
  release team signed, as `ubiquitty-host` or the released app, and refuses an unsigned or ad hoc binary
  wherever it lies. Every other build's host also trusts the files it was installed as
  ([`sync.md` §6.13](sync.md#613-host-handover-live-sessions-survive-a-host-upgrade)).
- Notarized archive of this commit: `./Scripts/archive-macos.sh` fetches Sparkle, builds with Developer ID signing,
  notarizes, staples and checks the app, then keeps the zip, its dSYM, the build log and an `archive.json`
  record under `~/Library/Developer/Ubiquitty/Archives/` (`UBQ_ARCHIVE_ROOT` names another).

## iOS archive

App Store Connect takes the iOS app as an archive of the `UbiquittyIOSApp`
scheme in `UbiquittyIOS.xcworkspace`, made for `generic/platform=iOS`. Xcode
Cloud makes it from a clone of the repository once `ci_scripts/ci_post_clone.sh`
has generated the project ([Xcode Cloud](#xcode-cloud)). `xcodebuild archive`
over a project generated with `--ios-only` makes the same archive on a Mac.

### The archive

The generated project installs the app into the archive's
`Products/Applications` (`SKIP_INSTALL = NO` and
`INSTALL_PATH = $(LOCAL_APPS_DIR)` on the app target) and keeps every other
target out (`SKIP_INSTALL = YES` for the project). An archive that holds a
library, the link probe or anything else beside the app is a generic archive,
which App Store Connect refuses. `Scripts/check-xcode-workspace.py` reads both
settings from the generated project, so `generate-xcode-workspace.sh` reports a
project whose archive would be refused.

The archive builds the Release configuration, and a TestFlight build is the
build that ships, so Release gets what the Ninja Release build gets. The Xcode
generator is multi-configuration and leaves `CMAKE_BUILD_TYPE` empty, so these
are set for the optimized configurations by name rather than keyed off the
build type:

- link-time optimization (`LLVM_LTO`) for every target that compiles C or C++,
  the link probe included, which the generator would otherwise leave out
  because it links as Swift;
- the training profile, `-fprofile-use` with the copy of
  `Support/pgo/portable-core.profdata` rooted for the checkout;
- the release path map, which keeps the builder's paths out of the binary.

Release also keeps its debug information, which the Ninja Release build does
not: every product is built with it (`GCC_GENERATE_DEBUGGING_SYMBOLS = YES`)
and it is kept as a dSYM (`DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`), which
the archive carries in `dSYMs/` and App Store Connect symbolicates crashes from.
Two settings make that hold:

- `DWARF_DSYM_FOLDER_PATH` is `$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)`,
  the build products folder an archive gathers dSYMs from. The generator points
  `CONFIGURATION_BUILD_DIR` into the CMake build tree, and a dSYM that follows
  it there is never archived.
- Swift compiles with `-Xfrontend -no-clang-module-breadcrumbs`. The
  breadcrumbs name the explicitly built clang module files, which `dsymutil`
  cannot find when the archive runs it, and it warns about each one. Swift's
  own debug information is unchanged, and lldb imports the clang modules from
  their headers.

`check-xcode-workspace.py` fails a generated iOS project whose Release
configuration lacks any of link-time optimization, the profile or the dSYM. A
compiler that cannot read the profile therefore fails the generation instead of
producing an unprofiled TestFlight build.

### Build numbers

- `CFBundleShortVersionString` is the named version, as for the macOS app.
  `CFBundleVersion` is the build number.
- App Store Connect takes an upload only when its build number is above every
  earlier upload with the same `CFBundleShortVersionString`. Xcode Cloud counts
  the builds of the app, 1, 2, 3 and on, as `CI_BUILD_NUMBER`, and an upload it
  makes carries that count as its build number, whatever the archived bundle
  says.
- `UBIQUITTY_IOS_BUILD_NUMBER` sets the iOS app's `CFBundleVersion`.
  `Scripts/generate-xcode-workspace.sh` passes it to the configure on every run,
  and `ci_post_clone.sh` sets it to `CI_BUILD_NUMBER`, so an Xcode Cloud archive
  carries the number its upload does.
- Without `UBIQUITTY_IOS_BUILD_NUMBER`, the iOS app carries the version's bundle
  integer ([Versioning](#versioning)), as every other bundle does. That integer
  is above any count Xcode Cloud reaches, so an upload carrying it would make
  App Store Connect refuse every later Xcode Cloud upload of that version.
- A build number is decimal digits with no leading zero, at most nine of them;
  the configure refuses anything else.
- The macOS app's `CFBundleVersion` stays the bundle integer, which Sparkle
  orders updates by.

### Xcode Cloud

Xcode Cloud clones the repository, runs `ci_scripts/ci_post_clone.sh`, and
archives. Xcode Cloud looks for `ci_scripts/` beside the workspace a workflow
builds, which is why both sit at the repository root. The script:

1. installs CMake and Go with Homebrew, which the build image carries, and
   Perl when the image lacks it. The configure that writes the project
   cross-builds AWS-LC and ngtcp2, the QUIC dependencies, and needs all three
   and the network;
2. fetches the history and tags its shallow clone leaves out, so the version is
   counted from the nearest tag rather than read from `VERSION`. A clone of a
   repository that holds no version tags fetches none: its build identity reads
   `no version tag`, and its version is `VERSION`'s, the last named version,
   without the count of commits since it. The marketing version and the build
   number are unaffected;
3. runs `Scripts/generate-xcode-workspace.sh --ios-only` with
   `UBIQUITTY_DEVELOPMENT_TEAM=5TC8J8TCS3` and
   `UBIQUITTY_IOS_BUILD_NUMBER=$CI_BUILD_NUMBER`, with the build root inside
   the clone (`build/xcode-cloud`), beside the project that links the QUIC
   archives from it. For an archive action (`CI_XCODEBUILD_ACTION=archive`,
   with `CI_XCODE_CLOUD` or `CI` set) it adds `--device-only`, which builds the
   QUIC dependencies for `iphoneos` alone (`UBIQUITTY_IOS_DEVICE_ONLY`): an
   archive never builds for the simulator. A local generation keeps both SDKs;
4. stops when generating changed a tracked file, which the build would report
   as a modified tree in its build identity.

It refuses a workflow for another platform than iOS and one whose team
(`CI_TEAM_ID`) is not 5TC8J8TCS3. The QUIC dependencies are built into the
fresh clone, so every Xcode Cloud build builds them again. The archive step
needs nothing more, so there is no `ci_pre_xcodebuild.sh`. Run by hand with
`CI_BUILD_NUMBER` set, the script prepares the checkout it is in the same way.

### Privacy manifest

`Source/Platform/iOS/App/PrivacyInfo.xcprivacy` is bundled at the root of the
app. App Store Connect refuses an upload that calls an API on Apple's
required-reason list without declaring a reason for it there. The manifest
declares no tracking, no tracking domains and no collected data types: the app
sends what it handles to the hosts the person using it names, and to no one
else.

The APIs below are the ones on Apple's list that a device build of the app
imports, read from the binary with `nm -u` and traced to the code that calls
them. It imports no disk-space and no active-keyboard API.

| Category | What the app calls | Reason | Why, from the code |
|---|---|---|---|
| User defaults | `UserDefaults.standard`, `@AppStorage` | `CA92.1`, data only the app reads | `HostSessionsView` keeps the order of the workspace list, and `BackgroundRefreshCoordinator` the next host to refresh, in the app's own standard defaults. |
| System boot time | `mach_absolute_time()`, `ProcessInfo.systemUptime` | `35F9.1`, time elapsed within the app | `Source/Platform/Apple/Clock.cpp` backs Core's monotonic clock, whose readings pace the ingest loop as intervals; the surface measures double taps, render passes and presentation with `systemUptime` differences. |
| File timestamps | `stat`, `fstat`, `fstatat`, `lstat`, `contentModificationDateKey` | `C617.1`, files in the app's container | `BackgroundRefreshStore` reads when a record in Application Support was written; Core checks the directories and files it keeps in the container (`SystemPAL.cpp`, `ColdResumeBridge.cpp`, `SocketPath.cpp`). |
| File timestamps | `fstat`, `fstatat` | `3B52.1`, files the person granted access to | `DropFiles.cpp` reads the type and size of the files the person drops onto the terminal's file tools or picks with the file importer, before sending them to the host. |

## Linux

### Prerequisites
- A Linux host (cannot build on macOS). Fedora, Debian 13 and Ubuntu 26.04 work.
- `cmake`, `ninja` (or make), and a C++23 compiler: **GCC 14** or newer, or
  **Clang 19** or newer. Configure stops on an older one and names the fix;
  the same floor applies to `build-host.sh` and `build-agent.sh` on Linux. On
  macOS the build uses Apple clang from Xcode.
- **GTK 4.16 or newer** (`-dev`) + the **Vulkan** loader/headers, and **glslc**, which
  compiles the renderer's shaders. Mesa **lavapipe** covers headless/CI rendering.
  Without glslc the configure stops; `UBIQUITTY_LINUX_GPU_SHADERS=OFF` in the
  environment of `build-linux-gtk.sh` builds a binary that renders on the CPU only.
  - Debian 13, Ubuntu 26.04 and newer: `apt install cmake ninja-build g++ pkg-config libgtk-4-dev libvulkan-dev glslc`.
    Ubuntu 24.04 cannot build the frontend, because its GTK is 4.14. Its plain
    `g++` is GCC 13 and its `clang` is Clang 18, both below the compiler floor,
    so the headless host builds there with `g++-14` installed and
    `CC=gcc-14 CXX=g++-14`. CMake keeps the compiler a build directory was
    first configured with, so switch compilers in a fresh directory.
  - Fedora: `dnf install cmake ninja-build gcc-c++ gtk4-devel vulkan-loader-devel glslc`
  - Arch: `pacman -S cmake ninja gcc pkgconf gtk4 vulkan-headers vulkan-icd-loader shaderc`
- Release builds with Clang apply the training profile in `Support/pgo` when the
  compiler can read it, and otherwise build without it and print
  `PGO: NOT APPLIED` with the compiler's reason. GCC never reads it.
  `UBIQUITTY_PGO=OFF` in the environment of a build script, or
  `-DUBIQUITTY_PGO=OFF` on a hand-run configure, leaves it out. The profile's
  drift from the tree is bounded twice in the pre-push gates, per push and in
  total against a budget recorded beside the profile, and the profile is
  renewed by `Scripts/pgo-retrain-check.sh --retrain` weekly or when the gate
  warns; `Support/pgo/README.md` has the rules.

### Build
```sh
./Scripts/build-linux-gtk.sh            # Debug, quiet
./Scripts/build-linux-gtk.sh Release
VERBOSE=1 ./Scripts/build-linux-gtk.sh  # stream full output (log: $UBQ_BUILD_ROOT/linux/build.log)
"$UBQ_BUILD_ROOT/linux/ubiquitty-linux"             # run (headless self-tests: --smoke, --dump-png, …)
```

### Package / distribute (AppImage)
```sh
./Scripts/build-appimage-support.sh  # once per native architecture, using Docker
./Scripts/package-linux-appimage.sh
```
Produces `$UBQ_BUILD_ROOT/dist/Ubiquitty-<version>-<architecture>.AppImage` (+ `.zsync` and a support-source archive) with
`zsync` update metadata. It's a **thin** AppImage (bundles the binary with its shaders and fonts, and
`appimageupdatetool`; relies on the host's glibc 2.38, GCC 13's libstdc++ and
GTK 4.16, or newer, and the Vulkan loader); first run needs no install. The
script reads the newest glibc and libstdc++ symbol versions the binary asks for
(`GLIBC_2.38` and `GLIBCXX_3.4.31` at most) and refuses one that asks for more.

Build in the CI image (`Scripts/ci-linux-image.sh`) with the clang that
applies the training profile, under `UBIQUITTY_PGO=REQUIRE`. Details + the in-app
"Check for Updates…" flow: [`auto-update.md`](auto-update.md#linux-appimage).

### Standalone command-line client

`Scripts/build-agent-linux.sh` builds static-musl `ubq` binaries for x86_64 and
ARM64 using Docker. Pass one architecture to build only that binary:

```sh
UBQ_BUILD_JOBS=4 ./Scripts/build-agent-linux.sh arm64
```

Output is under `$UBQ_BUILD_ROOT/agent-linux`. `UBQ_AGENT_LINUX_SOURCE` selects
another source checkout; `UBQ_AGENT_LINUX_OUTPUT` selects the output directory.
The build uses GCC 15 and does not apply the Clang PGO profile.

## Benchmark lanes (optional)

The parse-scenario lane (`Scripts/run-parse-scenarios.sh`) and the throughput
bench harness read their workloads from a checkout of
[ubench](https://github.com/ubiquitty/ubench) (`UBENCH_DIR`). They
are optional: no build, test suite, CI job, or contribution check requires
them. To run them, set `UBENCH_DIR` to the checkout's location.

## Distribution channels

The [downloads page](https://ubiquitty.org/) offers the macOS app, Linux
AppImages, and standalone host and command-line binaries. macOS updates use
Sparkle; Linux AppImages use zsync. See [Application updates](auto-update.md)
for the client behavior.

The iOS app goes to TestFlight as the archive Xcode Cloud makes after
`ci_scripts/ci_post_clone.sh` ([iOS archive](#ios-archive)).

## CI

### Source export

`Scripts/snapshot-clean.sh` validates the committed `HEAD` and can copy it into
a new directory. Install CMake, the selected frontend's build dependencies, and
Gitleaks first. The checks run against the exported files, including license
inventory, Markdown links, Core/host build smoke, frontend configuration, and
secret/personal-path scans.

```sh
nice -n 19 env UBQ_BUILD_JOBS=1 Scripts/snapshot-clean.sh
nice -n 19 env UBQ_BUILD_JOBS=1 Scripts/snapshot-clean.sh --output /tmp/ubiquitty-source
```

The destination's parent must exist and the destination must not exist. A dry
run writes no export. The command does not commit, push, rewrite Git history, or
change visibility. It exports committed files only; uncommitted changes are not
included. `UBIQUITTY_SNAPSHOT_SKIP_BUILD=1` is available for a documentation check
and is reported as a skipped build, not release validation.

Use this for a source distribution. Export validation checks the source tree;
it does not establish runtime safety or feature completeness.

### Workflows

- `.github/workflows/ci.yml` — tests, coverage, fuzz, style, portable snapshots
  on Linux, and portable plus CoreText/Metal snapshots on macOS for every PR.


### Runners and fork pull requests

Every workflow runs on GitHub-hosted runners. Workflow conditions cannot protect
self-hosted machines: a pull request can replace its own `runs-on` declaration.
The repository settings must enforce these requirements:

- **No self-hosted runner can reach it.** The list under Settings → Actions →
  Runners is empty. An organization that shares its runners does so only through
  a runner group whose repository access leaves public repositories out, which
  is a group's default. A repository owned by a personal account has no runner
  groups, so its runners are removed rather than restricted.
- **Every outside contributor's run waits for approval.** Under Settings →
  Actions → General, the approval policy for fork pull request workflows is the
  strictest one, covering all outside contributors rather than only first-time
  ones.

### SSH authentication for desktop remote sessions

Desktop SSH uses OpenSSH in batch mode with key or agent authentication. Before
connecting in the app, run `ssh user@host` in a terminal to verify the host key
and confirm authentication works. Password prompts are unavailable in the app's
subprocess transport. Authentication and host-key failures appear as connection
errors and stop automatic retries; correct the credential or trust entry before
reconnecting. Host-key verification remains enabled.

QUIC uses the `HostName` from `ssh -G` for the same SSH destination, so usernames
and SSH aliases are not passed to DNS as host names. Token and certificate-pin
exchange still travels over authenticated SSH. Unreachable UDP paths fall back
to SSH.
