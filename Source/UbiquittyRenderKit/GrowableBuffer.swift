// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// GrowableBuffer.swift — a Metal instance buffer that resizes to the frame.
//
// One frame's build writes nine instance streams, each into shared-storage
// memory the GPU reads in the same frame. The streams differ in what decides
// their length, and that difference is the only thing this type asks its owner
// to state: a stream sized from the grid settles the frame after a resize and
// wants `.exactFit`, a stream sized from what the frame happens to contain
// climbs and wants `.geometric`.
//
// Naming it at the declaration matters because getting it wrong is invisible.
// Exact-fit growth on a climbing stream reallocates on every new-high frame,
// and a Metal allocation inside an encode stalls it — a dropped frame,
// attributed to whatever else was on screen.

import Metal

/// How a buffer answers a request for more room than it holds.
enum BufferGrowth {
    /// Allocate exactly the requested count.
    ///
    /// For counts derived from the grid — rows times columns — which change
    /// only on a resize. Such a stream reaches its size on the first frame
    /// after one and never reallocates again, so overshooting would hold memory
    /// nothing has a path to ask for.
    case exactFit
    /// Allocate at least twice the current capacity.
    ///
    /// For counts derived from frame content, which climb frame by frame under
    /// a flood. Doubling makes the reallocations O(log n) over a session, then
    /// converges to the workload maximum and stops.
    case geometric
}

/// A Metal buffer holding one frame's instances of a single type.
///
/// Shared storage, because the CPU writes the instances and the GPU reads them
/// in the same frame with no blit between — and RINGED for the same reason: a
/// frame committed a moment ago is still reading its instances when the next
/// frame's build begins, and one buffer between them means the second build
/// overwrites what the first is drawing. What reaches the screen is then a
/// frame assembled from two, which reads as words flickering and thrashing
/// under a fast scroll rather than as anything a renderer would call an error.
/// Nothing waits: the ring is deep enough that a buffer comes round only after
/// the frames that read it have been presented, and the buffer's own command
/// buffer is consulted before it is written again.
///
/// A value type, and that is a per-frame cost rather than a taste: as a class,
/// every `ensure` reached through a renderer's stored property took a retain and
/// a release, because the optimiser cannot prove an aliased reference is not
/// mutated across the call. Twelve atomics per frame for six sizing calls, read
/// off the shipping driver's disassembly. Inline storage makes the same access
/// statically exclusive and emits neither.
struct GrowableBuffer {
    private let device: MTLDevice
    private let growth: BufferGrowth

    /// One element's stride in bytes.
    ///
    /// Carried as a number rather than as a generic parameter. As
    /// `GrowableBuffer<Element>` the optimiser emitted the unspecialised generic
    /// and two runtime metadata instantiations per sizing pass, and an
    /// `@inline(__always)` on `ensure` changed nothing — the cost was
    /// specialisation that never happened, not a missed inline. Only the typed
    /// view needs the element type, so only it is generic.
    private let stride: Int

    /// The ring's allocations, all of one capacity; nil until the first
    /// successful ``ensure(_:)``.
    private var ring: [MTLBuffer?] = Array(repeating: nil, count: GrowableBuffer.ringDepth)
    /// The command buffer each ring slot was last read by, so a slot is never
    /// rewritten while its frame is still executing.
    private var ringCommands: [MTLCommandBuffer?] = Array(repeating: nil, count: GrowableBuffer.ringDepth)
    private var ringIndex = 0

    /// How many frames' instances the ring holds.
    ///
    /// Three: a drawable in flight, one queued behind it, and the one being
    /// built. Deeper buys nothing a triple-buffered presentation can use.
    static let ringDepth = 3

    /// The allocation this frame writes into, or nil before the first sizing.
    var buffer: MTLBuffer? { ring[ringIndex] }
    /// How many elements ``buffer`` holds.
    ///
    /// A failed allocation must not advance it: this is what the caller clamps
    /// its instance count to, and a capacity larger than the buffer would be
    /// headroom that does not exist.
    private(set) var capacity: Int = 0

    /// Declares a stream without allocating for it.
    ///
    /// - Parameters:
    ///   - device: The device the allocations are made on.
    ///   - growth: How the capacity answers a request it cannot meet.
    ///   - stride: One element's stride in bytes.
    init(device: MTLDevice, growth: BufferGrowth, stride: Int) {
        self.device = device
        self.growth = growth
        self.stride = stride
    }

    /// Typed access to the allocation, for handing Core a span to write into.
    ///
    /// Nil before the first successful ``ensure(_:)``. Valid until the next one
    /// that grows, which is why a frame binds this after sizing and not before.
    /// - Parameter type: The element type the stream holds.
    /// - Returns: The typed base, or nil before the first successful sizing.
    func elements<Element>(as type: Element.Type) -> UnsafeMutablePointer<Element>? {
        buffer?.contents().bindMemory(to: type, capacity: capacity)
    }

    /// Grows the buffer to hold at least `count` elements.
    ///
    /// A refused allocation keeps the previous buffer and capacity rather than
    /// dropping them, so a caller that clamps to ``capacity`` draws a smaller
    /// frame instead of writing through a nil pointer.
    ///
    /// - Parameter count: Elements the frame needs room for.
    /// - Returns: Whether the buffer now holds that many.
    @discardableResult
    @inline(__always)
    mutating func ensure(_ count: Int) -> Bool {
        // The steady-state frame is a comparison and nothing else. Split so the
        // allocating half stays outlined: a frame that fits already is the case
        // that runs every frame, and inlining the whole body would put a
        // makeBuffer call the optimiser must schedule around into a path that
        // never takes it.
        if count <= capacity, buffer != nil {
            return true
        }
        return grow(to: count)
    }

    /// Allocates for `count`, keeping the previous buffer when refused.
    ///
    /// - Parameter count: Elements the frame needs room for.
    /// - Returns: Whether the buffer now holds that many.
    @inline(never)
    private mutating func grow(to count: Int) -> Bool {
        var wanted = count > 1 ? count : 1
        if case .geometric = growth, capacity * 2 > wanted {
            wanted = capacity * 2
        }
        var grownRing: [MTLBuffer?] = []
        grownRing.reserveCapacity(GrowableBuffer.ringDepth)
        for _ in 0..<GrowableBuffer.ringDepth {
            guard let grown = device.makeBuffer(length: wanted * stride, options: .storageModeShared) else {
                return false
            }
            grownRing.append(grown)
        }
        ring = grownRing
        ringCommands = Array(repeating: nil, count: GrowableBuffer.ringDepth)
        capacity = wanted
        return true
    }

    /// Moves to the next allocation and waits for whatever last read it.
    ///
    /// Called once per frame, before the build writes anything. The wait is the
    /// exception rather than the rule — three frames of presentation pass first
    /// — and it is what makes the ring a guarantee instead of a probability.
    mutating func advanceFrame() {
        ringIndex = (ringIndex + 1) % GrowableBuffer.ringDepth
        if let inFlight = ringCommands[ringIndex] {
            switch inFlight.status {
            case .notEnqueued, .enqueued:
                // Recorded by an encode whose frame dropped it uncommitted — a
                // lost drawable, or the image aspect-settle re-encode, both of
                // which are legitimate frames. Its passes never execute, so the
                // slot is already free; waiting on a command buffer that will
                // never be committed blocks the main thread forever.
                break
            case .completed, .error:
                break
            case .committed, .scheduled:
                inFlight.waitUntilCompleted()
            @unknown default:
                inFlight.waitUntilCompleted()
            }
        }
        ringCommands[ringIndex] = nil
    }

    /// Records the command buffer that will read this frame's allocation.
    ///
    /// - Parameter commands: The frame's command buffer.
    mutating func noteRead(by commands: MTLCommandBuffer) {
        ringCommands[ringIndex] = commands
    }
}
