// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// ProxyIconRevealScenarios.swift — the titlebar folder proxy icon's hover
// lifecycle, driven through the objects AppKit itself drives.
//
// Two of the three things asserted here are invisible to a unit test of the
// controller, because they are facts about the seam rather than about the
// state machine:
//
//   * whether the tracking area's owner ANSWERS the selector AppKit sends. A
//     Swift owner that spells `mouseEntered(with:)` and is never told to expose
//     it compiles, reads correctly, and is skipped in silence — so the assertion
//     has to be made against the installed area's real owner.
//   * whether the slot is RELEASED at rest. A reserved slot with an invisible
//     button is not visible to any assertion about the icon; what the user sees
//     is an empty gap where the title should begin.

/// Registers the folder-icon reveal scenarios with the UI-test runner.
@objc(UBProxyIconRevealScenarios)
public final class ProxyIconRevealScenarios: NSObject {
    /// Registers every scenario in this file.
    @objc
    public static func register() {
        UBUITestRegister("folder_icon_slot_is_released_at_rest") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window) else {
                    t.expect(false, desc: "a window with a titlebar came up")
                    return
                }
                // The cwd resolves as soon as the shell reports one; the slot
                // must stay released anyway, because nothing is hovering.
                t.expect(
                    window.representedURL == nil,
                    desc: "at rest the window holds no representedURL, so AppKit reserves "
                        + "no proxy-icon slot and the title begins where the title belongs"
                )
                t.expect(
                    window.standardWindowButton(.documentIconButton) == nil
                        || window.standardWindowButton(.documentIconButton)?.alphaValue == 0,
                    desc: "and no proxy icon is drawn"
                )
                // The native autosave control persists at rest: TextEdit's
                // edited window keeps "— Edited" visible while only the arrow
                // image is at alpha 0.
                let control = identityControl(in: strip)
                t.expect(
                    control.map { !$0.isHidden && $0.alphaValue == 1 } ?? false,
                    desc: "the title identity control persists at rest — visibility is arrow alpha, never control opacity"
                )
                t.expect(
                    control.flatMap(chevronArrowView(in:)).map { $0.alphaValue == 0 } ?? false,
                    desc: "and its arrow image rests at alpha 0, so no chevron is visible"
                )
                if let field = titleField(in: strip), let status = statusSuffix(of: field) {
                    t.expect(
                        !window.title.contains(status),
                        desc: "the dimensions live in the composed field string, not in the window-title string"
                    )
                }
                t.closeAllWindows()
            }
        }

        UBUITestRegister("folder_icon_hover_owner_answers_appkit") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window) else {
                    t.expect(false, desc: "a window with a titlebar came up")
                    return
                }
                let owners = strip.trackingAreas.compactMap { $0.owner as? NSObject }
                t.expect(
                    !owners.isEmpty,
                    desc: "the title strip carries a tracking area to hover over"
                )
                t.expect(
                    owners.contains { $0.responds(to: NSSelectorFromString("mouseEntered:")) },
                    desc: "and one of its owners answers mouseEntered:, the selector AppKit "
                        + "actually sends — an owner that does not is skipped without a word"
                )
                t.expect(
                    owners.contains { $0.responds(to: NSSelectorFromString("mouseExited:")) },
                    desc: "and answers mouseExited: too, so the reveal can be undone"
                )
                t.expect(
                    owners.contains { $0.responds(to: NSSelectorFromString("mouseMoved:")) },
                    desc: "and answers mouseMoved:, so each in-zone movement can reset the native hysteresis"
                )
                t.closeAllWindows()
            }
        }

        UBUITestRegister("folder_icon_reveals_and_retreats_on_hover") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // Every flight below is one the system's Reduce Motion takes
                // away, so it is pinned off: the machine's own switch must not
                // turn this into a test of the reduced path.
                SystemDisplayOptions.pinForTesting(reduceMotion: false, reduceTransparency: false)
                defer { SystemDisplayOptions.unpinForTesting() }
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window),
                    let owner = hoverOwner(of: strip)
                else {
                    t.expect(false, desc: "the title strip carries a hover owner")
                    return
                }
                let restTitleFrame = titleField(in: strip)
                    .map {
                        strip.convert($0.bounds, from: $0)
                    }

                let entered = Date()
                owner.perform(NSSelectorFromString("mouseEntered:"), with: crossing(in: window))
                t.pump(0.05)
                t.expect(
                    window.representedURL == nil,
                    desc: "an entry alone does not reveal — the reveal dwell must elapse first"
                )
                t.expect(
                    identityControl(in: strip).flatMap(chevronArrowView(in:)).map { $0.alphaValue == 0 }
                        ?? false,
                    desc: "entry alone leaves the chevron at alpha 0 — its fade rides the reveal flight, not the pointer"
                )
                let revealed = t.wait(until: { window.representedURL != nil }, timeout: 2.0)
                t.expect(
                    revealed,
                    desc: "the dwell resolves the slot and starts the reveal"
                )
                t.expect(
                    Date().timeIntervalSince(entered) >= 0.15,
                    desc: "the reveal waited out the chosen 0.15-second dwell — a timer cannot fire early"
                )
                guard revealed else {
                    t.closeAllWindows()
                    return
                }

                // Sampled immediately after the dwell fires, before the flight
                // completion clears these keys.
                let titleShift =
                    titleField(in: strip)?.layer?
                    .animation(forKey: "ub-folder-title-shift") as? CABasicAnimation
                t.expect(
                    titleShift != nil,
                    desc: "the title exposes its in-flight reveal animation instead of silently jumping to its endpoint"
                )
                t.expect(
                    titleShift.map { abs($0.duration - 0.3) < 0.000_001 } ?? false,
                    desc: "the title uses AppKit's exact 0.3-second rollover duration"
                )
                t.expect(
                    titleShift.map { hasCoreAnimationDefaultTiming($0.timingFunction) } ?? false,
                    desc: "the title uses Core Animation's default 0.25/0.10/0.25/1.00 timing curve"
                )
                let titleShiftEndpoints = positionEndpoints(of: titleShift)
                t.expect(
                    titleShiftEndpoints != nil,
                    desc: "the title reveal has inspectable position endpoints"
                )
                if let titleShiftEndpoints {
                    t.expect(
                        titleShiftEndpoints.from.x != titleShiftEndpoints.to.x,
                        desc: "the title's leg flies a real horizontal distance"
                    )
                    t.expect(
                        titleShiftEndpoints.from.y == titleShiftEndpoints.to.y,
                        desc: "the title's endpoints have the same vertical coordinate, so the flight cannot run diagonally"
                    )
                }

                let iconSlide =
                    window.standardWindowButton(.documentIconButton)?.layer?
                    .animation(forKey: "ub-folder-icon-slide") as? CABasicAnimation
                t.expect(
                    iconSlide != nil,
                    desc: "the proxy icon exposes its in-flight reveal animation too"
                )
                t.expect(
                    iconSlide.map { abs($0.duration - 0.3) < 0.000_001 } ?? false,
                    desc: "the proxy icon uses the same exact 0.3-second layout-derived leg"
                )
                t.expect(
                    window.standardWindowButton(.documentIconButton)?.layer?
                        .animation(forKey: "ub-folder-icon-fade") == nil,
                    desc: "the proxy icon does not fade — the native document button is opaque, only its layout moves"
                )
                t.expect(
                    window.standardWindowButton(.documentIconButton).map { !$0.isHidden && $0.alphaValue == 1 }
                        ?? false,
                    desc: "reveal unhides the icon synchronously at full alpha"
                )

                let control = identityControl(in: strip)
                t.expect(
                    control != nil,
                    desc: "the title identity control rides over the title through the reveal"
                )
                if let control {
                    t.expect(
                        !control.isHidden && control.alphaValue == 1,
                        desc: "the control stays at full alpha — visibility is arrow alpha, never control opacity"
                    )
                    if let revealedTitle = titleField(in: strip), let host = control.superview {
                        t.expect(
                            revealedTitle.superview === host,
                            desc: "the control shares the title field's superview, so whatever moves the title moves both"
                        )
                        let titleFrame = revealedTitle.frame
                        t.expect(
                            abs(control.frame.minX - titleFrame.minX) < 0.000_001
                                && abs(control.frame.minY - titleFrame.minY) < 0.000_001
                                && abs(control.frame.height - titleFrame.height) < 0.000_001,
                            desc: "the control overlays the title field's own frame, so the whole title is the click target"
                        )
                        t.expect(
                            control.frame.width > titleFrame.width,
                            desc: "and extends past the text for the chevron"
                        )
                    } else {
                        t.expect(false, desc: "the revealed title remains available to anchor the control")
                    }
                    if let arrow = chevronArrowView(in: control) {
                        t.expect(
                            arrow.frame.width == 8 && arrow.frame.height == 6,
                            desc: "the internal arrow is the native 8-by-6 image"
                        )
                    } else {
                        t.expect(false, desc: "the control carries its arrow image")
                    }

                    let actionsSlide =
                        control.layer?
                        .animation(forKey: "ub-folder-actions-slide") as? CABasicAnimation
                    t.expect(
                        actionsSlide != nil,
                        desc: "the control exposes its in-flight position animation instead of appearing out of sync"
                    )
                    t.expect(
                        control.layer?.animation(forKey: "ub-folder-actions-fade") == nil,
                        desc: "the control does not cross-fade during the flight"
                    )
                    t.expect(
                        actionsSlide.map { abs($0.duration - 0.3) < 0.000_001 } ?? false,
                        desc: "the control uses the title reveal's exact 0.3-second duration"
                    )
                    t.expect(
                        actionsSlide.map { hasCoreAnimationDefaultTiming($0.timingFunction) } ?? false,
                        desc: "the control's position uses the title reveal's default timing curve"
                    )
                    let actionsEndpoints = positionEndpoints(of: actionsSlide)
                    t.expect(
                        actionsEndpoints != nil,
                        desc: "the control reveal has inspectable position endpoints"
                    )
                    if let actionsEndpoints, let titleShiftEndpoints {
                        t.expect(
                            abs(
                                (actionsEndpoints.from.x - actionsEndpoints.to.x)
                                    - (titleShiftEndpoints.from.x - titleShiftEndpoints.to.x)
                            ) < 0.000_001,
                            desc: "the control and title translate by the same horizontal distance"
                        )
                    }
                }

                t.pump(0.4)
                t.expect(
                    window.standardWindowButton(.documentIconButton)?.alphaValue ?? 0 > 0,
                    desc: "and the icon is visible once the flight lands"
                )
                t.expect(
                    identityControl(in: strip).flatMap(chevronArrowView(in:)).map { $0.alphaValue == 1 }
                        ?? false,
                    desc: "the chevron landed with the same flight, one gesture with the icon"
                )
                t.expect(
                    chevronIsDrawn(in: identityControl(in: strip)),
                    desc: "and it is a drawn chevron — an image view at full opacity carrying no "
                        + "image shows nothing while passing every opacity assertion"
                )
                if let restTitleFrame, let nowTitleField = titleField(in: strip) {
                    let nowTitleFrame = strip.convert(nowTitleField.bounds, from: nowTitleField)
                    t.expect(
                        restTitleFrame.origin.x != nowTitleFrame.origin.x,
                        desc: "and the title has moved aside to make room for it"
                    )
                }

                let exited = Date()
                owner.perform(NSSelectorFromString("mouseExited:"), with: crossingOutside(in: window))
                t.expect(
                    window.representedURL != nil
                        && titleField(in: strip)?.layer?
                            .animation(forKey: "ub-folder-title-shift") == nil,
                    desc:
                        "the exit arms the retreat dwell rather than retreating at once, so a pointer crossing the title does not flicker it"
                )
                let retreating = t.wait(
                    until: {
                        window.standardWindowButton(.documentIconButton)?.layer?
                            .animation(forKey: "ub-folder-icon-slide") != nil
                    },
                    timeout: 2.0
                )
                t.expect(retreating, desc: "the dwell expires and the retreat flight begins")
                t.expect(
                    Date().timeIntervalSince(exited) >= 0.25,
                    desc: "the retreat waited out the full 0.25-second hover-off dwell"
                )
                t.expect(
                    window.standardWindowButton(.documentIconButton).map { !$0.isHidden && $0.layer?.mask != nil }
                        ?? false,
                    desc: "the icon retreats through the clipped edge it arrived by, symmetric with the reveal"
                )
                t.expect(
                    t.wait(until: { window.representedURL == nil }, timeout: 2.0),
                    desc: "the retreat completes and hands the slot back, so the gap closes again"
                )
                t.expect(
                    window.standardWindowButton(.documentIconButton)?.isHidden ?? true,
                    desc: "the completed retreat leaves the icon hidden"
                )
                t.expect(
                    identityControl(in: strip).flatMap(chevronArrowView(in:)).map { $0.alphaValue == 0 }
                        ?? false,
                    desc: "and the chevron left with the retreat, not on a clock of its own"
                )
                t.closeAllWindows()
            }
        }

        // The reduced half of the reveal: under Reduce Motion the dwell still
        // reveals the icon and the retreat still hands the slot back, and
        // nothing flies in between.
        UBUITestRegister("folder_icon_reveals_without_a_flight_under_reduce_motion") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                SystemDisplayOptions.pinForTesting(reduceMotion: true, reduceTransparency: false)
                defer { SystemDisplayOptions.unpinForTesting() }
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window),
                    let owner = hoverOwner(of: strip)
                else {
                    t.expect(false, desc: "the title strip carries a hover owner")
                    return
                }
                owner.perform(NSSelectorFromString("mouseEntered:"), with: crossing(in: window))
                t.expect(
                    t.wait(until: { window.representedURL != nil }, timeout: 2.0),
                    desc: "the dwell still resolves the slot and reveals under Reduce Motion"
                )
                t.expect(
                    titleField(in: strip)?.layer?.animation(forKey: "ub-folder-title-shift") == nil,
                    desc: "the title moves aside without a flight"
                )
                t.expect(
                    window.standardWindowButton(.documentIconButton)?.layer?
                        .animation(forKey: "ub-folder-icon-slide") == nil,
                    desc: "the proxy icon arrives without a flight"
                )
                t.expect(
                    window.standardWindowButton(.documentIconButton).map { !$0.isHidden && $0.alphaValue == 1 }
                        ?? false,
                    desc: "and stands at full alpha at once"
                )
                owner.perform(NSSelectorFromString("mouseExited:"), with: crossingOutside(in: window))
                t.expect(
                    t.wait(until: { window.representedURL == nil }, timeout: 2.0),
                    desc: "the retreat still hands the slot back"
                )
                t.expect(
                    window.standardWindowButton(.documentIconButton)?.isHidden ?? true,
                    desc: "and leaves the icon hidden"
                )
                t.closeAllWindows()
            }
        }

        UBUITestRegister("titlebar_title_takes_a_click_and_opens_the_popover") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window),
                    let control = identityControl(in: strip), let field = titleField(in: strip)
                else {
                    t.expect(false, desc: "the titlebar carries the title identity control")
                    return
                }

                // hitTest is handed a point in the SUPERVIEW's space. Testing it
                // against the control's own bounds answers nil for every click
                // the control actually receives, which reads as a dead
                // affordance: the hover lands (tracking areas bypass hitTest)
                // but nothing opens.
                guard let host = control.superview else {
                    t.expect(false, desc: "the control is installed in the titlebar")
                    return
                }
                let overTitleText = host.convert(
                    NSPoint(x: field.bounds.minX + 4, y: field.bounds.midY),
                    from: field
                )
                // Until the rollover presents, the row is not a control: the
                // native frame keeps every press, so titlebar gestures — the
                // double-click zoom above all — behave as if this control did
                // not exist.
                t.expect(
                    control.hitTest(overTitleText) == nil,
                    desc:
                        "before the rollover presents, the title text hit-tests to nothing of ours — the native titlebar keeps its gestures"
                )
                (control.target as? NSObject)?.setValue(true, forKey: "isTitleRegionHovered")
                t.pump(0.05)
                t.expect(
                    control.hitTest(overTitleText) === control,
                    desc:
                        "once presented, a click on the title text lands on the control — the whole title opens the popover, not just the chevron"
                )
                let controlCenterInHost = host.convert(
                    NSPoint(x: control.bounds.midX, y: control.bounds.midY),
                    from: control
                )
                t.expect(
                    control.hitTest(controlCenterInHost) === control,
                    desc: "a click at the control's centre lands on the control too, so the row is one target"
                )
                (control.target as? NSObject)?.setValue(false, forKey: "isTitleRegionHovered")
                t.pump(0.05)
                let outside = NSPoint(
                    x: controlCenterInHost.x - control.bounds.width - 40,
                    y: controlCenterInHost.y
                )
                t.expect(
                    control.hitTest(outside) == nil,
                    desc: "and a point outside the control hit-tests to nothing, so it claims no titlebar it does not occupy"
                )

                t.expect(
                    !popoverIsShown(),
                    desc: "no popover stands before the control is clicked"
                )

                // Short pumps only: `NSPopover.show` is synchronous, and a
                // long wait here lets a pending AppleEvent open reach
                // `applicationDidFinishLaunching` a second time, which aborts
                // in `PAL::installContext`.
                let actionsController = control.target as? NSObject
                func controllerSaysPopoverShown() -> Bool? {
                    actionsController?.value(forKey: "isPopoverShown") as? Bool
                }
                control.sendAction(control.action, to: control.target)
                t.pump(0.3)
                t.expect(
                    popoverIsShown(),
                    desc: "clicking the title opens the document-actions popover"
                )
                t.expect(
                    controllerSaysPopoverShown() == true,
                    desc: "and the controller knows it is open"
                )
                control.sendAction(control.action, to: control.target)
                t.pump(0.3)
                t.expect(
                    !popoverIsShown(),
                    desc: "a second activation closes the popover again"
                )
                t.expect(
                    controllerSaysPopoverShown() == false,
                    desc: "and the controller learns of the close"
                        + " (isPopoverShown=\(controllerSaysPopoverShown().map(String.init(describing:)) ?? "nil"))"
                )

                // The action fired directly proves the wiring; a real click
                // must also survive the dispatch itself. NSWindow.sendEvent
                // routes a titlebar press through the theme frame's own hit
                // testing, which is where a control shadowed by AppKit's own
                // views silently loses without any assertion above noticing.
                let clickInWindow = field.superview!
                    .convert(
                        NSPoint(x: field.frame.minX + 6, y: field.frame.midY),
                        to: nil
                    )
                if let frameView = window.contentView?.superview {
                    let restingHit = frameView.hitTest(clickInWindow)
                    t.expect(
                        restingHit === field || restingHit?.isDescendant(of: field) == true,
                        desc:
                            "unpresented, the frame resolves the title point to AppKit's own field — the double-click zoom and every native gesture keep working"
                            + " (got \(restingHit.map { NSStringFromClass(type(of: $0)) } ?? "nil"))"
                    )
                    actionsController?.setValue(true, forKey: "isTitleRegionHovered")
                    t.pump(0.05)
                    let presentedHit = frameView.hitTest(clickInWindow)
                    t.expect(
                        presentedHit === control,
                        desc: "presented, the frame's own hit test resolves the same point to the identity control"
                            + " (got \(presentedHit.map { NSStringFromClass(type(of: $0)) } ?? "nil"))"
                    )
                    actionsController?.setValue(false, forKey: "isTitleRegionHovered")
                    t.pump(0.05)
                }
                // The action fired directly above proves the wiring; the press
                // must also survive the dispatch itself, decomposed so a
                // failure names its half: does the event handling fire the
                // action, and does the popover then stand.
                let probe = ClickProbe()
                let savedTarget = control.target
                let savedAction = control.action
                control.target = probe
                control.action = #selector(ClickProbe.fire(_:))
                // Before the rollover has presented anything, the row hit-tests
                // to nothing of ours, so the press never reaches the control.
                for (kind, clickCount) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1)] {
                    if let event = NSEvent.mouseEvent(
                        with: kind,
                        location: clickInWindow,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        eventNumber: 0,
                        clickCount: clickCount,
                        pressure: kind == .leftMouseDown ? 1 : 0
                    ) {
                        window.sendEvent(event)
                    }
                }
                t.expect(
                    probe.fired == 0,
                    desc: "a press before the rollover presents fires nothing — the row acts only once the chevron is up"
                )
                actionsController?.setValue(true, forKey: "isTitleRegionHovered")
                t.pump(0.05)
                for (kind, clickCount) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1)] {
                    if let event = NSEvent.mouseEvent(
                        with: kind,
                        location: clickInWindow,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        eventNumber: 0,
                        clickCount: clickCount,
                        pressure: kind == .leftMouseDown ? 1 : 0
                    ) {
                        window.sendEvent(event)
                    }
                }
                control.target = savedTarget
                control.action = savedAction
                t.expect(
                    probe.fired == 1,
                    desc:
                        "a real press-and-release on the title text, dispatched through the window, fires the action (fired=\(probe.fired))"
                )
                t.expect(
                    control.window === window,
                    desc: "the control is still installed in the window before the final activation"
                )
                let controllerShown =
                    (savedTarget as? NSObject)?.value(forKey: "isPopoverShown") as? Bool
                t.expect(
                    controllerShown == false,
                    desc: "the controller agrees no popover stands before the final activation"
                        + " (isPopoverShown=\(controllerShown.map(String.init(describing:)) ?? "nil"))"
                )
                control.sendAction(control.action, to: control.target)
                t.expect(
                    popoverIsShown(),
                    desc: "the popover stands synchronously after the click's action runs"
                )
                t.pump(0.3)
                t.expect(
                    popoverIsShown(),
                    desc: "and it survives the runloop settling instead of closing itself"
                )

                // Editing in the popover writes through, and a write re-lays
                // the titlebar. A layout that re-adds the popover's anchor
                // dismisses it, so the panel would close under the pointer on
                // the first tag typed.
                var frame = window.frame
                frame.size.width -= 40
                window.setFrame(frame, display: true)
                t.pump(0.3)
                t.expect(
                    popoverIsShown(),
                    desc: "a titlebar relayout leaves the popover standing, so editing in it survives its own writes"
                )

                // With the popover standing, a press on the title is its
                // dismissal: the transient behaviour closes on the press, and
                // the release's action must not resurrect what the press just
                // closed. Dispatched through NSApp so the event monitors that
                // implement both halves actually run.
                for (kind, pressure) in [(NSEvent.EventType.leftMouseDown, 1.0), (.leftMouseUp, 0.0)] {
                    if let event = NSEvent.mouseEvent(
                        with: kind,
                        location: clickInWindow,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        eventNumber: 1,
                        clickCount: 1,
                        pressure: Float(pressure)
                    ) {
                        NSApp.sendEvent(event)
                    }
                }
                t.pump(0.4)
                t.expect(
                    !popoverIsShown(),
                    desc: "a click on the title while the popover stands closes it and stays closed"
                )

                // A chevron the popover raised without a dwell goes down
                // without one: no reveal ran here, so no exit hysteresis is
                // owed either. The pause first lets the press-dismissal guard
                // expire — the synthetic press above armed it.
                t.pump(1.05)
                control.sendAction(control.action, to: control.target)
                t.pump(0.2)
                t.expect(
                    popoverIsShown(),
                    desc: "the popover reopens for the keyboard-close check"
                )
                t.expect(
                    chevronArrowView(in: control).map { $0.alphaValue == 1 } ?? false,
                    desc: "opening the popover raises the chevron"
                )
                _ = (control.target as? NSObject)?.perform(NSSelectorFromString("closePopover"))
                t.pump(0.25)
                let arrowAlpha = chevronArrowView(in: control).map { $0.alphaValue }
                t.expect(
                    chevronArrowView(in: control).map { $0.alphaValue == 0 } ?? false,
                    desc: "closing it drops the chevron at once — no exit dwell when no dwell raised it"
                        + " (alpha=\(arrowAlpha.map(String.init(describing:)) ?? "nil"),"
                        + " windowScan=\(popoverIsShown()),"
                        + " controller=\(String(describing: controllerSaysPopoverShown())))"
                )
                t.closeAllWindows()
            }
        }

        UBUITestRegister("titlebar_status_joins_the_title_string") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                // The count below needs the directory in the title, and the
                // settings sandbox is one per run: a scenario earlier in the
                // registry can leave the directory off. The precondition is
                // established here rather than assumed, and put back after.
                let showedDirectory = SettingsBridge.app?.settingsTitleWindowDirectory() ?? true
                SettingsBridge.app?.settingsSetTitleWindowDirectory(true)
                defer { SettingsBridge.app?.settingsSetTitleWindowDirectory(showedDirectory) }
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window),
                    let field = titleField(in: strip)
                else {
                    t.expect(false, desc: "the titlebar carries a title field")
                    return
                }
                let styled = field.attributedStringValue
                let text = styled.string as NSString
                guard let status = statusSuffix(of: field) else {
                    t.expect(false, desc: "the field's string carries the dimensions after the title")
                    return
                }
                t.expect(
                    !window.title.contains(status),
                    desc: "the window-title string does not carry the dimensions — only the composed field does"
                )

                // One string means one baseline; what remains checkable is that
                // the status run wears its own smaller face and that no second
                // field carries the dimensions anywhere in the titlebar.
                let statusStart = text.length - (status as NSString).length
                let statusFont =
                    styled.attribute(.font, at: statusStart, effectiveRange: nil) as? NSFont
                let titleFont = field.font
                t.expect(
                    statusFont != nil && titleFont != nil && statusFont != titleFont
                        && statusFont!.pointSize < titleFont!.pointSize,
                    desc: "the status run wears its own lighter, slightly smaller face inside the one string"
                )
                t.expect(
                    textFieldsCarrying(status, under: strip).count == 1,
                    desc: "exactly one field carries the dimensions — no separate status field survives to drift off the baseline"
                )
                if let control = identityControl(in: strip), let arrow = chevronArrowView(in: control) {
                    let statusColor =
                        styled.attribute(.foregroundColor, at: statusStart, effectiveRange: nil)
                        as? NSColor
                    t.expect(
                        statusColor != nil && arrow.contentTintColor == statusColor,
                        desc:
                            "the chevron wears the status run's own colour — a second writer stamping the bright title colour would show here"
                    )
                } else {
                    t.expect(false, desc: "the control and its arrow are present to check the tint")
                }

                // Both em dashes are spaced by the one kern rule, so the gaps
                // around every separator on the line are equal by construction.
                var kernPairs: [(CGFloat, CGFloat)] = []
                var index = 0
                while index < text.length {
                    let dash = text.range(of: "\u{2014}", options: [], range: NSRange(location: index, length: text.length - index))
                    guard dash.location != NSNotFound else {
                        break
                    }
                    if dash.location > 0, NSMaxRange(dash) < text.length {
                        let before =
                            styled.attribute(.kern, at: dash.location - 1, effectiveRange: nil)
                            as? CGFloat ?? 0
                        let after =
                            styled.attribute(.kern, at: dash.location, effectiveRange: nil)
                            as? CGFloat ?? 0
                        kernPairs.append((before, after))
                    }
                    index = NSMaxRange(dash)
                }
                // The count alone cannot be acted on from a log: a run one
                // separator short says nothing of which segment is missing.
                // The line itself travels
                // with the verdict, and so does the window's own title, so a
                // reader can tell a directory that never arrived from a
                // status that was never composed.
                t.expect(
                    kernPairs.count >= 2,
                    desc: "the composed line carries at least the title's separator and the status "
                        + "separator (found \(kernPairs.count) in \"\(text as String)\"; window.title "
                        + "\"\(window.title)\"; directory "
                        + "\((window.windowController as? TerminalWindowController)?.beamSurface?.drive.currentDirectory() ?? "nil"))"
                )
                if let first = kernPairs.first {
                    t.expect(
                        kernPairs.allSatisfy { $0.0 == first.0 && $0.1 == first.1 },
                        desc: "every separator on the line wears the same kern pair, so the dashes cannot drift apart"
                    )
                    t.expect(
                        first.0 > 0 && first.1 > 0,
                        desc: "and the pair is real spacing, not the absence of the attribute"
                    )
                }
                t.closeAllWindows()
            }
        }

        UBUITestRegister("titlebar_popover_escape_cancels_edits") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window),
                    let control = identityControl(in: strip)
                else {
                    t.expect(false, desc: "the titlebar carries the title identity control")
                    return
                }
                let actionsController = control.target as? NSObject

                control.sendAction(control.action, to: control.target)
                t.pump(0.3)
                guard popoverIsShown(), let titleField = popoverTextField("titlebarDocumentActions.windowTitle") else {
                    t.expect(false, desc: "the popover opened with its title field")
                    return
                }
                titleField.stringValue = "typed-then-escaped"
                sendKey(53, characters: "\u{1b}", to: titleField.window)
                t.pump(0.4)
                t.expect(
                    !popoverIsShown(),
                    desc: "escape closes the popover"
                )
                t.expect(
                    (actionsController?.value(forKey: "windowTitleOverride") as? String) == "",
                    desc: "and the typed-but-unconfirmed title is discarded, not committed"
                )

                t.pump(1.05)
                control.sendAction(control.action, to: control.target)
                t.pump(0.3)
                guard popoverIsShown(), let reopened = popoverTextField("titlebarDocumentActions.windowTitle") else {
                    t.expect(false, desc: "the popover reopened for the commit half")
                    return
                }
                t.expect(
                    reopened.stringValue.isEmpty,
                    desc: "the reopened editor shows no ghost of the escaped text"
                )
                reopened.stringValue = "committed-title"
                sendKey(36, characters: "\r", to: reopened.window)
                t.pump(0.3)
                t.expect(
                    (actionsController?.value(forKey: "windowTitleOverride") as? String) == "committed-title",
                    desc: "return commits the typed title"
                )
                _ = actionsController?.perform(NSSelectorFromString("closePopover"))
                t.pump(0.3)
                t.closeAllWindows()
            }
        }

        UBUITestRegister("titlebar_hover_survives_a_tab_switch_while_the_popover_stands") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let first = settledWindow(t), let delegate = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "a window came up")
                    return
                }
                defer { t.closeAllWindows() }
                delegate.newTab(nil)
                t.pump(1.2)
                guard let group = first.tabGroup, group.windows.count == 2,
                    let second = group.windows.first(where: { $0 !== first })
                else {
                    t.expect(false, desc: "the window has a sibling tab to switch to")
                    return
                }

                group.selectedWindow = first
                t.pump(0.4)
                guard let strip = titlebarStrip(of: first), openIdentityPopover(in: strip, t) else {
                    t.expect(false, desc: "the first tab's title popover opened")
                    return
                }

                // Leaving and coming back is the whole gesture: the popover
                // goes off screen by a route that reports no close, and the tab
                // it belonged to has to come back usable.
                group.selectedWindow = second
                t.pump(0.8)
                group.selectedWindow = first
                t.pump(0.8)

                let actionsController = identityControl(in: strip)?.target as? NSObject
                t.expect(
                    (actionsController?.value(forKey: "isPopoverShown") as? Bool) == false,
                    desc: "the popover does not survive the switch away from its own tab — the "
                        + "controller that gates the rollover knows it is gone"
                )
                t.expect(
                    !popoverIsOnScreen(),
                    desc: "and nothing of it is left on screen"
                )
                t.expect(
                    revealFolderIcon(in: first),
                    desc: "the returned-to tab still carries a hover owner"
                )
                t.expect(
                    t.wait(until: { first.representedURL != nil }, timeout: 2.0),
                    desc: "and hovering it still reveals the icon — a popover the tab switch "
                        + "took off screen cannot suppress the rollover for the life of the tab"
                )
                t.expect(
                    chevronIsDrawn(in: identityControl(in: strip)),
                    desc: "and the chevron is drawn with it"
                )
            }
        }

        UBUITestRegister("titlebar_chevron_is_legible_in_both_titlebar_styles") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let delegate = SettingsBridge.app else {
                    t.expect(false, desc: "the settings bridge answers")
                    return
                }
                let styles: [(name: String, value: Int)] = [("themed", 0), ("native", 1)]
                for style in styles {
                    delegate.settingsSetTitlebarStyle(style.value)
                    t.pump(0.4)
                    guard let window = settledWindow(t), let strip = titlebarStrip(of: window) else {
                        t.expect(false, desc: "a window with a \(style.name) titlebar came up")
                        continue
                    }
                    t.expect(revealFolderIcon(in: window), desc: "the \(style.name) strip carries a hover owner")
                    _ = t.wait(until: { window.representedURL != nil }, timeout: 2.0)
                    t.pump(0.5)

                    let ink = chevronTint(in: identityControl(in: strip))
                    let row = titlebarRowColor(of: window)
                    let step = inkContrast(ink, over: row)
                    // The chevron is ink laid over the row at its own opacity.
                    // Composited, it has to move that row's lightness enough to
                    // be seen — an ink the same lightness as what it sits on is
                    // a chevron the user reports as missing.
                    t.expect(
                        (step ?? 0) > 0.10,
                        desc: "the chevron reads against the \(style.name) titlebar "
                            + "(lightness step \(String(format: "%.3f", step ?? -1)))"
                    )
                    if style.value == 1 {
                        // A window is pinned to the appearance its theme asks
                        // for, so ink resolved once and frozen is drawn under
                        // an appearance that was never consulted: a light theme
                        // wears the ink a dark one asked for, and the chevron
                        // is the colour of the row it sits on. Ink that answers
                        // the same in both appearances is that frozen ink.
                        let light = luminance(resolved(ink, under: .aqua))
                        let dark = luminance(resolved(ink, under: .darkAqua))
                        t.expect(
                            light != nil && dark != nil && abs(light! - dark!) > 0.2,
                            desc: "the native titlebar's ink resolves per appearance rather than "
                                + "being frozen at the moment it was computed"
                        )
                    }
                    t.closeAllWindows()
                }
                delegate.settingsSetTitlebarStyle(0)
                t.pump(0.3)
            }
        }

        // A press while the reveal is in flight: the flight lands and the
        // icon stays, and a held button does not collapse it. The press is
        // posted through the event queue so the controller's own monitor
        // sees it, as a real press would reach it.
        UBUITestRegister("folder_icon_press_during_the_reveal_lets_the_flight_land") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                SystemDisplayOptions.pinForTesting(reduceMotion: false, reduceTransparency: false)
                defer { SystemDisplayOptions.unpinForTesting() }
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window),
                    let owner = hoverOwner(of: strip), let field = titleField(in: strip)
                else {
                    t.expect(false, desc: "the title strip carries a hover owner and a title")
                    return
                }
                owner.perform(NSSelectorFromString("mouseEntered:"), with: crossing(in: window))
                let revealed = t.wait(until: { window.representedURL != nil }, timeout: 2.0)
                t.expect(revealed, desc: "the dwell starts the reveal")
                guard revealed else {
                    t.closeAllWindows()
                    return
                }
                let inFlight =
                    window.standardWindowButton(.documentIconButton)?.layer?
                    .animation(forKey: "ub-folder-icon-slide") != nil
                t.expect(inFlight, desc: "the press below lands while the icon is still in flight")
                let pressPoint = field.superview!.convert(NSPoint(x: field.frame.minX + 6, y: field.frame.midY), to: nil)
                if let down = mouseEvent(.leftMouseDown, in: window, at: pressPoint) {
                    deliver(down)
                }
                t.pump(0.05)
                t.expect(
                    window.representedURL != nil,
                    desc: "a press during the flight does not collapse the reveal"
                )
                t.pump(0.5)
                t.expect(
                    window.representedURL != nil
                        && (window.standardWindowButton(.documentIconButton).map { !$0.isHidden && $0.alphaValue == 1 } ?? false),
                    desc: "the flight lands with the icon revealed under the held button"
                )
                t.expect(
                    hasNoFolderFlightAnimations(on: window.standardWindowButton(.documentIconButton)),
                    desc: "and the landing cleared the flight"
                )
                if let up = mouseEvent(.leftMouseUp, in: window, at: pressPoint) {
                    deliver(up)
                }
                t.pump(0.3)
                t.expect(
                    t.wait(until: { popoverIsShown() }, timeout: 2.0),
                    desc: "the release of a click on the title opens the popover, whatever the reveal was doing"
                )
                t.closeAllWindows()
            }
        }

        // A click that lands before the dwell has elapsed: the row is still
        // the native frame's, so no control of ours sees the press — the
        // release opens the popover anyway, once the reveal it starts lands.
        UBUITestRegister("folder_icon_click_while_dwelling_opens_the_popover") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                SystemDisplayOptions.pinForTesting(reduceMotion: false, reduceTransparency: false)
                defer { SystemDisplayOptions.unpinForTesting() }
                t.closeAllWindows()
                guard let window = settledWindow(t) else {
                    t.expect(false, desc: "the title strip carries a hover owner and a title")
                    return
                }
                // The harness pumps the run loop without handling events, so
                // whatever the app queued since the last drain would be handled
                // between the entry and the press. Handled now, as the app's
                // own loop would have handled it, it leaves the press the next
                // event after the entry, and the title is read below as that
                // leaves it.
                drainEvents()
                guard let strip = titlebarStrip(of: window), let owner = hoverOwner(of: strip), let field = titleField(in: strip) else {
                    t.expect(false, desc: "the title strip carries a hover owner and a title")
                    return
                }
                let presentations = PopoverPresentationCounter()
                defer { presentations.stop() }
                owner.perform(NSSelectorFromString("mouseEntered:"), with: crossing(in: window))
                t.pump(0.02)
                let pressPoint = field.superview!.convert(NSPoint(x: field.frame.minX + 6, y: field.frame.midY), to: nil)
                if let down = mouseEvent(.leftMouseDown, in: window, at: pressPoint),
                    let up = mouseEvent(.leftMouseUp, in: window, at: pressPoint)
                {
                    deliver(down)
                    // Read once the press is handled: a reveal begun before it
                    // means the dwell elapsed first, and the click asserted
                    // below would not be the one this scenario is about.
                    t.expect(window.representedURL == nil, desc: "the click below lands while the row is still dwelling")
                    deliver(up)
                }
                t.expect(
                    t.wait(until: { window.representedURL != nil }, timeout: 2.0),
                    desc: "the click starts the reveal without waiting out the dwell"
                )
                t.expect(
                    t.wait(until: { hasNoFolderFlightAnimations(on: window.standardWindowButton(.documentIconButton)) }, timeout: 2.0),
                    desc: "the reveal lands"
                )
                t.expect(
                    t.wait(until: { popoverIsShown() }, timeout: 2.0),
                    desc: "and the popover opens when the reveal lands (popovers \(presentations.summary), "
                        + "window \(window.isKeyWindow ? "key" : "not key"), app \(NSApp.isActive ? "active" : "inactive"))"
                )
                t.closeAllWindows()
            }
        }

        UBUITestRegister("folder_icon_reentry_releases_proxy_and_chevron") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let window = settledWindow(t), let strip = titlebarStrip(of: window),
                    let owner = hoverOwner(of: strip)
                else {
                    t.expect(false, desc: "the title strip carries a hover owner")
                    return
                }

                owner.perform(NSSelectorFromString("mouseEntered:"), with: crossing(in: window))
                let firstReveal = t.wait(until: { window.representedURL != nil }, timeout: 2.0)
                t.expect(firstReveal, desc: "the first hover owns the proxy-icon slot")
                guard firstReveal else {
                    t.closeAllWindows()
                    return
                }
                t.pump(0.4)
                t.expect(
                    identityControl(in: strip).map { !$0.isHidden && $0.alphaValue > 0 } ?? false,
                    desc: "the first reveal keeps the identity control installed and visible"
                )

                owner.perform(NSSelectorFromString("mouseExited:"), with: crossingOutside(in: window))
                let firstExit = t.wait(until: { window.representedURL == nil }, timeout: 2.0)
                t.expect(firstExit, desc: "the first exit releases the proxy-icon slot")
                t.expect(
                    identityControl(in: strip).map { !$0.isHidden && $0.alphaValue == 1 } ?? false,
                    desc: "the exit keeps the control installed — the native status control persists at rest"
                )

                owner.perform(NSSelectorFromString("mouseEntered:"), with: crossing(in: window))
                let secondReveal = t.wait(until: { window.representedURL != nil }, timeout: 2.0)
                t.expect(secondReveal, desc: "re-entering after a completed exit owns a fresh proxy-icon slot")
                guard secondReveal else {
                    t.closeAllWindows()
                    return
                }
                t.pump(0.4)
                t.expect(
                    identityControl(in: strip).map { !$0.isHidden && $0.alphaValue > 0 } ?? false,
                    desc: "the fresh reveal reinstalls the control rather than retaining stale hidden state"
                )

                owner.perform(NSSelectorFromString("mouseExited:"), with: crossingOutside(in: window))
                let secondExit = t.wait(until: { window.representedURL == nil }, timeout: 2.0)
                t.expect(secondExit, desc: "the second exit releases the fresh proxy-icon slot")
                t.expect(
                    window.standardWindowButton(.documentIconButton)?.isHidden ?? true,
                    desc: "the final exit leaves the icon hidden"
                )
                t.expect(
                    identityControl(in: strip).flatMap(chevronArrowView(in:)).map { $0.alphaValue == 0 }
                        ?? true,
                    desc: "the final exit leaves no visible chevron arrow behind"
                )
                t.expect(
                    hasNoFolderFlightAnimations(on: window.standardWindowButton(.documentIconButton))
                        && hasNoFolderFlightAnimations(on: titleField(in: strip))
                        && hasNoFolderFlightAnimations(on: identityControl(in: strip)),
                    desc: "the final exit clears every proxy, title, and control flight before another hover begins"
                )
                t.closeAllWindows()
            }
        }

        // A running program marks its window edited — that is the close
        // button's dot — and AppKit draws an edited document's proxy at half
        // strength. The folder is not an unsaved document, so a tab running a
        // program shows it as solidly as one at a bare prompt.
        UBUITestRegister("folder_icon_on_an_edited_tab_is_drawn_as_solidly_as_on_a_plain_one") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                guard let first = settledWindow(t), let peer = settledWindow(t) else {
                    t.expect(false, desc: "a window came up")
                    return
                }
                defer { t.closeAllWindows() }
                first.addTabbedWindow(peer, ordered: .above)
                t.pump(1.2)
                guard let group = first.tabGroup, group.windows.count == 2,
                    let second = group.windows.first(where: { $0 !== first })
                else {
                    t.expect(false, desc: "the window has a second tab")
                    return
                }

                @MainActor
                func revealedIcon(in window: NSWindow) -> NSButton? {
                    group.selectedWindow = window
                    t.pump(0.6)
                    guard revealFolderIcon(in: window),
                        t.wait(until: { window.representedURL != nil }, timeout: 2.0)
                    else {
                        return nil
                    }
                    t.pump(0.8)
                    return window.standardWindowButton(.documentIconButton)
                }

                // What the compositor shows: the button's drawing and every
                // layer laid on it, rendered together.
                @MainActor
                func shownStrength(of icon: NSButton?) -> Double? {
                    guard let icon, let layer = icon.layer, icon.bounds.width > 0, icon.bounds.height > 0,
                        let space = CGColorSpace(name: CGColorSpace.sRGB)
                    else {
                        return nil
                    }
                    let scale = icon.window?.backingScaleFactor ?? 2
                    let width = Int(icon.bounds.width * scale)
                    let height = Int(icon.bounds.height * scale)
                    guard
                        let bitmap = CGContext(
                            data: nil,
                            width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: width * 4,
                            space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        )
                    else {
                        return nil
                    }
                    bitmap.scaleBy(x: scale, y: scale)
                    layer.render(in: bitmap)
                    guard let data = bitmap.data else { return nil }
                    let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
                    var peak: UInt8 = 0
                    for pixel in 0..<(width * height) {
                        peak = Swift.max(peak, bytes[pixel * 4 + 3])
                    }
                    return Double(peak) / 255
                }

                let plain = shownStrength(of: revealedIcon(in: first))
                second.isDocumentEdited = true
                t.pump(0.2)
                let edited = shownStrength(of: revealedIcon(in: second))
                guard let plain, let edited, plain > 0 else {
                    t.expect(
                        false,
                        desc: "both tabs reveal a drawn folder (plain \(String(describing: plain)), edited \(String(describing: edited)))"
                    )
                    return
                }
                t.expect(
                    abs(edited - plain) <= 0.04,
                    desc: "an edited tab's folder is shown as solidly as a plain tab's "
                        + "(plain \(String(format: "%.3f", plain)), edited \(String(format: "%.3f", edited)))"
                )
                t.expect(
                    second.isDocumentEdited,
                    desc: "and the window keeps its edited mark, so the close button keeps its dot"
                )
            }
        }
    }
}

/// Posts an event and drains the application's queue the way its own run
/// loop does: `nextEvent` is where a local event monitor runs and `sendEvent`
/// is where the window receives it. `pump` spins only the run loop and never
/// dequeues an application event, so a posted press left to it is never
/// delivered — and a scenario that waits on it then measures nothing.
@MainActor
private func deliver(_ event: NSEvent) {
    NSApp.postEvent(event, atStart: false)
    drainEvents()
}

/// Hands every queued event to the app, oldest first, until the queue has
/// been quiet for 50 ms.
@MainActor
private func drainEvents() {
    while let queued = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
        NSApp.sendEvent(queued)
    }
}

/// Counts popovers as AppKit announces them opening and closing, so a
/// popover that opened and closed between two samples reads differently from
/// one that never opened.
@MainActor
private final class PopoverPresentationCounter {
    private(set) var opened = 0
    private(set) var closed = 0
    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        tokens.append(
            center.addObserver(forName: NSPopover.willShowNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.opened += 1 }
            }
        )
        tokens.append(
            center.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed += 1 }
            }
        )
    }

    /// What was counted, for a failure to report.
    var summary: String { "opened \(opened), closed \(closed)" }

    /// Stops counting.
    func stop() {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        tokens = []
    }
}

/// A mouse event at a window point, as the queue would deliver one.
@MainActor
private func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: type == .leftMouseUp ? 0 : 1
    )
}

/// Every text field under `root` whose string carries `needle`.
@MainActor
private func textFieldsCarrying(_ needle: String, under root: NSView) -> [NSTextField] {
    var found: [NSTextField] = []
    var stack: [NSView] = [root]
    while let view = stack.popLast() {
        if let field = view as? NSTextField, field.attributedStringValue.string.contains(needle) {
            found.append(field)
        }
        stack.append(contentsOf: view.subviews)
    }
    return found
}

/// Reports whether a timing function is the implicit Core Animation default.
@MainActor
private func hasCoreAnimationDefaultTiming(_ timingFunction: CAMediaTimingFunction?) -> Bool {
    guard let timingFunction else { return false }
    let expected: [(Float, Float)] = [(0, 0), (0.25, 0.10), (0.25, 1), (1, 1)]
    var values = [Float](repeating: 0, count: 2)
    for (index, point) in expected.enumerated() {
        timingFunction.getControlPoint(at: index, values: &values)
        guard abs(values[0] - point.0) < 0.000_001, abs(values[1] - point.1) < 0.000_001 else {
            return false
        }
    }
    return true
}

/// The endpoints of a position animation, when it describes AppKit points.
@MainActor
private func positionEndpoints(of animation: CABasicAnimation?) -> (from: CGPoint, to: CGPoint)? {
    guard let animation, let from = animation.fromValue as? NSValue,
        let to = animation.toValue as? NSValue
    else {
        return nil
    }
    return (from: from.pointValue, to: to.pointValue)
}

/// Whether a view retains none of this feature's completed-flight animations.
@MainActor
private func hasNoFolderFlightAnimations(on view: NSView?) -> Bool {
    guard let view else {
        return true
    }
    let keys = [
        "ub-folder-icon-fade",
        "ub-folder-icon-slide",
        "ub-folder-title-shift",
        "ub-folder-actions-fade",
        "ub-folder-actions-slide",
    ]
    return keys.allSatisfy { view.layer?.animation(forKey: $0) == nil }
}

/// Counts action firings for the dispatched-click assertion.
private final class ClickProbe: NSObject {
    var fired = 0

    @objc
    func fire(_ sender: Any?) {
        fired += 1
    }
}
