import SwiftUI
import RoverKit

/// The "Rover" menu. Single-key shortcuts (WASD, Space…) are handled by
/// KeyboardDriver; the menu carries the ⌘ shortcuts.
struct RoverCommands: Commands {
    let rover: RoverClient
    let video: MJPEGStream
    let follow: FollowController

    var body: some Commands {
        CommandMenu("Rover") {
            Button("Emergency Stop") { rover.emergencyStop() }
                .keyboardShortcut(".", modifiers: .command)

            Divider()

            Button("Take Photo on Rover") { rover.capturePhoto() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Start / Stop Recording") { rover.toggleRecording() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Save Frame to Mac") { FrameSaver.save(from: video, rover: rover) }
                .keyboardShortcut("s", modifiers: .command)

            Button("Follow Target On / Off") { follow.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])

            Divider()

            Menu("Speed") {
                ForEach(SpeedPreset.allCases) { p in
                    Button(p.title) { rover.setSpeedPreset(p) }
                }
            }
            Button("Look Ahead") { rover.lookAhead() }
            Button("Toggle Head Light") { rover.toggleHeadLight() }
            Button("Cycle Zoom") { rover.cycleZoom() }

            Divider()

            Button("Reconnect") { Task { await rover.connect() } }
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}
