# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

include(${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyTests.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/dependent-tests.cmake)

ubiquitty_add_host_tests(
    ROOT ${CMAKE_SOURCE_DIR} SOURCES ${UBQ_DEPENDENT_TESTS}
    INCLUDE_DIRECTORIES ${UBIQUITTY_CORE_SOURCE_DIR}/Source ${UBIQUITTY_CORE_SOURCE_DIR}/Tests)

# Each Web shard renders complete frames. Keep the hosted Mac's fixed
# deadline free of competing test processes and shell compilation.
math(EXPR _ubq_web_last_shard "${test_web_terminal_SHARDS} - 1")
foreach(_ubq_web_shard RANGE 0 ${_ubq_web_last_shard})
    set_property(TEST test_web_terminal.${_ubq_web_shard} APPEND PROPERTY ENVIRONMENT UBQ_TEST_VERBOSE=1)
    if(APPLE)
        set_tests_properties(test_web_terminal.${_ubq_web_shard} PROPERTIES RUN_SERIAL TRUE)
    endif()
endforeach()

ubiquitty_default_shell_driver(_ubq_app_shell_driver)
# This Apple-only stanza reports the same unavailable status as before the
# app acquired its own test tree; the metadata belongs beside its owner.
set(shell_test_font_fanout_SKIP_RETURN_CODE 77)
set(shell_snapshots_SKIP_REGULAR_EXPRESSION
    "(^|\n)SKIP: snapshots: explicitly disabled with SNAPSHOT=skip(\n|$)")
set(shell_snapshots_TIMEOUT 2400)
ubiquitty_schedule_shell_stanzas(DRIVER "${_ubq_app_shell_driver}")
add_test(NAME test_ios_sync_driver
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/Tests/Tools/test_ios_sync_conformance.py")
ubiquitty_set_test_entry_properties(test_ios_sync_driver)

ubiquitty_finish_host_tests()

foreach(release_test release_ci release_preparation)
    add_test(NAME test_${release_test}
        COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/Tests/Tools/test_${release_test}.py")
    ubiquitty_set_test_entry_properties(test_${release_test})
endforeach()
