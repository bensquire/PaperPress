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

    var verdictLabel: String {
        if error != nil { return "Unreadable" }
        switch report?.verdict {
        case .convert: return "Re-compress"
        case .passThrough(.bornDigital): return "Born digital"
        case .passThrough(.alreadyOneBit): return "Already 1-bit"
        case .passThrough(.alreadySmall): return "Already small"
        case nil: return "…"
        }
    }

    var verdictHelp: String {
        if let error { return error }
        switch report?.verdict {
        case .convert:
            return "Scanned pages that will be re-compressed to compact 1-bit"
        case .passThrough(.bornDigital):
            return "Real text/vector PDF — rasterising it would only make it worse"
        case .passThrough(.alreadyOneBit):
            return "Scan is already 1-bit compressed"
        case .passThrough(.alreadySmall):
            return "Already compact for its page count"
        case nil:
            return ""
        }
    }

    var isConvert: Bool {
        report?.verdict == .convert
    }
}

@MainActor
final class AppModel: ObservableObject {
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

    private var worker: Task<Void, Never>?

    init(initialFolder: URL? = nil) {
        if let initialFolder {
            analyse(urls: [initialFolder])
        }
    }

    var busy: Bool {
        switch phase {
        case .analysing, .converting: true
        default: false
        }
    }

    var canConvert: Bool {
        phase == .review && !includedRows.isEmpty
    }

    var settings: Converter.Settings {
        var s = Converter.Settings()
        s.dpiCap = dpiCap
        s.photoDpiCap = photoDpiCap
        s.ocr = ocrEnabled
        s.jpegQuality = jpegQuality
        s.minSavingFraction = Double(minSavingPercent) / 100
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
        case let n: "\(n) dropped items"
        }
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose scanned PDFs, or folders of them"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        analyse(urls: panel.urls, append: phase == .review)
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
        let existingSources = Set(rows.map { $0.item.url.standardizedFileURL.path })
        let existingPaths = Set(rows.map(\.id))
        phase = .analysing(done: 0, of: 0)
        worker = Task.detached(priority: .userInitiated) { [self] in
            let items = FolderScanner.items(for: urls).filter {
                !existingSources.contains($0.url.standardizedFileURL.path)
                    && !existingPaths.contains($0.relativePath)
            }
            guard !items.isEmpty else {
                await MainActor.run {
                    self.phase = append ? .review : .idle
                    if !append {
                        self.errorText = "No PDFs found"
                    }
                }
                return
            }
            let base = await MainActor.run { () -> Int in
                let base = self.rows.count
                self.rows += items.map { FileRow(item: $0) }
                self.phase = .analysing(done: 0, of: items.count)
                return base
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

    func chooseOutputAndConvert() {
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
