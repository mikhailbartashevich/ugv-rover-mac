import SwiftUI
import RoverKit

struct MainToolbar: ToolbarContent {
    @ObservedObject var window: WindowState
    @Environment(RoverClient.self) private var rover
    @Environment(MJPEGStream.self) private var video

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) { ConnectionPill() }
        ToolbarItem(placement: .principal) { HostField() }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                FrameSaver.save(from: video, rover: rover)
            } label: {
                Label("Save Frame", systemImage: "square.and.arrow.down")
            }
            .help("Save the current frame to Pictures (⌘S)")
            .disabled(video.image == nil)

            Button {
                if video.isRunning { video.stop() } else if let u = rover.videoURL { video.start(url: u) }
            } label: {
                Label(video.isRunning ? "Pause Video" : "Play Video",
                      systemImage: video.isRunning ? "pause.circle" : "play.circle")
            }
            .help(video.isRunning ? "Pause the video stream" : "Start the video stream")

            Button { window.showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Modes, media, network and console (⌥⌘I)")
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
