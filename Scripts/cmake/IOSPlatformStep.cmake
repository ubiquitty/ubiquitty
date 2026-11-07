# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# IOSPlatformStep.cmake — the iOS build steps whose output belongs to one SDK.
#
# Four things in the iOS arm are built by a tool CMake does not drive, and each
# comes out different for a device and for the simulator: the SwiftPM archive
# (a triple), the shader library (a minimum-version flag), the app icon (an
# actool platform), and the copy of the last two into the bundle.
#
# They are here, behind one script, because of who decides the SDK. A Ninja tree
# is configured for one SDK and stays there, so its configure step could spell
# the answer into each command. An Xcode project cannot: the destination picked
# in the toolbar chooses the SDK at build time, long after configure, and a
# project with one SDK written into its commands builds simulator artefacts into
# a device app the moment somebody selects a phone. So the platform is read when
# the step runs — handed in by the Ninja tree, taken from Xcode's PLATFORM_NAME
# otherwise — and every path that depends on it is derived here from that one
# answer.
#
#   cmake -DSTEP=<ssh|shaders|icon|stage> -DSOURCE_DIR=<checkout>
#         -DCORE_SOURCE_DIR=<ubiquitty-core checkout>
#         -DKIT_SOURCE_DIR=<ubiquitty-kit checkout>
#         -DBINARY_DIR=<build tree> -DIOS_MIN=<deployment target>
#         [-DPLATFORM=<iphoneos|iphonesimulator>] [-DPER_PLATFORM=ON]
#         [-DBUNDLE=<app bundle>] -P IOSPlatformStep.cmake
#
# PER_PLATFORM puts the outputs under <build tree>/<platform>/ rather than in
# the build tree itself. A tree that serves both SDKs needs it: one shared
# default.metallib would be whichever SDK built last, with a timestamp that
# says it is current.
#

foreach(_required STEP SOURCE_DIR CORE_SOURCE_DIR KIT_SOURCE_DIR BINARY_DIR IOS_MIN)
    if(NOT DEFINED ${_required} OR "${${_required}}" STREQUAL "")
        message(FATAL_ERROR "IOSPlatformStep.cmake needs -D${_required}=...")
    endif()
endforeach()

if(NOT DEFINED PLATFORM OR PLATFORM STREQUAL "")
    set(PLATFORM "$ENV{PLATFORM_NAME}")
endif()
# Refused rather than defaulted. A step that guessed "device" for an unset
# platform would produce a well-formed artefact for the wrong SDK, which is the
# failure this script exists to remove.
if(NOT PLATFORM STREQUAL "iphoneos" AND NOT PLATFORM STREQUAL "iphonesimulator")
    message(FATAL_ERROR
        "IOSPlatformStep.cmake: the platform is '${PLATFORM}', and this arm builds for "
        "iphoneos or iphonesimulator. Pass -DPLATFORM=..., or run under Xcode, which "
        "exports PLATFORM_NAME for the destination being built.")
endif()

if(PER_PLATFORM)
    set(_outputDirectory "${BINARY_DIR}/${PLATFORM}")
else()
    set(_outputDirectory "${BINARY_DIR}")
endif()
file(MAKE_DIRECTORY "${_outputDirectory}")

if(PLATFORM STREQUAL "iphonesimulator")
    set(_triple "arm64-apple-ios${IOS_MIN}-simulator")
    set(_metalVersionFlag "-mios-simulator-version-min=${IOS_MIN}")
else()
    set(_triple "arm64-apple-ios${IOS_MIN}")
    set(_metalVersionFlag "-miphoneos-version-min=${IOS_MIN}")
endif()

set(_iconDirectory "${_outputDirectory}/ios-app-icon")
# The scale is spelled through a variable because a file name with the scale
# suffix written out reads as a mail address to Scripts/check-personal-paths.py.
set(_iconScale "2x")
set(_iconOutputs
    "${_iconDirectory}/Assets.car"
    "${_iconDirectory}/Ubiquitty60x60@${_iconScale}.png"
    "${_iconDirectory}/Ubiquitty76x76@${_iconScale}~ipad.png")
set(_metalLibrary "${_outputDirectory}/default.metallib")

# Runs one tool and stops the build on a failure, with the tool named.
#
# - Parameter what: What the command was doing, for the failure line.
function(ubiquitty_ios_run what)
    execute_process(COMMAND ${ARGN} RESULT_VARIABLE _status)
    if(NOT _status EQUAL 0)
        message(FATAL_ERROR "IOSPlatformStep.cmake (${STEP}, ${PLATFORM}): ${what} failed (${_status})")
    endif()
endfunction()

if(STEP STREQUAL "ssh")
    # UbiquittySSH, cross-built for this SDK by SwiftPM's default build system.
    #
    # The triple carries the deployment target, and the build compiles every
    # module of the graph for it, the dependencies whose packages declare a
    # lower floor included. The SDK is named by its path.
    execute_process(COMMAND xcrun --sdk "${PLATFORM}" --show-sdk-path
        OUTPUT_VARIABLE _sdkPath OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _sdkStatus)
    if(NOT _sdkStatus EQUAL 0 OR _sdkPath STREQUAL "")
        message(FATAL_ERROR "IOSPlatformStep.cmake: xcrun could not name the ${PLATFORM} SDK")
    endif()
    # One scratch for both SDKs. The build keeps each platform's products and
    # intermediates in folders named Release-<platform>, so the two never meet,
    # and the package checkouts, the part that costs a network fetch, are made
    # once.
    set(_scratch "${BINARY_DIR}/swiftpm-ssh")

    # An environment of its own, holding only what the toolchain and the
    # package fetch read. This step runs inside an Xcode build, which exports
    # every build setting it has into the environment, and SwiftPM builds with
    # Xcode's build system: what it finds there would be read as this build's.
    # SDKROOT, for one, makes SwiftPM compile Package.swift against the iOS SDK
    # while targeting the host, which fails with "unable to load standard
    # library". Git's variables go the same way: the pre-push hook exports
    # GIT_DIR and GIT_WORK_TREE at the pushing worktree, and the package fetch
    # then resolves its clones against them — "no versions of 'swift-nio'
    # match" from a hook, clean from any interactive shell
    # (Scripts/fetch-quic-deps.sh unsets them for the same class).
    set(_environment "")
    foreach(_name HOME PATH TMPDIR USER LOGNAME LANG LC_ALL DEVELOPER_DIR TOOLCHAINS
            HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY http_proxy https_proxy no_proxy all_proxy)
        if(DEFINED ENV{${_name}})
            list(APPEND _environment "${_name}=$ENV{${_name}}")
        endif()
    endforeach()
    find_program(_swift swift REQUIRED)
    # The language mode is the package's own (Package.swift): SwiftPM's build
    # system warns that a mode set by a compiler flag may disagree with the code
    # it generates for each target.
    ubiquitty_ios_run("swift build"
        /usr/bin/env -i ${_environment}
        "${_swift}" build -c release
        --package-path "${SOURCE_DIR}/Source/Platform/Apple/SSH"
        --scratch-path "${_scratch}"
        --triple "${_triple}"
        --sdk "${_sdkPath}")

    set(PRODUCTS "${_scratch}/out/Products/Release-${PLATFORM}")
    set(MODULE_MAPS "${_scratch}/out/Intermediates.noindex/GeneratedModuleMaps-${PLATFORM}")
    set(CHECKOUTS "${_scratch}/checkouts")
    set(LIBRARY "UbiquittySSH")
    set(ARCHIVE "${_outputDirectory}/libUbiquittySSH.a")
    set(FLAGS "${_outputDirectory}/UbiquittySSH-swift-flags.txt")
    include("${CMAKE_CURRENT_LIST_DIR}/ArchiveSwiftPMObjects.cmake")

elseif(STEP STREQUAL "shaders")
    # The shaders the renderer loads, compiled for this SDK. Same source as the
    # macOS arm: a shader is not platform code, and a second copy would be a
    # second renderer by another route. It includes Core's Tek raster by its
    # path under Core's Source root.
    set(_air "${_outputDirectory}/UBShaders.air")
    ubiquitty_ios_run("metal"
        xcrun -sdk "${PLATFORM}" metal ${_metalVersionFlag}
        -I "${CORE_SOURCE_DIR}/Source"
        -c "${KIT_SOURCE_DIR}/Source/UbiquittyRenderKit/UBShaders.metal"
        -o "${_air}")
    ubiquitty_ios_run("metallib"
        xcrun -sdk "${PLATFORM}" metallib "${_air}" -o "${_metalLibrary}")

elseif(STEP STREQUAL "icon")
    # The app icon: the same Icon Composer document the macOS bundle compiles
    # (Scripts/build-macos.sh), compiled by actool for this SDK. Assets.car is
    # what iOS 26 draws; the two PNGs are the fallbacks actool writes beside it
    # and Info.plist.in's CFBundleIcons names, all at the bundle's root.
    file(MAKE_DIRECTORY "${_iconDirectory}")
    ubiquitty_ios_run("actool"
        xcrun actool --output-format human-readable-text
        --notices --warnings --errors --app-icon Ubiquitty
        --compile "${_iconDirectory}"
        --platform ${PLATFORM}
        --minimum-deployment-target ${IOS_MIN}
        --target-device iphone --target-device ipad
        --output-partial-info-plist "${_iconDirectory}/partial.plist"
        "${SOURCE_DIR}/Resources/Icon/Ubiquitty.icon")

elseif(STEP STREQUAL "stage")
    # Into the bundle after the link, from this SDK's directory. A bundle is
    # per SDK already — Xcode names it for the platform — so what is copied
    # into it has to be chosen by the same answer.
    if(NOT DEFINED BUNDLE OR BUNDLE STREQUAL "")
        message(FATAL_ERROR "IOSPlatformStep.cmake: the stage step needs -DBUNDLE=<app bundle>")
    endif()
    foreach(_staged IN LISTS _metalLibrary _iconOutputs)
        if(NOT EXISTS "${_staged}")
            message(FATAL_ERROR
                "IOSPlatformStep.cmake: ${_staged} was not built for ${PLATFORM}, "
                "so the bundle would ship without it")
        endif()
        get_filename_component(_name "${_staged}" NAME)
        execute_process(
            COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_staged}" "${BUNDLE}/${_name}"
            RESULT_VARIABLE _status)
        if(NOT _status EQUAL 0)
            message(FATAL_ERROR "IOSPlatformStep.cmake: could not copy ${_name} into ${BUNDLE}")
        endif()
    endforeach()

else()
    message(FATAL_ERROR "IOSPlatformStep.cmake: unknown step '${STEP}' (ssh, shaders, icon, stage)")
endif()
