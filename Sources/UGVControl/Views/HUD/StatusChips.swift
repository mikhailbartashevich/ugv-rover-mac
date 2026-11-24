import SwiftUI
import RoverKit

/// What's active right now: recording, vision mode, reaction, zoom… (top-centre).
struct StatusChips: View {
    @Environment(RoverClient.self) private var rover

    var body: some View {
        let chips = items
        if !chips.isEmpty {
            HStack(spacing: 6) {
                ForEach(chips, id: \.text) { c in
                    Label(c.text, systemImage: c.symbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(c.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                }
            }
            .fixedSize()
        }
    }

    private struct Chip { let text: String; let symbol: String; let color: Color }

    private var items: [Chip] {
        var out: [Chip] = []
        if !rover.socket.isConnected && rover.reachable == true {
            out.append(Chip(text: "Control channel reconnecting", symbol: "bolt.horizontal.circle", color: .orange))
        }
        if rover.telemetry.batteryLow {
            out.append(Chip(text: "Battery low", symbol: "battery.25percent", color: .red))
        }
        if rover.visionMode != .none {
            out.append(Chip(text: rover.visionMode.title, symbol: rover.visionMode.symbol, color: .primary))
        }
        if rover.reaction != .none {
            out.append(Chip(text: "On detect: \(rover.reaction.title)", symbol: rover.reaction.symbol, color: .primary))
        }
        if rover.movementLocked {
            out.append(Chip(text: "Locked", symbol: "lock.fill", color: .primary))
        }
        if rover.zoom != .x1 {
            out.append(Chip(text: "Zoom \(rover.zoom.title)", symbol: "plus.magnifyingglass", color: .primary))
        }
        return out
    }
}
