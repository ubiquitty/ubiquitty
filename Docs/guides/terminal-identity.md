<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Terminal Identity

Ubiquitty tells the programs it runs who it is through four environment variables, set on
every shell it spawns:

| Variable               | What it is                          | Default                                            |
| ---------------------- | ----------------------------------- | -------------------------------------------------- |
| `TERM`                 | terminfo entry (capability lookup)  | `xterm-ubiquitty` if resolvable, else `xterm-256color` |
| `TERM_PROGRAM`         | which terminal app this is          | `Ubiquitty`                                          |
| `TERM_PROGRAM_VERSION` | its version                         | the app version                                    |
| `COLORTERM`            | color depth                         | always `truecolor`                                 |

`TERM` is `[term] identifier` from the configuration when it is set. Otherwise
it is `UBIQUITTY_TERM` from the environment of the process that starts the
shell, and `xterm-256color` when that is unset. The macOS app sets
`UBIQUITTY_TERM` at launch, to `xterm-ubiquitty` when that terminfo entry
resolves and to `xterm-256color` when it does not, so a host daemon the app
starts passes the same choice to its shells. A daemon started any other way
reads whatever `UBIQUITTY_TERM` its own environment carries.

Programs may use `TERM_PROGRAM`, terminfo, or terminal queries to decide which
features to enable. Ubiquitty reports its own name, and treats every program it
runs alike.

## Changing the reported identity yourself

The identity is yours to set, in **Settings** (⌘,) ▸ **Terminal** ▸ **Terminal Identity**,
or in `~/.config/ubiquitty/config.toml`:

```toml
[term]
program = "Ubiquitty"
version = "1.0.0"
```

New tabs use the changed identity; existing shells keep their environment.
Changing it affects all programs launched in those tabs, not only one tool,
and does not add terminal capabilities. Keep the default unless your workflow
requires a different value.

### Verify it

```sh
echo "$TERM_PROGRAM"        # the reported identity
echo "$TERM"                # xterm-ubiquitty when the terminfo entry resolves
infocmp xterm-ubiquitty     # non-zero exit means the entry is missing
```
