import CoreGraphics

/// How the rover follows. Defaults are deliberately slow.
public struct FollowSettings: Sendable, Equatable {
    /// Forward speed cap, m/s.
    public var maxSpeed = 0.12
    /// Turning speed cap, rad/s.
    public var maxTurn = 0.7
    /// Stop approaching once the target fills this much of the frame height.
    public var targetSize = 0.5
    /// After losing the target, turn slowly towards where it was last seen.
    public var searchWhenLost = true
    /// Below these the motors may not move at all, so any non-zero command is at least this.
    public var minSpeed = 0.04
    public var minTurn = 0.15

    public init() {}
}

public struct DriveCommand: Sendable, Equatable {
    /// m/s, forward positive.
    public var linear: Double
    /// rad/s, left (counter-clockwise) positive.
    public var angular: Double

    public init(linear: Double, angular: Double) {
        self.linear = linear
        self.angular = angular
    }

    public static let zero = DriveCommand(linear: 0, angular: 0)
    public var isZero: Bool { abs(linear) < 0.005 && abs(angular) < 0.02 }
}

/// Turns "where is the target in the frame" into a gentle drive command:
/// steer to keep it centred, creep closer while it's small, never reverse.
public enum FollowPlanner {
    static let centreDeadband = 0.06

    public static func command(for box: CGRect, settings s: FollowSettings) -> DriveCommand {
        let offset = Double(box.midX) - 0.5                       // −0.5 (left) … 0.5 (right)
        var angular = 0.0
        if abs(offset) > centreDeadband {
            angular = (-offset * 2 * s.maxTurn).clamped(to: -s.maxTurn...s.maxTurn)
            if abs(angular) < s.minTurn { angular = angular < 0 ? -s.minTurn : s.minTurn }
        }

        let size = Double(box.height)
        var linear = 0.0
        if size < s.targetSize - 0.04 {
            let gap = (s.targetSize - size) / s.targetSize        // 0 … 1
            let centred = max(0, 1 - abs(offset) * 3)             // turn first, then drive
            linear = s.maxSpeed * min(1, gap * 2.5) * centred
            if linear > 0.005 { linear = max(linear, min(s.minSpeed, s.maxSpeed)) } else { linear = 0 }
        }
        return DriveCommand(linear: linear, angular: angular)
    }
}
