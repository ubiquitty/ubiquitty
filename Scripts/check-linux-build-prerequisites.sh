#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# check-linux-build-prerequisites.sh — refuse a Linux frontend build that would
# stop at configure time, and say what to install instead.
#
# Named one at a time rather than left to "cmake failed": the GTK 4 and Vulkan
# development files are what a desktop machine usually lacks, and CMake's
# report of a missing pkg-config module names the module, not the package a
# distribution ships it in.

set -uo pipefail

compiler="${CXX:-c++}"
absent=()

presentOnPath() { command -v "$1" >/dev/null 2>&1; }

for tool in cmake pkg-config "$compiler"; do
    presentOnPath "$tool" || absent+=("$tool")
done

# GTK 4.16 is the floor CMakeLists.txt asks pkg-config for. An older GTK is
# present and still refused at configure, so its version is what is named.
if presentOnPath pkg-config; then
    if ! pkg-config --exists gtk4; then
        absent+=("gtk4 development files")
    elif ! pkg-config --atleast-version=4.16 gtk4; then
        absent+=("GTK 4.16 or newer (this is $(pkg-config --modversion gtk4))")
    fi
    pkg-config --exists vulkan || absent+=("Vulkan development files")
fi

# A loader package without its headers configures and then fails on the first
# include; one preprocessor pass over the header answers that up front.
if presentOnPath "$compiler" && ! "$compiler" -E -x c++ -include vulkan/vulkan.h /dev/null >/dev/null 2>&1; then
    absent+=("Vulkan headers")
fi

# The renderer's shaders are compiled by glslc. Without it the configure stops,
# unless the build asked for a CPU-only binary with UBIQUITTY_LINUX_GPU_SHADERS=OFF.
# The value is read as CMake reads the option: `0`, `OFF`, `NO`, `FALSE`, `N`,
# `IGNORE`, `NOTFOUND` and anything ending in `-NOTFOUND` are false in any
# case. Unset or empty is on, as build-linux-gtk.sh passes it.
shopt -s nocasematch
case "${UBIQUITTY_LINUX_GPU_SHADERS:-ON}" in
    0 | OFF | NO | FALSE | N | IGNORE | NOTFOUND | *-NOTFOUND) ;;
    *) presentOnPath glslc || absent+=("glslc") ;;
esac
shopt -u nocasematch

[ "${#absent[@]}" -eq 0 ] && exit 0

{
    echo "build-linux-gtk: missing prerequisites: ${absent[*]}"
    echo "Install them with one of:"
    echo "  Debian 13, Ubuntu 26.04 and newer: sudo apt install cmake ninja-build g++ pkg-config libgtk-4-dev libvulkan-dev glslc"
    echo "    (Ubuntu 24.04's GTK is 4.14, below the 4.16 floor)"
    echo "  Fedora: sudo dnf install cmake ninja-build gcc-c++ pkgconf-pkg-config gtk4-devel vulkan-loader-devel glslc"
    echo "  Arch: sudo pacman -S cmake ninja gcc pkgconf gtk4 vulkan-headers vulkan-icd-loader shaderc"
    echo "Without glslc, UBIQUITTY_LINUX_GPU_SHADERS=OFF builds a binary that renders on the CPU only."
} >&2
exit 1
