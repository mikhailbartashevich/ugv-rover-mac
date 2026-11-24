import SwiftUI
import AppKit
import RoverKit

@main
struct UGVControlApp: App {
    // The App value is created once, so plain lets are fine here
    // (SwiftUI's @State macro isn't available with Command Line Tools only).
    private let rover: RoverClient
    private let net = NetworkStatus()
    private let video: MJPEGStream
    private let media = MediaLibrary()
    private let provisioner = RoverProvisioner()
    private let cameraSetup = CameraSetup()
    private let follow: FollowController

    init() {
        // A plain SwiftPM binary needs this to get a Dock icon and a key window.
        NSApplication.shared.setActivationPolicy(.regular)
        let rover = RoverClient()
        let video = MJPEGStream()
        self.rover = rover
        self.video = video
        follow = FollowController(rover: rover, video: video, claude: ClaudeVision(apiKey: { APIKeyStore.load() }))
    }

    var body: some Scene {
        WindowGroup("UGV Control") {
            ContentView()
                .environment(rover)
                .environment(net)
                .environment(video)
                .environment(media)
                .environment(provisioner)
                .environment(follow)
                .environment(cameraSetup)
                .frame(minWidth: 920, minHeight: 620)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 800)
        .commands { RoverCommands(rover: rover, video: video, follow: follow) }
    }
}
