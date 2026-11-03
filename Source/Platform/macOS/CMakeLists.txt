# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

include(${CMAKE_SOURCE_DIR}/Scripts/cmake/TypedPasteboard.cmake)
# Source/Platform/macOS/CMakeLists.txt
#
# AppKit + CoreText frontend. Compiles the portable Core subtree
# against the macOS PAL implementations under this directory. The
# binary launches, opens one NSWindow, feeds a small ANSI stream
# through the VT100 parser, and writes the diagnostic events the parser
# emits via PAL::diagWrite to stderr and the unified log.
#
# Sub-build entered from the top-level CMakeLists.txt when
# UBIQUITTY_FRONTEND=macOS.
#

cmake_minimum_required(VERSION 3.13)

find_library(COCOA_FRAMEWORK Cocoa REQUIRED)
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(METAL_FRAMEWORK Metal REQUIRED)
find_library(METALKIT_FRAMEWORK MetalKit REQUIRED)
find_library(QUARTZCORE_FRAMEWORK QuartzCore REQUIRED)
find_library(CORETEXT_FRAMEWORK CoreText REQUIRED)
find_library(CARBON_FRAMEWORK Carbon REQUIRED)
find_library(IMAGEIO_FRAMEWORK ImageIO REQUIRED)
find_library(USERNOTIFICATIONS_FRAMEWORK UserNotifications REQUIRED)
find_library(AUDIOTOOLBOX_FRAMEWORK AudioToolbox REQUIRED)

# Portable Core subtree linked into the macOS frontend — DERIVED from the
# canonical SSOT (Scripts/portable-core-sources.txt) via ubiquitty_core_subset,
# the same mechanism every other frontend uses (Host/Agent/Linux/Wscons). A new
# SSOT TU flows into the macOS app automatically unless named in the trim.
#
# These TUs have no platform-header dependencies; scalar types come
# from Base/Types.h. None pulls in a window-system header.
# BoxGlyphRaster.cpp was excluded here until the portable snapshot renderer
# started wrapping BoxDrawingRasterizer, which this app links for its own
# --snapshot mode. The Metal path still draws its box characters its own way;
# what needs the procedural raster is the portable renderer inside this binary.
ubiquitty_core_subset(UBIQUITTY_MACOS_CORE EXCLUDE
    # Not part of the macOS app link set:
    Source/Core/Protocol/Sync/QUICBootstrap.cpp
    # Compiled in the app's own source list (control-socket handoff), not here:
    # Workspace model TUs the macOS frontend does not link:
    Source/Core/Session/Surface.cpp
)

# Frontend extras compiled alongside the portable core — not SSOT members
# (the SSOT's charter is portable-core .cpp only; these are the App shell,
# the OS-seam root TUs, and a vendored .c):
set(UBIQUITTY_MACOS_CORE_EXTRAS
    Source/Core/Input/PasteNormalize.cpp
    Source/PAL/OutputQueue.cpp
    # Remote-control socket reuses the agent's JSON-RPC value/parser and the
    # shared ~/.ubiquitty control-directory path + perms helpers (no parallel stack).
    Source/Core/Codec/JSON.cpp
    Source/ThirdParty/yyjson/yyjson.c
)

set(UBIQUITTY_PORTABLE_CORE ${UBIQUITTY_MACOS_CORE} ${UBIQUITTY_MACOS_CORE_EXTRAS})

# macOS frontend implementation files.
set(UBIQUITTY_MACOS_SOURCES
    Source/Platform/POSIX/SessionHandoff.cpp
    # The bundled host installed where this Mac's host runs from, and started
    # to take over an older one (LocalHostInstall.h).
    Source/Platform/POSIX/LocalHostInstall.cpp
    # A remote window's sealed resume owner (RemoteResumeBridge.h).
    Source/Platform/macOS/RemoteResumeBridge.cpp
    Source/Platform/macOS/SessionClipboardClient.cpp
    Source/Platform/Apple/Clock.cpp
    Source/Platform/Apple/ImageDecode.cpp
    Source/Platform/macOS/Diag.cpp
    Source/Platform/POSIX/PTYStream.cpp
    Source/Platform/POSIX/SerialStream.cpp
    Source/Platform/POSIX/PTYFacts.cpp
    # The gated kitty file read: hardening rules that belong to no single arm,
    # kept where both compile them (Source/Platform/POSIX/GatedFileRead.h).
    Source/Platform/POSIX/GatedFileRead.cpp
    Source/Platform/macOS/Clipboard.cpp
    Source/Platform/macOS/Bell.cpp
    Source/Platform/macOS/DECPSSound.cpp
)

# In-process UI integration test harness (--ui-test). Drives the real
# window/pane/tmux UI from code; absent from release builds. Off by default;
# Scripts/run-ui-tests.sh configures with -DUBIQUITTY_UI_TESTS=ON. The harness and
# its scenarios are Swift (UITest/Swift); this adds the one C++ door they use.
option(UBIQUITTY_UI_TESTS "Build the in-process UI integration test scenarios" OFF)
if(UBIQUITTY_UI_TESTS)
    list(APPEND UBIQUITTY_MACOS_SOURCES
        # Hands a scenario's directory client the showcase host, a fixture
        # under Tests/ no Swift module names.
        Source/Platform/macOS/UITest/ShowcaseHostDoor.cpp
    )
endif()

# The C++ side of the Swift seams. Plain C++ (no ObjC); built with the
# portable-Core flags below so it shares the Settings ABI. The first is what the
# application delegate needs from C++ — the platform context, the ssh and mosh
# wrappers, the settings edits that walk C++ structures; the next two are the clipboard-read
# resolver and the Settings window's theme and blur facts; the last is the
# reverse direction, C++ calling the pasteboard mapping that lives in Swift
# (TypedPasteboard.swift, linked as the UbiquittyPasteboard module).
set(UBIQUITTY_INTEROP_CPP
    Source/Platform/macOS/App/ApplicationBridge.cpp
    Source/Platform/macOS/App/UBClipboardReadInterop.cpp
    Source/Platform/macOS/App/UBSettingsInterop.cpp
    Source/Platform/macOS/TypedPasteboard.cpp
)

# The Swift renderer, as its own module. What holds it apart is the export
# wall: UbiquittyKit imports it internally, so the Kit's public interface can
# name no renderer type and carries no C++ (see UbiquittyKit below), and a file
# in the wrong one of the two shared lists fails to compile instead of leaking
# the renderer into the consumer's API. The iOS arm compiles the same module
# from the same list (Scripts/cmake/AppleSharedSwift.cmake).
#
# Speed does not separate it. The module compiles with dynamic exclusivity
# checking off. Core imports the slot cache as a foreign reference type, so a
# probe is a method call through a reference the renderer only reads, and
# neither Swift arm's loop carries swift_beginAccess: Tools/seam-bench reads
# 2.72 ns a crossing with the checks and 2.78 without, against 2.84 for inline
# C++ and 3.37 for a virtual call. Whether the flag buys anything on the
# renderer's other per-frame paths is unmeasured.
#
# This is also the boundary that makes the renderer extractable: it reaches
# Core through the module maps and Metal/CoreText through the SDK, and
# nothing in it names the app.
# The Apple-shared layer, read from one list so this arm and the iOS one
# cannot drift into rendering through different code.
include(${CMAKE_SOURCE_DIR}/Scripts/cmake/AppleSharedSwift.cmake)
set(UBIQUITTY_APPLE_SHARED_KIT_ABS "")
foreach(_src IN LISTS UBIQUITTY_APPLE_SHARED_KIT_SOURCES)
    list(APPEND UBIQUITTY_APPLE_SHARED_KIT_ABS "${CMAKE_SOURCE_DIR}/${_src}")
endforeach()
# Plus this shell's own chrome, which is AppKit and belongs to macOS.
set(UBIQUITTY_RENDERKIT_SOURCES
    ${UBIQUITTY_APPLE_SHARED_RENDERKIT_SOURCES}
    Source/Platform/macOS/App/TerminalView/ProgressBar.swift
    Source/Platform/macOS/App/TerminalView/PasswordPromptBadge.swift
    Source/Platform/macOS/App/TerminalView/PasswordPromptRegistry.swift
    Source/Platform/macOS/App/TerminalView/ChromeAccessoryBar.swift
    Source/Platform/macOS/App/TerminalView/SecureKeyboardEntryLock.swift
    Source/Platform/macOS/App/TerminalView/ClipboardScopeIndicator.swift
    Source/Platform/macOS/App/TerminalView/HintAccessory.swift
    Source/Platform/macOS/App/TerminalView/SessionPresenceIndicator.swift
    Source/Platform/macOS/App/TerminalView/RemoteConnectionIndicator.swift
    Source/Platform/macOS/App/TerminalView/TitlebarTagChip.swift
    Source/Platform/macOS/App/TerminalView/BroadcastIndicator.swift
    Source/Platform/macOS/App/TerminalView/TmuxSessionBadge.swift
    Source/Platform/macOS/App/TerminalView/BuildIdentityBadge.swift
    Source/Platform/macOS/App/TerminalView/ProgressTintPalette.swift
    Source/Platform/macOS/App/TerminalView/WindowBlurBackdrop.swift
    Source/Platform/macOS/App/TerminalView/TerminalScroller.swift
    Source/Platform/macOS/App/TerminalView/PointerShapeCursor.swift
    Source/Platform/macOS/App/TerminalView/SelectionPasteboard.swift
    Source/Platform/macOS/App/TerminalView/WindowTabSelection.swift
    Source/Platform/macOS/App/TerminalView/SurfaceFocus.swift)

# The application's Swift: its entry point, delegate and menus, the windows'
# shell and the settings window. Compiled with C++ interop; see the Swift flags
# block.
set(UBIQUITTY_SWIFT_SOURCES
    Source/Platform/macOS/App/Application/ApplicationMain.swift
    Source/Platform/macOS/App/Application/AppDelegate.swift
    Source/Platform/macOS/App/Application/AppDelegate+MainMenu.swift
    Source/Platform/macOS/App/Application/AppDelegate+Settings.swift
    Source/Platform/macOS/App/Application/SessionLayout.swift
    Source/Platform/macOS/App/SecureInput.swift
    Source/Platform/macOS/App/LocaleEnvironment.swift
    Source/Platform/macOS/App/CLIInstaller.swift
    Source/Platform/macOS/App/Updater.swift
    Source/Platform/macOS/App/ScriptingBridge.swift
    Source/Platform/macOS/App/Windowing/ConnectWindowController.swift
    Source/Platform/macOS/App/Windowing/InspectorController.swift
    Source/Platform/macOS/App/Windowing/TerminalWindows.swift
    Source/Platform/macOS/App/Windowing/ConnectRecents.swift
    Source/Platform/macOS/App/Windowing/HostServers.swift
    Source/Platform/macOS/App/Windowing/HostHandoff.swift
    Source/Platform/macOS/App/Windowing/HostManagementWindow.swift
    Source/Platform/macOS/App/Windowing/HostDirectoryModel.swift
    Source/Platform/macOS/App/Windowing/HostDirectoryClients.swift
    # A host's outline drawn: shared with the iOS app, which lists the same
    # files, so both draw Core's rows through one row view.
    Source/Platform/Apple/HostOutline/HostOutlineStore.swift
    Source/Platform/Apple/HostOutline/HostOutlineRowView.swift
    Source/Platform/Apple/HostOutline/HostOutlineList.swift
    Source/Platform/macOS/App/Windowing/ConnectModel.swift
    Source/Platform/macOS/App/Windowing/ConnectView.swift
    Source/Platform/macOS/App/Windowing/ConnectLauncher.swift
    Source/Platform/macOS/App/Windowing/ConnectReattach.swift
    Source/Platform/macOS/App/FontRouting/FontInventory.swift
    Source/Platform/macOS/App/FontRouting/FontRoutePreview.swift
    Source/Platform/macOS/App/SettingsModel.swift
    Source/Platform/macOS/App/SettingsControls.swift
    Source/Platform/macOS/App/SettingsListScaffold.swift
    Source/Platform/macOS/App/SettingsCatalog.swift
    Source/Platform/macOS/App/SettingsValues.swift
    Source/Platform/macOS/App/SettingsReset.swift
    Source/Platform/macOS/App/SettingsView.swift
    Source/Platform/macOS/App/ThemesPane.swift
    Source/Platform/macOS/App/ThemePicker.swift
    Source/Platform/macOS/App/FontSettingsPreview.swift
    Source/Platform/macOS/App/BackgroundImageSettings.swift
    Source/Platform/macOS/App/ViewCompatibility.swift
    Source/Platform/macOS/App/FontFeatureCatalog.swift
    Source/Platform/macOS/App/FontWeightCatalog.swift
    Source/Platform/macOS/App/FontFeaturesPane.swift
    Source/Platform/macOS/App/FontRoutingPane.swift
    Source/Platform/macOS/App/TektronixPane.swift
    Source/Platform/macOS/App/KeysPane.swift
    Source/Platform/macOS/App/ProfilesPane.swift
    Source/Platform/macOS/App/MacrosPane.swift
    Source/Platform/macOS/App/MacroStore.swift
    Source/Platform/macOS/App/TagPalette.swift
    Source/Platform/macOS/App/TagsPane.swift
    Source/Platform/macOS/App/PlatformPane.swift
    Source/Platform/macOS/App/AgentsPane.swift
    Source/Platform/macOS/App/SettingsWindowController.swift
    Source/Platform/macOS/App/ClipboardStore.swift
    Source/Platform/macOS/App/SessionClipboard.swift
    Source/Platform/macOS/App/ClipboardReadPrompt.swift
    Source/Platform/macOS/App/PastePushBridge.swift
    Source/Platform/macOS/App/PastePushPanel.swift
    Source/Platform/macOS/App/Beam/BeamCommands.swift
    Source/Platform/macOS/App/Beam/BeamModel.swift
    Source/Platform/macOS/App/Beam/PaletteBridge.swift
    Source/Platform/macOS/App/Beam/BeamTerminalProviders.swift
    Source/Platform/macOS/App/Beam/KeysCatalog.swift
    Source/Platform/macOS/App/CxxInterop.swift
    Source/Platform/macOS/App/Beam/BeamView.swift
    Source/Platform/macOS/App/CheatSheet/CheatSheetController.swift
    Source/Platform/macOS/App/CheatSheet/CheatSheetSources.swift
    Source/Platform/macOS/App/CheatSheet/CheatSheetView.swift
    Source/Platform/macOS/App/Beam/BeamController.swift
    Source/Platform/macOS/App/Beam/BeamWindowBridge.swift
    Source/Platform/macOS/App/Beam/BeamRemoteCommands.swift
    Source/Platform/macOS/App/Beam/BeamAgentCommands.swift
    Source/Platform/macOS/App/BeamTmuxContextCommands.swift
    Source/Platform/macOS/App/AboutView.swift
    Source/Platform/macOS/App/AboutWindowController.swift
    Source/Platform/macOS/App/PasteBuffersView.swift
    Source/Platform/macOS/App/PasteBuffersWindowController.swift
    Source/Platform/macOS/App/SyncDebugView.swift
    Source/Platform/macOS/App/SyncDebugWindowController.swift
    Source/Platform/macOS/App/SyncTraceSource.swift
)

# Swift UI-test scenarios: compiled only into the harness build, and kept in
# the UI-test tree rather than beside the product's Swift, so test code never
# ships. New scenarios are written here.
if(UBIQUITTY_UI_TESTS)
    list(APPEND UBIQUITTY_SWIFT_SOURCES
        Source/Platform/macOS/UITest/Swift/InspectorScenarios.swift
        Source/Platform/macOS/UITest/Swift/CustomTitleScenarios.swift
        Source/Platform/macOS/UITest/Swift/SessionPlumbingScenarios.swift
        Source/Platform/macOS/UITest/Swift/FontZoomScenarios.swift
        Source/Platform/macOS/UITest/Swift/ControlSocketScenarios.swift
        Source/Platform/macOS/UITest/Swift/ImageFrameScenarios.swift
        Source/Platform/macOS/UITest/Swift/PixelReportScenarios.swift
        Source/Platform/macOS/UITest/Swift/RenderedFrameScenarios.swift
        Source/Platform/macOS/UITest/Swift/TitleCompositionScenarios.swift
        Source/Platform/macOS/UITest/Swift/TabTitleFittingScenarios.swift
        Source/Platform/macOS/UITest/Swift/LocatorScenarios.swift
        Source/Platform/macOS/UITest/Swift/ProportionalRunScenarios.swift
        Source/Platform/macOS/UITest/Swift/FullscreenContentScenarios.swift
        Source/Platform/macOS/UITest/Swift/ColumnModeScenarios.swift
        Source/Platform/macOS/UITest/Swift/WindowOperationStormScenarios.swift
        Source/Platform/macOS/UITest/Swift/ResizeParityScenarios.swift
        Source/Platform/macOS/UITest/Swift/WindowFollowsFontScenarios.swift
        Source/Platform/macOS/UITest/Swift/RenderPreferencesScenarios.swift
        Source/Platform/macOS/UITest/Swift/PerfDiagnosticsScenarios.swift
        Source/Platform/macOS/UITest/Swift/FullscreenBracketScenarios.swift
        Source/Platform/macOS/UITest/Swift/PaletteOpacityScenarios.swift
        Source/Platform/macOS/UITest/Swift/TranslucencyScenarios.swift
        Source/Platform/macOS/UITest/Swift/BackgroundImageSettingsScenarios.swift
        Source/Platform/macOS/UITest/Swift/BoxGlyphRouteScenarios.swift
        Source/Platform/macOS/UITest/Swift/LocaleEnvironmentScenarios.swift
        Source/Platform/macOS/UITest/Swift/PastePushScenarios.swift
        Source/Platform/macOS/UITest/Swift/SymbolFallbackScenarios.swift
        Source/Platform/macOS/UITest/Swift/FontRoutingScenarios.swift
        Source/Platform/macOS/UITest/Swift/ShellIntegrationScenarios.swift
        Source/Platform/macOS/UITest/Swift/TitlebarTestSupport.swift
        Source/Platform/macOS/UITest/Swift/FileDropTestSupport.swift
        Source/Platform/macOS/UITest/Swift/ProxyIconRevealScenarios.swift
        Source/Platform/macOS/UITest/Swift/PaneChromeScenarios.swift
    Source/Platform/macOS/UITest/Swift/TitleDimensionsScenarios.swift
        Source/Platform/macOS/UITest/Swift/TagEditorScenarios.swift
        Source/Platform/macOS/UITest/Swift/TabStatusHintOffScenarios.swift
        Source/Platform/macOS/UITest/Swift/TagDotScenarios.swift
        Source/Platform/macOS/UITest/Swift/SurfaceDrawableScenarios.swift
        Source/Platform/macOS/UITest/Swift/ChromeThemeScenarios.swift
        Source/Platform/macOS/UITest/Swift/ChromeBadgeScenarios.swift
        Source/Platform/macOS/UITest/Swift/WindowGroundScenarios.swift
        Source/Platform/macOS/UITest/Swift/BroadcastInputScenarios.swift
        Source/Platform/macOS/UITest/Swift/ProgressChromeScenarios.swift
        Source/Platform/macOS/UITest/Swift/BellScenarios.swift
        Source/Platform/macOS/UITest/Swift/TriggerScenarios.swift
        Source/Platform/macOS/UITest/Swift/DropDownScenarios.swift
        Source/Platform/macOS/UITest/Swift/SessionClipboardScenarios.swift
        Source/Platform/macOS/UITest/Swift/WindowShapeScenarios.swift
        Source/Platform/macOS/UITest/Swift/SettingsWindowScenarios.swift
        Source/Platform/macOS/UITest/Swift/UpdaterScenarios.swift
        Source/Platform/macOS/UITest/Swift/ClearCommandScenarios.swift
        Source/Platform/macOS/UITest/Swift/ScrollerChromeScenarios.swift
        Source/Platform/macOS/UITest/Swift/PointerBehaviourScenarios.swift
        Source/Platform/macOS/UITest/Swift/SelectionOutputFollowScenarios.swift
        Source/Platform/macOS/UITest/Swift/RichTextScenarios.swift
        Source/Platform/macOS/UITest/Swift/LinkScenarios.swift
        Source/Platform/macOS/UITest/Swift/RemoteFileScenarios.swift
        Source/Platform/macOS/UITest/Swift/WindowPlacementScenarios.swift
        Source/Platform/macOS/UITest/Swift/FramePacingScenarios.swift
        Source/Platform/macOS/UITest/Swift/KeyBindingScenarios.swift
        Source/Platform/macOS/UITest/Swift/BeamSummonScenarios.swift
        Source/Platform/macOS/UITest/Swift/EditMenuScenarios.swift
        Source/Platform/macOS/UITest/Swift/FindBarScenarios.swift
        Source/Platform/macOS/UITest/Swift/KeyRoutingScenarios.swift
        Source/Platform/macOS/UITest/Swift/LayoutChordScenarios.swift
        Source/Platform/macOS/UITest/Swift/HostDirectoryScenarios.swift
        Source/Platform/macOS/UITest/Swift/ConnectWindowScenarios.swift
        Source/Platform/macOS/UITest/Swift/ConnectOutlineScenarios.swift
        Source/Platform/macOS/UITest/Swift/NativeTestContext.swift
        Source/Platform/macOS/UITest/Swift/UITestRunner.swift
        Source/Platform/macOS/UITest/Swift/RemoteWorkspaceScenarios.swift
        Source/Platform/macOS/UITest/Swift/HostedTabScenarios.swift
        Source/Platform/macOS/UITest/Swift/RemoteClearScenarios.swift
        Source/Platform/macOS/UITest/Swift/RemoteGroundScenarios.swift
        Source/Platform/macOS/UITest/Swift/RemoteViewScenarios.swift
        Source/Platform/macOS/UITest/Swift/RemoteLifecycleScenarios.swift
        Source/Platform/macOS/UITest/Swift/HostChipScenarios.swift
        Source/Platform/macOS/UITest/Swift/HostLabelScenarios.swift
        Source/Platform/macOS/UITest/Swift/SessionExitScenarios.swift
        Source/Platform/macOS/UITest/Swift/ShareSessionScenarios.swift
        Source/Platform/macOS/UITest/Swift/CursorPresentationScenarios.swift
        Source/Platform/macOS/UITest/Swift/FocusScenarios.swift
        Source/Platform/macOS/UITest/Swift/ConsentPromptScenarios.swift
        Source/Platform/macOS/UITest/Swift/WelcomeActionScenarios.swift
        Source/Platform/macOS/UITest/Swift/MacroStoreScenarios.swift
        Source/Platform/macOS/UITest/Swift/TmuxHostingScenarios.swift
        Source/Platform/macOS/UITest/Swift/MenuRoutingScenarios.swift
        Source/Platform/macOS/UITest/Swift/WindowOpScenarios.swift
        Source/Platform/macOS/UITest/Swift/DisplayPowerScenarios.swift
        Source/Platform/macOS/UITest/Swift/ScriptingScenarios.swift
        Source/Platform/macOS/UITest/Swift/SessionLogScenarios.swift
        Source/Platform/macOS/UITest/Swift/SessionLayoutScenarios.swift
        Source/Platform/macOS/UITest/Swift/RemoteResumeScenarios.swift
        Source/Platform/macOS/UITest/Swift/SessionLayoutStoreScenarios.swift
        Source/Platform/macOS/UITest/Swift/TabSurvivorScenarios.swift
        Source/Platform/macOS/UITest/Swift/TabAccessoryTransitionScenarios.swift
        Source/Platform/macOS/UITest/Swift/TabAccessorySelectionScenarios.swift
        Source/Platform/macOS/UITest/Swift/OcclusionScenarios.swift
        Source/Platform/macOS/UITest/Swift/QuietChromeScenarios.swift
        Source/Platform/macOS/UITest/Swift/TerminalBehaviourScenarios.swift
        Source/Platform/macOS/UITest/Swift/TextInputScenarios.swift
        Source/Platform/macOS/UITest/Swift/ProfileLaunchScenarios.swift
        Source/Platform/macOS/UITest/Swift/WindowContainment.swift
        Source/Platform/macOS/UITest/Swift/PasteboardIsolation.swift
    )
endif()

# Absolute paths so add_executable resolves them whether or not we
# were entered via add_subdirectory.
set(UBIQUITTY_ALL_SOURCES_ABS "")
foreach(_src IN LISTS UBIQUITTY_MACOS_SOURCES UBIQUITTY_PORTABLE_CORE
                      UBIQUITTY_INTEROP_CPP UBIQUITTY_SWIFT_SOURCES)
    list(APPEND UBIQUITTY_ALL_SOURCES_ABS "${CMAKE_SOURCE_DIR}/${_src}")
endforeach()

# Absolute Swift source paths, reused by the interop-header custom command.
set(UBIQUITTY_SWIFT_SOURCES_ABS "")
foreach(_src IN LISTS UBIQUITTY_SWIFT_SOURCES)
    list(APPEND UBIQUITTY_SWIFT_SOURCES_ABS "${CMAKE_SOURCE_DIR}/${_src}")
endforeach()

add_executable(Ubiquitty MACOSX_BUNDLE ${UBIQUITTY_ALL_SOURCES_ABS})
ubiquitty_bundle_license_notices(Ubiquitty)

set(UBIQUITTY_C_FAMILY_COMPILE
    "$<OR:$<COMPILE_LANGUAGE:C>,$<COMPILE_LANGUAGE:CXX>>")
function(ub_c_family_compile_definitions target)
    foreach(definition IN LISTS ARGN)
        target_compile_definitions(${target} PRIVATE
            "$<${UBIQUITTY_C_FAMILY_COMPILE}:${definition}>")
    endforeach()
endfunction()

# ThirdParty exemption, by construction: compile a vendored source
# into `target` with the standard vendored-code policy applied to that one TU —
# exceptions + RTTI restored (vendored C++ assumes the language defaults our
# targets otherwise disable) and -Werror defeated (a newer toolchain's opinion of
# code we don't own must not fail our build; warnings stay visible, only -Werror
# is dropped). Use for anything landing under Source/ThirdParty/ so the exemption
# holds by construction instead of a hand-copied per-file property block.
function(ub_add_thirdparty_source target source)
    target_sources(${target} PRIVATE "${source}")
    set_source_files_properties("${source}" PROPERTIES
        COMPILE_OPTIONS "-fexceptions;-frtti;-Wno-error;-w")
endfunction()

# Built-in themes ship as TOML (Source/Core/Themes/builtin-themes.toml) embedded via
# this generated TU — one source of truth, parsed at startup like user themes.
# Mirrors the Unifont codegen and Scripts/run-tests.sh's generation step.
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
target_sources(Ubiquitty PRIVATE ${BUILTIN_THEMES_GEN})

set(UBIQUITTY_APP_NAME "Ubiquitty" CACHE STRING "macOS app bundle/display name")
if(UBIQUITTY_APP_NAME STREQUAL "")
    message(FATAL_ERROR "UBIQUITTY_APP_NAME must not be empty")
endif()
if(UBIQUITTY_APP_NAME MATCHES "[/:]")
    message(FATAL_ERROR "UBIQUITTY_APP_NAME must not contain '/' or ':'")
endif()

# Mark the harness build in the C-family compile, as the Swift compile is
# marked below; ApplicationMain.swift gates the --ui-test entry on it.
#
# The harness build carries the UBIQUITTY_PERF_DIAG diagnostics a Debug build
# carries — the paint heatmap's capture pass, the drawing-debug panel — so a
# scenario can turn them on and read what they report. A shipping build still
# compiles them out: the value stands only where the harness is compiled in.
if(UBIQUITTY_UI_TESTS)
    ub_c_family_compile_definitions(Ubiquitty UBIQUITTY_UI_TESTS=1 UBIQUITTY_PERF_DIAG=1)
endif()

# Behind-window blur (private CGS window-server API; not App Store safe).
# Off by default. Plain background translucency (background_opacity) is
# always compiled in. See Source/Platform/macOS/UBBackgroundBlur.h.
option(UBIQUITTY_BACKGROUND_BLUR "Enable the behind-window blur (private CGS API)" OFF)
if(UBIQUITTY_BACKGROUND_BLUR)
    ub_c_family_compile_definitions(Ubiquitty UB_ENABLE_BACKGROUND_BLUR=1)
endif()

# The title row's build badge: the version, the build identity in parentheses,
# and the branch for a build off main — "0.2.0.3 (1a2b3c4d, modified) [lane]".
# main and a detached HEAD stay bare. It is written into the bundle's Info.plist
# (UBBuildIdentity) when the build is configured, so a new commit rewrites the
# plist and compiles nothing for it. The About panel reads the version and the
# identity from Core, which one translation unit carries
# (Scripts/cmake/BuildVersion.cmake).
set(UBIQUITTY_BUILD_BADGE "${UBIQUITTY_VERSION} (${UBIQUITTY_BUILD_IDENTITY})")
execute_process(
    COMMAND git -C "${CMAKE_SOURCE_DIR}" rev-parse --abbrev-ref HEAD
    OUTPUT_VARIABLE UBIQUITTY_BUILD_BRANCH
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
if(UBIQUITTY_BUILD_BRANCH AND NOT UBIQUITTY_BUILD_BRANCH STREQUAL "main"
        AND NOT UBIQUITTY_BUILD_BRANCH STREQUAL "HEAD")
    set(UBIQUITTY_BUILD_BADGE "${UBIQUITTY_BUILD_BADGE} [${UBIQUITTY_BUILD_BRANCH}]")
endif()
# The badge as the plist carries it: a branch name may hold the characters XML
# reserves, and one left unescaped would leave the bundle an unreadable plist.
set(UBIQUITTY_BUILD_BADGE_PLIST "${UBIQUITTY_BUILD_BADGE}")
string(REPLACE "&" "&amp;" UBIQUITTY_BUILD_BADGE_PLIST "${UBIQUITTY_BUILD_BADGE_PLIST}")
string(REPLACE "<" "&lt;" UBIQUITTY_BUILD_BADGE_PLIST "${UBIQUITTY_BUILD_BADGE_PLIST}")
string(REPLACE ">" "&gt;" UBIQUITTY_BUILD_BADGE_PLIST "${UBIQUITTY_BUILD_BADGE_PLIST}")

# LSMinimumSystemVersion is the `app` floor, the value the Swift frontend is
# compiled for: the first decides which machines install the app, the second
# which machines its code can run on. Declaring a lower one ships an app that
# installs and then fails to launch, and no build step compares them, so both
# come from UBIQUITTY_MACOS_APP_MIN.
configure_file(
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/Info.plist.in"
    "${CMAKE_BINARY_DIR}/Info.plist"
    @ONLY)

# Which application a build is to the system. User defaults, saved window
# state, notification routing and LaunchServices all key on the bundle
# identifier, and a notification click goes to whichever registered bundle
# LaunchServices resolves the identifier to, not to the process that posted
# it. So only the build that is installed or shipped claims the release
# identifier: every development build under it is one more copy a click can
# launch instead of focusing the running app. Scripts/build-macos.sh --release
# and --release-signing select `release`; every other build is `development`,
# and the distribution scripts refuse a bundle that is not `release`.
#
# The UI-test build is a third application: under the installed app's
# identifier a test run reads the frames the reader last left and writes its
# own back into their preferences. Scripts/run-ui-tests.sh clears its domain
# before every run, which makes a scenario's verdict a fact about the commit
# rather than about history.
set(UBIQUITTY_BUNDLE_IDENTITY "development" CACHE STRING
    "Which application the bundle is to the system: release (installed or shipped) or development")
set_property(CACHE UBIQUITTY_BUNDLE_IDENTITY PROPERTY STRINGS release development)
if(UBIQUITTY_UI_TESTS)
    set(UBIQUITTY_BUNDLE_IDENTIFIER "org.ubiquitty.Ubiquitty.uitest")
elseif(UBIQUITTY_BUNDLE_IDENTITY STREQUAL "release")
    set(UBIQUITTY_BUNDLE_IDENTIFIER "org.ubiquitty.Ubiquitty")
elseif(UBIQUITTY_BUNDLE_IDENTITY STREQUAL "development")
    set(UBIQUITTY_BUNDLE_IDENTIFIER "org.ubiquitty.Ubiquitty.dev")
else()
    message(FATAL_ERROR
        "UBIQUITTY_BUNDLE_IDENTITY is '${UBIQUITTY_BUNDLE_IDENTITY}'; it must be release or development")
endif()
message(STATUS "Bundle identifier: ${UBIQUITTY_BUNDLE_IDENTIFIER}")
# Xcode compares the Info.plist identifier with its own build setting and
# warns when the setting is empty.
set_target_properties(Ubiquitty PROPERTIES
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${UBIQUITTY_BUNDLE_IDENTIFIER}")

set_target_properties(Ubiquitty PROPERTIES
    OUTPUT_NAME "${UBIQUITTY_APP_NAME}"
    MACOSX_BUNDLE_INFO_PLIST
        "${CMAKE_BINARY_DIR}/Info.plist"
    MACOSX_BUNDLE_BUNDLE_NAME           "${UBIQUITTY_APP_NAME}"
    MACOSX_BUNDLE_GUI_IDENTIFIER        "${UBIQUITTY_BUNDLE_IDENTIFIER}"
    MACOSX_BUNDLE_BUNDLE_VERSION        "${UBIQUITTY_BUNDLE_VERSION}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING  "${UBIQUITTY_VERSION_NAMED}"
)

target_include_directories(Ubiquitty PRIVATE
    "${CMAKE_SOURCE_DIR}/Source"
    "${CMAKE_SOURCE_DIR}/Tests" # Performance/Profiler.h — shared distribution harness for --profile-render
)

# simdutf — SIMD UTF-8 decode for the ingest hot path (utf8DecodeRun).
# Vendored amalgamation (Source/ThirdParty/simdutf, v9.0.0) compiled into the
# app: self-contained + offline, no brew/system dependency. The amalgamation
# manages its own runtime arch dispatch (NEON/AVX/scalar), so it needs the
# exceptions/RTTI + -Werror exemption — applied via ub_add_thirdparty_source so
# the ThirdParty policy holds by construction, not a hand-copied property block.
set(SIMDUTF_DIR "${CMAKE_SOURCE_DIR}/Source/ThirdParty/simdutf")
ub_add_thirdparty_source(Ubiquitty "${SIMDUTF_DIR}/simdutf.cpp")
target_include_directories(Ubiquitty SYSTEM PRIVATE "${SIMDUTF_DIR}")
message(STATUS "simdutf: vendored ${SIMDUTF_DIR}")

# RE2 — the linear-time regex engine behind Core/ScrollSearch (Cmd-F search).
# Vendored pre-Abseil release (Source/ThirdParty/re2, 2023-03-01): 20 re2/ TUs
# plus the two util/ TUs the library needs, each through the ThirdParty
# exemption. The include root is the ThirdParty dir so re2's own
# `#include "re2/..."` and `#include "util/..."` paths resolve.
set(RE2_DIR "${CMAKE_SOURCE_DIR}/Source/ThirdParty/re2")
file(GLOB RE2_SOURCES "${RE2_DIR}/re2/*.cc")
list(APPEND RE2_SOURCES "${RE2_DIR}/util/rune.cc" "${RE2_DIR}/util/strutil.cc")
foreach(re2_source ${RE2_SOURCES})
    ub_add_thirdparty_source(Ubiquitty "${re2_source}")
endforeach()
target_include_directories(Ubiquitty SYSTEM PRIVATE "${RE2_DIR}")
message(STATUS "re2: vendored ${RE2_DIR} (ScrollSearch regex engine)")

target_compile_features(Ubiquitty PRIVATE cxx_std_23)

# Portable Core TUs build with -std=c++23 -fno-exceptions -fno-rtti
# (the WebKit-style strict ABI the host + agent targets also use), so
# the same source compiles without a divergent ABI. ObjC++ TUs need
# exceptions + RTTI for the Cocoa runtime, so we apply the strict flags
# per-file.
set(UBIQUITTY_PORTABLE_CORE_ABS "")
foreach(_src IN LISTS UBIQUITTY_PORTABLE_CORE)
    list(APPEND UBIQUITTY_PORTABLE_CORE_ABS "${CMAKE_SOURCE_DIR}/${_src}")
endforeach()
set_source_files_properties(${UBIQUITTY_PORTABLE_CORE_ABS} PROPERTIES
    COMPILE_FLAGS "-std=c++23 -fno-exceptions -fno-rtti")

# yyjson is a C TU (the one C source in the core list); the C++ flag block
# above must not stamp it. Set last: set_source_files_properties replaces,
# so this assignment wins. ThirdParty policy: warnings suppressed (-w) and
# -Werror defeated, matching re2/simdutf.
set_source_files_properties("${CMAKE_SOURCE_DIR}/Source/ThirdParty/yyjson/yyjson.c"
    PROPERTIES COMPILE_FLAGS "-std=c99 -Wno-error -w")

# The Swift read-bridge calls into the same Settings, and the pasteboard seam
# passes Core's own clipboard types; build them with the matching ABI flags so
# they share the no-exceptions/no-rtti world.
set_source_files_properties(
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/UBClipboardReadInterop.cpp"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/UBSettingsInterop.cpp"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/TypedPasteboard.cpp"
    PROPERTIES COMPILE_FLAGS "-std=c++23 -fno-exceptions -fno-rtti")

# ----------------------------------------------------------------------
# Is Sparkle compiled into this build? (Docs/auto-update.md.)
#
# Mirrors the QUIC opt-in: Scripts/fetch-sparkle.sh drops a pinned, prebuilt
# Sparkle.framework under UBIQUITTY_SPARKLE_PREFIX, by default the sparkle
# directory of this checkout's build root (Scripts/build_root.py), which is
# where the script writes when it is given no prefix. A default anywhere else
# makes `fetch-sparkle.sh` then `build-macos.sh` build an app with no updater and
# say so only in a configure status line. A cache still holding the in-tree
# default is moved with it, as the QUIC prefix is. The answer is settled here,
# ahead of the Swift flags, because it decides the framework search path the
# Swift compile and its header-emit pass both need: App/Updater.swift asks
# `canImport(Sparkle)`, so the search path is itself the compile-time switch.
# The link and the embed follow further down.
# ----------------------------------------------------------------------
option(UBIQUITTY_SPARKLE "Bundle Sparkle.framework for in-app auto-update" ON)
if(UBIQUITTY_SPARKLE_PREFIX STREQUAL "${CMAKE_SOURCE_DIR}/build/sparkle")
    unset(UBIQUITTY_SPARKLE_PREFIX CACHE)
endif()
set(UBIQUITTY_SPARKLE_PREFIX "${_ubiquitty_build_root}/sparkle" CACHE PATH
    "Prefix holding Sparkle.framework (populated by Scripts/fetch-sparkle.sh)")
set(_sparkle_fw "${UBIQUITTY_SPARKLE_PREFIX}/Sparkle.framework")
set(UBIQUITTY_SPARKLE_FOUND OFF)
if(UBIQUITTY_SPARKLE AND EXISTS "${_sparkle_fw}")
    set(UBIQUITTY_SPARKLE_FOUND ON)
endif()

# ----------------------------------------------------------------------
# Swift + C++ interop.
#
# The application is Swift; it reaches Core through C++ interop. Two bridges
# are wired here:
#
#   Swift -> C++ : -cxx-interoperability-mode=default plus -I to the
#                  Swift dir, where module.modulemap exposes this shell's own
#                  bridge headers as the `UbiquittyAppBridge` module.
#   C     -> Swift: -import-objc-header on the bridging header, for the
#                  Carbon secure-input calls and the harness's showcase door.
# ----------------------------------------------------------------------
set(UBIQUITTY_SWIFT_DIR "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App")

set_target_properties(Ubiquitty PROPERTIES
    Swift_MODULE_NAME "Ubiquitty")

# Shared Swift frontend flags (interop mode, include paths, the ObjC ->
# Swift bridging header). Reused by both the in-target Swift compile and
# the header-emit pass below so they see an identical module.
# Each include is a single -I<path> token (no space) so the SHELL:
# space-join below keeps one path bound to each flag; the bridging header
# is passed as its own -import-objc-header <path> pair.
# Whole-module, because Swift optimises a file at a time otherwise and no call
# inlines across a file boundary — Tools/seam-bench records that source
# annotations (@inline(__always), final) are no-ops without it, so a hot
# function called from another file stays outlined whatever it is marked.
#
# Dynamic exclusivity stays ON here, where it is a safety property and no
# per-frame seam runs. -wmo compiles a module as a unit, so the flag cannot be
# scoped to a file; the render kit below turns it off for its whole module, and
# seam-bench measures no price for the checks at the slot-cache seam.
# Whole-module is set as the target property below rather than spelled here,
# and the difference is not cosmetic. As a raw flag, CMake still declares one
# object per source while the compiler writes them all in one invocation with
# timestamps spread across it — so the earliest object is older than the newest
# source, ninja calls the archive dirty on a tree where nothing moved, and every
# build relinks the module, the executable, the metallib and the helpers. The
# property tells CMake to expect one object, which is what makes a no-op build a
# no-op. The literal flag stays on the header-emit passes below, which invoke
# swiftc directly and are not CMake targets.
# Swift modules and header-emission passes share the application's API floor.
# An omitted target inherits the build machine's OS and can produce modules
# that the application cannot import.
set(UBIQUITTY_SWIFT_FLAGS
    -target "${CMAKE_SYSTEM_PROCESSOR}-apple-macos${UBIQUITTY_MACOS_APP_MIN}"
    -package-name ubiquitty
    -cxx-interoperability-mode=default
    # The clang importer must compile the interop C++ modules at the same C++23
    # standard as the Core build — the modulemap'd terminal-model headers reach
    # Terminal.h → Encodings.h, which uses std::span (C++20). The importer's default
    # standard is pre-C++20, so raise it to match Core or the module won't build.
    -Xcc -std=c++23
    "-I${UBIQUITTY_SWIFT_DIR}"
    "-I${CMAKE_SOURCE_DIR}/Source"
    # The shared Apple map ahead of this shell's own, because a map is searched
    # in include order and the shared one owns Core's headers. Behind, this
    # shell's map is reached first, parses a Core header the shared one owns,
    # and defines its types a second time — which surfaces as a redefinition
    # inside Core rather than as anything about module maps.
    "-I${CMAKE_SOURCE_DIR}/Source/Platform/Apple"
    "-I${CMAKE_SOURCE_DIR}/Source/Platform/macOS"
    # Where the bridging header's precompiled form lands.
    #
    # swiftc precompiles -import-objc-header into a temporary directory and
    # records that path in every object's debug info. The directory is reaped
    # when the compile ends, so dsymutil later reports
    #
    #   warning: /var/folders/.../TemporaryDirectory.XXXX/Ubiquitty-Bridging-Header.pch:
    #            No such file or directory
    #
    # on every build -- a warning nobody can act on, about a file that was
    # correct when it was written. Naming a directory under the build tree makes
    # the recorded path outlive the compile, and shares one PCH between the
    # in-target compile and the header-emit pass instead of building it twice.
    "-pch-output-dir" "${CMAKE_CURRENT_BINARY_DIR}/swift-pch"
)
# Inline C++ factories imported by Swift must see the same transport feature
# as the linked C++ objects, including every generated-header emission pass.
if(UBIQUITTY_QUIC)
    list(APPEND UBIQUITTY_SWIFT_FLAGS -Xcc -DUBIQUITTY_QUIC=1
        "-I${UBIQUITTY_QUIC_PREFIX}/include")
endif()

option(UBIQUITTY_HARFBUZZ_PROBE "Build the experimental uniform-face shaping comparison" OFF)
if(UBIQUITTY_HARFBUZZ_PROBE)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(HARFBUZZ_PROBE REQUIRED IMPORTED_TARGET harfbuzz>=14.0)
    find_path(HARFBUZZ_PROBE_HEADERS hb.h HINTS ${HARFBUZZ_PROBE_INCLUDE_DIRS} REQUIRED)
    set(HARFBUZZ_PROBE_MODULE "${CMAKE_CURRENT_BINARY_DIR}/HarfBuzzProbe")
    file(MAKE_DIRECTORY "${HARFBUZZ_PROBE_MODULE}")
    file(WRITE "${HARFBUZZ_PROBE_MODULE}/module.modulemap"
        "module HarfBuzzProbe [system] {\n header \"${HARFBUZZ_PROBE_HEADERS}/hb.h\"\n header \"${HARFBUZZ_PROBE_HEADERS}/hb-ot.h\"\n header \"${HARFBUZZ_PROBE_HEADERS}/hb-coretext.h\"\n export *\n}\n")
    list(APPEND UBIQUITTY_SWIFT_FLAGS "-I${HARFBUZZ_PROBE_MODULE}" "-I${HARFBUZZ_PROBE_HEADERS}")
    target_link_libraries(Ubiquitty PRIVATE PkgConfig::HARFBUZZ_PROBE)
endif()

# What the header-emit swiftc passes add to UBIQUITTY_SWIFT_FLAGS. They run
# swiftc by hand, so neither the language mode CMake gives a Swift target (the
# Xcode generator carries it as a build setting instead) nor the directory-wide
# -warnings-as-errors reaches them. Both are stated here once, so a diagnostic
# that exists in a target's compile exists in its header pass and fails the same
# build: the Swift 6 mode, and -warnings-as-errors under UBIQUITTY_WERROR.
set(UBIQUITTY_SWIFT_HEADER_PASS_FLAGS -swift-version 6)
if(UBIQUITTY_WERROR)
    list(APPEND UBIQUITTY_SWIFT_HEADER_PASS_FLAGS -warnings-as-errors)
endif()

# Active-compilation conditions for the header-emit swiftc pass (separate from
# the in-target compile, so they must be propagated explicitly).
set(UBIQUITTY_SWIFT_EXTRA_FLAGS "")
if(UBIQUITTY_UI_TESTS)
    list(APPEND UBIQUITTY_SWIFT_EXTRA_FLAGS
        "-DUBIQUITTY_UI_TESTS" "-Xcc" "-DUBIQUITTY_UI_TESTS=1")
endif()
# The window-server blur radius is a Swift call now (WindowBlurBackdrop), so
# the gate reaches Swift as an active-compilation condition too.
if(UBIQUITTY_BACKGROUND_BLUR)
    list(APPEND UBIQUITTY_SWIFT_EXTRA_FLAGS "-DUBIQUITTY_BACKGROUND_BLUR")
endif()
# Sparkle reaches Swift as a search path rather than a condition: Updater.swift
# asks `canImport(Sparkle)`, which is true exactly when the module is findable.
if(UBIQUITTY_SPARKLE_FOUND)
    list(APPEND UBIQUITTY_SWIFT_EXTRA_FLAGS "-F" "${UBIQUITTY_SPARKLE_PREFIX}")
endif()

# Swift PGO, injected by build-macos.sh the way the C-family flags are — but
# through its own variable, not UBIQUITTY_SWIFT_FLAGS: that list also feeds
# the two -typecheck header-emit passes, whose command lines must not change
# on a retrain (codegen never runs there, and a changed line would rebuild
# the generated headers and everything behind them for nothing). Only the
# codegen targets consume this.
set(UBIQUITTY_SWIFT_PGO_FLAGS "" CACHE STRING
    "Swift codegen profile flags (empty = no PGO); set by Scripts/build-macos.sh")
set(UBIQUITTY_SWIFT_PGO_GENEX "")
if(UBIQUITTY_SWIFT_PGO_FLAGS)
    set(UBIQUITTY_SWIFT_PGO_GENEX "$<$<COMPILE_LANGUAGE:Swift>:SHELL:${UBIQUITTY_SWIFT_PGO_FLAGS}>")
endif()

# CMake deduplicates option lists before expanding a SHELL group. Keep repeated
# -Xcc forwarding pairs in one group while raw custom commands keep list argv.
set(UBIQUITTY_SWIFT_FLAGS_GROUPED "")
foreach(_swift_flag IN LISTS UBIQUITTY_SWIFT_FLAGS)
    string(APPEND UBIQUITTY_SWIFT_FLAGS_GROUPED " '${_swift_flag}'")
endforeach()

# How Debug is made whole-module, per generator. The reason is spelled on
# UbiquittyRenderKit below; this is only the spelling. Ninja takes the mode as
# a flag. Xcode plans a target's outputs from its own build setting, and a
# `-wmo` among the other flags contradicts that plan, so there the mode is the
# setting — on all three Swift targets, the app included, because an
# incremental importer loses the same members an incremental emitter does.
# Scripts/check-xcode-workspace.py reads the generated project for it.
set(UBIQUITTY_SWIFT_DEBUG_WHOLE_MODULE "")
if(CMAKE_GENERATOR MATCHES "Xcode")
    set_target_properties(Ubiquitty PROPERTIES
        XCODE_ATTRIBUTE_SWIFT_COMPILATION_MODE "wholemodule")
else()
    set(UBIQUITTY_SWIFT_DEBUG_WHOLE_MODULE
        "$<$<AND:$<COMPILE_LANGUAGE:Swift>,$<CONFIG:Debug>>:SHELL:-wmo>")
endif()
set_target_properties(Ubiquitty PROPERTIES
    Swift_COMPILATION_MODE "wholemodule"
    # The app's floor is `app`, not `cxx` — Scripts/macos-deployment-target.txt
    # says why there are two. Per-target because only the app takes the higher
    # one: the kit keeps `cxx` so a host below the app's floor can adopt it.
    XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET "${UBIQUITTY_MACOS_APP_MIN}")
target_compile_options(Ubiquitty PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:${UBIQUITTY_SWIFT_FLAGS_GROUPED}>"
    # The settings sources read the render kit's interface (the feature pane
    # draws its samples through the renderer's own face builder), so the app
    # module's Swift needs its swiftmodule on the search path.
    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-I ${CMAKE_CURRENT_BINARY_DIR}>"
    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-import-objc-header ${UBIQUITTY_SWIFT_DIR}/Ubiquitty-Bridging-Header.h>"
    ${UBIQUITTY_SWIFT_PGO_GENEX}
)


# ----------------------------------------------------------------------
# What the Swift modules INLINE, so Ninja knows to rebuild them when it moves.
#
# The mechanism, and every measurement behind it, is in
# cmake/SwiftInteropStamp.cmake — shared with the iOS arm, whose modules inline
# the same headers.
include("${CMAKE_SOURCE_DIR}/cmake/SwiftInteropStamp.cmake")
ubiquitty_swift_interop_stamp(UBIQUITTY_SWIFT_INTEROP_STAMP)

# Every Swift module that inlines those headers carries the stamp, and there are
# four: this executable's own module, UbiquittyRenderKit, UbiquittyKitModule and
# the UbiquittyKit framework (the last shares UBIQUITTY_KIT_SOURCES with the
# third, so one append serves both). The executable's is the one that matters
# most to trust the tests: UBIQUITTY_SWIFT_SOURCES is where every Swift UI
# scenario is compiled, so without this the module holding the assertions is
# built against a Core the rest of the app has already moved past — and an
# ablation meant to prove a scenario can fail reaches nothing, reporting a
# healthy test as vacuous.
#
# target_sources rather than a list append: add_executable(Ubiquitty) is above,
# and the stamp does not exist as a name until here.
target_sources(Ubiquitty PRIVATE "${UBIQUITTY_SWIFT_INTEROP_STAMP}")

# ----------------------------------------------------------------------
# UbiquittyRenderKit: the Swift renderer module.
# ----------------------------------------------------------------------
set(UBIQUITTY_RENDERKIT_SOURCES_ABS "")
foreach(_src IN LISTS UBIQUITTY_RENDERKIT_SOURCES)
    list(APPEND UBIQUITTY_RENDERKIT_SOURCES_ABS "${CMAKE_SOURCE_DIR}/${_src}")
endforeach()

list(APPEND UBIQUITTY_RENDERKIT_SOURCES_ABS "${UBIQUITTY_SWIFT_INTEROP_STAMP}")
add_library(UbiquittyRenderKit STATIC ${UBIQUITTY_RENDERKIT_SOURCES_ABS})
# This property is honoured in the optimised configurations and not in Debug,
# where CMake drives swiftc `-incremental`. The per-config spelling does not bind
# it either — measured, by building Debug from scratch with each and comparing.
# The mode is therefore forced as a flag below, and the difference it makes
# reaches the module interface rather than only the object code: an
# incrementally merged module is built from per-file partials, and a member whose
# signature names an imported C++ type is dropped from the serialized interface
# instead of being diagnosed. The consumer then fails at the call with "has no
# member" while the member is public on the same tree, so nothing points at the
# cause. Naming the mode per configuration is what makes the arm buildable in the
# mode it is debugged in.
set_target_properties(UbiquittyRenderKit PROPERTIES
    Swift_MODULE_NAME "UbiquittyRenderKit"
    Swift_COMPILATION_MODE "wholemodule")
# No bridging header: the renderer reaches Core through the module maps and
# the OS through the SDK. The six check-*.sh drivers compile these same
# files with neither the bridging header nor the app module, which is the
# standing proof this list stays self-contained.
# `Swift_COMPILATION_MODE` above is honoured in the optimised configurations and
# not in Debug, where CMake drives swiftc `-incremental`. That difference reaches
# the module interface rather than only the object code: an incrementally merged
# module is built from per-file partials, and a member whose signature names an
# imported C++ type is dropped from the serialized interface instead of being
# diagnosed. The consumer then fails at the call with "has no member", nothing
# points at the cause, and the member is demonstrably public on the same tree.
# Spelling the mode as a flag is what makes it hold in every configuration, so
# the arm builds in the mode it is debugged in.
if(CMAKE_GENERATOR MATCHES "Xcode")
    # The app's floor, as the setting. UBIQUITTY_SWIFT_FLAGS names it with
    # `-target`, which Xcode replaces with one built from this setting; left at
    # the C++ floor, the module is compiled for an OS older than the API it
    # is written against.
    set_target_properties(UbiquittyRenderKit PROPERTIES
        XCODE_ATTRIBUTE_SWIFT_COMPILATION_MODE "wholemodule"
        XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET "${UBIQUITTY_MACOS_APP_MIN}")
endif()
target_compile_options(UbiquittyRenderKit PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:${UBIQUITTY_SWIFT_FLAGS_GROUPED}>"
    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enforce-exclusivity=unchecked>"
    ${UBIQUITTY_SWIFT_DEBUG_WHOLE_MODULE}
    ${UBIQUITTY_SWIFT_PGO_GENEX})

# The render kit's generated interface, which Scripts/check-swift-cxx-exports.py
# reads for what the module exports across the seam. Emitted by its own pass so
# Ninja orders it after the module it describes.
set(UBIQUITTY_RENDERKIT_GENERATED_HEADER
    "${CMAKE_CURRENT_BINARY_DIR}/UbiquittyRenderKit-Swift.h")
add_custom_command(
    OUTPUT  "${UBIQUITTY_RENDERKIT_GENERATED_HEADER}"
    COMMAND xcrun swiftc
            -module-name UbiquittyRenderKit
            -emit-objc-header-path "${UBIQUITTY_RENDERKIT_GENERATED_HEADER}"
            -typecheck
            -wmo
            ${UBIQUITTY_SWIFT_FLAGS}
            ${UBIQUITTY_SWIFT_HEADER_PASS_FLAGS}
            ${UBIQUITTY_SWIFT_EXTRA_FLAGS}
            ${UBIQUITTY_RENDERKIT_SOURCES_ABS}
    DEPENDS ${UBIQUITTY_RENDERKIT_SOURCES_ABS}
            "${CMAKE_SOURCE_DIR}/Source/Platform/Apple/module.modulemap"
            ${UBIQUITTY_SWIFT_INTEROP_HEADERS}
    COMMENT "Emitting UbiquittyRenderKit-Swift.h"
    VERBATIM)
add_custom_target(UbiquittyRenderKitHeader
    DEPENDS "${UBIQUITTY_RENDERKIT_GENERATED_HEADER}")
# The header target waits for the library, and that is what makes the Xcode
# generator accept this directory at all.
#
# UbiquittyInteropStamp.swift is generated by one custom command and is a source
# of both UbiquittyRenderKit and (through UBIQUITTY_RENDERKIT_SOURCES_ABS) the
# emit above. Xcode's "new build system" refuses a generating command attached to
# two targets unless one is a dependency of the other — Ninja does not, which is
# why `generate-xcode-workspace.sh` failed while every ninja build passed.
#
# Ordering it this way rather than the other: the emit reads the same sources the
# library compiles, so running it after the library is the direction that was
# already true in practice.
add_dependencies(UbiquittyRenderKitHeader UbiquittyRenderKit)
add_dependencies(Ubiquitty UbiquittyRenderKitHeader)

# ----------------------------------------------------------------------
# UbiquittyKit (module): the pure-Swift surface over the machinery.
#
# Its files import the render kit and every Core interop module INTERNALLY,
# which is what keeps C++ out of the module's interface: a consumer of the
# UbiquittyKit module needs no interoperability flags and no module maps.
# The machinery it constructs is reached through package visibility — both
# modules compile under -package-name ubiquitty.
# ----------------------------------------------------------------------
set(UBIQUITTY_KIT_SOURCES
    ${UBIQUITTY_APPLE_SHARED_KIT_ABS}
    # macOS only: the ASCII-capable-layout lookup is Carbon, and the question
    # it answers — which Latin letter a physical key carries — has no iOS
    # meaning. Its one caller is inside `#if canImport(AppKit)`, so the phone
    # never names it.
    "${CMAKE_SOURCE_DIR}/Source/UbiquittyKit/Swift/KeyboardLayout.swift"
    # macOS only: every prompt it presents is an NSAlert, and the three
    # questions it asks — an agent driving a session, a program reading the
    # clipboard, an install copying a binary to a host — are the desktop's.
    "${CMAKE_SOURCE_DIR}/Source/UbiquittyKit/Swift/ConsentAlert.swift"
    # macOS only: a program's icon as AppKit images, read through ProcessIcons
    # below from the process icons only the macOS products ship.
    "${CMAKE_SOURCE_DIR}/Source/UbiquittyKit/Swift/TerminalSurface+ProgramIcon.swift"
    # macOS only: the pasteboard half of the PAL clipboard backend, which
    # Source/Platform/macOS/Clipboard.cpp calls through a C seam. It rides this
    # list because the seam has to resolve in both products — the app links this
    # module, and the framework compiles the same sources.
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/ClipboardPasteboard.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/StreamDebugView.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/StreamDebugWindowController.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/AdaptiveDriveDebugWindowController.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/PerfDiagnosticsWindows.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+PerfDiagnostics.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/PointerLockRegistry.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/WindowCornerMask.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/SystemDisplayOptions.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/SquareBottomWindow.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/ZoomTrackingWindow.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TitlebarInk.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/ProxyIconRevealController.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TitlebarDocumentActionsController.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TitlebarTagPalette.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/ProcessIcons.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/PhosphorIcons.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/ShippedIconsSmoke.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TagIconPicker.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TabStripStyling.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TabStripMaterial.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/PaneChrome.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/PaneTransferCoordinator.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TabTitleStyling.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TabAttentionDots.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/BellMark.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TabProgressIndicator.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TabStatusMark.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TabAccessoryPresenter.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/WindowLevelMemory.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/BroadcastInputMemory.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/ChromelessWindowChrome.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TabButtonProgressBar.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TabTagDots.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/SessionAttention.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/LinkPreviewBubble.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Notifications.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/ScriptingHook.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/FindBarMemory.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/LinkOpener.swift"
    # The Welcome screen's buttons, which LinkOpener dispatches first, and the
    # shell wrapper one of them installs: both shells open links through the
    # opener, so the dispatch lives beside it.
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/WelcomeActions.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/ShellIntegrationInstaller.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/QuarantinedDownload.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/ThemePreview.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalInspector.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/InspectorTarget.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalSettingsPreview.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+TmuxHosting.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+HostedWindows.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+RemoteHosting.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/RemoteSessionLifecycle.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/RemoteResume.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+Refusal.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+SpawnRefusal.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/ShareSessionSupport.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/LocalHostUpgrade.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+Sharing.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+WindowOps.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/ClosedWindowRecovery.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/ProfileEditorModel.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+Configuration.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+Triggers.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TriggerActions.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/DropDown/QuakeController.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/DropDown/QuakeHotkey.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+RemoteWorkspace.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+Paste.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+Clear.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+SessionLog.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+SessionCapture.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+Scripting.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/ControlHost.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+EditMenu.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/UBFindBar.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+Find.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+TitlebarIdentity.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TagRulePrefill.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/WindowFrameMemory.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/TerminalWindowController+Beam.swift"
    "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/App/Windowing/ShellSmoke.swift")
list(APPEND UBIQUITTY_KIT_SOURCES "${UBIQUITTY_SWIFT_INTEROP_STAMP}")
add_library(UbiquittyKitModule STATIC ${UBIQUITTY_KIT_SOURCES})
# Forced as a flag below for the reason spelled on UbiquittyRenderKit. This
# target reads the other's interface, so it is where a dropped member is
# observed — but both need it, since either one built incrementally can serialize
# a module the next reader finds short.
set_target_properties(UbiquittyKitModule PROPERTIES
    Swift_MODULE_NAME "UbiquittyKit"
    Swift_COMPILATION_MODE "wholemodule")
# Debug takes the mode as a flag for the reason spelled on UbiquittyRenderKit:
# the property alone is not honoured there, and an incrementally merged module
# drops interop members from its interface. This target is the consumer that
# reads the other's interface, so it is where the drop is observed — but both
# need the flag, since either one built incrementally can serialize a module the
# next reader finds short.
if(CMAKE_GENERATOR MATCHES "Xcode")
    set_target_properties(UbiquittyKitModule PROPERTIES
        XCODE_ATTRIBUTE_SWIFT_COMPILATION_MODE "wholemodule"
        # The module's name, as the setting Xcode reads: it names a module
        # for its product, which here is the target's name and not the name
        # the app imports.
        XCODE_ATTRIBUTE_PRODUCT_MODULE_NAME "UbiquittyKit"
        XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET "${UBIQUITTY_MACOS_APP_MIN}")
endif()
target_compile_options(UbiquittyKitModule PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:${UBIQUITTY_SWIFT_FLAGS_GROUPED}>"
    ${UBIQUITTY_SWIFT_DEBUG_WHOLE_MODULE}
    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-I ${CMAKE_CURRENT_BINARY_DIR}>"
    ${UBIQUITTY_SWIFT_PGO_GENEX})
add_dependencies(UbiquittyKitModule UbiquittyRenderKit)
target_link_libraries(UbiquittyKitModule PRIVATE UbiquittyRenderKit PUBLIC UbiquittyPasteboard)
target_link_libraries(Ubiquitty PRIVATE UbiquittyKitModule)
# AppKit resolves Swift extension actions through Objective-C metadata, without
# a direct symbol reference that would pull their archive members into the app.
target_link_options(Ubiquitty PRIVATE "LINKER:-ObjC")

# The harness's Swift seams and C++ lock-hold counter are members under
# UBIQUITTY_UI_TESTS, so every Swift module needs the active-compilation
# condition and its clang importer must see the same C++ definition as the
# app's translation units. A module importing the header without the latter
# lays TerminalRuntime out one field short, and the Swift shell's first ingest
# pass faults. One SHELL: group per target avoids CMake de-duplicating a second
# bare `-Xcc` away from its argument.
if(UBIQUITTY_UI_TESTS)
    foreach(_swift_target Ubiquitty UbiquittyRenderKit UbiquittyKitModule)
        target_compile_options(${_swift_target} PRIVATE
            "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-DUBIQUITTY_UI_TESTS>"
            "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xcc -DUBIQUITTY_UI_TESTS=1>")
    endforeach()
endif()
# The window-server blur radius is set from Swift (WindowBlurBackdrop) under
# the same gate the C-family definition above carries.
if(UBIQUITTY_BACKGROUND_BLUR)
    target_compile_options(Ubiquitty PRIVATE "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-DUBIQUITTY_BACKGROUND_BLUR>")
endif()

# Warnings for the C-family compiles. Scoped by language: CMake drives the
# final link through swiftc (Swift is in the target), and swiftc rejects
# clang's warning flags, so these must not leak into the Swift compile/link.
target_compile_options(Ubiquitty PRIVATE
    "$<$<COMPILE_LANGUAGE:CXX,C>:-Wall>"
    "$<$<COMPILE_LANGUAGE:CXX,C>:-Wextra>"
    # -Werror for the C-family compiles only (UBIQUITTY_WERROR, default ON).
    # Swift keeps its own default — it still emits a few harmless
    # conditional-compilation-flag notices from the valued -D defines.
    "$<$<AND:$<BOOL:${UBIQUITTY_WERROR}>,$<COMPILE_LANGUAGE:CXX,C>>:-Werror>"
)

target_link_libraries(Ubiquitty PRIVATE
    ${COCOA_FRAMEWORK}
    ${FOUNDATION_FRAMEWORK}
    ${METAL_FRAMEWORK}
    ${METALKIT_FRAMEWORK}
    ${QUARTZCORE_FRAMEWORK}
    ${CORETEXT_FRAMEWORK}
    ${CARBON_FRAMEWORK}
    ${IMAGEIO_FRAMEWORK}
    ${USERNOTIFICATIONS_FRAMEWORK}
    ${AUDIOTOOLBOX_FRAMEWORK}
)

# ----------------------------------------------------------------------
# Optional QUIC transport — Transport::QUICChannel over the portable
# Transport/QUICClient (ngtcp2 + AWS-LC). UBIQUITTY_QUIC controls whether this
# target links that stack; the default build ships QUIC on.
# The thin ObjC++ adapter carries the Sync byte stream like the other transports;
# all QUIC machinery is in the portable client.
# ----------------------------------------------------------------------
if(UBIQUITTY_QUIC)
    ubiquitty_ensure_quic_deps() # fetch the pinned QUIC TLS deps if absent
    target_sources(Ubiquitty PRIVATE
        "${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/QUICClient.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/DatagramBatch.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Core/Transport/QUICChannel.cpp")
    # QUICClient.cpp + QUICChannel.cpp are portable C++ — same strict ABI flags as
    # the Core TUs.
    set_source_files_properties(
        "${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/QUICClient.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/DatagramBatch.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Core/Transport/QUICChannel.cpp"
        PROPERTIES COMPILE_FLAGS "-std=c++23 -fno-exceptions -fno-rtti")
    target_include_directories(Ubiquitty PRIVATE "${UBIQUITTY_QUIC_PREFIX}/include")
    ub_c_family_compile_definitions(Ubiquitty UBIQUITTY_QUIC=1)
    # Link order: crypto backend -> ngtcp2 -> AWS-LC ssl -> crypto (most-dependent
    # first). AWS-LC is self-contained crypto — no Security.framework needed.
    target_link_libraries(Ubiquitty PRIVATE
        "${UBIQUITTY_QUIC_PREFIX}/lib/libngtcp2_crypto_boringssl.a"
        "${UBIQUITTY_QUIC_PREFIX}/lib/libngtcp2.a"
        "${UBIQUITTY_QUIC_PREFIX}/lib/libssl.a"
        "${UBIQUITTY_QUIC_PREFIX}/lib/libcrypto.a")
    message(STATUS "Ubiquitty: QUIC transport enabled (ngtcp2 + AWS-LC)")
endif()

# ----------------------------------------------------------------------
# Optional Sparkle auto-update (Docs/auto-update.md) — the link and the embed.
#
# Whether the framework is here was decided above, with the Swift flags. When it
# is, we link and embed it and App/Updater.swift compiles its real
# implementation; when it is not, the build still succeeds — the updater answers
# nil, and the "Check for Updates…" menu item is omitted — so a dev build that
# skipped the fetch just has no updater. The prebuilt framework is used (not a
# source build): building Sparkle from source strips its code signing.
# ----------------------------------------------------------------------
if(UBIQUITTY_SPARKLE_FOUND)
    message(STATUS "Ubiquitty: Sparkle auto-update enabled (${_sparkle_fw})")
    # Framework search path for the `import Sparkle` compile and for the link;
    # @rpath so the embedded copy under Contents/Frameworks resolves at runtime.
    target_compile_options(Ubiquitty PRIVATE
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-F ${UBIQUITTY_SPARKLE_PREFIX}>")
    target_link_libraries(Ubiquitty PRIVATE "${_sparkle_fw}")
    target_link_options(Ubiquitty PRIVATE
        "SHELL:-F ${UBIQUITTY_SPARKLE_PREFIX}"
        "SHELL:-Xlinker -rpath -Xlinker @executable_path/../Frameworks")
    # Embed into the bundle. ditto (not cmake -E copy_directory) so the
    # framework's symlink farm + the vendor signature survive the copy; the
    # signing pass (Scripts/sign-sparkle.sh, invoked from build-macos.sh)
    # re-signs the nested XPC services + framework before the app is sealed.
    add_custom_command(TARGET Ubiquitty POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory
                "$<TARGET_BUNDLE_CONTENT_DIR:Ubiquitty>/Frameworks"
        COMMAND ${CMAKE_COMMAND} -E rm -rf
                "$<TARGET_BUNDLE_CONTENT_DIR:Ubiquitty>/Frameworks/Sparkle.framework"
        COMMAND ditto "${_sparkle_fw}"
                "$<TARGET_BUNDLE_CONTENT_DIR:Ubiquitty>/Frameworks/Sparkle.framework"
        COMMENT "Embedding Sparkle.framework into bundle Frameworks"
        VERBATIM)
elseif(UBIQUITTY_SPARKLE)
    message(STATUS
        "Ubiquitty: Sparkle not found at ${_sparkle_fw} — auto-update disabled. "
        "Run Scripts/fetch-sparkle.sh to enable it.")
endif()

# The target mixes CXX and Swift; CMake links it through swiftc, which brings
# the C++ stdlib for its interop while CMake appends CXX's implicit one, so
# "-lc++" can land on the link line twice and ld warns "ignoring duplicate
# libraries". The dup is harmless (ld drops the second), but pruning CMake's
# per-language implicit libs is brittle — silence it at the linker instead. swiftc forwards via
# -Xlinker; SHELL: keeps the flag pair intact through CMake de-duplication.
target_link_options(Ubiquitty PRIVATE
    "SHELL:-Xlinker -no_warn_duplicate_libraries")

# ThinLTO defers code generation to the link, so a C-family .o holds bitcode
# and carries no DWARF: the debug map's OSO entries name the object files ld64
# writes for the LTO backend instead of the ones the compiler produced. Those
# default to a temporary directory the linker removes when it exits, leaving
# dsymutil nothing to collect for any C-family unit — the dSYM then covers only
# the Swift units, which are compiled to real objects, and Core frames
# symbolicate to a name without a file:line. -object_path_lto keeps the LTO
# objects under the build directory for the dSYM pass to read.
if(CMAKE_INTERPROCEDURAL_OPTIMIZATION AND CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
    file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/lto-objects")
    target_link_options(Ubiquitty PRIVATE
        "SHELL:-Xlinker -object_path_lto -Xlinker ${CMAKE_BINARY_DIR}/lto-objects")
endif()

# Unused-code analysis (Scripts/build-macos.sh --unused). The compiler-side
# -Wunused*/-ffunction-sections flags arrive via CMAKE_<LANG>_FLAGS from the
# script; the linker side must be a target option because this target links
# through swiftc, whose link rule ignores CMAKE_EXE_LINKER_FLAGS (the flags
# would only reach CMake's configure-time ABI test, which then clobbers the
# map with its own). -dead_strip drops unreferenced function/data sections
# and -map records them under "# Dead Stripped Symbols:" for the report.
option(UBIQUITTY_UNUSED_ANALYSIS
    "Link with -dead_strip and write a map of dead-stripped symbols" OFF)
if(UBIQUITTY_UNUSED_ANALYSIS)
    target_link_options(Ubiquitty PRIVATE
        "SHELL:-Xlinker -dead_strip"
        "SHELL:-Xlinker -map -Xlinker ${CMAKE_BINARY_DIR}/link.map")
endif()

# Shell-integration scripts (OSC 133 prompt marks). The app locates
# them at runtime via [NSBundle resourcePath]/shell-integration and
# exports UBIQUITTY_INTEGRATION_DIR to every spawned shell.
set(UBIQUITTY_SHELL_INTEGRATION_DIR
    "${CMAKE_SOURCE_DIR}/Resources/shell-integration")
add_custom_command(TARGET Ubiquitty POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
            "$<TARGET_BUNDLE_CONTENT_DIR:Ubiquitty>/Resources/shell-integration"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${UBIQUITTY_SHELL_INTEGRATION_DIR}"
            "$<TARGET_BUNDLE_CONTENT_DIR:Ubiquitty>/Resources/shell-integration"
    COMMENT "Copying shell-integration scripts into bundle Resources"
    VERBATIM)

# Bundle the fonts and their constituent license notices (Resources/fonts/) into
# Contents/Resources/fonts/. Loaded at runtime via [NSBundle resourcePath]/fonts
# and used as a glyph fallback for codepoints the primary font lacks (Nerd Font
# icons / Powerline) — see UbiquittyRenderKit/FontRouter.swift.
#
# The destination is REMOVED before the copy. `copy_directory` adds and
# overwrites and never deletes, and Info.plist's ATSApplicationFontsPath
# registers whatever sits in that directory — so a font dropped from the source
# tree stays registered, and for a family whose members are separate files that
# leaves the app resolving to a member the tree no longer carries. Nothing about
# the build reports it: the render is a perfectly good render of the wrong file.
#
# Driven by a stamp that depends on the font files rather than by POST_BUILD
# alone. A POST_BUILD command runs only when its target relinks, and changing
# the bundled fonts changes no macOS source, so the common case — edit the
# fonts, rebuild, read the bundle — is exactly the one POST_BUILD sleeps
# through.
#
# The stamp depends on a generated LIST of the bundled files as well as on the
# files. A stamp alone cannot see a deletion: removing a font leaves every
# surviving file older than the stamp, so the rule stays satisfied and the
# bundle keeps the file the tree dropped — the exact failure this rule exists
# to close. The list changes whenever the set does, and `file(GENERATE)` leaves
# its mtime alone when the content matches, so this costs nothing per build.
file(GLOB UBIQUITTY_BUNDLED_FONT_FILES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/Resources/fonts/*")
list(SORT UBIQUITTY_BUNDLED_FONT_FILES)
set(UBIQUITTY_BUNDLED_FONTS_LIST "${CMAKE_CURRENT_BINARY_DIR}/bundled-fonts.list")
file(GENERATE OUTPUT "${UBIQUITTY_BUNDLED_FONTS_LIST}"
     CONTENT "$<JOIN:${UBIQUITTY_BUNDLED_FONT_FILES},\n>\n")
#
# The stamp lives INSIDE the directory it records, which is what makes the rule
# self-healing: deleting the bundle, or just its fonts, takes the stamp with it
# and the copy runs again. A stamp kept in the build tree survives both, and
# then reports a bundle that is no longer there.
#
# Spelled at configure time from the bundle's own name rather than through
# `$<TARGET_BUNDLE_CONTENT_DIR:Ubiquitty>`: a generator expression is legal in a
# COMMAND and not in an OUTPUT, and the stamp has to be an OUTPUT for the
# deletion above to be seen. `OUTPUT_NAME` on the target is the same variable,
# so the two cannot name different bundles.
set(UBIQUITTY_BUNDLED_FONTS_DIR
    "${CMAKE_CURRENT_BINARY_DIR}/${UBIQUITTY_APP_NAME}.app/Contents/Resources/fonts")
set(UBIQUITTY_BUNDLED_FONTS_STAMP "${UBIQUITTY_BUNDLED_FONTS_DIR}/.bundled.stamp")
add_custom_command(
    OUTPUT "${UBIQUITTY_BUNDLED_FONTS_STAMP}"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${UBIQUITTY_BUNDLED_FONTS_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_SOURCE_DIR}/Resources/fonts"
            "${UBIQUITTY_BUNDLED_FONTS_DIR}"
    COMMAND ${CMAKE_COMMAND} -E touch "${UBIQUITTY_BUNDLED_FONTS_STAMP}"
    DEPENDS ${UBIQUITTY_BUNDLED_FONT_FILES} "${UBIQUITTY_BUNDLED_FONTS_LIST}"
    COMMENT "Bundling fonts: JetBrains Mono house face + Nerd Font symbols fallback"
    VERBATIM)
add_custom_target(ubiquitty-bundled-fonts ALL DEPENDS "${UBIQUITTY_BUNDLED_FONTS_STAMP}")
# Ordering, not content: the copy writes inside the bundle, so the bundle has to
# exist first.
add_dependencies(ubiquitty-bundled-fonts Ubiquitty)

# Bundle the Phosphor tag icons (Resources/phosphor/: the fill and regular
# fonts, the catalog a picker searches, and their license) into
# Contents/Resources/phosphor/. Read by PhosphorIcons.swift into fonts only the
# app holds, so unlike the fonts above they are never registered: their glyphs
# sit in the Private Use Area, where a registered font would answer a
# terminal's own icon codepoints. The same stamp-inside-the-copy rule as the
# fonts, for the same reasons.
file(GLOB UBIQUITTY_PHOSPHOR_FILES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/Resources/phosphor/*")
list(SORT UBIQUITTY_PHOSPHOR_FILES)
set(UBIQUITTY_PHOSPHOR_LIST "${CMAKE_CURRENT_BINARY_DIR}/bundled-phosphor.list")
file(GENERATE OUTPUT "${UBIQUITTY_PHOSPHOR_LIST}"
     CONTENT "$<JOIN:${UBIQUITTY_PHOSPHOR_FILES},\n>\n")
set(UBIQUITTY_PHOSPHOR_DIR
    "${CMAKE_CURRENT_BINARY_DIR}/${UBIQUITTY_APP_NAME}.app/Contents/Resources/phosphor")
set(UBIQUITTY_PHOSPHOR_STAMP "${UBIQUITTY_PHOSPHOR_DIR}/.bundled.stamp")
add_custom_command(
    OUTPUT "${UBIQUITTY_PHOSPHOR_STAMP}"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${UBIQUITTY_PHOSPHOR_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_SOURCE_DIR}/Resources/phosphor"
            "${UBIQUITTY_PHOSPHOR_DIR}"
    COMMAND ${CMAKE_COMMAND} -E touch "${UBIQUITTY_PHOSPHOR_STAMP}"
    DEPENDS ${UBIQUITTY_PHOSPHOR_FILES} "${UBIQUITTY_PHOSPHOR_LIST}"
    COMMENT "Bundling the Phosphor tag icons"
    VERBATIM)
add_custom_target(ubiquitty-bundled-phosphor ALL DEPENDS "${UBIQUITTY_PHOSPHOR_STAMP}")
add_dependencies(ubiquitty-bundled-phosphor Ubiquitty)

# Bundle the process icons (Resources/process-icons/: the icons, their catalog and
# their notice) into Contents/Resources/process-icons/, read by ProcessIcons.swift
# by the file Core's catalog names. The same stamp-inside-the-copy rule.
file(GLOB UBIQUITTY_PROCESS_ICON_FILES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/Resources/process-icons/*")
list(SORT UBIQUITTY_PROCESS_ICON_FILES)
set(UBIQUITTY_PROCESS_ICON_LIST "${CMAKE_CURRENT_BINARY_DIR}/bundled-process-icons.list")
file(GENERATE OUTPUT "${UBIQUITTY_PROCESS_ICON_LIST}"
     CONTENT "$<JOIN:${UBIQUITTY_PROCESS_ICON_FILES},\n>\n")
set(UBIQUITTY_PROCESS_ICON_DIR
    "${CMAKE_CURRENT_BINARY_DIR}/${UBIQUITTY_APP_NAME}.app/Contents/Resources/process-icons")
set(UBIQUITTY_PROCESS_ICON_STAMP "${UBIQUITTY_PROCESS_ICON_DIR}/.bundled.stamp")
add_custom_command(
    OUTPUT "${UBIQUITTY_PROCESS_ICON_STAMP}"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${UBIQUITTY_PROCESS_ICON_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_SOURCE_DIR}/Resources/process-icons"
            "${UBIQUITTY_PROCESS_ICON_DIR}"
    COMMAND ${CMAKE_COMMAND} -E touch "${UBIQUITTY_PROCESS_ICON_STAMP}"
    DEPENDS ${UBIQUITTY_PROCESS_ICON_FILES} "${UBIQUITTY_PROCESS_ICON_LIST}"
    COMMENT "Bundling the process icons"
    VERBATIM)
add_custom_target(ubiquitty-bundled-process-icons ALL DEPENDS "${UBIQUITTY_PROCESS_ICON_STAMP}")
add_dependencies(ubiquitty-bundled-process-icons Ubiquitty)

# Bundle the AppleScript dictionary (Ubiquitty.sdef) into Contents/Resources/.
# Info.plist's OSAScriptingDefinition names it by bare filename; Cocoa Scripting
# loads it from Resources at launch to make `tell application "Ubiquitty"` work.
add_custom_command(TARGET Ubiquitty POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
            "$<TARGET_BUNDLE_CONTENT_DIR:Ubiquitty>/Resources"
    COMMAND ${CMAKE_COMMAND} -E copy
            "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/Ubiquitty.sdef"
            "$<TARGET_BUNDLE_CONTENT_DIR:Ubiquitty>/Resources/Ubiquitty.sdef"
    COMMENT "Bundling AppleScript dictionary (Ubiquitty.sdef)"
    VERBATIM)

# Metal shader compilation. The Makefile / Ninja generators do not
# compile .metal sources natively, so we drive the metal compiler by
# hand and copy the resulting default.metallib into the bundle's
# Resources directory where [MTLDevice newDefaultLibrary] looks for it.
#
# Compiling .metal requires the Metal Toolchain, which ships with full
# Xcode (and, on recent macOS, as a separately downloaded component:
# `xcodebuild -downloadComponent MetalToolchain`). When the toolchain
# is absent we skip the shader build so the target still configures,
# compiles, and links; the runtime detects the missing library and
# reports it instead of crashing. Building the metallib then only
# requires a rebuild once the toolchain is installed.
set(UBIQUITTY_METAL_SRC "${CMAKE_SOURCE_DIR}/Source/UbiquittyRenderKit/UBShaders.metal")
set(UBIQUITTY_METAL_AIR "${CMAKE_CURRENT_BINARY_DIR}/UBShaders.air")
set(UBIQUITTY_METAL_LIB "${CMAKE_CURRENT_BINARY_DIR}/default.metallib")

# Without a version-min the metal compiler targets the newest Metal language
# version, producing a metallib older systems refuse to load. It is pinned to
# CMAKE_OSX_DEPLOYMENT_TARGET, the C++ floor, which is at or below the app's, so
# the shaders load everywhere the app installs.
set(UBIQUITTY_METAL_FLAGS "")
if(CMAKE_OSX_DEPLOYMENT_TARGET)
    set(UBIQUITTY_METAL_FLAGS "-mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
endif()

# Probe for a usable metal compiler. The Xcode-bundled metal at
# Toolchains/XcodeDefault.xctoolchain/usr/bin/metal is a stub that
# exits with "missing Metal Toolchain"; the real compiler lives in
# the cryptex-mounted Metal.xctoolchain and is reachable through
# `xcrun -f metal`. Always resolve via xcrun first.
execute_process(
    COMMAND xcrun -f metal
    OUTPUT_VARIABLE UBIQUITTY_METAL_TOOL
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
execute_process(
    COMMAND xcrun -f metallib
    OUTPUT_VARIABLE UBIQUITTY_METALLIB_TOOL
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)

set(UBIQUITTY_HAVE_METAL_TOOL FALSE)
if(UBIQUITTY_METAL_TOOL AND UBIQUITTY_METALLIB_TOOL)
    # Confirm the binary can actually compile (the Metal Toolchain
    # component must be downloaded — `xcodebuild -downloadComponent
    # MetalToolchain` on recent macOS).
    execute_process(
        COMMAND "${UBIQUITTY_METAL_TOOL}" -c "${UBIQUITTY_METAL_SRC}"
                -o "${UBIQUITTY_METAL_AIR}.probe"
        RESULT_VARIABLE _metal_probe_rc
        OUTPUT_QUIET ERROR_QUIET)
    if(_metal_probe_rc EQUAL 0)
        set(UBIQUITTY_HAVE_METAL_TOOL TRUE)
        file(REMOVE "${UBIQUITTY_METAL_AIR}.probe")
    endif()
endif()

if(UBIQUITTY_HAVE_METAL_TOOL)
    add_custom_command(
        OUTPUT  "${UBIQUITTY_METAL_AIR}"
        COMMAND "${UBIQUITTY_METAL_TOOL}" ${UBIQUITTY_METAL_FLAGS}
                -c "${UBIQUITTY_METAL_SRC}"
                -o "${UBIQUITTY_METAL_AIR}"
        DEPENDS "${UBIQUITTY_METAL_SRC}" "${CMAKE_SOURCE_DIR}/Source/Core/Tek/BeamRaster.h"
        COMMENT "Compiling UBShaders.metal -> AIR"
        VERBATIM)
    add_custom_command(
        OUTPUT  "${UBIQUITTY_METAL_LIB}"
        COMMAND "${UBIQUITTY_METALLIB_TOOL}" "${UBIQUITTY_METAL_AIR}"
                -o "${UBIQUITTY_METAL_LIB}"
        DEPENDS "${UBIQUITTY_METAL_AIR}"
        COMMENT "Linking default.metallib"
        VERBATIM)
    add_custom_target(UbiquittyMetalLib DEPENDS "${UBIQUITTY_METAL_LIB}")
    add_dependencies(Ubiquitty UbiquittyMetalLib)

    add_custom_command(TARGET Ubiquitty POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy "${UBIQUITTY_METAL_LIB}"
                "$<TARGET_BUNDLE_CONTENT_DIR:Ubiquitty>/Resources/default.metallib"
        COMMENT "Copying default.metallib into bundle Resources"
        VERBATIM)
else()
    message(WARNING
        "Metal Toolchain not found; UBShaders.metal will NOT be compiled. "
        "The app links but the renderer reports a missing default library "
        "at launch. Install full Xcode or run "
        "`xcodebuild -downloadComponent MetalToolchain`, then rebuild.")
endif()

# ----------------------------------------------------------------------
# UbiquittyKit: the embeddable terminal framework (UBIQUITTY_KIT=ON).
#
# The render-kit sources plus the portable Core they link, packaged as a
# macOS framework an external app consumes with no Ubiquitty app around it.
# Off by default: the app links the static UbiquittyRenderKit above, and a
# second whole-module Swift compile on every developer build would be paid
# for a product most builds do not ship. Scripts/check-ubiquittykit.sh builds
# it, embeds it in a signed app and exercises it from there.
#
# v1 recompiles the Core TUs into the framework, the same way the app builds
# them, so one configure produces the product. The Core frontend already
# exports install(EXPORT UbiquittyCoreTargets) archives; pointing this target
# at find_package(UbiquittyCore) instead is the later unification, taken when
# the Linux UbiquittyKit needs the same split.
# ----------------------------------------------------------------------
option(UBIQUITTY_KIT "Build the UbiquittyKit framework" OFF)
if(UBIQUITTY_KIT)
    # The OS-seam TUs the runtime needs beneath the portable Core: the PTY
    # transport, the clock, the diagnostics sink and the serial/pty facts.
    # App chrome (UB* classes, main, profile harnesses) stays out — the
    # framework is the terminal, not the application around it.
    #
    # Every one is C++ over a C API, so the framework links no Objective-C at
    # all. The clipboard's pasteboard half is Swift and rides
    # UBIQUITTY_KIT_SOURCES above.
    set(UBIQUITTY_KIT_SEAMS
        "${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/PTYStream.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/SerialStream.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/PTYFacts.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/SessionHandoff.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/LocalHostInstall.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/RemoteResumeBridge.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Platform/Apple/Clock.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/Diag.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/Bell.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/Clipboard.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Platform/macOS/DECPSSound.cpp")
    add_library(UbiquittyKit SHARED
        ${UBIQUITTY_KIT_SOURCES}
        "${CMAKE_CURRENT_BINARY_DIR}/BuiltinThemesData.gen.cpp"
        ${UBIQUITTY_KIT_SEAMS}
        ${UBIQUITTY_PORTABLE_CORE_ABS})
    add_dependencies(UbiquittyKit UbiquittyRenderKit)
    # The Kit sources import UbiquittyPasteboard, as UbiquittyKitModule's do;
    # the framework compiles the same sources and needs the same module.
    target_link_libraries(UbiquittyKit PRIVATE UbiquittyRenderKit UbiquittyPasteboard)
    # The Kit holds the window shell, and a shell's remote session offers the
    # QUIC carrier: it builds the same sources under the same define as the
    # app, or its sessions would fall back to the subprocess carrier on every
    # connect while the app beside it dialled QUIC. The two must agree, since
    # which one opened a window is a user default rather than a build.
    if(UBIQUITTY_QUIC)
        target_sources(UbiquittyKit PRIVATE
            "${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/QUICClient.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/DatagramBatch.cpp"
            "${CMAKE_SOURCE_DIR}/Source/Core/Transport/QUICChannel.cpp")
        set_source_files_properties(
            "${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/QUICClient.cpp"
        "${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/DatagramBatch.cpp"
            "${CMAKE_SOURCE_DIR}/Source/Core/Transport/QUICChannel.cpp"
            PROPERTIES COMPILE_FLAGS "-std=c++23 -fno-exceptions -fno-rtti")
        target_include_directories(UbiquittyKit PRIVATE "${UBIQUITTY_QUIC_PREFIX}/include")
        ub_c_family_compile_definitions(UbiquittyKit UBIQUITTY_QUIC=1)
        target_link_libraries(UbiquittyKit PRIVATE
            "${UBIQUITTY_QUIC_PREFIX}/lib/libngtcp2_crypto_boringssl.a"
            "${UBIQUITTY_QUIC_PREFIX}/lib/libngtcp2.a"
            "${UBIQUITTY_QUIC_PREFIX}/lib/libssl.a"
            "${UBIQUITTY_QUIC_PREFIX}/lib/libcrypto.a")
    endif()
    # The bundle's version is the Kit version, which versions the framework's
    # Swift interface: a host requires a version by reading its Info.plist.
    # Read at configure time, so the header is a configure dependency.
    set(_ubq_kit_version_header "${CMAKE_SOURCE_DIR}/Source/UbiquittyKit/Version.h")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_ubq_kit_version_header}")
    file(READ "${_ubq_kit_version_header}" _ubq_kit_version_text)
    string(REGEX MATCH "kitVersionString = \"([0-9]+\\.[0-9]+\\.[0-9]+)\"" _ "${_ubq_kit_version_text}")
    if(NOT CMAKE_MATCH_1)
        message(FATAL_ERROR "no kitVersionString in ${_ubq_kit_version_header}")
    endif()
    set(UBIQUITTY_KIT_VERSION "${CMAKE_MATCH_1}")
    set_target_properties(UbiquittyKit PROPERTIES
        FRAMEWORK TRUE
        FRAMEWORK_VERSION A
        MACOSX_FRAMEWORK_IDENTIFIER "dev.ubiquitty.UbiquittyKit"
        MACOSX_FRAMEWORK_SHORT_VERSION_STRING "${UBIQUITTY_KIT_VERSION}"
        MACOSX_FRAMEWORK_BUNDLE_VERSION "${UBIQUITTY_KIT_VERSION}"
        Swift_MODULE_NAME "UbiquittyKit"
        Swift_COMPILATION_MODE "wholemodule"
        # Its own module directory: the app's static veneer target emits the
        # same module name into the default location, and two rules for one
        # output stop the build before either runs.
        Swift_MODULE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/UbiquittyKitFramework")
    target_compile_options(UbiquittyKit PRIVATE
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:${UBIQUITTY_SWIFT_FLAGS_GROUPED}>"
        # Library evolution is what makes the internal imports invisible to a
        # consumer: the binary swiftmodule records every dependency, but the
        # textual interface names only the public ones, and the framework
        # ships the interface.
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-library-evolution>"
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-emit-module-interface-path ${CMAKE_CURRENT_BINARY_DIR}/UbiquittyKitFramework/UbiquittyKit.swiftinterface>"
        ${UBIQUITTY_SWIFT_PGO_GENEX})
    target_compile_features(UbiquittyKit PRIVATE cxx_std_23)
    target_include_directories(UbiquittyKit PRIVATE
        "${CMAKE_SOURCE_DIR}/Source"
        "${CMAKE_SOURCE_DIR}/Source/Platform/macOS"
        "${CMAKE_CURRENT_BINARY_DIR}")
    target_include_directories(UbiquittyKit SYSTEM PRIVATE "${RE2_DIR}" "${SIMDUTF_DIR}")
    # ScrollSearch links the vendored re2 and the ingest path the vendored
    # simdutf, exactly as the app does.
    foreach(re2_source ${RE2_SOURCES})
        ub_add_thirdparty_source(UbiquittyKit "${re2_source}")
    endforeach()
    ub_add_thirdparty_source(UbiquittyKit "${SIMDUTF_DIR}/simdutf.cpp")
    target_link_libraries(UbiquittyKit PRIVATE
        "-framework AppKit"
        "-framework Metal"
        "-framework QuartzCore"
        "-framework CoreText"
        "-framework CoreGraphics"
        "-framework AudioToolbox"
        "-framework UniformTypeIdentifiers")

    # The framework carries its own shaders: the pipelines resolve the
    # metallib from ShippedResources.bundle, which is this one.
    if(UBIQUITTY_HAVE_METAL_TOOL)
        add_dependencies(UbiquittyKit UbiquittyMetalLib)
        add_custom_command(TARGET UbiquittyKit POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy "${UBIQUITTY_METAL_LIB}"
                    "$<TARGET_FILE_DIR:UbiquittyKit>/Resources/default.metallib"
            COMMENT "Copying default.metallib into UbiquittyKit Resources"
            VERBATIM)
    endif()

    # The rest of what its code reads from that bundle, as the app carries it:
    # the shipped fonts with each licence beside its font, the icons a title
    # and a tag draw, and the notices of everything the framework links. Each
    # directory is staged whole, as the app's are, so a file the tree drops
    # leaves the framework a host embeds. ShippedFonts registers the fonts for
    # the host's process, since the system reads ATSApplicationFontsPath from
    # the app's Info.plist only.
    ubiquitty_bundle_resource_directory(UbiquittyKit "fonts" ${UBIQUITTY_BUNDLED_FONT_FILES})
    ubiquitty_bundle_resource_directory(UbiquittyKit "phosphor" ${UBIQUITTY_PHOSPHOR_FILES})
    ubiquitty_bundle_resource_directory(UbiquittyKit "process-icons" ${UBIQUITTY_PROCESS_ICON_FILES})
    ubiquitty_bundle_license_notices(UbiquittyKit)

    # The swiftmodule rides the framework's Modules directory, which is what
    # lets a consumer import the module from -F alone, and the bundle takes
    # the versioned layout codesign seals in an app: see
    # cmake/FrameworkBundleLayout.cmake. After every step that writes into
    # the bundle, since the script refuses one that breaks the layout.
    add_custom_command(TARGET UbiquittyKit POST_BUILD
        COMMAND ${CMAKE_COMMAND}
                "-DUBIQUITTY_FRAMEWORK=$<TARGET_BUNDLE_DIR:UbiquittyKit>"
                "-DUBIQUITTY_FRAMEWORK_VERSION=$<TARGET_PROPERTY:UbiquittyKit,FRAMEWORK_VERSION>"
                "-DUBIQUITTY_FRAMEWORK_INTERFACE=${CMAKE_CURRENT_BINARY_DIR}/UbiquittyKitFramework/UbiquittyKit.swiftinterface"
                "-DUBIQUITTY_FRAMEWORK_INTERFACE_NAME=${CMAKE_SYSTEM_PROCESSOR}-apple-macos.swiftinterface"
                -P "${CMAKE_SOURCE_DIR}/cmake/FrameworkBundleLayout.cmake"
        COMMENT "Laying out UbiquittyKit.framework"
        VERBATIM)
endif()
