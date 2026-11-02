# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

include_guard(GLOBAL)

set_property(GLOBAL PROPERTY UBIQUITTY_BUNDLE_RESOURCE_SCRIPT
    "${CMAKE_CURRENT_LIST_DIR}/StageBundleResources.cmake")

# Stages resources beneath the platform's bundle resource directory.
#
# - Parameters:
#   - target: The application bundle target.
#   - directory: The resource subdirectory, or an empty string for its root.
#   - ARGN: The resource files to copy.
function(ubiquitty_bundle_resources target directory)
    if(CMAKE_GENERATOR MATCHES "Xcode")
        target_sources(${target} PRIVATE ${ARGN})
        set_source_files_properties(${ARGN} PROPERTIES
            MACOSX_PACKAGE_LOCATION "Resources/${directory}" HEADER_FILE_ONLY TRUE)
        return()
    endif()

    set(destination "$<TARGET_BUNDLE_CONTENT_DIR:${target}>")
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        string(APPEND destination "/Resources")
    endif()
    if(NOT directory STREQUAL "")
        string(APPEND destination "/${directory}")
    endif()

    get_property(group TARGET ${target} PROPERTY UBIQUITTY_RESOURCE_GROUP_COUNT)
    if(NOT group)
        set(group 0)
    endif()
    math(EXPR group "${group} + 1")
    set_property(TARGET ${target} PROPERTY UBIQUITTY_RESOURCE_GROUP_COUNT ${group})

    # Resolving the bundle path outside a command avoids CMP0112's implicit
    # dependency on the executable under the project's CMake 3.13 policy floor.
    set(destinationFile
        "${CMAKE_CURRENT_BINARY_DIR}/CMakeFiles/${target}-resources-${group}-$<CONFIG>.txt")
    file(GENERATE OUTPUT "${destinationFile}" CONTENT "${destination}")
    get_property(stagingScript GLOBAL PROPERTY UBIQUITTY_BUNDLE_RESOURCE_SCRIPT)

    # Swift-only Ninja targets have no object rule that requests package-location
    # sources. An explicit dependency also restores deleted bundle resources
    # without recompiling or relinking an unchanged executable.
    add_custom_target(${target}-resources-${group}
        COMMAND ${CMAKE_COMMAND}
            "-DUBIQUITTY_BUNDLE_DESTINATION_FILE=${destinationFile}"
            "-DUBIQUITTY_BUNDLE_RESOURCES=${ARGN}"
            -P "${stagingScript}"
        DEPENDS ${ARGN}
        COMMENT "Staging ${target} bundle resources"
        VERBATIM)
    add_dependencies(${target} ${target}-resources-${group})
endfunction()
