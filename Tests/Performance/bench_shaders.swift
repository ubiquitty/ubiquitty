// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// bench_shaders.swift — GPU lane for the terminal's shading passes.
//
// Every other lane in this directory measures the CPU side of a frame. This
// encodes the real vertex and fragment stages from UBShaders.metal against an
// offscreen target and times the GPU, so a change to a shader can be judged
// before it ships.
//
// Metal puts it outside the portable bench battery: it is built and driven by
// Scripts/bench-shader-ab.sh rather than by CMake.
//
// Two metallibs, one host, so the arms differ only in the shader. Both are
// rendered once and compared pixel for pixel before anything is timed — a
// shader that is faster because it draws less is not faster — and the ink is
// counted so two arms cannot agree by both drawing nothing.
//
// Six passes, because a frame is not only its shading. `cell` and `glyph`
// shade; `grid` encodes both the way a frame does; `blit` is the fullscreen
// copy of the retained grid into the drawable, `copy` the same movement
// through the blit encoder rather than a shader, and `clear` a store-only
// pass. The three copy-shaped passes take no shader arm, so running one
// metallib against itself is how their absolute cost is read.
//
//   bench_shaders <A.metallib> <B.metallib> [grid|cell|glyph|blit|copy|clear]
//                 [fraction] [rounds] [backgroundOpacity] [defaultBackgroundAlpha]
//
// UBQ_BLIT_NEAREST makes arm B sample the blit source with nearest instead of
// linear — a sampler is host state, so no pair of metallibs can express it.
//
// UBQ_GLYPH_QUAD_SCALE scales every glyph quad, which is the ceiling on
// tightening one to its ink rather than its slot.

import Darwin
import Foundation
import Metal
import simd

/// The shaders' uniform block, laid out as UBShaders.metal reads it.
struct Uniforms {
    var viewportSizeInPixels = SIMD2<Float>()
    var cellSizeInPixels = SIMD2<Float>()
    var originInPixels = SIMD2<Float>()
    var backgroundOpacity: Float = 0
    var defaultBackground = SIMD4<Float>()
    var edgeToEdge: Int32 = 0
}

/// Both instance streams share this shape; the first two fields are named
/// differently per pass (grid position vs pixel origin) but occupy the same
/// bytes, which is what the Core-side offsetof asserts pin.
struct Instance {
    var a = SIMD2<Float>()
    var b = SIMD2<Float>()
    var foreground = SIMD4<Float>()
    var background = SIMD4<Float>()
    var atlasTopLeft = SIMD2<Float>()
    var atlasBottomRight = SIMD2<Float>()
}

/// Which stage pair a pipeline carries. The grid pass needs two, so the
/// variant is a parameter rather than read off the mode.
enum Stages {
    case cell
    case glyph
    case blit
}

func median(_ values: [Double]) -> Double {
    if values.isEmpty {
        return 0.0
    }
    return values.sorted()[values.count / 2]
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// The linear congruential stream every run draws the screen from, so two
/// launches build the same corpus.
struct ScreenRandom {
    var state: UInt32 = 0x9E37_79B9

    mutating func next() -> UInt32 {
        state = state &* 1_664_525 &+ 1_013_904_223
        return state
    }

    /// A screen shaped like a terminal at rest: mostly the default background,
    /// a minority carrying an SGR colour.
    mutating func background() -> SIMD4<Float> {
        if next() % 100 < 15 {
            let red = Float(next() % 256) / 255.0
            let green = Float(next() % 256) / 255.0
            let blue = Float(next() % 256) / 255.0
            return SIMD4<Float>(red, green, blue, 1.0)
        }
        return SIMD4<Float>(0.11, 0.11, 0.13, 1.0)
    }
}

@main
struct BenchShaders {
    static func main() {
        precondition(MemoryLayout<Instance>.stride == 64, "must match the Metal layout")
        precondition(MemoryLayout<Instance>.offset(of: \.foreground) == 16)
        precondition(MemoryLayout<Instance>.offset(of: \.background) == 32)
        precondition(MemoryLayout<Instance>.offset(of: \.atlasTopLeft) == 48)
        precondition(MemoryLayout<Uniforms>.offset(of: \.defaultBackground) == 32)
        precondition(MemoryLayout<Uniforms>.offset(of: \.edgeToEdge) == 48)
        precondition(MemoryLayout<Uniforms>.stride == 64)

        let arguments = CommandLine.arguments
        if arguments.count < 3 {
            printError(
                "usage: bench_shaders <A.metallib> <B.metallib> [cell|glyph] [fraction] [rounds] [backgroundOpacityKnob] [defaultBackgroundAlpha]"
            )
            exit(2)
        }
        let passName = arguments.count > 3 ? arguments[3] : ""
        let isGlyphPass = passName == "glyph"
        let isBlitPass = passName == "blit"
        // The renderer encodes cells, glyphs and rules into one render pass, so
        // the target is loaded and stored once for all of them. Timing a pass
        // alone charges it that traffic on its own, which double-counts against
        // a frame when the per-pass figures are added up. `grid` encodes the two
        // draws the way the frame does.
        let isGridPass = passName == "grid"
        let isClearPass = passName == "clear"
        let isCopyPass = passName == "copy"
        let environment = ProcessInfo.processInfo.environment
        let isNearestArmB = environment["UBQ_BLIT_NEAREST"] != nil
        let fraction = arguments.count > 4 ? Float(atof(arguments[4])) : (isGlyphPass ? 0.4 : 0.0)
        let rounds = arguments.count > 5 ? Int(atoi(arguments[5])) : 25
        let backgroundOpacityKnob = arguments.count > 6 ? Float(atof(arguments[6])) : 1.0
        let defaultBackgroundAlpha = arguments.count > 7 ? Float(atof(arguments[7])) : 1.0

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            printError("no Metal device")
            exit(1)
        }

        // The shipping drawable is sRGB, so the fragment stage emits linear and
        // the hardware re-encodes. A plain unorm target would change what the
        // shader is required to compute.
        let width = 3024
        let height = 1964
        let cellWidth: Float = 16.0
        let cellHeight: Float = 38.0
        let columns = Int(Float(width) / cellWidth)
        let rows = Int(Float(height) / cellHeight)
        let cellCount = columns * rows

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .private
        let target = device.makeTexture(descriptor: targetDescriptor)!

        let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 512,
            height: 512,
            mipmapped: false
        )
        atlasDescriptor.usage = .shaderRead
        let atlas = device.makeTexture(descriptor: atlasDescriptor)!
        do {
            // Stroke-shaped, not noise. A glyph occupies a minority of its slot
            // and the rest of the slot is zero coverage, so an atlas of dense
            // noise both overstates what the glyph pass shades and hides every
            // question about what the empty majority costs.
            var pixels = [UInt8](repeating: 0, count: 512 * 512)
            for y in 0..<512 {
                for x in 0..<512 {
                    let slotX = x % 16
                    let slotY = y % 32
                    let stem = 4 + (x / 16 + y / 32) % 3
                    let toStem = abs(Float(slotX) - Float(stem))
                    let toBar = abs(Float(slotY) - 16.0)
                    let distance = min(toStem, toBar < 1.5 ? 0.0 : toBar - 1.5)
                    let coverage = min(max(1.5 - distance, 0.0), 1.0)
                    pixels[y * 512 + x] = UInt8(coverage * 255.0 + 0.5)
                }
            }
            atlas.replace(region: MTLRegionMake2D(0, 0, 512, 512), mipmapLevel: 0, withBytes: pixels, bytesPerRow: 512)
        }

        // The source the copy passes move is the retained grid, so it is
        // declared as TerminalRenderer declares that texture: private storage
        // and render-target usage, which is what leaves the hardware free to
        // keep it losslessly compressed. Managed storage, or bytes uploaded
        // from the CPU, forfeit that — and a copy pass reads whatever the
        // compression left, so either one measures a texture the renderer
        // never has. It is filled by rendering the cell pass into it for the
        // same reason: a terminal screen is mostly one background colour, and
        // how well that compresses is part of what the copy costs.
        var blitSource: MTLTexture?
        if isBlitPass || isCopyPass {
            let blitDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb,
                width: width,
                height: height,
                mipmapped: false
            )
            blitDescriptor.usage = [.shaderRead, .renderTarget]
            blitDescriptor.storageMode = .private
            blitSource = device.makeTexture(descriptor: blitDescriptor)
        }

        let linearDescriptor = MTLSamplerDescriptor()
        linearDescriptor.minFilter = .linear
        linearDescriptor.magFilter = .linear
        let sampler = device.makeSamplerState(descriptor: linearDescriptor)!
        let nearestDescriptor = MTLSamplerDescriptor()
        nearestDescriptor.minFilter = .nearest
        nearestDescriptor.magFilter = .nearest
        let nearestSampler = device.makeSamplerState(descriptor: nearestDescriptor)!
        let armSampler = [sampler, (isBlitPass && isNearestArmB) ? nearestSampler : sampler]

        var random = ScreenRandom()

        // A glyph quad is its atlas slot, and the ink inside it is smaller.
        // Scaling the quad asks what a tighter one would be worth without
        // building the bounds an atlas does not currently keep.
        let quadScale = environment["UBQ_GLYPH_QUAD_SCALE"].map { Float(atof($0)) } ?? 1.0
        var instances: [Instance] = []
        var glyphInstances: [Instance] = []
        if isGlyphPass {
            // One quad per inked cell, sized like a glyph slot and placed on the
            // grid the cell pass painted.
            for index in 0..<cellCount {
                if Float(random.next() % 1000) / 1000.0 >= fraction {
                    continue
                }
                var glyph = Instance()
                glyph.a = SIMD2<Float>(Float(index % columns) * cellWidth, Float(index / columns) * cellHeight)
                glyph.b = SIMD2<Float>(cellWidth * quadScale, cellHeight * quadScale)
                glyph.foreground = SIMD4<Float>(0.85, 0.86, 0.88, 1.0)
                glyph.background = random.background()
                let u0 = Float(random.next() % 480)
                let v0 = Float(random.next() % 480)
                glyph.atlasTopLeft = SIMD2<Float>(u0, v0)
                glyph.atlasBottomRight = SIMD2<Float>(u0 + 10.0, v0 + 24.0)
                instances.append(glyph)
            }
        } else {
            instances.reserveCapacity(cellCount)
            for index in 0..<cellCount {
                var cell = Instance()
                cell.a = SIMD2<Float>(Float(index % columns), Float(index / columns))
                cell.b = SIMD2<Float>(1.0, 0.0) // widthCells, then padding
                cell.foreground = SIMD4<Float>(0.85, 0.86, 0.88, 1.0)
                cell.background = random.background()
                let hasGlyph = Float(random.next() % 1000) / 1000.0 < fraction
                let u0 = hasGlyph ? Float(random.next() % 480) : 0.0
                let v0 = hasGlyph ? Float(random.next() % 480) : 0.0
                // A subpixel-glyph frontend leaves the cell carrying background
                // only and sends the glyph down its own stream, which is the
                // shape the macOS arm builds.
                if isGridPass {
                    cell.atlasTopLeft = SIMD2<Float>(0.0, 0.0)
                    cell.atlasBottomRight = SIMD2<Float>(0.0, 0.0)
                    if hasGlyph {
                        var glyph = Instance()
                        glyph.a = SIMD2<Float>(Float(index % columns) * cellWidth, Float(index / columns) * cellHeight)
                        glyph.b = SIMD2<Float>(cellWidth * quadScale, cellHeight * quadScale)
                        glyph.foreground = cell.foreground
                        glyph.background = cell.background
                        glyph.atlasTopLeft = SIMD2<Float>(u0, v0)
                        glyph.atlasBottomRight = SIMD2<Float>(u0 + 10.0, v0 + 24.0)
                        glyphInstances.append(glyph)
                    }
                    instances.append(cell)
                    continue
                }
                cell.atlasTopLeft = SIMD2<Float>(u0, v0)
                cell.atlasBottomRight = hasGlyph ? SIMD2<Float>(u0 + 10.0, v0 + 24.0) : SIMD2<Float>(u0, v0)
                instances.append(cell)
            }
        }
        let instanceCount = instances.count
        // Absent when a glyph pass inks no cell; the pass then draws nothing and
        // the agreement check below refuses the empty target.
        let instanceBuffer =
            instances.isEmpty
            ? nil
            : device.makeBuffer(
                bytes: instances,
                length: instances.count * MemoryLayout<Instance>.stride,
                options: .storageModeShared
            )
        let glyphInstanceBuffer =
            glyphInstances.isEmpty
            ? nil
            : device.makeBuffer(
                bytes: glyphInstances,
                length: glyphInstances.count * MemoryLayout<Instance>.stride,
                options: .storageModeShared
            )
        let glyphInstanceCount = glyphInstances.count

        var uniforms = Uniforms()
        uniforms.viewportSizeInPixels = SIMD2<Float>(Float(width), Float(height))
        uniforms.cellSizeInPixels = SIMD2<Float>(cellWidth, cellHeight)
        uniforms.originInPixels = SIMD2<Float>(0.0, 0.0)
        uniforms.backgroundOpacity = backgroundOpacityKnob
        uniforms.defaultBackground = SIMD4<Float>(0.11, 0.11, 0.13, defaultBackgroundAlpha)
        uniforms.edgeToEdge = 0
        // Sized by stride, which carries the tail padding the shader's block
        // has, and zeroed so that padding is defined.
        let uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared)!
        uniformBuffer.contents().initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<Uniforms>.stride)
        uniformBuffer.contents().storeBytes(of: uniforms, as: Uniforms.self)

        func makeLibrary(_ path: String) -> MTLLibrary {
            do {
                return try device.makeLibrary(URL: URL(fileURLWithPath: path))
            } catch {
                printError("library \(path): \(error.localizedDescription)")
                exit(1)
            }
        }

        func makePipeline(_ path: String, _ stages: Stages) -> MTLRenderPipelineState {
            let library = makeLibrary(path)
            let descriptor = MTLRenderPipelineDescriptor()
            switch stages {
            case .blit:
                descriptor.vertexFunction = library.makeFunction(name: "fullscreenTriangleVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "fullscreenBlit")
            case .glyph:
                descriptor.vertexFunction = library.makeFunction(name: "glyphVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "glyphFragment")
            case .cell:
                descriptor.vertexFunction = library.makeFunction(name: "termVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "termFragment")
            }
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm_srgb
            switch stages {
            case .blit:
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .glyph:
                // perChannelCoverageOver, as MetalPipelines gives this pass: the
                // fragment's second output is the per-channel coverage.
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSource1Color
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSource1Alpha
            case .cell:
                break
            }
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                printError("pipeline \(path): \(error.localizedDescription)")
                exit(1)
            }
        }

        let primary: Stages = isBlitPass ? .blit : (isGlyphPass ? .glyph : .cell)
        let arms = [makePipeline(arguments[1], primary), makePipeline(arguments[2], primary)]
        let glyphArms = isGridPass ? [makePipeline(arguments[1], .glyph), makePipeline(arguments[2], .glyph)] : []

        if let blitSource {
            let library = makeLibrary(arguments[1])
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "termVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "termFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            let fill: MTLRenderPipelineState
            do {
                fill = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                printError("fill pipeline: \(error.localizedDescription)")
                exit(1)
            }
            let commands = queue.makeCommandBuffer()!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = blitSource
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0.011, 0.011, 0.013, 1.0)
            pass.colorAttachments[0].storeAction = .store
            let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(fill)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
            encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }

        // The draws one arm makes into an open encoder: the primary pass, and
        // for the grid pass the glyph draw inside the same encoder, so the
        // target is loaded and stored once for both.
        func encodeDraws(_ encoder: MTLRenderCommandEncoder, arm: Int) {
            encoder.setRenderPipelineState(arms[arm])
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
            encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(isBlitPass ? blitSource : atlas, index: 0)
            encoder.setFragmentSamplerState(armSampler[arm], index: 0)
            if isBlitPass {
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            } else {
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
            }
            if isGridPass, let glyphInstanceBuffer, glyphInstanceCount > 0 {
                encoder.setRenderPipelineState(glyphArms[arm])
                encoder.setVertexBuffer(glyphInstanceBuffer, offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: glyphInstanceCount)
            }
        }

        // Passes are batched into one command buffer so the per-submission cost
        // is divided across them: it is large, it varies between process
        // launches, and no shader change touches it, so leaving it in would
        // drown the thing being compared. UBQ_PASSES_PER_BUFFER=1 shows it.
        // A frame submits one command buffer and pays it once, which is why a
        // ratio here is a ratio of pass work and not of a frame.
        let passesPerBuffer = environment["UBQ_PASSES_PER_BUFFER"].map { max(1, Int(atoi($0))) } ?? 24
        func runOnce(_ arm: Int) -> Double {
            let commands = queue.makeCommandBuffer()!
            for _ in 0..<passesPerBuffer {
                if isCopyPass {
                    let copyEncoder = commands.makeBlitCommandEncoder()!
                    copyEncoder.copy(
                        from: blitSource!,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOriginMake(0, 0, 0),
                        sourceSize: MTLSizeMake(width, height, 1),
                        to: target,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOriginMake(0, 0, 0)
                    )
                    copyEncoder.endEncoding()
                    continue
                }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = isClearPass ? .clear : (isGlyphPass ? .load : .dontCare)
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0.02, 0.02, 0.03, 1.0)
                pass.colorAttachments[0].storeAction = .store
                let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
                if !isClearPass {
                    encodeDraws(encoder, arm: arm)
                }
                encoder.endEncoding()
            }
            commands.commit()
            commands.waitUntilCompleted()
            return (commands.gpuEndTime - commands.gpuStartTime) * 1000.0 / Double(passesPerBuffer)
        }

        // A speedup is only interesting once the arms agree on the pixels, and
        // an all-one-colour target would let two arms agree while drawing
        // nothing -- so the ink is counted too.
        if !isClearPass && !isCopyPass {
            let shotDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb,
                width: width,
                height: height,
                mipmapped: false
            )
            shotDescriptor.usage = .renderTarget
            shotDescriptor.storageMode = .shared
            let shots = [device.makeTexture(descriptor: shotDescriptor)!, device.makeTexture(descriptor: shotDescriptor)!]
            for arm in 0..<2 {
                let commands = queue.makeCommandBuffer()!
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = shots[arm]
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0.02, 0.02, 0.03, 1.0)
                pass.colorAttachments[0].storeAction = .store
                let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
                encodeDraws(encoder, arm: arm)
                encoder.endEncoding()
                commands.commit()
                commands.waitUntilCompleted()
            }
            let rowBytes = width * 4
            var pixelsA = [UInt8](repeating: 0, count: rowBytes * height)
            var pixelsB = [UInt8](repeating: 0, count: rowBytes * height)
            let region = MTLRegionMake2D(0, 0, width, height)
            shots[0].getBytes(&pixelsA, bytesPerRow: rowBytes, from: region, mipmapLevel: 0)
            shots[1].getBytes(&pixelsB, bytesPerRow: rowBytes, from: region, mipmapLevel: 0)
            var differing = 0
            var worst = 0
            var inked = 0
            let clear = (pixelsA[0], pixelsA[1], pixelsA[2])
            for index in stride(from: 0, to: pixelsA.count, by: 4) {
                var isDifferent = false
                for channel in 0..<4 {
                    let delta = abs(Int(pixelsA[index + channel]) - Int(pixelsB[index + channel]))
                    worst = max(worst, delta)
                    if delta != 0 {
                        isDifferent = true
                    }
                }
                if isDifferent {
                    differing += 1
                }
                if pixelsA[index] != clear.0 || pixelsA[index + 1] != clear.1 || pixelsA[index + 2] != clear.2 {
                    inked += 1
                }
            }
            let pixels = pixelsA.count / 4
            print(
                "  agreement: \(differing)/\(pixels) pixels differ, worst channel delta \(worst); arm A inked \(inked) "
                    + String(format: "(%.1f%%)", 100.0 * Double(inked) / Double(pixels))
            )
            if inked == 0 {
                printError("  the target is untouched -- the lane is measuring an empty pass")
                exit(1)
            }
        }

        for _ in 0..<6 {
            _ = runOnce(0)
            _ = runOnce(1)
        }

        var timesA: [Double] = []
        var timesB: [Double] = []
        var ratios: [Double] = []
        for round in 0..<rounds {
            let timeA: Double
            let timeB: Double
            if round % 2 == 0 {
                timeA = runOnce(0)
                timeB = runOnce(1)
            } else {
                timeB = runOnce(1)
                timeA = runOnce(0)
            }
            timesA.append(timeA)
            timesB.append(timeB)
            ratios.append(timeB / timeA)
        }

        let faster = ratios.filter { $0 < 1.0 }.count
        ratios.sort()
        let glyphLabel = isGridPass ? " + \(glyphInstanceCount) glyphs" : ""
        let label =
            isClearPass ? "clear" : (isCopyPass ? "copy" : (isGridPass ? "grid" : (isBlitPass ? "blit" : (isGlyphPass ? "glyph" : "cell"))))
        print(
            "  \(label) pass  \(instanceCount) instances\(glyphLabel)  "
                + String(format: "fraction %.2f", fraction) + "  \(rounds) rounds x \(passesPerBuffer) passes"
        )
        print(String(format: "  arm A  min %.4f ms  median %.4f ms", timesA.min()!, median(timesA)))
        print(String(format: "  arm B  min %.4f ms  median %.4f ms", timesB.min()!, median(timesB)))
        print(
            String(format: "  median ratio %.4f  ->  %+.2f%%", median(ratios), (median(ratios) - 1.0) * 100.0)
                + "   B faster in \(faster)/\(rounds) rounds  "
                + String(format: "(range %.4f .. %.4f)", ratios.first!, ratios.last!)
        )
    }
}
