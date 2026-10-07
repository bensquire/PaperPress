import CoreGraphics
import XCTest

@testable import PressKit

final class PDFRenderTests: FixtureTestCase {
    func test_gray_rendersAtRequestedScaleNotCentredAtNaturalSize() throws {
        // Arrange — fixture dashes start 50px in from the page edge, so a
        // correct render has ink near the margins; getDrawingTransform's
        // refusal to upscale would leave it centred at quarter size
        let page = Fixtures.textPage(width: 2480, height: 3508)
        let url = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 300), to: dir, name: "p.pdf"
        )
        let doc = try XCTUnwrap(CGPDFDocument(url as CFURL), "the fixture doesn't open")
        let pdfPage = try XCTUnwrap(doc.page(at: 1), "the fixture has no page 1")

        // Act
        let gray = try PDFRender.gray(page: pdfPage, dpi: 300)

        // Assert — dimensions match the dpi, and ink reaches the left tenth
        XCTAssertEqual(gray.width, 2480, "width in pixels at 300 dpi")
        XCTAssertEqual(gray.height, 3508, "height in pixels at 300 dpi")
        var leftmostInk = gray.width
        for y in 0..<gray.height {
            if let x = (0..<leftmostInk).first(where: {
                gray.pixels[y * gray.width + $0] < 100
            }) {
                leftmostInk = x
            }
        }
        XCTAssertLessThan(
            leftmostInk, gray.width / 10, "leftmost ink at x = \(leftmostInk) px: drawn centred and small?")
    }

    func test_gray_croppedPage_rendersOnlyTheVisibleArea() throws {
        // Arrange — the page's only ink sits outside a 100 × 100 pt crop
        let full = Fixtures.write(
            Fixtures.scannedPDF(pages: [Fixtures.blockPage()], dpi: 72), to: dir, name: "p.pdf"
        )
        let cropped = Fixtures.edited(full, as: "c.pdf") {
            $0.setBounds(CGRect(x: 0, y: 0, width: 100, height: 100), for: .cropBox)
        }
        let doc = try XCTUnwrap(CGPDFDocument(cropped as CFURL), "the cropped fixture doesn't open")
        let pdfPage = try XCTUnwrap(doc.page(at: 1), "the cropped fixture has no page 1")

        // Act
        let gray = try PDFRender.gray(page: pdfPage, dpi: 72)

        // Assert — crop-sized, and none of the hidden ink
        XCTAssertEqual(gray.width, 100, "width in pixels: the crop's 100 pt at 72 dpi")
        XCTAssertEqual(gray.height, 100, "height in pixels: the crop's 100 pt at 72 dpi")
        XCTAssertTrue(gray.pixels.allSatisfy { $0 > 200 }, "hidden ink should not render")
    }

    func test_gray_aboveScanResolution_enlargesToTheSameSize() throws {
        // Arrange — a 150 dpi scan
        let url = Fixtures.write(
            Fixtures.scannedPDF(pages: [Fixtures.textPage(width: 301, height: 403)], dpi: 150),
            to: dir, name: "p.pdf")
        let page = try XCTUnwrap(CGPDFDocument(url as CFURL)?.page(at: 1), "the fixture has no page 1")

        // Act
        let drawn = try PDFRender.gray(page: page, dpi: 300)
        let enlarged = try PDFRender.gray(page: page, dpi: 300, sourceDpi: 150)

        // Assert — the converter's pages keep their geometry
        XCTAssertEqual(enlarged.width, drawn.width, "enlarged width against Quartz's, in pixels")
        XCTAssertEqual(enlarged.height, drawn.height, "enlarged height against Quartz's, in pixels")
    }

    func test_gray_aboveScanResolution_givesTruer1BitEdges() throws {
        // Arrange — small type at 300 dpi, scanned at 150
        let truth = Fixtures.renderedTextPage(fontSize: 30, ink: 0)
        let url = Fixtures.write(
            Fixtures.scannedPDF(pages: [truth.resampled(scale: 0.5)], dpi: 150), to: dir, name: "p.pdf")
        let page = try XCTUnwrap(CGPDFDocument(url as CFURL)?.page(at: 1), "the fixture has no page 1")
        func offOutline(_ gray: Pipeline.GrayImage) -> Int {
            let bw = Binarize.sauvola(gray, dpi: 300)
            return zip(bw.ink, truth.pixels).filter { $0 != ($1 < 128) }.count
        }

        // Act
        let quartz = offOutline(try PDFRender.gray(page: page, dpi: 300))
        let lanczos = offOutline(try PDFRender.gray(page: page, dpi: 300, sourceDpi: 150))

        // Assert — fewer pixels on the wrong side of the letters' outlines
        // than Quartz enlarging the scan as it draws
        XCTAssertLessThan(
            Double(lanczos), Double(quartz) * 0.95,
            "pixels off the outlines: \(lanczos) enlarged first, \(quartz) drawn by Quartz")
    }
}
