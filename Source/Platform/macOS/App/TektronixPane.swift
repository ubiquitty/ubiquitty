// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// TektronixPane.swift — the Settings pane for Tek 4014 storage-tube mode.
// Folds the Bright Ubiquitty.Pen + Glowing Vectors toggles in with a color source
// picker: "Terminal Theme" (beam = theme foreground, clear = theme
// background) vs "Custom", which reveals editable beam + background color
// wells defaulting to green phosphor on near-black (the classic wireframe).
//
// Reads resolve through Core's key surface (settingBool and its siblings); writes funnel
// through the application delegate's settings surface, which persists to
// config.toml and applies live to every window. Settings stays the single
// source of truth; this view holds no parallel store beyond the @State the
// controls bind to.
//

import AppKit
import SwiftUI
import UbiquittyAppBridge
import UbiquittyKit

struct TektronixPane: View {
    // 0 = terminal theme, 1 = custom. Seeded from the live config.
    @State
    private var colorMode: Int = settingInt(.TekColorMode)
    // Packed 0xRRGGBBAA so ColorPack round-trips them; alpha is always opaque.
    @State
    private var beam: UInt32 = settingTekColor(.TekBeamColor)
    @State
    private var background: UInt32 = settingTekColor(.TekBackgroundColor)
    @State
    private var brightPen: Bool = settingBool(.TekBrightPen)
    @State
    private var glowVectors: Bool = settingBool(.TekGlowVectors)

    var body: some View {
        SettingsPaneStack {
            SettingsCardView(
                title: "Colors",
                footer:
                    "Terminal Theme draws the vectors in your theme foreground over its background. Custom uses the beam and background colors below — green phosphor on near-black is the classic storage-tube look."
            ) {
                SettingsListRow(isFirst: true) {
                    labeledControl("Source", detail: nil) {
                        Picker(
                            "",
                            selection: Binding(
                                get: { colorMode },
                                set: { setMode($0) }
                            )
                        ) {
                            Text("Terminal Theme").tag(0)
                            Text("Custom").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if colorMode == 1 {
                    SettingsListRow(isFirst: false) {
                        labeledControl(
                            "Beam",
                            detail: "Sets the color of the vectors, points, and GIN crosshair."
                        ) {
                            colorWell($beam) { setBeam($0) }
                        }
                    }
                    SettingsListRow(isFirst: false) {
                        labeledControl(
                            "Background",
                            detail: "Sets the color behind the vectors, like a cleared storage tube."
                        ) {
                            colorWell($background) { setBackground($0) }
                        }
                    }
                }
            }

            SettingsCardView(title: "Effects") {
                SettingsListRow(isFirst: true) {
                    labeledControl(
                        "Bright Pen",
                        detail: "Adds a storage-tube glow: a bright spot where the beam draws."
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { brightPen },
                                set: {
                                    brightPen = $0
                                    SettingsBridge.app?.settingsSetTekBrightPen($0)
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(SettingsSwitchStyle())
                    }
                }
                SettingsListRow(isFirst: false) {
                    labeledControl(
                        "Glowing Vectors",
                        detail: "Adds a bloom to the vectors, so overlaps brighten like a lit CRT."
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { glowVectors },
                                set: {
                                    glowVectors = $0
                                    SettingsBridge.app?.settingsSetTekGlowVectors($0)
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(SettingsSwitchStyle())
                    }
                }
            }
        }
    }

    // A label (+ optional detail) on the left, a trailing control on the right —
    // the same row geometry the data-driven catalog rows use.
    @ViewBuilder
    private func labeledControl<Control: View>(
        _ label: String,
        detail: String?,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            control()
        }
    }

    // An opacity-free color well over a packed-0xRRGGBBAA binding (the Tek field
    // is always fully opaque). Writes the picked color back as packed RGBA and
    // calls the live write-through.
    private func colorWell(_ value: Binding<UInt32>, set: @escaping (UInt32) -> Void) -> some View {
        ColorPicker(
            "",
            selection: Binding(
                get: { ColorPack.color(value.wrappedValue) },
                set: { color in
                    // Force opaque so the stored hex is a clean #rrggbb.
                    let packed = (ColorPack.pack(color) & 0xFFFF_FF00) | 0xFF
                    value.wrappedValue = packed
                    set(packed)
                }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
    }

    // MARK: write-through

    private func setMode(_ mode: Int) {
        colorMode = mode
        SettingsBridge.app?.settingsSetTekColorMode(mode)
    }

    // The ObjC setter takes packed 0xRRGGBB; drop the alpha byte the well carries.
    private func setBeam(_ rgba: UInt32) {
        SettingsBridge.app?.settingsSetTekBeamColor(rgba >> 8)
    }

    private func setBackground(_ rgba: UInt32) {
        SettingsBridge.app?.settingsSetTekBackgroundColor(rgba >> 8)
    }
}
