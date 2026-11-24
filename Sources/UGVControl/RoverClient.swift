import Foundation
import Observation

/// Talks to the rover's host program (ugv_rpi app.py, Flask on port 5000).
/// Commands go to `POST /send_command` with form field `command=base -c {json}`,
/// which the host forwards to the ESP32 sub-controller over serial.
@MainActor
@Observable
final class RoverClient {
    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "roverHost") }
    }
    var port: Int = 5000

    var reachable: Bool? = nil
    var lastError: String? = nil
    var lastSent: String = ""

    // Drive state
    var maxSpeed: Double = 0.4          // m/s, rover max ≈ 1.3
    private(set) var forward = 0        // -1, 0, 1
    private(set) var turn = 0           // -1 left, 0, 1 right
    private var driveTimer: Timer?
    private var inFlight = false

    // Gimbal (pan-tilt version only)
    var pan: Double = 0                 // -180…180
    var tilt: Double = 0                // -30…90

    // Lights
    var lightsOn = false

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.5
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init() {
        host = UserDefaults.standard.string(forKey: "roverHost") ?? "192.168.50.5"
    }

    /// `host` may include an explicit port ("10.0.0.7:5000"); default is 5000.
    var baseURL: URL? { URL(string: host.contains(":") ? "http://\(host)" : "http://\(host):\(port)") }
    var videoURL: URL? { baseURL?.appendingPathComponent("video_feed") }

    // MARK: - Low level

    func sendJSON(_ obj: [String: Any]) async {
        guard let url = baseURL?.appendingPathComponent("send_command") else { return }
        let json = Self.encode(obj)
        let command = "base -c \(json)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = command.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        req.httpBody = "command=\(encoded)".data(using: .utf8)
        lastSent = json
        do {
            let (_, resp) = try await session.data(for: req)
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            reachable = ok
            lastError = ok ? nil : "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
        } catch {
            reachable = false
            lastError = error.localizedDescription
        }
    }

    func ping() async {
        guard let url = baseURL else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        do {
            let (_, resp) = try await session.data(for: req)
            reachable = (resp as? HTTPURLResponse) != nil
            lastError = nil
        } catch {
            reachable = false
            lastError = error.localizedDescription
        }
    }

    // MARK: - Driving

    func setDrive(forward f: Int, turn t: Int) {
        guard f != forward || t != turn else { return }
        forward = f
        turn = t
        if f == 0 && t == 0 {
            driveTimer?.invalidate()
            driveTimer = nil
            Task { await sendStop() }
        } else {
            sendDriveTick()
            if driveTimer == nil {
                // The sub-controller stops on its own if commands stop arriving,
                // so we keep re-sending while a key is held.
                driveTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.sendDriveTick() }
                }
            }
        }
    }

    private func wheelSpeeds() -> (Double, Double) {
        let v = maxSpeed
        let f = Double(forward), t = Double(turn)
        if forward == 0 {
            // spin in place
            return (v * t * 0.7, -v * t * 0.7)
        }
        let l = v * (f + 0.5 * t * f.sign())
        let r = v * (f - 0.5 * t * f.sign())
        return (clamp(l, v), clamp(r, v))
    }

    private func clamp(_ x: Double, _ m: Double) -> Double { max(-m, min(m, x)) }

    private func sendDriveTick() {
        guard !inFlight else { return }
        let (l, r) = wheelSpeeds()
        inFlight = true
        Task {
            await sendJSON(["T": 1, "L": round2(l), "R": round2(r)])
            inFlight = false
        }
    }

    func sendStop() async {
        forward = 0; turn = 0
        driveTimer?.invalidate(); driveTimer = nil
        await sendJSON(["T": 1, "L": 0, "R": 0])
    }

    func emergencyStop() {
        Task { await sendStop() }
    }

    // MARK: - Gimbal & lights

    func nudgeGimbal(dx: Double, dy: Double) {
        pan = max(-180, min(180, pan + dx))
        tilt = max(-30, min(90, tilt + dy))
        Task { await sendJSON(["T": 133, "X": Int(pan), "Y": Int(tilt), "SPD": 0, "ACC": 0]) }
    }

    func centerGimbal() {
        pan = 0; tilt = 0
        Task { await sendJSON(["T": 133, "X": 0, "Y": 0, "SPD": 0, "ACC": 0]) }
    }

    func toggleLights() {
        lightsOn.toggle()
        let v = lightsOn ? 255 : 0
        Task { await sendJSON(["T": 132, "IO4": v, "IO5": v]) }
    }

    private func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// Compact JSON with "T" first and short decimals (JSONSerialization prints 0.40000000000000002).
    static func encode(_ obj: [String: Any]) -> String {
        let keys = obj.keys.sorted { a, b in a == "T" ? true : (b == "T" ? false : a < b) }
        let parts = keys.map { k -> String in
            let v: String
            switch obj[k] {
            case let d as Double:
                v = d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d)
            case let i as Int: v = String(i)
            case let str as String:
                v = "\"" + str.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            default: v = "null"
            }
            return "\"\(k)\":\(v)"
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

private extension Double {
    func sign() -> Double { self < 0 ? -1 : 1 }
}
