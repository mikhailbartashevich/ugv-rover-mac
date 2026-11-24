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
                if t.batteryLow { Badge(text: "LOW", color: .red) }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Metric(symbol: "cpu", title: "CPU", value: t.cpu.map { "\(Int($0))%" })
                    Metric(symbol: "memorychip", title: "RAM", value: t.ram.map { "\(Int($0))%" })
                }
                GridRow {
                    Metric(symbol: "thermometer.medium", title: "Temp", value: t.temp.map { String(format: "%.0f°C", $0) })
                    Metric(symbol: "wifi", title: "Signal", value: t.rssi.map { "\(Int($0)) dBm" })
                }
                GridRow {
                    Metric(symbol: "film", title: "FPS", value: fps(t))
                    Metric(symbol: "internaldrive", title: "Media", value: storage(t))
                }
            }
        }
        .frame(width: 236)
        .opacity(live ? 1 : 0.55)
        .hudCard()
        .help(live ? "Live data from the rover" : "Waiting for data from the rover")
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

private struct Metric: View {
    let symbol: String
    let title: String
    let value: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).frame(width: 14).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
            Text(value ?? "—").monospacedDigit()
        }
        .font(.caption)
        .lineLimit(1)
    }
}
