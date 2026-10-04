import Foundation

/// The tools a server offers, apart from the protocol that carries them.
public protocol MCPTools: Sendable {
    /// Each tool's definition: name, title, description, input schema.
    var definitions: [JSONValue] { get }
    func call(_ name: String, arguments: [String: JSONValue], progress: MCPProgress) async throws
        -> MCPToolResult
    /// Finishes work the tools carry on after their calls have been answered.
    func drain() async
}

extension MCPTools {
    public func drain() async {}
}

public struct MCPToolResult: Sendable, Equatable {
    public struct Image: Sendable, Equatable {
        public var data: Data
        public var mimeType: String

        public init(data: Data, mimeType: String) {
            self.data = data
            self.mimeType = mimeType
        }
    }

    /// Text and pictures in the order they are read. An order, not two lists: a result
    /// about several jobs puts each job's picture after its own lines, where two lists
    /// sent every picture after all the text, unlabelled — with two dry runs in one call
    /// an assistant could only guess which was which.
    public enum Block: Sendable, Equatable {
        case text(String)
        case image(Image)
    }

    public var blocks: [Block]
    public var structured: JSONValue?
    public var isError: Bool

    public init(text: [String], images: [Image] = [], structured: JSONValue? = nil, isError: Bool = false) {
        self.init(
            blocks: text.map(Block.text) + images.map(Block.image), structured: structured, isError: isError)
    }

    public init(blocks: [Block], structured: JSONValue? = nil, isError: Bool = false) {
        self.blocks = blocks
        self.structured = structured
        self.isError = isError
    }

    public var text: [String] {
        blocks.compactMap { if case .text(let text) = $0 { return text } else { return nil } }
    }

    public var images: [Image] {
        blocks.compactMap { if case .image(let image) = $0 { return image } else { return nil } }
    }

}

/// Reports a call's progress, when the client asked for it with a progress token.
/// Keeps the rule the spec makes: each value larger than the last.
public struct MCPProgress: Sendable {
    private let state: State?

    actor State {
        let token: JSONValue
        let output: @Sendable (String) async -> Void
        var last = -1.0
        var lastMessage: String?

        init(token: JSONValue, output: @escaping @Sendable (String) async -> Void) {
            self.token = token
            self.output = output
        }

        /// A thousandth, which is what a message with nothing new to count is worth:
        /// enough to rise, as the spec requires, and too little to overtake the next
        /// real figure.
        static let nudge = 0.001

        func report(_ fraction: Double, _ message: String?) async {
            // Rising, as the spec requires, and by a percent or with something new to
            // say: each note is a line the client parses. A phase that cannot count
            // itself keeps one fraction for minutes while its words change, and the
            // rule as written let none of it through (found in Prospect, whose solve
            // reported loading and then nothing at all).
            guard message != lastMessage || fraction >= last + 0.01 else { return }
            let fraction = max(fraction, message != lastMessage ? last + Self.nudge : fraction)
            guard fraction > last else { return }
            last = fraction
            lastMessage = message
            var params: [String: JSONValue] = [
                "progressToken": token, "progress": .number(fraction), "total": 1,
            ]
            if let message { params["message"] = .string(message) }
            let notification: JSONValue = [
                "jsonrpc": "2.0", "method": "notifications/progress", "params": .object(params),
            ]
            await output(notification.line())
        }
    }

    init(token: JSONValue?, output: @escaping @Sendable (String) async -> Void) {
        state = token.map { State(token: $0, output: output) }
    }

    public static let none = MCPProgress(token: nil, output: { _ in })

    /// `fraction` from 0 to 1.
    public func report(_ fraction: Double, _ message: String? = nil) async {
        await state?.report(fraction, message)
    }
}

/// A protocol error the tools may throw: a request the model could not have meant.
public enum MCPError: Error, Equatable {
    case invalidParams(String)
}

/// A Model Context Protocol server, one JSON-RPC message a line in and out.
///
/// Dual-era, as the 2026-07-28 revision allows: a request carrying
/// `io.modelcontextprotocol/protocolVersion` in its `_meta` is served statelessly under
/// that revision, and `initialize` selects the handshake of 2025-11-25 and before,
/// which is what Claude Code 2.1 opens a stdio server with. Written by hand to the
/// specification rather than taken from a package: the protocol is a handful of JSON
/// shapes, and the app takes no dependencies.
/// https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning
public actor MCPServer {
    public struct Info: Sendable {
        public var name: String
        public var version: String
        public var instructions: String

        public init(name: String, version: String, instructions: String) {
            self.name = name
            self.version = version
            self.instructions = instructions
        }
    }

    public static let modernVersions = ["2026-07-28"]
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    private let tools: MCPTools
    /// The tools' names, taken once: a call to any other is a protocol error.
    private let toolNames: Set<String>
    private let info: Info
    private let output: @Sendable (String) async -> Void
    /// Requests being answered, by id, so a cancellation can reach one.
    private var inFlight: [JSONValue: Task<Void, Never>] = [:]

    public init(tools: MCPTools, info: Info, output: @escaping @Sendable (String) async -> Void) {
        self.tools = tools
        toolNames = Set(tools.definitions.compactMap { $0["name"]?.string })
        self.info = info
        self.output = output
    }

    /// Takes one line from the client. A request is answered in a task of its own, so
    /// a long call does not hold up a ping behind it.
    public func receive(_ line: String) async {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            return await output(Self.error(id: .null, code: -32700, message: "Parse error"))
        }
        guard message["jsonrpc"]?.string == "2.0", let method = message["method"]?.string else {
            return await output(
                Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid Request"))
        }
        let params = message["params"]?.object ?? [:]
        guard let id = message["id"] else {
            return notice(method, params: params)
        }
        let task = Task {
            let response = await self.respond(to: method, params: params, id: id)
            // A cancelled request is not answered: the client has stopped listening.
            if !Task.isCancelled { await self.output(response) }
            self.finished(id)
        }
        // Before the task can run: it is isolated to this actor, which is busy until
        // this returns, so the entry is always there for it to remove.
        inFlight[id] = task
    }

    /// Waits for every request in flight to be answered.
    public func drain() async {
        while let task = inFlight.values.first {
            await task.value
        }
        await tools.drain()
    }

    private func finished(_ id: JSONValue) {
        inFlight[id] = nil
    }

    private func notice(_ method: String, params: [String: JSONValue]) {
        if method == "notifications/cancelled", let id = params["requestId"] {
            inFlight[id]?.cancel()
        }
    }

    private func respond(to method: String, params: [String: JSONValue], id: JSONValue) async -> String {
        let meta = params["_meta"]?.object ?? [:]
        if method == "initialize" {
            return Self.result(id: id, initializeResult(requested: params["protocolVersion"]?.string))
        }
        // Modern: the version on the request itself.
        let modern = meta[Self.versionKey]?.string
        if let modern {
            guard Self.modernVersions.contains(modern) else {
                return Self.error(
                    id: id, code: -32022, message: "Unsupported protocol version",
                    data: [
                        "supported": .array(
                            (Self.modernVersions + Self.legacyVersions).map(JSONValue.string)),
                        "requested": .string(modern),
                    ])
            }
            guard meta[Self.capabilitiesKey]?.object != nil else {
                return Self.error(
                    id: id, code: -32602, message: "Missing \(Self.capabilitiesKey) in _meta")
            }
        }

        var result: [String: JSONValue]
        switch method {
        case "server/discover":
            guard modern != nil else {
                return Self.error(id: id, code: -32602, message: "Missing \(Self.versionKey) in _meta")
            }
            result = [
                "supportedVersions": .array(Self.modernVersions.map(JSONValue.string)),
                "capabilities": ["tools": [:]],
                "instructions": .string(info.instructions),
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": .array(tools.definitions)]
        case "tools/call":
            guard let name = params["name"]?.string, toolNames.contains(name) else {
                return Self.error(
                    id: id, code: -32602, message: "Unknown tool: \(params["name"]?.string ?? "none")")
            }
            let progress = MCPProgress(token: meta["progressToken"], output: output)
            let called: MCPToolResult
            do {
                called = try await tools.call(
                    name, arguments: params["arguments"]?.object ?? [:], progress: progress)
            } catch MCPError.invalidParams(let message) {
                return Self.error(id: id, code: -32602, message: message)
            } catch {
                called = MCPToolResult(text: ["\(error)"], isError: true)
            }
            var content: [JSONValue] = called.blocks.map { block in
                switch block {
                case .text(let text):
                    return ["type": "text", "text": .string(text)]
                case .image(let image):
                    return [
                        "type": "image", "data": .string(image.data.base64EncodedString()),
                        "mimeType": .string(image.mimeType),
                    ]
                }
            }
            // The structured content as text too, for clients that read only text, as the
            // specification asks of every tool that returns it.
            if let structured = called.structured {
                content.append(["type": "text", "text": .string(structured.line())])
                result = [
                    "content": .array(content), "isError": .bool(called.isError),
                    "structuredContent": structured,
                ]
            } else {
                result = ["content": .array(content), "isError": .bool(called.isError)]
            }
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
        if modern != nil {
            result["resultType"] = "complete"
            result["_meta"] = [Self.serverInfoKey: serverInfo]
        }
        return Self.result(id: id, .object(result))
    }

    private var serverInfo: JSONValue {
        ["name": .string(info.name), "version": .string(info.version)]
    }

    /// The legacy handshake: the client's version when it is one this server speaks,
    /// otherwise the latest it does, which the client may accept or disconnect over.
    private func initializeResult(requested: String?) -> JSONValue {
        let version =
            requested.flatMap { Self.legacyVersions.contains($0) ? $0 : nil } ?? Self.legacyVersions[0]
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": serverInfo,
            "instructions": .string(info.instructions),
        ]
    }

    static func result(id: JSONValue, _ result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).line()
    }

    static func error(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> String {
        var error: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { error["data"] = data }
        return JSONValue.object(["jsonrpc": "2.0", "id": id, "error": .object(error)]).line()
    }
}
