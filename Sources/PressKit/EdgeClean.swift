import Foundation

/// Removes scan-edge artifacts — the black bands and corner shadows a
/// scanner lid or skewed feed leaves around a page. PaperDrop's rule
/// (delete anything touching the border) is wrong for already-cropped
/// pages, where tables and letterheads legitimately reach the edge; here
/// a border-touching dark component is removed only when it lies wholly
/// within a thin band along the edges. A shadow hugs the border; real
/// content extends into the page.
public enum EdgeClean {
    /// Band width scan artifacts must stay inside to be removed.
    static let bandMM = 10.0
    /// Whitening extends this many pixels past each artifact so its
    /// antialiased fringe goes with it.
    static let fringePx = 2

    /// Whitens qualifying edge components in place (to the paper level),
    /// so every downstream stage — G4, 4-bit, JPEG, OCR, and the damage
    /// measurement that decides demotion — sees the cleaned page.
    public static func removeScanBorders(_ g: inout Pipeline.GrayImage, dpi: Int) {
        let w = g.width, h = g.height
        guard w > 8, h > 8 else { return }
        guard let (inkLevel, paperLevel) = Binarize.classMeans(g),
            paperLevel - inkLevel > Binarize.minContrast
        else { return }
        let dark = UInt8(clamping: Int((inkLevel + paperLevel) / 2))

        // Dark border pixels seed the flood fill; most pages have none,
        // so find them before allocating anything page-sized.
        var seeds: [Int] = []
        for x in 0..<w {
            if g.pixels[x] < dark { seeds.append(x) }
            if g.pixels[(h - 1) * w + x] < dark { seeds.append((h - 1) * w + x) }
        }
        for y in 1..<(h - 1) {
            if g.pixels[y * w] < dark { seeds.append(y * w) }
            if g.pixels[y * w + w - 1] < dark { seeds.append(y * w + w - 1) }
        }
        guard !seeds.isEmpty else { return }

        let band = max(4, Int(bandMM / 25.4 * Double(dpi)))
        let paper = UInt8(clamping: Int(paperLevel.rounded()))
        var visited = [Bool](repeating: false, count: w * h)
        var stack = [Int]()
        var component = [Int]()

        // Re-check darkness: an earlier component's fringe may already
        // have whitened this seed.
        for seed in seeds where !visited[seed] && g.pixels[seed] < dark {
            component.removeAll(keepingCapacity: true)
            stack.removeAll(keepingCapacity: true)
            stack.append(seed)
            visited[seed] = true
            var maxDepth = 0
            while let idx = stack.popLast() {
                component.append(idx)
                let x = idx % w, y = idx / w
                maxDepth = max(maxDepth, min(min(x, w - 1 - x), min(y, h - 1 - y)))
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let n = ny * w + nx
                    if !visited[n], g.pixels[n] < dark {
                        visited[n] = true
                        stack.append(n)
                    }
                }
            }
            guard maxDepth <= band else { continue }

            // Whiten the component plus a diamond fringe around each pixel
            // (equivalent to fringePx rounds of 4-neighbour dilation).
            for idx in component {
                let x = idx % w, y = idx / w
                for dy in -fringePx...fringePx {
                    let ny = y + dy
                    guard ny >= 0, ny < h else { continue }
                    let span = fringePx - abs(dy)
                    for dx in -span...span {
                        let nx = x + dx
                        guard nx >= 0, nx < w else { continue }
                        g.pixels[ny * w + nx] = paper
                    }
                }
            }
        }
    }
}
