import Foundation
import zlib

/// 4-bit grayscale page encoding: 16 levels, packed two pixels per byte,
/// PNG "Up" row predictor, zlib deflate. The middle ground between 1-bit
/// G4 (destroys small low-res print) and grayscale JPEG (DCT mush on
/// text): on document pages it is both smaller than JPEG q0.6 and crisp.
/// Dithering was measured and rejected — the noise triples the Flate size
/// and 16 levels don't band on paper-and-ink content.
public enum Gray4 {
    public struct Encoded: Sendable {
        /// zlib-wrapped deflate of predictor-filtered rows, ready to embed
        /// as a FlateDecode image stream with PNG Predictor DecodeParms.
        public let data: Data
        public let width: Int
        public let height: Int
    }

    public static func encode(_ g: Pipeline.GrayImage) throws -> Encoded {
        let w = g.width, h = g.height
        let rowBytes = (w + 1) / 2

        // Pass 1: quantize to 16 levels and pack two pixels per byte.
        let lut = (0...255).map { UInt8((Double($0) / 17.0).rounded()) }
        var packed = [UInt8](repeating: 0, count: rowBytes * h)
        for y in 0..<h {
            let src = y * w
            let dst = y * rowBytes
            for x in 0..<w {
                let level = lut[Int(g.pixels[src + x])]
                if x % 2 == 0 {
                    packed[dst + x / 2] = level << 4
                } else {
                    packed[dst + x / 2] |= level
                }
            }
        }

        // Pass 2: PNG "Up" filter — each row minus the row above.
        var raw = [UInt8](repeating: 0, count: (rowBytes + 1) * h)
        for y in 0..<h {
            let src = y * rowBytes
            let dst = y * (rowBytes + 1)
            raw[dst] = 2  // PNG "Up" filter tag
            for b in 0..<rowBytes {
                let above = y > 0 ? packed[src - rowBytes + b] : 0
                raw[dst + 1 + b] = packed[src + b] &- above
            }
        }

        // Run-length deflate is the smallest and ~60× faster on scanned pages,
        // whose noise leaves little for long matches (a 150 dpi letter's page
        // at 300 dpi: 510 KB in 13 ms against level 9's 526 KB in 854 ms) —
        // and 24× larger on clean ones, where repeated glyphs are the matches
        // (295 KB against 12 KB). So both run-length and level 6 (a tenth of
        // level 9's time for ~3% more), and the smaller.
        let filtered = Data(raw)
        let rle = try Deflate.zlibData(filtered, level: 6, strategy: Z_RLE)
        let matched = try Deflate.zlibData(filtered, level: 6)
        return Encoded(data: rle.count <= matched.count ? rle : matched, width: w, height: h)
    }
}
