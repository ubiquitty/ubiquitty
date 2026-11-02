<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# The Swift renderer

The Apple frontends share the Swift and Metal renderer in
`Source/UbiquittyRenderKit/`, driven by `SurfaceRenderer.swift` in
`Source/UbiquittyKit/Swift/`. The macOS app, iOS app, native snapshots, and render
profiler use that surface. There is one Apple renderer implementation.

## Responsibilities

Core owns terminal state, frame capture, damage tracking, glyph keys and slot
geometry, cell styling, image placement, and instance construction. Swift owns
the Apple font objects, rasterisation through CoreText, Metal resources, and
presentation. Platform-independent rules belong in Core and are shared with
the software and Vulkan renderers.

`SurfaceTypography` adapts Core's resolved `RenderConfiguration` for both Apple
frontends. It does not define a second set of configuration defaults.

## Frame lifetime

`SurfaceRenderer` registers the surface's metrics and style with the runtime.
The runtime can capture a complete frame at a synchronized-output boundary.
Otherwise the renderer captures live terminal state under the model lock.
`Rendering::FrameCapture` owns the captured storage, so instance construction
and GPU work run after the lock is released.

`Rendering::buildCellInstances` fills the streams consumed by
`FrameEncoder.swift`. The glyph backend supplies platform rasterisation while
Core controls the cache keys and placement geometry. Retained-frame decisions
come from Core's render plan; the frontend owns the textures that retain pixels.

The cursor uses a separate overlay, with opacity and next-transition timing
resolved by Core's cursor policy. A new cursor phase can be composed over
retained terminal content without rebuilding every cell.

## Font changes

A renderer measures an adopted typography configuration and advances its build
generation. Surfaces refresh their font-dependent resources and invalidate
retained pixels. Metal pipelines remain reusable because a font change does not
change their shader contract.

Visible font preparation can run asynchronously. A live frame may be deferred
until preparation completes; the surface requests another presentation. Tests
that drive the live entry point must distinguish this deferral from a failed
render rather than require the first attempt to draw.

## Shared geometry

`Tek/BeamRaster.h` defines the Tektronix beam's per-pixel raster, shared by the
software snapshot renderer and the Metal Tek pass. A run is a capsule around its
segment: an integer distance from each pixel's centre gives the antialiased
core's coverage and indexes Core's halo table, so ends and joints are round and
the bitmap tier's Metal pixels equal the software reference's. A plotted point
is a degenerate run, the beam's round spot.

Character spacing, padding, and overlay placement also follow the Core snapshot
style. Reference updates require an inspected image change; matching a golden
is not a reason to discard configured spacing or clip an overlay at a margin.

## Validation

The snapshot harness compares native and bitmap output through the same Apple
surface used by the apps. `SurfaceSmoke.swift` exercises live frame composition,
retained targets, font changes, and synchronized captures. Portable regression
tests pin the Core geometry and software renderer independently.

A passing macOS build does not validate UIKit. The iOS build and simulator
snapshots require the SDK version declared in CMake. Missing toolchains and
snapshot exemptions must remain visible in validation evidence.
