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

Swift code built inside this repository reaches the C++ facade above through
C++ interoperability; see [the interop reference](swift-cxx-interop.md). The
facade defines no separate C ABI.

A Swift `TerminalSurface` retains its renderer. A renderer assigned to several
surfaces can share glyph resources and remains alive until its last owner
releases it. Prefer the surface initializer that creates and installs a renderer;
use separate construction when sharing one renderer between surfaces.

## Swift framework

`UbiquittyKit.framework` packages the Swift views for an app built outside
this repository. Compile against it with `-F` alone: its module interface
names only Swift and Apple types, and its public members are the framework's
interface.

A surface's `resolvedFontFamily` names the family its regular text is drawn
in. It is the configured family, spelled as configured, when that family is
drawn: a family the framework ships, GNU Unifont, which the framework draws
itself, or a family CoreText finds under any of its family, full or PostScript
names. A family that is not found is drawn in a substitute, and
`resolvedFontFamily` is CoreText's name for the substitute's family. A
`SurfaceTypography` whose `unifontScale` puts another family on the
framework's bitmap face draws GNU Unifont, and `resolvedFontFamily` is GNU
Unifont. It therefore differs from the configured family exactly when a
substitute is drawn.

`TerminalSurface.preferredFontFamily()` names the family Ubiquitty's own
windows draw in when the configuration names none: the first of Ubiquitty's
preferred families, in Core's order, that CoreText resolves by name, asked
after the framework registers its shipped fonts for the process. The surface
initializer and `makeRenderer(fontFamily:)` draw in Menlo when given no
family; pass `preferredFontFamily()` to draw in the family Ubiquitty's windows
default to.

Embed the framework in the app's `Contents/Frameworks` and sign the app. The
framework has the versioned layout codesign seals: its binary, `Resources`,
and `Modules` are in `Versions/A`, and its root holds only links into
`Versions/Current`.

The framework carries the files its code reads and reads them from its own
bundle, never from the app's: the Metal shaders, the shipped fonts with their
licenses, the icons that titles and tags draw, and the notices for everything
it links. A shipped family is drawn from the framework's own file, opened by
its path, whatever copy of it the system has. The framework registers the
shipped fonts for the process before anything in it resolves a family by name:
choosing the preferred family, the first surface, and the first renderer each
register them when they come first, and from then on the process's own font
lookups find the shipped families too. A configuration, a fallback list, or a
settings list can name a shipped family, and a window spawned first draws in
the family every later window draws in. The app copies and registers no font.

`Scripts/check-ubiquittykit.sh` checks the bundle's layout, its `Info.plist`
and the Kit version in it, each font's license, and that its fonts and icons
are the tree's files and no others, then embeds the framework in a minimal
app, signs the app ad hoc, verifies the signature strictly, and runs the
signed app once per step, each step the process's first call into the
framework: choosing the preferred family answers the first one the framework
ships or the system has, and registers the shipped fonts, as building a
renderer does; a lookup by name finds the shipped families the system has no
copy of, which only a lookup after the registration does; every style of a
shipped family and the symbol font are opened from the framework's files with
same-named decoys registered; the Phosphor and program icons are drawn from
the framework's files; a surface reports a family drawn under another of its
names, a PostScript name and GNU Unifont as configured, a missing family and a
name that only begins the names of CoreText's substitute by the substitute,
and another family on the bitmap tier as GNU Unifont; and a frame draws in a
shipped family.

## Versions and examples

`UbiquittyKit/Version.h` defines `kitVersionMajor`, `kitVersionMinor`,
`kitVersionPatch`, the packed `kitVersion`, and `kitVersionString`.
Use `UBIQUITTY_KIT_REQUIRE(major, minor, patch)` for a compile-time minimum.
The Swift framework carries `kitVersionString` as its bundle's
`CFBundleShortVersionString` and `CFBundleVersion`; a host reads it from
`Bundle(for: TerminalSurface.self)`.

The Kit version is independent of the model's `coreVersion` and the
application version, and it versions both the C++ facade and the framework's
Swift interface. A breaking signature, layout, or threading change requires a
major version; a compatible method, property, type, or defaulted observer hook
requires a minor version; a behavior-preserving fix without a surface change
is a patch.

The supported C++ surface is the umbrella's reachable header set, and the
supported Swift surface is the framework's module interface. Internal module
headers are not a separate compatibility promise.

- [Model embedding](libubiquittycore.md) describes the terminal and PAL contract.
- `Samples/find-package-consumer` consumes the installed package.
- `Source/UbiquittyKit/Session.h` is the complete session declaration.
- `Tests/UbiquittyKit/test_kit_session.cpp` exercises the session facade.
