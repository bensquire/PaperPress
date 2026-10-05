import Darwin
import Foundation

/// How the helper and the app reach each other: one Unix socket, and the
/// messages that cross it.
///
/// Prospect needs a Service pasteboard as well, because only that can grant a
/// sandboxed app the files it is handed. PaperPress isn't sandboxed, so a
/// request's paths travel in the request itself.
public enum JobChannel {
    public static let bundleIdentifier = "com.bensquire.paperpress"
    /// Bumped when a command or reply changes shape, so an old helper is told
    /// rather than misunderstood.
    public static let version = 1

    /// The socket, in the user's own Application Support: ~/Library is private
    /// to its user, where a fixed name in /tmp could be taken first by anyone
    /// and answered in the app's place.
    public static var socketPath: String {
        home.appendingPathComponent("Library/Application Support/PaperPress/paperpress.sock").path
    }

    /// From the user database, not $HOME, which a client launching the helper
    /// may have changed.
    static var home: URL {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }

    /// The longest path a `sockaddr_un` holds, terminator included.
    public static let maximumSocketPath = 104
}

/// What the helper asks the app.
public enum JobCommand: Codable, Sendable, Equatable {
    case ping
    /// Queue a batch. Answered with the job as accepted, or refused.
    case submit(JobRequest)
    case status(id: UUID)
    case list
    case cancel(id: UUID)
    /// Answered with the job's status as it changes, then once more when it is
    /// over.
    case wait(id: UUID)
}

/// What the app answers.
public enum JobReply: Codable, Sendable, Equatable {
    case pong(version: Int)
    case job(JobStatus)
    case jobs([JobStatus])
    /// A change to a job being waited on, without its file list.
    case progress(JobStatus)
    /// The last reply to a wait: the job is over.
    case done(JobStatus)
    case unknownJob(UUID)
    case refused(String)
    case error(String)
}

/// One JSON object a line. The default encoder escapes newlines inside strings,
/// so a line break only ever ends a message.
public enum JobLines {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    /// Bytes as they arrive, cut into whole lines.
    public struct Buffer: Sendable {
        private var pending = Data()

        public init() {}

        /// Adds bytes and returns every line they complete, without its newline.
        public mutating func append(_ data: Data) -> [Data] {
            pending.append(data)
            var lines: [Data] = []
            while let end = pending.firstIndex(of: 0x0A) {
                lines.append(pending[pending.startIndex..<end])
                pending.removeSubrange(pending.startIndex...end)
            }
            return lines
        }
    }
}
