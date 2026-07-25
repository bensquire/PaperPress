import CoreGraphics
import XCTest

@testable import PressKit

final class Gray4Tests: FixtureTestCase {
    /// Encode → embed in a PDF → render back; the worst pixel error must
    /// stay within one 17-gray quantization step plus render tolerance.
    private func assertGray4RoundTrips(
        _ page: Pipeline.GrayImage, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let pdf = PDFWriter.build(
            pages: [PDFWriter.Page(content: .gray4Flate(Gray4.encode(page)), dpi: 150)]
        )
        let url = Fixtures.write(pdf, to: dir, name: "roundtrip.pdf")
        let doc = try XCTUnwrap(CGPDFDocument(url as CFURL), file: file, line: line)
        let rendered = try PDFRender.gray(page: try XCTUnwrap(doc.page(at: 1)), dpi: 150)
        XCTAssertEqual(rendered.width, page.width, file: file, line: line)
        XCTAssertEqual(rendered.height, page.height, file: file, line: line)
        var worst = 0
        for i in 0..<page.pixels.count {
            worst = max(worst, abs(Int(page.pixels[i]) - Int(rendered.pixels[i])))
        }
        XCTAssertLessThan(worst, 24, file: file, line: line)
    }

    func test_encode_roundTripsThroughPDFWithinQuantizationError() throws {
        // Arrange / Act / Assert — smooth tones exercise every gray level
        try assertGray4RoundTrips(Fixtures.photoPage(width: 300, height: 400))
    }

    func test_encode_oddWidthPage_roundTrips() throws {
        // Arrange / Act / Assert — odd width exercises half-byte packing
        try assertGray4RoundTrips(Fixtures.photoPage(width: 301, height: 40))
    }
}
