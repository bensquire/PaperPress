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
        settings: Settings = Settings(),
        progress: (@Sendable (_ page: Int, _ ofPages: Int) -> Void)? = nil
    ) throws -> FileResult {
        if case .passThrough = report.verdict {
            try copyThrough(report.url, to: outURL)
            return FileResult(
                inputBytes: report.fileBytes, outputBytes: report.fileBytes,
                converted: false, pageKinds: []
            )
        }

        guard let doc = CGPDFDocument(report.url as CFURL) else {
            throw ScanError.scanFailed("Cannot open PDF \(report.url.lastPathComponent)")
        }
        var pages: [PDFWriter.Page] = []
        var kinds: [PageClassifier.Kind] = []
        for i in 1...doc.numberOfPages {
            progress?(i, doc.numberOfPages)
            guard let page = doc.page(at: i) else { continue }
            let info = i - 1 < report.pages.count ? report.pages[i - 1] : nil
            let nativeDpi: Int
            if case let .scan(dpi, _) = info?.kind {
                nativeDpi = dpi
            } else {
                nativeDpi = settings.dpiCap  // born-digital page in a mixed file
            }
            var dpi = max(72, min(nativeDpi, settings.dpiCap))
            var gray = try PDFRender.gray(page: page, dpi: dpi)
            let kind = PageClassifier.classify(gray)
            kinds.append(kind)
            if kind == .photo, dpi > settings.photoDpiCap {
                dpi = max(72, settings.photoDpiCap)
                gray = try PDFRender.gray(page: page, dpi: dpi)
            }
            let sizePt = (
                w: Double(gray.width) / Double(dpi) * 72,
                h: Double(gray.height) / Double(dpi) * 72
            )
            switch kind {
            case .text:
                var bw = Pipeline.threshold(gray, at: Pipeline.otsuThreshold(gray))
                // The page is already cropped to the paper — despeckle only;
                // removing border-touching components could eat real content.
                Pipeline.cleanComponents(&bw, removeBorder: false)
                let packed = Pipeline.pack(
                    bw, crop: Pipeline.Crop(x0: 0, y0: 0, x1: bw.width, y1: bw.height),
                    dpi: dpi
                )
                let stream = try G4.extractStream(fromTIFF: G4.tiff(from: packed))
                let words = settings.ocr ? try OCR.recognize(packed) : []
                pages.append(
                    PDFWriter.Page(
                        content: .g4(stream), dpi: dpi, ocrWords: words,
                        pageSizePt: sizePt
                    )
                )
            case .photo:
                guard
                    let jpeg = gray.jpegData(quality: settings.jpegQuality, dpi: dpi)
                else {
                    throw ScanError.scanFailed("JPEG encode failed")
                }
                let words: [OCR.Word] =
                    if settings.ocr, let img = gray.cgImage {
                        try OCR.recognize(cgImage: img)
                    } else {
                        []
                    }
                pages.append(
                    PDFWriter.Page(
                        content: .jpegGray(jpeg, width: gray.width, height: gray.height),
                        dpi: dpi, ocrWords: words, pageSizePt: sizePt
                    )
                )
            }
        }

        let data = PDFWriter.build(pages: pages)
        let goodEnough =
            Double(data.count) <= Double(report.fileBytes) * (1 - settings.minSavingFraction)
        if goodEnough {
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outURL, options: .atomic)
            copySourceDates(from: report.url, to: outURL)
            return FileResult(
                inputBytes: report.fileBytes, outputBytes: data.count,
                converted: true, pageKinds: kinds
            )
        }
        try copyThrough(report.url, to: outURL)
        return FileResult(
            inputBytes: report.fileBytes, outputBytes: report.fileBytes,
            converted: false, pageKinds: kinds
        )
    }

    static func copyThrough(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: dst.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
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
