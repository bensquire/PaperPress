import CoreGraphics
import ImageIO
import XCTest

@testable import PressApp
@testable import PressJobs
@testable import PressKit
@testable import PressMCP

/// The app as a fake: answers each command with canned replies, and records
/// what it was sent.
final class FakeLink: PaperPressLink, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [JobCommand] = []
    let answer: @Sendable (JobCommand) throws -> [JobReply]

    init(answer: @escaping @Sendable (JobCommand) throws -> [JobReply]) {
        self.answer = answer
    }

    var sent: [JobCommand] { lock.withLock { commands } }

    func send(_ command: JobCommand) async throws -> JobReply {
        lock.withLock { commands.append(command) }
        guard let first = try answer(command).first else { throw JobClient.Failure.closed }
        return first
    }

    func replies(to command: JobCommand) -> AsyncThrowingStream<JobReply, Error> {
        lock.withLock { commands.append(command) }
        let replies = Result { try answer(command) }
        return AsyncThrowingStream { continuation in
            switch replies {
            case .success(let replies):
                for reply in replies { continuation.yield(reply) }
                // A wait that never ends: the job is still running.
                if case .wait = command,
                    !replies.contains(where: { if case .done = $0 { true } else { false } })
                {
                    return
                }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}

struct FakeLauncher: PaperPressLauncher {
    var running = true
    var launches: @Sendable () throws -> Void = {}
    var isRunning: Bool { get async { running } }
    var runningApp: AppCopy? { get async { nil } }
    var helper: AppCopy { AppCopy(path: "/test/paperpress-mcp", version: "1", built: nil) }
    var helperReplaced = false
    func launch() async throws { try launches() }
}

final class PaperPressToolsTests: FixtureTestCase {
    private func tools(_ link: PaperPressLink, launcher: FakeLauncher = FakeLauncher())
        -> PaperPressTools
    {
        var tools = PaperPressTools(link: link, launcher: launcher, workingDirectory: dir)
        tools.waitSeconds = 5
        tools.launchTimeout = .milliseconds(300)
        tools.pollInterval = .milliseconds(50)
        return tools
    }

    /// An app that has never heard of anything: for tools that shouldn't ask it.
    private let silentApp = FakeLink { _ in throw JobClient.Failure.unreachable }

    private func call(
        _ tools: PaperPressTools, _ name: String, _ arguments: [String: JSONValue]
    ) async throws -> MCPToolResult {
        try await tools.call(name, arguments: arguments, progress: .none)
    }

    // MARK: analyse

    func test_everyToolTakingASource_pointsAtTheInbox() {
        // Arrange / Act — a client may not show the server's instructions
        let sources = PaperPressTools.toolDefinitions.compactMap { tool -> (String, String)? in
            let properties = tool["inputSchema"]?["properties"]
            guard let source = properties?["paths"] ?? properties?["path"] else { return nil }
            return (tool["name"]?.string ?? "", source["description"]?.string ?? "")
        }

        // Assert
        XCTAssertEqual(Set(sources.map(\.0)), ["analyse", "preview", "convert"])
        for (name, description) in sources {
            XCTAssertTrue(description.contains(Inbox.folder.path), name)
        }
    }

    func test_analyse_givesEachFileAVerdictWithoutTheApp() async throws {
        // Arrange — a scan and a born-digital file
        let src = dir.appendingPathComponent("in")
        Fixtures.write(Fixtures.lowResTextScanPDF(), to: src, name: "scan.pdf")
        Fixtures.write(Fixtures.bornDigitalPDF(), to: src, name: "digital.pdf")
        let link = silentApp

        // Act
        let result = try await call(tools(link), "analyse", ["paths": [.string(src.path)]])

        // Assert — both judged, the app never asked
        XCTAssertFalse(result.isError, "\(result.text)")
        let text = result.text.joined()
        XCTAssertTrue(text.contains("2 PDFs: 1 to re-compress"), text)
        XCTAssertTrue(text.contains("1 born digital"), text)
        XCTAssertEqual(result.structured?["files"]?.array?.count, 2)
        XCTAssertTrue(link.sent.isEmpty, "analyse asked the app: \(link.sent)")
    }

    func test_analyse_fromAReplacedHelper_saysItIsTheOlderVersion() async throws {
        // Arrange — PaperPress updated under a helper the client kept running
        let src = Fixtures.write(Fixtures.lowResTextScanPDF(), to: dir, name: "scan.pdf")
        var launcher = FakeLauncher()
        launcher.helperReplaced = true

        // Act
        let result = try await call(
            tools(silentApp, launcher: launcher), "analyse", ["paths": [.string(src.path)]])

        // Assert — answered, and said first
        XCTAssertEqual(result.text.first, PaperPressTools.replacedNote)
        XCTAssertTrue(result.text.dropFirst().joined().contains("re-compress"), "\(result.text)")
    }

    func test_analyse_missingPath_isAnErrorNamingIt() async throws {
        // Arrange / Act
        let result = try await call(tools(silentApp), "analyse", ["paths": ["nowhere"]])

        // Assert
        XCTAssertTrue(result.isError, "should be an error, got \(result.text)")
        XCTAssertTrue(result.text.joined().contains("nowhere"), "\(result.text)")
    }

    // MARK: preview

    func test_preview_showsTheConvertedPageAndHowItWasEncoded() async throws {
        // Arrange — a 300 dpi text scan, which converts to 1-bit
        let page = Fixtures.textPage(width: 2480, height: 3508, noise: true)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 300), to: dir, name: "scan.pdf")

        // Act
        let result = try await call(tools(silentApp), "preview", ["path": .string(src.path)])

        // Assert — a PNG within the size a model is shown, and the encoding named
        XCTAssertFalse(result.isError, "\(result.text)")
        XCTAssertTrue(result.text.joined().contains("1-bit (CCITT G4) at 300 dpi"), "\(result.text)")
        let image = try XCTUnwrap(result.images.first, "no picture in \(result.text)")
        XCTAssertEqual(image.mimeType, "image/png")
        let size = try pixelSize(image.data)
        XCTAssertEqual(Int(max(size.width, size.height)), PaperPressTools.previewMaxPixels)
    }

    func test_preview_region_showsThatPartAtFullResolution() async throws {
        // Arrange
        let page = Fixtures.textPage(width: 2480, height: 3508, noise: true)
        let src = Fixtures.write(
            Fixtures.scannedPDF(pages: [page], dpi: 300), to: dir, name: "scan.pdf")

        // Act — the top-left tenth of the page
        let result = try await call(
            tools(silentApp), "preview",
            [
                "path": .string(src.path),
                "region": ["x": 0, "y": 0, "width": .number(0.1), "height": .number(0.1)],
            ])

        // Assert — 248 × 351 px: the region at the encoded 300 dpi, not scaled
        let size = try pixelSize(try XCTUnwrap(result.images.first, "no picture in \(result.text)").data)
        XCTAssertEqual(size.width, 248, accuracy: 1, "picture width in pixels")
        XCTAssertEqual(size.height, 351, accuracy: 1, "picture height in pixels")
    }

    func test_preview_lowResText_saysItStaysGrayscale() async throws {
        // Arrange
        let src = Fixtures.write(Fixtures.lowResTextScanPDF(), to: dir, name: "tiny.pdf")

        // Act
        let result = try await call(tools(silentApp), "preview", ["path": .string(src.path)])

        // Assert
        XCTAssertTrue(result.text.joined().contains("4-bit grayscale"), "\(result.text)")
    }

    func test_preview_ofAFileLeftAlone_saysSoAndShowsThePage() async throws {
        // Arrange — a born-digital file, which convert copies unchanged
        let src = Fixtures.write(Fixtures.bornDigitalPDF(), to: dir, name: "digital.pdf")

        // Act
        let result = try await call(tools(silentApp), "preview", ["path": .string(src.path)])

        // Assert
        XCTAssertFalse(result.isError, "\(result.text)")
        XCTAssertTrue(result.text.joined().contains("unchanged (born digital)"), "\(result.text)")
        XCTAssertNotNil(result.images.first, "no picture of the page in \(result.text)")
    }

    private func pixelSize(
        _ png: Data, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (width: Double, height: Double) {
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(png as CFData, nil), "the picture isn't an image",
            file: file, line: line)
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil), "the picture has no frame to decode",
            file: file, line: line)
        return (Double(image.width), Double(image.height))
    }

    // MARK: convert

    func test_convert_submitsAbsolutePathsAndOverrides_andReportsTheResult() async throws {
        // Arrange — an app that takes the batch and finishes it at once
        let src = Fixtures.write(Fixtures.lowResTextScanPDF(), to: dir, name: "scan.pdf")
        let done = FileStatus(
            path: src.path, relativePath: "scan.pdf", verdict: .convert, inputBytes: 100_000,
            included: true, outcome: .converted([.gray4]), outputBytes: 10_000)
        let totals = {
            var totals = JobTotals()
            totals.add(
                Converter.FileResult(
                    inputBytes: 100_000, outputBytes: 10_000, outcome: .converted([.gray4])),
                failed: false)
            return totals
        }()
        let link = FakeLink { command in
            switch command {
            case .ping: [.pong(version: JobChannel.version)]
            case .submit(let request):
                [.job(JobStatus(request: request, source: .assistant, state: .analysing))]
            case .wait:
                [
                    .done(
                        JobStatus(
                            request: JobRequest(sources: [src], output: URL(fileURLWithPath: "/out")),
                            source: .assistant, state: .finished, total: 1, totals: totals,
                            files: [done]))
                ]
            default: []
            }
        }

        // Act — a relative path, and one setting changed
        let result = try await call(
            tools(link), "convert",
            ["paths": ["scan.pdf"], "output": "/out", "settings": ["dpi_cap": 200]])

        // Assert
        XCTAssertFalse(result.isError, "\(result.text)")
        guard
            case .submit(let request)? = link.sent.first(where: {
                if case .submit = $0 { true } else { false }
            })
        else { return XCTFail("nothing submitted: \(link.sent)") }
        XCTAssertEqual(request.sources, [src.standardizedFileURL])
        XCTAssertEqual(request.overrides, SettingsOverrides(dpiCap: 200))
        XCTAssertTrue(result.text.joined().contains("1 converted"), "\(result.text)")
    }

    func test_convert_stillRunningAfterTheWait_isAResultNotAnError() async throws {
        // Arrange — an app whose job never ends
        let src = Fixtures.write(Fixtures.lowResTextScanPDF(), to: dir, name: "scan.pdf")
        let link = FakeLink { command in
            switch command {
            case .ping: [.pong(version: JobChannel.version)]
            case .submit(let request): [.job(JobStatus(request: request, source: .assistant, state: .queued))]
            case .status(let id):
                [
                    .job(
                        JobStatus(
                            request: JobRequest(id: id, sources: [src], output: src), source: .assistant,
                            state: .converting))
                ]
            default: []
            }
        }
        var tools = tools(link)
        tools.waitSeconds = 0.2

        // Act
        let result = try await call(tools, "convert", ["paths": [.string(src.path)], "output": "/out"])

        // Assert — the id handed back, to wait on again
        XCTAssertFalse(result.isError, "\(result.text)")
        XCTAssertTrue(result.text.joined().contains("Still running"), "\(result.text)")
    }

    func test_convert_whenPaperPressCantBeOpened_saysSo() async throws {
        // Arrange — nothing listening, not running, and launching fails
        let src = Fixtures.write(Fixtures.lowResTextScanPDF(), to: dir, name: "scan.pdf")
        let launcher = FakeLauncher(
            running: false, launches: { throw PaperPressTools.ToolFailure("not installed") })

        // Act
        let result = try await call(
            tools(silentApp, launcher: launcher), "convert",
            ["paths": [.string(src.path)], "output": "/out"])

        // Assert
        XCTAssertTrue(result.isError, "should be an error, got \(result.text)")
        XCTAssertTrue(result.text.joined().contains("not installed"), "\(result.text)")
    }

    func test_convert_runningButNotListening_pointsAtTheSetting() async throws {
        // Arrange — the app is open with assistants off
        let src = Fixtures.write(Fixtures.lowResTextScanPDF(), to: dir, name: "scan.pdf")

        // Act
        let result = try await call(
            tools(silentApp), "convert", ["paths": [.string(src.path)], "output": "/out"])

        // Assert
        XCTAssertTrue(result.isError, "should be an error, got \(result.text)")
        XCTAssertTrue(result.text.joined().contains("Settings › Assistants"), "\(result.text)")
    }

    func test_convert_againstAnAppOfAnotherProtocol_namesBothSides() async throws {
        // Arrange
        let src = Fixtures.write(Fixtures.lowResTextScanPDF(), to: dir, name: "scan.pdf")
        let link = FakeLink { _ in [.pong(version: JobChannel.version + 1)] }

        // Act
        let result = try await call(
            tools(link), "convert", ["paths": [.string(src.path)], "output": "/out"])

        // Assert
        XCTAssertTrue(result.isError, "should be an error, got \(result.text)")
        XCTAssertTrue(result.text.joined().contains("protocol"), "\(result.text)")
    }

    func test_jobs_withPaperPressClosed_saysItIsNotRunning() async throws {
        // Arrange / Act
        let result = try await call(tools(silentApp), "jobs", [:])

        // Assert
        XCTAssertTrue(result.isError, "should be an error, got \(result.text)")
        XCTAssertTrue(result.text.joined().contains("not running"), "\(result.text)")
    }
}

final class JobLinesTests: XCTestCase {
    func test_buffer_cutsWholeLinesAndKeepsTheRest() {
        // Arrange
        var buffer = JobLines.Buffer()

        // Act
        let first = buffer.append(Data("one\ntw".utf8))
        let second = buffer.append(Data("o\n".utf8))

        // Assert
        XCTAssertEqual(first.map { String(decoding: $0, as: UTF8.self) }, ["one"])
        XCTAssertEqual(second.map { String(decoding: $0, as: UTF8.self) }, ["two"])
    }
}

/// The helper's tools through a real socket into a real queue.
final class AssistantEndToEndTests: AppModelTestCase {
    private let suite = "PaperPressTests-\(UUID().uuidString)"
    // Short: a socket path holds at most 104 bytes, and test temp folders
    // run long.
    private let socketFolder = URL(fileURLWithPath: "/tmp/pp-\(UUID().uuidString.prefix(8))")

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: socketFolder)
        super.tearDown()
    }

    private func listeningModel(
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> (AppModel, String) {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suite), "no defaults suite \(suite)", file: file, line: line)
        defaults.set(true, forKey: Automation.enabledKey)
        let path = socketFolder.appendingPathComponent("s.sock").path
        let model = AppModel(defaults: defaults, socketPath: path)
        model.ocrEnabled = false
        try await waitFor("listening", file: file, line: line) {
            model.automation.state == .listening
        }
        return (model, path)
    }

    func test_convertTool_writesThroughTheQueue() async throws {
        // Arrange — the app listening, a scan to convert
        let (model, path) = try await listeningModel()
        defer { model.automation.isEnabled = false }
        let src = Fixtures.write(
            Fixtures.lowResTextScanPDF(), to: dir.appendingPathComponent("in"), name: "scan.pdf")
        let out = dir.appendingPathComponent("out")
        let tools = PaperPressTools(
            link: JobClient(path: path), launcher: FakeLauncher(), workingDirectory: dir)

        // Act
        let result = try await tools.call(
            "convert", arguments: ["paths": [.string(src.path)], "output": .string(out.path)],
            progress: .none)

        // Assert — written, reported, and the job in the window's queue
        XCTAssertFalse(result.isError, "\(result.text)")
        XCTAssertTrue(result.text.joined().contains("1 converted"), "\(result.text)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("scan.pdf").path),
            "the converted scan should be written")
        XCTAssertEqual(model.jobs.first?.source, .assistant)
    }

    func test_socket_isClosedWhenAssistantsAreTurnedOff() async throws {
        // Arrange
        let (model, path) = try await listeningModel()

        // Act
        model.automation.isEnabled = false

        // Assert — nothing answers
        do {
            _ = try await JobClient(path: path).send(.ping)
            XCTFail("the socket should be closed")
        } catch let failure as JobClient.Failure {
            XCTAssertEqual(failure, .unreachable)
        }
    }
}
