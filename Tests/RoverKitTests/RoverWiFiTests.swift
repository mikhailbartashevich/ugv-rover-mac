import Foundation
import Testing
@testable import RoverKit

/// Runs the real Wi‑Fi scripts with bash against a fake `nmcli`/`sudo`, which logs every
/// call. The fake rover has two saved networks ("Home Net", active, priority 50, and
/// "Office", priority 5) plus the AccessPopup hotspot profile (priority 100, must be ignored).
struct FakeRover {
    static let home = "11111111-1111-1111-1111-111111111111"
    static let office = "22222222-2222-2222-2222-222222222222"
    static let ap = "33333333-3333-3333-3333-333333333333"
    static let added = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    let dir: URL
    var bin: URL { dir.appendingPathComponent("bin") }

    init(joinFails: Bool = false, sudoFails: Bool = false) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ugv-wifi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try write("profiles", """
            \(Self.home)|Home Net|infrastructure|Home|50|yes
            \(Self.office)|Office|infrastructure|Office|5|no
            \(Self.ap)|AccessPopup|ap|AccessPopup|100|no

            """)
        try write("active", Self.home)
        if joinFails { try write("fail", "") }
        try tool("nmcli", #"""
            F="$FAKE"; echo "$*" >> "$F/log"; A="$*"; U="${A##* }"
            get() { awk -F'|' -v u="$U" -v c="$1" '$1==u{print $c}' "$F/profiles"; }
            case "$A" in
              "-t -f DEVICE,TYPE device") printf 'eth0:ethernet\nwlan0:wifi\n' ;;
              "-t -e no -f UUID,DEVICE connection show --active") echo "$(cat "$F/active"):wlan0" ;;
              "-t -e no -f UUID,TYPE,NAME connection show")
                awk -F'|' '{print $1":802-11-wireless:"$2}' "$F/profiles"; echo "44444444-4444-4444-4444-444444444444:loopback:lo" ;;
              "-e no -g 802-11-wireless.mode connection show uuid "*) get 3 ;;
              "-e no -g 802-11-wireless.ssid connection show uuid "*) get 4 ;;
              "-e no -g connection.autoconnect-priority connection show uuid "*) get 5 ;;
              "-e no -g connection.autoconnect connection show uuid "*) get 6 ;;
              "-s -e no -g 802-11-wireless-security.key-mgmt connection show uuid "*) echo wpa-psk ;;
              "-s -e no -g 802-11-wireless-security.psk connection show uuid "*) echo "old secret" ;;
              "-g IP4.ADDRESS device show wlan0") echo "10.0.0.7/24" ;;
              "-t -e no -f IN-USE,SIGNAL,SECURITY,SSID device wifi list --rescan yes ifname wlan0")
                printf '*:70:WPA2:Home\n :55:WPA2 WPA3:Cafe: Guest\n :40:WPA3:Lab\n :62:WPA3:Lab\n :30:--:Open\n :20:WPA2:\n' ;;
              "connection add "*) echo "Connection 'x' (aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee) successfully added." ;;
              "connection modify "*|"connection delete "*) ;;
              "--wait 40 connection up uuid "*)
                if [ -f "$F/fail" ] && [ "$U" != "$(cat "$F/active")" ]; then
                  echo "Error: Connection activation failed: Secrets were required, but not provided." >&2; exit 4
                fi ;;
              *) echo "unexpected nmcli $A" >&2; exit 9 ;;
            esac
            """#)
        try tool("sudo", sudoFails ? "exit 1" : #"""
            [ "$1" = -n ] && shift
            if [ "$1" = -S ]; then shift 3; cat > /dev/null; fi
            exec "$@"
            """#)
        try tool("setsid", #"exec "$@""#)
        try tool("hostname", "echo ugv-rover")
        try tool("accesspopup", #"echo "accesspopup" >> "$FAKE/log""#)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func tool(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Runs a script like the Jupyter terminal does (`bash file`) and returns stdout.
    func run(_ script: String) throws -> String {
        let file = dir.appendingPathComponent("script-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [file.path]
        p.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "FAKE": dir.path, "HOME": dir.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(!FileManager.default.fileExists(atPath: file.path), "scripts delete themselves")
        return String(decoding: data, as: UTF8.self)
    }

    /// Waits for the detached part of the switch to finish.
    func waitForSwitch() async throws -> String {
        let log = dir.appendingPathComponent("ugv_wifi_switch.log")
        for _ in 0..<100 {
            if let s = try? String(contentsOf: log, encoding: .utf8), s.contains(" done") { return s }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("switch didn't finish")
        return ""
    }

    var log: String { (try? String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)) ?? "" }
    var nmcliWrites: [String] {
        log.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("connection add") || $0.hasPrefix("connection modify") || $0.hasPrefix("connection delete") }
    }

    func switchScript(_ ssid: String, password: String = "") -> String {
        RoverWiFiScript.makeSwitch(ssid: ssid, password: password, sudoPassword: "", tmp: dir.path, delay: 0)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

@Suite("Rover Wi‑Fi switch")
struct RoverWiFiTests {
    @Test func surveyListsCurrentNearbyAndSaved() throws {
        let rover = try FakeRover()
        defer { rover.cleanup() }
        let out = try rover.run(RoverWiFiScript.survey())
        #expect(out.contains(ProvisionScript.okMarker))
        let s = RoverWiFiScript.parseSurvey(out)
        #expect(s.hostname == "ugv-rover")
        #expect(s.currentSSID == "Home")
        #expect(s.ipv4 == "10.0.0.7")
        #expect(!s.currentIsAccessPoint)
        #expect(s.nearby.map(\.ssid) == ["Home", "Lab", "Cafe: Guest", "Open"], "current first, then by signal; hidden skipped")
        #expect(s.nearby.first { $0.ssid == "Lab" }?.signal == 62, "duplicates keep the strongest")
        #expect(s.nearby.first { $0.ssid == "Lab" }?.keyMgmt == "sae")
        #expect(s.nearby.first { $0.ssid == "Cafe: Guest" }?.keyMgmt == "wpa-psk")
        #expect(s.nearby.first { $0.ssid == "Open" }?.isOpen == true)
        #expect(s.saved.count == 3)
        #expect(s.isSaved("Office") && s.isSaved("Home Net") == false && !s.isSaved("AccessPopup"))
        #expect(rover.nmcliWrites.isEmpty, "scanning changes nothing")
    }

    @Test func newNetworkGetsTopPriorityAndKeepsOthers() async throws {
        let rover = try FakeRover()
        defer { rover.cleanup() }
        let out = try rover.run(rover.switchScript("Cafe: Guest", password: "it's $ecret"))
        #expect(out.contains(ProvisionScript.okMarker))
        let sw = try #require(RoverWiFiScript.parseSwitch(out))
        #expect(sw.hostname == "ugv-rover" && sw.uuid == FakeRover.added && sw.isNew)
        _ = try await rover.waitForSwitch()
        // Priority is above every client profile (50), ignoring the hotspot's 100.
        #expect(rover.nmcliWrites == [
            "connection add type wifi ifname wlan0 con-name ugv-Cafe: Guest ssid Cafe: Guest connection.autoconnect yes connection.autoconnect-priority 60 wifi-sec.key-mgmt wpa-psk wifi-sec.psk it's $ecret",
        ])
        #expect(rover.log.contains("--wait 40 connection up uuid \(FakeRover.added)"))
        #expect(!rover.log.contains("connection up uuid \(FakeRover.home)"), "no fallback on success")
        let res = try rover.run(RoverWiFiScript.readResult(tmp: rover.dir.path))
        #expect(RoverWiFiScript.parseResult(res) == RoverWiFiResult(ok: true, ssid: "Cafe: Guest", detail: "10.0.0.7/24"))
    }

    @Test func failedJoinRemovesOnlyTheNewProfileAndFallsBack() async throws {
        let rover = try FakeRover(joinFails: true)
        defer { rover.cleanup() }
        let out = try rover.run(rover.switchScript("Lab", password: "wrong"))
        #expect(out.contains(ProvisionScript.okMarker))
        _ = try await rover.waitForSwitch()
        let deletes = rover.nmcliWrites.filter { $0.hasPrefix("connection delete") }
        #expect(deletes == ["connection delete uuid \(FakeRover.added)"], "only the profile this switch created")
        #expect(rover.log.contains("--wait 40 connection up uuid \(FakeRover.home)"), "goes back to the old network")
        #expect(!rover.log.contains("accesspopup"), "old network came back, no hotspot needed")
        let r = try #require(RoverWiFiScript.parseResult(try rover.run(RoverWiFiScript.readResult(tmp: rover.dir.path))))
        #expect(!r.ok && r.ssid == "Lab" && r.detail.contains("Secrets were required"))
        let msg = WiFiSwitcher.describeFallback(r, target: "Lab", oldSSID: "Home")
        #expect(msg.contains("went back to “Home”") && msg.contains("password is probably wrong"))
    }

    @Test func savedNetworkIsUpdatedAndRestoredOnFailure() async throws {
        let rover = try FakeRover(joinFails: true)
        defer { rover.cleanup() }
        let out = try rover.run(rover.switchScript("Office", password: "new pass"))
        let sw = try #require(RoverWiFiScript.parseSwitch(out))
        #expect(sw.uuid == FakeRover.office && !sw.isNew)
        _ = try await rover.waitForSwitch()
        #expect(rover.nmcliWrites == [
            "connection modify uuid \(FakeRover.office) connection.autoconnect yes connection.autoconnect-priority 60 wifi-sec.key-mgmt wpa-psk wifi-sec.psk new pass",
            "connection modify uuid \(FakeRover.office) connection.autoconnect-priority 5 connection.autoconnect no 802-11-wireless-security.key-mgmt wpa-psk 802-11-wireless-security.psk old secret",
        ], "never deleted; old priority, autoconnect and password put back")
    }

    @Test func savedNetworkWithoutPasswordKeepsItsSecret() async throws {
        let rover = try FakeRover()
        defer { rover.cleanup() }
        _ = try rover.run(rover.switchScript("Office"))
        _ = try await rover.waitForSwitch()
        #expect(rover.nmcliWrites == [
            "connection modify uuid \(FakeRover.office) connection.autoconnect yes connection.autoconnect-priority 60",
        ])
    }

    @Test func refusesCurrentNetworkAndMissingSudo() throws {
        let rover = try FakeRover()
        defer { rover.cleanup() }
        let out = try rover.run(rover.switchScript("Home"))
        #expect(ProvisionScript.value(after: ProvisionScript.failMarker, in: out) == RoverWiFiScript.failAlreadyOn)
        #expect(rover.nmcliWrites.isEmpty)

        let locked = try FakeRover(sudoFails: true)
        defer { locked.cleanup() }
        let out2 = try locked.run(locked.switchScript("Lab", password: "x"))
        #expect(ProvisionScript.value(after: ProvisionScript.failMarker, in: out2) == RoverWiFiScript.failSudo)
        #expect(locked.log.isEmpty)
    }

    @Test func parsesNoisyTerminalOutput() {
        let payload = Data("ok\tMy Net\t192.168.1.20/24".utf8).base64EncodedString()
        let out = "\u{1B}[?2004hbash-5.2$ bash /tmp/x\r\n\(RoverWiFiScript.resultMarker) \(payload)\r\n__UGV_OK__\r\n"
        #expect(RoverWiFiScript.parseResult(out) == RoverWiFiResult(ok: true, ssid: "My Net", detail: "192.168.1.20/24"))
        #expect(RoverWiFiScript.parseResult("\(RoverWiFiScript.resultMarker) \r\n") == nil, "no result yet")
    }

    @Test func switchScriptSurvivesTerminalTransport() throws {
        let script = RoverWiFiScript.makeSwitch(ssid: "a'b\"c", password: "p $x `y`", sudoPassword: "")
        let lines = ProvisionScript.terminalLines(for: script)
        #expect(lines.allSatisfy { $0.count < 500 })
        #expect(!lines.joined().contains("a'b"), "secrets and names only travel base64-encoded")
    }
}

/// Read-only check against a real rover's JupyterLab: UGV_TEST_JUPYTER=<ip> Tools/test.sh
@Suite("Live rover Wi‑Fi survey", .enabled(if: ProcessInfo.processInfo.environment["UGV_TEST_JUPYTER"] != nil))
@MainActor
struct LiveWiFiSurveyTests {
    @Test func surveyReportsTheCurrentNetwork() async throws {
        let host = ProcessInfo.processInfo.environment["UGV_TEST_JUPYTER"] ?? ""
        let term = JupyterTerminal(base: try #require(URL(string: "http://\(host):8888")))
        try await term.open()
        let out = try await term.runScript(RoverWiFiScript.survey(), timeout: 40)
        await term.close()
        let s = RoverWiFiScript.parseSurvey(out)
        print("survey:", s.hostname ?? "-", s.currentSSID ?? "-", s.ipv4 ?? "-",
              s.nearby.map { "\($0.ssid)(\($0.signal),\($0.security))" }, s.saved.map { "\($0.name)=\($0.ssid)@\($0.priority)\($0.isAccessPoint ? " ap" : "")" })
        #expect(s.hostname != nil)
        #expect(s.currentSSID != nil || s.ipv4 == nil)
        #expect(!s.saved.isEmpty)
    }
}
