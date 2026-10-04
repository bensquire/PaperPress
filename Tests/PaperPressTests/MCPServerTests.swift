import XCTest

@testable import PressMCP

/// The protocol, line in and lines out, with tools that answer at once.
/// Ported from Prospect's tests of the same server.
final class MCPServerTests: XCTestCase {
    /// Tools that echo, report progress, report words, or return a picture.
    struct FakeTools: MCPTools {
        var definitions: [JSONValue] {
            [
                ["name": "echo", "description": "Echoes", "inputSchema": ["type": "object"]],
                ["name": "slow", "description": "Reports progress", "inputSchema": ["type": "object"]],
                ["name": "picture", "description": "Returns a picture", "inputSchema": ["type": "object"]],
                ["name": "talking", "description": "Reports words", "inputSchema": ["type": "object"]],
            ]
        }

        func call(_ name: String, arguments: [String: JSONValue], progress: MCPProgress) async throws
            -> MCPToolResult
        {
            switch name {
            case "picture":
                return MCPToolResult(
                    text: ["here"], images: [.init(data: Data([1, 2, 3]), mimeType: "image/png")])
            case "talking":
                for message in ["Converting 1 of 3", "Converting 2 of 3", "Converting 3 of 3"] {
                    await progress.report(0.4, message)
                }
                return MCPToolResult(text: ["done"])
            case "slow":
                for fraction in [0.2, 0.2, 0.1, 0.6, 1.0] { await progress.report(fraction, "step") }
                return MCPToolResult(text: ["done"])
            default:
                return MCPToolResult(
                    text: [arguments["say"]?.string ?? ""], structured: ["said": arguments["say"] ?? .null])
            }
        }
    }

    actor Lines {
        var lines: [JSONValue] = []
        func append(_ line: String) {
            lines.append(try! JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))
        }
    }

    static let modernMeta: JSONValue = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": [:],
    ]

    /// Sends lines to a fresh server and returns what it wrote once every
    /// request is answered.
    static func exchange(_ messages: [String]) async -> [JSONValue] {
        let lines = Lines()
        let server = MCPServer(
            tools: FakeTools(),
            info: .init(name: "paperpress", version: "1", instructions: "Compresses."),
            output: { await lines.append($0) })
        for message in messages { await server.receive(message) }
        await server.drain()
        return await lines.lines
    }

    static func request(_ id: Int, _ method: String, _ params: JSONValue = [:]) -> String {
        JSONValue.object([
            "jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params,
        ])
        .line()
    }

    private static func fractions(_ replies: [JSONValue]) -> [Double] {
        replies.filter { $0["method"] == "notifications/progress" }.compactMap {
            $0["params"]?["progress"]?.number
        }
    }

    func test_initialize_answersInTheClientsLegacyVersion() async {
        for version in ["2025-06-18", "2025-11-25", "2025-03-26"] {
            // Arrange / Act
            let replies = await Self.exchange([
                Self.request(1, "initialize", ["protocolVersion": .string(version), "capabilities": [:]])
            ])

            // Assert
            XCTAssertEqual(
                replies.first?["result"]?["protocolVersion"]?.string, version, "replied \(replies)")
            XCTAssertEqual(replies.first?["result"]?["serverInfo"]?["name"], "paperpress")
        }
    }

    func test_initialize_withAnUnknownVersion_offersTheLatestLegacyOne() async {
        // Arrange / Act
        let replies = await Self.exchange([
            Self.request(1, "initialize", ["protocolVersion": "2024-01-01", "capabilities": [:]])
        ])

        // Assert
        XCTAssertEqual(
            replies.first?["result"]?["protocolVersion"], "2025-11-25", "replied \(replies)")
    }

    func test_discover_listsTheModernVersionAndMarksTheResultComplete() async {
        // Arrange / Act
        let replies = await Self.exchange([
            Self.request(1, "server/discover", ["_meta": Self.modernMeta])
        ])

        // Assert
        let result = replies.first?["result"]
        XCTAssertEqual(result?["supportedVersions"], ["2026-07-28"], "replied \(replies)")
        XCTAssertEqual(result?["resultType"], "complete")
    }

    func test_anUnsupportedModernVersion_isRefusedWithTheSupportedOnes() async {
        // Arrange / Act
        let replies = await Self.exchange([
            Self.request(
                1, "tools/list",
                [
                    "_meta": [
                        "io.modelcontextprotocol/protocolVersion": "1900-01-01",
                        "io.modelcontextprotocol/clientCapabilities": [:],
                    ]
                ])
        ])

        // Assert
        XCTAssertEqual(replies.first?["error"]?["code"], -32022, "replied \(replies)")
    }

    func test_toolsList_namesEveryTool() async {
        // Arrange / Act
        let replies = await Self.exchange([Self.request(1, "tools/list")])

        // Assert
        let names = replies.first?["result"]?["tools"]?.array?.compactMap { $0["name"]?.string }
        XCTAssertEqual(names, ["echo", "slow", "picture", "talking"], "replied \(replies)")
    }

    func test_call_answersWithTextAndStructuredContent() async {
        // Arrange / Act
        let replies = await Self.exchange([
            Self.request(1, "tools/call", ["name": "echo", "arguments": ["say": "hello"]])
        ])

        // Assert
        let result = replies.first?["result"]
        XCTAssertEqual(result?["content"]?.array?.first?["text"], "hello", "replied \(replies)")
        XCTAssertEqual(result?["structuredContent"]?["said"], "hello")
        XCTAssertEqual(result?["isError"], false)
    }

    func test_unknownTool_isInvalidParams() async {
        // Arrange / Act
        let replies = await Self.exchange([Self.request(1, "tools/call", ["name": "nope"])])

        // Assert
        XCTAssertEqual(replies.first?["error"]?["code"], -32602, "replied \(replies)")
    }

    func test_unknownMethod_isNotFound() async {
        // Arrange / Act
        let replies = await Self.exchange([Self.request(1, "resources/list")])

        // Assert
        XCTAssertEqual(replies.first?["error"]?["code"], -32601, "replied \(replies)")
    }

    func test_unparseableInput_isAParseErrorWithNoID() async {
        // Arrange / Act
        let replies = await Self.exchange(["{not json"])

        // Assert
        XCTAssertEqual(replies.first?["error"]?["code"], -32700, "replied \(replies)")
        XCTAssertEqual(replies.first?["id"], .null)
    }

    func test_notifications_areNotAnswered() async {
        // Arrange / Act
        let replies = await Self.exchange([
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}"#,
        ])

        // Assert
        XCTAssertTrue(replies.isEmpty, "replied \(replies)")
    }

    func test_progress_goesOutRisingAndBeforeTheResult() async {
        // Arrange / Act — the tool reports 0.2, 0.2, 0.1, 0.6, 1.0
        let replies = await Self.exchange([
            Self.request(1, "tools/call", ["name": "slow", "_meta": ["progressToken": "t"]])
        ])

        // Assert — only the rises go out, and all before the result
        XCTAssertEqual(Self.fractions(replies), [0.2, 0.6, 1.0])
        XCTAssertEqual(replies.last?["id"], 1, "the result was not last: \(replies)")
    }

    func test_progress_thatCannotCount_stillReportsItsWords() async {
        // Arrange / Act — one fraction, three messages
        let replies = await Self.exchange([
            Self.request(1, "tools/call", ["name": "talking", "_meta": ["progressToken": "t"]])
        ])

        // Assert — every message, still rising, without running away
        let fractions = Self.fractions(replies)
        XCTAssertEqual(fractions.count, 3, "sent \(replies)")
        XCTAssertTrue(zip(fractions, fractions.dropFirst()).allSatisfy { $0 < $1 }, "went \(fractions)")
        XCTAssertLessThan(fractions.last ?? 1, 0.41, "the nudges ran away with the bar")
    }

    func test_noProgressToken_meansNoProgress() async {
        // Arrange / Act
        let replies = await Self.exchange([Self.request(1, "tools/call", ["name": "slow"])])

        // Assert
        XCTAssertEqual(replies.count, 1, "replied \(replies)")
    }

    func test_aPicture_goesOutAsAnImageBlock() async {
        // Arrange / Act
        let replies = await Self.exchange([Self.request(1, "tools/call", ["name": "picture"])])

        // Assert
        let image = replies.first?["result"]?["content"]?.array?.first { $0["type"] == "image" }
        XCTAssertEqual(image?["data"], "AQID", "replied \(replies)")
        XCTAssertEqual(image?["mimeType"], "image/png")
    }
}
