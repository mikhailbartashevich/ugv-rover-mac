import SwiftUI
import RoverKit

/// Rover link + Mac internet status, left of the toolbar.
struct ConnectionPill: View {
    @Environment(RoverClient.self) private var rover
    @Environment(NetworkStatus.self) private var net

    private enum Link { case checking, offline, limited, live }

    private var link: Link {
        switch (rover.reachable, rover.socket.isConnected) {
        case (nil, _): .checking
        case (false?, _): .offline
        case (true?, false): .limited
        case (true?, true): .live
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.8), radius: 3)
                Text(title)
            }
            .help(help)
            Divider().frame(height: 14)
            Label(net.internetOK == true ? "Internet" : "Offline",
                  systemImage: net.internetOK == true ? "globe" : "wifi.exclamationmark")
                .foregroundStyle(net.internetOK == true ? Color.secondary : Color.orange)
                .help(net.internetOK == true ? "This Mac is online" : "This Mac has no internet right now")
        }
        .font(.callout)
        .padding(.horizontal, 8)
    }

    private var color: Color {
        switch link { case .checking: .gray; case .offline: .red; case .limited: .orange; case .live: .green }
    }
    private var title: String {
        switch link { case .checking: "Checking…"; case .offline: rover.isSearching ? "Searching…" : "No rover"; case .limited: "Limited"; case .live: "Connected" }
    }
    private var help: String {
        switch link {
        case .checking: "Looking for the rover…"
        case .offline: rover.isSearching
            ? "Looking for the rover: its saved address, its .local name, its own hotspot (192.168.50.5) and every address on this Mac's networks."
            : "No rover at \(rover.host). The app keeps retrying and searches the network every 15 s. Details: \(rover.lastError ?? "no answer")"
        case .limited: "Driving works over HTTP, but the live control channel (telemetry, modes) is reconnecting."
        case .live: "Connected to \(rover.host)"
        }
    }
}
