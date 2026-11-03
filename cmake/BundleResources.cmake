# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

include_guard(GLOBAL)

set_property(GLOBAL PROPERTY UBIQUITTY_BUNDLE_RESOURCE_SCRIPT
    "${CMAKE_CURRENT_LIST_DIR}/StageBundleResources.cmake")

# The directory a bundle target's resources are written to, as a generator
# expression.
#
# A macOS framework's are its current version's, written to that directory
# itself rather than through the `Resources` link at its root. The root holds
# only links into the version, which is what codesign requires of a framework
# embedded in an app, and a write through a link that is missing makes a
# directory there instead.
#
# - Parameters:
#   - target: The bundle target.
#   - output: The variable that receives the expression.
function(ubiquitty_bundle_resource_root target output)
    get_target_property(isFramework ${target} FRAMEWORK)
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        set(root "$<TARGET_BUNDLE_CONTENT_DIR:${target}>")
    elseif(isFramework)
        set(root "$<TARGET_FILE_DIR:${target}>/Resources")
    else()
        set(root "$<TARGET_BUNDLE_CONTENT_DIR:${target}>/Resources")
    endif()
    set(${output} "${root}" PARENT_SCOPE)
endfunction()

# Stages resources beneath the platform's bundle resource directory.
#
# - Parameters:
#   - target: The bundle target.
#   - directory: The resource subdirectory, or an empty string for its root.
#   - ARGN: The resource files to copy.
function(ubiquitty_bundle_resources target directory)
    ubiquitty_stage_bundle_resources(${target} "${directory}" FALSE ${ARGN})
endfunction()

# Stages a resource subdirectory whole: after every build it holds the files
# given and nothing else, so a file the tree drops leaves an incrementally
# built bundle rather than shipping on in it. No other staging writes into the
# directory. Under Xcode the build system copies the files, and removes none.
#
# - Parameters:
#   - target: The bundle target.
#   - directory: The resource subdirectory.
#   - ARGN: The resource files the directory holds.
function(ubiquitty_bundle_resource_directory target directory)
    if(directory STREQUAL "")
        message(FATAL_ERROR "${target}: a resource directory staged whole needs a name, not the resource root")
    endif()
    ubiquitty_stage_bundle_resources(${target} "${directory}" TRUE ${ARGN})
endfunction()

# Stages resources for the two functions above.
#
# - Parameters:
#   - target: The bundle target.
#   - directory: The resource subdirectory, or an empty string for its root.
#   - isWhole: Whether the subdirectory holds these files and nothing else.
#   - ARGN: The resource files to copy.
function(ubiquitty_stage_bundle_resources target directory isWhole)
    get_property(stagedDirectories TARGET ${target} PROPERTY UBIQUITTY_STAGED_RESOURCE_DIRECTORIES)
    get_property(wholeDirectories TARGET ${target} PROPERTY UBIQUITTY_WHOLE_RESOURCE_DIRECTORIES)
    list(FIND stagedDirectories "${directory}" stagedIndex)
    list(FIND wholeDirectories "${directory}" wholeIndex)
    if(NOT wholeIndex EQUAL -1 OR (isWhole AND NOT stagedIndex EQUAL -1))
        message(FATAL_ERROR "${target} stages the resource directory '${directory}' twice, and one staging holds it whole")
    endif()
    set_property(TARGET ${target} APPEND PROPERTY UBIQUITTY_STAGED_RESOURCE_DIRECTORIES "${directory}")
    if(isWhole)
        set_property(TARGET ${target} APPEND PROPERTY UBIQUITTY_WHOLE_RESOURCE_DIRECTORIES "${directory}")
    endif()

    if(CMAKE_GENERATOR MATCHES "Xcode")
        target_sources(${target} PRIVATE ${ARGN})
        set_source_files_properties(${ARGN} PROPERTIES
            MACOSX_PACKAGE_LOCATION "Resources/${directory}" HEADER_FILE_ONLY TRUE)
        return()
    endif()

    ubiquitty_bundle_resource_root(${target} destination)
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
            "-DUBIQUITTY_BUNDLE_WHOLE_DIRECTORY=${isWhole}"
            -P "${stagingScript}"
        DEPENDS ${ARGN}
        COMMENT "Staging ${target} bundle resources"
        VERBATIM)
    add_dependencies(${target} ${target}-resources-${group})
endfunction()
