# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

include(${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyTests.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/dependent-tests.cmake)

ubiquitty_add_host_tests(
    ROOT ${CMAKE_SOURCE_DIR} SOURCES ${UBQ_DEPENDENT_TESTS}
    INCLUDE_DIRECTORIES ${UBIQUITTY_CORE_SOURCE_DIR}/Source ${UBIQUITTY_CORE_SOURCE_DIR}/Tests)

ubiquitty_default_shell_driver(_ubq_app_shell_driver)
ubiquitty_schedule_shell_stanzas(DRIVER "${_ubq_app_shell_driver}")
ubiquitty_finish_host_tests()
