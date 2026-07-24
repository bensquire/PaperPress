import CoreGraphics
import Foundation

/// Analyses an existing PDF to decide whether PaperPress can usefully
/// re-compress it: which pages are full-page scans (and at what native
/// resolution), which are born-digital, and whether the file is already
/// compact.
public enum PDFInspector {
    public enum PageKind: Equatable {
        /// Page dominated by one full-page raster image.
        /// `dpi` is the image's implied resolution; `oneBit` means the
        /// image is already CCITT/JBIG2 1-bit compressed.
        case scan(dpi: Int, oneBit: Bool)
        /// Real text/vector content, no full-page scan image.
        case bornDigital
    }

    public struct PageInfo: Equatable {
        public let kind: PageKind
        public let widthPt: Double
        public let heightPt: Double
    }

    public enum Verdict: Equatable {
        case convert
        case passThrough(PassReason)
    }

    public enum PassReason: Equatable {
        case bornDigital
        case alreadyOneBit
        case alreadySmall
    }

    public struct Report {
        public let url: URL
        public let fileBytes: Int
        public let pages: [PageInfo]
        public let verdict: Verdict
        /// Rough size after conversion (heuristic; refined during convert).
        public let estimatedBytes: Int
    }

    /// Bytes per scan page below which a file is considered not worth
    /// converting.
    public static let smallEnoughBytesPerPage = 45_000
    /// Expected G4 output density at scan resolution — measured ~20 KB for
    /// a text A4 at 300 dpi (8.7 Mpx). Drives the review-table estimate.
    static let estimatedBytesPerPixel = 0.0023

    public static func inspect(_ url: URL) throws -> Report {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else {
            throw PressError.scanFailed("Cannot open PDF \(url.lastPathComponent)")
        }
        guard doc.isUnlocked else {
            throw PressError.scanFailed("\(url.lastPathComponent) is password-protected")
        }
        let fileBytes =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            .flatMap { $0 } ?? 0

        // One PageInfo per document page, unconditionally — Converter relies
        // on positional alignment with page numbers.
        var pages: [PageInfo] = []
        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else {
                pages.append(PageInfo(kind: .bornDigital, widthPt: 595, heightPt: 842))
                continue
            }
            let box = page.orientedMediaBoxSize
            let kind = classify(page: page, widthPt: box.width, heightPt: box.height)
            pages.append(PageInfo(kind: kind, widthPt: box.width, heightPt: box.height))
        }

        let scans = pages.filter {
            if case .scan = $0.kind { return true }
            return false
        }
        let verdict: Verdict
        if scans.isEmpty {
            verdict = .passThrough(.bornDigital)
        } else if scans.allSatisfy({
            if case .scan(_, true) = $0.kind { return true }
            return false
        }) {
            verdict = .passThrough(.alreadyOneBit)
        } else if fileBytes / scans.count < smallEnoughBytesPerPage {
            verdict = .passThrough(.alreadySmall)
        } else {
            verdict = .convert
        }
        let estimated =
            verdict == .convert
            ? pages.map(estimatedPageBytes).reduce(0, +)
            : fileBytes
        return Report(
            url: url, fileBytes: fileBytes, pages: pages,
            verdict: verdict, estimatedBytes: estimated
        )
    }

    /// Expected output size of one converted page: pixel count at the
    /// processing resolution (text pages always render at ~300 dpi,
    /// upsampling low-res sources) × measured G4 density.
    static func estimatedPageBytes(_ page: PageInfo) -> Int {
        let dpi = 300.0
        let px = page.widthPt / 72 * dpi * (page.heightPt / 72 * dpi)
        return max(8_000, Int(px * estimatedBytesPerPixel))
    }

    // MARK: Page classification

    private static func classify(
        page: CGPDFPage, widthPt: Double, heightPt: Double
    ) -> PageKind {
        guard let dict = page.dictionary,
            let img = largestImage(inPageDict: dict)
        else {
            return .bornDigital
        }
        // A "scan page" is one whose largest image plausibly covers the whole
        // page: aspect ratios match and the implied resolution is scanner-like.
        // OCR'd scans also carry a text layer, so text presence doesn't veto.
        let pageAspect = widthPt / heightPt
        let imgAspect = Double(img.w) / Double(img.h)
        let dpiX = Double(img.w) / (widthPt / 72)
        let dpiY = Double(img.h) / (heightPt / 72)
        let aspectMatch =
            abs(pageAspect - imgAspect) / pageAspect < 0.2
            || abs(pageAspect - 1 / imgAspect) / pageAspect < 0.2
        guard aspectMatch, dpiX >= 40, dpiX <= 1300, abs(dpiX - dpiY) / dpiX < 0.35 else {
            return .bornDigital
        }
        return .scan(dpi: Int(dpiX.rounded()), oneBit: img.oneBit)
    }

    private struct ImageRef {
        let w: Int
        let h: Int
        let oneBit: Bool
    }

    private static func largestImage(inPageDict dict: CGPDFDictionaryRef) -> ImageRef? {
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources),
            let resources
        else { return nil }
        return largestImage(inResources: resources, depth: 0)
    }

    private static func largestImage(
        inResources resources: CGPDFDictionaryRef, depth: Int
    ) -> ImageRef? {
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
            let xobjects
        else { return nil }

        var best: ImageRef?
        CGPDFDictionaryApplyBlock(
            xobjects,
            { _, object, _ in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                    let sdict = CGPDFStreamGetDictionary(stream)
                else { return true }
                var subtype: UnsafePointer<CChar>?
                CGPDFDictionaryGetName(sdict, "Subtype", &subtype)
                switch subtype.map({ String(cString: $0) }) {
                case "Image":
                    var w: CGPDFInteger = 0
                    var h: CGPDFInteger = 0
                    CGPDFDictionaryGetInteger(sdict, "Width", &w)
                    CGPDFDictionaryGetInteger(sdict, "Height", &h)
                    var bpc: CGPDFInteger = 0
                    CGPDFDictionaryGetInteger(sdict, "BitsPerComponent", &bpc)
                    let oneBit =
                        bpc == 1
                        || filterNames(sdict).contains { name in
                            name == "CCITTFaxDecode" || name == "JBIG2Decode"
                        }
                    if w * h > (best.map { $0.w * $0.h } ?? 0) {
                        best = ImageRef(w: w, h: h, oneBit: oneBit)
                    }
                case "Form" where depth < 2:
                    // Some producers wrap the scan image in a Form XObject.
                    var inner: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(sdict, "Resources", &inner),
                        let inner,
                        let found = largestImage(inResources: inner, depth: depth + 1),
                        found.w * found.h > (best.map { $0.w * $0.h } ?? 0)
                    {
                        best = found
                    }
                default:
                    break
                }
                return true
            }, nil
        )
        return best
    }

    private static func filterNames(_ sdict: CGPDFDictionaryRef) -> [String] {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(sdict, "Filter", &name), let name {
            return [String(cString: name)]
        }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(sdict, "Filter", &array), let array else { return [] }
        var names: [String] = []
        for i in 0..<CGPDFArrayGetCount(array) {
            var n: UnsafePointer<CChar>?
            if CGPDFArrayGetName(array, i, &n), let n {
                names.append(String(cString: n))
            }
        }
        return names
    }
}
