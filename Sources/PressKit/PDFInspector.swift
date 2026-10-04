import CoreGraphics
import Foundation

/// Analyses an existing PDF to decide whether PaperPress can usefully
/// re-compress it: which pages are full-page scans (and at what native
/// resolution), which are born-digital, and whether the file is already
/// compact.
public enum PDFInspector {
    public enum PageKind: Equatable, Sendable {
        /// Page dominated by one full-page raster image.
        /// `dpi` is the image's implied resolution; `compact` means the
        /// image is already archival-compact (1-bit CCITT/JBIG2, or
        /// 4-bit grayscale).
        case scan(dpi: Int, compact: Bool)
        /// Real text/vector content, no full-page scan image.
        case bornDigital
    }

    public struct PageInfo: Equatable, Sendable {
        public let kind: PageKind
        /// Displayed size in points (crop box, rotation applied) — the
        /// size the converted page comes out at.
        public let widthPt: Double
        public let heightPt: Double
    }

    public enum Verdict: Equatable, Sendable, Codable {
        case convert
        case passThrough(PassReason)
    }

    public enum PassReason: Equatable, Sendable, Codable {
        case bornDigital
        /// Carries this app's Producer marker — converting again would
        /// only re-encode it.
        case alreadyProcessed
        case alreadyCompact
        case alreadySmall
    }

    public struct Report: Sendable {
        public let url: URL
        public let fileBytes: Int
        public let pages: [PageInfo]
        public let verdict: Verdict
        /// Rough size after conversion (heuristic, from the page sizes and
        /// resolutions; the converter reports the real figure).
        public let estimatedBytes: Int
    }

    /// Bytes per scan page below which a file is considered not worth
    /// converting.
    public static let smallEnoughBytesPerPage = 45_000
    /// Expected G4 output density at scan resolution — measured ~20 KB for
    /// a text A4 at 300 dpi (8.7 Mpx). Drives the review-table estimate.
    static let estimatedBytesPerPixel = 0.0023

    /// Inspects many files at once — parsing, a few milliseconds a file — and
    /// hands each result to `each` as it lands, in the caller's isolation (the
    /// window's model applies them on the main actor; the helper collects
    /// them). The one analysis loop the window, the queue and the helper share.
    nonisolated(nonsending) public static func inspectAll(
        _ urls: [URL], each: (Int, Result<Report, any Error>) async -> Void
    ) async {
        typealias Inspected = (Int, Result<Report, any Error>)
        await withTaskGroup(of: Inspected.self) { group in
            var next = 0
            func add(into group: inout TaskGroup<Inspected>) {
                guard next < urls.count, !Task.isCancelled else { return }
                let (index, url) = (next, urls[next])
                next += 1
                group.addTask { (index, Result { try inspect(url) }) }
            }
            for _ in 0..<max(1, ProcessInfo.processInfo.activeProcessorCount) {
                add(into: &group)
            }
            for await (index, result) in group {
                await each(index, result)
                add(into: &group)
            }
        }
    }

    public static func inspect(_ url: URL) throws -> Report {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else {
            throw PressError.scanFailed("Cannot open PDF \(url.lastPathComponent)")
        }
        guard doc.isUnlocked else {
            throw PressError.scanFailed("\(url.lastPathComponent) is password-protected")
        }
        // A size that can't be read is an error, not 0 bytes — 0 would
        // read as "already small" and skip the file.
        guard let fileBytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw PressError.scanFailed("Cannot read the size of \(url.lastPathComponent)")
        }
        let processedHere = producerIsPaperPress(doc)

        // One PageInfo per document page, unconditionally — Converter relies
        // on positional alignment with page numbers. Already-converted
        // files skip per-page classification: their verdict is settled and
        // nothing downstream reads page kinds on the pass-through path.
        var pages: [PageInfo] = []
        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else {
                pages.append(PageInfo(kind: .bornDigital, widthPt: 595, heightPt: 842))
                continue
            }
            let shown = page.visibleSize
            let kind = processedHere ? PageKind.bornDigital : classify(page: page)
            pages.append(PageInfo(kind: kind, widthPt: shown.width, heightPt: shown.height))
        }

        let scans = pages.filter {
            if case .scan = $0.kind { return true }
            return false
        }
        let verdict: Verdict
        if processedHere {
            verdict = .passThrough(.alreadyProcessed)
        } else if scans.isEmpty {
            verdict = .passThrough(.bornDigital)
        } else if scans.allSatisfy({
            if case let .scan(_, compact) = $0.kind { return compact }
            return false
        }) {
            verdict = .passThrough(.alreadyCompact)
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

    /// The processing resolution Converter uses for text pages — read
    /// from the library defaults so the estimate can't drift from the
    /// converter (the inspector has no per-run Settings).
    static let assumedTextDpi = Double(Converter.Settings().dpiCap)
    static let assumedMinG4Dpi = Converter.Settings().minG4Dpi
    /// 4-bit grayscale output density at native resolution: levelled and
    /// deflated, a 150 dpi letter's full pages came to 0.09–0.11 bytes a
    /// pixel.
    static let estimatedGray4BytesPerPixel = 0.1

    /// Expected output size of one converted page. Pages scanned below
    /// the G4 resolution floor stay grayscale at native resolution
    /// (mirroring the converter's dpi gate); the converter may also
    /// demote adequate-resolution pages on *measured* damage, which
    /// inspection can't predict — those come out larger than estimated.
    static func estimatedPageBytes(_ page: PageInfo) -> Int {
        if case let .scan(native, _) = page.kind, native < assumedMinG4Dpi {
            let px =
                page.widthPt / 72 * Double(native) * (page.heightPt / 72 * Double(native))
            return max(8_000, Int(px * estimatedGray4BytesPerPixel))
        }
        let px =
            page.widthPt / 72 * assumedTextDpi * (page.heightPt / 72 * assumedTextDpi)
        return max(8_000, Int(px * estimatedBytesPerPixel))
    }

    /// True when the document's Info Producer names this app — output we
    /// wrote ourselves, already converted. Exact or version-suffixed match
    /// only ("PaperPress", "PaperPress 1.2"); a substring check would let
    /// an unrelated producer name false-positive into a pass-through.
    private static func producerIsPaperPress(_ doc: CGPDFDocument) -> Bool {
        guard let info = doc.info else { return false }
        var producer: CGPDFStringRef?
        guard CGPDFDictionaryGetString(info, "Producer", &producer),
            let producer,
            let str = CGPDFStringCopyTextString(producer) as String?
        else { return false }
        let marker = PDFWriter.producerMarker
        return str == marker || str.hasPrefix(marker + " ")
    }

    // MARK: Page classification

    private static func classify(page: CGPDFPage) -> PageKind {
        guard let dict = page.dictionary,
            let img = largestImage(inPageDict: dict)
        else {
            return .bornDigital
        }
        // A "scan page" is one whose largest image plausibly covers the whole
        // page: aspect ratios match and the implied resolution is scanner-like.
        // OCR'd scans also carry a text layer, so text presence doesn't veto.
        // Measured against the media box, which the scan image fills; a
        // crop only hides part of it.
        let media = page.orientedSize(of: .mediaBox)
        let widthPt = Double(media.width)
        let heightPt = Double(media.height)
        let pageAspect = widthPt / heightPt
        let imgAspect = Double(img.w) / Double(img.h)
        let upright = abs(pageAspect - imgAspect) / pageAspect < 0.2
        let sideways = !upright && abs(pageAspect - 1 / imgAspect) / pageAspect < 0.2
        guard upright || sideways else { return .bornDigital }
        // A sideways image — a page shown with /Rotate 90, or a scan drawn
        // rotated — runs its width along the page's height.
        let (alongWidth, alongHeight) = upright ? (img.w, img.h) : (img.h, img.w)
        let dpiX = Double(alongWidth) / (widthPt / 72)
        let dpiY = Double(alongHeight) / (heightPt / 72)
        guard dpiX >= 40, dpiX <= 1300, abs(dpiX - dpiY) / dpiX < 0.35 else {
            return .bornDigital
        }
        return .scan(dpi: Int(dpiX.rounded()), compact: img.compact)
    }

    /// True when the file at `url` is a PDF this app wrote (its Producer
    /// carries the marker).
    public static func isPaperPressOutput(_ url: URL) -> Bool {
        guard let doc = CGPDFDocument(url as CFURL) else { return false }
        return producerIsPaperPress(doc)
    }

    private struct ImageRef {
        let w: Int
        let h: Int
        let compact: Bool
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
                    let compact =
                        bpc == 1 || bpc == 4
                        || filterNames(sdict).contains { name in
                            name == "CCITTFaxDecode" || name == "JBIG2Decode"
                        }
                    if w * h > (best.map { $0.w * $0.h } ?? 0) {
                        best = ImageRef(w: w, h: h, compact: compact)
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
