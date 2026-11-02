# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

file(READ "${UBIQUITTY_BUNDLE_DESTINATION_FILE}" destination)
file(MAKE_DIRECTORY "${destination}")
execute_process(
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        ${UBIQUITTY_BUNDLE_RESOURCES} "${destination}"
    RESULT_VARIABLE result)
if(NOT result EQUAL 0)
    message(FATAL_ERROR "Bundle resource staging failed: ${result}")
endif()
