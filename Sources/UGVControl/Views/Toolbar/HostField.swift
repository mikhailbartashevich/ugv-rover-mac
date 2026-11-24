import SwiftUI
import RoverKit

/// Rover address field in the middle of the toolbar.
struct HostField: View {
    @Environment(RoverClient.self) private var rover
    @Environment(MJPEGStream.self) private var video

    var body: some View {
        @Bindable var rover = rover
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.secondary)
            TextField("Rover IP", text: $rover.host)
                .textFieldStyle(.plain)
                .frame(width: 150)
                .help("The rover's address. On its own AccessPopup hotspot it's 192.168.50.5; on your Wi‑Fi it's the IP shown on the rover's screen (line “W:”). Add :port if it isn't 5000. Press Return to connect.")
                .onSubmit {
                    connect()
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            Button("Connect", action: connect)
                .buttonStyle(.borderless)
                .help("Connect to the rover at this address: checks its web app, opens the live control channel and restarts the video.")
        }
        .padding(.horizontal, 8)
    }

    private func connect() {
        video.stop()
        Task {
            await rover.connect()
            if rover.reachable == true, let u = rover.videoURL { video.start(url: u) }
        }
    }
}
