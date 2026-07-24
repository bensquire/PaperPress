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
    /// Mask is grown this many pixels so the artifact's antialiased
    /// fringe goes with it.
    static let fringePx = 2

    /// Whitens qualifying edge components in place (to the paper level),
    /// so every downstream encoding — G4, 4-bit, JPEG — benefits.
    public static func removeScanBorders(_ g: inout Pipeline.GrayImage, dpi: Int) {
        let w = g.width, h = g.height
        guard w > 8, h > 8 else { return }
        guard let (inkLevel, paperLevel) = Binarize.classMeans(g),
            paperLevel - inkLevel > 20
        else { return }
        let dark = UInt8(clamping: Int((inkLevel + paperLevel) / 2))
        let band = max(4, Int(bandMM / 25.4 * Double(dpi)))

        // Flood-fill dark components from every dark border pixel,
        // tracking how deep into the page each component reaches.
        var mask = [Bool](repeating: false, count: w * h)
        var visited = [Bool](repeating: false, count: w * h)
        var stack = [Int]()
        var component = [Int]()

        func depth(_ idx: Int) -> Int {
            let x = idx % w, y = idx / w
            return min(min(x, w - 1 - x), min(y, h - 1 - y))
        }

        var seeds: [Int] = []
        for x in 0..<w {
            seeds.append(x)
            seeds.append((h - 1) * w + x)
        }
        for y in 0..<h {
            seeds.append(y * w)
            seeds.append(y * w + w - 1)
        }

        for seed in seeds where g.pixels[seed] < dark && !visited[seed] {
            component.removeAll(keepingCapacity: true)
            stack.removeAll(keepingCapacity: true)
            stack.append(seed)
            visited[seed] = true
            var maxDepth = 0
            while let idx = stack.popLast() {
                component.append(idx)
                maxDepth = max(maxDepth, depth(idx))
                let x = idx % w, y = idx / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let n = ny * w + nx
                    if !visited[n], g.pixels[n] < dark {
                        visited[n] = true
                        stack.append(n)
                    }
                }
            }
            if maxDepth <= band {
                for idx in component {
                    mask[idx] = true
                }
            }
        }

        guard mask.contains(true) else { return }

        // Grow the mask to take the antialiased fringe, then whiten.
        var grown = mask
        for _ in 0..<fringePx {
            var next = grown
            for y in 0..<h {
                for x in 0..<w where !grown[y * w + x] {
                    let i = y * w + x
                    if (x > 0 && grown[i - 1]) || (x < w - 1 && grown[i + 1])
                        || (y > 0 && grown[i - w]) || (y < h - 1 && grown[i + w])
                    {
                        next[i] = true
                    }
                }
            }
            grown = next
        }
        let paper = UInt8(clamping: Int(paperLevel.rounded()))
        for i in 0..<(w * h) where grown[i] {
            g.pixels[i] = paper
        }
    }
}
