# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# AppleSharedSwift.cmake — the Swift layer macOS and iOS both compile.
#
# Metal and CoreText over the portable Core: the renderer, the glyph atlas and
# sheets, the font routing, the frame clock and the runtime drive. No AppKit and
# no UIKit — only the shell above it differs, which is the whole shape of these
# frontends.
#
# ONE LIST, read by both arms. Two lists would let the frontends drift into
# rendering through different code, which is the defect this layer exists to
# prevent: a terminal that draws one way on the desktop and another on the phone
# has two renderers to keep bug-for-bug, and the cell-instance stream stops
# being a single answer.
#
# Two lists, because the layer is two modules: the Kit's public API cannot
# name a RenderKit type, so a file in the wrong list fails to compile rather
# than merely sitting in the wrong place.
# UbiquittyKit imports UbiquittyRenderKit *internally*, which is what keeps C++
# out of the Kit's public interface — so a type named in the Kit's public API
# cannot come from the render kit. The platform view aliases are named in that
# API, and therefore belong to the Kit.
#
# Sets UBIQUITTY_APPLE_SHARED_RENDERKIT_SOURCES and
# UBIQUITTY_APPLE_SHARED_KIT_SOURCES, repo-relative.
#

set(UBIQUITTY_APPLE_SHARED_RENDERKIT_SOURCES
    Source/UbiquittyRenderKit/AtlasUploads.swift
    Source/UbiquittyRenderKit/ColorSheet.swift
    Source/UbiquittyRenderKit/CoverageSheet.swift
    Source/UbiquittyRenderKit/CursorAnimator.swift
    Source/UbiquittyRenderKit/DisplayLinkDrive.swift
    Source/UbiquittyRenderKit/FontCatalogue.swift
    Source/UbiquittyRenderKit/FontFaces.swift
    Source/UbiquittyRenderKit/FontGeometry.swift
    Source/UbiquittyRenderKit/BoxFaceLadder.swift
    Source/UbiquittyRenderKit/FontRouter.swift
    Source/UbiquittyRenderKit/FrameClock.swift
    Source/UbiquittyRenderKit/FrameClockSmoke.swift
    Source/UbiquittyRenderKit/PresentSlipAccounting.swift
    Source/UbiquittyRenderKit/PrimaryRunShaper.swift
    Source/UbiquittyRenderKit/FrameEncoder.swift
    Source/UbiquittyRenderKit/FrameGeometry.swift
    Source/UbiquittyRenderKit/FrameInstances.swift
    Source/UbiquittyRenderKit/GlyphAtlas.swift
    Source/UbiquittyRenderKit/GlyphRasterizer.swift
    Source/UbiquittyRenderKit/GlyphSource.swift
    Source/UbiquittyRenderKit/GrowableBuffer.swift
    Source/UbiquittyRenderKit/IdeographicFace.swift
    Source/UbiquittyRenderKit/LastResort.swift
    Source/UbiquittyRenderKit/LigatureFeatureClassifier.swift
    Source/UbiquittyRenderKit/LigatureSheet.swift
    Source/UbiquittyRenderKit/RichTextFaces.swift
    Source/UbiquittyRenderKit/RichTextFontCatalog.swift
    Source/UbiquittyRenderKit/RichTextGeometry.swift
    Source/UbiquittyRenderKit/RichTextShaper.swift
    Source/UbiquittyRenderKit/RichTextStore.swift
    Source/UbiquittyRenderKit/ShapingCandidateFilter.swift
    Source/UbiquittyRenderKit/ShippedFonts.swift
    Source/UbiquittyRenderKit/ShippedResources.swift
    Source/UbiquittyRenderKit/SizedWindowRaster.swift
    Source/UbiquittyRenderKit/UniformFaceShaper.swift
    Source/UbiquittyRenderKit/MetalPipelines.swift
    Source/UbiquittyRenderKit/MetalSamplers.swift
    Source/UbiquittyRenderKit/MTLDevice+Capabilities.swift
    Source/UbiquittyRenderKit/PassGPUProbe.swift
    Source/UbiquittyRenderKit/PlatformSelection.swift
    Source/UbiquittyRenderKit/Renderer.swift
    Source/UbiquittyRenderKit/BackdropImage.swift
    Source/UbiquittyRenderKit/ChromeTypography.swift
    Source/UbiquittyRenderKit/SurfaceImageStore.swift
    Source/UbiquittyRenderKit/SymbolFallbackPen.swift
    Source/UbiquittyRenderKit/SystemMotionPreference.swift
    Source/UbiquittyRenderKit/TekPass.swift
    Source/UbiquittyRenderKit/TerminalRenderer.swift
    Source/UbiquittyRenderKit/RuntimeDrainBench.swift
    Source/UbiquittyRenderKit/RuntimeDrive.swift
    Source/UbiquittyRenderKit/RuntimeFrameBench.swift
    Source/UbiquittyRenderKit/RuntimeSmoke.swift
    Source/UbiquittyRenderKit/StreamDebugRecorder.swift)

# The Kit's shared half: the types its public API names, which cannot live in a
# module it imports internally.
set(UBIQUITTY_APPLE_SHARED_KIT_SOURCES
    Source/UbiquittyKit/Swift/SealedStore.swift
    Source/UbiquittyKit/Swift/ProtectedFile.swift
    Source/UbiquittyKit/Swift/PlatformView.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Bindings.swift
    Source/UbiquittyKit/Swift/DrawEntrySmoke.swift
    Source/UbiquittyKit/Swift/IOSSurfaceSnapshot.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Thumbnail.swift
    Source/UbiquittyKit/Swift/TerminalSurface+ConsentPrompt.swift
    Source/UbiquittyKit/Swift/SurfaceRenderer.swift
    Source/UbiquittyKit/Swift/SurfaceRenderer+Configuration.swift
    Source/UbiquittyKit/Swift/SurfaceSelectionModel.swift
    Source/UbiquittyKit/Swift/DeliveryBench.swift
    Source/UbiquittyKit/Swift/SurfaceSmoke.swift
    Source/UbiquittyKit/Swift/GridCacheSmoke.swift
    Source/UbiquittyKit/Swift/GridCacheScrollBench.swift
    Source/UbiquittyKit/Swift/ShippedFacesSmoke.swift
    Source/UbiquittyKit/Swift/ShippedFamilyLookupSmoke.swift
    Source/UbiquittyKit/Swift/ProportionalFacesSmoke.swift
    Source/UbiquittyKit/Swift/TouchSmoke.swift
    Source/UbiquittyKit/Swift/RichTextSelectionSmoke.swift
    Source/UbiquittyKit/Swift/AccessibilityValueSmoke.swift
    Source/UbiquittyKit/Swift/SurfaceSnapshot.swift
    Source/UbiquittyKit/Swift/SnapshotRunner.swift
    Source/UbiquittyKit/Swift/SurfaceRenderProfile.swift
    Source/UbiquittyKit/Swift/LinkAccentColor.swift
    Source/UbiquittyKit/Swift/NetworkPathWatch.swift
    Source/UbiquittyKit/Swift/SystemMetalDevice.swift
    Source/UbiquittyKit/Swift/TerminalSurface.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Accessibility.swift
    Source/UbiquittyKit/Swift/TerminalSurface+AppKitEvents.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Clear.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Diagnostics.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Composition.swift
    Source/UbiquittyKit/Swift/TerminalSurface+DisplayPower.swift
    Source/UbiquittyKit/Swift/SurfaceFrameLink.swift
    Source/UbiquittyKit/Swift/TerminalSurface+ContextMenu.swift
    Source/UbiquittyKit/Swift/TerminalSurface+WindowDrag.swift
    Source/UbiquittyKit/Swift/TerminalSurface+EditCommands.swift
    Source/UbiquittyKit/Swift/TerminalSurface+DragAutoScroll.swift
    Source/UbiquittyKit/Swift/TerminalSurface+FileDrop.swift
    Source/UbiquittyKit/Swift/TerminalDragDrop.swift
    Source/UbiquittyKit/Swift/DropFileWorker.swift
    Source/UbiquittyKit/Swift/DropFileReceiver.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Factory.swift
    Source/UbiquittyKit/Swift/TerminalSurface+FontZoom.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Links.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Locator.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Keys.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Input.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Notifications.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Pointer.swift
    Source/UbiquittyKit/Swift/TerminalSurface+PointerFacts.swift
    Source/UbiquittyKit/Swift/TerminalSurface+PointerCursor.swift
    Source/UbiquittyKit/Swift/TerminalSurface+PointerLock.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Scrollback.swift
    Source/UbiquittyKit/Swift/TerminalSurface+ScrollbackAppKit.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Search.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Selection.swift
    Source/UbiquittyKit/Swift/TerminalSurface+SelectionAppKit.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Themes.swift
    Source/UbiquittyKit/Swift/TerminalSurface+Typing.swift
    Source/UbiquittyKit/Swift/TerminalSurface+TextInput.swift
    Source/UbiquittyKit/Swift/TerminalSurface+UIKitEvents.swift
    Source/UbiquittyKit/Swift/TerminalSurface+UIKitPointer.swift
    Source/UbiquittyKit/Swift/TerminalSurface+UIKitSelection.swift)
