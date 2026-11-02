// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// BackdropImage.swift — the background image, decoded once for every renderer.
//
// A decode that each renderer re-implemented would let a configured background
// image show in one and not in another. The bitmap must be
// PREMULTIPLIED, because the background fragment blends destination-over and
// expects a premultiplied source; it must be drawn in the presentation colour
// space rather than DeviceRGB, which is unmanaged and would hand a wide-gamut
// file's numbers to the sampler unmatched; and an oversized file is refused by
// the same Core rule an inline image is, so a hostile or careless path cannot
// ask for a texture the device will not make. Each of those is a rule someone
// re-deriving the decode gets wrong once.

import CoreGraphics
import ImageIO
import Metal
import UbiquittyCore

/// A background image decoded and uploaded, ready to sample.
@MainActor
@objc(UBBackdropImage)
public final class BackdropImage: NSObject {
    /// The texture, `rgba8Unorm_srgb` and premultiplied.
    @objc
    public let texture: any MTLTexture

    /// The decoded pixel width, which the fragment's fit arithmetic reads.
    @objc
    public let pixelWidth: Int

    /// The decoded pixel height.
    @objc
    public let pixelHeight: Int

    private init(texture: any MTLTexture, pixelWidth: Int, pixelHeight: Int) {
        self.texture = texture
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Decodes an image file into a texture the background pass can sample.
    ///
    /// - Parameters:
    ///   - path: The file the reader configured. An empty path decodes
    ///     nothing, which is how a cleared key turns the backdrop off.
    ///   - usesDisplayP3: Whether to draw in Display P3 rather than sRGB; the
    ///     reader's `[image] presentation_color_space`, resolved by the caller
    ///     because Core holds the key and this holds the decode.
    ///   - device: The device the texture is made on.
    /// - Returns: The decoded image, or nil when the file is missing,
    ///   undecodable, refused for its size, or the texture could not be made.
    @objc
    public static func load(path: String, usesDisplayP3: Bool, device: any MTLDevice) -> BackdropImage? {
        guard !path.isEmpty,
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let width = image.width
        let height = image.height
        // Core's axis limit alone. An image a program sends is held to the
        // byte budget as well, `Image::isDecodedImageBytesRefused`; a backdrop
        // is a file the user chose, so it may be up to 16384 a side.
        guard !Ubiquitty.Image.isDecodedImageSizeRefused(Int64(width), Int64(height)) else {
            return nil
        }
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let spaceName = usesDisplayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        // Premultiplied-last, which is what the destination-over blend wants —
        // no unpremultiply step, because the bitmap arrives in the form the
        // fragment samples.
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let isDrawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: spaceName),
                let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: stride,
                    space: space,
                    bitmapInfo: info
                )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = device.cpuWrittenTextureStorageMode
        guard isDrawn, let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: stride
            )
        }
        return BackdropImage(texture: texture, pixelWidth: width, pixelHeight: height)
    }
}
