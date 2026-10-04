import AppKit
import PressJobs
import PressMCP

/// Finds and launches PaperPress through AppKit: the edge of the helper, kept out
/// of `PressMCP` so the tools are tested without it.
struct WorkspaceLauncher: PaperPressLauncher {
    /// The app this helper ships inside, when it does; a development build of the
    /// helper finds whichever copy Launch Services knows.
    let appURL: URL?

    let helper: AppCopy

    var runningApp: AppCopy? {
        get async {
            await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: JobChannel.bundleIdentifier)
                    .first?.bundleURL.map(Self.copy(of:))
            }
        }
    }

    /// A copy of the app: its path, its marketing version, and when its
    /// executable was built.
    static func copy(of bundleURL: URL) -> AppCopy {
        let bundle = Bundle(url: bundleURL)
        return AppCopy(
            path: bundleURL.path,
            version: bundle?.infoDictionary?["CFBundleShortVersionString"] as? String,
            built: bundle?.executableURL.flatMap(Self.modified(_:)))
    }

    static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    var isRunning: Bool {
        get async { await runningApp != nil }
    }

    func launch() async throws {
        guard
            let url = appURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: JobChannel.bundleIdentifier)
        else {
            throw PaperPressTools.ToolFailure("PaperPress is not installed where this Mac can find it.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Opened behind whatever the person is working in: they asked their
        // assistant, not PaperPress.
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

let bundle = Bundle.main.bundleURL
let link = JobClient(path: JobChannel.socketPath)
let launcher = WorkspaceLauncher(
    appURL: bundle.pathExtension == "app" ? bundle : nil,
    // Read now, at start: the file may be replaced while this process runs on.
    helper: AppCopy(
        path: Bundle.main.executablePath ?? CommandLine.arguments[0],
        version: WorkspaceLauncher.copy(of: bundle).version,
        built: Bundle.main.executableURL.flatMap(WorkspaceLauncher.modified(_:))))
let mismatch = await alignWithRunningPaperPress(link, launcher)
let tools = PaperPressTools(
    link: link, launcher: launcher,
    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))

/// Settles the version question before a client asks anything, as Prospect's
/// helper does. A client starts this helper once and keeps it while PaperPress
/// is updated underneath, so the two can come to speak different protocols.
/// Where the running PaperPress carries a newer helper, become that helper —
/// once only, which the environment remembers, so two copies can't replace each
/// other in turn.
func alignWithRunningPaperPress(_ link: JobClient, _ launcher: WorkspaceLauncher) async -> String? {
    guard case .pong(let version)? = try? await link.send(.ping), version != JobChannel.version else {
        return nil
    }
    let app = await launcher.runningApp
    let replaced = ProcessInfo.processInfo.environment["PAPERPRESS_MCP_REPLACED"] != nil
    // Only toward the newer of the two: a helper ahead of the running app would
    // otherwise replace itself with the older one inside it.
    if !replaced, version > JobChannel.version, let path = app?.path {
        let fresh = URL(fileURLWithPath: path).appendingPathComponent("Contents/MacOS/paperpress-mcp")
        let here = URL(fileURLWithPath: launcher.helper.path).standardizedFileURL
        if FileManager.default.isExecutableFile(atPath: fresh.path),
            fresh.standardizedFileURL != here
                || WorkspaceLauncher.modified(fresh) != launcher.helper.built
        {
            StdioTransport.log(
                "paperpress-mcp: the running PaperPress speaks protocol \(version); replacing this helper with \(fresh.path)."
            )
            setenv("PAPERPRESS_MCP_REPLACED", "1", 1)
            // Replaces this process, standard input and output and all, so the
            // client never notices anything but a helper that agrees with the app.
            let arguments = [fresh.path] + CommandLine.arguments.dropFirst()
            var pointers = arguments.map { strdup($0) }
            pointers.append(nil)
            execv(fresh.path, &pointers)
            StdioTransport.log(
                "paperpress-mcp: could not start \(fresh.path): \(String(cString: strerror(errno)))")
        }
    }
    return PaperPressTools.versionMismatch(
        helperProtocol: JobChannel.version, appProtocol: version, helper: launcher.helper, app: app)
}

let info = MCPServer.Info(
    name: "paperpress",
    version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
    instructions: mismatch.map { $0 + "\n\n" + PaperPressTools.instructions }
        ?? PaperPressTools.instructions)

await StdioTransport.run { output in MCPServer(tools: tools, info: info, output: output) }
exit(0)
