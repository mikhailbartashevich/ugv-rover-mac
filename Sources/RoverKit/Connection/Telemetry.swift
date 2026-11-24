import Foundation

/// Live data the rover's host program pushes over Socket.IO (`update` on /ctrl).
/// Keys are the numeric `fb` codes from ugv_rpi's config.yaml.
public struct Telemetry: Sendable, Equatable {
    public var cpu: Double?
    public var ram: Double?
    public var temp: Double?
    public var rssi: Double?
    public var fps: Double?
    public var voltage: Double?
    public var pan: Double?
    public var tilt: Double?
    public var picturesMB: Double?
    public var videosMB: Double?
    public var visionMode: VisionMode?
    public var reaction: DetectionReaction?
    public var movementLocked: Bool?
    public var headLight: HeadLight?
    public var chassisLightOn: Bool?

    public init() {}

    /// 3S Li-ion pack: ~9.6 V empty … 12.6 V full.
    public var batteryFraction: Double? {
        guard let v = voltage, v > 1 else { return nil }
        return min(1, max(0, (v - 9.6) / 3.0))
    }

    public var batteryLow: Bool {
        guard let v = voltage, v > 1 else { return false }
        return v < 10.0
    }

    public mutating func apply(_ d: [String: Any]) {
        func num(_ k: Int) -> Double? { (d[String(k)] as? NSNumber)?.doubleValue }
        if let v = num(106) { cpu = v }
        if let v = num(107) { temp = v }
        if let v = num(108) { ram = v }
        if let v = num(111) { rssi = v }
        if let v = num(113) { fps = v }
        if let v = num(112) { voltage = v / 100 }
        if let v = num(109) { pan = v }
        if let v = num(110) { tilt = v }
        if let v = num(104) { picturesMB = v }
        if let v = num(105) { videosMB = v }
        // The host echoes back the `mode` it was sent, as a float (10303.0).
        if let v = num(101) { visionMode = VisionMode(rawValue: Int(v.rounded())) }
        if let v = num(103) { reaction = DetectionReaction(rawValue: Int(v.rounded())) }
        // led_mode: 0 off, 1 auto, 2 on.
        if let v = num(102) { headLight = HeadLight(rawValue: Int(v.rounded())) }
        if let v = num(115) { chassisLightOn = v != 0 }
        if let b = d["114"] as? Bool { movementLocked = b }
    }
}
