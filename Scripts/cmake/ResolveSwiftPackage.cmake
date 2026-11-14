# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

include_guard(GLOBAL)

# Resolution alone may retry a transient transport failure. A stale lockfile,
# invalid package, or compiler failure must retain its first failed verdict.
function(ubiquitty_resolve_swift_package)
    foreach(_attempt RANGE 1 3)
        message(STATUS "Resolving pinned Swift packages (attempt ${_attempt}/3)")
        execute_process(COMMAND ${ARGN}
            RESULT_VARIABLE _status TIMEOUT 300
            OUTPUT_VARIABLE _output ERROR_VARIABLE _error
            ECHO_OUTPUT_VARIABLE ECHO_ERROR_VARIABLE)
        if(_status STREQUAL "0")
            return()
        endif()
        string(TOLOWER "${_output}\n${_error}" _diagnostic)
        if(_attempt EQUAL 3 OR NOT _diagnostic MATCHES
                "could not resolve (host|proxy)|failed to connect|could not connect to server|connection reset by peer|connection timed out|recv failure|early eof|tls connection was non-properly terminated")
            message(FATAL_ERROR "Swift package resolution failed (${_status}) after ${_attempt} attempt(s)")
        endif()
        math(EXPR _delay "${_attempt} * 2")
        message(STATUS "Transient Swift package fetch failure; retrying in ${_delay}s")
        execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep "${_delay}")
    endforeach()
endfunction()
