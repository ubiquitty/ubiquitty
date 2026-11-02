# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# Tests/CMakeLists.txt — finds the host tests, builds them, and registers them
# with CTest.
#
# A test is added by adding its file. Any `test_*.cpp` under Tests/<Subsystem>/
# is found by the glob further down, compiled into an executable of its own and
# run by `ctest`; no list names it, because a source list kept by hand falls
# out of step with the files on disk and nothing reports the drift.
#
# Each test found is one of two kinds.
#
#   ordinary    Linked against ubiquitty-core, the aggregate of the model,
#               behaviour and bundled POSIX backend layers. Nearly every test is
#               one, and the suite compiles the Core once for all of them.
#
#   boundary    Named in UBIQUITTY_BOUNDARY_TESTS. Each checks a layering claim,
#               that some header compiles against a restricted set of
#               dependencies, so its link line is what is under test. That line
#               is written out here, beside the list, where a reader can see
#               exactly what each of these tests is allowed to reach.
#

# The boundary tests, which never link ubiquitty-core. Each compiles its own
# source and whatever its <test>_EXTRA_SOURCES grants it, and nothing more.
set(UBIQUITTY_BOUNDARY_TESTS
    test_types           # Base/Types.h on the bare standard library, no platform header
    test_owned_child     # mocked process ownership with no Core or process creation
    test_local_control   # tagged local control codec and authority with no Core or I/O link
    test_local_control_client # bounded reload exchange with mocked transport and clock
    test_local_quic_control # fixed local QUIC codec and injected authority/mint values only
    # The aggregate's SystemPAL.cpp is built without the test hook, which leaves
    # the symlink seam dead: linked against it, this test would check a
    # situation it never managed to arrange. It compiles its own hooked copy.
    test_atomic_storage_perms
)
set(test_atomic_storage_perms_EXTRA_SOURCES Source/Platform/POSIX/SystemPAL.cpp)
set(test_session_handoff_deadline_EXTRA_SOURCES Source/Platform/POSIX/SessionHandoff.cpp)
set(test_handover_transport_EXTRA_SOURCES Source/Platform/POSIX/HandoverTransport.cpp)
set(test_session_reclaim_EXTRA_SOURCES Source/Platform/POSIX/SessionHandoff.cpp)
foreach(_hooked_test test_atomic_storage_perms test_bytebuffer test_channel)
    set(${_hooked_test}_EXTRA_DEFINES UBIQUITTY_ENABLE_TEST_HOOKS=1)
endforeach()
set(test_channel_EXTRA_SOURCES Source/Core/Transport/PollChannel.cpp)
set(test_datagram_batch_EXTRA_SOURCES Source/Platform/POSIX/DatagramBatch.cpp)
# Named rather than taken from the aggregate: the coverage build instruments
# the sources a test target compiles, so a TU reached only through the
# library reports as having no coverage at all.
set(test_tool_invocation_EXTRA_SOURCES Source/Core/Clipboard/ToolInvocation.cpp)
set(test_clipboard_serve_EXTRA_SOURCES Source/Core/Session/ClipboardServe.cpp)
set(test_boundedsocketserver_EXTRA_DEFINES UBIQUITTY_ENABLE_TEST_HOOKS=1)
set(test_boundedsocketserver_EXTRA_SOURCES Source/Core/Session/BoundedSocketServer.cpp)
set(test_accessibility_palette_EXTRA_DEFINES UBIQUITTY_ENABLE_TEST_HOOKS=1)
# The seam lives in the implementation, so the define has to reach it: the
# archive's copy is compiled without hooks and carries no ForTest symbols.
set(test_accessibility_palette_EXTRA_SOURCES Source/Core/Accessibility/Palette.cpp)

# Exceptions. A test lands here only when it exercises a TU that
# Scripts/portable-core-sources.txt excludes — a platform backend or an optional
# codec the portable set does not carry — so the aggregate cannot supply it.
# The entries stay few on purpose. A list here that kept growing would say the
# portable source set is drawn in the wrong place, and the fix would belong in
# that set rather than in one more line below.
#
# Each of these needs a symbol the portable Core does not carry, and names the
# file that defines it; that link line is all the test lacks.
set(test_controlpaths_EXTRA_SOURCES    Source/Platform/Host/HostPaths.cpp)
set(test_attach_relay_EXTRA_SOURCES    Source/Platform/Host/AttachRelay.cpp)
set(test_handover_effects_EXTRA_SOURCES Source/Platform/Host/HandoverEffects.cpp)
set(test_handover_authority_tables_EXTRA_SOURCES Source/Platform/Host/HandoverAuthorityTables.cpp)
set(test_handover_global_tables_EXTRA_SOURCES Source/Platform/Host/HandoverGlobalTables.cpp)
set(test_handover_runtime_EXTRA_SOURCES Source/Platform/Host/HandoverRuntime.cpp)
set(test_handover_tables_EXTRA_SOURCES Source/Platform/Host/HandoverTables.cpp)
set(test_handover_workspace_tables_EXTRA_SOURCES Source/Platform/Host/HandoverWorkspaceTables.cpp)
# A private socket pair drives the real agent reader; no host process or user
# configuration participates in its request-lifetime tests.
set(test_agent_capture_EXTRA_SOURCES Source/Agent/AgentSession.cpp
                                    Source/Agent/RemoteCarrier.cpp
                                    Source/Platform/Host/HostPaths.cpp)
# The preferences backend is bundled now, so a target needing it names one file
# on every host rather than an Objective-C++ one here and a C++ one there — and
# no target needs Foundation for it any more.
set(test_themes_EXTRA_SOURCES          Source/Platform/POSIX/Preferences.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp)
# The typed pasteboard bridge is AppKit against a uniquely named pasteboard;
# the MIME fallback mapping consults the type database. The mapping is Swift, so
# the C++ seam beside the module is what the test compiles and the module below
# is what it links.
set(test_typed_pasteboard_EXTRA_SOURCES Source/Platform/macOS/TypedPasteboard.cpp)
if(APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    include(${CMAKE_SOURCE_DIR}/Scripts/cmake/TypedPasteboard.cmake)
endif()
set(test_typed_pasteboard_EXTRA_LIBS UbiquittyPasteboard)
# The three macOS PAL backends that need no window: the diagnostics sink, the
# bell and the clipboard's C++ half. None is Objective-C, so the target needs no
# .mm compiler. The test-hook define below reaches the bell, which counts each
# alert and silences its playback — the suite runs on a desk with speakers —
# and it keeps this target off the shared precompiled header, which is built
# without it.
set(test_macos_pal_EXTRA_SOURCES Source/Platform/macOS/Diag.cpp
                                 Source/Platform/macOS/Bell.cpp
                                 Source/Platform/macOS/Clipboard.cpp)
set(test_macos_pal_EXTRA_DEFINES UBIQUITTY_ENABLE_TEST_HOOKS=1)
set(test_macos_pal_EXTRA_LIBS "-framework AudioToolbox")
set(test_cfauto_EXTRA_LIBS "-framework CoreFoundation")
# The ImageIO decoder the macOS app installs, against PNGs the test deflates
# itself through the system zlib.
set(test_image_decode_EXTRA_SOURCES Source/Platform/Apple/ImageDecode.cpp)
set(test_image_decode_EXTRA_LIBS "-framework CoreFoundation" "-framework CoreGraphics" "-framework ImageIO" z)
# The daemon subset compiles HandoverAdmission.cpp, whose Apple half verifies a
# peer's code signature through Security and CoreFoundation.
if(APPLE)
    set(test_daemon_session_configuration_EXTRA_LIBS "-framework CoreFoundation" "-framework Security")
endif()
# These compile on this host — what they need is a link line, not a
# toolchain. Each names the file that defines the symbols its test calls; none
# of them needs GTK. The preferences backend is bundled, and this is the same
# file every other target here names.
set(test_preferences_backend_EXTRA_SOURCES    Source/Platform/POSIX/Preferences.cpp
                                              Source/Platform/POSIX/SystemPAL.cpp)
set(test_linux_updater_security_EXTRA_SOURCES Source/Platform/Linux/Updater.cpp)
set(test_linux_accessibility_EXTRA_SOURCES Source/Platform/Linux/Accessibility.cpp)
# The seam lives in the implementation, so the define has to reach it — the
# same shape as test_accessibility_palette above.
set(test_linux_updater_security_EXTRA_DEFINES UBIQUITTY_ENABLE_TEST_HOOKS=1)
# FontInventory includes <fontconfig/fontconfig.h>, which a developer Mac has
# through Homebrew but not on the default include path. Found rather than
# hardcoded — a Cellar version in a path would rot at the next upgrade — and an
# absent library defers the test with a reason instead of failing on a header
# error that names a path nobody set.
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
    pkg_check_modules(UBQ_FONTCONFIG QUIET fontconfig freetype2 harfbuzz)
    pkg_check_modules(UBQ_GIO QUIET IMPORTED_TARGET gio-2.0)
    pkg_check_modules(UBQ_PANGOCAIRO QUIET IMPORTED_TARGET pangocairo)
    pkg_check_modules(UBQ_GTK_ACCESSIBILITY QUIET IMPORTED_TARGET gtk4>=4.16)
endif()
if(UBQ_PANGOCAIRO_FOUND)
    set(test_linux_rich_text_EXTRA_SOURCES Source/Platform/Linux/PangoRichText.cpp)
    set(test_linux_rich_text_EXTRA_LIBS PkgConfig::UBQ_PANGOCAIRO)
endif()
find_program(UBQ_XVFB_RUN xvfb-run)
if(UBQ_GTK_ACCESSIBILITY_FOUND AND UBQ_XVFB_RUN)
    set(test_linux_accessible_terminal_EXTRA_SOURCES Source/Platform/Linux/AccessibleTerminal.cpp
                                                    Source/Platform/Linux/Accessibility.cpp)
    set(test_linux_accessible_terminal_EXTRA_LIBS PkgConfig::UBQ_GTK_ACCESSIBILITY)
endif()
if(UBQ_GIO_FOUND)
    set(test_linux_pty_watch_EXTRA_LIBS PkgConfig::UBQ_GIO)
    set(test_linux_configuration_watcher_EXTRA_SOURCES Source/Platform/Linux/ConfigurationWatcher.cpp
                                                       Source/Platform/POSIX/Preferences.cpp
                                                       Source/Platform/POSIX/SystemPAL.cpp)
    set(test_linux_configuration_watcher_EXTRA_LIBS PkgConfig::UBQ_GIO)
endif()
if(UBQ_FONTCONFIG_FOUND)
    set(test_linux_fontinventory_EXTRA_SOURCES    Source/Platform/Linux/FontInventory.cpp
                                                  Source/Platform/Linux/ColorGlyphPainter.cpp
                                                  Source/Platform/Linux/BundledFontDirectory.cpp)
    set(test_linux_fontinventory_EXTRA_INCLUDES   ${UBQ_FONTCONFIG_INCLUDE_DIRS})
    set(test_linux_fontinventory_EXTRA_LIBS       ${UBQ_FONTCONFIG_LINK_LIBRARIES})
    # The bundled fonts by absolute path: the inventory derives its directory
    # from the executable, and a test binary has no staged fonts beside it.
    set(test_linux_fontinventory_EXTRA_DEFINES
        UBQ_BUNDLED_FONTS_DIR="${CMAKE_SOURCE_DIR}/Resources/fonts")
    # The colour-emoji rasterizer needs the same two libraries: FreeType to read
    # a CBDT/sbix strike and fontconfig to find the font at all.
    set(test_linux_color_emoji_EXTRA_SOURCES  Source/Platform/Linux/FreeTypeRasterizer.cpp
                                              Source/Platform/Linux/FontInventory.cpp
                                              Source/Platform/Linux/BundledFontDirectory.cpp
                                              Source/Platform/Linux/ColorGlyphPainter.cpp
                                              Source/Core/Rendering/UnifontRasterizer.cpp
                                              Source/Core/Rendering/UnifontFaceMetrics.cpp
                                              Source/Core/Rendering/Unifont.cpp)
    set(test_linux_color_emoji_EXTRA_INCLUDES ${UBQ_FONTCONFIG_INCLUDE_DIRS})
    set(test_linux_color_emoji_EXTRA_LIBS     ${UBQ_FONTCONFIG_LINK_LIBRARIES})
    # The bundled fonts by absolute path, for the source-root reason above: a
    # rasteriser handed a relative fallback path derives the bundled emoji
    # face's path beside it, and a relative path resolves against nothing at
    # run time, so the host's own colour face was kept in the bundled one's place.
    set(test_linux_color_emoji_EXTRA_DEFINES
        UBQ_BUNDLED_FONTS_DIR="${CMAKE_SOURCE_DIR}/Resources/fonts")
    # Which file the fallback face opens: the same rasteriser, the same two
    # libraries, and the bundled directory by absolute path for the reason above
    # — the table lookup is derived beside the fallback path it is handed.
    set(test_linux_fallback_face_EXTRA_SOURCES  Source/Platform/Linux/FreeTypeRasterizer.cpp
                                                Source/Platform/Linux/FontInventory.cpp
                                                Source/Platform/Linux/BundledFontDirectory.cpp
                                                Source/Platform/Linux/ColorGlyphPainter.cpp
                                                Source/Core/Rendering/UnifontRasterizer.cpp
                                                Source/Core/Rendering/UnifontFaceMetrics.cpp
                                                Source/Core/Rendering/Unifont.cpp)
    set(test_linux_fallback_face_EXTRA_INCLUDES ${UBQ_FONTCONFIG_INCLUDE_DIRS})
    set(test_linux_fallback_face_EXTRA_LIBS     ${UBQ_FONTCONFIG_LINK_LIBRARIES})
    set(test_linux_fallback_face_EXTRA_DEFINES
        UBQ_BUNDLED_FONTS_DIR="${CMAKE_SOURCE_DIR}/Resources/fonts")
    # A doubled row drawn by the software renderer over the same rasteriser,
    # from the bundled faces by absolute path for the reason above.
    set(test_linux_sized_master_EXTRA_SOURCES  ${test_linux_fallback_face_EXTRA_SOURCES})
    set(test_linux_sized_master_EXTRA_INCLUDES ${UBQ_FONTCONFIG_INCLUDE_DIRS})
    set(test_linux_sized_master_EXTRA_LIBS     ${UBQ_FONTCONFIG_LINK_LIBRARIES})
    set(test_linux_sized_master_EXTRA_DEFINES
        UBQ_BUNDLED_FONTS_DIR="${CMAKE_SOURCE_DIR}/Resources/fonts")
    # A proportional run past its size held to FreeType's raster at that size,
    # over the same rasteriser and the bundled faces by absolute path.
    set(test_linux_proportional_at_size_EXTRA_SOURCES  ${test_linux_fallback_face_EXTRA_SOURCES})
    set(test_linux_proportional_at_size_EXTRA_INCLUDES ${UBQ_FONTCONFIG_INCLUDE_DIRS})
    set(test_linux_proportional_at_size_EXTRA_LIBS     ${UBQ_FONTCONFIG_LINK_LIBRARIES})
    set(test_linux_proportional_at_size_EXTRA_DEFINES
        UBQ_BUNDLED_FONTS_DIR="${CMAKE_SOURCE_DIR}/Resources/fonts")
    # The COLRv1 painter walks a paint graph FreeType exposes and finds its
    # face through fontconfig, so it needs the same pair.
    set(test_linux_color_glyph_painter_EXTRA_SOURCES  Source/Platform/Linux/ColorGlyphPainter.cpp)
    set(test_linux_color_glyph_painter_EXTRA_INCLUDES ${UBQ_FONTCONFIG_INCLUDE_DIRS})
    set(test_linux_color_glyph_painter_EXTRA_LIBS     ${UBQ_FONTCONFIG_LINK_LIBRARIES})
else()
    list(APPEND UBIQUITTY_UNAVAILABLE_TESTS test_linux_fontinventory test_linux_color_emoji test_linux_color_glyph_painter test_linux_fallback_face test_linux_sized_master test_linux_proportional_at_size)
    list(APPEND UBIQUITTY_DEFERRED_TESTS ${UBIQUITTY_UNAVAILABLE_TESTS})
endif()
set(test_pty_EXTRA_SOURCES             Source/Platform/POSIX/PTYStream.cpp
                                       Source/Platform/POSIX/PTYFacts.cpp)
set(test_appruntime_EXTRA_SOURCES      Source/Core/App/AppRuntime.cpp)
set(test_welcome_screen_EXTRA_SOURCES   Source/Core/App/WelcomeScreen.cpp)
set(test_shell_integration_install_EXTRA_SOURCES Source/Core/App/ShellIntegrationInstall.cpp)
# The gated kitty file read and its verified unlink live in Platform/POSIX so no
# single arm owns the hardening rules. The portable Core does not carry them, so
# each test over them names the TU.
set(test_macos_file_read_EXTRA_SOURCES Source/Platform/POSIX/GatedFileRead.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp)
set(test_gated_file_read_EXTRA_SOURCES Source/Platform/POSIX/GatedFileRead.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp)
# The fairness doorway spins on PAL::monotonicMicros and yields through
# PAL::schedulerYield, so this one needs the real clock: a fake that advances a
# microsecond per call turns the donation band into an iteration count.
set(test_drain_host_pacing_EXTRA_SOURCES Source/Platform/POSIX/SystemPAL.cpp)
# The libFuzzer harness, linked into an ordinary test so its corpus can be
# replayed. LLVMFuzzerTestOneInput is a plain function; only the driver needs
# -fsanitize=fuzzer, and the replay supplies its own driver by reading files.
set(test_sync_corpus_replay_EXTRA_SOURCES Tests/Core/Protocol/Sync/fuzz_sync.cpp)
# The absolute source root, which only this side still has: the compiler cache
# rewrites source paths on the command line so builds at different checkouts
# share one cache, and anything the test derives from __FILE__ goes relative
# with them.
set(test_sync_corpus_replay_EXTRA_DEFINES
    UBQ_SYNC_FUZZ_CORPUS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Core/Protocol/Sync/fuzz-corpus")
# The tmux Control Mode corpus, replayed the same way: fuzz_tmux.cpp is the
# harness, and the path is handed in for the same source-root reason as above.
set(test_tmux_corpus_replay_EXTRA_SOURCES Tests/Core/Protocol/Tmux/fuzz_tmux.cpp)
set(test_tmux_corpus_replay_EXTRA_DEFINES
    UBQ_TMUX_FUZZ_CORPUS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Core/Protocol/Tmux/fuzz-corpus")
# The RTF corpus, replayed through fuzz_richtext.cpp, which checks the
# document invariants on every body the reader accepts.
set(test_richtext_corpus_replay_EXTRA_SOURCES Tests/Core/RichText/fuzz_richtext.cpp)
set(test_richtext_corpus_replay_EXTRA_DEFINES
    UBQ_RICHTEXT_CORPUS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Corpus/richtext")
# The measurements the session layer's constants are read against.
set(test_sync_measured_policy_EXTRA_DEFINES
    UBQ_MEASUREMENTS_DOC="${CMAKE_SOURCE_DIR}/Docs/sync-measurements.md")
set(test_sync_memory_owner_EXTRA_DEFINES
    UBQ_MEASUREMENTS_DOC="${CMAKE_SOURCE_DIR}/Docs/sync-measurements.md")
# The Sync PTY corpus (Tests/Corpus/sync), read by Tests/SyncCorpus.h; the path
# is handed in for the same source-root reason as above.
set(test_sync_pty_corpus_EXTRA_DEFINES
    UBQ_SYNC_PTY_CORPUS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Corpus/sync")
set(test_sync_corpus_oracle_EXTRA_DEFINES
    UBQ_SYNC_PTY_CORPUS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Corpus/sync")
set(test_sync_corpus_EXTRA_DEFINES
    UBQ_SYNC_PTY_CORPUS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Corpus/sync")
set(test_sync_shaped_link_EXTRA_DEFINES
    UBQ_SYNC_PTY_CORPUS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Corpus/sync")
# The frozen handover pane record lives in the handover fuzzer's corpus.
set(test_sync_handover_body_EXTRA_DEFINES
    UBQ_HANDOVER_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Corpus/sync/fuzz_sync_handover")
set(test_sync_handover_resume_EXTRA_DEFINES
    UBQ_SYNC_PTY_CORPUS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Corpus/sync")
set(test_sync_connection_EXTRA_DEFINES
    UBQ_SYNC_PTY_CORPUS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Corpus/sync")
# The UAX #29 grapheme conformance corpus, vendored beside the test. UCD inputs
# for table generation are fetched per build-grapheme-tables.py rather than
# checked in; a test fixture is different in kind — one that must be present for
# the test to execute cannot be an optional download, or the check never runs.
# Same source-root reason as the sync corpus above: the compiler cache rewrites
# __FILE__, so the path is handed in by the build system.
set(test_grapheme_conformance_EXTRA_DEFINES
    GRAPHEME_BREAK_TEST_CORPUS="${CMAKE_CURRENT_SOURCE_DIR}/Core/Unicode/GraphemeBreakTest.txt")
# The UAX #9 bidi conformance corpus, on the same terms and for the same reason.
# It is 6.6 MB against the grapheme corpus's 124 KB, which is a real weight
# decision rather than a rounding error: vendored whole because a sampled
# conformance corpus invites "which cases did you drop", and a number nobody can
# reproduce from the tree is the kind of claim this suite exists to refuse. It
# changes once per Unicode version and compresses to ~0.4 MB in the object store.
set(test_bidi_conformance_EXTRA_DEFINES
    BIDI_CHARACTER_TEST_CORPUS="${CMAKE_CURRENT_SOURCE_DIR}/Core/Unicode/BidiCharacterTest.txt")
# The Emoji_Presentation authority (emoji-data.txt), vendored beside the test.
# build-unicode-tables.py emits that property from this same file, so the check
# holds the generated table against the authority — an emit bug or a version
# skew between the two surfaces here. Path handed in by the build, as above.
# build-grapheme-tables.py reads the same file for Extended_Pictographic, so
# the two generators want one UCD drop between them: a skew puts the width
# tables and the GB11 rule on different Unicode versions, which neither
# generator can see from its own side.
set(test_emoji_presentation_conformance_EXTRA_DEFINES
    EMOJI_DATA_FILE="${CMAKE_CURRENT_SOURCE_DIR}/Core/Unicode/emoji-data.txt")
# The web frontend's bridge. WebPAL comes along because the browser supplies the
# PAL the wasm build links; both compile natively (their emscripten calls are
# guarded), which is the point — the bridge is testable without a browser.
# The PAL clock conformance check links a frontend's PAL and asserts its clock
# runs at the rate PAL.h promises. Pointed at the web frontend's, whose clock
# converts the browser's milliseconds; any PAL that compiles natively can be
# swapped in here.
set(test_clock_conformance_EXTRA_SOURCES Source/Platform/Web/WebPAL.cpp)
# The determinism pin is one backend's, not a contract every PAL answers:
# UBIQUITTY_FAKE_TICKS exists in the macOS clock alone. Naming a source under
# Platform/Apple is also what keeps a Linux configure from building this one —
# the filter below drops any target whose extra sources live there, whatever
# their extension: Clock.cpp is C++ over mach/mach_time.h.
set(test_clock_pin_EXTRA_SOURCES       Source/Platform/Apple/Clock.cpp)

set(test_web_terminal_EXTRA_SOURCES    Source/Platform/Web/WebTerminal.cpp
                                       Source/Platform/Web/WebRichText.cpp
                                       Source/Platform/Web/WebFontRasterizer.cpp
                                       Source/Platform/Web/WebFontInventory.cpp
                                       Source/Platform/Web/WebPAL.cpp)
# The browser's FontInventory. Its coverage probes need a canvas, so natively
# they answer absent and the cases assert the bookkeeping — handle identity and
# generation invalidation — which is the half that does not need a font.
set(test_web_font_inventory_EXTRA_SOURCES Source/Platform/Web/WebFontInventory.cpp)
# The rasterizer's available arm, driven through the ForTest host seam: both
# TUs compile with the hooks so a stand-in text engine can answer the probes
# and the draws. The browser's own drawing is the wasm-snapshot and
# web-gpu-parity tiers' subject, not this binary's.
set(test_web_font_rasterizer_EXTRA_SOURCES Source/Platform/Web/WebFontRasterizer.cpp
                                           Source/Platform/Web/WebFontInventory.cpp)
set(test_web_font_rasterizer_EXTRA_DEFINES UBIQUITTY_ENABLE_TEST_HOOKS=1)
set(test_serial_EXTRA_SOURCES          Source/Platform/POSIX/SerialStream.cpp)
# PTYFacts carries gatherSubtree / firstChildProcess / stopProcessTracker, which
# PTYStream references and the portable Core does not define. Naming it here is
# what lets this test build as a CMake target instead of a shell stanza.
# The Terminal -> ModeSnapshot sampler, so the key seam can be exercised against
# a live Terminal — the overload the web, wscons and GTK arms call.
set(test_key_encode_EXTRA_SOURCES      Source/Core/Runtime/ModeSnapshot.cpp)
# A live TerminalSession, so it needs the PTY-backed stack the session tests
# use: the runtime, the PTY pair, and the PAL the clock and spawn resolve to.
set(test_palette_apply_EXTRA_SOURCES   Source/Core/Runtime/TerminalRuntime.cpp
                                       Source/Platform/POSIX/PTYStream.cpp
                                       Source/Platform/POSIX/PTYFacts.cpp
                                       Source/Platform/POSIX/Poll.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp
                                       Source/Platform/POSIX/ProcessSpawnAndWait.cpp
                                       Source/Platform/Host/HostPAL.cpp
                                       Source/Core/Session/ProcessSubtree.cpp)
# Stands a real TerminalSession, so it needs the same PTY-backed stack
# test_palette_apply does — including the PAL the session's clock resolves to,
# which the session reaches whether or not a case ever launches a shell.
set(test_attach_over_carrier_EXTRA_SOURCES Source/Core/Runtime/TerminalRuntime.cpp
                                       Source/Platform/POSIX/PTYStream.cpp
                                       Source/Platform/POSIX/PTYFacts.cpp
                                       Source/Platform/POSIX/Poll.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp
                                       Source/Platform/POSIX/ProcessSpawnAndWait.cpp
                                       Source/Platform/Host/HostPAL.cpp
                                       Source/Core/Session/ProcessSubtree.cpp)
# It drives a session's withdrawal of a held effect with no change of state
# after it, which only the test hooks reach.
set(test_attach_over_carrier_EXTRA_DEFINES UBIQUITTY_ENABLE_TEST_HOOKS=1)
# The directory client's test doors are compiled only under the hook, so the
# target that drives them owns that translation unit as it owns the runtime's.
set(test_runtime_EXTRA_SOURCES         Source/Core/Runtime/TerminalRuntime.cpp
                                       Source/Core/Runtime/HostDirectoryClient.cpp
                                       Source/Platform/POSIX/PTYStream.cpp
                                       Source/Platform/POSIX/PTYFacts.cpp
                                       Source/Core/Session/ProcessSubtree.cpp)
set(test_ios_quic_factory_EXTRA_SOURCES ${test_attach_over_carrier_EXTRA_SOURCES}
                                       Source/Platform/iOS/SessionBridge.cpp)
set(test_ios_quic_factory_EXTRA_LIBS ubiquitty-kit)
set(test_ios_control_client_EXTRA_SOURCES ${test_attach_over_carrier_EXTRA_SOURCES}
                                       Source/Platform/iOS/SessionBridge.cpp)
set(test_ios_control_client_EXTRA_LIBS ubiquitty-kit "-framework CoreFoundation")
if(APPLE AND UBIQUITTY_QUIC)
    ubiquitty_ensure_quic_deps()
    list(APPEND test_ios_quic_factory_EXTRA_SOURCES
        Source/Core/Transport/QUICChannel.cpp
        Source/Platform/POSIX/QUICClient.cpp
        Source/Platform/POSIX/DatagramBatch.cpp)
    set(test_ios_quic_factory_EXTRA_DEFINES UBIQUITTY_QUIC=1)
    set(test_ios_quic_factory_EXTRA_INCLUDES "${UBIQUITTY_QUIC_PREFIX}/include")
    list(APPEND test_ios_quic_factory_EXTRA_LIBS
        "${UBIQUITTY_QUIC_PREFIX}/lib/libngtcp2_crypto_boringssl.a"
        "${UBIQUITTY_QUIC_PREFIX}/lib/libngtcp2.a"
        "${UBIQUITTY_QUIC_PREFIX}/lib/libssl.a"
        "${UBIQUITTY_QUIC_PREFIX}/lib/libcrypto.a")
endif()
# The copy/capture counters are compiled out of the shared Core archives. These
# targets own their implementation translation unit so the test-hook layout and
# the code updating it are built under the same definition.
set(test_runtime_EXTRA_DEFINES         UBIQUITTY_ENABLE_TEST_HOOKS=1)
# A TerminalSession reaches the PAL for its clock whether or not a case ever
# launches a shell, so this carries what test_attach_over_carrier carries.
set(test_window_request_queue_EXTRA_SOURCES Source/Core/Runtime/TerminalRuntime.cpp
                                       Source/Platform/POSIX/PTYStream.cpp
                                       Source/Platform/POSIX/PTYFacts.cpp
                                       Source/Platform/POSIX/Poll.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp
                                       Source/Platform/POSIX/ProcessSpawnAndWait.cpp
                                       Source/Platform/Host/HostPAL.cpp
                                       Source/Core/Session/ProcessSubtree.cpp)
set(test_session_key_modes_EXTRA_SOURCES ${test_window_request_queue_EXTRA_SOURCES})
# The in-process link is a real TerminalSession's, so it links the same set.
set(test_pane_link_conformance_EXTRA_SOURCES ${test_window_request_queue_EXTRA_SOURCES})
# The notification sink stands the same real TerminalSession the window-request
# queue does, so it links the same PTY-backed PAL set.
set(test_notification_sink_EXTRA_SOURCES ${test_window_request_queue_EXTRA_SOURCES})
# The trigger queue stands the same real TerminalSession, for the same reason.
set(test_trigger_effects_EXTRA_SOURCES ${test_window_request_queue_EXTRA_SOURCES})
# A share hands a live shell's PTY over and resumes it, so it stands the same
# real TerminalSession over a real PTY.
set(test_session_share_reclaim_EXTRA_SOURCES ${test_window_request_queue_EXTRA_SOURCES})
set(test_terminal_frame_inputs_EXTRA_SOURCES Source/Core/Rendering/TerminalFrameInputs.cpp)
set(test_linux_raster_context_EXTRA_SOURCES Source/Platform/Linux/Raster.cpp)
set(test_terminal_frame_inputs_EXTRA_DEFINES UBIQUITTY_ENABLE_TEST_HOOKS=1)
# The rewrap's copy count, so the scaling case reads work rather than time.
set(test_reflow_scaling_EXTRA_SOURCES Source/Core/Screen/Reflow.cpp)
set(test_reflow_scaling_EXTRA_DEFINES UBIQUITTY_ENABLE_TEST_HOOKS=1)
set(test_frame_copy_statistics_disabled_EXTRA_SOURCES Source/Core/Rendering/TerminalFrameInputs.cpp)
set(test_frame_copy_statistics_disabled_EXTRA_DEFINES UBIQUITTY_PERF_DIAG=0)
# The ingest loop runs over a real PTY with the real clock, poll and waker —
# the daemon's PAL set, which is the same "portable POSIX, no GUI" shape.
set(test_ingest_loop_EXTRA_SOURCES     Source/Platform/POSIX/PTYStream.cpp
                                       Source/Platform/POSIX/PTYFacts.cpp
                                       Source/Platform/POSIX/Poll.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp
                                       Source/Platform/Host/HostPAL.cpp
                                       Source/Core/Session/ProcessSubtree.cpp)
# The settings fan-out runs against a started session, and a session is the
# runtime whether or not the case opens a PTY: the same PAL set has to link.
set(test_apply_terminal_preferences_EXTRA_SOURCES
                                       Source/Platform/POSIX/PTYStream.cpp
                                       Source/Platform/POSIX/PTYFacts.cpp
                                       Source/Platform/POSIX/Poll.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp
                                       Source/Platform/Host/HostPAL.cpp
                                       Source/Core/Session/ProcessSubtree.cpp)
# The workspace model launches real pane sessions, so it needs the same
# PTY-backed stack the ingest-loop test does.
set(test_workspace_clients_EXTRA_SOURCES Source/Platform/POSIX/PTYStream.cpp
                                       Source/Platform/POSIX/PTYFacts.cpp
                                       Source/Platform/POSIX/Poll.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp
                                       Source/Platform/Host/HostPAL.cpp
                                       Source/Core/Session/ProcessSubtree.cpp)
# The iOS shell's pane clients are portable C++ over Core and PAL, so an Apple
# host runs the installer the phone links, over real sessions on the same stack
# as the workspace-clients test. The platform filter keeps other hosts from
# building it.
set(test_ios_session_clients_EXTRA_SOURCES ${test_workspace_clients_EXTRA_SOURCES}
                                       Source/Platform/iOS/SessionClients.cpp)
# Two models launch real pane sessions under two configurations, so it needs
# the same PTY-backed stack the workspace-clients test does.
# Three sessions in one model launch real children and answer for their own
# lifetimes, over the same PTY-backed stack.
set(test_session_exit_lifetime_EXTRA_SOURCES Source/Platform/POSIX/PTYStream.cpp
                                       Source/Platform/POSIX/PTYFacts.cpp
                                       Source/Platform/POSIX/Poll.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp
                                       Source/Platform/Host/HostPAL.cpp
                                       Source/Core/Session/ProcessSubtree.cpp)
# A launched pane's child reports the context it was given, over the same
# PTY-backed stack; PTYStream.cpp is where an inherited context is dropped.
set(test_launch_context_EXTRA_SOURCES Source/Platform/POSIX/PTYStream.cpp
                                       Source/Platform/POSIX/PTYFacts.cpp
                                       Source/Platform/POSIX/Poll.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp
                                       Source/Platform/Host/HostPAL.cpp
                                       Source/Core/Session/ProcessSubtree.cpp)
set(test_session_configuration_EXTRA_SOURCES Source/Platform/POSIX/PTYStream.cpp
                                       Source/Platform/POSIX/PTYFacts.cpp
                                       Source/Platform/POSIX/Poll.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp
                                       Source/Platform/Host/HostPAL.cpp
                                       Source/Core/Session/ProcessSubtree.cpp)
# A split window's captured layout is measured from its panes' live sessions,
# so the case launches them over the same PTY-backed stack.
set(test_workspace_layout_capture_EXTRA_SOURCES Source/Platform/POSIX/PTYStream.cpp
                                       Source/Platform/POSIX/PTYFacts.cpp
                                       Source/Platform/POSIX/Poll.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp
                                       Source/Platform/Host/HostPAL.cpp
                                       Source/Core/Session/ProcessSubtree.cpp)
# The daemon creates real PTY sessions, so it links the host daemon's own
# objects over the same PTY-backed stack.
set(test_daemon_session_configuration_EXTRA_SOURCES
                                       Source/Platform/Host/Daemon.cpp
                                       Source/Platform/Host/HandoverAdmission.cpp
                                       # The reactor routes a successor's first record into the
                                       # handover transaction, which reaches every carried owner.
                                       Source/Platform/Host/HandoverStartup.cpp
                                       Source/Platform/Host/HandoverRequest.cpp
                                       Source/Platform/Host/HostHandover.cpp
                                       Source/Platform/Host/HostTableHandover.cpp
                                       Source/Platform/Host/HandoverTables.cpp
                                       Source/Platform/Host/HandoverWorkspaceTables.cpp
                                       Source/Platform/Host/HandoverAuthorityTables.cpp
                                       Source/Platform/Host/HandoverGlobalTables.cpp
                                       Source/Platform/Host/HandoverEffects.cpp
                                       Source/Platform/Host/HandoverRuntime.cpp
                                       Source/Platform/Host/SessionHandover.cpp
                                       Source/Platform/Host/SessionHandoverFacts.cpp
                                       Source/Platform/POSIX/HandoverLease.cpp
                                       Source/Platform/POSIX/HandoverTransport.cpp
                                       Source/Platform/Host/ClipboardTool.cpp
                                       Source/Platform/Host/HostPaths.cpp
                                       Source/Platform/Host/HostPAL.cpp
                                       Source/Platform/POSIX/PTYStream.cpp
                                       Source/Platform/POSIX/PTYFacts.cpp
                                       Source/Platform/POSIX/Poll.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp
                                       Source/Platform/POSIX/SessionHandoff.cpp
                                       Source/Core/Session/ProcessSubtree.cpp)
# The socket tests drive the daemon's receive loop without launching a shell.
set(test_daemon_client_io_EXTRA_SOURCES ${test_daemon_session_configuration_EXTRA_SOURCES})
set(test_daemon_scrollback_maintenance_EXTRA_SOURCES ${test_daemon_session_configuration_EXTRA_SOURCES})
set(test_daemon_input_withdrawal_EXTRA_SOURCES ${test_daemon_session_configuration_EXTRA_SOURCES})
set(test_daemon_client_io_EXTRA_LIBS ${test_daemon_session_configuration_EXTRA_LIBS})
set(test_daemon_scrollback_maintenance_EXTRA_LIBS ${test_daemon_session_configuration_EXTRA_LIBS})
set(test_daemon_input_withdrawal_EXTRA_LIBS ${test_daemon_session_configuration_EXTRA_LIBS})
# The Core rules a daemon session installs, driven through the daemon's own
# pass; the coherence cases replay the Sync PTY corpus.
set(test_daemon_core_rules_EXTRA_SOURCES ${test_daemon_session_configuration_EXTRA_SOURCES})
# A hosted pane's measure in its clients' faces, through the daemon's pass.
set(test_proportional_measure_attached_EXTRA_SOURCES ${test_daemon_session_configuration_EXTRA_SOURCES})
set(test_proportional_measure_attached_EXTRA_LIBS ${test_daemon_session_configuration_EXTRA_LIBS})
set(test_daemon_core_rules_EXTRA_LIBS ${test_daemon_session_configuration_EXTRA_LIBS})
set(test_daemon_core_rules_EXTRA_DEFINES
    UBQ_SYNC_PTY_CORPUS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Corpus/sync")
# The clipboard helpers are installed by the daemon's own ClipboardTool TU.
set(test_clipboard_tool_environment_EXTRA_SOURCES ${test_daemon_session_configuration_EXTRA_SOURCES})
set(test_clipboard_tool_environment_EXTRA_LIBS ${test_daemon_session_configuration_EXTRA_LIBS})
# Codec::JSON calls the vendored yyjson TU. It is a member of the aggregate
# beside the codec (ubiquitty-core-model), so a target that reaches JSON
# through Core links the parser and one that does not links neither; the two
# targets below name it because they compile the codec themselves.
# The rows the web page's renderer is tested against (Tests/Web/outline-rows.mjs)
# are the ones Core spells, held to it here; the path is handed in because
# anything derived from __FILE__ goes relative under the compiler cache.
set(test_session_outline_text_EXTRA_DEFINES
    UBQ_OUTLINE_ROWS_FIXTURE="${CMAKE_CURRENT_SOURCE_DIR}/Web/outline-rows.json")
set(test_json_depth_EXTRA_SOURCES      Source/Core/Codec/JSON.cpp
                                       Source/ThirdParty/yyjson/yyjson.c)
set(test_json_EXTRA_SOURCES            Source/Core/Codec/JSON.cpp
                                       Source/ThirdParty/yyjson/yyjson.c)
set(test_json_EXTRA_DEFINES            UBIQUITTY_ENABLE_TEST_HOOKS=1)
# The vectorised decoder is compiled only into the macOS app, so a parity target
# built the ordinary way has one path and compares it with itself. The define and
# the two sources are what give this target a second arm.
set(test_utf8_simd_parity_EXTRA_DEFINES UBIQUITTY_ENABLE_TEST_HOOKS=1)
set(test_utf8_simd_parity_EXTRA_SOURCES Source/Core/Unicode/UTF8Decoder.cpp
                                        Source/ThirdParty/simdutf/simdutf.cpp)
set(test_utf8_simd_parity_EXTRA_INCLUDES ${CMAKE_SOURCE_DIR}/Source/ThirdParty/simdutf)
# Same suppression the agent target gives it: a vendored TU must not fail the
# build on a compiler bump under -Werror, and -std=c99 keeps the C++ options off
# a C source.
# SKIP_PRECOMPILE_HEADERS keeps the shared C++ precompiled header off this C
# translation unit; a target mixing the two cannot resolve one PCH for both.
# The vendored UTF-8 library under the same policy: a newer clang's opinion of
# an unused static in a file this tree does not own (utf16_length_from_utf8 on
# a newer Linux clang) must not fail the parity test's build under -Werror.
set_source_files_properties(${CMAKE_SOURCE_DIR}/Source/ThirdParty/simdutf/simdutf.cpp
    PROPERTIES COMPILE_OPTIONS "-Wno-error;-w")
set_source_files_properties(${CMAKE_SOURCE_DIR}/Source/ThirdParty/yyjson/yyjson.c
    PROPERTIES COMPILE_FLAGS "-std=c99 -Wno-error -w"
               SKIP_PRECOMPILE_HEADERS ON)

# A test of a layer built on top of the aggregate links that layer by name.
set(test_kit_session_EXTRA_LIBS ubiquitty-kit)

# Directories whose tests are left to Scripts/run-tests.sh as a whole. Empty:
# every test target gets the real source root, so the tests under
# Tests/Platform, Host, Linux and Agent build against the Core aggregate even
# though Platform/<Frontend>/*.h stages into no layer. A test that needs a
# symbol only a frontend supplies is deferred by name below.
set(UBIQUITTY_FRONTEND_TEST_DIRS)
# Individually deferred — each needs a symbol only a frontend or an external dep
# supplies, so it cannot link in a Core-only configure. Not skipped because they
# are broken; skipped because the portable Core carries no frontend and no
# platform backend, which is where each one's missing symbol lives. They stay in
# Scripts/run-tests.sh until the frontends get the same treatment.
#
# Named individually with the reason beside the name, rather than by directory:
# skipping whole directories hid 12 tests that build fine. The reason travels
# WITH the entry so removing one removes both — a list where they are separated
# leaves a paragraph explaining an entry no one can find.
list(APPEND UBIQUITTY_DEFERRED_TESTS
    # SwiftBridge's clipboard resolver is defined in
    # Source/Platform/macOS/App/UBClipboardReadInterop.cpp, a macOS frontend
    # file a Core-only configure does not compile.
    test_clipboard_read_resolver
    # configureFontRouting is defined in Platform/Linux/main.cpp, which
    # carries the GTK entry point and cannot link into a test.
    test_linux_route_parity
    # SerialStream is a POSIX backend (Source/Platform/POSIX/SerialStream.cpp),
    # and it sits behind PAL::OutputQueue: a Core-only configure links neither.
    test_serial)

# Both this directory and every directory under it. `*/test_*.cpp` requires a
# subdirectory, so a test written beside this file is picked up by neither
# driver: not here, and not by run-tests.sh, whose skip list is generated from
# what this glob found. It would report nothing and be counted by no one.
set(_ubq_test_patterns
    "${CMAKE_CURRENT_SOURCE_DIR}/test_*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/*/test_*.cpp")
file(GLOB_RECURSE UBIQUITTY_TEST_SOURCES CONFIGURE_DEPENDS ${_ubq_test_patterns})
# The iOS protected-file suite links Swift (the creator and its protection
# probe) and runs inside a simulator; Scripts/run-ios-protected-file-tests.sh
# builds it, and no host can.
list(FILTER UBIQUITTY_TEST_SOURCES EXCLUDE REGEX "/test_ios_protected_file\\.cpp$")
if(NOT UBQ_PANGOCAIRO_FOUND)
    list(FILTER UBIQUITTY_TEST_SOURCES EXCLUDE REGEX "/test_linux_rich_text\\.cpp$")
    message(STATUS "Linux rich text test requires PangoCairo")
endif()
# The configuration watcher is the Linux frontend's, over inotify. A GLib
# found elsewhere watches through another backend: on macOS its kqueue monitor
# reports no in-place write to a file an atomic rename replaced, which no
# shipped build depends on, and the case fails there on every run for it.
if(NOT UBQ_GIO_FOUND OR NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    list(FILTER UBIQUITTY_TEST_SOURCES EXCLUDE REGEX "/test_linux_configuration_watcher\\.cpp$")
endif()
if(NOT UBQ_GIO_FOUND)
    list(FILTER UBIQUITTY_TEST_SOURCES EXCLUDE REGEX "/test_linux_pty_watch\\.cpp$")
endif()

if(NOT UBQ_GTK_ACCESSIBILITY_FOUND OR NOT UBQ_XVFB_RUN)
    list(FILTER UBIQUITTY_TEST_SOURCES EXCLUDE REGEX "/test_linux_accessible_terminal\\.cpp$")
    message(STATUS "Linux accessible widget test requires GTK 4.16 and xvfb-run")
endif()

# Tests whose single-process runtime sets the suite's wall clock. The binary
# must accept `--shard I/N` and partition its own outermost dimension; the swept
# space is unchanged, only the process count. Sharding a test that finishes in
# milliseconds costs more in process startup than it saves.
set(test_keymap_exhaustive_SHARDS 8)

# One precompiled header, built once and shared by every ordinary test through
# REUSE_FROM. A per-target precompiled header builds separately for each test
# target and costs more than it saves.
#
# Two exclusions are mandatory, and the registration loop below enforces both:
#
#   Boundary tests assert that a header compiles against a restricted dependency
#   set. A force-included precompiled header supplies that set from outside the
#   header under test, so the assertion passes for a header that no longer
#   stands alone.
#
#   EXTRA_DEFINES change the preprocessor state the precompiled header was built
#   under, and clang rejects one whose flags don't match its consumer.
#
# Only stable, widely included headers belong here. Every ordinary test parses
# this set whether or not it includes these headers, so a change to any one of
# them invalidates the precompiled header for the whole suite.
#
# That force-include is also why -DUBIQUITTY_TEST_PCH=OFF must keep working and
# must stay in CI. A test that drops an #include it still depends on compiles
# clean here and fails there, so the OFF configuration is what proves every
# test's include list stands on its own.
#   Tests that declare a name the precompiled header also declares. Each of
#   these defines its own Row, Cell or Pen and never included the Core header
#   that declares the same name, so force-including it makes the name ambiguous.
set(UBIQUITTY_NO_PCH_TESTS
    test_filetransfer test_linkrun test_pastenormalize
    test_scroll_lane_differential test_sgr_combined_parity
    test_terminalimage_widen test_title_walk_pacing
    test_unifont_sizing test_width)
# GIO enables POSIX thread support; its consumers cannot reuse a PCH built
# without the dependency's compiler options.
list(APPEND UBIQUITTY_NO_PCH_TESTS test_linux_configuration_watcher test_linux_pty_watch test_linux_accessible_terminal test_linux_rich_text)

option(UBIQUITTY_TEST_PCH "Share one precompiled header across the test targets" ON)

if(UBIQUITTY_TEST_PCH)
add_library(ubiquitty-test-pch OBJECT ${CMAKE_CURRENT_SOURCE_DIR}/PCHCarrier.cpp)
target_link_libraries(ubiquitty-test-pch PRIVATE ubiquitty-core)
target_include_directories(ubiquitty-test-pch PRIVATE
    ${CMAKE_SOURCE_DIR}/Source
    ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(ubiquitty-test-pch PRIVATE cxx_std_23)
target_compile_options(ubiquitty-test-pch PRIVATE
    -Wall -Wextra -Werror -Wno-deprecated-declarations -Wno-multichar -Wno-comment)
target_precompile_headers(ubiquitty-test-pch PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/Harness.h
    ${CMAKE_SOURCE_DIR}/Source/Core/TerminalOperations.h
    ${CMAKE_SOURCE_DIR}/Source/Core/CellGrid.h)
# A compiler or standard library upgraded in place keeps its paths and takes
# its package's build time, which can be older than the precompiled header, so
# nothing rebuilt the header and every test refused it: g++ as "created by a
# different GCC executable", clang as a standard header "modified since the
# precompiled header was built". The source the header is compiled from depends
# on a stamp naming the toolchain, rewritten only when the toolchain changes,
# so an upgrade rebuilds the header. It is a dependency rather than a header in
# the list: CMake keeps cmake_pch.hxx's time when the list changes, so a new
# entry would leave every existing tree's header stale.
set(_ubq_test_pch_toolchain ${CMAKE_CURRENT_BINARY_DIR}/test-pch-toolchain.stamp)
add_custom_target(ubiquitty-test-pch-toolchain
    COMMAND ${CMAKE_COMMAND} -DCOMPILER=${CMAKE_CXX_COMPILER} -DSTAMP=${_ubq_test_pch_toolchain}
        -P ${CMAKE_SOURCE_DIR}/Scripts/cmake/CompilerIdentity.cmake
    BYPRODUCTS ${_ubq_test_pch_toolchain}
    VERBATIM)
add_dependencies(ubiquitty-test-pch ubiquitty-test-pch-toolchain)
set_source_files_properties(${CMAKE_CURRENT_BINARY_DIR}/CMakeFiles/ubiquitty-test-pch.dir/cmake_pch.hxx.cxx
    PROPERTIES OBJECT_DEPENDS ${_ubq_test_pch_toolchain})
# g++ builds the precompiled header past ccache. A .gch the cache restored has
# made a clean tree redefine every type the header holds, and rebuilding it
# uncached cleared that. Moving any header it holds already makes ccache miss
# this compile, so the cache saves nothing here.
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    set_target_properties(ubiquitty-test-pch PROPERTIES CXX_COMPILER_LAUNCHER "")
endif()
endif()

# What the loop below records: how many tests it left out of CTest, the name of
# each one it registered, and every ctest entry those names expand to.
set(_ubq_deferred 0)
set(_ubq_registered_names "")
set(_ubq_ctest_entries "")
# These tests own real Apple framework objects and run on the desktop host.
if(NOT APPLE OR NOT CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    list(FILTER UBIQUITTY_TEST_SOURCES EXCLUDE REGEX "/Platform/Apple/test_(cfauto|image_decode)\\.cpp$")
endif()
# A test named for the platform it exercises compiles only there: these reach
# Apple framework headers directly, and discovery is by glob, so the filter is
# what keeps a Linux configure from building them.
if(NOT APPLE)
    list(FILTER UBIQUITTY_TEST_SOURCES EXCLUDE REGEX "/test_macos_[^/]*\\.(cpp|mm)$")
    # A target whose extra sources include Objective-C++ needs a compiler this
    # host does not have, whatever the test is called. The filter above keys on
    # the file NAME, so test_themes — named for a portable subject, linking
    # Preferences.mm — walked past it and failed the whole configure at
    # `cannot execute 'cc1objplus'`, taking every other test with it.
    set(_ubq_survivors "")
    foreach(_candidate IN LISTS UBIQUITTY_TEST_SOURCES)
        get_filename_component(_candidate_name ${_candidate} NAME_WE)
        set(_candidate_extra "${${_candidate_name}_EXTRA_SOURCES}")
        # A source under an Apple platform directory reaches Apple's SDK
        # whatever its extension: Platform/Apple/Clock.cpp is C++ over
        # mach/mach_time.h, and the extension alone let test_clock_pin through
        # to `'mach/mach_time.h' file not found` on every Linux suite job.
        if(_candidate_extra MATCHES "\\.mm(;|$)"
                OR _candidate_extra MATCHES "(^|;)Source/Platform/(Apple|macOS|iOS)/")
            continue()
        endif()
        list(APPEND _ubq_survivors ${_candidate})
    endforeach()
    set(UBIQUITTY_TEST_SOURCES ${_ubq_survivors})
endif()

# The libFuzzer harnesses, driven over a fixed corpus by Tests/FuzzDriver.cpp.
#
# They are outside the glob above, which takes `test_*.cpp`, so the only entry
# reaching them is shell_fuzz_harnesses_compile — syntax-only by its own header.
# A harness therefore compiled and never ran, and the assertions inside one had
# never been evaluated: fuzz_sync carries sixteen, added to make it an oracle.
#
# Core only. Tests/Host/fuzz_quic_preamble.cpp needs the QUIC stack, which is a
# fetched dependency and off by default — it stays compile-checked, where the
# twelve here become ctest entries that run in milliseconds.
file(GLOB_RECURSE UBIQUITTY_FUZZ_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/Core/fuzz_*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/Core/*/fuzz_*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/Core/*/*/fuzz_*.cpp")
foreach(_fuzz_source IN LISTS UBIQUITTY_FUZZ_SOURCES)
    get_filename_component(_fuzz_name ${_fuzz_source} NAME_WE)
    set(${_fuzz_name}_EXTRA_SOURCES Tests/FuzzDriver.cpp)
endforeach()
# fuzz_sync_screen, fuzz_sync_connection, fuzz_sync_catalog and fuzz_resume_record reach the model only through the Sync
# codec, so nothing either links pulls the POSIX PAL out of ubiquitty-core
# before the model archive is scanned, and the model's own PAL calls (OSC 7's host name) stay undefined
# under a linker that scans each archive once. The backend is named directly.
list(APPEND fuzz_sync_screen_EXTRA_SOURCES Source/Platform/POSIX/SystemPAL.cpp)
list(APPEND fuzz_sync_connection_EXTRA_SOURCES Source/Platform/POSIX/SystemPAL.cpp)
list(APPEND fuzz_sync_catalog_EXTRA_SOURCES Source/Platform/POSIX/SystemPAL.cpp)
list(APPEND fuzz_resume_record_EXTRA_SOURCES Source/Platform/POSIX/SystemPAL.cpp)
list(APPEND UBIQUITTY_TEST_SOURCES ${UBIQUITTY_FUZZ_SOURCES})

foreach(_test_source IN LISTS UBIQUITTY_TEST_SOURCES)
    get_filename_component(_test_name ${_test_source} NAME_WE)

    if(_test_name IN_LIST UBIQUITTY_UNAVAILABLE_TESTS)
        math(EXPR _ubq_deferred "${_ubq_deferred} + 1")
        message(STATUS "Ubiquitty tests: ${_test_name} unavailable (fontconfig, freetype2, and harfbuzz are required)")
        continue()
    endif()

    # A test deferred by name, or one under a frontend's directory, needs
    # something only a frontend supplies; that layer stages nowhere by design.
    file(RELATIVE_PATH _test_relative ${CMAKE_CURRENT_SOURCE_DIR} ${_test_source})
    string(REGEX MATCH "^[^/]*" _subsystem "${_test_relative}")
    if(_test_name IN_LIST UBIQUITTY_DEFERRED_TESTS OR _subsystem IN_LIST UBIQUITTY_FRONTEND_TEST_DIRS)
        math(EXPR _ubq_deferred "${_ubq_deferred} + 1")
        # A deferred test cannot LINK here — that is why it is deferred — but it
        # can compile, and compiling is what catches a change to it. Without
        # this, a deferred test is built by nothing until the shell driver
        # reaches it, and the shell driver stops at the first failure, so one
        # broken file hides the rest. An OBJECT library compiles and never
        # links, which is exactly the check a deferred test can take.
        add_library(ubq-deferred-${_test_name} OBJECT ${_test_source})
        target_include_directories(ubq-deferred-${_test_name} PRIVATE
            ${CMAKE_SOURCE_DIR}/Source
            ${CMAKE_CURRENT_SOURCE_DIR})
        target_compile_features(ubq-deferred-${_test_name} PRIVATE cxx_std_23)
        target_compile_options(ubq-deferred-${_test_name} PRIVATE
            -Wall -Wextra -Werror -Wno-deprecated-declarations -Wno-multichar -Wno-comment)
        continue()
    endif()

    # <test>_EXTRA_SOURCES is written from the repository root and the target
    # takes absolute paths. The same pass notes any Objective-C++ source, which
    # keeps the target off the shared precompiled header further down.
    set(_extra_abs "")
    set(_test_has_objcxx OFF)
    foreach(_extra_source IN LISTS ${_test_name}_EXTRA_SOURCES)
        list(APPEND _extra_abs ${CMAKE_SOURCE_DIR}/${_extra_source})
        if(_extra_source MATCHES "\\.mm$")
            set(_test_has_objcxx ON)
        endif()
    endforeach()

    add_executable(${_test_name} ${_test_source} ${_extra_abs})

    # Every test reads the source root and Tests/. A boundary test gets nothing
    # more, neither the Core library nor a layer stage, so the header it covers
    # has to compile from its own includes; its link line is the assertion.
    target_include_directories(${_test_name} PRIVATE
        ${CMAKE_SOURCE_DIR}/Source
        ${CMAKE_CURRENT_SOURCE_DIR})
    if(_test_name IN_LIST UBIQUITTY_BOUNDARY_TESTS)
        # The harness's Preferences pin names Core symbols, and with no Core to
        # link they would be undefined, so this define compiles the pin out.
        target_compile_definitions(${_test_name} PRIVATE UBIQUITTY_TEST_WITHOUT_CORE)
    else()
        target_link_libraries(${_test_name} PRIVATE ubiquitty-core ${${_test_name}_EXTRA_LIBS})
    endif()

    if(DEFINED ${_test_name}_EXTRA_DEFINES)
        target_compile_definitions(${_test_name} PRIVATE ${${_test_name}_EXTRA_DEFINES})
    endif()

    # A target pulling in a vendored source needs that vendor's header root, which
    # the layer includes above do not carry.
    if(DEFINED ${_test_name}_EXTRA_INCLUDES)
        target_include_directories(${_test_name} PRIVATE ${${_test_name}_EXTRA_INCLUDES})
    endif()

    # See the ubiquitty-test-pch block above for why these are excluded.
    # A target carrying Objective-C++ cannot reuse it either: the shared header is
    # precompiled with Objective-C disabled, and clang rejects a .mm compiled
    # against it — "Objective-C was disabled in precompiled file". Detected from
    # the sources where they are resolved above rather than listed, so a test
    # that gains a .mm later opts out by having one.
    if(UBIQUITTY_TEST_PCH
            AND NOT _test_has_objcxx
            AND NOT _test_name IN_LIST UBIQUITTY_BOUNDARY_TESTS
            AND NOT _test_name IN_LIST UBIQUITTY_NO_PCH_TESTS
            AND NOT DEFINED ${_test_name}_EXTRA_DEFINES)
        target_precompile_headers(${_test_name} REUSE_FROM ubiquitty-test-pch)
    endif()

    # Required here on each test rather than inherited: a boundary test links no
    # Core target that could carry the language standard to it.
    target_compile_features(${_test_name} PRIVATE cxx_std_23)
    target_compile_options(${_test_name} PRIVATE
        "$<$<COMPILE_LANGUAGE:CXX>:-Wall;-Wextra;-Werror;-Wno-deprecated-declarations;-Wno-multichar;-Wno-comment>")
    # A sharded test registers N ctest entries over one binary, so ctest can run
    # the partitions concurrently. ctest-covered.txt still gets the BASE name:
    # that file is matched against run-tests.sh stanza names, which do not shard.
    if(DEFINED ${_test_name}_SHARDS)
        math(EXPR _last_shard "${${_test_name}_SHARDS} - 1")
        foreach(_shard RANGE ${_last_shard})
            add_test(NAME ${_test_name}.${_shard}
                COMMAND ${_test_name} --shard ${_shard}/${${_test_name}_SHARDS})
            list(APPEND _ubq_ctest_entries ${_test_name}.${_shard})
        endforeach()
    else()
        if(_test_name STREQUAL "test_linux_accessible_terminal")
            add_test(NAME ${_test_name} COMMAND ${CMAKE_COMMAND} -E env GDK_BACKEND=x11 ${UBQ_XVFB_RUN} -a $<TARGET_FILE:${_test_name}>)
        else()
            add_test(NAME ${_test_name} COMMAND ${_test_name})
        endif()
        list(APPEND _ubq_ctest_entries ${_test_name})
    endif()
    list(APPEND _ubq_registered_names ${_test_name})
endforeach()
# Counted here, before the shell stanzas further down join the same list.
list(LENGTH _ubq_registered_names _ubq_registered)

# The build, run as a fixture. Left alone, ctest runs whatever binaries the tree
# already holds, so a compile that failed would leave the old ones to report a
# green suite, and a broken build would read exactly like a passing one. This
# entry builds before any other; when it fails, every entry requiring it is
# reported Not Run and ctest exits non-zero.
add_test(NAME ubq_build
    COMMAND ${CMAKE_COMMAND}
        -DBUILD_DIR=${CMAKE_BINARY_DIR}
        -DPYTHON=${Python3_EXECUTABLE}
        -DJOBS_SCRIPT=${CMAKE_SOURCE_DIR}/Scripts/build_jobs.py
        -P ${CMAKE_CURRENT_SOURCE_DIR}/run_build_fixture.cmake)
#
# The bound stops a wedged compile from holding the runner; it is not the
# deadlock detector, which is UBIQUITTY_TEST_TIMEOUT below, per entry. A 2-vCPU
# hosted runner with a cold cache needs close to 1800 seconds, and a build cut
# off near its end loses every entry to the build, which says nothing about the
# code under test. The bound has to fit the COLD build, because a warm one is
# never near it and a cold one is exactly the case that should still finish —
# after a cache eviction, a compiler change, or a first run on a new image.
set_tests_properties(ubq_build PROPERTIES
    FIXTURES_SETUP ubq_build_fixture
    TIMEOUT 1800)

# A hang has to fail, and fail quickly. Some tests pass an indefinite timeout on
# purpose — Tests/PAL/test_poll.cpp does, so a backend that parks where the
# contract says it must return is caught rather than passing quietly — and
# without a bound here that test would hold a ctest slot for CTest's 1500-second
# default. Most entries finish in about a second, so this bound turns a deadlock
# red fast. Entries that legitimately need longer take their own TIMEOUT below
# rather than lifting this one, because a bound raised to fit the slowest entry
# stops catching deadlocks in the rest. An instrumented run needs more than this:
# run-coverage.sh raises it, and says why there.
set(UBIQUITTY_TEST_TIMEOUT 60 CACHE STRING
    "Seconds before a single test entry is killed and reported as a failure")

# Where per-test coverage profiles land. One directory decided here rather than
# by whoever exports LLVM_PROFILE_FILE, so the writer and the reader of these
# files agree without a second place to keep in step.
set(UBIQUITTY_COVERAGE_RAW_DIR "${CMAKE_BINARY_DIR}/coverage-raw" CACHE PATH
    "Directory for per-test .profraw files under -DUBIQUITTY_COVERAGE=ON")

if(APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    # Actual CryptoKit AEAD with task-owned in-memory keys: no user's keychain
    # or app process participates. Production keychain availability is a
    # separate platform acceptance check, not inferred from this test.
    enable_language(Swift)
    # Every Swift target here compiles whole-module, as the kits and the app
    # do. CMake drives Debug with swiftc -incremental whatever
    # Swift_COMPILATION_MODE says, and the incremental driver fails a relink
    # whose inputs it all skips with cannotResolveTempPath(<target>-1.swiftmodule):
    # a version bump alone breaks the test build. Whole-module keeps no
    # incremental state to go stale.
    add_compile_options("$<$<COMPILE_LANGUAGE:Swift>:-wmo>")
    add_executable(test_rich_text_native_geometry
        ${CMAKE_SOURCE_DIR}/Source/UbiquittyRenderKit/RichTextGeometry.swift
        ${CMAKE_SOURCE_DIR}/Tests/Platform/test_rich_text_native_geometry.swift)
    set_target_properties(test_rich_text_native_geometry PROPERTIES Swift_LANGUAGE_VERSION 6)
    add_test(NAME test_rich_text_native_geometry COMMAND test_rich_text_native_geometry)
    list(APPEND _ubq_ctest_entries test_rich_text_native_geometry)
    add_executable(test_rich_text_font_catalog
        ${CMAKE_SOURCE_DIR}/Source/UbiquittyRenderKit/RichTextFontCatalog.swift
        ${CMAKE_SOURCE_DIR}/Tests/Platform/test_rich_text_font_catalog.swift)
    set_target_properties(test_rich_text_font_catalog PROPERTIES Swift_LANGUAGE_VERSION 6)
    add_test(NAME test_rich_text_font_catalog COMMAND test_rich_text_font_catalog)
    list(APPEND _ubq_ctest_entries test_rich_text_font_catalog)
    add_executable(test_cold_resume_descriptor
        ${CMAKE_SOURCE_DIR}/Source/Platform/iOS/App/ColdResumeDescriptor.swift
        ${CMAKE_SOURCE_DIR}/Tests/Platform/test_cold_resume_descriptor.swift)
    set_target_properties(test_cold_resume_descriptor PROPERTIES Swift_LANGUAGE_VERSION 6)
    add_test(NAME test_cold_resume_descriptor COMMAND test_cold_resume_descriptor)
    list(APPEND _ubq_ctest_entries test_cold_resume_descriptor)
    add_executable(test_background_refresh_delivery
        ${CMAKE_SOURCE_DIR}/Source/Platform/iOS/App/BackgroundRefreshAuthorization.swift
        ${CMAKE_SOURCE_DIR}/Tests/Platform/test_background_refresh_delivery.swift)
    set_target_properties(test_background_refresh_delivery PROPERTIES Swift_LANGUAGE_VERSION 6)
    # The authorization names its banners with Core's prefix
    # (Core/OSC/Notification.h), so it imports Core through the shared Apple
    # module map at Core's standard, as the iOS app compiles it. The function is
    # inline, so nothing is linked for it.
    target_compile_options(test_background_refresh_delivery PRIVATE
        -cxx-interoperability-mode=default
        "SHELL:-Xcc -std=c++23"
        "-I${CMAKE_SOURCE_DIR}/Source"
        "-I${CMAKE_SOURCE_DIR}/Source/Platform/Apple")
    add_test(NAME test_background_refresh_delivery COMMAND test_background_refresh_delivery)
    list(APPEND _ubq_ctest_entries test_background_refresh_delivery)

    add_executable(test_resume_sealer
        ${CMAKE_SOURCE_DIR}/Source/UbiquittyKit/Swift/SealedStore.swift
        ${CMAKE_SOURCE_DIR}/Tests/Platform/test_resume_sealer.swift)
    set_target_properties(test_resume_sealer PROPERTIES Swift_LANGUAGE_VERSION 6)
    add_test(NAME test_resume_sealer COMMAND test_resume_sealer)
    list(APPEND _ubq_ctest_entries test_resume_sealer)

    # Keep the production source first: the native Kit uses whole-module
    # compilation, where an earlier Foundation String overload lookup can hide
    # the C++ string initializer even from a later explicit CxxStdlib import.
    add_executable(test_resume_sealer_cxx
        ${CMAKE_SOURCE_DIR}/Source/UbiquittyKit/Swift/SealedStore.swift
        ${CMAKE_SOURCE_DIR}/Tests/Platform/test_resume_sealer_cxx.swift)
    set_target_properties(test_resume_sealer_cxx PROPERTIES
        Swift_LANGUAGE_VERSION 6
        Swift_COMPILATION_MODE wholemodule)
    target_compile_options(test_resume_sealer_cxx PRIVATE
        -cxx-interoperability-mode=default)
    add_test(NAME test_resume_sealer_cxx COMMAND test_resume_sealer_cxx)
    list(APPEND _ubq_ctest_entries test_resume_sealer_cxx)
endif()

foreach(_entry IN LISTS _ubq_ctest_entries)
    # 77 is UbiquittyTest::skippedExitCode (Tests/Harness.h): every case that
    # ran declined. Read as Skipped, a binary that asserted nothing is counted
    # out loud instead of as a pass.
    set_tests_properties(${_entry} PROPERTIES
        FIXTURES_REQUIRED ubq_build_fixture
        SKIP_RETURN_CODE 77
        TIMEOUT ${UBIQUITTY_TEST_TIMEOUT})
    # Under coverage every test process writes a profile, but the default name
    # carries only the PID — so the merged profile answers "was this line
    # reached" and cannot answer "by which test". Naming the file after the
    # ctest entry makes the second question answerable, which is what lets a
    # tool run the tests that reach a line instead of all of them. %p stays:
    # a test that forks writes one profile per process, and the prefix still
    # attributes every one of them to the entry that spawned it.
    if(UBIQUITTY_COVERAGE)
        set_tests_properties(${_entry} PROPERTIES
            ENVIRONMENT "LLVM_PROFILE_FILE=${UBIQUITTY_COVERAGE_RAW_DIR}/${_entry}--%p.profraw")
    endif()
endforeach()

if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND TARGET test_linux_rich_text)
    # The native family-selection test must have real fonts even in a minimal
    # image. Add the shipped files as application startup does; keep the native
    # system inventory so enumeration still exercises its actual family map.
    set(UBQ_RICH_TEXT_FONT_DIRECTORY "${CMAKE_SOURCE_DIR}/Resources/fonts")
    string(REPLACE "&" "&amp;" UBQ_RICH_TEXT_FONT_DIRECTORY "${UBQ_RICH_TEXT_FONT_DIRECTORY}")
    string(REPLACE "<" "&lt;" UBQ_RICH_TEXT_FONT_DIRECTORY "${UBQ_RICH_TEXT_FONT_DIRECTORY}")
    file(CONFIGURE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/rich-text-fonts.conf" CONTENT [=[
<?xml version="1.0"?>
<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
    <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
    <dir>@UBQ_RICH_TEXT_FONT_DIRECTORY@</dir>
</fontconfig>
]=] @ONLY)
    set_property(TEST test_linux_rich_text APPEND PROPERTY
        ENVIRONMENT "FONTCONFIG_FILE=${CMAKE_CURRENT_BINARY_DIR}/rich-text-fonts.conf")
endif()

# test_web_terminal builds a WebTerminal per case, and a WebTerminal builds the
# whole renderer stack down to a LigatureSheet whose GlyphSlotCache fills its ink
# records. That is per-case setup rather than work under test, and it puts this
# entry an order of magnitude above the rest — measured past the shared bound on
# a fast machine, so a slower runner has less margin still. It takes its own
# bound rather than lifting the shared one: every other entry keeps the tight
# deadlock guard, and this one keeps a guard rather than CTest's 1500-second
# default. Making the per-case construction cheaper would retire this line.
if(TARGET test_web_terminal)
    set_tests_properties(test_web_terminal PROPERTIES TIMEOUT 300)
endif()

# ----------------------------------------------------------------------
# The Rule-10 layer boundary, tried by the compiler.
# check-core-layer-partition.sh proves that each Core source has exactly one
# layer; it cannot see whether the staged include directories keep a higher
# layer's headers out of the model's reach. A module list entry broad enough to
# match every behaviour subtree, such as a bare "Core", stages them all into the
# model directory while that gate and the build both stay green, so these
# probes attempt the includes themselves.
# ----------------------------------------------------------------------
# Registers a ctest entry that compiles Boundary/<source> with the model stage
# as its one include directory, and fails unless that compile succeeds.
function(ubq_add_layer_probe probeName probeSource)
    add_test(NAME ${probeName}
        COMMAND ${CMAKE_COMMAND}
            -DCXX=${CMAKE_CXX_COMPILER}
            -DINCLUDE_DIR=${CMAKE_BINARY_DIR}/layer-include/model
            -DSRC=${CMAKE_CURRENT_SOURCE_DIR}/Boundary/${probeSource}
            -DEXPECT=pass -DOUT=${CMAKE_CURRENT_BINARY_DIR}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/Boundary/run_boundary_probe.cmake)
    set_tests_properties(${probeName} PROPERTIES
        FIXTURES_REQUIRED ubq_build_fixture
        TIMEOUT ${UBIQUITTY_TEST_TIMEOUT})
endfunction()

# A model header has to be reachable, or the probe after it passes on an empty stage.
ubq_add_layer_probe(test_layer_boundary_control probe_model_from_model.cpp)
# The behaviour headers that probe names must not be.
ubq_add_layer_probe(test_layer_boundary probe_behaviour_from_model.cpp)

# ----------------------------------------------------------------------
# The shell-only remainder, as one ctest entry so `ctest` is the single entry
# point for the whole suite. The stanzas meant are libcore_consumer, the
# snapshot harness, the fuzzers and the QUIC, capability, consent and token
# integration groups. run-tests.sh still compiles them, so this unifies
# REPORTING, not their build.
#
# NO_CTEST=1 stops the handoff recursing back into ctest, and it is what makes
# these entries terminate.
#
# SKIP_CTEST_COVERED=1 decides nothing here, and it is kept rather than dropped.
# It suppresses the stanzas ctest already ran, which matters when the driver is
# invoked with no filter — and each entry below names one stanza, so the filter
# answers first and the covered list is never opened. The driver says so on its
# own last line rather than leaving the reader to derive it. What keeps it here
# is the arrangement it protects against: a registration that goes back to one
# entry for the whole remainder re-runs the suite serially, recompiling the Core
# sources per test, and that entry would need the variable already set.
#
# -DUBIQUITTY_CTEST_SHELL_REMAINDER=OFF leaves them out, for a quick loop on the
# C++ tests: those take seconds, and the stanzas take minutes.
# ----------------------------------------------------------------------
option(UBIQUITTY_CTEST_SHELL_REMAINDER
    "Schedule the remaining run-tests.sh stanzas as ctest entries, one each" ON)

# One ctest entry per stanza rather than one for all of them. As a single
# RUN_SERIAL entry the remainder was 340 of the suite's 369 seconds — 92% of the
# wall clock in one test, with every other core idle beside it. The stanzas are
# independent (each compiles its own link set and runs its own binary), so ctest
# can schedule them like any other test.
#
# The names come from the driver itself: `run-tests.sh --list-stanzas` prints
# what it can be filtered to. Deriving them keeps this from becoming a second
# list to maintain — a stanza added to the driver is scheduled here without
# anyone remembering to say so.
if(UBIQUITTY_CTEST_SHELL_REMAINDER)
    execute_process(
        COMMAND ${CMAKE_SOURCE_DIR}/Scripts/run-tests.sh --list-stanzas
        OUTPUT_VARIABLE _ubq_stanza_text
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _ubq_stanza_result)

    if(NOT _ubq_stanza_result EQUAL 0)
        message(FATAL_ERROR
            "run-tests.sh --list-stanzas failed; the shell stanzas cannot be scheduled")
    endif()

    # The stanzas that share a CMake build directory, each paired with the
    # directory it shares. They cannot run beside another stanza using the same
    # tree — two configures into one directory race on compiler inspection under
    # CMakeFiles/, and the socket name adopt_session derives from the binary they
    # both write makes the loser talk to the winner's daemon.
    #
    # One lock per directory rather than one for the whole set: stanzas on
    # different trees do not contend, and a single lock would serialize forty of
    # them to protect against a collision most of them cannot have.
    # COMMAND_ERROR_IS_FATAL, because this list going empty is silent by nature:
    # no locks are attached, every stanza still runs, and the suite still reports
    # a result -- just an unreliable one. That is what happened when build output
    # moved to $UBQ_BUILD_ROOT and the detector kept matching $ROOT/build/: it
    # emitted nothing for a day and nothing said so. The script now exits
    # non-zero rather than emit an empty list, and this makes that refusal stop
    # the configure instead of being discarded here.
    execute_process(
        COMMAND ${CMAKE_SOURCE_DIR}/Scripts/run-tests.sh --list-serial-stanzas
        OUTPUT_VARIABLE _ubq_serial_text
        OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY)
    string(REPLACE "\n" ";" _ubq_serial_pairs "${_ubq_serial_text}")
    # "<stanza> <directory>" -> _ubq_lock_<stanza> holding the directory.
    foreach(_ubq_pair IN LISTS _ubq_serial_pairs)
        if(_ubq_pair STREQUAL "")
            continue()
        endif()
        string(REGEX REPLACE "^([^ ]+) .*$" "\\1" _ubq_pair_stanza "${_ubq_pair}")
        string(REGEX REPLACE "^[^ ]+ (.*)$" "\\1" _ubq_pair_dir "${_ubq_pair}")
        # A stanza touching two trees needs both locks, so this accumulates.
        list(APPEND _ubq_lock_${_ubq_pair_stanza} "ubq_build_${_ubq_pair_dir}")
        if(_ubq_pair_dir STREQUAL "host-noquic")
            list(APPEND _ubq_host_noquic_stanzas ${_ubq_pair_stanza})
        elseif(_ubq_pair_dir STREQUAL "host-quic")
            list(APPEND _ubq_host_quic_stanzas ${_ubq_pair_stanza})
        endif()
    endforeach()

    # How many compilers one shell stanza may fork, and simultaneously what
    # ctest charges it against `-j`. One variable because the two have to be the
    # same number: the fan-out the stanza performs is the width ctest must
    # reserve, and a stanza that under-declares is scheduled as though it were
    # idle.
    set(UBIQUITTY_SHELL_STANZA_JOBS 2 CACHE STRING
        "Compilers a single shell stanza may fork, and the ctest slots it holds")

    # The Host fixture is a build, not a test, and every stanza that needs the
    # binary is stopped until it finishes — so a width chosen for a test makes
    # all of them wait longer. It gets a build's width and declares it, which is
    # what keeps ctest from starting that much other work beside it.
    set(UBIQUITTY_HOST_FIXTURE_JOBS 8 CACHE STRING
        "Compilers the Host-frontend fixture may fork, and the ctest slots it holds")

    # Stanzas that run the built Host frontend. One fixture builds that tree;
    # they require the fixture and only read it, so no stanza configures or
    # builds it and none holds a lock against another.
    execute_process(
        COMMAND ${CMAKE_SOURCE_DIR}/Scripts/run-tests.sh --list-host-binary-stanzas
        OUTPUT_VARIABLE _ubq_host_binary_text
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _ubq_host_binary_result)
    if(NOT _ubq_host_binary_result EQUAL 0)
        message(FATAL_ERROR
            "run-tests.sh --list-host-binary-stanzas failed; the Host fixture cannot be wired")
    endif()
    string(REPLACE "\n" ";" _ubq_host_binary_stanzas "${_ubq_host_binary_text}")

    # Stanzas that run the built agent. The agent_binary fixture builds it once,
    # with a build's width, for the same reasons as the Host fixture.
    execute_process(
        COMMAND ${CMAKE_SOURCE_DIR}/Scripts/run-tests.sh --list-agent-binary-stanzas
        OUTPUT_VARIABLE _ubq_agent_binary_text
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _ubq_agent_binary_result)
    if(NOT _ubq_agent_binary_result EQUAL 0)
        message(FATAL_ERROR
            "run-tests.sh --list-agent-binary-stanzas failed; the agent fixture cannot be wired")
    endif()
    string(REPLACE "\n" ";" _ubq_agent_binary_stanzas "${_ubq_agent_binary_text}")

    # A cold dependency prefix is built once. Every stanza that probes those
    # archives waits for that setup instead of independently observing a
    # transient absence and reporting a green skip.
    execute_process(
        COMMAND ${CMAKE_SOURCE_DIR}/Scripts/run-tests.sh --list-quic-dependency-stanzas
        OUTPUT_VARIABLE _ubq_quic_dependency_text
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _ubq_quic_dependency_result)
    if(NOT _ubq_quic_dependency_result EQUAL 0)
        message(FATAL_ERROR
            "run-tests.sh --list-quic-dependency-stanzas failed; the QUIC fixture cannot be wired")
    endif()
    string(REPLACE "\n" ";" _ubq_quic_dependency_stanzas "${_ubq_quic_dependency_text}")

    string(REPLACE "\n" ";" _ubq_stanzas "${_ubq_stanza_text}")
    # The platform jobs depend on a successful exact-head preflight, whose
    # style aggregate already executes every gate self-test. The workflow sets
    # this only for those jobs; standalone and local suites retain the stanza.
    if("$ENV{UBQ_CI_PREFLIGHT_COMPLETE}" STREQUAL "1")
        list(REMOVE_ITEM _ubq_stanzas gate_self_tests)
        message(STATUS "Ubiquitty tests: gate self-tests covered by exact-head preflight")
    endif()
    # run-tests.sh's closing line, which says what the run did. Nothing ran and
    # something declined is a stanza that asserted nothing.
    # A dot would match one byte and the dash between is three, so the span is
    # written as one.
    set(_ubq_stanza_decline "run-tests\\.sh: PASSED .+ 0 ran, [1-9]")
    set(_ubq_quic_test_stanzas quic_channel_lifecycle quic_daemon_accept quic_bound_socket)
    # The stanzas that render with the portable snapshot renderer.
    set(_ubq_snapshot_renderer_stanzas snapshots)
    foreach(_ubq_stanza IN LISTS _ubq_stanzas)
        if(_ubq_stanza STREQUAL "")
            continue()
        endif()
        # Told only to the stanzas that require the fixture. A stanza that is
        # not ordered after it must keep building on demand, because being told
        # the binary is ready is a promise nothing has made to it.
        set(_ubq_stanza_env UBQ_TEST_TARGETS_PREBUILT=1)
        set(_ubq_stanza_jobs ${UBIQUITTY_SHELL_STANZA_JOBS})
        if(NOT _ubq_stanza STREQUAL "cache_sweep_fixture")
            list(APPEND _ubq_stanza_env UBQ_CACHE_SWEEP_COMPLETE=1)
        endif()
        if(_ubq_stanza STREQUAL "quic_test_fixture")
            set(_ubq_stanza_jobs ${UBIQUITTY_HOST_FIXTURE_JOBS})
            list(APPEND _ubq_stanza_env UBQ_COVERAGE_BUILD_FIXTURE=1)
        endif()
        if(_ubq_stanza STREQUAL "libcore_fixture")
            set(_ubq_stanza_jobs ${UBIQUITTY_HOST_FIXTURE_JOBS})
            list(APPEND _ubq_stanza_env UBQ_COVERAGE_BUILD_FIXTURE=1)
        elseif(_ubq_stanza STREQUAL "libcore_consumer" OR _ubq_stanza STREQUAL "driver_shapes")
            list(APPEND _ubq_stanza_env UBQ_LIBCORE_PREBUILT=1)
        endif()
        # The portable snapshot renderer is a full portable Core build, which
        # does not fit a rendering stanza's timeout beside the rest of the suite.
        # Its fixture builds it with a build's width; the snapshots entry is
        # ordered after it and refuses a stale renderer instead of rebuilding.
        if(_ubq_stanza STREQUAL "snapshot_renderer_fixture")
            set(_ubq_stanza_jobs ${UBIQUITTY_HOST_FIXTURE_JOBS})
            list(APPEND _ubq_stanza_env UBQ_COVERAGE_BUILD_FIXTURE=1)
        elseif(_ubq_stanza IN_LIST _ubq_snapshot_renderer_stanzas)
            list(APPEND _ubq_stanza_env UBQ_SNAPSHOT_RENDERER_PREBUILT=1)
        endif()
        if(_ubq_stanza IN_LIST _ubq_host_binary_stanzas)
            list(APPEND _ubq_stanza_env UBQ_HOST_PREBUILT=1)
        elseif(_ubq_stanza STREQUAL "host_binary" OR _ubq_stanza STREQUAL "agent_binary")
            set(_ubq_stanza_jobs ${UBIQUITTY_HOST_FIXTURE_JOBS})
            # The fixture builds and runs nothing, and that is its design: the stanzas
            # ordered after it execute what it compiled, and their profiles
            # carry their own entry names. Holding the fixture itself to a
            # profile would fail every coverage run for the one stanza whose
            # job ends at the link. Declared here, beside the fact that makes
            # it true, rather than as a name list in the gate.
            list(APPEND _ubq_stanza_env UBQ_COVERAGE_BUILD_FIXTURE=1)
        endif()
        if(_ubq_stanza IN_LIST _ubq_agent_binary_stanzas)
            list(APPEND _ubq_stanza_env UBQ_AGENT_PREBUILT=1)
        endif()
        # The Host frontend and the agent are the exception to building on
        # demand: their fixtures build them for this run, so a stanza the two
        # lists above did not order after them refuses to build either rather
        # than relink it under the stanzas executing it.
        if(NOT _ubq_stanza STREQUAL "host_binary" AND NOT _ubq_stanza STREQUAL "agent_binary")
            list(APPEND _ubq_stanza_env UBQ_SHARED_BINARIES_FROM_FIXTURES=1)
        endif()
        if(_ubq_stanza IN_LIST _ubq_host_noquic_stanzas
                AND NOT _ubq_stanza STREQUAL "host_noquic_fixture")
            list(APPEND _ubq_stanza_env UBQ_HOST_NOQUIC_PREBUILT=1)
            list(REMOVE_ITEM _ubq_lock_${_ubq_stanza} "ubq_build_host-noquic")
        endif()
        if(_ubq_stanza IN_LIST _ubq_host_quic_stanzas
                AND NOT _ubq_stanza STREQUAL "host_quic_fixture")
            list(APPEND _ubq_stanza_env UBQ_HOST_QUIC_PREBUILT=1)
            list(REMOVE_ITEM _ubq_lock_${_ubq_stanza} "ubq_build_host-quic")
        endif()
        if(_ubq_stanza STREQUAL "host_noquic_fixture"
                OR _ubq_stanza STREQUAL "host_quic_fixture")
            set(_ubq_stanza_jobs ${UBIQUITTY_HOST_FIXTURE_JOBS})
            list(APPEND _ubq_stanza_env UBQ_COVERAGE_BUILD_FIXTURE=1)
        endif()
        if(_ubq_stanza STREQUAL "cache_sweep_fixture")
            list(APPEND _ubq_stanza_env UBQ_COVERAGE_BUILD_FIXTURE=1)
        endif()
        if(_ubq_stanza STREQUAL "quic_deps_fixture")
            set(_ubq_stanza_jobs ${UBIQUITTY_HOST_FIXTURE_JOBS})
            list(APPEND _ubq_stanza_env UBQ_COVERAGE_BUILD_FIXTURE=1)
        endif()
        # Under coverage the stanza's own compiles instrument (UBQ_COVERAGE
        # reaches the compiler rider and the cmake wrapper in run-tests.sh),
        # and the profile path names the entry so the covering-test index
        # attributes the stanza's lines to it — %p still separates the
        # processes a stanza forks.
        set(_ubq_stanza_coverage_env "")
        if(UBIQUITTY_COVERAGE)
            # %c: continuous mode. The stanzas' daemons die by SIGTERM/SIGKILL
            # in their drivers' teardown, and an instrumented process killed by
            # a signal writes nothing at exit — a daemon's whole run then reads
            # as unreached. Continuous mode mmaps the counters into the profile
            # as they increment, so the file is complete however the process
            # ends. The %c is a mode flag, not a substitution: the filename
            # keeps the entry--pid shape the index parses.
            set(_ubq_stanza_coverage_env
                UBQ_COVERAGE=1
                "LLVM_PROFILE_FILE=${UBIQUITTY_COVERAGE_RAW_DIR}/shell_${_ubq_stanza}--%c%p.profraw")
        endif()
        # Covered from here on: run-tests.sh's full run skips a stanza this list
        # names, because ctest has run it as shell_<stanza>. A stanza missing
        # from the list runs twice, in ctest and again in the loop after it.
        list(APPEND _ubq_registered_names ${_ubq_stanza})
        add_test(NAME shell_${_ubq_stanza}
            COMMAND ${CMAKE_COMMAND} -E env NO_CTEST=1 SKIP_CTEST_COVERED=1
                UBQ_OUT=${CMAKE_BINARY_DIR}/shell/${_ubq_stanza}
                # The tree whose object files this entry is about. UBQ_OUT above
                # points a stanza at its own scratch directory, and a stanza that
                # derived the tree from it looked for the suite's objects inside
                # its own — check-core-subset-symbols then refused every run,
                # because a tree with no objects reads as a cut it cannot judge.
                UBQ_HOST_TEST_TREE=${CMAKE_BINARY_DIR}
                UBIQUITTY_QUIC_PREFIX=${UBIQUITTY_QUIC_PREFIX}
                UBQ_BUILD_JOBS=${_ubq_stanza_jobs}
                ${_ubq_stanza_env}
                ${_ubq_stanza_coverage_env}
                ${CMAKE_SOURCE_DIR}/Scripts/run-tests.sh ${_ubq_stanza})
        # A stanza compiles its own link set before it runs, so its clock
        # includes a build the CMake-covered tests already have. Three of them
        # pass in 45-70s alone, which the ordinary per-test timeout would call a
        # hang the moment the machine is busy.
        #
        # PROCESSORS is what tells ctest that. Without it a stanza counts as one
        # process while it forks that many compilers, so `-j N` schedules N
        # stanzas and the machine gets N times this number — 49 concurrent
        # compilers measured against 15 cores at `-j12`. The same variable feeds
        # the stanza's own fan-out above, because a declared width and an actual
        # one that are written separately are two numbers that can disagree, and
        # only the smaller one is ever believed.
        set(_ubq_stanza_fixtures "")
        if(_ubq_stanza STREQUAL "quic_deps_fixture")
            list(APPEND _ubq_stanza_fixtures ubq_cache_sweep_fixture)
        elseif(NOT _ubq_stanza STREQUAL "cache_sweep_fixture")
            list(APPEND _ubq_stanza_fixtures
                ubq_build_fixture
                ubq_cache_sweep_fixture)
        endif()
        if(_ubq_stanza IN_LIST _ubq_host_binary_stanzas)
            list(APPEND _ubq_stanza_fixtures ubq_host_binary_fixture)
        endif()
        if(_ubq_stanza IN_LIST _ubq_agent_binary_stanzas)
            list(APPEND _ubq_stanza_fixtures ubq_agent_binary_fixture)
        endif()
        if(_ubq_stanza IN_LIST _ubq_host_noquic_stanzas
                AND NOT _ubq_stanza STREQUAL "host_noquic_fixture")
            list(APPEND _ubq_stanza_fixtures ubq_host_noquic_fixture)
        endif()
        if(_ubq_stanza IN_LIST _ubq_host_quic_stanzas
                AND NOT _ubq_stanza STREQUAL "host_quic_fixture")
            list(APPEND _ubq_stanza_fixtures ubq_host_quic_fixture)
        endif()
        if(_ubq_stanza STREQUAL "host_binary"
                OR _ubq_stanza STREQUAL "host_noquic_fixture"
                OR _ubq_stanza STREQUAL "host_quic_fixture")
            list(APPEND _ubq_stanza_fixtures ubq_quic_deps_fixture)
        endif()
        if(_ubq_stanza IN_LIST _ubq_quic_dependency_stanzas)
            list(APPEND _ubq_stanza_fixtures ubq_quic_deps_fixture)
        endif()
        if(_ubq_stanza STREQUAL "libcore_consumer" OR _ubq_stanza STREQUAL "driver_shapes")
            list(APPEND _ubq_stanza_fixtures ubq_libcore_fixture)
        endif()
        if(_ubq_stanza IN_LIST _ubq_snapshot_renderer_stanzas)
            list(APPEND _ubq_stanza_fixtures ubq_snapshot_renderer_fixture)
        endif()
        if(_ubq_stanza IN_LIST _ubq_quic_test_stanzas)
            list(APPEND _ubq_stanza_fixtures ubq_quic_test_fixture)
        endif()
        list(REMOVE_DUPLICATES _ubq_stanza_fixtures)
        # A stanza that asserted nothing exits 0, which ctest reports as a pass
        # and a reader counts as coverage. run-tests.sh ends every run with what
        # it did, and "0 ran" is the whole-stanza decline: the tool was absent,
        # the platform was wrong, the daemon would not start. Matching that line
        # turns those into ctest's own Skipped, which the summary counts out
        # loud. A stanza that ran anything at all does not match it.
        set_tests_properties(shell_${_ubq_stanza} PROPERTIES
            FIXTURES_REQUIRED "${_ubq_stanza_fixtures}"
            PROCESSORS ${_ubq_stanza_jobs}
            SKIP_REGULAR_EXPRESSION "${_ubq_stanza_decline}"
            TIMEOUT 600)
        if(_ubq_stanza STREQUAL "snapshots")
            # The CI battery runs these tiers separately. Its explicit opt-out
            # is a skipped test, not a passing render or an unmatched filter.
            #
            # On macOS the stanza renders the portable, macOS and Swift tiers,
            # about fifteen hundred cases through the app, which took seventeen
            # minutes on a ten-core laptop with nothing else running: a
            # rendering stanza's ten minutes cannot hold it.
            set_tests_properties(shell_snapshots PROPERTIES
                SKIP_REGULAR_EXPRESSION
                    "(^|\n)SKIP: snapshots: explicitly disabled with SNAPSHOT=skip(\n|$);${_ubq_stanza_decline}")
            set_tests_properties(shell_snapshots PROPERTIES TIMEOUT 2400)
        endif()
        if(_ubq_stanza STREQUAL "clipboard_tool_no_rcs")
            set_tests_properties(shell_clipboard_tool_no_rcs PROPERTIES
                SKIP_REGULAR_EXPRESSION
                    "SKIP: clipboard_tool_no_rcs requires zsh;${_ubq_stanza_decline}")
        endif()
        if(_ubq_stanza STREQUAL "test_font_fanout")
            set_tests_properties(shell_${_ubq_stanza} PROPERTIES SKIP_RETURN_CODE 77)
        endif()
        if(_ubq_stanza STREQUAL "host_binary")
            # It builds the tree the others read, so it is the one that may write
            # it and the only one ctest orders first.
            set_tests_properties(shell_host_binary PROPERTIES
                FIXTURES_SETUP ubq_host_binary_fixture)
        endif()
        if(_ubq_stanza STREQUAL "agent_binary")
            # This fixture includes a cold Release build of the agent.
            set_tests_properties(shell_agent_binary PROPERTIES
                FIXTURES_SETUP ubq_agent_binary_fixture
                TIMEOUT 1800)
        endif()
        if(_ubq_stanza STREQUAL "quic_test_fixture")
            set_tests_properties(shell_quic_test_fixture PROPERTIES
                FIXTURES_SETUP ubq_quic_test_fixture TIMEOUT 900)
        endif()
        if(_ubq_stanza STREQUAL "libcore_fixture")
            set_tests_properties(shell_libcore_fixture PROPERTIES
                FIXTURES_SETUP ubq_libcore_fixture
                TIMEOUT 1800)
        endif()
        if(_ubq_stanza STREQUAL "snapshot_renderer_fixture")
            # Sized for a cold optimized build of the portable Core.
            set_tests_properties(shell_snapshot_renderer_fixture PROPERTIES
                FIXTURES_SETUP ubq_snapshot_renderer_fixture
                TIMEOUT 1800)
        endif()
        if(_ubq_stanza STREQUAL "sanitized_sync")
            # This stanza builds and runs a separate instrumented tree.
            set_tests_properties(shell_${_ubq_stanza} PROPERTIES TIMEOUT 1800)
        endif()
        if(_ubq_stanza STREQUAL "host_noquic_fixture")
            set_tests_properties(shell_host_noquic_fixture PROPERTIES
                FIXTURES_SETUP ubq_host_noquic_fixture
                TIMEOUT 900)
        endif()
        if(_ubq_stanza STREQUAL "cache_sweep_fixture")
            set_tests_properties(shell_cache_sweep_fixture PROPERTIES
                FIXTURES_SETUP ubq_cache_sweep_fixture
                TIMEOUT 60)
        endif()
        if(_ubq_stanza STREQUAL "quic_deps_fixture")
            set_tests_properties(shell_quic_deps_fixture PROPERTIES
                FIXTURES_SETUP ubq_quic_deps_fixture
                TIMEOUT 900)
        endif()
        if(_ubq_stanza STREQUAL "host_quic_fixture")
            set_tests_properties(shell_host_quic_fixture PROPERTIES
                FIXTURES_SETUP ubq_host_quic_fixture
                TIMEOUT 900)
        endif()
        if(DEFINED _ubq_lock_${_ubq_stanza})
            list(REMOVE_DUPLICATES _ubq_lock_${_ubq_stanza})
            set_tests_properties(shell_${_ubq_stanza} PROPERTIES
                RESOURCE_LOCK "${_ubq_lock_${_ubq_stanza}}")
        endif()
    endforeach()

    list(LENGTH _ubq_stanzas _ubq_stanza_count)
    message(STATUS "Ubiquitty tests: ${_ubq_stanza_count} shell stanzas scheduled individually")

    # What the stanza lane holds, for the census that runs after every ctest
    # invocation. `ctest -E '^shell_'` is the command this repository reaches
    # for, and it runs none of these, so its summary is a true sentence about a
    # fraction of the suite that reads as one about all of it.
    #
    # CTEST_CUSTOM_POST_TEST takes a list of commands, each run with no
    # arguments, so the count travels in a file rather than beside the path.
    string(REPLACE ";" "\n" _ubq_stanza_lines "${_ubq_stanzas}")
    file(WRITE "${CMAKE_BINARY_DIR}/shell-lane-stanzas.txt" "${_ubq_stanza_lines}\n")
    file(WRITE "${CMAKE_BINARY_DIR}/CTestCustom.cmake"
        "set(CTEST_CUSTOM_POST_TEST \"${CMAKE_SOURCE_DIR}/Scripts/ctest-shell-lane-census.sh\")\n")
endif()

# ----------------------------------------------------------------------
# Dev tools that are not tests: flood benchmarks, a fuzz-corpus generator, a
# PTY-replay client. They have no pass/fail behaviour, so they are compiled and
# never run — an OBJECT library is exactly that, and it puts them in the default
# build so a header or API they call cannot drift without failing ninja.
#
# They rotted this way before, invisibly, because nothing referenced them.
# ----------------------------------------------------------------------
# Globbed, never listed. A hand-maintained list of tools is the same thing that
# let bench_stack.cpp and four siblings sit uncompiled: a file nothing names is
# a file nothing checks. The naming convention is the registration.
# Tools/ is a sibling of Tests/ and holds the same kind of thing: programs with
# no pass/fail behaviour. They were built by run-tests.sh stanzas, which both
# compiled and ran them — and font-diagnose contains no assertion at all, so
# running it asserted nothing and only cost the time. Compiled here, never run,
# which is what the rest of this block already does for the tools inside Tests/.
file(GLOB UBIQUITTY_SIBLING_TOOL_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_SOURCE_DIR}/Tools/*.cpp")

# No `*/` before the name. GLOB_RECURSE already reaches every depth, and a `*/`
# would additionally require a subdirectory — so a tool placed directly in
# Tests/ would follow the naming convention and go silently unregistered, the
# one case where "the naming convention is the registration" above would be
# false. Measured with cmake -P over a probe tree: `Tests/*/bench_*.cpp` matches
# depth 2 and depth 3 and misses `Tests/bench_x.cpp`; the form below matches all
# three.
file(GLOB_RECURSE UBIQUITTY_TOOL_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/bench_*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/perf_*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/profile_*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/build_corpus.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/smoke_client.cpp")
list(APPEND UBIQUITTY_TOOL_SOURCES ${UBIQUITTY_SIBLING_TOOL_SOURCES})

foreach(_tool_source IN LISTS UBIQUITTY_TOOL_SOURCES)
    get_filename_component(_tool_name ${_tool_source} NAME_WE)
    add_library(ubq-tool-${_tool_name} OBJECT ${_tool_source})
    target_include_directories(ubq-tool-${_tool_name} PRIVATE
        ${CMAKE_SOURCE_DIR}/Source
        ${CMAKE_SOURCE_DIR}/Source/ThirdParty/simdutf
        ${CMAKE_CURRENT_SOURCE_DIR})
    target_compile_features(ubq-tool-${_tool_name} PRIVATE cxx_std_23)
    target_compile_options(ubq-tool-${_tool_name} PRIVATE
        -Wall -Wextra -Werror -Wno-deprecated-declarations -Wno-multichar -Wno-comment)
endforeach()

add_executable(ubq-host-smoke-client $<TARGET_OBJECTS:ubq-tool-smoke_client>)
target_link_libraries(ubq-host-smoke-client PRIVATE ubiquitty-core)

set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

function(ubq_configure_shell_target target)
    target_include_directories(${target} PRIVATE
        ${CMAKE_SOURCE_DIR}/Source
        ${CMAKE_SOURCE_DIR}/Source/ThirdParty/simdutf
        ${CMAKE_CURRENT_SOURCE_DIR})
    target_compile_features(${target} PRIVATE cxx_std_23)
    set_target_properties(${target} PROPERTIES CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    target_compile_options(${target} PRIVATE -Wall -Wextra -Werror -fno-exceptions -fno-rtti)
endfunction()

# These integration stanzas retain their process setup and assertions in the
# shell driver, but link the same Core as the rest of this test tree.
foreach(_shell_test session_directory remote_session_smoke remote_workspace_smoke
        named_layout_restore remote_clear_e2e tmux_real_e2e ack_rides_input remote_pane_link_e2e)
    add_executable(ubq-shell-${_shell_test} ${CMAKE_CURRENT_SOURCE_DIR}/Host/${_shell_test}.cpp)
    ubq_configure_shell_target(ubq-shell-${_shell_test})
    target_link_libraries(ubq-shell-${_shell_test} PRIVATE ubiquitty-core Threads::Threads)
endforeach()

# Handover's socket tests keep their restricted link set; sharing a build
# must not supply missing dependencies from the full Core aggregate.
add_library(ubq-shell-handover-transport OBJECT
    ${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/HandoverTransport.cpp
    ${CMAKE_SOURCE_DIR}/Source/Core/Protocol/Sync/HandoverChannel.cpp)
ubq_configure_shell_target(ubq-shell-handover-transport)
add_executable(ubq-shell-handover_admission
    ${CMAKE_CURRENT_SOURCE_DIR}/Host/handover_admission.cpp
    ${CMAKE_SOURCE_DIR}/Source/Platform/Host/HandoverAdmission.cpp
    ${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/PTYFacts.cpp
    ${CMAKE_SOURCE_DIR}/Source/Core/Session/ProcessSubtree.cpp)
add_executable(ubq-shell-handover_request
    ${CMAKE_CURRENT_SOURCE_DIR}/Host/handover_request.cpp
    ${CMAKE_SOURCE_DIR}/Source/Platform/Host/HandoverRequest.cpp)
foreach(_handover ubq-shell-handover_admission ubq-shell-handover_request)
    ubq_configure_shell_target(${_handover})
    target_compile_definitions(${_handover} PRIVATE UBIQUITTY_TEST_WITHOUT_CORE)
    target_link_libraries(${_handover} PRIVATE ubq-shell-handover-transport)
endforeach()
if(APPLE)
    target_link_libraries(ubq-shell-handover_admission PRIVATE "-framework CoreFoundation" "-framework Security")
endif()

# These targets are built only by the QUIC shell fixture, after its dependency
# fixture supplies the TLS archives. Core-only builds need not fetch them.
set(_ubq_shell_quic_libraries
    "${UBIQUITTY_QUIC_PREFIX}/lib/libngtcp2_crypto_boringssl.a"
    "${UBIQUITTY_QUIC_PREFIX}/lib/libngtcp2.a"
    "${UBIQUITTY_QUIC_PREFIX}/lib/libssl.a"
    "${UBIQUITTY_QUIC_PREFIX}/lib/libcrypto.a")
if(APPLE)
    list(APPEND _ubq_shell_quic_libraries "-framework CoreFoundation" "-framework Security")
endif()
add_library(ubq-shell-quic-client OBJECT EXCLUDE_FROM_ALL
    ${CMAKE_SOURCE_DIR}/Source/Core/Transport/QUICChannel.cpp
    ${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/QUICClient.cpp
    ${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/DatagramBatch.cpp)
ubq_configure_shell_target(ubq-shell-quic-client)
target_include_directories(ubq-shell-quic-client PUBLIC "${UBIQUITTY_QUIC_PREFIX}/include")
target_compile_definitions(ubq-shell-quic-client PUBLIC UBIQUITTY_QUIC=1)
target_link_libraries(ubq-shell-quic-client PUBLIC ${_ubq_shell_quic_libraries} Threads::Threads)
add_executable(ubq-shell-quic_channel_lifecycle EXCLUDE_FROM_ALL ${CMAKE_CURRENT_SOURCE_DIR}/Host/quic_channel_lifecycle.cpp)
ubq_configure_shell_target(ubq-shell-quic_channel_lifecycle)
target_link_libraries(ubq-shell-quic_channel_lifecycle PRIVATE ubq-shell-quic-client)

add_library(ubq-shell-quic-server OBJECT EXCLUDE_FROM_ALL
    ${CMAKE_SOURCE_DIR}/Source/Platform/Host/HostQUIC.cpp
    ${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/DatagramBatch.cpp
    ${CMAKE_SOURCE_DIR}/Source/Platform/Host/HostPaths.cpp
    ${CMAKE_SOURCE_DIR}/Source/Core/Session/ControlPaths.cpp
    ${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/SocketPath.cpp
    ${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/SystemPAL.cpp
    ${CMAKE_SOURCE_DIR}/Source/Platform/POSIX/Preferences.cpp
    ${CMAKE_SOURCE_DIR}/Source/Core/Preferences/PreferencesPaths.cpp)
ubq_configure_shell_target(ubq-shell-quic-server)
target_include_directories(ubq-shell-quic-server PUBLIC "${UBIQUITTY_QUIC_PREFIX}/include")
target_link_libraries(ubq-shell-quic-server PUBLIC ${_ubq_shell_quic_libraries} Threads::Threads)
foreach(_server_test quic_daemon_accept quic_bound_socket)
    add_executable(ubq-shell-${_server_test} EXCLUDE_FROM_ALL ${CMAKE_CURRENT_SOURCE_DIR}/Host/${_server_test}.cpp)
    ubq_configure_shell_target(ubq-shell-${_server_test})
    target_link_libraries(ubq-shell-${_server_test} PRIVATE ubq-shell-quic-server)
endforeach()
target_compile_definitions(ubq-shell-quic_bound_socket PRIVATE UBIQUITTY_TEST_WITHOUT_CORE)

# The Sync stream the Emacs and Neovim clients decode, written by a real host
# connection: emacs_sync_decode and neovim_sync_decode run it. Built here, it
# links the Core this tree already compiled rather than each stanza compiling
# a Core of its own.
add_executable(ubq-sync-stream-fixture ${CMAKE_CURRENT_SOURCE_DIR}/Platform/sync_stream_fixture.cpp)
target_include_directories(ubq-sync-stream-fixture PRIVATE
    ${CMAKE_SOURCE_DIR}/Source
    ${CMAKE_SOURCE_DIR}/Source/ThirdParty/simdutf
    ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(ubq-sync-stream-fixture PRIVATE cxx_std_23)
target_compile_options(ubq-sync-stream-fixture PRIVATE
    -fno-exceptions -fno-rtti -Wno-deprecated-declarations -Wno-multichar -Wno-comment)
target_link_libraries(ubq-sync-stream-fixture PRIVATE ubiquitty-core)

# tmux control mode under load against a real tmux server, hosted as a
# frontend hosts it: run-tests.sh's tmux_control_stress runs it. Its sessions
# launch over real PTYs, so it links the PAL set the ingest-loop test does.
set(_ubq_tmux_stress_sources ${CMAKE_CURRENT_SOURCE_DIR}/Host/tmux_control_stress.cpp)
foreach(_ubq_pal_source IN LISTS test_ingest_loop_EXTRA_SOURCES)
    list(APPEND _ubq_tmux_stress_sources ${CMAKE_SOURCE_DIR}/${_ubq_pal_source})
endforeach()
add_executable(ubq-tmux-control-stress ${_ubq_tmux_stress_sources})
target_include_directories(ubq-tmux-control-stress PRIVATE
    ${CMAKE_SOURCE_DIR}/Source
    ${CMAKE_SOURCE_DIR}/Source/ThirdParty/simdutf
    ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(ubq-tmux-control-stress PRIVATE cxx_std_23)
target_compile_options(ubq-tmux-control-stress PRIVATE
    -Wall -Wextra -Werror -Wno-deprecated-declarations -Wno-multichar -Wno-comment)
target_link_libraries(ubq-tmux-control-stress PRIVATE ubiquitty-core)

# The structured seeds of the Sync fuzz corpus, written at the current wire;
# Scripts/refresh-sync-fuzz-corpus.py runs it.
add_executable(ubq-sync-corpus-builder $<TARGET_OBJECTS:ubq-tool-build_corpus>)
target_link_libraries(ubq-sync-corpus-builder PRIVATE ubiquitty-core)

# ctest-covered.txt tells Scripts/run-tests.sh which of its stanzas ctest has
# already run: every C++ test registered above and, with
# UBIQUITTY_CTEST_SHELL_REMAINDER, every shell stanza scheduled here. The driver
# skips those and runs the rest. Nobody edits the file, so no name can be run by
# both drivers or dropped by both.
list(SORT _ubq_registered_names)
list(JOIN _ubq_registered_names "\n" _ubq_covered_text)
file(WRITE ${CMAKE_BINARY_DIR}/ctest-covered.txt "${_ubq_covered_text}\n")

message(STATUS
    "Ubiquitty tests: CTest runs ${_ubq_registered} (one at a time with ctest -R <name>); "
    "${_ubq_deferred} more are left to Scripts/run-tests.sh")
