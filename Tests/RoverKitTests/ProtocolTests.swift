import Foundation
import Testing
@testable import RoverKit

@Suite("ESP32 commands")
struct ESP32CommandTests {
    @Test func wheelsEncodeWithTFirstAndShortDecimals() {
        #expect(ESP32Command.wheels(left: 0.4, right: -0.858).json == #"{"T":1,"L":0.40,"R":-0.86}"#)
        #expect(ESP32Command.stop.json == #"{"T":1,"L":0,"R":0}"#)
    }

    @Test func gimbalAndSteady() {
        #expect(ESP32Command.gimbal(pan: -10, tilt: 5).json == #"{"T":133,"X":-10,"Y":5,"SPD":0,"ACC":128}"#)
        #expect(ESP32Command.gimbalSteady(true, tilt: 0).json == #"{"T":137,"s":1,"y":0}"#)
    }

    @Test func stringsAreEscaped() {
        #expect(ESP32Command(3, [("Text", .string(#"say "hi""#))]).json == #"{"T":3,"Text":"say \"hi\""}"#)
    }
}

@Suite("Telemetry")
struct TelemetryTests {
    @Test func parsesHostUpdate() {
        var t = Telemetry()
        t.apply(["106": 23, "107": 48.5, "108": 31, "111": -52, "112": 1105, "113": 24.6,
                 "101": 10303, "103": 10402, "102": 1, "115": 255, "114": true])
        #expect(t.cpu == 23)
        #expect(t.voltage == 11.05)
        #expect(t.visionMode == .faces)
        #expect(t.reaction == .capture)
        #expect(t.headLight == .auto)
        #expect(t.chassisLightOn == true)
        #expect(t.movementLocked == true)
        #expect(abs((t.batteryFraction ?? 0) - 0.4833) < 0.01)
        #expect(t.batteryLow == false)
    }

    @Test func lowBattery() {
        var t = Telemetry()
        t.apply(["112": 980])
        #expect(t.batteryLow)
    }
}

@Suite("Provisioning script")
struct ProvisionScriptTests {
    @Test func linesAreShortAndRoundTrip() throws {
        let script = ProvisionScript.make(ssid: #"My "Home" 'Net'"#, password: "p@ss $x", sudoPassword: "")
        let lines = ProvisionScript.terminalLines(for: script)
        #expect(lines.allSatisfy { $0.count < 500 })
        let b64 = lines.dropFirst().dropLast().map { line -> String in
            let start = line.index(line.firstIndex(of: "'")!, offsetBy: 1)
            let end = line.lastIndex(of: "'")!
            return String(line[start..<end])
        }.joined()
        let decoded = try #require(Data(base64Encoded: b64))
        #expect(String(decoding: decoded, as: UTF8.self) == script)
    }

    @Test func markerValues() {
        let out = "junk\r\n__UGV_FAIL__ sudo\r\nbash-5.2$ "
        #expect(ProvisionScript.value(after: ProvisionScript.failMarker, in: out) == "sudo")
    }
}

@Suite("Camera setup script")
struct CameraSetupScriptTests {
    @Test func editsBothResolutionLinesAndRestarts() {
        let s = CameraSetup.script(CameraResolution(width: 1280, height: 960))
        #expect(s.contains("default_res_w:).*/\\1 1280"))
        #expect(s.contains("default_res_h:).*/\\1 960"))
        #expect(s.contains("config.yaml.bak-ugvcontrol"))
        #expect(s.contains("setsid nohup"))
        #expect(s.contains(ProvisionScript.okMarker) && s.contains(ProvisionScript.failMarker))
    }

    @Test func onlyWheelCommandsCountAsMotion() {
        #expect(ESP32Command.wheels(left: 0.1, right: 0).isMotion)
        #expect(!ESP32Command.stop.isMotion)
        #expect(!ESP32Command.gimbal(pan: 10, tilt: 0).isMotion)
    }
}
