import AppKit
import Foundation
import PressJobs

/// Whether an assistant — Claude, or any other client of the helper — may
/// reach the queue: the setting, the socket it opens, and the lines that tell
/// a client where the helper is.
///
/// Off on a fresh install. Turning it on opens the socket; off closes it, and
/// jobs already queued run on. analyse and preview work without it: they run
/// in the helper and only read files.
@MainActor
public final class Automation: ObservableObject {
    @Published public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            apply()
        }
    }
    /// The socket's own state, followed so Settings can show it.
    @Published public private(set) var state: JobServer.State = .stopped

    public let socketPath: String
    /// The helper a client launches: beside the app's own executable, in
    /// Contents/MacOS for the app and in the build folder for `swift run`.
    public let helperURL: URL
    weak var handler: JobHandling?

    private let defaults: UserDefaults
    private var server: JobServer?

    static let enabledKey = "assistantsEnabled"

    public init(defaults: UserDefaults = .standard, socketPath: String = JobChannel.socketPath) {
        self.defaults = defaults
        self.socketPath = socketPath
        helperURL = (Bundle.main.executableURL ?? Bundle.main.bundleURL)
            .deletingLastPathComponent().appendingPathComponent("paperpress-mcp")
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// Opens or closes the socket to match the setting.
    public func apply() {
        guard isEnabled, let handler else {
            server?.stop()
            server = nil
            state = .stopped
            return
        }
        guard server == nil else { return }
        let server = JobServer(path: socketPath, handler: handler)
        server.onStateChange = { [weak self] change in self?.state = change }
        do {
            try server.start()
            self.server = server
        } catch {
            state = .failed("\(error)")
        }
    }

    /// Closes the socket as the app quits, leaving the setting as it is.
    public func shutdown() {
        server?.stop()
        server = nil
    }

    /// For Claude Code's terminal: for every project, where `claude mcp add` on
    /// its own adds a server to the current one only. Quoted when the path has a
    /// space, as an app moved into a folder with one would.
    public var claudeCodeCommand: String {
        let path = helperURL.path
        let quoted = path.contains(" ") ? "'\(path)'" : path
        return "claude mcp add --scope user paperpress -- \(quoted)"
    }

    /// For Claude Desktop's configuration file, and the many clients that use
    /// the same shape.
    public var claudeDesktopConfiguration: String {
        let configuration = ["mcpServers": ["paperpress": ["command": helperURL.path]]]
        let data =
            (try? JSONSerialization.data(
                withJSONObject: configuration,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
