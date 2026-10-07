import XCTest

@testable import PressKit

final class ConverterTests: FixtureTestCase {
    private var noOCR: Converter.Settings {
        var s = Converter.Settings()
        s.ocr = false
        return s
    }

    /// No OCR, and any size accepted: for tests about what a page becomes.
    private var anySaving: Converter.Settings {
        var s = noOCR
        s.minSavingFraction = -1
        return s
    }

    func test_convert_scannedTextPDF_producesSmallerG4PDF() async throws {
        // Arrange
        let page = Fixtures.textPage(width: 2480, height: 3508, noise: true)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 300), to: dir, name: "scan.pdf"
        )
        let out = dir.appendingPathComponent("out/scan.pdf")
        let report = try PDFInspector.inspect(src)

        // Act
        let result = try await Converter.convert(report: report, to: out, settings: noOCR)

        // Assert
        XCTAssertTrue(result.converted)
        XCTAssertLessThan(result.outputBytes, result.inputBytes / 2)
        XCTAssertEqual(result.outcome, .converted([.g4]))
        let written = try Data(contentsOf: out)
        XCTAssertNotNil(
            written.range(of: Data("CCITTFaxDecode".utf8)),
            "converted page should be G4-encoded"
        )
    }

    func test_convert_photoPage_staysJPEG() async throws {
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
        let result = try await Converter.convert(report: report, to: out, settings: settings)

        // Assert
        XCTAssertEqual(result.outcome, .converted([.jpeg]))
        let written = try Data(contentsOf: out)
        XCTAssertNotNil(
            written.range(of: Data("DCTDecode".utf8)),
            "photo page should stay JPEG"
        )
        XCTAssertNil(written.range(of: Data("CCITTFaxDecode".utf8)))
    }

    func test_convert_passThroughVerdict_copiesFileByteIdentical() async throws {
        // Arrange
        let data = Fixtures.bornDigitalPDF()
        let src = Fixtures.write(data, to: dir, name: "digital.pdf")
        let out = dir.appendingPathComponent("out/sub/digital.pdf")
        let report = try PDFInspector.inspect(src)

        // Act
        let result = try await Converter.convert(report: report, to: out, settings: noOCR)

        // Assert
        XCTAssertEqual(result.outcome, .copied(.passThrough))
        XCTAssertEqual(try Data(contentsOf: out), data)
    }

    func test_convert_insufficientSaving_fallsBackToCopy() async throws {
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
        let result = try await Converter.convert(report: report, to: out, settings: settings)

        // Assert
        XCTAssertEqual(result.outcome, .copied(.insufficientSaving))
        XCTAssertEqual(try Data(contentsOf: out), srcData)
    }

    func test_convert_dpiCap_downsamplesHighResScan() async throws {
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
        _ = try await Converter.convert(report: report, to: out, settings: settings)

        // Assert — rebuilt page images are 150dpi-sized (620px wide, in the
        // XObject header), not 2480
        let written = try Data(contentsOf: out)
        XCTAssertNotNil(written.range(of: Data("/Width 620".utf8)))
        XCTAssertNil(written.range(of: Data("/Width 2480".utf8)))
    }

    func test_convert_ontoItsOwnSource_throwsAndLeavesOriginalIntact() async throws {
        // Arrange — output path == source path (loose file, parent chosen
        // as the output folder)
        let data = Fixtures.bornDigitalPDF()
        let src = Fixtures.write(data, to: dir, name: "loose.pdf")
        let report = try PDFInspector.inspect(src)

        // Act / Assert
        await assertThrowsAsync(
            try await Converter.convert(report: report, to: src, settings: noOCR)
        )
        XCTAssertEqual(try Data(contentsOf: src), data)
    }

    /// A 75 dpi text source — demoted by the resolution gate (the damage
    /// backstop is covered at the Binarize unit level).
    private func lowResTextReport() throws -> PDFInspector.Report {
        try PDFInspector.inspect(
            Fixtures.write(Fixtures.lowResTextScanPDF(), to: dir, name: "tiny.pdf")
        )
    }

    func test_convert_demotedTextPage_usesGray4ByDefault() async throws {
        // Arrange
        let out = dir.appendingPathComponent("out/tiny.pdf")
        let settings = anySaving

        // Act
        let result = try await Converter.convert(
            report: try lowResTextReport(), to: out, settings: settings
        )

        // Assert — demoted, and encoded as 4-bit Flate, not JPEG
        XCTAssertEqual(result.outcome, .converted([.gray4]))
        let written = try Data(contentsOf: out)
        XCTAssertNotNil(written.range(of: Data("/BitsPerComponent 4".utf8)))
        XCTAssertNil(written.range(of: Data("DCTDecode".utf8)))
    }

    func test_convert_lowResTextPage_staysGrayscaleEvenWhenCrisp() async throws {
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
        let settings = anySaving

        // Act
        let result = try await Converter.convert(report: report, to: out, settings: settings)

        // Assert
        XCTAssertEqual(result.outcome, .converted([.gray4]))
        XCTAssertNil(
            try Data(contentsOf: out).range(of: Data("CCITTFaxDecode".utf8))
        )
    }

    func test_convert_damageDemotedPage_keepsTheTextResolution() async throws {
        // Arrange — a 300 dpi text scan forced to stay grayscale
        let page = Fixtures.textPage(width: 2480, height: 3508, noise: true)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 300), to: dir, name: "fine.pdf"
        )
        let out = dir.appendingPathComponent("out/fine.pdf")
        var settings = anySaving
        settings.maxG4Damage = -1

        // Act
        let result = try await Converter.convert(
            report: try PDFInspector.inspect(src), to: out, settings: settings)

        // Assert — 4-bit at the full 300 dpi, not cut to the photo cap
        XCTAssertEqual(result.outcome, .converted([.gray4]))
        XCTAssertNotNil(
            try Data(contentsOf: out).range(of: Data("/Width 2480".utf8)),
            "a page kept grayscale for its fine detail should keep its resolution")
    }

    func test_convert_grayscaleTextPage_hasWhitePaper() async throws {
        // Arrange — the low-res scan's paper is 250, not white
        let out = dir.appendingPathComponent("out/tiny.pdf")
        let settings = anySaving

        // Act
        _ = try await Converter.convert(report: try lowResTextReport(), to: out, settings: settings)

        // Assert — paper comes out white
        let counts = Pipeline.histogram(try Fixtures.rendered(out, dpi: 75))
        XCTAssertEqual(counts.indices.max { counts[$0] < counts[$1] }, 255, "paper should be white")
    }

    func test_convert_demotedTextPage_respectsJPEGSetting() async throws {
        // Arrange
        let out = dir.appendingPathComponent("out/tiny.pdf")
        var settings = anySaving
        settings.demotedTextFormat = .jpeg

        // Act
        _ = try await Converter.convert(
            report: try lowResTextReport(), to: out, settings: settings
        )

        // Assert
        let written = try Data(contentsOf: out)
        XCTAssertNotNil(written.range(of: Data("DCTDecode".utf8)))
        XCTAssertNil(written.range(of: Data("/BitsPerComponent 4".utf8)))
    }

    func test_convert_damageDemotion_staysGrayscaleAtAdequateResolution() async throws {
        // Arrange — an adequate-resolution source (150 dpi, above the gate)
        // with the damage backstop tightened so this page's measured score
        // exceeds it: exercises the damage-demotion arm the dpi gate
        // normally shields
        let page = Fixtures.renderedTextPage(fontSize: 14, ink: 0.1)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 150), to: dir, name: "adequate.pdf"
        )
        let out = dir.appendingPathComponent("out/adequate.pdf")
        let report = try PDFInspector.inspect(src)
        var settings = anySaving
        settings.maxG4Damage = 0.01
        settings.dpiCap = 150  // skip the 2x upsample; the arm under test is unaffected

        // Act
        let result = try await Converter.convert(report: report, to: out, settings: settings)

        // Assert — demoted by damage, not resolution, and grayscale
        XCTAssertEqual(result.outcome, .converted([.gray4]))
        let written = try Data(contentsOf: out)
        XCTAssertNil(written.range(of: Data("CCITTFaxDecode".utf8)))
        XCTAssertNotNil(written.range(of: Data("/BitsPerComponent 4".utf8)))
    }

    func test_convert_mixedDocument_encodesEachPageByKind() async throws {
        // Arrange — a text page and a photo page in one file (small pages:
        // the assertions are about per-page encoding, not size)
        let text = Fixtures.textPage(width: 620, height: 800, noise: true)
        let photo = Fixtures.photoPage(width: 620, height: 800)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [text, photo], dpi: 150), to: dir, name: "mixed.pdf"
        )
        let out = dir.appendingPathComponent("out/mixed.pdf")
        let report = try PDFInspector.inspect(src)
        let settings = anySaving

        // Act
        let result = try await Converter.convert(report: report, to: out, settings: settings)

        // Assert — one G4 page, one JPEG page, in order
        XCTAssertEqual(result.outcome, .converted([.g4, .jpeg]))
        let written = try Data(contentsOf: out)
        XCTAssertNotNil(written.range(of: Data("CCITTFaxDecode".utf8)))
        XCTAssertNotNil(written.range(of: Data("DCTDecode".utf8)))
    }

    func test_convert_preservesSourceModificationDate() async throws {
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
        _ = try await Converter.convert(report: report, to: out, settings: noOCR)

        // Assert
        let outDate =
            try FileManager.default.attributesOfItem(atPath: out.path)[.modificationDate]
            as? Date
        XCTAssertEqual(outDate, past)
    }

    // MARK: Destinations

    func test_convert_refusesToReplaceAFileItDidNotWrite() async throws {
        // Arrange — the output path already holds someone else's file
        let page = Fixtures.textPage(width: 1240, height: 1754, noise: true)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 150), to: dir, name: "scan.pdf"
        )
        let out = Fixtures.write(
            Data("keep me".utf8), to: dir.appendingPathComponent("out"), name: "scan.pdf")
        let report = try PDFInspector.inspect(src)

        // Act / Assert
        await assertThrowsAsync(try await Converter.convert(report: report, to: out, settings: noOCR)) {
            guard case .destinationExists = $0 as? PressError else {
                return XCTFail("expected destinationExists, got \($0)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: out), Data("keep me".utf8), "file should be untouched")
    }

    func test_convert_replacesItsOwnEarlierOutput() async throws {
        // Arrange — a first run already wrote the output
        let page = Fixtures.textPage(width: 2480, height: 3508, noise: true)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 300), to: dir, name: "scan.pdf"
        )
        let out = dir.appendingPathComponent("out/scan.pdf")
        let report = try PDFInspector.inspect(src)
        _ = try await Converter.convert(report: report, to: out, settings: noOCR)

        // Act — run again into the same folder
        let again = try await Converter.convert(report: report, to: out, settings: noOCR)

        // Assert
        XCTAssertTrue(again.converted, "a re-run should replace its own output")
    }

    func test_convert_copyOverItsOwnEarlierOutput_replacesItWithTheSource() async throws {
        // Arrange — a first run converted the scan; a second, asking for a
        // saving no output can reach, copies the original over that output
        let page = Fixtures.textPage(width: 1240, height: 1754, noise: true)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 150), to: dir, name: "scan.pdf"
        )
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: src.path)
        let out = dir.appendingPathComponent("out/scan.pdf")
        let report = try PDFInspector.inspect(src)
        _ = try await Converter.convert(report: report, to: out, settings: anySaving)
        var strict = noOCR
        strict.minSavingFraction = 0.9999

        // Act
        let result = try await Converter.convert(report: report, to: out, settings: strict)

        // Assert — the source's bytes and date, and nothing left beside it
        XCTAssertEqual(result.outcome, .copied(.insufficientSaving))
        XCTAssertEqual(
            try Data(contentsOf: out), try Data(contentsOf: src), "the output should be the source's bytes")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: out.path)[.modificationDate] as? Date, past,
            "the copy should keep the source's modification date")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path),
            ["scan.pdf"], "the output folder should hold only the copy")
    }

    func test_convert_passThroughOverAnIdenticalCopy_leavesItInPlace() async throws {
        // Arrange — an earlier run already copied this file through
        let src = Fixtures.write(Fixtures.bornDigitalPDF(), to: dir, name: "digital.pdf")
        let out = dir.appendingPathComponent("out/digital.pdf")
        let report = try PDFInspector.inspect(src)
        _ = try await Converter.convert(report: report, to: out, settings: noOCR)
        let before =
            try out.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier as? NSObject

        // Act
        let result = try await Converter.convert(report: report, to: out, settings: noOCR)

        // Assert — reported as copied, and the same file still there
        XCTAssertEqual(result.outcome, .copied(.passThrough))
        let after =
            try out.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier as? NSObject
        XCTAssertEqual(after, before, "an identical copy should not be rewritten")
    }

    func test_convert_ontoItsSourceSpelledInAnotherCase_throws() async throws {
        // Arrange — on a case-insensitive volume LOOSE.PDF is loose.pdf
        let isCaseSensitive = try dir.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames
        try XCTSkipIf(isCaseSensitive != false, "needs a case-insensitive volume")
        let data = Fixtures.bornDigitalPDF()
        let src = Fixtures.write(data, to: dir, name: "loose.pdf")
        let report = try PDFInspector.inspect(src)

        // Act / Assert
        await assertThrowsAsync(
            try await Converter.convert(
                report: report, to: dir.appendingPathComponent("LOOSE.PDF"), settings: noOCR)
        )
        XCTAssertEqual(try Data(contentsOf: src), data)
    }

    // MARK: Page handling

    func test_convert_croppedPage_comesOutAtTheCropSize() async throws {
        // Arrange — an A4 scan cropped in a viewer to 300 × 400 pt
        let page = Fixtures.textPage(width: 2480, height: 3508, noise: true)
        let full = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 300), to: dir, name: "full.pdf"
        )
        let cropped = Fixtures.edited(full, as: "cropped.pdf") {
            $0.setBounds(CGRect(x: 100, y: 100, width: 300, height: 400), for: .cropBox)
        }
        let out = dir.appendingPathComponent("out/cropped.pdf")
        let settings = anySaving

        // Act
        _ = try await Converter.convert(
            report: try PDFInspector.inspect(cropped), to: out, settings: settings)

        // Assert — the hidden part stays hidden: the page is the crop
        let media = try XCTUnwrap(CGPDFDocument(out as CFURL)?.page(at: 1)).getBoxRect(.mediaBox)
        XCTAssertEqual(media.width, 300, accuracy: 1)
        XCTAssertEqual(media.height, 400, accuracy: 1)
    }

    func test_convert_mixedFile_keepsVectorPagesAsTheyWere() async throws {
        // Arrange — a real-text cover sheet followed by a scanned page
        let scan = Fixtures.textPage(width: 2480, height: 3508, noise: true)
        let src = Fixtures.write(
            Fixtures.drawnPDF([.text("Vector cover sheet"), .scan(scan, dpi: 300)]),
            to: dir, name: "mixed.pdf"
        )
        let report = try PDFInspector.inspect(src)
        XCTAssertEqual(report.verdict, .convert, "fixture sanity")
        let out = dir.appendingPathComponent("out/mixed.pdf")
        let settings = anySaving

        // Act
        let result = try await Converter.convert(report: report, to: out, settings: settings)

        // Assert — page 1 copied, not rasterised: its text is still text,
        // and it draws exactly as the source did
        XCTAssertEqual(result.outcome, .converted([.original, .g4]))
        XCTAssertTrue(Fixtures.pageText(of: out).contains("Vector cover sheet"))
        XCTAssertFalse(
            try XCTUnwrap(Fixtures.contentStream(of: out)).contains("/Im0"),
            "page 1 should carry no raster image"
        )
        let before = try Fixtures.rendered(src, dpi: 72)
        let after = try Fixtures.rendered(out, dpi: 72)
        XCTAssertEqual(after.pixels, before.pixels, "copied page should render identically")
    }

    func test_convert_fileChangedSinceAnalysis_throwsAndWritesNothing() async throws {
        // Arrange — analysed as two pages, then replaced by one
        let page = Fixtures.textPage(width: 1240, height: 1754, noise: true)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page, page], dpi: 150), to: dir, name: "scan.pdf"
        )
        let report = try PDFInspector.inspect(src)
        Fixtures.write(Fixtures.scannedPDF(pages: [page], dpi: 150), to: dir, name: "scan.pdf")
        let out = dir.appendingPathComponent("out/scan.pdf")

        // Act / Assert
        await assertThrowsAsync(try await Converter.convert(report: report, to: out, settings: noOCR)) {
            guard case .changedSinceAnalysis = $0 as? PressError else {
                return XCTFail("expected changedSinceAnalysis, got \($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func test_convert_cancelled_stopsAndWritesNothing() async throws {
        // Arrange
        let page = Fixtures.textPage(width: 1240, height: 1754, noise: true)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page, page], dpi: 150), to: dir, name: "scan.pdf"
        )
        let report = try PDFInspector.inspect(src)
        let out = dir.appendingPathComponent("out/scan.pdf")
        let settings = noOCR

        // Act — a conversion whose task is already cancelled
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Converter.convert(report: report, to: out, settings: settings)
        }

        // Assert
        do {
            _ = try await task.value
            XCTFail("a cancelled conversion should throw")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
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

    func test_items_namesDifferingOnlyInCase_getNumberedSuffix() {
        // Arrange — one file on disk on a default (case-insensitive) volume
        let one = touch("one/Scan.pdf")
        let two = touch("two/scan.pdf")

        // Act
        let items = FolderScanner.items(for: [one, two])

        // Assert — distinct output paths whatever the volume
        let keys = Set(items.map { $0.relativePath.lowercased() })
        XCTAssertEqual(keys.count, 2, "got \(items.map(\.relativePath))")
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
