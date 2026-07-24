import CoreGraphics
import XCTest

@testable import PressKit

final class PDFWriterTests: XCTestCase {
    func test_build_embedsInvisibleOCRTextLayer() throws {
        // Arrange — a G4 page with one recognised word
        let page = Fixtures.textPage()
        let stream = try Converter.encodeG4(page, dpi: 150)
        let words = [
            OCR.Word(text: "HELLO", box: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.05))
        ]

        // Act
        let pdf = PDFWriter.build(
            pages: [PDFWriter.Page(content: .g4(stream), dpi: 150, ocrWords: words)]
        )

        // Assert — invisible render mode, the word, and the font resource
        XCTAssertNotNil(pdf.range(of: Data("BT 3 Tr".utf8)))
        XCTAssertNotNil(pdf.range(of: Data("(HELLO) Tj".utf8)))
        XCTAssertNotNil(pdf.range(of: Data("/F1".utf8)))
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
