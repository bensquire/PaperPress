import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public extension Pipeline.ProcessedPage {
    /// The 1-bit page as a CGImage (for thumbnails and OCR).
    var cgImage: CGImage? {
        let rowBytes = (width + 7) / 8
        guard let provider = CGDataProvider(data: packed as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 1, bitsPerPixel: 1,
            bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

public extension Pipeline.GrayImage {
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Paper to white and ink to black: a levels adjustment from the page's
    /// own ink and paper (`levels`, or measured here), or the page unchanged
    /// when it has too little contrast to stretch. For pages the classifier
    /// calls text — it alone judges paper and ink: a photograph's light and
    /// dark halves aren't, and stretching them would clip it.
    ///
    /// The black point is the darkest ink, not the ink class's mean: the
    /// mean takes in every antialiased fringe pixel, and mapping it to black
    /// clipped half the ink and thickened strokes 1.33× on a 100 dpi letter.
    /// The ink class's darkest twentieth keeps them as scanned (1.00×).
    func levelled(_ levels: Binarize.Levels? = nil) -> Pipeline.GrayImage {
        guard let (ink, paper) = levels ?? Binarize.levels(self) else { return self }
        let hist = Pipeline.histogram(self)
        let split = Int((ink + paper) / 2)
        let inkCount = hist[0..<split].reduce(0, +)
        var seen = 0.0
        let black = Double(
            (0..<split).first { v in
                seen += hist[v]
                return seen >= 0.05 * inkCount
            } ?? Int(ink))
        guard paper - black > Binarize.minContrast else { return self }
        let scale = 255 / (paper - black)
        let lut = (0...255).map { UInt8(clamping: Int(((Double($0) - black) * scale).rounded())) }
        var out = self
        lut.withUnsafeBufferPointer { table in
            out.pixels.withUnsafeMutableBufferPointer { px in
                for i in px.indices { px[i] = table[Int(px[i])] }
            }
        }
        return out
    }

    func cropped(_ c: Pipeline.Crop) -> Pipeline.GrayImage {
        let cw = c.x1 - c.x0, ch = c.y1 - c.y0
        var out = [UInt8](repeating: 0, count: cw * ch)
        for y in 0..<ch {
            let src = (y + c.y0) * width + c.x0
            out.replaceSubrange(
                y * cw..<(y * cw + cw),
                with: pixels[src..<(src + cw)]
            )
        }
        return Pipeline.GrayImage(width: cw, height: ch, pixels: out)
    }

    func jpegData(quality: Double = 0.7, dpi: Int) -> Data? {
        cgImage.flatMap { ImageEncode.jpeg($0, quality: quality, dpi: dpi) }
    }
}

/// Shared ImageIO encoding (used for JPEG pages and G4 TIFFs).
public enum ImageEncode {
    public static func jpeg(
        _ image: CGImage, quality: Double = 0.7,
        dpi: Int
    ) -> Data? {
        encode(
            image, uti: UTType.jpeg.identifier as CFString,
            properties: [
                kCGImageDestinationLossyCompressionQuality: quality,
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi,
            ]
        )
    }

    public static func png(_ image: CGImage) -> Data? {
        encode(image, uti: UTType.png.identifier as CFString, properties: [:])
    }

    static func encode(
        _ image: CGImage, uti: CFString,
        properties: [CFString: Any]
    ) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, uti, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
