import XCTest

@testable import PressKit

final class EdgeCleanTests: XCTestCase {
    /// 600×800 page at 300 dpi: 10mm band ≈ 118px.
    private func page() -> Pipeline.GrayImage {
        Fixtures.blockPage()
    }

    func test_removeScanBorders_whitensEdgeBand() {
        // Arrange — a 30px black band down the left edge (scan artifact)
        var g = page()
        for y in 0..<800 {
            for x in 0..<30 {
                g.pixels[y * 600 + x] = 10
            }
        }

        // Act
        EdgeClean.removeScanBorders(&g, dpi: 300)

        // Assert — band gone, interior content untouched
        XCTAssertGreaterThan(g.pixels[400 * 600 + 10], 200, "edge band should be whitened")
        XCTAssertLessThan(g.pixels[320 * 600 + 300], 50, "content should survive")
    }

    func test_removeScanBorders_keepsContentReachingTheEdge() {
        // Arrange — a full-width horizontal rule that touches both side
        // edges mid-page (like a receipt-pad line): its pixels extend far
        // beyond the edge band, so it must be kept
        var g = page()
        for y in 500..<504 {
            for x in 0..<600 {
                g.pixels[y * 600 + x] = 30
            }
        }

        // Act
        EdgeClean.removeScanBorders(&g, dpi: 300)

        // Assert
        XCTAssertLessThan(g.pixels[502 * 600 + 300], 60, "full-width rule should survive")
        XCTAssertLessThan(g.pixels[502 * 600 + 2], 60, "even at the edge itself")
    }

    func test_removeScanBorders_cleanPage_isUntouched() {
        // Arrange
        var g = page()
        let before = g.pixels

        // Act
        EdgeClean.removeScanBorders(&g, dpi: 300)

        // Assert
        XCTAssertEqual(g.pixels, before)
    }
}
