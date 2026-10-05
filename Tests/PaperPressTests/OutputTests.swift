import CoreGraphics
import CoreText
import PDFKit
import XCTest

@testable import PressKit

final class PDFWriterTests: FixtureTestCase {
    /// Encoded once: every OCR-layer test draws its words over this page.
    private static let background = try! Converter.encodeG4(Fixtures.textPage(), dpi: 150)

    /// A one-page G4 PDF carrying `words` as its OCR layer, on disk.
    private func ocrPDF(_ words: [OCR.Word]) throws -> URL {
        let pdf = try PDFWriter.build(
            pages: [PDFWriter.Page(content: .g4(Self.background), dpi: 150, ocrWords: words)]
        )
        return Fixtures.write(pdf, to: dir, name: "ocr.pdf")
    }

    private func word(_ text: String, x: CGFloat = 0.1) -> OCR.Word {
        OCR.Word(text: text, box: CGRect(x: x, y: 0.8, width: 0.2, height: 0.05))
    }

    func test_build_embedsInvisibleOCRTextLayer() throws {
        // Arrange / Act
        let url = try ocrPDF([word("HELLO")])

        // Assert — invisible render mode, the word, and a viewer finds it
        let content = try XCTUnwrap(Fixtures.contentStream(of: url))
        XCTAssertTrue(content.contains("BT 3 Tr"), "text layer should be invisible")
        XCTAssertTrue(content.contains("(HELLO ) Tj"), "word should be in the content stream")
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

    /// Where a reader puts the OCR layer's first `length` characters, and
    /// the page's size, in points.
    private func selected(_ length: Int, in url: URL) throws -> (bounds: CGRect, page: CGSize) {
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: length)))
        return (selection.bounds(for: page), page.bounds(for: .mediaBox).size)
    }

    func test_build_highlightsAWordOverItsBox() throws {
        // Arrange / Act — capitals, wider than an average letter, where OCR
        // boxed them
        let (highlight, page) = try selected(5, in: try ocrPDF([word("HELLO")]))

        // Assert — selecting it highlights the box: not below it, and not
        // past it into a next word, which a reader would then join it to
        XCTAssertEqual(highlight.minX, 0.1 * page.width, accuracy: 1)
        XCTAssertEqual(highlight.maxX, 0.3 * page.width, accuracy: 1)
        XCTAssertEqual(highlight.minY, 0.8 * page.height, accuracy: 0.5)
        XCTAssertEqual(highlight.height, 0.05 * page.height, accuracy: 0.5)
    }

    func test_build_endsAWordClearOfTheNextOnItsLine() throws {
        // Arrange / Act — boxes all but touching, as Vision's do
        let (first, page) = try selected(5, in: try ocrPDF([word("other"), word("states", x: 0.302)]))

        // Assert — a gap of a fifth of the font size before the next word,
        // where pdftotext -raw breaks words (it ignores space characters)
        XCTAssertLessThanOrEqual(first.maxX, 0.302 * page.width - 0.2 * 0.05 * page.height)
    }

    func test_build_withoutAnOCRLayer_leavesTheFontOut() throws {
        // Arrange / Act
        let pdf = try PDFWriter.build(pages: [PDFWriter.Page(content: .g4(Self.background), dpi: 150)])

        // Assert — nearly a kilobyte of /Widths no page would use
        XCTAssertNil(pdf.range(of: Data("/BaseFont".utf8)))
    }

    func test_helveticaWidths_matchTheStandardMetrics() {
        // Arrange / Act / Assert — space, a, D, é, en dash (AFM: 278 556 722 556 556)
        let widths = PDFWriter.helveticaWidths
        XCTAssertEqual(widths.count, 224)
        XCTAssertEqual([0x20, 0x61, 0x44, 0xE9, 0x96].map { widths[$0 - 32] }, [278, 556, 722, 556, 556])
    }

    func test_build_keepsTheSpaceBetweenWordBoxes() throws {
        // Arrange / Act — two words side by side, as OCR reports them
        let url = try ocrPDF([word("DOMESTIC"), word("APPLIANCE", x: 0.32)])

        // Assert — a reader doesn't run them together
        let text = Fixtures.pageText(of: url)
        XCTAssertTrue(text.contains("DOMESTIC APPLIANCE"), "got \(text)")
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
    func test_recognize_keepsLinesVisionDoesNotSplitIntoWords() async throws {
        // Arrange — English and Chinese lines on one page
        let w = 1200, h = 300
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (i, (font, text)) in [
            ("Helvetica", "Invoice number 4521 for the archive"), ("PingFang SC", "发票号码用于档案保存"),
        ]
        .enumerated() {
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: CTFontCreateWithName(font as CFString, 40, nil)
            ]
            context.textPosition = CGPoint(x: 40, y: CGFloat(h - 100 - i * 120))
            CTLineDraw(
                CTLineCreateWithAttributedString(
                    CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)), context)
        }

        // Act
        let words = try await OCR.recognize(cgImage: try XCTUnwrap(context.makeImage()))

        // Assert — the English word by word, and the Chinese line whole
        let texts = words.map(\.text)
        XCTAssertTrue(texts.contains("Invoice"), "\(texts)")
        XCTAssertTrue(texts.contains { $0.contains("发票") }, "\(texts)")
    }

    func test_recognize_findsEachWordOnAClearPage() async throws {
        // Arrange — legible rendered type
        let page = Fixtures.renderedTextPage(fontSize: 14, ink: 0.1)

        // Act
        let words = try await OCR.recognize(cgImage: try XCTUnwrap(page.cgImage))

        // Assert — Vision finds text, one word an entry, each boxed in
        // range and narrower than the line it came from
        XCTAssertFalse(words.isEmpty)
        let joined = words.map(\.text).joined(separator: " ")
        let expected = Fixtures.sampleText.split(separator: " ").map(String.init)
        XCTAssertTrue(expected.contains { joined.contains($0) })
        for word in words {
            XCTAssertFalse(word.text.contains(where: \.isWhitespace), "\"\(word.text)\" is more than a word")
            XCTAssertTrue(word.box.minX >= 0 && word.box.maxX <= 1)
            XCTAssertTrue(word.box.minY >= 0 && word.box.maxY <= 1)
            XCTAssertLessThan(word.box.width, 0.5, "\"\(word.text)\" has its line's box")
        }
    }
}

final class G4Tests: XCTestCase {
    private let codestream: [UInt8] = [0x26, 0xA0, 0x08, 0x00]

    /// A little-endian, one-strip G4 TIFF of an 8 × 1 page: the codestream
    /// at 8, then the directory at 12, every entry a SHORT.
    private func tiff(fillOrder: Int) -> Data {
        var d: [UInt8] = [0x49, 0x49, 42, 0, 12, 0, 0, 0] + codestream
        let tags = [(256, 8), (257, 1), (259, 4), (262, 0), (266, fillOrder), (273, 8), (279, 4)]
        d += [UInt8(tags.count), 0]
        for (tag, value) in tags {
            d += [UInt8(tag & 0xFF), UInt8(tag >> 8), 3, 0, 1, 0, 0, 0, UInt8(value), 0, 0, 0]
        }
        return Data(d + [0, 0, 0, 0])
    }

    func test_extractStream_readsALittleEndianTIFF() throws {
        // Arrange / Act — ImageIO writes big-endian, so only this reaches
        // the little-endian reads
        let stream = try G4.extractStream(fromTIFF: tiff(fillOrder: 1))

        // Assert
        XCTAssertEqual(stream.data, Data(codestream))
        XCTAssertEqual(stream.width, 8)
        XCTAssertEqual(stream.height, 1)
    }

    func test_extractStream_refusesReversedBitOrder() {
        // Arrange / Act / Assert — CCITTFaxDecode would misread every byte
        XCTAssertThrowsError(try G4.extractStream(fromTIFF: tiff(fillOrder: 2))) {
            guard case .scanFailed(let message) = $0 as? ScanError, message.contains("fill order") else {
                return XCTFail("got \($0)")
            }
        }
    }
}
