import SwiftUI
import AppKit
import RoverKit

enum InspectorTab: String, CaseIterable, Identifiable {
    case modes, media, network, console
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .modes: "slider.horizontal.3"
        case .media: "photo.on.rectangle"
        case .network: "network"
        case .console: "terminal"
        }
    }
}

/// View-local state (kept in an ObservableObject because the @State macro needs Xcode).
@MainActor
final class WindowState: ObservableObject {
    @Published var showInspector = false
    @Published var inspectorTab: InspectorTab = .modes
    let keyboard = KeyboardDriver()
    let gamepad = GamepadDriver()

    func open(_ tab: InspectorTab) {
        inspectorTab = tab
        showInspector = true
    }
}

struct ContentView: View {
    @Environment(RoverClient.self) private var rover
    @Environment(NetworkStatus.self) private var net
    @Environment(MJPEGStream.self) private var video
    @StateObject private var window = WindowState()

    var body: some View {
        ZStack {
            VideoView()
                .ignoresSafeArea(.container, edges: .top)
                .releasesFocusOnTap()
            HUDOverlay()
                .padding(16)
        }
        .toolbar { MainToolbar(window: window) }
        .inspector(isPresented: $window.showInspector) {
            InspectorView(tab: $window.inspectorTab)
                .inspectorColumnWidth(min: 340, ideal: 380, max: 480)
        }
        .task { await startUp() }
        .onChange(of: rover.reachable) { _, ok in
            if ok == true, !video.isRunning, let url = rover.videoURL { video.start(url: url) }
        }
    }

    private func startUp() async {
        window.keyboard.start(rover: rover)
        window.gamepad.start(rover: rover)
        // Don't start with the host field focused, or it would swallow driving keys.
        try? await Task.sleep(for: .milliseconds(300))
        NSApp.keyWindow?.makeFirstResponder(nil)

        await rover.connect()
        if rover.reachable != true { window.open(.network) }
        DebugSnapshot.run { name in
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                if let tab = InspectorTab(rawValue: name) { window.open(tab) } else { window.showInspector = false }
            }
        }
        while !Task.isCancelled {
            await net.refresh()
            if rover.reachable != true { await rover.connect() }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

/// Camera feed with the centre reticle.
struct VideoView: View {
    @Environment(MJPEGStream.self) private var video

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.10), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
            if let img = video.image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay { Crosshair() }
            } else {
                ContentUnavailableView {
                    Label("No Video", systemImage: "video.slash")
                } description: {
                    Text(video.error ?? "Connect to the rover to see the camera feed.")
                }
                .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}
