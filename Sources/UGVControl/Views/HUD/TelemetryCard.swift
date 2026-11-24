import SwiftUI
import RoverKit

/// Battery and system stats reported by the rover (top-left).
struct TelemetryCard: View {
    @Environment(RoverClient.self) private var rover
    @Environment(MJPEGStream.self) private var video

    var body: some View {
        let t = rover.telemetry
        let live = rover.socket.lastUpdate != nil

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BatteryGlyph(fraction: t.batteryFraction, low: t.batteryLow)
                Text(t.voltage.map { String(format: "%.1f V", $0) } ?? "— V")
                    .font(.callout.weight(.semibold).monospacedDigit())
                if let f = t.batteryFraction {
                    Text("\(Int((f * 100).rounded()))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(t.batteryLow ? Color.red : Color.secondary)
                }
                Spacer(minLength: 0)
                if rover.socket.battery.isCharging {
                    Label("Charging", systemImage: "bolt.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                        .help("The battery voltage has been rising steadily while the rover stands still, so it's most likely on the charger. The rover doesn't report its charger directly; this takes a minute or two to show after connecting or driving.")
                } else if t.batteryLow {
                    Badge(text: "LOW", color: .red)
                }
            }

            // Icon | label | value, twice per row, so every column lines up.
            Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 6) {
                metricRow(Metric(symbol: "cpu", title: "CPU", value: t.cpu.map { "\(Int($0))%" }),
                          Metric(symbol: "memorychip", title: "RAM", value: t.ram.map { "\(Int($0))%" }))
                metricRow(Metric(symbol: "thermometer.medium", title: "Temp", value: t.temp.map { String(format: "%.0f°C", $0) }),
                          Metric(symbol: "wifi", title: "Signal", value: t.rssi.map { "\(Int($0)) dBm" }))
                metricRow(Metric(symbol: "film", title: "FPS", value: fps(t)),
                          Metric(symbol: "internaldrive", title: "Media", value: storage(t)))
            }
            .font(.caption)
            .lineLimit(1)
        }
        .frame(width: 244, alignment: .leading)
        .opacity(live ? 1 : 0.55)
        .hudCard()
        .help(live ? "Live data from the rover, refreshed every few seconds. Battery % is estimated from the 3-cell pack voltage (≈9.6 V empty … 12.6 V full); charge below 10 V. FPS is the rover's camera rate, Media is the space used by photos and videos on the rover." : "Waiting for data from the rover — it arrives over the live control channel once connected.")
    }

    private func fps(_ t: Telemetry) -> String? {
        if let f = t.fps, f > 0 { return String(format: "%.0f", f) }
        return video.fps > 0 ? String(format: "%.0f", video.fps) : nil
    }

    private func storage(_ t: Telemetry) -> String? {
        guard let p = t.picturesMB, let v = t.videosMB else { return nil }
        return "\(Int(p + v)) MB"
    }
}

private struct Metric {
    let symbol: String
    let title: String
    let value: String?
}

private extension TelemetryCard {
    func metricRow(_ a: Metric, _ b: Metric) -> some View {
        GridRow {
            cells(a)
            Color.clear.frame(width: 8, height: 1)          // gap between the two groups
            cells(b)
        }
    }

    @ViewBuilder func cells(_ m: Metric) -> some View {
        Image(systemName: m.symbol)
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .gridColumnAlignment(.center)
        Text(m.title).foregroundStyle(.secondary)
        Text(m.value ?? "—").monospacedDigit()
    }
}
