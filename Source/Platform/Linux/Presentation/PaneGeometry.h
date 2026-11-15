// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/Rendering/PaddingGeometry.h"
#include "Core/Rendering/RemoteViewport.h"

namespace Ubiquitty::Linux::Presentation {

/// One pane's drawable, grid and presented-image geometry, in device pixels.
///
/// Padding belongs inside the drawable. The grid's transform remains separate
/// from the texture's outer bounds so text may overhang cells into that padding
/// while input addresses the same grid that Core drew.
struct PaneGeometry {
    /// Maps unscaled grid pixels to the local pane, including remote Fit/Pan.
    Rendering::RemoteViewportPlacement placement;
    /// The padded content rectangle inside the widget's full viewport.
    FloatRect content;
    /// The widget's full drawable extent.
    FloatSize viewport;
    /// The grid's origin within the raster image before presentation.
    FloatPoint rasterOrigin;
    /// The raster extent, retaining the whole host grid for remote presentation.
    FloatSize rasterSize;
    /// Where the raster image's outer corner is drawn within the local pane.
    FloatPoint textureOrigin;
    /// The optional remote Fit/Pan clip; local text keeps the full drawable.
    std::optional<FloatRect> contentClip;

    /// Resolves one pane using Core's padding and remote-placement policies.
    ///
    /// - Parameters:
    ///   - viewport: The whole widget allocation, in device pixels.
    ///   - insets: Requested device-pixel padding, resolved to whole-pixel edges.
    ///   - cell: The renderer's natural cell extent.
    ///   - grid: The model owner's grid dimensions.
    ///   - request: Remote ownership, cursor and presentation policy facts.
    /// - Returns: One geometry for rasterization, painting and pointer mapping.
    [[nodiscard]] static PaneGeometry resolve(FloatSize viewport, Rendering::EdgeInsets insets,
        FloatSize cell, GridSize grid, Rendering::RemoteViewportRequest request = {});

    /// Resolves the local grid fitting within a padded widget allocation.
    ///
    /// - Parameters:
    ///   - viewport: The whole widget allocation, in device pixels.
    ///   - insets: Requested device-pixel padding, aligned as in `resolve`.
    ///   - cell: The natural cell extent, in device pixels.
    /// - Returns: Raw grid counts; the caller keeps its prior grid below one.
    [[nodiscard]] static GridSize gridForAllocation(FloatSize viewport, Rendering::EdgeInsets insets, FloatSize cell);

    /// Hits a cell only inside the displayed grid and optional content clip.
    ///
    /// - Parameters:
    ///   - point: A widget point in device pixels, retaining native precision.
    ///   - cell: The unscaled cell extent used by the raster image.
    ///   - grid: The model owner's displayed grid dimensions.
    /// - Returns: The uniform-grid cell, or no value in padding or clipped space.
    [[nodiscard]] std::optional<CellPosition> cellAtPointIfInside(DoublePoint point, FloatSize cell, GridSize grid) const;

    /// Maps a device-pixel widget point into the unscaled grid.
    ///
    /// - Parameter point: A point from the widget's upper-left corner.
    /// - Returns: Grid-relative pixels, before cell or letter hit testing.
    [[nodiscard]] FloatPoint picturePoint(FloatPoint point) const;

    /// Maps unscaled grid pixels to the widget's device-pixel coordinates.
    ///
    /// - Parameter point: A point from the grid's upper-left corner.
    /// - Returns: The corresponding point from the widget's upper-left corner.
    [[nodiscard]] FloatPoint viewportPoint(FloatPoint point) const;
};

} // namespace Ubiquitty::Linux::Presentation
