import XCTest

@testable import PressKit

final class Gray4Tests: FixtureTestCase {
    /// Encode → embed in a PDF → render back; the worst pixel error must
    /// stay within one 17-gray quantization step plus render tolerance.
    private func assertGray4RoundTrips(
        _ page: Pipeline.GrayImage, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let pdf = try PDFWriter.build(
            pages: [PDFWriter.Page(content: .gray4Flate(try Gray4.encode(page)), dpi: 150)]
        )
        let url = Fixtures.write(pdf, to: dir, name: "roundtrip.pdf")
        let rendered = try Fixtures.rendered(url, dpi: 150)
        XCTAssertEqual(rendered.width, page.width, "rendered width in pixels", file: file, line: line)
        XCTAssertEqual(rendered.height, page.height, "rendered height in pixels", file: file, line: line)
        var worst = 0
        for i in 0..<page.pixels.count {
            worst = max(worst, abs(Int(page.pixels[i]) - Int(rendered.pixels[i])))
        }
        XCTAssertLessThan(
            worst, 24, "worst pixel off by \(worst) gray levels", file: file, line: line)
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
