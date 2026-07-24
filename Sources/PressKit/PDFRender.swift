import CoreGraphics
import Foundation

/// Rasterises a PDF page to 8-bit grayscale for the compression pipeline.
public enum PDFRender {
    public static func gray(page: CGPDFPage, dpi: Int) throws -> Pipeline.GrayImage {
        var box = page.getBoxRect(.mediaBox)
        if page.rotationAngle % 180 != 0 {
            box = CGRect(x: 0, y: 0, width: box.height, height: box.width)
        }
        let scale = Double(dpi) / 72
        let w = max(1, Int((box.width * scale).rounded()))
        let h = max(1, Int((box.height * scale).rounded()))
        var pixels = [UInt8](repeating: 255, count: w * h)
        try pixels.withUnsafeMutableBytes { buf in
            guard
                let ctx = CGContext(
                    data: buf.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else {
                throw ScanError.scanFailed("Cannot create render context")
            }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            // getDrawingTransform never scales UP, so ask it only to handle
            // rotation/origin at natural (point) size and apply the dpi
            // scale ourselves.
            ctx.concatenate(CGAffineTransform(scaleX: scale, y: scale))
            ctx.concatenate(
                page.getDrawingTransform(
                    .mediaBox, rect: CGRect(x: 0, y: 0, width: box.width, height: box.height),
                    rotate: 0, preserveAspectRatio: true
                )
            )
            ctx.drawPDFPage(page)
        }
        return Pipeline.GrayImage(width: w, height: h, pixels: pixels)
    }
}
