import AppKit
import Foundation
import PressKit
import SwiftUI

/// One source PDF flowing through analyse → review → convert.
struct FileRow: Identifiable {
    let item: FolderScanner.Item
    var report: PDFInspector.Report?
    var error: String?
    var included = true
    var result: Converter.FileResult?

    var id: String { item.relativePath }

    /// One switch owns both the badge label and its tooltip, so a new
    /// verdict can't be added to one and forgotten in the other.
    private var verdictText: (label: String, help: String) {
        switch report?.verdict {
        case .convert:
            ("Re-compress", "Scanned pages that will be re-compressed to compact 1-bit")
        case .passThrough(.bornDigital):
            ("Born digital", "Real text/vector PDF — rasterising it would only make it worse")
        case .passThrough(.alreadyProcessed):
            (
                "Already converted",
                "Produced by PaperPress — converting again would only re-encode it"
            )
        case .passThrough(.alreadyCompact):
            ("Already compact", "Pages are already archival-compact (1-bit or 4-bit)")
        case .passThrough(.alreadySmall):
            ("Already small", "Already compact for its page count")
        case nil:
            ("…", "")
        }
    }

    var verdictLabel: String {
        error != nil ? "Unreadable" : verdictText.label
    }

    var verdictHelp: String {
        error ?? verdictText.help
    }

    var isConvert: Bool {
        report?.verdict == .convert
    }

    /// Whether this row took part in the last conversion run — the same
    /// predicate convert(to:) uses to build its job list.
    var participated: Bool {
        included && report != nil
    }

    /// Conversion ran for this row and failed (vs an analysis error).
    var failed: Bool {
        error != nil && result == nil
    }

    /// Outcome badge + tooltip for the results view, one switch for both.
    var resultText: (label: String, help: String) {
        if failed, let error {
            return ("Failed", error)
        }
        switch result?.outcome {
        case let .converted(encodings):
            var counts: [String] = []
            let g4 = encodings.filter { $0 == .g4 }.count
            let gray4 = encodings.filter { $0 == .gray4 }.count
            let jpeg = encodings.filter { $0 == .jpeg }.count
            if g4 > 0 { counts.append("1-bit ×\(g4)") }
            if gray4 > 0 { counts.append("grayscale ×\(gray4)") }
            if jpeg > 0 { counts.append("JPEG ×\(jpeg)") }
            return (
                "Converted",
                "Pages: " + counts.joined(separator: " · ")
            )
        case .copied(.insufficientSaving):
            return (
                "Copied",
                "Converting saved too little — original copied unchanged"
            )
        case .copied(.passThrough):
            return ("Copied", "Copied through byte-identical")
        case nil:
            return ("—", "")
        }
    }

    /// Fraction of the input saved by conversion, nil when not converted.
    var savingFraction: Double? {
        guard let result, result.converted, result.inputBytes > 0 else { return nil }
        return 1 - Double(result.outputBytes) / Double(result.inputBytes)
    }
}

@MainActor
public final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case analysing(done: Int, of: Int)
        case review
        case converting(done: Int, of: Int)
        case done
    }

    @Published var phase = Phase.idle
    @Published var rows: [FileRow] = []
    @Published var sourceURLs: [URL] = []
    @Published var outputURL: URL?
    @Published var errorText: String?

    // Settings (persisted; defaults come from the library so the two can't
    // drift)
    @AppStorage("dpiCap") var dpiCap = Converter.Settings().dpiCap
    @AppStorage("photoDpiCap") var photoDpiCap = Converter.Settings().photoDpiCap
    @AppStorage("ocrEnabled") var ocrEnabled = Converter.Settings().ocr
    @AppStorage("jpegQuality") var jpegQuality = Converter.Settings().jpegQuality
    @AppStorage("minSavingPercent") var minSavingPercent =
        Int(Converter.Settings().minSavingFraction * 100)
    @AppStorage("demotedTextFormat") var demotedTextFormat =
        Converter.Settings().demotedTextFormat
    @AppStorage("removeScanEdges") var removeScanEdges =
        Converter.Settings().removeScanEdges

    private var worker: Task<Void, Never>?

    public init(initialFolder: URL? = nil) {
        if let initialFolder {
            analyse(urls: [initialFolder])
        }
    }

    public var busy: Bool {
        switch phase {
        case .analysing, .converting: true
        default: false
        }
    }

    public var canConvert: Bool {
        phase == .review && !includedRows.isEmpty
    }

    var settings: Converter.Settings {
        var s = Converter.Settings()
        s.dpiCap = dpiCap
        s.photoDpiCap = photoDpiCap
        s.ocr = ocrEnabled
        s.jpegQuality = jpegQuality
        s.minSavingFraction = Double(minSavingPercent) / 100
        s.demotedTextFormat = demotedTextFormat
        s.removeScanEdges = removeScanEdges
        return s
    }

    // MARK: Totals

    var includedRows: [FileRow] {
        rows.filter(\.included)
    }

    var totalInputBytes: Int {
        includedRows.compactMap { $0.report?.fileBytes }.reduce(0, +)
    }

    var totalEstimatedBytes: Int {
        includedRows.compactMap { $0.report?.estimatedBytes }.reduce(0, +)
    }

    var totalOutputBytes: Int {
        rows.compactMap { $0.result?.outputBytes }.reduce(0, +)
    }

    var convertedCount: Int {
        rows.filter { $0.result?.converted == true }.count
    }

    // MARK: Analyse

    var sourceLabel: String {
        switch sourceURLs.count {
        case 0: ""
        case 1: sourceURLs[0].path
        case let n: "\(n) sources"
        }
    }

    public func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose scanned PDFs, or folders of them"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        open(urls: panel.urls)
    }

    /// Entry point for externally arriving files (Open With, Dock drops,
    /// Services, the open panel): joins the current review if one is
    /// showing, else starts fresh. Drop targets in the UI don't use this —
    /// their append/replace semantics come from which zone was dropped on.
    func open(urls: [URL]) {
        analyse(urls: urls, append: phase == .review)
    }

    /// Expand the given PDFs/folders and inspect them. With append=true
    /// (drop onto the review table) new items join the existing rows;
    /// otherwise they replace them.
    func analyse(urls: [URL], append: Bool = false) {
        worker?.cancel()
        outputURL = nil
        errorText = nil
        if append {
            sourceURLs += urls
        } else {
            sourceURLs = urls
            rows = []
        }
        let existing = rows.map(\.item)
        let base = rows.count
        phase = .analysing(done: 0, of: 0)
        worker = Task.detached(priority: .userInitiated) { [self] in
            let items = FolderScanner.items(for: urls, merging: existing)
            guard !items.isEmpty else {
                await MainActor.run {
                    if append {
                        self.phase = .review
                    } else {
                        self.phase = .idle
                        self.errorText = "No PDFs found"
                    }
                }
                return
            }
            await MainActor.run {
                self.rows += items.map { FileRow(item: $0) }
                self.phase = .analysing(done: 0, of: items.count)
            }
            for (i, item) in items.enumerated() {
                if Task.isCancelled { return }
                var report: PDFInspector.Report?
                var error: String?
                do {
                    report = try PDFInspector.inspect(item.url)
                } catch let e {
                    error = e.localizedDescription
                }
                let done = i + 1
                await MainActor.run { [report, error] in
                    guard !Task.isCancelled else { return }
                    self.rows[base + i].report = report
                    self.rows[base + i].error = error
                    self.rows[base + i].included = report?.verdict == .convert
                    self.phase = .analysing(done: done, of: items.count)
                }
            }
            await MainActor.run {
                self.phase = .review
            }
        }
    }

    // MARK: Convert

    public func chooseOutputAndConvert() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Convert"
        panel.message = "Choose where to write the compressed copies"
        guard panel.runModal() == .OK, let out = panel.url else { return }
        guard
            !sourceURLs.contains(where: {
                $0.standardizedFileURL == out.standardizedFileURL
            })
        else {
            errorText = "Choose a different folder than the source"
            return
        }
        convert(to: out)
    }

    /// True when any included file's planned output path IS its source
    /// (covers both "output = dropped folder" and "output = a loose
    /// file's own folder"); the Converter guard remains the invariant.
    func outputCollides(with out: URL) -> Bool {
        includedRows.contains { row in
            out.appendingPathComponent(row.item.relativePath).standardizedFileURL
                == row.item.url.standardizedFileURL
        }
    }

    func convert(to out: URL) {
        outputURL = out
        errorText = nil
        let jobs = rows.enumerated().filter { $0.element.included && $0.element.report != nil }
        let settings = settings
        phase = .converting(done: 0, of: jobs.count)
        worker = Task.detached(priority: .userInitiated) { [self] in
            // Files are independent (distinct output paths), so convert a few
            // concurrently; the cap bounds the page buffers held in flight.
            let width = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
            var failures = 0
            var done = 0
            await withTaskGroup(of: (Int, Result<Converter.FileResult, Error>).self) { group in
                var next = 0
                func spawnNext(into group: inout TaskGroup<(Int, Result<Converter.FileResult, Error>)>) {
                    guard next < jobs.count, !Task.isCancelled else { return }
                    let (index, row) = jobs[next]
                    next += 1
                    let dst = out.appendingPathComponent(row.item.relativePath)
                    group.addTask {
                        do {
                            return (
                                index,
                                .success(
                                    try Converter.convert(
                                        report: row.report!, to: dst, settings: settings
                                    ))
                            )
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                for _ in 0..<width {
                    spawnNext(into: &group)
                }
                for await (index, result) in group {
                    done += 1
                    if case .failure = result { failures += 1 }
                    await MainActor.run { [done] in
                        switch result {
                        case let .success(r): self.rows[index].result = r
                        case let .failure(e): self.rows[index].error = e.localizedDescription
                        }
                        self.phase = .converting(done: done, of: jobs.count)
                    }
                    spawnNext(into: &group)
                }
            }
            let failed = failures
            await MainActor.run {
                self.phase = .done
                if failed > 0 {
                    self.errorText = "\(failed) file\(failed == 1 ? "" : "s") failed"
                }
            }
        }
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        phase = rows.contains(where: { $0.report != nil }) ? .review : .idle
    }

    func reset() {
        worker?.cancel()
        worker = nil
        rows = []
        sourceURLs = []
        outputURL = nil
        errorText = nil
        phase = .idle
    }

    func setAllIncluded(_ included: Bool) {
        for i in rows.indices where rows[i].error == nil {
            rows[i].included = included
        }
    }

    /// The file to preview for a results row: the written output when the
    /// conversion produced one (the point is to inspect quality), else
    /// the source (e.g. for failed rows). Routed by recorded results, not
    /// filesystem checks — no stat() in view bodies.
    func previewURL(for row: FileRow) -> URL {
        if row.result != nil, let outputURL {
            return outputURL.appendingPathComponent(row.item.relativePath)
        }
        return row.item.url
    }

    func revealOutput() {
        if let outputURL {
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        }
    }
}

// MARK: Formatting

func byteLabel(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
