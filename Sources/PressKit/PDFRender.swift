import CoreGraphics
import Foundation

extension CGPDFPage {
    /// A box's size with the page's rotation applied.
    public func orientedSize(of box: CGPDFBox) -> CGSize {
        oriented(getBoxRect(box).size)
    }

    /// The part of the page a viewer shows — the crop box clipped to the
    /// media box, rotation applied. Renders and copied pages use this, so
    /// content outside a crop stays hidden: "When the page is displayed
    /// or printed, its contents are to be clipped to this rectangle"
    /// (/documentation/coregraphics/cgpdfbox/cropbox).
    public var visibleSize: CGSize {
        let media = getBoxRect(.mediaBox)
        let visible = getBoxRect(.cropBox).intersection(media)
        return oriented(visible.isEmpty ? media.size : visible.size)
    }

    private func oriented(_ size: CGSize) -> CGSize {
        rotationAngle % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }
}

extension Pipeline.GrayImage {
    /// Area-averaged rescale — used to derive a lower-resolution page from
    /// a render already in hand instead of rasterising the PDF again.
    public func resampled(scale: Double) -> Pipeline.GrayImage {
        let nw = max(1, Int((Double(width) * scale).rounded()))
        let nh = max(1, Int((Double(height) * scale).rounded()))
        guard nw != width || nh != height, let img = cgImage else { return self }
        var out = [UInt8](repeating: 255, count: nw * nh)
        out.withUnsafeMutableBytes { buf in
            guard
                let ctx = CGContext(
                    data: buf.baseAddress, width: nw, height: nh,
                    bitsPerComponent: 8, bytesPerRow: nw,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else { return }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        }
        return Pipeline.GrayImage(width: nw, height: nh, pixels: out)
    }
}

/// Rasterises a PDF page to 8-bit grayscale for the compression pipeline.
public enum PDFRender {
    public static func gray(page: CGPDFPage, dpi: Int) throws -> Pipeline.GrayImage {
        let box = page.visibleSize
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
            // getDrawingTransform is asked only for rotation and origin, at
            // natural (point) size, and the dpi scale is applied here:
            // observed not to scale up (PDFRenderTests), which its page
            // doesn't promise either way. It clips the crop box to the
            // media box itself, matching visibleSize.
            ctx.concatenate(CGAffineTransform(scaleX: scale, y: scale))
            ctx.concatenate(
                page.getDrawingTransform(
                    .cropBox, rect: CGRect(x: 0, y: 0, width: box.width, height: box.height),
                    rotate: 0, preserveAspectRatio: true
                )
            )
            ctx.drawPDFPage(page)
        }
        return Pipeline.GrayImage(width: w, height: h, pixels: pixels)
    }
}
