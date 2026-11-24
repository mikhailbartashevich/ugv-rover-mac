import Foundation

/// Infers "charging" from the battery voltage, because the rover doesn't report its
/// charger: while the rover stands still, a steadily rising voltage means it's on charge.
///
/// Driving sags the voltage and it bounces back afterwards, which would look like
/// charging, so the history is cleared whenever the wheels are driven.
public struct BatteryTrend: Sendable {
    /// How far back to look.
    public static let window: TimeInterval = 300
    /// Need at least this much quiet history before deciding.
    public static let minimumSpan: TimeInterval = 90
    /// Volts per minute that count as charging (~0.36 V/hour; a 3S pack on charge
    /// typically rises 1–2 V/hour until it's nearly full).
    public static let chargingSlope = 0.006

    private var samples: [(at: Date, volts: Double)] = []

    public init() {}

    public mutating func add(_ volts: Double, at time: Date = Date()) {
        guard volts > 1 else { return }
        samples.append((time, volts))
        samples.removeAll { time.timeIntervalSince($0.at) > Self.window }
    }

    /// The wheels moved: start over.
    public mutating func noteLoad() {
        samples.removeAll()
    }

    /// Least-squares slope in volts per minute, once there's enough history.
    public var slopePerMinute: Double? {
        guard samples.count >= 6, let first = samples.first, let last = samples.last,
              last.at.timeIntervalSince(first.at) >= Self.minimumSpan else { return nil }
        let xs = samples.map { $0.at.timeIntervalSince(first.at) / 60 }
        let ys = samples.map(\.volts)
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let num = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let den = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        return den > 0 ? num / den : nil
    }

    public var isCharging: Bool { (slopePerMinute ?? 0) > Self.chargingSlope }
}
