import XCTest

@testable import PressKit

final class BinarizeTests: XCTestCase {
    /// Bold ink and faint print on the same page — the case a global Otsu
    /// threshold gets wrong (the split lands between the two ink shades
    /// and the faint one is lost as "paper").
    private func mixedContrastPage(width: Int = 600, height: Int = 800)
        -> Pipeline.GrayImage
    {
        var pixels = [UInt8](repeating: 250, count: width * height)
        func dashes(rows: Range<Int>, value: UInt8) {
            for line in stride(from: rows.lowerBound, to: rows.upperBound, by: 24) {
                for y in line..<(line + 10) {
                    for x in 50..<(width - 50) where (x / 30) % 2 == 0 {
                        pixels[y * width + x] = value
                    }
                }
            }
        }
        dashes(rows: 60..<360, value: 15)  // bold print, top half
        dashes(rows: 440..<740, value: 205)  // faded print, bottom half
        return Pipeline.GrayImage(width: width, height: height, pixels: pixels)
    }

    func test_sauvola_keepsFaintPrintAlongsideBoldPrint() {
        // Arrange
        let page = mixedContrastPage()

        // Act
        let bw = Binarize.sauvola(page, dpi: 300)

        // Assert — a bold-dash pixel and a faded-dash pixel are both ink,
        // and blank paper stays white
        XCTAssertTrue(bw[60, 65], "bold print should be ink")
        XCTAssertTrue(bw[60, 445], "faded print should be ink too")
        XCTAssertFalse(bw[10, 400], "blank margin should stay paper")
        XCTAssertFalse(bw[300, 410], "gap between blocks should stay paper")
    }

    func test_sauvola_blankPage_staysEntirelyWhite() {
        // Arrange
        let page = Pipeline.GrayImage(
            width: 400, height: 400, pixels: [UInt8](repeating: 245, count: 160_000)
        )

        // Act
        let bw = Binarize.sauvola(page, dpi: 300)

        // Assert
        XCTAssertFalse(bw.ink.contains(true))
    }

    func test_sauvola_matchesOtsuOnCleanBimodalPage() {
        // Arrange — the ordinary case must not regress: crisp dark text on
        // clean paper binarises the same way under either method
        let page = Fixtures.textPage(noise: true)

        // Act
        let adaptive = Binarize.sauvola(page, dpi: 300)
        let global = Pipeline.threshold(page, at: Pipeline.otsuThreshold(page))

        // Assert — over 99% of pixels agree
        let disagree = zip(adaptive.ink, global.ink).filter { $0 != $1 }.count
        XCTAssertLessThan(Double(disagree) / Double(adaptive.ink.count), 0.01)
    }
}
