import SwiftUI
import RoverKit

struct MainToolbar: ToolbarContent {
    @ObservedObject var window: WindowState
    @Environment(RoverClient.self) private var rover
    @Environment(VideoStream.self) private var video

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) { ConnectionPill() }
        ToolbarItem(placement: .principal) { HostField() }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                FrameSaver.save(from: video, rover: rover)
            } label: {
                Label("Save Frame", systemImage: "square.and.arrow.down")
            }
            .help("Save the current camera frame as a JPEG to Pictures › UGV Rover on this Mac (⌘S). Unlike the camera button below, nothing is stored on the rover.")
            .disabled(!video.hasFrame)

            Button {
                if video.isRunning { video.stop() } else if let u = rover.videoURL { video.start(url: u) }
            } label: {
                Label(video.isRunning ? "Pause Video" : "Play Video",
                      systemImage: video.isRunning ? "pause.circle" : "play.circle")
            }
            .help(video.isRunning ? "Pause the live camera stream to save Wi‑Fi bandwidth and CPU. Driving and telemetry keep working." : "Start the live camera stream from the rover.")

            Button { window.showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide the side panel: vision modes and settings, Follow, photos and videos on the rover, network setup, and the command console (⌥⌘I).")
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
