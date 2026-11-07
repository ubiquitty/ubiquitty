<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Build Ubiquitty for each platform

Run commands from the repository root. Build products go outside the checkout;
the scripts resolve a separate directory for each checkout. Set it explicitly
when following the output paths below:

```sh
export UBQ_BUILD_ROOT="$(python3 Libraries/ubiquitty-core/Scripts/build_root.py .)"
export UBQ_BUILD_JOBS=4
export CMAKE_BUILD_PARALLEL_LEVEL="$UBQ_BUILD_JOBS"
```

The job count is an example, not a required setting: choose it for the machine's
available memory and cores, and coordinate concurrent work on shared machines.
Do not run timing-sensitive tests alongside another build.

## Common prerequisites

- Git, Python 3, CMake, and Bash. Use Ninja for Apple Swift and Web builds;
  the native headless and Linux scripts can also use Make.
- C++23 and a standard library with `std::expected`: GCC 14+ or Clang 19+
  for non-Apple native builds. Apple builds use Xcode's toolchain. The compiler
  and library feature checks live in `Libraries/ubiquitty-core/Scripts/cmake/ToolchainFloor.cmake` and
  `Libraries/ubiquitty-core/Source/Base/ToolchainFloor.h`.
- Set `CC` and `CXX` before configuring if the system default is older. For
  example, after installing GCC 14, use `CC=gcc-14 CXX=g++-14`. Choose a fresh
  build directory when switching compilers; CMake caches the compiler.
- The first QUIC-enabled build fetches pinned ngtcp2 and AWS-LC sources and
  needs network access, Go, and Perl. Apple SSH dependencies are also fetched
  on their first build. The platform sections identify which builds need them.

The CMake frontend selectors are `macOS`, `iOS`, `Linux`, `Host`, `Agent`,
`Wscons`, and `Core`. Web uses `Core` with Emscripten. Emacs and Neovim are
interpreted clients, not CMake frontends. `Source/Platform/Apple`, `POSIX`,
and `Wasm` provide shared platform code rather than additional applications.

## macOS

Use an Apple-silicon Mac with macOS 26 or later and full Xcode, including
Apple clang 21, Swift 6, the macOS SDK, and the Metal compiler. Command Line
Tools alone do not provide the required Apple build tools. Install CMake,
Ninja, Python 3, Go, and Perl; select the intended Xcode with `xcode-select`.
If `xcrun -f metal` cannot find Metal, install Xcode's Metal Toolchain component.

```sh
./Scripts/build-macos.sh
./Scripts/build-macos.sh --debug
```

The default is an optimized development app at
`$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/Ubiquitty.app`. The script also
builds and bundles matching `ubiquitty-host` and `ubq` helpers, and the static
Linux hosts the app installs over SSH. Those are built in a container, so they
need Docker (OrbStack or Docker Desktop) unless the build root already holds
verified ones from the same source; without Docker the build stops after the
app and helpers. `--no-linux-hosts`, or `UBIQUITTY_LINUX_HOSTS=0` for
`./Scripts/install-macos.sh`, builds without them. Use `--release` for the
release bundle identifier, or `--run` to launch after building. Signing,
Sparkle, installation, and packaging are described in the
[release guide](building-and-releasing.md#macos).

For Xcode development, run `./Scripts/generate-xcode-workspace.sh` and open
`Ubiquitty.xcworkspace`; see the
[workspace instructions](building-and-releasing.md#xcode-workspace).

## iOS and iPadOS

Build on an Apple-silicon Mac with full Xcode providing the iOS **27.1+ SDKs**
(`iphoneos` and `iphonesimulator`), Ninja, CMake, Python 3, Go, and Perl.
The SDK requirement differs from the app's deployment minimum, iOS **26.0**.
The script builds arm64 for both SDKs and fetches the Apple SSH and QUIC
dependencies.

```sh
./Scripts/build-ios.sh
# Or build one SDK:
./Scripts/build-ios.sh --sdk iphonesimulator
./Scripts/build-ios.sh --sdk iphoneos
```

Outputs are `$UBQ_BUILD_ROOT/ios-iphonesimulator/Ubiquitty.app` and
`$UBQ_BUILD_ROOT/ios-iphoneos/Ubiquitty.app`, with the corresponding Core
archives and link probe. Building a device app is not installing it: physical
devices require a development signing team and provisioning profile.
Use `./Scripts/generate-xcode-workspace.sh --ios-only`, open
`UbiquittyIOS.xcworkspace`, and select `UbiquittyIOSApp` in Xcode for
interactive deployment. The archive App Store Connect takes is described in the
[release guide](building-and-releasing.md#ios-archive).

See the [iOS build and simulator test commands](building-and-releasing.md#ios-app).
The app connects to a host; it does not run a local shell on the phone.

## Linux GTK4 and Vulkan

Build natively on Linux with the common C++ toolchain, `pkg-config`, and
development packages for **GTK 4.16 or newer, Vulkan, FreeType, Fontconfig, and
HarfBuzz**. Debian 13, Ubuntu 26.04 and Fedora carry them; Ubuntu 24.04's GTK
is 4.14.
Install **glslc** to compile the renderer's shaders, and a Vulkan driver
appropriate to the GPU; Mesa lavapipe provides a software driver. Without
glslc the configure stops, unless `UBIQUITTY_LINUX_GPU_SHADERS=OFF` asks for a
binary that renders on the CPU only.
Optional X11/XFixes or Wayland client/protocol/scanner packages enable their
respective pointer-lock backends.

```sh
./Libraries/ubiquitty-kit/Scripts/check-linux-build-prerequisites.sh
./Scripts/build-linux-gtk.sh
./Scripts/build-linux-gtk.sh Release
"$UBQ_BUILD_ROOT/linux/ubiquitty-linux"
```

The default build is Debug. Keep the generated shaders and bundled fonts beside
the executable in `$UBQ_BUILD_ROOT/linux`; copying the binary alone omits
renderer resources. The prerequisite script diagnoses the GTK/Vulkan baseline
and glslc; CMake checks the font libraries and reports optional backend
omissions, and the build script prints each warning the configure raised.
For distribution package names and AppImage packaging, see
[Linux in the release guide](building-and-releasing.md#linux).

The frontend runs local sessions only: it has no Sync client and does not
attach to a `ubiquitty-host` session.

When the Vulkan device offers external memory, the frontend hands GTK each
rendered frame as a dma-buf. Setting `UBIQUITTY_LINUX_NO_DMABUF` reads every
frame back into memory and uploads it instead, which isolates a driver or
compositor fault in the dma-buf path; the log's
`dma-buf presentation` line says which path runs. `UBIQUITTY_FONT` and
`UBIQUITTY_FONT_SIZE` override the configured font
([Fonts](guides/appearance-and-fonts.md#fonts)).

## Headless host and ubq

On macOS or Linux, use the common native toolchain; these targets do not need
AppKit, GTK, Metal, or Vulkan. The host build enables QUIC and needs Go, Perl,
and network access for its dependency build. The `ubq` build does not build
that QUIC dependency stack.

```sh
./Libraries/ubiquitty-core/Scripts/build-host.sh
./Libraries/ubiquitty-core/Scripts/build-agent.sh
```

Both default to Release; each accepts `--debug`. The executables are
`$UBQ_BUILD_ROOT/host/ubiquitty-host` and `$UBQ_BUILD_ROOT/agent/ubq`.
Building does not install or start a daemon. See
[host operation](https://github.com/ubiquitty/core/blob/main/Docs/host-management.md)
and the [CLI reference](https://github.com/ubiquitty/core/blob/main/Docs/ubq.md).

The Linux local-handover admission gate needs headers exposing `SO_PEERPIDFD`
and a kernel implementing it (Linux 6.5 or a backport). A build or kernel without
that facility refuses handover; ordinary host startup and attachment are
unchanged. The admission gate alone does not enable live daemon replacement.

`./Scripts/build-all.sh --headless` builds these two tools together.
Without `--headless`, `build-all.sh` also builds the macOS app: it is **not**
a build of every platform in this guide.

### Static Linux host binaries

A machine with a reachable Docker daemon can build the static-musl host
artifacts. Docker must support the selected architecture, natively or through
its configured emulation; the script builds dependencies inside its pinned
Linux container.

```sh
./Libraries/ubiquitty-core/Scripts/build-host-linux.sh          # x86_64 and arm64
./Libraries/ubiquitty-core/Scripts/build-host-linux.sh arm64    # one architecture
```

Outputs are `$UBQ_BUILD_ROOT/host-cross/ubiquitty-host-linux-x86_64` and
`ubiquitty-host-linux-arm64`. These are deployment assets for Linux hosts,
not a cross-build of the GTK frontend.

## Web and WebAssembly

Install Emscripten and activate its environment so `emcmake` and `emcc` are
on `PATH`, together with Ninja, CMake, and Python 3. Its bundled Clang must
meet the compiler floor above. Node.js runs the build's JavaScript boundary
and page smoke checks.

```sh
./Scripts/build-web.sh
# Build and serve the staged page over HTTP on port 8777:
./Scripts/build-web.sh --serve
```

The browser files, fonts, `ubiquitty.js`, and `ubiquitty.wasm` are staged in
`$UBQ_BUILD_ROOT/web-dist`; serve that directory rather than opening it with
`file://`. The build selects `UBIQUITTY_FRONTEND=Core`, disables native QUIC,
and builds the `ubiquitty-web` target. It does not require a native GUI SDK.

For the standalone Core's Wasm consumer under Node, run
`./Libraries/ubiquitty-core/Scripts/wasm-smoke.sh`; it builds in `$UBQ_BUILD_ROOT/wasm`.
These scripts report a skip when required tools are missing. A successful
shell exit after a skip is not evidence that the Wasm artifact was built.

## OpenBSD and NetBSD wscons

Build on OpenBSD or NetBSD with the common compiler tools, the OS wscons
headers, and `libutil`. No GUI toolkit, GPU library, or font-shaping library
is required.

```sh
cmake -S . -B "$UBQ_BUILD_ROOT/wscons" \
  -DUBIQUITTY_FRONTEND=Wscons -DUBIQUITTY_QUIC=OFF \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$UBQ_BUILD_ROOT/wscons" --target ubiquitty-wscons --parallel "$UBQ_BUILD_JOBS"
```

The executable is `$UBQ_BUILD_ROOT/wscons/ubiquitty-wscons`. CMake rejects
this frontend on other operating systems. Running it takes over a wsdisplay
console and reads a wskbd device; it needs access to those devices and is not
a desktop-terminal smoke test. Inspect
`Source/Platform/Wscons/main.cpp` for device arguments before running it.

No CI job builds or links this frontend. `Scripts/check-wscons-compiles.sh`
compiles its sources against stub wscons headers with `-fsyntax-only`, which
checks its calls into Core and nothing about whether it runs.

Three environment variables apply to it. `UBIQUITTY_WSCONS_THEME` names a
theme and wins over `[appearance] theme`. `UBIQUITTY_WSCONS_SCALE` is the whole
number of screen pixels per glyph pixel, 2 by default and at least 1, so a
larger value gives fewer, larger cells. `UBIQUITTY_WSCONS_DEBUG` prints each
key event, its encoded bytes, and each frame's render and blit time to standard
error.

## Emacs

Use Emacs 27.1+ and a host binary built from the same checkout. Build the host
as above; the editor client itself is Elisp, with no C++ module to compile.
Optional byte compilation from the repository root:

```sh
emacs --batch -L Source/Platform/Emacs -f batch-byte-compile \
  Source/Platform/Emacs/ubiquitty-sync-wire.el \
  Source/Platform/Emacs/ubiquitty-sync.el
```

Add `Source/Platform/Emacs` to `load-path`, require `ubiquitty-sync`, and
set `ubiquitty-sync-host-program` to the built host's absolute path if it is
not on `PATH`. Start with `M-x ubiquitty-sync`.
See the [Emacs setup and rendering reference](../Source/Platform/Emacs/README.md).

## Neovim

Use Neovim 0.10+ and a matching host binary. The Lua client needs no separate
compilation. Add it to the editor's runtime path and configure the host:

```lua
vim.opt.runtimepath:append("/path/to/ubiquitty/Source/Platform/Neovim")
require("ubiquitty_sync").setup({
    host_program = "/absolute/path/to/ubiquitty-host",
})
```

Run `:UbiquittySync`. Plugin-manager setup and key bindings are in the
[Neovim reference](../Source/Platform/Neovim/README.md).
Both editor clients use `ubiquitty-host --attach`; they do not connect
directly to the daemon's protected socket.

## libUbiquittyCore and UbiquittyKit

The native `Core` frontend builds static libraries and a consumer sample with
no GUI toolkit. Use the common native toolchain, Python 3, and Bash:

```sh
cmake -S . -B "$UBQ_BUILD_ROOT/core" \
  -DUBIQUITTY_FRONTEND=Core -DUBIQUITTY_QUIC=OFF \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$UBQ_BUILD_ROOT/core" \
  --target core-consumer ubiquitty-kit --parallel "$UBQ_BUILD_JOBS"
"$UBQ_BUILD_ROOT/core/core-consumer"
```

Link the CMake target `ubiquitty-core` or the session facade
`ubiquitty-kit`, not one archive in isolation; the targets carry the model,
behavior, and backend dependencies. See the
[Core embedding reference](https://github.com/ubiquitty/core/blob/main/Docs/libubiquittycore.md)
and [UbiquittyKit API](https://github.com/ubiquitty/kit/blob/main/Docs/ubiquittykit-api.md).

The separate `ubiquitty-snapshot` target is the portable render tool;
`./Libraries/ubiquitty-core/Scripts/build-core-snapshot.sh` builds it for the
[snapshot test catalog](https://github.com/ubiquitty/core/blob/main/Tests/Snapshots/README.md).
