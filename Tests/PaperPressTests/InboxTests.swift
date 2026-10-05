import XCTest

@testable import PressApp
@testable import PressJobs

final class InboxTests: FixtureTestCase {
    private var inbox: URL { dir.appendingPathComponent("Inbox") }

    func test_contains_onlyWhatLivesInTheInbox() throws {
        // Arrange — a file in it, the folder itself, a look-alike sibling,
        // and a linked folder leading out
        let file = Fixtures.touch("Inbox/sub/a.pdf", in: dir)
        let outside = Fixtures.touch("elsewhere/b.pdf", in: dir)
        Fixtures.touch("Inbox2/c.pdf", in: dir)
        try FileManager.default.createSymbolicLink(
            at: inbox.appendingPathComponent("link"), withDestinationURL: outside.deletingLastPathComponent())

        // Act / Assert
        XCTAssertTrue(Inbox.contains(file, in: inbox))
        XCTAssertFalse(Inbox.contains(inbox, in: inbox))
        XCTAssertFalse(Inbox.contains(dir.appendingPathComponent("Inbox2/c.pdf"), in: inbox))
        XCTAssertFalse(Inbox.contains(outside, in: inbox))
        XCTAssertFalse(Inbox.contains(inbox.appendingPathComponent("link/b.pdf"), in: inbox))
        XCTAssertTrue(Inbox.contains(inbox.appendingPathComponent("link"), in: inbox), "the link itself")
    }

    func test_remove_deletesInboxFilesAndTheFoldersTheyLeaveEmpty() throws {
        // Arrange
        let dropped = Fixtures.touch("Inbox/chat/a.pdf", in: dir)
        let kept = Fixtures.touch("Inbox/b.pdf", in: dir)
        let outside = Fixtures.touch("elsewhere/c.pdf", in: dir)
        try FileManager.default.createSymbolicLink(
            at: inbox.appendingPathComponent("link"), withDestinationURL: outside.deletingLastPathComponent())

        // Act — handed everything, including what isn't its to delete
        Inbox.remove([dropped, outside, inbox.appendingPathComponent("link/c.pdf"), inbox], from: inbox)

        // Assert
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        XCTAssertFalse(exists(dropped))
        XCTAssertFalse(exists(dropped.deletingLastPathComponent()), "emptied folder goes too")
        XCTAssertTrue(exists(kept))
        XCTAssertTrue(exists(outside), "never outside the inbox, even through a link")
        XCTAssertTrue(exists(inbox))
    }

    func test_sweep_deletesOnlyWhatHasWaitedADay() {
        // Arrange
        let file = Fixtures.touch("Inbox/a.pdf", in: dir)

        // Act / Assert — kept today, gone two days on
        Inbox.sweep(inbox)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        Inbox.sweep(inbox, now: Date().addingTimeInterval(2 * Inbox.keptFor))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

final class InboxJobTests: AppModelTestCase {
    func test_job_deletesTheInboxFilesItWroteOut() async throws {
        // Arrange — a scan saved into the inbox, a born-digital file beside
        // it that the batch leaves alone, and a scan elsewhere
        let model = makeModel()
        model.inbox = dir.appendingPathComponent("Inbox")
        let dropped = Fixtures.write(Fixtures.lowResTextScanPDF(), to: model.inbox, name: "scan.pdf")
        let skipped = Fixtures.write(Fixtures.bornDigitalPDF(), to: model.inbox, name: "digital.pdf")
        let original = Fixtures.write(
            Fixtures.lowResTextScanPDF(), to: dir.appendingPathComponent("in"), name: "own.pdf")
        let out = dir.appendingPathComponent("out")

        // Act
        let accepted = try model.submit(JobRequest(sources: [dropped, skipped, original], output: out))
        let job = try await finishedJob(model, accepted.id)

        // Assert — written out and gone from the inbox; the rest stay
        XCTAssertEqual(job.state, .finished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("scan.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropped.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: skipped.path), "not written out: kept for the day")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func test_convertIfSafe_refusesAWindowBatchsOutputIntoTheInbox() async throws {
        // Arrange
        let model = try await reviewedModel(["scan.pdf": Fixtures.lowResTextScanPDF()])
        model.inbox = dir.appendingPathComponent("Inbox")

        // Act / Assert
        XCTAssertFalse(model.convertIfSafe(to: model.inbox.appendingPathComponent("out")))
        XCTAssertTrue(model.jobs.isEmpty)
    }

    func test_submit_refusesOutputIntoTheInbox() {
        // Arrange
        let model = makeModel()
        model.inbox = dir.appendingPathComponent("Inbox")
        let src = Fixtures.write(
            Fixtures.lowResTextScanPDF(), to: dir.appendingPathComponent("in"), name: "a.pdf")

        // Act / Assert — the folder and anywhere in it
        for output in [model.inbox, model.inbox.appendingPathComponent("out")] {
            XCTAssertThrowsError(try model.submit(JobRequest(sources: [src], output: output)), output.path)
        }
    }
}
