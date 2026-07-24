import XCTest

@testable import PressKit

final class PDFInspectorTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        super.setUp()
        dir = Fixtures.tempDir()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

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
        guard case let .scan(dpi, oneBit) = report.pages[0].kind else {
            return XCTFail("expected a scan page, got \(report.pages[0].kind)")
        }
        XCTAssertEqual(dpi, 150)
        XCTAssertFalse(oneBit)
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
        XCTAssertEqual(report.verdict, .passThrough(.alreadyOneBit))
    }

    func test_inspect_missingFile_throws() {
        // Arrange
        let url = dir.appendingPathComponent("nope.pdf")

        // Act / Assert
        XCTAssertThrowsError(try PDFInspector.inspect(url))
    }
}
