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
        let doc = try XCTUnwrap(CGPDFDocument(url as CFURL))

        // Act
        let gray = try PDFRender.gray(page: try XCTUnwrap(doc.page(at: 1)), dpi: 300)

        // Assert — dimensions match the dpi, and ink reaches the left tenth
        XCTAssertEqual(gray.width, 2480)
        XCTAssertEqual(gray.height, 3508)
        var leftmostInk = gray.width
        for y in 0..<gray.height {
            if let x = (0..<leftmostInk).first(where: {
                gray.pixels[y * gray.width + $0] < 100
            }) {
                leftmostInk = x
            }
        }
        XCTAssertLessThan(leftmostInk, gray.width / 10)
    }
}
