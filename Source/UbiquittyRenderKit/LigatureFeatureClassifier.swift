// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// LigatureFeatureClassifier.swift — the platform's few lines of the ligature
// classification: shape the probe Core asks for, hand back the glyph ids. The
// loop, the candidates, the probes and the verdict are Core's
// (`LigatureClassificationSession`); this file exists because CoreText is the
// one fact Core cannot have. Swift rather than a C++ CoreText body, so the
// same file serves an iOS frontend unchanged — and so both macOS shells read
// one shaper: the Objective-C arm reaches this class through the generated
// header, which is how one font stops classifying two ways.
//
// The session seam is values in both directions — a request out, a vector of
// ids back — which is what keeps this file free of context pointers and
// unmanaged casts.
//

import CoreText
import Foundation
import UbiquittyCore

@objc(UBLigatureFeatureClassifier)
public final class LigatureFeatureClassifier: NSObject {
    /// What the classification found in a face.
    ///
    /// A class rather than a tuple because the Objective-C arm reads it
    /// through the generated header, which carries no Swift struct.
    @objc(UBLigatureClassificationVerdict)
    public final class Verdict: NSObject {
        /// The qualifying features, serialised in Core's grammar.
        @objc
        public let featureSpec: String
        /// Whether the face ligates at all, its own defaults included.
        @objc
        public let doesLigate: Bool

        init(featureSpec: String, doesLigate: Bool) {
            self.featureSpec = featureSpec
            self.doesLigate = doesLigate
        }
    }

    /// Classifies `font`'s ligature features through Core's session.
    ///
    /// - Parameter font: The face the strips will rasterise with, the
    ///   reader's own features already applied, so the classification answers
    ///   relative to what will actually draw.
    /// - Returns: The verdict.
    @objc
    public static func classify(_ font: CTFont) -> Verdict {
        var session = Ubiquitty.Rendering.LigatureClassificationSession()
        while session.isAwaitingProbe() {
            let request = session.pendingProbe()
            session.submitGlyphs(
                shape(
                    String(request.text),
                    under: font,
                    featureTag: String(request.featureTag),
                    featureValue: Int(request.featureValue)
                )
            )
        }
        let classification = session.classification()
        return Verdict(
            featureSpec: String(Ubiquitty.Rendering.serializeFontFeatureSettings(classification.features)),
            doesLigate: classification.doesLigate
        )
    }

    /// Shapes `text` as one line and collects the glyph ids.
    ///
    /// - Parameters:
    ///   - text: The probe to shape.
    ///   - font: The face to shape under.
    ///   - featureTag: The OpenType tag to carry; empty shapes the face's
    ///     defaults.
    ///   - featureValue: The tag's value; zero disables it.
    /// - Returns: The ids, in run order.
    private static func shape(
        _ text: borrowing String,
        under font: borrowing CTFont,
        featureTag: String,
        featureValue: Int
    ) -> Ubiquitty.Rendering.ProbeGlyphs {
        var shaped = copy font
        if !featureTag.isEmpty {
            let settings = [
                [
                    kCTFontOpenTypeFeatureTag: featureTag,
                    kCTFontOpenTypeFeatureValue: featureValue,
                ] as [CFString: Any]
            ]
            let descriptor = CTFontDescriptorCreateWithAttributes(
                [kCTFontFeatureSettingsAttribute: settings] as CFDictionary
            )
            shaped = CTFontCreateCopyWithAttributes(shaped, CTFontGetSize(shaped), nil, descriptor)
        }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: copy text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): shaped]
            )
        )
        var glyphs = Ubiquitty.Rendering.ProbeGlyphs()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else {
                continue
            }
            var ids = [CGGlyph](repeating: 0, count: glyphCount)
            CTRunGetGlyphs(run, CFRange(location: 0, length: glyphCount), &ids)
            for id in ids {
                glyphs.push_back(UInt32(id))
            }
        }
        return glyphs
    }
}
