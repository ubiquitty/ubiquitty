#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# build-macos.sh — build the macOS frontend.
#
#   ./Scripts/build-macos.sh            optimized RelWithDebInfo (-O2 + NDEBUG) — DEFAULT
#   ./Scripts/build-macos.sh --debug    Debug build (-O0, asserts, diagnostics on)
#   ./Scripts/build-macos.sh --clean    wipe $UBQ_BUILD_ROOT/macos/ first
#   ./Scripts/build-macos.sh --run      build + launch the .app
#   ./Scripts/build-macos.sh --release  the build that is installed or shipped: the
#                                       default optimisation, under the release
#                                       bundle identifier (org.ubiquitty.Ubiquitty).
#                                       Every other build is a development build,
#                                       org.ubiquitty.Ubiquitty.dev, so it is never
#                                       a copy LaunchServices can route the
#                                       installed app's notifications or launches to.
#   ./Scripts/build-macos.sh --no-helpers  skip bundling ubiquitty-host/agent (fast app-only)
#   ./Scripts/build-macos.sh --no-linux-hosts  bundle only the native helpers
#   ./Scripts/build-macos.sh --app-name NAME  build NAME.app and show NAME in About
#   ./Scripts/build-macos.sh --asan     AddressSanitizer build (implies --debug),
#                                       into $UBQ_BUILD_ROOT/macos-asan/; prints run instructions
#   ./Scripts/build-macos.sh --unused   unused-code analysis into $UBQ_BUILD_ROOT/macos-unused/:
#                                       clang -Wunused* warnings + linker dead-strip
#                                       report + clang-tidy misc-unused (if installed)
#   ./Scripts/build-macos.sh --release-signing
#                                       sign for DISTRIBUTION: auto-detects the
#                                       "Developer ID Application" identity and
#                                       signs everything with the hardened
#                                       runtime + a secure timestamp (the
#                                       notarization prerequisites). Errors out
#                                       if no Developer ID certificate is
#                                       installed. Pair with
#                                       Scripts/notarize-macos.sh to produce a
#                                       shareable, Gatekeeper-clean build.
#                                       Implies the release bundle identifier.
#
# Bundles the ubiquitty-host daemon + ubq MCP server into the .app's
# Contents/Helpers by default (lock-step build), where an MCP client can
# register them. --no-helpers skips that for a quick app-only rebuild.
#
# Output: $UBQ_BUILD_ROOT/macos/Source/Platform/macOS/<app-name>.app

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs; see CMakeLists.txt.
CORE_ROOT="${UBIQUITTY_CORE_SOURCE_DIR:-$ROOT/Libraries/ubiquitty-core}"
KIT_ROOT="${UBIQUITTY_KIT_SOURCE_DIR:-$ROOT/Libraries/ubiquitty-kit}"

# Bound the compile fan-out. `cmake --build -j` with no number hands ninja its
# default of cores + 2, and several checkouts may build on one machine at
# once, so the unbounded form asks for far more processes than there are cores
# and the machine stops responding.
# How many compilers this machine can run at once; see Scripts/build-jobs.sh.
# shellcheck source=Scripts/build-jobs.sh
. "$CORE_ROOT/Scripts/build-jobs.sh"
BUILD_JOBS="$(ubq_build_jobs)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
# Build dir + extra configure args are overridable (run-ui-tests.sh points at a
# separate $UBQ_BUILD_ROOT/macos-uitest with -DUBIQUITTY_UI_TESTS=ON). Default: the normal build.
CLEAN=0
RUN=0
ASAN=0
UNUSED=0
RELEASE_SIGNING=0             # --release-signing: Developer ID + hardened runtime
# Bundle ubiquitty-host + ubq into the .app. Env twin of
# --no-helpers for callers that can't pass flags (the external bench harness
# invokes each commit's script bare); the host FORCES QUIC ON by design
# (build-host.sh), so skipping helpers is what makes a UBIQUITTY_QUIC=OFF
# bench build fully fetch-free. Shipping default unchanged.
HELPERS_BUNDLE="${UBIQUITTY_HELPERS:-1}"
LINUX_HOSTS_BUNDLE="${UBIQUITTY_LINUX_HOSTS:-1}"
BUILD_TYPE="RelWithDebInfo"   # release by default; --debug opts in to Debug
BUNDLE_IDENTITY="development" # --release / --release-signing: the installed or shipped app
BUILD_DIR_OVERRIDE="${UBIQUITTY_BUILD_DIR:-}" # explicit dir wins over the --asan default
APP_NAME="${UBIQUITTY_APP_NAME:-Ubiquitty}"
while [ $# -gt 0 ]; do
    case "$1" in
        --clean)       CLEAN=1 ;;
        --run)         RUN=1 ;;
        --no-helpers)  HELPERS_BUNDLE=0 ;;  # skip helper build/bundle (fast app-only iteration)
        --no-linux-hosts) LINUX_HOSTS_BUNDLE=0 ;;
        --release)     BUILD_TYPE="RelWithDebInfo"; BUNDLE_IDENTITY="release" ;;
        --release-signing) RELEASE_SIGNING=1; BUNDLE_IDENTITY="release" ;;  # Developer ID + hardened runtime (distribution)
        --debug)       BUILD_TYPE="Debug" ;;
        --asan)        ASAN=1; BUILD_TYPE="Debug" ;;  # sanitize; Debug for clean traces
        --unused)      UNUSED=1 ;;   # unused-code analysis; report only, app not runnable
        --app-name|--name)
            opt="$1"
            shift
            if [ $# -eq 0 ]; then
                echo "$opt requires a name" >&2
                exit 2
            fi
            APP_NAME="$1"
            ;;
        --app-name=*)  APP_NAME="${1#--app-name=}" ;;
        --name=*)      APP_NAME="${1#--name=}" ;;
        -h|--help)
            sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# --asan and --unused both claim the global CMake flag variables; combining
# them would silently drop one set, so refuse.
if [ "$ASAN" = "1" ] && [ "$UNUSED" = "1" ]; then
    echo "--asan and --unused are mutually exclusive" >&2
    exit 2
fi

# Resolve the build dir: an explicit UBIQUITTY_BUILD_DIR always wins; otherwise
# --asan / --unused get their own trees so they never clobber the normal
# optimized build.
if [ -n "$BUILD_DIR_OVERRIDE" ]; then
    BUILD="$BUILD_DIR_OVERRIDE"
elif [ "$ASAN" = "1" ]; then
    BUILD="$UBQ_BUILD_ROOT/macos-asan"
elif [ "$UNUSED" = "1" ]; then
    BUILD="$UBQ_BUILD_ROOT/macos-unused"
else
    BUILD="$UBQ_BUILD_ROOT/macos"
fi

if [ -z "$APP_NAME" ]; then
    echo "app name must not be empty" >&2
    exit 2
fi
case "$APP_NAME" in
    *[/:]*)
        echo "app name must not contain '/' or ':'" >&2
        exit 2
        ;;
esac

if ! xcrun -f metal >/dev/null 2>&1; then
    echo "xcrun can't find 'metal'. Run:" >&2
    echo "  xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi

# Pin the sysroot to the SDK the ACTIVE toolchain resolves.
# Scripts/cmake/UbiquittyPreProject.cmake auto-resolves CMAKE_OSX_SYSROOT only when the cached value is unset or its
# directory no longer exists — but a switch of the selected toolchain (e.g.
# `xcode-select` moving from CommandLineTools to Xcode.app) leaves both SDK dirs
# present, so a cache baked against the old one survives. CMake then reconfigures
# with a SPLIT SDK: framework search (-F) tracks the current xcrun toolchain while
# -isysroot stays the stale cached SDK. Mismatched, Apple's own frameworks lose
# system-header status, and their deprecated typedefs (ApplicationServices ▸
# QD.framework ▸ ColorSyncDeprecated.h) flood -Wdeprecated-declarations, failing
# -Werror. Passing the freshly-resolved SDK on the configure line overrides any
# stale cache every run; UbiquittyPreProject.cmake treats a caller-supplied valid
# sysroot as authoritative, so this composes with it rather than fighting it. UBIQUITTY_CMAKE_EXTRA
# comes last on the cmake line, so an explicit caller override still wins.
SDK_ARGS=()
if MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" && [ -d "$MACOS_SDK" ]; then
    SDK_ARGS=("-DCMAKE_OSX_SYSROOT=$MACOS_SDK")
fi

# Stale-artifact guard for the PAL base layer. The macOS incremental build does
# not rebuild every dependent of a change to a widely-included PAL base type:
# adding a virtual to PAL::Stream left a warm build producing an app
# that failed --smoke-surface ("shell declined to launch") while a clean build
# passed — a stale C++ artifact (an archive not relinked, or a POST_BUILD copy).
# The interop stamp (cmake/SwiftInteropStamp.cmake) rebuilds the Swift modules on
# a PAL header edit and reaches no C++ artifact. The exact artifact is unproven,
# so this forces a full clean rather than dropping a named output. Keyed on the
# CONTENT of Source/PAL/*.h, which change rarely for a base layer, so the clean
# build fires seldom — where fingerprinting all of Core would tax every macOS
# build for a bug only a base-type change causes. A missing fingerprint (the
# first build after this landed) records and does not force, so it costs nobody
# a rebuild for a staleness they may not have; a real base-type edit after that
# is what trips it.
PAL_FINGERPRINT_FILE="$BUILD/.pal-fingerprint-sha256"
PAL_FINGERPRINT="$(cat "$CORE_ROOT"/Source/PAL/*.h 2>/dev/null | shasum -a 256 | cut -d' ' -f1 || true)"
PAL_CHANGED=0
if [ -n "$PAL_FINGERPRINT" ] && [ -f "$PAL_FINGERPRINT_FILE" ] \
        && [ "$PAL_FINGERPRINT" != "$(cat "$PAL_FINGERPRINT_FILE" 2>/dev/null)" ]; then
    PAL_CHANGED=1
fi
if [ "$PAL_CHANGED" = "1" ] && [ "$CLEAN" != "1" ]; then
    echo "build-macos.sh: a Source/PAL base type changed since the last build of $BUILD — forcing a clean build (stale-artifact guard)."
    CLEAN=1
fi

[ "$CLEAN" = "1" ] && rm -rf "$BUILD"

# The bundled helpers (ubiquitty-host, ubq) link the same PAL but
# build in $UBQ_BUILD_ROOT/host and $UBQ_BUILD_ROOT/agent — separate directories the clean above
# never reaches. build-host.sh's incremental build can keep a helper from before
# a PAL ABI change, which build-macos.sh then copies into Contents/Helpers, where
# it masks the change the same way a stale app object would; that is the hazard
# the lock-step helper build (below) exists to avoid. Drop both on any PAL change,
# not only when this run set CLEAN, so an explicit --clean across a PAL edit
# reaches them too; build-host.sh and build-agent.sh then relink from source.
if [ "$PAL_CHANGED" = "1" ]; then
    rm -rf "$UBQ_BUILD_ROOT/host" "$UBQ_BUILD_ROOT/agent"
fi

# The macOS frontend mixes Swift with C++ in one target. CMake only drives the Swift compiler under the Ninja
# or Xcode generators — the default "Unix Makefiles" generator rejects
# Swift — so we require Ninja here.
if ! command -v ninja >/dev/null 2>&1; then
    echo "ninja not found — required for the Swift-enabled macOS build." >&2
    echo "  Install with: brew install ninja" >&2
    exit 1
fi

# AddressSanitizer across C/C++ (-fsanitize=address), Swift (-sanitize=address),
# and the link (so the asan runtime dylib is embedded). One sanitizer for the whole
# app — a partial build would mismatch the runtime.
SAN_ARGS=()
if [ "$ASAN" = "1" ]; then
    SAN_ARGS=(
        "-DCMAKE_C_FLAGS=-fsanitize=address"
        "-DCMAKE_CXX_FLAGS=-fsanitize=address"
        "-DCMAKE_Swift_FLAGS=-sanitize=address"
        "-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address"
    )
fi

# Unused-code analysis (--unused). Three independent detectors:
#   1. clang warnings — internal-linkage code the compiler can prove unused
#      within one TU (static functions, private fields, dead statements).
#   2. Linker dead-strip — cross-TU: -ffunction-sections gives every function
#      its own section, -dead_strip drops unreferenced ones, and -map records
#      them under "# Dead Stripped Symbols:". Catches "defined in A.cpp,
#      called from nowhere", which the compiler alone cannot see.
#   3. clang-tidy misc-unused-* over compile_commands.json (run after the
#      build, below) — using-decls, aliases, parameters.
# Caveats on tier 2: ObjC methods (reached via selectors), virtuals (kept by
# vtables), and exported symbols never strip — treat output as candidates.
# The dead-strip/-map link flags live in the macOS CMakeLists behind
# UBIQUITTY_UNUSED_ANALYSIS: the app links through swiftc, whose CMake link
# rule ignores CMAKE_EXE_LINKER_FLAGS, so they must be target options.
LINK_MAP="$BUILD/link.map"
UNUSED_ARGS=()
if [ "$UNUSED" = "1" ]; then
    UNUSED_WARN_FLAGS="-Wunused -Wunused-function -Wunneeded-internal-declaration \
-Wunused-private-field -Wunused-member-function -Wunused-template -Wunreachable-code \
-ffunction-sections -fdata-sections"
    UNUSED_ARGS=(
        "-DCMAKE_C_FLAGS=$UNUSED_WARN_FLAGS"
        "-DCMAKE_CXX_FLAGS=$UNUSED_WARN_FLAGS"
        "-DUBIQUITTY_UNUSED_ANALYSIS=ON"
    )
fi

# RelWithDebInfo keeps the dSYM flow but its CMake default is -O2; the parser
# and emit hot loops prefer -O3, which the bundled host daemon already ships
# as Release. Override the config flags so the app Core gets the same
# treatment; -g and NDEBUG unchanged.
#
# UBIQUITTY_QUIC=OFF skips the QUIC TLS deps fetch+build (network + minutes
# per fresh tree). Shipping builds keep the ON default; the external bench
# harness (a ubench checkout) builds one fresh tree per swept commit and QUIC
# contributes nothing to what it measures.
#
# PGO: when the checked-in training profile exists, feed it to every C-family TU
# (-fprofile-use), on top of -O3+ThinLTO. The two -Wno flags are the tolerance
# contract: TUs the training battery never executes (platform sources,
# third-party), functions that drifted since the last retrain, and same-name CFG
# mismatches (the trainer's bench main vs the app main) compile clean at plain
# -O3 placement instead of erroring — clang discards mismatched counts, and
# -Wbackend-plugin under this target's -Werror would otherwise turn that note
# into a build failure. Regenerate with Scripts/pgo-train.sh (its own commit).
# UBIQUITTY_PGO=OFF is the A/B escape hatch and must keep producing the pre-PGO
# flag set exactly. It reaches CMake as the UBIQUITTY_PGO cache variable too:
# with the flags below empty, Scripts/cmake/UbiquittyOptimize.cmake otherwise
# places the default profile itself, and a cache variable is not seeded from the
# environment. UBQ_PGO_PROFILE, as in run-bench.sh and build-perf-bench.sh: an
# A/B that has to swap the tracked artifact in and out of Support/pgo/ loses an
# arm to the next branch switch.
PGO_PROFILE="${UBQ_PGO_PROFILE:-$CORE_ROOT/Support/pgo/portable-core.profdata}"
# shellcheck source=Scripts/pgo-flags.sh
source "$CORE_ROOT/Scripts/pgo-flags.sh"
# A leading space: the flag string is concatenated into a longer one below.
PGO_FLAGS="$(ubiquitty_pgo_flags "$CORE_ROOT" "${CMAKE_CXX_COMPILER:-c++}")"
PGO_FLAGS="${PGO_FLAGS:+ $PGO_FLAGS}"
if [ -n "$PGO_FLAGS" ]; then
    # shellcheck source=Scripts/pgo-staleness.sh
    source "$CORE_ROOT/Scripts/pgo-staleness.sh"
    pgo_staleness_warning "$CORE_ROOT" "${PGO_PROFILE#"$CORE_ROOT"/}"
fi
# Swift PGO: a separate profile from a separate corpus. The C-family profile
# trains on bench_stack, which links no Swift; the Swift renderer's counters
# can only come from the app binary (Scripts/pgo-train-swift.sh). Swift's
# -profile-use is front-end instrumentation and clang's shipping profile is
# IR-level — one merged file would be legal on this toolchain but would tie
# the two corpora's staleness together for no gain. The stamp rides as an
# inert conditional-compilation flag for the same ninja reason as the C++
# define: a retrain must change every consuming command line. A missed
# function prints `no profile data available` from swiftc — unsuppressed,
# and -Werror here scopes to the C family, so it warns without failing.
# Opt-in, not automatic: this swiftc (6.3.2) can abort the RenderKit compile
# under -profile-use — an assertion in ColdBlockInfo::analyze inside the
# SILPerformanceInliner, tripped or not by the exact counter values a given
# training run produced. One profile compiles clean, the next retrain aborts
# every build. Until the toolchain holds, a trained profile on disk must not
# decide by itself; UBIQUITTY_SWIFT_PGO=ON is the informed consent.
SWIFT_PGO_PROFILE="${UBQ_SWIFT_PGO_PROFILE:-$ROOT/Support/pgo/swift-renderkit.profdata}"
SWIFT_PGO_FLAGS=""
if [ -f "$SWIFT_PGO_PROFILE" ] && [ "${UBIQUITTY_SWIFT_PGO:-OFF}" = "ON" ] && [ "${UBIQUITTY_PGO:-ON}" != "OFF" ]; then
    SWIFT_PGO_STAMP="$(shasum -a 256 "$SWIFT_PGO_PROFILE" | cut -c1-16)"
    SWIFT_PGO_FLAGS="-profile-use=$SWIFT_PGO_PROFILE -DUBIQUITTY_SWIFT_PGO_STAMP_$SWIFT_PGO_STAMP"
    echo "Swift PGO:  using $SWIFT_PGO_PROFILE (UBIQUITTY_PGO=OFF to disable)"
    # shellcheck source=Scripts/pgo-staleness.sh
    source "$CORE_ROOT/Scripts/pgo-staleness.sh"
    pgo_staleness_warning "$ROOT" "${SWIFT_PGO_PROFILE#"$ROOT"/}"
fi
# shellcheck source=Scripts/build-provenance.sh
source "$CORE_ROOT/Scripts/build-provenance.sh"
build_provenance_warning "$ROOT" "$BUILD" "Scripts/build-macos.sh --clean"
# The installed or shipped identity carries the updater. Without the framework
# CMake builds an app with no updater and says so only in a configure status
# line, and an installed copy without one never hears of a release. So the
# release identity fetches the pinned framework into
# the prefix CMake reads; a development build still leaves it to the caller.
if [ "$BUNDLE_IDENTITY" = "release" ]; then
    "$ROOT/Scripts/fetch-sparkle.sh" "${UBIQUITTY_SPARKLE_PREFIX:-$UBQ_BUILD_ROOT/sparkle}" || exit 1
fi
# The QUIC dependencies' prefix: CMake's default is this checkout's build root,
# the prefix the bundled helpers build against too, so the app and its helpers
# share one AWS-LC and ngtcp2. UBIQUITTY_QUIC_PREFIX names another, for a CI
# job whose prefix outlives the build root. Sparkle's prefix works the same
# way: CMake defaults to the build root's sparkle directory, where
# fetch-sparkle.sh writes, and UBIQUITTY_SPARKLE_PREFIX names another.
cmake -B "$BUILD" -S "$ROOT" -G Ninja -DUBIQUITTY_FRONTEND=macOS \
    "-DUBIQUITTY_CORE_SOURCE_DIR=$CORE_ROOT" "-DUBIQUITTY_KIT_SOURCE_DIR=$KIT_ROOT" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    ${UBIQUITTY_QUIC_PREFIX:+"-DUBIQUITTY_QUIC_PREFIX=$UBIQUITTY_QUIC_PREFIX"} \
    ${UBIQUITTY_SPARKLE_PREFIX:+"-DUBIQUITTY_SPARKLE_PREFIX=$UBIQUITTY_SPARKLE_PREFIX"} \
    "-DCMAKE_CXX_FLAGS_RELWITHDEBINFO=-O3 -g -DNDEBUG$PGO_FLAGS" \
    "-DCMAKE_C_FLAGS_RELWITHDEBINFO=-O3 -g -DNDEBUG$PGO_FLAGS" \
    "-DUBIQUITTY_SWIFT_PGO_FLAGS=$SWIFT_PGO_FLAGS" \
    "-DUBIQUITTY_PGO=${UBIQUITTY_PGO:-ON}" \
    -DUBIQUITTY_QUIC="${UBIQUITTY_QUIC:-ON}" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    "-DUBIQUITTY_APP_NAME=$APP_NAME" \
    "-DUBIQUITTY_BUNDLE_IDENTITY=$BUNDLE_IDENTITY" \
    ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} \
    ${SAN_ARGS[@]+"${SAN_ARGS[@]}"} \
    ${UNUSED_ARGS[@]+"${UNUSED_ARGS[@]}"} \
    ${UBIQUITTY_CMAKE_EXTRA:-}
# The default build's database is the one clangd reads; an --asan, --unused or
# UBIQUITTY_BUILD_DIR tree is a variant and does not claim the checkout's link.
[ "$BUILD" = "$UBQ_BUILD_ROOT/macos" ] && ubq_link_compile_database "$BUILD" "$ROOT"

echo "Build type: $BUILD_TYPE"
[ "$ASAN" = "1" ] && echo "Sanitizer:  AddressSanitizer"
[ "$UNUSED" = "1" ] && echo "Mode:       unused-code analysis"
echo "App name:   $APP_NAME"
if [ "$UNUSED" = "1" ]; then
    # tee the compile output so the -Wunused* warnings can be summarized
    # below; pipefail keeps a build failure fatal through the pipe.
    cmake --build "$BUILD" -j"$BUILD_JOBS" 2>&1 | tee "$BUILD/unused-build.log"
else
    cmake --build "$BUILD" -j"$BUILD_JOBS"
fi
build_provenance_stamp "$ROOT" "$BUILD"

# Record the PAL base-layer content this build was made against, for the
# stale-artifact guard above. set -e means a failed build exited before here, so
# this only stamps a build that succeeded.
if [ -n "$PAL_FINGERPRINT" ]; then
    printf '%s\n' "$PAL_FINGERPRINT" > "$PAL_FINGERPRINT_FILE"
fi

# --unused: emit the three reports and stop. The analysis app skips shader
# compilation, signing, and helper bundling — it is not meant to be launched.
if [ "$UNUSED" = "1" ]; then
    echo
    echo "=== Unused-code report ==============================================="

    # 1. Compiler warnings (per-TU, internal linkage). Vendored code under
    # Source/ThirdParty is reported separately — not ours to clean up. Only
    # freshly compiled TUs warn, so an incremental build under-reports;
    # guard every grep with `|| true` — no match is not an error (pipefail).
    WARN_TXT="$BUILD/unused-warnings.txt"
    WARN_3P_TXT="$BUILD/unused-warnings-thirdparty.txt"
    WARN_ALL="$({ grep -E 'warning: .*\[-W(unused|unneeded|unreachable)[a-z-]*\]' \
        "$BUILD/unused-build.log" || true; } | sort -u)"
    { printf '%s\n' "$WARN_ALL" | grep -v '/ThirdParty/' || true; } | sed '/^$/d' > "$WARN_TXT"
    { printf '%s\n' "$WARN_ALL" | grep '/ThirdParty/' || true; } > "$WARN_3P_TXT"
    echo
    echo "-- 1. clang -Wunused* warnings: $(wc -l < "$WARN_TXT" | tr -d ' ') (full list: $WARN_TXT)"
    echo "   (+ $(wc -l < "$WARN_3P_TXT" | tr -d ' ') in Source/ThirdParty: $WARN_3P_TXT)"
    echo "   (incremental builds only scan freshly compiled TUs — use --clean for a full sweep)"
    head -40 "$WARN_TXT"

    # 2. Linker dead-strip (cross-TU). Map lines look like:
    #    <<dead>>  0x00000028  [  3] __ZN4Grid9oldHelperEv
    # Drop data junk (string literals, ObjC metadata, EH tables) and demangle.
    # LC_ALL=C: dead string literals carry arbitrary bytes, which BSD
    # sed/grep reject as invalid UTF-8 under the default locale.
    DEAD_TXT="$BUILD/unused-symbols.txt"
    if [ -f "$LINK_MAP" ] && LC_ALL=C grep -q '^# Dead Stripped Symbols:' "$LINK_MAP"; then
        LC_ALL=C sed -n 's/^<<dead>>[[:space:]]*[^[:space:]]*[[:space:]]*\[ *[0-9]*\] *//p' "$LINK_MAP" \
            | LC_ALL=C grep -vE '^(literal string:|CFString|l_|ltmp|L_|GCC_except_table|__OBJC_|_OBJC_|objc-cat-list|anon\.|[0-9]+-byte-literal)' \
            | LC_ALL=C grep -vE '\.cold\.[0-9]+$' \
            | c++filt | xcrun swift-demangle 2>/dev/null | sort -u > "$DEAD_TXT" || true
        echo
        echo "-- 2. dead-stripped symbols: $(wc -l < "$DEAD_TXT" | tr -d ' ') (full list: $DEAD_TXT)"
        echo "   (candidates only — ObjC methods, virtuals, and exported symbols never strip)"
        head -40 "$DEAD_TXT"
    else
        echo
        echo "-- 2. dead-strip report unavailable: no '# Dead Stripped Symbols:' section"
        echo "   in $LINK_MAP (linker too old or map not written)."
    fi

    # 3. clang-tidy misc-unused over the exported compile_commands.json.
    #    Xcode's toolchain does not ship clang-tidy; use brew llvm if present.
    RUN_TIDY="$(command -v run-clang-tidy || true)"
    if [ -z "$RUN_TIDY" ]; then
        for prefix in /opt/homebrew/opt/llvm /usr/local/opt/llvm; do
            [ -x "$prefix/bin/run-clang-tidy" ] && { RUN_TIDY="$prefix/bin/run-clang-tidy"; break; }
        done
    fi
    echo
    if [ -n "$RUN_TIDY" ]; then
        TIDY_TXT="$BUILD/unused-tidy.txt"
        echo "-- 3. clang-tidy misc-unused (this can take a few minutes) ..."
        "$RUN_TIDY" -p "$BUILD" -quiet \
            -checks='-*,misc-unused-using-decls,misc-unused-alias-decls,misc-unused-parameters,readability-redundant-declaration' \
            "$ROOT/Source/.*" 2>/dev/null \
            | grep -E 'warning:' | sort -u > "$TIDY_TXT" || true
        echo "   findings: $(wc -l < "$TIDY_TXT" | tr -d ' ') (full list: $TIDY_TXT)"
        head -40 "$TIDY_TXT"
    else
        echo "-- 3. clang-tidy not found — skipped. Install with: brew install llvm"
    fi

    echo
    echo "Reports in $BUILD/: unused-warnings.txt, unused-symbols.txt$([ -n "$RUN_TIDY" ] && echo ', unused-tidy.txt')"
    [ "$RUN" = "1" ] && echo "NOTE: --run ignored — the --unused build is unsigned and has no shaders."
    exit 0
fi

APP="$BUILD/Source/Platform/macOS/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"
echo
echo "Built: $APP"

# The renderer is useless without compiled shaders, but CMake's Metal step is
# non-fatal — it skips the metallib (its toolchain probe differs from the SDK
# `metal` that xcrun resolves, and it swallows shader-compile errors) and the
# app still links, silently shipping a blank-rendering build. So if the
# metallib isn't present, compile it directly via xcrun: this both fills the
# CMake gap and makes a SHADER COMPILE ERROR a hard build failure. Runs before
# signing so the resource is covered by the signature.
METALLIB="$APP/Contents/Resources/default.metallib"
# The checkout a source root names: the one this build was configured with, or
# this tree, the root CMake takes when the configure names none. CMake resolves
# a relative root against this tree.
configured_source_root() { # <UBIQUITTY_CORE_SOURCE_DIR | UBIQUITTY_KIT_SOURCE_DIR>
    local root
    root="$(sed -n "s/^$1:[A-Z]*=//p" "$BUILD/CMakeCache.txt" 2>/dev/null)"
    case "$root" in
        "") printf '%s\n' "$ROOT" ;;
        /*) printf '%s\n' "$root" ;;
        *) printf '%s\n' "$ROOT/$root" ;;
    esac
}
SHADER="$(configured_source_root UBIQUITTY_KIT_SOURCE_DIR)/Source/UbiquittyRenderKit/UBShaders.metal"
# The shader includes Core's Tek raster by its path under Core's Source root.
SHADER_INCLUDES="$(configured_source_root UBIQUITTY_CORE_SOURCE_DIR)/Source"
# always recompile the metallib via xcrun. CMake's Metal step is unreliable (it
# silently skips / leaves a stale metallib) and `cmake --build` touches the
# bundle metallib so its mtime ends up NEWER than the shader — which would defeat
# an `-nt` guard and silently ship a stale shader (e.g. a new shapeKind
# branch missing → wrong renders). The xcrun compile is cheap, so run it
# unconditionally: the .metal source is the single source of truth.
if true; then
    echo "Compiling default.metallib via xcrun metal ..."
    # Version-min matches the app's CMAKE_OSX_DEPLOYMENT_TARGET
    # (Scripts/cmake/UbiquittyPreProject.cmake): without it the metal compiler targets the newest Metal
    # language version and the metallib refuses to load on older macOS.
    MACOS_MIN="${UBIQUITTY_MACOS_MIN:-"$(sed -n 's/^cxx=//p' "$CORE_ROOT/Scripts/macos-deployment-target.txt")"}"
    AIR="$(mktemp -t mtshaders.XXXXXX).air"
    if ! xcrun -sdk macosx metal -mmacosx-version-min="$MACOS_MIN" -O3 -I "$SHADER_INCLUDES" \
            -c "$SHADER" -o "$AIR"; then
        echo "ERROR: Metal shader compile failed: $SHADER" >&2
        rm -f "$AIR"; exit 1
    fi
    if ! xcrun -sdk macosx metallib "$AIR" -o "$METALLIB"; then
        echo "ERROR: metallib link failed." >&2
        rm -f "$AIR"; exit 1
    fi
    rm -f "$AIR"
fi
[ -f "$METALLIB" ] || { echo "ERROR: default.metallib missing — render would be blank." >&2; exit 1; }
echo "Shaders: default.metallib present."

# RelWithDebInfo emits DWARF into the per-TU .o files; the linked binary
# only references them via a debug map, which Instruments can't follow once
# the .app is copied or re-signed. Collect the DWARF into a .dSYM bundle so
# Time Profiler / counters traces symbolicate to file:line and inlined frames.
#
# dsymutil's diagnostics are the only signal that an object named by the debug
# map was missing at collection time, and a dSYM that covers a subset of the
# binary looks identical to a complete one from the outside — the frames it
# does not cover resolve to a symbol name and no source. They stay on stderr.
# The C-family check below is the positive assertion: the Swift units compile
# to real objects and are collected whatever happens to the LTO ones, so a dSYM
# holding only .swift compile units is the shape a lost LTO object tree takes.
if [ "$BUILD_TYPE" = "RelWithDebInfo" ]; then
    if dsymutil "$BIN" -o "$APP.dSYM"; then
        DWARF_BIN="$APP.dSYM/Contents/Resources/DWARF/$APP_NAME"
        # `|| true` absorbs the SIGPIPE dwarfdump takes when grep -q stops
        # reading at the first match: under pipefail that status would reach
        # the `if` and read as "no C-family units" on a dSYM that has them.
        if { dwarfdump --debug-info "$DWARF_BIN" 2>/dev/null || true; } \
                | grep -qE 'DW_AT_name.*\.(cpp|c)"'; then
            echo "dSYM:  $APP.dSYM — Instruments symbolication ready."
        else
            echo "WARNING: $APP.dSYM carries no C-family compile units; C++" >&2
            echo "         frames will show disassembly instead of source. The LTO" >&2
            echo "         objects the debug map names are missing — check that the" >&2
            echo "         link ran with -object_path_lto (Source/Platform/macOS/CMakeLists.txt)." >&2
        fi
    else
        echo "WARNING: dsymutil failed; Instruments traces may show raw addresses." >&2
    fi
fi

# App icon: compile Resources/Icon/Ubiquitty.icon (Icon Composer document) into the
# bundle. actool emits Assets.car (Liquid Glass, macOS 26+) plus a Ubiquitty.icns
# raster fallback for older systems; Info.plist's CFBundleIconName/CFBundleIconFile
# name them. Runs before signing so the icon is covered by the signature.
ICON_SRC="$ROOT/Resources/Icon/Ubiquitty.icon"
if [ -d "$ICON_SRC" ]; then
    ICON_PLIST="$(mktemp)"
    if xcrun actool --app-icon Ubiquitty \
            --compile "$APP/Contents/Resources" \
            --platform macosx --minimum-deployment-target 26.0 \
            --output-partial-info-plist "$ICON_PLIST" \
            "$ICON_SRC" >/dev/null 2>&1; then
        echo "Icon:  compiled Ubiquitty.icon (Assets.car + Ubiquitty.icns)"
    else
        echo "WARNING: actool failed on $ICON_SRC; bundle has no custom icon." >&2
    fi
    rm -f "$ICON_PLIST"
else
    echo "Icon:  $ICON_SRC not found — skipping (default icon)."
fi

# Code-sign the bundle. macOS TCC keys folder-access grants (Documents,
# Downloads, Desktop, …) to the app's code identity. An ad-hoc signature has
# no Designated Requirement, so TCC falls back to the cdhash — which changes
# on every relink — and the grants never persist: macOS re-prompts each
# rebuild. Signing with a STABLE identity (even a self-signed code-signing
# cert) gives a constant DR, so a grant survives rebuilds.
#   • Export UBIQUITTY_SIGN_IDENTITY="<cert name>" to force a specific identity.
#   • Export UBIQUITTY_SIGN_IDENTITY=ad-hoc to sign ad-hoc even where an identity
#     exists — a CI runner whose login keychain is locked to non-interactive
#     sessions holds "Ubiquitty Dev" and cannot use it (errSecInternalComponent).
#   • Otherwise a cert named "Ubiquitty Dev" is used automatically if present.
#   • Falls back to ad-hoc (works, but no grant persistence).
# One-time self-signed cert: ./Scripts/make-signing-cert.sh (or Keychain Access
# ▸ Certificate Assistant ▸ Create a Certificate… → name "Ubiquitty Dev", Identity
# Type "Self Signed Root", Certificate Type "Code Signing").
# Bundle the headless helpers into Contents/Helpers so the .app is self-contained:
# an MCP client registers Contents/Helpers/ubq as a stdio MCP server, with
# UBIQUITTY_HOST_BIN → Contents/Helpers/ubiquitty-host (which the agent
# auto-starts). Build them lock-step with the app (they share
# Core/Sync — a stale helper would silently mask a protocol change). Signed below,
# individually, before the app signature seals the bundle. --no-helpers skips it.
if [ "$HELPERS_BUNDLE" = "1" ]; then
    HELPER_ARGS=""
    [ "$BUILD_TYPE" = "Debug" ] && HELPER_ARGS="--debug"
    echo "Building bundled helpers (ubiquitty-host, ubq) ..."
    # Each helper's build shows as it runs, each line under the helper's name,
    # and is kept in a log beside its build tree: on a failure the log's end is
    # printed again, so the error is the last thing on screen rather than
    # whatever a later step said.
    build_helper() { # <name> <script>
        local name="$1"
        local log="$UBQ_BUILD_ROOT/$1-build.log"
        local script="$2"
        shift 2
        mkdir -p "$UBQ_BUILD_ROOT"
        if ! "$CORE_ROOT/Scripts/$script" "$@" 2>&1 | tee "$log" | awk -v name="$name" '{ print name ": " $0; fflush() }'; then
            echo "ERROR: $script failed; the end of its log ($log):" >&2
            tail -n 40 "$log" >&2
            exit 1
        fi
    }
    # A Developer ID build's host trusts only the release team's code
    # signature (Source/Platform/Host/SignaturePolicy.h); any other trusts
    # the files it was installed as, too, as it runs unsigned or ad hoc.
    if [ "$RELEASE_SIGNING" = "1" ]; then
        export UBIQUITTY_RELEASE_SIGNING=ON
    else
        export UBIQUITTY_RELEASE_SIGNING="${UBIQUITTY_RELEASE_SIGNING:-OFF}"
    fi
    build_helper ubiquitty-host build-host.sh $HELPER_ARGS
    build_helper ubq build-agent.sh $HELPER_ARGS
    HELPERS_DIR="$APP/Contents/Helpers"
    mkdir -p "$HELPERS_DIR"
    cp -f "$UBQ_BUILD_ROOT/host/ubiquitty-host" "$HELPERS_DIR/ubiquitty-host"
    cp -f "$UBQ_BUILD_ROOT/agent/ubq" "$HELPERS_DIR/ubq"
    # Record what went in, so a later --no-helpers rebuild can say whether the
    # pair still matches. Nothing else carries it: a helper loses its provenance
    # at the copy, and the bundle it lands in is signed and launchable either way.
    build_provenance_record_bundled "$ROOT" "$BUILD"
    echo "Helpers: bundled ubiquitty-host + ubq into Contents/Helpers"

    # Linux executables are sealed resources, copied over SSH rather than run here.
    CROSS_DIR="$UBQ_BUILD_ROOT/host-cross"
    RES_DIR="$APP/Contents/Resources"
    mkdir -p "$RES_DIR"
    if [ "$LINUX_HOSTS_BUNDLE" = "1" ]; then
        build_helper linux-hosts build-host-linux.sh
        for arch in x86_64 arm64; do
            cross="ubiquitty-host-linux-$arch"
            cp -f "$CROSS_DIR/$cross" "$RES_DIR/$cross"
            echo "Resources: bundled $cross for auto-deploy"
        done
    else
        rm -f "$RES_DIR/ubiquitty-host-linux-x86_64" "$RES_DIR/ubiquitty-host-linux-arm64"
    fi
else
    # Skipping the helper build leaves whatever the last build put there, which
    # is a different commit as soon as one has passed. The app is rebuilt and the
    # helpers are not, so the bundle holds two sides of anything that moved in
    # Core or the sync protocol — and it signs, launches and smokes exactly like
    # a matched one.
    build_provenance_warn_bundled "$ROOT" "$BUILD" "$APP"
fi

# The Swift compile drops a depfile (Ubiquitty.d) and a stray Ubiquitty.dSYM into
# Contents/MacOS/. codesign treats every file there as a nested code object and
# rejects the non-Mach-O ones, so strip them before signing — only the
# executable belongs in MacOS/.
rm -f "$APP/Contents/MacOS/"*.d
rm -rf "$APP/Contents/MacOS/"*.dSYM

SIGN_ID="${UBIQUITTY_SIGN_IDENTITY:-}"
SIGN_FLAGS=()
ADHOC_REQUESTED=0
if [ "$SIGN_ID" = "ad-hoc" ]; then
    ADHOC_REQUESTED=1
    SIGN_ID=""
fi
if [ "$RELEASE_SIGNING" = "1" ]; then
    # Distribution signing: a real "Developer ID Application" identity plus the
    # two notarization prerequisites — the hardened runtime and a secure
    # timestamp. Unlike the dev path, a missing identity is a hard error: a
    # half-signed "release" build is worse than no build.
    if [ -z "$SIGN_ID" ]; then
        SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    fi
    if [ -z "$SIGN_ID" ]; then
        echo "ERROR: --release-signing needs a \"Developer ID Application\" certificate" >&2
        echo "  and none is installed. After your Apple Developer Program enrollment" >&2
        echo "  completes: Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸" >&2
        echo "  \"Developer ID Application\" (or create it at developer.apple.com ▸" >&2
        echo "  Certificates and double-click the download). Verify with:" >&2
        echo "    security find-identity -v -p codesigning | grep \"Developer ID\"" >&2
        exit 1
    fi
    case "$SIGN_ID" in
        "Developer ID Application:"*) ;;
        *)
            echo "ERROR: --release-signing requires a \"Developer ID Application:\" identity;" >&2
            echo "  got \"$SIGN_ID\" (UBIQUITTY_SIGN_IDENTITY?). Gatekeeper accepts nothing else" >&2
            echo "  for apps distributed outside the App Store." >&2
            exit 1 ;;
    esac
    SIGN_FLAGS=(--options runtime --timestamp)
elif [ -z "$SIGN_ID" ] && [ "$ADHOC_REQUESTED" = "0" ] \
        && security find-identity -v -p codesigning 2>/dev/null \
        | grep -q "Ubiquitty Dev"; then
    SIGN_ID="Ubiquitty Dev"
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="-"
fi

sign_component_failure() { # <diagnostic>
    if [ "$SIGN_ID" = "-" ]; then
        echo "ERROR: $1" >&2
        exit 1
    fi
    echo "WARNING: $1" >&2
}

# Nested Mach-O must carry its own signature before the outer app signature
# seals the completed resources, including for ad-hoc builds.
# (bash 3.2 errors on "${SIGN_FLAGS[@]}" when empty under set -u; the
# +-expansion guards that.)
# Each under its own identifier: a release's host takes as its successor and
# its relay a binary the team signed as ubiquitty-host, and nothing else the
# team signed (Source/Platform/Host/SignaturePolicy.h).
if [ "$HELPERS_BUNDLE" = "1" ] && [ -d "$APP/Contents/Helpers" ]; then
    for helper in ubiquitty-host ubq; do
        codesign --force --sign "$SIGN_ID" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} --identifier "$helper" \
            "$APP/Contents/Helpers/$helper" \
            || sign_component_failure "signing the bundled $helper failed."
    done
fi
# Sparkle.framework (if embedded) carries nested XPC services / Autoupdate /
# Updater.app that must be signed inner-to-outer before the app is sealed —
# codesign rejects unsigned nested code. No-op when Sparkle isn't bundled.
# --preserve-metadata=entitlements keeps the XPC services' shipped sandbox
# entitlements across the re-sign (Sparkle's documented hardened-runtime
# signing recipe); harmless when none are present.
"$ROOT/Scripts/sign-sparkle.sh" "$APP" "$SIGN_ID" \
    ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} --preserve-metadata=entitlements \
    || sign_component_failure "signing Sparkle.framework failed."
# A team identity gives the app a keychain access group, which the sealed
# resume record needs (Source/Platform/macOS/App/Ubiquitty.entitlements). Both
# entitlements are restricted, so they go on only with a provisioning profile
# that authorizes them: an ad-hoc or self-signed build, or a team build with no
# profile, runs without them and keeps no remote window across a restart, so a
# distributed build (--release-signing, or
# UBIQUITTY_RELEASE_SIGNING=ON) refuses to sign without one.
# UBIQUITTY_TEAM_ID names the team when the certificate does not;
# UBIQUITTY_PROVISIONING_PROFILE names the profile when the usual folders do not
# hold one for this team and bundle, and must authorize them too.
#
# An identity given as a SHA-1 hash is found among every certificate by that
# hash, since find-certificate -c matches only a name. A certificate that
# cannot be read, or that names no team, leaves TEAM_ID empty rather than
# ending the build: under pipefail the failed lookup would otherwise stop the
# script, silently, after the app is built and before it is signed.
signing_certificate_pem() {
    if [[ "$SIGN_ID" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        security find-certificate -a -Z -p 2>/dev/null | awk -v want="$(printf '%s' "$SIGN_ID" | tr 'a-f' 'A-F')" '
            /^SHA-1 hash:/ { keep = ($3 == want); next }
            keep && /BEGIN CERTIFICATE/ { inside = 1 }
            keep && inside { print }
            /END CERTIFICATE/ { if (inside) { inside = 0; keep = 0; exit } }'
    else
        security find-certificate -c "$SIGN_ID" -p 2>/dev/null
    fi
}
ENTITLEMENT_FLAGS=()
TEAM_ID="${UBIQUITTY_TEAM_ID:-}"
if [ "$SIGN_ID" != "-" ] && [ -z "$TEAM_ID" ]; then
    TEAM_ID="$(signing_certificate_pem \
        | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
        | sed -n 's/^ *organizationalUnitName *= *\([A-Z0-9]\{10\}\)$/\1/p' | head -1 || true)"
fi
if [ "$SIGN_ID" != "-" ] && [ -n "$TEAM_ID" ]; then
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
    profile_authorizes_bundle() {
        local identifier
        [ -f "$1" ] || return 1
        security cms -D -i "$1" -o "$BUILD/profile-check.plist" 2>/dev/null || return 1
        identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$BUILD/profile-check.plist" 2>/dev/null)"
        case "$identifier" in
            "$TEAM_ID.$BUNDLE_ID"|"$TEAM_ID.*") return 0 ;;
        esac
        return 1
    }
    PROFILE="${UBIQUITTY_PROVISIONING_PROFILE:-}"
    if [ -n "$PROFILE" ] && ! profile_authorizes_bundle "$PROFILE"; then
        echo "NOTE: UBIQUITTY_PROVISIONING_PROFILE=$PROFILE does not authorize $TEAM_ID.$BUNDLE_ID." >&2
        PROFILE=""
    elif [ -z "$PROFILE" ]; then
        for candidate in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.provisionprofile \
                "$HOME/Library/MobileDevice/Provisioning Profiles/"*.provisionprofile; do
            if profile_authorizes_bundle "$candidate"; then
                PROFILE="$candidate"
                break
            fi
        done
    fi
    if [ -n "$PROFILE" ]; then
        cp -f "$PROFILE" "$APP/Contents/embedded.provisionprofile"
        ENTITLEMENTS_FILE="$BUILD/Ubiquitty.entitlements"
        sed -e "s/__TEAM__/$TEAM_ID/g" -e "s/__BUNDLE__/$BUNDLE_ID/g" \
            "$ROOT/Source/Platform/macOS/App/Ubiquitty.entitlements" > "$ENTITLEMENTS_FILE"
        ENTITLEMENT_FLAGS=(--entitlements "$ENTITLEMENTS_FILE")
        echo "Entitlements: keychain access group $TEAM_ID.org.ubiquitty.Ubiquitty, under $(basename "$PROFILE")."
    elif [ "$RELEASE_SIGNING" = "1" ] || [ "${UBIQUITTY_RELEASE_SIGNING:-OFF}" = "ON" ]; then
        echo "ERROR: no provisioning profile authorizes $TEAM_ID.$BUNDLE_ID, and a distributed build needs its keychain access group." >&2
        echo "  Create a macOS profile for that identifier (or $TEAM_ID.*) with Keychain Sharing, or set UBIQUITTY_PROVISIONING_PROFILE." >&2
        exit 1
    else
        echo "NOTE: no provisioning profile authorizes $TEAM_ID.$BUNDLE_ID, so this build keeps no remote window across a restart."
        echo "  Create a macOS profile for that identifier (or $TEAM_ID.*) with Keychain Sharing, or set UBIQUITTY_PROVISIONING_PROFILE."
    fi
fi
if codesign --force --sign "$SIGN_ID" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} ${ENTITLEMENT_FLAGS[@]+"${ENTITLEMENT_FLAGS[@]}"} "$APP"; then
    if [ "$RELEASE_SIGNING" = "1" ] || [ "$SIGN_ID" = "-" ]; then
        codesign --verify --deep --strict "$APP" \
            || { echo "ERROR: bundle signature failed verification." >&2; exit 1; }
    fi
    if [ "$RELEASE_SIGNING" = "1" ]; then
        echo "Signed for distribution: \"$SIGN_ID\" (hardened runtime + timestamp)."
        echo "  Next: ./Scripts/notarize-macos.sh — notarize + staple for Gatekeeper."
    elif [ "$SIGN_ID" != "-" ]; then
        echo "Signed: \"$SIGN_ID\" — TCC folder grants persist across rebuilds."
    elif [ "$ADHOC_REQUESTED" = "1" ]; then
        echo "Signed: ad-hoc, as UBIQUITTY_SIGN_IDENTITY=ad-hoc asked."
    else
        echo "Signed: ad-hoc — macOS re-prompts for folder access each rebuild."
        echo "  To persist grants, create a self-signed code-signing cert named"
        echo "  \"Ubiquitty Dev\" (Keychain Access ▸ Certificate Assistant), or set"
        echo "  UBIQUITTY_SIGN_IDENTITY to an existing identity."
    fi
else
    if [ "$RELEASE_SIGNING" = "1" ] || [ "$SIGN_ID" = "-" ]; then
        echo "ERROR: signing with \"$SIGN_ID\" failed." >&2
        exit 1
    fi
    echo "WARNING: signing with \"$SIGN_ID\" failed." >&2
fi

if [ "$RUN" = "1" ]; then
    echo "Launching ..."
    open "$APP"
fi
