<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# iPhone and iPad interface

The app requires iOS 26.0 or newer and builds with the iOS 27.1 SDK or newer; the
bar items' overflow priorities (27.0) and the Duo pane arrangement (27.1) are
reached through availability, and an older device lays the same items and the
same pair out without them.

## Conventions

Every screen follows the same rules, held in `InterfaceConventions.swift`:

- A sheet's buttons take their system roles in the system's placements:
  `Button(role: .cancel)` or `Button(role: .close)` in
  `.cancellationAction`, `Button(role: .confirm)` in `.confirmationAction`,
  and `.destructive` for an action that deletes or ends something. Cancel,
  Close and Done are role-only buttons (`Button(role:action:)`): iOS draws its
  glass glyph and supplies the accessibility label. A sheet that only shows
  something or applies each change as it is made has only Close. A verb that
  starts an operation (**Connect**, **Sign In**) and a refusal a request names
  (**Deny**) keep their word. A verb is disabled only when the form says why
  beside the field at fault. On iPhone Duo's folded display a sheet's bar stays
  horizontal (`toolbarVerticalBehavior(.disabled)`), so its Cancel or Close
  stays in the sheet rather than moving to the window's rail.
- Red with an exclamation mark is for what went wrong, green only for a live
  connection, and every other state is secondary text. The accent colour is
  for what can be tapped. A program's status is told by its symbol first —
  `xmark.octagon.fill` failed; waiting for you, `questionmark.bubble.fill` for
  an answer, `hand.raised.fill` for a permission and `key.fill` for a sign-in;
  `bell.badge.fill` a bell or notification nobody has seen; `circle.dotted`
  working, `play.circle.fill` running, `moon.zzz` idle — and its colour
  repeats it.
- One symbol per thing: `terminal` for a session or pane, `square.on.square`
  for tabs, `rectangle.split.2x1` and `rectangle.split.1x2` only for splitting,
  `macwindow` for a workspace.
- A feature that is unavailable replaces the screen's content with one
  explanation; it is never drawn over rows.
- Haptics follow the system setting: a selection tick for a pane switch, a
  modifier toggle, or a grabbed selection handle; success or error when a
  connection, a transfer, or a termination settles; the system's press
  haptic for an accessory key.
- Every icon-only control has a label and a hint for VoiceOver. Accessory keys
  grow with Dynamic Type, and the function tray drops to four columns at
  accessibility sizes. Increase Contrast gives floating cards an opaque ground,
  and Reduce Motion turns the switch notice's fade into a cut.

## iOS 26 and 27 patterns

Each screen uses the system's current component rather than drawing its own.
The app runs on iOS 26, so a component that arrived in iOS 27 is reached with
`if #available(iOS 27, *)`, with the nearest iOS 26 equivalent in the `else`
branch:

- Floating controls use `.buttonStyle(.glass)`, and the one primary action of
  a floating card or an empty state uses `.buttonStyle(.glassProminent)`. A
  custom floating surface uses `.glassEffect(_:in:)`, never a material
  background with a hand-drawn shadow or capsule. Neighbouring glass shapes
  share a `GlassEffectContainer`.
- Toolbar items are grouped with `ToolbarSpacer(.fixed)` so navigation and
  actions are separate glass groups, rather than with `Spacer()` in one group.
- Overflow belongs to the system: `toolbarOverflowMenu { }` holds what does
  not fit, not a hand-built ellipsis `Menu`. An item that must never collapse
  uses `.topBarPinnedTrailing`, and the order items collapse in is set with
  `visibilityPriority(_:)`.
- A bar minimizes on scroll only where nothing on it is the way out:
  `toolbarMinimizationBehavior(_:for:)`. A sheet's bar never minimizes
  (`.never`), because it holds the sheet's only Cancel and Close.
- A strip pinned under a bar is a `safeAreaBar(edge:)`, so content scrolls
  under it with the system's scroll edge effect, not a `safeAreaInset` with
  a painted `.bar` background.
- Alerts and confirmation dialogs are driven by their subject:
  `confirmationDialog(_:item:titleVisibility:actions:)`,
  `alert(_:item:actions:)`, and `alert(error:actions:message:)` for a failure,
  never a `Bool` binding derived from an optional.
- What a screen belongs to goes in `navigationSubtitle(_:)` under its title,
  not in a strip of its own.
- A sheet with unsaved edits asks before a swipe discards them:
  `dismissalConfirmationDialog(_:shouldPresent:actions:)`.
- Search is the system's toolbar search: `.searchable` with its default
  placement and `.searchToolbarBehavior(.minimize)` where the list is the
  screen's content, not a navigation bar drawer.
- On a wide layout a sheet that edits something beside the terminal takes
  `presentationPlacement(.trailing)`, and the toolbar item that opens it is
  its `matchedTransitionSource(id:in:)` with a `.zoom` navigation transition.
- Haptics on custom controls are the semantic ones: `.press(.button)` or
  `.press(.buttonIconOnly)` for a press, `.selection` for a choice, and
  `.success` or `.error` for an outcome; never `.impact` on a key cap.
- Bar glyphs are symbol names without `.circle`: every bar item already sits
  on a glass capsule.

## Navigation and input

The iOS app uses native SwiftUI navigation and system controls. One split view
serves every width: at compact width (an iPhone, a folded iPhone, a narrow iPad
window) it collapses so Hosts, Workspaces, and the terminal form a navigation
stack; at regular width (an unfolded iPhone, a large iPhone in landscape, an
iPad) the sidebar stays beside the terminal. The sidebar is a stack of its
own, Hosts then a host's Workspaces, so a workspace tapped there replaces the
terminal beside it without a push. Because the
container is the same at both widths, folding or unfolding the device, turning
it, or resizing the window keeps the terminal on screen with its keyboard,
open sheet, and pending permission request intact. Connections belong to the
session store and survive navigation.

On a phone the terminal has one bottom bar, laid out like Safari's: **Back**
to the workspaces on the leading side, **Tabs** in the centre, and
**Show Keyboard**, **Dictate**, and **More** on the trailing side. Tabs shows
the overlapping-squares icon with the current tab and total, such as **2/4**.
For a split tab, a second line shows the terminal icon with the current pane
and its total, such as **1/2**. Both follow the overview's ordering and update
as focus moves or tabs are reordered or closed. Tapping the button opens
the overview, where each card names its tab and shows its panes. Swiping across
the terminal moves between panes and tabs. A floating progress capsule shows connection progress
and offers Cancel, or Retry Now during reconnection, without resizing the grid.
On iPhone Duo folded the system stands the bar on its side as a trailing rail:
Back, the keyboard, Dictate and More, with **Show All Tabs** heading the More menu.

**More** groups the rest: Paste, Copy, Select All, and Find in Scrollback; Files; New Tab,
Split Right, and Split Down; Terminal Keys; Settings and
Connection Details. In a wide window — an iPad, an unfolded iPhone Duo — the
navigation bar shows instead, with the title, the host and tab position as its
subtitle, a title menu, and **New Tab**, **Split**, the keyboard, **Dictate**, and **More**
at the trailing edge. There is no bottom bar there, and the host sidebar keeps
the system's appearance whatever the terminal's colours are.

A long press selects the word under the finger and offers the edit menu as the
finger lifts: Copy, Paste, Select All, Look Up, Share, and Open Link over a
link or a selected URL. A tap opens a link a program marks as clickable, but
never an `ssh`, `sftp`, `ftp` or `ftps` link, which connects to a host the
program named: Open Link is how one opens, or a **⌘**-click with a keyboard
and pointer. A double-tap selects a word and a third tap the line.
Handles at both ends of the selection move either end. A tap beside the
selection puts it away. Scrolled back, the view shows a scroll indicator and a
**Jump to Bottom** button that counts the lines that arrived below; new output
never moves a view held in the scrollback.

A failed connection shows its cause in one line under the status bar — "build
refused the connection on port 22." — with **Try Again** and **Details**, and
can be dismissed. In landscape on a phone the bar steps aside for the grid and
leaves a grabber at the bottom edge; tapping it or the grid brings the bar back.

### Terminal keys

On iPhone, the software keyboard carries one row of key caps (at most 44 pt
tall). The caps follow the keyboard's own ten-key grid, so they line up with
the letters below. The row holds these keys:

- **Leading edge:** esc, tab, ctrl and alt. These stay put.
- **Middle:** the symbols a shell uses that iOS keeps behind 123 and #+=.
  They begin with `~ / | -`, followed by `` _ \ ` > < * $ & ; = ' " [ ] { } ``.
  The middle scrolls sideways.
- **Trailing edge:** the arrow pad and fn, plus Dictate and Hide Keyboard where
  the keyboard covers the bottom bar.

fn turns the middle into a second page of the same row: Shift, F1–F12, home,
end, page up, page down, insert and delete.

Modifiers work in three ways:

- Tap once: the modifier applies to the next key, and its cap fills with the
  accent color.
- Tap twice: the modifier locks, and its cap gains a bar, as Caps Lock does.
  A third tap turns it off.
- Hold: the modifier applies to keys pressed with another finger. Holding
  ctrl also offers ^C ^D ^Z ^R ^L ^A ^E ^W. Slide to one and release to send
  it in one gesture.

Tap a quadrant of the arrow pad for one arrow. Press and drag to use the pad
as a trackpad nub: the drag locks to the axis it moves along first, and each
step of travel from where the finger came down sends one arrow that way with a
selection click. Dragging back sends the opposite arrow, one step at a time,
and holding still sends nothing. A step is 14 pt in a compact width and 18 pt
in a regular one; a touch that stays within 10 pt of where it came down is a
tap. With VoiceOver, swipe up or down on an arrow to send one arrow of its axis
per swipe.

Every press gives the system's press haptic. Characters pop up above the finger, as on
the system keyboard. The system silences the haptic when System Haptics is
off. iOS has no API that exposes the keyboard's own haptic setting.

VoiceOver reads each key by name ("Escape", "Control, next key", "Control,
locked"). The Control chords are VoiceOver actions on ctrl. The row grows
with Dynamic Type up to the first accessibility size. Beyond that, a long
press shows the large content viewer.

On iPhone Duo's outer display, the bar is a rail on the trailing edge. The row
ends before the rail, and the rail's keyboard button replaces Hide Keyboard.
In landscape and on the inner display the same row shows more of the middle at
once.

On iPad these keys go in the keyboard's shortcuts bar, where Pages and Numbers
put theirs:

- **Leading groups:** esc and tab; ctrl, alt and shift; the arrows.
- **Trailing groups:** `~ / | - _`, a menu of the other symbols, and an fn
  menu.

A modifier shows its state on its item: selected when it applies to the next
key, and underlined as well when locked.

With a hardware keyboard attached, the iPhone row leaves with the software
keyboard. On iPad the system shrinks the shortcuts bar to its floating form.

`TerminalAccessoryKey` is the only table of these keys, and both
presentations read from it. A press names either a key or a character, never
bytes. Core encodes it with the pending modifiers and the terminal's modes.
Core is also the encoder for the macOS and web keyboards, so ^C from the row
is the ^C a Mac sends, Kitty keyboard mode included.

Text composition and hardware-keyboard input keep their own paths. Hardware
Command-V pastes, Command-C copies the selection, and Command-A selects all.
Control-C remains a terminal key, not a copy command.

### Dictation

Dictation is on-device, with a live preview. The microphone beside the keyboard
button opens it listening with one tap. While typing on a phone, a microphone
in the terminal key row hides the software keyboard and opens dictation. Both
microphone buttons have a minimum 44-point tap target. Only finalized speech
enters the terminal; revisable words stay in the preview. The bar's Send puts
the Return after the last spoken phrase — it
finishes recognition first, so the line that goes is the whole of what was
said — and sends a plain Return when nothing is being dictated. Interrupted
speech can be inserted or discarded explicitly, and switching panes clears it. A microphone permission refusal links to system Settings. Escape,
Tab, Control-C/D/L, and arrow keys remain in **Terminal Keys** in the overflow
menu. Paste uses Core's
normalization, bracketed-paste protection, and configured multiline confirmation.

## Hosts

Hosts lists **Open Connections**, then **Saved Hosts**. A host that is
connected discloses what it holds beneath its row: its workspaces, and within
each its tabs and panes. Each row gives the title its first line and the
program's status text its second when present, with shallow indentation to
leave room for names on a phone. The machine named by the host row is omitted
from its child titles; a pane on another machine keeps that machine's name.
The rows are the host's own outline, the one the workspaces screen
and the Mac's Connect window draw, followed live while the connection is up
and the list is on screen. Returning to Hosts keeps the latest received rows
and their expanded state while the watch refreshes them. A disconnected host
shows no rows.

Tapping a row opens it: the terminal attaches to that workspace and shows
that tab and pane, without stopping on the workspaces screen. On iPhone every
row under a workspace shares one indent, so titles keep the width; where
there is more room, panes nest under their tabs. VoiceOver reads each row as
one element — what it is, its title and status, the workspace it is in and
the host it is on — with **Open**, and **Expand** or **Collapse** where it
folds. The search in the toolbar filters these rows too: a host the search
names keeps every row, and any other connected host keeps the rows that match.

## Workspaces

Opening a host that names no workspace shows its workspaces. The large title
is the host's name, and the subtitle says whether this device is connected
and how many workspaces the host holds ("Connected · 4 workspaces"), when it
last answered, or "Not connected". The toolbar has **New Workspace**, which
asks for a name and suggests one the host doesn't hold, and **Sort By**:
Recent, Name, or Needs Attention.

**Needs You** comes first: each pane whose program asks a question, waits
for permission, or failed, with what it says and where it is. **Respond…**
answers a permission request on this connection in its sheet; otherwise it,
and **Open**, go to the pane. **Workspaces** follow, then **Saved** for
workspaces nothing runs in, which opening restores.

A workspace row has two lines at most: a status symbol and the name, then
its tab count, who is attached, and how long ago anything happened. Each
status has its own symbol as well as its colour, so states read in
grayscale: running, working (with its progress), waiting for you, failed,
done, and idle. A workspace nobody named is called by a label or name a
person put on what it has in front, else by the last component of its
pane's directory, the rule Core applies on every platform. Expanding a
workspace lists its tabs on one line each, cut in the middle so the end of a
path stays visible; on a wide screen panes nest under their tabs.

Swiping right opens a workspace; swiping left offers **Terminate** and
**Rename**. Terminate asks first, pointing at the row and naming what runs
there. Touching and holding a row previews its details and tabs, with Open,
Open in New Window where the device shows several windows, Rename…, Copy
Name, and Terminate…. Pull down to ask the host again.

The list is the host's answer and is asked for each time it appears. An
answer read before this device connected doesn't describe the workspace the
connection started, so it is shown as being asked again rather than as the
host's word. "No Workspaces" appears only when the host answered with none,
and "Couldn’t Ask the Host", with **Try Again**, when it didn't answer.

## Touch gestures

On the grid, one finger scrolls vertically and swipes sideways through every
pane in the workspace: left for the next pane, right for the previous,
wrapping at either end. Panes follow window and tab order, then the split
tree's left/top-to-right/bottom order within each tab. A pan settles
on one axis once it has travelled about 12 points, so a scroll never becomes a
pane switch partway through, and a sideways swipe sends the program no
horizontal scroll. It switches when it has crossed a third of the pane (at
least 80 points) or is flicked decisively. Two fingers tap for Settings and
swipe sideways for the app's open connections, in host-list order, wrapping;
a pinch zooms, told apart from the two-finger swipe because it changes the
distance between the fingers rather than moving them together. Each switch
names where it landed in a brief notice at the top of the grid — the tab and
pane, or the host and its workspace — and says so when there is only one pane or
one connection. Leaving a terminal is the bar's **Back** button or the system's
edge swipe.

## Tabs and panes

**Settings → Session Titles** chooses the components of automatic titles in
workspace lists and tabs: the folder (name or path), program title, active
process and its arguments, shell command, program status, and dimensions.
Turn off **Folder** to omit the leading working directory. Changes apply to
open lists and tabs immediately and survive relaunching the app. Custom
workspace and tab names keep precedence. Pane titles inherit the tab's
composition unless the configuration gives them an explicit override.

**Tabs**, or **Show All Tabs** in the wide title menu, opens the tab overview over the whole screen, as Safari's
does; Command-Shift-Backslash opens it from a hardware keyboard. Each tab is a
card: its split layout in miniature, every pane a live picture of the frame
it shows, drawn by the pane's own renderer into an offscreen target and
scaled down, so no card holds a Metal layer. Core names each tab and pane by
the rule the macOS tab strip uses (`App::composeTitle`) over the facts the
host sends for each pane: its program's title, its working directory and its
process. A name a person gave the tab wins. The focused tab's card and the
focused pane have an accent outline. VoiceOver reads a card as its place,
name, pane count and focus ("Tab 2 of 3, vim notes.md, 2 panes, focused"),
with Close Tab, Rename Tab, available Move Tab Earlier/Later actions, and one
Show action per pane. Directional move commands are accessibility actions;
touch reordering uses drag and drop on both iOS 26 and iOS 27.

A tap on a pane focuses it and closes the overview. A card's ✕ closes the
tab; closing a tab or a pane asks first with Core's question, which names the
programs the host reports running there. A card's context menu offers
Rename Tab…, New Tab, Split Right, Split Down, and Close Tab; a pane's, among
several, adds Zoom Pane, Move to New Tab, and Close Pane. Dragging a card onto
another moves the tab to that place through the host's tab-order call, which
needs the host's workspace listing. The title carries the tab count, and the bottom toolbar holds New Tab and
the system close button. Creating a tab opens its terminal once the host confirms
the new pane. Creating a split keeps the overview open and focuses the new pane;
Reduce Motion replaces the insertion with a cross-fade. Every change is a host request, refused while
reconnecting; a pending request shows progress on its card, and a refusal is
drawn on the card it was about. A connection with no workspace shows
**Tabs Unavailable** in place of the cards.

A regular-width window also shows a tab strip under the top edge: tap a tab
to switch, drag to reorder, and use its ✕ or context menu to close or rename
it. Command-1 to Command-8 select a tab, Command-9 the last, and
Command-Shift-[ and Command-Shift-] step through them. A compact window displays the focused pane alone. A
regular-width window — the inner display of iPhone Duo, an iPad — shows the
focused pane and one more, in a system `ArrangementView`: side by side when the
space is wider than tall, one above the other when taller, and each moved clear
of the fold when iPhone Duo is partially folded. Focusing a pane already on
screen moves nothing; choosing one that is not replaces the pane without focus,
so the pane in use stays put. An accent border marks the focused pane, and
tapping the other pane focuses it. **Show Two Panes When Wide** in the overflow
menu turns this off. Pane attachments
share the workspace connection; layout and process lifetime remain host-owned.
Closing a pane requires confirmation because it ends the running process.

## Find in scrollback

**More → Find in Scrollback…**, or Command-F on a hardware keyboard, puts a
find bar above the keyboard and the bottom bar. Typing searches the focused
pane's scrollback as the query changes, verbatim and ignoring case. The bar
shows Core's counter ("3 of 12", "No matches"), and Previous Match and Next
Match step through the matches, wrapping at either end; Command-G and
Command-Shift-G do the same, and Return goes to the next. The search is
Core's, the same one the macOS and Linux find bars run: matches are
highlighted in the grid by the renderer's capture of the model, never by a
second scan here, and the active match is scrolled into view by Core's
placement rule. Switching panes searches the new pane and clears the old
one. The close button or Escape takes the bar down and leaves the active match
selected, so it can be copied. At accessibility text sizes the field takes
a row of its own.

## File transfer

**Files** uses the system document picker to send a file and the system export
sheet to save a received file. Sending uses the host's bounded paste-file
channel: the host saves the payload and inserts its path into the terminal.
Receiving asks for an absolute path; the host enforces its session-directory
boundary. The interface reports failures and only offers Save after a successful
reply. Ordinary SSH shell connections explain that host file transfer and
workspace management are unavailable.

## Permission requests

**Permission Request** presents the verified process separately from the agent's
claimed name. The available grant durations follow Core's request policy.
Unknown actions or capabilities are denied. The sheet is answered only by its
buttons: it cannot be swiped away, and a layout change that rebuilds the
screen presents it again rather than answering it. A request left unanswered
is denied by the host at its deadline. A request interrupts a
terminal tool sheet so approval is not hidden behind settings.

Workspace tree requests approve or deny one exact operation. They do not offer
a standing grant. Each response belongs to the live question shown: resolving,
expiring, replacing, or disconnecting that question invalidates its sheet, and
a stale response must not answer a successor question.

## Signing in

The app never asks for a credential the server didn't ask for. Each SSH
connection first asks the server to accept it with no credential (the SSH
`none` method). A server that authenticates by identity, such as a Tailscale
SSH node, accepts it, and nothing is asked. Otherwise the server lists the
methods it accepts. The saved key is offered only if the list includes
`publickey`, and a password only if it includes `password`. The saved password
is used when there is one; otherwise a sheet asks once, with any message the
server sent, and every connection of that attempt reuses the answer. The answer
isn't saved.

Messages the server sends while signing in go to the connection log. A message
with a link, such as Tailscale's request to approve a sign-in, opens a sheet
with the server's text and **Open Link**. The connection stays open until the
server answers, and the bootstrap deadline is held while the app waits on the
person. A server that closes the connection during sign-in, as sshd does after
too many failed attempts, is reported as a sign-in failure, not a network
failure.

The host editor's **Sign In With** menu has three choices. **Saved Password**
offers the password saved in the keychain when the server lists `password`.
**Ask for Password** saves nothing and asks each time the server wants one.
**SSH Key** offers the saved key when the server lists `publickey`, and asks for
a password only if the server refuses the key and lists `password`, as OpenSSH's
client does. A key is pasted, imported from Files, or generated on the device
(ECDSA P-256), and its public key can be copied or shared to the host's
`authorized_keys`. Ed25519 and ECDSA keys are read in OpenSSH, PKCS#8 and SEC1
containers; a key under a passphrase, and RSA, DSA and hardware security keys,
are refused with the reason. Saved hosts use these three explicit sign-in
choices; unknown methods are refused. The SSH library has no keyboard-interactive method, so a server that accepts only that method is
reported as accepting nothing this host can offer.

Fields are judged when they are left or when **Save** is tapped, never before,
and an error sits under the field it belongs to. Pasting `user@host:port` into
**Address** fills the user name and port too, read by Core's address parse.
The number pad has a trailing **Done** button that dismisses the keyboard;
only the sheet's confirmation button saves the host.
**Use Workspaces**, the QUIC preference, is on for a new host; a saved host
keeps the setting it had.

## Settings and connection recovery

**Save remote history** in Settings is off by default. For pinned, saved QUIC
workspaces it retains bounded history with the encrypted resume picture and
restores it before connecting. The key and exact host, credential, workspace,
and client identity are protected by the device keychain. Changing the setting
retires saved caches and disconnects protected sessions; reconnect to continue.
A failed retirement leaves the setting unchanged and reports a storage error.
Host history clears retire the old key before a new epoch is displayed. Cached
content never grants permission to send input or replays unsent text.

**Settings** opens from Hosts without a connection, from More, or with a
two-finger tap. It holds app-wide appearance, text, cursor, terminal, history,
and notification preferences and opens at full height. Theme choices show
palette previews, with separate light and dark choices when matching the system.
Saved host themes override the app defaults; their picker is in Connection
Details, beside workspace identity, transport, attendance, program status,
host key, and the connection log. The system font picker includes
monospaced faces, with a live preview, size and line-spacing controls, and reset.
Line Spacing in the Font section adds space to each line's natural height.
**Settings → Padding** sets the space between the text and the pane's edges:
All Edges at once, or Top, Bottom, Left and Right alone, and Reset to Default.
The default is Core's iOS default of 4 points on every edge, measured inside
the safe area. Open panes re-lay out their grids as the value changes, and the
value persists in the same configuration document as every other setting. Fallback ranges
can be added, edited, and removed, with any installed font and a per-range size
matching choice. Invalid ranges leave the configuration unchanged. Font choices
apply live to every open connection and persist as defaults for new
connections on the device; pinch zoom remains per pane. Pinching changes the
font and terminal grid at display refreshes, reflowing visible text during the
gesture and settling deferred history when it ends. Font changes retain the
Metal pipeline states. Saved hosts show unheard bells
and program status. Background event delivery does not require a rendered frame.
Returning from suspension reattaches QUIC with a fresh one-time bootstrap while
retaining workspace identity. Network monitoring observes both active routes and
reachability, so connectivity returning on the same interface retimes recovery.
The initial bootstrap has a 30-second deadline, held while the sign-in waits
on the person, and concurrent listing and attach
requests share that initial ask. Failed asks can be retried. Its authenticated
SSH host key pins subsequent
bootstrap connections and appears in Connection Details. Callbacks from a closed SSH
carrier cannot update or feed a replacement session.

The interface follows Apple's [split-view guidance](https://developer.apple.com/design/human-interface-guidelines/split-views)
and [toolbar guidance](https://developer.apple.com/design/human-interface-guidelines/toolbars).
System components provide platform materials, accessibility semantics, Dynamic
Type for interface text, and standard document-provider integration.

Sessions created by the app outlive the client while their host and process
remain running. Explicit termination ends the session; processes may also exit
normally. Leaving the terminal view is not a termination request.

## Background catch-up

Enable **Check While Away** under **Notifications** in a saved
host's settings after connecting once
to pin its SSH host key. Refresh connects directly to that machine over SSH;
there is no relay or push service. It reads retained notifications, unresolved
program questions, and current pane status. An optional bounded screen preview
is cached as text without creating a terminal view or GPU renderer. The cached
host view shows when its information was last fetched.

iOS chooses when a `BGAppRefreshTask` runs. The app requests an opportunity no
earlier than 15 minutes later, but this is not a polling interval or a delivery
guarantee. Background App Refresh settings, device use, power policy, and force
quitting can prevent execution. Incoming Sync traffic cannot wake a suspended
app. Opening the app runs the same catch-up immediately. The host must be awake,
reachable, and already running a compatible daemon; background work never
installs, promotes, or starts a host binary.

The opt-in explicitly authorizes a separate saved SSH credential usable while
the phone is locked after its first unlock following restart. It is scoped to
the saved host, port, username, authentication type, and pinned host key. The
interactive credential retains its existing protection. Prompt-only logins
cannot enable unattended refresh. Disabling refresh or deleting the host
removes its background credential and cached data; removal or settings-write
failures stop refresh and require a retry. Renewed credentials or endpoint/trust
changes create a distinct permission, retire old cached data, and remove only
the old permission's notifications. This uses the SSH account's
existing authority; it is not a separately restricted SSH account. The refresh
operation itself only reads state and never binds a pane, sends input, resizes
the terminal, takes focus, or becomes the primary notification client.

The host retains up to 256 admitted notification/question events for seven days.
Events, cursor, and pending notification delivery are persisted together on the
phone; interrupted delivery reuses stable notification identifiers. A named OSC
99 notification replaces an earlier notification with the same name in that
pane. Resolved, superseded, and deleted-pane questions are suppressed before
presentation. Notification timing preferences still use Core's current audience
policy, and notification permission is requested only after opting in.

Questions require a program to report an OSC 7501 blocked state with question,
permission, or authentication kind. Ordinary terminal text and a colored busy
indicator do not identify a question. The cached screen is a preview, not an
archive: image data and bulk scrollback are excluded, and oversized or unfinished
synchronized redraws are skipped. Each refresh has a 20-second deadline and
bounded pages; later visits resume committed progress.

## Contract validation

From the repository root:

```sh
Scripts/build-ios.sh --sdk iphonesimulator --ui-tests
Scripts/run-ios-smokes.sh
Scripts/run-ios-ui-tests.sh
```

Choose an installed simulator with `UBQ_IOS_DEVICE_TYPE` when testing a specific
device shape. Width-class checks require a device that reaches regular width;
folding and vertical toolbar checks require the corresponding device and poses.
A skipped geometry case is not validation of that geometry.

Offline checks cover tool presentation, navigation, keyboard focus, gestures,
screen replacement, pane arrangement, and request identity. Live workspace,
file-transfer, and consent round trips additionally require a reachable host;
offline UI checks do not establish those network contracts.

The `--smoke-background-refresh` app launch checks separate Keychain protection,
credential scope, protected cache writes, and exactly-once task completion under
expiry and cancellation. Simulator execution does not establish real-device
background scheduling frequency.

## Keyboard preferences and file actions

Settings → Keyboard controls whether a hardware keyboard’s Option key sends
Meta. Accessory Keys edits the order and visibility of symbols on both iPhone
and iPad. Escape, Tab, modifiers, arrows, and function keys remain available;
Reset to Default removes the custom order. The corresponding configuration is
`[keys] option_as_alt` and `accessory_symbols`, an ordered subset of the default
symbol row. An empty string hides the optional symbols.

The iPad File menu offers New Tab (Command-T), Split Right (Command-D), Split
Down (Command-Shift-D), Close Pane (Command-W), and Close Tab (Command-Shift-W).
Close confirms the exact panes shown in the question even if focus changes.

Files accepts a single file dropped from Files and offers Quick Look, Share,
and Save to Files for a received file. Preview copies are protected temporary
files removed when the sheet releases them. Receiving still uses a full path
inside the host session’s permitted directory.

Permission requests identify the host and session, put Allow Once and Deny
together, and disclose the effect of session or permanent grants separately.
Permanent permission requires confirming that matching requests may be approved
automatically after this connection ends.
