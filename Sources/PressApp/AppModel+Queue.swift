import AppKit
import Foundation
import PressJobs
import PressKit

/// A batch in the queue: from the window once reviewed, or from an assistant.
struct Job: Identifiable {
    var request: JobRequest
    let source: JobSource
    var state: JobState
    var failure: String?
    /// Every PDF the batch's sources hold, ticked where it writes them.
    var files: [FileRow]
    /// Settled when the job was made, not at run time: a job means what it
    /// meant when it was queued, whatever the settings become while it waits.
    var settings: Converter.Settings

    var id: UUID { request.id }

    /// The files this batch writes.
    var writing: [FileRow] { files.filter(\.participated) }

    /// What's been written so far, counted from the rows' own results.
    var totals: JobTotals {
        files.reduce(into: JobTotals()) { totals, row in totals.add(row.result, failed: row.failed) }
    }

    var done: Int { totals.done }

    /// How far through, 0 to 1.
    var fraction: Double {
        let total = writing.count
        return total > 0 ? Double(done) / Double(total) : 0
    }

    /// The job without its file list: what the queue's list and progress
    /// updates carry.
    var summary: JobStatus {
        JobStatus(
            request: request, source: source, state: state, failure: failure,
            total: writing.count, totals: totals)
    }

    var status: JobStatus {
        var status = summary
        status.files = files.map { row in
            FileStatus(
                path: row.item.url.path, relativePath: row.item.relativePath,
                verdict: row.report?.verdict, pages: row.report?.pages.count,
                inputBytes: row.report?.fileBytes, estimatedBytes: row.report?.estimatedBytes,
                included: row.participated, outcome: row.result?.outcome,
                outputBytes: row.result?.outputBytes, error: row.error,
                conversionError: row.convertError)
        }
        return status
    }
}

/// What can be done to a job in its state — one list for the detail's
/// buttons and the queue's menu.
enum JobAction: Hashable {
    case approve, reject, cancel, reveal, remove

    static func available(for job: Job) -> [JobAction] {
        switch job.state {
        case .awaitingApproval: [.reject, .approve]
        case .analysing, .queued, .converting: [.cancel]
        case .finished, .failed, .cancelled: [.reveal, .remove]
        }
    }

    var title: String {
        switch self {
        case .approve: "Approve"
        case .reject: "Reject"
        case .cancel: "Cancel"
        case .reveal: "Show in Finder"
        case .remove: "Remove"
        }
    }

    func isEnabled(for job: Job) -> Bool {
        switch self {
        case .approve: !job.writing.isEmpty
        case .reveal: job.done > 0
        case .reject, .cancel, .remove: true
        }
    }
}

/// A client waiting on a job, and the summary it was last sent.
struct JobWatcher {
    let id: UUID
    let continuation: AsyncStream<JobStatus>.Continuation
    var last: JobStatus?
}

/// The queue: every conversion goes through it, from the window and from
/// assistants alike. One job converts at a time — Vision runs one
/// recognition at a time however many are asked of it (8 pages: 7.61 s
/// serial, 7.56 s concurrent on 10 cores), so two batches at once would
/// each take twice as long — and the window stays free to put the next
/// batch together meanwhile.
extension AppModel {
    func job(_ id: UUID) -> Job? {
        jobs.first { $0.id == id }
    }

    /// Anything not yet over: closing the window or quitting would drop it.
    public var hasUnfinishedJobs: Bool {
        jobs.contains { !$0.state.isTerminal }
    }

    /// The queue's one admission rule: no output may land on one of the
    /// batch's own originals (`files` is the whole batch, ticked or not:
    /// every one is an original). Checked whenever a batch joins the queue —
    /// including on approval, which can tick more files.
    static func overwriteProblem(_ files: [FileRow], into output: URL) -> String? {
        guard
            let clash = OutputPlan.firstCollision(
                files.filter(\.participated).map(\.item), sources: files.map(\.item), in: output)
        else { return nil }
        return
            "Writing into \(output.path) would put \(clash.relativePath) on top of an original; choose another folder"
    }

    /// Adds a job and starts it if nothing is running.
    @discardableResult
    func enqueue(_ job: Job) -> UUID {
        jobs.append(job)
        notifyJobWatchers()
        runNextJobIfIdle()
        return job.id
    }

    /// Changes a job and tells any client waiting on it.
    func updateJob(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        notifyJobWatchers()
    }

    func perform(_ action: JobAction, on id: UUID) {
        switch action {
        case .approve: approve(id)
        case .reject, .cancel: cancelJob(id)
        case .reveal: revealOutput(of: id)
        case .remove: removeJob(id)
        }
    }

    /// Lets a job that was waiting for approval run — unless the files now
    /// ticked would overwrite an original, which it says instead.
    func approve(_ id: UUID) {
        guard let job = job(id), job.state == .awaitingApproval else { return }
        if let problem = Self.overwriteProblem(job.files, into: job.request.output) {
            return updateJob(id) { $0.failure = problem }
        }
        updateJob(id) {
            $0.failure = nil
            $0.state = .queued
        }
        runNextJobIfIdle()
    }

    /// Ticks or unticks a file of a job still waiting for approval.
    func setIncluded(_ included: Bool, file: FileRow.ID, in id: UUID) {
        guard job(id)?.state == .awaitingApproval else { return }
        updateJob(id) { job in
            FileRow.update(&job.files, file) { $0.included = included && $0.report != nil }
        }
    }

    /// Takes a waiting job out of the queue, or stops the running one after
    /// its current page; the runner then moves on to the next.
    public func cancelJob(_ id: UUID) {
        guard let job = job(id), !job.state.isTerminal else { return }
        switch job.state {
        case .analysing:
            jobAnalyses[id]?.cancel()
            jobAnalyses[id] = nil
        case .converting:
            runner?.cancel()
        default:
            break
        }
        updateJob(id) { $0.state = .cancelled }
    }

    func removeJob(_ id: UUID) {
        guard job(id)?.state.isTerminal == true else { return }
        jobs.removeAll { $0.id == id }
        if selection == .job(id) { selection = .draft }
    }

    func clearFinishedJobs() {
        jobs.removeAll(where: \.state.isTerminal)
        if case .job(let id) = selection, job(id) == nil { selection = .draft }
    }

    /// Starts the next queued job when nothing is converting and the queue
    /// isn't paused. Called wherever something stops running or is queued.
    func runNextJobIfIdle() {
        guard runner == nil, !queueIsPaused,
            let next = jobs.first(where: { $0.state == .queued })
        else { return }
        let id = next.id
        updateJob(id) { $0.state = .converting }
        let work = next.writing.compactMap { row in
            row.report.map {
                Work(
                    id: row.id, report: $0,
                    destination: OutputPlan.destination(for: row.item, in: next.request.output))
            }
        }
        let positions = FileRow.positions(of: next.files)
        let settings = next.settings
        runner = Task {
            await convert(id, work, positions: positions, settings: settings)
            runner = nil
            runNextJobIfIdle()
        }
    }

    struct Work: Sendable {
        let id: FileRow.ID
        let report: PDFInspector.Report
        let destination: URL
    }

    private func convert(
        _ jobID: UUID, _ work: [Work], positions: [FileRow.ID: Int], settings: Converter.Settings
    ) async {
        // Files are independent (distinct output paths), so a few convert
        // concurrently. Vision serialises recognition, so with OCR on a
        // second file only overlaps its CPU stages with the first's OCR, and
        // more would just hold page buffers.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let width = settings.ocr ? 2 : min(4, max(1, cores - 2))
        typealias Outcome = (FileRow.ID, Result<Converter.FileResult, any Error>)
        await withTaskGroup(of: Outcome.self) { group in
            var next = 0
            func spawnNext(into group: inout TaskGroup<Outcome>) {
                guard next < work.count, !Task.isCancelled else { return }
                let item = work[next]
                next += 1
                group.addTask { (item.id, await Self.convert(item, settings: settings)) }
            }
            for _ in 0..<width {
                spawnNext(into: &group)
            }
            for await (id, result) in group {
                // A cancelled job's stragglers record nothing; their files
                // stop at the next page and write nothing.
                guard !Task.isCancelled else { continue }
                updateJob(jobID) { job in
                    FileRow.update(&job.files, id, at: positions[id]) { row in
                        switch result {
                        case let .success(r): row.result = r
                        case let .failure(e): row.convertError = e.localizedDescription
                        }
                    }
                }
                spawnNext(into: &group)
            }
        }
        guard !Task.isCancelled else { return }
        updateJob(jobID) { $0.state = .finished }
    }

    @concurrent
    private nonisolated static func convert(
        _ work: Work, settings: Converter.Settings
    ) async -> Result<Converter.FileResult, any Error> {
        Result {
            try Converter.convert(report: work.report, to: work.destination, settings: settings)
        }
    }

    /// The file to preview for a job's row: the written output when the
    /// conversion produced one (the point is to inspect quality), else the
    /// source. Routed by recorded results, not filesystem checks — no stat()
    /// in view bodies.
    func previewURL(for row: FileRow, in job: Job) -> URL {
        row.result != nil
            ? OutputPlan.destination(for: row.item, in: job.request.output) : row.item.url
    }

    func revealOutput(of id: UUID) {
        guard let job = job(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([job.request.output])
    }

    // MARK: Assistants' batches

    /// An assistant's batch, analysed the way the window analyses one, then
    /// queued — or held for approval. The window isn't taken from whoever is
    /// using it; the job appears in the queue.
    private func analyseJob(_ id: UUID) async {
        guard let request = job(id)?.request else { return }
        let items = await Self.scan(request.sources, merging: [])
        guard !Task.isCancelled else { return }
        guard !items.isEmpty else {
            return finishAnalysis(id) {
                $0.state = .failed
                $0.failure = "No PDFs found in \(request.sources.map(\.path).joined(separator: ", "))"
            }
        }
        updateJob(id) { $0.files = items.map { FileRow(item: $0) } }
        let finished = await inspect(items) { batch in
            updateJob(id) { job in
                for (index, outcome) in batch {
                    // Rows are in item order, so the index is the row's place.
                    FileRow.update(&job.files, items[index].id, at: index) {
                        $0.record(outcome, includeUnchanged: request.copyUnchanged)
                    }
                }
            }
        }
        guard finished, let analysed = job(id) else { return }
        if let problem = Self.overwriteProblem(analysed.files, into: request.output) {
            return finishAnalysis(id) {
                $0.state = .failed
                $0.failure = problem
            }
        }
        if analysed.writing.isEmpty {
            return finishAnalysis(id) { $0.state = .finished }
        }
        let holds = approvesAssistantJobs
        finishAnalysis(id) { $0.state = holds ? .awaitingApproval : .queued }
        if holds {
            NSApp?.requestUserAttention(.informationalRequest)
        }
        runNextJobIfIdle()
    }

    private func finishAnalysis(_ id: UUID, _ change: (inout Job) -> Void) {
        jobAnalyses[id] = nil
        updateJob(id, change)
    }
}

/// The queue as the socket sees it.
extension AppModel: JobHandling {
    public func status(of id: UUID) -> JobStatus? {
        job(id)?.status
    }

    public func summaries() -> [JobStatus] {
        jobs.map(\.summary)
    }

    public func submit(_ request: JobRequest) throws -> JobStatus {
        guard !request.sources.isEmpty else {
            throw JobRefusal("A batch needs at least one PDF or folder.")
        }
        guard request.output.isFileURL else {
            throw JobRefusal("The output must be a folder on this Mac.")
        }
        guard job(request.id) == nil else {
            throw JobRefusal("Job \(request.id.uuidString) is already queued.")
        }
        let job = Job(
            request: request, source: .assistant, state: .analysing, files: [],
            settings: request.overrides.applied(to: settings))
        jobs.append(job)
        jobAnalyses[job.id] = Task { await analyseJob(job.id) }
        notifyJobWatchers()
        return job.status
    }

    public func updates(for id: UUID) -> AsyncStream<JobStatus> {
        // The newest only: a client waiting on a batch wants where it is, and a
        // slow one shouldn't make the app hold every tick it missed.
        let (stream, continuation) = AsyncStream.makeStream(
            of: JobStatus.self, bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        jobWatchers[key] = JobWatcher(id: id, continuation: continuation)
        continuation.onTermination = { _ in
            Task { @MainActor [weak self] in self?.jobWatchers[key] = nil }
        }
        notifyJobWatchers()
        return stream
    }

    /// Tells each waiting client about its job, if it changed — as a summary:
    /// building and comparing every file's status on every tick would cost
    /// the square of the batch. With nobody waiting it is one empty check.
    func notifyJobWatchers() {
        guard !jobWatchers.isEmpty else { return }
        for (key, watcher) in jobWatchers {
            guard let summary = job(watcher.id)?.summary else {
                watcher.continuation.finish()
                jobWatchers[key] = nil
                continue
            }
            guard summary != watcher.last else { continue }
            jobWatchers[key]?.last = summary
            watcher.continuation.yield(summary)
            if summary.state.isTerminal {
                watcher.continuation.finish()
                jobWatchers[key] = nil
            }
        }
    }
}
