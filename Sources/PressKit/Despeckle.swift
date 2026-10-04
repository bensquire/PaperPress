extension Pipeline {
    /// Removes ink components smaller than `minSpeck` pixels (dust),
    /// 8-connected — the same result as
    /// `cleanComponents(&bw, minSpeck:, removeBorder: false)` without its
    /// page-sized Int32 label map (35 MB at A4/300 dpi). A speck is tiny,
    /// so each search stops as soon as it has seen `minSpeck` pixels:
    /// constant work per ink pixel, and memory for `minSpeck` indices.
    public static func despeckle(_ bw: inout BinaryImage, minSpeck: Int = 4) {
        let w = bw.width, h = bw.height
        guard minSpeck > 1, w > 0, h > 0 else { return }
        var found: [Int] = []
        found.reserveCapacity(minSpeck)
        bw.ink.withUnsafeMutableBufferPointer { ink in
            for start in 0..<(w * h) where ink[start] {
                found.removeAll(keepingCapacity: true)
                found.append(start)
                var next = 0
                search: while next < found.count {
                    let idx = found[next]
                    next += 1
                    let x = idx % w, y = idx / w
                    for ny in max(0, y - 1)...min(h - 1, y + 1) {
                        for nx in max(0, x - 1)...min(w - 1, x + 1) {
                            let n = ny * w + nx
                            if ink[n], !found.contains(n) {
                                found.append(n)
                                if found.count >= minSpeck { break search }
                            }
                        }
                    }
                }
                if found.count < minSpeck {
                    for i in found { ink[i] = false }
                }
            }
        }
    }
}
