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
        XCTAssertGreaterThan(
            report.fileBytes, PDFInspector.smallEnoughBytesPerPage,
            "fixture sanity: \(report.fileBytes) bytes is already small")
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
        XCTAssertFalse(compact, "an 8-bit JPEG scan isn't archival-compact")
    }

    func test_inspect_rotatedScanPage_isStillAScan() throws {
        // Arrange — a 300 dpi scan whose page is shown rotated, as Preview
        // writes it after "Rotate Left"
        let page = Fixtures.textPage(width: 2480, height: 3508, noise: true)
        let upright = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 300), to: dir, name: "upright.pdf"
        )
        let rotated = Fixtures.edited(upright, as: "rotated.pdf") { $0.rotation = 90 }

        // Act
        let report = try PDFInspector.inspect(rotated)

        // Assert
        XCTAssertEqual(report.pages.map(\.kind), [.scan(dpi: 300, compact: false)])
        XCTAssertEqual(report.verdict, .convert)
    }

    func test_inspect_photoPage_isEstimatedAsAPhotograph() throws {
        // Arrange — a continuous-tone page, which the converter keeps as JPEG
        let page = Fixtures.photoPage(width: 1240, height: 1754)
        let url = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 150), to: dir, name: "photo.pdf")

        // Act
        let report = try PDFInspector.inspect(url)

        // Assert — estimated as the photograph it is, not as 1-bit text
        XCTAssertEqual(report.verdict, .convert, "fixture sanity")
        XCTAssertEqual(
            report.estimatedBytes,
            PDFInspector.estimatedPageBytes(report.pages[0], photographic: 1),
            "the estimate should be the photograph's")
        XCTAssertNotEqual(
            report.estimatedBytes, PDFInspector.estimatedPageBytes(report.pages[0]),
            "estimated as a 1-bit text page")
    }

    func test_inspect_textPage_isEstimatedFromItsInk() async throws {
        // Arrange — a dense page of small type, scanned at 150 dpi
        let url = Fixtures.write(
            Fixtures.scannedPDF(pages: [Fixtures.renderedTextPage(fontSize: 9, ink: 0.1)], dpi: 150),
            to: dir, name: "dense.pdf")
        let out = dir.appendingPathComponent("out.pdf")

        // Act
        let report = try PDFInspector.inspect(url)
        let converted = try await Converter.convert(report: report, to: out)

        // Assert — near what converting writes (a flat rate a pixel was
        // well under it)
        guard case .converted([.g4]) = converted.outcome else {
            return XCTFail("fixture should convert to 1-bit, got \(converted.outcome)")
        }
        let ratio = Double(report.estimatedBytes) / Double(converted.outputBytes)
        XCTAssertEqual(
            ratio, 1, accuracy: 0.3, "estimated \(report.estimatedBytes), wrote \(converted.outputBytes)")
    }

    func test_inspect_g4PDF_passesThroughAsAlreadyCompact() throws {
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

    /// Convert the canonical low-res scan and return the written output.
    private func convertOwnOutput(
        format: Converter.DemotedTextFormat = .gray4
    ) async throws -> URL {
        let src = Fixtures.write(Fixtures.lowResTextScanPDF(), to: dir, name: "src.pdf")
        let out = dir.appendingPathComponent("out/src.pdf")
        var settings = Converter.Settings()
        settings.ocr = false
        settings.minSavingFraction = -1
        settings.demotedTextFormat = format
        _ = try await Converter.convert(
            report: try PDFInspector.inspect(src), to: out, settings: settings
        )
        return out
    }

    func test_inspect_ownConvertedOutput_passesThroughAsAlreadyProcessed() async throws {
        // Arrange — convert a low-res text scan (demotes to 4-bit gray)
        let out = try await convertOwnOutput()

        // Act — re-analyse the output, as a second app run would
        let report = try PDFInspector.inspect(out)

        // Assert — idempotent: never re-compress our own output
        XCTAssertEqual(report.verdict, .passThrough(.alreadyProcessed))
    }

    func test_inspect_ownJPEGOutput_passesThroughAsAlreadyProcessed() async throws {
        // Arrange — same, with the JPEG demoted-format setting
        let out = try await convertOwnOutput(format: .jpeg)

        // Act
        let report = try PDFInspector.inspect(out)

        // Assert
        XCTAssertEqual(report.verdict, .passThrough(.alreadyProcessed))
    }

    func test_inspect_foreignGray4PDF_passesThroughAsAlreadyCompact() throws {
        // Arrange — a 4-bit page from another producer (no marker)
        let page = Fixtures.photoPage(width: 620, height: 800)
        let pdf = try PDFWriter.build(
            pages: [PDFWriter.Page(content: .gray4Flate(try Gray4.encode(page)), dpi: 75)],
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
