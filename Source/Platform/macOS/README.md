<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Ubiquitty macOS Frontend

A native macOS frontend for the portable Ubiquitty terminal engine. The app is a Swift AppKit terminal surface with a shared Swift Metal renderer. It spawns local PTYs, renders Core `Terminal` state through Metal, and also supports remote snapshot sessions and tmux render-only tabs.

## Build

```sh
./Scripts/build-macos.sh
```

See the [build guide](../../../Docs/building-and-releasing.md) for the Xcode,
Metal toolchain, compiler, and Go prerequisites.

## Run

```sh
UBQ_DOC_BUILD_ROOT="$(python3 Scripts/build_root.py .)"
open "$UBQ_DOC_BUILD_ROOT/macos/Source/Platform/macOS/Ubiquitty.app"
```

An NSWindow opens with a Metal-rendered terminal running the user's shell on a PTY. Keystrokes encode through the shared input/keymap layer and reach the PTY; PTY output flows into Core's VT parser and repaints the grid. Resizing recomputes cols/rows from renderer cell metrics, resizes Core `Terminal`, and issues `TIOCSWINSZ` so the child sees the same terminal size.

Boot trace lands in `Console.app` under the `Ubiquitty` process. Look for lines such as `spawned shell:` and `winsize:`.

## Architecture

- `UBAppDelegate` owns application startup, menus, configuration reload, and Objective-C application adapters.
- `App/Windowing/TerminalWindowController.swift` owns windows and projects the Core workspace into tabs and panes. `TerminalWindows.swift` routes app-wide actions to the selected window.
- `Source/UbiquittyKit/Swift/TerminalSurface.swift` implements native input, selection, accessibility, and presentation over `RuntimeDrive`.
- `Source/UbiquittyRenderKit/RuntimeDrive.swift` imports Core directly. `TerminalSession` owns the model lock, local ingest, remote Sync attachment, and hosted-pane routing.
- `Source/UbiquittyKit/Swift/SurfaceRenderer.swift` captures Core frame inputs under the session lock and drives the shared Swift Metal renderer in `Source/UbiquittyRenderKit/`.
- `Source/Core/Runtime/TmuxControlHost.*` owns tmux control connections. `TerminalWindowController+HostedWindows.swift` and `TerminalWindowController+TmuxHosting.swift` project hosted windows and panes without giving them independent PTYs.
- `Source/Platform/POSIX/PTYStream.cpp` implements local PTY streams. SSH and QUIC carry Sync sessions through Core's transport and remote-session modules.
- `App/` also holds Swift settings, consent prompts, and application tools. PAL implementations provide platform primitives; terminal behavior remains in portable Core.

The native snapshot command uses `SurfaceSnapshot` and the same `SurfaceRenderer` as interactive windows. Consecutive `--also-feed` / `--also-snapshot` pairs reuse that surface and its retained frame. `--profile-render` uses `SurfaceRenderProfile`; its `total`, `cpu`, `gpu` (commit-to-completion), and `gpuexec` lanes measure the Swift path. Compare profile lanes only when their measured boundaries and workload match.

## Layering

```text
TerminalWindowController / TerminalSurface (Swift, AppKit or UIKit)
        |
        v
RuntimeDrive (Swift, direct C++ interop)
        |
        v
TerminalSession / TerminalRuntime (portable C++23)
        +--> Terminal / VT parser / reflow / Sync / tmux
        +--> PAL (PTY streams, transport, clock, clipboard)

SurfaceRenderer --> Core frame capture --> Swift Metal encoding
```

Model and transport state belong to Core sessions. Frontend renderers own font and GPU resources and consume bounded captures; they do not parse terminal output or own the session's transport.
