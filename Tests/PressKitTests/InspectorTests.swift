import XCTest

@testable import PressKit

final class PDFInspectorTests: FixtureTestCase {
    func test_inspect_bornDigitalPDF_passesThrough() throws {
        // Arrange
        let url = Fixtures.write(Fixtures.bornDigitalPDF(), to: dir, name: "digital.pdf")

        // Act
        let report = try PDFInspector.inspect(url)

        // Assert
        XCTAssertEqual(report.verdict, .passThrough(.bornDigital))
        XCTAssertEqual(report.pages.map(\.kind), [.bornDigital])
    }

    func test_inspect_scannedJPEGPDF_isConvertCandidate() throws {
        // Arrange — noisy 300dpi scan-style pages, large enough to beat the
        // "already small" threshold
        let page = Fixtures.textPage(width: 2480, height: 3508, noise: true)
        let url = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 300), to: dir, name: "scan.pdf"
        )

        // Act
        let report = try PDFInspector.inspect(url)

        // Assert
        XCTAssertEqual(report.verdict, .convert)
        XCTAssertGreaterThan(report.fileBytes, PDFInspector.smallEnoughBytesPerPage)
    }

    func test_inspect_scanPage_reportsNativeDpi() throws {
        // Arrange
        let page = Fixtures.textPage(width: 1240, height: 1754, noise: true)
        let url = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 150), to: dir, name: "scan150.pdf"
        )

        // Act
        let report = try PDFInspector.inspect(url)

        // Assert
        guard case let .scan(dpi, compact) = report.pages[0].kind else {
            return XCTFail("expected a scan page, got \(report.pages[0].kind)")
        }
        XCTAssertEqual(dpi, 150)
        XCTAssertFalse(compact)
    }

    func test_inspect_g4PDF_passesThroughAsAlreadyOneBit() throws {
        // Arrange
        let page = Fixtures.textPage(width: 1240, height: 1754)
        let url = Fixtures.write(
            try Fixtures.g4PDF(pages: [page], dpi: 150), to: dir, name: "g4.pdf"
        )

        // Act
        let report = try PDFInspector.inspect(url)

        // Assert
        XCTAssertEqual(report.verdict, .passThrough(.alreadyCompact))
    }

    func test_inspect_smallScanFile_passesThroughAsAlreadySmall() throws {
        // Arrange — a genuine scan, but already compact for its page count
        // (mostly blank paper compresses well under the 45KB/page bar)
        let page = Fixtures.blockPage()
        let url = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 75, quality: 0.3),
            to: dir, name: "small.pdf"
        )
        let bytes = try Data(contentsOf: url).count
        XCTAssertLessThan(bytes, PDFInspector.smallEnoughBytesPerPage, "fixture sanity")

        // Act
        let report = try PDFInspector.inspect(url)

        // Assert
        XCTAssertEqual(report.verdict, .passThrough(.alreadySmall))
    }

    func test_inspect_ownConvertedOutput_passesThroughAsAlreadyProcessed() throws {
        // Arrange — convert a low-res text scan (demotes to 4-bit gray)
        let tiny = Fixtures.renderedTextPage(fontSize: 4, ink: 0.3)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [tiny], dpi: 75), to: dir, name: "src.pdf"
        )
        let out = dir.appendingPathComponent("out/src.pdf")
        var settings = Converter.Settings()
        settings.ocr = false
        settings.minSavingFraction = -1
        _ = try Converter.convert(
            report: try PDFInspector.inspect(src), to: out, settings: settings
        )

        // Act — re-analyse the output, as a second app run would
        let report = try PDFInspector.inspect(out)

        // Assert — idempotent: never re-compress our own output
        XCTAssertEqual(report.verdict, .passThrough(.alreadyProcessed))
    }

    func test_inspect_ownJPEGOutput_passesThroughAsAlreadyProcessed() throws {
        // Arrange — same, with the JPEG demoted-format setting
        let tiny = Fixtures.renderedTextPage(fontSize: 4, ink: 0.3)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [tiny], dpi: 75), to: dir, name: "src.pdf"
        )
        let out = dir.appendingPathComponent("out/src.pdf")
        var settings = Converter.Settings()
        settings.ocr = false
        settings.minSavingFraction = -1
        settings.demotedTextFormat = .jpeg
        _ = try Converter.convert(
            report: try PDFInspector.inspect(src), to: out, settings: settings
        )

        // Act
        let report = try PDFInspector.inspect(out)

        // Assert
        XCTAssertEqual(report.verdict, .passThrough(.alreadyProcessed))
    }

    func test_inspect_foreignGray4PDF_passesThroughAsAlreadyCompact() throws {
        // Arrange — a 4-bit page from another producer (no marker)
        let page = Fixtures.photoPage(width: 620, height: 800)
        let pdf = PDFWriter.build(
            pages: [PDFWriter.Page(content: .gray4Flate(Gray4.encode(page)), dpi: 75)],
            producer: Fixtures.foreignProducer
        )
        let url = Fixtures.write(pdf, to: dir, name: "gray4.pdf")

        // Act
        let report = try PDFInspector.inspect(url)

        // Assert
        XCTAssertEqual(report.verdict, .passThrough(.alreadyCompact))
    }

    func test_inspect_missingFile_throws() {
        // Arrange
        let url = dir.appendingPathComponent("nope.pdf")

        // Act / Assert
        XCTAssertThrowsError(try PDFInspector.inspect(url))
    }
}
