import XCTest

@testable import PressKit

final class ConverterTests: FixtureTestCase {
    private var noOCR: Converter.Settings {
        var s = Converter.Settings()
        s.ocr = false
        return s
    }

    func test_convert_scannedTextPDF_producesSmallerG4PDF() throws {
        // Arrange
        let page = Fixtures.textPage(width: 2480, height: 3508, noise: true)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 300), to: dir, name: "scan.pdf"
        )
        let out = dir.appendingPathComponent("out/scan.pdf")
        let report = try PDFInspector.inspect(src)

        // Act
        let result = try Converter.convert(report: report, to: out, settings: noOCR)

        // Assert
        XCTAssertTrue(result.converted)
        XCTAssertLessThan(result.outputBytes, result.inputBytes / 2)
        XCTAssertEqual(result.pageKinds, [.text])
        let written = try Data(contentsOf: out)
        XCTAssertNotNil(
            written.range(of: Data("CCITTFaxDecode".utf8)),
            "converted page should be G4-encoded"
        )
    }

    func test_convert_photoPage_staysJPEG() throws {
        // Arrange
        let page = Fixtures.photoPage(width: 1240, height: 1754)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 150), to: dir, name: "photo.pdf"
        )
        let out = dir.appendingPathComponent("out/photo.pdf")
        let report = try PDFInspector.inspect(src)
        var settings = noOCR
        settings.minSavingFraction = -1  // accept any size for this encoding check

        // Act
        let result = try Converter.convert(report: report, to: out, settings: settings)

        // Assert
        XCTAssertEqual(result.pageKinds, [.photo])
        let written = try Data(contentsOf: out)
        XCTAssertNotNil(
            written.range(of: Data("DCTDecode".utf8)),
            "photo page should stay JPEG"
        )
        XCTAssertNil(written.range(of: Data("CCITTFaxDecode".utf8)))
    }

    func test_convert_passThroughVerdict_copiesFileByteIdentical() throws {
        // Arrange
        let data = Fixtures.bornDigitalPDF()
        let src = Fixtures.write(data, to: dir, name: "digital.pdf")
        let out = dir.appendingPathComponent("out/sub/digital.pdf")
        let report = try PDFInspector.inspect(src)

        // Act
        let result = try Converter.convert(report: report, to: out, settings: noOCR)

        // Assert
        XCTAssertFalse(result.converted)
        XCTAssertEqual(try Data(contentsOf: out), data)
    }

    func test_convert_insufficientSaving_fallsBackToCopy() throws {
        // Arrange — require a saving G4 can't reach (>99.99%; the PDF
        // skeleton alone is bigger than that budget)
        let page = Fixtures.textPage(width: 1240, height: 1754, noise: true)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 150), to: dir, name: "scan.pdf"
        )
        let srcData = try Data(contentsOf: src)
        let out = dir.appendingPathComponent("out/scan.pdf")
        let report = try PDFInspector.inspect(src)
        var settings = noOCR
        settings.minSavingFraction = 0.9999

        // Act
        let result = try Converter.convert(report: report, to: out, settings: settings)

        // Assert
        XCTAssertFalse(result.converted)
        XCTAssertEqual(try Data(contentsOf: out), srcData)
    }

    func test_convert_dpiCap_downsamplesHighResScan() throws {
        // Arrange — 600dpi source, capped to 150
        let page = Fixtures.textPage(width: 2480, height: 3508, noise: true)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 600), to: dir, name: "hires.pdf"
        )
        let out = dir.appendingPathComponent("out/hires.pdf")
        let report = try PDFInspector.inspect(src)
        var settings = noOCR
        settings.dpiCap = 150
        settings.minSavingFraction = -1

        // Act
        _ = try Converter.convert(report: report, to: out, settings: settings)

        // Assert — rebuilt page images are 150dpi-sized (620px wide, in the
        // XObject header), not 2480
        let written = try Data(contentsOf: out)
        XCTAssertNotNil(written.range(of: Data("/Width 620".utf8)))
        XCTAssertNil(written.range(of: Data("/Width 2480".utf8)))
    }

    func test_convert_preservesSourceModificationDate() throws {
        // Arrange
        let page = Fixtures.textPage(width: 2480, height: 3508, noise: true)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 300), to: dir, name: "dated.pdf"
        )
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: past], ofItemAtPath: src.path
        )
        let out = dir.appendingPathComponent("out/dated.pdf")
        let report = try PDFInspector.inspect(src)

        // Act
        _ = try Converter.convert(report: report, to: out, settings: noOCR)

        // Assert
        let outDate =
            try FileManager.default.attributesOfItem(atPath: out.path)[.modificationDate]
            as? Date
        XCTAssertEqual(outDate, past)
    }
}

final class FolderScannerTests: FixtureTestCase {
    func test_pdfs_findsNestedPDFsWithRelativePathsSorted() throws {
        // Arrange
        let root: URL = dir
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("b/inner"), withIntermediateDirectories: true
        )
        for path in ["a.pdf", "b/inner/c.pdf", "b/d.PDF", "note.txt", ".hidden.pdf"] {
            fm.createFile(atPath: root.appendingPathComponent(path).path, contents: Data())
        }

        // Act
        let items = FolderScanner.pdfs(under: root)

        // Assert
        XCTAssertEqual(items.map(\.relativePath), ["a.pdf", "b/d.PDF", "b/inner/c.pdf"])
    }
}
