#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# run-ios-live-lane.sh — run the iOS UI suite's live cases against a private
# loopback host built from this checkout.
#
#   ./Scripts/run-ios-live-lane.sh
#   UBQ_IOS_UI_ONLY=TerminalGestureUITests/testALiveArrowDragMovesTheCursorOneArrowPerStep \
#       ./Scripts/run-ios-live-lane.sh
#   UBQ_LIVE_LANE_RUNS=3 ./Scripts/run-ios-live-lane.sh   the same selection three times in a row
#   UBQ_LIVE_LANE_KEEP=1 ./Scripts/run-ios-live-lane.sh   keep the directory, with the listener's
#                                   log, each remote command and the daemon's log, for a failure
#
# The live cases dial `ubiquitty-host` over SSH, and the app refuses a host of
# another build. So the host is built here, by build-host.sh, from the same
# checkout as the app run-ios-ui-tests.sh installs. A host copied from another
# tree, or the account's own daemon, makes every live case read an empty grid.
#
# The SSH server is a private OpenSSH listener on a free loopback port, run as
# this user with keys made for the run. Its ForceCommand runs the app's remote
# command with HOME, UBIQUITTY_HOME and the XDG directories inside the run's
# temporary directory, so the account's ~/.ubiquitty, dotfiles, shell history
# and daemon are never read or touched. On exit the listener and the daemon it
# started are stopped, and the directory is removed.
#
# Exit status is run-ios-ui-tests.sh's for the last run, or 2 when the lane
# could not be set up.
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"

RUNS="${UBQ_LIVE_LANE_RUNS:-1}"
case "$RUNS" in
    '' | *[!0-9]* | 0) echo "run-ios-live-lane: UBQ_LIVE_LANE_RUNS must be a positive number, got '$RUNS'" >&2; exit 2 ;;
esac
SSHD=/usr/sbin/sshd
[ -x "$SSHD" ] || { echo "run-ios-live-lane: no OpenSSH server at $SSHD" >&2; exit 2; }

nice -n 5 "$ROOT/Scripts/build-host.sh" >/dev/null || { echo "run-ios-live-lane: build-host.sh failed" >&2; exit 2; }
HOST_BINARY="$UBQ_BUILD_ROOT/host/ubiquitty-host"
[ -x "$HOST_BINARY" ] || { echo "run-ios-live-lane: build-host.sh produced no $HOST_BINARY" >&2; exit 2; }

# /tmp rather than $TMPDIR: the per-user temporary directory's path is long
# enough to push the daemon's socket past the 104-byte sun_path limit.
FIXTURE="$(mktemp -d /tmp/ubq-live-lane.XXXXXX)" || exit 2
chmod 700 "$FIXTURE"
SSHD_PID=""
HOME_DIRECTORY="$FIXTURE/account"
DAEMON_HOME="$HOME_DIRECTORY/.ubiquitty"

stopFixture() {
    if [ -n "$SSHD_PID" ]; then
        kill "$SSHD_PID" 2>/dev/null
        wait "$SSHD_PID" 2>/dev/null
    fi
    # Only a daemon running this run's own binary is signalled.
    for pidFile in "$DAEMON_HOME"/host-*.pid; do
        [ -f "$pidFile" ] || continue
        pid="$(cat "$pidFile")"
        case "$(ps -p "$pid" -o command= 2>/dev/null)" in
            "$DAEMON_HOME/ubiquitty-host"* | "/private$DAEMON_HOME/ubiquitty-host"*) kill "$pid" 2>/dev/null ;;
        esac
    done
    if [ -n "${UBQ_LIVE_LANE_KEEP:-}" ]; then
        echo "run-ios-live-lane: kept $FIXTURE" >&2
    else
        rm -rf "$FIXTURE"
    fi
}
# shellcheck disable=SC2329 # invoked by the trap
trap stopFixture EXIT

mkdir -p "$DAEMON_HOME" "$HOME_DIRECTORY/config" "$HOME_DIRECTORY/cache"
chmod 700 "$HOME_DIRECTORY" "$DAEMON_HOME"
cp "$HOST_BINARY" "$DAEMON_HOME/ubiquitty-host"
ssh-keygen -q -t ed25519 -N "" -f "$FIXTURE/host-key" || exit 2
ssh-keygen -q -t ed25519 -N "" -f "$FIXTURE/client-key" || exit 2

PORT="$(/usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')" || exit 2

cat >"$FIXTURE/remote-command.sh" <<EOF
#!/bin/sh
printf '%s\\n' "\$SSH_ORIGINAL_COMMAND" >>"$FIXTURE/remote-commands.log"
exec env -i HOME="$HOME_DIRECTORY" UBIQUITTY_HOME="$DAEMON_HOME" \\
    XDG_CONFIG_HOME="$HOME_DIRECTORY/config" XDG_CACHE_HOME="$HOME_DIRECTORY/cache" \\
    SHELL=/bin/bash BASH_SILENCE_DEPRECATION_WARNING=1 TERM="\${TERM:-xterm-256color}" LANG=en_US.UTF-8 \\
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \\
    /bin/sh -c "\${SSH_ORIGINAL_COMMAND:-exec /bin/bash --noprofile --norc -i}"
EOF
chmod 755 "$FIXTURE/remote-command.sh"

# StrictModes is off because /tmp is world-writable; the key file and the
# directory holding it are this user's alone (0700).
cat >"$FIXTURE/sshd.conf" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $FIXTURE/host-key
PidFile $FIXTURE/sshd.pid
AuthorizedKeysFile $FIXTURE/client-key.pub
AllowUsers $(id -un)
StrictModes no
UsePAM no
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PermitUserRC no
PermitUserEnvironment no
PermitTTY yes
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
ForceCommand $FIXTURE/remote-command.sh
EOF

"$SSHD" -D -e -f "$FIXTURE/sshd.conf" 2>"$FIXTURE/sshd.log" &
SSHD_PID=$!
ready=0
for _ in $(seq 1 50); do
    if /usr/bin/nc -z -G 1 127.0.0.1 "$PORT" 2>/dev/null; then
        ready=1
        break
    fi
    kill -0 "$SSHD_PID" 2>/dev/null || break
    sleep 0.1
done
if [ "$ready" != 1 ]; then
    echo "run-ios-live-lane: the private SSH listener did not start:" >&2
    cat "$FIXTURE/sshd.log" >&2
    exit 2
fi
echo "run-ios-live-lane: $(basename "$HOST_BINARY") from this checkout behind 127.0.0.1:$PORT"

status=0
for run in $(seq 1 "$RUNS"); do
    [ "$RUNS" -gt 1 ] && echo "run-ios-live-lane: run $run of $RUNS"
    UBQ_LIVE_SSH_HOST=127.0.0.1 UBQ_LIVE_SSH_USER="$(id -un)" UBQ_LIVE_SSH_PORT="$PORT" \
        UBQ_LIVE_SSH_KEY_FILE="$FIXTURE/client-key" "$ROOT/Scripts/run-ios-ui-tests.sh"
    status=$?
    [ "$status" -eq 0 ] || break
done
exit "$status"
