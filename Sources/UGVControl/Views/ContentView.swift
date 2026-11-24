import SwiftUI
import AppKit
import AVFoundation
import RoverKit

enum InspectorTab: String, CaseIterable, Identifiable {
    case modes, follow, media, network, console
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .modes: "slider.horizontal.3"
        case .follow: "pawprint"
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
    @Environment(VideoStream.self) private var video
    @Environment(FollowController.self) private var follow
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
        window.keyboard.start(rover: rover, follow: follow)
        window.gamepad.start(rover: rover)
        // Don't start with the host field focused, or it would swallow driving keys.
        try? await Task.sleep(for: .milliseconds(300))
        NSApp.keyWindow?.makeFirstResponder(nil)

        await net.refresh()
        await rover.connectOrDiscover(localPrefixes: net.localPrefixes)
        if rover.reachable != true { window.open(.network) }
        DebugSnapshot.run { name in
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                if name == "following" {
                    window.showInspector = false
                    follow.start()
                } else if let tab = InspectorTab(rawValue: name) {
                    window.open(tab)
                } else {
                    window.showInspector = false
                }
            }
        }
        // Keep the link alive: retry every 5 s, and search the network again every 15 s
        // (e.g. after the Mac or the rover changes Wi‑Fi).
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            await net.refresh()
            tick += 1
            guard rover.reachable != true else { continue }
            if tick % 3 == 0 {
                await rover.connectOrDiscover(localPrefixes: net.localPrefixes)
            } else {
                await rover.connect()
            }
        }
    }
}

/// Camera feed with the centre reticle.
struct VideoView: View {
    @Environment(VideoStream.self) private var video

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.10), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
            VideoLayerView(layer: video.displayLayer)
                .aspectRatio(video.videoSize, contentMode: .fit)
                .opacity(video.hasFrame ? (video.isReconnecting ? 0.4 : 1) : 0)
            if video.hasFrame {
                Color.clear
                    .aspectRatio(video.videoSize, contentMode: .fit)
                    .overlay { Crosshair() }
                    .overlay {
                        if video.isReconnecting {
                            Label("Reconnecting video…", systemImage: "arrow.triangle.2.circlepath")
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .glassEffect(.regular, in: .capsule)
                                .help("The video stream dropped (for example while the rover's program restarts). The app retries every 2 seconds.")
                        }
                    }
                    .overlay { DetectionOverlay() }
            } else {
                ContentUnavailableView {
                    Label(video.isRunning ? "Starting Video…" : "No Video", systemImage: video.isRunning ? "video" : "video.slash")
                } description: {
                    Text(video.error ?? (video.isRunning
                        ? "Waiting for the camera's next keyframe — this can take up to 8 seconds."
                        : "Connect to the rover to see the camera feed."))
                }
                .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

/// Hosts the stream's `AVSampleBufferDisplayLayer`, which shows each decoded frame
/// as soon as it arrives, without going through SwiftUI.
struct VideoLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> LayerHostView {
        let v = LayerHostView()
        v.hosted = layer
        return v
    }

    func updateNSView(_ v: LayerHostView, context: Context) {
        if v.hosted !== layer { v.hosted = layer }
    }

    final class LayerHostView: NSView {
        var hosted: CALayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let hosted { layer?.addSublayer(hosted) }
                needsLayout = true
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}
