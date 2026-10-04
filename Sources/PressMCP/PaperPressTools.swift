import CoreGraphics
import Foundation
import ImageIO
import PressJobs
import PressKit
import UniformTypeIdentifiers

/// The app, as far as the helper's tools need it: its socket, and the AppKit
/// calls that find and launch it. Protocols, so a test can stand in for both.
public protocol PaperPressLink: Sendable {
    func send(_ command: JobCommand) async throws -> JobReply
    func replies(to command: JobCommand) -> AsyncThrowingStream<JobReply, Error>
}

extension JobClient: PaperPressLink {}

/// Where a copy of PaperPress or its helper lives, and which build it is: what a
/// person needs to tell two copies apart when they don't match.
public struct AppCopy: Sendable, Equatable {
    public var path: String
    public var version: String?
    public var built: Date?

    public init(path: String, version: String?, built: Date?) {
        self.path = path
        self.version = version
        self.built = built
    }

    var described: String {
        var words = path
        if let version { words += ", version \(version)" }
        if let built { words += ", built \(built.formatted(date: .abbreviated, time: .shortened))" }
        return words
    }
}

public protocol PaperPressLauncher: Sendable {
    var isRunning: Bool { get async }
    /// The copy of PaperPress that is running, if one is.
    var runningApp: AppCopy? { get async }
    /// This helper, as it was when it started: a helper keeps running the code
    /// it started with after the file on disk is replaced.
    var helper: AppCopy { get }
    func launch() async throws
}

/// PaperPress's tools. analyse and preview read files in this process and need
/// no app; convert and the rest go through the app's queue, where the user sees
/// every batch and can stop it.
public struct PaperPressTools: MCPTools {
    let link: PaperPressLink
    let launcher: PaperPressLauncher
    /// What a relative path in a call is relative to: the client's, which launched this.
    let workingDirectory: URL
    public var launchTimeout: Duration = .seconds(30)
    /// How long a call waits for a job before handing back its id instead, until
    /// the client shows it will sit through longer. Learnt in Prospect: Claude
    /// Desktop's bridge gave up at 60 s on a job that was running perfectly well,
    /// which reads as a failure and invites a retry that does the work twice.
    public var waitSeconds: Double = 45
    public var pollInterval: Duration = .milliseconds(250)
    /// The longest wait this client has already sat through.
    let patience = Patience()

    /// A preview's longer side, in pixels: the most a model is shown of a picture
    /// before the client scales it down.
    static let previewMaxPixels = 1568
    /// Files listed in a reply before the rest are left to `detail`.
    static let listedFiles = 50

    public init(link: PaperPressLink, launcher: PaperPressLauncher, workingDirectory: URL) {
        self.link = link
        self.launcher = launcher
        self.workingDirectory = workingDirectory
    }

    public static let instructions = """
        PaperPress shrinks scanned PDFs on this Mac. Scan pages become 1-bit CCITT G4 (about \
        20 KB an A4 page) with a searchable OCR text layer; photographs stay grayscale JPEG; \
        print too fine for black and white stays 4-bit grayscale; born-digital pages are kept as \
        they are. Start with analyse: it reads PDFs or folders of them without changing anything \
        and gives each file a verdict (re-compress, or leave alone because it is born digital, \
        already converted, already compact or already small) with an estimated size. Use preview \
        to see one page as it would come out before committing a batch, when legibility matters. \
        Then convert into an output folder: copies are written there mirroring the sources. \
        Originals are never modified, an output folder that would put a file on top of an \
        original is refused, and a file already in the output folder is replaced only if \
        PaperPress wrote it. Conversion takes about a second a page with OCR, so convert hands \
        back a job id after 45 seconds rather than holding the call; follow it with wait. Jobs \
        run one at a time in PaperPress's queue, where the user can see and cancel them, and the \
        user may have to approve one before it runs.
        """

    public var definitions: [JSONValue] { Self.toolDefinitions }

    static let toolDefinitions: [JSONValue] = {
        let paths: JSONValue = [
            "type": "array", "minItems": 1, "items": ["type": "string"],
            "description":
                "PDF files and folders of them (searched recursively). Full paths are safest: a relative path is taken from wherever the client started this server.",
        ]
        // Defaults read from the converter, so the schema can't drift from it.
        let defaults = Converter.Settings()
        let settings: JSONValue = [
            "type": "object", "additionalProperties": false,
            "description": "Changes for this batch only; anything left out keeps PaperPress's own setting.",
            "properties": [
                "dpi_cap": [
                    "type": "integer", "minimum": 72, "maximum": 1200,
                    "description": .string(
                        "Resolution text pages are rendered and stored at (PaperPress's default \(defaults.dpiCap))."
                    ),
                ],
                "photo_dpi_cap": [
                    "type": "integer", "minimum": 72, "maximum": 600,
                    "description": .string(
                        "Highest resolution for photographic pages (default \(defaults.photoDpiCap))."),
                ],
                "ocr": [
                    "type": "boolean",
                    "description": .string("Add a searchable text layer (default \(defaults.ocr))."),
                ],
                "jpeg_quality": [
                    "type": "number", "minimum": .number(0.1), "maximum": 1,
                    "description": .string(
                        "JPEG quality for photographic pages (default \(defaults.jpegQuality))."),
                ],
                "min_saving_percent": [
                    "type": "integer", "minimum": 0, "maximum": 99,
                    "description": .string(
                        "Copy the original instead when converting would save less than this (default \(Int(defaults.minSavingFraction * 100)))."
                    ),
                ],
                "low_res_text_format": [
                    "type": "string", "enum": ["gray4", "jpeg"],
                    "description": .string(
                        "How text kept grayscale (too low-res, or too fine, for 1-bit) is stored (default \(defaults.demotedTextFormat.rawValue))."
                    ),
                ],
                "remove_scan_edges": [
                    "type": "boolean",
                    "description": .string(
                        "Whiten black scan-edge bands on document pages (default \(defaults.removeScanEdges))."
                    ),
                ],
            ],
        ]
        let waitSecondsSchema: JSONValue = [
            "type": "number", "minimum": 0,
            "description":
                "How long to wait before handing back the job's id (default 45). Held to what this client has already sat through, since its transport may give up sooner.",
        ]
        let detail: JSONValue = [
            "type": "boolean",
            "description": .string(
                "List every file, not just the totals and the first \(listedFiles). Default false."),
        ]
        let id: JSONValue = ["type": "string", "description": "A job id, as convert returned it."]
        return [
            [
                "name": "analyse", "title": "Analyse PDFs",
                "description":
                    "Reads PDFs, or folders of them, and says what converting would do to each, without writing anything or needing the PaperPress app open. Each file gets a verdict — convert, or pass through as born_digital, already_processed, already_compact or already_small — with its pages, size and estimated converted size.",
                "inputSchema": [
                    "type": "object", "required": ["paths"], "additionalProperties": false,
                    "properties": ["paths": paths, "detail": detail],
                ],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "preview", "title": "Preview a converted page",
                "description": .string(
                    "Converts one page exactly as convert would (without OCR) and returns a picture of the result, how it was encoded and its size. Writes nothing. The picture is at most \(previewMaxPixels) pixels on its longer side, so a whole A4 page shows at about 130 dpi: use region to look closely at small print."
                ),
                "inputSchema": [
                    "type": "object", "required": ["path"], "additionalProperties": false,
                    "properties": [
                        "path": ["type": "string", "description": "A PDF file."],
                        "page": [
                            "type": "integer", "minimum": 1,
                            "description": "Page number, from 1 (default 1).",
                        ],
                        "region": [
                            "type": "object", "additionalProperties": false,
                            "required": ["x", "y", "width", "height"],
                            "description":
                                "Part of the page to show, as fractions of its size from the top left.",
                            "properties": [
                                "x": ["type": "number", "minimum": 0, "maximum": 1],
                                "y": ["type": "number", "minimum": 0, "maximum": 1],
                                "width": ["type": "number", "exclusiveMinimum": 0, "maximum": 1],
                                "height": ["type": "number", "exclusiveMinimum": 0, "maximum": 1],
                            ],
                        ],
                        "settings": settings,
                    ],
                ],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "convert", "title": "Convert PDFs",
                "description":
                    "Writes compressed copies of PDFs, or folders of them, into an output folder, through PaperPress's queue. By default only the files worth re-compressing are written; with copy_unchanged the rest are copied too, so the output mirrors the sources whole. Originals are never modified. Opens PaperPress if it isn't running (the user must have turned on Settings › Assistants). Returns the batch's results, or its job id if it is still running after wait_seconds; the job carries on either way.",
                "inputSchema": [
                    "type": "object", "required": ["paths", "output"], "additionalProperties": false,
                    "properties": [
                        "paths": paths,
                        "output": [
                            "type": "string",
                            "description":
                                "The folder to write into, created if needed. Not a source folder, and not one inside a source folder that would mirror onto its originals.",
                        ],
                        "copy_unchanged": [
                            "type": "boolean",
                            "description":
                                "Also copy files that are left alone, byte for byte (default false).",
                        ],
                        "settings": settings,
                        "wait_seconds": waitSecondsSchema,
                        "detail": detail,
                    ],
                ],
                "annotations": ["destructiveHint": false],
            ],
            [
                "name": "wait", "title": "Wait for jobs",
                "description":
                    "Waits for jobs convert started — for the first to finish, or with all for every one — up to wait_seconds. A wait that runs out is a result, not an error: the jobs still running are listed with their state, to wait on again.",
                "inputSchema": [
                    "type": "object", "required": ["ids"], "additionalProperties": false,
                    "properties": [
                        "ids": ["type": "array", "minItems": 1, "items": id],
                        "all": ["type": "boolean", "description": "Wait for every job. Default false."],
                        "wait_seconds": waitSecondsSchema,
                        "detail": detail,
                    ],
                ],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "job_status", "title": "Follow a job",
                "description": "One job's state and progress, and once finished, what happened to each file.",
                "inputSchema": [
                    "type": "object", "required": ["id"], "additionalProperties": false,
                    "properties": ["id": id, "detail": detail],
                ],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "jobs", "title": "List PaperPress's queue",
                "description": "Every batch in PaperPress's queue this session, with its state.",
                "inputSchema": ["type": "object", "additionalProperties": false, "properties": [:]],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "cancel", "title": "Cancel a job",
                "description":
                    "Takes a waiting batch out of the queue, or stops a running one after its current page. Files already written stay.",
                "inputSchema": [
                    "type": "object", "required": ["id"], "additionalProperties": false,
                    "properties": ["id": id],
                ],
            ],
        ]
    }()

    public func call(_ name: String, arguments: [String: JSONValue], progress: MCPProgress)
        async throws -> MCPToolResult
    {
        do {
            switch name {
            case "analyse": return try await analyse(arguments, progress: progress)
            case "preview": return try preview(arguments)
            case "convert": return try await convert(arguments, progress: progress)
            case "wait": return try await waitForJobs(arguments, progress: progress)
            case "job_status": return try await jobStatus(arguments)
            case "jobs": return try await jobs()
            case "cancel": return try await cancel(arguments)
            default: throw MCPError.invalidParams("Unknown tool: \(name)")
            }
        } catch let failure as ToolFailure {
            return MCPToolResult(text: [failure.message], isError: true)
        }
    }

    /// A tool execution error, in words the model can act on.
    public struct ToolFailure: Error {
        public let message: String
        public init(_ message: String) { self.message = message }

        static let off = ToolFailure(
            "PaperPress is running but not taking batches from assistants: turn on Settings › Assistants › Allow AI assistants to convert with PaperPress."
        )
        static let notRunning = ToolFailure(
            "PaperPress is not running, or assistants are turned off in its Settings. Start a conversion to open it."
        )
    }

    // MARK: - analyse

    private func analyse(_ arguments: [String: JSONValue], progress: MCPProgress) async throws
        -> MCPToolResult
    {
        let urls = try paths(arguments)
        let items = FolderScanner.items(for: urls)
        guard !items.isEmpty else {
            throw ToolFailure("No PDFs found in \(urls.map(\.path).joined(separator: ", ")).")
        }
        var files = items.map {
            FileStatus(path: $0.url.path, relativePath: $0.relativePath, included: false)
        }
        // A notification a percent, not a file: each is a line the client parses.
        let step = max(1, items.count / 100)
        var done = 0
        await PDFInspector.inspectAll(items.map(\.url)) { index, result in
            switch result {
            case .success(let report):
                files[index].verdict = report.verdict
                files[index].pages = report.pages.count
                files[index].inputBytes = report.fileBytes
                files[index].estimatedBytes = report.estimatedBytes
                files[index].included = report.isWritten(copyingUnchanged: false)
            case .failure(let error):
                files[index].error = error.localizedDescription
            }
            done += 1
            if done % step == 0 || done == items.count {
                await progress.report(
                    Double(done) / Double(items.count), "Analysed \(done) of \(items.count)")
            }
        }
        let detail = arguments["detail"]?.bool ?? false
        let shown = Self.listed(files, detail: detail)
        var lines = [Self.analysisSummary(files)] + shown.map(Self.analysisLine)
        lines += Self.more(files.count - shown.count, indent: "")
        return MCPToolResult(
            text: [lines.joined(separator: "\n")],
            structured: [
                "files": try JSONValue.encoding(shown.map(FileSummary.init)),
                "total_files": .number(Double(files.count)),
            ])
    }

    static func analysisSummary(_ files: [FileStatus]) -> String {
        let convert = files.filter { $0.verdict == .convert }
        let input = convert.compactMap(\.inputBytes).reduce(0, +)
        let estimate = convert.compactMap(\.estimatedBytes).reduce(0, +)
        var parts = ["\(convert.count) to re-compress (\(byteLabel(input)) → about \(byteLabel(estimate)))"]
        for reason in [
            PDFInspector.PassReason.bornDigital, .alreadyProcessed, .alreadyCompact, .alreadySmall,
        ] {
            let count = files.count { $0.verdict == .passThrough(reason) }
            if count > 0 { parts.append("\(count) \(reason.label.lowercased())") }
        }
        let unreadable = files.count { $0.error != nil }
        if unreadable > 0 { parts.append("\(unreadable) unreadable") }
        return "\(files.count) PDF\(files.count == 1 ? "" : "s"): " + parts.joined(separator: ", ") + "."
    }

    static func analysisLine(_ file: FileStatus) -> String {
        if let error = file.error { return "\(file.path): unreadable — \(error)" }
        let size = file.inputBytes.map(byteLabel) ?? "?"
        let pages = file.pages.map { "\($0) page\($0 == 1 ? "" : "s")" } ?? ""
        switch file.verdict {
        case .convert:
            return
                "\(file.path): re-compress, \(pages), \(size) → about \(file.estimatedBytes.map(byteLabel) ?? "?")"
        case .passThrough(let reason):
            return "\(file.path): leave alone (\(reason.label.lowercased())), \(pages), \(size)"
        case nil:
            return "\(file.path): not analysed"
        }
    }

    // MARK: - preview

    private func preview(_ arguments: [String: JSONValue]) throws -> MCPToolResult {
        guard let path = arguments["path"]?.string else {
            throw MCPError.invalidParams("preview needs a path")
        }
        let url = resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolFailure("\(url.path) doesn't exist.")
        }
        let number = Int(arguments["page"]?.number ?? 1)
        let region = try self.region(arguments["region"])
        let report = try PDFInspector.inspect(url)
        guard report.pages.indices.contains(number - 1) else {
            throw ToolFailure("\(url.lastPathComponent) has \(report.pages.count) pages, not \(number).")
        }
        // The app's own settings, as the queue would convert with them.
        let settings = try settingsOverrides(arguments["settings"])
            .applied(to: SettingsStore.load(SettingsStore.appDefaults))
        switch try Converter.preview(page: number, of: report, settings: settings) {
        case .unchanged(let reason):
            return try picture(
                of: CGPDFDocument(url as CFURL)?.page(at: number), dpi: 150, region: region,
                lines: [
                    "convert would copy \(url.lastPathComponent) unchanged (\(reason.label.lowercased())); this is page \(number) as it is."
                ])
        case .converted(let pdf, let encoding, let dpi):
            let perPage = report.fileBytes / max(1, report.pages.count)
            let stored: String
            switch encoding {
            case .g4: stored = "1-bit (CCITT G4) at \(dpi ?? 0) dpi"
            case .gray4:
                stored =
                    "4-bit grayscale at \(dpi ?? 0) dpi (text kept grayscale: the scan is too low-res, or its print too fine, for 1-bit)"
            case .jpeg: stored = "grayscale JPEG at \(dpi ?? 0) dpi"
            case .original: stored = "kept as it is (a born-digital page)"
            }
            return try picture(
                of: CGDataProvider(data: pdf as CFData).flatMap(CGPDFDocument.init)?.page(at: 1),
                dpi: dpi ?? 150, region: region,
                lines: [
                    "Page \(number) of \(url.lastPathComponent) as convert would write it: \(stored), about \(byteLabel(pdf.count)) without its text layer. The source averages \(byteLabel(perPage)) a page."
                ])
        }
    }

    /// A page drawn as a viewer draws it, cropped to `region`, scaled to fit
    /// `previewMaxPixels`, as a PNG.
    private func picture(
        of page: CGPDFPage?, dpi: Int, region: CGRect?, lines: [String]
    ) throws -> MCPToolResult {
        guard let page else { throw ToolFailure("The page couldn't be drawn.") }
        var gray = try PDFRender.gray(page: page, dpi: dpi)
        if let region {
            let x0 = Int(region.minX * Double(gray.width))
            let y0 = Int(region.minY * Double(gray.height))
            let x1 = min(gray.width, max(x0 + 1, Int(region.maxX * Double(gray.width))))
            let y1 = min(gray.height, max(y0 + 1, Int(region.maxY * Double(gray.height))))
            gray = gray.cropped(Pipeline.Crop(x0: x0, y0: y0, x1: x1, y1: y1))
        }
        let longest = max(gray.width, gray.height)
        var shownDpi = Double(dpi)
        if longest > Self.previewMaxPixels {
            let scale = Double(Self.previewMaxPixels) / Double(longest)
            gray = gray.resampled(scale: scale)
            shownDpi *= scale
        }
        guard let image = gray.cgImage, let png = ImageEncode.png(image) else {
            throw ToolFailure("The picture couldn't be encoded.")
        }
        let shown =
            region == nil
            ? "The picture shows the whole page at \(Int(shownDpi.rounded())) dpi."
            : "The picture shows that region at \(Int(shownDpi.rounded())) dpi."
        return MCPToolResult(
            text: [(lines + [shown]).joined(separator: " ")],
            images: [.init(data: png, mimeType: "image/png")])
    }

    private func region(_ value: JSONValue?) throws -> CGRect? {
        guard let value else { return nil }
        guard let x = value["x"]?.number, let y = value["y"]?.number,
            let w = value["width"]?.number, let h = value["height"]?.number,
            x >= 0, y >= 0, w > 0, h > 0, x + w <= 1.0001, y + h <= 1.0001
        else {
            throw MCPError.invalidParams(
                "region needs x, y, width and height as fractions of the page, within it")
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - convert

    private func convert(_ arguments: [String: JSONValue], progress: MCPProgress) async throws
        -> MCPToolResult
    {
        let sources = try paths(arguments)
        guard let output = arguments["output"]?.string, !output.isEmpty else {
            throw MCPError.invalidParams("convert needs an output folder")
        }
        let request = JobRequest(
            sources: sources, output: resolve(output),
            copyUnchanged: arguments["copy_unchanged"]?.bool ?? false,
            overrides: try settingsOverrides(arguments["settings"]))
        try await reachApp()
        let accepted: JobStatus
        switch try await link.send(.submit(request)) {
        case .job(let status): accepted = status
        case .refused(let reason): throw ToolFailure(reason)
        case .error(let message): throw ToolFailure(message)
        default: throw ToolFailure("PaperPress didn't take the batch.")
        }
        let (seconds, notes) = await waiting(arguments)
        let ended = try await followUntil(accepted.id, seconds: seconds, progress: progress)
        let latest: JobStatus
        if let ended {
            latest = ended
        } else {
            latest = await status(of: accepted.id) ?? accepted
        }
        return report(
            [latest], seconds: seconds, notes: notes, detail: arguments["detail"]?.bool ?? false)
    }

    // MARK: - wait, job_status, jobs, cancel

    private func waitForJobs(_ arguments: [String: JSONValue], progress: MCPProgress) async throws
        -> MCPToolResult
    {
        let ids = try jobIDs(arguments["ids"])
        let all = arguments["all"]?.bool ?? false
        let (seconds, notes) = await waiting(arguments)
        var finished: [UUID: JobStatus] = [:]
        try await following(ids, seconds: seconds, progress: ids.count == 1 ? progress : .none) {
            status in
            finished[status.id] = status
            if ids.count > 1 {
                await progress.report(
                    Double(finished.count) / Double(ids.count),
                    "\(finished.count) of \(ids.count) jobs finished")
            }
            return all && finished.count < ids.count
        }
        var statuses: [JobStatus] = []
        for id in ids {
            if let status = finished[id] {
                statuses.append(status)
            } else if let status = await status(of: id) {
                statuses.append(status)
            }
        }
        return report(
            statuses, seconds: seconds, notes: notes, detail: arguments["detail"]?.bool ?? false)
    }

    private func jobStatus(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        report(
            [try await answer(.status(id: jobID(arguments["id"])))], seconds: nil, notes: [],
            detail: arguments["detail"]?.bool ?? false)
    }

    private func cancel(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        report(
            [try await answer(.cancel(id: jobID(arguments["id"])))], seconds: nil, notes: [],
            detail: false)
    }

    /// The app's answer about one job.
    private func answer(_ command: JobCommand) async throws -> JobStatus {
        switch try await ask(command) {
        case .job(let status): return status
        case .unknownJob(let id): throw ToolFailure("PaperPress has no job \(id.uuidString) this session.")
        default: throw ToolFailure("PaperPress didn't answer about that job.")
        }
    }

    private func jobs() async throws -> MCPToolResult {
        guard case .jobs(let statuses) = try await ask(.list) else {
            throw ToolFailure("PaperPress didn't list its queue.")
        }
        guard !statuses.isEmpty else {
            return MCPToolResult(text: ["PaperPress's queue is empty."], structured: ["jobs": []])
        }
        let lines = statuses.map { "\($0.id.uuidString)  \($0.name): \(Self.stateWords($0))" }
        return MCPToolResult(
            text: [lines.joined(separator: "\n")],
            structured: ["jobs": try JSONValue.encoding(statuses.map { JobSummary($0, files: false) })])
    }

    // MARK: - Reaching the app

    /// Makes sure the app is listening, launching it if it isn't running.
    private func reachApp() async throws {
        if try await ping() { return }
        guard !(await launcher.isRunning) else { throw ToolFailure.off }
        try await launcher.launch()
        guard try await poll(for: launchTimeout, { try await ping() ? true : nil }) != nil else {
            throw await launcher.isRunning
                ? ToolFailure.off : ToolFailure("PaperPress did not start within \(launchTimeout).")
        }
    }

    /// Asks again every `pollInterval` until the answer comes or the time is up.
    private func poll<T>(for timeout: Duration, _ check: () async throws -> T?) async throws -> T? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let answer = try await check() { return answer }
            try await Task.sleep(for: pollInterval)
        }
        return nil
    }

    private func ping() async throws -> Bool {
        guard case .pong(let version)? = try? await link.send(.ping) else { return false }
        guard version == JobChannel.version else {
            throw ToolFailure(
                Self.versionMismatch(
                    helperProtocol: JobChannel.version, appProtocol: version,
                    helper: launcher.helper, app: await launcher.runningApp))
        }
        return true
    }

    /// Names both sides and says which to update: a client keeps a helper
    /// running across an update of the app.
    public static func versionMismatch(
        helperProtocol: Int, appProtocol: Int, helper: AppCopy, app: AppCopy?
    ) -> String {
        var lines = [
            "This helper speaks protocol \(helperProtocol) and the running PaperPress speaks protocol \(appProtocol), so they cannot work together.",
            "Helper: \(helper.described).",
            "Running PaperPress: \(app?.described ?? "not found").",
        ]
        if helperProtocol > appProtocol {
            lines.append(
                "The running PaperPress is the older one: quit it, and open the PaperPress this helper came with."
            )
        } else {
            let fresh = app.map { " or point the client at \($0.path)/Contents/MacOS/paperpress-mcp" } ?? ""
            lines.append(
                "This helper is the older one. A client keeps its MCP server running after PaperPress is updated, so restart the server in the client (in Claude Code, /mcp; Claude Desktop, quit and reopen it)\(fresh)."
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Sends a command to an app that must already be running: asking after the
    /// queue doesn't launch it.
    private func ask(_ command: JobCommand) async throws -> JobReply {
        do {
            return try await link.send(command)
        } catch JobClient.Failure.unreachable {
            throw ToolFailure.notRunning
        }
    }

    private func status(of id: UUID) async -> JobStatus? {
        guard case .job(let status)? = try? await link.send(.status(id: id)) else { return nil }
        return status
    }

    // MARK: - Waiting

    /// How long this call waits, and what to say if that's less than it asked
    /// for: held to what this client is known to bear, since a caller can't see
    /// its own transport's timeout.
    private func waiting(_ arguments: [String: JSONValue]) async -> (seconds: Double, notes: [String]) {
        let borne = max(waitSeconds, patience.longest)
        guard let asked = arguments["wait_seconds"]?.number else { return (borne, []) }
        guard asked > borne else { return (asked, []) }
        return (
            borne,
            [
                "wait_seconds was held to \(Int(borne)) s rather than the \(Int(asked)) s asked for: a client's transport usually gives up at 60 s, and this one hasn't yet sat through longer. The job itself is unaffected."
            ]
        )
    }

    /// Follows every job in `ids` at once, handing each end to `each` as it
    /// comes, until `each` says it has enough or `seconds` pass. The jobs a wait
    /// leaves behind run on in PaperPress.
    private func following(
        _ ids: [UUID], seconds: Double, progress: MCPProgress = .none,
        each: (JobStatus) async -> Bool
    ) async throws {
        guard seconds > 0 else { return }
        let clock = ContinuousClock.now
        // Recorded only on the way out, and not when the client gave up: a wait
        // that was cancelled is evidence of the opposite.
        defer { patience.sat(through: Double((ContinuousClock.now - clock).components.seconds)) }
        let tools = self
        try await withThrowingTaskGroup(of: JobStatus?.self) { group in
            for id in ids { group.addTask { try await tools.follow(id, progress: progress) } }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            while let next = try await group.next() {
                guard let status = next, await each(status) else { return }
            }
        }
    }

    /// Follows a job until it ends or `seconds` pass; nil when the time is up,
    /// with the job left running.
    func followUntil(_ id: UUID, seconds: Double, progress: MCPProgress) async throws -> JobStatus? {
        var ended: JobStatus?
        try await following([id], seconds: seconds, progress: progress) {
            ended = $0
            return false
        }
        return ended
    }

    /// Follows a job to its end, passing its progress on.
    func follow(_ id: UUID, progress: MCPProgress) async throws -> JobStatus {
        for try await reply in link.replies(to: .wait(id: id)) {
            switch reply {
            case .progress(let status):
                await progress.report(status.fraction ?? 0, Self.stateWords(status))
            case .done(let status):
                return status
            case .unknownJob:
                throw ToolFailure("PaperPress has no job \(id.uuidString) this session.")
            case .error(let message):
                throw ToolFailure(message)
            default:
                continue
            }
        }
        // A cancelled task ends the stream rather than throwing from it.
        try Task.checkCancellation()
        throw ToolFailure("PaperPress closed the connection before the job finished.")
    }

    // MARK: - Reporting

    /// Each job's lines, then which are still going; the same in structured form.
    private func report(
        _ statuses: [JobStatus], seconds: Double?, notes: [String], detail: Bool
    ) -> MCPToolResult {
        var lines = notes
        for status in statuses {
            lines.append("\(status.id.uuidString)  \(status.name): \(Self.stateWords(status))")
            if status.state.isTerminal || status.state == .awaitingApproval {
                let shown = Self.listed(status.files, detail: detail)
                lines += shown.map { "  " + Self.fileLine($0) }
                lines += Self.more(status.files.count - shown.count, indent: "  ")
            }
        }
        let running = statuses.filter { !$0.state.isTerminal }
        if !running.isEmpty, let seconds {
            lines.append(
                "Still running after \(Int(seconds)) s: \(running.map(\.id.uuidString).joined(separator: ", ")). Follow with wait."
            )
        }
        var structured: JSONValue = [
            "jobs": (try? JSONValue.encoding(statuses.map { JobSummary($0, files: true, detail: detail) }))
                ?? []
        ]
        if !notes.isEmpty { structured["notes"] = .array(notes.map(JSONValue.string)) }
        return MCPToolResult(text: [lines.joined(separator: "\n")], structured: structured)
    }

    /// A job's state in a sentence: where it is, or what it came to. Counts
    /// come from the status's totals, which a summary without its file list
    /// still carries.
    static func stateWords(_ status: JobStatus) -> String {
        let totals = status.totals
        switch status.state {
        case .analysing:
            return "analysing\(status.files.isEmpty ? "" : " \(status.files.count) files")."
        case .awaitingApproval:
            return "waiting for the user to approve it in PaperPress (\(status.total) files to write)."
        case .queued:
            return "queued behind other batches."
        case .converting:
            return "converting: \(status.done) of \(status.total) files written."
        case .failed:
            return "failed: \(status.failure ?? "no reason given")."
        case .cancelled:
            return "cancelled after \(status.done) of \(status.total) files; files already written stay."
        case .finished:
            guard status.total > 0 else {
                return
                    "nothing to write: no file was worth re-compressing. Pass copy_unchanged to copy them anyway."
            }
            var words = "\(totals.converted) converted"
            if totals.copied > 0 { words += ", \(totals.copied) copied unchanged" }
            if totals.failed > 0 { words += ", \(totals.failed) failed" }
            words += "; \(byteLabel(totals.inputBytes)) → \(byteLabel(totals.outputBytes))"
            if totals.savedBytes > 0 { words += ", saved \(byteLabel(totals.savedBytes))" }
            return words + ". Written to \(status.request.output.path)."
        }
    }

    static func fileLine(_ file: FileStatus) -> String {
        if let error = file.error { return "\(file.relativePath): unreadable — \(error)" }
        if let error = file.conversionError { return "\(file.relativePath): failed — \(error)" }
        guard file.included else {
            if case .passThrough(let reason) = file.verdict {
                return "\(file.relativePath): not written (\(reason.label.lowercased()))"
            }
            return "\(file.relativePath): not written"
        }
        switch file.outcome {
        case .converted(let pages):
            let size = "\(file.inputBytes.map(byteLabel) ?? "?") → \(file.outputBytes.map(byteLabel) ?? "?")"
            return "\(file.relativePath): converted, \(size) (\(pages.summary))"
        case .copied(.insufficientSaving):
            return "\(file.relativePath): copied unchanged, converting saved too little"
        case .copied(.passThrough):
            return "\(file.relativePath): copied unchanged"
        case nil:
            return "\(file.relativePath): to write"
        }
    }

    static func listed(_ files: [FileStatus], detail: Bool) -> [FileStatus] {
        detail ? files : Array(files.prefix(listedFiles))
    }

    /// The line saying how many files a reply left out, if any.
    static func more(_ hidden: Int, indent: String) -> [String] {
        hidden > 0 ? ["\(indent)…and \(hidden) more; pass detail true to list them."] : []
    }

    // MARK: - Arguments

    private func paths(_ arguments: [String: JSONValue]) throws -> [URL] {
        let raw = arguments["paths"]?.array?.compactMap(\.string) ?? []
        guard !raw.isEmpty else { throw MCPError.invalidParams("paths must name at least one PDF or folder") }
        let urls = raw.map(resolve)
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            throw ToolFailure("Not found: \(missing.map(\.path).joined(separator: ", ")).")
        }
        return urls
    }

    /// A path from a call, made absolute against the client's folder.
    /// Appended rather than resolved `relativeTo:`, which drops the base's last
    /// component when its URL doesn't end in a slash.
    private func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url =
            expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded) : workingDirectory.appendingPathComponent(expanded)
        return url.standardizedFileURL
    }

    private func jobID(_ value: JSONValue?) throws -> UUID {
        guard let raw = value?.string, let id = UUID(uuidString: raw) else {
            throw MCPError.invalidParams("A job id must be as convert returned it.")
        }
        return id
    }

    private func jobIDs(_ value: JSONValue?) throws -> [UUID] {
        let raw = value?.array?.compactMap(\.string) ?? []
        let ids = raw.compactMap(UUID.init(uuidString:))
        guard !ids.isEmpty, ids.count == raw.count else {
            throw MCPError.invalidParams("Job ids must be as convert returned them.")
        }
        return ids
    }

    private func settingsOverrides(_ value: JSONValue?) throws -> SettingsOverrides {
        guard let object = value?.object else { return SettingsOverrides() }
        var overrides = SettingsOverrides()
        overrides.dpiCap = object["dpi_cap"]?.number.map { Int($0) }
        overrides.photoDpiCap = object["photo_dpi_cap"]?.number.map { Int($0) }
        overrides.ocr = object["ocr"]?.bool
        overrides.jpegQuality = object["jpeg_quality"]?.number
        overrides.minSavingPercent = object["min_saving_percent"]?.number.map { Int($0) }
        if let format = object["low_res_text_format"]?.string {
            guard let parsed = Converter.DemotedTextFormat(rawValue: format) else {
                throw MCPError.invalidParams("low_res_text_format is gray4 or jpeg")
            }
            overrides.demotedTextFormat = parsed
        }
        overrides.removeScanEdges = object["remove_scan_edges"]?.bool
        return overrides
    }
}

/// A file as the structured reply gives it.
struct FileSummary: Encodable {
    let path: String
    let relativePath: String
    let verdict: String?
    let pages: Int?
    let inputBytes: Int?
    let estimatedBytes: Int?
    let included: Bool
    let outcome: String?
    let pageEncodings: [String]?
    let outputBytes: Int?
    let error: String?
    let conversionError: String?

    init(_ file: FileStatus) {
        path = file.path
        relativePath = file.relativePath
        switch file.verdict {
        case .convert: verdict = "convert"
        case .passThrough(.bornDigital): verdict = "born_digital"
        case .passThrough(.alreadyProcessed): verdict = "already_processed"
        case .passThrough(.alreadyCompact): verdict = "already_compact"
        case .passThrough(.alreadySmall): verdict = "already_small"
        case nil: verdict = nil
        }
        pages = file.pages
        inputBytes = file.inputBytes
        estimatedBytes = file.estimatedBytes
        included = file.included
        switch file.outcome {
        case .converted(let encodings):
            outcome = "converted"
            pageEncodings = encodings.map {
                switch $0 {
                case .g4: "g4"
                case .gray4: "gray4"
                case .jpeg: "jpeg"
                case .original: "original"
                }
            }
        case .copied(.passThrough):
            outcome = "copied"
            pageEncodings = nil
        case .copied(.insufficientSaving):
            outcome = "copied_insufficient_saving"
            pageEncodings = nil
        case nil:
            outcome = nil
            pageEncodings = nil
        }
        outputBytes = file.outputBytes
        error = file.error
        conversionError = file.conversionError
    }

    enum CodingKeys: String, CodingKey {
        case path, verdict, pages, included, outcome, error
        case relativePath = "relative_path"
        case inputBytes = "input_bytes"
        case estimatedBytes = "estimated_bytes"
        case pageEncodings = "page_encodings"
        case outputBytes = "output_bytes"
        case conversionError = "conversion_error"
    }
}

/// A job as the structured reply gives it.
struct JobSummary: Encodable {
    let id: String
    let name: String
    let state: String
    let failure: String?
    let output: String
    let done: Int
    let total: Int
    let converted: Int
    let copied: Int
    let failed: Int
    let inputBytes: Int
    let outputBytes: Int
    let files: [FileSummary]?

    init(_ status: JobStatus, files: Bool, detail: Bool = false) {
        id = status.id.uuidString
        name = status.name
        state = status.state.rawValue
        failure = status.failure
        output = status.request.output.path
        done = status.done
        total = status.total
        converted = status.totals.converted
        copied = status.totals.copied
        failed = status.totals.failed
        inputBytes = status.totals.inputBytes
        outputBytes = status.totals.outputBytes
        self.files =
            files
            ? PaperPressTools.listed(status.files, detail: detail).map(FileSummary.init) : nil
    }

    enum CodingKeys: String, CodingKey {
        case id, name, state, failure, output, done, total, converted, copied, failed, files
        case inputBytes = "input_bytes"
        case outputBytes = "output_bytes"
    }
}

/// How long this client has shown it will wait for an answer. A helper can't
/// ask a transport what its timeout is; what it can see is what has already
/// worked.
final class Patience: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0

    var longest: Double { lock.withLock { seconds } }

    func sat(through waited: Double) {
        lock.withLock { seconds = max(seconds, waited) }
    }
}
