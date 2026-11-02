<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Remote Sessions & AI Agents

**ubiquitty-host** keeps terminal sessions running independently of the app,
locally or on a remote machine. The host owns the shell, terminal state, and
retained history. Graphical clients render that state; agents can read it and
send input when authorized.

## Connect over SSH

**File ▸ Connect…** (⌘⇧K) opens the unified Connect + Sessions window; choose **Ubiquitty
Host** in the sidebar. It opens a window that is a *thin client*: the terminal Core runs
on the remote host (under `ubiquitty-host`), and your local window only renders the synced
grid and sends your keystrokes. The title bar shows a status pill (connecting / connected,
and whether it's over the QUIC data plane or the SSH fallback).

Connect signs in through OpenSSH, so authentication follows your `~/.ssh/config`
and agent. OpenSSH asks the server what it accepts before offering anything: a
Tailscale SSH host that accepts the tailnet identity signs in with no password,
and in an SSH shell a Tailscale check's approval link appears in the terminal. The iOS app
negotiates the same way with its own SSH client; see
[the iOS interface](../ios-interface.md#signing-in).

The session survives a dropped connection while the host and shell remain
running. Reconnect resumes from retained state or receives a fresh checkpoint.
This does not preserve a running process across a server reboot. The SSH carrier
sends a liveness probe every 15 seconds and closes after three unanswered probes, allowing the
client to reconnect after a network drop instead of waiting for TCP to time out.

### When signing in fails

Connect runs OpenSSH with `BatchMode=yes`, so it signs in with what your SSH
configuration and agent already provide and never prompts. Saved hosts carry no
key of their own: the key comes from `~/.ssh/config`. OpenSSH offers every key
your agent holds before the files you name, and a server disconnects after
`MaxAuthTries` failures (six by default). An agent holding keys for other
machines, such as a password manager's, can use up those attempts before the
right key is offered. Connect then shows **Too Many Authentication Attempts**.
To offer only the host's key, set it for that host:

```
Host build-box
    IdentityFile ~/.ssh/build-box
    IdentitiesOnly yes
```

A key that needs a passphrase or a host that wants a password shows
**Needs a Password or Key**; **Open SSH Shell** runs the same connection in a
terminal, where SSH can ask. A host that signs you in and then closes the
connection before its `ubiquitty-host` answers shows **Closed the Connection**.
The shell is where you can see why `ubiquitty-host` did not start.

After the SSH bootstrap answers, a QUIC connection that fails its handshake
doesn't fail the session. The session goes on over SSH, and the carrier reports
that QUIC fell back.

### Show a grid sized by another client

Each window keeps its own size when another attached client controls the host's
terminal dimensions. On macOS and iOS, `remote.non_owner_presentation` selects
how that host grid is shown:

```toml
[remote]
non_owner_presentation = "pan"
```

The default, `"letterbox"`, keeps the normal grid origin. `"pan"` keeps text at
its native size and moves the local viewport just enough to show the host's
visible cursor. It retains the viewport while reading history or while the
cursor is hidden. `"fit"` scales the grid and its images uniformly, without
enlarging them. It stops at the existing 6pt minimum used by font zoom; a view
smaller than that grid clips it symmetrically. This is the font-size limit,
not a guarantee of readability for every font. None of these choices resizes
the host terminal. Local terminals and the attachment that owns the host's
geometry keep their ordinary behavior.

The live human client that owns the terminal size also supplies its theme to
programs. If that client disconnects, another attached human with permission to
type can change the theme without taking the retained size. Programs subscribed
to colour-scheme changes are notified even while idle. An attached agent cannot
replace the human's theme.

### What a host is holding

Selecting a host lists what it holds as an outline: each workspace, and under it
its windows, tabs and panes. A level with one child is folded into the row above
it, so a workspace of one window, one tab and one pane is one row. A row shows
its title and what is running there, its labels and tags, a status mark (a
program's reported state, a failed command, a bell or a notification nobody has
seen), progress, a tab's colour and badge, who is attached, and how long ago
anything under it last wrote or was typed into. A closed row says how many
windows, tabs and panes it hides. A workspace nothing runs in, which the host
can restore from its record, is listed as restorable.

If more than one Ubiquitty installation is running on the same machine, the
**Running Sessions** picker lists the other hosts by when they started. Choose
one to see its workspaces on Mac or iOS. Each selection connects through the
installation that owns those sessions; their numeric identifiers are kept
separate. Discovery requires an updated host and client.

The list follows the host while the window is open. If the connection drops,
the rows stay, faded, under the reason, until the host answers again.

A host holds at most 64 sessions and serves at most 64 clients at once, local
and QUIC connections together. A connect or a shared window that would start a
65th session is refused because the host is full, and every running session is
left as it was; end a session to make room. A 65th client is not admitted.

The search field narrows the outline by title, program, directory, label or
tag. Opening a workspace's row attaches to it; opening a pane's row attaches
and shows that pane. When nothing says which workspace a connect means, Connect
asks. A row's menu sets a label or tags, renames a workspace or a tab, moves a
tab, closes a window or terminates a session or a workspace. Closing and
terminating ask first and say what ends; anyone attached to a session is asked
by the host and can decline.

The remote executable lives at `~/.ubiquitty/ubiquitty-host`. When it is missing,
Connect offers to install a matching bundled executable, subject to
`auto_install_host` and approval for that host. Automatic installation depends on
the executables included in the app: a matching macOS architecture can use the
bundled host, and Linux x86_64 or aarch64 requires its corresponding bundled
asset. Otherwise Connect offers the commands that install it by hand.
Installation never builds from source on the server.

If the host refuses the connection because its protocol version is incompatible,
the refusal offers **Update**. An older build whose protocol range overlaps the
client's can still connect. The update installs before it connects: it asks the
host its platform and how many sessions its running daemon holds, uploads the
matching bundled executable as `~/.ubiquitty/ubiquitty-host.new`, and checks its
SHA-256 and that it runs (`--version`, `--help`) before replacing anything. The
replaced executable is kept as the one `ubiquitty-host.backup-<date>`. When
sessions are running, you choose between **Update When They End** — the new
executable waits as `ubiquitty-host.pending` and takes over on the first
connect after the daemon's last session exits — and **Update Now**, which asks
the running daemon to hand its live sessions to the new host. The shells keep
running, with their PTYs, pane and workspace identities, scrollback and resume
state. Clients reconnect to the successor. If handover is refused, the old
daemon keeps serving its sessions and the app reports the update as pending,
with the host log to inspect. It never stops a daemon to force an update.
Upload validation failures leave the installed executable unchanged; a startup
or handover failure after installation leaves the new executable in place.

A host hands its sessions only to a successor that reads its state format;
otherwise it keeps them, and the update waits for them to end. Linux handover
also requires the running kernel to support socket peer pidfds; if it does
not, the old daemon keeps its sessions and the update remains pending.

To install by hand, choose **Copy Install Commands** and run them on the
server. They download the published host of the app's own version for the
server's `uname -sm`, from
`https://ubiquitty.org/download/host/<version>/ubiquitty-host-<os>-<arch>`
(`linux-x86_64`, `linux-arm64` or `macos-arm64`), compare its SHA-256 with that
directory's `SHA256SUMS`, rename it over `~/.ubiquitty/ubiquitty-host` and
print its `--version`. A refused download never replaces the installed host.
For a platform no release publishes a host for, Connect says so and offers no
commands. The published hosts and their URLs are listed in
[Hosting](../auto-update.md#hosting).
If the remote `$TERM` is not recognized, use **File ▸ Set Up Ubiquitty on Remote Host…**,
or connect from a shell with
`/Applications/Ubiquitty.app/Contents/MacOS/Ubiquitty ssh [ssh options] <host>`, which
installs the `xterm-ubiquitty` entry over SSH before the login shell starts. Its
`mosh` form installs nothing; see
[Over SSH / inside tmux](shell-integration.md#over-ssh--inside-tmux).

Startup text from a remote shell is accepted up to 16 KiB, with individual lines
limited to 4 KiB. The bootstrap marks where that text ends and the host protocol
begins. A fresh host in the session picker reports the missing installation and
offers guidance to use Connect.

The default host build opens a QUIC UDP listener on all interfaces at an
OS-assigned port, as well as its owner-only local Unix socket. To disable UDP
when starting a daemon, use `--quic-port -1`; see
[listener defaults, authentication, and controls](../quic-trust.md#what-the-daemon-listens-on).

## Share This Window with Agents

**File ▸ Share This Window with Agents** hands every running local shell in the
window's native tabs and split panes to your local `ubiquitty-host`. Choose
**Create New Workspace** and a name, or **Add to** an existing workspace.
The shells keep running with the same state, tabs, and splits. Open that host
from another device to connect to the shared workspace. Agents can also ask to
watch or type into those terminals.

- It's **consent-gated**: when an agent asks to attach, you're prompted; you can allow once,
  for the session, or always.
- A **presence button** shows other clients attached to the pane. Split panes
  have their own button in the pane title; a single pane uses the window title
  bar. The button and **Session** menu list participants and offer per-agent
  **revoke**.
- On macOS, an agent reading a screen turns that pane's presence button amber.
  It stays amber after the agent disconnects, until you open its activity list.
  The list shows recent readers and times; a read arriving after the list was
  built remains unread. A single pane uses the window's title-bar button.
  The host records successful text captures and the start of a screen stream,
  including a stream used for a screenshot. The history contains no screen
  contents, is bounded, and is sent only to human clients attached to that pane.
  This requires a host and client that support screen-access activity.
- **File ▸ Stop Sharing This Window** asks the daemon to return every shared
  pane to the Mac window, with the same processes still running.
- If a handoff is interrupted, keep the window open. **Share This Window**
  retries the same publication without creating a second workspace.

## The `ubq` client (CLI + MCP)

`ubq` is a headless client of the daemon — the same Sync protocol, minus the
renderer. It's how AI tooling drives terminals. Build it with `./Scripts/build-agent.sh`.
The manual, with every verb and an example for each, is [Docs/ubq.md](../ubq.md).
The daemon refuses an agent that presents no capability token, so issue one before the first
command (see **Token auth** below).

**As a CLI** it has verbs to create and drive sessions, each an operation in
the method registry with a schema (`ubq api list`). Under the default `confirm`
policy, `new`, `run` and `send` need an `allow` rule or `--yes` typed at your
terminal, and exit 4 without one; see [Policy](../ubq.md#policy).

```
ubq new --label build              # start a session in the daemon
ubq ls                             # list sessions, their labels and panes
ubq run -s build -- make test      # run, return its exit status and output
ubq send -s build --enter "<keys>" # type into a session
ubq read -s build --screen         # the current screen as text
ubq wait -s build --for exit       # woken by the daemon's event, never polled
ubq events --json                  # the event stream, one JSON object per line
ubq -H user@host ls                # the same verbs against a daemon over ssh
```

**As an MCP server** (`ubq mcp`) it exposes those as `terminal_*` tools over
JSON-RPC stdio, so a coding assistant can open, run, read, screenshot, and manage
terminals. `ubq -H user@host mcp` exposes the same tools against that remote
host, using the token and consent required there. `terminal_screen` returns
the screen as text; `terminal_screenshot` requests an image.

### Registering the MCP server

Register `ubq mcp` with your MCP client as a stdio server. The macOS app bundles the
agent at `Ubiquitty.app/Contents/Helpers/ubq` and the host at
`Ubiquitty.app/Contents/Helpers/ubiquitty-host`; a source checkout builds them with
`Scripts/build-agent.sh` and `Scripts/build-host.sh`. This common JSON shape shows the
command, arguments, and environment; adapt the outer key to your client:

```json
{
  "mcpServers": {
    "ubiquitty-terminal": {
      "command": "/absolute/path/to/ubq",
      "args": ["mcp"],
      "env": {
        "UBIQUITTY_HOST_BIN": "/absolute/path/to/ubiquitty-host"
      }
    }
  }
}
```

Replace both paths with executable binaries from the same build. A daemon must already
be running or the agent must be able to start it through `UBIQUITTY_HOST_BIN`.
Registration alone does not grant access: token authentication and consent still apply
as described below. See the [agent reference](../../Source/Agent/README.md) for commands,
tool schemas, policy, authentication, and exit codes.

Safety for the agent side:

- **Policy** — an allow / confirm / deny ruleset (default *confirm*) gates actions, with an
  audit log. Configure via `$UBIQUITTY_AGENT_POLICY` or `<control-dir>/agent-policy.conf`.
- **Token auth** — scoped, revocable capability tokens, required by default. The
  daemon refuses every agent and every remote (QUIC) client that presents no
  valid token; only a Local peer (the macOS app, or another of the daemon's own
  trusted binaries, connecting as the same user) is exempt. Before
  the first `ubq` command, issue a token with
  `ubiquitty-host token issue --scope all --label <name>` and export the printed
  value as `$UBIQUITTY_AGENT_TOKEN` (or save it to `<control-dir>/agent-token`);
  without one the daemon refuses the agent, and the verb reports
  "authentication required" (exit 7). On a host with
  no human attached to answer a consent prompt — a headless server — add
  `--allow-always`, which records the standing attach consent for that token at
  issue time; `token revoke` withdraws it with the token. Starting the daemon with
  `UBIQUITTY_REQUIRE_TOKEN=0` turns enforcement off for local agents, for
  development and tests; a remote peer still needs a token.

**Workspace tree changes require separate approval for each operation.** An
attached person must approve an agent's exact rename, move, split, close, or
other tree edit, including a request made by typing `ubq` in a shell. A standing
attach grant, `--allow-always`, or an agent-policy rule does not replace that
approval. Without an attached person to answer, these operations are refused.

Command-aware features (precise exit codes, "wait until idle", reading a specific command's
output) rely on [shell integration](shell-integration.md) being active in the session.

## How it fits together

```
   your shell ──(live PTY)──► ubiquitty-host daemon ──(Sync protocol)──┬─► Ubiquitty window (renders)
                                  (runs the Core)                     └─► ubq (AI agent)
```

Sharing, remote sessions, and agent access use the same host. Attach consent and
per-operation workspace approval are separate checks.

QUIC needs inbound UDP to the daemon’s advertised port. A filtered UDP path
times out its handshake after five seconds, then the connection falls back to SSH.
