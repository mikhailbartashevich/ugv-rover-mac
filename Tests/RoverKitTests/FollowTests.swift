import Foundation
import CoreGraphics
import Testing
@testable import RoverKit

@Suite("Follow planner")
struct FollowPlannerTests {
    let s = FollowSettings()

    @Test func turnsTowardsTargetOnTheLeft() {
        let c = FollowPlanner.command(for: CGRect(x: 0.05, y: 0.3, width: 0.2, height: 0.3), settings: s)
        #expect(c.angular > 0, "left is positive")
        #expect(c.linear == 0, "turn first when far off-centre")
    }

    @Test func approachesWhenCentredAndSmall() {
        let c = FollowPlanner.command(for: CGRect(x: 0.42, y: 0.4, width: 0.16, height: 0.2), settings: s)
        #expect(c.angular == 0)
        #expect(c.linear > 0 && c.linear <= s.maxSpeed)
    }

    @Test func holdsWhenCloseAndNeverReverses() {
        let c = FollowPlanner.command(for: CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.8), settings: s)
        #expect(c == .zero)
    }
}

@Suite("Claude advice parsing")
struct ClaudeAdviceTests {
    @Test func parsesStructuredOutput() {
        let a = ClaudeVision.parse([
            "target_visible": true, "target_direction": "left",
            "target_box": ["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4],
            "obstacle_ahead": true, "safe_to_drive": false, "note": "Chair leg ahead",
        ], latency: 1.2)
        #expect(a.targetVisible && a.direction == .left && a.obstacleAhead && !a.safeToDrive)
        let box = try! #require(a.box)
        #expect(abs(box.minX - 0.1) < 1e-9 && abs(box.minY - 0.2) < 1e-9)
        #expect(abs(box.width - 0.3) < 1e-9 && abs(box.height - 0.4) < 1e-9)
    }

    @Test func nullBox() {
        let a = ClaudeVision.parse(["target_visible": false, "target_direction": "not_visible", "target_box": NSNull(),
                                    "obstacle_ahead": false, "safe_to_drive": true, "note": ""], latency: 0)
        #expect(a.box == nil && a.direction == .notVisible)
    }
}

/// Closed loop against the mock rover's simulator:
///   python Tools/mock-rover/mock_rover.py 5056 --world <cat photo>
///   UGV_TEST_SIM=127.0.0.1:5056 swift test --filter Follow
@Suite("Follow in simulator", .enabled(if: ProcessInfo.processInfo.environment["UGV_TEST_SIM"] != nil))
@MainActor
struct FollowSimTests {
    let host = ProcessInfo.processInfo.environment["UGV_TEST_SIM"] ?? ""

    private func sim() async throws -> [String: Any] {
        let (d, _) = try await URLSession.shared.data(from: URL(string: "http://\(host)/sim")!)
        return try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
    }

    @Test func turnsToTheCatThenApproachesAndStops() async throws {
        let rover = RoverClient()
        rover.host = host
        let video = MJPEGStream()
        await rover.connect()
        video.start(url: rover.videoURL!)
        let follow = FollowController(rover: rover, video: video, claude: ClaudeVision(apiKey: { nil }))
        follow.settings.targetSize = 0.8

        let end = Date().addingTimeInterval(40)
        while Date() < end, !(rover.socket.canSendJSON && video.lastFrameAt != nil) {
            try await Task.sleep(for: .milliseconds(100))
        }
        var reset = URLRequest(url: URL(string: "http://\(host)/sim/reset")!)
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)
        try await Task.sleep(for: .milliseconds(500))   // let a fresh frame arrive
        let before = try await sim()
        follow.start()

        var phases: [FollowController.Phase] = []
        while Date() < end {
            try await Task.sleep(for: .milliseconds(250))
            if phases.last != follow.phase { phases.append(follow.phase) }
            if follow.phase == .holding { break }
        }
        let after = try await sim()
        follow.stop()
        video.stop()
        rover.socket.disconnect()

        let x0 = before["target_x_in_view"] as? Double ?? 0
        let x1 = after["target_x_in_view"] as? Double ?? 0
        let z1 = after["zoom"] as? Double ?? 1
        print("phases:", phases.map(\.rawValue), "x:", x0, "→", x1, "zoom:", z1)
        #expect(phases.contains(.following))
        #expect(follow.phase == .off)
        #expect(abs(x1 - 0.5) < abs(x0 - 0.5), "turned towards the cat")
        #expect(abs(x1 - 0.5) < 0.15, "cat ends up near the centre")
        #expect(z1 > 1.1, "drove closer")
    }
}
