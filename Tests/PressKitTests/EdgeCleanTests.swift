import XCTest

@testable import PressKit

final class EdgeCleanTests: XCTestCase {
    /// 600×800 page at 300 dpi: 10mm band ≈ 118px.
    private func page() -> Pipeline.GrayImage {
        Fixtures.blockPage()
    }

    func test_removeScanBorders_whitensEdgeBand() {
        // Arrange — a 30px black band down the left edge (scan artifact)
        var g = page()
        for y in 0..<800 {
            for x in 0..<30 {
                g.pixels[y * 600 + x] = 10
            }
        }

        // Act
        EdgeClean.removeScanBorders(&g, dpi: 300)

        // Assert — band gone, interior content untouched
        XCTAssertGreaterThan(g.pixels[400 * 600 + 10], 200, "edge band should be whitened")
        XCTAssertLessThan(g.pixels[320 * 600 + 300], 50, "content should survive")
    }

    func test_removeScanBorders_keepsContentReachingTheEdge() {
        // Arrange — a full-width horizontal rule that touches both side
        // edges mid-page (like a receipt-pad line): its pixels extend far
        // beyond the edge band, so it must be kept
        var g = page()
        for y in 500..<504 {
            for x in 0..<600 {
                g.pixels[y * 600 + x] = 30
            }
        }

        // Act
        EdgeClean.removeScanBorders(&g, dpi: 300)

        // Assert
        XCTAssertLessThan(g.pixels[502 * 600 + 300], 60, "full-width rule should survive")
        XCTAssertLessThan(g.pixels[502 * 600 + 2], 60, "even at the edge itself")
    }

    func test_removeScanBorders_cleanPage_isUntouched() {
        // Arrange
        var g = page()
        let before = g.pixels

        // Act
        EdgeClean.removeScanBorders(&g, dpi: 300)

        // Assert
        XCTAssertEqual(g.pixels, before)
    }
}

final class EdgeCleanConverterTests: FixtureTestCase {
    func test_convert_lowResTextPageWithEdgeBand_isCleanedInOutput() throws {
        // Arrange — a 75 dpi text page with a black scan band down the
        // left edge: the resolution gate demotes it to grayscale, and the
        // band must still be cleaned on that path
        var page = Fixtures.textPage(width: 620, height: 800, noise: true)
        for y in 0..<800 {
            for x in 0..<12 {
                page.pixels[y * 620 + x] = 10
            }
        }
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 75), to: dir, name: "band.pdf"
        )
        let out = dir.appendingPathComponent("out/band.pdf")
        let report = try PDFInspector.inspect(src)
        var settings = Converter.Settings()
        settings.ocr = false
        settings.minSavingFraction = -1

        // Act
        _ = try Converter.convert(report: report, to: out, settings: settings)

        // Assert — the written page's left edge is paper, not band
        let doc = try XCTUnwrap(CGPDFDocument(out as CFURL))
        let rendered = try PDFRender.gray(page: try XCTUnwrap(doc.page(at: 1)), dpi: 75)
        var darkEdge = 0
        for y in 0..<rendered.height {
            if rendered.pixels[y * rendered.width + 4] < 100 { darkEdge += 1 }
        }
        XCTAssertLessThan(
            darkEdge, rendered.height / 20,
            "edge band should be whitened in the demoted grayscale output"
        )
    }
}
