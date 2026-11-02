#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Compiles the controller's font fan-out bodies with headless Swift doubles.

The native UI and clipboard are never opened. This checks frontend delivery,
not Core receipt semantics or native drawing. Exit 77 means unavailable.
"""

import argparse
import math
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CONTROLLER = ROOT / "Source/Platform/macOS/App/Windowing/TerminalWindowController.swift"
SUCCESS = "PASS: configuration, OSC, and zoom reach local/tmux/remote panes; remote root deduplicated; sibling requests untouched"

PRELUDE = r'''
struct SurfaceTypography {
    init() {}
    init(configuration: Ubiquitty.Rendering.RenderConfiguration) {}
}
extension String { func empty() -> Bool { isEmpty } }
enum Ubiquitty {
    enum Rendering {
        struct FontFeatures { func string() -> String { "" } }
        // Core's fold of the configuration document, as far as the fan-out
        // reads it: the family is asked of the surface, which owns the house
        // fallback.
        struct RenderConfiguration {
            var fontSizePoints = 20.0
            var fontFeatures = FontFeatures()
            var usesDisplayP3 = false
        }
    }
    @MainActor enum Preferences {
        struct Configuration {}
        static let configuration: UnsafeMutablePointer<Configuration> = {
            let pointer = UnsafeMutablePointer<Configuration>.allocate(capacity: 1)
            pointer.initialize(to: Configuration())
            return pointer
        }()
        static func values() -> UnsafePointer<Configuration> { UnsafePointer(configuration) }
        enum Effective {
            static func liveRenderConfiguration() -> Rendering.RenderConfiguration { Rendering.RenderConfiguration() }
        }
        enum Zoom {
            static func zoomedFontSize(_ size: Double, _ offset: Double) -> Double { size + offset }
        }
    }
}
protocol TerminalSurfaceRenderer: AnyObject {}
// A projected surface can be drawn by a renderer the font fan-out has no
// adopt for. It still holds frames laid out on the cell the change moves.
@MainActor final class ForeignRenderer: TerminalSurfaceRenderer {}
@MainActor final class SurfaceRenderer: TerminalSurfaceRenderer {
    var familyName = "Initial"
    var pointSize = 12.0
    var typography = SurfaceTypography()
    @discardableResult func adopt(pointSize: Double, familyName: String, typography: SurfaceTypography) -> Bool {
        self.pointSize = pointSize
        self.familyName = familyName
        return true
    }
    func adopt(pointSize: Double, typography: SurfaceTypography) { self.pointSize = pointSize }
    func adopt(usesDisplayP3: Bool, relabeling: NSObject) {}
}
struct FontRequest { let isResolved = true; let family: String; let sizePoints: Double }
@MainActor final class RuntimeDrive {
    static let maxFontRequestsPerDelivery = 8
    var publications: [(String, Double)] = []
    var pending: FontRequest?
    var begins = 0
    var acknowledgments = 0
    func publishActualFont(family: String, sizePoints: Double) { publications.append((family, sizePoints)) }
    func beginFontRequest(configuredFamily: String, configuredSizePoints: Double) -> FontRequest? {
        begins += 1
        return pending
    }
    func acknowledgeFontRequest(_ request: FontRequest, didApply: Bool, actualFamily: String, actualSizePoints: Double) -> Bool {
        acknowledgments += 1
        pending = nil
        publishActualFont(family: actualFamily, sizePoints: actualSizePoints)
        return true
    }
}
@MainActor final class TerminalSurface {
    let drive = RuntimeDrive()
    let metalLayer = NSObject()
    var renderer: (any TerminalSurfaceRenderer)?
    var invalidations = 0
    var resizes = 0
    var needsDisplay = false
    init(_ renderer: any TerminalSurfaceRenderer) { self.renderer = renderer }
    static func family(of configuration: Ubiquitty.Rendering.RenderConfiguration) -> String { "Configured" }
    static func installedHouseFontFamily() -> String { "House" }
    func invalidateRetainedBaseline() { invalidations += 1 }
    // The real one releases the per-scale renderers and their retained grids
    // before it invalidates the baseline and asks for a draw. Nothing here
    // retains a grid, so the double keeps the two effects a caller can see.
    func discardRetainedFrames() { invalidateRetainedBaseline(); needsDisplay = true }
    func resizeGridToBounds() { resizes += 1 }
}
@MainActor final class TerminalWindowController {
    static var spawnedControllers: [TerminalWindowController] = []
    var surfaces: [Int: TerminalSurface] = [:]
    var tmuxSurfaces: [Int32: TerminalSurface] = [:]
    var remotePaneSurfaces: [Int: TerminalSurface] = [:]
    var remoteSurface: TerminalSurface?
    var surfaceRenderer: any TerminalSurfaceRenderer
    var fontZoomOffset = 0.0
    var cellMetricChanges = 0
    // What the last fan-out applied, which the controller records so a later
    // configuration change can tell whether the faces moved.
    var appliedTypographyConfiguration: Ubiquitty.Rendering.RenderConfiguration?
    init(_ renderer: any TerminalSurfaceRenderer) { surfaceRenderer = renderer }
    // The window-follows-the-font wrapper: the real one snapshots the window
    // before the mutation and resizes or reflows after it. Here it counts the
    // passes and runs the mutation, so the fan-out's delivery is what is
    // checked and the classification stays the controller's own test.
    func applyCellMetricChange(_ mutate: () -> Void) { cellMetricChanges += 1; mutate() }
    // A window with no profile draws under the live document's fold.
    var windowRenderConfiguration: Ubiquitty.Rendering.RenderConfiguration {
        Ubiquitty.Preferences.Effective.liveRenderConfiguration()
    }
    // The chrome the window re-dresses after the faces: painted by the real
    // controller, and no part of what reaches a pane.
    var isTerminalColorSpaceDisplayP3 = false
    var paintedChromeInputs: Int?
    func applyChromeTheme() {}
    func zoomForTest(_ offset: Double) { applyFontZoom(offset: offset) }
    var projectedSurfacesForTest: [TerminalSurface] { projectedSurfaces }
'''
ASSERTIONS = r'''
}

let renderer = SurfaceRenderer()
let unrelatedRenderer = SurfaceRenderer()
let local = TerminalSurface(renderer)
let tmux = TerminalSurface(renderer)
let remote = TerminalSurface(renderer)
let root = TerminalSurface(renderer)
let unrelated = TerminalSurface(unrelatedRenderer)
let foreign = TerminalSurface(ForeignRenderer())
let controller = TerminalWindowController(renderer)
controller.surfaces = [1: local]
controller.tmuxSurfaces = [2: tmux]
controller.remotePaneSurfaces = [3: remote, 4: root, 5: unrelated, 6: foreign]
controller.remoteSurface = root
TerminalWindowController.spawnedControllers = [controller]
let shared = [local, tmux, remote, root]
var failures = 0
@MainActor func expect(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: " + message) }
}

var appearanceNotifications = 0
let appearanceObserver = NotificationCenter.default.addObserver(
    forName: .terminalAppearanceChanged, object: nil, queue: .main
) { _ in
    MainActor.assumeIsolated {
        appearanceNotifications += 1
        for surface in controller.projectedSurfacesForTest {
            expect(surface.needsDisplay, "appearance observers see invalidated panes")
            guard surface.renderer is SurfaceRenderer else { continue }
            expect(surface.drive.publications.last?.0 == "Configured",
                   "appearance observers see the configured font after pane delivery")
        }
    }
}

TerminalWindowController.applyFontConfigurationToOpenWindows()
expect(appearanceNotifications == 1, "configuration notifies previews once for all panes")
for (index, surface) in shared.enumerated() {
    expect(surface.drive.publications.count == 1, "configuration publishes exactly once to pane \(index)")
    expect(surface.drive.publications.last?.0 == "Configured" && surface.drive.publications.last?.1 == 20,
           "configuration publishes both actual axes to pane \(index)")
    expect(surface.invalidations == 1 && surface.needsDisplay, "configuration invalidates pane \(index)")
}
expect(unrelated.drive.publications.count == 1, "configuration also reaches an independent projected renderer")
expect(foreign.drive.publications.isEmpty, "configuration publishes nothing through a renderer it cannot adopt")
expect(foreign.invalidations == 1 && foreign.needsDisplay,
       "configuration drops the retained frames of a pane it cannot adopt")
expect(controller.cellMetricChanges == 1, "configuration lands on a window in one wrapped cell-metric pass")

tmux.drive.pending = FontRequest(family: "PendingTmux", sizePoints: 28)
remote.drive.pending = FontRequest(family: "PendingRemote", sizePoints: 31)
local.drive.pending = FontRequest(family: "Requested", sizePoints: 25)
controller.applyFontSwap(on: local)
expect(local.drive.acknowledgments == 1, "only requester acknowledges its operation")
for (index, surface) in shared.dropFirst().enumerated() {
    expect(surface.drive.publications.count == 2, "OSC swap publishes once to sibling \(index)")
    expect(surface.drive.publications.last?.0 == "Requested" && surface.drive.publications.last?.1 == 25,
           "OSC swap publishes actual axes to sibling \(index)")
    expect(surface.drive.begins == 0 && surface.drive.acknowledgments == 0,
           "OSC swap cannot begin or acknowledge sibling \(index)'s operation")
    expect(surface.invalidations == 2 && surface.resizes == 1, "OSC swap invalidates and resizes sibling \(index)")
}
expect(tmux.drive.pending != nil && remote.drive.pending != nil, "sibling requests remain pending")
expect(unrelated.drive.publications.count == 1, "OSC swap leaves a different renderer untouched")
expect(foreign.invalidations == 1, "OSC swap leaves a pane it cannot adopt untouched")

controller.zoomForTest(3)
for (index, surface) in shared.enumerated() {
    expect(surface.drive.publications.count == 3, "zoom publishes once to pane \(index)")
    expect(surface.drive.publications.last?.0 == "Requested" && surface.drive.publications.last?.1 == 23,
           "zoom publishes both actual axes to pane \(index)")
    expect(surface.invalidations == 3, "zoom invalidates pane \(index)")
}
expect(controller.cellMetricChanges == 2, "zoom is one wrapped cell-metric pass as well")
expect(foreign.invalidations == 2 && foreign.drive.publications.isEmpty,
       "zoom invalidates a pane it cannot adopt without publishing through it")
expect(appearanceNotifications == 1, "pane OSC and zoom do not change the configuration preview")
let detachedRoot = TerminalSurface(renderer)
controller.remoteSurface = detachedRoot
TerminalWindowController.applyFontConfigurationToOpenWindows()
expect(detachedRoot.drive.publications.count == 1, "configuration includes a remote root outside the pane maps")
expect(root.drive.publications.count == 4, "replacing remote root does not remove its mapped pane")
expect(appearanceNotifications == 2, "each configuration application notifies previews once")
TerminalWindowController.spawnedControllers = []
TerminalWindowController.applyFontConfigurationToOpenWindows()
expect(appearanceNotifications == 3, "configuration reaches previews with no terminal windows")
NotificationCenter.default.removeObserver(appearanceObserver)
if failures != 0 { exit(1) }
print("PASS: configuration, OSC, and zoom reach local/tmux/remote panes; remote root deduplicated; sibling requests untouched")
'''


def declaration(source, marker):
    if source.count(marker) != 1:
        raise ValueError(f"expected exactly one declaration: {marker}")
    start = source.index(marker)
    body = source.index("{", start)
    depth = 1
    end = body + 1
    while depth and end < len(source):
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    if depth:
        raise ValueError(f"unterminated declaration: {marker}")
    return source[start:end]


# A marker names a declaration and, where the double relies on it, the
# `static` that puts it on the type. Access modifiers stay out: visibility is
# not part of the fan-out this control pins, and a marker that spells one
# stops finding its declaration the moment the modifier is widened.
MARKERS = (
    "static func applyFontConfigurationToOpenWindows()",
    "var projectedSurfaces:",
    "func applyFontSwap(on surface:",
    "func applyFontZoom(offset:",
    "func applyWindowTypography()",
)


def driver_source(source, old_control):
    bodies = [declaration(source, marker) for marker in MARKERS]
    if old_control:
        replacements = (
            (4, "for surface in projectedSurfaces {", "for surface in surfaces.values {"),
            (2, "for sibling in projectedSurfaces", "for sibling in Array(surfaces.values) + Array(tmuxSurfaces.values)"),
            (3, "for surface in projectedSurfaces {", "for surface in Array(surfaces.values) + Array(tmuxSurfaces.values) {"),
        )
        for index, current, old in replacements:
            if bodies[index].count(current) != 1:
                raise ValueError(f"old control cannot identify the fan-out: {current}")
            bodies[index] = bodies[index].replace(current, old, 1)
    notifications = declaration(source, "extension Notification.Name")
    return "import Foundation\n\n" + notifications + PRELUDE + "\n".join(bodies) + ASSERTIONS


def bounded_timeout(value):
    number = float(value)
    if not math.isfinite(number) or not 0 < number <= 120:
        raise argparse.ArgumentTypeError("timeout must be finite and between 0 and 120 seconds")
    return number


def run_step(command, timeout, label):
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, start_new_session=True) as process:
        try:
            output, _ = process.communicate(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            output, _ = process.communicate()
            if isinstance(error, KeyboardInterrupt):
                raise
            return 1, output + f"FAIL: {label} exceeded {timeout:g} seconds\n"
        return process.returncode, output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controller", type=Path, default=CONTROLLER)
    parser.add_argument("--list-sources", action="store_true", help="lists the exact production input without compiling")
    parser.add_argument("--old-control", action="store_true", help="restores the incomplete loops and must fail")
    parser.add_argument("--swiftc", default=os.environ.get("SWIFTC", "swiftc"), help="Swift compiler executable, not a shell command")
    parser.add_argument("--compile-timeout", type=bounded_timeout, default=120)
    parser.add_argument("--execution-timeout", type=bounded_timeout, default=10)
    arguments = parser.parse_args()

    try:
        controller = arguments.controller.resolve(strict=True)
        source = controller.read_text()
        if arguments.list_sources:
            print(controller)
            return 0
        driver = driver_source(source, arguments.old_control)
        if platform.system() != "Darwin":
            print("UNAVAILABLE: test_font_fanout requires Darwin", file=sys.stderr)
            return 77
        compiler = shutil.which(arguments.swiftc)
        if compiler is None:
            print(f"UNAVAILABLE: Swift compiler not found: {arguments.swiftc}", file=sys.stderr)
            return 77
        with tempfile.TemporaryDirectory(prefix="ubiquitty-font-fanout-") as directory:
            path = Path(directory)
            swift = path / "control.swift"
            binary = path / "control"
            swift.write_text(driver)
            status, output = run_step(
                [compiler, "-swift-version", "6", "-package-name", "ubiquitty", str(swift), "-o", str(binary)],
                arguments.compile_timeout, "Swift compilation",
            )
            print(output, end="")
            if status:
                print(f"FAIL: Swift compilation exited {status}", file=sys.stderr)
                return 1
            status, output = run_step([str(binary)], arguments.execution_timeout, "font fan-out control")
            print(output, end="")
            if status:
                print(f"FAIL: font fan-out control exited {status}", file=sys.stderr)
                return 1
            if output.splitlines().count(SUCCESS) != 1:
                print("FAIL: font fan-out control did not report its completed assertions", file=sys.stderr)
                return 1
    except (OSError, ValueError) as error:
        print(f"FAIL: font fan-out control: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
