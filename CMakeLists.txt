# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.13)

# Honor each Swift target's compilation mode, including whole-module Debug.
# This policy must be selected before Swift is first enabled.
if(POLICY CMP0157)
    cmake_policy(SET CMP0157 NEW)
endif()

# The checkouts this build reads besides its own tree: ubiquitty-core
# (libubiquitty and the multiplexer) and ubiquitty-kit (the renderers and the
# drop-in terminal views). Every path below names the checkout of the
# repository that owns the file; a file every repository carries is read from
# this tree. The Kit defaults to the submodule Libraries/ubiquitty-kit and Core
# to the Kit's own submodule, the Core that Kit pins, as Scripts/library-scripts.sh
# resolves them. Both are ABSOLUTE rather than REALPATH, so a compile line spells
# a root the way its caller did.
#
# Core's build modules are read from Core's checkout, at this top directory:
# Scripts/cmake/UbiquittyCoreRoot.cmake says why and in which order.
if(NOT DEFINED UBIQUITTY_CORE_SOURCE_DIR)
    set(UBIQUITTY_CORE_SOURCE_DIR "${CMAKE_SOURCE_DIR}/Libraries/ubiquitty-kit/Libraries/ubiquitty-core")
endif()
include("${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyCoreRoot.cmake")
if(NOT DEFINED UBIQUITTY_KIT_SOURCE_DIR)
    set(UBIQUITTY_KIT_SOURCE_DIR "${CMAKE_SOURCE_DIR}/Libraries/ubiquitty-kit")
endif()
get_filename_component(UBIQUITTY_KIT_SOURCE_DIR "${UBIQUITTY_KIT_SOURCE_DIR}" ABSOLUTE)
# The version is this tree's: its commit and its VERSION file, not Core's.
if(NOT DEFINED UBIQUITTY_VERSION_SOURCE_DIR)
    set(UBIQUITTY_VERSION_SOURCE_DIR "${CMAKE_SOURCE_DIR}")
endif()
# The header root, once per distinct checkout, Core's first: a single directory
# when every root is this tree.
set(UBIQUITTY_SOURCE_INCLUDE_DIRECTORIES
    "${UBIQUITTY_CORE_SOURCE_DIR}/Source" "${UBIQUITTY_KIT_SOURCE_DIR}/Source" "${CMAKE_SOURCE_DIR}/Source")
list(REMOVE_DUPLICATES UBIQUITTY_SOURCE_INCLUDE_DIRECTORIES)

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

# The compiler launcher, the deployment floors, the SDK and the version, which
# project() reads.
include("${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyPreProject.cmake")

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

# Xcode archives with libtool rather than ar and ranlib, so the recipe
# UbiquittyToolchain.cmake sets does not reach it. Its flag says the same thing,
# set per static library below because the generator writes an empty
# OTHER_LIBTOOLFLAGS on every target and that overrides a project-wide value.
#
# The App Intents metadata step has nothing to extract: no target here declares
# an intent, and the step otherwise reports "Metadata extraction skipped" for
# the app and asks every Swift library for compiler-emitted .swiftconstvalues
# the libraries are not built to produce.
if(CMAKE_GENERATOR MATCHES "Xcode")
    set(CMAKE_XCODE_ATTRIBUTE_LM_SKIP_METADATA_EXTRACTION YES)
endif()

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

# Core's toolchain, optimisation, sources and libraries, which every arm below
# builds on.
include("${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyToolchain.cmake")
include("${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyOptimize.cmake")
include("${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyCoreSources.cmake")
include("${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyCoreLibrary.cmake")

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
# The two Apple arms build application bundles, which carry their resources
# and licence notices inside, around the Kit's Swift modules and shaders, which
# each arm creates where it compiles them.
if(UBIQUITTY_FRONTEND STREQUAL "macOS" OR UBIQUITTY_FRONTEND STREQUAL "iOS")
    include("${UBIQUITTY_KIT_SOURCE_DIR}/cmake/BundleResources.cmake")
    include("${UBIQUITTY_KIT_SOURCE_DIR}/cmake/BundleLicenseNotices.cmake")
    include("${UBIQUITTY_KIT_SOURCE_DIR}/Scripts/cmake/UbiquittyKit.cmake")
endif()

if(UBIQUITTY_FRONTEND STREQUAL "macOS")

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
        "-DCORE_SOURCE_DIR=${UBIQUITTY_CORE_SOURCE_DIR}"
        "-DKIT_SOURCE_DIR=${UBIQUITTY_KIT_SOURCE_DIR}"
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
    ubiquitty_add_core_ios_library(ubiquitty-core-ios EXCLUDE
        # Nothing is trimmed for naming a spawn any more — the iOS backends
        # UbiquittyCoreSources.cmake swaps in answer, so the policy is enforced
        # by what the binary contains rather than by hoping no caller survives
        # the cut.
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
        # Its consumers in this arm include the app's bridge and the Swift
        # modules, so the header root it publishes is every checkout's.
        INCLUDE_DIRECTORIES ${UBIQUITTY_SOURCE_INCLUDE_DIRECTORIES})

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
        target_sources(ubiquitty-core-ios PRIVATE ${UBIQUITTY_QUIC_CLIENT_SOURCES})
        target_include_directories(ubiquitty-core-ios PRIVATE
            "${UBIQUITTY_QUIC_PLATFORM_PREFIX}/include")
        target_compile_definitions(ubiquitty-core-ios PRIVATE UBIQUITTY_QUIC=1)
        ubiquitty_link_quic_archives(ubiquitty-core-ios PUBLIC "${UBIQUITTY_QUIC_PLATFORM_PREFIX}")
        message(STATUS "ubiquitty-core-ios: QUIC transport enabled (ngtcp2 + AWS-LC)")
    endif()

    # ubiquitty-kit: the Tier-3 embedder facade (UbiquittyKit::Session), and the
    # iOS shell's whole view of a session. It sits outside the portable-core SSOT
    # because it is a layer above it, so an arm that wants it names it — as the
    # Core frontend does.
    ubiquitty_add_session_facade(ubiquitty-kit CORE_TARGET ubiquitty-core-ios)
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
    set_source_files_properties(Source/Platform/iOS/ShowcaseHost.cpp PROPERTIES INCLUDE_DIRECTORIES "${UBIQUITTY_CORE_SOURCE_DIR}/Tests")
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
    target_include_directories(ubiquitty-core-ios-link PRIVATE ${UBIQUITTY_SOURCE_INCLUDE_DIRECTORIES})
    # The archives are linked as libraries below, with the shared Swift Kit.
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
                "${CMAKE_SOURCE_DIR}/Scripts/cmake/ResolveSwiftPackage.cmake"
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

    # The shell's own module map, rendered from a template so that each header
    # it names is spelled from its owner's checkout. Only the app's module
    # imports it, so only the app's search path names its directory.
    set(UBIQUITTY_IOS_MODULE_MAP_DIR "${CMAKE_BINARY_DIR}/modulemaps/ios")
    configure_file("${CMAKE_SOURCE_DIR}/Source/Platform/iOS/module.modulemap.in"
        "${UBIQUITTY_IOS_MODULE_MAP_DIR}/module.modulemap" @ONLY)

    # The XCUITest bundle (UbiquittyUITests below) drives the app, and the
    # consent check it makes feeds Core's real queue, through a door normal
    # applications cannot see.
    option(UBIQUITTY_IOS_UI_TESTS "Build the iOS XCUITest bundle" OFF)
    # Whether the bundle is built: for the simulator alone, for the reason
    # UbiquittyUITests below gives. The door it reaches is compiled into the
    # arm's Swift modules and C++ under the same answer.
    set(UBIQUITTY_IOS_UI_TEST_BUNDLE OFF)
    set(UBIQUITTY_IOS_SWIFT_CONDITIONS "")
    if(UBIQUITTY_IOS_UI_TESTS AND CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
        set(UBIQUITTY_IOS_UI_TEST_BUNDLE ON)
        list(APPEND UBIQUITTY_IOS_SWIFT_CONDITIONS UBIQUITTY_IOS_UI_TESTS)
    endif()

    # ------------------------------------------------------------------
    # The Apple-shared Swift layer, compiled here from the same lists the macOS
    # arm compiles: UbiquittyRenderKit, Metal and CoreText over the portable
    # Core — the renderer, not a second one written for this platform — and
    # the UbiquittyKit module the shell hosts, which imports the render kit
    # internally and so keeps C++ out of the interface this shell holds. Core
    # is all the renderer calls; the session facade and the shell's bridge sit
    # above it and are the app's to link.
    # ------------------------------------------------------------------
    ubiquitty_kit_swift_flags(PLATFORM iOS SOURCE_ROOTS "${CMAKE_SOURCE_DIR}")
    ubiquitty_kit_add_swift_modules(PLATFORM iOS
        CXX_TARGETS ubiquitty-core-ios ubiquitty-ios-bridge
        MODULE_MAPS "${UBIQUITTY_IOS_MODULE_MAP_DIR}/module.modulemap"
        LINK_LIBRARIES ubiquitty-core-ios
        CONDITIONS ${UBIQUITTY_IOS_SWIFT_CONDITIONS})

    # The bridge, and the shared Swift Kit owning the protected sealer the
    # bridge's ColdResumeBridge calls. Both are linked normally: global
    # -all_load would load Swift archives twice when their module dependencies
    # also autolink them.
    target_link_libraries(ubiquitty-core-ios-link PRIVATE UbiquittyKitModule ubiquitty-ios-bridge)
    set_property(TARGET ubiquitty-core-ios-link PROPERTY LINKER_LANGUAGE Swift)
    # The C++-only probe uses Swift's driver, which supplies libc++ when
    # interoperability is explicit, as it is for the app and framework.
    target_link_options(ubiquitty-core-ios-link PRIVATE -cxx-interoperability-mode=default)

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
        Source/Platform/iOS/App/SSHInboundBuffer.swift
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
    ubiquitty_kit_add_metal_library(ubiquitty-ios-shaders PLATFORM iOS
        OUTPUT_DIRECTORY "${UBIQUITTY_IOS_PLATFORM_DIR}"
        PLATFORM_LABEL "${UBIQUITTY_IOS_PLATFORM_LABEL}"
        STEP ${UBIQUITTY_IOS_STEP} -DSTEP=shaders
        STEP_SCRIPT "${UBIQUITTY_IOS_STEP_SCRIPT}")

    # The shell's own module is whole-module too, as every Swift target of the
    # arm is: it reaches Core's frame capture directly, so it inlines the same
    # headers the kits do. Scripts/check-xcode-workspace.py holds each one to
    # the mode in each configuration.
    add_executable(UbiquittyIOSApp MACOSX_BUNDLE ${UBIQUITTY_IOS_APP_SOURCES})
    ubiquitty_kit_swift_whole_module(UbiquittyIOSApp)
    ubiquitty_bundle_license_notices(UbiquittyIOSApp)
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
        list(APPEND UBIQUITTY_IOS_BUNDLED_FONTS "${UBIQUITTY_CORE_SOURCE_DIR}/Resources/fonts/${font}")
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
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-I ${UBIQUITTY_IOS_MODULE_MAP_DIR}>"
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-I ${CMAKE_CURRENT_BINARY_DIR}>"
        # The module search path and every generated C module map, read from a
        # response file because the set is the dependency graph's rather than
        # ours and does not exist until the package has been built.
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:@${_ubq_ssh_flags}>")
    # The importer reads Core's headers under every definition the C++ that
    # compiles Core and this app's own C++ carry, and a Core type the two lay
    # out apart fails the link of the layout probe the app waits for.
    ubiquitty_kit_forward_definitions(UbiquittyIOSApp CXX_TARGETS ubiquitty-core-ios ubiquitty-ios-bridge UbiquittyIOSApp)
    ubiquitty_kit_add_layout_probe(PLATFORM iOS CXX_TARGETS ubiquitty-core-ios ubiquitty-ios-bridge)
    add_dependencies(UbiquittyIOSApp ubiquitty-kit-layout-probe)
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
    if(UBIQUITTY_IOS_UI_TEST_BUNDLE)
        # Keep the importer and C++ definitions in agreement without enabling
        # the desktop-only UI harness: the Kit's modules carry the condition
        # given them above, and the app's module and C++ carry it here.
        ubiquitty_kit_add_swift_conditions(UbiquittyIOSApp ${UBIQUITTY_IOS_SWIFT_CONDITIONS})
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
# link set in Core's Scripts/run-tests.sh — a live Terminal pulls in the full OSC /
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
    ubiquitty_core_subset(UBIQUITTY_HOST_CORE ABSOLUTE EXCLUDE
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
        Source/Core/Selection/SelectionOverCapture.cpp
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
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/main.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/LocalHostInstall.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/AttachRelay.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/Daemon.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HandoverAdmission.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HandoverRequest.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HandoverAuthorityTables.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HandoverGlobalTables.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HandoverEffects.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HandoverRuntime.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HandoverTables.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HandoverWorkspaceTables.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HostTableHandover.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HostHandover.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HandoverStartup.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/SessionHandoverFacts.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/SessionHandover.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/PTYStream.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/PTYFacts.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/PAL/OutputQueue.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HostPaths.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/ClipboardTool.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/ResumeRecordTool.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/ShellIntegrationFiles.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HostPAL.cpp
        # In-process adoption fixtures link this same POSIX ownership sender
        # as the native app, without an exiting descriptor-adoption CLI helper.
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/SessionHandoff.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/HandoverLease.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/HandoverTransport.cpp
        # Portable Core (single-sourced from Scripts/portable-core-sources.txt;
        # ControlPaths + Tmux.cpp + NativeAttachment + QUICBootstrap come in via the
        # SSOT — Core's Terminal embeds the tmux -CC client, so Tmux.cpp stays).
        ${UBIQUITTY_HOST_CORE}
        ${UBIQUITTY_SIMDUTF_SOURCES}
        # Codec/JSON.cpp wraps it, for the calls Sync/Control.cpp reads.
        ${UBIQUITTY_YYJSON_SOURCE}
        # ScrollSearch.cpp stays in this subset for `pane.search`, so the RE2
        # units ride along.
        ${UBIQUITTY_RE2_SOURCES}
    )
    ubiquitty_embed_builtin_themes(_ubq_host_themes_gen)
    target_sources(ubiquitty-host PRIVATE ${_ubq_host_themes_gen})
    set(_ubq_host_shell_integration_gen ${CMAKE_CURRENT_BINARY_DIR}/ShellIntegrationScripts.gen.cpp)
    ubiquitty_generate_shell_integration_source(${_ubq_host_shell_integration_gen})
    target_sources(ubiquitty-host PRIVATE ${_ubq_host_shell_integration_gen})
    target_include_directories(ubiquitty-host PRIVATE "${UBIQUITTY_CORE_SOURCE_DIR}/Source")
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
            ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HostQUIC.cpp
            ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/DatagramBatch.cpp)
        target_include_directories(ubiquitty-host PRIVATE "${UBIQUITTY_QUIC_PREFIX}/include")
        target_compile_definitions(ubiquitty-host PRIVATE UBIQUITTY_QUIC=1)
        ubiquitty_link_quic_archives(ubiquitty-host PRIVATE "${UBIQUITTY_QUIC_PREFIX}")
    endif()

    if(UBIQUITTY_BUILD_SYNC_TRANSPORT_ACCEPTANCE)
        # The fixture's server uses the shipping host source set and reactor.
        # Its attach/bootstrap modes call the same production entry point;
        # renaming only this separate object leaves ubiquitty-host unchanged.
        get_target_property(_ubq_transport_host_sources ubiquitty-host SOURCES)
        list(REMOVE_ITEM _ubq_transport_host_sources
            ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/main.cpp)
        add_library(ubq-sync-transport-host-objects OBJECT EXCLUDE_FROM_ALL
            ${_ubq_transport_host_sources}
            ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/QUICClient.cpp
            ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Core/Transport/QUICChannel.cpp)
        add_library(ubq-sync-transport-main-object OBJECT EXCLUDE_FROM_ALL
            ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/main.cpp)
        target_compile_definitions(ubq-sync-transport-main-object PRIVATE main=ubiquittyHostMain)
        add_executable(sync_transport_acceptance EXCLUDE_FROM_ALL
            ${UBIQUITTY_CORE_SOURCE_DIR}/Tests/Host/sync_transport_acceptance.cpp
            $<TARGET_OBJECTS:ubq-sync-transport-host-objects>
            $<TARGET_OBJECTS:ubq-sync-transport-main-object>)
        foreach(_ubq_transport_target IN ITEMS
                ubq-sync-transport-host-objects ubq-sync-transport-main-object sync_transport_acceptance)
            target_include_directories(${_ubq_transport_target} PRIVATE
                "$<TARGET_PROPERTY:ubiquitty-host,INCLUDE_DIRECTORIES>" "${UBIQUITTY_CORE_SOURCE_DIR}/Tests")
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
    ubiquitty_core_subset(UBIQUITTY_AGENT_CORE ABSOLUTE EXCLUDE
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
        Source/Core/Selection/SelectionOverCapture.cpp
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
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Agent/main.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Agent/AgentSession.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Agent/AgentMCP.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Agent/RemoteCarrier.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Core/Codec/JSON.cpp
        ${UBIQUITTY_YYJSON_SOURCE}
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HostPaths.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HostPAL.cpp
        # Portable Core (single-sourced from Scripts/portable-core-sources.txt;
        # ControlPaths + NativeAttachment/SyncClientCore + Tmux.cpp arrive via SSOT).
        ${UBIQUITTY_AGENT_CORE}
        ${UBIQUITTY_SIMDUTF_SOURCES}
    )
    ubiquitty_generate_completions_header(
        "${CMAKE_CURRENT_BINARY_DIR}/generated/Agent/CompletionScripts.h")
    target_include_directories(ubq PRIVATE "${UBIQUITTY_CORE_SOURCE_DIR}/Source"
        "${CMAKE_CURRENT_BINARY_DIR}/generated")
    target_include_directories(ubq SYSTEM PRIVATE "${UBIQUITTY_SIMDUTF_DIR}")
    target_compile_features(ubq PRIVATE cxx_std_23)
    set_target_properties(ubq PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    target_compile_options(ubq PRIVATE
        -fno-exceptions -fno-rtti -Wall -Wextra
        ${UBIQUITTY_NARROWING_WARNING}
        "$<$<BOOL:${UBIQUITTY_WERROR}>:-Werror>")

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
    ubiquitty_core_subset(UBIQUITTY_LINUX_CORE ABSOLUTE EXCLUDE
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
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/Accessibility.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/AccessibleTerminal.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/VulkanRenderer.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/VulkanColorGlyphAtlas.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/VulkanGlyphAtlas.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/VulkanImageTextures.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/BundledFontDirectory.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/FontInventory.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/FontRouting.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/PangoRichText.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/ColorGlyphPainter.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/FreeTypeRasterizer.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/Raster.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/PAL.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/Clipboard.cpp
        Source/Platform/Linux/ConfigurationWatcher.cpp
        Source/Platform/Linux/Updater.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/PointerLock.cpp
        # PTY transport + platform seam (this frontend runs Core locally with its
        # own PTY; PTYStream/PTYFacts/OutputQueue/PasteNormalize are not in the SSOT).
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/PTYStream.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/PTYFacts.cpp
        # The gated kitty file read (t=f / t=t), shared with the macOS arm so the
        # hardening rules have one home rather than one per frontend.
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/GatedFileRead.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/VulkanCoverageSheet.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/PAL/OutputQueue.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Core/Input/PasteNormalize.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Core/Preferences/FontRoutePreferences.cpp
        # Portable Core (single-sourced from Scripts/portable-core-sources.txt;
        # the local session driver, input encoders, themes, layout model, and the
        # software renderer all arrive via the SSOT below — HostPaths/ControlPaths
        # come in via the SSOT (ControlPaths) + inline (HostPaths, not in SSOT)).
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HostPaths.cpp
        # Codec/JSON.cpp arrives via the SSOT and ControlRPC calls it for the
        # control socket, so the parser it wraps has to be in the link set.
        ${UBIQUITTY_YYJSON_SOURCE}
        ${UBIQUITTY_LINUX_CORE}
        # ScrollSearch.cpp stays in this subset, so the RE2 TUs ride along.
        ${UBIQUITTY_RE2_SOURCES}
        ${UBIQUITTY_SIMDUTF_SOURCES}
    )
    # gdk_x11_display_get_xdisplay / gdk_x11_surface_get_xid are GDK4's only
    # route to the raw Xlib handles XWarpPointer/XFixesHideCursor need, and
    # this GTK build marks them deprecated (GTK5's backend getters move
    # elsewhere) with no in-GTK4 replacement — so only this warning, and only
    # in the one file that calls them, is downgraded from -Werror.
    if(UBIQUITTY_X11_FOUND)
        set_source_files_properties(${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/PointerLock.cpp PROPERTIES
            COMPILE_FLAGS "-Wno-error=deprecated-declarations")
    endif()
    target_include_directories(ubiquitty-linux PRIVATE ${UBIQUITTY_SOURCE_INCLUDE_DIRECTORIES})
    target_include_directories(ubiquitty-linux SYSTEM PRIVATE "${UBIQUITTY_RE2_DIR}" "${UBIQUITTY_SIMDUTF_DIR}")
    if(NOT APPLE)
        # Portable <MacTypes.h> stand-in for this non-Apple build (Selection.h and
        # the other shared headers that include <MacTypes.h> directly), mirroring
        # Core's Scripts/run-tests.sh's HOST_COMPAT include. Base/Types.h self-provides the
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

    # Built-in themes, the generated definition of builtinThemesTOML that
    # Themes.cpp parses at startup.
    ubiquitty_embed_builtin_themes(_ubq_linux_themes_gen COMMENT "Embedding built-in themes TOML")
    target_sources(ubiquitty-linux PRIVATE ${_ubq_linux_themes_gen})

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
        # Generated C, not this target's own: silenced the way yyjson.c is,
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
                        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/shaders/${shader}
                        -o ${CMAKE_CURRENT_BINARY_DIR}/${shader}.spv
                DEPENDS ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/shaders/${shader}
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
                    "${UBIQUITTY_CORE_SOURCE_DIR}/Resources/fonts/${font}"
                    "${CMAKE_CURRENT_BINARY_DIR}/${font}"
            DEPENDS "${UBIQUITTY_CORE_SOURCE_DIR}/Resources/fonts/${font}"
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
    ubiquitty_core_subset(UBIQUITTY_WSCONS_CORE ABSOLUTE EXCLUDE
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
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Wscons/WsconsDisplay.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Wscons/WsconsKeyboard.cpp
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Wscons/WsconsPAL.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/SystemPAL.cpp
        # PTY transport + platform seam (forkpty's Darwin/OpenBSD/NetBSD path
        # in PTYStream.cpp already covers this OS — see its <util.h> branch).
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/PTYStream.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/PTYFacts.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/PAL/OutputQueue.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Core/Input/PasteNormalize.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Core/Preferences/FontRoutePreferences.cpp
        ${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Host/HostPaths.cpp
        ${UBIQUITTY_WSCONS_CORE}
        ${UBIQUITTY_RE2_SOURCES}
        ${UBIQUITTY_SIMDUTF_SOURCES}
    )
    target_include_directories(ubiquitty-wscons PRIVATE ${UBIQUITTY_SOURCE_INCLUDE_DIRECTORIES} "${UBIQUITTY_RE2_DIR}")
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

    # Built-in themes, the same generation step as Linux.
    ubiquitty_embed_builtin_themes(_ubq_wscons_themes_gen COMMENT "Embedding built-in themes TOML")
    target_sources(ubiquitty-wscons PRIVATE ${_ubq_wscons_themes_gen})

# ----------------------------------------------------------------------
# Core — the standalone libUbiquittyCore static library + its consumer
# sample. The portable terminal Core as a real,
# reusable build artifact: no frontend, no Apple/GTK/Vulkan, no external
# transport stack. The library links against nothing but Source/ + a
# caller-supplied PAL. The source set is the SINGLE canonical list in
# Scripts/portable-core-sources.txt, read by UbiquittyCoreSources.cmake and by
# the bash perf drivers so the list can never drift.
#
#   cmake -S . -B build/core -DUBIQUITTY_FRONTEND=Core -DUBIQUITTY_QUIC=OFF
#   cmake --build build/core
#
# Public umbrella header: Source/UbiquittyCore/UbiquittyCore.h. Curated public surface
# (Terminal lifecycle + processBytes, snapshot/getDisplayRow, the paint model,
# Preferences, the PAL contract). See Docs/libubiquittycore.md.
# ----------------------------------------------------------------------
elseif(UBIQUITTY_FRONTEND STREQUAL "Core")

    # The standalone lib links the FULL canonical portable-Core set (the same
    # list the host/agent/linux frontends trim from), as the layer libraries
    # every consumer of Core links.
    ubiquitty_add_core_layer_libraries()

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
        target_include_directories(ubiquitty-web PRIVATE ${UBIQUITTY_SOURCE_INCLUDE_DIRECTORIES})
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

    add_executable(core-consumer ${UBIQUITTY_CORE_SOURCE_DIR}/Samples/core-consumer/main.cpp)
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
    add_executable(ubiquitty-snapshot ${UBIQUITTY_CORE_SOURCE_DIR}/Tools/snapshot/main.cpp)
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

    # The package find_package(UbiquittyCore) reads, with its licence notices.
    ubiquitty_install_core_package()

else()

    message(FATAL_ERROR
        "UBIQUITTY_FRONTEND='${UBIQUITTY_FRONTEND}' is not recognised. "
        "Valid values: macOS, iOS, Host, Agent, Linux, Wscons, Core.")

endif()

# ----------------------------------------------------------------------
# The app's host tests and shell integration scenarios use its pinned Core.
# Core and Kit register their own unit suites in their respective projects.
# ----------------------------------------------------------------------
if(UBIQUITTY_BUILD_TESTS AND NOT TARGET ubiquitty-core)
    message(FATAL_ERROR
        "UBIQUITTY_BUILD_TESTS links every test against ubiquitty-core, which only "
        "the Core frontend defines; configure with -DUBIQUITTY_FRONTEND=Core.")
elseif(UBIQUITTY_BUILD_TESTS)
    enable_testing()
    add_subdirectory(Tests)
endif()

# Last, once every target of every arm exists.
ubiquitty_order_after_build_version("${CMAKE_CURRENT_SOURCE_DIR}")
