// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Tests/Platform/test_metal_shader_library.swift
//
// `MetalPipelines.moduleShaderLibrary(for:)` keeps the library a device first
// loads, so a window opened while the application is being replaced still has
// shaders to draw with.
//
// Every new window and tab builds a renderer, and the renderer asks for the
// module's shader library. An application replaced while it runs, by an update
// or a rebuild over its bundle, has no `default.metallib` for as long as the
// replacement lasts. A library read from the bundle on every request fails for
// all of that time, and so does every window asked for in it.
//
// The binary runs from a directory that holds a `default.metallib`: a
// command-line tool's main bundle is the directory it runs from, so that
// directory is the bundle the library is read from. The test takes the file
// away and puts it back itself, and checks two things in two processes:
//
// - held: a library loaded before the file goes is the one handed out while it
//   is gone, and it still builds its functions;
// - late: a request made while the file is gone answers nil, and a request
//   after it returns loads it, because a failed load is not kept.
//
// Compiled by plain `xcrun swiftc` with MetalPipelines.swift and
// ShippedResources.swift. A failure prints FAIL file:line, and any failure
// exits nonzero.
//

import Foundation
import Metal

var failures = 0

func check(_ condition: Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    if !condition {
        print("FAIL \(file):\(line): \(what)")
        failures += 1
    }
}

/// Moves the bundle's library aside, runs `body`, and moves it back.
///
/// - Parameters:
///   - library: The library file in the bundle.
///   - body: What runs while the bundle has no library.
func withoutLibraryFile(_ library: URL, _ body: () -> Void) {
    let away = library.deletingLastPathComponent().appendingPathComponent("default.metallib.away")
    try? FileManager.default.removeItem(at: away)
    do {
        try FileManager.default.moveItem(at: library, to: away)
    } catch {
        check(false, "the library file moves aside: \(error)")
        return
    }
    check(!FileManager.default.fileExists(atPath: library.path), "the bundle has no library file")
    body()
    do {
        try FileManager.default.moveItem(at: away, to: library)
    } catch {
        check(false, "the library file moves back: \(error)")
    }
}

/// A library loaded while the file is there is the one every later request gets.
func checkHeldLibrary(device: any MTLDevice, library: URL) {
    guard let first = MetalPipelines.moduleShaderLibrary(for: device) else {
        check(false, "the library loads while its file is in the bundle")
        return
    }
    guard let function = first.functionNames.first else {
        check(false, "the loaded library names a function")
        return
    }
    withoutLibraryFile(library) {
        let second = MetalPipelines.moduleShaderLibrary(for: device)
        check(second != nil, "a request while the bundle has no library still gets the loaded one")
        check(second === first, "the request gets the library loaded before the file went")
        check(second?.makeFunction(name: function) != nil, "the loaded library still builds its function")
    }
    check(MetalPipelines.moduleShaderLibrary(for: device) === first, "the library is not read again once the file is back")
}

/// A request made while the file is gone fails, and is not remembered as failed.
func checkLateLibrary(device: any MTLDevice, library: URL) {
    withoutLibraryFile(library) {
        check(MetalPipelines.moduleShaderLibrary(for: device) == nil, "a request with no library file answers nil")
    }
    check(MetalPipelines.moduleShaderLibrary(for: device) != nil, "the library loads once its file is back")
}

/// Runs the late phase in a process that has loaded no library yet.
///
/// - Returns: The child's exit status, or nil when it could not be started.
func runLatePhase() -> Int32? {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    child.arguments = ["--late"]
    do {
        try child.run()
    } catch {
        return nil
    }
    child.waitUntilExit()
    return child.terminationStatus
}

@main
struct MetalShaderLibraryTest {
    static func main() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            check(false, "a Metal device exists")
            print("test_metal_shader_library: no Metal device, so nothing to ask")
            exit(0)
        }
        guard let library = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
            check(false, "the directory the test runs from holds a default.metallib")
            exit(1)
        }
        if CommandLine.arguments.dropFirst().first == "--late" {
            checkLateLibrary(device: device, library: library)
            exit(failures == 0 ? 0 : 1)
        }
        checkHeldLibrary(device: device, library: library)
        let lateStatus = runLatePhase()
        check(lateStatus == 0, "the late phase passes in a process of its own")
        print(failures == 0 ? "test_metal_shader_library: PASS" : "test_metal_shader_library: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
