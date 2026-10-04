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
        // strip reuse and band boundaries are exercised, with dark marks so
        // the stroke cap engages
        var rng = SeededRandom()
        let w = 90, h = 300
        var pixels = [UInt8](repeating: 0, count: w * h)
        for i in 0..<pixels.count {
            pixels[i] = rng.next() % 8 == 0 ? 20 &+ (rng.next() % 40) : 200 &+ (rng.next() % 50)
        }
        let g = Pipeline.GrayImage(width: w, height: h, pixels: pixels)
        let dpi = 300
        let r = Binarize.window(dpi: dpi) / 2
        let k = 0.15
        let cap = Binarize.levels(g).map(Binarize.StrokeCap.init)

        // Act
        let banded = Binarize.sauvola(g, dpi: dpi, k: k)

        // Assert — every pixel matches the threshold from a brute-force
        // local mean and variance (the banded integrals are under test, not
        // the threshold formula they feed)
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
                let t = Binarize.threshold(
                    mean: mean, variance: max(0, sq / n - mean * mean), k: k, cap: cap)
                XCTAssertEqual(
                    banded[x, y], Double(g.pixels[y * w + x]) < t,
                    "mismatch at (\(x),\(y))"
                )
            }
        }
    }

    func test_sauvola_keepsALoneDotOnSlightlyBrighterPaper() {
        // Arrange — text sets the page's paper at 240; a patch a shade
        // brighter holds one 6 px black dot, a full stop on its own (the
        // case where the stroke cap's estimate ran away: uncapped, it
        // erased all 36 pixels)
        var page = Fixtures.textPage(width: 600, height: 800)
        for i in page.pixels.indices where page.pixels[i] == 250 { page.pixels[i] = 240 }
        var rng = SeededRandom(seed: 3)
        for y in 700..<790 {
            for x in 400..<590 {
                page.pixels[y * 600 + x] = rng.next() % 5 == 0 ? 241 : 242
            }
        }
        for y in 740..<746 { for x in 490..<496 { page.pixels[y * 600 + x] = 20 } }

        // Act
        let bw = Binarize.sauvola(page, dpi: 300)

        // Assert
        let dot = (740..<746).flatMap { y in (490..<496).map { x in bw[x, y] } }
        XCTAssertEqual(dot.count { $0 }, 36, "the dot should survive whole")
    }

    /// How much ink a page carries once averaged down by `factor`: 0 for
    /// paper, 1 for ink at the given levels.
    private func inkMass(
        _ g: Pipeline.GrayImage, ink: Double, paper: Double, averagedBy factor: Double
    ) -> Double {
        let small = g.resampled(scale: 1 / factor)
        return small.pixels.reduce(0.0) {
            $0 + max(0, min(1, (paper - Double($1)) / (paper - ink)))
        } / Double(small.pixels.count)
    }

    func test_sauvola_keepsDarkPrintsWeight() {
        // Arrange — real type (ink 13, paper 250) as a 150 dpi scan rendered
        // at 300, the way the converter sees it
        let gray = Fixtures.renderedTextPage(fontSize: 20, ink: 0.05).resampled(scale: 2)

        // Act
        let bw = Binarize.sauvola(gray, dpi: 300)

        // Assert — about the scan's own weight (Sauvola alone: 1.27×)
        let binary = Pipeline.GrayImage(
            width: bw.width, height: bw.height, pixels: bw.ink.map { $0 ? 0 : 255 })
        let weight =
            inkMass(binary, ink: 0, paper: 255, averagedBy: 2)
            / inkMass(gray, ink: 0.05 * 255, paper: 250, averagedBy: 2)
        XCTAssertEqual(weight, 1, accuracy: 0.12, "stroke weight \(weight)× the scan's")
    }
}

final class DespeckleTests: XCTestCase {
    func test_despeckle_removesExactlyWhatComponentLabellingRemoves() {
        // Arrange — random ink at ~16% density: lone dots, pairs, triples
        // and larger clumps, all touching in every arrangement
        var rng = SeededRandom()
        let w = 300, h = 200
        let ink = (0..<(w * h)).map { _ in rng.next() < 40 }
        var labelled = Pipeline.BinaryImage(width: w, height: h, ink: ink)
        var searched = labelled

        // Act
        Pipeline.cleanComponents(&labelled, removeBorder: false)
        Pipeline.despeckle(&searched)

        // Assert
        XCTAssertNotEqual(searched.ink, ink, "fixture should contain specks")
        XCTAssertEqual(searched.ink, labelled.ink, "both should remove the same pixels")
    }
}
