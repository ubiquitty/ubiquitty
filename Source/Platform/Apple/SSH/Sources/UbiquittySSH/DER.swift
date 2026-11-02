// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Just enough DER to read an RFC 5915 elliptic-curve private key.
///
/// Not a DER library: it reads one structure, and every shape it
/// does not expect is a nil rather than a guess: a parser that recovers from
/// malformed input tends to recover into the wrong reading, and the value being
/// extracted here is a private key whose curve decides how it is used.
///
/// Reading SEC1 here keeps the key reader from telling people to convert their
/// file to a container the build cannot read.
enum DER {
    /// prime256v1, 1.2.840.10045.3.1.7.
    static let p256OID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    /// secp384r1, 1.3.132.0.34.
    static let p384OID: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x22]
    /// secp521r1, 1.3.132.0.35.
    static let p521OID: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x23]

    /// The two fields of an ECPrivateKey this reader needs.
    struct ECPrivateKeyFields {
        /// The private scalar, exactly as the OCTET STRING carried it.
        let privateKey: [UInt8]
        /// The named curve's OID body, without its tag and length.
        let curveOID: [UInt8]
        /// The public point the file carries beside the scalar, uncompressed,
        /// or nil when the optional field is absent.
        let publicKey: [UInt8]?

        /// The scalar at the width its curve requires.
        ///
        /// Left-padded rather than truncated. An encoder may drop leading zero
        /// bytes, so a short scalar is a small key rather than a different one;
        /// a scalar LONGER than the curve is malformed and refused.
        ///
        /// - Parameter width: The curve's scalar size in bytes.
        /// - Returns: The padded scalar, or nil when it is too long to be one.
        func scalar(paddedTo width: Int) -> [UInt8]? {
            if privateKey.count == width { return privateKey }
            if privateKey.count > width { return nil }
            return [UInt8](repeating: 0, count: width - privateKey.count) + privateKey
        }
    }

    /// Reads an RFC 5915 ECPrivateKey.
    ///
    /// - Parameter bytes: The DER encoding.
    /// - Returns: Its scalar and curve, or nil for anything unexpected.
    static func ecPrivateKey(_ bytes: [UInt8]) -> ECPrivateKeyFields? {
        var reader = Reader(bytes)
        // ECPrivateKey ::= SEQUENCE { version, privateKey, [0] params, [1] key }
        guard var body = reader.reader(tag: 0x30), reader.isEmpty else { return nil }
        // version INTEGER, which must be 1; any other version is a structure
        // this reader has not been shown.
        guard let version = body.element(tag: 0x02), version == [0x01] else { return nil }
        guard let privateKey = body.element(tag: 0x04) else { return nil }
        // parameters [0], context-specific and constructed, wrapping the
        // curve: by name, as OpenSSL writes it, or spelled out, as the
        // LibreSSL behind macOS's `ssh-keygen -m PEM` writes it.
        guard var parameters = body.reader(tag: 0xA0) else { return nil }
        let curveOID: [UInt8]
        if let named = parameters.element(tag: 0x06) {
            curveOID = named
        } else if var explicit = parameters.reader(tag: 0x30), let named = namedCurve(explicit: &explicit) {
            curveOID = named
        } else {
            return nil
        }
        guard parameters.isEmpty else { return nil }
        // publicKey [1] BIT STRING, optional: no unused bits, then the point.
        var publicKey: [UInt8]?
        if var wrapper = body.reader(tag: 0xA1) {
            guard let bits = wrapper.element(tag: 0x03), bits.first == 0, wrapper.isEmpty else { return nil }
            publicKey = Array(bits.dropFirst())
        }
        guard body.isEmpty else { return nil }
        return ECPrivateKeyFields(privateKey: privateKey, curveOID: curveOID, publicKey: publicKey)
    }

    /// Identifies a supported curve only when every domain parameter matches.
    /// Sharing a field prime does not make two elliptic curves equivalent.
    private static func namedCurve(explicit: inout Reader) -> [UInt8]? {
        guard explicit.element(tag: 0x02) == [0x01], var field = explicit.reader(tag: 0x30),
            field.element(tag: 0x06) == primeFieldOID, let prime = field.element(tag: 0x02),
            field.isEmpty, prime.first.map({ $0 & 0x80 == 0 }) == true,
            var curve = explicit.reader(tag: 0x30), let coefficientA = curve.element(tag: 0x04),
            let coefficientB = curve.element(tag: 0x04), let base = explicit.element(tag: 0x04),
            let order = explicit.element(tag: 0x02), order.first.map({ $0 & 0x80 == 0 }) == true
        else { return nil }
        // The optional seed describes how the curve was chosen, not its
        // domain. It must still be a whole BIT STRING with valid unused bits.
        if let seed = curve.element(tag: 0x03) {
            guard let unused = seed.first, unused < 8, seed.count > 1,
                seed.last.map({ $0 & UInt8((1 << Int(unused)) - 1) == 0 }) == true
            else { return nil }
        }
        guard curve.isEmpty else { return nil }
        if let cofactor = explicit.element(tag: 0x02), cofactor != [1] { return nil }
        guard explicit.isEmpty,
            let expected = explicitCurves.first(where: { $0.prime == Array(prime.drop { $0 == 0 }) })
        else { return nil }
        var expectedA = expected.prime
        expectedA[expectedA.count - 1] -= 3
        guard Array(coefficientA.drop { $0 == 0 }) == expectedA,
            Array(coefficientB.drop { $0 == 0 }) == expected.coefficientB,
            base == expected.base, Array(order.drop { $0 == 0 }) == expected.order
        else { return nil }
        return expected.oid
    }

    /// The public domain parameters of the NIST prime curves, in SEC 2's
    /// uncompressed form. All three have coefficient a = p - 3 and cofactor 1.
    private struct ExplicitCurve {
        let oid: [UInt8]
        let prime: [UInt8]
        let coefficientB: [UInt8]
        let base: [UInt8]
        let order: [UInt8]
    }

    /// prime-field, 1.2.840.10045.1.1.
    private static let primeFieldOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x01, 0x01]
    /// P-256's field prime, 2^256 − 2^224 + 2^192 + 2^96 − 1.
    private static let p256Prime: [UInt8] =
        [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01] + [UInt8](repeating: 0, count: 12) + [UInt8](repeating: 0xFF, count: 12)
    /// P-384's field prime, 2^384 − 2^128 − 2^96 + 2^32 − 1.
    private static let p384Prime: [UInt8] =
        [UInt8](repeating: 0xFF, count: 31) + [0xFE] + [UInt8](repeating: 0xFF, count: 4) + [UInt8](repeating: 0, count: 8)
        + [UInt8](repeating: 0xFF, count: 4)
    /// P-521's field prime, 2^521 − 1.
    private static let p521Prime: [UInt8] = [0x01] + [UInt8](repeating: 0xFF, count: 65)

    private static let explicitCurves = [
        ExplicitCurve(
            oid: p256OID,
            prime: p256Prime,
            coefficientB: [
                0x5A, 0xC6, 0x35, 0xD8, 0xAA, 0x3A, 0x93, 0xE7, 0xB3, 0xEB, 0xBD, 0x55,
                0x76, 0x98, 0x86, 0xBC, 0x65, 0x1D, 0x06, 0xB0, 0xCC, 0x53, 0xB0, 0xF6,
                0x3B, 0xCE, 0x3C, 0x3E, 0x27, 0xD2, 0x60, 0x4B,
            ],
            base: [
                0x04, 0x6B, 0x17, 0xD1, 0xF2, 0xE1, 0x2C, 0x42, 0x47, 0xF8, 0xBC, 0xE6,
                0xE5, 0x63, 0xA4, 0x40, 0xF2, 0x77, 0x03, 0x7D, 0x81, 0x2D, 0xEB, 0x33,
                0xA0, 0xF4, 0xA1, 0x39, 0x45, 0xD8, 0x98, 0xC2, 0x96, 0x4F, 0xE3, 0x42,
                0xE2, 0xFE, 0x1A, 0x7F, 0x9B, 0x8E, 0xE7, 0xEB, 0x4A, 0x7C, 0x0F, 0x9E,
                0x16, 0x2B, 0xCE, 0x33, 0x57, 0x6B, 0x31, 0x5E, 0xCE, 0xCB, 0xB6, 0x40,
                0x68, 0x37, 0xBF, 0x51, 0xF5,
            ],
            order: [
                0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
                0xFF, 0xFF, 0xFF, 0xFF, 0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84,
                0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
            ]
        ),
        ExplicitCurve(
            oid: p384OID,
            prime: p384Prime,
            coefficientB: [
                0xB3, 0x31, 0x2F, 0xA7, 0xE2, 0x3E, 0xE7, 0xE4, 0x98, 0x8E, 0x05, 0x6B,
                0xE3, 0xF8, 0x2D, 0x19, 0x18, 0x1D, 0x9C, 0x6E, 0xFE, 0x81, 0x41, 0x12,
                0x03, 0x14, 0x08, 0x8F, 0x50, 0x13, 0x87, 0x5A, 0xC6, 0x56, 0x39, 0x8D,
                0x8A, 0x2E, 0xD1, 0x9D, 0x2A, 0x85, 0xC8, 0xED, 0xD3, 0xEC, 0x2A, 0xEF,
            ],
            base: [
                0x04, 0xAA, 0x87, 0xCA, 0x22, 0xBE, 0x8B, 0x05, 0x37, 0x8E, 0xB1, 0xC7,
                0x1E, 0xF3, 0x20, 0xAD, 0x74, 0x6E, 0x1D, 0x3B, 0x62, 0x8B, 0xA7, 0x9B,
                0x98, 0x59, 0xF7, 0x41, 0xE0, 0x82, 0x54, 0x2A, 0x38, 0x55, 0x02, 0xF2,
                0x5D, 0xBF, 0x55, 0x29, 0x6C, 0x3A, 0x54, 0x5E, 0x38, 0x72, 0x76, 0x0A,
                0xB7, 0x36, 0x17, 0xDE, 0x4A, 0x96, 0x26, 0x2C, 0x6F, 0x5D, 0x9E, 0x98,
                0xBF, 0x92, 0x92, 0xDC, 0x29, 0xF8, 0xF4, 0x1D, 0xBD, 0x28, 0x9A, 0x14,
                0x7C, 0xE9, 0xDA, 0x31, 0x13, 0xB5, 0xF0, 0xB8, 0xC0, 0x0A, 0x60, 0xB1,
                0xCE, 0x1D, 0x7E, 0x81, 0x9D, 0x7A, 0x43, 0x1D, 0x7C, 0x90, 0xEA, 0x0E,
                0x5F,
            ],
            order: [
                0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                0xC7, 0x63, 0x4D, 0x81, 0xF4, 0x37, 0x2D, 0xDF, 0x58, 0x1A, 0x0D, 0xB2,
                0x48, 0xB0, 0xA7, 0x7A, 0xEC, 0xEC, 0x19, 0x6A, 0xCC, 0xC5, 0x29, 0x73,
            ]
        ),
        ExplicitCurve(
            oid: p521OID,
            prime: p521Prime,
            coefficientB: [
                0x51, 0x95, 0x3E, 0xB9, 0x61, 0x8E, 0x1C, 0x9A, 0x1F, 0x92, 0x9A, 0x21,
                0xA0, 0xB6, 0x85, 0x40, 0xEE, 0xA2, 0xDA, 0x72, 0x5B, 0x99, 0xB3, 0x15,
                0xF3, 0xB8, 0xB4, 0x89, 0x91, 0x8E, 0xF1, 0x09, 0xE1, 0x56, 0x19, 0x39,
                0x51, 0xEC, 0x7E, 0x93, 0x7B, 0x16, 0x52, 0xC0, 0xBD, 0x3B, 0xB1, 0xBF,
                0x07, 0x35, 0x73, 0xDF, 0x88, 0x3D, 0x2C, 0x34, 0xF1, 0xEF, 0x45, 0x1F,
                0xD4, 0x6B, 0x50, 0x3F, 0x00,
            ],
            base: [
                0x04, 0x00, 0xC6, 0x85, 0x8E, 0x06, 0xB7, 0x04, 0x04, 0xE9, 0xCD, 0x9E,
                0x3E, 0xCB, 0x66, 0x23, 0x95, 0xB4, 0x42, 0x9C, 0x64, 0x81, 0x39, 0x05,
                0x3F, 0xB5, 0x21, 0xF8, 0x28, 0xAF, 0x60, 0x6B, 0x4D, 0x3D, 0xBA, 0xA1,
                0x4B, 0x5E, 0x77, 0xEF, 0xE7, 0x59, 0x28, 0xFE, 0x1D, 0xC1, 0x27, 0xA2,
                0xFF, 0xA8, 0xDE, 0x33, 0x48, 0xB3, 0xC1, 0x85, 0x6A, 0x42, 0x9B, 0xF9,
                0x7E, 0x7E, 0x31, 0xC2, 0xE5, 0xBD, 0x66, 0x01, 0x18, 0x39, 0x29, 0x6A,
                0x78, 0x9A, 0x3B, 0xC0, 0x04, 0x5C, 0x8A, 0x5F, 0xB4, 0x2C, 0x7D, 0x1B,
                0xD9, 0x98, 0xF5, 0x44, 0x49, 0x57, 0x9B, 0x44, 0x68, 0x17, 0xAF, 0xBD,
                0x17, 0x27, 0x3E, 0x66, 0x2C, 0x97, 0xEE, 0x72, 0x99, 0x5E, 0xF4, 0x26,
                0x40, 0xC5, 0x50, 0xB9, 0x01, 0x3F, 0xAD, 0x07, 0x61, 0x35, 0x3C, 0x70,
                0x86, 0xA2, 0x72, 0xC2, 0x40, 0x88, 0xBE, 0x94, 0x76, 0x9F, 0xD1, 0x66,
                0x50,
            ],
            order: [
                0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFA, 0x51, 0x86,
                0x87, 0x83, 0xBF, 0x2F, 0x96, 0x6B, 0x7F, 0xCC, 0x01, 0x48, 0xF7, 0x09,
                0xA5, 0xD0, 0x3B, 0xB5, 0xC9, 0xB8, 0x89, 0x9C, 0x47, 0xAE, 0xBB, 0x6F,
                0xB7, 0x1E, 0x91, 0x38, 0x64, 0x09,
            ]
        ),
    ]

    /// A cursor over DER, handing back one element at a time.
    private struct Reader {
        private let bytes: [UInt8]
        private var index: Int

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            index = 0
        }

        var isEmpty: Bool { index == bytes.count }

        /// The next element's content, when it carries the expected tag.
        mutating func element(tag: UInt8) -> [UInt8]? {
            guard let range = next(tag: tag) else { return nil }
            return Array(bytes[range])
        }

        /// The next element's content as its own cursor, for a constructed tag.
        mutating func reader(tag: UInt8) -> Reader? {
            guard let range = next(tag: tag) else { return nil }
            return Reader(Array(bytes[range]))
        }

        /// Advances over one element and returns where its content sits.
        private mutating func next(tag: UInt8) -> Range<Int>? {
            guard index < bytes.count, bytes[index] == tag else { return nil }
            var cursor = index + 1
            guard cursor < bytes.count else { return nil }
            let first = bytes[cursor]
            cursor += 1
            var length = 0
            if first & 0x80 == 0 {
                length = Int(first)
            } else {
                // Long form: the low bits count the length's own bytes. More
                // than four would exceed anything this structure can hold, and
                // is refused rather than accumulated into an overflow.
                let count = Int(first & 0x7F)
                guard count > 0, count <= 4, cursor + count <= bytes.count else { return nil }
                for _ in 0..<count {
                    length = (length << 8) | Int(bytes[cursor])
                    cursor += 1
                }
            }
            guard length >= 0, cursor + length <= bytes.count else { return nil }
            index = cursor + length
            return cursor..<(cursor + length)
        }
    }
}
