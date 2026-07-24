import Foundation

/// Local adaptive binarisation (Sauvola). A global Otsu threshold loses
/// faint print on pages that also carry bold black content — the split
/// lands between the two ink shades and the faint one becomes "paper".
/// Sauvola judges each pixel against its neighbourhood's mean and
/// standard deviation instead: T = m·(1 + k·(s/R − 1)). Anywhere locally
/// flat (blank paper) the threshold drops well below the mean, so noise
/// stays white; anywhere with local contrast (text, however faded) the
/// threshold rises to meet it.
public enum Binarize {
    /// Sauvola dynamic-range constant (half the gray range).
    static let dynamicRange = 128.0
    /// Minimum ink-paper contrast for class statistics to mean anything
    /// (shared by damage() and EdgeClean).
    static let minContrast = 20.0
    /// damage(): a block counts as content when its mean is at least this
    /// far (× contrast) below paper…
    static let contentDarknessGate = 0.15
    /// …AND its local range exceeds this (× contrast) — text strokes, not
    /// flat decorative gray, which 1-bit legitimately drops.
    static let contentContrastGate = 0.3
    /// Tile edge in blocks (~1 inch at 300 dpi with 4px blocks): the
    /// granularity at which "worst region" is judged.
    static let tileBlocks = 64
    /// A tile needs at least this many content blocks to be scored —
    /// stray marks in an otherwise empty tile are not a "region".
    static let minTileContentBlocks = 24
    /// A tile's ink/paper levels come from its own pixels when at least
    /// this many fall in the class; otherwise the page-level fallback.
    static let minTileClassPixels = 50.0
    /// Floor on tile-local contrast (× page contrast) so flat or
    /// near-empty tiles don't divide by a vanishing denominator. Distinct
    /// from contentContrastGate despite the coincidental value.
    static let minTileContrastFraction = 0.3

    /// Ink and paper class means at the Otsu split, derived from the
    /// histogram in O(256) — the same quantities Otsu's search computes
    /// internally, without another full-image pass.
    static func classMeans(_ g: Pipeline.GrayImage)
        -> (ink: Double, paper: Double)?
    {
        let hist = Pipeline.histogram(g)
        let total = hist.reduce(0, +)
        guard total > 0 else { return nil }
        let sumAll = (0..<256).reduce(0.0) { $0 + Double($1) * hist[$1] }
        var bestVar = -1.0
        var best: (ink: Double, paper: Double)?
        var cum = 0.0
        var cumSum = 0.0
        for t in 1..<256 {
            cum += hist[t - 1]
            cumSum += Double(t - 1) * hist[t - 1]
            if cum == 0 || cum == total { continue }
            let m0 = cumSum / cum
            let m1 = (sumAll - cumSum) / (total - cum)
            let v = cum * (total - cum) * (m0 - m1) * (m0 - m1)
            if v > bestVar {
                bestVar = v
                best = (m0, m1)
            }
        }
        return best
    }

    /// How much a binarisation damaged a page, 0…1-ish, judged by its
    /// WORST region: a reader condemns a page for one destroyed column,
    /// and a page mean lets a crisp centre dilute it (three successive
    /// threshold calibrations were falsified by exactly that).
    ///
    /// Both images are box-downsampled; per ~1-inch tile, the binary is
    /// mapped back onto the tile's OWN ink/paper gray levels and compared
    /// against the gray. Tile-local levels make the score tone-invariant:
    /// faint print rendered solid black — a rescue, not damage — agrees
    /// with itself, while merged strokes, filled counters, and lost
    /// strokes still diverge. The page score is the worst tile with
    /// enough content.
    public static func damage(
        _ g: Pipeline.GrayImage, _ bw: Pipeline.BinaryImage, block: Int = 4
    ) -> Double {
        let w = g.width, h = g.height
        let sw = w / block, sh = h / block
        guard sw > 0, sh > 0 else { return 0 }

        guard let (inkLevel, paperLevel) = classMeans(g) else { return 0 }
        let contrast = paperLevel - inkLevel
        guard contrast > minContrast else { return 0 }

        let tw = (sw + tileBlocks - 1) / tileBlocks
        let th = (sh + tileBlocks - 1) / tileBlocks

        // Pixel area the block grid covers; both passes ignore the
        // remainder beyond it.
        let cw = sw * block
        let ch = sh * block
        let tilePx = block * tileBlocks

        // Pass 1: per-tile ink/paper gray levels, classified by the binary.
        // Iterated in tile-column runs so the tile index is loop-invariant.
        var inkSum = [Double](repeating: 0, count: tw * th)
        var inkN = [Double](repeating: 0, count: tw * th)
        var papSum = [Double](repeating: 0, count: tw * th)
        var papN = [Double](repeating: 0, count: tw * th)
        for y in 0..<ch {
            let rowBase = y * w
            let tileRow = (y / block) / tileBlocks * tw
            for tx in 0..<tw {
                let t = tileRow + tx
                var iS = 0.0
                var iN = 0.0
                var pS = 0.0
                var pN = 0.0
                for x in (tx * tilePx)..<min(cw, (tx + 1) * tilePx) {
                    let v = Double(g.pixels[rowBase + x])
                    if bw.ink[rowBase + x] {
                        iS += v
                        iN += 1
                    } else {
                        pS += v
                        pN += 1
                    }
                }
                inkSum[t] += iS
                inkN[t] += iN
                papSum[t] += pS
                papN[t] += pN
            }
        }

        // Pass 2: per-block disagreement against tile-local levels.
        var tileDiff = [Double](repeating: 0, count: tw * th)
        var tileCount = [Double](repeating: 0, count: tw * th)
        for by in 0..<sh {
            for bx in 0..<sw {
                var gSum = 0.0
                var inkFrac = 0.0
                var gMin = 255.0
                var gMax = 0.0
                for dy in 0..<block {
                    let row = (by * block + dy) * w + bx * block
                    for dx in 0..<block {
                        let v = Double(g.pixels[row + dx])
                        gSum += v
                        gMin = min(gMin, v)
                        gMax = max(gMax, v)
                        if bw.ink[row + dx] { inkFrac += 1 }
                    }
                }
                let n = Double(block * block)
                let gMean = gSum / n
                // Only structured content blocks — see the gate constants.
                guard gMean < paperLevel - contentDarknessGate * contrast,
                    gMax - gMin > contentContrastGate * contrast
                else { continue }
                let t = (by / tileBlocks) * tw + (bx / tileBlocks)
                let tInk = inkN[t] > minTileClassPixels ? inkSum[t] / inkN[t] : inkLevel
                let tPap = papN[t] > minTileClassPixels ? papSum[t] / papN[t] : paperLevel
                let tContrast = max(tPap - tInk, minTileContrastFraction * contrast)
                let bMean = (inkFrac / n) * tInk + (1 - inkFrac / n) * tPap
                tileDiff[t] += abs(bMean - gMean) / tContrast
                tileCount[t] += 1
            }
        }
        var worst = 0.0
        for t in 0..<(tw * th) where tileCount[t] >= Double(minTileContentBlocks) {
            worst = max(worst, tileDiff[t] / tileCount[t])
        }
        return worst
    }

    /// Rows thresholded per band: integral tables are built per band over
    /// just the rows the band's windows reach, so transient memory is
    /// O(width × band) — ~7 MB — instead of two full-page UInt64 tables
    /// (~140 MB for an A4 at 300 dpi). The overlapping ±r rows are
    /// recomputed per band; the integral build is a small fraction of the
    /// pass, so the recompute is cheap.
    static let sauvolaBandRows = 128

    /// Adaptive threshold. `k` controls strictness (higher = less ink);
    /// the literature uses 0.2–0.5, but faded print sits barely below its
    /// local mean, so PaperPress runs gentler (0.15) — measured on real
    /// faded certificates, and still white on paper grain and typical
    /// bleed-through. The window scales with dpi (~1/6 inch) so behaviour
    /// is resolution-stable.
    public static func sauvola(
        _ g: Pipeline.GrayImage, dpi: Int, k: Double = 0.15
    ) -> Pipeline.BinaryImage {
        let w = g.width, h = g.height
        let window = max(25, dpi / 6) | 1
        let r = window / 2

        var ink = [Bool](repeating: false, count: w * h)
        let stride = w + 1
        let maxStripRows = sauvolaBandRows + 2 * r + 1
        // Integral strips of value and value², reused across bands. Row 0
        // and column 0 of each strip are the integral's zero border: never
        // written after the zero-filled allocation, so no per-band reset
        // is needed.
        var sum = [UInt64](repeating: 0, count: stride * (maxStripRows + 1))
        var sumSq = [UInt64](repeating: 0, count: stride * (maxStripRows + 1))

        // Unsafe buffers: these loops touch ~10 subscripts per pixel and
        // bounds checks measurably dominate at 8+ Mpx.
        sum.withUnsafeMutableBufferPointer { sumBuf in
            sumSq.withUnsafeMutableBufferPointer { sqBuf in
                g.pixels.withUnsafeBufferPointer { pix in
                    ink.withUnsafeMutableBufferPointer { out in
                        var bandStart = 0
                        while bandStart < h {
                            let bandEnd = min(h, bandStart + sauvolaBandRows)
                            // Strip covers every row the band's windows
                            // can touch.
                            let stripStart = max(0, bandStart - r)
                            let stripEnd = min(h, bandEnd + r)
                            for sy in 0..<(stripEnd - stripStart) {
                                var rowSum: UInt64 = 0
                                var rowSq: UInt64 = 0
                                let src = (stripStart + sy) * w
                                let above = sy * stride
                                let here = (sy + 1) * stride
                                for x in 0..<w {
                                    let v = UInt64(pix[src + x])
                                    rowSum += v
                                    rowSq += v * v
                                    sumBuf[here + x + 1] = sumBuf[above + x + 1] + rowSum
                                    sqBuf[here + x + 1] = sqBuf[above + x + 1] + rowSq
                                }
                            }
                            for y in bandStart..<bandEnd {
                                let y0 = max(0, y - r), y1 = min(h, y + r + 1)
                                let a = (y0 - stripStart) * stride
                                let b = (y1 - stripStart) * stride
                                let rowBase = y * w
                                for x in 0..<w {
                                    let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                                    let n = Double((y1 - y0) * (x1 - x0))
                                    let s1 = Double(
                                        sumBuf[b + x1] &+ sumBuf[a + x0]
                                            &- sumBuf[a + x1] &- sumBuf[b + x0])
                                    let s2 = Double(
                                        sqBuf[b + x1] &+ sqBuf[a + x0]
                                            &- sqBuf[a + x1] &- sqBuf[b + x0])
                                    let mean = s1 / n
                                    let variance = max(0, s2 / n - mean * mean)
                                    let t =
                                        mean
                                        * (1 + k
                                            * (variance.squareRoot() / dynamicRange - 1))
                                    out[rowBase + x] = Double(pix[rowBase + x]) < t
                                }
                            }
                            bandStart = bandEnd
                        }
                    }
                }
            }
        }
        return Pipeline.BinaryImage(width: w, height: h, ink: ink)
    }
}
