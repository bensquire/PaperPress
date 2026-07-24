import CoreGraphics
import XCTest

@testable import PressKit

final class Gray4Tests: FixtureTestCase {
    func test_encode_oddWidthPage_roundTrips() throws {
        // Arrange — odd width exercises the half-byte row packing
        let page = Fixtures.photoPage(width: 301, height: 40)
        let pdf = PDFWriter.build(
            pages: [PDFWriter.Page(content: .gray4Flate(Gray4.encode(page)), dpi: 150)]
        )
        let url = Fixtures.write(pdf, to: dir, name: "odd.pdf")

        // Act
        let doc = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let rendered = try PDFRender.gray(page: try XCTUnwrap(doc.page(at: 1)), dpi: 150)

        // Assert
        XCTAssertEqual(rendered.width, 301)
        var worst = 0
        for i in 0..<page.pixels.count {
            worst = max(worst, abs(Int(page.pixels[i]) - Int(rendered.pixels[i])))
        }
        XCTAssertLessThan(worst, 24)
    }

    func test_encode_roundTripsThroughPDFWithinQuantizationError() throws {
        // Arrange — a page with smooth tones and text
        let page = Fixtures.photoPage(width: 300, height: 400)
        let pdf = PDFWriter.build(
            pages: [PDFWriter.Page(content: .gray4Flate(Gray4.encode(page)), dpi: 150)]
        )
        let url = Fixtures.write(pdf, to: dir, name: "g4bit.pdf")

        // Act — render the written PDF back at the same resolution
        let doc = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let rendered = try PDFRender.gray(page: try XCTUnwrap(doc.page(at: 1)), dpi: 150)

        // Assert — same dimensions, and pixels within quantization step
        // (17 levels apart) plus rendering tolerance
        XCTAssertEqual(rendered.width, page.width)
        XCTAssertEqual(rendered.height, page.height)
        var worst = 0
        for i in 0..<page.pixels.count {
            worst = max(worst, abs(Int(page.pixels[i]) - Int(rendered.pixels[i])))
        }
        XCTAssertLessThan(worst, 24, "4-bit round trip should stay within ~one level")
    }
}
