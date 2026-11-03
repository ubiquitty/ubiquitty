# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# FrameworkBundleLayout.cmake — finishes a versioned macOS framework in the
# layout codesign seals inside an app.
#
#     cmake -DUBIQUITTY_FRAMEWORK=<bundle>.framework
#           -DUBIQUITTY_FRAMEWORK_VERSION=A
#           -DUBIQUITTY_FRAMEWORK_INTERFACE=<module>.swiftinterface
#           -DUBIQUITTY_FRAMEWORK_INTERFACE_NAME=<arch>-apple-macos.swiftinterface
#           -P FrameworkBundleLayout.cmake
#
# Everything the framework carries lives in its version directory: the binary,
# Resources and Modules. The root holds the Versions directory and one link per
# entry into Versions/Current, and nothing else. codesign refuses to sign an
# app embedding a framework whose root holds anything more ("unsealed contents
# present in the root directory of an embedded framework").
#
# The version directory holds nothing a build leaves behind. The compiler
# writes its dependency files beside the binary it links, and its dSYM when it
# emits debug information; a host embedding the bundle would ship them. The
# dependency files are read by nobody and removed. The dSYM moves beside the
# bundle, where a debugger finds it and a copy of the bundle leaves it.
#
# The script ends by refusing a bundle that still breaks the layout, so a later
# step writing into the root fails the build rather than the host's signing.
# That includes a bundle without its Info.plist, which codesign cannot seal:
# CMake writes the plist when it generates the build, and no build step writes
# it again, so a bundle deleted and rebuilt without generating comes out
# without one.

foreach(variable UBIQUITTY_FRAMEWORK UBIQUITTY_FRAMEWORK_VERSION UBIQUITTY_FRAMEWORK_INTERFACE
        UBIQUITTY_FRAMEWORK_INTERFACE_NAME)
    if(NOT DEFINED ${variable})
        message(FATAL_ERROR "FrameworkBundleLayout.cmake: ${variable} is not set")
    endif()
endforeach()

set(bundle "${UBIQUITTY_FRAMEWORK}")
get_filename_component(name "${bundle}" NAME_WE)
set(version "${bundle}/Versions/${UBIQUITTY_FRAMEWORK_VERSION}")
if(NOT EXISTS "${version}/${name}")
    message(FATAL_ERROR "FrameworkBundleLayout.cmake: no binary at ${version}/${name}")
endif()

# Replaces whatever is at `path` with a symbolic link to `target`.
function(replace_with_link target path)
    if(IS_SYMLINK "${path}")
        file(REMOVE "${path}")
    elseif(EXISTS "${path}")
        file(REMOVE_RECURSE "${path}")
    endif()
    execute_process(COMMAND "${CMAKE_COMMAND}" -E create_symlink "${target}" "${path}" RESULT_VARIABLE result)
    if(NOT result EQUAL 0)
        message(FATAL_ERROR "FrameworkBundleLayout.cmake: cannot link ${path} to ${target}")
    endif()
endfunction()

file(GLOB dependencyFiles "${version}/*.d")
if(dependencyFiles)
    file(REMOVE ${dependencyFiles})
endif()
if(IS_DIRECTORY "${version}/${name}.dSYM")
    file(REMOVE_RECURSE "${bundle}.dSYM")
    file(RENAME "${version}/${name}.dSYM" "${bundle}.dSYM")
endif()

# The textual interface and not the binary swiftmodule: a consumer reading the
# binary form demands every module this one imported, however the imports
# were scoped; the interface carries the public surface only.
set(module "${version}/Modules/${name}.swiftmodule")
file(REMOVE_RECURSE "${version}/Modules")
file(MAKE_DIRECTORY "${module}")
execute_process(
    COMMAND "${CMAKE_COMMAND}" -E copy "${UBIQUITTY_FRAMEWORK_INTERFACE}"
        "${module}/${UBIQUITTY_FRAMEWORK_INTERFACE_NAME}"
    RESULT_VARIABLE result)
if(NOT result EQUAL 0)
    message(FATAL_ERROR "FrameworkBundleLayout.cmake: cannot copy ${UBIQUITTY_FRAMEWORK_INTERFACE}")
endif()

replace_with_link("${UBIQUITTY_FRAMEWORK_VERSION}" "${bundle}/Versions/Current")
set(rootLinks "${name}" Resources Modules)
foreach(entry IN LISTS rootLinks)
    replace_with_link("Versions/Current/${entry}" "${bundle}/${entry}")
endforeach()

# What each directory may hold. `_CodeSignature` is there once the bundle is
# signed in place.
set(rootEntries Versions ${rootLinks})
set(versionEntries "${name}" Resources Modules Headers _CodeSignature)
file(GLOB entries LIST_DIRECTORIES true RELATIVE "${bundle}" "${bundle}/*" "${bundle}/.*")
foreach(entry IN LISTS entries)
    list(FIND rootEntries "${entry}" index)
    if(index LESS 0)
        message(FATAL_ERROR "FrameworkBundleLayout.cmake: ${bundle}/${entry} is outside the version directory; "
            "write it into Versions/${UBIQUITTY_FRAMEWORK_VERSION} and link it from the root")
    endif()
endforeach()
file(GLOB entries LIST_DIRECTORIES true RELATIVE "${version}" "${version}/*" "${version}/.*")
foreach(entry IN LISTS entries)
    list(FIND versionEntries "${entry}" index)
    if(index LESS 0)
        message(FATAL_ERROR "FrameworkBundleLayout.cmake: ${version}/${entry} is not part of a framework version")
    endif()
endforeach()
if(NOT EXISTS "${version}/Resources/Info.plist")
    message(FATAL_ERROR "FrameworkBundleLayout.cmake: no Info.plist in ${version}/Resources; "
        "CMake writes it when it generates the build, so generate again after deleting the bundle")
endif()
