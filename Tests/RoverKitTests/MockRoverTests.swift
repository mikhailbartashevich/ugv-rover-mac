import Foundation
import Testing
@testable import RoverKit

/// End-to-end checks against a rover (or the Flask-SocketIO mock in Tools/mock-rover).
/// Run with: UGV_TEST_ROVER=127.0.0.1:5055 swift test
@Suite("Live rover", .enabled(if: ProcessInfo.processInfo.environment["UGV_TEST_ROVER"] != nil))
@MainActor
struct MockRoverTests {
    let host = ProcessInfo.processInfo.environment["UGV_TEST_ROVER"] ?? ""

    private func waitUntil(_ timeout: Double = 8, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return cond()
    }

    @Test func socketConnectsAndReceivesTelemetry() async {
        let rover = RoverClient()
        rover.host = host
        await rover.connect()
        #expect(rover.reachable == true)
        #expect(await waitUntil { rover.socket.canSendJSON })
        #expect(await waitUntil { rover.telemetry.voltage != nil })
        rover.socket.disconnect()
    }

    @Test func modeChangeIsReportedBack() async {
        let rover = RoverClient()
        rover.host = host
        await rover.connect()
        #expect(await waitUntil { rover.socket.isConnected })
        rover.setVisionMode(.faces)
        #expect(await waitUntil { rover.telemetry.visionMode == .faces })
        rover.setVisionMode(.none)
        #expect(await waitUntil { rover.telemetry.visionMode == VisionMode.none })
        rover.setHeadLight(.auto)
        #expect(await waitUntil { rover.telemetry.headLight == .auto })
        rover.setHeadLight(.off)
        rover.socket.disconnect()
    }

    @Test func capturedPhotoAppearsInLibrary() async {
        let rover = RoverClient()
        rover.host = host
        await rover.connect()
        #expect(await waitUntil { rover.socket.isConnected })
        let lib = MediaLibrary()
        await lib.refresh(base: rover.baseURL!)
        #expect(lib.error == nil)
        let before = lib.photos.count
        try? await Task.sleep(for: .seconds(1.1))   // photo names are per-second timestamps
        rover.capturePhoto()
        try? await Task.sleep(for: .seconds(1))
        await lib.refresh(base: rover.baseURL!)
        #expect(lib.photos.count == before + 1)
        rover.socket.disconnect()
    }

    /// Needs UGV_TEST_ROVER_LOG pointing at the mock's data/commands.log.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["UGV_TEST_ROVER_LOG"] != nil))
    func drivingGoesOverSocketAndStops() async throws {
        let logURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["UGV_TEST_ROVER_LOG"]!)
        let rover = RoverClient()
        rover.host = host
        await rover.connect()
        #expect(await waitUntil { rover.socket.canSendJSON })
        let start = (try? String(contentsOf: logURL, encoding: .utf8))?.count ?? 0
        rover.setSpeedPreset(.slow)
        rover.setDrive(forward: 1, turn: 0)
        try await Task.sleep(for: .milliseconds(700))
        rover.setDrive(forward: 0, turn: 0)
        rover.setGimbal(pan: 20, tilt: 10)
        try await Task.sleep(for: .milliseconds(400))
        let log = String(try String(contentsOf: logURL, encoding: .utf8).dropFirst(start))
        let forward = log.components(separatedBy: #"JSON {"T":1,"L":0.39,"R":0.39}"#).count - 1
        #expect(forward >= 3, "drive command is repeated while held")
        #expect(log.contains(#"JSON {"T":1,"L":0,"R":0}"#))
        #expect(log.contains(#"JSON {"T":133,"X":20,"Y":10,"SPD":0,"ACC":128}"#))
        #expect(!log.contains("HTTP"), "socket path used, not HTTP")
        rover.socket.disconnect()
    }

    @Test func commandLineFallback() async {
        let rover = RoverClient()
        rover.host = host
        #expect(await rover.sendCommandLine(#"base -c {"T":130}"#))
    }
}
