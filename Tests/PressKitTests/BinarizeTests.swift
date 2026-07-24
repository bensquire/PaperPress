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

    func test_damage_calibrationAnchors_holdWithinTolerance() {
        // The worst-region metric's evidence: real crisp pages measure
        // 0.12-0.37, real degraded ones >= 0.42. These fixture anchors
        // fail if the metric itself drifts, even when pages don't cross
        // the threshold. Bands are wide enough to absorb CoreText
        // rendering variation across OS versions.

        // Arrange — tiny and normal print, upsampled 4× as the converter
        // treats a 75 dpi source
        let tiny = Fixtures.renderedTextPage(fontSize: 4, ink: 0.3).resampled(scale: 4)
        let normal = Fixtures.renderedTextPage(fontSize: 14, ink: 0.1).resampled(scale: 4)

        // Act
        let tinyScore = Binarize.damage(tiny, Binarize.sauvola(tiny, dpi: 300))
        let normalScore = Binarize.damage(normal, Binarize.sauvola(normal, dpi: 300))

        // Assert — each anchor holds its band, and the ordering holds
        XCTAssertGreaterThan(tinyScore, 0.15)
        XCTAssertLessThan(tinyScore, 0.35)
        XCTAssertGreaterThan(normalScore, 0.12)
        XCTAssertLessThan(normalScore, 0.30)
        XCTAssertGreaterThan(tinyScore, normalScore, "smaller print must score worse")
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

    func test_sauvola_bandedMatchesBruteForceReference() {
        // Arrange — small random-ish page spanning several bands so the
        // strip reuse and band boundaries are exercised
        var rng = SeededRandom()
        let w = 90, h = 300
        var pixels = [UInt8](repeating: 0, count: w * h)
        for i in 0..<pixels.count {
            pixels[i] = 150 &+ (rng.next() % 100)
        }
        let g = Pipeline.GrayImage(width: w, height: h, pixels: pixels)
        let dpi = 300
        let window = max(25, dpi / 6) | 1
        let r = window / 2
        let k = 0.15

        // Act
        let banded = Binarize.sauvola(g, dpi: dpi, k: k)

        // Assert — every pixel matches a brute-force local mean/std Sauvola
        for y in stride(from: 0, to: h, by: 7) {
            for x in stride(from: 0, to: w, by: 5) {
                var sum = 0.0
                var sq = 0.0
                var n = 0.0
                for yy in max(0, y - r)..<min(h, y + r + 1) {
                    for xx in max(0, x - r)..<min(w, x + r + 1) {
                        let v = Double(g.pixels[yy * w + xx])
                        sum += v
                        sq += v * v
                        n += 1
                    }
                }
                let mean = sum / n
                let sd = max(0, sq / n - mean * mean).squareRoot()
                let t = mean * (1 + k * (sd / Binarize.dynamicRange - 1))
                XCTAssertEqual(
                    banded[x, y], Double(g.pixels[y * w + x]) < t,
                    "mismatch at (\(x),\(y))"
                )
            }
        }
    }
}
