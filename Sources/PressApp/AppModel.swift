import AppKit
import Foundation
import PressJobs
import PressKit
import SwiftUI

/// One source PDF flowing through analyse → review → convert.
struct FileRow: Identifiable {
    let item: FolderScanner.Item
    var report: PDFInspector.Report?
    /// Why analysis failed; such a row can't be converted.
    var error: String?
    /// Ticked for conversion. Set from the verdict once analysed, so a row
    /// with no verdict yet is never ticked.
    var included = false
    var result: Converter.FileResult?
    /// Why this row's last conversion failed — kept apart from `error`, so
    /// a failed run doesn't relabel the file as unreadable.
    var convertError: String?

    var id: String { item.relativePath }

    var analysed: Bool { report != nil || error != nil }

    /// Takes an analysis's outcome: ticked when the verdict says to convert,
    /// or with `includeUnchanged`, whenever there's a verdict at all.
    mutating func record(
        _ outcome: Result<PDFInspector.Report, any Error>, includeUnchanged: Bool
    ) {
        switch outcome {
        case let .success(report):
            self.report = report
            included = report.isWritten(copyingUnchanged: includeUnchanged)
        case let .failure(error):
            self.error = error.localizedDescription
        }
    }

    /// One switch owns both the badge label and its tooltip, so a new
    /// verdict can't be added to one and forgotten in the other.
    private var verdictText: (label: String, help: String) {
        switch report?.verdict {
        case .convert:
            ("Re-compress", "Scanned pages that will be re-compressed to compact 1-bit")
        case .passThrough(let reason):
            (reason.label, Self.help(reason))
        case nil:
            ("…", "")
        }
    }

    private static func help(_ reason: PDFInspector.PassReason) -> String {
        switch reason {
        case .bornDigital: "Real text/vector PDF — rasterising it would only make it worse"
        case .alreadyProcessed: "Produced by PaperPress — converting again would only re-encode it"
        case .alreadyCompact: "Pages are already archival-compact (1-bit or 4-bit)"
        case .alreadySmall: "Already compact for its page count"
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

    /// Whether this row takes part in a conversion run — the predicate
    /// convert(to:) builds its job list from.
    var participated: Bool {
        included && report != nil
    }

    /// Conversion ran for this row and failed.
    var failed: Bool {
        convertError != nil
    }

    /// Outcome badge + tooltip for the results view, one switch for both.
    var resultText: (label: String, help: String) {
        if let convertError {
            return ("Failed", convertError)
        }
        switch result?.outcome {
        case let .converted(encodings):
            return ("Converted", "Pages: " + encodings.summary)
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

    /// Where each row sits, taken when a run starts: a run's rows only move
    /// when a newer request cancels it, so the hint holds while the run
    /// writes, and update() checks it anyway.
    static func positions(of rows: [FileRow]) -> [FileRow.ID: Int] {
        Dictionary(rows.indices.map { (rows[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Changes the row with `id`, looking first at `hint`.
    static func update(
        _ rows: inout [FileRow], _ id: FileRow.ID, at hint: Int? = nil,
        _ change: (inout FileRow) -> Void
    ) {
        if let hint, rows.indices.contains(hint), rows[hint].id == id {
            change(&rows[hint])
        } else if let i = rows.firstIndex(where: { $0.id == id }) {
            change(&rows[i])
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
    /// The batch being put together in the window: dropped, analysed,
    /// reviewed. Convert turns it into a job and the window is free for the
    /// next one.
    enum Phase: Equatable {
        case idle
        case analysing(done: Int, of: Int)
        case review
    }

    /// What the window shows: the batch being put together, or a queued one.
    enum Selection: Hashable {
        case draft
        case job(UUID)
    }

    @Published var phase = Phase.idle
    @Published var rows: [FileRow] = []
    @Published var sourceURLs: [URL] = []
    @Published var errorText: String?
    @Published var selection = Selection.draft
    @Published var jobs: [Job] = []
    /// Held like a printer's queue: what's waiting stays waiting, so several
    /// batches can be lined up before any starts.
    @Published var queueIsPaused = false {
        didSet { runNextJobIfIdle() }
    }

    // Settings (persisted under SettingsStore's keys, which the helper reads
    // too; defaults come from the library so the two can't drift)
    @AppStorage(SettingsStore.dpiCap) var dpiCap = Converter.Settings().dpiCap
    @AppStorage(SettingsStore.photoDpiCap) var photoDpiCap = Converter.Settings().photoDpiCap
    @AppStorage(SettingsStore.ocr) var ocrEnabled = Converter.Settings().ocr
    @AppStorage(SettingsStore.jpegQuality) var jpegQuality = Converter.Settings().jpegQuality
    @AppStorage(SettingsStore.minSavingPercent) var minSavingPercent =
        Int(Converter.Settings().minSavingFraction * 100)
    @AppStorage(SettingsStore.demotedTextFormat) var demotedTextFormat =
        Converter.Settings().demotedTextFormat
    @AppStorage(SettingsStore.removeScanEdges) var removeScanEdges =
        Converter.Settings().removeScanEdges
    /// Hold an assistant's batch until it's approved in the window. Off, as in
    /// Prospect: the client already asks before every tool call; on for a
    /// second look at what will be written.
    @AppStorage("approvesAssistantJobs") var approvesAssistantJobs = false

    /// Whether assistants can reach the queue, and the socket they reach it by.
    public let automation: Automation

    /// The window batch's analysis. Kept after cancel() so a test can await
    /// the cancelled run winding down.
    private(set) var worker: Task<Void, Never>?
    /// Sources added to the batch but not yet scanned into rows — carried
    /// over when a newer request supersedes the scan.
    private var unscanned: [URL] = []

    // Queue state (AppModel+Queue.swift).
    /// The job converting now; one at a time, since Vision runs one
    /// recognition at a time however many are asked of it.
    var runner: Task<Void, Never>?
    /// Assistants' batches being analysed.
    var jobAnalyses: [UUID: Task<Void, Never>] = [:]
    var jobWatchers: [UUID: JobWatcher] = [:]

    public init(
        initialFolder: URL? = nil, defaults: UserDefaults = .standard,
        socketPath: String = JobChannel.socketPath
    ) {
        automation = Automation(defaults: defaults, socketPath: socketPath)
        automation.handler = self
        automation.apply()
        if let initialFolder {
            analyse(urls: [initialFolder])
        }
    }

    /// The window batch is being analysed.
    public var busy: Bool {
        if case .analysing = phase { return true }
        return false
    }

    public var canConvert: Bool {
        phase == .review && rows.contains(where: \.participated)
    }

    var settings: Converter.Settings {
        SettingsStore.load(.standard)
    }

    // MARK: Totals

    var includedRows: [FileRow] {
        rows.filter(\.participated)
    }

    var totalInputBytes: Int {
        includedRows.compactMap { $0.report?.fileBytes }.reduce(0, +)
    }

    var totalEstimatedBytes: Int {
        includedRows.compactMap { $0.report?.estimatedBytes }.reduce(0, +)
    }

    // MARK: Analyse

    var sourceLabel: String {
        switch sourceURLs.count {
        case 0: ""
        case 1: sourceURLs[0].path
        case let n: "\(n) sources"
        }
    }

    /// What the window batch is called in the queue.
    var draftTitle: String {
        sourceURLs.isEmpty ? "New Batch" : JobRequest.name(for: sourceURLs)
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
    /// Services, the open panel): joins the window batch while one is being
    /// analysed or reviewed, else starts a fresh one, and shows it. Queued
    /// jobs carry on regardless. Drop targets in the UI don't use this —
    /// their append/replace semantics come from which zone was dropped on.
    func open(urls: [URL]) {
        analyse(urls: urls, append: phase != .idle)
        selection = .draft
    }

    /// Expand the given PDFs/folders and inspect them. With append=true
    /// new items join the existing rows; otherwise they replace them.
    func analyse(urls: [URL], append: Bool = false) {
        worker?.cancel()
        errorText = nil
        if append {
            sourceURLs += urls
            unscanned += urls
        } else {
            sourceURLs = urls
            unscanned = urls
            rows = []
        }
        phase = .analysing(done: 0, of: 0)
        worker = Task { await runAnalysis() }
    }

    private func runAnalysis() async {
        let items = await Self.scan(unscanned, merging: rows.map(\.item))
        guard !Task.isCancelled else { return }
        unscanned = []
        rows += items.map { FileRow(item: $0) }
        guard !rows.isEmpty else {
            phase = .idle
            sourceURLs = []
            errorText = "No PDFs found"
            return
        }
        // Every row still waiting: the new items, and any a superseded
        // analysis left unfinished.
        let pending = rows.filter { !$0.analysed }.map(\.item)
        let positions = FileRow.positions(of: rows)
        var done = 0
        phase = .analysing(done: 0, of: pending.count)
        let finished = await inspect(pending) { batch in
            var updated = rows
            for (index, outcome) in batch {
                let id = pending[index].id
                FileRow.update(&updated, id, at: positions[id]) {
                    $0.record(outcome, includeUnchanged: false)
                }
            }
            rows = updated
            done += batch.count
            phase = .analysing(done: done, of: pending.count)
        }
        if finished { phase = .review }
    }

    @concurrent
    nonisolated static func scan(
        _ urls: [URL], merging existing: [FolderScanner.Item]
    ) async -> [FolderScanner.Item] {
        FolderScanner.items(for: urls, merging: existing)
    }

    /// Inspects `items` several at a time and hands the outcomes to `apply`
    /// in batches of about a fiftieth of the list: each update copies the
    /// rows and redraws whatever watches the model, so once a file would
    /// cost the square of a big batch. False when the run was cancelled —
    /// a cancelled run applies nothing more, as the rows may already be a
    /// new batch's.
    func inspect(
        _ items: [FolderScanner.Item],
        apply: ([(Int, Result<PDFInspector.Report, any Error>)]) -> Void
    ) async -> Bool {
        let chunk = max(1, items.count / 50)
        var pending: [(Int, Result<PDFInspector.Report, any Error>)] = []
        await PDFInspector.inspectAll(items.map(\.url)) { index, outcome in
            // Back on the main actor, where cancel() runs.
            guard !Task.isCancelled else { return }
            pending.append((index, outcome))
            if pending.count >= chunk {
                apply(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        guard !Task.isCancelled else { return false }
        if !pending.isEmpty { apply(pending) }
        return true
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
        convertIfSafe(to: out)
    }

    /// Queues the window batch unless some output would land on one of its
    /// own originals — the source folder itself, a loose file's parent, or a
    /// folder inside a source tree that mirrors part of it.
    @discardableResult
    func convertIfSafe(to out: URL) -> Bool {
        if let problem = Self.overwriteProblem(rows, into: out) {
            errorText = problem
            return false
        }
        enqueueDraft(to: out)
        return true
    }

    /// The window batch becomes a job — its files as ticked, the settings as
    /// they are now — and the window is free for the next one. The job is
    /// shown, so its progress and results are where the batch was.
    func enqueueDraft(to out: URL) {
        let request = JobRequest(sources: sourceURLs, output: out)
        let id = enqueue(
            Job(request: request, source: .window, state: .queued, files: rows, settings: settings))
        reset()
        selection = .job(id)
    }

    /// Stops analysing the window batch. A row without a verdict has nothing
    /// to review, so it goes.
    func cancel() {
        worker?.cancel()
        rows.removeAll { !$0.analysed }
        unscanned = []
        if rows.isEmpty {
            sourceURLs = []
            phase = .idle
        } else {
            phase = .review
        }
    }

    /// Discards the window batch. Queued jobs are untouched.
    func reset() {
        worker?.cancel()
        rows = []
        sourceURLs = []
        unscanned = []
        errorText = nil
        phase = .idle
    }

    func setAllIncluded(_ included: Bool) {
        for i in rows.indices where rows[i].report != nil {
            rows[i].included = included
        }
    }
}
