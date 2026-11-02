// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The browser compositor consumes Core's resolved placement. Policy and the
// inverse picture map remain in Core; this module only converts device to CSS
// pixels and measures the pointer from the clipped viewport.
export function placePicture(canvas, extent, placement, deviceScale) {
  canvas.style.left = `${placement.originX / deviceScale}px`;
  canvas.style.top = `${placement.originY / deviceScale}px`;
  canvas.style.width = `${extent.width * placement.scale / deviceScale}px`;
  canvas.style.height = `${extent.height * placement.scale / deviceScale}px`;
}

export function viewportPoint(event, viewport, deviceScale) {
  const bounds = viewport.getBoundingClientRect();
  return { x: (event.clientX - bounds.left) * deviceScale,
    y: (event.clientY - bounds.top) * deviceScale };
}
