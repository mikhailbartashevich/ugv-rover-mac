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
        let video = VideoStream()
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

@Suite("Battery trend")
struct BatteryTrendTests {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func risingVoltageWhileStillIsCharging() {
        var b = BatteryTrend()
        for i in 0..<30 { b.add(11.00 + Double(i) * 0.0025 + (i % 2 == 0 ? 0.01 : -0.01), at: t0 + Double(i) * 5) }
        #expect(b.isCharging)          // +0.03 V/min
    }

    @Test func flatNoisyVoltageIsNot() {
        var b = BatteryTrend()
        for i in 0..<30 { b.add(11.05 + (i % 3 == 0 ? 0.02 : -0.01), at: t0 + Double(i) * 5) }
        #expect(!b.isCharging)
    }

    @Test func needsEnoughHistoryAndResetsOnDriving() {
        var b = BatteryTrend()
        for i in 0..<10 { b.add(11.0 + Double(i) * 0.05, at: t0 + Double(i) * 5) }
        #expect(!b.isCharging, "only 45 s of data")
        for i in 10..<30 { b.add(11.0 + Double(i) * 0.05, at: t0 + Double(i) * 5) }
        #expect(b.isCharging)
        b.noteLoad()
        #expect(!b.isCharging)
    }
}

/// Far-away target: the cat is a few dozen pixels tall at the start.
///   python Tools/mock-rover/mock_rover.py 5058 --world <cat photo> --target-scale 0.18
///   UGV_TEST_FAR_SIM=127.0.0.1:5058 Tools/test.sh --filter Far
@Suite("Far target in simulator", .enabled(if: ProcessInfo.processInfo.environment["UGV_TEST_FAR_SIM"] != nil))
@MainActor
struct FarTargetTests {
    let host = ProcessInfo.processInfo.environment["UGV_TEST_FAR_SIM"] ?? ""

    @Test func spotsASmallDistantCatAndClosesIn() async throws {
        let rover = RoverClient()
        rover.host = host
        let video = VideoStream()
        await rover.connect()
        var reset = URLRequest(url: URL(string: "http://\(host)/sim/reset")!)
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)
        video.start(url: rover.videoURL!)
        let follow = FollowController(rover: rover, video: video, claude: ClaudeVision(apiKey: { nil }))
        follow.settings.maxSpeed = 0.25
        if ProcessInfo.processInfo.environment["UGV_TEST_FAR_CLAUDE"] != nil {
            // Uses the local Claude Code to spot what the Mac can't.
            follow.claudeEnabled = true
            follow.claude.backend = .claudeCode
        }

        let end = Date().addingTimeInterval(75)
        while Date() < end, !(rover.socket.canSendJSON && video.lastFrameAt != nil) {
            try await Task.sleep(for: .milliseconds(100))
        }
        follow.start()
        var sources = Set<String>()
        var firstHeight: CGFloat?
        var maxHeight: CGFloat = 0
        while Date() < end {
            try await Task.sleep(for: .milliseconds(250))
            if let d = follow.detection {
                sources.insert(d.source.rawValue)
                if firstHeight == nil { firstHeight = d.box.height }
                maxHeight = max(maxHeight, d.box.height)
            }
            if maxHeight > 0.35 { break }
        }
        follow.stop()
        video.stop()
        rover.socket.disconnect()
        print("far: sources \(sources.sorted()), first seen at \(Int((firstHeight ?? 0) * 100))% of frame height, reached \(Int(maxHeight * 100))%")
        #expect(firstHeight != nil, "the distant cat was found")
        #expect((firstHeight ?? 1) < 0.2, "it really was small when first found")
        #expect(maxHeight > (firstHeight ?? 1) * 1.5, "and the rover drove towards it")
    }
}
