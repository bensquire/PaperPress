import CoreGraphics
import Foundation

/// Re-compresses one PDF: renders each page, thresholds document pages to
/// CCITT G4, keeps photographic pages as grayscale JPEG, re-OCRs, and
/// rebuilds a compact PDF. Falls back to copying the original when the
/// result wouldn't be meaningfully smaller.
public enum Converter {
    public struct Settings: Sendable {
        /// Pages are processed at their native scan resolution, capped here.
        public var dpiCap = 300
        /// Photographic pages get a lower cap — continuous tone gains
        /// nothing from document resolution and the JPEG bytes are the
        /// dominant cost.
        public var photoDpiCap = 150
        public var ocr = true
        public var jpegQuality = 0.6
        /// Output must be at least this fraction smaller than the input,
        /// else the original is copied through unchanged.
        public var minSavingFraction = 0.2
        public init() {}
    }

    /// Pages are classified on a cheap render at this resolution, so the
    /// text/photo decision doesn't shift when the user changes dpi caps.
    static let probeDpi = 100

    public struct FileResult {
        public let inputBytes: Int
        public let outputBytes: Int
        /// False = original copied through (pass-through verdict or the
        /// conversion didn't save enough).
        public let converted: Bool
        /// Per converted page: how it was encoded.
        public let pageKinds: [PageClassifier.Kind]
    }

    /// Convert (or pass through) `report.url`, writing the result to `outURL`.
    /// The output file keeps the source's modification date.
    public static func convert(
        report: PDFInspector.Report, to outURL: URL,
        settings: Settings = Settings()
    ) throws -> FileResult {
        guard outURL.standardizedFileURL != report.url.standardizedFileURL else {
            throw PressError.wouldOverwrite(outURL.lastPathComponent)
        }
        if case .passThrough = report.verdict {
            return try passThrough(report, to: outURL, kinds: [])
        }

        guard let doc = CGPDFDocument(report.url as CFURL) else {
            throw PressError.scanFailed("Cannot open PDF \(report.url.lastPathComponent)")
        }
        var pages: [PDFWriter.Page] = []
        var kinds: [PageClassifier.Kind] = []
        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else { continue }
            let nativeDpi: Int
            if case let .scan(dpi, _) = report.pages[i - 1].kind {
                nativeDpi = dpi
            } else {
                nativeDpi = settings.dpiCap  // born-digital page in a mixed file
            }
            let textDpi = max(72, min(nativeDpi, settings.dpiCap))

            let probe = try PDFRender.gray(page: page, dpi: min(probeDpi, textDpi))
            let kind = PageClassifier.classify(probe)
            kinds.append(kind)
            let dpi =
                kind == .photo
                ? max(72, min(nativeDpi, settings.photoDpiCap))
                : textDpi
            let gray =
                dpi == min(probeDpi, textDpi)
                ? probe
                : try PDFRender.gray(page: page, dpi: dpi)

            let content: PDFWriter.Content
            let ocrImage: CGImage?
            switch kind {
            case .text:
                let (stream, packed) = try encodeG4(gray, dpi: dpi)
                content = .g4(stream)
                ocrImage = packed.cgImage
            case .photo:
                guard
                    let jpeg = gray.jpegData(quality: settings.jpegQuality, dpi: dpi)
                else {
                    throw PressError.scanFailed("JPEG encode failed")
                }
                content = .jpegGray(jpeg, width: gray.width, height: gray.height)
                ocrImage = gray.cgImage
            }
            var words: [OCR.Word] = []
            if settings.ocr, let img = ocrImage {
                words = try OCR.recognize(cgImage: img)
            }
            pages.append(PDFWriter.Page(content: content, dpi: dpi, ocrWords: words))
        }

        let data = PDFWriter.build(pages: pages)
        let goodEnough =
            Double(data.count) <= Double(report.fileBytes) * (1 - settings.minSavingFraction)
        guard goodEnough else {
            return try passThrough(report, to: outURL, kinds: kinds)
        }
        try ensureParent(of: outURL)
        try data.write(to: outURL, options: .atomic)
        copySourceDates(from: report.url, to: outURL)
        return FileResult(
            inputBytes: report.fileBytes, outputBytes: data.count,
            converted: true, pageKinds: kinds
        )
    }

    /// Threshold + despeckle + pack a grayscale page and extract its CCITT
    /// G4 stream — the exact encoding a converted text page gets (also used
    /// by test fixtures so "already 1-bit" inputs match real output).
    /// Sauvola (local adaptive) rather than global Otsu: existing scans mix
    /// bold print with faded print on one page, and a global split loses
    /// whichever shade lands above it.
    public static func encodeG4(_ gray: Pipeline.GrayImage, dpi: Int) throws
        -> (stream: G4.Stream, page: Pipeline.ProcessedPage)
    {
        var bw = Binarize.sauvola(gray, dpi: dpi)
        // The page is already cropped to the paper — despeckle only;
        // removing border-touching components could eat real content.
        Pipeline.cleanComponents(&bw, removeBorder: false)
        let packed = Pipeline.pack(
            bw, crop: Pipeline.Crop(x0: 0, y0: 0, x1: bw.width, y1: bw.height),
            dpi: dpi
        )
        return (try G4.extractStream(fromTIFF: G4.tiff(from: packed)), packed)
    }

    private static func passThrough(
        _ report: PDFInspector.Report, to outURL: URL,
        kinds: [PageClassifier.Kind]
    ) throws -> FileResult {
        try copyThrough(report.url, to: outURL)
        return FileResult(
            inputBytes: report.fileBytes, outputBytes: report.fileBytes,
            converted: false, pageKinds: kinds
        )
    }

    static func copyThrough(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try ensureParent(of: dst)
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
    }

    static func ensureParent(of url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
    }

    static func copySourceDates(from src: URL, to dst: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: src.path) else { return }
        var keep: [FileAttributeKey: Any] = [:]
        if let m = attrs[.modificationDate] {
            keep[.modificationDate] = m
        }
        if let c = attrs[.creationDate] {
            keep[.creationDate] = c
        }
        try? fm.setAttributes(keep, ofItemAtPath: dst.path)
    }
}
