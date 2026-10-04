import Foundation
import Network

/// The helper's end of the socket. One connection a command: the commands are
/// few and small, and a wait holds its own connection for as long as the job
/// runs.
public struct JobClient: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Nothing is listening: the app is not running, or assistants are off.
        case unreachable
        case closed

        public var description: String {
            switch self {
            case .unreachable: "PaperPress is not answering."
            case .closed: "PaperPress closed the connection."
            }
        }
    }

    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// The first reply to a command.
    public func send(_ command: JobCommand) async throws -> JobReply {
        for try await reply in replies(to: command) {
            return reply
        }
        throw Failure.closed
    }

    /// Every reply to a command, until the app closes the connection or, for a
    /// wait, the job is done. Cancelling the task that reads it closes the
    /// connection.
    public func replies(to command: JobCommand) -> AsyncThrowingStream<JobReply, Error> {
        let path = path
        return AsyncThrowingStream { continuation in
            let connection = NWConnection(to: .unix(path: path), using: .tcp)
            let queue = DispatchQueue(label: "com.bensquire.paperpress.job-client")

            // The buffer travels with each receive rather than living beside
            // them, so nothing is shared between calls on the connection's queue.
            @Sendable func receive(_ buffer: JobLines.Buffer) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
                    data, _, isComplete, error in
                    var buffer = buffer
                    for line in buffer.append(data ?? Data()) {
                        guard let reply = try? JSONDecoder().decode(JobReply.self, from: line) else {
                            continue
                        }
                        continuation.yield(reply)
                        if case .done = reply { return continuation.finish() }
                        if case .wait = command { continue }
                        return continuation.finish()
                    }
                    if let error { return continuation.finish(throwing: Self.failure(error)) }
                    if isComplete { return continuation.finish(throwing: Failure.closed) }
                    receive(buffer)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let data = try? JobLines.encode(command) else {
                        return continuation.finish(throwing: Failure.closed)
                    }
                    connection.send(content: data, completion: .contentProcessed { _ in })
                    receive(JobLines.Buffer())
                case .waiting(let error), .failed(let error):
                    continuation.finish(throwing: Self.failure(error))
                default:
                    break
                }
            }
            continuation.onTermination = { _ in connection.cancel() }
            connection.start(queue: queue)
        }
    }

    /// A missing socket file and a file nobody listens on both mean the same
    /// thing to the helper: nothing to talk to.
    private static func failure(_ error: NWError) -> Error {
        if case .posix(let code) = error, [.ENOENT, .ECONNREFUSED].contains(code) {
            return Failure.unreachable
        }
        return error
    }
}
