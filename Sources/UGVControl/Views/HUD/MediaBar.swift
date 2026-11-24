import SwiftUI
import RoverKit

/// Record, photo, zoom and keyboard help (bottom-centre).
struct MediaBar: View {
    @Environment(RoverClient.self) private var rover
    @Environment(FollowController.self) private var follow
    @StateObject private var showKeys = ViewFlag()

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                RecordButton()

                Button { rover.capturePhoto() } label: {
                    Image(systemName: "camera.fill").font(.title2).frame(width: 44, height: 44)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .help("Take a photo with the rover's camera and store it on the rover (P). Browse and download photos in the inspector's Media tab.")

                Button { follow.toggle() } label: {
                    Image(systemName: follow.isActive ? "pawprint.fill" : "pawprint")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(follow.isActive ? .green : .gray.opacity(0.35))
                .help(follow.isActive
                      ? "Following the \(follow.target.rawValue) — \(follow.phase.title.lowercased()). Click (or press F) to stop."
                      : "Follow the \(follow.target.rawValue): the rover finds it in the video and slowly drives after it, keeping it centred. Settings in the inspector's Follow tab. Shortcut: F.")

                Button { rover.cycleZoom() } label: {
                    Text(rover.zoom.title).font(.callout.weight(.semibold).monospacedDigit())
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Digital zoom of the rover's camera: 1× → 2× → 4× (Z). Affects the stream, photos and recordings.")

                Button { showKeys.on.toggle() } label: {
                    Image(systemName: "keyboard").frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Show every keyboard and game-controller shortcut.")
                .popover(isPresented: $showKeys.on, arrowEdge: .top) { KeyboardHelp() }
            }
        }
    }
}

private struct RecordButton: View {
    @Environment(RoverClient.self) private var rover

    var body: some View {
        Button { rover.toggleRecording() } label: {
            HStack(spacing: 6) {
                Image(systemName: rover.isRecording ? "stop.fill" : "record.circle")
                if let since = rover.recordingSince {
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        Text(Duration.seconds(ctx.date.timeIntervalSince(since)).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                    }
                } else {
                    Text("Record")
                }
            }
            .font(.callout.weight(.medium))
            .frame(minWidth: 84, minHeight: 32)
        }
        .buttonStyle(.glassProminent)
        .tint(rover.isRecording ? .red : .gray.opacity(0.35))
        .help(rover.isRecording ? "Stop recording; the video is saved on the rover (R). Find it in the inspector's Media tab." : "Record video to the rover's own storage (R). The timer shows how long it's been recording.")
    }
}

/// The shortcut cheat-sheet shown from the keyboard button.
struct KeyboardHelp: View {
    private let rows: [(String, String)] = [
        ("W A S D  /  ← ↑ ↓ →", "Drive (hold)"),
        ("Space  /  ⌘.", "Stop"),
        ("⇧ + arrows", "Aim camera"),
        ("C", "Look ahead"),
        ("G", "Camera stabilisation"),
        ("1  2  3", "Slow / Middle / Fast"),
        ("P", "Photo on rover"),
        ("R", "Record on rover"),
        ("Z", "Zoom 1× / 2× / 4×"),
        ("L  /  B", "Head / chassis lights"),
        ("⌘S", "Save frame to Mac"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { key, action in
                    GridRow {
                        Text(key).font(.callout.monospaced().weight(.semibold))
                        Text(action).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text("Game Controller").font(.headline)
            Text("Left stick drives, right stick aims the camera. A photo · B stop · X light · Y look ahead · RB record · LB zoom · D-pad ↑↓ speed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 340)
    }
}
