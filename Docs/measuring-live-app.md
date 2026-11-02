<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Measuring the live macOS app

Measure the app through its real PTY, renderer, and presentation path when the
question concerns interactive behavior. A Core replay benchmark answers a
narrower question; see [measuring a Core change](measuring-a-core-change.md) and
[the measurement guide](benchmarks.md).

## Reproducible measurements

Record the app commit, build options, macOS and SDK versions, hardware, display
scale, grid geometry, font, power state, and workload. Keep the window visible
and its focus state consistent. Use synthetic sessions without private data.

- Use the repository's `Tests/Performance` programs for the
  specific layer they measure. State when a result excludes GPU presentation.
- Use `Scripts/energy-scenarios.py` for its documented energy scenarios and
  supply shareable recordings when publishing results.
- Capture a separate Instruments or `sample` profile for attribution. Do not
  combine profiled timings with uninstrumented measurements.
- Alternate the compared builds, repeat runs, and report variation and raw
  samples. Check the rendered result as well as the elapsed time.

External harnesses used during development are optional. Their results are not
publicly reproducible until the harness, workload, and configuration are
available alongside the measurements.

## Driving an isolated instance

The [control socket](control-socket.md) supports scripted input and screen
inspection. Give a test instance a separate `UBIQUITTY_HOME` and
`XDG_CONFIG_HOME` so its socket and configuration do not belong to the user's
session. Verify the intended instance before sending input.

Configure explicit permissions for the operations the test needs. An automation
policy is part of the measurement configuration; do not infer permission from
the presence of a local socket. Consult the control-socket documentation for
request methods, policy evaluation, and approval behavior.

## Validate the instrument

A capture of an occluded window can return a stale backing store. Use a live
ScreenCaptureKit capture when measuring presented frames, include a visibly
changing positive control, and compare successive captures before concluding
that the renderer was idle.

A background or inactive app can draw less often than a focused one. A profile
showing mostly idle threads therefore needs window/focus context. Measure PTY
drain time, frame preparation, and presentation separately before attributing a
wall-clock difference to the renderer.
