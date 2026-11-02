// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import QuartzCore
import UbiquittyKit
import UbiquittyRenderKit

//
// TitlebarTestSupport.swift — what every titlebar scenario needs to find the
// thing it asserts on.
//
// The titlebar identity is drawn into AppKit's own views, so a scenario cannot
// address it by outlet: it finds the strip, the title field, the identity
// control and the popover's fields by the same public seams the product uses,
// and synthesizes the crossings AppKit would deliver. Those lookups are shared
// by every file that drives the titlebar — the reveal scenarios and the tag
// editor's — so they live here rather than in whichever file needed them first.
//

/// Brings up a terminal window and waits for its shell to report a directory.
///
/// The directory is what the title's first separator hangs on, and a scenario
/// that counts separators, or reveals the folder the directory names, is
/// asking about a window whose shell has reached its prompt. A fixed pump
/// measured how loaded the machine was rather than whether that had happened:
/// on the test runner, which shares its day with other jobs, the shell had not
/// reported by the time the pump ended, and a scenario that passes on an idle
/// desktop failed there on the count. The wait is for the claim's own
/// precondition; a shell that never reports still times out.
///
/// - Parameter t: the running context.
/// - Returns: the window, or nil when none came up.
@MainActor
func settledWindow(_ t: UBUITestContext) -> NSWindow? {
    guard let controller = t.newWindowRunning(nil), let window = controller.window else { return nil }
    _ = t.wait(until: { controller.beamSurface?.drive.currentDirectory() != nil }, timeout: 8.0)
    // One more turn after the report, so the restyle it triggers has laid out
    // before a scenario measures the field.
    t.pump(0.2)
    return window
}

/// Removes every `[[tags]]` rule titled `name`, as the Tags pane's delete
/// does, by position from the last so earlier positions stay valid.
///
/// - Parameter name: The title of the rules to remove.
@MainActor
func deleteTagRules(named name: String) {
    guard let delegate = SettingsBridge.app else { return }
    let positions = delegate.settingsTags()
        .filter { ($0["name"] as? String) == name }
        .compactMap { $0["index"] as? Int }
    for index in positions.sorted(by: >) {
        delegate.settingsDeleteTag(at: index)
    }
}

@MainActor
func manualTags(of window: NSWindow) -> [String] {
    (window.windowController as? TerminalWindowController)?.manualTags ?? []
}

/// Sets the window's hand-set tag names, as the popover's editor does.
///
/// - Parameters:
///   - names: The names to set.
///   - window: The window to tag.
@MainActor
func setManualTags(_ names: [String], on window: NSWindow) {
    (window.windowController as? TerminalWindowController)?.manualTags = names
}

/// Stamps the window as reached over ssh, the way the Connect paths do.
///
/// - Parameters:
///   - host: The machine the session runs on.
///   - window: The window to stamp.
@MainActor
func markRemoteSSHHost(_ host: String, on window: NSWindow) {
    (window.windowController as? TerminalWindowController)?.remoteHostKey = host
}

/// Dismisses a settings pane's edit sheet with Escape.
///
/// Escape rather than a press: the sheet's Cancel is a SwiftUI button, drawn
/// rather than installed as a control, so no view in the tree can be pressed.
/// It carries the cancel-action shortcut, and going through it is what clears
/// the pane's edit binding — closing the sheet's window leaves the binding set
/// and the next presentation shows nothing. A scenario that raises an editor
/// dismisses it on the way out, which is what makes a file's scenarios
/// independent of the order they run in.
///
/// - Parameter t: The running context, pumped so the dismissal settles.
@MainActor
func dismissEditSheet(_ t: UBUITestContext) {
    let standing = settingsPanelWindow()
    let sheet =
        NSApp.windows.first { $0.isVisible && $0.isSheet }
        ?? NSApp.windows.last { $0.isVisible && $0 !== standing && $0.windowController == nil }
    guard let sheet else { return }
    sendKey(53, characters: "\u{1b}", to: sheet)
    t.pump(0.4)
}

/// The Settings window, when one stands.
@MainActor
func settingsPanelWindow() -> NSWindow? {
    NSApp.windows.first { window in
        window.isVisible && window.windowController is SettingsWindowController
    }
}

/// Opens the title identity's popover the way a click on the title does.
///
/// - Parameters:
///   - strip: The window's titlebar container.
///   - t: The running context.
/// - Returns: Whether the popover came up.
@MainActor
func openIdentityPopover(in strip: NSView, _ t: UBUITestContext) -> Bool {
    guard let control = identityControl(in: strip) else { return false }
    control.sendAction(control.action, to: control.target)
    t.pump(0.3)
    return popoverIsShown()
}

/// Dismisses the identity popover through the controller's own close path.
@MainActor
func closeIdentityPopover(in strip: NSView, _ t: UBUITestContext) {
    let actions = identityControl(in: strip)?.target as? NSObject
    _ = actions?.perform(NSSelectorFromString("closePopover"))
    t.pump(0.3)
}

/// The popover's tag-names field.
@MainActor
func popoverTagsField() -> NSTokenField? {
    popoverView("titlebarDocumentActions.tags") as? NSTokenField
}

/// One palette dot in the popover's tag strip.
///
/// - Parameter name: The colour the dot carries.
/// - Returns: The dot, or nil when the popover is not up.
@MainActor
func popoverTagDot(_ name: String) -> NSView? {
    popoverView("titlebarDocumentActions.tagDot.\(name)")
}

/// Whether a palette dot reports itself set, through the value a screen
/// reader would hear rather than through the controller's private state.
@MainActor
func tagDotIsSet(_ dot: NSView?) -> Bool {
    (dot?.accessibilityValue() as? Int) == 1
}

/// Types tag names into the popover's field and commits them with Return, the
/// keystroke path a user takes.
///
/// - Parameters:
///   - names: The names to leave in the field.
///   - field: The popover's tag field.
///   - t: The running context.
@MainActor
func typeTags(_ names: [String], into field: NSTokenField, _ t: UBUITestContext) {
    field.window?.makeFirstResponder(field)
    field.stringValue = names.joined(separator: ",")
    sendKey(36, characters: "\r", to: field.window)
    t.pump(0.4)
}

/// How many tag chips the title row draws.
///
/// Counted rather than merely detected: a scenario that asks whether a chip
/// exists cannot fail when one name is drawn twice. Each tag the stack drew
/// counts once, and the host chip wearing a tag as its capsule counts as that
/// tag's chip, since the stack leaves the tag out while it does.
///
/// - Parameter field: The window's title field.
/// - Returns: The number of tag chips the row draws.
@MainActor
func titleChipCount(_ field: NSTextField?) -> Int {
    titleMarks(field).count + (hostChip(over: field)?.capsuleFillForTesting == nil ? 0 : 1)
}

/// The host chip standing in a title field's reserved span, nil when none
/// stands.
///
/// - Parameter field: The window's title field.
/// - Returns: The chip.
@MainActor
func hostChip(over field: NSTextField?) -> RemoteConnectionIndicator? {
    field?.subviews.lazy.compactMap { $0 as? RemoteConnectionIndicator }.first { !$0.isHidden && $0.frame.width > 0 }
}

/// The alpha a view paints at one of its points, read off its own drawing
/// over a clear backing: the strength a fill is laid down at, with nothing
/// beneath it to blend with.
///
/// - Parameters:
///   - view: The view.
///   - point: The point, in the view's coordinates.
/// - Returns: The alpha, nil when the view cannot be drawn or the point is
///   outside it.
@MainActor
func drawnAlpha(of view: NSView, at point: NSPoint) -> CGFloat? {
    guard let rep = drawnBitmap(of: view) else { return nil }
    return drawnColor(in: rep, of: view, at: point)?.alphaComponent
}

/// A view's drawing read into a bitmap over a clear backing, each text field
/// in it drawn once, as the window shows it.
///
/// An off-screen capture draws a text field's text twice: once through the
/// field's own cell, and once through the private label view the field shows
/// it with on screen, which the window composites alone. Every glyph and
/// attachment the field holds then lands over itself, and a translucent fill
/// reads stronger in the capture than on screen. The label views' layers are
/// hidden for the capture, which leaves the cell's drawing of the same string,
/// once.
///
/// - Parameter view: The view.
/// - Returns: The bitmap, nil when the view cannot be drawn.
@MainActor
func drawnBitmap(of view: NSView) -> NSBitmapImageRep? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    var hidden: [CALayer] = []
    var pending: [NSView] = [view]
    while let next = pending.popLast() {
        if next.superview is NSTextField, NSStringFromClass(type(of: next)).hasSuffix("NSTextFieldSimpleLabel"),
            let layer = next.layer, !layer.isHidden
        {
            layer.isHidden = true
            hidden.append(layer)
        }
        pending.append(contentsOf: next.subviews)
    }
    defer {
        for layer in hidden {
            layer.isHidden = false
        }
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// The colour a view's bitmap holds at one of the view's points.
///
/// - Parameters:
///   - rep: The bitmap, from `drawnBitmap(of:)` for a view.
///   - view: The view it was drawn from.
///   - point: The point, in the view's coordinates.
/// - Returns: The colour, nil outside the bitmap.
@MainActor
func drawnColor(in rep: NSBitmapImageRep, of view: NSView, at point: NSPoint) -> NSColor? {
    let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
    let x = Int(point.x * scale)
    let y = view.isFlipped ? Int(point.y * scale) : rep.pixelsHigh - 1 - Int(point.y * scale)
    guard x >= 0, x < rep.pixelsWide, y >= 0, y < rep.pixelsHigh else { return nil }
    return pixelColor(in: rep, x: x, y: y)
}

/// An image drawn at twice its size over a clear backing, in sRGB, so a
/// colour drawn into it reads back as the components it was made with.
///
/// - Parameter image: The image, such as a tag pill's.
/// - Returns: The bitmap, nil when the image cannot be drawn.
@MainActor
func drawnBitmap(of image: NSImage) -> NSBitmapImageRep? {
    let scale: CGFloat = 2
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(image.size.width * scale)),
            pixelsHigh: Int(ceil(image.size.height * scale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )?
        .retagging(with: .sRGB), let graphics = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill(using: .copy)
    image.draw(in: NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// A bitmap's pixel as the colour its components are in the bitmap's own
/// colour space.
///
/// `colorAt` names a device bitmap's colours Generic RGB even once the bitmap
/// is retagged sRGB, so a colour read through it and converted to sRGB drifts
/// from the components drawn, the darkest the most: a near-black ink would no
/// longer match itself.
///
/// - Parameters:
///   - rep: The bitmap.
///   - x: The pixel's column.
///   - y: The pixel's row, from the top.
/// - Returns: The colour, nil outside the bitmap.
func pixelColor(in rep: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
    guard let color = rep.colorAt(x: x, y: y), color.numberOfComponents == rep.colorSpace.numberOfColorComponents + 1 else {
        return rep.colorAt(x: x, y: y)
    }
    var components = [CGFloat](repeating: 0, count: color.numberOfComponents)
    color.getComponents(&components)
    return NSColor(colorSpace: rep.colorSpace, components: components, count: components.count)
}

/// The colour an image's bitmap holds at one of the image's points.
///
/// - Parameters:
///   - rep: The bitmap, from `drawnBitmap(of:)` for an image.
///   - size: The image's size, in points.
///   - point: The point, in the image's own unflipped coordinates.
/// - Returns: The colour, nil outside the bitmap.
func drawnColor(in rep: NSBitmapImageRep, size: NSSize, at point: NSPoint) -> NSColor? {
    let scale = CGFloat(rep.pixelsWide) / max(size.width, 1)
    let x = Int(point.x * scale)
    let y = rep.pixelsHigh - 1 - Int(point.y * scale)
    guard x >= 0, x < rep.pixelsWide, y >= 0, y < rep.pixelsHigh else { return nil }
    return pixelColor(in: rep, x: x, y: y)
}

/// The solid pixels a bitmap holds inside a rect of the unflipped drawing it
/// was read from: the ink of a pill whose fill is laid down translucent,
/// which the ink covers opaque.
///
/// - Parameters:
///   - rep: The bitmap.
///   - size: The drawing's size, in points.
///   - rect: The rect, in the drawing's coordinates.
/// - Returns: Each solid pixel's colour, and the height of its bottom edge.
func solidPixels(in rep: NSBitmapImageRep, size: NSSize, rect: NSRect) -> [(bottom: CGFloat, color: NSColor)] {
    let scale = CGFloat(rep.pixelsWide) / max(size.width, 1)
    let rows = max(0, Int(rect.minY * scale))..<min(rep.pixelsHigh, Int(rect.maxY * scale))
    let columns = max(0, Int(rect.minX * scale))..<min(rep.pixelsWide, Int(rect.maxX * scale))
    guard !rows.isEmpty, !columns.isEmpty else { return [] }
    var pixels: [(bottom: CGFloat, color: NSColor)] = []
    for row in rows {
        for column in columns {
            guard let pixel = pixelColor(in: rep, x: column, y: rep.pixelsHigh - 1 - row), pixel.alphaComponent > 0.98 else { continue }
            pixels.append((CGFloat(row) / scale, pixel))
        }
    }
    return pixels
}

/// The solid pixels an image paints inside one of its rects.
///
/// - Parameters:
///   - image: The image.
///   - rect: The rect, in the image's own unflipped coordinates.
/// - Returns: Each solid pixel's colour and the height of its bottom edge;
///   empty when the image cannot be drawn.
@MainActor
func solidPixels(of image: NSImage, in rect: NSRect) -> [(bottom: CGFloat, color: NSColor)] {
    drawnBitmap(of: image).map { solidPixels(in: $0, size: image.size, rect: rect) } ?? []
}

/// The solid pixels an unflipped view paints inside one of its rects, each
/// text field in it drawn once.
///
/// - Parameters:
///   - view: The view.
///   - rect: The rect, in the view's coordinates.
/// - Returns: Each solid pixel's colour and the height of its bottom edge;
///   empty when the view cannot be drawn or is flipped.
@MainActor
func solidPixels(of view: NSView, in rect: NSRect) -> [(bottom: CGFloat, color: NSColor)] {
    guard !view.isFlipped, let rep = drawnBitmap(of: view) else { return [] }
    return solidPixels(in: rep, size: view.bounds.size, rect: rect)
}

/// Whether two colours are the same in sRGB, to within a rounding.
///
/// - Parameters:
///   - a: One colour.
///   - b: The other.
///   - tolerance: How far apart each component may be.
/// - Returns: True when both have an sRGB form and each pair of components is
///   that close.
func isSameSRGBColor(_ a: NSColor?, _ b: NSColor?, tolerance: CGFloat = 0.04) -> Bool {
    guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else { return false }
    return abs(a.redComponent - b.redComponent) < tolerance && abs(a.greenComponent - b.greenComponent) < tolerance
        && abs(a.blueComponent - b.blueComponent) < tolerance
}

/// The alpha an image paints at one of its points, drawn at twice its size
/// over a clear backing.
///
/// - Parameters:
///   - image: The image, such as a tag marker's.
///   - point: The point, in the image's own unflipped coordinates.
/// - Returns: The alpha, nil when the image cannot be drawn or the point is
///   outside it.
@MainActor
func drawnAlpha(of image: NSImage, at point: NSPoint) -> CGFloat? {
    let scale: CGFloat = 2
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(image.size.width * scale)),
            pixelsHigh: Int(ceil(image.size.height * scale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let bounds = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
    NSColor.clear.setFill()
    bounds.fill(using: .copy)
    image.draw(in: NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale))
    NSGraphicsContext.restoreGraphicsState()
    let x = Int(point.x * scale)
    let y = rep.pixelsHigh - 1 - Int(point.y * scale)
    guard x >= 0, x < rep.pixelsWide, y >= 0, y < rep.pixelsHigh else { return nil }
    return rep.colorAt(x: x, y: y)?.alphaComponent
}

/// The tag mark a window's tab title leads with, as the bake wrote it; nil
/// for a title that leads with none.
///
/// - Parameter window: The tab's window.
/// - Returns: The mark's attachment.
@MainActor
func tabTagMark(of window: NSWindow) -> TabTagMarkAttachment? {
    guard let title = window.tab.attributedTitle, title.length > 0 else { return nil }
    return title.attribute(.attachment, at: 0, effectiveRange: nil) as? TabTagMarkAttachment
}

/// The field a tab button draws its title in: the one holding a tag mark
/// when one does, otherwise the first that is not the accessory's shortcut
/// hint.
///
/// - Parameter button: The tab button.
/// - Returns: The field.
@MainActor
func tabTitleField(in button: NSView) -> NSTextField? {
    var fields: [NSTextField] = []
    var stack = button.subviews
    while let view = stack.popLast() {
        if let field = view as? NSTextField, !field.isHidden {
            fields.append(field)
        }
        stack.append(contentsOf: view.subviews)
    }
    let marked = fields.first { field in
        let value = field.attributedStringValue
        return value.length > 0 && value.attribute(.attachment, at: 0, effectiveRange: nil) is TabTagMarkAttachment
    }
    return marked ?? fields.first { !$0.stringValue.hasPrefix("\u{2318}") }
}

/// The tag marks a group's strip shows, read off each pill's title field
/// rather than the bake, in strip order; nil where a pill shows none.
///
/// - Parameter window: Any window of the group.
/// - Returns: One entry per pill.
@MainActor
func drawnTabTagMarks(inGroupOf window: NSWindow) -> [TabTagMarkAttachment?] {
    TabStripStyling.tabPills(inGroupOf: window)
        .map { pill in
            guard let value = tabTitleField(in: pill.button)?.attributedStringValue, value.length > 0 else { return nil }
            return value.attribute(.attachment, at: 0, effectiveRange: nil) as? TabTagMarkAttachment
        }
}

/// The tag stack the title leads with: the one attachment holding every
/// marker's pill, which the host chip's reserved span and the trailing bell
/// are not; nil when the title leads with none.
///
/// - Parameter field: The window's title field.
/// - Returns: The stack's attachment.
@MainActor
func titleTagStack(_ field: NSTextField?) -> TitlebarTagAttachment? {
    guard let value = field?.attributedStringValue, value.length > 0 else {
        return nil
    }
    var stack: TitlebarTagAttachment?
    value.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value.length)) { attachment, _, stop in
        if let found = attachment as? TitlebarTagAttachment {
            stack = found
            stop.pointee = true
        }
    }
    return stack
}

/// The tags the title's stack drew, in order; empty when it leads with none.
///
/// - Parameter field: The window's title field.
/// - Returns: The marks.
@MainActor
func titleMarks(_ field: NSTextField?) -> [TitlebarTagMark] {
    titleTagStack(field)?.marks ?? []
}

/// The attachment the title ENDS with, or nil when its last run is text.
///
/// The tag chips are attachments too, so a count answers nothing about which
/// one is which; the mark this exists for is the trailing bell, and what makes
/// it that mark is its position — the chips lead, the bell is last.
///
/// - Parameter field: The title field to read.
/// - Returns: The trailing attachment, or nil for none.
@MainActor
func titleTrailingAttachment(_ field: NSTextField?) -> NSTextAttachment? {
    guard let value = field?.attributedStringValue, value.length > 0 else {
        return nil
    }
    return value.attribute(.attachment, at: value.length - 1, effectiveRange: nil) as? NSTextAttachment
}

/// The colour washing the title row, or nil when the row carries no wash.
///
/// - Parameter window: The window to read.
/// - Returns: The tint, in sRGB.
@MainActor
func titlebarWash(of window: NSWindow) -> NSColor? {
    guard let container = titlebarStrip(of: window), let cgColor = container.layer?.backgroundColor,
        let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB), color.alphaComponent > 0
    else {
        return nil
    }
    return color
}

/// Every terminal window the app currently holds, newest last.
@MainActor
func liveTerminalWindows() -> [NSWindow] {
    NSApp.windows.filter { $0.isVisible && $0.windowController != nil && titlebarStrip(of: $0) != nil }
}

/// AppKit's titlebar container for a windowed (non-fullscreen) window.
@MainActor
func titlebarStrip(of window: NSWindow) -> NSView? {
    let root = window.contentView?.superview ?? window.contentView
    var stack: [NSView] = root.map { [$0] } ?? []
    while let view = stack.popLast() {
        if NSStringFromClass(type(of: view)) == "NSTitlebarContainerView" {
            return view
        }
        stack.append(contentsOf: view.subviews)
    }
    return nil
}

/// The strip's tracking-area owner that answers AppKit's rollover.
@MainActor
func hoverOwner(of strip: NSView) -> NSObject? {
    for area in strip.trackingAreas {
        if let owner = area.owner as? NSObject, owner.responds(to: NSSelectorFromString("mouseEntered:")),
            !(owner is NSView)
        {
            return owner
        }
    }
    return nil
}

/// The window's own title field, matched the way the controller matches it:
/// the widest text field that is a DIRECT subview of `NSTitlebarView`. A tab's
/// label carries the same string but lives inside the accessory clip view, so
/// depth is what separates the two.
@MainActor
func titleField(in strip: NSView) -> NSTextField? {
    let titlebar =
        NSStringFromClass(type(of: strip)) == "NSTitlebarView"
        ? strip
        : strip.subviews.first { NSStringFromClass(type(of: $0)) == "NSTitlebarView" }
    guard let titlebar else { return nil }
    var best: NSTextField?
    for case let field as NSTextField in titlebar.subviews where !field.isHidden && field.frame.width > 0 {
        if best == nil || field.frame.width > best!.frame.width {
            best = field
        }
    }
    return best
}

/// The dimensions run at the end of the field's composed string: whatever
/// follows the last em dash, when it reads as columns-by-rows.
@MainActor
func statusSuffix(of field: NSTextField) -> String? {
    let text = field.attributedStringValue.string
    guard let dash = text.range(of: "\u{2014}", options: .backwards) else {
        return nil
    }
    let suffix = String(text[dash.upperBound...])
    guard suffix.contains("\u{00d7}"), suffix.rangeOfCharacter(from: .decimalDigits) != nil else {
        return nil
    }
    return suffix
}

/// The title identity control, found through its public accessibility seam.
@MainActor
func identityControl(in root: NSView) -> NSControl? {
    var stack: [NSView] = [root]
    while let view = stack.popLast() {
        if let control = view as? NSControl,
            control.accessibilityIdentifier() == "titlebarDocumentActions.button"
        {
            return control
        }
        stack.append(contentsOf: view.subviews)
    }
    return nil
}

/// Whether a popover is actually ON SCREEN anywhere in the application.
///
/// `isVisible` cannot answer this: a popover that left with its tab keeps it
/// and only drops out of the visible occlusion state.
///
/// - Returns: Whether the user can see a popover.
@MainActor
func popoverIsOnScreen() -> Bool {
    NSApp.windows.contains { window in
        NSStringFromClass(type(of: window)).contains("Popover")
            && window.isVisible
            && window.occlusionState.contains(.visible)
    }
}

/// Whether a popover window stands anywhere in the application.
@MainActor
func popoverIsShown() -> Bool {
    NSApp.windows.contains { window in
        window.isVisible && NSStringFromClass(type(of: window)).contains("Popover")
    }
}

/// A crossing event at the center of the title text hit zone.
@MainActor
func crossing(in window: NSWindow) -> NSEvent? {
    guard let strip = titlebarStrip(of: window),
        let titleField = titleField(in: strip)
    else { return nil }
    let hitZone = mouseSensitiveRect(in: strip, titleField: titleField, window: window)
    let center = NSPoint(x: hitZone.midX, y: hitZone.midY)
    let locationInWindow = strip.convert(center, to: nil)
    return NSEvent.enterExitEvent(
        with: .mouseEntered,
        location: locationInWindow,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        trackingNumber: 0,
        userData: nil
    )
}

/// A crossing event just outside the title text hit zone.
@MainActor
func crossingOutside(in window: NSWindow) -> NSEvent? {
    guard let strip = titlebarStrip(of: window),
        let titleField = titleField(in: strip)
    else { return nil }
    let hitZone = mouseSensitiveRect(in: strip, titleField: titleField, window: window)
    let outsidePoint = NSPoint(x: hitZone.maxX + 1, y: hitZone.midY)
    let locationInWindow = strip.convert(outsidePoint, to: nil)
    return NSEvent.enterExitEvent(
        with: .mouseExited,
        location: locationInWindow,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        trackingNumber: 0,
        userData: nil
    )
}

/// Reveals a window's folder proxy icon the way a dwell on the title strip
/// does, for a scenario whose subject is what the icon then shows.
///
/// The slot is released until a hover owns it, so a scenario that asserts on
/// `representedURL` has to hold a hover open for as long as it is asserting.
///
/// - Parameter window: The window whose strip is hovered.
/// - Returns: True when a hover owner was found and sent the crossing.
@MainActor
func revealFolderIcon(in window: NSWindow?) -> Bool {
    guard let window, let strip = titlebarStrip(of: window),
        let owner = hoverOwner(of: strip)
    else {
        return false
    }
    owner.perform(NSSelectorFromString("mouseEntered:"), with: crossing(in: window))
    return true
}

/// A text field inside any visible window, found by its accessibility id.
@MainActor
func popoverTextField(_ identifier: String) -> NSTextField? {
    popoverView(identifier) as? NSTextField
}

/// The first view in any visible window carrying this accessibility
/// identifier.
@MainActor
func popoverView(_ identifier: String) -> NSView? {
    for window in NSApp.windows where window.isVisible {
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if view.accessibilityIdentifier() == identifier {
                return view
            }
            stack.append(contentsOf: view.subviews)
        }
    }
    return nil
}

/// Dispatches one key press to a window, the way the field editor hears it.
@MainActor
func sendKey(_ keyCode: UInt16, characters: String, to window: NSWindow?) {
    guard let window else { return }
    for isDown in [true, false] {
        if let event = NSEvent.keyEvent(
            with: isDown ? .keyDown : .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) {
            window.sendEvent(event)
        }
    }
}

/// Matches AppKit's private `_mouseSensitiveTitleRevealRect`: it begins with
/// the document proxy's title-sensitive base rect, then outsets it by
/// `NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)`.
@MainActor
func mouseSensitiveRect(in strip: NSView, titleField: NSTextField, window: NSWindow) -> NSRect {
    var rect = strip.convert(titleField.bounds, from: titleField)
    if let documentButton = window.standardWindowButton(.documentIconButton) {
        rect = rect.union(strip.convert(documentButton.bounds, from: documentButton))
    }
    if let control = identityControl(in: strip), !control.isHidden, control.superview != nil {
        rect = rect.union(strip.convert(control.bounds, from: control))
    }
    return NSInsetRect(rect, -8, -4)
}

/// The internal arrow image view whose alpha the rollover drives, the replica
/// of the native `NSButtonImageView` inside `NSThemeAutosaveButton`.
@MainActor
func chevronArrowView(in control: NSControl) -> NSImageView? {
    control.subviews.compactMap { $0 as? NSImageView }.first
}

/// Whether the chevron is actually DRAWN, not merely present and opaque.
///
/// Alpha alone cannot answer it: an image view carrying no image passes every
/// opacity assertion while showing nothing, so the image and its size are
/// checked with it.
///
/// - Parameter control: The title identity control.
/// - Returns: Whether a chevron is on screen.
@MainActor
func chevronIsDrawn(in control: NSControl?) -> Bool {
    guard let arrow = control.flatMap(chevronArrowView(in:)), !arrow.isHidden, arrow.alphaValue > 0,
        let image = arrow.image
    else {
        return false
    }
    return image.size.width > 0 && image.size.height > 0 && arrow.frame.width > 0
}

/// A colour as it resolves under one appearance.
///
/// A dynamic colour answers differently in each appearance and a baked one
/// answers the same in both, which is what makes this the instrument for
/// telling them apart.
///
/// - Parameters:
///   - color: The colour to resolve.
///   - appearance: The appearance to resolve it under.
/// - Returns: The resolved sRGB colour, or nil when it does not convert.
@MainActor
func resolved(_ color: NSColor?, under appearance: NSAppearance.Name) -> NSColor? {
    guard let color, let appearance = NSAppearance(named: appearance) else {
        return nil
    }
    var out: NSColor?
    appearance.performAsCurrentDrawingAppearance {
        out = color.usingColorSpace(.sRGB)
    }
    return out
}

/// Perceived lightness, for asking whether two colours can be told apart.
@MainActor
func luminance(_ color: NSColor?) -> CGFloat? {
    guard let srgb = color?.usingColorSpace(.sRGB) else {
        return nil
    }
    return 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent
}

/// The chevron's tint, as the image view carries it.
@MainActor
func chevronTint(in control: NSControl?) -> NSColor? {
    control.flatMap(chevronArrowView(in:))?.contentTintColor
}

/// The colour the title row is painted, as the chevron sits on it.
///
/// A themed titlebar paints its own layer; a native one leaves the system
/// material, whose settled colour is the window background.
///
/// - Parameter window: The window to read.
/// - Returns: The row's colour under that window's appearance.
@MainActor
func titlebarRowColor(of window: NSWindow) -> NSColor? {
    if let wash = titlebarWash(of: window), wash.alphaComponent > 0.5 {
        return wash
    }
    var resolved: NSColor?
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
        resolved = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
    }
    return resolved
}

/// How far ink moves the lightness of what it is laid over, at its own opacity.
///
/// Opacity is the point: ink of a contrasting hue laid on at a tenth of an
/// alpha is still invisible, so the composite is what gets compared.
///
/// - Parameters:
///   - ink: The ink, carrying its own alpha.
///   - background: What it is drawn over.
/// - Returns: The lightness step, or nil when either colour is unreadable.
@MainActor
func inkContrast(_ ink: NSColor?, over background: NSColor?) -> CGFloat? {
    guard let ink = ink?.usingColorSpace(.sRGB), let background = background?.usingColorSpace(.sRGB),
        let backgroundLuminance = luminance(background)
    else {
        return nil
    }
    let alpha = ink.alphaComponent
    let composite = NSColor(
        srgbRed: ink.redComponent * alpha + background.redComponent * (1 - alpha),
        green: ink.greenComponent * alpha + background.greenComponent * (1 - alpha),
        blue: ink.blueComponent * alpha + background.blueComponent * (1 - alpha),
        alpha: 1
    )
    guard let compositeLuminance = luminance(composite) else {
        return nil
    }
    return abs(compositeLuminance - backgroundLuminance)
}
