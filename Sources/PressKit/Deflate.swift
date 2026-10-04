import Foundation
import zlib

/// zlib-wrapped deflate (RFC 1950), as PDF's FlateDecode expects. The system
/// libz rather than the Compression framework, whose COMPRESSION_ZLIB is
/// level 5 only (/documentation/compression/compression_zlib), with no other
/// levels or strategies.
enum Deflate {
    static func zlibData(
        _ data: Data, level: Int32 = Z_BEST_COMPRESSION, strategy: Int32 = Z_DEFAULT_STRATEGY
    ) throws -> Data {
        var stream = z_stream()
        guard
            deflateInit2_(
                &stream, level, Z_DEFLATED, MAX_WBITS, 8, strategy, ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw PressError.scanFailed("Compression failed to start") }
        defer { deflateEnd(&stream) }
        var out = Data(count: Int(deflateBound(&stream, uLong(data.count))))
        let status = data.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(src.count)
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(dst.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else {
            throw PressError.scanFailed("Compression failed (zlib \(status))")
        }
        out.count = Int(stream.total_out)
        return out
    }
}
