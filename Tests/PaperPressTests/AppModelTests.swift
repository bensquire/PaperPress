import XCTest

@testable import PressApp
@testable import PressJobs
@testable import PressKit

@MainActor
class AppModelTestCase: FixtureTestCase {
    /// What the model's @AppStorage keeps in the test process's own defaults:
    /// cleared before and after each test, so none sees another's settings.
    nonisolated private static let storedKeys = [
        SettingsStore.dpiCap, SettingsStore.photoDpiCap, SettingsStore.ocr,
        SettingsStore.jpegQuality, SettingsStore.minSavingPercent, SettingsStore.demotedTextFormat,
        SettingsStore.removeScanEdges, Automation.approvesJobsKey,
    ]

    override func setUp() {
        super.setUp()
        Self.storedKeys.forEach(UserDefaults.standard.removeObject(forKey:))
    }

    override func tearDown() {
        Self.storedKeys.forEach(UserDefaults.standard.removeObject(forKey:))
        super.tearDown()
    }

    func makeModel() -> AppModel {
        let model = AppModel()
        model.ocrEnabled = false
        return model
    }

    struct TimedOut: Error {}

    /// Poll published state until the condition holds; throws on timeout
    /// so the test stops instead of asserting against half-built state.
    /// (@nonobjc: an async method on an NSObject subclass otherwise gets an
    /// Objective-C thunk, which would let the condition escape.)
    @nonobjc func waitFor(
        _ what: String, timeout: TimeInterval = 30, file: StaticString = #filePath,
        line: UInt = #line, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out after \(Int(timeout)) s waiting for \(what)", file: file, line: line)
                throw TimedOut()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// A model holding an analysed window batch of `files` in `in/`.
    func reviewedModel(
        _ files: [String: Data], file: StaticString = #filePath, line: UInt = #line
    ) async throws -> AppModel {
        let src = dir.appendingPathComponent("in")
        for (name, data) in files { Fixtures.write(data, to: src, name: name) }
        let model = makeModel()
        model.analyse(urls: [src])
        try await waitFor("review", file: file, line: line) { model.phase == .review }
        return model
    }

    /// The model's one job, once it's over.
    func finishedJob(
        _ model: AppModel, _ id: UUID? = nil, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Job {
        let id = try XCTUnwrap(id ?? model.jobs.first?.id, "no job queued", file: file, line: line)
        try await waitFor("job over", file: file, line: line) { model.job(id)?.state.isTerminal == true }
        return try XCTUnwrap(model.job(id), "job \(id) left the queue", file: file, line: line)
    }
}

final class AppModelTests: AppModelTestCase {
    func test_analyse_populatesRowsWithVerdictsAndLandsOnReview() async throws {
        // Arrange / Act — one convertible scan, one born-digital, in a folder
        let model = try await reviewedModel([
            "scan.pdf": Fixtures.lowResTextScanPDF(), "digital.pdf": Fixtures.bornDigitalPDF(),
        ])

        // Assert — verdicts assigned, pass-through unticked
        XCTAssertEqual(model.rows.count, 2)
        let scan = try XCTUnwrap(model.rows.first { $0.id == "scan.pdf" }, "no row for scan.pdf")
        let digital = try XCTUnwrap(
            model.rows.first { $0.id == "digital.pdf" }, "no row for digital.pdf")
        XCTAssertEqual(scan.report?.verdict, .convert)
        XCTAssertTrue(scan.included, "a scan to convert should be ticked")
        XCTAssertEqual(digital.report?.verdict, .passThrough(.bornDigital))
        XCTAssertFalse(digital.included, "a born-digital file should be unticked")
    }

    func test_open_duringReview_appendsAndDedupes() async throws {
        // Arrange — a review in progress with one file
        let a = Fixtures.write(Fixtures.lowResTextScanPDF(), to: dir, name: "a.pdf")
        let b = Fixtures.write(Fixtures.bornDigitalPDF(), to: dir, name: "b.pdf")
        let model = makeModel()
        model.analyse(urls: [a])
        try await waitFor("first review") { model.phase == .review }

        // Act — open a new file plus the one already in the batch
        model.open(urls: [a, b])
        try await waitFor("appended review") {
            model.phase == .review && model.rows.count == 2
        }

        // Assert — b appended, a not duplicated
        XCTAssertEqual(model.rows.map(\.id).sorted(), ["a.pdf", "b.pdf"])
    }

    func test_open_duringAnalysis_joinsTheBatch() async throws {
        // Arrange — an analysis just started
        let a = Fixtures.write(Fixtures.lowResTextScanPDF(), to: dir, name: "a.pdf")
        let b = Fixtures.write(Fixtures.bornDigitalPDF(), to: dir, name: "b.pdf")
        let model = makeModel()
        model.analyse(urls: [a])

        // Act — another file arrives before it finishes
        model.open(urls: [b])
        try await waitFor("review") { model.phase == .review }

        // Assert — both files, both analysed
        XCTAssertEqual(model.rows.map(\.id).sorted(), ["a.pdf", "b.pdf"])
        XCTAssertTrue(
            model.rows.allSatisfy(\.analysed),
            "unanalysed: \(model.rows.filter { !$0.analysed }.map(\.id))")
    }

    func test_cancel_duringAnalysis_dropsRowsWithoutAVerdict() {
        // Arrange — one row analysed, one still waiting
        let model = makeModel()
        let analysed = FolderScanner.Item(
            url: dir.appendingPathComponent("a.pdf"), relativePath: "a.pdf")
        let waiting = FolderScanner.Item(
            url: dir.appendingPathComponent("b.pdf"), relativePath: "b.pdf")
        var row = FileRow(item: analysed)
        row.error = "unreadable"
        model.rows = [row, FileRow(item: waiting)]
        model.phase = .analysing(done: 1, of: 2)

        // Act
        model.cancel()

        // Assert
        XCTAssertEqual(model.rows.map(\.id), ["a.pdf"])
        XCTAssertEqual(model.phase, .review)
    }

    func test_convertIfSafe_refusesOutputOntoAnotherOriginal() async throws {
        // Arrange — Scans/a.pdf and Scans/sub/a.pdf; Scans/sub as the output
        // folder would put a.pdf's output on top of the other original
        let root = dir.appendingPathComponent("Scans")
        Fixtures.write(Fixtures.lowResTextScanPDF(), to: root, name: "a.pdf")
        let other = Fixtures.write(
            Fixtures.lowResTextScanPDF(), to: root.appendingPathComponent("sub"), name: "a.pdf"
        )
        let before = try Data(contentsOf: other)
        let model = makeModel()
        model.analyse(urls: [root])
        try await waitFor("review") { model.phase == .review }

        // Act
        let started = model.convertIfSafe(to: root.appendingPathComponent("sub"))

        // Assert — refused up front, nothing queued, original untouched
        XCTAssertFalse(started, "conversion should not start")
        XCTAssertEqual(model.phase, .review)
        XCTAssertTrue(model.jobs.isEmpty, "\(model.jobs.count) jobs queued")
        XCTAssertNotNil(model.errorText, "the refusal should say why")
        XCTAssertEqual(try Data(contentsOf: other), before, "original should be untouched")
    }

    func test_convertIfSafe_refusesALooseFilesOwnFolder() async throws {
        // Arrange — a loose file: its parent as output would overwrite it
        let loose = Fixtures.write(Fixtures.lowResTextScanPDF(), to: dir, name: "loose.pdf")
        let model = makeModel()
        model.analyse(urls: [loose])
        try await waitFor("review") { model.phase == .review }

        // Act / Assert
        XCTAssertFalse(model.convertIfSafe(to: dir), "own folder should be refused")
        XCTAssertTrue(
            model.convertIfSafe(to: dir.appendingPathComponent("out")),
            "a separate folder should be accepted"
        )
    }
}

final class QueueTests: AppModelTestCase {
    func test_convert_queuesTheBatchAndFreesTheWindow() async throws {
        // Arrange
        let model = try await reviewedModel(["scan.pdf": Fixtures.lowResTextScanPDF()])

        // Act
        model.convertIfSafe(to: dir.appendingPathComponent("out"))

        // Assert — the batch is a job, shown; the window batch is empty again
        let job = try XCTUnwrap(model.jobs.first, "the batch wasn't queued")
        XCTAssertEqual(model.selection, .job(job.id))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.rows.isEmpty, "the window still holds \(model.rows.map(\.id))")
        XCTAssertEqual(job.source, .window)
    }

    func test_job_writesOutputsAndReportsPerFileResults() async throws {
        // Arrange — one convert, one pass-through ticked so it gets copied
        let model = try await reviewedModel([
            "scan.pdf": Fixtures.lowResTextScanPDF(), "digital.pdf": Fixtures.bornDigitalPDF(),
        ])
        model.setAllIncluded(true)
        let out = dir.appendingPathComponent("out")

        // Act
        model.convertIfSafe(to: out)
        let job = try await finishedJob(model)

        // Assert — files exist, per-row outcomes recorded
        XCTAssertEqual(job.state, .finished)
        for name in ["scan.pdf", "digital.pdf"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path), name)
        }
        let scan = try XCTUnwrap(job.files.first { $0.id == "scan.pdf" }, "no result for scan.pdf")
        let digital = try XCTUnwrap(
            job.files.first { $0.id == "digital.pdf" }, "no result for digital.pdf")
        XCTAssertEqual(scan.result?.outcome, .converted([.gray4]))
        XCTAssertEqual(digital.result?.outcome, .copied(.passThrough))
        XCTAssertEqual(job.totals.converted, 1)
        XCTAssertEqual(scan.resultText.label, "Converted")
        XCTAssertEqual(digital.resultText.label, "Copied")
    }

    func test_previewURL_routesToOutputWhenConvertedElseSource() async throws {
        // Arrange — a queued job, held by the paused queue
        let model = try await reviewedModel(["scan.pdf": Fixtures.lowResTextScanPDF()])
        let out = dir.appendingPathComponent("out")
        model.queueIsPaused = true
        model.convertIfSafe(to: out)
        let waiting = try XCTUnwrap(model.jobs.first, "the batch wasn't queued")

        // Act / Assert — no result yet: preview shows the source
        let row = try XCTUnwrap(waiting.files.first, "the queued batch has no files")
        XCTAssertEqual(model.previewURL(for: row, in: waiting), row.item.url)

        // Arrange — let it run
        model.queueIsPaused = false
        let job = try await finishedJob(model)

        // Act / Assert — result recorded: preview shows the written output
        XCTAssertEqual(
            model.previewURL(for: try XCTUnwrap(job.files.first, "the job has no files"), in: job),
            out.appendingPathComponent("scan.pdf")
        )
    }

    func test_jobs_convertOneAtATime() async throws {
        // Arrange — two batches lined up behind a paused queue
        let model = makeModel()
        model.queueIsPaused = true
        let first = try await queueBatch(in: model, named: "one")
        let second = try await queueBatch(in: model, named: "two")

        // Act
        model.queueIsPaused = false

        // Assert — the second waits while the first converts
        XCTAssertEqual(model.job(first)?.state, .converting)
        XCTAssertEqual(model.job(second)?.state, .queued)
        let done = try await finishedJob(model, second)
        XCTAssertEqual(done.state, .finished)
        XCTAssertEqual(model.job(first)?.state, .finished)
    }

    func test_pause_holdsQueuedJobsUntilResumed() async throws {
        // Arrange
        let model = makeModel()
        model.queueIsPaused = true

        // Act
        let id = try await queueBatch(in: model, named: "held")

        // Assert — held, then runs once resumed
        XCTAssertEqual(model.job(id)?.state, .queued)
        model.queueIsPaused = false
        let job = try await finishedJob(model, id)
        XCTAssertEqual(job.state, .finished)
    }

    func test_cancelJob_whileConverting_stopsItAndRunsTheNext() async throws {
        // Arrange — two batches, the first converting
        let model = makeModel()
        model.queueIsPaused = true
        let first = try await queueBatch(in: model, named: "one", files: 4)
        let second = try await queueBatch(in: model, named: "two")
        model.queueIsPaused = false
        XCTAssertEqual(model.job(first)?.state, .converting, "fixture sanity")

        // Act
        model.cancelJob(first)
        let next = try await finishedJob(model, second)

        // Assert — the first stays cancelled; the queue moved on
        XCTAssertEqual(model.job(first)?.state, .cancelled, "cancel should stick")
        XCTAssertEqual(next.state, .finished)
    }

    func test_open_whileAJobConverts_startsANewBatch() async throws {
        // Arrange — a batch converting
        let model = makeModel()
        let id = try await queueBatch(in: model, named: "one")
        let extra = Fixtures.write(Fixtures.bornDigitalPDF(), to: dir, name: "extra.pdf")

        // Act — a file arrives from Finder mid-run
        model.open(urls: [extra])
        try await waitFor("review") { model.phase == .review }
        let job = try await finishedJob(model, id)

        // Assert — the new file is the window's batch; the job finished apart
        XCTAssertEqual(model.selection, .draft)
        XCTAssertEqual(model.rows.map(\.id), ["extra.pdf"])
        XCTAssertEqual(job.state, .finished)
    }

    func test_savedTotals_leaveOutFailedFiles() {
        // Arrange — 10 MB converted to 1 MB, and a 50 MB file that failed
        func row(_ name: String, bytes: Int) -> FileRow {
            let item = FolderScanner.Item(url: dir.appendingPathComponent(name), relativePath: name)
            var row = FileRow(item: item)
            row.report = PDFInspector.Report(
                url: item.url, fileBytes: bytes, pages: [], verdict: .convert,
                estimatedBytes: bytes / 10)
            row.included = true
            return row
        }
        var converted = row("a.pdf", bytes: 10_000_000)
        converted.result = Converter.FileResult(
            inputBytes: 10_000_000, outputBytes: 1_000_000, outcome: .converted([.g4]))
        var failed = row("b.pdf", bytes: 50_000_000)
        failed.convertError = "boom"
        let job = Job(
            request: JobRequest(sources: [dir], output: dir), source: .window, state: .finished,
            files: [converted, failed], settings: Converter.Settings())

        // Act
        let totals = job.totals

        // Assert — 9 MB saved, not 59
        XCTAssertEqual(totals.savedBytes, 9_000_000)
        XCTAssertEqual(totals.failed, 1)
        XCTAssertEqual(failed.resultText.label, "Failed")
        XCTAssertEqual(failed.verdictLabel, "Re-compress", "a failed run isn't an unreadable file")
    }

    func test_summaries_carryTotalsWithoutFileLists() async throws {
        // Arrange — a finished batch
        let model = try await reviewedModel(["scan.pdf": Fixtures.lowResTextScanPDF()])
        model.convertIfSafe(to: dir.appendingPathComponent("out"))
        _ = try await finishedJob(model)

        // Act — what the queue's list sends an assistant
        let summary = try XCTUnwrap(model.summaries().first, "no summary for the finished batch")

        // Assert — the counts survive without the file list
        XCTAssertTrue(summary.files.isEmpty, "a summary carried \(summary.files.count) files")
        XCTAssertEqual(summary.totals.converted, 1)
        XCTAssertGreaterThan(summary.totals.inputBytes, 0, "the summary lost the input size")
    }

    func test_clearFinishedJobs_keepsUnfinishedOnes() async throws {
        // Arrange — one finished, one held by the paused queue
        let model = makeModel()
        let done = try await queueBatch(in: model, named: "done")
        _ = try await finishedJob(model, done)
        model.queueIsPaused = true
        let held = try await queueBatch(in: model, named: "held")

        // Act
        model.clearFinishedJobs()

        // Assert
        XCTAssertEqual(model.jobs.map(\.id), [held])
        XCTAssertEqual(model.selection, .job(held), "the held batch is still shown")
    }

    /// Analyses a folder of `files` low-res scans and queues it.
    private func queueBatch(in model: AppModel, named name: String, files: Int = 1) async throws
        -> UUID
    {
        let src = dir.appendingPathComponent(name)
        for i in 0..<files {
            Fixtures.write(Fixtures.lowResTextScanPDF(), to: src, name: "scan\(i).pdf")
        }
        model.analyse(urls: [src])
        try await waitFor("review of \(name)") { model.phase == .review }
        model.convertIfSafe(to: dir.appendingPathComponent("out-\(name)"))
        guard case .job(let id) = model.selection else {
            XCTFail("batch \(name) wasn't queued; the window shows \(model.selection)")
            throw TimedOut()
        }
        return id
    }
}

final class AssistantJobTests: AppModelTestCase {
    private func sources() -> URL {
        let src = dir.appendingPathComponent("in")
        Fixtures.write(Fixtures.lowResTextScanPDF(), to: src, name: "scan.pdf")
        Fixtures.write(Fixtures.bornDigitalPDF(), to: src, name: "digital.pdf")
        return src
    }

    func test_submit_analysesThenConvertsWhatIsWorthIt() async throws {
        // Arrange
        let model = makeModel()
        let out = dir.appendingPathComponent("out")

        // Act
        let accepted = try model.submit(JobRequest(sources: [sources()], output: out))
        let job = try await finishedJob(model, accepted.id)

        // Assert — the scan written, the born-digital file left alone, and the
        // window untouched
        XCTAssertEqual(accepted.state, .analysing)
        XCTAssertEqual(job.state, .finished)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("scan.pdf").path),
            "the scan should be written")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("digital.pdf").path),
            "the born-digital file should be left out")
        XCTAssertEqual(model.selection, .draft)
        XCTAssertEqual(job.source, .assistant)
    }

    func test_submit_copyUnchanged_mirrorsTheSources() async throws {
        // Arrange
        let model = makeModel()
        let out = dir.appendingPathComponent("out")

        // Act
        let accepted = try model.submit(
            JobRequest(sources: [sources()], output: out, copyUnchanged: true))
        _ = try await finishedJob(model, accepted.id)

        // Assert
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("digital.pdf").path),
            "the born-digital file should be copied with copy_unchanged")
    }

    func test_submit_withApproval_waitsForIt() async throws {
        // Arrange
        let model = makeModel()
        model.approvesAssistantJobs = true
        let accepted = try model.submit(
            JobRequest(sources: [sources()], output: dir.appendingPathComponent("out")))

        // Act / Assert — held until approved, then runs
        try await waitFor("approval") { model.job(accepted.id)?.state == .awaitingApproval }
        model.approve(accepted.id)
        let job = try await finishedJob(model, accepted.id)
        XCTAssertEqual(job.state, .finished)
    }

    func test_submit_outputOntoAnOriginal_failsAndWritesNothing() async throws {
        // Arrange — the sources' own folder as output
        let model = makeModel()
        let src = sources()
        let before = try Data(contentsOf: src.appendingPathComponent("scan.pdf"))

        // Act
        let accepted = try model.submit(JobRequest(sources: [src], output: src))
        let job = try await finishedJob(model, accepted.id)

        // Assert
        XCTAssertEqual(job.state, .failed)
        XCTAssertNotNil(job.failure, "the failed job should say why")
        XCTAssertEqual(
            try Data(contentsOf: src.appendingPathComponent("scan.pdf")), before,
            "the original should be untouched")
    }

    func test_approve_afterTickingAFileOntoAnOriginal_refuses() async throws {
        // Arrange — writing into in/sub: x.pdf is safe, but y.pdf (born
        // digital, unticked) would land on the original in/sub/y.pdf
        let src = dir.appendingPathComponent("in")
        Fixtures.write(Fixtures.lowResTextScanPDF(), to: src, name: "x.pdf")
        Fixtures.write(Fixtures.bornDigitalPDF(), to: src, name: "y.pdf")
        let original = Fixtures.write(
            Fixtures.bornDigitalPDF(), to: src.appendingPathComponent("sub"), name: "y.pdf")
        let before = try Data(contentsOf: original)
        let model = makeModel()
        model.approvesAssistantJobs = true
        let accepted = try model.submit(
            JobRequest(sources: [src], output: src.appendingPathComponent("sub")))
        try await waitFor("approval") { model.job(accepted.id)?.state == .awaitingApproval }

        // Act — tick y.pdf, then approve
        model.setIncluded(true, file: "y.pdf", in: accepted.id)
        model.approve(accepted.id)

        // Assert — held, with the reason, and the original untouched
        let job = try XCTUnwrap(model.job(accepted.id), "the job left the queue")
        XCTAssertEqual(job.state, .awaitingApproval)
        XCTAssertNotNil(job.failure, "the held job should say why")
        XCTAssertEqual(try Data(contentsOf: original), before, "the original should be untouched")
    }

    func test_submit_overridesChangeOnlyWhatTheyName() throws {
        // Arrange — the app's own settings, and an assistant asking for no OCR
        let model = makeModel()
        model.dpiCap = 200
        defer { model.dpiCap = Converter.Settings().dpiCap }

        // Act
        let accepted = try model.submit(
            JobRequest(
                sources: [sources()], output: dir.appendingPathComponent("out"),
                overrides: SettingsOverrides(ocr: false)))

        // Assert — the user's resolution kept, OCR off
        let settings = try XCTUnwrap(model.job(accepted.id), "the job wasn't queued").settings
        XCTAssertEqual(settings.dpiCap, 200)
        XCTAssertFalse(settings.ocr, "the override should turn OCR off")
    }

    func test_updates_followAJobToItsEnd() async throws {
        // Arrange
        let model = makeModel()
        let accepted = try model.submit(
            JobRequest(sources: [sources()], output: dir.appendingPathComponent("out")))

        // Act
        var seen: [JobState] = []
        for await status in model.updates(for: accepted.id) {
            seen.append(status.state)
        }

        // Assert — the stream ends, and on the job's end
        XCTAssertEqual(seen.last, .finished)
    }
}
