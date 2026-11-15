// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/Presentation/PaneGeometry.h"

#include <algorithm>

namespace Ubiquitty::Linux::Presentation {

PaneGeometry PaneGeometry::resolve(FloatSize viewport, Rendering::EdgeInsets insets,
    FloatSize cell, GridSize grid, Rendering::RemoteViewportRequest request)
{
    PaneGeometry geometry;
    geometry.viewport = viewport;
    geometry.content = Rendering::pixelAlignedGridContentRect(viewport, insets);
    geometry.rasterOrigin = geometry.content.origin;
    // Core clamps opposing insets together. Size the raster from that resolved
    // padding rather than the unbounded request, retaining remote host pixels
    // without stretching the local widget's allocation to fit them.
    const Rendering::EdgeInsets resolvedInsets {
        geometry.content.origin.x,
        viewport.width - geometry.content.origin.x - geometry.content.size.width,
        geometry.content.origin.y,
        viewport.height - geometry.content.origin.y - geometry.content.size.height,
    };
    geometry.rasterSize = Rendering::viewportForGrid(grid, cell, resolvedInsets, 0);
    geometry.rasterSize.width = std::max(geometry.rasterSize.width, viewport.width);
    geometry.rasterSize.height = std::max(geometry.rasterSize.height, viewport.height);
    request.viewport = geometry.content.size;
    request.cell = cell;
    request.grid = grid;
    geometry.contentClip = Rendering::remoteViewportContentClip(request, geometry.content);
    geometry.placement = Rendering::remoteViewportPlacement(request);
    geometry.placement.origin.x += geometry.content.origin.x;
    geometry.placement.origin.y += geometry.content.origin.y;
    geometry.textureOrigin = {
        geometry.placement.origin.x - geometry.rasterOrigin.x * geometry.placement.scale,
        geometry.placement.origin.y - geometry.rasterOrigin.y * geometry.placement.scale,
    };
    return geometry;
}

GridSize PaneGeometry::gridForAllocation(FloatSize viewport, Rendering::EdgeInsets insets, FloatSize cell)
{
    const auto content = Rendering::pixelAlignedGridContentRect(viewport, insets);
    return Rendering::gridFromViewport(content.size, {}, 0, cell, Rendering::GridFloor::None);
}

std::optional<CellPosition> PaneGeometry::cellAtPointIfInside(DoublePoint point, FloatSize cell, GridSize grid) const
{
    if (contentClip && (point.x < contentClip->origin.x || point.y < contentClip->origin.y || point.x >= static_cast<double>(contentClip->origin.x) + contentClip->size.width || point.y >= static_cast<double>(contentClip->origin.y) + contentClip->size.height))
        return std::nullopt;
    return Rendering::pointToCellIfInside(point, { placement.origin.x, placement.origin.y },
        { cell.width * placement.scale, cell.height * placement.scale }, grid);
}

FloatPoint PaneGeometry::picturePoint(FloatPoint point) const
{
    return placement.picturePoint(point);
}

FloatPoint PaneGeometry::viewportPoint(FloatPoint point) const
{
    return placement.viewportPoint(point);
}

} // namespace Ubiquitty::Linux::Presentation
