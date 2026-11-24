import Foundation

/// A JSON command for the ESP32 sub-controller (`{"T": type, …}`).
public struct ESP32Command: Sendable, Equatable {
    public let type: Int
    public let fields: [(String, Value)]

    public enum Value: Sendable, Equatable {
        case int(Int)
        case double(Double)
        case string(String)
    }

    public init(_ type: Int, _ fields: [(String, Value)] = []) {
        self.type = type
        self.fields = fields
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.json == b.json
    }

    /// A wheel command that actually moves (T:1 / T:11 / T:13 with a non-zero value).
    public var isMotion: Bool {
        guard [1, 11, 13].contains(type) else { return false }
        return fields.contains { _, v in
            switch v {
            case .int(let i): i != 0
            case .double(let d): abs(d) > 0.001
            case .string: false
            }
        }
    }

    /// Compact JSON with "T" first and short decimals.
    public var json: String {
        let parts = [("T", Value.int(type))] + fields
        return "{" + parts.map { "\"\($0.0)\":\(Self.encode($0.1))" }.joined(separator: ",") + "}"
    }

    private static func encode(_ v: Value) -> String {
        switch v {
        case .int(let i): return String(i)
        case .double(let d):
            if d == d.rounded() { return String(Int(d)) }
            return String(format: "%.2f", d)
        case .string(let s):
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
    }
}

// MARK: - Commands used by the app

public extension ESP32Command {
    /// T:1 — closed-loop wheel speeds in m/s.
    static func wheels(left: Double, right: Double) -> Self {
        .init(1, [("L", .double(left)), ("R", .double(right))])
    }

    /// T:13 — linear (m/s) and angular (rad/s) velocity.
    static func velocity(linear: Double, angular: Double) -> Self {
        .init(13, [("X", .double(linear)), ("Z", .double(angular))])
    }

    static let stop = wheels(left: 0, right: 0)

    /// T:133 — move the pan-tilt to an absolute angle.
    static func gimbal(pan: Double, tilt: Double) -> Self {
        .init(133, [("X", .double(pan)), ("Y", .double(tilt)), ("SPD", .int(0)), ("ACC", .int(128))])
    }

    /// T:137 — gimbal self-stabilisation on/off with a tilt bias.
    static func gimbalSteady(_ on: Bool, tilt: Double) -> Self {
        .init(137, [("s", .int(on ? 1 : 0)), ("y", .double(tilt))])
    }
}
