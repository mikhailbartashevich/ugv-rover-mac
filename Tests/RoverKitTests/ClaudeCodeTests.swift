import Foundation
import Testing
@testable import RoverKit

@Suite("Claude Code CLI output")
struct ClaudeCodeParseTests {
    @Test func readsStructuredOutputFromResultEvent() throws {
        let out = """
        {"type":"system","subtype":"init"}
        {"type":"assistant","message":{"content":[]}}
        {"type":"result","subtype":"success","is_error":false,"result":"…","structured_output":{"target_visible":true,"note":"ok"}}
        """
        let obj = try ClaudeCodeCLI.parse(stdout: Data(out.utf8), stderr: Data(), status: 0)
        #expect(obj["target_visible"] as? Bool == true)
    }

    @Test func fallsBackToJSONInResultText() throws {
        let out = #"{"type":"result","subtype":"success","is_error":false,"result":"{\"note\":\"hi\"}"}"#
        let obj = try ClaudeCodeCLI.parse(stdout: Data(out.utf8), stderr: Data(), status: 0)
        #expect(obj["note"] as? String == "hi")
    }

    @Test func explainsSignInProblems() {
        let out = #"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Please run /login"}"#
        #expect(throws: ClaudeError.self) { try ClaudeCodeCLI.parse(stdout: Data(out.utf8), stderr: Data(), status: 1) }
        #expect(ClaudeCodeCLI.friendly("Please run /login").contains("isn't signed in"))
    }

    @Test func reportsStderrWhenNoResult() {
        #expect(throws: ClaudeError.self) {
            try ClaudeCodeCLI.parse(stdout: Data(), stderr: Data("boom".utf8), status: 2)
        }
    }
}

/// Real call through the locally installed Claude Code (uses your Claude plan).
///   UGV_TEST_CLAUDE_CODE=/path/to/cat.jpg Tools/test.sh --filter ClaudeCodeLive
@Suite("ClaudeCodeLive", .enabled(if: ProcessInfo.processInfo.environment["UGV_TEST_CLAUDE_CODE"] != nil))
@MainActor
struct ClaudeCodeLiveTests {
    @Test func seesTheCat() async throws {
        let path = ProcessInfo.processInfo.environment["UGV_TEST_CLAUDE_CODE"]!
        let jpeg = try Data(contentsOf: URL(fileURLWithPath: path))
        let vision = ClaudeVision(apiKey: { nil })
        vision.backend = .claudeCode
        #expect(vision.isAvailable)
        let a = try await vision.advise(jpeg: jpeg, target: .cat, context: "Rover state: looking.")
        print("Claude Code:", a.note, a.direction, a.box as Any, String(format: "%.1f s", a.latency))
        #expect(a.targetVisible)
        #expect(a.box != nil)
    }
}
