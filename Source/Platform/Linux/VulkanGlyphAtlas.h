// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Vulkan side of the glyph-atlas seam (Rendering::GlyphBackend). Owns one
// combined R8 VkImage atlas driven by a portable GlyphSlotCache: mono glyphs
// occupy the LEFT cellWidth px of a slot and return the left-half UV; wide glyphs
// fill it. MIRRORS the CPU SoftwareRenderer::rasterizeInto so coverage is
// byte-identical (the CPU<->GPU oracle). The owner (VulkanRenderer) creates the
// image + view + sampler and re-uploads touched slots before each draw.

#include "Core/Rendering/CellInstanceBuilder.h"
#include "Core/Rendering/GlyphRasterizer.h"
#include "Core/Rendering/GlyphSlotCache.h"
#include "Core/Rendering/UnifontRasterizer.h"
#include "Platform/Linux/VulkanColorGlyphAtlas.h"
#include "Platform/Linux/VulkanCoverageSheet.h"

#include <climits>
#include <cstdint>
#include <span>
#include <vector>

#include <vulkan/vulkan.h>

// Declared rather than included: the strip sheet reaches this class only as a
// pointer, and it includes the shaper, which nothing on this side needs.
namespace Ubiquitty::Rendering {
struct AtlasRowBand;
class LigatureSheet;
class ProportionalGlyphSheet;
}

namespace Ubiquitty::Linux {

/// The Vulkan side of the glyph seam.
///
/// Owns one R8 image holding mono, wide and cluster slots, which is why its wide
/// keys carry ``sharedAtlasWideGlyphKey``'s tag and Metal's do not.
class VulkanGlyphAtlas {
public:
    // Defaults to the owned UnifontRasterizer; pass a real-font rasterizer (the
    // same instance the SoftwareRenderer gets) to keep coverage byte-identical.
    // The caller owns the injected rasterizer.
    /// Builds an atlas over the owned Unifont rasterizer.
    ///
    /// `maxTextureDimension` defaults to the 2D size every conformant Vulkan
    /// device must support, so a caller with no device yet still gets a grid
    /// no device may refuse; the renderer passes the queried limit instead.
    ///
    /// - Parameters:
    ///   - cellWidthInPixels: The cell box width the slots are sized for.
    ///   - cellHeightInPixels: The cell box height.
    ///   - maxTextureDimension: The device's largest 2D texture edge.
    VulkanGlyphAtlas(int cellWidthInPixels, int cellHeightInPixels, int maxTextureDimension = 4096, int cellsInWidestScreen = 0);

    /// Builds an atlas whose coverage comes from `rasterizer`, at an explicit
    /// cell size.
    ///
    /// - Parameters:
    ///   - cellWidthInPixels: The cell box width the slots are sized for.
    ///   - cellHeightInPixels: The cell box height.
    ///   - rasterizer: Draws the glyphs; the caller owns it.
    ///   - maxTextureDimension: The device's largest 2D texture edge.
    VulkanGlyphAtlas(int cellWidthInPixels, int cellHeightInPixels, Rendering::GlyphRasterizer&, int maxTextureDimension = 4096, int cellsInWidestScreen = 0);
    // Font-derived cell: size the slots to the injected rasterizer's cellMetrics()
    // (the same dims the CPU path derives from the same rasterizer). Caller owns it.
    explicit VulkanGlyphAtlas(Rendering::GlyphRasterizer&, int maxTextureDimension = 4096, int cellsInWidestScreen = 0);

    // The cell geometry the atlas slots are sized for (font-derived when
    // constructed from a rasterizer).
    [[nodiscard]] int cellWidth() const { return m_cellWidth; }
    [[nodiscard]] int cellHeight() const { return m_cellHeight; }

    /// Whether this atlas has the slots Core's sheet rule asks for a screen
    /// of `cellsOnScreen` cells (``Rendering::glyphSheetGridForScreen``).
    ///
    /// An atlas is cut for the grid it first served, so a grid that grows past
    /// it has more cells than the atlas has slots for; its owner rebuilds it.
    ///
    /// - Parameters:
    ///   - cellsOnScreen: Cells in the grid the next frame draws.
    ///   - maxTextureDimension: The device's 2D texture limit.
    /// - Returns: True when no larger grid would be cut for that screen.
    [[nodiscard]] bool holdsScreen(int cellsOnScreen, int maxTextureDimension) const;

    // The rasterizer the slots fault through — so the owner reads the same
    // cellMetrics() the slots were sized from for the decoration pass.
    [[nodiscard]] Rendering::GlyphRasterizer& rasterizer() const { return m_rasterizer; }

    // Create the VkImage (R8, SAMPLED + TRANSFER_DST) + view + nearest /
    // clamp-to-edge sampler + host-visible staging buffer. False on any Vulkan
    // failure. queue/commandPool are borrowed for the per-frame slot uploads.
    bool create(VkDevice, VkPhysicalDevice, VkQueue, uint32_t queueFamily, VkCommandPool);
    void destroy(VkDevice);

    // Re-upload every slot rasterized since the last upload, leaving the image in
    // SHADER_READ_ONLY_OPTIMAL. Call after buildCellInstances, before the draw.
    // Idempotent when nothing was touched.
    bool upload(VkDevice, VkQueue, VkCommandPool);

    /// Stages changed slots and records their copy beside the frame's draw.
    /// The previous upload must have completed. Keep this atlas unchanged until
    /// the command buffer completes, then call `didUpload`.
    [[nodiscard]] bool recordUpload(VkDevice device, VkCommandBuffer commandBuffer);

    /// Commits the dirty range and image layout after successful completion.
    void didUpload();

    [[nodiscard]] VkImageView view() const { return m_sheet.view(); }
    [[nodiscard]] VkSampler sampler() const { return m_sheet.sampler(); }

    /// The seam this atlas supplies, as a table.
    ///
    /// `wideClusterGlyph` stays null as well: a two-cell base carrying combining
    /// marks takes Core's default, which draws the wide base and drops the marks.
    /// That default lands on `wideGlyph`, which this table does supply — the
    /// sentence above describes a degraded glyph rather than an absent one only
    /// because of that, and it stops being true the moment the wide entry goes.
    /// `colorGlyph` stays null; `shapeLigatureRuns` is published when a strip
    /// sheet is attached and reports itself usable, and a host whose font has no
    /// shaper leaves it absent and renders rows unligatured.
    ///
    /// Colour is not absent: `VulkanColorGlyphAtlas` is a dedicated RGBA sheet
    /// (`VK_FORMAT_R8G8B8A8_UNORM`), and the colour routes are assigned when it
    /// has a face to draw from, so the builder takes its bound-cache path
    /// (`buildCellInstances` tries `rasteriseColorGlyph` on a bound colour cache
    /// first) and never asks for this entry. What decides is the machine rather
    /// than this file: the sheet exists when FreeType loaded an emoji face
    /// (`FreeTypeRasterizer::hasColorGlyphs`), and a system
    /// with no emoji font installed leaves the routes null and an emoji drawing
    /// as coverage. Both are accurate reports of this backend on that host,
    /// which is a claim a header cannot make on its own.
    ///
    /// `boxGlyph` is the mono fetch, as SoftwareRenderer's is: the lines in
    /// 2500..257F, where `BoxDrawing::prefersProcedural` is false, keep the
    /// face's weight and dashes, and the fills Core decomposes into the
    /// box-fill stream never reach it.
    ///
    /// - Returns: A table pointing at this atlas, valid for its lifetime.
    /// Points the backend's colour hooks at a sheet this does not own.
    ///
    /// `GlyphBackend` carries one `context` for every hook, so the colour
    /// entries can only reach a second object through this one. The pointer is
    /// all that crosses: no format or slot arithmetic is shared, which is what
    /// keeps this class a single R8 sheet.
    ///
    /// - Parameter colorAtlas: The colour sheet, or null to leave the hooks
    ///   absent so every cluster takes the mono path.
    void setColorAtlas(VulkanColorGlyphAtlas* colorAtlas) { m_colorAtlas = colorAtlas; }

    /// Points the backend's ligature hook at a strip sheet this does not own.
    ///
    /// Attached on the same terms as the colour sheet and for the same reason:
    /// one `context` serves every hook, so a second sheet is reachable only
    /// through this one. What crosses is the pointer.
    ///
    /// The hook is published only for a sheet that reports itself usable, which
    /// is the difference between a row rendering unligatured and a row rendering
    /// blank: Core routes a covered cell's glyph away from the mono path the
    /// moment the hook exists, so a hook over a sheet with no strip to give
    /// takes the cells with it.
    ///
    /// - Parameter ligatureSheet: The strip sheet, or null to leave the hook
    ///   absent so every row takes the per-glyph path.
    void setLigatureSheet(Rendering::LigatureSheet* ligatureSheet) { m_ligatureSheet = ligatureSheet; }

    /// Points the backend's proportional-strip hook at its independent sheet.
    ///
    /// - Parameter proportionalStripSheet: The non-owning sheet, or null when
    ///   proportional strip shaping is unavailable.
    void setProportionalStripSheet(Rendering::LigatureSheet* proportionalStripSheet) { m_proportionalStripSheet = proportionalStripSheet; }

    /// Points the backend's proportional hooks at a dedicated sheet this does
    /// not own.
    ///
    /// - Parameter proportionalSheet: The sheet, or null to keep the strip or
    ///   grid-face fallback.
    void setProportionalSheet(Rendering::ProportionalGlyphSheet* proportionalSheet) { m_proportionalSheet = proportionalSheet; }

    [[nodiscard]] Rendering::GlyphBackend glyphBackend();

    /// Starts a frame on the owned cache, so a slot touched inside it is not
    /// evicted within it.
    void beginFrame();
    /// Returns one code point's atlas rect, faulting it into a slot on a miss.
    ///
    /// - Parameters:
    ///   - codePoint: The code point to draw.
    ///   - weight: The variable-font weight the key is derived with.
    ///   - phase: The subpixel phase the key is derived with.
    /// - Returns: The glyph's atlas rect, or an absent glyph when no slot is free.
    Rendering::AtlasGlyph monoGlyph(std::uint32_t codePoint, Rendering::FontFace, std::uint32_t weight, std::uint32_t phase);
    /// Hands the builder this renderer's mono atlas for one frame.
    ///
    /// - Returns: The slot cache, its layout and capacity, and weight 0 — this
    ///   rasterizer applies no variable weight, so one key keeps key and raster
    ///   in agreement.
    Rendering::MonoAtlasBinding bindMonoAtlas();
    /// Rasterizes a mono glyph into a slot the cache has just allocated.
    ///
    /// - Parameters:
    ///   - codePoint: The code point to draw.
    ///   - phase: Ignored; this rasterizer has no subpixel phases.
    ///   - slot: The slot to draw into.
    /// - Returns: True, always. No branch leaves before the upload — a code
    ///   point the rasterizer declines still lands in the slot as a blank,
    ///   which is a defined answer this key owns.
    bool rasteriseMonoGlyph(std::uint32_t codePoint, Rendering::FontFace, std::uint32_t variant, int slot);
    /// Returns the monochrome master for a base and its combining marks.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster's code points, base first.
    ///   - count: How many of them.
    ///   - weight: The variable-font weight the raster applies.
    ///   - phase: The subpixel phase the key is derived with.
    /// - Returns: The run's atlas rect, or an absent glyph when no slot is free.
    Rendering::AtlasGlyph clusterGlyph(const std::uint32_t* codePoints, int count, Rendering::FontFace, std::uint32_t weight, std::uint32_t phase);
    /// Returns a two-cell glyph's rect, tagged into the shared atlas's wide
    /// keyspace so it cannot collide with a box key.
    ///
    /// - Parameter codePoint: The code point to draw.
    /// - Returns: The glyph's atlas rect, or an absent glyph when no slot is free.
    Rendering::AtlasGlyph wideGlyph(std::uint32_t codePoint, Rendering::FontFace);
    /// Reports no 2x master on a sheet of its own.
    ///
    /// The combined image has one uniform slot pitch, so a double-height slot
    /// cannot share its grid. A doubled row's cells take ``sizedGlyph`` windows
    /// of their doubled master instead, and only a cell those decline is the
    /// 1x glyph cropped.
    ///
    /// - Parameters:
    ///   - codePoint: Ignored; no code point has a master here.
    ///   - face: Ignored, for the same reason.
    /// - Returns: An absent glyph, always.
    Rendering::AtlasGlyph doubleGlyph(std::uint32_t codePoint, Rendering::FontFace face, Rendering::DoubleRegion)
    {
        (void)codePoint;
        (void)face;
        return {};
    }
    /// Returns one slot-shaped window of a glyph rasterised at an OSC 66 scale.
    ///
    /// Backs ``Rendering::GlyphBackend::sizedGlyph``: FreeType draws the master
    /// Core selects for the tile (``Rendering::selectSizedMaster``) — an OSC 66
    /// block at its scale, a DECDHL glyph at twice its height, a DECDWL glyph
    /// twice as wide — and ``Rendering::rasteriseSizedWindow`` cuts the window
    /// `(tile.band, tile.tile)` of it into an ordinary mono slot, as the software
    /// renderer cuts it. The two arms then hold the same coverage for the same
    /// tile, which keeps the CPU-versus-GPU oracle byte-identical on sized text.
    ///
    /// Declined, so the builder crops the cell's own raster instead, for a
    /// rasterizer that would only magnify (a bitmap face such as Unifont), for a
    /// blank, and for a tile no master serves (``Rendering::isSizedMasterTile``):
    /// those are the tiles `SoftwareRenderer::sizedGlyph` declines.
    ///
    /// - Parameters:
    ///   - codePoint: The code point to draw.
    ///   - weight: The variable-font weight the key is derived with.
    ///   - phase: The subpixel phase the key is derived with.
    ///   - tile: The scale, fraction and window to cut.
    /// - Returns: The window's glyph box in atlas pixels, or an absent glyph when
    ///   declined or when no slot is free.
    Rendering::AtlasGlyph sizedGlyph(std::uint32_t codePoint, Rendering::FontFace, std::uint32_t weight, std::uint32_t phase, Rendering::SizedTile tile);

    /// ``sizedGlyph`` for a two-cell glyph, windows two cells wide.
    ///
    /// Backs ``Rendering::GlyphBackend::sizedWideGlyph``. The master is the
    /// tile's scale times the canvas ``wideGlyph`` rasterises into, and each
    /// window is cut into a wide slot of the same sheet, stepping by the two
    /// cells the builder's wide tiles span, as `SoftwareRenderer::sizedWideGlyph`
    /// cuts it on its wide page. Declined where ``sizedGlyph`` is.
    ///
    /// The sheet is shared, so the key's verified contents carry a third word
    /// the narrow windows lack: a code point whose width setting changes between
    /// frames keys its two-cell windows apart from its one-cell ones.
    ///
    /// - Parameters:
    ///   - codePoint: The code point to draw.
    ///   - tile: The scale, fraction and window to cut.
    /// - Returns: The window's two-cell glyph box in atlas pixels, or an absent
    ///   glyph when declined or when no slot is free.
    Rendering::AtlasGlyph sizedWideGlyph(std::uint32_t codePoint, Rendering::FontFace, Rendering::SizedTile tile);

    /// Copies a coverage plane the builder rasterised into a mono slot.
    ///
    /// Backs ``Rendering::GlyphBackend::stageMonoCoverage``, whose whole
    /// obligation is this copy: the glyphs Core draws itself — a DECDLD soft
    /// font today — arrive as finished pixels rather than as something to look
    /// up, so no rasterizer of this backend's is consulted.
    ///
    /// - Parameters:
    ///   - slot: The slot the cache assigned.
    ///   - coverage: R8 bytes, row-major, laid out for the slot box; the size
    ///     is checked against the slot rather than trusted.
    /// - Returns: Whether the slot was written.
    bool stageMonoCoverage(int slot, std::span<const std::uint8_t> coverage);

    /// Returns the R8 host mirror the image is uploaded from, row-major.
    ///
    /// Every raster and every stage writes the mirror, and the upload copies it
    /// verbatim, so what a slot holds here is what the sampler will read. That
    /// makes a slot's placement checkable on a machine with no GPU — including
    /// whether writing one slot left its neighbours alone, which a rendering
    /// cannot show and a wrong row pitch would break.
    ///
    /// - Returns: `atlasWidth * atlasHeight` bytes, empty while unsized.
    [[nodiscard]] std::span<const std::uint8_t> monoCoverage() const { return m_coverage; }

    /// Returns the host mirror's row pitch in pixels.
    ///
    /// - Returns: The atlas width; a row of the mirror starts every this many bytes.
    [[nodiscard]] int atlasWidthInPixels() const { return m_atlasWidth; }

private:
    [[nodiscard]] Rendering::AtlasRowBand dirtyRows() const;
    Rendering::AtlasGlyph faultGlyph(std::uint32_t key, std::uint32_t codePoint, Rendering::FontFace);
    // The cluster counterpart of faultGlyph: the slot its key holds, or a fresh
    // one composited through the rasterizer's cluster path, and the cell box
    // inside it in atlas pixels.
    Rendering::AtlasGlyph faultCluster(std::uint32_t key, std::span<const std::uint32_t> codePoints, Rendering::FontFace, std::uint32_t weight);
    // MIRRORS SoftwareRenderer::rasterizeInto via the same GlyphRasterizer: faults
    // coverage into a slot-local scratch and blits `slotWidthInPixels` px into the
    // host mirror. slotWidthInPixels is cellWidth for mono (left half), 2*cellWidth
    // for wide. The face is the cell's: the key already tells bold from regular,
    // so a raster that asked for the regular face regardless filled the bold
    // slot with regular ink, and every bold cell drew regular on this arm alone.
    void rasterizeInto(int slot, int slotWidthInPixels, std::uint32_t codePoint, Rendering::FontFace);
    /// Records the ink box a raster just written to `slot` covers.
    ///
    /// - Parameters:
    ///   - slot: The slot written.
    ///   - plane: The slot-relative coverage written, empty for a blank.
    ///   - widthInPixels: The plane's width.
    ///   - heightInPixels: The plane's height.
    void recordInkBox(int slot, std::span<const std::uint8_t> plane, int widthInPixels, int heightInPixels);
    // The cluster counterpart of rasterizeInto, into the mono overflow canvas.
    void rasterizeClusterInto(int slot, std::span<const std::uint32_t> codePoints, Rendering::FontFace, std::uint32_t weight);
    /// The canvas a sized window fills inside its slot.
    enum class SizedWindowCanvas : std::uint8_t {
        /// The mono overflow canvas: the cell with a margin at each side.
        Mono,
        /// The two-cell box, with no horizontal margin.
        Wide,
    };
    /// Draws the glyph at the tile's scale and cuts the tile's window of it
    /// into the slot, as ``sizedGlyph`` and ``sizedWideGlyph`` describe.
    ///
    /// - Parameters:
    ///   - canvas: Which canvas the window fills.
    ///   - slot: The slot the cache assigned to the tile.
    ///   - codePoint: The code point to draw.
    ///   - weight: The variable-font weight the raster applies.
    ///   - phase: The anchor's raster variant, whose phase bits are drawn into the window.
    ///   - tile: The scale, fraction and window to cut.
    void rasteriseSizedWindowInto(SizedWindowCanvas canvas, int slot, std::uint32_t codePoint, Rendering::FontFace, std::uint32_t weight, std::uint32_t phase, Rendering::SizedTile);

    [[nodiscard]] uint32_t findMemoryType(VkPhysicalDevice, uint32_t typeBits, VkMemoryPropertyFlags want) const;

    int m_cellWidth;
    int m_cellHeight;
    // Declared before the slot-geometry members: m_monoMarginXInPixels reads this
    // rasterizer's glyphOverhang(), and the cell-width/height ctor delegates with
    // m_unifont as the rasterizer — so it must be constructed first.
    // Attached by the backend and freed by it: the setters hand over pointers,
    // never the sheets.
    VulkanColorGlyphAtlas* m_colorAtlas = nullptr;
    Rendering::LigatureSheet* m_ligatureSheet = nullptr;
    Rendering::LigatureSheet* m_proportionalStripSheet = nullptr;
    Rendering::ProportionalGlyphSheet* m_proportionalSheet = nullptr;
    Rendering::UnifontRasterizer m_unifont; // default raster + injected fallback
    int m_monoMarginXInPixels; // horizontal overflow margin per side (0 ⇒ cell-tight)
    int m_monoMarginYInPixels; // vertical overflow margin per side (0 ⇒ cell-tight)
    int m_monoSlotWidthInPixels; // cellWidth + 2*m_monoMarginXInPixels — the mono overflow canvas
    int m_slotWidthInPixels; // max(2*cellWidth, m_monoSlotWidthInPixels) — the grid slot pitch
    int m_slotHeightInPixels; // cellHeight + 2*m_monoMarginYInPixels — the grid slot height
    // Core's fit of the grid to the texture limit, before any dimension is
    // derived from it. The Metal sheets clamp through the same function; a
    // backend that skipped it hands vkCreateImage an extent the device may
    // refuse, at exactly the font sizes nobody tests.
    Rendering::AtlasGridFit m_fit;
    int m_columns;
    int m_capacity;
    int m_atlasWidth;
    int m_atlasHeight;

    /// Widens the dirty range to include this slot.
    ///
    /// Called wherever the mirror is written, because a write the range does
    /// not cover is a glyph the device never receives: the slot holds its new
    /// coverage on the host and the image keeps the previous occupant, which
    /// draws as whichever character was there before.
    ///
    /// - Parameter slot: The slot just written. A negative slot widens nothing.
    void markSlotDirty(int slot);

    Rendering::GlyphSlotCache m_cache;
    Rendering::GlyphSlotGeometry m_geometry; // grid-slot geometry (pitch = m_slotWidthInPixels)
    std::vector<std::uint8_t> m_coverage; // R8 host mirror, atlasWidth*atlasHeight
    Rendering::GlyphRasterizer& m_rasterizer; // == m_unifont unless one is injected
    std::vector<std::uint8_t> m_slotScratch; // slotWidthInPixels*slotHeightInPixels R8, reused per glyph
    // Per slot, the ink its raster measured, slot-relative and guarded
    // (Rendering::measureInkBox), handed to the builder on the mono binding.
    std::vector<Rendering::GlyphInkBox> m_inkBoxForSlot; // capacity
    std::vector<std::uint8_t> m_sizedScratch; // the scaled master a sized window is cut from, reused per window
    // The slots whose mirror bytes are ahead of the image, as an inclusive
    // range. A range rather than a set of slots: the copy addresses rows, so
    // two dirty slots also carry the band between them -- which is still the
    // difference between kilobytes and the whole megabyte sheet, and costs no
    // bookkeeping per slot.
    //
    // Starts covering everything, because the image is uninitialized until the
    // first upload and a mirror that has never been sent is entirely ahead of
    // it.
    int m_firstDirtySlot = 0;
    int m_lastDirtySlot = INT_MAX;

    // The device-side sheet: image, view, sampler, staging and the barriers that
    // move it between transfer and shader-read. Shared with the ligature strip
    // sheet, which is the same resource at a different extent.
    VulkanCoverageSheet m_sheet;
};

} // namespace Ubiquitty::Linux
