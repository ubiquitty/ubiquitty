// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"
#include "Platform/Linux/Presentation/PaneGeometry.h"

#include <cmath>

using namespace Ubiquitty;
using namespace Ubiquitty::Linux::Presentation;

namespace {

TEST(localPaddingChangesGridOriginWithoutMovingTheTexture)
{
    for (const float scale : { 1.0f, 2.0f }) {
        const FloatSize viewport { 120 * scale, 100 * scale };
        const Rendering::EdgeInsets insets { 3 * scale, 5 * scale, 7 * scale, 11 * scale };
        const FloatSize cell { 8 * scale, 16 * scale };
        const GridSize grid = PaneGeometry::gridForAllocation(viewport, insets, cell);
        CHECK(grid.columns == 14 && grid.rows == 5);
        const auto geometry = PaneGeometry::resolve(viewport, insets, cell, grid);
        CHECK(geometry.rasterOrigin.x == 3 * scale && geometry.rasterOrigin.y == 7 * scale);
        CHECK(geometry.rasterSize.width == viewport.width && geometry.rasterSize.height == viewport.height);
        CHECK(geometry.textureOrigin.x == 0 && geometry.textureOrigin.y == 0);
        const FloatPoint pointer { 3 * scale + 2.5f * cell.width, 7 * scale + 1.5f * cell.height };
        const auto gridPoint = geometry.picturePoint(pointer);
        const auto cellUnderPointer = Rendering::pointToCell(gridPoint, {}, cell, grid, Rendering::RowClamp::Clamped);
        CHECK(cellUnderPointer.column == 2 && cellUnderPointer.row == 1);
        const auto pixel = Rendering::pointToDevicePixel(gridPoint, {}, 1.0f,
            { static_cast<int>(grid.columns * cell.width), static_cast<int>(grid.rows * cell.height) });
        CHECK(pixel.x == static_cast<int>(2.5f * cell.width) + 1);
        CHECK(pixel.y == static_cast<int>(1.5f * cell.height) + 1);
        const auto inverse = geometry.viewportPoint(gridPoint);
        CHECK(inverse.x == pointer.x && inverse.y == pointer.y);
    }
}

TEST(remotePaddingKeepsImageAndGridInTheSameTransform)
{
    for (const auto policy : { Rendering::RemoteViewportPolicy::Fit, Rendering::RemoteViewportPolicy::Pan }) {
        Rendering::RemoteViewportRequest request;
        request.policy = policy;
        request.isGeometryOwnedElsewhere = true;
        request.minimumScale = 0.25f;
        request.cursor = { 30, 70 };
        const auto geometry = PaneGeometry::resolve({ 240, 180 }, { 7, 11, 13, 17 },
            { 8, 16 }, { 80, 40 }, request);
        CHECK(geometry.rasterSize.width == 658 && geometry.rasterSize.height == 670);
        for (const auto point : { FloatPoint { 0, 0 }, FloatPoint { 40, 64 }, FloatPoint { 639, 639 } }) {
            const auto widget = geometry.viewportPoint(point);
            const auto roundTrip = geometry.picturePoint(widget);
            CHECK(std::abs(roundTrip.x - point.x) < 0.001f);
            CHECK(std::abs(roundTrip.y - point.y) < 0.001f);
            const FloatPoint throughTexture {
                geometry.textureOrigin.x + (geometry.rasterOrigin.x + point.x) * geometry.placement.scale,
                geometry.textureOrigin.y + (geometry.rasterOrigin.y + point.y) * geometry.placement.scale,
            };
            CHECK(std::abs(throughTexture.x - widget.x) < 0.001f);
            CHECK(std::abs(throughTexture.y - widget.y) < 0.001f);
        }
    }
}

TEST(fractionalPaddingUsesOneDevicePixelGridForRasterAndInput)
{
    constexpr float scale = 2;
    const FloatSize viewport { 60 * scale, 50 * scale };
    const Rendering::EdgeInsets insets { 1.625f * scale, 2.875f * scale, 3.375f * scale, 5.625f * scale };
    const FloatSize cell { 4 * scale, 8 * scale };
    const auto grid = PaneGeometry::gridForAllocation(viewport, insets, cell);
    CHECK(grid.columns == 13 && grid.rows == 5);
    const auto geometry = PaneGeometry::resolve(viewport, insets, cell, grid);
    CHECK(geometry.rasterOrigin.x == 3 && geometry.rasterOrigin.y == 7);
    CHECK(geometry.content.origin == geometry.rasterOrigin);
    CHECK(geometry.placement.origin == geometry.rasterOrigin);
    CHECK(geometry.textureOrigin.x == 0 && geometry.textureOrigin.y == 0);
    const auto hit = geometry.cellAtPointIfInside({ 19.25, 23.25 }, cell, grid);
    REQUIRE(hit.has_value());
    CHECK(hit->column == 2 && hit->row == 1);
    CHECK(!geometry.cellAtPointIfInside({ 19.25, 6.75 }, cell, grid));
    const auto inverse = geometry.viewportPoint(geometry.picturePoint({ 19.25f, 23.25f }));
    CHECK(inverse.x == 19.25f && inverse.y == 23.25f);

    const auto required = Rendering::viewportForGrid(grid, cell, insets, 0);
    const FloatSize allocated { std::ceil(required.width / scale) * scale, std::ceil(required.height / scale) * scale };
    const auto fitted = PaneGeometry::gridForAllocation(allocated, insets, cell);
    CHECK(fitted.columns >= grid.columns && fitted.rows >= grid.rows);

    const auto tiny = PaneGeometry::resolve({ 5, 5 }, { 3, 3, 3, 3 }, cell, { 1, 1 });
    CHECK(tiny.rasterOrigin.x == 3 && tiny.rasterOrigin.y == 3);
    CHECK(tiny.content.size.width == 0 && tiny.content.size.height == 0);
    CHECK(tiny.textureOrigin.x == 0 && tiny.textureOrigin.y == 0);
}

TEST(onlyRemoteFitAndPanUseThePaddedContentClip)
{
    Rendering::RemoteViewportRequest request;
    request.policy = Rendering::RemoteViewportPolicy::Fit;
    const auto resolve = [&] {
        return PaneGeometry::resolve({ 120, 100 }, { 3, 5, 7, 11 }, { 8, 16 }, { 14, 5 }, request);
    };
    CHECK(!resolve().contentClip);
    request.isGeometryOwnedElsewhere = true;
    for (const auto policy : { Rendering::RemoteViewportPolicy::Fit, Rendering::RemoteViewportPolicy::Pan }) {
        request.policy = policy;
        const auto geometry = resolve();
        REQUIRE(geometry.contentClip.has_value());
        CHECK(geometry.contentClip->origin.x == 3 && geometry.contentClip->origin.y == 7);
        CHECK(geometry.contentClip->size.width == 112 && geometry.contentClip->size.height == 82);
    }
    request.isProgramViewport = true;
    CHECK(!resolve().contentClip);
    request.isProgramViewport = false;
    request.policy = Rendering::RemoteViewportPolicy::Letterbox;
    CHECK(!resolve().contentClip);
}

TEST(strictHitsRejectPaddingAndHiddenRemoteCells)
{
    const FloatSize cell { 8, 16 };
    const GridSize grid { 14, 5 };
    const auto local = PaneGeometry::resolve({ 120, 100 }, { 3, 5, 7, 11 }, cell, grid);
    const auto first = local.cellAtPointIfInside({ 7, 15 }, cell, grid);
    REQUIRE(first.has_value());
    CHECK(first->row == 0 && first->column == 0);
    for (const auto point : { DoublePoint { 2, 15 }, { 7, 6 }, { 115, 15 }, { 7, 87 }, { 7, 88 } })
        CHECK(!local.cellAtPointIfInside(point, cell, grid));

    Rendering::RemoteViewportRequest request;
    request.policy = Rendering::RemoteViewportPolicy::Fit;
    request.minimumScale = 1;
    request.isGeometryOwnedElsewhere = true;
    const GridSize remoteGrid { 80, 40 };
    const auto remote = PaneGeometry::resolve({ 120, 100 }, { 3, 5, 7, 11 }, cell, remoteGrid, request);
    REQUIRE(remote.contentClip.has_value());
    // These widget points still address valid host cells, but their pixels
    // are outside the remote presentation's visible content rectangle.
    for (const auto point : { DoublePoint { 2, 15 }, { 7, 6 }, { 115, 15 }, { 7, 89 } }) {
        const auto hiddenHostCell = Rendering::pointToCellIfInside(point,
            { remote.placement.origin.x, remote.placement.origin.y }, { 8, 16 }, remoteGrid);
        REQUIRE(hiddenHostCell.has_value());
        CHECK(!remote.cellAtPointIfInside(point, cell, remoteGrid));
    }
    REQUIRE(remote.cellAtPointIfInside({ 7, 15 }, cell, remoteGrid).has_value());
}

TEST(paddingClampAndSubcellAllocationUseTheCoreGridPolicy)
{
    const auto collapsed = PaneGeometry::resolve({ 20, 10 }, { 30, 30, 30, 30 }, { 8, 16 }, { 1, 1 });
    CHECK(collapsed.content.origin.x == 10 && collapsed.content.origin.y == 5);
    CHECK(collapsed.content.size.width == 0 && collapsed.content.size.height == 0);
    const auto emptyGrid = PaneGeometry::gridForAllocation({ 20, 10 }, { 30, 30, 30, 30 }, { 8, 16 });
    CHECK(emptyGrid.columns == 0 && emptyGrid.rows == 0);
    const auto edgeToEdge = PaneGeometry::resolve({ 16, 32 }, {}, { 8, 16 }, { 2, 2 });
    CHECK(edgeToEdge.rasterOrigin.x == 0 && edgeToEdge.rasterOrigin.y == 0);
    CHECK(edgeToEdge.textureOrigin.x == 0 && edgeToEdge.textureOrigin.y == 0);
}

} // namespace

UBIQUITTY_TEST_MAIN()
