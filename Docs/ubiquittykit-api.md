<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# UbiquittyKit embedding API

`UbiquittyKit::Session` drives a terminal through a local PTY, a direct byte
carrier, or a synchronized host connection. The embedder supplies the terminal,
a dispatcher, and an observer. The session owns its transport-driving state.

Include `UbiquittyKit/UbiquittyKit.h` and link the `ubiquitty-kit` CMake target.
An installed-package consumer uses `Ubiquitty::ubiquitty-kit` from
`find_package(UbiquittyCore REQUIRED)`. The umbrella also exposes the model
surface and configuration API.

UbiquittyKit, UbiquittyRenderKit, the engine they link and the application
shells built on them are all [Apache-2.0](../LICENSES/Apache-2.0.txt); see
[licensing](licensing.md).

## Choose a factory

| Factory | Input | Behavior |
| --- | --- | --- |
| `Session::createLocal` | An owned `PAL::Stream` opened as a PTY | Feeds terminal bytes directly and owns the local carrier |
| `Session::createDirect` | An owned `Transport::Channel` and resize callback | Feeds terminal bytes without Sync framing, such as an ordinary SSH shell |
| `Session::createRemote` | A borrowed `Ubiquitty::Session::ChannelFactory` and session ID | Drives the host protocol and reconnects through the factory |

All factories also take a borrowed `Ubiquitty::Terminal&`,
`Ubiquitty::Session::Dispatcher&`, and `UbiquittyKit::Session::Observer&`.
The dispatcher is the session thread. Its `post` and `postDelayed` hand it a
`Ubiquitty::Session::PostedWork`, a move-only unit held without a heap
allocation; the dispatcher owns each unit from then on, and either runs it once
on that thread with `std::move(work)()` or destroys it unrun.
A remote session ID of zero requests a new host session;
a nonzero ID requests attachment to that session. `createDirect` takes
`std::function<void(int, int)>` for carrier geometry changes; an empty callback
is permitted for a carrier without resize support.

Use `origin()` for presentation of the byte source and `health()` for its
live connection state. Do not infer health from origin or duplicate session
behavior in the frontend.

## Lifecycle and input

`start(columns, rows)` begins a session with its initial geometry.
`setSize(columns, rows)` updates geometry. `stop()` closes a local carrier
or detaches a remote client; the remote host retains its session.
Start and stop are idempotent.

`sendInput(std::string_view)` copies the supplied bytes before returning.
It does nothing before the session is up. For input containing NUL, construct
the string view with an explicit length; a NUL-terminated constructor loses
the bytes after the first NUL.

A session is not copyable. Destroy it before destroying the terminal,
dispatcher, observer, or remote channel factory it borrows.

After a remote session reconnects, some typed input may be in doubt: a
connection carried it, and the host could not say whether it was written.
The session never sends it again on its own, because doing so can run a
command twice, and what is typed next waits behind it. `onInputInDoubt()`
reports the change. Show `inputInDoubtNotice()` beside the terminal without
blocking it, and call `resendInputInDoubt()` or `discardInputInDoubt()` only
when the person chooses.

## Threading

Every public session method, including `sendInput`, runs on the session's
dispatcher thread. Carrier I/O runs on its own thread; the session marshals
work to the dispatcher before touching the terminal or invoking its observer.

The dispatcher supplies:

```cpp
void post(std::function<void()> work);
void postDelayed(double seconds, std::function<void()> work);
```

Implement both using the embedder's event loop. Posting from an I/O thread must
schedule work on the session thread, not execute it inline on the posting
thread. Create and destroy sessions on the main thread that owns live
configuration.

## Observer

Subclass `Session::Observer` and override the callbacks the embedder needs:

| Callback | Purpose |
| --- | --- |
| `onFrame()` | Schedule a repaint or snapshot read |
| `onTitle(std::string_view)` | Update the displayed title |
| `onBell()` | Present the terminal bell |
| `onExit()` | Handle the session ending |
| `onHealthChanged(Health, const std::string&)` | Display connection health and its detail |
| `onConfiguration(const RenderConfiguration&)` | Apply resolved renderer configuration |
| `onInputInDoubt()` | Show or remove the notice for typed input in doubt |

Callbacks have default no-op implementations. Borrowed callback arguments are
valid only during the call; copy anything retained by the frontend.
`onExit()` is terminal: no further observer hooks follow.

Live configuration enters through `Preferences::configure`. Each session
updates its terminal state, delivers the resolved renderer configuration on
the session thread, and then emits a frame notification.

## Swift views

Swift uses C++ interoperability; see [the interop reference](swift-cxx-interop.md).
The public interface described here is C++. It does not define a separate C ABI.

A Swift `TerminalSurface` retains its renderer. A renderer assigned to several
surfaces can share glyph resources and remains alive until its last owner
releases it. Prefer the surface initializer that creates and installs a renderer;
use separate construction when sharing one renderer between surfaces.

## Versions and examples

`UbiquittyKit/Version.h` defines `kitVersionMajor`, `kitVersionMinor`,
`kitVersionPatch`, the packed `kitVersion`, and `kitVersionString`.
Use `UBIQUITTY_KIT_REQUIRE(major, minor, patch)` for a compile-time minimum.

The Kit version is independent of the model's `coreVersion` and the
application version. A breaking signature, layout, or threading change requires
a major version; a compatible method or defaulted observer hook requires a
minor version; a behavior-preserving fix without a surface change is a patch.

The supported surface is the umbrella's reachable header set. Internal module
headers are not a separate compatibility promise.

- [Model embedding](libubiquittycore.md) describes the terminal and PAL contract.
- `Samples/find-package-consumer` consumes the installed package.
- `Source/UbiquittyKit/Session.h` is the complete session declaration.
- `Tests/UbiquittyKit/test_kit_session.cpp` exercises the session facade.
