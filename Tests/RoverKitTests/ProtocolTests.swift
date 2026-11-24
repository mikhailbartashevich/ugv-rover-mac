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

@Suite("Control commands")
struct CtrlCommandTests {
    /// Same shapes the stock web UI sends with `cmdSend(cmd, mode)` (ugv_rpi refactor branch).
    @Test func matchesTheWebUI() {
        #expect(CtrlCommand.vision(.faces).json == #"{"cmd":101,"mode":10303}"#)
        #expect(CtrlCommand.headLight(.auto).json == #"{"cmd":102,"mode":10405}"#)
        #expect(CtrlCommand.headLight(.off).json == #"{"cmd":102,"mode":10404}"#)
        #expect(CtrlCommand.reaction(.capture).json == #"{"cmd":103,"mode":10402}"#)
        #expect(CtrlCommand.movementLocked(false).json == #"{"cmd":114,"mode":10502}"#)
        #expect(CtrlCommand.chassisLight(255).json == #"{"cmd":115,"mode":255}"#)
        #expect(CtrlCommand.capturePhoto.json == #"{"cmd":10201,"mode":0}"#)
        #expect(CtrlCommand.recording(true).json == #"{"cmd":10203,"mode":1}"#)
        #expect(CtrlCommand.recording(false).json == #"{"cmd":10203,"mode":0}"#)
        #expect(CtrlCommand.zoom(.x4).json == #"{"cmd":10104,"mode":4}"#)
    }
}

@Suite("Telemetry")
struct TelemetryTests {
    @Test func parsesHostUpdate() {
        var t = Telemetry()
        // The rover echoes 101/103 back as floats; 102 is 0/1/2.
        t.apply(["106": 23, "107": 48.5, "108": 31, "111": -52, "112": 1105, "113": 24.6,
                 "101": 10303.0, "103": 10402.0, "102": 1, "115": 255, "114": true])
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
        #expect(s.contains("$CFG.bak-ugvcontrol"))
        #expect(s.contains("readlink /proc/$p/exe"), "picks the Python process, not the sh wrapper")
        #expect(s.contains("setsid nohup"))
        #expect(s.contains("pgrep -P"), "stops app.py's mediamtx and ffmpeg too")
        #expect(!s.contains("cv_ctrl.py"), "no patching of the rover's code")
        #expect(s.contains(ProvisionScript.okMarker) && s.contains(ProvisionScript.failMarker))
    }

    @Test func onlyWheelCommandsCountAsMotion() {
        #expect(ESP32Command.wheels(left: 0.1, right: 0).isMotion)
        #expect(!ESP32Command.stop.isMotion)
        #expect(!ESP32Command.gimbal(pan: 10, tilt: 0).isMotion)
    }
}

@Suite("Camera config")
struct CameraConfigTests {
    @Test func readsResolutionFromConfigYAML() {
        let yaml = "sbc_config:\n  feedback_interval: 0.001\nvideo:\n  default_res_h: 960\n  default_res_w: 1280\n"
        #expect(CameraSetup.resolution(inConfig: yaml) == CameraResolution(width: 1280, height: 960))
        #expect(CameraSetup.resolution(inConfig: "video: {}") == nil)
    }

    @MainActor
    @Test func videoURLFollowsTheWebPort() {
        let rover = RoverClient()
        rover.host = "192.168.0.111"
        #expect(rover.videoURL?.absoluteString == "rtsp://192.168.0.111:8554/cam")
        rover.host = "127.0.0.1:5055"
        #expect(rover.videoURL?.absoluteString == "rtsp://127.0.0.1:8609/cam")
    }
}

@Suite("RTSP / H.264")
struct RTSPTests {
    // From the rover's mediamtx.
    let sdp = """
    v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=Stream\r\nc=IN IP4 0.0.0.0\r\nt=0 0\r\n\
    m=video 0 RTP/AVP 96\r\na=control:trackID=0\r\na=rtpmap:96 H264/90000\r\n\
    a=fmtp:96 packetization-mode=1; sprop-parameter-sets=Z0LAH9oBQBbsBEAAAAMAQAAADyPGDKg=,aM4PyA==; profile-level-id=42C01F\r\n
    """

    @Test func parsesTheH264Track() throws {
        let t = try #require(SDP.h264Track(sdp))
        #expect(t.payloadType == 96)
        #expect(t.control == "trackID=0")
        #expect(t.parameterSets.count == 2)
        #expect(t.parameterSets[0].first.map { $0 & 0x1F } == 7)
        #expect(t.parameterSets[1].first.map { $0 & 0x1F } == 8)
        #expect(H264Decoder.formatDescription(sps: t.parameterSets[0], pps: t.parameterSets[1]) != nil)
        #expect(SDP.resolve(control: t.control, base: "rtsp://h:8554/cam/") == "rtsp://h:8554/cam/trackID=0")
        #expect(SDP.resolve(control: "trackID=0", base: "rtsp://h:8554/cam") == "rtsp://h:8554/cam/trackID=0")
        #expect(SDP.sessionTimeout("1234;timeout=60") == 60)
    }

    private func rtp(_ seq: UInt16, ts: UInt32, marker: Bool, _ payload: [UInt8]) -> RTPPacket {
        var b: [UInt8] = [0x80, (marker ? 0x80 : 0) | 96, UInt8(seq >> 8), UInt8(seq & 0xFF),
                          UInt8(ts >> 24), UInt8(ts >> 16 & 0xFF), UInt8(ts >> 8 & 0xFF), UInt8(ts & 0xFF), 0, 0, 0, 1]
        b += payload
        return RTPPacket(Data(b))!
    }

    @Test func reassemblesFragmentedAndAggregatedNALs() {
        var d = H264Depacketizer()
        // STAP-A with SPS + PPS, then an IDR split into three FU-A fragments.
        #expect(d.push(rtp(1, ts: 9000, marker: false, [24, 0, 2, 0x67, 0xAA, 0, 2, 0x68, 0xBB])).isEmpty)
        #expect(d.push(rtp(2, ts: 9000, marker: false, [0x7C, 0x85, 1, 2])).isEmpty)
        #expect(d.push(rtp(3, ts: 9000, marker: false, [0x7C, 0x05, 3])).isEmpty)
        let units = d.push(rtp(4, ts: 9000, marker: true, [0x7C, 0x45, 4]))
        #expect(units.count == 1)
        #expect(units.first?.nals == [Data([0x67, 0xAA]), Data([0x68, 0xBB]), Data([0x65, 1, 2, 3, 4])])
        #expect(units.first?.timestamp == 9000)
    }

    @Test func dropsAFrameWithALostPacket() {
        var d = H264Depacketizer()
        _ = d.push(rtp(10, ts: 1, marker: false, [0x7C, 0x81, 1]))
        #expect(d.push(rtp(12, ts: 1, marker: true, [0x7C, 0x41, 3])).isEmpty)
        #expect(d.push(rtp(13, ts: 2, marker: true, [0x41, 9])).first?.nals == [Data([0x41, 9])])
    }
}
