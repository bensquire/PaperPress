import CoreGraphics
import Foundation

extension CGPDFPage {
    /// MediaBox size with the page's rotation applied — the size the page
    /// actually displays at. Inspector dpi maths and render dimensions must
    /// agree, so both go through this.
    public var orientedMediaBoxSize: CGSize {
        let box = getBoxRect(.mediaBox)
        return rotationAngle % 180 == 0
            ? CGSize(width: box.width, height: box.height)
            : CGSize(width: box.height, height: box.width)
    }
}

/// Rasterises a PDF page to 8-bit grayscale for the compression pipeline.
public enum PDFRender {
    public static func gray(page: CGPDFPage, dpi: Int) throws -> Pipeline.GrayImage {
        let box = page.orientedMediaBoxSize
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
                throw PressError.scanFailed("Cannot create render context")
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
