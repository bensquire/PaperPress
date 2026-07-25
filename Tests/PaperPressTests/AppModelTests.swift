import XCTest

@testable import PressApp
@testable import PressKit

@MainActor
final class AppModelTests: FixtureTestCase {
    private func makeModel() -> AppModel {
        let model = AppModel()
        model.ocrEnabled = false
        return model
    }

    private struct TimedOut: Error {}

    /// Poll published state until the condition holds; throws on timeout
    /// so the test stops instead of asserting against half-built state.
    private func waitFor(
        _ what: String, timeout: TimeInterval = 30,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw TimedOut()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func test_analyse_populatesRowsWithVerdictsAndLandsOnReview() async throws {
        // Arrange — one convertible scan, one born-digital, in a folder
        let src = dir.appendingPathComponent("in")
        Fixtures.write(Fixtures.lowResTextScanPDF(), to: src, name: "scan.pdf")
        Fixtures.write(Fixtures.bornDigitalPDF(), to: src, name: "digital.pdf")
        let model = makeModel()

        // Act
        model.analyse(urls: [src])
        try await waitFor("review") { model.phase == .review }

        // Assert — verdicts assigned, pass-through unticked
        XCTAssertEqual(model.rows.count, 2)
        let scan = try XCTUnwrap(model.rows.first { $0.id == "scan.pdf" })
        let digital = try XCTUnwrap(model.rows.first { $0.id == "digital.pdf" })
        XCTAssertEqual(scan.report?.verdict, .convert)
        XCTAssertTrue(scan.included)
        XCTAssertEqual(digital.report?.verdict, .passThrough(.bornDigital))
        XCTAssertFalse(digital.included)
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

    func test_convert_writesOutputsAndReportsPerFileResults() async throws {
        // Arrange — analysed batch: one convert, one pass-through (ticked
        // so it participates and gets copied)
        let src = dir.appendingPathComponent("in")
        Fixtures.write(Fixtures.lowResTextScanPDF(), to: src, name: "scan.pdf")
        Fixtures.write(Fixtures.bornDigitalPDF(), to: src, name: "digital.pdf")
        let model = makeModel()
        model.analyse(urls: [src])
        try await waitFor("review") { model.phase == .review }
        model.setAllIncluded(true)
        let out = dir.appendingPathComponent("out")

        // Act
        model.convert(to: out)
        try await waitFor("done") { model.phase == .done }

        // Assert — files exist, per-row outcomes recorded
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("scan.pdf").path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: out.appendingPathComponent("digital.pdf").path)
        )
        let scan = try XCTUnwrap(model.rows.first { $0.id == "scan.pdf" })
        let digital = try XCTUnwrap(model.rows.first { $0.id == "digital.pdf" })
        XCTAssertEqual(scan.result?.outcome, .converted([.gray4]))
        XCTAssertEqual(digital.result?.outcome, .copied(.passThrough))
        XCTAssertEqual(model.convertedCount, 1)
        XCTAssertTrue(scan.participated)
        XCTAssertEqual(scan.resultText.label, "Converted")
        XCTAssertEqual(digital.resultText.label, "Copied")
    }

    func test_previewURL_routesToOutputWhenConvertedElseSource() async throws {
        // Arrange — analysed but not yet converted
        let src = Fixtures.write(Fixtures.lowResTextScanPDF(), to: dir, name: "scan.pdf")
        let model = makeModel()
        model.analyse(urls: [src])
        try await waitFor("review") { model.phase == .review }

        // Act / Assert — no result yet: preview shows the source
        XCTAssertEqual(model.previewURL(for: try XCTUnwrap(model.rows.first)), src)

        // Arrange — convert
        let out = dir.appendingPathComponent("out")
        model.convert(to: out)
        try await waitFor("done") { model.phase == .done }

        // Act / Assert — result recorded: preview shows the written output
        XCTAssertEqual(
            model.previewURL(for: try XCTUnwrap(model.rows.first)),
            out.appendingPathComponent("scan.pdf")
        )
    }

    func test_outputCollides_detectsSourceFolderAndLooseParent() async throws {
        // Arrange — a loose file: its parent as output would overwrite it
        let loose = Fixtures.write(Fixtures.lowResTextScanPDF(), to: dir, name: "loose.pdf")
        let model = makeModel()
        model.analyse(urls: [loose])
        try await waitFor("review") { model.phase == .review }

        // Act / Assert
        XCTAssertTrue(model.outputCollides(with: dir))
        XCTAssertFalse(model.outputCollides(with: dir.appendingPathComponent("out")))
    }
}
