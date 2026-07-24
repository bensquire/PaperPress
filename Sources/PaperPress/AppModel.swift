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
        case let .passThrough(reason): return reason.label
        case nil: return "…"
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
        case converting(done: Int, of: Int, current: String)
        case done
    }

    @Published var phase = Phase.idle
    @Published var rows: [FileRow] = []
    @Published var sourceURL: URL?
    @Published var outputURL: URL?
    @Published var errorText: String?

    // Settings (persisted)
    @AppStorage("dpiCap") var dpiCap = 300
    @AppStorage("photoDpiCap") var photoDpiCap = 150
    @AppStorage("ocrEnabled") var ocrEnabled = true
    @AppStorage("jpegQuality") var jpegQuality = 0.6
    @AppStorage("minSavingPercent") var minSavingPercent = 20

    private var worker: Task<Void, Never>?

    init() {
        // Dev/testing convenience: `PAPERPRESS_FOLDER=/path PaperPress`
        // skips straight to analysing that folder. (An ordinary CLI
        // argument won't do — AppKit treats it as a document to open and
        // then never creates the window.)
        if let path = ProcessInfo.processInfo.environment["PAPERPRESS_FOLDER"] {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                isDir.boolValue
            {
                analyse(folder: URL(fileURLWithPath: path))
            }
        }
    }

    var busy: Bool {
        switch phase {
        case .analysing, .converting: true
        default: false
        }
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

    func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder of scanned PDFs"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        analyse(folder: url)
    }

    func analyse(folder: URL) {
        worker?.cancel()
        sourceURL = folder
        outputURL = nil
        errorText = nil
        rows = []
        phase = .analysing(done: 0, of: 0)
        worker = Task.detached(priority: .userInitiated) { [self] in
            let items = FolderScanner.pdfs(under: folder)
            guard !items.isEmpty else {
                await MainActor.run {
                    self.phase = .idle
                    self.errorText = "No PDFs found in \(folder.lastPathComponent)"
                }
                return
            }
            await MainActor.run {
                self.rows = items.map { FileRow(item: $0) }
                self.phase = .analysing(done: 0, of: items.count)
            }
            for (i, item) in items.enumerated() {
                if Task.isCancelled { return }
                var row = FileRow(item: item)
                do {
                    row.report = try PDFInspector.inspect(item.url)
                    row.included = row.report?.verdict == .convert
                } catch {
                    row.error = error.localizedDescription
                    row.included = false
                }
                let done = i + 1
                await MainActor.run { [row] in
                    guard !Task.isCancelled else { return }
                    self.rows[i] = row
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
        guard let sourceURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Convert"
        panel.message = "Choose where to write the compressed copies"
        guard panel.runModal() == .OK, let out = panel.url else { return }
        guard out.standardizedFileURL != sourceURL.standardizedFileURL else {
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
        phase = .converting(done: 0, of: jobs.count, current: "")
        worker = Task.detached(priority: .userInitiated) { [self] in
            var failures = 0
            for (n, (index, row)) in jobs.enumerated() {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.phase = .converting(
                        done: n, of: jobs.count, current: row.item.relativePath
                    )
                }
                let dst = out.appendingPathComponent(row.item.relativePath)
                do {
                    let result = try Converter.convert(
                        report: row.report!, to: dst, settings: settings
                    )
                    await MainActor.run {
                        self.rows[index].result = result
                    }
                } catch {
                    failures += 1
                    await MainActor.run {
                        self.rows[index].error = error.localizedDescription
                    }
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
        sourceURL = nil
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
