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
                .onSubmit {
                    connect()
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            Button("Connect", action: connect)
                .buttonStyle(.borderless)
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
