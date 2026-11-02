// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// ⚠️  No new code in this file. Write Swift, in the Swift arm.
//
// Objective-C++ on the macOS frontend is being retired: the Swift arm under
// Source/Platform/macOS/App is where logic lives, and it reaches Core
// directly through cxx-interop. Add nothing here. Do not grow an @objc seam to
// reach Swift from here either — existing seams shrink toward thin accessors
// and never grow. Migrate the surrounding code instead, by the recipes in
// Docs/swift-cxx-interop.md.

//
// UBBackgroundBlur.h — the compile-time gate for the behind-window blur.
// The blur drives the private CGSSetWindowBackgroundBlurRadius window-server
// call — fine for our own builds, not App Store safe — so it stays opt-in.
//
// Plain background translucency (background_opacity < 1, text stays solid)
// uses only public API and is always available. While either effect is
// active the window needs a non-opaque backing, which leaves a faint light
// seam on rounded window corners; the window stays fully opaque (no seam)
// until the user actually enables one.
//
// Enable the blur with the CMake option:
//
//     -DUBIQUITTY_BACKGROUND_BLUR=ON
//
// (Source/Platform/macOS/CMakeLists.txt maps it to this macro.) Shared by
// TerminalWindowController.swift and UBSettingsInterop.cpp so a single definition
// decides both the behavior and the Settings-UI gating.
//
#ifndef UB_ENABLE_BACKGROUND_BLUR
#define UB_ENABLE_BACKGROUND_BLUR 0
#endif
