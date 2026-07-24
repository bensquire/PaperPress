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

    func test_damage_cleanBinarisation_staysUnderShippedThreshold() {
        // Arrange
        let page = Fixtures.textPage(noise: true)

        // Act
        let bw = Binarize.sauvola(page, dpi: 300)
        let damage = Binarize.damage(page, bw)

        // Assert — clearly under the shipped G4 fallback threshold
        XCTAssertLessThan(damage, Converter.Settings().maxG4Damage - 0.05)
    }

    func test_damage_tinyPrintFromLowResSource_exceedsShippedThreshold() {
        // Arrange — real letterforms at ~4px, upsampled 4× exactly as the
        // converter treats a 75 dpi source. At this size the antialiasing
        // IS the glyph; binarisation must be measurably destructive so the
        // converter demotes the page. (Regular synthetic patterns don't
        // trigger this — only irregular glyph shapes do.)
        let upsampled = Fixtures.renderedTextPage(fontSize: 4, ink: 0.3)
            .resampled(scale: 4)

        // Act
        let bw = Binarize.sauvola(upsampled, dpi: 300)
        let damage = Binarize.damage(upsampled, bw)

        // Assert
        XCTAssertGreaterThan(damage, Converter.Settings().maxG4Damage)
    }

    func test_damage_calibrationAnchors_holdWithinTolerance() {
        // The 0.18 threshold rests on measured scores (clean <= 0.177,
        // degraded >= 0.191 on real documents). These fixture anchors fail
        // if the metric itself drifts, even when pages don't cross the
        // threshold. Bands are wide enough to absorb CoreText rendering
        // variation across OS versions.
        let tiny = Fixtures.renderedTextPage(fontSize: 4, ink: 0.3).resampled(scale: 4)
        let tinyScore = Binarize.damage(tiny, Binarize.sauvola(tiny, dpi: 300))
        XCTAssertGreaterThan(tinyScore, 0.30)
        XCTAssertLessThan(tinyScore, 0.48)

        let normal = Fixtures.renderedTextPage(fontSize: 14, ink: 0.1).resampled(scale: 4)
        let normalScore = Binarize.damage(normal, Binarize.sauvola(normal, dpi: 300))
        XCTAssertGreaterThan(normalScore, 0.10)
        XCTAssertLessThan(normalScore, 0.23)
    }

    func test_damage_normalPrintFromLowResSource_staysUnderShippedThreshold() {
        // Arrange — same low-res treatment, but normal-size print (like
        // the certificates that binarise fine at 100 dpi)
        let upsampled = Fixtures.renderedTextPage(fontSize: 14, ink: 0.1)
            .resampled(scale: 4)

        // Act
        let bw = Binarize.sauvola(upsampled, dpi: 300)
        let damage = Binarize.damage(upsampled, bw)

        // Assert
        XCTAssertLessThan(damage, Converter.Settings().maxG4Damage)
    }

    func test_damage_erasedInk_scoresHigh() {
        // Arrange — a binarisation that lost every stroke (all paper)
        let page = Fixtures.textPage(noise: true)
        let blank = Pipeline.BinaryImage(
            width: page.width, height: page.height,
            ink: [Bool](repeating: false, count: page.width * page.height)
        )

        // Act
        let damage = Binarize.damage(page, blank)

        // Assert — destroying all content must score far above the threshold
        XCTAssertGreaterThan(damage, 0.4)
    }
}
