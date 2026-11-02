#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# ios-simulator.sh — the simulator a checkout owns: found or made, booted for
# the run, and shut down again when the run that booted it ends.
#
# Sourced after Scripts/build-root.sh by every script that drives the iOS app
# on a simulator. A booted device is not free: CoreSimulator keeps a
# launchd_sim tree (backboardd, SpringBoard, the app) and its own render hosts
# (SimRenderServer, three SimMetalHost) alive for each one, and scripts that
# each boot a device and leave it running stack those trees up, idle, on every
# Mac that runs them. A run releases what it
# acquired: the device it found already booted stays booted, because somebody
# else is using it; the device it booted itself is shut down on exit, however
# the script ends.
#
# One simulator per checkout, named for the build root that already identifies
# it. A single shared device is a device several worktrees install to,
# uninstall from and drive at once: one run's uninstall lands mid-test in
# another's, and the failure reads as a broken test rather than as two runs on
# one machine. The build root carries a hash of the checkout path
# (Scripts/build-root.sh), so the name is derived rather than chosen — and a
# device whose build root is gone belonged to a checkout that is gone, which is
# what the prune deletes.
#
#   . "$ROOT/Scripts/ios-simulator.sh"
#   ubq_ios_device_acquire run-ios-smokes   # sets UBQ_IOS_DEVICE to the udid
#
#   UBQ_IOS_DEVICE_TYPE="iPhone 16 Pro Max"
#                           the model the checkout's device is made as;
#                           iPhone 18 Pro when unset, on the newest runtime
#                           that makes one. Not iPhone Duo, although the 27.1
#                           preview runtime makes only it: that runtime's
#                           display renders nothing on the Xcode that ships
#                           it (backboardd: "SimDisplay : unsupported
#                           SimColorSpace"), so every screen is black and
#                           the accessibility tree the suite drives is empty.
#                           A model the newest runtime does not support
#                           cannot be made, and the acquire says so. Another
#                           model is another device, named with the model as
#                           a suffix, so switching models never drives a
#                           device made as the wrong one. A model whose
#                           landscape width is regular is what lets a turn
#                           of the device change the app's width class.
#   UBQ_IOS_KEEP_BOOTED=1   a caller that runs several scripts against the
#                           device in a row sets this and owns the boot and
#                           the shutdown itself, so the device boots once
#   Scripts/ios-simulator.sh --boot         boot the checkout's device; prints
#                                           "<udid> booted" when this call booted
#                                           it and "<udid> already-booted" when
#                                           it was up — the caller shuts down
#                                           only what it booted
#   Scripts/ios-simulator.sh --shutdown     shut the checkout's device down
#   Scripts/ios-simulator.sh --prune        delete devices whose checkout is gone
#
# Executable as well as sourceable, for the commands above.

ubq_ios_default_device_type="iPhone 18 Pro"

ubq_ios_device_type() { # the model the checkout's device is made as
    printf '%s\n' "${UBQ_IOS_DEVICE_TYPE:-$ubq_ios_default_device_type}"
}

ubq_ios_device_name() { # the checkout's device, from the build root it already has
    local type slug
    type="$(ubq_ios_device_type)"
    if [ "$type" = "$ubq_ios_default_device_type" ]; then
        printf 'ubq-ios-test-%s\n' "${UBQ_BUILD_ROOT##*-}"
        return
    fi
    slug="$(printf '%s' "$type" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
    slug="${slug#-}"
    printf 'ubq-ios-test-%s-%s\n' "${UBQ_BUILD_ROOT##*-}" "${slug%-}"
}

# The udid and state of a device by name on one runtime; nothing when that
# runtime has none. With no runtime, the newest runtime that has one.
ubq_ios_device_lookup() { # <name> [runtime identifier]  -> "udid state"
    xcrun simctl list devices -j 2>/dev/null | /usr/bin/python3 -c '
import json, sys
name, wanted = sys.argv[1], sys.argv[2]
devices = json.load(sys.stdin)["devices"]
runtimes = [wanted] if wanted else sorted(devices, reverse=True)
for runtime in runtimes:
    for device in devices.get(runtime, []):
        if device.get("name") == name and device.get("isAvailable", True):
            print(device["udid"], device["state"])
            raise SystemExit
' "$1" "${2:-}"
}

# Deletes the checkout's devices on every runtime but the newest installed one.
#
# A device keeps the runtime it was made on, and the app's floor follows the
# SDK: once a newer runtime is installed and the floor moves to it, the old
# device refuses every install ("Requires a Newer Version of iOS"), and the
# scripts that reuse it by name report the app as uninstallable. A device that
# is booted is somebody's run in progress and is left alone.
ubq_ios_retire_stale_devices() { # <name> <runtime identifier>
    xcrun simctl list devices -j 2>/dev/null | /usr/bin/python3 -c '
import json, sys
name, current = sys.argv[1], sys.argv[2]
for runtime, rows in json.load(sys.stdin)["devices"].items():
    if runtime == current:
        continue
    for device in rows:
        if device.get("name") == name and device.get("state") != "Booted":
            print(device["udid"])
' "$1" "$2" | while read -r udid; do
        xcrun simctl delete "$udid" >/dev/null 2>&1 \
            && echo "ios-simulator: deleted $1 on a runtime older than the newest installed"
    done
}

# The newest iOS runtime that can make the checkout's device type. A runtime
# carries its own list of the models it supports — a Duo-only preview image
# supports one — and the newest runtime outright would refuse every other
# model while an older runtime, still within the product's floor, makes it.
ubq_ios_newest_runtime() {
    xcrun simctl list runtimes -j 2>/dev/null | UBQ_DEVICE_TYPE="$(ubq_ios_device_type)" /usr/bin/python3 -c '
import json, os, sys
wanted = os.environ["UBQ_DEVICE_TYPE"]
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and "iOS" in r.get("name", "")]
able = [r for r in runtimes if any(t.get("name") == wanted or t.get("identifier") == wanted for t in r.get("supportedDeviceTypes", []))]
print((able or runtimes)[-1]["identifier"] if runtimes else "")'
}

# Finds or creates the checkout's device and boots it. UBQ_IOS_DEVICE holds the
# udid afterwards. The device is shut down again when this process exits if,
# and only if, it was not booted when this process found it.
ubq_ios_device_acquire() { # <caller, for messages>
    local caller="$1" name found state runtime
    name="$(ubq_ios_device_name)"
    ubq_ios_prune_simulators
    runtime="$(ubq_ios_newest_runtime)"
    [ -n "$runtime" ] || { echo "$caller: no available iOS simulator runtime" >&2; return 2; }
    ubq_ios_retire_stale_devices "$name" "$runtime"
    found="$(ubq_ios_device_lookup "$name" "$runtime")"
    if [ -z "$found" ]; then
        UBQ_IOS_DEVICE="$(xcrun simctl create "$name" "$(ubq_ios_device_type)" "$runtime" 2>/dev/null)"
        [ -n "$UBQ_IOS_DEVICE" ] || { echo "$caller: could not create a $(ubq_ios_device_type) simulator on $runtime" >&2; return 2; }
        state="Shutdown"
    else
        UBQ_IOS_DEVICE="${found%% *}"
        state="${found##* }"
    fi
    export UBQ_IOS_DEVICE
    # Armed before the boot, so a boot that is interrupted still leaves nothing
    # behind. A device that was already booted belongs to whoever booted it.
    if [ "$state" != "Booted" ]; then
        UBQ_IOS_DEVICE_BOOTED_HERE="$UBQ_IOS_DEVICE"
        trap 'ubq_ios_device_release' EXIT
    fi
    xcrun simctl bootstatus "$UBQ_IOS_DEVICE" -b >/dev/null 2>&1
}

# Shuts down the device this process booted. Idempotent, and a no-op for a
# device this process only found: the caller that booted it releases it.
# UBQ_IOS_KEEP_BOOTED=1 defers the release to the caller that set it.
ubq_ios_device_release() {
    [ -n "${UBQ_IOS_DEVICE_BOOTED_HERE:-}" ] || return 0
    [ "${UBQ_IOS_KEEP_BOOTED:-0}" = "1" ] && return 0
    xcrun simctl shutdown "$UBQ_IOS_DEVICE_BOOTED_HERE" >/dev/null 2>&1 || true
    UBQ_IOS_DEVICE_BOOTED_HERE=""
}

# Deletes the devices this tree created for checkouts that no longer exist: a
# name carrying a derived build-root suffix — Xcode's 28-letter hash, then the
# model's slug for a device made as another model — whose DerivedData
# directory is gone, and the one shared name the scripts used
# before the device was per checkout. A name with any other suffix came from a
# build root somebody set by hand (UBQ_BUILD_ROOT), and its checkout cannot be
# judged from here, so it is left alone.
ubq_ios_prune_simulators() {
    xcrun simctl list devices -j 2>/dev/null | /usr/bin/python3 -c '
import json, os, re, sys
home = os.path.expanduser("~")
for runtime, rows in json.load(sys.stdin)["devices"].items():
    for device in rows:
        name = device.get("name", "")
        if name == "ubq-ios-test":
            print(device["udid"], name)
        elif name.startswith("ubq-ios-test-"):
            suffix = name[len("ubq-ios-test-"):]
            match = re.fullmatch(r"([a-z]{28})(-[a-z0-9-]+)?", suffix)
            if match and not os.path.isdir(f"{home}/Library/Developer/Xcode/DerivedData/Ubiquitty-{match.group(1)}"):
                print(device["udid"], name)
' | while read -r udid name; do
        xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
        xcrun simctl delete "$udid" >/dev/null 2>&1 && echo "ios-simulator: deleted $name — its checkout is gone"
    done
}

# The executable forms, for a caller that is not a shell script: the snapshot
# harness renders every iOS case through the shim in one batch, and the
# single-case tool drives xcodebuild itself. Both boot once, run, and shut down
# only what they booted, on the same terms as a sourcing script.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
    --prune)
        ubq_ios_prune_simulators
        ;;
    --boot)
        ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        # shellcheck source=Scripts/build-root.sh
        . "$ROOT/Scripts/build-root.sh"
        # Exported, not prefixed onto the call: the trap that would shut the
        # device down runs at exit, after a prefix has expired.
        export UBQ_IOS_KEEP_BOOTED=1
        ubq_ios_device_acquire ios-simulator || exit 2
        if [ -n "${UBQ_IOS_DEVICE_BOOTED_HERE:-}" ]; then
            printf '%s booted\n' "$UBQ_IOS_DEVICE"
        else
            printf '%s already-booted\n' "$UBQ_IOS_DEVICE"
        fi
        ;;
    --shutdown)
        ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        # shellcheck source=Scripts/build-root.sh
        . "$ROOT/Scripts/build-root.sh"
        found="$(ubq_ios_device_lookup "$(ubq_ios_device_name)")"
        [ -n "$found" ] && xcrun simctl shutdown "${found%% *}" >/dev/null 2>&1
        exit 0
        ;;
    *)
        echo "usage: Scripts/ios-simulator.sh --boot | --shutdown | --prune" >&2
        exit 2
        ;;
    esac
fi
