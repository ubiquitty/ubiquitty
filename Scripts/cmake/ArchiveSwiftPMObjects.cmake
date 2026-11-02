# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# ArchiveSwiftPMObjects.cmake — hand a SwiftPM library's objects, as one archive,
# and the flags that import its modules to a consumer outside SwiftPM.
#
# SwiftPM's default build system leaves a static library product as
# lib<Product>.a in its products folder: one object per module of the product's
# graph, each named for its module, beside that module's <Module>.swiftmodule.
# The archive is copied as it is, so the link gets the modules the product
# depends on and no other module the package graph happens to build.
#
# Run as `cmake -DPRODUCTS=<products folder> -DMODULE_MAPS=<generated module maps>
# -DCHECKOUTS=<checkouts> -DLIBRARY=<product> -DARCHIVE=<out> -DFLAGS=<out> -P thisfile`.
#

foreach(_required PRODUCTS MODULE_MAPS CHECKOUTS LIBRARY ARCHIVE FLAGS)
    if(NOT DEFINED ${_required} OR "${${_required}}" STREQUAL "")
        message(FATAL_ERROR "ArchiveSwiftPMObjects.cmake needs -D${_required}=...")
    endif()
endforeach()

set(_library "${PRODUCTS}/lib${LIBRARY}.a")
if(NOT EXISTS "${_library}")
    message(FATAL_ERROR
        "ArchiveSwiftPMObjects: SwiftPM left no ${_library} — did the build run, for the "
        "platform this folder is named for, with ${LIBRARY} a static library product?")
endif()
execute_process(
    COMMAND xcrun ar t "${_library}"
    OUTPUT_VARIABLE _members
    RESULT_VARIABLE _result
    ERROR_VARIABLE _error)
if(NOT _result EQUAL 0)
    message(FATAL_ERROR "ArchiveSwiftPMObjects: ar could not list ${_library}: ${_error}")
endif()
string(REGEX MATCHALL "[^\n]+\\.o" _objects "${_members}")
list(LENGTH _objects _count)
# An empty archive links cleanly and defines nothing, and the first sign would
# be an undefined symbol in whatever consumed it.
if(_count LESS 1)
    message(FATAL_ERROR "ArchiveSwiftPMObjects: ${_library} holds no objects")
endif()
# Touched after the copy, which may keep the source's time: a build system that
# finds this output older than an input it was remade for remakes it again.
file(COPY_FILE "${_library}" "${ARCHIVE}")
file(TOUCH "${ARCHIVE}")

# The compile flags a consumer needs, written beside the archive.
#
# The module search path is the products folder, where each module's
# .swiftmodule sits. The module maps come from two places, because SwiftPM
# writes a map for a module only when the module ships none of its own: the
# generated ones, for every Swift module and for a C module without a map,
# are in one folder per platform, and a C module that ships a map keeps it in
# its checkout — `_AtomicsShims`, which `Atomics` imports, is one. Taking both
# names each module once. They are read here, at the moment they exist, rather
# than guessed at configure time when the folders are still empty.
file(GLOB _generatedMaps "${MODULE_MAPS}/*.modulemap")
list(LENGTH _generatedMaps _generatedCount)
if(_generatedCount LESS 1)
    message(FATAL_ERROR "ArchiveSwiftPMObjects: no module maps under ${MODULE_MAPS}")
endif()
file(GLOB_RECURSE _checkoutMaps "${CHECKOUTS}/*/Sources/*/include/module.modulemap")
set(_moduleMaps ${_generatedMaps} ${_checkoutMaps})
list(LENGTH _moduleMaps _mapCount)
set(_flags "-I\n${PRODUCTS}\n")
foreach(_map IN LISTS _moduleMaps)
    string(APPEND _flags "-Xcc\n-fmodule-map-file=${_map}\n")
endforeach()
file(WRITE "${FLAGS}" "${_flags}")

message(STATUS "ArchiveSwiftPMObjects: ${_count} object(s) -> ${ARCHIVE}; ${_mapCount} module map(s) -> ${FLAGS}")
