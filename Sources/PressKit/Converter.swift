import CoreGraphics
import Foundation

/// Re-compresses one PDF: renders each scanned page, thresholds document
/// pages to CCITT G4, keeps photographic pages as grayscale JPEG, re-OCRs,
/// carries born-digital pages over unchanged, and rebuilds a compact PDF.
/// Falls back to copying the original when the result wouldn't be
/// meaningfully smaller.
public enum Converter {
    public struct Settings: Sendable, Equatable, Codable {
        /// Text pages are rendered at this resolution, and 1-bit pages
        /// stored at it: higher-res scans are downsampled, lower-res ones
        /// upsampled so their antialiasing becomes smooth 1-bit edges. Text
        /// kept grayscale is stored at its own resolution up to this.
        public var dpiCap = 300
        /// Photographic pages are stored at their native resolution up to
        /// this. Measured on a real photograph scanned at 300 dpi: 200 dpi
        /// JPEG q0.6 is 2.4 dB truer on screen than 150 dpi (40.8 vs 38.4
        /// PSNR) for 58% more bytes — a better trade than raising the JPEG
        /// quality, which bought 0.6 dB for 43% more.
        public var photoDpiCap = 200
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
        /// Format for text kept grayscale (by resolution or damage). 4-bit
        /// grayscale is both smaller than JPEG q0.6 on document content and
        /// crisper (no DCT ringing); JPEG remains for anyone preferring
        /// smooth tones. Photographic pages always use JPEG.
        public var demotedTextFormat = DemotedTextFormat.gray4
        /// Whiten black scan-edge bands/shadows (see EdgeClean). Runs
        /// before classification and the damage measurement, so a heavy
        /// band can't flip a page to photo or count as binarisation
        /// damage. Photographic pages are never cleaned — they may
        /// legitimately be dark at their edges.
        public var removeScanEdges = true
        public init() {}
    }

    public enum DemotedTextFormat: String, Sendable, Codable {
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

    /// How one page of a converted file was encoded.
    public enum PageEncoding: Equatable, Sendable, Codable {
        case g4
        case gray4
        case jpeg
        /// A born-digital page carried over from the source unchanged.
        case original
    }

    /// Why an original was copied through instead of converted.
    public enum CopyReason: Equatable, Sendable, Codable {
        /// The analysis verdict was pass-through (born digital, already
        /// converted/compact/small).
        case passThrough
        /// Conversion ran but didn't clear the minimum-saving bar.
        case insufficientSaving
    }

    public enum Outcome: Equatable, Sendable, Codable {
        case converted([PageEncoding])
        case copied(CopyReason)
    }

    public struct FileResult: Sendable {
        public let inputBytes: Int
        public let outputBytes: Int
        public let outcome: Outcome

        public var converted: Bool {
            if case .converted = outcome { return true }
            return false
        }
    }

    /// Convert (or pass through) `report.url`, writing the result to `outURL`.
    /// The output file keeps the source's modification date. Checks for
    /// cancellation between pages; a cancelled conversion writes nothing.
    public static func convert(
        report: PDFInspector.Report, to outURL: URL,
        settings: Settings = Settings()
    ) throws -> FileResult {
        let holdsSource = try checkDestination(outURL, source: report.url)
        if case .passThrough = report.verdict {
            return try copyResult(report, to: outURL, reason: .passThrough, alreadyThere: holdsSource)
        }

        let doc = try open(report)
        let copier = PageCopier()
        var pages: [PDFWriter.Page] = []
        for (i, info) in report.pages.enumerated() {
            try Task.checkCancellation()
            pages.append(
                try convertPage(
                    page(i + 1, of: doc, report), info: info, settings: settings, copier: copier))
        }

        let data = try PDFWriter.build(pages: pages)
        try verify(data, pageCount: pages.count, name: report.url.lastPathComponent)
        let goodEnough =
            Double(data.count) <= Double(report.fileBytes) * (1 - settings.minSavingFraction)
        guard goodEnough else {
            return try copyResult(
                report, to: outURL, reason: .insufficientSaving, alreadyThere: holdsSource)
        }
        try Task.checkCancellation()
        try ensureParent(of: outURL)
        try data.write(to: outURL, options: .atomic)
        copySourceDates(from: report.url, to: outURL)
        return FileResult(
            inputBytes: report.fileBytes, outputBytes: data.count,
            outcome: .converted(pages.map { encoding(of: $0.content) })
        )
    }

    /// What `convert` would do with one page.
    public enum Preview {
        /// The file is copied unchanged, so the page is too.
        case unchanged(PDFInspector.PassReason)
        /// The page as it would be written, as a one-page PDF; `dpi` is the
        /// resolution it was encoded at, nil for a page carried over as it was.
        case converted(pdf: Data, encoding: PageEncoding, dpi: Int?)
    }

    /// One page as `convert` would write it — the same verdict and the same
    /// ladder, without OCR — to look at before a batch is committed. `number`
    /// counts from 1.
    public static func preview(
        page number: Int, of report: PDFInspector.Report, settings: Settings = Settings()
    ) throws -> Preview {
        if case .passThrough(let reason) = report.verdict {
            return .unchanged(reason)
        }
        guard report.pages.indices.contains(number - 1) else {
            throw PressError.scanFailed(
                "\(report.url.lastPathComponent) has \(report.pages.count) pages, not \(number)")
        }
        let doc = try open(report)
        var settings = settings
        settings.ocr = false
        let converted = try convertPage(
            page(number, of: doc, report), info: report.pages[number - 1], settings: settings,
            copier: PageCopier())
        let encoding = encoding(of: converted.content)
        return .converted(
            pdf: try PDFWriter.build(pages: [converted]), encoding: encoding,
            dpi: encoding == .original ? nil : converted.dpi)
    }

    /// The source as analysed. The plan is per page, so a file edited since
    /// analysis no longer matches it.
    private static func open(_ report: PDFInspector.Report) throws -> CGPDFDocument {
        let name = report.url.lastPathComponent
        guard let doc = CGPDFDocument(report.url as CFURL) else {
            throw PressError.scanFailed("Cannot open PDF \(name)")
        }
        guard doc.numberOfPages == report.pages.count else {
            throw PressError.changedSinceAnalysis(name)
        }
        return doc
    }

    /// A page that can't be read is an error, never a shorter file.
    private static func page(
        _ number: Int, of doc: CGPDFDocument, _ report: PDFInspector.Report
    ) throws -> CGPDFPage {
        guard let page = doc.page(at: number) else {
            throw PressError.unreadablePage(number, report.url.lastPathComponent)
        }
        return page
    }

    /// One page through the encoding ladder.
    private static func convertPage(
        _ page: CGPDFPage, info: PDFInspector.PageInfo, settings: Settings, copier: PageCopier
    ) throws -> PDFWriter.Page {
        let nativeDpi: Int
        switch info.kind {
        case let .scan(dpi, _):
            nativeDpi = dpi
        case .bornDigital:
            // Real text and vector art in a mixed file: carried over
            // object for object — rasterising is what the Born digital
            // verdict exists to prevent. Rasterising stays the fallback
            // for a page whose objects can't be copied.
            if let copied = try? copier.copy(page) {
                return PDFWriter.Page(original: copied)
            }
            nativeDpi = settings.dpiCap
        }

        // Text pages render at the cap even when the source is lower-res:
        // a low-dpi grayscale scan carries sub-pixel detail in its
        // antialiasing, and thresholding at native resolution destroys it
        // (jagged text). Upsampling first turns that antialiasing back
        // into smooth 1-bit edges — at the price of processing every
        // low-res page at cap resolution. Photographs render at their own
        // resolution, up to the photo cap.
        let textDpi = max(72, settings.dpiCap)
        let probeRenderDpi = min(probeDpi, textDpi)
        let probeCleaned = settings.removeScanEdges
        let probe = try Self.probe(page, dpi: probeRenderDpi, clean: probeCleaned)

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
        var g4: (stream: G4.Stream, gray: Pipeline.GrayImage)?
        var demoted: (gray: Pipeline.GrayImage, levels: Binarize.Levels?)?
        if isText, nativeDpi >= settings.minG4Dpi {
            let gray = try preparedGray(dpi: textDpi, clean: cleanText)
            // Measured once, for the binarisation, its damage score and
            // (if it stays grayscale) its levels.
            let levels = Binarize.levels(gray)
            let bw = Binarize.sauvola(gray, dpi: textDpi, levels: levels)
            if Binarize.damage(gray, bw, levels: levels) <= settings.maxG4Damage {
                g4 = (try encodeG4(binarized: bw, dpi: textDpi), gray)
            } else {
                // Binarisation measurably destroys a region — stay
                // grayscale, reusing this render instead of
                // rasterising again.
                demoted = (gray, levels)
            }
        }

        let content: PDFWriter.Content
        let ocrSource: Pipeline.GrayImage
        let dpi: Int
        if let g4 {
            content = .g4(g4.stream)
            ocrSource = g4.gray
            dpi = textDpi
        } else {
            // Text kept grayscale keeps the text resolution, capped at the
            // source's own: it was kept grayscale because its detail is
            // fine, so halving its resolution undid the point (measured
            // error at 300 dpi: 16 at full resolution against 52 at the
            // photo cap). Photographs take the photo cap.
            dpi = max(72, min(nativeDpi, isText ? textDpi : settings.photoDpiCap))
            let rendered: Pipeline.GrayImage
            if let demoted {
                rendered = demoted.gray.resampled(scale: Double(dpi) / Double(textDpi))
            } else {
                // Photos are never edge-cleaned — they may be
                // legitimately dark at the edges.
                rendered = try preparedGray(dpi: dpi, clean: isText && cleanText)
            }
            // Text gets its paper whitened and its ink set black: truer and
            // much smaller (4-bit at 300 dpi: 277 KB against 1,069 KB
            // unlevelled — the scanner's noise defeated Flate). It takes the
            // configured grayscale format; photographs stay 8-bit JPEG, as 16
            // levels band continuous tone. (Levels measured on the text-dpi
            // render serve when the page keeps that resolution.)
            let gray =
                isText
                ? rendered.levelled(dpi == textDpi ? demoted?.levels : nil) : rendered
            content =
                try isText && settings.demotedTextFormat == .gray4
                ? .gray4Flate(Gray4.encode(gray))
                : jpegContent(gray, quality: settings.jpegQuality, dpi: dpi)
            ocrSource = gray
        }
        // OCR reads the grayscale, downsampled to ocrDpi — better for
        // Vision than 1-bit input, and much faster. Word boxes are
        // normalised, so the text layer is unaffected. Prepared only
        // when OCR is on.
        var words: [OCR.Word] = []
        if settings.ocr, let img = ocrInput(ocrSource, at: dpi).cgImage {
            words = try OCR.recognize(cgImage: img)
        }
        return PDFWriter.Page(content: content, dpi: dpi, ocrWords: words)
    }

    /// The cheap render a page is classified on. Cleaned first when asked: a
    /// heavy edge band would otherwise read as photo content — the one path
    /// where the cleanup would never run. Shared with PDFInspector's size
    /// estimate, so both make the same call.
    static func probe(_ page: CGPDFPage, dpi: Int, clean: Bool) throws -> Pipeline.GrayImage {
        var probe = try PDFRender.gray(page: page, dpi: dpi)
        if clean {
            EdgeClean.removeScanBorders(&probe, dpi: dpi)
        }
        return probe
    }

    /// The writer is hand-rolled: a file Quartz can't open, or one that
    /// lost a page, never replaces anything.
    private static func verify(_ data: Data, pageCount: Int, name: String) throws {
        guard let provider = CGDataProvider(data: data as CFData),
            let doc = CGPDFDocument(provider),
            doc.numberOfPages == pageCount
        else {
            throw PressError.scanFailed("The rebuilt \(name) failed verification")
        }
    }

    /// The output may replace only what PaperPress wrote before — an
    /// earlier conversion (it carries the Producer marker) — or a file
    /// byte-identical to the source, whose content the source still
    /// holds. Anything else at the path is left alone: an unrelated file,
    /// or the source itself however its path is spelled. Returns whether the
    /// destination already holds the source's bytes, so a copy can be skipped.
    @discardableResult
    static func checkDestination(_ dst: URL, source: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dst.path) else { return false }
        if OutputPlan.isSameFile(dst, source) {
            throw PressError.wouldOverwrite(dst.lastPathComponent)
        }
        if PDFInspector.isPaperPressOutput(dst) { return false }
        guard fm.contentsEqual(atPath: source.path, andPath: dst.path) else {
            throw PressError.destinationExists(dst.lastPathComponent)
        }
        return true
    }

    /// The encoding is a fact of the page content — derived, not tracked
    /// in parallel, so a new branch can't forget to record it.
    private static func encoding(of content: PDFWriter.Content) -> PageEncoding {
        switch content {
        case .g4: .g4
        case .gray4Flate: .gray4
        case .jpegGray: .jpeg
        case .original: .original
        }
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
        -> G4.Stream
    {
        try encodeG4(binarized: Binarize.sauvola(gray, dpi: dpi), dpi: dpi)
    }

    static func encodeG4(binarized: Pipeline.BinaryImage, dpi: Int) throws
        -> G4.Stream
    {
        var bw = binarized
        // The page is already cropped to the paper — despeckle only;
        // removing border-touching components could eat real content.
        Pipeline.despeckle(&bw)
        let packed = Pipeline.pack(
            bw, crop: Pipeline.Crop(x0: 0, y0: 0, x1: bw.width, y1: bw.height),
            dpi: dpi
        )
        return try G4.extractStream(fromTIFF: G4.tiff(from: packed))
    }

    private static func copyResult(
        _ report: PDFInspector.Report, to outURL: URL, reason: CopyReason, alreadyThere: Bool
    ) throws -> FileResult {
        try Task.checkCancellation()
        if !alreadyThere {
            try copyThrough(report.url, to: outURL)
        }
        return FileResult(
            inputBytes: report.fileBytes, outputBytes: report.fileBytes,
            outcome: .copied(reason)
        )
    }

    /// Copies `src` over `dst`. Only reached once checkDestination has
    /// cleared whatever is at `dst`; copyItem itself refuses an existing
    /// destination, hence the removal.
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
