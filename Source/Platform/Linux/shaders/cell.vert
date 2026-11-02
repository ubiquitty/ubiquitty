#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Per-instance attributes are the portable Rendering::CellInstance
// (Source/Core/Rendering/CellInstance.h) — the locations map to its field byte
// offsets so the instance buffer is a direct upload of CellInstance[]. Location
// 2 is the 4 bytes of alignment padding at offset 12, which no attribute
// declares.
layout(location = 0) in vec2 inGridPosition; // (column, row) in cell units  @0
layout(location = 1) in float inWidthCells; // 1 narrow, 2 wide lead       @8
layout(location = 3) in vec4 inForeground; //                                      @16
layout(location = 4) in vec4 inBackground; //                                      @32
layout(location = 5) in vec2 inAtlasMin; // glyph UV top-left              @48
layout(location = 6) in vec2 inAtlasMax; // glyph UV bottom-right          @56

layout(push_constant) uniform Push {
    vec2 viewportSize; // pixels (cols*cellWidth, rows*cellHeight)
    vec2 cellSize; // pixels
}
pc;

layout(location = 0) out vec4 outForeground;
layout(location = 1) out vec4 outBackground;
layout(location = 2) flat out float outHasGlyph;
// The cell's pixel origin + the glyph's atlas UV slot, passed FLAT so the
// fragment shader can recover the integer atlas texel deterministically (see
// cell.frag) instead of sampling an interpolated UV — that integer path matches
// the CPU SoftwareRenderer's nearest tap exactly, keeping CPU<->GPU byte-equal
// even with the FreeType path's anti-aliased (non-0/255) coverage.
layout(location = 3) flat out vec2 outCellOriginPx;
layout(location = 4) flat out vec2 outAtlasMin;
layout(location = 5) flat out vec2 outAtlasMax;
layout(location = 6) flat out vec2 outCellSizePx;

// Two triangles -> a unit quad.
const vec2 kCorners[6] = vec2[](
    vec2(0, 0), vec2(1, 0), vec2(0, 1),
    vec2(0, 1), vec2(1, 0), vec2(1, 1));

void main()
{
    vec2 corner = kCorners[gl_VertexIndex];
    vec2 originPx = inGridPosition * pc.cellSize;
    vec2 sizePx = vec2(inWidthCells * pc.cellSize.x, pc.cellSize.y);
    vec2 px = originPx + corner * sizePx;
    vec2 ndc = px / pc.viewportSize * 2.0 - 1.0; // Vulkan: (-1,-1) = top-left
    gl_Position = vec4(ndc, 0.0, 1.0);
    outForeground = inForeground;
    outBackground = inBackground;
    // atlasTopLeft == atlasBottomRight marks a blank cell — don't sample texel (0,0).
    outHasGlyph = (inAtlasMax.x > inAtlasMin.x) ? 1.0 : 0.0;
    outCellOriginPx = originPx;
    outAtlasMin = inAtlasMin;
    outAtlasMax = inAtlasMax;
    outCellSizePx = sizePx;
}
