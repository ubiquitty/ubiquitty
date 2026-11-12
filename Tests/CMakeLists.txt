# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

include(${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyTests.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/dependent-tests.cmake)

ubiquitty_add_host_tests(
    ROOT ${CMAKE_SOURCE_DIR} SOURCES ${UBQ_DEPENDENT_TESTS}
    INCLUDE_DIRECTORIES ${UBIQUITTY_CORE_SOURCE_DIR}/Source ${UBIQUITTY_CORE_SOURCE_DIR}/Tests)

ubiquitty_default_shell_driver(_ubq_app_shell_driver)
# This Apple-only stanza reports the same unavailable status as before the
# app acquired its own test tree; the metadata belongs beside its owner.
set(shell_test_font_fanout_SKIP_RETURN_CODE 77)
set(shell_snapshots_SKIP_REGULAR_EXPRESSION
    "(^|\n)SKIP: snapshots: explicitly disabled with SNAPSHOT=skip(\n|$)")
set(shell_snapshots_TIMEOUT 2400)
ubiquitty_schedule_shell_stanzas(DRIVER "${_ubq_app_shell_driver}")
ubiquitty_finish_host_tests()
