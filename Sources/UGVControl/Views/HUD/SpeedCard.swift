import SwiftUI
import RoverKit

/// Speed presets + fine slider and the emergency stop (bottom-right).
struct SpeedCard: View {
    @Environment(RoverClient.self) private var rover

    var body: some View {
        @Bindable var rover = rover
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Speed", systemImage: "gauge.with.dots.needle.50percent")
                    Spacer()
                    Text(String(format: "%.2f m/s", rover.maxSpeed))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                Picker("Speed preset", selection: Binding(get: { rover.speedPreset }, set: { if let p = $0 { rover.setSpeedPreset(p) } })) {
                    ForEach(SpeedPreset.allCases) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Speed presets, as in the rover's web UI: Slow 30 %, Middle 66 %, Fast 100 % of the 1.3 m/s top speed. Keys 1 / 2 / 3.")
                Slider(value: $rover.speedRate, in: 0.1...1.0)
                    .help("Fine-tune the top driving speed from 10 % to 100 %. Applies to the keyboard, the on-screen pad and a game controller (not to Follow, which has its own limit).")
            }
            .frame(width: 230)
            .hudCard()

            Button { rover.emergencyStop() } label: {
                VStack(spacing: 2) {
                    Image(systemName: "stop.fill").font(.title2)
                    Text("STOP").font(.caption.weight(.bold))
                }
                .frame(width: 72, height: 72)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(.red)
            .help("Emergency stop: brakes the wheels at once, ends Follow, and repeats the stop over HTTP in case the live channel is down. Keys: Space or ⌘.")
        }
    }
}
