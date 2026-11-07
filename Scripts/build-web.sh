#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# build-web.sh — build the browser frontend to wasm32 and stage a servable dir.
#
# The browser is a thin consumer of the portable Core: it links the same
# canonical source list every other frontend trims from, so anything it cannot
# reach through Core is a gap in Core rather than something to write in
# JavaScript.
#
# Skips gracefully (exit 0, logged) when emscripten is absent, so the wider
# build battery stays green on a machine without it — the same contract
# wasm-smoke.sh follows.
#
#   ./Scripts/build-web.sh [--serve]
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs; see CMakeLists.txt.
CORE_ROOT="${UBIQUITTY_CORE_SOURCE_DIR:-$ROOT/Libraries/ubiquitty-core}"
KIT_ROOT="${UBIQUITTY_KIT_SOURCE_DIR:-$ROOT/Libraries/ubiquitty-kit}"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
# shellcheck source=Scripts/ubq-roots.sh
. "$CORE_ROOT/Scripts/ubq-roots.sh"
BUILD="$UBQ_BUILD_ROOT/web"
STAGE="$UBQ_BUILD_ROOT/web-dist"

if ! command -v emcmake >/dev/null 2>&1; then
    echo "build-web: emscripten (emcmake) not found — skipping" >&2
    exit 0
fi

# CMake caches the absolute Emscripten toolchain and compiler paths. Package
# upgrades remove versioned prefixes, and CMake cannot repair a configure whose
# cached toolchain no longer exists. Drop only that stale generated state; a
# valid cache keeps its objects and avoids a clean rebuild.
if [[ -f "$BUILD/CMakeCache.txt" ]]; then
    staleToolchainPath=""
    while IFS='=' read -r key value; do
        case "$key" in
            CMAKE_TOOLCHAIN_FILE:*|CMAKE_C_COMPILER:*|CMAKE_CXX_COMPILER:*)
                if [[ "$value" = /* && ! -e "$value" ]]; then
                    staleToolchainPath="$value"
                    break
                fi
                ;;
        esac
    done < "$BUILD/CMakeCache.txt"
    if [[ -n "$staleToolchainPath" ]]; then
        echo "build-web: discarding stale CMake toolchain cache ($staleToolchainPath)" >&2
        cmake -E remove -f "$BUILD/CMakeCache.txt"
        cmake -E remove_directory "$BUILD/CMakeFiles"
    fi
fi

# Ninja, explicitly, because emcmake defaults to Unix Makefiles and every other
# build directory in the tree is Ninja.
#
# Core's run-tests.sh sweeps every build/*/CMakeCache.txt through
# ubq_reset_on_generator_change and removes any directory whose generator does
# not match, so that a stanza adding a build directory inherits the check rather
# than needing an edit there. Nothing in that file owns build/web, so a build
# with another generator would be removed and never rebuilt, silently narrowing
# check-tidy's scan by the six Wasm translation units.
echo "build-web: configuring for wasm32 ..." >&2
# QUIC is on everywhere a build can carry it; wasm32 is the exception the
# platform makes, not a choice: the carrier is ngtcp2 over UDP sockets with
# AWS-LC underneath, and a wasm target has neither. A browser reaches a host
# through the page's socket, which is the web frontend's own transport.
emcmake cmake -S "$ROOT" -B "$BUILD" -G Ninja \
    "-DUBIQUITTY_CORE_SOURCE_DIR=$CORE_ROOT" "-DUBIQUITTY_KIT_SOURCE_DIR=$KIT_ROOT" \
    -DUBIQUITTY_FRONTEND=Core -DUBIQUITTY_QUIC=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON >/dev/null

echo "build-web: building ..." >&2
cmake --build "$BUILD" --target ubiquitty-web

# The page reaches the module through cwrap and the heap views. Emscripten drops
# any runtime method not named in EXPORTED_RUNTIME_METHODS, and the failure is
# silent at build time — cwrap keeps working while every buffer access is
# undefined, so the first symptom is a TypeError in the browser. Assert the
# generated glue actually carries what the page uses.
# Grep for the EXPORT, not the symbol: emscripten's glue defines HEAPU8
# internally whether or not it is exported, so a bare name match passes on a
# build the page cannot use. Module["name"] is what cwrap-style access needs.
# ccall, _malloc and _free join the list because the page hands Core its
# configuration bytes through them. A dropped one is the same silent shape as
# the two above: the handover throws, and without this the first symptom is a
# deployment whose config.toml appears to do nothing.
for symbol in cwrap ccall HEAPU8 _malloc _free; do
    if ! grep -q "Module\[.$symbol.\]" "$BUILD/ubiquitty.js"; then
        echo "build-web: FAIL — $symbol missing from the generated module." >&2
        echo "build-web: add it to EXPORTED_RUNTIME_METHODS / EXPORTED_FUNCTIONS in CMakeLists.txt." >&2
        exit 1
    fi
done

# Every entry point the page cwraps must exist in the module. The page names them
# as strings, so a renamed or dropped export is not a compile error anywhere — it
# is a TypeError on the frame that first calls it, which in practice means the
# feature is silently dead until someone exercises it by hand.
cwrapped="$(grep -oE "cwrap\('[A-Za-z0-9_]+'" "$ROOT/Source/Platform/Web/terminal.js" | sed "s/cwrap('//; s/'//" | sort -u)"
if [ -z "$cwrapped" ]; then
    echo "build-web: FAIL — no cwrap('name') call found in terminal.js. The page always" >&2
    echo "  cwraps at least ubiquittyWebCreate, so the call spelling drifted (the quotes" >&2
    echo "  reformatted, say) and this export check would pass having verified nothing." >&2
    exit 1
fi
missing=""
for symbol in $cwrapped; do
    grep -q "$symbol" "$BUILD/ubiquitty.js" || missing="$missing $symbol"
done
if [ -n "$missing" ]; then
    echo "build-web: FAIL — the page cwraps entry points the module does not export:$missing" >&2
    echo "build-web: each needs UBIQUITTY_WEB_EXPORT in WebExports.cpp." >&2
    exit 1
fi

# Nothing may reach the wasm terminal before create(). Every such export answers
# 0 with no terminal rather than throwing, so an early call is discarded in
# silence and the feature it served is missing with no error anywhere.
if ! python3 "$ROOT/Scripts/check-web-init-order.py"; then
    exit 1
fi

# Every palette command the C++ side registers must have somewhere to land. An
# id with no handler is not an error anywhere: Beam accepts the row, closes, the
# page looks the id up in its own table, finds nothing, and the user sees the
# palette vanish having done nothing.
#
# Every beam id the file names, not only those registered through `add(...)`.
# Keying on the call spelling was keying on a syntactic accident: a command built
# as a PaletteCommand literal is invisible to it, and one of those (the padding
# editor) is applied inside WebTerminal and handed to the page, so losing its
# handler would leave the value set and the window never re-fitted.
#
# An exemption keyed on the id appearing in WebTerminal.cpp would excuse every
# id, because that is the file that registers them, and would pass a planted
# orphan. A gate keyed on something the subject always satisfies is not a gate.
# So the exemption below is a NAMED list,
# short enough to read, and each entry is one `feedBeamKey` returns on before
# m_beamCommand is assigned. Before adding a name here, check that: an id that
# does reach the page and has no handler is exactly what this catches.
CONSUMED_IN_PLACE="beam.theme beam.font"
beam_ids="$(grep -oE '"beam\.[A-Za-z]+"' "$ROOT/Source/Platform/Web/WebTerminal.cpp" | tr -d '"' | sort -u)"
if [ -z "$beam_ids" ]; then
    echo "build-web: FAIL — no \"beam.<name>\" id found in WebTerminal.cpp. Beam palette" >&2
    echo "  commands exist, so the id spelling drifted (a digit or underscore in a name," >&2
    echo "  an id built through a helper) and this orphan check would pass over nothing." >&2
    exit 1
fi
orphans=""
for id in $beam_ids; do
    case " $CONSUMED_IN_PLACE " in *" $id "*) continue ;; esac
    grep -q "'$id'" "$ROOT/Source/Platform/Web/terminal.js" || orphans="$orphans $id"
done
if [ -n "$orphans" ]; then
    echo "build-web: FAIL — palette commands with no handler:$orphans" >&2
    echo "build-web: each needs a case in terminal.js's BEAM_COMMANDS, or handling in WebTerminal::feedBeamKey." >&2
    exit 1
fi

mkdir -p "$STAGE"
cp "$BUILD/ubiquitty.js" "$BUILD/ubiquitty.wasm" "$STAGE/"
cp "$ROOT/Source/Platform/Web/index.html" "$ROOT/Source/Platform/Web/terminal.js" "$ROOT/Source/Platform/Web/webgl.js" "$ROOT/Source/Platform/Web/fonts.js" "$ROOT/Source/Platform/Web/rich-text.js" "$ROOT/Source/Platform/Web/picture.js" "$ROOT/Source/Platform/Web/outline.js" "$STAGE/"
cp "$ROOT/Source/Platform/Web/workspace.html" "$ROOT/Source/Platform/Web/workspace.css"    "$ROOT/Source/Platform/Web/workspace.js" "$ROOT/Source/Platform/Web/workspace-layout.js" "$STAGE/"
cp "$ROOT/Source/Platform/Web/workspace-search.js" "$STAGE/"
mkdir -p "$STAGE/phosphor" "$STAGE/process-icons"
cp "$KIT_ROOT/Resources/phosphor/Phosphor.ttf" "$KIT_ROOT/Resources/phosphor/catalog.json" "$KIT_ROOT/Resources/phosphor/LICENSE" "$STAGE/phosphor/"
cp "$CORE_ROOT"/Resources/process-icons/* "$STAGE/process-icons/"
python3 - "$STAGE/process-icons" <<'PYICONS'
import json, pathlib, sys
icons = pathlib.Path(sys.argv[1])
(icons / "files.json").write_text(json.dumps({item.stem: item.suffix[1:] for item in icons.iterdir() if item.suffix in (".svg", ".png")}))
PYICONS
# The icons index.html links, from the app icon's exports.
cp "$ROOT/Resources/Icon/Ubiquitty.svg" "$STAGE/favicon.svg"
cp "$ROOT/Resources/Icon/Raster/favicon.ico" "$ROOT/Resources/Icon/Raster/apple-touch-icon.png" "$STAGE/"
# The house face, as every other frontend bundles it. A browser can only use a
# font it has been served or the user happens to have installed, so without this
# the page falls back to Unifont on a machine that has never seen JetBrains Mono
# — a different terminal from the one macOS ships.
mkdir -p "$STAGE/fonts"
# Quoted because the brackets are a glob character class: unquoted, the shell
# looks for a file whose name has one character from {w,g,h,t} there, finds
# none, and passes the pattern through — which happens to work here and would
# stop working the moment such a file existed.
cp "$CORE_ROOT/Resources/fonts/JetBrainsMono[wght].ttf" \
   "$CORE_ROOT/Resources/fonts/JetBrainsMono-Italic[wght].ttf" "$STAGE/fonts/"
# The bundled symbol/Nerd-font fallback, as macOS and Linux ship it. Without
# this the page's `symbol_fallback` route
# names a family the page never served, and `validateFamily` declines every
# route to it — the gap this stage exists to close degrades right back to
# Unifont on every machine, not just the ones missing the font locally.
cp "$CORE_ROOT/Resources/fonts/SymbolsNerdFontMono-Regular.ttf" "$STAGE/fonts/"
# Serving a font redistributes it, and its license has to travel with it: OFL
# section 2 and MIT both require the notice in every copy. The stage carries
# the same notice set every other package does, under licenses/, and is
# checked against the inventory the way a bundle is. The folder is rebuilt so a
# notice the inventory dropped does not linger from an earlier stage.
rm -rf "$STAGE/licenses"
python3 "$CORE_ROOT/Scripts/license_notices.py" --source "$ROOT" --core "$CORE_ROOT" --kit "$KIT_ROOT" --copy "$STAGE/licenses"
if ! python3 "$CORE_ROOT/Scripts/license_notices.py" --source "$ROOT" --core "$CORE_ROOT" --kit "$KIT_ROOT" --verify "$STAGE/licenses"; then
    echo "build-web: FAIL — the staged licenses/ does not match the inventory's notices." >&2
    exit 1
fi
# The page's own half, driven under node. The build guard above proves every
# entry point exists; this proves the bytes survive the trip and the staged
# clipboard contract holds. Skipped rather than failed where node is absent — a
# missing tool is a gap, not a defect.
if command -v node >/dev/null 2>&1; then
    node "$ROOT/Tests/Web/workspace-layout.mjs" || exit 1
    node "$ROOT/Tests/Web/workspace-search.mjs" || exit 1
    node "$ROOT/Tests/Web/rich-text-invalidation.mjs" || exit 1
    node "$ROOT/Tests/Web/boundary.mjs" "$STAGE" 2>&1 | grep -v "streaming compile failed\|falling back to ArrayBuffer" || exit 1
else
    echo "build-web: SKIP boundary.mjs — no node on PATH"
fi

# The page itself, loaded against a stub DOM. Every other check here reads the
# bundle — that a symbol is exported, that a cwrap resolves — and none of them
# can tell whether the module runs. A `const` bound below the first call that
# reads it throws on the first paint and kills the page, with every one of
# those checks green.
if command -v node >/dev/null 2>&1; then
    if node "$ROOT/Tests/Web/page-smoke.mjs" "$STAGE" 2>&1 | grep -vE "wasm streaming|falling back"; then
        :
    else
        echo "build-web: FAIL — the page does not reach a frame" >&2
        exit 1
    fi
else
    echo "build-web: SKIP page-smoke.mjs — no node on PATH" >&2
fi

# The stage is a copy no build step refreshes, so the stanzas that drive it ask
# this stamp whether the bytes it was staged from are still the tree's.
# shellcheck source=Scripts/build-provenance.sh
source "$CORE_ROOT/Scripts/build-provenance.sh"
build_provenance_stamp "$ROOT" "$BUILD"
echo "build-web: staged $STAGE" >&2

if [ "${1:-}" = "--serve" ]; then
    # The module is loaded as ES6 and the wasm needs a real MIME type, so a
    # file:// open will not work — serve it.
    echo "build-web: serving http://127.0.0.1:8777/ (Ctrl-C to stop)" >&2
    cd "$STAGE" && exec python3 -m http.server 8777 --bind 127.0.0.1
fi
