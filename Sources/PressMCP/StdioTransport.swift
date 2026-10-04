import Foundation

/// The stdio transport: a message a line on standard input, a message a line on
/// standard output, and nothing else on standard output. Logs go to standard error.
/// When the client closes standard input the server finishes what it was asked, then
/// exits. A call still running then finishes; its answer has nowhere to go, so a
/// closed standard output is ignored rather than allowed to end the process
/// part-way. (A conversion runs in the app's queue and doesn't depend on this
/// process at all.)
/// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio
public enum StdioTransport {
    public static func run(_ makeServer: (@escaping @Sendable (String) async -> Void) -> MCPServer)
        async
    {
        signal(SIGPIPE, SIG_IGN)
        let writer = LineWriter()
        let server = makeServer { line in await writer.write(line) }
        do {
            for try await line in FileHandle.standardInput.bytes.lines where !line.isEmpty {
                await server.receive(line)
            }
        } catch {
            log("paperpress-mcp: reading standard input failed: \(error)")
        }
        await server.drain()
    }

    public static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Writes whole lines, one at a time, so a progress notification never lands in the
/// middle of a response.
actor LineWriter {
    func write(_ line: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }
}
