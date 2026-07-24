import Compression
import Foundation

/// 4-bit grayscale page encoding: 16 levels, packed two pixels per byte,
/// PNG "Up" row predictor, zlib deflate. The middle ground between 1-bit
/// G4 (destroys small low-res print) and grayscale JPEG (DCT mush on
/// text): on document pages it is both smaller than JPEG q0.6 and crisp.
/// Dithering was measured and rejected — the noise triples the Flate size
/// and 16 levels don't band on paper-and-ink content.
public enum Gray4 {
    public struct Encoded {
        /// zlib-wrapped deflate of predictor-filtered rows, ready to embed
        /// as a FlateDecode image stream with PNG Predictor DecodeParms.
        public let data: Data
        public let width: Int
        public let height: Int
    }

    public static func encode(_ g: Pipeline.GrayImage) -> Encoded {
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

        return Encoded(data: zlib(Data(raw)), width: w, height: h)
    }

    /// Apple's Compression framework emits raw deflate; PDF FlateDecode
    /// wants the RFC 1950 zlib wrapper, so add header + adler32 ourselves.
    private static func zlib(_ raw: Data) -> Data {
        let cap = raw.count + raw.count / 2 + 1024
        var deflated = Data(count: cap)
        let n = deflated.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                    src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        var out = Data([0x78, 0x9C])
        out.append(deflated.prefix(n))
        var a: UInt32 = 1
        var b: UInt32 = 0
        raw.withUnsafeBytes { buf in
            // Modulo only every 5552 bytes (the standard adler32 chunk —
            // the largest run that can't overflow UInt32).
            var i = 0
            while i < buf.count {
                let end = min(i + 5552, buf.count)
                while i < end {
                    a &+= UInt32(buf[i])
                    b &+= a
                    i += 1
                }
                a %= 65521
                b %= 65521
            }
        }
        let adler = (b << 16) | a
        out.append(
            contentsOf: [
                UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF),
                UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF),
            ]
        )
        return out
    }
}
