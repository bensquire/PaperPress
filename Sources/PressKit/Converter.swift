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
        /// Text pages scanned below this resolution always stay grayscale
        /// — low-res sources always degrade somewhere under 1-bit.
        /// Calibration record: BinarizeTests.test_damage_calibrationAnchors.
        public var minG4Dpi = 150
        /// Backstop for pages at or above minG4Dpi: worst-region
        /// binarisation damage (see Binarize.damage) above this stays
        /// grayscale (verified-crisp <= 0.37, degraded >= 0.42; record in
        /// BinarizeTests.test_damage_calibrationAnchors).
        public var maxG4Damage = 0.40
        /// Format for those demoted text pages. 4-bit grayscale is both
        /// smaller than JPEG q0.6 on document content and crisper (no DCT
        /// ringing); JPEG remains for anyone preferring smooth tones.
        /// Photographic pages always use JPEG.
        public var demotedTextFormat = DemotedTextFormat.gray4
        /// Whiten black scan-edge bands/shadows (see EdgeClean). Runs
        /// before classification and the damage measurement, so a heavy
        /// band can't flip a page to photo or count as binarisation
        /// damage. Photographic pages are never cleaned — they may
        /// legitimately be dark at their edges.
        public var removeScanEdges = true
        public init() {}
    }

    public enum DemotedTextFormat: String, Sendable {
        case gray4
        case jpeg
    }

    /// Pages are classified on a cheap render at this resolution, so the
    /// text/photo decision doesn't shift when the user changes dpi caps.
    static let probeDpi = 100
    /// OCR input is capped here: Vision normalises resolution internally,
    /// and measured accuracy at 150 dpi grayscale equals or beats the
    /// 300 dpi 1-bit page (antialiasing helps it) at ~2.4x less time —
    /// OCR dominates per-page wall clock.
    static let ocrDpi = 150

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
            let nativeDpi: Int =
                if case let .scan(d, _) = report.pages[i - 1].kind {
                    d
                } else {
                    settings.dpiCap  // born-digital page in a mixed file
                }
            var probe = try PDFRender.gray(page: page, dpi: probeRenderDpi)
            let probeCleaned = settings.removeScanEdges
            if probeCleaned {
                // Clean before classifying: a heavy edge band would
                // otherwise read as photo content — the one path where
                // the cleanup would never run.
                EdgeClean.removeScanBorders(&probe, dpi: probeRenderDpi)
            }

            // The one seam for obtaining a page render: callers state the
            // cleaning policy and cannot skip or wrongly inherit it — the
            // probe is reused only when its cleaning state matches. (Two
            // regressions came from branches hand-wiring render+clean.)
            func preparedGray(dpi: Int, clean: Bool) throws -> Pipeline.GrayImage {
                if dpi == probeRenderDpi, clean == probeCleaned {
                    return probe
                }
                var g = try PDFRender.gray(page: page, dpi: dpi)
                if clean {
                    EdgeClean.removeScanBorders(&g, dpi: dpi)
                }
                return g
            }
            let cleanText = settings.removeScanEdges

            // The encoding ladder: classified text → G4, unless the source
            // is too low-res to binarise or binarisation measurably
            // destroys legibility → grayscale.
            let isText = PageClassifier.classify(probe) == .text
            var g4: (stream: G4.Stream, page: Pipeline.ProcessedPage)?
            var g4OCRImage: CGImage?
            var demotedGray: Pipeline.GrayImage?
            if isText, nativeDpi >= settings.minG4Dpi {
                let gray = try preparedGray(dpi: textDpi, clean: cleanText)
                let bw = Binarize.sauvola(gray, dpi: textDpi)
                if Binarize.damage(gray, bw) <= settings.maxG4Damage {
                    g4 = try encodeG4(binarized: bw, dpi: textDpi)
                    // OCR reads the grayscale, downsampled to ocrDpi —
                    // better for Vision than the 1-bit page, and much
                    // faster. Word boxes are normalised, so the text
                    // layer is unaffected.
                    g4OCRImage = ocrInput(gray, at: textDpi).cgImage
                } else {
                    // Binarisation measurably destroys a region — stay
                    // grayscale, reusing this render instead of
                    // rasterising again.
                    demotedGray = gray
                }
            }

            let content: PDFWriter.Content
            let ocrImage: CGImage?
            let dpi: Int
            if let (stream, _) = g4 {
                content = .g4(stream)
                ocrImage = g4OCRImage
                dpi = textDpi
                kinds.append(.text)
            } else {
                dpi = max(72, min(nativeDpi, settings.photoDpiCap))
                let gray: Pipeline.GrayImage
                if let demotedGray {
                    gray = demotedGray.resampled(scale: Double(dpi) / Double(textDpi))
                } else {
                    // Photos are never edge-cleaned — they may be
                    // legitimately dark at the edges.
                    gray = try preparedGray(dpi: dpi, clean: isText && cleanText)
                }
                // Text (demoted by resolution or damage) keeps the
                // configured grayscale format; photos are always JPEG.
                content =
                    try isText && settings.demotedTextFormat == .gray4
                    ? .gray4Flate(Gray4.encode(gray))
                    : jpegContent(gray, quality: settings.jpegQuality, dpi: dpi)
                ocrImage = ocrInput(gray, at: dpi).cgImage
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

    /// Downsample OCR input to ocrDpi when the render exceeds it.
    private static func ocrInput(
        _ gray: Pipeline.GrayImage, at dpi: Int
    ) -> Pipeline.GrayImage {
        dpi > ocrDpi ? gray.resampled(scale: Double(ocrDpi) / Double(dpi)) : gray
    }

    private static func jpegContent(
        _ gray: Pipeline.GrayImage, quality: Double, dpi: Int
    ) throws -> PDFWriter.Content {
        guard let jpeg = gray.jpegData(quality: quality, dpi: dpi) else {
            throw PressError.scanFailed("JPEG encode failed")
        }
        return .jpegGray(jpeg, width: gray.width, height: gray.height)
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
