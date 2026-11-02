# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.13)
# The Swift 6 language mode, for every Swift target in both Apple arms: its
# data-race checking is the enforcement that keeps the tree at zero
# concurrency diagnostics, as a build failure rather than a warning. The Xcode
# generator turns CMAKE_Swift_LANGUAGE_VERSION into a `-swift-version` word in
# OTHER_SWIFT_FLAGS, which Xcode reports as overriding the language mode; there
# the mode is the SWIFT_VERSION build setting instead.
if(CMAKE_GENERATOR MATCHES "Xcode")
    set(CMAKE_XCODE_ATTRIBUTE_SWIFT_VERSION 6)
else()
    set(CMAKE_Swift_LANGUAGE_VERSION 6)
endif()

# Route compilation through ccache when it is installed. Vendored ThirdParty
# never changes, so compiling it again on every clean configure is pure repeat
# cost. Silently absent is fine: an unset launcher is the
# stock build, so nobody has to install anything for the tree to work.
#
# Ahead of the project() call because CMAKE_<LANG>_COMPILER_LAUNCHER is read
# when a language is enabled, not when a target is defined.
#
# The sloppiness setting is carried here rather than left to the operator's
# environment, because without it the cache misses much of the tree and
# silently so. ccache will not reuse a compilation that consumed a precompiled
# header unless pch_defines lets it skip verifying the PCH's own macro state,
# and the test suite shares one PCH across nearly every target.
#
# time_macros covers __DATE__/__TIME__, which nothing here depends on.
if(NOT DEFINED CMAKE_CXX_COMPILER_LAUNCHER)
    find_program(UBIQUITTY_CCACHE ccache)
    if(UBIQUITTY_CCACHE)
        set(_ubq_ccache_launcher
            ${CMAKE_COMMAND} -E env CCACHE_SLOPPINESS=pch_defines,time_macros
            ${UBIQUITTY_CCACHE})
        set(CMAKE_C_COMPILER_LAUNCHER ${_ubq_ccache_launcher})
        set(CMAKE_CXX_COMPILER_LAUNCHER ${_ubq_ccache_launcher})
        message(STATUS "Ubiquitty: compiling through ccache (${UBIQUITTY_CCACHE})")
    endif()
endif()

#
# Top-level CMakeLists.txt — Ubiquitty multi-frontend build.
#
# The same Source/Core + Source/Rendering subset feeds every frontend,
# selected at configure time via -DUBIQUITTY_FRONTEND=<name>:
#
#   macOS   AppKit + CoreText + Metal app. Compiles Source/Platform/macOS/
#           against the portable Core. (Scripts/build-macos.sh)
#   iOS     The portable Core + the Apple-shared Swift layer, built for
#           iphoneos and iphonesimulator. A library arm, not an app: it
#           carries no UIKit and no entry point. (Scripts/build-ios.sh)
#   Host    ubiquitty-host, the persistent session daemon — portable Core +
#           Source/Core/Protocol/Sync + the POSIX PTY, no GUI. (Scripts/build-host.sh)
#   Agent   ubq, the headless Sync client + MCP server for AI
#           agents. (Scripts/build-agent.sh)
#   Core    libUbiquittyCore — the portable Core packaged as a standalone
#           static library + a consumer sample, no frontend (Docs/libubiquittycore.md).
#   Linux   GTK4 + Vulkan frontend over the portable Core.
#           (Scripts/build-linux-gtk.sh)
#   Wscons  The OpenBSD/NetBSD console itself: wsdisplay for output, wskbd
#           for keys, the CPU SoftwareRenderer drawing into the framebuffer,
#           and neither a GUI toolkit nor a GPU (Source/Platform/Wscons/main.cpp).
#           Only run by hand on OpenBSD 7.9 x64 under QEMU. Built from source
#           on request; no release ships it.
#
# See:
#   Source/PAL/PAL.h
#   Docs/architecture.md
#
# The Core builds as C++23 with -fno-exceptions and -fno-rtti (WebKit
# style), which also keeps binary size bounded.

# Minimum supported macOS. Must be set before project() so the compiler /
# SDK probes pick it up. Ignored on non-Apple hosts. Override the C++ floor with
# -DCMAKE_OSX_DEPLOYMENT_TARGET=...
#
# Scripts/macos-deployment-target.txt holds two floors and says why each is the
# number it is. `cxx` becomes CMAKE_OSX_DEPLOYMENT_TARGET, so every C-family
# target inherits it: the portable Core, UbiquittyKit, the bundled
# ubiquitty-host and ubq helpers, and the Metal shader library; the
# vendored QUIC builds and the generated Xcode workspace read the same line.
# `app` is higher and is the floor a user meets: the app bundle's
# LSMinimumSystemVersion and the Swift frontend's target. Every consumer reads
# its number from that file rather than restating it.
file(STRINGS "${CMAKE_CURRENT_LIST_DIR}/Scripts/macos-deployment-target.txt" _ubqFloors
     REGEX "^(cxx|app)=")
foreach(_ubqLine IN LISTS _ubqFloors)
    if(_ubqLine MATCHES "^cxx=(.+)$")
        set(UBIQUITTY_MACOS_MIN "${CMAKE_MATCH_1}")
    elseif(_ubqLine MATCHES "^app=(.+)$")
        set(UBIQUITTY_MACOS_APP_MIN "${CMAKE_MATCH_1}")
    endif()
endforeach()
if(NOT UBIQUITTY_MACOS_MIN OR NOT UBIQUITTY_MACOS_APP_MIN)
    message(FATAL_ERROR "Scripts/macos-deployment-target.txt must define cxx= and app=")
endif()

# An iOS configure reads the same file and must take neither number.
# CMAKE_OSX_DEPLOYMENT_TARGET names the deployment target of whichever Apple
# platform is being built, so the macOS floor written into an iOS build declares
# iOS 13.3 — a version no SDK in this toolchain still builds for, and one no
# diagnostic attributes to a file named for macOS. The iOS floor is its own
# number, set first so the macOS reconciliation below is inert for this build
# rather than merely harmless.
#
# Every iOS product shares the same deployment floor: the first release of the
# previous major, which is what a phone that has not taken this year's update
# runs. What the shell reaches for above it — the bar items' overflow
# priorities (27.0) and the arrangement view that lays a Duo's pane pair clear
# of the fold (27.1) — is gated on availability, and an older device lays the
# same items and the same pair out without them.
set(UBIQUITTY_IOS_MIN "26.0")
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    if(NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
        set(CMAKE_OSX_DEPLOYMENT_TARGET "${UBIQUITTY_IOS_MIN}" CACHE STRING
            "Minimum iOS version the binaries support")
    elseif(CMAKE_OSX_DEPLOYMENT_TARGET VERSION_LESS "${UBIQUITTY_IOS_MIN}")
        message(STATUS "Ubiquitty: iOS deployment target ${CMAKE_OSX_DEPLOYMENT_TARGET} is below this tree's ${UBIQUITTY_IOS_MIN}; raising it")
        set(CMAKE_OSX_DEPLOYMENT_TARGET "${UBIQUITTY_IOS_MIN}" CACHE STRING
            "Minimum iOS version the binaries support" FORCE)
    endif()
endif()

# A directory configured before that file changed keeps the OLD value:
# CMAKE_OSX_DEPLOYMENT_TARGET is a cache variable, `if(NOT DEFINED)` never
# revisits it, and CMake says nothing. The compiler then rejects a header nobody
# edited, naming neither the cache nor the change.
#
# So the value this tree last chose is remembered beside it. When they differ, a
# cached target equal to the PREVIOUS choice came from here rather than from the
# person building, and is updated. One equal to neither was passed with -D and is
# left alone — which is what makes this safe to run on every configure.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    # This build's floor was set above. Both arms below compare a target against
    # the macOS number, and an iOS target is not on that scale.
elseif(DEFINED CACHE{UBIQUITTY_MACOS_MIN_CHOSEN})
    if(NOT "$CACHE{UBIQUITTY_MACOS_MIN_CHOSEN}" STREQUAL "${UBIQUITTY_MACOS_MIN}"
       AND "${CMAKE_OSX_DEPLOYMENT_TARGET}" STREQUAL "$CACHE{UBIQUITTY_MACOS_MIN_CHOSEN}")
        message(STATUS "Ubiquitty: deployment target $CACHE{UBIQUITTY_MACOS_MIN_CHOSEN} -> ${UBIQUITTY_MACOS_MIN}; this directory predates the change")
        set(CMAKE_OSX_DEPLOYMENT_TARGET "${UBIQUITTY_MACOS_MIN}" CACHE STRING
            "Minimum macOS version the binaries support" FORCE)
    endif()
elseif(DEFINED CMAKE_OSX_DEPLOYMENT_TARGET
       AND CMAKE_OSX_DEPLOYMENT_TARGET VERSION_LESS "${UBIQUITTY_MACOS_MIN}")
    # A directory configured before this marker existed carries no record of
    # what chose its target, so the two cases cannot be told apart and the
    # comparison has to stand in for the record: BELOW the tree's floor is the
    # one value that cannot compile, whoever set it. Raising it is the only
    # action that leaves a buildable directory either way.
    message(STATUS "Ubiquitty: deployment target ${CMAKE_OSX_DEPLOYMENT_TARGET} is below this tree's ${UBIQUITTY_MACOS_MIN}; raising it")
    set(CMAKE_OSX_DEPLOYMENT_TARGET "${UBIQUITTY_MACOS_MIN}" CACHE STRING
        "Minimum macOS version the binaries support" FORCE)
endif()
set(UBIQUITTY_MACOS_MIN_CHOSEN "${UBIQUITTY_MACOS_MIN}" CACHE INTERNAL
    "The target this tree last chose, so a moved default is distinguishable from an override")

if(NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "${UBIQUITTY_MACOS_MIN}" CACHE STRING
        "Minimum macOS version the binaries support")
endif()

# Pin the macOS SDK so the compiler gets a real -isysroot. Without it CMake
# resolves system frameworks under a bare -F (a USER framework path), which
# demotes Apple's own headers to non-system and floods the build with
# deprecation / unused-parameter warnings from inside AppKit / Foundation /
# ApplicationServices — noise that would also block -Werror. A resolved
# -isysroot restores their system-header status. Host-side only; the Linux
# frontend builds on Linux where this is a no-op.
#
# An iOS build is excluded by name rather than by the CMAKE_OSX_SYSROOT test
# alone: `xcrun --show-sdk-path` answers with the macOS SDK whatever is being
# built, so a configure that reached here would pin an iOS target to macOS
# headers and fail on the first UIKit import with a message about a missing
# framework.
if(CMAKE_HOST_APPLE AND NOT CMAKE_OSX_SYSROOT
        AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    execute_process(COMMAND xcrun --sdk macosx --show-sdk-path
        OUTPUT_VARIABLE UBIQUITTY_MACOS_SDK
        OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    if(UBIQUITTY_MACOS_SDK AND IS_DIRECTORY "${UBIQUITTY_MACOS_SDK}")
        set(CMAKE_OSX_SYSROOT "${UBIQUITTY_MACOS_SDK}" CACHE PATH
            "macOS SDK sysroot (resolved via xcrun)" FORCE)
    endif()
endif()

# The version of this build, derived from the commit it is built from: the
# nearest `vMAJOR.MINOR.PATCH` tag and the commits past it, or the VERSION file
# where the tree cannot say. The rule, its bounds and its refusals are in
# Scripts/cmake/BuildVersion.cmake.
include(${CMAKE_CURRENT_SOURCE_DIR}/Scripts/cmake/BuildVersion.cmake)
ubiquitty_resolve_build_version("${CMAKE_CURRENT_SOURCE_DIR}")
message(STATUS "Ubiquitty version: ${UBIQUITTY_VERSION} (${UBIQUITTY_BUILD_IDENTITY})")
set(UBIQUITTY_BUILD_VERSION_DIR "${CMAKE_BINARY_DIR}/generated/version")
set(UBIQUITTY_BUILD_VERSION_RECONFIGURE_STAMP "${UBIQUITTY_BUILD_VERSION_DIR}/reconfigure.stamp")
file(MAKE_DIRECTORY "${UBIQUITTY_BUILD_VERSION_DIR}")
if(NOT EXISTS "${UBIQUITTY_BUILD_VERSION_RECONFIGURE_STAMP}")
    file(WRITE "${UBIQUITTY_BUILD_VERSION_RECONFIGURE_STAMP}" "")
endif()
# The version is baked into bundle metadata when the build is configured, so
# whatever moves it re-runs the configure: VERSION and the rule themselves, the
# worktree's HEAD and its log, and the stamp the build step writes when it
# finds the tree on another version than the one configured. The portable-Core
# source SSOT is read with file(STRINGS) at configure time, so it needs the
# same treatment — without it, adding a Core .cpp silently leaves every
# configured build tree linking the stale source list until a manual
# reconfigure.
ubiquitty_build_version_configure_inputs("${CMAKE_CURRENT_SOURCE_DIR}" _ubq_version_configure_inputs)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/VERSION"
    "${CMAKE_CURRENT_SOURCE_DIR}/Scripts/cmake/BuildVersion.cmake"
    "${UBIQUITTY_BUILD_VERSION_RECONFIGURE_STAMP}"
    ${_ubq_version_configure_inputs}
    "${CMAKE_CURRENT_SOURCE_DIR}/Scripts/portable-core-sources.txt")

# CMake uses the top-level project name as the generated IDE-project filename.
# Keep the product-facing default stable, while allowing the multi-frontend
# Xcode workspace to give each independently configured project a clear name.
# The Apple Developer team the generated Xcode project signs a device build
# with, and the reason it is a variable rather than a literal: a team id belongs
# to one Apple account, so a value written into the tree would be wrong for
# everyone but its owner. Xcode stores the team in project.pbxproj, which CMake
# rewrites on every generate, so a team picked in the UI survives until the next
# regeneration and no longer — setting it here is what makes it stick.
# Scripts/generate-xcode-workspace.sh reads it from the environment and, when
# unset, from the one team in the keychain, so the usual case configures nothing.
set(UBIQUITTY_DEVELOPMENT_TEAM "$ENV{UBIQUITTY_DEVELOPMENT_TEAM}" CACHE STRING
    "Apple Developer team id for signing the generated Xcode project (empty: pick one in Xcode)")

set(UBIQUITTY_CMAKE_PROJECT_NAME "Ubiquitty" CACHE STRING
    "Name of the generated CMake IDE project")
if(NOT UBIQUITTY_CMAKE_PROJECT_NAME MATCHES "^[A-Za-z][A-Za-z0-9_]*$")
    message(FATAL_ERROR
        "UBIQUITTY_CMAKE_PROJECT_NAME must begin with a letter and contain only letters, digits, or underscores")
endif()
project(${UBIQUITTY_CMAKE_PROJECT_NAME} VERSION "${UBIQUITTY_VERSION_NAMED}" LANGUAGES C CXX)

# The compiler is known from here on, and nothing has been compiled yet: a
# compiler below the floor is refused now, with the remedy, rather than once per
# translation unit by Source/Base/ToolchainFloor.h.
include(${CMAKE_CURRENT_SOURCE_DIR}/Scripts/cmake/ToolchainFloor.cmake)
ubiquitty_check_toolchain_floor("${CMAKE_CXX_COMPILER_ID}" "${CMAKE_CXX_COMPILER_VERSION}")

# A translation unit whose whole body sits behind a build flag — PerfCounters.cpp
# under UBIQUITTY_PERF_DIAG=OFF — compiles to an object with no symbols, and
# Apple's ranlib says so for every archive that holds one: "has no symbols",
# once per library per configure. The object is right; the symbol table is what
# ar builds and ranlib rebuilds, so ar is told to skip it (S) and ranlib to keep
# quiet about an empty member. GNU tools have no such warning and keep CMake's
# default recipe.
if(APPLE)
    foreach(_ubq_lang C CXX)
        set(CMAKE_${_ubq_lang}_ARCHIVE_CREATE "<CMAKE_AR> Scr <TARGET> <LINK_FLAGS> <OBJECTS>")
        set(CMAKE_${_ubq_lang}_ARCHIVE_FINISH "<CMAKE_RANLIB> -no_warning_for_no_symbols -c <TARGET>")
    endforeach()
endif()

# Xcode archives with libtool rather than ar and ranlib, so the recipe above
# does not reach it. Its flag says the same thing, set per static library below
# because the generator writes an empty OTHER_LIBTOOLFLAGS on every target and
# that overrides a project-wide value.
#
# The App Intents metadata step has nothing to extract: no target here declares
# an intent, and the step otherwise reports "Metadata extraction skipped" for
# the app and asks every Swift library for compiler-emitted .swiftconstvalues
# the libraries are not built to produce.
if(CMAKE_GENERATOR MATCHES "Xcode")
    set(CMAKE_XCODE_ATTRIBUTE_LM_SKIP_METADATA_EXTRACTION YES)
endif()

# An empty CMAKE_BUILD_TYPE is not a neutral default: CMake passes no
# optimisation flag at all, so a hand-configured build directory produces a -O0
# binary that looks and runs like any other. In a terminal whose whole claim is
# throughput that is a trap -- an unoptimised host serialises its scrollback
# byte at a time under libc++ container annotations, burns a core, and every
# number measured against it is wrong in a way nothing reports.
#
# The build scripts always pass one. This is for `cmake -B <dir> -D...` by hand,
# which is how benchmarks and bisects get configured, and where the mistake
# costs the most.
#
# A test tree defaults to Debug instead: Release carries NDEBUG, NDEBUG changes
# sizeof(CellGrid), and the gate below rejects that combination outright. It also
# compiles out the assertions the suite exists to trip -- a Release test tree
# reports every case passing while a checked-pointer violation goes unnoticed,
# which is this same trap wearing the other face.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    if(UBIQUITTY_BUILD_TESTS)
        set(CMAKE_BUILD_TYPE "Debug" CACHE STRING "Build type" FORCE)
    else()
        set(CMAKE_BUILD_TYPE "Release" CACHE STRING "Build type" FORCE)
    endif()
    message(WARNING
        "CMAKE_BUILD_TYPE was empty, which means NO optimisation, not a default.\n"
        "  Defaulting to Release. Pass -DCMAKE_BUILD_TYPE=Debug if that is what you meant.")
endif()
message(STATUS "Ubiquitty build type: ${CMAKE_BUILD_TYPE}")

# The version reaches a binary through one generated header, which one
# translation unit includes (Source/Core/BuildVersion.cpp). It is
# never a compile definition: a definition rides every translation unit's
# command line, and a version that moves with each commit would then recompile
# the tree on every pull. The header lives in the build directory, so nothing
# that hashes Source/ sees it change.
#
# The configure writes it, and a step that runs in every build rewrites it when
# its text would change: a commit, or a first edit to a tracked file, which the
# build identity names. The include directory is the same on every command line
# in every build, so it invalidates nothing.
set(UBIQUITTY_BUILD_VERSION_HEADER "${UBIQUITTY_BUILD_VERSION_DIR}/UbiquittyBuildVersion.h")
ubiquitty_write_build_version_header(
    "${UBIQUITTY_BUILD_VERSION_HEADER}" "${UBIQUITTY_VERSION}" "${UBIQUITTY_BUILD_IDENTITY}")
include_directories("${UBIQUITTY_BUILD_VERSION_DIR}")
# What this configure derived, for the build step to hold the tree against. A
# file rather than an argument below, so the build graph is the same text at
# every commit.
file(WRITE "${UBIQUITTY_BUILD_VERSION_DIR}/configured-version.txt" "${UBIQUITTY_VERSION}\n")
add_custom_target(ubiquitty-build-version
    COMMAND "${CMAKE_COMMAND}"
        "-DUBIQUITTY_VERSION_SOURCE_DIR=${CMAKE_SOURCE_DIR}"
        "-DUBIQUITTY_VERSION_HEADER=${UBIQUITTY_BUILD_VERSION_HEADER}"
        "-DUBIQUITTY_VERSION_CONFIGURED_FILE=${UBIQUITTY_BUILD_VERSION_DIR}/configured-version.txt"
        "-DUBIQUITTY_VERSION_RECONFIGURE_STAMP=${UBIQUITTY_BUILD_VERSION_RECONFIGURE_STAMP}"
        -P "${CMAKE_SOURCE_DIR}/Scripts/cmake/BuildVersion.cmake"
    BYPRODUCTS "${UBIQUITTY_BUILD_VERSION_HEADER}"
    COMMENT "Checking the build version"
    VERBATIM)

# Embed the canonical shell-completion scripts (Resources/shell-integration/*)
# into a generated header so `ubq completions bash|zsh` can print
# them with no install footprint. Single source of truth: the Resource files.
# A long raw-string delimiter that cannot appear inside a shell script keeps
# arbitrary script bytes literal.
function(ubiquitty_generate_completions_header out_header)
    file(READ "${CMAKE_CURRENT_SOURCE_DIR}/Resources/shell-integration/ubq.bash" _bash)
    file(READ "${CMAKE_CURRENT_SOURCE_DIR}/Resources/shell-integration/ubq.zsh" _zsh)
    set(_content "// Generated by CMake from Resources/shell-integration/*. DO NOT EDIT.\n")
    string(APPEND _content "#pragma once\n")
    string(APPEND _content "namespace Ubiquitty { namespace Agent {\n")
    string(APPEND _content "inline const char* bashCompletion = R\"UBQCOMPLETION(${_bash})UBQCOMPLETION\";\n")
    string(APPEND _content "inline const char* zshCompletion = R\"UBQCOMPLETION(${_zsh})UBQCOMPLETION\";\n")
    string(APPEND _content "} }\n")
    file(WRITE "${out_header}" "${_content}")
endfunction()

# Embed the shell-integration scripts (Resources/shell-integration/*) in the
# host binary, which writes them to its control directory for the shells it
# starts: a host copied to another machine carries no Resources directory. The
# file is rewritten only when its bytes change, and editing a script
# reconfigures.
function(ubiquitty_generate_shell_integration_source out_source)
    set(_content "// Generated by CMake from Resources/shell-integration/*. DO NOT EDIT.\n")
    string(APPEND _content "#include \"Platform/Host/ShellIntegrationFiles.h\"\n\n")
    string(APPEND _content "namespace Ubiquitty::Host {\n\n")
    string(APPEND _content "std::span<const ShellIntegrationScript> shellIntegrationScripts()\n{\n")
    string(APPEND _content "    static constexpr ShellIntegrationScript scripts[] {\n")
    foreach(_name bash.sh zsh.sh fish.fish)
        set(_path "${CMAKE_CURRENT_SOURCE_DIR}/Resources/shell-integration/${_name}")
        file(READ "${_path}" _body)
        set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_path}")
        string(APPEND _content "        { \"${_name}\", R\"UBQINTEGRATION(${_body})UBQINTEGRATION\" },\n")
    endforeach()
    string(APPEND _content "    };\n    return scripts;\n}\n\n} // namespace Ubiquitty::Host\n")
    set(_existing "")
    if(EXISTS "${out_source}")
        file(READ "${out_source}" _existing)
    endif()
    if(NOT _existing STREQUAL _content)
        file(WRITE "${out_source}" "${_content}")
    endif()
endfunction()

# ----------------------------------------------------------------------
# Frontend selection.
#
# Honour an explicit -DUBIQUITTY_FRONTEND=... If unset, default to "Linux"
# on a Linux host and "macOS" otherwise. The Host and Agent frontends are
# always selected explicitly by their build scripts.
# ----------------------------------------------------------------------
if(NOT DEFINED UBIQUITTY_FRONTEND)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        set(UBIQUITTY_FRONTEND "Linux")
    else()
        set(UBIQUITTY_FRONTEND "macOS")
    endif()
endif()
set(UBIQUITTY_FRONTEND "${UBIQUITTY_FRONTEND}" CACHE STRING
    "Frontend to build (macOS, iOS, Host, Agent, Linux, Wscons, Core)")
message(STATUS "Ubiquitty frontend: ${UBIQUITTY_FRONTEND}")

# Treat compiler warnings as errors in every first-party compile: -Werror for
# C, C++ and Objective-C (set per target, beside each target's warning list),
# -warnings-as-errors for Swift (set once here, so every Swift target in this
# directory and below inherits it, and the Xcode generator carries it into
# OTHER_SWIFT_FLAGS). ON by default to keep the tree warning-clean; flip OFF
# (-DUBIQUITTY_WERROR=OFF) if a new SDK/compiler version introduces warnings in
# code you can't touch yet, so a toolchain bump never hard-blocks a build.
option(UBIQUITTY_WERROR "Treat compiler warnings as errors" ON)
add_compile_options(
    "$<$<AND:$<COMPILE_LANGUAGE:Swift>,$<BOOL:${UBIQUITTY_WERROR}>>:-warnings-as-errors>")

# Xcode enables -Wshorten-64-to-32 by default and Ninja builds do not, so an
# implicit 64-to-32-bit narrowing used to surface only in an Xcode build. Every
# clang compile of first-party C and C++ code asks for it. GCC has
# no such flag, so the expression is empty there. Vendored sources carry -w.
set(UBIQUITTY_NARROWING_WARNING
    "$<$<COMPILE_LANG_AND_ID:C,Clang,AppleClang>:-Wshorten-64-to-32>"
    "$<$<COMPILE_LANG_AND_ID:CXX,Clang,AppleClang>:-Wshorten-64-to-32>")

# ----------------------------------------------------------------------
# QUIC transport (ngtcp2 + AWS-LC) — the resilient always-on datagram transport
# (roaming / NAT / loss survival). ON for every shipping frontend (the macOS app,
# the native host, and the static-musl Linux cross-build); the pinned stack is
# auto-fetched below if missing. OFF applies only to libUbiquittyCore, the
# dependency-free standalone Core. The link step finds the static libs + headers
# under UBIQUITTY_QUIC_PREFIX.
# ----------------------------------------------------------------------
option(UBIQUITTY_QUIC "Build the QUIC transport (ngtcp2 + AWS-LC)" ON)
# The host tests link against the portable Core layer chain, which only the
# Core frontend defines; Tests/CMakeLists.txt finds and registers them.
option(UBIQUITTY_BUILD_TESTS "Configure the host tests and register each one with CTest" OFF)
option(UBIQUITTY_BUILD_SYNC_TRANSPORT_ACCEPTANCE
    "Build the isolated real SSH/QUIC acceptance executable (Host, QUIC, Debug only)" OFF)
if(UBIQUITTY_BUILD_SYNC_TRANSPORT_ACCEPTANCE AND
        (NOT UBIQUITTY_FRONTEND STREQUAL "Host" OR NOT UBIQUITTY_QUIC))
    message(FATAL_ERROR
        "Sync transport acceptance requires UBIQUITTY_FRONTEND=Host and UBIQUITTY_QUIC=ON")
endif()

# NDEBUG does not merely delete assert() here. CellGrid declares
# `m_paintInvariantBroken` inside #ifndef NDEBUG, and `assertInvariants` the same
# way, so sizeof(CellGrid) differs between a TU that defines it and one that does
# not. A tree where some
# translation units have it is not a weaker test run — it is an ODR violation that
# links, runs, and prints its pass line.
#
# Fatal rather than a warning for that reason: there is no runtime signal to notice
# later. The FLAGS are read rather than the build type, so NDEBUG arriving through
# CXXFLAGS or a toolchain file is caught too, and the config is uppercased because
# that is how CMake looks the per-config flags up — `-DCMAKE_BUILD_TYPE=debug` is
# legal and must not trip this.
string(TOUPPER "${CMAKE_BUILD_TYPE}" _ubq_config_upper)
if((UBIQUITTY_BUILD_TESTS OR UBIQUITTY_BUILD_SYNC_TRANSPORT_ACCEPTANCE) AND
        "${CMAKE_C_FLAGS} ${CMAKE_CXX_FLAGS} ${CMAKE_CXX_FLAGS_${_ubq_config_upper}}"
        MATCHES "NDEBUG")
    message(FATAL_ERROR
        "UBIQUITTY_BUILD_TESTS=ON with NDEBUG in the compile flags "
        "(CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}).\n"
        "  NDEBUG changes sizeof(CellGrid), so the tests and the code under them "
        "would disagree about the layout of the type they share.\n"
        "  Configure the test tree with -DCMAKE_BUILD_TYPE=Debug.")
endif()

# A standard library that checks its subscripts, for the test tree only.
#
# Both spellings, because the two libraries this tree is compiled against
# disagree about the name and each ignores the other's: libc++ reads the
# hardening mode, libstdc++ reads the assertions switch. Fast mode is the tier
# that checks element access and iterator validity without the allocator and
# complexity checks the debug tier adds, so the cost is a compare and a branch
# at each subscript rather than a different data structure.
#
# The reason it is set here rather than left to whoever configures a build: an
# unchecked `operator[]` past the end of a container cannot report a defect, so
# an arm compiled without this is not weak evidence about out-of-bounds reads —
# it is no evidence. Agreement is evidence only among arms that could have
# disagreed.
#
# The whole tree compiles clean under it, and its cost is small beside what a
# sweep of cases spends.
#
# Scoped to the test configuration, so the shipping frontends keep the unchecked
# subscript: this is an instrument for the tier that runs cases rather than a
# guard for the tier that draws frames, and a bounds check in buildCellInstances
# would sit in the hottest loop in the renderer.
#
# The switch exists so the question "was this case failing before the checks, or
# because of them" can be answered by building both ways. Answering it any other
# way means reasoning about a trap from its absence, which is the reasoning this
# whole block exists to remove.
option(UBIQUITTY_TEST_BOUNDS_CHECKS "Compile the test tree against a checking standard library" ON)
if(UBIQUITTY_BUILD_TESTS AND UBIQUITTY_TEST_BOUNDS_CHECKS)
    # C and C++ only: a Swift compile takes -D as a bare condition and warns
    # on the value, and the test tree's Swift targets are warning-clean.
    add_compile_definitions(
        "$<$<COMPILE_LANGUAGE:C,CXX>:_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST>"
        "$<$<COMPILE_LANGUAGE:C,CXX>:_GLIBCXX_ASSERTIONS=1>")
endif()

# Compressed debug information in the Linux test tree's Debug builds. ELF
# carries DWARF in the binary itself, about four fifths of a test binary's 100
# MB, and a daemon a test drives reads its whole executable when it pins the
# files a local adopt may come from: on a loaded build machine the hashing
# alone took a handoff case past ctest's limit. Compressed, the binaries and
# the build trees are about half the size. zlib rather than zstd: Fedora's gdb
# reads zlib-compressed sections and refuses zstd ones ("BFD is not built with
# zstd support"), while the sanitizers' symbolizer reads both. None where the
# compiler, assembler and linker do not take it. Mach-O keeps its DWARF beside
# the objects, so macOS has nothing here to compress.
if(UBIQUITTY_BUILD_TESTS AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
    include(CheckCXXSourceCompiles)
    set(_ubq_saved_required_flags "${CMAKE_REQUIRED_FLAGS}")
    set(CMAKE_REQUIRED_FLAGS "-g -gz=zlib")
    check_cxx_source_compiles("int main() { return 0; }" UBIQUITTY_LINKS_ZLIB_DEBUG_SECTIONS)
    set(CMAKE_REQUIRED_FLAGS "${_ubq_saved_required_flags}")
    if(UBIQUITTY_LINKS_ZLIB_DEBUG_SECTIONS)
        add_compile_options("$<$<AND:$<CONFIG:Debug>,$<OR:$<COMPILE_LANGUAGE:C>,$<COMPILE_LANGUAGE:CXX>>>:-gz=zlib>")
        add_link_options("$<$<CONFIG:Debug>:-gz=zlib>")
    endif()
endif()

# Source-based coverage. Set at the top level rather than per target so the Core
# libraries and the tests that exercise them are instrumented by one switch —
# llvm-cov attributes a Core line to the test binary that ran it, and a
# half-instrumented tree reports that line as unexecuted.
option(UBIQUITTY_COVERAGE "Instrument for llvm-cov source-based coverage" OFF)
if(UBIQUITTY_COVERAGE)
    # -runtime-counter-relocation is what makes CONTINUOUS mode work, and the
    # shell tier asks for continuous mode by putting %c in LLVM_PROFILE_FILE
    # (Tests/CMakeLists.txt) so a daemon killed by a signal still leaves a
    # complete profile. On ELF the counters are not writable in place, so the
    # runtime needs the bias symbol this flag emits; without it every
    # instrumented process prints
    #
    #     LLVM Profile Error: __llvm_profile_counter_bias is undefined
    #
    # on stderr, continuous mode does not happen, and the profile is whatever
    # the exit hook managed to write — which for a signalled daemon is nothing.
    # The message is not fatal, which is why this survived: the process exits 0
    # and the run looks well. It is the message itself that fails a test, by
    # landing in a stream the test reads. Mach-O relocates counters without the
    # flag and accepts it as a no-op, so it is unconditional rather than
    # per-platform — one spelling cannot drift from the other.
    #
    # Clang's languages only. These are clang's spellings, and a Swift target
    # in the tree (the pasteboard library a test links) hands them to swiftc,
    # which stops at `unknown argument: '-fprofile-instr-generate'` and takes
    # the whole instrumented build with it. The index is of C++ sources, so a
    # Swift target is built plain.
    foreach(_ubq_coverage_option -fprofile-instr-generate -fcoverage-mapping -fprofile-update=atomic "SHELL:-mllvm -runtime-counter-relocation")
        add_compile_options("$<$<NOT:$<COMPILE_LANGUAGE:Swift>>:${_ubq_coverage_option}>")
    endforeach()
    # A test whose link swiftc drives still carries instrumented C++ objects,
    # which need the profile runtime; `-profile-generate` is swiftc's spelling
    # of the link half.
    add_link_options("$<IF:$<LINK_LANGUAGE:Swift>,-profile-generate,-fprofile-instr-generate>")
    # The profile runtime's writer is linked only here, and a declaration of it
    # in any other build leaves an undefined symbol. A test that forks and lets
    # the child die needs it: the child never reaches the exit hook that writes
    # its counters, so the branch it went there to exercise reports unexecuted.
    add_compile_definitions("$<$<NOT:$<COMPILE_LANGUAGE:Swift>>:UBIQUITTY_COVERAGE_INSTRUMENTED=1>")
endif()

# Runtime sanitizers. Set at the top level for the same reason coverage is: the
# Core and the tests that exercise it must carry one instrumentation, since an
# allocation made by an uninstrumented Core is invisible to the checker in the
# test that frees it. The value is the -fsanitize= list verbatim
# ("address", "address,undefined"); empty builds nothing sanitized.
set(UBIQUITTY_SANITIZERS "" CACHE STRING
    "Comma-separated -fsanitize= list applied to every target (empty: none)")
if(UBIQUITTY_SANITIZERS)
    # The vptr check reads type information, which a tree built without RTTI
    # has none of: Clang leaves the check out there by itself, and GCC keeps it
    # and stops at the link for want of every typeinfo. Named off for both.
    add_compile_options(-fsanitize=${UBIQUITTY_SANITIZERS} -fno-sanitize=vptr -fno-omit-frame-pointer)
    add_link_options(-fsanitize=${UBIQUITTY_SANITIZERS} -fno-sanitize=vptr)
    # wuffs marks its generated code no_sanitize("unsigned-integer-overflow"),
    # a check Clang alone has. GCC answers the feature test the mark sits
    # behind, ignores the name and warns that it did, which under -Werror ends
    # a sanitized build at a third-party file. The mark is right where the
    # check exists, so the warning stays a warning here.
    if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
        add_compile_options(-Wno-error=attributes)
    endif()
endif()
# The QUIC dependencies live in the checkout's build root, beside every other
# build product (Scripts/build_root.py), so each checkout builds AWS-LC and
# ngtcp2 once. The default used to sit inside the source tree while
# build-host.sh, run-tests.sh and run-ui-tests.sh named the build root, so a
# fresh checkout built the TLS stack twice and wrote half of it into the tree.
# A cache still holding that in-tree default is moved with it; an explicit
# -DUBIQUITTY_QUIC_PREFIX or a prefix named anywhere else is left alone.
find_package(Python3 COMPONENTS Interpreter REQUIRED)
execute_process(
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/Scripts/build_root.py" "${CMAKE_SOURCE_DIR}"
    OUTPUT_VARIABLE _ubiquitty_build_root
    RESULT_VARIABLE _ubiquitty_build_root_status
    OUTPUT_STRIP_TRAILING_WHITESPACE)
if(NOT _ubiquitty_build_root_status EQUAL 0 OR _ubiquitty_build_root STREQUAL "")
    message(FATAL_ERROR "Scripts/build_root.py could not name this checkout's build root "
        "(status ${_ubiquitty_build_root_status}); pass -DUBIQUITTY_QUIC_PREFIX=<prefix> to choose one")
endif()
if(UBIQUITTY_QUIC_PREFIX STREQUAL "${CMAKE_SOURCE_DIR}/build/quic-deps")
    unset(UBIQUITTY_QUIC_PREFIX CACHE)
endif()
set(UBIQUITTY_QUIC_PREFIX "${_ubiquitty_build_root}/quic-deps" CACHE PATH
    "Prefix holding the built ngtcp2 + AWS-LC (from Scripts/fetch-quic-deps.sh)")

# Ensure the pinned QUIC TLS deps (ngtcp2 + its crypto backend) in
# UBIQUITTY_QUIC_PREFIX are complete and native. Only frontends that actually link the
# QUIC transport (Host, macOS) call this, so a QUIC-free consumer (Core, Agent,
# Linux) never triggers a TLS-stack download or a network fetch at configure time.
# ensure-quic-deps.sh returns immediately for a warm cache; a cold or incompatible
# prefix delegates once to the pinned builder. The gate covers every static archive
# the QUIC targets link.
#
# - Parameter ARGV0: On iOS, the SDK to ensure (`iphoneos` or `iphonesimulator`).
#   Omitted, it is read from CMAKE_OSX_SYSROOT. A tree that serves both SDKs —
#   the Xcode project, where the destination picks one at build time — calls
#   once per SDK, since the sysroot it was configured with names only one.
function(ubiquitty_ensure_quic_deps)
    # Which platform the archives are for, and where they live.
    #
    # The host keeps the bare prefix rather than gaining a subdirectory of its own, so
    # every already-built tree stays built and no existing consumer re-downloads a TLS
    # stack it has.
    set(_ubiquitty_quic_sdk "")
    set(_ubiquitty_quic_deployment_target "")
    set(_ubiquitty_quic_prefix "${UBIQUITTY_QUIC_PREFIX}")
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        # The simulator and the device are DIFFERENT builds — arm64-apple-ios-simulator
        # against arm64-apple-ios — so they are different prefixes, and a device slice
        # is not evidence for a simulator one or the other way round.
        if(ARGC GREATER 0)
            set(_ubiquitty_quic_sdk "${ARGV0}")
        elseif(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
            set(_ubiquitty_quic_sdk "iphonesimulator")
        else()
            set(_ubiquitty_quic_sdk "iphoneos")
        endif()
        # Passed rather than read by the script: UBIQUITTY_IOS_MIN lives once, here.
        set(_ubiquitty_quic_deployment_target "${UBIQUITTY_IOS_MIN}")
        set(_ubiquitty_quic_prefix "${UBIQUITTY_QUIC_PREFIX}/${_ubiquitty_quic_sdk}")
    endif()
    # What the caller links against. Reads the same as UBIQUITTY_QUIC_PREFIX on the host,
    # so the targets that already name that keep working unchanged.
    set(UBIQUITTY_QUIC_PLATFORM_PREFIX "${_ubiquitty_quic_prefix}" PARENT_SCOPE)

    set(_ubiquitty_quic_required_libraries
        "${_ubiquitty_quic_prefix}/lib/libngtcp2_crypto_boringssl.a"
        "${_ubiquitty_quic_prefix}/lib/libngtcp2.a"
        "${_ubiquitty_quic_prefix}/lib/libssl.a"
        "${_ubiquitty_quic_prefix}/lib/libcrypto.a")

    # UBQ_CMAKE rather than letting the script find one: an Xcode run-script phase runs
    # with a PATH that excludes /opt/homebrew/bin, so a bare `cmake` in the script is not
    # found even though cmake is what is running this line. Handing over CMAKE_COMMAND also
    # guarantees the dependencies are built by the same cmake as the rest of the tree.
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E env "UBQ_CMAKE=${CMAKE_COMMAND}"
                "${CMAKE_SOURCE_DIR}/Scripts/ensure-quic-deps.sh"
                "${_ubiquitty_quic_prefix}"
                "${_ubiquitty_quic_sdk}"
                "${_ubiquitty_quic_deployment_target}"
        RESULT_VARIABLE _ubiquitty_quic_fetch_rc)

    set(_ubiquitty_quic_missing_libraries)
    foreach(_ubiquitty_quic_library IN LISTS _ubiquitty_quic_required_libraries)
        if(NOT EXISTS "${_ubiquitty_quic_library}")
            list(APPEND _ubiquitty_quic_missing_libraries "${_ubiquitty_quic_library}")
        endif()
    endforeach()

    if(_ubiquitty_quic_missing_libraries)
        string(REPLACE ";" ", " _ubiquitty_quic_missing_libraries_text
            "${_ubiquitty_quic_missing_libraries}")
    endif()

    # RESULT_VARIABLE carries an exit status or a string saying why the process
    # could not be run at all, and the two want different advice. A missing Go or
    # Perl makes the script exit non-zero after running; a non-numeric result
    # means it never started, and naming a dependency then sends the reader to
    # install something they already have.
    if(NOT _ubiquitty_quic_fetch_rc MATCHES "^[0-9]+$")
        message(FATAL_ERROR
            "QUIC deps: could not run Scripts/ensure-quic-deps.sh — ${_ubiquitty_quic_fetch_rc}. "
            "The script did not start, so nothing about the QUIC stack has been established. "
            "Check that it is executable and that its shebang is on line 1: a `#!` below the "
            "first line is a comment, and execve then fails with ENOEXEC where no shell retries it.")
    endif()

    # 127 is specifically "command not found", and the script has already said which on its
    # stderr. Advising Go and Perl there sends a reader to install two things they have, and
    # describes the most likely PAST cause rather than the one that just happened.
    if(_ubiquitty_quic_fetch_rc EQUAL 127)
        message(FATAL_ERROR
            "QUIC deps: Scripts/ensure-quic-deps.sh could not find a tool it needs (exit 127) — "
            "its output above names which. An Xcode run-script phase has a restricted PATH, "
            "which is the usual cause. "
            "Configure with -DUBIQUITTY_QUIC=OFF to build without the QUIC transport.")
    endif()

    if(NOT _ubiquitty_quic_fetch_rc EQUAL 0)
        message(FATAL_ERROR
            "QUIC deps: Scripts/ensure-quic-deps.sh exited ${_ubiquitty_quic_fetch_rc}. "
            "AWS-LC needs Go and Perl on PATH. "
            "Configure with -DUBIQUITTY_QUIC=OFF to build without the QUIC transport.")
    endif()

    if(_ubiquitty_quic_missing_libraries)
        message(FATAL_ERROR
            "QUIC deps: Scripts/ensure-quic-deps.sh reported success and these archives are "
            "still absent: ${_ubiquitty_quic_missing_libraries_text}. "
            "The prefix (${_ubiquitty_quic_prefix}) and what the script installs disagree.")
    endif()
endfunction()

# Which configurations get what an optimized build gets: link-time
# optimization, the training profile and the release path map below.
#
# A single-configuration build is one configuration, named by CMAKE_BUILD_TYPE.
# A multi-configuration generator writes them all into one project and leaves
# CMAKE_BUILD_TYPE empty, so there each setting is made for the optimized
# configurations by name. The Xcode project's Release configuration is what an
# archive builds, and a TestFlight build is the build that ships, so it gets
# what the Ninja Release build gets.
get_property(UBIQUITTY_MULTI_CONFIGURATION GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(UBIQUITTY_MULTI_CONFIGURATION OR CMAKE_BUILD_TYPE MATCHES "Release|RelWithDebInfo|MinSizeRel")
    set(UBIQUITTY_BUILDS_OPTIMIZED ON)
else()
    set(UBIQUITTY_BUILDS_OPTIMIZED OFF)
endif()

# ----------------------------------------------------------------------
# Link-time optimization for optimized native builds.
#
# Cross-TU inlining folds the per-byte ingest helpers (utf8Feed, cellAt,
# VT100Parser::transition, Unicode::Width::forCodePoint, SGR::apply) into their
# hot-loop callers — they otherwise stay out-of-line because they live in
# separate translation units. Gated to optimized configs (Debug stays fast to
# build).
# ----------------------------------------------------------------------
if(UBIQUITTY_BUILDS_OPTIMIZED)
    include(CheckIPOSupported)
    check_ipo_supported(RESULT _ubiquitty_ipo_ok OUTPUT _ubiquitty_ipo_msg)
    if(_ubiquitty_ipo_ok AND UBIQUITTY_MULTI_CONFIGURATION)
        # Per configuration. The Xcode generator writes LLVM_LTO into each
        # configuration it is on for.
        foreach(_ubiquitty_ipo_configuration IN ITEMS RELEASE RELWITHDEBINFO MINSIZEREL)
            set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_${_ubiquitty_ipo_configuration} ON)
        endforeach()
    elseif(_ubiquitty_ipo_ok)
        set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
    endif()
    if(_ubiquitty_ipo_ok)
        # GCC's LTO compares every type by name across translation units and
        # warns [-Wodr] where the definitions differ. Wuffs makes them differ
        # on purpose: a decoder struct carries a 123 MB `dead_weight` member in
        # every TU except the one that defines WUFFS_IMPLEMENTATION, so that no
        # consumer can stack-allocate at a sizeof upstream does not promise.
        # The consumers here (Source/Core/Codec/ZlibInflate.cpp, PNGDecoder.cpp)
        # hold pointers into storage the implementation TU sizes and never the
        # struct by value, and every -Wodr line in the tree's Linux logs names
        # a wuffs type. Clang's LTO has no such check. The accidental kind of
        # collision is caught at the source by Scripts/check-name-collisions.py,
        # where a fix is possible; here the only choice is whether to be told
        # about upstream's design on every link.
        if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
            add_link_options(-Wno-odr)
        endif()
        message(STATUS "LTO/IPO: enabled for the optimized configurations")
    else()
        message(STATUS "LTO/IPO: unsupported (${_ubiquitty_ipo_msg})")
    endif()
endif()

# ----------------------------------------------------------------------
# PGO — the training profile reaches every arm whose compiler can read it.
#
# Every arm, not only the macOS app: the host daemon and the GTK frontend run
# the wire/parse workload the profile is trained on. The policy belongs beside
# the IPO decision above, which is the other thing every Release build gets.
#
# Clang only, and this is not a preference. The profile is LLVM's IR
# instrumentation format; GCC's -fprofile-use takes a DIRECTORY of .gcda files,
# so handed a .profdata path it looks for `<path>/<object>.gcda`, finds none,
# warns once, and COMPILES ANYWAY. The result is a plain -O3 binary that the
# build log calls profile-guided. A build that cannot use the profile reports
# that it did not, so the log distinguishes the two cases.
#
# UBIQUITTY_PGO=OFF is the A/B escape hatch and must keep producing the pre-PGO
# flag set exactly. UBIQUITTY_PGO=REQUIRE stops a configure that would build
# without the profile, as Scripts/pgo-flags.sh does for the builds it serves:
# a release that ships a profiled binary asks for it. A caller that already put
# -fprofile-use in the C++ flags owns the decision -- Scripts/build-macos.sh
# does, because it also has an ObjC++ exclusion and a separate Swift profile to
# place -- and is left alone.
#
# Both the plain flags and the per-configuration ones, because a caller placing
# them is as likely to use either and this has to see them wherever they land.
# build-macos.sh writes CMAKE_CXX_FLAGS_RELWITHDEBINFO, so a check of
# CMAKE_CXX_FLAGS alone reads empty, adds a second -fprofile-use and a second
# UBIQUITTY_PGO_STAMP, and the two stamps disagree the moment the profile is
# retrained after that cache was written -- which -Werror turns into
# "'UBIQUITTY_PGO_STAMP' macro redefined" on every C and C++ file. The stamp
# exists to make a retrain invalidate cached objects, so a duplicate of it that
# goes stale is the failure it was invented to prevent.
#
# Under a multi-configuration generator the flags are conditioned on the
# optimized configurations, and every one of those configurations' flags is
# read for a caller's own -fprofile-use.
if(UBIQUITTY_BUILDS_OPTIMIZED)
    set(UBIQUITTY_PGO "ON" CACHE STRING "Use the checked-in training profile (ON/OFF/REQUIRE)")
    if(NOT DEFINED UBIQUITTY_PGO_PROFILE)
        find_package(Python3 COMPONENTS Interpreter REQUIRED)
        execute_process(
            COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/Scripts/pgo_localize.py
                --default-profile "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_SYSTEM_NAME}" "${CMAKE_SYSTEM_PROCESSOR}"
            OUTPUT_VARIABLE _ubiquitty_pgo_default
            OUTPUT_STRIP_TRAILING_WHITESPACE
            COMMAND_ERROR_IS_FATAL ANY)
        set(UBIQUITTY_PGO_PROFILE "${_ubiquitty_pgo_default}"
            CACHE FILEPATH "The training profile -fprofile-use reads")
    endif()
    if(UBIQUITTY_MULTI_CONFIGURATION)
        string(JOIN " " _ubiquitty_pgo_caller_flags "${CMAKE_CXX_FLAGS}" "${CMAKE_CXX_FLAGS_RELEASE}"
            "${CMAKE_CXX_FLAGS_RELWITHDEBINFO}" "${CMAKE_CXX_FLAGS_MINSIZEREL}")
        set(_ubiquitty_pgo_compiles
            "$<AND:$<COMPILE_LANGUAGE:C,CXX>,$<OR:$<CONFIG:Release>,$<CONFIG:RelWithDebInfo>,$<CONFIG:MinSizeRel>>>")
    else()
        string(TOUPPER "${CMAKE_BUILD_TYPE}" _ubiquitty_pgo_config)
        set(_ubiquitty_pgo_caller_flags "${CMAKE_CXX_FLAGS} ${CMAKE_CXX_FLAGS_${_ubiquitty_pgo_config}}")
        set(_ubiquitty_pgo_compiles "$<COMPILE_LANGUAGE:C,CXX>")
    endif()
    if(NOT UBIQUITTY_PGO STREQUAL "OFF" AND NOT _ubiquitty_pgo_caller_flags MATCHES "-fprofile-use")
        unset(_ubiquitty_pgo_unapplied)
        set(_ubiquitty_pgo_toolchain_status 0)
        if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND CMAKE_CXX_COMPILER_ID MATCHES "Clang")
            find_package(Python3 COMPONENTS Interpreter REQUIRED)
            execute_process(
                COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/Scripts/pgo_toolchain.py
                    verify "${UBIQUITTY_PGO_PROFILE}" "${CMAKE_CXX_COMPILER}"
                RESULT_VARIABLE _ubiquitty_pgo_toolchain_status
                ERROR_VARIABLE _ubiquitty_pgo_toolchain_refusal
                ERROR_STRIP_TRAILING_WHITESPACE)
        endif()
        if(NOT EXISTS "${UBIQUITTY_PGO_PROFILE}")
            message(STATUS "PGO: no profile at ${UBIQUITTY_PGO_PROFILE} — building without one")
            set(_ubiquitty_pgo_unapplied "there is no profile at ${UBIQUITTY_PGO_PROFILE}")
        elseif(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
            message(STATUS
                "PGO: NOT APPLIED — ${CMAKE_CXX_COMPILER_ID} does not read LLVM's profile format. "
                "Support/pgo carries a .profdata (clang, IR instrumentation); GCC's -fprofile-use "
                "wants a directory of .gcda and would compile clean without it. This build is "
                "plain -O3, and says so rather than claiming a profile it did not use.")
            set(_ubiquitty_pgo_unapplied "${CMAKE_CXX_COMPILER_ID} does not read LLVM's profile format")
        elseif(NOT _ubiquitty_pgo_toolchain_status EQUAL 0)
            message(STATUS "PGO: NOT APPLIED — ${_ubiquitty_pgo_toolchain_refusal}; building without PGO")
            set(_ubiquitty_pgo_unapplied "${_ubiquitty_pgo_toolchain_refusal}")
        else()
            # The profile's CONTENT rides along as an inert define. A build
            # system rebuilds an object when its command line changes, and
            # -fprofile-use names only the profile's PATH: after a retrain the
            # cached objects still carry the old counts, and ThinLTO then
            # refuses to link the mix on conflicting ProfileSummary flags.
            file(SHA256 "${UBIQUITTY_PGO_PROFILE}" _ubiquitty_pgo_hash)
            string(SUBSTRING "${_ubiquitty_pgo_hash}" 0 16 _ubiquitty_pgo_stamp)
            # A clang older than the llvm-profdata that wrote the profile cannot
            # read it and fails every translation unit on it, so the compiler is
            # asked before it is handed the file. Scripts/cmake/ToolchainFloor.cmake
            # says why the question is put to the compiler and not its version.
            ubiquitty_compiler_reads_profile(_ubiquitty_pgo_readable _ubiquitty_pgo_refusal
                "${UBIQUITTY_PGO_PROFILE}" "${_ubiquitty_pgo_stamp}")
            if(NOT _ubiquitty_pgo_readable)
                message(STATUS
                    "PGO: NOT APPLIED — ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION} cannot read "
                    "${UBIQUITTY_PGO_PROFILE}: ${_ubiquitty_pgo_refusal}. This build is plain -O3. "
                    "A clang at least as new as the LLVM that wrote the profile applies it, and "
                    "-DUBIQUITTY_PGO=OFF leaves it out without asking.")
                set(_ubiquitty_pgo_unapplied
                    "${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION} cannot read the profile")
            else()
                # The three -Wno flags are the tolerance contract: TUs the
                # training battery never executes, functions that drifted since
                # the retrain, and same-name CFG mismatches compile at plain -O3
                # placement instead of erroring under this tree's -Werror.
                # The committed profile keys internal-linkage functions by the
                # trainer's relative paths, and this build compiles absolute
                # ones, so it reads a copy rooted at this source tree;
                # Scripts/pgo_localize.py says why no flag can do it. The copy
                # is derived per profile and root, so a retrain reconfigures.
                set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${UBIQUITTY_PGO_PROFILE}")
                find_package(Python3 COMPONENTS Interpreter REQUIRED)
                execute_process(
                    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/Scripts/pgo_localize.py
                        "${UBIQUITTY_PGO_PROFILE}" "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/pgo"
                    OUTPUT_VARIABLE _ubiquitty_pgo_local
                    OUTPUT_STRIP_TRAILING_WHITESPACE
                    COMMAND_ERROR_IS_FATAL ANY)
                add_compile_options(
                    $<${_ubiquitty_pgo_compiles}:-fprofile-use=${_ubiquitty_pgo_local}>
                    $<${_ubiquitty_pgo_compiles}:-DUBIQUITTY_PGO_STAMP=${_ubiquitty_pgo_stamp}>
                    $<${_ubiquitty_pgo_compiles}:-Wno-profile-instr-unprofiled>
                    $<${_ubiquitty_pgo_compiles}:-Wno-profile-instr-out-of-date>
                    $<${_ubiquitty_pgo_compiles}:-Wno-backend-plugin>)
                message(STATUS "PGO: using ${UBIQUITTY_PGO_PROFILE} as ${_ubiquitty_pgo_local}")
            endif()
        endif()
        if(DEFINED _ubiquitty_pgo_unapplied AND UBIQUITTY_PGO STREQUAL "REQUIRE")
            message(FATAL_ERROR
                "PGO: UBIQUITTY_PGO=REQUIRE, and this build would have no profile: "
                "${_ubiquitty_pgo_unapplied}. Configure with a clang that reads it, or with "
                "UBIQUITTY_PGO=ON to accept a plain -O3 build.")
        endif()
    endif()
endif()

# A release build keeps the builder's paths out of what it writes. re2 under
# Source/ThirdParty passes __FILE__ to its logging, and an absolute checkout or
# build root in a shipped binary names the machine it was built on and makes two
# builds of one commit at different paths differ. Release and MinSizeRel remap
# every path the compiler records. RelWithDebInfo remaps only __FILE__, because
# its debug information is how Instruments and lldb find the sources; the
# vendored QUIC stack is remapped where it is built (Scripts/fetch-quic-deps.sh).
# A multi-configuration project carries both, each conditioned on its
# configurations.
#
# - Parameters:
#   - option: The prefix-map option.
#   - condition: The generator expression the option is added under.
function(ubiquitty_add_path_map option condition)
    # An empty prefix would match every path, so each is named only when set.
    foreach(mappedPath IN ITEMS
            "${CMAKE_SOURCE_DIR}=." "${CMAKE_BINARY_DIR}=build" "${UBIQUITTY_QUIC_PREFIX}=quic-deps")
        if(NOT mappedPath MATCHES "^=")
            add_compile_options("$<${condition}:${option}=${mappedPath}>")
        endif()
    endforeach()
endfunction()
set(_ubiquitty_path_map_compiles "$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>")
if(UBIQUITTY_MULTI_CONFIGURATION)
    ubiquitty_add_path_map("-ffile-prefix-map"
        "$<AND:${_ubiquitty_path_map_compiles},$<OR:$<CONFIG:Release>,$<CONFIG:MinSizeRel>>>")
    ubiquitty_add_path_map("-fmacro-prefix-map"
        "$<AND:${_ubiquitty_path_map_compiles},$<CONFIG:RelWithDebInfo>>")
elseif(CMAKE_BUILD_TYPE MATCHES "^(Release|MinSizeRel)$")
    ubiquitty_add_path_map("-ffile-prefix-map" "${_ubiquitty_path_map_compiles}")
elseif(CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
    ubiquitty_add_path_map("-fmacro-prefix-map" "${_ubiquitty_path_map_compiles}")
endif()

# ----------------------------------------------------------------------
# Canonical portable-Core source set — read once, shared by every frontend.
#
# Scripts/portable-core-sources.txt is the single source of truth for the
# portable Core translation units (mechanically regenerated by
# Scripts/gen-portable-core-sources.sh, also read by the bash perf drivers).
# Parsing it here — above the per-frontend if/elseif chain — lets the
# ubiquitty-core lib and the host/agent/linux executables derive their Core
# link set from one list instead of each hand-maintaining an overlapping copy
# (the drift hazard this list prevents). A frontend that links only a subset
# trims it explicitly via ubiquitty_core_subset(... EXCLUDE ...) below; a new
# Core .cpp added to the canonical list then flows into every frontend
# automatically unless that frontend names it in its trim list.
# ----------------------------------------------------------------------
file(STRINGS "${CMAKE_SOURCE_DIR}/Scripts/portable-core-sources.txt"
    _ubiquitty_core_source_lines)
set(UBIQUITTY_CORE_SOURCES "")
foreach(_line IN LISTS _ubiquitty_core_source_lines)
    string(STRIP "${_line}" _line)
    # Accept only Source/....cpp paths; comments + blanks are ignored
    # structurally (no dependence on # being the first byte). Paths stay
    # repo-relative so a frontend can REMOVE_ITEM by the same spelling.
    if(_line MATCHES "^Source/.+\\.cpp$")
        list(APPEND UBIQUITTY_CORE_SOURCES "${_line}")
    endif()
endforeach()
list(LENGTH UBIQUITTY_CORE_SOURCES _ubiquitty_core_source_count)
if(_ubiquitty_core_source_count LESS 50)
    message(FATAL_ERROR
        "portable-Core: only ${_ubiquitty_core_source_count} sources parsed from "
        "Scripts/portable-core-sources.txt — list missing or malformed?")
endif()

# wasm32 (emscripten) swaps the bundled POSIX backends for the Wasm ones: wasm
# has no fork / PTY / persistent filesystem, no local-socket namespace, and no
# way to block waiting for readiness on the thread that would deliver it. The
# frontend half of the PAL (clock / clipboard / bell) is supplied by the
# embedder, unchanged.
# The bundled backends, named once. Both the core source list and the L3b layer
# list swap the same set, and a backend added to one and not the other fails the
# partition assertion below rather than at the link — but only after someone
# builds for wasm, which is not most days.
set(UBIQUITTY_BUNDLED_BACKENDS SystemPAL Preferences Poll Socket SocketPath Spawn)
if(EMSCRIPTEN)
    foreach(_backend IN LISTS UBIQUITTY_BUNDLED_BACKENDS)
        list(REMOVE_ITEM UBIQUITTY_CORE_SOURCES Source/Platform/POSIX/${_backend}.cpp)
        list(APPEND UBIQUITTY_CORE_SOURCES Source/Platform/Wasm/${_backend}.cpp)
    endforeach()
endif()

# iOS swaps the one bundled backend whose facility the platform does not have.
#
# A swap rather than a trim, and the difference is what the subset gate reads: a
# trimmed Spawn.cpp leaves every caller of spawnPipedCommand referencing a symbol
# no kept translation unit defines, which is precisely the cut the gate exists to
# refuse. Swapping keeps the symbol and changes its answer — the backend reports
# the capability absent, so the binary carries no fork and no execve while the
# code that merely names one still links.
#
# The rest of the POSIX set stays: sockets, polling, preferences and the system
# PAL all work here. Only starting a child does not.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    list(REMOVE_ITEM UBIQUITTY_CORE_SOURCES Source/Platform/POSIX/Spawn.cpp)
    list(APPEND UBIQUITTY_CORE_SOURCES Source/Platform/iOS/Spawn.cpp)
    list(REMOVE_ITEM UBIQUITTY_CORE_SOURCES Source/Platform/POSIX/ProcessSpawnAndWait.cpp)
    list(APPEND UBIQUITTY_CORE_SOURCES Source/Platform/iOS/ProcessSpawnAndWait.cpp)
endif()

# A compiler that misfolds memcmp at a runtime offset says so here rather than
# through one silently failing test. See the module for why the cure is not a
# global flag.
include(${CMAKE_SOURCE_DIR}/Scripts/cmake/CheckMemcmpFold.cmake)
ubiquitty_check_memcmp_fold()

# ubiquitty_core_subset(<out-var> KEEP_ONLY... | EXCLUDE...) — resolve a
# frontend's Core link set from the canonical list, as repo-relative paths.
#   EXCLUDE <files...>   start from the full canonical list, drop these.
#   KEEP_ONLY <files...> start empty, keep only these (order = canonical).
# Asserts every named file is actually in the canonical list, so a typo or a
# Core file that left the SSOT fails configure instead of silently dropping a
# TU from the build.
function(ubiquitty_core_subset out_var)
    set(_mode "")
    set(_named "")
    foreach(_arg IN LISTS ARGN)
        if(_arg STREQUAL "EXCLUDE" OR _arg STREQUAL "KEEP_ONLY")
            set(_mode "${_arg}")
        else()
            list(APPEND _named "${_arg}")
        endif()
    endforeach()
    foreach(_f IN LISTS _named)
        if(NOT _f IN_LIST UBIQUITTY_CORE_SOURCES)
            message(FATAL_ERROR
                "ubiquitty_core_subset: '${_f}' is not in the canonical "
                "Scripts/portable-core-sources.txt — stale name?")
        endif()
    endforeach()
    if(_mode STREQUAL "EXCLUDE")
        set(_result ${UBIQUITTY_CORE_SOURCES})
        if(_named)
            list(REMOVE_ITEM _result ${_named})
        endif()
    elseif(_mode STREQUAL "KEEP_ONLY")
        set(_result "")
        foreach(_c IN LISTS UBIQUITTY_CORE_SOURCES)
            if(_c IN_LIST _named)
                list(APPEND _result "${_c}")
            endif()
        endforeach()
    else()
        message(FATAL_ERROR "ubiquitty_core_subset: need EXCLUDE or KEEP_ONLY")
    endif()
    set(${out_var} "${_result}" PARENT_SCOPE)
endfunction()

# RE2 — the linear-time regex engine behind Core/ScrollSearch. Vendored
# pre-Abseil release (Source/ThirdParty/re2, 2023-03-01). Any target whose
# Core subset keeps Source/Core/Screen/ScrollSearch.cpp links these TUs and adds
# UBIQUITTY_RE2_DIR to its include path; a target that trims ScrollSearch
# (Agent) takes neither. The vendored TUs carry the ThirdParty policy:
# exceptions/RTTI restored, -Werror defeated, warnings suppressed (-w: the TUs
# are vendored, not ours to fix, so their diagnostics are noise in our build).
set(UBIQUITTY_RE2_DIR "${CMAKE_SOURCE_DIR}/Source/ThirdParty/re2")
file(GLOB UBIQUITTY_RE2_SOURCES "${UBIQUITTY_RE2_DIR}/re2/*.cc")
list(APPEND UBIQUITTY_RE2_SOURCES
    "${UBIQUITTY_RE2_DIR}/util/rune.cc"
    "${UBIQUITTY_RE2_DIR}/util/strutil.cc")
set_source_files_properties(${UBIQUITTY_RE2_SOURCES} PROPERTIES
    COMPILE_OPTIONS "-fexceptions;-frtti;-Wno-error;-w")

# simdutf — the SIMD UTF-8 and base64 kernels (Source/ThirdParty/simdutf,
# v9.0.0, one amalgamated TU). Every target that compiles portable Core takes
# it, because Core/Codec/Base64.cpp calls it unconditionally: a codec that
# decodes one way on one platform and another way elsewhere is the shape a
# frontend divergence hides in, and this is an attacker-reachable decoder.
#
# There is no build-time gate on it. A macro answering "is simdutf here" made
# every include of it conditional and the scalar side of that fork unreachable
# from the lane anyone ran, which is a second implementation of an
# attacker-reachable decoder that nothing exercises.
#
# It compiles on every arm this tree builds on, the alpine g++ floor and
# emscripten included. The amalgamation dispatches on the arch at runtime, so
# it carries the ThirdParty policy the way re2 does:
# exceptions/RTTI restored, -Werror defeated, warnings suppressed.
set(UBIQUITTY_SIMDUTF_DIR "${CMAKE_SOURCE_DIR}/Source/ThirdParty/simdutf")
set(UBIQUITTY_SIMDUTF_SOURCES "${UBIQUITTY_SIMDUTF_DIR}/simdutf.cpp")
set_source_files_properties(${UBIQUITTY_SIMDUTF_SOURCES} PROPERTIES
    COMPILE_OPTIONS "-fexceptions;-frtti;-Wno-error;-w")

# ----------------------------------------------------------------------
# UbiquittySSH — the SwiftPM package wrapping swift-nio-ssh into the carrier a
# subprocess-less frontend drives (Source/Platform/Apple/SSH). SwiftPM-only,
# because swift-nio-ssh ships no CMake; the sources are named here so the
# Swift-rot gate sees them, and the target below is what actually compiles
# them. Opt-in, because the first build fetches swift-nio-ssh from GitHub —
# a network dependency no default configure should carry.
#
# The scratch path stays outside Source/ on purpose: SwiftPM's default in-tree
# .build checks third-party sources out under Source/, where the boundary
# gate reads a vendored Foundation import as Core reaching for a framework.
set(UBIQUITTY_SSH_PACKAGE_SOURCES
    Source/Platform/Apple/SSH/Package.swift
    Source/Platform/Apple/SSH/Sources/UbiquittySSH/SSHAuthenticationInteraction.swift
    Source/Platform/Apple/SSH/Sources/UbiquittySSH/SSHCarrier.swift
    Source/Platform/Apple/SSH/Sources/UbiquittySSH/SSHCloseClassification.swift
    Source/Platform/Apple/SSH/Sources/UbiquittySSH/SSHCredential.swift
    Source/Platform/Apple/SSH/Sources/UbiquittySSH/SSHPrivateKeyText.swift
    Source/Platform/Apple/SSH/Sources/UbiquittySSH/DER.swift
    Source/Platform/Apple/SSH/Sources/UbiquittySSH/SSHPipelineProbe.swift)
# The package's own test target, which `swift test` compiles and runs; named
# for the same gate, and run by the test target below.
set(UBIQUITTY_SSH_PACKAGE_TEST_SOURCES
    Source/Platform/Apple/SSH/Tests/UbiquittySSHTests/SSHAuthenticationNegotiationTests.swift
    Source/Platform/Apple/SSH/Tests/UbiquittySSHTests/SSHAuthenticationWireTests.swift
    Source/Platform/Apple/SSH/Tests/UbiquittySSHTests/SSHPrivateKeyTextTests.swift)
option(UBIQUITTY_BUILD_SSH_PACKAGE "Build the UbiquittySSH SwiftPM package (fetches swift-nio-ssh)" OFF)
if(APPLE AND UBIQUITTY_BUILD_SSH_PACKAGE)
    add_custom_target(ubiquitty-ssh-package ALL
        COMMAND swift build
                --package-path "${CMAKE_SOURCE_DIR}/Source/Platform/Apple/SSH"
                --scratch-path "${CMAKE_SOURCE_DIR}/build/swiftpm-ssh"
        COMMENT "Building UbiquittySSH (SwiftPM; fetches swift-nio-ssh on first run)"
        VERBATIM)
    add_custom_target(ubiquitty-ssh-package-tests
        COMMAND swift test
                --package-path "${CMAKE_SOURCE_DIR}/Source/Platform/Apple/SSH"
                --scratch-path "${CMAKE_SOURCE_DIR}/build/swiftpm-ssh"
        COMMENT "Testing UbiquittySSH (SwiftPM)"
        VERBATIM)
    add_dependencies(ubiquitty-ssh-package-tests ubiquitty-ssh-package)
endif()

# ----------------------------------------------------------------------
# macOS — AppKit + Metal + CoreText frontend.
#
# The shipped native app lives under Source/Platform/macOS/: AppKit windows,
# Swift chrome, a Metal renderer, CoreText shaping, and the PAL/Runtime bridge
# into the shared portable Core.
# ----------------------------------------------------------------------
include(cmake/LicenseNotices.cmake)

if(UBIQUITTY_FRONTEND STREQUAL "macOS")

    cmake_minimum_required(VERSION 3.12)
    enable_language(Swift)
    add_subdirectory(Source/Platform/macOS)

# ----------------------------------------------------------------------
# iOS — the portable Core, Apple-shared Swift layer, and SwiftUI application.
# The device and simulator builds include the app and an archive link check;
# the simulator can also build the XCUITest bundle (Scripts/build-ios.sh).
#
# Core needs nothing from this platform. Every translation unit in
# Scripts/portable-core-sources.txt compiles for arm64-apple-ios unchanged, so
# what the subset below removes is a cut made by policy rather than one forced by
# portability — see the trim list for what that distinction costs.
# ----------------------------------------------------------------------
elseif(UBIQUITTY_FRONTEND STREQUAL "iOS")

    # Without an iOS toolchain CMake compiles this for the host, and the arm
    # then proves nothing about the platform it is named for — a green build
    # that answers a different question is worse than no arm, because it is
    # quoted as evidence.
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        message(FATAL_ERROR
            "UBIQUITTY_FRONTEND=iOS needs an iOS toolchain. Configure with "
            "-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos (or "
            "iphonesimulator) -DCMAKE_OSX_ARCHITECTURES=arm64, or build through "
            "Scripts/build-ios.sh, which passes all three.")
    endif()

    # The app's CFBundleVersion. App Store Connect takes an upload only when its
    # build number is above every earlier upload of the same
    # CFBundleShortVersionString, and Xcode Cloud gives each upload it makes the
    # build number it counts itself, whatever the bundle carries. An upload made
    # anywhere else has to take the next number of that one sequence, which is
    # what UBIQUITTY_IOS_BUILD_NUMBER names: the version's bundle integer would
    # sort above every number Xcode Cloud counts and refuse each later upload.
    # Empty, the app carries the bundle integer, as every other bundle does.
    #
    # Not seeded from the environment, unlike the team: a number belongs to one
    # upload, and a cache that kept it would stamp it on every later build of the
    # directory. Scripts/generate-xcode-workspace.sh passes it on every run.
    # Checked here, ahead of the configure's slow steps, so a mistyped number
    # stops the configure before the QUIC dependencies are built.
    set(UBIQUITTY_IOS_BUILD_NUMBER "" CACHE STRING
        "CFBundleVersion of the iOS app for an App Store Connect upload (empty: the version's bundle integer)")
    set(UBIQUITTY_IOS_BUNDLE_VERSION "${UBIQUITTY_BUNDLE_VERSION}")
    if(NOT UBIQUITTY_IOS_BUILD_NUMBER STREQUAL "")
        string(LENGTH "${UBIQUITTY_IOS_BUILD_NUMBER}" _ubq_ios_build_number_length)
        if(_ubq_ios_build_number_length GREATER 9)
            message(FATAL_ERROR
                "UBIQUITTY_IOS_BUILD_NUMBER is ${_ubq_ios_build_number_length} characters long; "
                "a build number is at most 9 digits.")
        elseif(NOT UBIQUITTY_IOS_BUILD_NUMBER MATCHES "^[1-9][0-9]*$")
            message(FATAL_ERROR
                "UBIQUITTY_IOS_BUILD_NUMBER is '${UBIQUITTY_IOS_BUILD_NUMBER}', which is not a build number: "
                "decimal digits only, above zero and with no leading zero.")
        endif()
        set(UBIQUITTY_IOS_BUNDLE_VERSION "${UBIQUITTY_IOS_BUILD_NUMBER}")
    endif()
    message(STATUS "Ubiquitty iOS: CFBundleVersion ${UBIQUITTY_IOS_BUNDLE_VERSION}")

    # The SDK this arm builds against, which is not the deployment target. The
    # layout that iPhone Duo asks for — `ArrangementView`, reserved regions, the
    # vertical bars — is declared only by the iOS 27.1 SDK, and an app linked
    # against an earlier one is kept out from under the status bar and camera
    # on that device. The SDK is newer than the floor on purpose: the floor is
    # what a device must run, the SDK is what the shell must see to compile
    # the availability-gated reach for that layout.
    set(UBIQUITTY_IOS_SDK_MIN "27.1")

    # Which SDKs this build tree serves, and how a path says "the one being
    # built".
    #
    # A Ninja tree is one SDK: Scripts/build-ios.sh configures a tree per SDK
    # and the answer is known here. An Xcode project is both. The destination
    # in the toolbar chooses the SDK when the build starts, so nothing in the
    # project may carry one.
    #
    # A project per SDK does not work in its place. SDKROOT=iphonesimulator
    # reads to Xcode as "these targets support the simulator and nothing else":
    # a scheme over them has no buildable for a phone, and Xcode refuses the
    # destination with a message about the targets' SDKs. Two projects also put
    # two schemes of one name in the workspace, of which it shows one.
    #
    # So the project is configured once, for iphoneos — the base SDK from which
    # Xcode derives the simulator on its own — and every SDK-bound path below is
    # spelled with $(PLATFORM_NAME), which Xcode expands per destination to
    # `iphoneos` or `iphonesimulator`. Scripts/check-xcode-workspace.py refuses
    # a generated project in which an SDK's own name or path survives.
    if(CMAKE_GENERATOR MATCHES "Xcode")
        if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
            message(FATAL_ERROR
                "Ubiquitty: the iOS Xcode project is configured with "
                "-DCMAKE_OSX_SYSROOT=iphoneos and serves the simulator from there. "
                "Configured for ${CMAKE_OSX_SYSROOT}, its targets support only the "
                "simulator and Xcode refuses every device destination.")
        endif()
        set(UBIQUITTY_IOS_SDKS iphoneos iphonesimulator)
        set(UBIQUITTY_IOS_PLATFORM "$(PLATFORM_NAME)")
        # For the lines a build prints. The setting's own spelling cannot go
        # there: a shell reads $(...) as a command to run.
        set(UBIQUITTY_IOS_PLATFORM_LABEL "the destination's SDK")
        set(UBIQUITTY_IOS_PLATFORM_DIR "${CMAKE_CURRENT_BINARY_DIR}/$(PLATFORM_NAME)")
        # The step script reads PLATFORM_NAME from the build's environment.
        set(UBIQUITTY_IOS_STEP_PLATFORM -DPER_PLATFORM=ON)
        set(CMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "iphoneos iphonesimulator")
    else()
        if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
            set(UBIQUITTY_IOS_SDKS iphonesimulator)
        else()
            set(UBIQUITTY_IOS_SDKS iphoneos)
        endif()
        set(UBIQUITTY_IOS_PLATFORM "${UBIQUITTY_IOS_SDKS}")
        set(UBIQUITTY_IOS_PLATFORM_LABEL "${UBIQUITTY_IOS_SDKS}")
        set(UBIQUITTY_IOS_PLATFORM_DIR "${CMAKE_CURRENT_BINARY_DIR}")
        set(UBIQUITTY_IOS_STEP_PLATFORM "-DPLATFORM=${UBIQUITTY_IOS_SDKS}")
    endif()
    # One spelling of the step script's invocation, so the four steps cannot
    # disagree about which tree or which SDK they are for.
    set(UBIQUITTY_IOS_STEP
        ${CMAKE_COMMAND}
        "-DSOURCE_DIR=${CMAKE_SOURCE_DIR}"
        "-DBINARY_DIR=${CMAKE_CURRENT_BINARY_DIR}"
        "-DIOS_MIN=${UBIQUITTY_IOS_MIN}"
        ${UBIQUITTY_IOS_STEP_PLATFORM})
    set(UBIQUITTY_IOS_STEP_SCRIPT "${CMAKE_SOURCE_DIR}/Scripts/cmake/IOSPlatformStep.cmake")

    foreach(_ubq_ios_sdk IN LISTS UBIQUITTY_IOS_SDKS)
        execute_process(
            COMMAND xcrun --sdk "${_ubq_ios_sdk}" --show-sdk-version
            OUTPUT_VARIABLE _ubq_ios_sdk_version
            OUTPUT_STRIP_TRAILING_WHITESPACE
            RESULT_VARIABLE _ubq_ios_sdk_result
            ERROR_QUIET)
        if(NOT _ubq_ios_sdk_result EQUAL 0 OR _ubq_ios_sdk_version STREQUAL "")
            message(FATAL_ERROR
                "Ubiquitty: could not read the version of the ${_ubq_ios_sdk} SDK; "
                "the iOS arm needs the iOS ${UBIQUITTY_IOS_SDK_MIN} SDK or newer.")
        elseif(_ubq_ios_sdk_version VERSION_LESS "${UBIQUITTY_IOS_SDK_MIN}")
            message(FATAL_ERROR
                "Ubiquitty: the ${_ubq_ios_sdk} SDK is ${_ubq_ios_sdk_version}; the iOS arm "
                "needs ${UBIQUITTY_IOS_SDK_MIN} or newer (Xcode 27.1). Select that Xcode with "
                "xcode-select or DEVELOPER_DIR.")
        endif()
    endforeach()

    # The iOS Core link set = the canonical portable-Core list minus the
    # translation units that start a child process, and the ones whose only
    # purpose is to talk to one.
    #
    # This cut is made by policy, which is what separates it from every other
    # subset in this file. The others trim what a frontend does not reach, and a
    # mistake there is a link error. Here the SDK still declares posix_spawn and
    # fork, so every unit named below compiles and links for iOS exactly as it
    # does for macOS — nothing fails, and a shell spawn left in the set would
    # ship, run against a sandbox that denies it, and be found at App Store
    # review rather than by a compiler. Naming the units is what gives the cut a
    # mechanism:
    # check-core-subset-symbols.py parses this block out of CMakeLists.txt and
    # refuses a kept unit that references a symbol only a trimmed one defines, so
    # the day the iOS side reaches for the spawn path, the gate says so instead
    # of the platform.
    #
    # DelegatedChannel.cpp stays in the set. It is the carrier seam for exactly
    # this frontend — its own header says so — and it is what a session attaches
    # over in place of the subprocess this list removes.
    ubiquitty_core_subset(UBIQUITTY_IOS_CORE EXCLUDE
        # Nothing is trimmed for naming a spawn any more — the backends above
        # answer, so the policy is enforced by what the binary contains rather
        # than by hoping no caller survives the cut.
        #
        # LocalPTYChannel.cpp is not trimmed with it, and the difference is the
        # point of this list. It spawns nothing — 56 lines that wrap a
        # PAL::Stream somebody else opened — and on this arm nobody can open one,
        # because the only definition of PAL::openPTY lives in the POSIX
        # PTYStream backend, outside the canonical list and never added here. It
        # is also what UbiquittyKit::Session::createLocal names, so trimming it
        # took the whole embedder facade down with it on the one platform that
        # needs the facade most.
        # Control-mode tmux. Not a capability this frontend can reach yet: a
        # tmux over the carrier is a session type nothing here constructs, and
        # a local `tmux -CC` needs the child process the line above rules out.
        Source/Core/Protocol/Tmux/Session.cpp
        Source/Core/Runtime/TmuxControlHost.cpp
        # Runs the receive/send agent (`sz`/`rz`) on the session's terminal.
        Source/Core/Network/FileTransferLaunch.cpp
        # Compiles a terminfo entry by running `tic`; the only caller of
        # PAL::processSpawnAndWait.
        Source/Core/Terminfo/UbiquittyTerminfo.cpp
        # The subtree-membership arithmetic behind "which process is in the
        # foreground". Portable and syscall-free, but its only caller is the
        # POSIX PTYFacts backend, which lives outside the canonical list and
        # which an arm with no PTY never adds.
        Source/Core/Session/ProcessSubtree.cpp
    )

    # Built-in themes: Themes.cpp is in the canonical set and parses
    # builtinThemesTOML at startup, so the generated definition has to be in the
    # library or every consumer of Themes.o links short.
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    set(_ubq_ios_themes_gen ${CMAKE_CURRENT_BINARY_DIR}/BuiltinThemesData.gen.cpp)
    add_custom_command(
        OUTPUT ${_ubq_ios_themes_gen}
        COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/Scripts/embed-builtin-themes.py
                ${CMAKE_SOURCE_DIR}/Source/Core/Themes/builtin-themes.toml
                ${_ubq_ios_themes_gen}
        DEPENDS ${CMAKE_SOURCE_DIR}/Source/Core/Themes/builtin-themes.toml
                ${CMAKE_SOURCE_DIR}/Scripts/embed-builtin-themes.py
        COMMENT "Embedding built-in themes TOML (ubiquitty-core-ios)"
        VERBATIM)

    add_library(ubiquitty-core-ios STATIC
        ${UBIQUITTY_IOS_CORE}
        # This platform's answer to the PTY factory: there is no local shell, so
        # it refuses. See the file for why refusing beats trimming the caller.
        Source/Platform/iOS/PTYStream.cpp
        # The pasteboard is Objective-C and this shell is Swift, so the entry
        # point is here and the shell installs the sink.
        Source/Platform/iOS/Clipboard.cpp
        # The Darwin clock, shared with the AppKit shell — mach_absolute_time is
        # not macOS's, and this arm needs the same two entry points.
        Source/Platform/Apple/Clock.cpp
        ${_ubq_ios_themes_gen}
        # ScrollSearch.cpp stays in this subset, so the RE2 units ride along;
        # Codec/JSON.cpp wraps yyjson for the same reason.
        ${UBIQUITTY_RE2_SOURCES}
        ${UBIQUITTY_SIMDUTF_SOURCES}
        Source/ThirdParty/yyjson/yyjson.c)
    set_source_files_properties(Source/ThirdParty/yyjson/yyjson.c PROPERTIES
        COMPILE_FLAGS "-std=c99 -Wno-error -w")
    target_include_directories(ubiquitty-core-ios PUBLIC Source)
    target_include_directories(ubiquitty-core-ios SYSTEM PRIVATE
        "${UBIQUITTY_RE2_DIR}" "${UBIQUITTY_SIMDUTF_DIR}")
    target_compile_features(ubiquitty-core-ios PRIVATE cxx_std_23)
    target_link_libraries(ubiquitty-core-ios PUBLIC "-framework Foundation")
    set_target_properties(ubiquitty-core-ios PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    target_compile_options(ubiquitty-core-ios PRIVATE
        -fno-exceptions -fno-rtti -Wall -Wextra
        ${UBIQUITTY_NARROWING_WARNING}
        "$<$<BOOL:${UBIQUITTY_WERROR}>:-Werror>")

    # QUIC (ngtcp2 + AWS-LC), the same client half the macOS app links.
    #
    # The carriers are portable: a QUICChannel dials directly and forks nothing,
    # which is why this arm can have them at all. What was platform-bound was the
    # DEPS — Scripts/fetch-quic-deps.sh built macOS archives only — and
    # ubiquitty_ensure_quic_deps() now cross-builds and answers with the prefix
    # for the platform being built rather than for the host.
    #
    # An Xcode project builds them for both SDKs unless UBIQUITTY_IOS_DEVICE_ONLY
    # says only a device is built: Xcode Cloud's archive, which builds them again
    # on every run and never for the simulator. A project configured so has no
    # simulator archives to link, and a simulator destination fails at the link.
    # Scripts/generate-xcode-workspace.sh passes it on every run.
    option(UBIQUITTY_IOS_DEVICE_ONLY
        "Build the Xcode project's QUIC dependencies for iphoneos alone (Xcode Cloud's device archive)" OFF)
    set(_ubq_ios_quic_sdks ${UBIQUITTY_IOS_SDKS})
    if(CMAKE_GENERATOR MATCHES "Xcode" AND UBIQUITTY_IOS_DEVICE_ONLY)
        set(_ubq_ios_quic_sdks iphoneos)
        message(STATUS "Ubiquitty iOS: QUIC dependencies for iphoneos alone (UBIQUITTY_IOS_DEVICE_ONLY)")
    endif()
    if(UBIQUITTY_QUIC)
        foreach(_ubq_ios_sdk IN LISTS _ubq_ios_quic_sdks)
            ubiquitty_ensure_quic_deps("${_ubq_ios_sdk}")
        endforeach()
        # Per SDK, by the same spelling as everything else SDK-bound here: a
        # prefix resolved at configure would link the device's archives into a
        # simulator build of the same project.
        set(UBIQUITTY_QUIC_PLATFORM_PREFIX "${UBIQUITTY_QUIC_PREFIX}/${UBIQUITTY_IOS_PLATFORM}")
        target_sources(ubiquitty-core-ios PRIVATE
            Source/Platform/POSIX/QUICClient.cpp
            Source/Platform/POSIX/DatagramBatch.cpp
            Source/Core/Transport/QUICChannel.cpp)
        target_include_directories(ubiquitty-core-ios PRIVATE
            "${UBIQUITTY_QUIC_PLATFORM_PREFIX}/include")
        target_compile_definitions(ubiquitty-core-ios PRIVATE UBIQUITTY_QUIC=1)
        # crypto backend -> ngtcp2 -> AWS-LC ssl -> crypto (most-dependent first
        # for static archives). AWS-LC is self-contained — no framework needed.
        target_link_libraries(ubiquitty-core-ios PUBLIC
            "${UBIQUITTY_QUIC_PLATFORM_PREFIX}/lib/libngtcp2_crypto_boringssl.a"
            "${UBIQUITTY_QUIC_PLATFORM_PREFIX}/lib/libngtcp2.a"
            "${UBIQUITTY_QUIC_PLATFORM_PREFIX}/lib/libssl.a"
            "${UBIQUITTY_QUIC_PLATFORM_PREFIX}/lib/libcrypto.a")
        message(STATUS "ubiquitty-core-ios: QUIC transport enabled (ngtcp2 + AWS-LC)")
    endif()

    # ubiquitty-kit: the Tier-3 embedder facade (UbiquittyKit::Session), and the
    # iOS shell's whole view of a session. It sits outside the portable-core SSOT
    # because it is a layer above it, so an arm that wants it names it — as the
    # Core frontend does.
    add_library(ubiquitty-kit STATIC Source/UbiquittyKit/Session.cpp)
    target_link_libraries(ubiquitty-kit PUBLIC ubiquitty-core-ios)
    target_compile_features(ubiquitty-kit PRIVATE cxx_std_23)
    set_target_properties(ubiquitty-kit PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    target_compile_options(ubiquitty-kit PRIVATE
        -fno-exceptions -fno-rtti -Wall -Wextra
        ${UBIQUITTY_NARROWING_WARNING}
        "$<$<BOOL:${UBIQUITTY_WERROR}>:-Werror>")

    # The shell's seam onto the facade: the two abstract bases Swift cannot
    # derive from, and the carrier's inbound direction. See
    # Source/Platform/iOS/SessionBridge.h for why it exists at all. The pane
    # clients are here for the same reason: Swift cannot derive the clipboard
    # client and capability policy every pane's terminal is given.
    add_library(ubiquitty-ios-bridge STATIC Source/Platform/iOS/SessionBridge.cpp Source/Platform/iOS/ColdResumeBridge.cpp Source/Platform/iOS/ShowcaseHost.cpp
        Source/Platform/iOS/SessionClients.cpp)
    # The showcase host a smoke seeds is the test fixture every frontend's
    # outline is checked against.
    set_source_files_properties(Source/Platform/iOS/ShowcaseHost.cpp PROPERTIES INCLUDE_DIRECTORIES "${CMAKE_SOURCE_DIR}/Tests")
    target_link_libraries(ubiquitty-ios-bridge PUBLIC ubiquitty-kit)
    if(CMAKE_GENERATOR MATCHES "Xcode")
        set_target_properties(ubiquitty-core-ios ubiquitty-kit ubiquitty-ios-bridge PROPERTIES
            XCODE_ATTRIBUTE_OTHER_LIBTOOLFLAGS "-no_warning_for_no_symbols")
    endif()
    target_compile_features(ubiquitty-ios-bridge PRIVATE cxx_std_23)
    set_target_properties(ubiquitty-ios-bridge PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    target_compile_options(ubiquitty-ios-bridge PRIVATE
        -fno-exceptions -fno-rtti -Wall -Wextra
        ${UBIQUITTY_NARROWING_WARNING}
        "$<$<BOOL:${UBIQUITTY_WERROR}>:-Werror>")
    # The same QUIC define the core gets. The bridge builds the app's pinned
    # QUIC ChannelFactory, so without this its carrier is compiled out and the
    # phone silently never dials — the app would ask for QUIC, get an SSH
    # fallback, and look exactly like a host that could not offer one.
    #
    # It was compiled out: -Wunused-private-field on the factory's port is what
    # said so, because the field is only read inside the QUIC branch.
    if(UBIQUITTY_QUIC)
        target_compile_definitions(ubiquitty-ios-bridge PRIVATE UBIQUITTY_QUIC=1)
        target_include_directories(ubiquitty-ios-bridge PRIVATE
            "${UBIQUITTY_QUIC_PLATFORM_PREFIX}/include")
    endif()

    # The archive's link check. See Source/Platform/iOS/LinkProbe.cpp for why an
    # archive that builds is not a library that links. Force-load each C++
    # archive so the check covers the whole cut, not only reachable objects.
    add_library(ubiquitty-core-ios-link SHARED Source/Platform/iOS/LinkProbe.cpp)
    target_include_directories(ubiquitty-core-ios-link PRIVATE "${CMAKE_SOURCE_DIR}/Source")
    # The shared Swift Kit below brings the bridge and Core transitively.
    # Listing the bridge here too puts it before and after its Swift owner
    # on the link line, producing a duplicate-library warning.
    foreach(_archive ubiquitty-core-ios ubiquitty-kit ubiquitty-ios-bridge)
        target_link_options(ubiquitty-core-ios-link PRIVATE
            "LINKER:-force_load,$<TARGET_FILE:${_archive}>")
    endforeach()
    target_compile_features(ubiquitty-core-ios-link PRIVATE cxx_std_23)
    set_target_properties(ubiquitty-core-ios-link PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    target_compile_options(ubiquitty-core-ios-link PRIVATE
        "$<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions;-fno-rtti;-Wall;-Wextra>"
        ${UBIQUITTY_NARROWING_WARNING}
        "$<$<AND:$<COMPILE_LANGUAGE:CXX>,$<BOOL:${UBIQUITTY_WERROR}>>:-Werror>")

    # ------------------------------------------------------------------
    # UbiquittySSH, cross-built for the SDK being built.
    #
    # Scripts/cmake/IOSPlatformStep.cmake holds the build itself, and the reason
    # it is a script rather than a command spelled here: the triple and the SDK
    # are known at configure time only in a tree that serves one SDK.
    #
    # The compiler probe below still needs a triple at configure time, and gets
    # the configured sysroot's. Matched rather than compared: CMAKE_OSX_SYSROOT
    # is whatever the caller passed, and by the time this runs it may be the
    # short name or the resolved path. An equality test against
    # "iphonesimulator" quietly answers "device" for the path form, and the only
    # symptom is a -target whose platform disagrees with the -sdk beside it.
    set(_ubq_ios_spm_triple "arm64-apple-ios${UBIQUITTY_IOS_MIN}")
    if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
        set(_ubq_ios_spm_triple "${_ubq_ios_spm_triple}-simulator")
    endif()
    message(STATUS "Ubiquitty iOS: Swift target ${_ubq_ios_spm_triple}; SDKs served: ${UBIQUITTY_IOS_SDKS}")
    execute_process(COMMAND xcrun --sdk "${CMAKE_OSX_SYSROOT}" --show-sdk-path
        OUTPUT_VARIABLE _ubq_ios_sdk_path OUTPUT_STRIP_TRAILING_WHITESPACE)
    set(_ubq_ssh_archive "${UBIQUITTY_IOS_PLATFORM_DIR}/libUbiquittySSH.a")
    set(_ubq_ssh_flags "${UBIQUITTY_IOS_PLATFORM_DIR}/UbiquittySSH-swift-flags.txt")

    add_custom_command(
        OUTPUT "${_ubq_ssh_archive}" "${_ubq_ssh_flags}"
        COMMAND ${UBIQUITTY_IOS_STEP} -DSTEP=ssh -P "${UBIQUITTY_IOS_STEP_SCRIPT}"
        DEPENDS ${UBIQUITTY_SSH_PACKAGE_SOURCES}
                "${UBIQUITTY_IOS_STEP_SCRIPT}"
                "${CMAKE_SOURCE_DIR}/Scripts/cmake/ArchiveSwiftPMObjects.cmake"
        COMMENT "Building UbiquittySSH for ${UBIQUITTY_IOS_PLATFORM_LABEL} (first run fetches swift-nio-ssh)"
        VERBATIM)
    add_custom_target(ubiquitty-ssh-ios DEPENDS "${_ubq_ssh_archive}" "${_ubq_ssh_flags}")

    # ------------------------------------------------------------------
    # The app. SwiftUI over the seam, and nothing else — every decision it
    # renders was taken below it.
    # ------------------------------------------------------------------
    #
    # CMake drives swiftc with -sdk alone and no -target, so a cross build
    # compiles against the iOS sysroot while still targeting the host: swiftc
    # says as much ("using sysroot for 'iPhoneSimulator' but targeting
    # 'MacOSX'") and then fails to find a standard library for a triple nobody
    # asked for. The compiler target is a separate variable and it has to be set
    # before the language is enabled, because that is when the probe runs.
    set(CMAKE_Swift_COMPILER_TARGET "${_ubq_ios_spm_triple}")
    enable_language(Swift)
    # The SDK's own library directories are Xcode's to supply. CMake probed
    # them at configure time, for the configured SDK, and writes the ones a
    # Swift link does not imply onto the app's search path — where a simulator
    # build would find the device SDK's Swift libraries ahead of its own. The
    # Swift link driver passes the destination SDK's usr/lib/swift itself.
    # Every enabled language is filtered, because each one probed the same
    # directories and any of them left unfiltered puts them back. This runs
    # after the last enable_language() of the arm for the same reason.
    if(CMAKE_GENERATOR MATCHES "Xcode")
        get_property(_ubq_ios_languages GLOBAL PROPERTY ENABLED_LANGUAGES)
        foreach(_ubq_ios_language IN LISTS _ubq_ios_languages)
            list(FILTER CMAKE_${_ubq_ios_language}_IMPLICIT_LINK_DIRECTORIES EXCLUDE REGEX "\\.sdk/")
        endforeach()
    endif()

    # ------------------------------------------------------------------
    # UbiquittyRenderKit — the Apple-shared Swift layer, compiled here from the
    # same list the macOS arm compiles. Metal and CoreText over the portable
    # Core: this is the renderer, not a second one written for this platform.
    # ------------------------------------------------------------------
    include(${CMAKE_SOURCE_DIR}/Scripts/cmake/AppleSharedSwift.cmake)
    set(UBIQUITTY_IOS_RENDERKIT_ABS "")
    foreach(_src IN LISTS UBIQUITTY_APPLE_SHARED_RENDERKIT_SOURCES)
        list(APPEND UBIQUITTY_IOS_RENDERKIT_ABS "${CMAKE_SOURCE_DIR}/${_src}")
    endforeach()

    # The interop flags the layer needs to see Core through its module maps.
    # Whole-module for the reason the macOS arm states: an incrementally merged
    # module drops a member whose signature names an imported C++ type from its
    # serialized interface, and the consumer then fails at the call with "has no
    # member" while the member is public on the same tree.
    set(UBIQUITTY_IOS_SWIFT_FLAGS
        -package-name ubiquitty
        -cxx-interoperability-mode=default
        -Xcc -std=c++23
        "-I${CMAKE_SOURCE_DIR}/Source"
        # The interop map shared by both Apple shells, and the one directory it
        # still reaches into: the virtual-key table. The app-level bridges that
        # made the phone compile against Source/Platform/macOS/App are in that
        # shell's own map now.
        "-I${CMAKE_SOURCE_DIR}/Source/Platform/Apple"
        "-I${CMAKE_SOURCE_DIR}/Source/Platform/macOS")
    if(UBIQUITTY_QUIC)
        list(APPEND UBIQUITTY_IOS_SWIFT_FLAGS "SHELL:-Xcc -DUBIQUITTY_QUIC=1"
            "-I${UBIQUITTY_QUIC_PLATFORM_PREFIX}/include")
    endif()

    # What the Swift modules INLINE. Same mechanism as the macOS arm, from the
    # same file — see cmake/SwiftInteropStamp.cmake for why a Swift target
    # cannot see through an interop include on its own, and what a build that
    # does not know it looks like.
    include("${CMAKE_SOURCE_DIR}/cmake/SwiftInteropStamp.cmake")
    ubiquitty_swift_interop_stamp(UBIQUITTY_SWIFT_INTEROP_STAMP)

    add_library(UbiquittyRenderKit STATIC ${UBIQUITTY_IOS_RENDERKIT_ABS})
    target_sources(UbiquittyRenderKit PRIVATE "${UBIQUITTY_SWIFT_INTEROP_STAMP}")
    set_target_properties(UbiquittyRenderKit PROPERTIES
        Swift_MODULE_NAME "UbiquittyRenderKit"
        Swift_COMPILATION_MODE "wholemodule")
    # Whole-module in every configuration, spelled the way each generator
    # honours.
    #
    # `Swift_COMPILATION_MODE` above is inert under this tree's policy level:
    # CMake compiles the optimised configurations whole-module and Debug
    # incrementally whatever the property says. Ninja takes the mode as a flag.
    # Xcode does not — `-wmo` among the other flags contradicts the mode Xcode
    # itself planned the target's outputs for — so there it is the build
    # setting, on the target, which holds in all four configurations.
    #
    # Debug is the configuration a person presses Run on, and incremental
    # there is not merely slower to link. A member whose signature names an
    # imported C++ type does not survive an incremental compile on either side
    # of an import: the importer fails with "value of type 'RuntimeDrive' has
    # no member 'readSnapshot'" on a member that is public in the source, and
    # nothing is diagnosed where it was lost. Making the two kits whole-module
    # moves the failure from the Kit to the app, which imports them the same
    # way — so the mode belongs to every Swift target here, the app included.
    # Scripts/check-xcode-workspace.py holds each one to it in each
    # configuration.
    #
    # - Parameter target: A Swift target of this arm.
    function(ubiquitty_ios_swift_whole_module target)
        if(CMAKE_GENERATOR MATCHES "Xcode")
            set_target_properties(${target} PROPERTIES
                XCODE_ATTRIBUTE_SWIFT_COMPILATION_MODE "wholemodule")
        else()
            target_compile_options(${target} PRIVATE
                "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-wmo>")
        endif()
    endfunction()
    ubiquitty_ios_swift_whole_module(UbiquittyRenderKit)
    target_compile_options(UbiquittyRenderKit PRIVATE
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:${UBIQUITTY_IOS_SWIFT_FLAGS}>")
    target_link_libraries(UbiquittyRenderKit PRIVATE ubiquitty-ios-bridge)

    # UbiquittyKit — the surface a shell hosts, from the same shared list the
    # macOS arm compiles. The Kit imports the render kit internally, which is
    # what keeps C++ out of the interface this shell holds.
    set(UBIQUITTY_IOS_KIT_ABS "")
    foreach(_src IN LISTS UBIQUITTY_APPLE_SHARED_KIT_SOURCES)
        list(APPEND UBIQUITTY_IOS_KIT_ABS "${CMAKE_SOURCE_DIR}/${_src}")
    endforeach()
    add_library(UbiquittyKitModule STATIC ${UBIQUITTY_IOS_KIT_ABS})
    target_sources(UbiquittyKitModule PRIVATE "${UBIQUITTY_SWIFT_INTEROP_STAMP}")
    set_target_properties(UbiquittyKitModule PROPERTIES
        Swift_MODULE_NAME "UbiquittyKit"
        Swift_COMPILATION_MODE "wholemodule"
        XCODE_ATTRIBUTE_PRODUCT_MODULE_NAME "UbiquittyKit")
    ubiquitty_ios_swift_whole_module(UbiquittyKitModule)
    target_compile_options(UbiquittyKitModule PRIVATE
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:${UBIQUITTY_IOS_SWIFT_FLAGS}>"
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-I ${CMAKE_CURRENT_BINARY_DIR}>")
    add_dependencies(UbiquittyKitModule UbiquittyRenderKit)
    target_link_libraries(UbiquittyKitModule PRIVATE UbiquittyRenderKit)

    # ColdResumeBridge calls the protected sealer owned by the shared Swift
    # Kit. Link that real owner normally: global -all_load would load Swift
    # archives twice when their module dependencies also autolink them.
    target_link_libraries(ubiquitty-core-ios-link PRIVATE UbiquittyKitModule)
    set_property(TARGET ubiquitty-core-ios-link PROPERTY LINKER_LANGUAGE Swift)

    set(UBIQUITTY_IOS_APP_SOURCES
        Source/Platform/iOS/App/UbiquittyApp.swift
        Source/Platform/iOS/App/HostLabel.swift
        Source/Platform/iOS/App/HostRecord.swift
        Source/Platform/iOS/App/HostStore.swift
        Source/Platform/iOS/App/SessionStore.swift
        Source/Platform/iOS/App/SecretStore.swift
        Source/Platform/iOS/App/BackgroundRefreshStore.swift
        Source/Platform/iOS/App/BackgroundRefreshAuthorization.swift
        Source/Platform/iOS/App/BackgroundRefreshRun.swift
        Source/Platform/iOS/App/BackgroundRefreshConnection.swift
        Source/Platform/iOS/App/BackgroundRefreshCoordinator.swift
        Source/Platform/iOS/App/NotificationPresentation.swift
        Source/Platform/iOS/App/BackgroundRefreshView.swift
        Source/Platform/iOS/App/BackgroundRefreshSmoke.swift
        Source/Platform/iOS/App/ColdResumeDescriptor.swift
        Source/Platform/iOS/App/ColdResumeSession.swift
        Source/Platform/iOS/App/ColdResumeSmoke.swift
        Source/Platform/iOS/App/LiveHostSeed.swift
        Source/Platform/iOS/App/HostListView.swift
        Source/Platform/iOS/App/HostSessionsView.swift
        Source/Platform/iOS/App/WorkspaceRows.swift
        Source/Platform/iOS/App/HostLiveOutlineRows.swift
        Source/Platform/Apple/HostOutline/HostOutlineStore.swift
        Source/Platform/Apple/HostOutline/HostOutlineRowView.swift
        Source/Platform/Apple/HostOutline/HostOutlineList.swift
        Source/Platform/iOS/App/HostEditorView.swift
        Source/Platform/iOS/App/HostKeyView.swift
        Source/Platform/iOS/App/SignInPromptView.swift
        Source/Platform/iOS/App/ConnectionDetailsView.swift
        Source/Platform/iOS/App/TerminalKeyTranslation.swift
        Source/Platform/iOS/App/TerminalKeyboardInput.swift
        Source/Platform/iOS/App/TerminalAccessoryKey.swift
        Source/Platform/iOS/App/TerminalKeyboardAccessory.swift
        Source/Platform/iOS/App/SSHCarrierClient.swift
        Source/Platform/iOS/App/SSHFailurePresentation.swift
        Source/Platform/iOS/App/QUICBootstrapProbe.swift
        Source/Platform/iOS/App/QUICBootstrapClosePolicy.swift
        Source/Platform/iOS/App/QUICCarrierProvider.swift
        Source/Platform/iOS/App/SyncSSHCarrier.swift
        Source/Platform/iOS/App/NetworkPathSmoke.swift
        Source/Platform/iOS/App/PasswordLockSmoke.swift
        Source/Platform/iOS/App/SSHPipelineSmoke.swift
        Source/Platform/iOS/App/SSHConnectSmoke.swift
        Source/Platform/iOS/App/SecretStoreSmoke.swift
        Source/Platform/iOS/App/HostRecordSmoke.swift
        Source/Platform/iOS/App/SecondPickSmoke.swift
        Source/Platform/iOS/App/RedialSmoke.swift
        Source/Platform/iOS/App/BootstrapRetrySmoke.swift
        Source/Platform/iOS/App/BootstrapSupersedeSmoke.swift
        Source/Platform/iOS/App/TerminalGroundSmoke.swift
        Source/Platform/iOS/App/HintSmoke.swift
        Source/Platform/iOS/App/ScreenVisibilitySmoke.swift
        Source/Platform/iOS/App/BackgroundViewSmoke.swift
        Source/Platform/iOS/App/PaneArrangementSmoke.swift
        Source/Platform/iOS/App/SwipeNavigationSmoke.swift
        Tests/Platform/KeyboardAccessorySmoke.swift
        Tests/Platform/NotificationPresentationSmoke.swift
        Source/Platform/iOS/App/PointerLockSmoke.swift
        Source/Platform/iOS/App/CursorBlinkSmoke.swift
        Source/Platform/iOS/App/SurfaceFocusSmoke.swift
        Source/Platform/iOS/App/InlineImageSmoke.swift
        Source/Platform/iOS/App/ConfigurationSmoke.swift
        Source/Platform/iOS/App/RichTextSmoke.swift
        Source/Platform/iOS/App/SkipInkSmoke.swift
        Source/Platform/iOS/App/ConnectionLog.swift
        Source/Platform/iOS/App/ConnectionLogSmoke.swift
        Source/Platform/iOS/App/TerminalPaneArrangement.swift
        Source/Platform/iOS/App/TerminalSwipeNavigation.swift
        Source/Platform/iOS/App/TerminalSurfaceHost.swift
        Source/Platform/iOS/App/TerminalSessionModel.swift
        Source/Platform/iOS/App/AppSettingsModel.swift
        Source/Platform/iOS/App/ReceivedFilePreview.swift
        Source/Platform/iOS/App/AppSettingsView.swift
        Source/Platform/iOS/App/AccessoryKeysView.swift
        Source/Platform/iOS/App/FallbackFontsView.swift
        Source/Platform/iOS/App/TerminalFontPicker.swift
        Source/Platform/iOS/App/TerminalDictation.swift
        Source/Platform/iOS/App/TerminalVoiceTranscript.swift
        Source/Platform/iOS/App/InterfaceConventions.swift
        Source/Platform/iOS/App/TerminalChrome.swift
        Source/Platform/iOS/App/TerminalToolsView.swift
        Source/Platform/iOS/App/TerminalTabs.swift
        Source/Platform/iOS/App/TerminalTabOverview.swift
        Source/Platform/iOS/App/TerminalFind.swift
        Source/Platform/iOS/App/TerminalScreenView.swift
        Source/Platform/iOS/App/IOSSnapshotLaunch.swift
        Source/Platform/iOS/App/SmokeLaunch.swift)

    # The shaders the renderer loads, compiled for the SDK being built. Same
    # source as the macOS arm: a shader is not platform code, and a second copy
    # would be a second renderer by another route.
    set(_ubq_ios_metal_lib "${UBIQUITTY_IOS_PLATFORM_DIR}/default.metallib")
    add_custom_command(
        OUTPUT "${_ubq_ios_metal_lib}"
        COMMAND ${UBIQUITTY_IOS_STEP} -DSTEP=shaders -P "${UBIQUITTY_IOS_STEP_SCRIPT}"
        DEPENDS "${CMAKE_SOURCE_DIR}/Source/UbiquittyRenderKit/UBShaders.metal"
                "${CMAKE_SOURCE_DIR}/Source/Core/Tek/BeamRaster.h"
                "${UBIQUITTY_IOS_STEP_SCRIPT}"
        COMMENT "Compiling UBShaders.metal for ${UBIQUITTY_IOS_PLATFORM_LABEL}"
        VERBATIM)
    add_custom_target(ubiquitty-ios-shaders DEPENDS "${_ubq_ios_metal_lib}")

    # The shell's own module carries it too. It reaches Core's frame capture
    # directly, so it inlines the same headers the kits do.
    add_executable(UbiquittyIOSApp MACOSX_BUNDLE ${UBIQUITTY_IOS_APP_SOURCES})
    ubiquitty_ios_swift_whole_module(UbiquittyIOSApp)
    ubiquitty_bundle_license_notices(UbiquittyIOSApp)
    # The target mixes CXX and Swift; CMake links it through swiftc and appends
    # the implicit C++ stdlib for the CXX side too, so "-lc++" lands on the link
    # line twice and ld warns "ignoring duplicate libraries" — the same doubling
    # the macOS app silences the same way (Source/Platform/macOS/CMakeLists.txt).
    target_link_options(UbiquittyIOSApp PRIVATE
        "SHELL:-Xlinker -no_warn_duplicate_libraries")
    # Every file BundledFonts.h names. A family in that table whose file is not
    # here resolves to a path that does not exist, and the frontend does not
    # stop there: it falls through to the embedded Unifont, which renders, so
    # the failure is a picture in the wrong face. Scripts/check-bundled-fonts.py
    # compares this list against the table.
    set(UBIQUITTY_IOS_BUNDLED_FONT_FILES
        "JetBrainsMono[wght].ttf"
        "JetBrainsMono-Italic[wght].ttf"
        "MonaspaceNeon-Regular.otf"
        "MonaspaceNeon-Bold.otf"
        "MonaspaceNeon-Italic.otf"
        "MonaspaceNeon-BoldItalic.otf"
        "MonaspaceNeonVar.ttf"
        "NotoSans-Regular.ttf"
        "NotoSans-Bold.ttf"
        "NotoColorEmoji-COLRv1.ttf"
        "SymbolsNerdFontMono-Regular.ttf")
    set(UBIQUITTY_IOS_BUNDLED_FONTS "")
    # UIAppFonts from the same list. A file staged into the bundle and left out
    # of this key is present and unregistered: `UIFont(name:)` cannot open it,
    # the app falls to the system face, and the grid comes out at another
    # family's metrics with nothing reported. Spelling the two lists separately
    # is what let four files be copied and four registered while the table named
    # eight.
    set(UBIQUITTY_IOS_APP_FONTS_ENTRIES "")
    foreach(font IN LISTS UBIQUITTY_IOS_BUNDLED_FONT_FILES)
        list(APPEND UBIQUITTY_IOS_BUNDLED_FONTS "${CMAKE_SOURCE_DIR}/Resources/fonts/${font}")
        string(APPEND UBIQUITTY_IOS_APP_FONTS_ENTRIES
            "        <string>fonts/${font}</string>\n")
    endforeach()
    ubiquitty_bundle_resources(UbiquittyIOSApp "fonts" ${UBIQUITTY_IOS_BUNDLED_FONTS})
    # The privacy manifest, at the bundle's root, where App Store Connect reads
    # it: the required-reason APIs the app calls and why.
    ubiquitty_bundle_resources(UbiquittyIOSApp ""
        "${CMAKE_SOURCE_DIR}/Source/Platform/iOS/App/PrivacyInfo.xcprivacy")
    # The app icon: the same Icon Composer document the macOS bundle compiles
    # (Scripts/build-macos.sh), compiled by actool for the SDK being built.
    # Assets.car is what iOS 26 draws; the two PNGs are the fallbacks actool
    # writes beside it and Info.plist.in's CFBundleIcons names, all at the
    # bundle's root. Scripts/cmake/IOSPlatformStep.cmake names the same three
    # files, since it is what writes them and what copies them.
    set(_ubq_ios_icon_source "${CMAKE_SOURCE_DIR}/Resources/Icon/Ubiquitty.icon")
    set(_ubq_ios_icon_dir "${UBIQUITTY_IOS_PLATFORM_DIR}/ios-app-icon")
    # The scale is spelled through a variable because a file name with the
    # scale suffix written out reads as a mail address to
    # Scripts/check-personal-paths.py.
    set(_ubq_ios_icon_scale "2x")
    set(_ubq_ios_icon_outputs
        "${_ubq_ios_icon_dir}/Assets.car"
        "${_ubq_ios_icon_dir}/Ubiquitty60x60@${_ubq_ios_icon_scale}.png"
        "${_ubq_ios_icon_dir}/Ubiquitty76x76@${_ubq_ios_icon_scale}~ipad.png")
    file(GLOB _ubq_ios_icon_inputs CONFIGURE_DEPENDS
        "${_ubq_ios_icon_source}/icon.json" "${_ubq_ios_icon_source}/Assets/*")
    add_custom_command(
        OUTPUT ${_ubq_ios_icon_outputs}
        COMMAND ${UBIQUITTY_IOS_STEP} -DSTEP=icon -P "${UBIQUITTY_IOS_STEP_SCRIPT}"
        DEPENDS ${_ubq_ios_icon_inputs} "${UBIQUITTY_IOS_STEP_SCRIPT}"
        COMMENT "Compiling Ubiquitty.icon for ${UBIQUITTY_IOS_PLATFORM_LABEL}"
        VERBATIM)
    add_custom_target(ubiquitty-ios-app-icon DEPENDS ${_ubq_ios_icon_outputs})
    add_dependencies(UbiquittyIOSApp ubiquitty-ios-app-icon)
    target_sources(UbiquittyIOSApp PRIVATE "${UBIQUITTY_SWIFT_INTEROP_STAMP}")
    add_dependencies(UbiquittyIOSApp ubiquitty-ios-shaders)
    # The icon and the shader library, copied after the link rather than
    # declared as bundle sources. With the Ninja generator a
    # MACOSX_PACKAGE_LOCATION file of this Swift target is only an order
    # dependency of object files the target does not have, so nothing builds it
    # and the bundle ships without it; LINK_DEPENDS relinks the app when the
    # icon changes, which is what runs the copy again. With Xcode a bundle
    # source is one fixed path in the project, and these two have a path per
    # SDK, so the copy is the form both generators can share.
    if(NOT CMAKE_GENERATOR MATCHES "Xcode")
        set_property(TARGET UbiquittyIOSApp APPEND PROPERTY LINK_DEPENDS ${_ubq_ios_icon_outputs})
    endif()
    # Not VERBATIM: under Xcode the bundle directory is spelled with a build
    # setting the phase's shell has to expand.
    add_custom_command(TARGET UbiquittyIOSApp POST_BUILD
        COMMAND ${UBIQUITTY_IOS_STEP} -DSTEP=stage
                "-DBUNDLE=$<TARGET_BUNDLE_DIR:UbiquittyIOSApp>"
                -P "${UBIQUITTY_IOS_STEP_SCRIPT}"
        COMMENT "Copying the app icon and default.metallib into the iOS app")
    add_dependencies(UbiquittyIOSApp ubiquitty-ssh-ios)
    # The simulator's securityd gates the keychain on the
    # application-identifier entitlement: an app without one has every
    # SecItemAdd refused with -34018, and each credential the host editor
    # saves is silently dropped. The entitlements cannot ride the code
    # signature — a simulator app is a host process, and the host kernel
    # refuses to spawn an ad-hoc binary claiming restricted entitlements
    # (POSIX 163). They ride the executable instead, in the two __TEXT
    # sections the simulator runtime reads and the host kernel does not:
    # __entitlements holds the plist, __ents_der its DER form, which is
    # how Xcode signs its own simulator builds.
    if("iphonesimulator" IN_LIST UBIQUITTY_IOS_SDKS)
        set(_ubq_ios_sim_entitlements
            "${CMAKE_SOURCE_DIR}/Source/Platform/iOS/App/Simulator.entitlements")
        set(_ubq_ios_sim_entitlements_der
            "${CMAKE_CURRENT_BINARY_DIR}/simulator-entitlements.der")
        execute_process(
            COMMAND xcrun derq query -f xml
                    -i "${_ubq_ios_sim_entitlements}"
                    -o "${_ubq_ios_sim_entitlements_der}" --raw
            RESULT_VARIABLE _ubq_ios_derq_result)
        if(NOT _ubq_ios_derq_result EQUAL 0)
            message(FATAL_ERROR "derq could not encode ${_ubq_ios_sim_entitlements}")
        endif()
        # Regenerated when the plist changes: the DER is made at configure
        # time, so the plist has to be able to trigger one.
        set_property(DIRECTORY APPEND PROPERTY
            CMAKE_CONFIGURE_DEPENDS "${_ubq_ios_sim_entitlements}")
    endif()
    if(CMAKE_GENERATOR MATCHES "Xcode")
        # Both SDKs from one project, so the two sections are the simulator's
        # alone by a response file per SDK: the device's is empty. The link
        # line names whichever the destination selects. A build setting
        # conditioned on the SDK would say the same thing, and CMake quotes a
        # setting reference on a link line into a single argument, empty on a
        # device.
        file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/iphoneos/link-options.rsp" "")
        file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/iphonesimulator/link-options.rsp"
            "\"-Wl,-sectcreate,__TEXT,__entitlements,${_ubq_ios_sim_entitlements}\"\n"
            "\"-Wl,-sectcreate,__TEXT,__ents_der,${_ubq_ios_sim_entitlements_der}\"\n")
        target_link_options(UbiquittyIOSApp PRIVATE
            "@${UBIQUITTY_IOS_PLATFORM_DIR}/link-options.rsp")
        # A device build signs; a simulator build cannot use a signature for
        # what it needs and so carries none.
        set(_ubq_ios_codesign_allowed YES)
        set_target_properties(UbiquittyIOSApp PROPERTIES
            "XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]" NO
            # The scheme the workspace offers, written by the generator rather
            # than left for Xcode to invent from the target list, so its name
            # and what it builds are the same on every machine.
            XCODE_GENERATE_SCHEME ON
            # Installed by an archive into Products/Applications, where App
            # Store Connect reads the app from. The generator writes an empty
            # INSTALL_PATH for an application, and an archive leaves a product
            # with no install path among its uninstalled products.
            XCODE_ATTRIBUTE_SKIP_INSTALL NO
            XCODE_ATTRIBUTE_INSTALL_PATH "$(LOCAL_APPS_DIR)")
        # Every other target stays out of the archive. An archive that installs
        # a library, a link probe or anything else beside the app is a generic
        # archive, which App Store Connect refuses. Said once for the project,
        # where every target inherits it, and overridden by the app alone.
        # Scripts/check-xcode-workspace.py reads both from the generated project.
        set(CMAKE_XCODE_ATTRIBUTE_SKIP_INSTALL YES)
    elseif("iphonesimulator" IN_LIST UBIQUITTY_IOS_SDKS)
        set(_ubq_ios_codesign_allowed NO)
        target_link_options(UbiquittyIOSApp PRIVATE
            "LINKER:-sectcreate,__TEXT,__entitlements,${_ubq_ios_sim_entitlements}"
            "LINKER:-sectcreate,__TEXT,__ents_der,${_ubq_ios_sim_entitlements_der}")
    else()
        set(_ubq_ios_codesign_allowed YES)
    endif()
    # Xcode writes UIDeviceFamily from TARGETED_DEVICE_FAMILY and warns about a
    # plist that carries its own; any other generator has only this template.
    if(CMAKE_GENERATOR MATCHES "Xcode")
        set(UBIQUITTY_IOS_PLIST_DEVICE_FAMILY "")
    else()
        set(UBIQUITTY_IOS_PLIST_DEVICE_FAMILY
            "    <key>UIDeviceFamily</key>\n    <array>\n        <integer>1</integer>\n        <integer>2</integer>\n    </array>\n")
    endif()
    set_target_properties(UbiquittyIOSApp PROPERTIES
        OUTPUT_NAME "Ubiquitty"
        Swift_MODULE_NAME "UbiquittyIOSApp"
        # The module name again, as the setting Xcode reads. Without it Xcode
        # names the module for the product, `Ubiquitty`, which is not the
        # module the Ninja build compiles and is the name of Core's namespace.
        XCODE_ATTRIBUTE_PRODUCT_MODULE_NAME "UbiquittyIOSApp"
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/Source/Platform/iOS/App/Info.plist.in"
        MACOSX_BUNDLE_BUNDLE_NAME "Ubiquitty"
        MACOSX_BUNDLE_GUI_IDENTIFIER "org.ubiquitty.Ubiquitty"
        MACOSX_BUNDLE_BUNDLE_VERSION "${UBIQUITTY_IOS_BUNDLE_VERSION}"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${UBIQUITTY_VERSION_NAMED}"
        # The same identifier again, as a build setting.
        # MACOSX_BUNDLE_GUI_IDENTIFIER substitutes into the Info.plist template,
        # which is all the Ninja build reads. Xcode additionally compares that
        # plist against its own PRODUCT_BUNDLE_IDENTIFIER and refuses a target
        # where the two disagree, and unset reads as disagreeing.
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "org.ubiquitty.Ubiquitty"
        # iPhone and iPad. Xcode writes UIDeviceFamily from this setting and
        # warns about a plist that carries its own.
        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
        # Automatic, with the team named: Xcode resets an unset team to nothing
        # on every regeneration, and a device build cannot sign without one.
        XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
        XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${UBIQUITTY_DEVELOPMENT_TEAM}"
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED ${_ubq_ios_codesign_allowed})
    target_compile_options(UbiquittyIOSApp PRIVATE
        # The C seam arrives as a clang module rather than a bridging header:
        # there is no Objective-C in this frontend to hang one off.
        # The shell reads Core's frame capture directly, the way the macOS
        # shell's Swift does — no value-object facade between the surface and
        # the model it draws.
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:${UBIQUITTY_IOS_SWIFT_FLAGS}>"
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-I ${CMAKE_SOURCE_DIR}/Source/Platform/iOS>"
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-I ${CMAKE_CURRENT_BINARY_DIR}>"
        # The module search path and every generated C module map, read from a
        # response file because the set is the dependency graph's rather than
        # ours and does not exist until the package has been built.
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:@${_ubq_ssh_flags}>")
    target_link_libraries(UbiquittyIOSApp PRIVATE
        UbiquittyKitModule
        UbiquittyRenderKit
        ubiquitty-ios-bridge
        "${_ubq_ssh_archive}")
    if(CMAKE_GENERATOR MATCHES "Xcode")
        # The SDK as the build setting, which Xcode resolves for the
        # destination. The path xcrun answers at configure time is one SDK's,
        # with its version in it: wrong for the other destination at once, and
        # wrong for both after the next Xcode update renames the directory.
        foreach(_swift_link_target UbiquittyIOSApp ubiquitty-core-ios-link)
            target_link_options(${_swift_link_target} PRIVATE
                "SHELL:-isysroot $(SDKROOT)"
                "LINKER:-F,$(SDKROOT)/System/Library/Frameworks")
        endforeach()
    else()
        # swiftc links through clang, and passes its own -sdk no further: the
        # clang it drives falls back to the host's sysroot and warns that it is
        # building for iPhone against MacOSX. Hand that clang the SDK directly.
        foreach(_swift_link_target UbiquittyIOSApp ubiquitty-core-ios-link)
            target_link_options(${_swift_link_target} PRIVATE
                "SHELL:-Xclang-linker -isysroot -Xclang-linker ${_ubq_ios_sdk_path}"
                "LINKER:-F,${_ubq_ios_sdk_path}/System/Library/Frameworks")
        endforeach()
    endif()
    # ------------------------------------------------------------------
    # UbiquittyUITests — the XCUITest bundle, driven by Scripts/run-ios-ui-tests.sh.
    #
    # A bundle rather than a library, and it links no app code: an XCUITest runs
    # in its own process and reaches the application through the automation
    # daemon, so the only thing it shares with the app is the bundle identifier
    # it names. That is the point — a suite that could call into the app would be
    # able to assert on state no finger can reach.
    #
    # Simulator only. XCTRunner on a device needs a provisioning profile and a
    # real signing identity, which a development machine may not have (see the macOS
    # codesign note), so a device configuration would produce a bundle nothing
    # here can run.
    option(UBIQUITTY_IOS_UI_TESTS "Build the iOS XCUITest bundle" OFF)
    if(UBIQUITTY_IOS_UI_TESTS AND CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
        # The consent check feeds Core's real queue, through a door normal
        # applications cannot see. Keep the importer and C++ definitions in
        # agreement without enabling the desktop-only UI harness.
        foreach(_swift_target UbiquittyIOSApp UbiquittyRenderKit UbiquittyKitModule)
            target_compile_options(${_swift_target} PRIVATE
                "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-DUBIQUITTY_IOS_UI_TESTS>"
                "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xcc -DUBIQUITTY_IOS_UI_TESTS=1>")
        endforeach()
        foreach(_core_target ubiquitty-core-ios ubiquitty-ios-bridge ubiquitty-core-ios-link)
            target_compile_definitions(${_core_target} PRIVATE
                "$<$<COMPILE_LANGUAGE:CXX>:UBIQUITTY_IOS_UI_TESTS=1>")
        endforeach()
        target_compile_definitions(UbiquittyIOSApp PRIVATE
            "$<$<COMPILE_LANGUAGE:CXX>:UBIQUITTY_IOS_UI_TESTS=1>")
        set(_ubq_ios_uitest_platform
            "${CMAKE_OSX_SYSROOT}")
        execute_process(
            COMMAND xcrun --sdk iphonesimulator --show-sdk-platform-path
            OUTPUT_VARIABLE _ubq_ios_uitest_platform_path
            OUTPUT_STRIP_TRAILING_WHITESPACE)
        set(_ubq_ios_uitest_frameworks
            "${_ubq_ios_uitest_platform_path}/Developer/Library/Frameworks")
        set(_ubq_ios_uitest_libraries
            "${_ubq_ios_uitest_platform_path}/Developer/usr/lib")

        add_library(UbiquittyUITests MODULE
            Source/Platform/iOS/UITest/TerminalGestureUITests.swift)
        set_target_properties(UbiquittyUITests PROPERTIES
            BUNDLE TRUE
            BUNDLE_EXTENSION "xctest"
            OUTPUT_NAME "UbiquittyUITests"
            Swift_MODULE_NAME "UbiquittyUITests"
            MACOSX_BUNDLE_INFO_PLIST
                "${CMAKE_SOURCE_DIR}/Source/Platform/iOS/UITest/Info.plist.in"
            MACOSX_BUNDLE_BUNDLE_NAME "UbiquittyUITests"
            MACOSX_BUNDLE_GUI_IDENTIFIER "org.ubiquitty.Ubiquitty.uitests"
            MACOSX_BUNDLE_BUNDLE_VERSION "${UBIQUITTY_BUNDLE_VERSION}"
            MACOSX_BUNDLE_SHORT_VERSION_STRING "${UBIQUITTY_VERSION_NAMED}"
            XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "org.ubiquitty.Ubiquitty.uitests"
            LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
            XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
        target_compile_options(UbiquittyUITests PRIVATE
            # XCTest arrives as a clang module from the platform's framework
            # directory; its SWIFT overlay is a separate .swiftmodule beside the
            # dylib, and without the -I the import resolves to the C headers
            # alone and every XCTAssert is "cannot find in scope".
            "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-F ${_ubq_ios_uitest_frameworks}>"
            "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-I ${_ubq_ios_uitest_libraries}>")
        target_link_options(UbiquittyUITests PRIVATE
            "SHELL:-F ${_ubq_ios_uitest_frameworks}"
            "SHELL:-L ${_ubq_ios_uitest_libraries}"
            "SHELL:-lXCTestSwiftSupport"
            "SHELL:-Xclang-linker -isysroot -Xclang-linker ${_ubq_ios_sdk_path}"
            # A .xctest is a Mach-O BUNDLE, not a dylib. CMake's MODULE gives a
            # dylib on Apple platforms, and XCTest refuses to load one.
            "LINKER:-bundle"
            # Both, because the bundle is loaded from the runner app's PlugIns
            # and its dependencies sit beside the runner rather than beside it.
            "LINKER:-rpath,@executable_path/Frameworks"
            "LINKER:-rpath,@loader_path/Frameworks")
    endif()

    target_link_options(UbiquittyIOSApp PRIVATE
        # -force_load, and it is not an optimisation. A Swift archive carries its
        # protocol conformances and type metadata in __swift5_* sections of the
        # member objects, and a member no symbol reference pulls in takes its
        # metadata with it. The link still succeeds — the conformance is found at
        # compile time from the module — and the program then faults inside a
        # library it never called, on a vtable that was never registered.
        "LINKER:-force_load,${_ubq_ssh_archive}")

    # What every product of the Xcode project's Release configuration, which is
    # what an archive builds, is built with beyond the flags. Set per target,
    # for every product of this directory, so a target added later is held to
    # it; Scripts/check-xcode-workspace.py reads each setting back.
    #
    # - Debug information, kept as a dSYM: App Store Connect symbolicates a
    #   TestFlight crash from it. The generator writes
    #   GCC_GENERATE_DEBUGGING_SYMBOLS on each target from whether the
    #   configuration's flags carry -g, and Release's carry none.
    # - The dSYM written where an archive gathers dSYMs from, which is the build
    #   products folder Xcode would choose,
    #   $(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME). The generator
    #   points CONFIGURATION_BUILD_DIR into this build tree, where a dSYM is
    #   written and never archived.
    # - No clang module breadcrumbs in Swift's debug information. They name the
    #   explicitly built .pcm files, which dsymutil cannot find when it runs and
    #   warns about, one by one. Swift's own debug information is unchanged, and
    #   lldb imports the clang modules from their headers.
    # - Link-time optimization wherever C or C++ is compiled. The generator
    #   writes LLVM_LTO only for a target it links as C or C++, and the link
    #   probe links as Swift because it links the Swift kits; the Ninja build
    #   compiles its C++ for link-time optimization like any other.
    if(CMAKE_GENERATOR MATCHES "Xcode")
        get_property(_ubq_ios_targets DIRECTORY PROPERTY BUILDSYSTEM_TARGETS)
        foreach(_ubq_ios_target IN LISTS _ubq_ios_targets)
            get_target_property(_ubq_ios_target_type ${_ubq_ios_target} TYPE)
            if(NOT _ubq_ios_target_type MATCHES "^(STATIC_LIBRARY|SHARED_LIBRARY|MODULE_LIBRARY|EXECUTABLE)$")
                continue()
            endif()
            set_target_properties(${_ubq_ios_target} PROPERTIES
                "XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS[variant=Release]" YES
                "XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT[variant=Release]" dwarf-with-dsym
                "XCODE_ATTRIBUTE_DWARF_DSYM_FOLDER_PATH[variant=Release]"
                    "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)")
            target_compile_options(${_ubq_ios_target} PRIVATE
                "$<$<AND:$<COMPILE_LANGUAGE:Swift>,$<CONFIG:Release>>:SHELL:-Xfrontend -no-clang-module-breadcrumbs>")
            get_target_property(_ubq_ios_target_sources ${_ubq_ios_target} SOURCES)
            list(FILTER _ubq_ios_target_sources INCLUDE REGEX "\\.(c|cc|cpp|cxx|m|mm)$")
            if(_ubq_ios_target_sources)
                foreach(_ubq_ios_configuration IN ITEMS Release RelWithDebInfo MinSizeRel)
                    string(TOUPPER "${_ubq_ios_configuration}" _ubq_ios_configuration_upper)
                    if(CMAKE_INTERPROCEDURAL_OPTIMIZATION_${_ubq_ios_configuration_upper})
                        # Thin, as the generator writes it for clang.
                        set_property(TARGET ${_ubq_ios_target} PROPERTY
                            "XCODE_ATTRIBUTE_LLVM_LTO[variant=${_ubq_ios_configuration}]" YES_THIN)
                    endif()
                endforeach()
            endif()
        endforeach()
    endif()

# ----------------------------------------------------------------------
# Host — ubiquitty-host, the persistent session daemon: the Core runs on the
# server and Ubiquitty attaches as a thin client (Docs/architecture.md §9a).
#
# A portable-POSIX binary (no Cocoa / Metal / Swift):
# the portable Core subset + Source/Core/Protocol/Sync (the wire protocol) + the
# POSIX PTY (Source/Platform/Host/PTY) + the host PAL down-functions
# (HostPAL) + the host main. Builds with clang on macOS (local testing)
# and gcc on Linux. The Core source list mirrors the test_sync
# link set in Scripts/run-tests.sh — a live Terminal pulls in the full OSC /
# SGR / Tek / Kitty / Unicode dispatch surface.
# ----------------------------------------------------------------------
elseif(UBIQUITTY_FRONTEND STREQUAL "Host")

    # The host daemon's Core link set = the canonical portable-Core list minus
    # the TUs a headless, render-free server never references. The minimal
    # daemon drops the on-screen renderers (box/glyph/software/Unifont),
    # the input encoders, selection, session-persistence + the layout/process
    # model, the local-socket/poll transports, and the QUIC client carrier (the
    # daemon listens via HostQUIC, gated below). A Core .cpp added to the SSOT
    # flows in here automatically unless it joins this trim list.
    # Theme resolution, palette adaptation, and trigger configuration stay:
    # the host seeds terminals with the same launch policy as graphical clients.
    ubiquitty_core_subset(UBIQUITTY_HOST_CORE EXCLUDE
        # App-level theme/appearance/config-reload policy, which drives a host
        # seam a GUI frontend implements. A headless arm follows no system
        # appearance and watches no config file, and keeping it drags the whole
        # Themes resolution in behind it.
        Source/Core/App/AppRuntime.cpp
        # The first-launch Welcome screen and the shell wrapper one of its
        # buttons installs. A headless arm shows no screen and installs nothing
        # into a reader's startup files.
        Source/Core/App/ShellIntegrationInstall.cpp
        Source/Core/App/WelcomeScreen.cpp
        # The theme list and a theme's colours, for a frontend's picker. A
        # headless arm shows none, and keeping it drags Themes resolution in
        # behind it, exactly as AppRuntime above does.
        Source/Core/Themes/ThemeApply.cpp
        # Codec::JSON, ControlRPC and the method registry stay: a Sync
        # `Call` is a JSON-RPC request the daemon reads (Sync/Control.cpp) and
        # serves only when the registry's Sync column names it, so yyjson
        # joins the target below. The schema validator stays with them: the
        # daemon checks a call's parameters against its entry's schema before
        # any effect (Control::admitCall). The control socket's server goes:
        # the daemon serves its calls over the Sync protocol, not the
        # frontends' JSON-RPC socket.
        Source/Core/Protocol/Control/Server.cpp
        # LinkRun.cpp STAYS in the daemon's set since the frame capture
        # learned to resolve link kinds: TerminalFrameInputs.cpp is kept and
        # references kindForLinkID unconditionally, and this list resolves
        # names, not the call graph — trimming it again surfaces only at
        # link time, in every stanza linking the daemon's objects. The
        # pointer-hover walk below still goes: nothing kept calls it.
        # PAL/Process.cpp STAYS: the daemon reads a hosted pane's facts with
        # the walk reading a local pane uses (Session::walkedProcessFacts), so
        # the chain a title shows is formatted by the same code on both sides.
        Source/Core/Screen/VisibleLink.cpp
        Source/PAL/ProcessSignal.cpp
        # ScrollSearch.cpp stays: `pane.search` runs its history search on the
        # host (Sync/Control.cpp), and RE2 joins the target below.
        Source/Core/Screen/ScrollTuning.cpp
        Source/Core/Session/SessionInfo.cpp
        # The drawing-debug readout draws for a frontend the daemon is not.
        # The heatmap's counters stay: the frame capture kept here feeds them.
        Source/Core/Diagnostics/DrawingDebug.cpp
        Source/Core/Input/ComposeEngine.cpp
        Source/Core/Input/Keybindings.cpp
        # Keys/Keymap.cpp and Keys/KittyKeyboard.cpp stay: a remote client's
        # keys are encoded here, under the pane's live modes
        # (Runtime/RemoteInput.cpp).
        Source/Core/Input/PointerInput.cpp
        Source/Core/Input/PointerLadder.cpp
        Source/Core/Protocol/Tmux/Commands.cpp
        Source/Core/Protocol/Tmux/Session.cpp
        Source/Core/Runtime/TmuxControlHost.cpp
        Source/Core/Protocol/Tmux/Tiler.cpp
        Source/Core/Rendering/BoxDrawCommands.cpp
        Source/Core/Rendering/BoxDrawing.cpp
        Source/Core/Rendering/BoxEdgeStretch.cpp
        Source/Core/Rendering/BoxFillEmit.cpp
        Source/Core/Rendering/BoxGlyphRaster.cpp
        Source/Core/Rendering/BoxStrokeProfile.cpp
        Source/Core/Rendering/CellInstanceBuilder.cpp
        Source/Core/Rendering/LetterLayout.cpp
        Source/Core/Rendering/OverlayAssembly.cpp
        Source/Core/Selection/SelectionSpans.cpp
        # The Terminal-bound selection facade is per-view UI machinery over the
        # span gathers the line above trims: a headless daemon drives no mouse
        # gesture, and keeping the facade while trimming its gathers is exactly
        # the link error that motivates trimming them together.
        Source/Core/Selection/TerminalSelection.cpp
        # The overlay span gathers walk search/hilite/trigger state into row
        # spans for a frame the daemon never draws; they reference the trimmed
        # renderers (ScrollSearch, OverlayGeometry), so they travel with them.
        Source/Core/Rendering/OverlaySpanGather.cpp
        Source/Core/Rendering/ColorResolve.cpp
        Source/Core/Rendering/FontFeatureSpecification.cpp
        Source/Core/Rendering/FontVariationSpecification.cpp
        Source/Core/Rendering/ShapedCellCache.cpp
        Source/Core/Rendering/LigatureClassification.cpp
        Source/Core/Rendering/FontMetrics.cpp
        Source/Core/Rendering/GlyphSlotCache.cpp
        Source/Core/Rendering/LigatureSheet.cpp
        Source/Core/Rendering/OverlayGeometry.cpp
        Source/Core/Rendering/PNGEncoder.cpp
        Source/Core/Rendering/ProportionalGlyphSheet.cpp
        Source/Core/Rendering/SoftwareRenderer.cpp
        Source/Core/Rendering/BackgroundImage.cpp
        Source/Core/Rendering/TerminalSnapshot.cpp
        Source/Core/Rendering/BundledRichText.cpp
        Source/Core/Rendering/Unifont.cpp
        Source/Core/Rendering/ProportionalStrike.cpp
        Source/Core/Rendering/ProportionalStrikeData.cpp
        Source/Core/Rendering/ProportionalOutline.cpp
        Source/Core/Rendering/ProportionalOutlineData.cpp
        Source/Core/Rendering/UnifontData.cpp
        # The proportional strip's raster and the copy decision arrived in Core
        # on 2026-09-05 and flowed into every subset, as a new Core .cpp does.
        # The daemon rasters nothing — it keeps no rasterizer, which is what
        # this one needs — and it runs no clipboard: the frontend decides a
        # copy and the daemon relays the bytes.
        Source/Core/Rendering/ProportionalStripRaster.cpp
        Source/Core/Selection/CopyClipboard.cpp
        Source/Core/Rendering/UnifontRasterizer.cpp
        Source/Core/Runtime/TerminalRuntime.cpp
        # Selection.cpp stays: Core/Screen/ClearBuffer.cpp is in the
        # SSOT and calls Selection::clear, so excluding it drops a definition a
        # kept translation unit needs. The exclude list resolves names, not the
        # call graph, so a trim like that surfaces only at link time.
        Source/Core/Selection/StyledClipboard.cpp
        # Layout::Workspace, Surface and the workspace record stay: the host is
        # the authority for a hosted workspace's topology (Docs/session-model.md
        # §6 — a daemon Session is a pane's leaf backing, the Workspace sits above
        # them). They are fixed-pool data with no platform or render types.
        # Runtime::WorkspaceSession is a different thing: the frontend's runtime
        # (TerminalSession, SwiftInterop) and stays out with TerminalRuntime.
        Source/Core/Terminfo/UbiquittyTerminfo.cpp
        Source/Core/Themes/ThemeImport.cpp
        Source/Core/Transport/LocalSocketChannel.cpp
        # LocalPTYChannel derives from PollChannel, so it must be trimmed
        # wherever its base is — otherwise its vtable, ctor and dtor have no
        # definition and the link fails (Release hides it by eliding the
        # unused vtable; Debug does not).
        Source/Core/Transport/DelegatedChannel.cpp
        Source/Core/Transport/KnownHosts.cpp
        Source/Core/Transport/LocalPTYChannel.cpp)
    # Unicode/Normalize.cpp is not trimmed: ScrollSearch, which `pane.search`
    # runs, calls it.

    add_executable(ubiquitty-host
        # Host frontend: the daemon main, the forkpty transport + platform seam,
        # and the host PAL down-functions (none of these live in the portable
        # SSOT — they are the server's own glue).
        Source/Platform/Host/main.cpp
        Source/Platform/POSIX/LocalHostInstall.cpp
        Source/Platform/Host/AttachRelay.cpp
        Source/Platform/Host/Daemon.cpp
        Source/Platform/Host/HandoverAdmission.cpp
        Source/Platform/Host/HandoverRequest.cpp
        Source/Platform/Host/HandoverAuthorityTables.cpp
        Source/Platform/Host/HandoverGlobalTables.cpp
        Source/Platform/Host/HandoverEffects.cpp
        Source/Platform/Host/HandoverRuntime.cpp
        Source/Platform/Host/HandoverTables.cpp
        Source/Platform/Host/HandoverWorkspaceTables.cpp
        Source/Platform/Host/HostTableHandover.cpp
        Source/Platform/Host/HostHandover.cpp
        Source/Platform/Host/HandoverStartup.cpp
        Source/Platform/Host/SessionHandoverFacts.cpp
        Source/Platform/Host/SessionHandover.cpp
        Source/Platform/POSIX/PTYStream.cpp
        Source/Platform/POSIX/PTYFacts.cpp
        Source/PAL/OutputQueue.cpp
        Source/Platform/Host/HostPaths.cpp
        Source/Platform/Host/ClipboardTool.cpp
        Source/Platform/Host/ResumeRecordTool.cpp
        Source/Platform/Host/ShellIntegrationFiles.cpp
        Source/Platform/Host/HostPAL.cpp
        # In-process adoption fixtures link this same POSIX ownership sender
        # as the native app, without an exiting descriptor-adoption CLI helper.
        Source/Platform/POSIX/SessionHandoff.cpp
        Source/Platform/POSIX/HandoverLease.cpp
        Source/Platform/POSIX/HandoverTransport.cpp
        # Portable Core (single-sourced from Scripts/portable-core-sources.txt;
        # ControlPaths + Tmux.cpp + NativeAttachment + QUICBootstrap come in via the
        # SSOT — Core's Terminal embeds the tmux -CC client, so Tmux.cpp stays).
        ${UBIQUITTY_HOST_CORE}
        ${UBIQUITTY_SIMDUTF_SOURCES}
        # Codec/JSON.cpp wraps it, for the calls Sync/Control.cpp reads.
        Source/ThirdParty/yyjson/yyjson.c
        # ScrollSearch.cpp stays in this subset for `pane.search`, so the RE2
        # units ride along.
        ${UBIQUITTY_RE2_SOURCES}
    )
    set_source_files_properties(Source/ThirdParty/yyjson/yyjson.c PROPERTIES
        COMPILE_FLAGS "-std=c99 -Wno-error -w")
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    set(_ubq_host_themes_gen ${CMAKE_CURRENT_BINARY_DIR}/BuiltinThemesData.gen.cpp)
    add_custom_command(
        OUTPUT ${_ubq_host_themes_gen}
        COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/Scripts/embed-builtin-themes.py
                ${CMAKE_SOURCE_DIR}/Source/Core/Themes/builtin-themes.toml
                ${_ubq_host_themes_gen}
        DEPENDS ${CMAKE_SOURCE_DIR}/Source/Core/Themes/builtin-themes.toml
                ${CMAKE_SOURCE_DIR}/Scripts/embed-builtin-themes.py
        VERBATIM)
    target_sources(ubiquitty-host PRIVATE ${_ubq_host_themes_gen})
    set(_ubq_host_shell_integration_gen ${CMAKE_CURRENT_BINARY_DIR}/ShellIntegrationScripts.gen.cpp)
    ubiquitty_generate_shell_integration_source(${_ubq_host_shell_integration_gen})
    target_sources(ubiquitty-host PRIVATE ${_ubq_host_shell_integration_gen})
    target_include_directories(ubiquitty-host PRIVATE Source)
    target_include_directories(ubiquitty-host SYSTEM PRIVATE "${UBIQUITTY_SIMDUTF_DIR}" "${UBIQUITTY_RE2_DIR}")
    target_compile_features(ubiquitty-host PRIVATE cxx_std_23)
    set_target_properties(ubiquitty-host PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    # No try/catch, no dynamic_cast/typeid in this target's code — drop
    # the C++ runtime overhead we don't use, matching the host test suite.
    target_compile_options(ubiquitty-host PRIVATE
        -fno-exceptions -fno-rtti -Wall -Wextra
        ${UBIQUITTY_NARROWING_WARNING}
        "$<$<BOOL:${UBIQUITTY_WERROR}>:-Werror>")
    # A release's host trusts its successor, its app and its relay by the
    # release team's code signature alone, and refuses an unsigned or ad hoc
    # binary wherever it lies; a development build also trusts the files it
    # was installed as and resolved, as it runs unsigned or under a
    # development certificate (Source/Platform/Host/SignaturePolicy.h). Off
    # unless a release build turns it on through
    # build-macos.sh --release-signing and build-host.sh.
    option(UBIQUITTY_RELEASE_SIGNING "The host trusts only the release team's code signature" OFF)
    target_compile_definitions(ubiquitty-host PRIVATE UBIQUITTY_RELEASE_SIGNING=$<BOOL:${UBIQUITTY_RELEASE_SIGNING}>)
    # forkpty lives in libutil on Linux (glibc); on macOS it is in libc
    # via <util.h>, so the link is a no-op there.
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        target_link_libraries(ubiquitty-host PRIVATE util)
    endif()
    if(APPLE)
        target_link_libraries(ubiquitty-host PRIVATE "-framework CoreFoundation" "-framework Security")
    endif()
    # QUIC listener (ngtcp2 + AWS-LC), opt-in. Link order: crypto backend →
    # ngtcp2 → AWS-LC ssl → crypto (most-dependent first for static archives).
    if(UBIQUITTY_QUIC)
        ubiquitty_ensure_quic_deps() # fetch the pinned QUIC TLS deps if absent
        # DatagramBatch beside it: the write pump sends through the same batch
        # the client reads through, so the platform difference lives in one file
        # rather than once per direction.
        target_sources(ubiquitty-host PRIVATE
            Source/Platform/Host/HostQUIC.cpp
            Source/Platform/POSIX/DatagramBatch.cpp)
        target_include_directories(ubiquitty-host PRIVATE "${UBIQUITTY_QUIC_PREFIX}/include")
        target_compile_definitions(ubiquitty-host PRIVATE UBIQUITTY_QUIC=1)
        # crypto backend -> ngtcp2 -> AWS-LC ssl -> crypto (most-dependent first).
        # AWS-LC is self-contained crypto — no macOS framework dependency.
        target_link_libraries(ubiquitty-host PRIVATE
            "${UBIQUITTY_QUIC_PREFIX}/lib/libngtcp2_crypto_boringssl.a"
            "${UBIQUITTY_QUIC_PREFIX}/lib/libngtcp2.a"
            "${UBIQUITTY_QUIC_PREFIX}/lib/libssl.a"
            "${UBIQUITTY_QUIC_PREFIX}/lib/libcrypto.a")
    endif()

    if(UBIQUITTY_BUILD_SYNC_TRANSPORT_ACCEPTANCE)
        # The fixture's server uses the shipping host source set and reactor.
        # Its attach/bootstrap modes call the same production entry point;
        # renaming only this separate object leaves ubiquitty-host unchanged.
        get_target_property(_ubq_transport_host_sources ubiquitty-host SOURCES)
        list(REMOVE_ITEM _ubq_transport_host_sources Source/Platform/Host/main.cpp)
        add_library(ubq-sync-transport-host-objects OBJECT EXCLUDE_FROM_ALL
            ${_ubq_transport_host_sources}
            Source/Platform/POSIX/QUICClient.cpp
            Source/Core/Transport/QUICChannel.cpp)
        add_library(ubq-sync-transport-main-object OBJECT EXCLUDE_FROM_ALL
            Source/Platform/Host/main.cpp)
        target_compile_definitions(ubq-sync-transport-main-object PRIVATE main=ubiquittyHostMain)
        add_executable(sync_transport_acceptance EXCLUDE_FROM_ALL
            Tests/Host/sync_transport_acceptance.cpp
            $<TARGET_OBJECTS:ubq-sync-transport-host-objects>
            $<TARGET_OBJECTS:ubq-sync-transport-main-object>)
        foreach(_ubq_transport_target IN ITEMS
                ubq-sync-transport-host-objects ubq-sync-transport-main-object sync_transport_acceptance)
            target_include_directories(${_ubq_transport_target} PRIVATE
                "$<TARGET_PROPERTY:ubiquitty-host,INCLUDE_DIRECTORIES>" Tests)
            target_include_directories(${_ubq_transport_target} SYSTEM PRIVATE
                "${UBIQUITTY_SIMDUTF_DIR}" "${UBIQUITTY_RE2_DIR}")
            target_compile_definitions(${_ubq_transport_target} PRIVATE
                "$<TARGET_PROPERTY:ubiquitty-host,COMPILE_DEFINITIONS>")
            target_compile_options(${_ubq_transport_target} PRIVATE
                "$<TARGET_PROPERTY:ubiquitty-host,COMPILE_OPTIONS>")
            target_compile_features(${_ubq_transport_target} PRIVATE cxx_std_23)
            set_target_properties(${_ubq_transport_target} PROPERTIES
                CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
        endforeach()
        find_package(Threads REQUIRED)
        target_link_libraries(sync_transport_acceptance PRIVATE
            "$<TARGET_PROPERTY:ubiquitty-host,LINK_LIBRARIES>" Threads::Threads)
    endif()

# ----------------------------------------------------------------------
# Agent — ubq, the headless terminal frontend for AI agents
# (see Source/Agent/README.md).
#
# A portable-POSIX binary (no Cocoa / Metal / Swift): a Sync
# client that attaches to the ubiquitty-host daemon's host.sock, applies
# SNAPSHOTs into a passive Core Terminal, and exposes it programmatically
# (Source/Agent). It runs no PTY and no parser, so it drops the daemon's
# forkpty / Daemon sources; it shares the same Core + Sync + Preferences +
# HostPaths/PAL link set the host uses, minus the PTY transport.
# ----------------------------------------------------------------------
elseif(UBIQUITTY_FRONTEND STREQUAL "Agent")

    # The agent's Core link set = the canonical portable-Core list minus the
    # TUs a headless Sync client never references. It runs no PTY and no parser
    # (it applies SNAPSHOTs into a passive Terminal), so it drops the input encoders,
    # selection, the process model, session-persistence, the Tek/box
    # decorators + font-spec, the QUIC client carrier, and the
    # local-socket/poll/subprocess transports. It keeps the workspace layout
    # model, because the Sync client it is mirrors the workspace it attaches to. It KEEPS the software renderer
    # (Unifont/SoftwareRenderer/CellInstanceBuilder) for the screenshot raster.
    # A Core .cpp added to the SSOT flows in here unless it joins this trim list.
    ubiquitty_core_subset(UBIQUITTY_AGENT_CORE EXCLUDE
        # App-level theme/appearance/config-reload policy, which drives a host
        # seam a GUI frontend implements. A headless arm follows no system
        # appearance and watches no config file, and keeping it drags the whole
        # Themes resolution in behind it.
        Source/Core/App/AppRuntime.cpp
        # The first-launch Welcome screen and the shell wrapper one of its
        # buttons installs. A headless arm shows no screen and installs nothing
        # into a reader's startup files.
        Source/Core/App/ShellIntegrationInstall.cpp
        Source/Core/App/WelcomeScreen.cpp
        # The theme list and a theme's colours, for a frontend's picker. A
        # headless arm shows none, and keeping it drags Themes resolution in
        # behind it, exactly as AppRuntime above does.
        Source/Core/Themes/ThemeApply.cpp
        # The copy decision arrived in Core on 2026-09-05 and flowed in here as
        # a new Core .cpp does. A headless agent has no clipboard to copy to,
        # and keeping it drags the theme palette, the effective preferences and
        # Unicode normalisation in behind it. TerminalSelection.cpp goes with
        # it — it now builds a styled clipboard, which is the same cut, and the
        # daemon's subset has trimmed it since it was written.
        Source/Core/Selection/CopyClipboard.cpp
        Source/Core/Selection/TerminalSelection.cpp
        Source/Core/Preferences/PreferencesAccessors.cpp
        # The frontends' control socket reads its switch through the accessors
        # trimmed above, and a headless agent serves no windows to drive.
        Source/Core/Protocol/Control/Server.cpp
        Source/Core/Preferences/EffectiveValue.cpp
        # The app's own config writes, marked so its file watcher can tell
        # them from a person's edit. It writes through EffectiveValue.cpp,
        # trimmed above, and only AppRuntime.cpp, trimmed with it, asks; a
        # headless agent writes no configuration and watches no file.
        Source/Core/Preferences/SelfWriteGuard.cpp
        # The renderer-configuration fold reads the accessors trimmed above;
        # the agent's screenshot raster is configured from its own arguments.
        Source/Core/Preferences/FontRoutePreferences.cpp
        Source/Core/Preferences/RenderConfigurationFold.cpp
        # The overlay spans a GUI pane paints over its grid; a headless
        # screenshot raster draws the grid alone.
        Source/Core/Rendering/OverlaySpanGather.cpp
        # LinkRun.cpp is kept. The agent's screenshot raster runs the frame
        # capture, whose TerminalFrameInputs.cpp calls kindForLinkID on every
        # path; this list is matched by name and knows nothing of who calls
        # whom, so cutting it would pass here and fail at link time on each arm
        # whose linker keeps the caller. The pointer-hover walk that follows
        # has no caller left in the set and is cut.
        Source/Core/Screen/VisibleLink.cpp
        # Panes/PaneTree.cpp and Session/LayoutTree.cpp STAY: the Sync client
        # mirrors the workspace it attaches to (RemoteSessionCore.cpp builds a
        # Layout::Workspace; WorkspaceWire.cpp and Protocol/Tmux/PaneLayout.cpp
        # walk its pane trees), and a headless client attaches over Sync like
        # any other. Trimming either leaves a kept file needing a definition
        # only the trimmed one has, which check-core-subset-symbols refuses.
        Source/PAL/Process.cpp
        Source/PAL/ProcessSignal.cpp
        Source/Core/Session/ProcessSubtree.cpp
        # The matcher goes, with the RE2 and normalisation it needs, and the
        # search built on it: the agent runs no search.
        # Screen/ScrollSearchResults.cpp STAYS: the frame capture kept for the
        # screenshot raster reads the active match through FrameDamage.cpp to
        # damage its highlight, and those readers live there rather than
        # beside the matcher for this cut.
        Source/Core/Screen/ScrollSearch.cpp
        Source/Core/Search/HistoryScan.cpp
        Source/Core/Search/SearchController.cpp
        Source/Core/Search/ScreenScan.cpp
        Source/Core/Search/SearchExecutor.cpp
        Source/Core/Screen/ScrollTuning.cpp
        Source/Core/Session/SessionInfo.cpp
        # The drawing-debug readout is a GUI overlay; a headless agent shows
        # none. The heatmap's counters stay: the frame capture kept here feeds
        # them.
        Source/Core/Diagnostics/DrawingDebug.cpp
        Source/Core/Input/ComposeEngine.cpp
        Source/Core/Input/Keybindings.cpp
        # VT.cpp uses the key encoders for XTGETTCAP replies.
        # The routing ladder: which mode a press, a drag or a wheel notch turns
        # into. A headless arm routes no pointer. PointerInput.cpp beside it
        # stays, because it holds more than the encoders — the kept
        # TerminalSelection.cpp calls viewportAfterOutput and
        # isSnapPolicyConsulted, declared in PointerInput.h, to decide where a
        # view sits after output arrives.
        Source/Core/Input/PointerLadder.cpp
        Source/Core/Protocol/Sync/QUICBootstrap.cpp
        Source/Core/Protocol/Sync/QUICBootstrapReader.cpp
        # The host's half of a Sync call: it serves a client's request, a
        # history search among them, against the pane it owns. The agent is a
        # client that sends calls and serves none, and the search it would
        # answer with lives in ScrollSearch.cpp, trimmed above.
        Source/Core/Protocol/Sync/Control.cpp
        # The host's encoder for a remote client's keys and pointer: it turns
        # a client's input into bytes for the pane's program, through the
        # keymap trimmed above. Only the daemon builds one; the agent sends
        # its input to the host and encodes none of it.
        Source/Core/Runtime/RemoteInput.cpp
        Source/Core/Protocol/Tmux/Commands.cpp
        Source/Core/Protocol/Tmux/Session.cpp
        Source/Core/Runtime/TmuxControlHost.cpp
        Source/Core/Protocol/Tmux/Tiler.cpp
        Source/Core/Rendering/BoxEdgeStretch.cpp
        Source/Core/Rendering/BoxGlyphRaster.cpp
        Source/Core/Rendering/BoxStrokeProfile.cpp
        Source/Core/Rendering/FontFeatureSpecification.cpp
        Source/Core/Rendering/FontVariationSpecification.cpp
        # ShapedCellCache.cpp and FontMetrics.cpp are not on this list:
        # LigatureSheet.cpp, kept here, answers a shaped run by identity
        # through the one and places a proportional face's pen through the
        # other.
        Source/Core/Rendering/LigatureClassification.cpp
        Source/Core/Rendering/RenderPlan.cpp
        Source/Core/Rendering/TerminalSnapshot.cpp
        Source/Core/Rendering/BundledRichText.cpp
        Source/Core/Runtime/LaunchCommand.cpp
        Source/Core/Runtime/LaunchArguments.cpp
        Source/Core/Runtime/TerminalRuntime.cpp
        Source/Core/Runtime/TriggerConfig.cpp
        # Reads the two [triggers] gates through PreferencesAccessors, trimmed
        # above; a headless agent runs no trigger engine to resolve.
        Source/Core/Runtime/TriggerEffect.cpp
        # Selection.cpp stays, for the reason the host subset states:
        # Core/Screen/ClearBuffer.cpp is in the SSOT and calls Selection::clear,
        # so excluding it drops a definition a kept translation unit needs.
        Source/Core/Selection/StyledClipboard.cpp
        Source/Core/Session/HostLayoutRecord.cpp
        Source/Core/Session/Surface.cpp
        # Workspace.cpp stays: RemoteSessionCore serializes shared-window calls.
        Source/Core/Session/WorkspaceCapture.cpp
        Source/Core/Terminfo/UbiquittyTerminfo.cpp
        Source/Core/Accessibility/Palette.cpp
        # CellColor.cpp STAYS: the screenshot raster's frame inputs
        # (TerminalFrameInputs.cpp, kept for that raster) resolve each cell's
        # colours through CellPalette, which it defines.
        Source/Core/Themes/CellPaletteFromTheme.cpp
        Source/Core/Themes/TermPaletteFromTheme.cpp
        Source/Core/Themes/ThemeImport.cpp
        Source/Core/Themes/Themes.cpp
        Source/Core/Themes/ThemesCustom.cpp
        Source/Core/Transport/LocalSocketChannel.cpp
        # LocalPTYChannel derives from PollChannel, so it must be trimmed
        # wherever its base is — otherwise its vtable, ctor and dtor have no
        # definition and the link fails (Release hides it by eliding the
        # unused vtable; Debug does not).
        Source/Core/Transport/DelegatedChannel.cpp
        Source/Core/Transport/KnownHosts.cpp
        Source/Core/Transport/LocalPTYChannel.cpp
        Source/Core/Unicode/Normalize.cpp)

    add_executable(ubq
        # Agent frontend: the headless main + the MCP/policy/session glue + JSON,
        # and the host PAL/paths it shares with the daemon (none in the SSOT).
        Source/Agent/main.cpp
        Source/Agent/AgentSession.cpp
        Source/Agent/AgentMCP.cpp
        Source/Agent/RemoteCarrier.cpp
        Source/Core/Codec/JSON.cpp
        Source/ThirdParty/yyjson/yyjson.c
        Source/Platform/Host/HostPaths.cpp
        Source/Platform/Host/HostPAL.cpp
        # Portable Core (single-sourced from Scripts/portable-core-sources.txt;
        # ControlPaths + NativeAttachment/SyncClientCore + Tmux.cpp arrive via SSOT).
        ${UBIQUITTY_AGENT_CORE}
        ${UBIQUITTY_SIMDUTF_SOURCES}
    )
    ubiquitty_generate_completions_header(
        "${CMAKE_CURRENT_BINARY_DIR}/generated/Agent/CompletionScripts.h")
    target_include_directories(ubq PRIVATE Source
        "${CMAKE_CURRENT_BINARY_DIR}/generated")
    target_include_directories(ubq SYSTEM PRIVATE "${UBIQUITTY_SIMDUTF_DIR}")
    target_compile_features(ubq PRIVATE cxx_std_23)
    set_target_properties(ubq PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    target_compile_options(ubq PRIVATE
        -fno-exceptions -fno-rtti -Wall -Wextra
        ${UBIQUITTY_NARROWING_WARNING}
        "$<$<BOOL:${UBIQUITTY_WERROR}>:-Werror>")
    # yyjson is a vendored ThirdParty C TU in this target's source list; give it
    # the same suppression re2/simdutf get — its diagnostics are noise, and a
    # vendored TU must not fail the build on a compiler bump under
    # UBIQUITTY_WERROR. -std=c99 keeps the target's C++ options off a C source.
    set_source_files_properties(Source/ThirdParty/yyjson/yyjson.c PROPERTIES
        COMPILE_FLAGS "-std=c99 -Wno-error -w")

# ----------------------------------------------------------------------
# Linux — GTK4 shell + Vulkan renderer over the portable Core. Local Core +
# own PTY, offscreen Vulkan -> GdkMemoryTexture in a GtkPicture (no swapchain;
# runs headless on Mesa lavapipe). The selected source set below is the live
# terminal path: Core, Runtime, Input, Unifont, PTY, and LinuxPAL.
# ----------------------------------------------------------------------
elseif(UBIQUITTY_FRONTEND STREQUAL "Linux")

    find_package(PkgConfig REQUIRED)
    pkg_check_modules(GTK4 REQUIRED IMPORTED_TARGET gtk4>=4.16)
    pkg_check_modules(PANGOCAIRO REQUIRED IMPORTED_TARGET pangocairo)
    # Real-font glyph raster: fontconfig matches the monospace family, FreeType
    # rasterizes AA coverage. HarfBuzz is linked with the font stack so shaping support can
    # use the same target without a build-system change.
    pkg_check_modules(FREETYPE REQUIRED IMPORTED_TARGET freetype2)
    pkg_check_modules(FONTCONFIG REQUIRED IMPORTED_TARGET fontconfig)
    pkg_check_modules(HARFBUZZ REQUIRED IMPORTED_TARGET harfbuzz)
    find_package(Vulkan REQUIRED)

    # Relative pointer lock (DECSET 7403): the OS-level grab behind
    # PointerLock.cpp, split across two mechanisms neither of which is
    # REQUIRED — a build missing one library's dev headers still gets a
    # working lock through the other, guarded by the UBIQUITTY_LINUX_HAS_*
    # compile definitions below. X11's XWarpPointer/XFixesHideCursor need
    # only x11 + xfixes (this arm uses the warp-back-to-centre technique, not
    # raw XInput2 motion, so xi is not a dependency). Wayland's true relative
    # deltas need wayland-client (the library) and wayland-protocols (the XML
    # this build generates client code from via wayland-scanner) together —
    # partial Wayland support is not support.
    pkg_check_modules(UBIQUITTY_X11 IMPORTED_TARGET x11 xfixes)
    pkg_check_modules(UBIQUITTY_WAYLAND_CLIENT IMPORTED_TARGET wayland-client)
    pkg_check_modules(UBIQUITTY_WAYLAND_PROTOCOLS wayland-protocols)
    find_program(UBIQUITTY_WAYLAND_SCANNER wayland-scanner)
    set(UBIQUITTY_LINUX_POINTER_LOCK_DEFS "")
    if(UBIQUITTY_X11_FOUND)
        list(APPEND UBIQUITTY_LINUX_POINTER_LOCK_DEFS UBIQUITTY_LINUX_HAS_X11=1)
    else()
        message(STATUS "Linux pointer lock: x11/xfixes dev headers not found — the X11 backend is compiled out")
    endif()
    set(UBIQUITTY_LINUX_HAS_WAYLAND_DEPS FALSE)
    if(UBIQUITTY_WAYLAND_CLIENT_FOUND AND UBIQUITTY_WAYLAND_PROTOCOLS_FOUND AND UBIQUITTY_WAYLAND_SCANNER)
        set(UBIQUITTY_LINUX_HAS_WAYLAND_DEPS TRUE)
        list(APPEND UBIQUITTY_LINUX_POINTER_LOCK_DEFS UBIQUITTY_LINUX_HAS_WAYLAND=1)
    else()
        message(STATUS "Linux pointer lock: wayland-client/wayland-protocols/wayland-scanner not all found — the Wayland backend is compiled out")
    endif()

    # The Linux frontend's Core link set = the canonical portable-Core list minus
    # the TUs this GTK4 + Vulkan shell does not use: the Sync wire (it runs Core
    # locally with its own PTY, not as a remote client), the QUIC carrier, the
    # tmux session/commands model, session-persistence + the remote-session core
    # + the SCM_RIGHTS session handoff (all Sync/remote-only), the
    # Tek-vector/Unifont renderers, and the socket/poll transports. A Core .cpp
    # added to the SSOT flows in here unless it joins this trim list.
    #
    # The styled clipboard and the palette-from-theme helper were on this list
    # while only the macOS controller reached them. The copy decision is Core's
    # now (Selection::copyClipboard, Themes::copyPalette), reached from the
    # portable Selection and Themes TUs every frontend links, so their link set
    # carries both; a frontend that copies plain text still runs only the code
    # it calls.
    #
    # `FontFeatureSpecification.cpp` was on this list because nothing here
    # parsed `font.features` — the shaper was handed no feature list at all. It
    # comes off with the code that reads it: a trim list records what a frontend
    # does not do, and an entry left after that stops being true makes a link
    # error the only thing that reports the gap.
    #
    # `Tek/Project.cpp` came off every list for the same reason. It was trimmed
    # while the projection was a frontend's own step, drawn per arm; the Tek
    # graphic-input report now builds it inside the portable machine, so the
    # always-linked `Tek4014.cpp` references it and the projection is Core's
    # rather than optional. Pure integer and float math with no dependency but
    # `<cmath>`, so what the four subsets gain for it is a small object file.
    ubiquitty_core_subset(UBIQUITTY_LINUX_CORE EXCLUDE
        Source/Core/Protocol/Sync/QUICBootstrap.cpp
        Source/Core/Protocol/Sync/QUICBootstrapReader.cpp
        Source/Core/Protocol/Tmux/Session.cpp
        Source/Core/Runtime/TmuxControlHost.cpp
        Source/Core/Protocol/Tmux/Tiler.cpp
        # ShapedCellCache.cpp is not on this list: LigatureSheet.cpp, kept
        # here, answers a shaped run by identity through it.
        Source/Core/Rendering/LigatureClassification.cpp
        # TerminalSnapshot.cpp is not on this list: the CPU raster draws a
        # Tektronix frame with its compositeTektronixFrame.
        Source/Core/Session/HostLayoutRecord.cpp
        Source/Core/Session/Surface.cpp
        # Workspace.cpp stays: RemoteSessionCore serializes shared-window calls.
        Source/Core/Session/WorkspaceCapture.cpp
        Source/Core/Terminfo/UbiquittyTerminfo.cpp
        Source/Core/Transport/LocalSocketChannel.cpp
        # LocalPTYChannel derives from PollChannel, so it must be trimmed
        # wherever its base is — otherwise its vtable, ctor and dtor have no
        # definition and the link fails (Release hides it by eliding the
        # unused vtable; Debug does not).
        Source/Core/Transport/DelegatedChannel.cpp
        Source/Core/Transport/KnownHosts.cpp
        Source/Core/Transport/LocalPTYChannel.cpp)

    add_executable(ubiquitty-linux
        # Linux frontend (GTK4 shell + Vulkan renderer + the local PAL)
        Source/Platform/Linux/main.cpp
        Source/Platform/Linux/Accessibility.cpp
        Source/Platform/Linux/AccessibleTerminal.cpp
        Source/Platform/Linux/VulkanRenderer.cpp
        Source/Platform/Linux/VulkanColorGlyphAtlas.cpp
        Source/Platform/Linux/VulkanGlyphAtlas.cpp
        Source/Platform/Linux/VulkanImageTextures.cpp
        Source/Platform/Linux/BundledFontDirectory.cpp
        Source/Platform/Linux/FontInventory.cpp
        Source/Platform/Linux/FontRouting.cpp
        Source/Platform/Linux/PangoRichText.cpp
        Source/Platform/Linux/ColorGlyphPainter.cpp
        Source/Platform/Linux/FreeTypeRasterizer.cpp
        Source/Platform/Linux/Raster.cpp
        Source/Platform/Linux/PAL.cpp
        Source/Platform/Linux/Clipboard.cpp
        Source/Platform/Linux/ConfigurationWatcher.cpp
        Source/Platform/Linux/Updater.cpp
        Source/Platform/Linux/PointerLock.cpp
        # PTY transport + platform seam (this frontend runs Core locally with its
        # own PTY; PTYStream/PTYFacts/OutputQueue/PasteNormalize are not in the SSOT).
        Source/Platform/POSIX/PTYStream.cpp
        Source/Platform/POSIX/PTYFacts.cpp
        # The gated kitty file read (t=f / t=t), shared with the macOS arm so the
        # hardening rules have one home rather than one per frontend.
        Source/Platform/POSIX/GatedFileRead.cpp
        Source/Platform/Linux/VulkanCoverageSheet.cpp
        Source/PAL/OutputQueue.cpp
        Source/Core/Input/PasteNormalize.cpp
        Source/Core/Preferences/FontRoutePreferences.cpp
        # Portable Core (single-sourced from Scripts/portable-core-sources.txt;
        # the local session driver, input encoders, themes, layout model, and the
        # software renderer all arrive via the SSOT below — HostPaths/ControlPaths
        # come in via the SSOT (ControlPaths) + inline (HostPaths, not in SSOT)).
        Source/Platform/Host/HostPaths.cpp
        # Codec/JSON.cpp arrives via the SSOT and ControlRPC calls it for the
        # control socket, so the parser it wraps has to be in the link set.
        Source/ThirdParty/yyjson/yyjson.c
        ${UBIQUITTY_LINUX_CORE}
        # ScrollSearch.cpp stays in this subset, so the RE2 TUs ride along.
        ${UBIQUITTY_RE2_SOURCES}
        ${UBIQUITTY_SIMDUTF_SOURCES}
    )
    # A vendored ThirdParty C TU gets the suppression re2 and simdutf get: its
    # diagnostics are noise, and it must not fail the build on a compiler bump
    # under UBIQUITTY_WERROR. -std=c99 keeps the target's C++ options off it.
    set_source_files_properties(Source/ThirdParty/yyjson/yyjson.c PROPERTIES
        COMPILE_FLAGS "-std=c99 -Wno-error -w")
    # gdk_x11_display_get_xdisplay / gdk_x11_surface_get_xid are GDK4's only
    # route to the raw Xlib handles XWarpPointer/XFixesHideCursor need, and
    # this GTK build marks them deprecated (GTK5's backend getters move
    # elsewhere) with no in-GTK4 replacement — so only this warning, and only
    # in the one file that calls them, is downgraded from -Werror.
    if(UBIQUITTY_X11_FOUND)
        set_source_files_properties(Source/Platform/Linux/PointerLock.cpp PROPERTIES
            COMPILE_FLAGS "-Wno-error=deprecated-declarations")
    endif()
    target_include_directories(ubiquitty-linux PRIVATE Source)
    target_include_directories(ubiquitty-linux SYSTEM PRIVATE "${UBIQUITTY_RE2_DIR}" "${UBIQUITTY_SIMDUTF_DIR}")
    if(NOT APPLE)
        # Portable <MacTypes.h> stand-in for this non-Apple build (Selection.h and
        # the other shared headers that include <MacTypes.h> directly), mirroring
        # Scripts/run-tests.sh's HOST_COMPAT include. Base/Types.h self-provides the
        # same typedefs off-Apple; the shim's identical typedefs coexist with it.
    endif()
    target_compile_definitions(ubiquitty-linux PRIVATE ${UBIQUITTY_LINUX_POINTER_LOCK_DEFS})
    target_compile_features(ubiquitty-linux PRIVATE cxx_std_23)
    set_target_properties(ubiquitty-linux PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    target_compile_options(ubiquitty-linux PRIVATE
        -fno-exceptions -fno-rtti -Wall -Wextra
        ${UBIQUITTY_NARROWING_WARNING}
        "$<$<BOOL:${UBIQUITTY_WERROR}>:-Werror>")
    target_link_libraries(ubiquitty-linux PRIVATE PkgConfig::GTK4 PkgConfig::PANGOCAIRO Vulkan::Vulkan
        PkgConfig::FREETYPE PkgConfig::FONTCONFIG PkgConfig::HARFBUZZ)
    # forkpty lives in libutil on Linux/glibc (PTYStream.cpp).
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        target_link_libraries(ubiquitty-linux PRIVATE util)
    endif()
    if(UBIQUITTY_X11_FOUND)
        target_link_libraries(ubiquitty-linux PRIVATE PkgConfig::UBIQUITTY_X11)
    endif()
    if(UBIQUITTY_LINUX_HAS_WAYLAND_DEPS)
        target_link_libraries(ubiquitty-linux PRIVATE PkgConfig::UBIQUITTY_WAYLAND_CLIENT)
    endif()

    # Built-in themes: embed Source/Core/Themes/builtin-themes.toml as a generated TU
    # (the definition of builtinThemesTOML that Themes.cpp parses at startup).
    # Mirrors the macOS target's generation so theme apply works on Linux too.
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    set(BUILTIN_THEMES_TOML ${CMAKE_SOURCE_DIR}/Source/Core/Themes/builtin-themes.toml)
    set(BUILTIN_THEMES_GEN ${CMAKE_CURRENT_BINARY_DIR}/BuiltinThemesData.gen.cpp)
    add_custom_command(
        OUTPUT ${BUILTIN_THEMES_GEN}
        COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/Scripts/embed-builtin-themes.py
                ${BUILTIN_THEMES_TOML} ${BUILTIN_THEMES_GEN}
        DEPENDS ${BUILTIN_THEMES_TOML} ${CMAKE_SOURCE_DIR}/Scripts/embed-builtin-themes.py
        COMMENT "Embedding built-in themes TOML"
        VERBATIM)
    target_sources(ubiquitty-linux PRIVATE ${BUILTIN_THEMES_GEN})

    # Wayland pointer-lock protocols: wayland-scanner generates the client-side
    # marshaling code for zwp_pointer_constraints_v1 and zwp_relative_pointer_v1
    # from the XML wayland-protocols ships — there is no distributed header for
    # either, every client generates its own from the same upstream XML. Skipped
    # whole when the Wayland deps are not all present; PointerLock.cpp's
    # UBIQUITTY_LINUX_HAS_WAYLAND guard is what actually decides whether the
    # generated code is compiled in, but generating unused code the guard then
    # discards would be a build step with no purpose.
    if(UBIQUITTY_LINUX_HAS_WAYLAND_DEPS)
        pkg_get_variable(UBIQUITTY_WAYLAND_PROTOCOLS_DIR wayland-protocols pkgdatadir)
        set(UBIQUITTY_WAYLAND_GEN_DIR ${CMAKE_CURRENT_BINARY_DIR}/linux-wayland-protocols)
        file(MAKE_DIRECTORY ${UBIQUITTY_WAYLAND_GEN_DIR})

        set(UBIQUITTY_POINTER_CONSTRAINTS_XML "${UBIQUITTY_WAYLAND_PROTOCOLS_DIR}/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml")
        set(UBIQUITTY_POINTER_CONSTRAINTS_HEADER "${UBIQUITTY_WAYLAND_GEN_DIR}/pointer-constraints-unstable-v1-client-protocol.h")
        set(UBIQUITTY_POINTER_CONSTRAINTS_SOURCE "${UBIQUITTY_WAYLAND_GEN_DIR}/pointer-constraints-unstable-v1-protocol.c")
        add_custom_command(OUTPUT ${UBIQUITTY_POINTER_CONSTRAINTS_HEADER}
            COMMAND ${UBIQUITTY_WAYLAND_SCANNER} client-header ${UBIQUITTY_POINTER_CONSTRAINTS_XML} ${UBIQUITTY_POINTER_CONSTRAINTS_HEADER}
            DEPENDS ${UBIQUITTY_POINTER_CONSTRAINTS_XML}
            COMMENT "wayland-scanner client-header pointer-constraints-unstable-v1" VERBATIM)
        add_custom_command(OUTPUT ${UBIQUITTY_POINTER_CONSTRAINTS_SOURCE}
            COMMAND ${UBIQUITTY_WAYLAND_SCANNER} private-code ${UBIQUITTY_POINTER_CONSTRAINTS_XML} ${UBIQUITTY_POINTER_CONSTRAINTS_SOURCE}
            DEPENDS ${UBIQUITTY_POINTER_CONSTRAINTS_XML} ${UBIQUITTY_POINTER_CONSTRAINTS_HEADER}
            COMMENT "wayland-scanner private-code pointer-constraints-unstable-v1" VERBATIM)

        set(UBIQUITTY_RELATIVE_POINTER_XML "${UBIQUITTY_WAYLAND_PROTOCOLS_DIR}/unstable/relative-pointer/relative-pointer-unstable-v1.xml")
        set(UBIQUITTY_RELATIVE_POINTER_HEADER "${UBIQUITTY_WAYLAND_GEN_DIR}/relative-pointer-unstable-v1-client-protocol.h")
        set(UBIQUITTY_RELATIVE_POINTER_SOURCE "${UBIQUITTY_WAYLAND_GEN_DIR}/relative-pointer-unstable-v1-protocol.c")
        add_custom_command(OUTPUT ${UBIQUITTY_RELATIVE_POINTER_HEADER}
            COMMAND ${UBIQUITTY_WAYLAND_SCANNER} client-header ${UBIQUITTY_RELATIVE_POINTER_XML} ${UBIQUITTY_RELATIVE_POINTER_HEADER}
            DEPENDS ${UBIQUITTY_RELATIVE_POINTER_XML}
            COMMENT "wayland-scanner client-header relative-pointer-unstable-v1" VERBATIM)
        add_custom_command(OUTPUT ${UBIQUITTY_RELATIVE_POINTER_SOURCE}
            COMMAND ${UBIQUITTY_WAYLAND_SCANNER} private-code ${UBIQUITTY_RELATIVE_POINTER_XML} ${UBIQUITTY_RELATIVE_POINTER_SOURCE}
            DEPENDS ${UBIQUITTY_RELATIVE_POINTER_XML} ${UBIQUITTY_RELATIVE_POINTER_HEADER}
            COMMENT "wayland-scanner private-code relative-pointer-unstable-v1" VERBATIM)

        set(UBIQUITTY_WAYLAND_PROTOCOL_SOURCES
            ${UBIQUITTY_POINTER_CONSTRAINTS_HEADER} ${UBIQUITTY_POINTER_CONSTRAINTS_SOURCE}
            ${UBIQUITTY_RELATIVE_POINTER_HEADER} ${UBIQUITTY_RELATIVE_POINTER_SOURCE})
        # Generated C, not this target's own: silenced the way yyjson.c is above,
        # so a compiler bump's new warning in wayland-scanner's OWN output does
        # not fail a build this tree does not control the source of.
        set_source_files_properties(${UBIQUITTY_POINTER_CONSTRAINTS_SOURCE} ${UBIQUITTY_RELATIVE_POINTER_SOURCE} PROPERTIES
            COMPILE_FLAGS "-Wno-error -w")
        target_sources(ubiquitty-linux PRIVATE ${UBIQUITTY_WAYLAND_PROTOCOL_SOURCES})
        target_include_directories(ubiquitty-linux PRIVATE ${UBIQUITTY_WAYLAND_GEN_DIR})
    endif()

    # Stage-2 GPU glyph renderer: compile the cell shaders to SPIR-V next to the
    # binary (loaded at runtime from the executable's directory).
    #
    # A binary without them still runs: its first GPU frame cannot load a
    # shader, and the frontend demotes to the CPU raster for the rest of the
    # run. So a configure that cannot find glslc stops here unless it was asked
    # for a CPU-only binary; a warning in a configure log that the build scripts
    # discard on success is how a build finished green with no GPU renderer.
    option(UBIQUITTY_LINUX_GPU_SHADERS "Compile the Linux Vulkan renderer's SPIR-V shaders (needs glslc)" ON)
    if(UBIQUITTY_LINUX_GPU_SHADERS)
        find_program(UBIQUITTY_GLSLC glslc)
        if(NOT UBIQUITTY_GLSLC)
            message(FATAL_ERROR
                "glslc not found, so the Linux Vulkan renderer's shaders cannot be compiled. "
                "Install it (Debian, Ubuntu and Fedora: glslc; Arch: shaderc), or configure with "
                "-DUBIQUITTY_LINUX_GPU_SHADERS=OFF for a binary that renders on the CPU only.")
        endif()
        set(_ubiquitty_spv "")
        foreach(shader IN ITEMS cell.vert cell.frag glyph.vert glyph.frag color.vert color.frag decoration.vert decoration.frag overlay.vert overlay.frag image.vert image.frag backdrop.vert backdrop.frag boxfill.vert boxfill.frag)
            add_custom_command(
                OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/${shader}.spv
                COMMAND ${UBIQUITTY_GLSLC}
                        ${CMAKE_CURRENT_SOURCE_DIR}/Source/Platform/Linux/shaders/${shader}
                        -o ${CMAKE_CURRENT_BINARY_DIR}/${shader}.spv
                DEPENDS Source/Platform/Linux/shaders/${shader}
                COMMENT "glslc ${shader} -> SPIR-V" VERBATIM)
            list(APPEND _ubiquitty_spv ${CMAKE_CURRENT_BINARY_DIR}/${shader}.spv)
        endforeach()
        add_custom_target(ubiquitty-linux-shaders ALL DEPENDS ${_ubiquitty_spv})
        add_dependencies(ubiquitty-linux ubiquitty-linux-shaders)
    else()
        message(STATUS "Linux GPU shaders: OFF (UBIQUITTY_LINUX_GPU_SHADERS), so this binary renders on the CPU only")
    endif()

    # Bundle every shipped font next to the binary. The frontend resolves a
    # configured family to a file through Rendering::bundledFonts() and opens it
    # from the executable's directory via /proc/self/exe, so a family in that
    # table with no file here resolves to a path that does not exist — and
    # FreeType then falls all the way to the embedded Unifont, which RENDERS,
    # so the failure is a picture in the wrong face rather than an error.
    #
    # The list is here rather than globbed because a glob makes adding a file to
    # Resources/fonts a rendering change nobody wrote down; it must match the
    # table the frontend reads, and check-bundled-fonts.py compares the two.
    set(UBIQUITTY_LINUX_BUNDLED_FONTS
        "SymbolsNerdFontMono-Regular.ttf"
        "JetBrainsMono[wght].ttf"
        "JetBrainsMono-Italic[wght].ttf"
        "MonaspaceNeon-Regular.otf"
        "MonaspaceNeon-Bold.otf"
        "MonaspaceNeon-Italic.otf"
        "MonaspaceNeon-BoldItalic.otf"
        "MonaspaceNeonVar.ttf"
        "NotoSans-Regular.ttf"
        "NotoSans-Bold.ttf"
        "NotoColorEmoji-COLRv1.ttf")
    set(UBIQUITTY_LINUX_BUNDLED_FONT_OUTPUTS "")
    foreach(font IN LISTS UBIQUITTY_LINUX_BUNDLED_FONTS)
        add_custom_command(
            OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/${font}"
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    "${CMAKE_CURRENT_SOURCE_DIR}/Resources/fonts/${font}"
                    "${CMAKE_CURRENT_BINARY_DIR}/${font}"
            DEPENDS "Resources/fonts/${font}"
            COMMENT "Bundle ${font} next to ubiquitty-linux" VERBATIM)
        list(APPEND UBIQUITTY_LINUX_BUNDLED_FONT_OUTPUTS "${CMAKE_CURRENT_BINARY_DIR}/${font}")
    endforeach()
    add_custom_target(ubiquitty-linux-font ALL DEPENDS ${UBIQUITTY_LINUX_BUNDLED_FONT_OUTPUTS})
    add_dependencies(ubiquitty-linux ubiquitty-linux-font)

    # The installed layout is the build directory's: the binary with its shaders
    # and fonts in one directory, since the frontend finds both through
    # /proc/self/exe. package-linux-appimage.sh lays out the AppDir with
    # `cmake --install`, so the AppImage ships exactly the lists above rather
    # than a second hand-kept copy of them.
    install(TARGETS ubiquitty-linux RUNTIME DESTINATION bin)
    install(FILES ${_ubiquitty_spv} ${UBIQUITTY_LINUX_BUNDLED_FONT_OUTPUTS} DESTINATION bin)

# ----------------------------------------------------------------------
# Wscons — the OpenBSD/NetBSD console as a terminal, standing where getty would
# on a VT (Source/Platform/Wscons/main.cpp). It maps the wsdisplay framebuffer,
# paints it with the portable CPU SoftwareRenderer and the bundled Unifont, so
# FreeType, fontconfig and HarfBuzz are not needed, and takes keys from wskbd.
# The <dev/wscons/*.h> headers exist on those two systems alone, so no other
# host can build it. It has only been run by hand on OpenBSD 7.9 x64 under
# QEMU; NetBSD and real hardware are untried, and no release includes it.
# ----------------------------------------------------------------------
elseif(UBIQUITTY_FRONTEND STREQUAL "Wscons")

    if(NOT (CMAKE_SYSTEM_NAME STREQUAL "OpenBSD" OR CMAKE_SYSTEM_NAME STREQUAL "NetBSD"))
        message(FATAL_ERROR "UBIQUITTY_FRONTEND=Wscons only builds on OpenBSD/NetBSD (CMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME})")
    endif()

    # Same trim list as the Linux frontend: drop Sync/QUIC, tmux, session-
    # persistence + handoff, the styled clipboard, the Tek/font-spec/Unifont
    # renderers, the palette-from-theme helpers, and the socket/poll
    # transports. A Core .cpp added to the SSOT flows in here unless it joins
    # this trim list.
    #
    # Identical to the Linux trim by construction, and that identity is the only
    # thing verifying it: no Linux or macOS machine can configure a Wscons build, so a TU
    # excluded only here is a claim nothing compiles. `check-core-subset-parity`
    # holds the two lists equal for that reason. `FontFeatureSpecification.cpp`
    # therefore linked when Linux started parsing `font.features`, even though
    # this frontend calls no shaper — a parser of standard-library string
    # handling costs a few kilobytes, and diverging the lists would cost the
    # only check this subset has.
    ubiquitty_core_subset(UBIQUITTY_WSCONS_CORE EXCLUDE
        Source/Core/Protocol/Sync/QUICBootstrap.cpp
        Source/Core/Protocol/Sync/QUICBootstrapReader.cpp
        Source/Core/Protocol/Tmux/Session.cpp
        Source/Core/Runtime/TmuxControlHost.cpp
        Source/Core/Protocol/Tmux/Tiler.cpp
        # ShapedCellCache.cpp is not on this list: LigatureSheet.cpp, kept
        # here, answers a shaped run by identity through it.
        Source/Core/Rendering/LigatureClassification.cpp
        # TerminalSnapshot.cpp is not on this list: Linux keeps it for the CPU
        # raster's Tektronix frame, and this trim is verified only by being
        # Linux's (Scripts/check-core-subset-parity.sh).
        Source/Core/Session/HostLayoutRecord.cpp
        Source/Core/Session/Surface.cpp
        # Workspace.cpp stays: RemoteSessionCore serializes shared-window calls.
        Source/Core/Session/WorkspaceCapture.cpp
        Source/Core/Terminfo/UbiquittyTerminfo.cpp
        Source/Core/Transport/LocalSocketChannel.cpp
        # LocalPTYChannel derives from PollChannel, so it must be trimmed
        # wherever its base is — otherwise its vtable, ctor and dtor have no
        # definition and the link fails (Release hides it by eliding the
        # unused vtable; Debug does not).
        Source/Core/Transport/DelegatedChannel.cpp
        Source/Core/Transport/KnownHosts.cpp
        Source/Core/Transport/LocalPTYChannel.cpp)

    add_executable(ubiquitty-wscons
        Source/Platform/Wscons/main.cpp
        Source/Platform/Wscons/WsconsDisplay.cpp
        Source/Platform/Wscons/WsconsKeyboard.cpp
        Source/Platform/Wscons/WsconsPAL.cpp
        Source/Platform/POSIX/SystemPAL.cpp
        # PTY transport + platform seam (forkpty's Darwin/OpenBSD/NetBSD path
        # in PTYStream.cpp already covers this OS — see its <util.h> branch).
        Source/Platform/POSIX/PTYStream.cpp
        Source/Platform/POSIX/PTYFacts.cpp
        Source/PAL/OutputQueue.cpp
        Source/Core/Input/PasteNormalize.cpp
        Source/Core/Preferences/FontRoutePreferences.cpp
        Source/Platform/Host/HostPaths.cpp
        ${UBIQUITTY_WSCONS_CORE}
        ${UBIQUITTY_RE2_SOURCES}
        ${UBIQUITTY_SIMDUTF_SOURCES}
    )
    target_include_directories(ubiquitty-wscons PRIVATE Source "${UBIQUITTY_RE2_DIR}")
    target_include_directories(ubiquitty-wscons SYSTEM PRIVATE "${UBIQUITTY_SIMDUTF_DIR}")
    target_compile_features(ubiquitty-wscons PRIVATE cxx_std_23)
    set_target_properties(ubiquitty-wscons PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    target_compile_options(ubiquitty-wscons PRIVATE
        -fno-exceptions -fno-rtti -Wall -Wextra
        ${UBIQUITTY_NARROWING_WARNING}
        "$<$<BOOL:${UBIQUITTY_WERROR}>:-Werror>")
    # forkpty lives in libutil on the BSDs (PTYStream.cpp's <util.h> branch).
    target_link_libraries(ubiquitty-wscons PRIVATE util)

    # Built-in themes, same generation step as Linux/macOS.
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    set(BUILTIN_THEMES_TOML ${CMAKE_SOURCE_DIR}/Source/Core/Themes/builtin-themes.toml)
    set(BUILTIN_THEMES_GEN ${CMAKE_CURRENT_BINARY_DIR}/BuiltinThemesData.gen.cpp)
    add_custom_command(
        OUTPUT ${BUILTIN_THEMES_GEN}
        COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/Scripts/embed-builtin-themes.py
                ${BUILTIN_THEMES_TOML} ${BUILTIN_THEMES_GEN}
        DEPENDS ${BUILTIN_THEMES_TOML} ${CMAKE_SOURCE_DIR}/Scripts/embed-builtin-themes.py
        COMMENT "Embedding built-in themes TOML"
        VERBATIM)
    target_sources(ubiquitty-wscons PRIVATE ${BUILTIN_THEMES_GEN})

# ----------------------------------------------------------------------
# Core — the standalone libUbiquittyCore static library + its consumer
# sample. The portable terminal Core as a real,
# reusable build artifact: no frontend, no Apple/GTK/Vulkan, no external
# transport stack. The library links against nothing but Source/ + a
# caller-supplied PAL. The source set is the SINGLE canonical list in
# Scripts/portable-core-sources.txt, read here and by the bash perf
# drivers so the list can never drift.
#
#   cmake -S . -B build/core -DUBIQUITTY_FRONTEND=Core -DUBIQUITTY_QUIC=OFF
#   cmake --build build/core
#
# Public umbrella header: Source/UbiquittyCore/UbiquittyCore.h. Curated public surface
# (Terminal lifecycle + processBytes, snapshot/getDisplayRow, the paint model,
# Preferences, the PAL contract). See Docs/libubiquittycore.md.
# ----------------------------------------------------------------------
elseif(UBIQUITTY_FRONTEND STREQUAL "Core")

    # The standalone lib links the FULL canonical portable-Core set — the shared
    # UBIQUITTY_CORE_SOURCES parsed once above from Scripts/portable-core-sources.txt
    # (the same list the host/agent/linux frontends trim from). Repo-relative
    # paths resolve against the top-level CMAKE_CURRENT_SOURCE_DIR.

    # Themes.cpp parses the built-in [[themes]] from an embedded TOML symbol
    # (builtinThemesTOML), generated from Source/Core/Themes/builtin-themes.toml.
    # The lib compiles Themes.cpp, so it must also carry the generated TU or any
    # consumer pulling Themes.o gets an unresolved symbol.
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    set(_core_themes_toml ${CMAKE_SOURCE_DIR}/Source/Core/Themes/builtin-themes.toml)
    set(_core_themes_gen ${CMAKE_CURRENT_BINARY_DIR}/BuiltinThemesData.gen.cpp)
    add_custom_command(
        OUTPUT ${_core_themes_gen}
        COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/Scripts/embed-builtin-themes.py
                ${_core_themes_toml} ${_core_themes_gen}
        DEPENDS ${_core_themes_toml} ${CMAKE_SOURCE_DIR}/Scripts/embed-builtin-themes.py
        COMMENT "Embedding built-in themes TOML (ubiquitty-core)"
        VERBATIM)

    # ---- Per-layer library targets (Docs/package-layers.md phase 5) --------
    # Layer membership has ONE authority: Scripts/check-core-layer-partition.sh.
    # The TU list of each layer is emitted from it at configure time, and the
    # union is asserted equal to the canonical SSOT — a TU in no layer (or a
    # drifted checker) fails configure, never silently mis-packages.
    foreach(_layer L0 L1 L2 L3b)
        execute_process(
            COMMAND bash ${CMAKE_SOURCE_DIR}/Scripts/check-core-layer-partition.sh --emit ${_layer}
            WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
            OUTPUT_VARIABLE _layer_out
            RESULT_VARIABLE _layer_rc)
        if(NOT _layer_rc EQUAL 0)
            message(FATAL_ERROR "check-core-layer-partition.sh --emit ${_layer} failed — the SSOT has an unclassified TU")
        endif()
        string(STRIP "${_layer_out}" _layer_out)
        string(REPLACE "\n" ";" UBIQUITTY_${_layer}_SOURCES "${_layer_out}")
    endforeach()
    # The checker classifies the SSOT, which names the POSIX backends. wasm swaps
    # them above, so the layer owning them follows: L3b holds whichever backends
    # this target actually builds, or the layer library compiles a TU the target
    # excluded and the union stops matching the canonical list.
    if(EMSCRIPTEN)
        foreach(_backend IN LISTS UBIQUITTY_BUNDLED_BACKENDS)
            list(REMOVE_ITEM UBIQUITTY_L3b_SOURCES Source/Platform/POSIX/${_backend}.cpp)
            list(APPEND UBIQUITTY_L3b_SOURCES Source/Platform/Wasm/${_backend}.cpp)
        endforeach()
    endif()
    set(_ubq_layer_union ${UBIQUITTY_L0_SOURCES} ${UBIQUITTY_L1_SOURCES}
        ${UBIQUITTY_L2_SOURCES} ${UBIQUITTY_L3b_SOURCES})
    list(SORT _ubq_layer_union)
    set(_ubq_canonical ${UBIQUITTY_CORE_SOURCES})
    list(SORT _ubq_canonical)
    if(NOT _ubq_layer_union STREQUAL _ubq_canonical)
        message(FATAL_ERROR
            "layer partition != the portable-core SSOT — run "
            "Scripts/check-core-layer-partition.sh for the unassigned TU")
    endif()

    # ubiquitty-core-model: the L0 foundation/PAL-contract implementation + the
    # L1 terminal model. ScrollSearch.cpp (L1) pulls the RE2 TUs along.
    # Codec/JSON.cpp (in the model) calls the vendored yyjson, so the parser
    # rides the same archive: a consumer that reaches no JSON pulls neither
    # member, and one that does needs no source list of its own to say so.
    add_library(ubiquitty-core-model STATIC
        ${UBIQUITTY_L0_SOURCES}
        ${UBIQUITTY_L1_SOURCES}
        ${UBIQUITTY_RE2_SOURCES}
        ${UBIQUITTY_SIMDUTF_SOURCES}
        Source/ThirdParty/yyjson/yyjson.c)
    set_source_files_properties(Source/ThirdParty/yyjson/yyjson.c PROPERTIES
        COMPILE_FLAGS "-std=c99 -Wno-error -w")

    # ubiquitty-behaviour: the L2 behaviour + Transport-SDK layer, over the
    # model. Themes.cpp (L2) needs the generated builtinThemesTOML TU.
    add_library(ubiquitty-behaviour STATIC
        ${UBIQUITTY_L2_SOURCES}
        ${_core_themes_gen})
    target_link_libraries(ubiquitty-behaviour PUBLIC ubiquitty-core-model)

    # ubiquitty-core: the aggregate every consumer links — surface unchanged by
    # the split (identical symbols + headers). Carries the bundled POSIX PAL
    # backend (L3b), which belongs to neither package.
    add_library(ubiquitty-core STATIC
        ${UBIQUITTY_L3b_SOURCES})
    # The three archives reference each other in both directions by design: L2
    # calls the PAL contract and L3b implements it, so behaviour's undefined
    # symbols resolve in an archive that precedes it on the link line. Apple's
    # linker rescans and does not care; GNU ld makes one pass per archive and
    # leaves them undefined, so every consumer needs the group rather than each
    # consumer discovering this.
    target_link_libraries(ubiquitty-core PUBLIC ubiquitty-behaviour)
    # …and back: L2 calls the PAL contract that this L3b backend defines, so the
    # reference genuinely runs both ways. Declaring the cycle is what makes
    # CMake repeat the archives, which is what a linker that resolves in one
    # pass needs. Apple's linker rescans every archive and never needed the
    # repetition; what it does with it is print `ld: warning: ignoring
    # duplicate libraries` on every link in the tree, tests included — the same
    # words as a link line naming a library twice by accident, which is the
    # only kind worth being told about. So the back-edge is declared only for
    # the linker that needs it. Nothing links behaviour on its own — core is
    # its one consumer — so on Apple the one direction above is the whole
    # graph.
    if(NOT APPLE)
        target_link_libraries(ubiquitty-behaviour PUBLIC ubiquitty-core)
        # The model calls the PAL contract too: OSC 7 asks the platform its
        # host name (PAL::systemHostName, which this backend defines), and the
        # model's archive is the last on a consumer's link line, where one
        # pass leaves that reference undefined.
        target_link_libraries(ubiquitty-core-model PUBLIC ubiquitty-core)
    endif()
    # This target compiles the L3b backend and nothing else, and that backend
    # includes its own Platform/POSIX/*.h. Those headers are in no layer stage,
    # since staging them would put a platform backend inside the model and
    # behaviour include boundary, so the target reads the real source root. The
    # path is PRIVATE so that no consumer of the library inherits it.
    target_include_directories(ubiquitty-core PRIVATE ${CMAKE_SOURCE_DIR}/Source)

    # ubiquitty-kit: the Tier-3 embedder facade (UbiquittyKit::Session — one
    # object, local or remote origin) over the layer chain. Additive: no
    # in-tree frontend links it; its surface is versioned by kitVersion
    # (Source/UbiquittyKit/Version.h), independent of coreVersion.
    add_library(ubiquitty-kit STATIC
        Source/UbiquittyKit/Session.cpp)
    target_link_libraries(ubiquitty-kit PUBLIC ubiquitty-core)

    # Installable-package wiring (find_package(UbiquittyCore)). The package
    # version is the SUPPORTED-SURFACE semver from Source/UbiquittyCore/Version.h
    # (single source), independent of the app VERSION.
    include(GNUInstallDirs)
    file(READ ${CMAKE_SOURCE_DIR}/Source/UbiquittyCore/Version.h _ubq_ver_h)
    string(REGEX MATCH "coreVersionMajor = ([0-9]+)" _ "${_ubq_ver_h}")
    set(_ubq_major ${CMAKE_MATCH_1})
    string(REGEX MATCH "coreVersionMinor = ([0-9]+)" _ "${_ubq_ver_h}")
    set(_ubq_minor ${CMAKE_MATCH_1})
    string(REGEX MATCH "coreVersionPatch = ([0-9]+)" _ "${_ubq_ver_h}")
    set(_ubq_patch ${CMAKE_MATCH_1})
    set(UBIQUITTY_CORE_API_VERSION "${_ubq_major}.${_ubq_minor}.${_ubq_patch}")
    set(_ubq_incdir ${CMAKE_INSTALL_INCLUDEDIR}/UbiquittyCore-${_ubq_major}.${_ubq_minor})

    # Durable published-header topology: each layer's BUILD-interface include
    # dir is a STAGED tree holding only its own modules' headers, so an upward
    # include fails at compile time (no Preferences/ header exists in the model
    # stage) — the compile-time half of the Rule-10 boundary. Lower stages
    # propagate to higher targets through the PUBLIC links; the INSTALL
    # interface stays the versioned install include dir.
    set(_ubq_stage ${CMAKE_CURRENT_BINARY_DIR}/layer-include)
    # The module lists come from check-core-layer-partition.sh, which is also what
    # assigns each TU its layer. They were written here as well until the two
    # copies drifted into opposite match orders: the headers staged correctly
    # while the TUs did not, so ubiquitty-core-model shipped the behaviour layer
    # and nothing reported it. One spelling, read by both.
    #
    # Matched against paths relative to Source/, behaviour before model — a bare
    # "Core" is a model prefix and every behaviour subtree lives under it, so the
    # other order stages behaviour into model and disables the Rule-10
    # compile-time boundary instead of enforcing it.
    foreach(_layer_modules L1 L2)
        execute_process(
            COMMAND ${CMAKE_SOURCE_DIR}/Scripts/check-core-layer-partition.sh --emit-modules ${_layer_modules}
            WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
            OUTPUT_VARIABLE _modules_out RESULT_VARIABLE _modules_rc)
        if(NOT _modules_rc EQUAL 0)
            message(FATAL_ERROR "check-core-layer-partition.sh --emit-modules ${_layer_modules} failed")
        endif()
        string(STRIP "${_modules_out}" _modules_out)
        string(REPLACE "\n" ";" _modules_out "${_modules_out}")
        set(_ubq_${_layer_modules}_modules "${_modules_out}")
    endforeach()
    set(_ubq_behaviour_modules ${_ubq_L2_modules})
    set(_ubq_model_modules ${_ubq_L1_modules})
    # The stage has to be a function of the CURRENT classification, not of every
    # classification this build directory has ever seen: reclassify a module and
    # its old staged copy stays where it was, so the Rule-10 boundary keeps
    # admitting an include it should now reject — silently, because the compile
    # still succeeds.
    #
    # Emptying the stages first achieves that and costs the whole team. Every
    # staged header is then NEW on every configure — fresh mtime, identical
    # contents — so every translation unit including one rebuilds: 159 of them
    # per configure, on every push, for every checkout. `configure_file(COPYONLY)`
    # below is already write-if-different and would have left those mtimes
    # alone; it never got the chance, because the file it would have compared
    # against had just been deleted.
    #
    # So the wanted set is collected as the stage is filled, and the sweep after
    # the loop removes only what is absent from it. Both properties hold: a header
    # that changed layer loses its old copy, and a header that changed nothing
    # keeps its mtime.
    set(_ubq_staged_wanted "")
    file(GLOB_RECURSE _ubq_all_headers RELATIVE ${CMAKE_SOURCE_DIR}/Source
        CONFIGURE_DEPENDS ${CMAKE_SOURCE_DIR}/Source/*.h)
    # Top-level directories whose headers go into no stage at all.
    set(_ubq_unstaged_roots ThirdParty/ Platform/ PAL/)
    foreach(_header ${_ubq_all_headers})
        set(_stage_dir "")
        string(REGEX MATCH "^[^/]+/" _header_root "${_header}")
        get_filename_component(_header_dir "${_header}" DIRECTORY)
        if(_header STREQUAL "Forward.h")
            set(_stage_dir model)
        elseif(_header_dir STREQUAL "PAL")
            set(_stage_dir model) # the L0 PAL contract; per-OS backend subdirs stage nowhere
        elseif(_header MATCHES "^UbiquittyKit/")
            set(_stage_dir kit)
        elseif(_header_root IN_LIST _ubq_unstaged_roots)
            set(_stage_dir "") # vendored + concrete backends: no layer stage
        else()
            # A behaviour module's path is longer than the Core/ prefix the model
            # list claims, so the behaviour list gets the first look and the
            # model list only sees what it left unclaimed.
            foreach(_stage_layer behaviour model)
                if(NOT _stage_dir)
                    foreach(_module ${_ubq_${_stage_layer}_modules})
                        if(_header MATCHES "^${_module}/")
                            set(_stage_dir ${_stage_layer})
                        endif()
                    endforeach()
                endif()
            endforeach()
        endif()
        if(_stage_dir)
            # configure_file rather than file(COPY): configure_file registers the input as a
            # configure dependency, so editing a header's CONTENTS re-runs CMake and
            # refreshes the staged copy. file(COPY) runs once and leaves the stage
            # stale until something else forces a reconfigure — and because every
            # target includes the stage ahead of Source/, the build then compiles
            # against the OLD header while reporting success.
            configure_file(${CMAKE_SOURCE_DIR}/Source/${_header}
                ${_ubq_stage}/${_stage_dir}/${_header} COPYONLY)
            list(APPEND _ubq_staged_wanted ${_ubq_stage}/${_stage_dir}/${_header})
        endif()
    endforeach()
    # Protocol/Tmux stages under model ahead of the generic behaviour match sees
    # Protocol/Sync — the two subtrees land in different stages by the explicit
    # per-subtree patterns above. The generated Terminfo blob header is
    # root-relative in its includer, so it stages at the behaviour root.
    if(EXISTS ${CMAKE_SOURCE_DIR}/Source/UbiquittyTerminfo.h)
        configure_file(${CMAKE_SOURCE_DIR}/Source/UbiquittyTerminfo.h
            ${_ubq_stage}/behaviour/UbiquittyTerminfo.h COPYONLY)
        list(APPEND _ubq_staged_wanted ${_ubq_stage}/behaviour/UbiquittyTerminfo.h)
    endif()

    # Remove staged headers the current classification does not want: one whose
    # module moved between layers, and one whose source header was deleted or
    # renamed. Everything else keeps the mtime `configure_file` decided not to
    # touch, which is what keeps the dependent rebuilds off.
    file(GLOB_RECURSE _ubq_staged_present ${_ubq_stage}/model/*.h
        ${_ubq_stage}/behaviour/*.h ${_ubq_stage}/kit/*.h)
    foreach(_staged ${_ubq_staged_present})
        if(NOT _staged IN_LIST _ubq_staged_wanted)
            file(REMOVE ${_staged})
        endif()
    endforeach()

    target_include_directories(ubiquitty-core-model PUBLIC
        $<BUILD_INTERFACE:${_ubq_stage}/model>
        $<INSTALL_INTERFACE:${_ubq_incdir}>)
    target_include_directories(ubiquitty-behaviour PUBLIC
        $<BUILD_INTERFACE:${_ubq_stage}/behaviour>)
    target_include_directories(ubiquitty-kit PUBLIC
        $<BUILD_INTERFACE:${_ubq_stage}/kit>)
    # Each layer's OWN TUs compile against the full tree (vendored ThirdParty
    # reaches through published headers; Rule 10 guards their source-level
    # discipline) — PRIVATE, so CONSUMERS resolve only through the stages.
    foreach(_ubq_layer_target ubiquitty-core-model ubiquitty-behaviour ubiquitty-kit)
        target_include_directories(${_ubq_layer_target} PRIVATE ${CMAKE_SOURCE_DIR}/Source)
    endforeach()
    # RE2 headers are an implementation detail of ScrollSearch.cpp — PRIVATE,
    # never part of the installed package surface; SYSTEM so re2's own header
    # diagnostics don't surface through ScrollSearch.cpp's TU.
    target_include_directories(ubiquitty-core-model SYSTEM PRIVATE "${UBIQUITTY_RE2_DIR}" "${UBIQUITTY_SIMDUTF_DIR}")
    # WebKit style: no exceptions, no RTTI. The library is OS-clean — every TU
    # is framework- and (above the PAL/Transport seam) POSIX-free, enforced by
    # Scripts/check-boundaries.py.
    foreach(_ubq_layer_target ubiquitty-core-model ubiquitty-behaviour ubiquitty-core ubiquitty-kit)
        target_compile_features(${_ubq_layer_target} PUBLIC cxx_std_23)
        set_target_properties(${_ubq_layer_target} PROPERTIES
            CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
        target_compile_options(${_ubq_layer_target} PRIVATE
            -fno-exceptions -fno-rtti -Wall -Wextra
        ${UBIQUITTY_NARROWING_WARNING}
            "$<$<BOOL:${UBIQUITTY_WERROR}>:-Werror>"
            -Wno-deprecated-declarations -Wno-multichar -Wno-comment)
    endforeach()

    # Standalone consumer sample: links ubiquitty-core against an in-file STUB
    # PAL (the system-services half the bundled POSIX backend does not supply),
    # feeds bytes into a Terminal, reads a snapshot row, prints it. PROVES reuse
    # with no frontend.
    # The browser frontend: the same library chain core-consumer links, proving
    # a browser is a thin consumer of the portable Core rather than a parallel
    # implementation. Anything it cannot reach through ubiquitty-core is a gap in
    # Core, not something to write in JavaScript.
    if(EMSCRIPTEN)
        add_executable(ubiquitty-web
            Source/Platform/Web/WebFontInventory.cpp
            Source/Platform/Web/WebFontRasterizer.cpp
            Source/Platform/Web/WebTerminal.cpp
            Source/Platform/Web/WebRichText.cpp
            Source/Platform/Web/WebPAL.cpp
            Source/Platform/Web/WebExports.cpp)
        target_link_libraries(ubiquitty-web PRIVATE ubiquitty-core)
        target_include_directories(ubiquitty-web PRIVATE ${CMAKE_SOURCE_DIR}/Source)
        target_compile_features(ubiquitty-web PRIVATE cxx_std_23)
        set_target_properties(ubiquitty-web PROPERTIES
            CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF
            OUTPUT_NAME "ubiquitty" SUFFIX ".js")
        # MODULARIZE + EXPORT_ES6 so the page imports the module rather than
        # depending on a global; memory grows because the RGBA image scales with
        # the window.
        target_link_options(ubiquitty-web PRIVATE
            "SHELL:-s MODULARIZE=1"
            "SHELL:-s EXPORT_ES6=1"
            "SHELL:-s ALLOW_MEMORY_GROWTH=1"
            # HEAPU8 is not optional here: the page writes input bytes into the
            # heap and reads the rendered image straight out of it, so dropping
            # it leaves cwrap working and every buffer access undefined.
            "SHELL:-s EXPORTED_RUNTIME_METHODS=['ccall','cwrap','HEAPU8']"
            "SHELL:-s EXPORTED_FUNCTIONS=['_malloc','_free']"
            # node beside web so a headless render can load this module. The
            # snapshot tier compares frontends by their pixels, and a frontend
            # that only runs in a browser is compared by nothing.
            "SHELL:-s ENVIRONMENT=web,node"
            # The render keeps grid-sized scratch on the stack, which overruns
            # emscripten's 64 KB default: the size core-consumer gives it. The
            # stack goes below the static data so an overflow traps at address
            # zero; an optimised link otherwise puts the data first, and the
            # overflow rewrites it — the width table read back narrow, and a
            # wide glyph drew as a narrow one with nothing reporting it.
            "SHELL:-s STACK_SIZE=8388608"
            "SHELL:-s INITIAL_MEMORY=33554432"
            -Wl,--stack-first)
    endif()

    add_executable(core-consumer Samples/core-consumer/main.cpp)
    target_link_libraries(core-consumer PRIVATE ubiquitty-core)
    target_compile_features(core-consumer PRIVATE cxx_std_23)
    set_target_properties(core-consumer PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    target_compile_options(core-consumer PRIVATE
        -fno-exceptions -fno-rtti -Wall -Wextra
        ${UBIQUITTY_NARROWING_WARNING}
        "$<$<BOOL:${UBIQUITTY_WERROR}>:-Werror>")

    # Cross-platform golden-image producer. It links the same installable Core
    # and always renders through the embedded GNU Unifont software backend.
    add_executable(ubiquitty-snapshot Tools/snapshot/main.cpp)
    target_link_libraries(ubiquitty-snapshot PRIVATE ubiquitty-core)
    target_compile_features(ubiquitty-snapshot PRIVATE cxx_std_23)
    set_target_properties(ubiquitty-snapshot PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    target_compile_options(ubiquitty-snapshot PRIVATE
        -fno-exceptions -fno-rtti -Wall -Wextra
        ${UBIQUITTY_NARROWING_WARNING}
        "$<$<BOOL:${UBIQUITTY_WERROR}>:-Werror>")
    # forkpty lives in libutil on Linux/glibc (PTYStream is in the lib via the
    # POSIX PAL backend's transitive surface); a no-op on macOS.
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        target_link_libraries(core-consumer PRIVATE util)
    endif()
    # wasm32: the Core's maxColumns-sized stack buffers (rowBuffer[maxColumns])
    # overflow emscripten's 64 KB default stack — grow it and allow heap growth
    # for the Terminal's heap model. The result runs under node; no source impact.
    # Stack first, so an overflow past even this traps rather than rewriting
    # the static data an optimised link places below it.
    if(EMSCRIPTEN)
        target_link_options(core-consumer PRIVATE
            -sSTACK_SIZE=8388608 -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=33554432
            -Wl,--stack-first)
    endif()

    # ---- Install + export the package (find_package(UbiquittyCore)) ---------
    include(CMakePackageConfigHelpers)

    # All four archives ship: the aggregate's PUBLIC links make model +
    # behaviour part of its exported link interface, and Kit links that chain.
    # Every target must therefore be present in the export set.
    install(TARGETS ubiquitty-kit ubiquitty-core ubiquitty-behaviour ubiquitty-core-model
        EXPORT UbiquittyCoreTargets
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})

    # Install the same classified header trees that build-interface consumers
    # compile against. This includes the Core/Kit umbrellas, Base, PAL and
    # Forward.h, without maintaining a second module list or publishing the
    # concrete platform backends and vendored implementation headers.
    install(DIRECTORY
        "${_ubq_stage}/model/"
        "${_ubq_stage}/behaviour/"
        "${_ubq_stage}/kit/"
        DESTINATION ${_ubq_incdir}
        FILES_MATCHING PATTERN "*.h")

    install(EXPORT UbiquittyCoreTargets
        FILE UbiquittyCoreTargets.cmake
        NAMESPACE Ubiquitty::
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/UbiquittyCore)

    configure_package_config_file(
        ${CMAKE_SOURCE_DIR}/cmake/UbiquittyCoreConfig.cmake.in
        ${CMAKE_CURRENT_BINARY_DIR}/UbiquittyCoreConfig.cmake
        INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/UbiquittyCore)
    write_basic_package_version_file(
        ${CMAKE_CURRENT_BINARY_DIR}/UbiquittyCoreConfigVersion.cmake
        VERSION ${UBIQUITTY_CORE_API_VERSION}
        COMPATIBILITY SameMajorVersion)
    install(FILES
        ${CMAKE_CURRENT_BINARY_DIR}/UbiquittyCoreConfig.cmake
        ${CMAKE_CURRENT_BINARY_DIR}/UbiquittyCoreConfigVersion.cmake
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/UbiquittyCore)

    ubiquitty_install_license_notices("${CMAKE_INSTALL_DOCDIR}")

else()

    message(FATAL_ERROR
        "UBIQUITTY_FRONTEND='${UBIQUITTY_FRONTEND}' is not recognised. "
        "Valid values: macOS, iOS, Host, Agent, Linux, Wscons, Core.")

endif()

# ----------------------------------------------------------------------
# The host tests. Tests/CMakeLists.txt finds them on disk; nothing here or there
# keeps a list of them.
# ----------------------------------------------------------------------
if(UBIQUITTY_BUILD_TESTS AND NOT TARGET ubiquitty-core)
    message(FATAL_ERROR
        "UBIQUITTY_BUILD_TESTS links every test against ubiquitty-core, which only "
        "the Core frontend defines; configure with -DUBIQUITTY_FRONTEND=Core.")
elseif(UBIQUITTY_BUILD_TESTS)
    enable_testing()
    add_subdirectory(Tests)
endif()

# Every compiled target is built after the step that refreshes the generated
# version header, so the one translation unit that includes it never compiles
# against the previous commit's text and then again against this one's.
function(_ubq_order_after_build_version directory)
    get_property(_targets DIRECTORY "${directory}" PROPERTY BUILDSYSTEM_TARGETS)
    foreach(_target IN LISTS _targets)
        get_target_property(_type ${_target} TYPE)
        if(_type MATCHES "^(EXECUTABLE|STATIC_LIBRARY|SHARED_LIBRARY|MODULE_LIBRARY|OBJECT_LIBRARY)$")
            add_dependencies(${_target} ubiquitty-build-version)
        endif()
    endforeach()
    get_property(_subdirectories DIRECTORY "${directory}" PROPERTY SUBDIRECTORIES)
    foreach(_subdirectory IN LISTS _subdirectories)
        _ubq_order_after_build_version("${_subdirectory}")
    endforeach()
endfunction()
_ubq_order_after_build_version("${CMAKE_CURRENT_SOURCE_DIR}")
