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

    /// How much a binarisation damaged a page, 0…1-ish. Both images are
    /// box-downsampled and the binary one is mapped back onto the gray
    /// ink/paper levels; the score is their mean disagreement over content
    /// blocks, normalised by the ink-paper contrast. Legible binarisation
    /// reproduces the downsampled gray closely (small print blurs the same
    /// way in both); destroyed print — merged or fragmented strokes —
    /// diverges hard.
    public static func damage(
        _ g: Pipeline.GrayImage, _ bw: Pipeline.BinaryImage, block: Int = 4
    ) -> Double {
        let w = g.width, h = g.height
        let sw = w / block, sh = h / block
        guard sw > 0, sh > 0 else { return 0 }

        let t = Int(Pipeline.otsuThreshold(g))
        var inkSum = 0.0, inkN = 0.0, paperSum = 0.0, paperN = 0.0
        for p in g.pixels {
            if Int(p) < t {
                inkSum += Double(p)
                inkN += 1
            } else {
                paperSum += Double(p)
                paperN += 1
            }
        }
        guard inkN > 0, paperN > 0 else { return 0 }
        let inkLevel = inkSum / inkN
        let paperLevel = paperSum / paperN
        let contrast = paperLevel - inkLevel
        guard contrast > 20 else { return 0 }

        var diffSum = 0.0
        var blocks = 0.0
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
                // Only structured content blocks: dark enough to hold ink
                // AND locally contrasty (text strokes/edges). Flat gray —
                // decorative banners, tints — is continuous-tone that 1-bit
                // legitimately drops; it must not dominate the score.
                guard gMean < paperLevel - 0.15 * contrast,
                    gMax - gMin > 0.3 * contrast
                else { continue }
                let bMean = (inkFrac / n) * inkLevel + (1 - inkFrac / n) * paperLevel
                diffSum += abs(bMean - gMean) / contrast
                blocks += 1
            }
        }
        return blocks > 0 ? diffSum / blocks : 0
    }

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

        // Integral images of value and value² over a (w+1)×(h+1) grid.
        var sum = [UInt64](repeating: 0, count: (w + 1) * (h + 1))
        var sumSq = [UInt64](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum: UInt64 = 0
            var rowSq: UInt64 = 0
            let above = y * (w + 1)
            let here = (y + 1) * (w + 1)
            for x in 0..<w {
                let v = UInt64(g.pixels[y * w + x])
                rowSum += v
                rowSq += v * v
                sum[here + x + 1] = sum[above + x + 1] + rowSum
                sumSq[here + x + 1] = sumSq[above + x + 1] + rowSq
            }
        }

        var ink = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h, y + r + 1)
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                let n = Double((y1 - y0) * (x1 - x0))
                let a = y0 * (w + 1), b = y1 * (w + 1)
                let s1 = Double(
                    sum[b + x1] &+ sum[a + x0] &- sum[a + x1] &- sum[b + x0])
                let s2 = Double(
                    sumSq[b + x1] &+ sumSq[a + x0] &- sumSq[a + x1] &- sumSq[b + x0])
                let mean = s1 / n
                let variance = max(0, s2 / n - mean * mean)
                let t = mean * (1 + k * (variance.squareRoot() / dynamicRange - 1))
                ink[y * w + x] = Double(g.pixels[y * w + x]) < t
            }
        }
        return Pipeline.BinaryImage(width: w, height: h, ink: ink)
    }
}
