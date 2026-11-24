import Foundation
import Observation

/// Everything the app does to the rover. Driving and modes go over Socket.IO like
/// the stock web UI; HTTP `POST /send_command` is the fallback and the console.
@MainActor
@Observable
public final class RoverClient {
    public struct Toast: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let text: String
        public let symbol: String
    }

    // MARK: Connection

    public var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "roverHost") }
    }
    public let defaultPort = 5000
    public private(set) var reachable: Bool?
    public private(set) var lastError: String?
    public private(set) var lastSent = ""
    public let socket = RoverSocket()

    public var telemetry: Telemetry { socket.telemetry }

    /// `host` may include an explicit port ("10.0.0.7:5000").
    public var baseURL: URL? {
        URL(string: host.contains(":") ? "http://\(host)" : "http://\(host):\(defaultPort)")
    }
    public var videoURL: URL? { baseURL?.appendingPathComponent("video_feed") }
    public var hostIP: String { baseURL?.host() ?? host }

    // MARK: Driving

    public var speedRate: Double = SpeedPreset.middle.rate
    public var speedPreset: SpeedPreset? { SpeedPreset.allCases.first { abs($0.rate - speedRate) < 0.01 } }
    public var maxSpeed: Double { RoverLimits.maxWheelSpeed * speedRate }
    public private(set) var forward = 0
    public private(set) var turn = 0
    @ObservationIgnored private var driveTimer: Timer?
    @ObservationIgnored private var analogActive = false
    @ObservationIgnored private var httpInFlight = false

    // MARK: Camera & media

    public private(set) var pan: Double = 0
    public private(set) var tilt: Double = 0
    public private(set) var steady = false
    public private(set) var zoom: CameraZoom = .x1
    public private(set) var resolution: StreamResolution?
    public private(set) var recordingSince: Date?
    public var isRecording: Bool { recordingSince != nil }

    // MARK: Modes — the rover reports these back; local values cover the gap until it does.

    @ObservationIgnored private var pending: [String: (Any, Date)] = [:]
    private var pendingTick = 0

    public var visionMode: VisionMode { reported("vision", telemetry.visionMode) ?? .none }
    public var reaction: DetectionReaction { reported("reaction", telemetry.reaction) ?? .none }
    public var headLight: HeadLight { reported("head", telemetry.headLight) ?? .off }
    public var chassisLightOn: Bool { reported("chassis", telemetry.chassisLightOn) ?? false }
    // The rover starts with movement locked.
    public var movementLocked: Bool { reported("lock", telemetry.movementLocked) ?? true }

    public private(set) var toast: Toast?

    /// Called when the user drives or stops by hand (autopilot uses it to step aside).
    @ObservationIgnored public var onManualOverride: (() -> Void)?

    public init() {
        host = UserDefaults.standard.string(forKey: "roverHost") ?? "192.168.50.5"
    }

    // MARK: - Connection

    /// Checks the web app and (re)opens the Socket.IO channel.
    public func connect() async {
        await ping()
        if reachable == true, let base = baseURL {
            socket.connect(to: base)
        } else {
            socket.disconnect()
        }
    }

    public func ping() async {
        guard let url = baseURL else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            reachable = (resp as? HTTPURLResponse) != nil
            lastError = nil
        } catch {
            reachable = false
            lastError = error.localizedDescription
        }
    }

    // MARK: - Sending

    /// Sends an ESP32 command over Socket.IO, or over HTTP if the socket is down.
    public func send(_ command: ESP32Command) {
        lastSent = command.json
        if socket.emit(command) { return }
        guard !httpInFlight else { return }
        httpInFlight = true
        Task {
            _ = await sendCommandLine("base -c \(command.json)")
            httpInFlight = false
        }
    }

    /// Runs a line through the host's command line (`POST /send_command`), e.g.
    /// `base -c {"T":130}`. Returns whether the host accepted it.
    @discardableResult
    public func sendCommandLine(_ line: String) async -> Bool {
        guard let url = baseURL?.appendingPathComponent("send_command") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 2
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = "command=\(line.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")".data(using: .utf8)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            reachable = ok
            lastError = ok ? nil : "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            return ok
        } catch {
            reachable = false
            lastError = error.localizedDescription
            return false
        }
    }

    private func ctrl(_ code: Int) -> Bool {
        if socket.emitCtrl(code) { return true }
        show("Control channel offline", symbol: "bolt.horizontal.circle")
        return false
    }

    // MARK: - Driving

    /// Digital driving (keyboard / on-screen pad): forward −1…1, turn −1…1.
    public func setDrive(forward f: Int, turn t: Int) {
        guard f != forward || t != turn else { return }
        if f != 0 || t != 0 { onManualOverride?() }
        forward = f
        turn = t
        if f == 0 && t == 0 {
            stopDriveTimer()
            send(.stop)
        } else {
            sendDriveTick()
            startDriveTimer()
        }
    }

    /// Analog driving (gamepad): linear −1…1 (forward +), angular −1…1 (left +).
    public func analogDrive(linear: Double, angular: Double) {
        if abs(linear) < 0.01 && abs(angular) < 0.01 {
            if analogActive { analogActive = false; send(.stop) }
            return
        }
        if !analogActive { onManualOverride?() }
        analogActive = true
        send(.velocity(linear: linear * maxSpeed, angular: angular * 2.5 * speedRate))
    }

    public func emergencyStop() {
        onManualOverride?()
        forward = 0
        turn = 0
        analogActive = false
        stopDriveTimer()
        send(.stop)
        if socket.canSendJSON { _ = sendCommandLineInBackground("base -c \(ESP32Command.stop.json)") }
    }

    public func setSpeedPreset(_ preset: SpeedPreset) {
        speedRate = preset.rate
    }

    /// Wheel mix copied from the web UI: arcs slow the inner wheel, spins counter-rotate.
    private func wheelSpeeds() -> (Double, Double) {
        let fast = RoverLimits.maxWheelSpeed * speedRate
        let slow = RoverLimits.arcInnerWheelSpeed * speedRate
        switch (forward, turn) {
        case (1, 0): return (fast, fast)
        case (-1, 0): return (-fast, -fast)
        case (0, -1): return (-fast, fast)
        case (0, 1): return (fast, -fast)
        case (1, -1): return (slow, fast)
        case (1, 1): return (fast, slow)
        case (-1, -1): return (-slow, -fast)
        case (-1, 1): return (-fast, -slow)
        default: return (0, 0)
        }
    }

    private func sendDriveTick() {
        let (l, r) = wheelSpeeds()
        send(.wheels(left: l, right: r))
    }

    private func startDriveTimer() {
        guard driveTimer == nil else { return }
        // The ESP32 stops by itself when commands stop arriving, so keep sending while held.
        driveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendDriveTick() }
        }
    }

    private func stopDriveTimer() {
        driveTimer?.invalidate()
        driveTimer = nil
    }

    private func sendCommandLineInBackground(_ line: String) -> Task<Bool, Never> {
        Task { await sendCommandLine(line) }
    }

    // MARK: - Camera

    public func nudgeGimbal(dx: Double, dy: Double) {
        setGimbal(pan: pan + dx, tilt: tilt + dy)
    }

    public func setGimbal(pan p: Double, tilt t: Double) {
        pan = p.clamped(to: RoverLimits.panRange)
        tilt = t.clamped(to: RoverLimits.tiltRange)
        if steady {
            send(.gimbalSteady(true, tilt: tilt))
        } else {
            send(.gimbal(pan: pan, tilt: tilt))
        }
    }

    /// "Ahead" in the web UI: camera straight forward.
    public func lookAhead() {
        setGimbal(pan: 0, tilt: 0)
    }

    public func setSteady(_ on: Bool) {
        steady = on
        if on { pan = 0 }
        send(.gimbalSteady(on, tilt: tilt))
        show(on ? "Camera stabilisation on" : "Camera stabilisation off", symbol: "gyroscope")
    }

    public func setZoom(_ z: CameraZoom) {
        guard ctrl(z.code) else { return }
        zoom = z
    }

    public func cycleZoom() { setZoom(zoom.next) }

    public func setResolution(_ r: StreamResolution) {
        guard ctrl(r.rawValue) else { return }
        resolution = r
    }

    public func capturePhoto() {
        guard ctrl(RoverCode.capturePhoto) else { return }
        show("Photo saved on rover", symbol: "camera.fill")
    }

    public func toggleRecording() {
        if isRecording {
            guard ctrl(RoverCode.recordStop) else { return }
            recordingSince = nil
            show("Recording saved on rover", symbol: "stop.circle")
        } else {
            guard ctrl(RoverCode.recordStart) else { return }
            recordingSince = Date()
        }
    }

    // MARK: - Lights

    public func setHeadLight(_ mode: HeadLight) {
        guard ctrl(mode.code) else { return }
        remember("head", mode)
    }

    public func toggleHeadLight() {
        setHeadLight(headLight == .off ? .on : .off)
    }

    public func setChassisLight(_ on: Bool) {
        guard ctrl(on ? RoverCode.chassisLightOn : RoverCode.chassisLightOff) else { return }
        remember("chassis", on)
    }

    // MARK: - Vision

    public func setVisionMode(_ mode: VisionMode) {
        guard ctrl(mode.rawValue) else { return }
        remember("vision", mode)
    }

    public func setReaction(_ r: DetectionReaction) {
        guard ctrl(r.rawValue) else { return }
        remember("reaction", r)
    }

    public func setMovementLocked(_ locked: Bool) {
        guard ctrl(locked ? RoverCode.movementLock : RoverCode.movementUnlock) else { return }
        remember("lock", locked)
    }

    // MARK: - Toasts

    public func show(_ text: String, symbol: String) {
        let t = Toast(text: text, symbol: symbol)
        toast = t
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast?.id == t.id { toast = nil }
        }
    }

    // MARK: - Helpers

    private func remember(_ key: String, _ value: Any) {
        pending[key] = (value, Date())
        pendingTick += 1
    }

    /// Recently-set local value wins for 1.5 s, then whatever the rover reports.
    private func reported<T>(_ key: String, _ fromRover: T?) -> T? {
        _ = pendingTick
        if let (v, at) = pending[key], Date().timeIntervalSince(at) < 1.5, let typed = v as? T { return typed }
        return fromRover ?? pending[key]?.0 as? T
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
