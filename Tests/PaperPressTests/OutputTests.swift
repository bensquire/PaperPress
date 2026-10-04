import CoreGraphics
import XCTest

@testable import PressKit

final class PDFWriterTests: FixtureTestCase {
    /// A one-page G4 PDF carrying `words` as its OCR layer, on disk.
    private func ocrPDF(_ words: [OCR.Word]) throws -> URL {
        let stream = try Converter.encodeG4(Fixtures.textPage(), dpi: 150)
        let pdf = try PDFWriter.build(
            pages: [PDFWriter.Page(content: .g4(stream), dpi: 150, ocrWords: words)]
        )
        return Fixtures.write(pdf, to: dir, name: "ocr.pdf")
    }

    private func word(_ text: String) -> OCR.Word {
        OCR.Word(text: text, box: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.05))
    }

    func test_build_embedsInvisibleOCRTextLayer() throws {
        // Arrange / Act
        let url = try ocrPDF([word("HELLO")])

        // Assert — invisible render mode, the word, and a viewer finds it
        let content = try XCTUnwrap(Fixtures.contentStream(of: url))
        XCTAssertTrue(content.contains("BT 3 Tr"), "text layer should be invisible")
        XCTAssertTrue(content.contains("(HELLO) Tj"), "word should be in the content stream")
        XCTAssertTrue(
            Fixtures.pageText(of: url).contains("HELLO"), "page text should be searchable"
        )
    }

    func test_build_compressesTheTextLayer() throws {
        // Arrange / Act — a page with plenty of OCR text
        let words = (0..<200).map { word("invoice number \($0) for the archive") }
        let url = try ocrPDF(words)

        // Assert — the operators aren't stored raw
        let file = try Data(contentsOf: url)
        XCTAssertNil(
            file.range(of: Data("BT 3 Tr".utf8)), "content stream should be Flate-compressed"
        )
        XCTAssertNotNil(file.range(of: Data("/Filter/FlateDecode>>".utf8)))
    }

    func test_build_ocrTextKeepsLatin1Accents() throws {
        // Arrange / Act — accented and typographic characters from OCR
        let url = try ocrPDF([word("Café – crème brûlée’s"), word("Grüße")])

        // Assert — extracted as written, not blanked to spaces
        let text = Fixtures.pageText(of: url)
        XCTAssertTrue(text.contains("Café"), "got \(text)")
        XCTAssertTrue(text.contains("brûlée’s"), "got \(text)")
        XCTAssertTrue(text.contains("Grüße"), "got \(text)")
    }

    func test_build_stampsPaperPressProducerByDefault() throws {
        // Arrange / Act
        let page = Fixtures.textPage()
        let pdf = try PDFWriter.build(
            pages: [PDFWriter.Page(content: .g4(try Converter.encodeG4(page, dpi: 150)), dpi: 150)]
        )

        // Assert
        XCTAssertNotNil(
            pdf.range(of: Data("/Producer (\(PDFWriter.producerMarker))".utf8))
        )
        XCTAssertNotNil(pdf.range(of: Data("/Info ".utf8)))
    }

    func test_build_fixtureProducerOverridesDefault() {
        // Arrange / Act — fixtures must look like third-party scans
        let pdf = Fixtures.scannedPDF(pages: [Fixtures.textPage()], dpi: 150)

        // Assert
        XCTAssertNil(pdf.range(of: Data(PDFWriter.producerMarker.utf8)))
        XCTAssertNotNil(pdf.range(of: Data(Fixtures.foreignProducer.utf8)))
    }

    func test_build_copiedPagesShareTheirFont() throws {
        // Arrange — two vector pages set in the same font
        let src = Fixtures.write(
            Fixtures.drawnPDF([.text("First page"), .text("Second page")]), to: dir, name: "v.pdf"
        )
        let doc = try XCTUnwrap(CGPDFDocument(src as CFURL))
        let copier = PageCopier()
        let copies = try (1...2).map { try copier.copy(try XCTUnwrap(doc.page(at: $0))) }

        // Act
        let one = try PDFWriter.build(pages: [PDFWriter.Page(original: copies[0])])
        let two = try PDFWriter.build(pages: copies.map { PDFWriter.Page(original: $0) })

        // Assert — the second page adds its content, not another font
        let fonts = { (pdf: Data) in
            String(decoding: pdf, as: UTF8.self).components(separatedBy: "/FontFile").count - 1
        }
        XCTAssertGreaterThan(fonts(one), 0, "fixture should embed a font program")
        XCTAssertEqual(fonts(two), fonts(one), "shared font should be written once")
        let url = Fixtures.write(two, to: dir, name: "two.pdf")
        XCTAssertTrue(
            Fixtures.pageText(of: url, page: 2).contains("Second page"),
            "the second page should still reach the font it shares")
    }
}

final class PressErrorTests: XCTestCase {
    func test_errorDescriptions_areHumanReadable() {
        // Arrange / Act / Assert
        XCTAssertEqual(
            PressError.scanFailed("boom").errorDescription, "Processing failed: boom"
        )
        XCTAssertEqual(
            PressError.wouldOverwrite("a.pdf").errorDescription,
            "Writing a.pdf here would overwrite the original"
        )
    }
}

final class OCRTests: XCTestCase {
    func test_recognize_findsTextOnAClearPage() throws {
        // Arrange — legible rendered type
        let page = Fixtures.renderedTextPage(fontSize: 14, ink: 0.1)

        // Act
        let words = try OCR.recognize(cgImage: try XCTUnwrap(page.cgImage))

        // Assert — Vision finds text and normalised boxes are in range
        XCTAssertFalse(words.isEmpty)
        let joined = words.map(\.text).joined(separator: " ")
        let expected = Fixtures.sampleText.split(separator: " ").map(String.init)
        XCTAssertTrue(expected.contains { joined.contains($0) })
        for word in words {
            XCTAssertTrue(word.box.minX >= 0 && word.box.maxX <= 1)
            XCTAssertTrue(word.box.minY >= 0 && word.box.maxY <= 1)
        }
    }
}
