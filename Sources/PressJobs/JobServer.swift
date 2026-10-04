import Foundation
import Network

/// What the app tells the socket about its queue.
@MainActor
public protocol JobHandling: AnyObject {
    /// One job, with its file list.
    func status(of id: UUID) -> JobStatus?
    /// Every job, without file lists.
    func summaries() -> [JobStatus]
    /// Queues a batch, or throws why it can't be taken.
    func submit(_ request: JobRequest) throws -> JobStatus
    func cancelJob(_ id: UUID)
    /// The job's summary now, then each change, finishing once the job is over.
    func updates(for id: UUID) -> AsyncStream<JobStatus>
}

/// The app's end of the socket: a Unix-domain listener that answers
/// `JobCommand`s.
///
/// Network.framework rather than BSD sockets: `NWListener` takes a Unix
/// endpoint as its required local endpoint and hands back connections with
/// framing left to us, which is all this needs.
/// /documentation/network/nwendpoint/unix(path:)
@MainActor
public final class JobServer {
    public enum State: Equatable, Sendable {
        case stopped, listening, failed(String)
    }

    public let path: String
    public private(set) var state: State = .stopped {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((State) -> Void)?

    private weak var handler: JobHandling?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(path: String, handler: JobHandling) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        guard listener == nil else { return }
        guard path.utf8.count < JobChannel.maximumSocketPath else {
            throw POSIXError(.ENAMETOOLONG)
        }
        // Private to this user: whoever can connect can ask for files to be
        // written.
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // A file left by a launch that did not stop cleanly would make the bind fail.
        unlink(path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    /// Closes the socket. Jobs already queued run on; only asking after them stops.
    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
        unlink(path)
        state = .stopped
    }

    private func listenerChanged(_ change: NWListener.State) {
        switch change {
        case .ready:
            chmod(path, 0o600)
            state = .listening
        case .failed(let error):
            state = .failed("\(error)")
            listener?.cancel()
            listener = nil
        case .cancelled where state != .stopped:
            state = .stopped
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] change in
            MainActor.assumeIsolated {
                switch change {
                case .failed, .cancelled: self?.connections[key] = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection, buffer: JobLines.Buffer())
    }

    private func receive(on connection: NWConnection, buffer: JobLines.Buffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                for line in buffer.append(data ?? Data()) {
                    self.answer(line, on: connection)
                }
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func answer(_ line: Data, on connection: NWConnection) {
        guard let command = try? JSONDecoder().decode(JobCommand.self, from: line) else {
            send(.error("PaperPress did not understand that request."), on: connection)
            return
        }
        guard let handler else {
            return send(.error("PaperPress is closing."), on: connection)
        }
        switch command {
        case .ping:
            send(.pong(version: JobChannel.version), on: connection)
        case .submit(let request):
            do {
                send(.job(try handler.submit(request)), on: connection)
            } catch {
                send(.refused(error.localizedDescription), on: connection)
            }
        case .list:
            send(.jobs(handler.summaries()), on: connection)
        case .status(let id):
            send(handler.status(of: id).map(JobReply.job) ?? .unknownJob(id), on: connection)
        case .cancel(let id):
            guard handler.status(of: id) != nil else { return send(.unknownJob(id), on: connection) }
            handler.cancelJob(id)
            send(handler.status(of: id).map(JobReply.job) ?? .unknownJob(id), on: connection)
        case .wait(let id):
            guard handler.status(of: id) != nil else { return send(.unknownJob(id), on: connection) }
            let updates = handler.updates(for: id)
            Task { @MainActor [weak self] in
                var last: JobStatus?
                for await status in updates {
                    last = status
                    guard !status.state.isTerminal else { break }
                    self?.send(.progress(status), on: connection)
                }
                // The updates are summaries; the end goes out with its files.
                if let last { self?.send(.done(handler.status(of: id) ?? last), on: connection) }
            }
        }
    }

    private func send(_ reply: JobReply, on connection: NWConnection) {
        guard let data = try? JobLines.encode(reply) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
