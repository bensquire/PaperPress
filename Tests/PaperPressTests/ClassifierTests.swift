import XCTest

@testable import PressKit

final class PageClassifierTests: XCTestCase {
    func test_classify_bimodalTextPage_isText() {
        // Arrange
        let page = Fixtures.textPage()

        // Act
        let kind = PageClassifier.classify(page)

        // Assert
        XCTAssertEqual(kind, .text)
    }

    func test_classify_noisyTextPage_isStillText() {
        // Arrange — mild paper-grain noise must not flip the verdict
        let page = Fixtures.textPage(noise: true)

        // Act
        let kind = PageClassifier.classify(page)

        // Assert
        XCTAssertEqual(kind, .text)
    }

    func test_classify_gradientPhotoPage_isPhoto() {
        // Arrange
        let page = Fixtures.photoPage()

        // Act
        let kind = PageClassifier.classify(page)

        // Assert
        XCTAssertEqual(kind, .photo)
    }

    func test_classify_blankPage_isText() {
        // Arrange — an empty page must go 1-bit, not JPEG
        let page = Pipeline.GrayImage(
            width: 200, height: 200, pixels: [UInt8](repeating: 248, count: 40000)
        )

        // Act
        let kind = PageClassifier.classify(page)

        // Assert
        XCTAssertEqual(kind, .text)
    }

    /// A page whose "paper" is mid-gray: what a low-contrast photograph
    /// looks like to the paper-peak test, with sharp dark blocks so its
    /// midtones sit at edges as a document's do.
    private func midGrayPaperPage() -> Pipeline.GrayImage {
        var page = Fixtures.textPage(noise: true)
        for i in page.pixels.indices where page.pixels[i] > 200 {
            page.pixels[i] = page.pixels[i] - 105  // paper ~140–150
        }
        return page
    }

    func test_classify_midGrayPaper_isPhoto() {
        // Arrange — a light peak, but not light enough to be paper
        let page = midGrayPaperPage()

        // Act
        let kind = PageClassifier.classify(page)

        // Assert — JPEG, the side that never destroys content
        XCTAssertEqual(kind, .photo)
    }

    func test_levelled_whitensPaperAndBlackensInk() {
        // Arrange — paper 244–255 with grain, ink 15
        let page = Fixtures.textPage(noise: true)

        // Act
        let levelled = page.levelled()

        // Assert — the paper's grain gone to white, the ink to black
        let paper = levelled.pixels.filter { $0 > 128 }
        XCTAssertGreaterThan(Double(paper.count { $0 >= 250 }) / Double(paper.count), 0.9)
        XCTAssertEqual(levelled.pixels.min(), 0)
    }

    func test_levelled_withoutContrast_leavesThePageAlone() {
        // Arrange — nothing to tell ink from paper by
        let flat = Pipeline.GrayImage(
            width: 100, height: 100, pixels: (0..<10_000).map { UInt8(200 + $0 % 5) })

        // Act / Assert
        XCTAssertEqual(flat.levelled().pixels, flat.pixels)
    }

    func test_levelled_keepsStrokeWeight() {
        // Arrange — real type (ink 13, paper 250) antialiased at a low
        // resolution, as a 100 dpi scan holds it
        let gray = Fixtures.renderedTextPage(fontSize: 14, ink: 0.05).resampled(scale: 0.75)

        // Act
        let levelled = gray.levelled()

        // Assert — about the same coverage of ink, now black on white (the
        // ink class's mean as black point made these strokes 1.34× heavier)
        func coverage(_ g: Pipeline.GrayImage, ink: Double, paper: Double) -> Double {
            g.pixels.reduce(0.0) { $0 + max(0, min(1, (paper - Double($1)) / (paper - ink))) }
        }
        let weight = coverage(levelled, ink: 0, paper: 255) / coverage(gray, ink: 13, paper: 250)
        XCTAssertEqual(weight, 1, accuracy: 0.12, "stroke weight \(weight)× the scan's")
    }
}
