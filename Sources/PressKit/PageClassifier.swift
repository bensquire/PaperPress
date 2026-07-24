import Foundation

/// Decides whether a rendered page is high-contrast document content
/// (safe to threshold to 1-bit) or photographic/continuous-tone
/// (kept as grayscale JPEG).
public enum PageClassifier {
    public enum Kind: Equatable {
        case text
        case photo
    }

    /// A document page is mostly blank paper: one dominant light histogram
    /// spike, with ink and stroke-edge transitions holding only a small
    /// share. Continuous-tone content has no such spike. (Otsu separability
    /// was tried first and fails on sparse-ink pages — thin-stroke edge
    /// pixels blow up the ink class variance until real text scores like a
    /// gradient.) A borderline page falls to JPEG, the side that never
    /// destroys content.
    static let paperFractionThreshold = 0.6
    /// "Near the paper peak" = within this many gray levels of the mode.
    static let paperBand = 20
    /// Maximum fraction of the page allowed to be smooth midtone before
    /// it counts as continuous-tone content.
    static let smoothMidtoneThreshold = 0.08

    public static func classify(_ g: Pipeline.GrayImage) -> Kind {
        let hist = Pipeline.histogram(g)
        let total = Double(g.pixels.count)
        guard total > 0 else { return .text }

        // Densest ±paperBand window in the histogram = the paper peak.
        // (A single-bin mode is fragile: paper grain spreads the peak over
        // many bins while solid ink can concentrate in one.)
        var bandMass = [Double](repeating: 0, count: 256)
        for c in 0..<256 {
            for v in max(0, c - paperBand)...min(255, c + paperBand) {
                bandMass[c] += hist[v]
            }
        }
        let peak = bandMass.indices.max(by: { bandMass[$0] < bandMass[$1] })!
        // Paper must be light; a dark peak means continuous tone (or an
        // inverted/washed scan, which 1-bit would mangle anyway).
        guard peak >= 128 else { return .photo }
        guard bandMass[peak] / total >= paperFractionThreshold else { return .photo }

        // Histogram shape isn't enough: gamma-skewed gradients can pack
        // most pixels into one light band too. The spatial tell: on a
        // document, midtone pixels only occur at stroke edges (high local
        // contrast); smooth midtone areas mean continuous-tone content.
        let midLo = 40
        let midHi = peak - paperBand - 5
        guard midHi > midLo else { return .text }
        var smoothMid = 0
        var samples = 0
        let w = g.width
        let step = max(1, min(g.width, g.height) / 512)
        var y = 1
        while y < g.height - 1 {
            var x = 1
            while x < w - 1 {
                samples += 1
                let v = Int(g.pixels[y * w + x])
                if v >= midLo, v <= midHi {
                    let n = [
                        g.pixels[y * w + x - 1], g.pixels[y * w + x + 1],
                        g.pixels[(y - 1) * w + x], g.pixels[(y + 1) * w + x],
                    ]
                    if Int(n.max()!) - Int(n.min()!) < 12 {
                        smoothMid += 1
                    }
                }
                x += step
            }
            y += step
        }
        guard samples > 0 else { return .text }
        return Double(smoothMid) / Double(samples) <= smoothMidtoneThreshold
            ? .text : .photo
    }
}
