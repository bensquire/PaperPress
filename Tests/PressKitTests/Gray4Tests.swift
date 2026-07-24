import CoreGraphics
import XCTest

@testable import PressKit

final class Gray4Tests: FixtureTestCase {
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

    func test_convert_demotedTextPage_usesGray4ByDefault() throws {
        // Arrange — tiny print at low resolution forces demotion
        let tiny = Fixtures.renderedTextPage(fontSize: 4, ink: 0.3)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [tiny], dpi: 75), to: dir, name: "tiny.pdf"
        )
        let out = dir.appendingPathComponent("out/tiny.pdf")
        let report = try PDFInspector.inspect(src)
        var settings = Converter.Settings()
        settings.ocr = false
        settings.minSavingFraction = -1

        // Act
        let result = try Converter.convert(report: report, to: out, settings: settings)

        // Assert — demoted, and encoded as 4-bit Flate, not JPEG
        XCTAssertEqual(result.pageKinds, [.photo])
        let written = try Data(contentsOf: out)
        XCTAssertNotNil(written.range(of: Data("/BitsPerComponent 4".utf8)))
        XCTAssertNil(written.range(of: Data("DCTDecode".utf8)))
    }

    func test_convert_demotedTextPage_respectsJPEGSetting() throws {
        // Arrange
        let tiny = Fixtures.renderedTextPage(fontSize: 4, ink: 0.3)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [tiny], dpi: 75), to: dir, name: "tiny.pdf"
        )
        let out = dir.appendingPathComponent("out/tiny.pdf")
        let report = try PDFInspector.inspect(src)
        var settings = Converter.Settings()
        settings.ocr = false
        settings.minSavingFraction = -1
        settings.demotedTextFormat = .jpeg

        // Act
        _ = try Converter.convert(report: report, to: out, settings: settings)

        // Assert
        let written = try Data(contentsOf: out)
        XCTAssertNotNil(written.range(of: Data("DCTDecode".utf8)))
        XCTAssertNil(written.range(of: Data("/BitsPerComponent 4".utf8)))
    }
}
