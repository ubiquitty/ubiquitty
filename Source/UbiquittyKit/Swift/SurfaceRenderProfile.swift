// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(AppKit)
import AppKit
import Metal
import QuartzCore
internal import UbiquittyCore

/// Measures complete and incrementally damaged frames through the shipping renderer.
@MainActor
public enum SurfaceRenderProfile {
    /// Profiles and exits when the words ask for `--profile-render`; returns
    /// otherwise, so the app launches as usual.
    ///
    /// - Parameter arguments: The terminal's own command line, the program first.
    public static func runIfRequested(_ arguments: [String]) {
        guard arguments.contains("--profile-render") else { return }
        setenv("UBIQUITTY_FAKE_TICKS", "0", 0)
        func value(_ name: String, default fallback: String) -> String {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return fallback }
            return arguments[index + 1]
        }
        let rows = max(2, Int(value("--rows", default: "24")) ?? 24)
        let columns = max(2, Int(value("--columns", default: "80")) ?? 80)
        let scale = max(1, Double(value("--scale", default: "2")) ?? 2)
        let frames = max(1, Int(value("--frames", default: "300")) ?? 300)
        let warmup = max(0, Int(value("--warmup", default: "30")) ?? 30)
        guard rows <= Int(Ubiquitty.maxRows), columns <= Int(Ubiquitty.maxColumns),
            scale.isFinite, frames <= 1_000_000, warmup <= 1_000_000
        else {
            finish(2, "invalid grid or sampling bounds")
        }
        let retainsGrid = arguments.contains("--grid-cache")
        let ligatures = !arguments.contains("--no-ligatures")
        guard Ubiquitty.Preferences.configure(std.string("[font]\nligatures = \(ligatures)\n"), .Strict).isApplied else {
            finish(2, "could not configure the profile's ligatures")
        }
        var profiles: [[String: Any]] = []
        var renderedFrames = 0
        for scene in Ubiquitty.Diagnostics.RenderProfile.buildScenes(Int32(rows), Int32(columns)) {
            let name = String(cString: scene.name)
            if retainsGrid && scene.damageUnit.empty() {
                FileHandle.standardError.write(Data("profile: skipping \(name), which has no incremental damage fixture\n".utf8))
                continue
            }
            guard
                let capture = SurfaceSnapshot(
                    rows: rows,
                    columns: columns,
                    contentScale: scale,
                    configuration: Ubiquitty.Preferences.values().pointee
                )
            else {
                finish(2, "could not construct the surface")
            }
            capture.feed(scene.feed)
            capture.surface.viewOffset = Int(scene.viewOffset)
            if scene.hasSelection, let terminal = capture.surface.drive.borrowTerminal() {
                var bounds = Ubiquitty.SelectionBounds()
                bounds.row0 = Int32(min(3, rows - 1))
                bounds.column0 = Int32(min(2, columns - 1))
                bounds.row1 = Int32(min(9, rows - 1))
                bounds.column1 = Int32(max(2, columns / 2))
                capture.surface.selectionModel.session.pointee.state = Ubiquitty.Selection.characterSelectionOverVisibleRows(
                    terminal,
                    bounds
                )
            }
            if scene.hasBackgroundImage { installBackdrop(on: capture) }
            var total: [Double] = []
            var cpu: [Double] = []
            var gpu: [Double] = []
            var execution: [Double] = []
            for frame in 0..<(warmup + frames) {
                if retainsGrid {
                    var damage = ""
                    for band in 0..<3 {
                        damage += "\u{1b}[\(1 + ((frame * 3 + band) % rows));1H" + String(scene.damageUnit) + String(frame % 10)
                    }
                    capture.feed(std.string(damage + "\u{1b}[0m"))
                } else {
                    capture.surface.invalidateRetainedBaseline()
                }
                let start = CACurrentMediaTime()
                guard capture.render() else { finish(2, "renderer declined \(name)") }
                let duration = CACurrentMediaTime() - start
                renderedFrames += 1
                guard frame >= warmup else { continue }
                let wait = capture.renderer.offscreenGPUSeconds
                total.append(duration * 1e6)
                cpu.append(max(0, duration - wait) * 1e6)
                gpu.append(wait * 1e6)
                execution.append(capture.renderer.offscreenGPUExecutionSeconds * 1e6)
            }
            for (phase, samples) in [("total", total), ("cpu", cpu), ("gpu", gpu), ("gpuexec", execution)] {
                profiles.append(distribution(name: "render_" + name + "_" + phase, samples: samples))
            }
        }
        guard !profiles.isEmpty else { finish(2, "no scene produced a measurement") }
        let report: [String: Any] = [
            "platform": value("--platform", default: "macOS"), "commit": value("--commit", default: "unknown"),
            "renderer": "swift", "unit": "us", "profiles": profiles,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else {
            finish(2, "could not encode results")
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
        finish(0, "Swift renderer drew \(renderedFrames) frames")
    }

    private static func distribution(name: String, samples: [Double]) -> [String: Any] {
        let sorted = samples.sorted()
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(samples.count)
        func percentile(_ p: Double) -> Double {
            let position = p * Double(sorted.count - 1)
            let lower = Int(position)
            let upper = min(lower + 1, sorted.count - 1)
            return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
        }
        return [
            "name": name, "samples": samples.count, "mean": mean, "stddev": sqrt(variance),
            "min": sorted[0], "max": sorted[sorted.count - 1], "p50": percentile(0.5),
            "p90": percentile(0.9), "p95": percentile(0.95), "p99": percentile(0.99),
        ]
    }

    private static func installBackdrop(on capture: SurfaceSnapshot) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        guard let texture = capture.texture.device.makeTexture(descriptor: descriptor) else { finish(2, "no backdrop texture") }
        var pixels = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let offset = (y * 64 + x) * 4
                pixels[offset] = UInt8(x * 4)
                pixels[offset + 1] = UInt8(y * 4)
                pixels[offset + 2] = ((x / 8 + y / 8) % 2 == 0) ? 200 : 40
            }
        }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: 256)
        }
        capture.renderer.setBackdrop(texture: texture, opacity: 0.5, mode: 0, pixelWidth: 64, pixelHeight: 64)
    }

    private static func finish(_ status: Int32, _ message: String) -> Never {
        FileHandle.standardError.write(Data("profile: \(message)\n".utf8))
        _exit(status)
    }
}
#endif
