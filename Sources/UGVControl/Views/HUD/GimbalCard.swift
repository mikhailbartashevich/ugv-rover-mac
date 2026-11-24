import SwiftUI
import RoverKit

/// Pan-tilt camera: position, aiming buttons, stabilisation and lights (top-right).
struct GimbalCard: View {
    @Environment(RoverClient.self) private var rover

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Camera", systemImage: "web.camera").font(.callout.weight(.medium))
                Spacer()
                if rover.steady { Badge(text: "STEADY") }
            }

            HStack(spacing: 14) {
                PanDial(angle: rover.pan).frame(width: 56, height: 56)
                TiltGauge(angle: rover.tilt).frame(width: 14, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pan  \(Int(rover.pan))°")
                    Text("Tilt  \(Int(rover.tilt))°")
                }
                .font(.caption.monospacedDigit())
                Spacer(minLength: 0)
            }

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    aim("arrow.left", "Pan left (⇧←)") { rover.nudgeGimbal(dx: -10, dy: 0) }
                    aim("arrow.up", "Tilt up (⇧↑)") { rover.nudgeGimbal(dx: 0, dy: 10) }
                    aim("arrow.down", "Tilt down (⇧↓)") { rover.nudgeGimbal(dx: 0, dy: -10) }
                    aim("arrow.right", "Pan right (⇧→)") { rover.nudgeGimbal(dx: 10, dy: 0) }
                    Spacer(minLength: 4)
                    aim("scope", "Look ahead (C)") { rover.lookAhead() }
                    Button { rover.setSteady(!rover.steady) } label: {
                        Image(systemName: "gyroscope").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .tint(rover.steady ? .accentColor : nil)
                    .help(rover.steady ? "Stabilisation on (G)" : "Stabilisation off (G)")
                    LightsMenu()
                }
            }
        }
        .frame(width: 268)
        .hudCard()
    }

    private func aim(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .help(help)
    }
}

/// Head light Off / Auto / On and the chassis lights.
private struct LightsMenu: View {
    @Environment(RoverClient.self) private var rover

    var body: some View {
        Menu {
            Picker("Head Light", selection: Binding(get: { rover.headLight }, set: { rover.setHeadLight($0) })) {
                ForEach(HeadLight.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Chassis Lights", isOn: Binding(get: { rover.chassisLightOn }, set: { rover.setChassisLight($0) }))
        } label: {
            Image(systemName: rover.headLight.symbol).frame(width: 22, height: 22)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .tint(rover.headLight == .off ? nil : .yellow)
        .fixedSize()
        .help("Lights (L toggles the head light, B the chassis lights)")
    }
}
