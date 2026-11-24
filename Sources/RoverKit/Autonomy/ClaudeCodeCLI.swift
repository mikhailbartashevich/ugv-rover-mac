import Foundation

/// Runs the locally installed Claude Code CLI in headless mode (`claude -p`) to ask one
/// question about an image and get JSON back. Uses whatever account Claude Code is
/// signed in with, so no API key is needed.
///
/// The image goes in as a content block over `--input-format stream-json` (no temp
/// files), the answer is constrained by `--json-schema`, and all tools, MCP servers and
/// session saving are off so the call is quick and can't touch anything.
public final class ClaudeCodeCLI: @unchecked Sendable {
    /// Where `claude` was found, or nil. GUI apps don't get the shell's PATH, so the
    /// usual install locations are checked directly.
    public let executable: URL?

    public init() {
        executable = Self.locate()
    }

    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            ProcessInfo.processInfo.environment["UGV_CLAUDE_PATH"],
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ].compactMap { $0 }
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        return candidates.lazy
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
            .first
    }

    /// Path for display, with ~ for the home folder.
    public var displayPath: String? {
        executable.map { $0.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
    }

    public func structuredAnswer(system: String, jpeg: Data, text: String,
                                 schema: [String: Any], model: String,
                                 timeout: TimeInterval = 60) async throws -> [String: Any] {
        guard let exe = executable else {
            throw ClaudeError("Claude Code isn't installed on this Mac.")
        }
        let schemaJSON = String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)
        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": text],
                ],
            ],
        ]
        var input = try JSONSerialization.data(withJSONObject: message)
        input.append(0x0A)

        let args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json", "--verbose",
            "--json-schema", schemaJSON,
            "--system-prompt", system,
            "--model", model,
            "--effort", "low",
            "--tools", "",
            "--strict-mcp-config",
            "--no-session-persistence",
        ]
        let (out, err, status) = try await Self.run(exe, args: args, input: input, timeout: timeout)
        return try Self.parse(stdout: out, stderr: err, status: status)
    }

    /// Finds the final `result` event and returns its structured output.
    static func parse(stdout: Data, stderr: Data, status: Int32) throws -> [String: Any] {
        let lines = String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
        let result = lines.reversed().lazy
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .first { $0["type"] as? String == "result" }

        guard let result else {
            let msg = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClaudeError(friendly(msg.isEmpty ? "Claude Code exited with status \(status)." : msg))
        }
        if result["is_error"] as? Bool == true || result["subtype"] as? String != "success" {
            let msg = result["result"] as? String ?? (result["subtype"] as? String ?? "error")
            throw ClaudeError(friendly(msg))
        }
        if let obj = result["structured_output"] as? [String: Any] { return obj }
        if let text = result["result"] as? String,
           let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return obj
        }
        throw ClaudeError("Claude Code didn't return the expected JSON.")
    }

    static func friendly(_ msg: String) -> String {
        let lower = msg.lowercased()
        if lower.contains("log in") || lower.contains("login") || lower.contains("not logged") || lower.contains("authenticat") {
            return "Claude Code isn't signed in. Open Terminal, run `claude` once and sign in."
        }
        if lower.contains("usage limit") || lower.contains("rate limit") {
            return "Claude usage limit reached — try again later or ask less often."
        }
        return String(msg.prefix(200))
    }

    /// Runs a process off the main thread, feeding stdin, with a timeout.
    static func run(_ exe: URL, args: [String], input: Data, timeout: TimeInterval) async throws -> (Data, Data, Int32) {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            // Run outside any project so no project settings or CLAUDE.md are picked up.
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            for k in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { env[k] = nil }
            p.environment = env
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            p.standardInput = stdin
            p.standardOutput = stdout
            p.standardError = stderr

            let outBuf = LockedData(), errBuf = LockedData()
            stdout.fileHandleForReading.readabilityHandler = { outBuf.append($0.availableData) }
            stderr.fileHandleForReading.readabilityHandler = { errBuf.append($0.availableData) }

            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            p.terminationHandler = { proc in
                timer.cancel()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                outBuf.append(stdout.fileHandleForReading.readDataToEndOfFile())
                errBuf.append(stderr.fileHandleForReading.readDataToEndOfFile())
                if proc.terminationReason == .uncaughtSignal {
                    cont.resume(throwing: ClaudeError("Claude Code took longer than \(Int(timeout)) s."))
                } else {
                    cont.resume(returning: (outBuf.data, errBuf.data, proc.terminationStatus))
                }
            }
            do {
                try p.run()
            } catch {
                cont.resume(throwing: ClaudeError("Couldn't start Claude Code: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
    }
}

/// Thread-safe byte buffer for pipe readers.
private final class LockedData: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}
