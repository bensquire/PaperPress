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
}
