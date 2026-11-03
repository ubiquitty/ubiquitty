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

# A directory staged whole holds the files staged into it and nothing else.
if(UBIQUITTY_BUNDLE_WHOLE_DIRECTORY)
    set(names "")
    foreach(resource IN LISTS UBIQUITTY_BUNDLE_RESOURCES)
        get_filename_component(name "${resource}" NAME)
        list(APPEND names "${name}")
    endforeach()
    file(GLOB entries LIST_DIRECTORIES true RELATIVE "${destination}" "${destination}/*")
    foreach(entry IN LISTS entries)
        list(FIND names "${entry}" index)
        if(index EQUAL -1)
            file(REMOVE_RECURSE "${destination}/${entry}")
        endif()
    endforeach()
endif()
