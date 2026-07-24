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

    func test_convert_ontoItsOwnSource_throwsAndLeavesOriginalIntact() throws {
        // Arrange — output path == source path (loose file, parent chosen
        // as the output folder)
        let data = Fixtures.bornDigitalPDF()
        let src = Fixtures.write(data, to: dir, name: "loose.pdf")
        let report = try PDFInspector.inspect(src)

        // Act / Assert
        XCTAssertThrowsError(
            try Converter.convert(report: report, to: src, settings: noOCR)
        )
        XCTAssertEqual(try Data(contentsOf: src), data)
    }

    /// A 75 dpi text source — demoted by the resolution gate (the damage
    /// backstop is covered at the Binarize unit level).
    private func lowResTextReport() throws -> PDFInspector.Report {
        let tiny = Fixtures.renderedTextPage(fontSize: 4, ink: 0.3)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [tiny], dpi: 75), to: dir, name: "tiny.pdf"
        )
        return try PDFInspector.inspect(src)
    }

    func test_convert_demotedTextPage_usesGray4ByDefault() throws {
        // Arrange
        let out = dir.appendingPathComponent("out/tiny.pdf")
        var settings = noOCR
        settings.minSavingFraction = -1

        // Act
        let result = try Converter.convert(
            report: try lowResTextReport(), to: out, settings: settings
        )

        // Assert — demoted, and encoded as 4-bit Flate, not JPEG
        XCTAssertEqual(result.pageKinds, [.photo])
        let written = try Data(contentsOf: out)
        XCTAssertNotNil(written.range(of: Data("/BitsPerComponent 4".utf8)))
        XCTAssertNil(written.range(of: Data("DCTDecode".utf8)))
    }

    func test_convert_lowResTextPage_staysGrayscaleEvenWhenCrisp() throws {
        // Arrange — large clean type, but a 75 dpi source: the resolution
        // gate demotes without consulting the damage metric (three
        // calibration rounds showed 75 dpi sources always degrade
        // somewhere on the page)
        let crisp = Fixtures.renderedTextPage(fontSize: 20, ink: 0.1)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [crisp], dpi: 75), to: dir, name: "crisp75.pdf"
        )
        let out = dir.appendingPathComponent("out/crisp75.pdf")
        let report = try PDFInspector.inspect(src)
        var settings = noOCR
        settings.minSavingFraction = -1

        // Act
        let result = try Converter.convert(report: report, to: out, settings: settings)

        // Assert
        XCTAssertEqual(result.pageKinds, [.photo])
        XCTAssertNil(
            try Data(contentsOf: out).range(of: Data("CCITTFaxDecode".utf8))
        )
    }

    func test_convert_demotedTextPage_respectsJPEGSetting() throws {
        // Arrange
        let out = dir.appendingPathComponent("out/tiny.pdf")
        var settings = noOCR
        settings.minSavingFraction = -1
        settings.demotedTextFormat = .jpeg

        // Act
        _ = try Converter.convert(
            report: try lowResTextReport(), to: out, settings: settings
        )

        // Assert
        let written = try Data(contentsOf: out)
        XCTAssertNotNil(written.range(of: Data("DCTDecode".utf8)))
        XCTAssertNil(written.range(of: Data("/BitsPerComponent 4".utf8)))
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

final class FolderScannerItemsTests: FixtureTestCase {
    private func touch(_ path: String) -> URL {
        Fixtures.touch(path, in: dir)
    }

    func test_items_mixedFolderAndLooseFile_expandsBoth() {
        // Arrange
        _ = touch("Folder/inner/a.pdf")
        let loose = touch("elsewhere/loose.pdf")

        // Act
        let items = FolderScanner.items(
            for: [dir.appendingPathComponent("Folder"), loose]
        )

        // Assert — multi-source, so the folder's items carry its name
        XCTAssertEqual(items.map(\.relativePath), ["Folder/inner/a.pdf", "loose.pdf"])
    }

    func test_items_singleFolder_keepsUnprefixedMirroring() {
        // Arrange
        _ = touch("Folder/inner/a.pdf")

        // Act
        let items = FolderScanner.items(for: [dir.appendingPathComponent("Folder")])

        // Assert
        XCTAssertEqual(items.map(\.relativePath), ["inner/a.pdf"])
    }

    func test_items_duplicateNames_getNumberedSuffix() {
        // Arrange — two loose files with the same name from different folders
        let one = touch("one/scan.pdf")
        let two = touch("two/scan.pdf")

        // Act
        let items = FolderScanner.items(for: [one, two])

        // Assert
        XCTAssertEqual(items.map(\.relativePath).sorted(), ["scan-2.pdf", "scan.pdf"])
    }

    func test_items_sameSourceTwice_isDeduped() {
        // Arrange — a file dropped directly AND inside a dropped folder
        let inFolder = touch("Folder/doc.pdf")

        // Act
        let items = FolderScanner.items(
            for: [dir.appendingPathComponent("Folder"), inFolder]
        )

        // Assert
        XCTAssertEqual(items.count, 1)
    }

    func test_items_nonPDFLooseFile_isIgnored() {
        // Arrange
        let txt = touch("notes.txt")

        // Act
        let items = FolderScanner.items(for: [txt])

        // Assert
        XCTAssertTrue(items.isEmpty)
    }

    func test_items_mergingExistingSource_isDeduped() {
        // Arrange — batch already contains the file
        let loose = touch("doc.pdf")
        let existing = FolderScanner.items(for: [loose])

        // Act — same file dropped again
        let added = FolderScanner.items(for: [loose], merging: existing)

        // Assert
        XCTAssertTrue(added.isEmpty)
    }

    func test_items_mergingNameCollision_getsSuffixNotDropped() {
        // Arrange — a different file that shares a name with an existing row
        let first = touch("one/scan.pdf")
        let second = touch("two/scan.pdf")
        let existing = FolderScanner.items(for: [first])

        // Act
        let added = FolderScanner.items(for: [second], merging: existing)

        // Assert
        XCTAssertEqual(added.map(\.relativePath), ["scan-2.pdf"])
    }

    func test_items_folderAppendedToBatch_isPrefixed() {
        // Arrange — a non-empty batch makes any later folder multi-source
        let loose = touch("loose.pdf")
        _ = touch("Folder/a.pdf")
        let existing = FolderScanner.items(for: [loose])

        // Act — single folder, but appended
        let added = FolderScanner.items(
            for: [dir.appendingPathComponent("Folder")], merging: existing
        )

        // Assert
        XCTAssertEqual(added.map(\.relativePath), ["Folder/a.pdf"])
    }
}

final class FolderScannerTests: FixtureTestCase {
    func test_pdfs_findsNestedPDFsWithRelativePathsSorted() throws {
        // Arrange
        let root: URL = dir
        for path in ["a.pdf", "b/inner/c.pdf", "b/d.PDF", "note.txt", ".hidden.pdf"] {
            Fixtures.touch(path, in: root)
        }

        // Act
        let items = FolderScanner.pdfs(under: root)

        // Assert
        XCTAssertEqual(items.map(\.relativePath), ["a.pdf", "b/d.PDF", "b/inner/c.pdf"])
    }
}
