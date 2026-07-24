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
        /// A binarised text page whose measured damage (see
        /// Binarize.damage) exceeds this stays grayscale instead:
        /// print too small for the source resolution cannot survive any
        /// threshold, and legibility beats compression. Calibrated by
        /// magnified inspection of real receipts and certificates:
        /// visually clean pages score <= 0.177, visibly degraded ones
        /// (clogged counters, merged strokes) >= 0.191.
        public var maxG4Damage = 0.18
        /// Format for those demoted text pages. 4-bit grayscale is both
        /// smaller than JPEG q0.6 on document content and crisper (no DCT
        /// ringing); JPEG remains for anyone preferring smooth tones.
        /// Photographic pages always use JPEG.
        public var demotedTextFormat = DemotedTextFormat.gray4
        public init() {}
    }

    public enum DemotedTextFormat: String, Sendable, CaseIterable {
        case gray4
        case jpeg
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
        // Text pages render at the cap even when the source is lower-res:
        // a low-dpi grayscale scan carries sub-pixel detail in its
        // antialiasing, and thresholding at native resolution destroys it
        // (jagged text). Upsampling first turns that antialiasing back
        // into smooth 1-bit edges — at the price of processing every
        // low-res page at cap resolution. Photo pages keep native.
        let textDpi = max(72, settings.dpiCap)
        let probeRenderDpi = min(probeDpi, textDpi)
        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else { continue }
            let probe = try PDFRender.gray(page: page, dpi: probeRenderDpi)

            // The encoding ladder: classified text → G4, unless
            // binarisation measurably destroys legibility → grayscale JPEG.
            var g4: (stream: G4.Stream, page: Pipeline.ProcessedPage)?
            var demotedGray: Pipeline.GrayImage?
            if PageClassifier.classify(probe) == .text {
                let gray =
                    textDpi == probeRenderDpi
                    ? probe
                    : try PDFRender.gray(page: page, dpi: textDpi)
                let bw = Binarize.sauvola(gray, dpi: textDpi)
                if Binarize.damage(gray, bw) <= settings.maxG4Damage {
                    g4 = try encodeG4(binarized: bw, dpi: textDpi)
                } else {
                    // Print too small for the source resolution — no
                    // threshold keeps it legible. Stay grayscale, reusing
                    // this render instead of rasterising a third time.
                    demotedGray = gray
                }
            }

            let content: PDFWriter.Content
            let ocrImage: CGImage?
            let dpi: Int
            if let (stream, packed) = g4 {
                content = .g4(stream)
                ocrImage = packed.cgImage
                dpi = textDpi
                kinds.append(.text)
            } else {
                let nativeDpi: Int =
                    if case let .scan(d, _) = report.pages[i - 1].kind {
                        d
                    } else {
                        settings.photoDpiCap
                    }
                dpi = max(72, min(nativeDpi, settings.photoDpiCap))
                let gray: Pipeline.GrayImage =
                    if let demotedGray {
                        demotedGray.resampled(scale: Double(dpi) / Double(textDpi))
                    } else if dpi == probeRenderDpi {
                        probe
                    } else {
                        try PDFRender.gray(page: page, dpi: dpi)
                    }
                if demotedGray != nil, settings.demotedTextFormat == .gray4 {
                    content = .gray4Flate(Gray4.encode(gray))
                } else {
                    guard
                        let jpeg = gray.jpegData(quality: settings.jpegQuality, dpi: dpi)
                    else {
                        throw PressError.scanFailed("JPEG encode failed")
                    }
                    content = .jpegGray(jpeg, width: gray.width, height: gray.height)
                }
                ocrImage = gray.cgImage
                kinds.append(.photo)
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
        try encodeG4(binarized: Binarize.sauvola(gray, dpi: dpi), dpi: dpi)
    }

    static func encodeG4(binarized: Pipeline.BinaryImage, dpi: Int) throws
        -> (stream: G4.Stream, page: Pipeline.ProcessedPage)
    {
        var bw = binarized
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
