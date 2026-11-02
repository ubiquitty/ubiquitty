// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Source/Platform/Linux/VulkanGlyphAtlas.cpp — see VulkanGlyphAtlas.h.

#include "Platform/Linux/VulkanGlyphAtlas.h"

#include "Core/Rendering/AtlasCoverage.h"
#include "Core/Rendering/LigatureSheet.h"
#include "Core/Rendering/ProportionalGlyphSheet.h"
#include "Platform/Linux/VulkanMemory.h"

#include "Core/Rendering/CellDecisions.h"
#include "Core/Rendering/GlyphBackend.h"
#include "Core/Rendering/GlyphKey.h"
#include "Core/Rendering/GlyphSlotCache.h"
#include "Core/Rendering/SizedMaster.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <span>

namespace Ubiquitty::Linux {

namespace {
// One combined R8 atlas: every slot is wide-sized so a wide glyph fills it and a
// mono glyph the left half. The row count comes from the screen the atlas
// serves (Rendering::glyphAtlasNominalCapacity), because a screen cannot
// reference more distinct glyphs than it has cells and one that runs out draws
// the overflow as bare background.
constexpr int atlasColumns = 32;

} // namespace

VulkanGlyphAtlas::VulkanGlyphAtlas(int cellWidthInPixels, int cellHeightInPixels, int maxTextureDimension, int cellsInWidestScreen)
    : VulkanGlyphAtlas(cellWidthInPixels, cellHeightInPixels, m_unifont, maxTextureDimension, cellsInWidestScreen)
{
}

// Font-derived: size the slots to the rasterizer's cellMetrics() cell — the
// same dims the CPU SoftwareRenderer derives from the same rasterizer.
VulkanGlyphAtlas::VulkanGlyphAtlas(Rendering::GlyphRasterizer& rasterizer, int maxTextureDimension, int cellsInWidestScreen)
    : VulkanGlyphAtlas(Rendering::cellDimension(rasterizer.cellMetrics().cellWidth), Rendering::cellDimension(rasterizer.cellMetrics().cellHeight), rasterizer, maxTextureDimension, cellsInWidestScreen)
{
}

VulkanGlyphAtlas::VulkanGlyphAtlas(int cellWidthInPixels, int cellHeightInPixels, Rendering::GlyphRasterizer& rasterizer, int maxTextureDimension, int cellsInWidestScreen)
    : m_cellWidth(cellWidthInPixels)
    , m_cellHeight(cellHeightInPixels)
    // Overflow margin from the shared sizing policy over the rasterizer's font
    // overhang (the same margin the CPU path derives), so a Nerd-Font glyph wider
    // than the cell box has a slot to render into. Zero for Unifont ⇒
    // m_monoSlotWidthInPixels == cellWidth, every UV unchanged.
    , m_monoMarginXInPixels(Rendering::computeGlyphSlot(rasterizer.glyphOverhang()).marginInPixels.width)
    , m_monoMarginYInPixels(Rendering::computeGlyphSlot(rasterizer.glyphOverhang()).marginInPixels.height)
    , m_monoSlotWidthInPixels(cellWidthInPixels + 2 * m_monoMarginXInPixels)
    , m_slotWidthInPixels(m_monoSlotWidthInPixels > cellWidthInPixels * 2 ? m_monoSlotWidthInPixels : cellWidthInPixels * 2)
    , m_slotHeightInPixels(cellHeightInPixels + 2 * m_monoMarginYInPixels)
    // Rows to hold what Core asks for, then the device clamp cuts the grid to
    // what it will allocate. Asking generously is safe because that clamp is
    // what decides the real size; asking for a constant is what left a screen
    // able to reference more glyphs than the atlas could hold.
    , m_fit(Rendering::glyphSheetGridForScreen(cellsInWidestScreen, 1, atlasColumns,
          IntSize { m_slotWidthInPixels, m_slotHeightInPixels }, maxTextureDimension))
    , m_columns(m_fit.columns)
    , m_capacity(m_fit.columns * m_fit.rows)
    , m_atlasWidth(m_fit.columns * m_slotWidthInPixels)
    , m_atlasHeight(m_fit.rows * m_slotHeightInPixels)
    , m_cache(m_capacity, Rendering::recommendedHashBuckets(m_capacity), m_columns)
    // The real box and margins, not the slot standing in for them. These fields
    // went unread while the UV math here was hand-rolled, so placeholders were
    // harmless; they stop being harmless the moment a lookup routes through
    // atlasRectForSlot, which would then return the full slot and look correct against
    // any zero-overhang face.
    , m_geometry { m_fit.columns, m_slotWidthInPixels, m_slotHeightInPixels, cellWidthInPixels,
        Ubiquitty::IntSize { m_monoMarginXInPixels, m_monoMarginYInPixels } }
    , m_rasterizer(rasterizer)
    , m_slotScratch(static_cast<std::size_t>(m_slotWidthInPixels) * m_slotHeightInPixels, 0)
{
    m_coverage.assign(static_cast<std::size_t>(m_atlasWidth) * m_atlasHeight, 0);
    m_inkBoxForSlot.assign(static_cast<std::size_t>(m_capacity), Rendering::unmeasuredGlyphInkBox());
}

bool VulkanGlyphAtlas::holdsScreen(int cellsOnScreen, int maxTextureDimension) const
{
    const Rendering::AtlasGridFit fit = Rendering::glyphSheetGridForScreen(cellsOnScreen, 1, atlasColumns,
        IntSize { m_slotWidthInPixels, m_slotHeightInPixels }, maxTextureDimension);
    return !fit.valid || fit.columns * fit.rows <= m_capacity;
}

uint32_t VulkanGlyphAtlas::findMemoryType(VkPhysicalDevice physical, uint32_t typeBits, VkMemoryPropertyFlags want) const
{
    return findVulkanMemoryType(physical, typeBits, want);
}

bool VulkanGlyphAtlas::create(VkDevice device, VkPhysicalDevice physical, VkQueue /*queue*/, uint32_t /*queueFamily*/, VkCommandPool /*commandPool*/)
{
    // A single slot wider than the device limit fits in no grid at all; Core
    // reports that as an invalid fit and the atlas refuses loudly here rather
    // than handing vkCreateImage an extent it may reject after the fact.
    if (!m_fit.valid)
        return false;
    // The image, its view, the sampler and the staging buffer are
    // VulkanCoverageSheet's — the same resource the ligature strip sheet needs,
    // and the nearest-sampler choice the CPU-versus-GPU oracle rests on lives
    // there so two sheets cannot answer it differently.
    return m_sheet.create(device, physical, m_atlasWidth, m_atlasHeight);
}

void VulkanGlyphAtlas::destroy(VkDevice device)
{
    m_sheet.destroy(device);
}

void VulkanGlyphAtlas::beginFrame()
{
    m_cache.beginFrame();
    if (m_colorAtlas)
        m_colorAtlas->beginFrame();
    if (m_proportionalSheet)
        m_proportionalSheet->beginFrame();
    if (m_proportionalStripSheet)
        m_proportionalStripSheet->beginFrame();
    if (m_ligatureSheet)
        m_ligatureSheet->beginFrame();
}

// MIRROR of SoftwareRenderer::rasterizeInto via the same GlyphRasterizer: faults
// coverage into a slot-local scratch and blits `slotWidthInPixels` px into the
// host mirror. A false return (no glyph) clears those px.
void VulkanGlyphAtlas::rasterizeInto(int slot, int slotWidthInPixels, std::uint32_t codePoint, Rendering::FontFace face)
{
    // Core's arithmetic, not this backend's. The Metal backend uploads to the
    // same slots from the same grid, and two derivations of where slot N sits
    // place a glyph in one rectangle and sample it from another.
    const Rendering::AtlasSlotRegion box = Rendering::atlasSlotRegion(
        slot, m_geometry.columns, m_geometry.slotWidthInPixels, m_geometry.slotHeightInPixels);
    const int slotHeightInPixels = box.height;
    const int x0 = box.x;
    const int y0 = box.y;

    // Every branch below writes the mirror, so every branch marks it dirty —
    // the clear for an absent glyph included. An unmarked write is invisible
    // until the NEXT dirty upload: the first frame uploads unconditionally
    // (the image starts uninitialized), so a glyph first seen on any later
    // frame stayed in the mirror and drew blank, and a blank glyph is what a
    // space looks like.
    markSlotDirty(slot);
    const bool present = m_rasterizer.rasterizeGlyph(codePoint, face,
        /*weight=*/0, slotWidthInPixels, slotHeightInPixels, m_slotScratch.data());
    const std::span<const std::uint8_t> plane = present
        ? std::span<const std::uint8_t>(m_slotScratch).first(static_cast<std::size_t>(slotWidthInPixels) * slotHeightInPixels)
        : std::span<const std::uint8_t> {};
    Rendering::writeAtlasCoverage(m_coverage, m_atlasWidth, { x0, y0, slotWidthInPixels, slotHeightInPixels }, plane);
    // Measured as it lands, so the frame that faulted the glyph already draws
    // its quad at the ink and says where the ink reaches.
    recordInkBox(slot, plane, slotWidthInPixels, slotHeightInPixels);
}

void VulkanGlyphAtlas::recordInkBox(int slot, std::span<const std::uint8_t> plane, int widthInPixels, int heightInPixels)
{
    if (slot < 0 || slot >= m_capacity)
        return;
    m_inkBoxForSlot[static_cast<std::size_t>(slot)] = plane.empty()
        ? Rendering::emptyGlyphInkBox()
        : Rendering::measureInkBox(plane, widthInPixels, heightInPixels);
}

bool VulkanGlyphAtlas::stageMonoCoverage(int slot, std::span<const std::uint8_t> coverage)
{
    const int slotWidth = m_geometry.slotWidthInPixels;
    const int slotHeight = m_geometry.slotHeightInPixels;
    // The count is checked rather than trusted: it is the caller's idea of this
    // slot's size, and a plane the wrong shape would be blitted row by row into
    // the neighbours rather than refused.
    if (slot < 0 || slot >= m_capacity || m_geometry.columns <= 0
        || coverage.size() != static_cast<std::size_t>(slotWidth) * static_cast<std::size_t>(slotHeight))
        return false;

    const int x0 = (slot % m_geometry.columns) * slotWidth;
    const int y0 = (slot / m_geometry.columns) * slotHeight;
    Rendering::writeAtlasCoverage(m_coverage, m_atlasWidth, { x0, y0, slotWidth, slotHeight }, coverage);
    markSlotDirty(slot); // the host mirror moved ahead of the image
    recordInkBox(slot, coverage, slotWidth, slotHeight);
    return true;
}

void VulkanGlyphAtlas::rasterizeClusterInto(int slot, std::span<const std::uint32_t> codePoints, Rendering::FontFace face, std::uint32_t weight)
{
    // The mono overflow canvas, as rasterizeInto fills it for one glyph: a
    // cluster composites into the same box its base alone would take.
    const int width = m_monoSlotWidthInPixels;
    const int height = m_slotHeightInPixels;
    const Rendering::AtlasSlotRegion region { (slot % m_columns) * m_slotWidthInPixels, (slot / m_columns) * m_slotHeightInPixels, width, height };
    const bool inked = m_rasterizer.rasterizeCluster(codePoints.data(), static_cast<int>(codePoints.size()), face, weight, width, height, m_slotScratch.data());
    const std::span<const std::uint8_t> plane = inked ? std::span<const std::uint8_t>(m_slotScratch).first(static_cast<std::size_t>(width) * static_cast<std::size_t>(height)) : std::span<const std::uint8_t> {};
    Rendering::writeAtlasCoverage(m_coverage, m_atlasWidth, region, plane);
    recordInkBox(slot, plane, width, height);
}

void VulkanGlyphAtlas::rasteriseSizedWindowInto(SizedWindowCanvas canvas, int slot, std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t weight, std::uint32_t phase, Rendering::SizedTile tile)
{
    // The window fills the canvas its unsized glyph fills: the mono overflow
    // canvas, or the two-cell box with no horizontal margin. The rest of the
    // grid pitch stays blank. The cut is Core's, the one the software renderer
    // makes, so the two arms hold the same bytes.
    const bool isWide = canvas == SizedWindowCanvas::Wide;
    // The windows step as far as the quads they land on: the face's fractional
    // advance for a glyph-stream quad, the cell box for a grid cell.
    const Rendering::CellMetrics metrics = m_rasterizer.cellMetrics();
    const Rendering::SizedWindowCanvas window = Rendering::sizedWindowCanvas(isWide ? 2 * m_cellWidth : m_monoSlotWidthInPixels,
        m_slotHeightInPixels, isWide ? 0 : m_monoMarginXInPixels, m_monoMarginYInPixels, metrics.cellHeight, metrics.cellWidth, isWide ? 2 : 1, tile.step,
        static_cast<float>(isWide ? 2 * m_cellWidth : m_cellWidth));
    const Rendering::AtlasSlotRegion region { (slot % m_columns) * m_slotWidthInPixels, (slot / m_columns) * m_slotHeightInPixels, window.width, window.height };
    markSlotDirty(slot);
    const std::span<std::uint8_t> pixels = std::span(m_slotScratch).first(static_cast<std::size_t>(window.width) * static_cast<std::size_t>(window.height));
    if (!Rendering::rasteriseSizedWindow(m_rasterizer, codePoint, face, weight, tile, phase, window, m_sizedScratch, pixels)) {
        Rendering::writeAtlasCoverage(m_coverage, m_atlasWidth, region, {});
        return;
    }
    Rendering::writeAtlasCoverage(m_coverage, m_atlasWidth, region, pixels);
}

Rendering::AtlasGlyph VulkanGlyphAtlas::sizedGlyph(std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t weight, std::uint32_t phase, Rendering::SizedTile tile)
{
    if (!m_rasterizer.rasterisesScaledGlyphsSharply())
        return {};
    if (codePoint == 0 || codePoint == ' ' || !Rendering::isSizedMasterTile(tile))
        return {};
    const std::uint32_t scaleLane = tile.scaleLane();
    const std::uint32_t key = Rendering::sizedTileKey(codePoint, weight, face, phase, scaleLane, tile.band, tile.tile);
    // Verified, because the key is a hash and this sheet's cache also holds the
    // mono, wide and cluster keyspaces: a collision must miss, not draw another
    // glyph's window.
    const std::array<std::uint32_t, 2> contents = { codePoint, Rendering::sizedTileWord(weight, face, phase, scaleLane, tile.band, tile.tile) };
    bool isFresh = false;
    const int slot = m_cache.slotForKeyVerified(key, contents.data(), static_cast<int>(contents.size()), &isFresh);
    if (slot < 0)
        return {}; // the sheet is full this frame: the builder crops the cell instead
    if (isFresh)
        rasteriseSizedWindowInto(SizedWindowCanvas::Mono, slot, codePoint, face, weight, phase, tile);
    // The cell box inside the mono slot, past the margin, in atlas pixels — the
    // rect a mono glyph answers with.
    const int left = (slot % m_columns) * m_slotWidthInPixels + m_monoMarginXInPixels;
    const int top = (slot / m_columns) * m_slotHeightInPixels + m_monoMarginYInPixels;
    Rendering::AtlasGlyph out;
    out.minUV = { static_cast<float>(left), static_cast<float>(top) };
    out.maxUV = { static_cast<float>(left + m_cellWidth), static_cast<float>(top + m_cellHeight) };
    out.present = true;
    return out;
}

Rendering::AtlasGlyph VulkanGlyphAtlas::sizedWideGlyph(std::uint32_t codePoint, Rendering::FontFace face, Rendering::SizedTile tile)
{
    if (!m_rasterizer.rasterisesScaledGlyphsSharply())
        return {};
    if (codePoint == 0 || codePoint == ' ' || !Rendering::isSizedMasterTile(tile))
        return {};
    // Weight and phase 0, as wideGlyph keys them. The third word sets the
    // two-cell windows apart from the one-cell ones on this shared sheet; the
    // tag stays the sized-tile tag, and the word count alone fails a probe
    // that lands on a narrow window.
    const std::uint32_t scaleLane = tile.scaleLane();
    const std::array<std::uint32_t, 3> contents = { codePoint, Rendering::sizedTileWord(0u, face, 0u, scaleLane, tile.band, tile.tile), 2u };
    const std::uint32_t key = 0xA0000000u | (Rendering::fnv1aCluster(contents.data(), static_cast<int>(contents.size())) & 0x1FFFFFFFu);
    bool isFresh = false;
    const int slot = m_cache.slotForKeyVerified(key, contents.data(), static_cast<int>(contents.size()), &isFresh);
    if (slot < 0)
        return {};
    if (isFresh)
        rasteriseSizedWindowInto(SizedWindowCanvas::Wide, slot, codePoint, face, 0u, 0u, tile);
    const int left = (slot % m_columns) * m_slotWidthInPixels;
    const int top = (slot / m_columns) * m_slotHeightInPixels + m_monoMarginYInPixels;
    Rendering::AtlasGlyph out;
    out.minUV = { static_cast<float>(left), static_cast<float>(top) };
    out.maxUV = { static_cast<float>(left + 2 * m_cellWidth), static_cast<float>(top + m_cellHeight) };
    out.present = true;
    return out;
}

Rendering::AtlasGlyph VulkanGlyphAtlas::faultGlyph(std::uint32_t key, std::uint32_t codePoint, Rendering::FontFace face)
{
    bool fresh = false;
    const int slot = m_cache.slotForKey(key, &fresh);
    if (slot < 0)
        return {}; // atlas full this frame -> draw background only
    const bool isWide = Rendering::isSharedAtlasWideGlyphKey(key);
    // Mono fills its overflow canvas (cell + 2*margin); wide fills its 2-cell box
    // — not the grid pitch, which is max(2*cell, monoSlot) and would over-stretch
    // a wide glyph when the mono margin pushes the pitch past 2 cells.
    const int wideWidthInPixels = m_cellWidth * 2;
    const int slotWidthInPixels = isWide ? wideWidthInPixels : m_monoSlotWidthInPixels;
    if (fresh) {
        rasterizeInto(slot, slotWidthInPixels, codePoint, face);
        markSlotDirty(slot);
    }

    // UV is the GLYPH BOX (cell box) inside the grid slot, marginInPixels.height down.
    // Mono: cell box centered in the overflow canvas (builder expands it to the
    // full slot for the subpixel GlyphInstance). Wide: 2-cell box. Margins 0
    // (Unifont) ⇒ box == grid slot.
    const int column = slot % m_columns;
    const int row = slot / m_columns;
    const int px0 = column * m_geometry.slotWidthInPixels;
    const int py0 = row * m_geometry.slotHeightInPixels;
    const int glyphX0 = isWide ? px0 : px0 + m_monoMarginXInPixels;
    const int glyphY0 = py0 + m_monoMarginYInPixels;
    const int glyphWidthInPixels = isWide ? wideWidthInPixels : m_cellWidth;
    const int glyphHeight = m_cellHeight;
    Rendering::AtlasGlyph out;
    // Atlas pixels: the shaders texelFetch these directly, so no normalized
    // pair is multiplied back by textureSize.
    out.minUV = { static_cast<float>(glyphX0), static_cast<float>(glyphY0) };
    out.maxUV = { static_cast<float>(glyphX0 + glyphWidthInPixels), static_cast<float>(glyphY0 + glyphHeight) };
    out.present = true;
    return out;
}

Rendering::AtlasGlyph VulkanGlyphAtlas::faultCluster(std::uint32_t key, std::span<const std::uint32_t> codePoints, Rendering::FontFace face, std::uint32_t weight)
{
    bool isFresh = false;
    const int slot = m_cache.slotForKeyVerified(key, codePoints.data(), static_cast<int>(codePoints.size()), &isFresh);
    if (slot < 0)
        return {}; // the sheet is full this frame: background only
    if (isFresh) {
        rasterizeClusterInto(slot, codePoints, face, weight);
        markSlotDirty(slot);
    }
    // The cell box inside the mono slot, past the margin, in atlas pixels: the
    // same units faultGlyph answers in, which the shaders texelFetch directly.
    const int left = (slot % m_columns) * m_slotWidthInPixels + m_monoMarginXInPixels;
    const int top = (slot / m_columns) * m_slotHeightInPixels + m_monoMarginYInPixels;
    Rendering::AtlasGlyph out;
    out.minUV = { static_cast<float>(left), static_cast<float>(top) };
    out.maxUV = { static_cast<float>(left + m_cellWidth), static_cast<float>(top + m_cellHeight) };
    out.present = true;
    return out;
}

Rendering::AtlasGlyph VulkanGlyphAtlas::monoGlyph(std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t weight, std::uint32_t phase) { return faultGlyph(Rendering::monoGlyphKey(codePoint, weight, face, phase), codePoint, face); }

// The builder probes this cache itself, so what crosses is the cache and its
// layout rather than a call per cell. Weight 0 for the reason wideGlyph gives:
// this rasterizer applies no variable weight, so one key keeps key and raster in
// agreement instead of fanning a glyph across slots the raster fills identically.
Rendering::MonoAtlasBinding VulkanGlyphAtlas::bindMonoAtlas()
{
    Rendering::MonoAtlasBinding binding;
    binding.cache = &m_cache;
    binding.geometry = m_geometry;
    binding.slotCapacity = m_capacity;
    binding.inkBoxForSlot = m_inkBoxForSlot.data();
    binding.weight = 0u;
    return binding;
}

// The mono overflow canvas (cell + 2*margin), not the grid pitch: the pitch is
// max(2*cell, monoSlot) and rasterising to it would stretch the glyph wherever
// the mono margin pushes the pitch past two cells.
bool VulkanGlyphAtlas::rasteriseMonoGlyph(std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t, int slot)
{
    // No branch leaves before the upload: a code point the rasterizer declines
    // still lands in the slot as a blank, which is a defined answer this key
    // owns rather than the last tenant's ink.
    rasterizeInto(slot, m_monoSlotWidthInPixels, codePoint, face);
    return true;
}

Rendering::AtlasGlyph VulkanGlyphAtlas::clusterGlyph(const std::uint32_t* codePoints, int count, Rendering::FontFace face, std::uint32_t weight, std::uint32_t phase)
{
    const std::span<const std::uint32_t> cluster = count > 0 ? std::span(codePoints, static_cast<std::size_t>(count)) : std::span<const std::uint32_t> {};
    return faultCluster(Rendering::coverageClusterKey(codePoints, count, phase, face), cluster, face, weight);
}

// Weight 0: the Vulkan rasterizer applies no variable weight, so keying a single
// weight keeps key and raster in agreement (and avoids fanning one glyph across
// per-weight slots the raster fills identically).
Rendering::AtlasGlyph VulkanGlyphAtlas::wideGlyph(std::uint32_t codePoint, Rendering::FontFace face) { return faultGlyph(Rendering::sharedAtlasWideGlyphKey(codePoint, 0u, face), codePoint, face); }

Rendering::GlyphBackend VulkanGlyphAtlas::glyphBackend()
{
    Rendering::GlyphBackend backend;
    backend.context = this;
    // The primary face's pitch and the letter layout's shaper are the
    // rasterizer's, the same instance the CPU arm faults through.
    backend.primaryFacePitch = m_rasterizer.primaryFacePitch();
    backend.shapePrimaryRun = [](void* context, Rendering::ClusterSpan codePoints, Rendering::FontFace face, std::uint32_t weight,
                                  Ubiquitty::ProportionalShapedGlyph* out, int capacity) {
        if (!out || capacity <= 0)
            return 0;
        return static_cast<VulkanGlyphAtlas*>(context)->m_rasterizer.shapePrimaryRun(codePoints, face, weight,
            std::span<Ubiquitty::ProportionalShapedGlyph>(out, static_cast<std::size_t>(capacity)));
    };
    backend.beginFrame = [](void* context) { static_cast<VulkanGlyphAtlas*>(context)->beginFrame(); };
    backend.bindMonoAtlas = [](void* context) { return static_cast<VulkanGlyphAtlas*>(context)->bindMonoAtlas(); };
    backend.rasteriseMonoGlyph = [](void* context, std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t variant, int slot) {
        return static_cast<VulkanGlyphAtlas*>(context)->rasteriseMonoGlyph(codePoint, face, variant, slot);
    };
    backend.stageMonoCoverage = [](void* context, int slot, std::span<const std::uint8_t> coverage) {
        return static_cast<VulkanGlyphAtlas*>(context)->stageMonoCoverage(slot, coverage);
    };
    backend.monoGlyph = [](void* context, std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t weight, std::uint32_t phase) {
        return static_cast<VulkanGlyphAtlas*>(context)->monoGlyph(codePoint, face, weight, phase);
    };
    // Box LINES keep Core's font-first policy, answered by the ordinary mono
    // fetch as SoftwareRenderer answers it: the face's strokes carry its weight
    // and dashes, and a refusal falls to the box-fill stream's geometry.
    backend.boxGlyph = [](void* context, std::uint32_t codePoint, Rendering::FontFace face) {
        return static_cast<VulkanGlyphAtlas*>(context)->monoGlyph(codePoint, face, 0, 0);
    };
    // Colour hooks, present only when a colour sheet was attached and that sheet
    // found a face — both conditions, since either alone leaves nothing to
    // sample. Left null otherwise, which is how a cluster falls to the mono path
    // and draws as an outline rather than as an empty cell.
    if (m_colorAtlas && m_colorAtlas->hasColorSource()) {
        backend.bindColorAtlas = [](void* context) {
            return static_cast<VulkanGlyphAtlas*>(context)->m_colorAtlas->bindColorAtlas();
        };
        backend.rasteriseColorGlyph = [](void* context, std::span<const std::uint32_t> codePoints, int slot) {
            return static_cast<VulkanGlyphAtlas*>(context)->m_colorAtlas->rasteriseColorGlyph(codePoints.data(), static_cast<int>(codePoints.size()), slot);
        };
        backend.sizedColorGlyph = [](void* context, std::span<const std::uint32_t> codePoints, Rendering::SizedTile tile) {
            return static_cast<VulkanGlyphAtlas*>(context)->m_colorAtlas->sizedColorGlyph(codePoints, tile);
        };
    }

    backend.wideGlyph = [](void* context, std::uint32_t codePoint, Rendering::FontFace face) {
        return static_cast<VulkanGlyphAtlas*>(context)->wideGlyph(codePoint, face);
    };
    backend.sizedGlyph = [](void* context, std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t weight, std::uint32_t phase, Rendering::GlyphPass, Rendering::SizedTile tile) {
        return static_cast<VulkanGlyphAtlas*>(context)->sizedGlyph(codePoint, face, weight, phase, tile);
    };
    backend.sizedWideGlyph = [](void* context, std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t, Rendering::SizedTile tile) {
        return static_cast<VulkanGlyphAtlas*>(context)->sizedWideGlyph(codePoint, face, tile);
    };
    backend.doubleGlyph = [](void* context, std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t, Rendering::DoubleRegion region) {
        return static_cast<VulkanGlyphAtlas*>(context)->doubleGlyph(codePoint, face, region);
    };
    backend.clusterGlyph = [](void* context, std::span<const std::uint32_t> codePoints, Rendering::FontFace face, std::uint32_t weight, std::uint32_t phase) {
        return static_cast<VulkanGlyphAtlas*>(context)->clusterGlyph(codePoints.data(), static_cast<int>(codePoints.size()), face, weight, phase);
    };
    // Ligature shaping, present only over a sheet that reports itself usable —
    // it needs a face with a shaper, and a sheet whose slot did not fit reports
    // false. Both conditions, and for a sharper reason than the colour pair
    // above: publishing this hook moves a covered cell's glyph off the mono path,
    // so a hook that then has no strip to answer with draws nothing at all.
    if (m_ligatureSheet && m_ligatureSheet->isUsable()) {
        backend.shapeLigatureRuns = [](void* context, Rendering::LigatureRowSpan row, float /*rowOriginXInPixels*/,
                                        float cellWidthInPixels, Rendering::GlyphPass, Rendering::LigatureRunStream runs) {
            // The row origin is not passed on: this sheet shapes into slots and
            // reports the strip in atlas pixels, so where the row lands on
            // screen is the builder's arithmetic and never the shaper's.
            static_cast<VulkanGlyphAtlas*>(context)->m_ligatureSheet->shapeRow(row, cellWidthInPixels, runs);
        };
    }
    // The proportional strip, over a sheet whose rasterizer has a proportional
    // face. Published only then, for the reason above: the hook moves the run
    // off the grid-face fallback, and a hook that answers absent draws nothing.
    if (m_proportionalStripSheet && m_proportionalStripSheet->hasProportionalFace()) {
        backend.proportionalStrip = [](void* context, Rendering::ClusterSpan codePoints, int widthCells, std::uint8_t horizontalAlign,
                                        float penResidualInPixels, Rendering::FontFace face, std::uint32_t /*weight*/, std::uint32_t variant, int tileIndex, Rendering::SizedTile size) {
            VulkanGlyphAtlas* atlas = static_cast<VulkanGlyphAtlas*>(context);
            return atlas->m_proportionalStripSheet->proportionalStrip(codePoints, widthCells, horizontalAlign, penResidualInPixels,
                static_cast<float>(atlas->cellWidth()), face, variant, tileIndex, size);
        };
    }
    if (m_proportionalSheet && m_proportionalSheet->isUsable()) {
        backend.bindProportionalAtlas = [](void* context) {
            return static_cast<VulkanGlyphAtlas*>(context)->m_proportionalSheet->binding();
        };
        backend.shapeProportionalRun = [](void* context, Rendering::ClusterSpan codePoints,
                                           Rendering::FontFace face, std::uint32_t,
                                           Ubiquitty::ProportionalShapedGlyph* out, int capacity) {
            if (!out || capacity <= 0)
                return 0;
            return static_cast<VulkanGlyphAtlas*>(context)->m_proportionalSheet->shapeRun(
                codePoints, face, std::span<Ubiquitty::ProportionalShapedGlyph>(out, static_cast<std::size_t>(capacity)));
        };
        backend.rasteriseProportionalGlyph = [](void* context, std::uint32_t glyphID,
                                                 Rendering::FontFace face, std::uint32_t weight,
                                                 std::uint32_t variant, int slot) {
            return static_cast<VulkanGlyphAtlas*>(context)->m_proportionalSheet->rasteriseGlyph(
                glyphID, face, weight, variant, slot);
        };
        backend.rasteriseSizedProportionalGlyph = [](void* context, std::uint32_t glyphID, Rendering::FontFace face, std::uint32_t weight,
                                                      std::uint32_t variant, Rendering::SizedTile tile, int slot) {
            return static_cast<VulkanGlyphAtlas*>(context)->m_proportionalSheet->rasteriseSizedGlyph(
                glyphID, face, weight, variant, tile, slot);
        };
    }
    return backend;
}

void VulkanGlyphAtlas::markSlotDirty(int slot)
{
    if (slot < 0)
        return;
    if (slot < m_firstDirtySlot)
        m_firstDirtySlot = slot;
    if (m_lastDirtySlot == INT_MAX || slot > m_lastDirtySlot)
        m_lastDirtySlot = slot;
}

Rendering::AtlasRowBand VulkanGlyphAtlas::dirtyRows() const
{
    if (!m_sheet.isReadable() || m_lastDirtySlot == INT_MAX)
        return { 0, m_atlasHeight };
    return Rendering::atlasDirtyRowBand(m_firstDirtySlot, m_lastDirtySlot,
        m_geometry.columns, m_geometry.slotHeightInPixels, m_atlasHeight);
}

bool VulkanGlyphAtlas::upload(VkDevice device, VkQueue queue, VkCommandPool commandPool)
{
    const Rendering::AtlasRowBand band = dirtyRows();
    if (!m_sheet.upload(device, queue, commandPool, m_coverage, band.firstRow, band.rowCount))
        return false;
    didUpload();
    return true;
}

bool VulkanGlyphAtlas::recordUpload(VkDevice device, VkCommandBuffer commandBuffer)
{
    const Rendering::AtlasRowBand band = dirtyRows();
    return m_sheet.recordUpload(device, commandBuffer, m_coverage, band.firstRow, band.rowCount);
}

void VulkanGlyphAtlas::didUpload()
{
    m_sheet.didUpload();
    m_firstDirtySlot = INT_MAX;
    m_lastDirtySlot = -1;
}

} // namespace Ubiquitty::Linux
