# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

include("${CMAKE_CURRENT_LIST_DIR}/BundleResources.cmake")

set_property(GLOBAL PROPERTY UBIQUITTY_LICENSE_NOTICE_SCRIPT
    "${CMAKE_CURRENT_LIST_DIR}/../Scripts/license_notices.py")

function(ubiquitty_license_notice_paths output)
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    get_property(script GLOBAL PROPERTY UBIQUITTY_LICENSE_NOTICE_SCRIPT)
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
        "${script}" "${CMAKE_SOURCE_DIR}/Docs/third-party-inventory.json")
    execute_process(
        COMMAND "${Python3_EXECUTABLE}" "${script}" --source "${CMAKE_SOURCE_DIR}" --list
        RESULT_VARIABLE result OUTPUT_VARIABLE paths ERROR_VARIABLE error
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(NOT result EQUAL 0)
        message(FATAL_ERROR "Cannot collect distribution license notices: ${error}")
    endif()
    string(REPLACE "\n" ";" paths "${paths}")
    set(${output} "${paths}" PARENT_SCOPE)
endfunction()

function(ubiquitty_bundle_license_notices target)
    ubiquitty_license_notice_paths(notices)
    foreach(notice IN LISTS notices)
        get_filename_component(directory "${notice}" DIRECTORY)
        if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
            # A top-level Resources directory makes codesign interpret a shallow
            # iOS bundle as a different layout. Keep the entire linked notice
            # hierarchy under one ordinary resource directory instead.
            set(directory "Licenses/${directory}")
        endif()
        ubiquitty_bundle_resources(${target} "${directory}" "${CMAKE_SOURCE_DIR}/${notice}")
    endforeach()

    # The staged set is checked against the inventory after every build, on
    # every generator: a resource rule that silently builds nothing ships an
    # app without its licences, and only the finished bundle can show that.
    ubiquitty_bundle_resource_root(${target} noticeRoot)
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        string(APPEND noticeRoot "/Licenses")
    endif()
    # FindPython's executable variable is scoped to the function that found
    # it, so the check finds the interpreter for itself.
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    get_property(script GLOBAL PROPERTY UBIQUITTY_LICENSE_NOTICE_SCRIPT)
    # Not VERBATIM: under Xcode the bundle directory is spelled with a build
    # setting the phase's shell has to expand.
    add_custom_command(TARGET ${target} POST_BUILD
        COMMAND "${Python3_EXECUTABLE}" "${script}"
            --source "${CMAKE_SOURCE_DIR}" --verify "${noticeRoot}"
        COMMENT "Checking ${target}'s bundled licence notices")
endfunction()

function(ubiquitty_install_license_notices destination)
    ubiquitty_license_notice_paths(notices)
    foreach(notice IN LISTS notices)
        get_filename_component(directory "${notice}" DIRECTORY)
        install(FILES "${CMAKE_SOURCE_DIR}/${notice}" DESTINATION "${destination}/${directory}")
    endforeach()
endfunction()
