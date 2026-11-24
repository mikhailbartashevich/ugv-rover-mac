import Foundation
import CoreGraphics

/// Claude's read of one camera frame.
public struct ClaudeAdvice: Sendable, Equatable {
    public enum Direction: String, Sendable { case left, center, right, notVisible = "not_visible" }

    public let targetVisible: Bool
    public let direction: Direction
    /// Normalised, top-left origin; Claude's estimate, so rough.
    public let box: CGRect?
    public let obstacleAhead: Bool
    public let safeToDrive: Bool
    public let note: String
    public let date: Date
    public let latency: TimeInterval
}

/// Where Claude runs.
public enum ClaudeBackend: String, CaseIterable, Identifiable, Sendable {
    /// The Claude Code CLI installed on this Mac (`claude -p`), signed in with your Claude account.
    case claudeCode
    /// The Messages API with an Anthropic API key.
    case api
    public var id: String { rawValue }
    public var title: String { self == .claudeCode ? "Claude Code" : "API Key" }
}

/// Asks Claude about a camera frame. Used as a slow supervisor next to the on-device
/// tracker: spotting obstacles and finding the target when the tracker loses it.
/// By default it runs through the locally installed Claude Code, so no API key is needed.
@MainActor
public final class ClaudeVision {
    public var model = "claude-opus-5-5"
    public var backend: ClaudeBackend {
        didSet { UserDefaults.standard.set(backend.rawValue, forKey: "claudeBackend") }
    }
    public let cli = ClaudeCodeCLI()
    private let apiKey: () -> String?
    private let endpoint: URL
    private let session: URLSession

    public init(apiKey: @escaping () -> String?) {
        self.apiKey = apiKey
        backend = UserDefaults.standard.string(forKey: "claudeBackend").flatMap(ClaudeBackend.init) ?? .claudeCode
        let base = ProcessInfo.processInfo.environment["UGV_ANTHROPIC_BASE_URL"] ?? "https://api.anthropic.com"
        endpoint = URL(string: base)!.appendingPathComponent("v1/messages")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        session = URLSession(configuration: cfg)
    }

    public var hasKey: Bool { !(apiKey() ?? "").isEmpty }

    /// Whether the selected backend can be used right now.
    public var isAvailable: Bool {
        switch backend {
        case .claudeCode: cli.executable != nil
        case .api: hasKey
        }
    }

    public func advise(jpeg: Data, target: FollowTarget, context: String) async throws -> ClaudeAdvice {
        let started = Date()
        let obj: [String: Any]
        switch backend {
        case .claudeCode:
            obj = try await cli.structuredAnswer(system: Self.systemPrompt(target), jpeg: jpeg, text: context,
                                                 schema: Self.schema, model: model)
        case .api:
            obj = try await askAPI(jpeg: jpeg, target: target, context: context)
        }
        return Self.parse(obj, latency: Date().timeIntervalSince(started))
    }

    // MARK: - Messages API (raw HTTP: there's no official Swift SDK)

    private func askAPI(jpeg: Data, target: FollowTarget, context: String) async throws -> [String: Any] {
        guard let key = apiKey(), !key.isEmpty else { throw ClaudeError("No Anthropic API key set.") }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 4000,
            "fallbacks": "default",
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": Self.schema],
            ],
            "system": Self.systemPrompt(target),
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": context],
                ],
            ]],
        ] as [String: Any])

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            switch status {
            case 401: throw ClaudeError("The API key was rejected.")
            case 429: throw ClaudeError("Rate limited — asking less often would help.")
            case 529: throw ClaudeError("Claude is overloaded right now.")
            default: throw ClaudeError(msg)
            }
        }
        if json["stop_reason"] as? String == "refusal" { throw ClaudeError("Claude declined this frame.") }
        let content = json["content"] as? [[String: Any]] ?? []
        guard let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ClaudeError("Unexpected reply from Claude.")
        }
        return obj
    }

    // MARK: - Prompt

    nonisolated static func systemPrompt(_ target: FollowTarget) -> String {
        """
        You are the eyes of a small wheeled ground rover (camera about 20 cm above the floor) that is slowly \
        following a \(target.rawValue) around a home. You receive one frame from its forward-facing camera.
        Report whether the \(target.rawValue) is visible and where: which third of the frame its centre is in, \
        and its bounding box as fractions of the frame (x, y = top-left corner; width, height), or null if not visible.
        Report whether something blocks driving straight ahead within about half a metre — furniture legs, walls, \
        doors, cables, steps or stairs, toys. The \(target.rawValue) itself is not an obstacle.
        safe_to_drive is false if moving forward slowly could hit something, fall down a step, or get stuck.
        Keep note under 15 words, plain English.
        """
    }

    nonisolated(unsafe) static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["target_visible", "target_direction", "target_box", "obstacle_ahead", "safe_to_drive", "note"],
        "properties": [
            "target_visible": ["type": "boolean"],
            "target_direction": ["type": "string", "enum": ["left", "center", "right", "not_visible"]],
            "target_box": ["anyOf": [
                ["type": "null"],
                [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["x", "y", "width", "height"],
                    "properties": [
                        "x": ["type": "number"], "y": ["type": "number"],
                        "width": ["type": "number"], "height": ["type": "number"],
                    ],
                ],
            ]],
            "obstacle_ahead": ["type": "boolean"],
            "safe_to_drive": ["type": "boolean"],
            "note": ["type": "string"],
        ],
    ]

    nonisolated static func parse(_ o: [String: Any], latency: TimeInterval) -> ClaudeAdvice {
        var box: CGRect?
        if let b = o["target_box"] as? [String: Any],
           let x = (b["x"] as? NSNumber)?.doubleValue, let y = (b["y"] as? NSNumber)?.doubleValue,
           let w = (b["width"] as? NSNumber)?.doubleValue, let h = (b["height"] as? NSNumber)?.doubleValue,
           w > 0, h > 0 {
            box = CGRect(x: x, y: y, width: w, height: h).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return ClaudeAdvice(
            targetVisible: o["target_visible"] as? Bool ?? false,
            direction: ClaudeAdvice.Direction(rawValue: o["target_direction"] as? String ?? "") ?? .notVisible,
            box: box,
            obstacleAhead: o["obstacle_ahead"] as? Bool ?? false,
            safeToDrive: o["safe_to_drive"] as? Bool ?? true,
            note: o["note"] as? String ?? "",
            date: Date(),
            latency: latency
        )
    }
}

public struct ClaudeError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
