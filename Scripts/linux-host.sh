#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# linux-host.sh — run CI's Linux stages on a native Linux host over ssh.
#
# The hook's Linux arms otherwise run in an arm64 container on this Mac
# (Scripts/run-linux.sh). The Linux goldens are minted on a native x86_64 host
# and the container cannot export dma-buf, so a native host is the machine that
# agrees with them. A clone names one, and every Linux arm the hook runs goes
# there when it answers:
#
#   git config ubiquitty.linuxHost <ssh host>     this clone's standing choice
#   UBIQUITTY_LINUX_HOST=<ssh host> …             one run; an empty value forces
#                                                 the container
#
# Unset by default, so a machine that names no host runs what it always ran.
#
# Usage:
#   linux-host.sh host                  the configured host, or nothing
#   linux-host.sh route                 "host <name>" or "container <why>"
#   linux-host.sh stages [--fetch <scratch-relative path>=<local directory>]…
#                        <stage>…       run these stages of CI's Linux battery
#   linux-host.sh release               remove this run's remote directory
#
# `stages` runs `ci_batteries.py run linux --only <stage>` on the host, so the
# command, environment and log of each stage are CI's own; they are not written
# out a second time here. The tree is synced to a per-run directory under the
# remote user's home, the stage logs are brought back under
# $UBQ_LINUX_HOST_RESULTS (default $UBQ_CI_ROOT/linux-host), and the directory
# is removed again.
#
# UBQ_LINUX_HOST_RUN names a run that several invocations share: the first one
# syncs and builds, later ones find the build tree warm, and `release` removes
# the directory. The pre-push hook sets it and releases on exit. Without it each
# invocation is a run of its own and removes its directory before returning,
# including when a stage fails or the invocation is interrupted.
#
# Provisioning is not here. The packages the host needs are the ones CI's
# "Linux tools" and "GTK/Vulkan toolchain" stages check for; a host missing one
# fails the build stage naming it.
#
# Stages of one run are sequential. Two invocations at once would share one
# build tree.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"

# Seconds to wait for the host before the container is used instead.
CONNECT_TIMEOUT="${UBQ_LINUX_HOST_CONNECT_TIMEOUT:-5}"
# Free gigabytes the host's home filesystem must have. The build tree, the host
# test tree and the snapshot renders are several gigabytes together; a full disk
# otherwise fails somewhere in the middle of a compile.
MINIMUM_FREE_GIGABYTES="${UBQ_LINUX_HOST_MIN_FREE_GB:-10}"
# Directory names under the remote home. Cleanup refuses any path outside the
# first, so a mistaken run identifier cannot name something else.
RUNS_DIRECTORY="ubiquitty-linux-runs"
CACHE_DIRECTORY=".cache/ubiquitty-linux-host"
# A run directory untouched this long belongs to an invocation that died
# without releasing it (a killed terminal, a lost connection).
STALE_MINUTES=1440

# The run an invocation that owns its directory removes on exit.
ownedIdentifier=""

sshOptions=(-o BatchMode=yes -o "ConnectTimeout=$CONNECT_TIMEOUT")

configuredHost() {
    # A variable that is set wins even when empty: that is how one run opts out
    # of a clone's standing choice.
    if [ -n "${UBIQUITTY_LINUX_HOST+set}" ]; then
        printf '%s' "$UBIQUITTY_LINUX_HOST"
        return 0
    fi
    git -C "$ROOT" config --get ubiquitty.linuxHost 2>/dev/null || true
}

# An ssh destination is never an option: a value starting with a dash would be
# read as one.
validHostName() {
    case "$1" in
        '' | -* | *[!A-Za-z0-9._@:-]*) return 1 ;;
    esac
}

probeHost() { # <host>
    ssh "${sshOptions[@]}" "$1" true >/dev/null 2>&1
}

routeToHost() {
    if [ -n "${UBQ_LINUX_HOST_ROUTE:-}" ]; then
        printf '%s\n' "$UBQ_LINUX_HOST_ROUTE"
        return 0
    fi
    local host
    host="$(configuredHost)"
    if [ -z "$host" ]; then
        printf 'container no Linux host is configured (git config ubiquitty.linuxHost)\n'
    elif ! validHostName "$host"; then
        printf 'container %s is not a usable ssh host name\n' "$host"
    elif probeHost "$host"; then
        printf 'host %s\n' "$host"
    else
        printf 'container %s did not answer ssh within %ss\n' "$host" "$CONNECT_TIMEOUT"
    fi
}

# The host this invocation runs on, which is the route's answer. Asking for it
# here as well as in the hook keeps a direct invocation from running somewhere
# its caller did not decide.
requiredHost() {
    local route
    route="$(routeToHost)"
    case "$route" in
        "host "*) printf '%s' "${route#host }" ;;
        *)
            echo "linux-host: no Linux host to run on — ${route#container }" >&2
            return 2
            ;;
    esac
}

runIdentifier() {
    printf '%s' "${UBQ_LINUX_HOST_RUN:-}"
}

# Where a shared run remembers what it created, so `release` knows whether there
# is anything to remove without asking the host.
stateFile() { # <run identifier>
    printf '%s/linux-host-%s.state' "${UBQ_CI_ROOT:-${TMPDIR:-/tmp}}" "$1"
}

validRunIdentifier() {
    case "$1" in
        '' | *[!A-Za-z0-9._-]*) return 1 ;;
    esac
}

# The checkout's files as a NUL-separated list: tracked and untracked-unignored
# files that exist, which is the tree a push would send and what the hook's own
# cache keys cover, uncommitted edits included. A tracked file deleted in the
# working tree is left out rather than failing the sync, and a directory entry
# (a submodule) is not a file.
treeFiles() {
    python3 - "$ROOT" <<'FILES'
import os
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}

def git(where, *arguments):
    return subprocess.check_output(["git", "-C", str(where), *arguments], env=environment)

def files(where, prefix=b""):
    top = git(where, "rev-parse", "--show-toplevel").decode().strip()
    if Path(top).resolve() != where.resolve():
        raise ValueError(f"required submodule is not initialized: {where}")
    tracked = git(where, "ls-files", "--stage", "-z")
    modules = set()
    for entry in tracked.split(b"\0"):
        if entry:
            header, name = entry.split(b"\t", 1)
            if header.split()[0] == b"160000":
                modules.add(name)
    names = set(git(where, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0"))
    for name in sorted(names - {b""}):
        path = where / os.fsdecode(name)
        if name in modules:
            if path.is_symlink() or not path.is_dir():
                raise ValueError(f"required submodule is not initialized: {path}")
            yield from files(path, prefix + name + b"/")
        elif path.is_symlink() or path.is_file():
            yield prefix + name

try:
    # Resolve the complete list before rsync can consume a partial composition.
    entries = list(files(root))
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    print(f"linux-host: source sync refused: {error}", file=sys.stderr)
    sys.exit(2)
sys.stdout.buffer.write(b"\0".join(entries) + b"\0")
FILES
}

prepareRemote() { # <host> <run identifier>
    ssh "${sshOptions[@]}" "$1" bash -s -- "$2" "$RUNS_DIRECTORY" "$MINIMUM_FREE_GIGABYTES" "$STALE_MINUTES" <<'REMOTE'
set -eu
runIdentifier=$1 runsDirectory=$2 minimumFree=$3 staleMinutes=$4
runs="$HOME/$runsDirectory"
mkdir -p "$runs"
free=$(df -Pk "$runs" | awk 'NR == 2 { print int($4 / 1048576) }')
if [ "$free" -lt "$minimumFree" ]; then
    echo "linux-host: $(hostname) has ${free} GB free under $runs; ${minimumFree} GB is the floor." >&2
    exit 3
fi
# Directories of runs that never released, by age, and only inside the runs
# directory: this host is shared with CI.
find "$runs" -mindepth 1 -maxdepth 1 -type d -mmin +"$staleMinutes" -exec rm -rf -- {} +
scratch="$runs/$runIdentifier"
mkdir -p "$scratch/ubiquitty" "$scratch/tmp" "$scratch/tools" "$scratch/ci" "$scratch/build-gcc"
touch "$scratch"
REMOTE
}

syncTree() { # <host> <run identifier>
    local host="$1" identifier="$2"
    local expectedCore="$ROOT" expectedKit="$ROOT"
    [ ! -e "$ROOT/Libraries/ubiquitty-core" ] || expectedCore="$ROOT/Libraries/ubiquitty-core"
    [ ! -e "$ROOT/Libraries/ubiquitty-kit" ] || expectedKit="$ROOT/Libraries/ubiquitty-kit"
    if [ "$(cd "$CORE_ROOT" && pwd -P)" != "$(cd "$expectedCore" && pwd -P)" ] \
        || [ "$(cd "$KIT_ROOT" && pwd -P)" != "$(cd "$expectedKit" && pwd -P)" ]; then
        echo "linux-host: remote checks require the checkout's pinned library mounts; external source overrides are not synchronized" >&2
        return 2
    fi
    # Only this run's gitless source tree is replaced. Build/cache/log siblings
    # stay warm, while a deleted tracked or untracked library file cannot
    # survive into a later stage of the shared run.
    ssh "${sshOptions[@]}" "$host" bash -s -- "$RUNS_DIRECTORY/$identifier/ubiquitty" <<'REMOTE'
set -eu
find "$HOME/$1" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
REMOTE
    treeFiles | rsync -a --from0 --files-from=- -e "ssh ${sshOptions[*]}" \
        "$ROOT/" "$host:$RUNS_DIRECTORY/$identifier/ubiquitty/"
}

# One stage list on the host, in the CI environment. The scratch directory plays
# the runner's workspace: the checkout is a child of it and the build roots its
# siblings, which is where ci_batteries.py puts them.
runStages() { # <host> <run identifier> <stage>…
    local host="$1" identifier="$2"
    shift 2
    local onlyArguments=() stage
    for stage in "$@"; do
        onlyArguments+=(--only "$stage")
    done

    # Values this side knows and the host cannot derive: the tree it receives
    # has no .git, so the version the Mac's builds state comes with it, as
    # run-linux.sh hands it to its container.
    #
    # The host's own Vulkan driver, not lavapipe: CI forces the software driver
    # for runners with no GPU, and the dma-buf smokes need a driver that can
    # export (ci_batteries.py names the variable).
    local prelude="export UBQ_CI_LINUX_VULKAN=native"$'\n'
    if command -v cmake >/dev/null 2>&1; then
        prelude+="export UBIQUITTY_BUILD_VERSION=$(printf '%q' "$(UBQ_VERSION_TREE="$ROOT" "$CORE_ROOT/Scripts/build-version.sh" version)")"$'\n'
        prelude+="export UBIQUITTY_BUILD_IDENTITY=$(printf '%q' "$(UBQ_VERSION_TREE="$ROOT" "$CORE_ROOT/Scripts/build-version.sh" identity)")"$'\n'
    fi
    if [ -n "${UBQ_BUILD_JOBS:-}" ]; then
        prelude+="export UBQ_BUILD_JOBS=$(printf '%q' "$UBQ_BUILD_JOBS")"$'\n'
    fi

    {
        printf '%s' "$prelude"
        cat <<'REMOTE'
set -euo pipefail
scratch="$HOME/$1" cacheDirectory="$HOME/$2"
shift 2
touch "$scratch"
export RUNNER_WORKSPACE="$scratch" RUNNER_TEMP="$scratch/tmp" RUNNER_TOOL_CACHE="$scratch/tools"
export UBQ_CI_ROOT="$scratch/ci"
# The compiler cache is shared by every run directory: the same sources compile
# to the same objects wherever they are checked out.
export CCACHE_BASEDIR="$scratch" CCACHE_NOHASHDIR=1
cd "$scratch/ubiquitty"
unset UBQ_CORE_ROOT UBQ_KIT_ROOT UBIQUITTY_CORE_SOURCE_DIR UBIQUITTY_KIT_SOURCE_DIR
. ./Scripts/library-scripts.sh
# The QUIC dependency prefix is built once per version of its fetch script and
# kept outside the run directory; the run reaches it through the path CI uses.
quicKey=$(sha256sum "$CORE_ROOT/Scripts/fetch-quic-deps.sh" | cut -c1-12)
mkdir -p "$cacheDirectory/quic-deps-$quicKey"
ln -sfn "$cacheDirectory/quic-deps-$quicKey" "$scratch/build-gcc/quic-deps"
exec python3 "$CORE_ROOT/Scripts/ci_batteries.py" run linux \
    --source-root "$PWD" --core-source-root "$CORE_ROOT" --kit-source-root "$KIT_ROOT" "$@"
REMOTE
    } | ssh "${sshOptions[@]}" "$host" bash -s -- "$RUNS_DIRECTORY/$identifier" "$CACHE_DIRECTORY" \
        ${onlyArguments[@]+"${onlyArguments[@]}"}
}

fetchResults() { # <host> <run identifier> <scratch-relative path>=<local directory>…
    local host="$1" identifier="$2" mapping remotePath localDirectory
    shift 2
    for mapping in "$@"; do
        remotePath="${mapping%%=*}"
        localDirectory="${mapping#*=}"
        mkdir -p "$localDirectory"
        # A path the stages did not create is not a failure of the fetch.
        rsync -a -e "ssh ${sshOptions[*]}" \
            "$host:$RUNS_DIRECTORY/$identifier/$remotePath/" "$localDirectory/" 2>/dev/null || true
    done
}

releaseRun() { # <run identifier>
    local identifier="$1" state host
    validRunIdentifier "$identifier" || return 0
    state="$(stateFile "$identifier")"
    [ -f "$state" ] || return 0
    host="$(cat "$state")"
    rm -f "$state"
    validHostName "$host" || return 0
    # The remote path is rebuilt from the validated identifier under the runs
    # directory, so nothing else on the host can be named.
    ssh "${sshOptions[@]}" "$host" bash -s -- "$RUNS_DIRECTORY" "$identifier" >/dev/null 2>&1 <<'REMOTE' || true
set -eu
rm -rf -- "$HOME/$1/$2"
REMOTE
}

stagesCommand() {
    local fetches=() results
    while [ "${1:-}" = "--fetch" ]; do
        fetches+=("$2")
        shift 2
    done
    if [ "$#" -eq 0 ]; then
        echo "linux-host: stages needs at least one stage name (ci_batteries.py list linux)" >&2
        return 2
    fi
    local host
    host="$(requiredHost)" || return 2

    results="${UBQ_LINUX_HOST_RESULTS:-${UBQ_CI_ROOT:-${TMPDIR:-/tmp}/ubiquitty-ci}/linux-host}"
    local identifier shared=1
    identifier="$(runIdentifier)"
    if [ -z "$identifier" ]; then
        shared=0
        identifier="$(hostname -s)-$$-$(date +%s)"
    fi
    if ! validRunIdentifier "$identifier"; then
        echo "linux-host: UBQ_LINUX_HOST_RUN may hold letters, digits, dot, dash and underscore only" >&2
        return 2
    fi

    local state
    state="$(stateFile "$identifier")"
    mkdir -p "$(dirname "$state")"
    # Recorded before the first remote command, so an interrupt between the
    # mkdir and the end of the sync still finds the directory to remove.
    printf '%s' "$host" > "$state"
    if [ "$shared" = 0 ]; then
        ownedIdentifier="$identifier"
        trap 'releaseRun "$ownedIdentifier"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
    fi

    echo "linux-host: $host, run $identifier, stages: $*" >&2
    prepareRemote "$host" "$identifier"
    syncTree "$host" "$identifier"
    local status=0
    runStages "$host" "$identifier" "$@" || status=$?
    # The stage logs, and the images a failed snapshot case leaves, in the
    # directory run.py writes them to on this machine and prints in its report.
    local failureDirectory
    failureDirectory="${UBIQUITTY_SNAPSHOT_FAILURE_DIR:-$(python3 -c 'import tempfile; print(tempfile.gettempdir())')/ubiquitty-regression-fail}"
    fetchResults "$host" "$identifier" "ci/linux=$results" "tmp/ubiquitty-regression-fail=$failureDirectory" \
        ${fetches[@]+"${fetches[@]}"}
    if [ "$status" -eq 255 ]; then
        echo "linux-host: the connection to $host failed during the run." >&2
    fi
    return "$status"
}

case "${1:-}" in
    host) configuredHost; echo ;;
    route) routeToHost ;;
    stages) shift; stagesCommand "$@" ;;
    release)
        identifier="$(runIdentifier)"
        [ -n "$identifier" ] && releaseRun "$identifier"
        exit 0
        ;;
    *)
        sed -n '/^# Usage:/,/^#   linux-host.sh release/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
        exit 2
        ;;
esac
