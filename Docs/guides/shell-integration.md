<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Shell Integration

Shell integration lets Ubiquitty understand where your **prompts** and **commands** begin and
end, and **which machine and directory** a session is actually in. With it, you can jump
between prompts, select or copy a command's output, clear the screen relative to a prompt,
and have a window tag match the host you ssh'd to. It's based on two shared conventions,
**OSC 133** marks and **OSC 7** location reports.

## What it enables

- **Jump to Previous / Next Prompt** — ⌘⇧↑ / ⌘⇧↓ — scroll between executed commands.
- **Select Last Command Output** — ⌘⇧A — select everything the last command printed.
- **Clear to Previous Mark** — ⌘L — remove the most recent command (its prompt + output) from
  the screen, sliding the current prompt up into its place; press again to remove the command
  before it, and so on.
- A small **bracket** is drawn in the gutter at each command's prompt — green normally, and
  red when the command exited non-zero (so failures are visible at a glance).
- Right-click a command region for **Copy Command** / **Copy Command Output** actions.
- The **host and directory** a session is in, reported by the shell itself — which is what
  lets a `match_host` tag rule fire for a machine you reached by typing `ssh`, and what sees
  past a second hop (see *Over SSH* below).

## Setting it up

Your shell emits the OSC 133 marks. Ubiquitty exports `UBIQUITTY_INTEGRATION_DIR` to every shell
it launches, and the snippet for your shell lives there. A shell the host daemon
starts gets it too: a daemon the app did not start writes the scripts it carries
to the `shell-integration` directory of its control directory (`~/.ubiquitty` by
default), so the same rc block loads them for `ubq` and remote sessions.

**Welcome screen ▸ Install shell integration**, or **Ubiquitty ▸ Install Shell Integration…**,
adds a block that sources it to `~/.zshrc` and `~/.bashrc`, and to `~/.bash_profile` and
`~/.config/fish/config.fish` when you have them:

```sh
# >>> Ubiquitty shell integration >>>
# Loads Ubiquitty's shell integration in the shells Ubiquitty starts.
# Remove this block to undo.
if [[ -n "${UBIQUITTY_INTEGRATION_DIR-}" && -r "$UBIQUITTY_INTEGRATION_DIR/zsh.sh" ]]; then
    source "$UBIQUITTY_INTEGRATION_DIR/zsh.sh"
fi
# <<< Ubiquitty shell integration <<<
```

It asks first, naming the files it would write and which of them it would create. `~/.zshrc`
and `~/.bashrc` are created when missing; `~/.bash_profile` is not, because a new one would
stop a login bash from reading `~/.profile`. A file already sourcing the snippet is left as it
is, a later install rewrites the block in place, and a startup file that is a symbolic link
into a dotfiles repository stays one: the block is written to the file it points at.

To set it up by hand instead, source the snippet from your rc file:

```sh
# ~/.zshrc
[ -n "$UBIQUITTY_INTEGRATION_DIR" ] && source "$UBIQUITTY_INTEGRATION_DIR/zsh.sh"

# ~/.bashrc
[ -n "$UBIQUITTY_INTEGRATION_DIR" ] && source "$UBIQUITTY_INTEGRATION_DIR/bash.sh"

# ~/.config/fish/config.fish
test -n "$UBIQUITTY_INTEGRATION_DIR" && source "$UBIQUITTY_INTEGRATION_DIR/fish.fish"
```

Before each prompt it sends `CSI 7 SP q` to restore the terminal's configured
cursor shape and blink. Prompt hooks can then select their own cursor, including
vi editing modes. This uses xterm's DECSCUSR extension; `CSI 0 SP q` selects a
blinking block under the DEC definition.

The snippet emits four marks around each command:

| Mark | Meaning |
|------|---------|
| `OSC 133 ; A` | prompt start |
| `OSC 133 ; B` | command input start |
| `OSC 133 ; C` | command output start (the command is now running) |
| `OSC 133 ; D ; <exit>` | command finished, with its exit code |

and one location report each time a prompt is drawn:

| Report | Meaning |
|--------|---------|
| `OSC 7 ; file://<host>/<path>` | the working directory, and the machine it is on |
| `OSC 1337 ; RemoteHost=<user>@<host>` | the same machine, in iTerm2's spelling |

Neither is a Ubiquitty invention — OSC 133 is read by kitty, WezTerm, VS Code, iTerm2 and
Windows Terminal, and OSC 7 by those and vte-based terminals. A shell already emitting them
for another terminal works in Ubiquitty unchanged, and ours emits them to any terminal rather
than only to this one.

## Over SSH / inside tmux

The marks are just escape sequences, so they flow over SSH and through `tmux`. If a remote
host's `$TERM` isn't recognized, use **File ▸ Set Up Ubiquitty on Remote Host…** to install
the `xterm-ubiquitty` entry there (it gives you a copy-paste `tic` command — no file transfer
needed).

The app's executable also installs the entry as you connect:

```sh
/Applications/Ubiquitty.app/Contents/MacOS/Ubiquitty ssh [ssh options] example-host
```

It runs `ssh -t` with your options, and on the remote host, before the login shell starts,
compiles the entry into `~/.terminfo` when `tic` is installed and the entry does not
already resolve. A failed install still starts the login shell. The host must be the last
argument, and the wrapper takes no remote command of its own. `Ubiquitty mosh [mosh options]
example-host` connects through mosh with no terminfo step, so install the entry first by one
of the other two ways.

Install integration on each remote host where you want prompt marks and
location reports. The local process tree cannot identify a second SSH hop:
after `ssh bastion` followed by `ssh example-host`, the shell on `example-host`
must report its location for the title and `match_host` rules to use it.

Copy the snippet across and source it from the remote shell's startup file — unconditionally,
without testing `TERM_PROGRAM`:

```sh
scp "$UBIQUITTY_INTEGRATION_DIR/zsh.sh" example-host:~/.ubiquitty-zsh.sh
ssh example-host 'echo "source ~/.ubiquitty-zsh.sh" >> ~/.zshrc'
```

Do not depend on `TERM_PROGRAM` for remote setup: SSH does not forward it
unless the client and server are configured to do so. The snippets emit
terminal sequences rather than changing the reported terminal identity.

> Without shell integration Ubiquitty still works fully; the prompt-aware commands fall
> back (e.g. ⌘L clears to the top, ⌘⇧A is unavailable).

## CLI tab-completion

The `ubq` and `ubiquitty-host` command-line tools ship bash and zsh tab-completion
for their verbs and flags. `ubq` also completes live session IDs by querying the
running daemon (`ubq ls`).

The quickest setup evaluates the embedded script at shell startup:

```sh
# ~/.zshrc
eval "$(ubq completions zsh)"

# ~/.bashrc
eval "$(ubq completions bash)"
```

The same scripts ship as files alongside the OSC 133 snippets, so you can install them the
distro-standard way instead:

```sh
# zsh: drop into your fpath, then run compinit
cp "$UBIQUITTY_INTEGRATION_DIR/ubq.zsh" "${fpath[1]}/_ubq"

# bash: drop into the completions directory
cp "$UBIQUITTY_INTEGRATION_DIR/ubq.bash" /usr/local/etc/bash_completion.d/
```
