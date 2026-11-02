#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Scripts/install-hooks.sh — install the repo's git hooks (run once per clone).
#
#   ./Scripts/install-hooks.sh
#
# Installs a dispatcher under each hook name rather than a symlink to this
# checkout's Scripts/hooks. Linked worktrees share one hooks directory, so a
# symlink into one working tree gates every worktree with that tree's copy and
# leaves every hook dangling once it is removed — which git skips silently, so
# it reads exactly like a hook that ran and passed. The dispatcher resolves the
# hook from whichever tree git is operating on, so each worktree is gated by its
# own code and this is safe to run from anywhere.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISPATCH="$ROOT/Scripts/hooks-dispatch"
[ -f "$DISPATCH" ] || { echo "install-hooks: missing $DISPATCH" >&2; exit 1; }

# An explicit core.hooksPath wins; otherwise the COMMON hooks dir, which is where
# git looks for every worktree. `--git-path hooks` is per-worktree and is not.
HOOKS_DIR="$(cd "$ROOT" && { git config core.hooksPath || echo "$(git rev-parse --git-common-dir)/hooks"; })"
[[ "$HOOKS_DIR" != /* ]] && HOOKS_DIR="$ROOT/$HOOKS_DIR"
mkdir -p "$HOOKS_DIR" 2>/dev/null || true

# Retire only dispatchers installed by this script. User-owned hooks stay intact.
for name in post-commit post-merge; do
    installed="$HOOKS_DIR/$name"
    if [ -f "$installed" ] && [ ! -L "$installed" ] && cmp -s "$DISPATCH" "$installed"; then
        rm "$installed"
        echo "removed retired dispatcher: $name"
    fi
done

for hook in "$ROOT"/Scripts/hooks/*; do
    [[ -f "$hook" ]] || continue
    name="$(basename "$hook")"
    # Remove first: an entry left by an older install is a symlink into some
    # worktree, and copying through it would overwrite that tree's source file.
    rm -f "$HOOKS_DIR/$name"
    cp "$DISPATCH" "$HOOKS_DIR/$name"
    chmod +x "$HOOKS_DIR/$name"
    echo "installed: $HOOKS_DIR/$name (resolves to <worktree>/Scripts/hooks/$name)"
done

echo
echo "Installed clone-wide; each worktree runs its own copy of the hook."
