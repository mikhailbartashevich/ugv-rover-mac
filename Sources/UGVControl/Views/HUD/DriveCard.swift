import SwiftUI
import RoverKit

/// Press-and-hold driving pad (bottom-left). Lights up while a key is held.
struct DriveCard: View {
    @Environment(RoverClient.self) private var rover

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(spacing: 6) {
                pad("chevron.up", f: 1, t: 0, key: "W ↑", help: "Drive forward")
                HStack(spacing: 6) {
                    pad("arrow.counterclockwise", f: 0, t: -1, key: "A ←", help: "Spin left on the spot")
                    Image(systemName: "car.side")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: 56)
                    pad("arrow.clockwise", f: 0, t: 1, key: "D →", help: "Spin right on the spot")
                }
                pad("chevron.down", f: -1, t: 0, key: "S ↓", help: "Drive backward")
            }
        }
    }

    private func pad(_ icon: String, f: Int, t: Int, key: String, help: String) -> some View {
        let active = (f != 0 && rover.forward == f) || (t != 0 && rover.turn == t)
        return VStack(spacing: 2) {
            Image(systemName: icon).font(.title3.weight(.semibold))
            Text(key).font(.caption2.monospaced()).opacity(0.6)
        }
        .foregroundStyle(active ? Color.white : Color.primary)
        .frame(width: 56, height: 56)
        .glassEffect(active ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 14))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in rover.setDrive(forward: f, turn: t) }
                .onEnded { _ in rover.setDrive(forward: 0, turn: 0) }
        )
        .help("\(help) while you hold this (or the key shown); release to stop. Hold two keys, e.g. W + A, to drive in an arc. Speed follows the Slow / Middle / Fast setting.")
        .accessibilityLabel(help)
        .accessibilityAddTraits(.isButton)
    }
}
