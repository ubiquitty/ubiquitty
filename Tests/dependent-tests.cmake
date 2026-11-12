# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# Tests/dependent-tests.cmake — the app's host tests.
#
# Tests/CMakeLists.txt reads the per-test sources, links and definitions below.
# UBQ_DEPENDENT_TESTS names paths under this repository's Tests/. The shared
# Core test machinery links them against the same Core the app builds, while
# Core and Kit register their own unit tests in their repositories.
#
# The tests whose subject needs a frontend's library are not listed: the iOS
# session tests and the SwiftBridge clipboard resolver run as stanzas of
# Scripts/run-tests-stanzas-app.sh, which build what they need.
#

set(UBQ_DEPENDENT_TESTS
    Core/test_frontend_capability_environment.cpp
    Core/test_frontend_capability_policies.cpp
    Platform/test_macos_file_read.cpp
    Platform/test_web_terminal.cpp
    Platform/test_web_font_inventory.cpp
    Platform/test_web_font_rasterizer.cpp
    Platform/test_linux_updater_security.cpp)

# The app's tests include its own headers beside Core's and the Kit's, which the
# include directories Core hands every test do not reach.
foreach(_ubq_dependent_test IN LISTS UBQ_DEPENDENT_TESTS)
    get_filename_component(_ubq_dependent_name ${_ubq_dependent_test} NAME_WE)
    list(APPEND ${_ubq_dependent_name}_EXTRA_INCLUDES ${CMAKE_SOURCE_DIR}/Source ${CMAKE_SOURCE_DIR}/Tests)
endforeach()

# The gated kitty file read and its verified unlink live in Platform/POSIX so no
# single arm owns the hardening rules. The portable Core does not carry them, so
# each test over them names the TU.
set(test_macos_file_read_EXTRA_SOURCES Source/Platform/POSIX/GatedFileRead.cpp
                                       Source/Platform/POSIX/SystemPAL.cpp)

# The 240 bridge cases exceed one entry's budget on hosted Macs. The harness
# partitions the complete registry, keeping the existing per-entry timeout.
set(test_web_terminal_SHARDS 4)
set(test_web_terminal_EXTRA_SOURCES    ${CMAKE_SOURCE_DIR}/Source/Platform/Web/WebTerminal.cpp
                                       ${CMAKE_SOURCE_DIR}/Source/Platform/Web/WebRichText.cpp
                                       ${CMAKE_SOURCE_DIR}/Source/Platform/Web/WebFontRasterizer.cpp
                                       ${CMAKE_SOURCE_DIR}/Source/Platform/Web/WebFontInventory.cpp
                                       ${CMAKE_SOURCE_DIR}/Source/Platform/Web/WebPAL.cpp)
# The browser's FontInventory. Its coverage probes need a canvas, so natively
# they answer absent and the cases assert the bookkeeping: handle identity and
# generation invalidation, which is the half that does not need a font.
set(test_web_font_inventory_EXTRA_SOURCES ${CMAKE_SOURCE_DIR}/Source/Platform/Web/WebFontInventory.cpp)
# The rasterizer's available arm, driven through the ForTest host seam: both
# TUs compile with the hooks so a stand-in text engine can answer the probes and
# the draws.
set(test_web_font_rasterizer_EXTRA_SOURCES ${CMAKE_SOURCE_DIR}/Source/Platform/Web/WebFontRasterizer.cpp
                                           ${CMAKE_SOURCE_DIR}/Source/Platform/Web/WebFontInventory.cpp)
set(test_web_font_rasterizer_EXTRA_DEFINES UBIQUITTY_ENABLE_TEST_HOOKS=1)

set(test_linux_updater_security_EXTRA_SOURCES ${CMAKE_SOURCE_DIR}/Source/Platform/Linux/Updater.cpp)
set(test_linux_updater_security_EXTRA_DEFINES UBIQUITTY_ENABLE_TEST_HOOKS=1)

# The Sync stream the Emacs and Neovim clients decode, written by a real host
# connection: emacs_sync_decode and neovim_sync_decode run it. Built here, it
# links the Core this tree already compiled rather than each stanza compiling a
# Core of its own.
add_executable(ubq-sync-stream-fixture ${CMAKE_SOURCE_DIR}/Tests/Platform/sync_stream_fixture.cpp)
target_include_directories(ubq-sync-stream-fixture PRIVATE
    ${UBIQUITTY_CORE_SOURCE_DIR}/Source
    ${UBIQUITTY_CORE_SOURCE_DIR}/Source/ThirdParty/simdutf
    ${UBIQUITTY_CORE_SOURCE_DIR}/Tests)
target_compile_features(ubq-sync-stream-fixture PRIVATE cxx_std_23)
target_compile_options(ubq-sync-stream-fixture PRIVATE
    -fno-exceptions -fno-rtti -Wno-deprecated-declarations -Wno-multichar -Wno-comment)
target_link_libraries(ubq-sync-stream-fixture PRIVATE ubiquitty-core)

# These stanzas can build their shared Host daemon on demand. Keep each build
# and the daemon it drives under the same tree lock; the driver's inventories
# also name any other shared build trees, so their owners remain the recipes.
ubiquitty_default_shell_driver(_ubq_app_shell_driver)
ubiquitty_lock_shell_build_trees(DRIVER "${_ubq_app_shell_driver}")
