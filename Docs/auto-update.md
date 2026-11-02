<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Application updates

Packaged frontends update themselves:
**macOS** via [Sparkle](https://sparkle-project.org) 2.x (EdDSA-signed appcast),
from the project's website; **Linux** via an **AppImage** with `zsync` delta updates.
This page describes update behavior and the code that implements it.
For the broader build/packaging picture see
[`building-and-releasing.md`](building-and-releasing.md). The macOS sections come
first; the Linux section is at the end.

## How it works

1. The app embeds `Sparkle.framework` in `Contents/Frameworks` and, on launch,
   starts an `SPUStandardUpdaterController` (via the Swift `Updater`). It checks
   the **appcast** once a day in the background while
   `[updates] check_automatically` is on, which it is by default, and at once
   when the person chooses **Check for Updates…** ([Update
   checks](#update-checks)). The appcast XML feed is named by `SUFeedURL` in the
   app's `Info.plist`, which the build generates from
   `Source/Platform/macOS/Info.plist.in`.
2. Each appcast `<item>` carries a version + an `<enclosure>` pointing at a
   release archive on the website
   (`https://ubiquitty.org/download/macos/<version>/Ubiquitty-<version>.zip`)
   with an **EdDSA signature**.
3. If the newest item is newer than the running `CFBundleVersion`, Sparkle
   shows the update. When the person chooses to install it, Sparkle downloads
   it, verifies the EdDSA signature against `SUPublicEDKey` in the same
   `Info.plist`, and installs it atomically via its XPC helpers. Nothing is
   downloaded or installed before that choice.

The feed's `sparkle:version` is the archive's `CFBundleVersion`, one integer
that orders as the versions do (`MAJOR × 10⁹ + MINOR × 10⁷ + PATCH × 10⁵ + N`;
see [Versioning](building-and-releasing.md#versioning)). Sparkle's standard
comparator splits a version into numeric fields and compares each as a 64-bit
integer, so a single integer is compared whole, and a build installed from the
tree (`0.2.0.3`, `20000003`) is offered the next named version (`0.2.1`,
`20100000`) and never an older one. `sparkle:shortVersionString` is the
three-field `CFBundleShortVersionString`, which the updater shows and does not
compare.

Update integrity rests on the **EdDSA (ed25519) signature**, independent of
Apple. Developer ID code signing + notarization is layered on top so a *fresh*
install passes Gatekeeper without a manual bypass — but it's optional; EdDSA
alone is enough for Sparkle to accept an update.

## Update checks

The schedule is a Ubiquitty preference, not Sparkle's:

```toml
[updates]
check_automatically = true   # the default; false checks only when asked
```

Settings ▸ Software Update shows it as **Check for updates automatically**.
The `Updater` reads Core's effective value when it starts and again after every
configuration change, and sets Sparkle's `automaticallyChecksForUpdates` from
it, so a change takes effect in the running app. Sparkle stores its own copy of
that switch in the app's user defaults; the app writes the copy and never reads
it as the setting.

The bundle settles the rest:

| `Info.plist` key | Value | Effect |
|---|---|---|
| `SUEnableAutomaticChecks` | `true` | Sparkle treats its own "check automatically?" question as answered and never asks it |
| `SUScheduledCheckInterval` | `86400` | scheduled checks are a day apart |
| `SUAllowsAutomaticUpdates` | `false` | no automatic download or installation, and the update alert offers no option to turn it on |

A scheduled check that fails — no network, a 404, a feed that does not parse —
shows nothing. Sparkle's scheduled driver presents an error only once it has
shown an update, so such a failure ends the check silently: the `Updater` writes
it to the app's diagnostic log, and Sparkle schedules the next check a full
interval later. A check the person chose shows its failure. A copy that has
never checked runs its first scheduled check at launch.

## Your terminals across an update

When you choose **Install and Relaunch**, Sparkle tells Ubiquitty that it's
about to relaunch it, then asks it to quit. That quit keeps your session the
way **Restore Last Session on Launch** does, whether or not that setting is on
(`Session::isSessionKeptByQuit`):

- Each local tab's shell, and each pane of a split, moves to the local
  `ubiquitty-host` daemon and keeps running. Sync and remote windows keep
  their sessions on their hosts.
- Ubiquitty saves every window: its frame and screen, whether it was in full
  screen, its place in front of or behind the others, its tabs and the
  selected one, and each tab's split and focused pane.
- The updated Ubiquitty opens every window as it was, with each tab rejoining
  its running shell, and Sync and remote tabs in the same windows as the
  local ones beside them.

The saved arrangement carries a mark that only the launch after the update
reads, and that launch removes it. With **Restore Last Session on Launch**
off, the next time you open Ubiquitty it starts with a new window as usual.

If the update can't keep a program that's running, because the daemon doesn't
start or refuses a shell, Ubiquitty asks before it quits, as it does for any
quit. Click **Cancel** to keep working: the update waits, and Sparkle installs
it the next time Ubiquitty quits, then opens the new version. To install it
sooner, choose **Check for Updates…** again and click **Install and
Relaunch**.

Sparkle reports the relaunch through its updater delegate
(`updaterWillRelaunchApplication:`), which `Updater.swift` passes to the app
delegate as the reason the app quits; Ubiquitty never infers it from the quit
itself. The UI scenario
`swift_update_relaunch_keeps_every_window_tab_split_and_shell` drives that
quit, the launch after it, and the launch after that.

## Code map

| Piece | Where |
|---|---|
| Swift updater over Sparkle (real + no-updater arm) | `Source/Platform/macOS/App/Updater.swift` |
| Updater start + "Check for Updates…" menu item | `Source/Platform/macOS/App/Application/AppDelegate.swift` (`applicationDidFinishLaunching`) and `AppDelegate+MainMenu.swift` (`installAppMenu`) |
| `[updates] check_automatically` | `Source/Core/Preferences` (`Key::UpdatesCheckAutomatically`, `Effective::shouldCheckForUpdatesAutomatically`) |
| Settings ▸ Software Update | `Source/Platform/macOS/App/SettingsCatalog.swift` (`softwareUpdateCategories`) |
| `SUFeedURL` + `SUPublicEDKey` + the schedule keys | `Source/Platform/macOS/Info.plist.in` (the template the build fills in) |
| The relaunch notice, the quit it decides, and the one launch that restores it | `Updater.swift` (`isRelaunchingForUpdate`), `AppDelegate.swift` (`quitReason`), `Source/Platform/macOS/App/Windowing/TerminalWindows.swift` (`terminationReply`, `restoreLaunchArrangement`), `Source/Platform/macOS/App/Application/SessionLayout.swift` (`takeLayoutForLaunch`), `Source/Core/Session/RestorePlan.h` (`isSessionKeptByQuit`) |
| CMake gate `UBIQUITTY_SPARKLE` (link + embed) | `Source/Platform/macOS/CMakeLists.txt` |
| Fetch the pinned prebuilt framework + tools | `Scripts/fetch-sparkle.sh` → `$UBQ_BUILD_ROOT/sparkle` |
| Sign the framework's nested code | `Scripts/sign-sparkle.sh` (called from `build-macos.sh`) |

`Updater.swift` is the only file that imports Sparkle, and it asks
`canImport(Sparkle)` — true exactly when CMake put the framework on the Swift
compile's search path. A dev build that skipped `fetch-sparkle.sh` compiles the
other arm: `Updater.startedUpdater()` answers nil, `Updater.isAvailable` is
false, and the menu item and the Settings page are omitted, so the app builds
and runs with or without the framework. The UI scenarios in
`Source/Platform/macOS/UITest/Swift/UpdaterScenarios.swift` pin both arms: the
item and the toggle are offered exactly when the build has an updater, the
schedule follows the preference, a scheduled check that fails presents nothing,
and nothing installs without the person. A UI-test build points every check at
an address on the machine that nothing answers, so a run never reaches the
release feed.

## Build

```sh
export UBQ_BUILD_ROOT="$(python3 Scripts/build_root.py .)"
nice -n 19 ./Scripts/fetch-sparkle.sh
nice -n 19 ./Scripts/build-macos.sh
```

`fetch-sparkle.sh` writes to `$UBQ_BUILD_ROOT/sparkle`, the prefix CMake looks
in by default. To keep the framework elsewhere, give the script that prefix and
set `UBIQUITTY_SPARKLE_PREFIX` to it for `build-macos.sh`.

`build-macos.sh` signs `Sparkle.framework`'s nested code (two XPC services,
`Autoupdate`, `Updater.app`) inner-to-outer via `sign-sparkle.sh` **before**
sealing the app. We never use `codesign --deep` — it signs in the wrong order
and corrupts the XPC service signatures (Sparkle's documented footgun). The
framework is the **prebuilt** release artifact, never a source build (building
from source strips Sparkle's signing).

## Linux (AppImage)

The AppImage carries a `zsync` update URL for its architecture. **Check for
Updates…** runs the bundled updater, which downloads changed blocks, verifies
the result and replaces the AppImage. The x86_64 and ARM64 update addresses
select their own packages.

`Scripts/package-linux-appimage.sh` builds the image, embeds the update URL,
and produces its `.zsync` control file. `Scripts/build-appimage-support.sh`
builds the pinned runtime and updater with their matching source archives and
notices. The package depends on the system GTK and Vulkan libraries; see
[Linux packaging](building-and-releasing.md#package--distribute-appimage).

The desktop app's update action is implemented in
`Source/Platform/Linux/main.cpp`. It is available when the app runs from an
AppImage. A normal source build uses the distribution's installation tools.
