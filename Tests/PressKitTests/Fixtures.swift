import CoreGraphics
import CoreText
import Foundation
import XCTest

@testable import PressKit

/// Deterministic pseudo-random generator so fixture images are stable.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64 = 0x5EED) {
        state = seed
    }
    mutating func next() -> UInt8 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: state >> 33)
    }
}

/// Base class giving every suite the same fresh-temp-dir lifecycle.
class FixtureTestCase: XCTestCase {
    var dir: URL!

    override func setUp() {
        super.setUp()
        dir = Fixtures.tempDir()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }
}

enum Fixtures {
    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PressKitTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A text-like page: white paper, black paragraph blocks, mild paper
    /// noise (keeps the JPEG fixture realistically large without pushing
    /// the classifier away from "text").
    static func textPage(width: Int = 600, height: Int = 800, noise: Bool = false)
        -> Pipeline.GrayImage
    {
        var pixels = [UInt8](repeating: 250, count: width * height)
        if noise {
            var rng = SeededRandom()
            for i in 0..<pixels.count {
                pixels[i] = 244 &+ (rng.next() % 12)
            }
        }
        // "Paragraphs": rows of short black dashes.
        for line in stride(from: 60, to: height - 60, by: 24) {
            for y in line..<(line + 10) {
                var x = 50
                var rng = SeededRandom(seed: UInt64(line))
                while x < width - 50 {
                    let dash = 12 + Int(rng.next() % 30)
                    for dx in 0..<dash where x + dx < width - 50 {
                        pixels[y * width + x + dx] = 15
                    }
                    x += dash + 8 + Int(rng.next() % 10)
                }
            }
        }
        return Pipeline.GrayImage(width: width, height: height, pixels: pixels)
    }

    /// Deterministic page for pixel-exact assertions: plain paper with one
    /// solid interior paragraph block at (150..<450, 300..<340).
    static func blockPage(width: Int = 600, height: Int = 800) -> Pipeline.GrayImage {
        var pixels = [UInt8](repeating: 250, count: width * height)
        for y in 300..<340 {
            for x in 150..<450 {
                pixels[y * width + x] = 20
            }
        }
        return Pipeline.GrayImage(width: width, height: height, pixels: pixels)
    }

    /// Paint a dark scan-style band down the left edge of a page.
    static func addLeftBand(
        to page: inout Pipeline.GrayImage, widthPx: Int, level: UInt8
    ) {
        for y in 0..<page.height {
            for x in 0..<widthPx {
                page.pixels[y * page.width + x] = level
            }
        }
    }

    /// A continuous-tone page: smooth diagonal gradient.
    static func photoPage(width: Int = 600, height: Int = 800) -> Pipeline.GrayImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = UInt8((x + y) * 255 / (width + height))
            }
        }
        return Pipeline.GrayImage(width: width, height: height, pixels: pixels)
    }

    /// Wrap grayscale pages as a "scanned" PDF: one full-page JPEG per page.
    static func scannedPDF(pages: [Pipeline.GrayImage], dpi: Int, quality: Double = 0.95)
        -> Data
    {
        PDFWriter.build(
            pages: pages.map { g in
                PDFWriter.Page(
                    content: .jpegGray(
                        g.jpegData(quality: quality, dpi: dpi)!,
                        width: g.width, height: g.height
                    ),
                    dpi: dpi
                )
            }
        )
    }

    /// A PDF whose pages are already 1-bit CCITT G4 — encoded through the
    /// same path the product uses, so the fixture can't drift from real
    /// output.
    static func g4PDF(pages: [Pipeline.GrayImage], dpi: Int) throws -> Data {
        PDFWriter.build(
            pages: try pages.map { g in
                PDFWriter.Page(
                    content: .g4(try Converter.encodeG4(g, dpi: dpi)),
                    dpi: dpi
                )
            }
        )
    }

    /// A born-digital PDF: vector rectangles drawn straight into a PDF
    /// context, no raster images at all.
    static func bornDigitalPDF() -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = CGDataConsumer(data: data)!
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(gray: 0, alpha: 1)
        for line in stride(from: 60, to: 780, by: 24) {
            ctx.fill(CGRect(x: 50, y: CGFloat(line), width: 495, height: 10))
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    @discardableResult
    static func write(_ data: Data, to dir: URL, name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }

    /// The line renderedTextPage repeats — tests asserting on OCR output
    /// derive their expected words from here.
    static let sampleText = "DOMESTIC APPLIANCE REPAIRS TEL: 0115 2896529 MOB: 07711 265414 "

    /// Real rendered type on paper — glyph shapes matter for the damage
    /// metric in ways regular synthetic patterns can't reproduce.
    /// `ink` is the text gray (0 = black); page is 620×800 at "native" scale.
    static func renderedTextPage(fontSize: CGFloat, ink: CGFloat) -> Pipeline.GrayImage {
        let w = 620, h = 800
        var px = [UInt8](repeating: 250, count: w * h)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: 250 / 255.0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: ink, alpha: 1),
            ]
            let sample = Fixtures.sampleText
            var y = CGFloat(20)
            while y < CGFloat(h) - 20 {
                let line = CTLineCreateWithAttributedString(
                    CFAttributedStringCreate(
                        nil, (sample + sample) as CFString, attrs as CFDictionary)!)
                ctx.textPosition = CGPoint(x: 15, y: y)
                CTLineDraw(line, ctx)
                y += fontSize * 1.6
            }
        }
        return Pipeline.GrayImage(width: w, height: h, pixels: px)
    }

    /// Create an empty placeholder file (with intermediate directories) —
    /// enough for FolderScanner tests, which never open the files.
    @discardableResult
    static func touch(_ path: String, in dir: URL) -> URL {
        let url = dir.appendingPathComponent(path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }
}
