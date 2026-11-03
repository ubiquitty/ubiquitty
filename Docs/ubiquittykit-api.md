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

A `TerminalSurface` presents into its own `metalLayer`, and the layer's
drawables are the surface's. A host reads `metalLayer` on the main actor and may
call `nextDrawable()` on the layer on any thread; Swift 6 sees no `Sendable`
layer, so a host hands it to a thread of its own in an `@unchecked Sendable`
wrapper. While output flows to a surface in a macOS window, the surface's
display link can take over delivering the drawables; while it does,
`nextDrawable()` on the layer returns nil rather than raising, on every thread.
The layer does not see a display link a host attaches to it, and the surface's
own frames raise under one, so a host attaches none. To draw a terminal into a
layer of its own, a host keeps the surface out of a window and calls the
renderer's `encodeFrame(for:into:)` with that layer.

A Swift `TerminalSurface` retains its renderer. A renderer assigned to several
surfaces can share glyph resources and remains alive until its last owner
releases it. Prefer the surface initializer that creates and installs a renderer;
use separate construction when sharing one renderer between surfaces.

A surface names the program its pane runs, so a host that draws its own tab
or pane chrome reads Core's answer instead of walking the process table:

| Property | Value |
| --- | --- |
| `foregroundProgramName` | The foreground process's own name, such as `claude` |
| `foregroundProgramKey` | The process catalog's key for the program, such as `claude-code`; nil when the catalog holds no entry |
| `foregroundProcessChain` | The chain a title shows, such as `vi ◂ claude` |
| `foregroundProcessChainWithArguments` | The same chain with each program's arguments |
| `foregroundProgramIcon` | The catalog's icon for the key, as a `TerminalSurface.ProgramIcon`; nil when the key is nil (macOS) |

Each is current whenever the observer's
`terminalSurfaceDidChangeProcessState(_:)` fires and is read on the main
thread, as the surface is. The callbacks of one delivery of what the session
reported (process state, tab status, title, screen update, exit and the rest)
read these and `programStatus` from one sample; a read outside them takes
the newest. The key is Core's resolution, the one a title's program icon uses:
the program an OSC 7501 status record names while a program holds the
terminal, then the foreground process. A status record can move the key
without a process moving; that arrives as
`terminalSurfaceDidChangeTabStatus(_:)`.

Who holds the terminal and the name come from one reading of the foreground,
and the name is the holder's: a job is named by the program that makes it
one, such as the `sleep` in `( sleep 30; true )`, and the shell's own work,
such as a prompt hook's subshell, by the shell. A job several programs make,
such as `( make ) | tee log`, is named by the one that has held it longest, so
the programs that come and go inside it do not rename it. A nested shell's
subshell or prompt hook is that shell's work, so it holds the terminal as a
program and is named by the nested shell. A reading is kept when the one after
it finds the same group, holder and name, and read again while they move, at
most three times: on this machine for a local session, and on the host for a
pane `ubiquitty-host` serves. A foreground still moving after that is kept as
last read until the next sample reads it again. On macOS a program is named by
its executable's file name, and one whose executable no longer reads, as one
that is exiting or whose file was deleted, by the name the kernel keeps for
it, cut at 16 bytes. On Linux, local or on a host, a program is named by the
name it was run by, so `vi` run through a link to `vim.basic` reads `vi` and
tmux, which renames itself `tmux: client`, reads `tmux`; one that is exiting
is named by the name the kernel keeps for it, cut at 15 bytes. A sample that
moves the name or the holder fires the process-state callback.

A local session reports this machine's process walk while the observer's
`terminalSurfaceNeedsProcessState(_:)` answers true. The surface asks when its
presentation moves and whenever an observer is assigned, so a host whose answer
changes assigns its observer again. The process-state callback fires while the
surface's window shows it, and also while that answer is true when no window
shows the surface. A surface that has never been in a window counts as shown.
A host that keeps background tabs' surfaces out of the window keeps hearing
them by answering true. With neither, the move is held until one holds again.

A pane that `ubiquitty-host` serves reports the host's own facts, so the
program running on the host is the one named, and who holds its terminal is
the host's own sample. Before the host has described the pane, the name and
chains are empty and the key is nil, even when the pane's screen already
carries a status record. Once the session has ended, here or on the host, the
name and chains are empty and the key is nil: nothing runs there.

The program's status sits beside its name. `programStatus` is a
`TerminalSurface.ProgramStatus`, current whenever
`terminalSurfaceDidChangeTabStatus(_:)` fires, which is never held for a
surface nobody sees. A pane that `ubiquitty-host` serves carries the status its
program posted on the host whether or not it is on screen:

| Field | Value |
| --- | --- |
| `kind` | `idle`, `running`, `working`, `done`, `attention`, `blocked` or `failed`; nil without a record |
| `blockKind` | What a blocked program waits for: `permission`, `question` or `authentication` |
| `progress` | A working program's percent, 0 through 100, when it reports one |
| `label` | The status in words, such as `codex: Waiting for input`; at most 48 bytes |
| `color` | The colour to draw it in, under the pane's theme |
| `colorSlot` | The theme status that colour stands for; nil for a colour the program chose itself |

The kind, label and colour come from the pane's primary OSC 7501 record. A
pane with no record carries the OSC 21337 tab status a program set, as a colour
and a label with no kind. The program a record names is
`foregroundProgramKey`, not a field here.

A host draws a program's icon from Core's catalog through the Kit, with no
catalog of its own. `TerminalSurface.ProgramIcon(key:)` looks a catalog key up
and answers nil for an empty key, for a key the catalog does not hold, and for
a framework without the icon's file. A program's name is not a key: Claude
Code runs as `claude`, its key is `claude-code`, and
`ProgramIcon(key: "claude")` is nil. `foregroundProgramIcon` is the lookup of
`foregroundProgramKey`. The icon is an AppKit value, on macOS only, where the
icons ship:

| Member | Value |
| --- | --- |
| `key` | The catalog key, such as `claude-code` |
| `title` | The program's name as its owner writes it, such as `Claude Code`, for a tooltip or an accessibility label |
| `renderingMode` | `template`: one colour, the ink of the text beside it; `original`: the icon's own colours |
| `image` | The icon in its file's colours, fitted in a square of `preferredSide`; a template icon's is marked `isTemplate`, so an image view, button or menu tints it |
| `preferredSide` | The side Ubiquitty's titles draw an icon at: 16 points, the size Safari draws a site's icon at in its tab |
| `needsPlate(on:)` | Whether a drawn icon needs a plate behind it on a ground: Core's decision from the icon's own colour, its contrast with the ground and whether the icon brings a tile of its own; false for a template icon |
| `image(side:ink:ground:)` | The icon as Ubiquitty's titles draw it: a template icon in the ink, a drawn icon in its colours on a squircle plate in the ink when `needsPlate(on:)` says so; nil for a side that is not positive |

The lookup and `image(side:ink:ground:)` run on the main thread. The icon is
`Sendable`: its members and `needsPlate(on:)` read on any thread and its
images draw on any thread, so a host may hand one to a background task or an
actor's cache and rasterise it there for a thumbnail. The icon's file is read
from the framework's own bundle, never the host's, and from the app's bundle
in the Ubiquitty app. The first lookup of a key reads its file, and the image
read is kept for the life of the process: at most one per catalog program,
whatever keys a host asks for. Every later lookup of the key reads nothing; a
lookup walks the catalog's few entries by key, and a key the catalog does not
hold reads no file. Each lookup returns images of its own that draw the kept
one, so a host may resize or tint one without touching another lookup's, and
may look an icon up on every process-state or tab status callback rather than
keep one.

### Theme colors

A host that paints its own chrome around a surface reads the terminal's colors
from the Kit rather than deriving them:

| API | Use |
| --- | --- |
| `TerminalSurface.colors(ofTheme:)` | A theme's colors, by name, without a surface; nil for a name Core does not know |
| `TerminalSurface.colors` | The colors a surface's grid draws now |
| `applyTheme(named:)` | Applies a theme by name; false, with nothing changed, for a name Core does not know |
| `TerminalSurfaceObserver.terminalSurface(_:didChangeColors:)` | The colors moved: a theme or palette was applied, or a program set or reset one with OSC 4, 10, 11, 12, 17 or 19, or 104, 110–112, 117 or 119 |

`TerminalColors` carries the default text color (`foreground`), `background`,
`cursor`, the sixteen `ansi` colors in palette order, and the
`selectionBackground` and `selectionForeground` a program set with OSC 17 and
19. A name is matched whole: one holding a NUL names no theme.

A theme's colors are the ones its apply draws: both are resolved under the
palette adaptation the process runs with. The Ubiquitty app sets that
adaptation from its color vision setting and the system's Increase Contrast.
The Kit sets none, so in another host a theme's colors are the ones the theme
names, and a host that follows Increase Contrast picks its themes for it.

A surface's colors are its theme's with a program's OSC overrides in place;
DECSCNM's whole-screen swap is drawn over them rather than written into them.
While a program holds a synchronized update (DEC 2026) open they stay the
colors of the frame from before it: a color the program sets inside the update
is not in them until the update ends, and one it puts back before then never
is.
No theme names a selection color, so a theme's selection colors are nil, and a
surface's are nil until a program sets one; while the background is nil the
grid fills a selection in the `[selection]` style.

Each color is a `TerminalColor`: the 8-bit channels Core holds, with the
opacity the grid draws text in it, rather than a platform color. The
`[appearance] color_space` setting reads the same channels as sRGB or as
Display P3 ([surface color space](wide-gamut.md)), and a theme read without a
surface has no space yet. `platformColor(usesDisplayP3:)` makes the color once
the host knows the space, which is the `SurfaceStyle.usesDisplayP3` its
renderer draws under.

The callback is raised on the main actor, at most once per apply or batch of
output however many colors it moved, and only when the colors differ from
those the previous call carried. A program re-asserting a color it already set
raises nothing, and neither does a batch that moves a color and puts it back.
On a local surface `applyTheme(at:)`, `applyTheme(named:)` and
`applyPalette(indexedRGB:defaultsRGB:indexedAlpha:)` report before they
return, so a handler that applies colors is called again from inside that
apply when it moves them; a remote surface reports when its host's palette
arrives. While a program holds a synchronized update open, the grid keeps the
frame from before it and the callback waits with it, until the update ends or
the terminal stops waiting on it. Each update that ends is a frame the grid
can draw, so a program writing updates back to back is heard at the first one
to end rather than when it stops writing, and an apply made while an update is
open is heard when it ends. The grid's own brief holds, such as its wait for
the redraw that follows a whole-screen erase, do not delay the callback, and a
surface nothing draws reports as a drawn one does, since a host's chrome around
a hidden pane still shows its colors. The callback has an empty default, so an
existing observer compiles unchanged.

### Clear commands

`clear(_:)` runs one of the clear commands the app's Edit menu offers, on the
main thread. What each command clears and what the program is sent are Core's:
the app's menu items, its key bindings and this call run the same command.
One method takes a `TerminalSurface.ClearCommand` rather than one method per
command, as Core's own dispatch does, so a host that binds gestures or builds
a menu passes the command through instead of restating the choice.

| Command | App item | Screen | Scrollback | Program is sent |
| --- | --- | --- | --- | --- |
| `.buffer` | Clear Buffer, Cmd-K | Blank, except the cursor's row up to the cursor, which rises to the top row | Emptied | Ctrl-L |
| `.scrollback` | Clear Scrollback, Opt-Cmd-K | Text stands; rows return to single width and height | Emptied | Nothing |
| `.screen` | Clear Screen | The prompt's first row scrolls to the top row | Gains the rows above the prompt | Nothing |

The prompt's first row is the row the shell marked with OSC 133 A; without
shell integration it is the cursor's row, and the cursor's row is what
`.buffer` keeps. Ctrl-L asks the shell to redraw a prompt its line editor
still places where the screen no longer shows it.

A command that removes or moves rows drops the selection, raising
`terminalSurfaceSelectionDidChange(_:)`, and returns the view to the live tail.
`.scrollback` does both under every program, whether or not there was history
to remove. A program that owns the screen's layout, by the alternate screen, a
scroll region or left and right margins, is sent Ctrl-L for `.buffer` and
`.screen` in place of the clear, and its screen, the selection and the view
stay for those two; `.scrollback` still empties the history, and leaves the
rows' width and height as the program drew them. A prompt already on the top
row leaves `.screen` nothing to do, and the selection stays. Except on a pane
attached to a host, `accessibilityValue()` reads the screen the command left as
soon as the call returns, with or without a selection and wherever the view
was.

The surface's own context menu offers Clear Scrollback and Reset Terminal, and
the surface answers both for itself, acting on the pane the menu opened over;
a host's responder chain needs nothing for them. On a pane attached to a host,
Clear Scrollback goes to the host as `clear(.scrollback)` does, and Reset
Terminal is disabled: the program's terminal is the host's, and a reset of the
pane's copy would leave the host's modes standing while the pane drew others.

A pane attached to a host sends the command to the host, which runs it on its
own copy and sends Ctrl-L to its program itself; the result arrives with the
host's next update. The surface drops its selection and returns to the live
tail when the request is sent. Before the attachment is established the call
does nothing, and a host refuses it from an attachment that may only watch.
On a tmux pane the command runs on the surface's copy, and Ctrl-L reaches the
program through tmux.

`Scripts/check-ubiquittykit.sh` runs all three, from the live tail and from a
view scrolled back, and the context menu's two items, from a consumer compiled
with `-F` alone, against a program of known output.

### Resizing in code

On macOS a host that moves or resizes panes in code, by setting frames
directly or by animating them, calls nothing beyond setting each surface's
frame. A surface takes a run of frame changes the way it takes the drag of a
split divider, without the live-resize calls AppKit sends during a drag:

- A lone frame change fits the grid to the new bounds and rewraps the
  scrollback at once.
- A frame change made within 80 ms of the one before it, as each step of an
  `NSAnimationContext` animation of the frame or of a host's own timer is,
  opens a run. Each step of the run fits the visible grid to its bounds and
  leaves the scrollback's rewrap for the end, and the pane keeps its previous
  frame while a full-screen program's repaint for the step is still arriving,
  as in a drag. While the window is on screen, the layer presents each step's
  frame in the same Core Animation transaction as its bounds change.
- Once the frame has held still for 80 ms the run settles: the grid is fitted
  to the final bounds, the scrollback is rewrapped once at the final width, and
  a frame of the settled grid is drawn. The settle moves no bounds, so that
  frame is presented as any other frame is, never in a Core Animation
  transaction, and it never holds the main thread until the GPU schedules it.

80 ms is longer than the gap between two steps of an animation, which AppKit
sets one display refresh apart, and short enough that the settle has happened
by the time a person reads the moved pane. Steps set further apart than that
are lone changes, each paid for at once. A window whose frame has no width or
height takes every change as a lone one.

The observer's `terminalSurface(_:didResizeGridTo:columns:)` fires once for
each change of the grid's rows or columns, whether a lone change, a step or a
settle made it. A settle that leaves the grid as the last step left it, which
is the usual case, fires nothing.

A host that resizes panes from the pointer, dragging a divider it draws
itself, brackets the drag with `beginLiveResize()` and `endLiveResize()`, as
AppKit brackets the drag of an `NSSplitView` divider or a window edge. It
calls `beginLiveResize()` on each surface the drag resizes when the drag
begins, sets their frames as the pointer moves, and calls `endLiveResize()` on
each when the pointer is released. A bracketed drag settles once, when it
ends, however long the pointer holds still on the way. Unbracketed, a pause of
more than 80 ms settles the run and the step after the pause resizes as a lone
change, so the scrollback is rewrapped twice for each pause. A bracket that
begins during a run takes the run over and settles it when it ends. A host
animating frames whose steps it cannot keep 80 ms apart, a timer of its own on
a busy main thread among them, brackets the animation the same way.

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
the framework's files, and a key outside the catalog draws and keeps none; a
program's icon looked up by catalog key draws in its own colours or in the ink
it is given, as the catalog says, with Core's plate decision, and handed to
another thread reads and draws there as on the main one; a surface reports a
family drawn under another of its names, a PostScript name and GNU Unifont as
configured, a missing family and a name that only begins the names of
CoreText's substitute by the substitute, and another family on the bitmap tier
as GNU Unifont; a frame draws in a shipped family; and a theme's colors are
read, applied by name and followed as programs move them.

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
- `Scripts/check-ubiquittykit.sh` builds `UbiquittyKit.framework` and runs a
  Swift consumer compiled with `-F` alone: it draws a frame, looks programs'
  icons up by catalog key, a drawn one with Core's plate decision and a
  template one in the ink it is given, hands them to another thread and reads
  and draws them there as on the main one, and finds none for a key the
  catalog does not hold; reads a theme's
  colors without a surface, applies the theme by name, and hears each OSC
  color write and reset, and a palette or theme it applies, move the colors
  through the observer, with nothing heard for a write that moves nothing or
  inside a synchronized update, whether the bytes are fed, the surface is
  hidden, or a program writes them to the surface's pseudo-terminal, among
  them a program writing updates back to back. A further consumer launches a
  shell in a surface taken out of its window, runs a program, and reads its
  name, catalog key, icon and chains; hears nothing while its observer declines
  process facts and the move once it asks again; reads the status a record
  posts and the colour a program sets; and reads nothing named once the shell
  exits.
