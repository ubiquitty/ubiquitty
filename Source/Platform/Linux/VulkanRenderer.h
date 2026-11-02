// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Offscreen Vulkan for the Linux frontend. No swapchain / surface / present:
// render into a VkImage, copy to a host-visible buffer, hand tightly-packed RGBA8
// to GTK as a GdkMemoryTexture. Runs headless on Mesa lavapipe. renderGrid
// consumes the same portable buildCellInstances output the CPU SoftwareRenderer
// composites, drawing it with instanced pipelines over a VulkanGlyphAtlas — the
// CPU<->GPU oracle.

#include "Core/Rendering/CellInstance.h"
#include "Core/Rendering/FocusedMatchBounce.h"
#include "Core/Rendering/FrameDamage.h"
#include "Core/Rendering/GlyphRasterizer.h"
#include "Core/Rendering/LetterLayout.h"
#include "Core/Rendering/LigatureSheet.h"
#include "Core/Rendering/OverlayGeometry.h"
#include "Core/Rendering/OverlaySpanGather.h"
#include "Core/Rendering/ProportionalGlyphSheet.h"
#include "Platform/Linux/FreeTypeRasterizer.h"
#include "Platform/Linux/ImageExtent.h"
#include "Platform/Linux/Raster.h"
#include "Platform/Linux/VulkanColorGlyphAtlas.h"
#include "Platform/Linux/VulkanGlyphAtlas.h"
#include "Platform/Linux/VulkanImageTextures.h"

#include <array>
#include <atomic>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include <vulkan/vulkan.h>

namespace Ubiquitty {
struct Terminal;
} // Ubiquitty::Terminal, the global cell-model POD
namespace Ubiquitty {
namespace Selection {
struct Session;
}
} // Selection/Selection.h — the portable selection state

namespace Ubiquitty::Linux {

/// A frame's hand-back of the model.
///
/// The renderer reads the Terminal while it builds the frame's instances and
/// never after; a caller that holds the model lock for that read is told
/// here, at the boundary, so the parser is not stalled for the GPU pass
/// and the readback that follow.
struct ModelCaptureHandoff {
    /// Called on the rendering thread with `context`, or never when null.
    void (*onCaptured)(void* context) = nullptr;
    /// Handed back verbatim.
    void* context = nullptr;
};

class VulkanRenderer {
public:
    bool init();
    void shutdown();

    // Inject the glyph rasterizer the GPU atlas faults through so GPU coverage
    // matches the CPU path that took the same rasterizer. Call before the first
    // renderGrid (the atlas is created lazily there); the caller owns the
    // rasterizer and must outlive the renderer. Without it, the atlas defaults to
    // its own UnifontRasterizer.
    void setGlyphRasterizer(Rendering::GlyphRasterizer& rasterizer) { m_injectedRasterizer = &rasterizer; }

    /// Injects the face the ligature strip sheet shapes runs through.
    ///
    /// Separate from ``setGlyphRasterizer`` so one face can be rendered both with
    /// shaping and without it. The ligature smoke needs exactly that pair: two
    /// arms over the same face whose only difference is the substitution, so the
    /// image between them is the ligature and nothing else.
    ///
    /// Shaping itself is a capability of the rasterizer — ``hasLigatureShaping``,
    /// ``shapeTextRun`` and ``rasteriseShapedRun`` on the Core seam — so this
    /// handle chooses whether a strip sheet is built, not what is able to shape.
    /// Folding it into ``setGlyphRasterizer`` makes shaping a property of the
    /// face alone, which leaves that pair no way to ask for the unligatured
    /// picture; a replacement for the control arm comes first.
    ///
    /// Call before the first `renderGrid`, which is where the sheet is built;
    /// the caller owns the face and must outlive the renderer.
    ///
    /// Left uncalled, no strip sheet exists and rows render unligatured — the
    /// same picture a font with no ligature features gives, which is why it is
    /// a safe default rather than a broken one.
    ///
    /// - Parameter rasterizer: The face to shape and rasterise strips with. One
    ///   that loaded no shaper leaves the sheet unusable, and the hook is not
    ///   published at all rather than published over a sheet with nothing to
    ///   give.
    void setLigatureRasterizer(Rendering::GlyphRasterizer& rasterizer) { m_ligatureRasterizer = &rasterizer; }

    [[nodiscard]] std::string diagnoseFontRoutes(std::string_view utf8Text) const;

    // Render a `width`x`height` image cleared to (r,g,b,1) and copy it out as
    // tightly-packed RGBA8 (row stride == width*4). False on any failure.
    bool renderClear(uint32_t width, uint32_t height, float red, float green, float blue, std::vector<uint8_t>& outRGBA);

    /// GPU grid renderer: snapshots the visible grid, builds the portable
    /// cell + decoration instances exactly as SoftwareRenderer::render,
    /// uploads the atlas, draws, and copies out tightly-packed RGBA8. Shares
    /// the CPU path's selectionRowSpans / fillCursorState helpers so both
    /// stay byte-identical (the oracle).
    ///
    /// - Parameters:
    ///   - rasterContext: This window's capture and style state, shared with its CPU path.
    ///   - term: The terminal to draw; null fails.
    ///   - outRGBA: Receives the pixels, widthOut × heightOut × 4 bytes.
    ///   - widthOut: Set to columns × cellWidth.
    ///   - heightOut: Set to rows × cellHeight.
    ///   - viewOffset: The scrollback window (0 = live tail); when > 0 the
    ///     cursor is suppressed.
    ///   - selection: The pane's selection session driving the overlay;
    ///     nullable.
    ///   - cursor: The resolved cursor look; null draws a static focused
    ///     block.
    ///   - blinkTicks: The SGR 5/6 blink tick, resolved once per frame and
    ///     passed to both paths; 0 holds blink text fully opaque.
    /// - Returns: Whether a frame was produced. A grid larger than the device's
    ///   largest frame produces none and says so in
    ///   ``didDeclineOversizedGrid``, without calling `handoff`.
    ///   - handoff: Called once the frame has read its last Terminal field,
    ///     before any GPU work, so a caller holding the model lock for the
    ///     capture can release it while the frame is drawn and read back;
    ///     an empty handoff is never called.
    bool renderGrid(RasterContext& rasterContext, Ubiquitty::Terminal* term, std::vector<uint8_t>& outRGBA, int& widthOut, int& heightOut, int viewOffset = 0, Ubiquitty::Selection::Session* selection = nullptr, const CursorOverlay* cursor = nullptr, uint32_t blinkTicks = 0, ModelCaptureHandoff handoff = {});

    // Drop the GPU glyph atlas so the next renderGrid rebuilds it from the
    // currently-injected rasterizer. Idles the device first; cell dims + target
    // size are re-derived on the rebuild.
    void rebuildAtlas();

    // How many frames Loaded the retained grid target instead of rebuilding
    // it. The multi-frame smoke reads this as its coverage bound: byte
    // equality against the CPU arm cannot distinguish a working partial path
    // from a verdict that quietly rebuilds every frame in full, and a smoke
    // blind to that difference is a copy test that cannot fail.
    [[nodiscard]] std::uint64_t partialFrameCount() const { return m_partialFrameCount; }

    /// The cells a proportional run needs in the strip sheet's proportional
    /// face (Docs/proportional-text.md), for the measurer a pane's session
    /// installs; zero before the sheet is cut or when it has no such face,
    /// How long the last frame blocked on the queue, in seconds.
    ///
    /// The pipeline submits and waits, so this is the whole GPU render as the
    /// CPU experiences it: nothing overlaps it.
    [[nodiscard]] double lastFrameWaitSeconds() const { return m_lastFrameWaitSeconds; }

    /// How long the last frame took to copy out of the staging buffer.
    ///
    /// The host half of the round trip. A presentation path that handed the
    /// image to the compositor directly would not pay it.
    [[nodiscard]] double lastFrameReadbackSeconds() const { return m_lastFrameReadbackSeconds; }

    /// Whether the last ``renderGrid`` declined its grid as larger than any
    /// frame this device can draw, rather than failing.
    ///
    /// The frame is the model's grid at this renderer's cell, and the model's
    /// grid is not the window's: a program's page length (DECSLPP, DECSNLS), a
    /// remote owner's geometry or a large font makes it wider or taller than
    /// the largest image the device makes, and creating one is invalid usage a
    /// driver need not report. Nothing about the renderer is wrong when this
    /// holds: the caller draws that frame another way, and the next grid that
    /// fits is drawn here.
    [[nodiscard]] bool didDeclineOversizedGrid() const { return m_didDeclineOversizedGrid; }

    /// The largest frame this device can draw, in device pixels; empty before
    /// ``init`` has found a device.
    [[nodiscard]] ImageExtent maxTargetExtent() const { return m_maxTargetExtent; }

    /// A rendered frame left in exportable GPU memory for the compositor.
    ///
    /// The frame is complete when this is handed out (the render waits on
    /// its queue), so a consumer reads it without a fence. The descriptor is
    /// the receiver's to close; the slot stays reserved until
    /// ``releaseExportedFrame`` hands back its token.
    struct ExportedFrame {
        /// A dma-buf descriptor over the frame's memory, owned by the receiver.
        int fileDescriptor = -1;
        /// The frame's width in pixels.
        uint32_t width = 0;
        /// The frame's height in pixels.
        uint32_t height = 0;
        /// Bytes from one row to the next.
        uint32_t stride = 0;
        /// Bytes from the start of the memory to the first pixel.
        uint32_t offset = 0;
        /// The token ``releaseExportedFrame`` takes back.
        uint64_t releaseToken = 0;
    };

    /// Whether the device can hand frames to the compositor as dma-bufs.
    ///
    /// - Returns: True when external-memory export is available and has not
    ///   been refused.
    [[nodiscard]] bool canExportFrames() const { return m_canExportFrames; }

    /// Asks the next ``renderGrid`` to leave its frame in an exportable
    /// image instead of copying it to the host; the request is consumed by
    /// that frame. A frame that cannot export (no free slot, a failed
    /// export) reads back as usual and ``takeExportedFrame`` answers empty.
    void requestFrameExport() { m_isExportRequested = true; }

    /// Switches dma-buf export off for the rest of the run, after the
    /// toolkit refused an import; frames read back from then on.
    void disableFrameExport() { m_canExportFrames = false; }

    /// Selects the importability probe for newly allocated export buffers.
    ///
    /// The default probe requires a CPU-readable mapping: GTK may select a
    /// software importer after accepting a dma-buf's format. Called before the
    /// first export; the callback borrows the descriptor and must not retain it.
    /// A refusal disables export and the current frame reads back instead.
    ///
    /// - Parameters:
    ///   - canImport: The consumer's probe, or null for the default probe.
    ///   - context: Borrowed until the renderer is shut down.
    void setFrameImportProbe(bool (*canImport)(void*, int, std::size_t), void* context)
    {
        m_canImportFrame = canImport;
        m_frameImportContext = context;
    }

    /// The frame the last ``renderGrid`` exported, once.
    ///
    /// - Returns: The exported frame, or nothing when it read back instead.
    [[nodiscard]] std::optional<ExportedFrame> takeExportedFrame() { return std::exchange(m_exportedFrame, std::nullopt); }

    /// The column under a pixel along a row of the last GPU frame: the letter
    /// there where the primary face laid the row out as proportional runs
    /// (LetterLayout.h), else the column at the pitch.
    ///
    /// - Parameters:
    ///   - row: The visible row.
    ///   - xInPixels: The pixel, from the grid's left edge.
    /// - Returns: The column, clamped to the frame.
    [[nodiscard]] int columnAt(int row, double xInPixels) const;

    /// Where a pixel is along such a row, in cells, for ``PointerFact::xInCells``.
    ///
    /// - Parameters:
    ///   - row: The visible row.
    ///   - xInPixels: The pixel, from the grid's left edge.
    /// - Returns: The position, 0 through the column count.
    [[nodiscard]] double xInCellsAt(int row, double xInPixels) const;

    /// Returns an exported frame's slot to the ring, from any thread.
    ///
    /// A token from before the slots were rebuilt is ignored, so a texture
    /// released after a resize cannot free a slot of the new size.
    ///
    /// - Parameter token: The ``ExportedFrame::releaseToken``.
    void releaseExportedFrame(uint64_t token);

    /// which Core answers with the grid-face width.
    ///
    /// Called on the reader thread under the model lock while this renderer
    /// may be drawing: the sheet shapes through the rasterizer alone, and the
    /// rasterizer guards its proportional faces.
    ///
    /// - Parameters:
    ///   - codePoints: The run's text.
    ///   - style: The face the run is set in; the weight is the face's own.
    ///   - glyphsOut: Receives the shaped glyphs.
    /// - Returns: How many were written, or zero.
    [[nodiscard]] int shapeProportionalRun(std::span<const std::uint32_t> codePoints, Ubiquitty::ProportionalRunStyle style, std::span<Ubiquitty::ProportionalShapedGlyph> glyphsOut) const
    {
        if (!m_proportionalStripSheet || m_cellWidth <= 0)
            return 0;
        return m_proportionalStripSheet->shapeProportionalRun(codePoints, static_cast<Rendering::FontFace>(style.faceBits), glyphsOut);
    }
    /// One cell's advance in the sheet's pixels, for the measurer seam.
    /// Whether the focused search match's pill is mid-bounce on the last
    /// frame, so the window keeps painting until the curve rests.
    [[nodiscard]] bool isFocusedMatchBouncing() const { return m_focusedMatchAgeSeconds >= 0.0f && m_focusedMatchAgeSeconds < Rendering::focusedPillBounceSeconds; }
    [[nodiscard]] float proportionalCellAdvanceInPixels() const { return static_cast<float>(m_cellWidth); }

    /// How many ligature strip slices the last grid frame drew.
    ///
    /// Zero on a host with no shaping face, and zero for a frame whose text
    /// holds no run — so a test reads it as "did this frame take the strip
    /// path", which pixels alone cannot answer: a run that ligates nothing
    /// rasterises the same either way, and a strip pass doing nothing is
    /// invisible in a comparison that only checks the picture.
    ///
    /// - Returns: The instance count of the last frame's ligature draw.
    [[nodiscard]] std::uint32_t lastFrameLigatureInstanceCount() const { return m_lastFrameLigatureInstances; }

    /// How many dedicated proportional glyph instances the last frame drew.
    [[nodiscard]] std::uint32_t lastFrameProportionalInstanceCount() const { return m_lastFrameProportionalInstances; }
    /// How many bounded proportional strip tiles the last frame drew.
    [[nodiscard]] std::uint32_t lastFrameProportionalStripInstanceCount() const { return m_lastFrameProportionalStripInstances; }
    /// Counts the last frame's proportional glyphs and strips whose quad is wider than the atlas rect it samples.
    ///
    /// A smoke comparing the glyph stage's spread of a rect across a wider quad against the software renderer
    /// reads this to know the frame held such a quad: with none, the two agree whatever the stage does.
    ///
    /// - Returns: The number of stretched instances in the two proportional streams.
    [[nodiscard]] std::uint32_t lastFrameStretchedProportionalInstanceCount() const;
    /// Counts mono glyph quads whose dimensions differ from their full atlas rect.
    ///
    /// A script-glyph smoke uses the count to require the scaled path for a
    /// native face and the unchanged raster geometry for a bitmap face.
    [[nodiscard]] std::uint32_t lastFrameScaledGlyphInstanceCount() const;

private:
    bool ensureTarget(uint32_t width, uint32_t height);
    void destroyTarget();
    /// Builds the exportable presentation images at the target's size.
    ///
    /// - Parameters:
    ///   - width: The target's width in pixels.
    ///   - height: The target's height in pixels.
    /// - Returns: Whether every slot was built and exported.
    bool ensureExportSlots(uint32_t width, uint32_t height);
    /// Destroys the presentation images and voids every outstanding release token.
    void destroyExportSlots();
    /// Copies a completed target through its persistent host mapping.
    /// - Parameter output: Receives the target's RGBA pixels.
    /// - Returns: Whether the mapped memory was made visible and copied.
    bool readTarget(std::vector<uint8_t>& output);
    [[nodiscard]] uint32_t findMemoryType(uint32_t typeBits, VkMemoryPropertyFlags want) const;

    // GPU grid pipeline objects (render pass, two pipelines, the
    // descriptor set bound to the atlas, the host-visible instance buffers).
    bool ensureGridPipelines();
    void destroyGridPipelines();
    bool ensureGridTarget(uint32_t width, uint32_t height); // image view + framebuffer
    void destroyGridTarget();
    /// Builds the retained image pair the partial path renders through.
    ///
    /// Created lazily on the first frame whose snapshot retains its cells; a
    /// fresh-path frame renders into m_image directly and never touches the
    /// pair. A size change recreates both images and drops
    /// m_hasRetainedTarget, so the next frame rebuilds in full.
    ///
    /// - Parameters:
    ///   - width: The grid target width in pixels.
    ///   - height: The grid target height in pixels.
    /// - Returns: False when an image, its memory, view or framebuffer could
    ///   not be created.
    bool ensureRetainedGridImages(uint32_t width, uint32_t height);
    /// Destroys the retained image pair and forgets its contents.
    void destroyRetainedGridImages();
    /// Grows the per-stream instance buffers to hold at least these counts.
    ///
    /// Every stream is reallocated together when any one outgrows its buffer:
    /// they share a lifetime and a frame, so tracking them separately would buy
    /// a set of capacities to keep in step for an allocation that happens on a
    /// resize.
    ///
    /// - Parameters:
    ///   - cellCount: Cell backgrounds, one per cell.
    ///   - glyphCount: Subpixel overflow glyphs.
    ///   - decorationCount: Underlines, strikes and the other rules.
    ///   - overlayCount: The cursor and the selection quads.
    ///   - colorCount: Colour emoji; zero when no colour face is installed.
    ///   - ligatureCount: Ligature strip slices; zero when nothing shapes them.
    ///   - wideCount: Two-cell glyphs that leave their cells, which are the
    ///     ones a fractional block draws smaller.
    ///   - boxFillCount: Box-drawing, block, shade and braille quads.
    /// - Returns: False when a buffer could not be created or bound.
    bool ensureInstanceBuffers(std::size_t cellCount, std::size_t glyphCount,
        std::size_t proportionalCount, std::size_t proportionalStripCount, std::size_t decorationCount,
        std::size_t overlayCount, std::size_t colorCount,
        std::size_t ligatureCount, std::size_t wideCount, std::size_t boxFillCount);
    void destroyInstanceBuffers();
    VkShaderModule loadShader(const char* spvFileName) const;

    // Inline-image pass: a second render pass that reads the grid result (color
    // attachment as input attachment) and over-blends each resolved image quad,
    // byte-for-byte matching SoftwareRenderer::compositeImages. Built lazily.
    bool ensureImagePipeline();
    void destroyImagePipeline();
    bool ensureImageInstanceBuffer(std::size_t instanceCount);
    void destroyImageInstanceBuffer();

    // Overlay (cursor + translucent selection) pass: runs in the same
    // input-attachment render pass as the image pass, so the over-blend is
    // computed in the integer domain against the grid result (subpassLoad) —
    // byte-for-byte matching the CPU path for translucent alpha, where
    // fixed-function hardware blend would round differently. Built lazily; depends
    // on ensureImagePipeline().
    bool ensureOverlayPipeline();
    void destroyOverlayPipeline();

    // Background-image pass: one quad, drawn in the input-attachment render
    // pass after the cursor tier and before the overlays, compositing the
    // window's image beneath the frame exactly as
    // Rendering::compositeBackgroundImage does on the CPU. Built lazily;
    // depends on ensureImagePipeline().
    /// Builds the background-image pipeline and its transfer-table buffer
    /// once.
    ///
    /// - Returns: `false` on any Vulkan failure.
    bool ensureBackdropPipeline();
    /// Releases what ``ensureBackdropPipeline`` built.
    void destroyBackdropPipeline();

    VkInstance m_instance = VK_NULL_HANDLE;
    VkPhysicalDevice m_physical = VK_NULL_HANDLE;
    VkDevice m_device = VK_NULL_HANDLE;
    VkQueue m_queue = VK_NULL_HANDLE;
    uint32_t m_queueFamily = 0;
    VkCommandPool m_commandPool = VK_NULL_HANDLE;
    VkCommandBuffer m_commandBuffer = VK_NULL_HANDLE;

    uint32_t m_width = 0, m_height = 0;
    VkImage m_image = VK_NULL_HANDLE;
    VkDeviceMemory m_imageMemory = VK_NULL_HANDLE;
    VkBuffer m_staging = VK_NULL_HANDLE;
    VkDeviceMemory m_stagingMemory = VK_NULL_HANDLE;
    VkDeviceSize m_stagingSize = 0;
    void* m_stagingMapped = nullptr;

    // Grid renderer state.
    VkRenderPass m_renderPass = VK_NULL_HANDLE;
    VkDescriptorSetLayout m_descriptorSetLayout = VK_NULL_HANDLE;
    VkPipelineLayout m_pipelineLayout = VK_NULL_HANDLE;
    VkPipeline m_cellPipeline = VK_NULL_HANDLE;
    VkPipeline m_glyphPipeline = VK_NULL_HANDLE; // subpixel overflow glyph pass
    // A frame with a picture under its text paints the cells in two halves
    // around it, the ground and then the ink, and blends every glyph stream's
    // ink over the picture rather than over the cell background it covers.
    VkPipeline m_cellGroundPipeline = VK_NULL_HANDLE;
    VkPipeline m_cellInkPipeline = VK_NULL_HANDLE;
    VkPipeline m_glyphOverTargetPipeline = VK_NULL_HANDLE;
    VkPipeline m_decorationPipeline = VK_NULL_HANDLE;
    // The emoji pass. Same layout and same instance stream as the glyph pass;
    // it differs in its shaders and in blending against the framebuffer.
    VkPipeline m_colorPipeline = VK_NULL_HANDLE;
    // Core's box-fill stream (BoxFillEmit and the braille lattice), drawn over
    // the cell backgrounds the way every other arm draws it.
    VkPipeline m_boxFillPipeline = VK_NULL_HANDLE;
    VkDescriptorPool m_descriptorPool = VK_NULL_HANDLE;
    VkDescriptorSet m_descriptorSet = VK_NULL_HANDLE;
    VkDescriptorSet m_proportionalDescriptorSet = VK_NULL_HANDLE;
    VkDescriptorSet m_proportionalStripDescriptorSet = VK_NULL_HANDLE;
    bool m_descriptorWritten = false;
    bool m_isProportionalDescriptorWritten = false;
    bool m_isProportionalStripDescriptorWritten = false;

    VkImageView m_colorView = VK_NULL_HANDLE; // view of m_image as a color attachment
    VkFramebuffer m_framebuffer = VK_NULL_HANDLE;
    uint32_t m_framebufferWidth = 0, m_framebufferHeight = 0;

    // Each instance stream is mapped once, when its buffer is created, and stays
    // mapped for the buffer's life. The memory is HOST_VISIBLE|HOST_COHERENT and
    // persistent mapping of it is explicitly legal; a frame writes through the
    // pointer and needs no flush.
    //
    // The alternative was six vkMapMemory/vkUnmapMemory pairs inside the frame,
    // each with its own unwind of the maps before it — six calls and about sixty
    // lines of ladder, per frame, to obtain pointers that never move.
    //
    // A mapped pointer is valid only while its buffer is: every one is cleared
    // in destroyInstanceBuffers, beside the free that invalidates it.
    VkBuffer m_cellBuffer = VK_NULL_HANDLE;
    VkDeviceMemory m_cellBufferMemory = VK_NULL_HANDLE;
    void* m_cellMapped = nullptr;
    std::size_t m_cellCapacity = 0; // CellInstance slots
    VkBuffer m_glyphBuffer = VK_NULL_HANDLE;
    VkDeviceMemory m_glyphBufferMemory = VK_NULL_HANDLE;
    void* m_glyphMapped = nullptr;
    std::size_t m_glyphCapacity = 0; // GlyphInstance slots (subpixel overflow pass)
    std::uint32_t m_lastFrameGlyphInstances = 0;
    VkBuffer m_proportionalBuffer = VK_NULL_HANDLE;
    VkDeviceMemory m_proportionalBufferMemory = VK_NULL_HANDLE;
    void* m_proportionalMapped = nullptr;
    std::size_t m_proportionalCapacity = 0;
    VkBuffer m_proportionalStripBuffer = VK_NULL_HANDLE;
    VkDeviceMemory m_proportionalStripBufferMemory = VK_NULL_HANDLE;
    void* m_proportionalStripMapped = nullptr;
    std::size_t m_proportionalStripCapacity = 0;
    VkBuffer m_decorationBuffer = VK_NULL_HANDLE;
    VkDeviceMemory m_decorationBufferMemory = VK_NULL_HANDLE;
    void* m_decorationMapped = nullptr;
    std::size_t m_decorationCapacity = 0; // DecorationInstance slots
    VkBuffer m_colorBuffer = VK_NULL_HANDLE;
    VkDeviceMemory m_colorBufferMemory = VK_NULL_HANDLE;
    void* m_colorMapped = nullptr;
    std::size_t m_colorCapacity = 0;
    VkBuffer m_overlayBuffer = VK_NULL_HANDLE;
    VkDeviceMemory m_overlayBufferMemory = VK_NULL_HANDLE;
    void* m_overlayMapped = nullptr;
    std::size_t m_overlayCapacity = 0; // OverlayInstance slots
    VkBuffer m_boxFillBuffer = VK_NULL_HANDLE;
    VkDeviceMemory m_boxFillBufferMemory = VK_NULL_HANDLE;
    void* m_boxFillMapped = nullptr;
    std::size_t m_boxFillCapacity = 0; // OverlayInstance slots of the box-fill stream

    // Inline-image pass state. The image render pass loads the grid result and
    // binds the color attachment as input attachment 0 (the background read);
    // set 0 = the per-image source texture (from m_imageTextures), set 1 = the
    // input-attachment background. m_imagePipeline alpha-composites each quad.
    VkRenderPass m_imageRenderPass = VK_NULL_HANDLE;
    VkDescriptorSetLayout m_imageSamplerSetLayout = VK_NULL_HANDLE; // set 0 (source image)
    VkDescriptorSetLayout m_imageBackgroundSetLayout = VK_NULL_HANDLE; // set 1 (input attachment)
    VkPipelineLayout m_imagePipelineLayout = VK_NULL_HANDLE;
    VkPipeline m_imagePipeline = VK_NULL_HANDLE;
    VkDescriptorPool m_imageBackgroundPool = VK_NULL_HANDLE;
    VkDescriptorSet m_imageBackgroundSet = VK_NULL_HANDLE;
    bool m_imageBackgroundWritten = false;
    VkBuffer m_imageInstanceBuffer = VK_NULL_HANDLE;
    VkDeviceMemory m_imageInstanceBufferMemory = VK_NULL_HANDLE;
    std::size_t m_imageInstanceCapacity = 0; // ImageInstance slots
    VulkanImageTextures m_imageTextures;
    bool m_imageTexturesCreated = false;

    // Overlay pass (cursor + translucent selection), drawn in m_imageRenderPass
    // with the grid result bound as input attachment 0 (set 0) so the shader
    // over-blends in the integer domain. The instance buffer is m_overlayBuffer
    // (the portable OverlayInstance), shared with buildCellInstances.
    VkPipelineLayout m_overlayBlendPipelineLayout = VK_NULL_HANDLE;
    VkPipeline m_overlayBlendPipeline = VK_NULL_HANDLE;

    // Background-image pass state: set 2 is Core's sRGB transfer tables, in a
    // buffer written once, beside set 0 (the image's texture, held by
    // m_imageTextures) and set 1 (the frame under it).
    VkDescriptorSetLayout m_backdropTransferSetLayout = VK_NULL_HANDLE;
    VkDescriptorPool m_backdropTransferPool = VK_NULL_HANDLE;
    VkDescriptorSet m_backdropTransferSet = VK_NULL_HANDLE;
    VkBuffer m_backdropTransferBuffer = VK_NULL_HANDLE;
    VkDeviceMemory m_backdropTransferMemory = VK_NULL_HANDLE;
    VkPipelineLayout m_backdropPipelineLayout = VK_NULL_HANDLE;
    VkPipeline m_backdropPipeline = VK_NULL_HANDLE;

    // The atlas is constructed lazily (first renderGrid) so an injected rasterizer
    // can be passed into it; without one it uses its own UnifontRasterizer. The
    // cell is DERIVED from the rasterizer's cellMetrics() (matching the CPU path),
    // else Unifont 8×16. m_cellWidth/m_cellHeight are filled from the atlas once
    // constructed and drive the image size, metrics, push consts.
    Rendering::GlyphRasterizer* m_injectedRasterizer = nullptr;
    // How many overlay quads each instanced draw covers, in draw order. Built
    // while the instance buffer is mapped, because the quads' rects are what
    // decides it and the buffer is unmapped before the pass records.
    std::vector<std::size_t> m_overlayRunLengths;

    // Whether the readback staging memory is coherent. A cached type that is
    // not coherent holds stale lines until the range is invalidated, and the
    // frame then read back is whatever the CPU last had rather than what the
    // GPU just drew.
    bool m_isStagingCoherent = true;

    // Where the last frame's wall clock went, for the perf log. Split because
    // the two halves answer different questions: the wait is how long the CPU
    // stood still for the GPU, and the readback is the host round trip a direct
    // presentation would remove.
    double m_lastFrameWaitSeconds = 0.0;
    // dma-buf presentation: a ring of linear, exportable images the frame is
    // copied into on the GPU, so the host never reads it back. Three cover
    // the one on screen, the one being drawn and one the compositor holds a
    // moment longer. A slot is reserved from export until GTK releases the
    // texture over it, possibly off this thread.
    /// One exportable presentation image and what an importer needs of it.
    struct ExportSlot {
        /// The linear image the frame is copied into.
        VkImage image = VK_NULL_HANDLE;
        /// Its dedicated, exportable memory.
        VkDeviceMemory memory = VK_NULL_HANDLE;
        /// The dma-buf over the memory; each handoff is a dup of it.
        int fileDescriptor = -1;
        /// Bytes from one row to the next.
        uint32_t stride = 0;
        /// Bytes from the memory's start to the first pixel.
        uint32_t offset = 0;
    };
    static constexpr std::size_t exportSlotCount = 3;
    std::array<ExportSlot, exportSlotCount> m_exportSlots {};
    std::array<std::atomic<bool>, exportSlotCount> m_isExportSlotHeld {};
    std::atomic<uint32_t> m_exportGeneration { 1 };
    uint32_t m_exportWidth = 0;
    uint32_t m_exportHeight = 0;
    bool m_canExportFrames = false;
    bool m_isExportRequested = false;
    bool (*m_canImportFrame)(void*, int, std::size_t) = nullptr;
    void* m_frameImportContext = nullptr;
    // Whether a full ring has been reported, so the log says it once.
    bool m_hasReportedFullExportRing = false;
    std::optional<ExportedFrame> m_exportedFrame;
    PFN_vkGetMemoryFdKHR m_getMemoryFileDescriptor = nullptr;
    double m_lastFrameReadbackSeconds = 0.0;

    // The largest frame the target, its retained pair and the grid target may
    // be. Every one of them is sized from the model's grid, which a program
    // can grow past the window, so the bound is checked before any is made.
    ImageExtent m_maxTargetExtent;
    bool m_didDeclineOversizedGrid = false;
    // The frame last declined, so a grid that stays too large is reported once.
    ImageExtent m_lastDeclinedExtent;

    std::optional<VulkanGlyphAtlas> m_atlas;
    // The colour sheet bound at descriptor 1. Constructed beside the mono atlas
    // whether or not a colour face exists, because the binding is in every set
    // and a descriptor a shader could sample must point at a real image.
    std::optional<VulkanColorGlyphAtlas> m_colorAtlas;
    bool m_atlasCreated = false;

    // Core owns the proportional glyph cache and its host mirror. This image is
    // only the Vulkan storage for that sheet.
    std::optional<Rendering::ProportionalGlyphSheet> m_proportionalSheet;
    VulkanCoverageSheet m_proportionalImage;
    std::uint32_t m_lastFrameProportionalInstances = 0;

    // The bounded proportional-run fallback is a separate strip sheet. It
    // shares no slots, image, descriptor, or instance stream with ligatures.
    std::optional<Rendering::LigatureSheet> m_proportionalStripSheet;
    VulkanCoverageSheet m_proportionalStripImage;
    std::uint32_t m_lastFrameProportionalStripInstances = 0;

    // The ligature strip sheet and the device image it uploads through. Built
    // only when a shaping rasterizer was injected, so a run of `!=` renders as
    // two glyphs rather than as nothing on a host that cannot shape it.
    //
    // Two objects for one sheet, unlike the mono atlas, which holds its own: the
    // strip sheet is a portable host-side shaper with no Vulkan in it, and
    // keeping the image out here is what lets the same sheet serve a second
    // backend without carrying a device it has no use for.
    Rendering::GlyphRasterizer* m_ligatureRasterizer = nullptr;
    std::optional<Rendering::LigatureSheet> m_ligatureSheet;
    VulkanCoverageSheet m_ligatureImage;
    // A second set over one layout, differing only in what binding 0 points at.
    // This is how the ligature strips reach the mono glyph pipeline: macOS draws
    // them with that pipeline over a rebound texture, and a descriptor set is
    // where Vulkan keeps a texture binding. A shader variant would have been a
    // second copy of the coverage formula the CPU oracle pins.
    VkDescriptorSet m_ligatureDescriptorSet = VK_NULL_HANDLE;
    bool m_isLigatureDescriptorWritten = false;
    VkBuffer m_ligatureBuffer = VK_NULL_HANDLE;
    VkDeviceMemory m_ligatureBufferMemory = VK_NULL_HANDLE;
    void* m_ligatureMapped = nullptr;
    std::size_t m_ligatureCapacity = 0;
    std::uint32_t m_lastFrameLigatureInstances = 0;
    // The wide stream, drawn on the mono pipeline over the same sheet: this
    // atlas holds wide slots beside the mono ones, so the stream needs no
    // texture of its own. It carries what SoftwareRenderer's wide stream
    // carries — two-cell glyphs a fractional block draws smaller — with the
    // wide-slot geometry left at zero on both arms, so every other two-cell
    // glyph stays on its cells.
    VkBuffer m_wideBuffer = VK_NULL_HANDLE;
    VkDeviceMemory m_wideBufferMemory = VK_NULL_HANDLE;
    void* m_wideMapped = nullptr;
    std::size_t m_wideCapacity = 0;

    // The retained CPU snapshot: Core's drain says which rows changed and
    // refreshCapturedRows re-reads only those, so a steady frame stops paying a
    // full row sweep. The baseline is what the next drain proves itself
    // against; a frame the fresh snapshot would composite over (pre-edit, Beam
    // palette) or shape (RTL/cursive rows) bypasses all of it, because those
    // transforms never belong in the retained copy — it must equal the fresh
    // read byte for byte.
    std::vector<Ubiquitty::Cell> m_retainedCells;
    std::vector<std::uint8_t> m_retainedLineAttributes;
    std::vector<std::uint8_t> m_retainedRowMarks;
    std::vector<std::uint8_t> m_rowDirty;
    // The last frame's letters by row and column, and which rows hold them
    // (LetterLayout.h): the builder writes them, the pointer reads them.
    std::vector<Rendering::LetterExtent> m_letters;
    std::vector<std::uint8_t> m_letterRows;
    int m_letterColumns = 0;
    [[nodiscard]] std::span<const Rendering::LetterExtent> rowLetters(int row) const;
    // Read and advanced by Core's planRetainedFrame; this side only stores it.
    Ubiquitty::Rendering::RetainedFrameBaseline m_retainedBaseline;
    // Where this frame's build carried ink across a row edge, and where the
    // pair's ink does, as the last frame that built every row into it drew
    // it. One byte per row boundary (CellInstanceBuilder.h rowInkCrossings).
    std::vector<std::uint8_t> m_rowInkCrossings;
    std::vector<std::uint8_t> m_targetRowInkCrossings;
    // The selection the pair holds behind its text, for the next frame's marks.
    Ubiquitty::Rendering::BakedSelection m_bakedSelection;

    // The retained grid target: a texture pair holding the GRID passes only —
    // no overlays, no images — in the state the CPU baseline describes. A
    // partial frame Loads the front image and repaints only the dirty rows; a
    // pending scroll copies Core's blit bands front to back and the pair
    // swaps. The composited m_image is rebuilt every frame by one full-image
    // copy, which is what lets the cursor and the selection move without
    // dirtying a row. The overlay chrome a fresh-path frame composites into
    // its cells must never enter this pair: those frames draw into m_image
    // directly, and the pair heals afterwards because the skipped drains
    // arrive at the next one as dirty rows.
    VkRenderPass m_gridLoadRenderPass = VK_NULL_HANDLE; // LOAD twin of m_renderPass
    VkImage m_gridImages[2] = { VK_NULL_HANDLE, VK_NULL_HANDLE };
    VkDeviceMemory m_gridImageMemory[2] = { VK_NULL_HANDLE, VK_NULL_HANDLE };
    VkImageView m_gridImageViews[2] = { VK_NULL_HANDLE, VK_NULL_HANDLE };
    VkFramebuffer m_gridFramebuffers[2] = { VK_NULL_HANDLE, VK_NULL_HANDLE };
    uint32_t m_gridImageWidth = 0, m_gridImageHeight = 0;
    int m_gridFrontIndex = 0;
    // Whether the front image holds the pixels the CPU baseline describes.
    // Cleared while a retained frame is in flight and set after its submit
    // completes, so a failed submit forces the next frame to rebuild in full
    // rather than Load a target the pass never finished writing.
    bool m_hasRetainedTarget = false;
    std::uint64_t m_partialFrameCount = 0;
    int m_cellWidth = 0;
    bool m_isBitmapTier = false; // the frame's face is Core's bitmap: pushed to the shaders that quantise coverage
    Rendering::FocusedMatchBounceClock m_focusedMatchBounce; // the focused pill's bounce clock, advanced per frame
    float m_focusedMatchAgeSeconds = -1.0f; // the last frame's reading of that clock
    int m_cellHeight = 0;
};

} // namespace Ubiquitty::Linux
