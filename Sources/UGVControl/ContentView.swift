import SwiftUI
import AppKit

@MainActor
final class ContentUI: ObservableObject {
    @Published var showInspector = false
    let keyboard = KeyboardDriver()
}

struct ContentView: View {
    @Environment(RoverClient.self) private var rover
    @Environment(NetworkStatus.self) private var net
    @Environment(MJPEGStream.self) private var video
    @StateObject private var ui = ContentUI()

    var body: some View {
        ZStack {
            VideoBackground()
                .ignoresSafeArea(.container, edges: .top)
                .contentShape(Rectangle())
                .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
            HUD().padding(20)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { ConnectionPill() }
            ToolbarItem(placement: .principal) { HostField() }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if video.isRunning { video.stop() }
                    else if let u = rover.videoURL { video.start(url: u) }
                } label: {
                    Label(video.isRunning ? "Stop Video" : "Start Video",
                          systemImage: video.isRunning ? "video.fill" : "video.slash")
                }
                .help(video.isRunning ? "Stop video stream" : "Start video stream")

                Button { ui.showInspector.toggle() } label: {
                    Label("Network", systemImage: "network")
                }
                .help("Network & connection setup")
            }
        }
        .inspector(isPresented: $ui.showInspector) {
            NetworkPanel()
                .inspectorColumnWidth(min: 320, ideal: 360, max: 460)
        }
        .task {
            ui.keyboard.start(rover: rover)
            // Don't start with the host field focused, or it would swallow driving keys.
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.keyWindow?.makeFirstResponder(nil)
            await rover.ping()
            if rover.reachable == true, let url = rover.videoURL { video.start(url: url) }
            if rover.reachable != true { ui.showInspector = true }
            while !Task.isCancelled {
                await net.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

// MARK: - Toolbar

struct ConnectionPill: View {
    @Environment(RoverClient.self) private var rover
    @Environment(NetworkStatus.self) private var net

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(roverColor).frame(width: 8, height: 8)
                    .shadow(color: roverColor.opacity(0.8), radius: 3)
                Text(roverText)
            }
            Divider().frame(height: 14)
            Label(net.internetOK == true ? "Internet" : "Offline",
                  systemImage: net.internetOK == true ? "globe" : "wifi.exclamationmark")
                .foregroundStyle(net.internetOK == true ? Color.secondary : Color.orange)
        }
        .font(.callout)
        .padding(.horizontal, 8)
    }

    private var roverColor: Color {
        switch rover.reachable { case true?: .green; case false?: .red; default: .gray }
    }
    private var roverText: String {
        switch rover.reachable { case true?: "Connected"; case false?: "No rover"; default: "Checking…" }
    }
}

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
                .onSubmit { connect(); NSApp.keyWindow?.makeFirstResponder(nil) }
            Button("Connect", action: connect).buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
    }

    private func connect() {
        Task {
            await rover.ping()
            if rover.reachable == true, let u = rover.videoURL { video.start(url: u) }
        }
    }
}

// MARK: - Video

struct VideoBackground: View {
    @Environment(MJPEGStream.self) private var video

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.10), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
            if let img = video.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
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

// MARK: - HUD

struct HUD: View {
    var body: some View {
        VStack {
            HStack(alignment: .top) {
                Spacer()
                GimbalCard()
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 16) {
                DriveCard()
                Spacer()
                ViewThatFits(in: .horizontal) {
                    KeyHints()
                    Color.clear.frame(width: 0, height: 0)
                }
                Spacer()
                StopCard()
            }
        }
    }
}

struct DriveCard: View {
    @Environment(RoverClient.self) private var rover

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(spacing: 6) {
                pad("chevron.up", f: 1, t: 0, key: "W ↑")
                HStack(spacing: 6) {
                    pad("arrow.counterclockwise", f: 0, t: -1, key: "A ←")
                    Image(systemName: "car.side")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: 56)
                    pad("arrow.clockwise", f: 0, t: 1, key: "D →")
                }
                pad("chevron.down", f: -1, t: 0, key: "S ↓")
            }
        }
    }

    private func pad(_ icon: String, f: Int, t: Int, key: String) -> some View {
        let active = (f != 0 && rover.forward == f) || (t != 0 && rover.turn == t)
        return VStack(spacing: 2) {
            Image(systemName: icon).font(.title3.weight(.semibold))
            Text(key).font(.caption2.monospaced()).opacity(0.6)
        }
        .foregroundStyle(active ? Color.white : Color.primary)
        .frame(width: 56, height: 56)
        .glassEffect(active ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 14))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in rover.setDrive(forward: f, turn: t) }
                .onEnded { _ in rover.setDrive(forward: 0, turn: 0) }
        )
    }
}

struct StopCard: View {
    @Environment(RoverClient.self) private var rover

    var body: some View {
        @Bindable var rover = rover
        VStack(alignment: .trailing, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Speed", systemImage: "gauge.with.dots.needle.33percent")
                    Spacer()
                    Text(String(format: "%.2f m/s", rover.maxSpeed))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                Slider(value: $rover.maxSpeed, in: 0.1...1.3, step: 0.05)
            }
            .frame(width: 220)
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))

            Button { rover.emergencyStop() } label: {
                VStack(spacing: 2) {
                    Image(systemName: "stop.fill").font(.title2)
                    Text("STOP").font(.caption.weight(.bold))
                }
                .frame(width: 76, height: 76)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(.red)
            .help("Emergency stop (Space)")
        }
    }
}

struct GimbalCard: View {
    @Environment(RoverClient.self) private var rover

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Camera", systemImage: "camera.metering.center.weighted")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(Int(rover.pan))° / \(Int(rover.tilt))°")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 4) {
                        nudge("arrow.left") { rover.nudgeGimbal(dx: -10, dy: 0) }
                        VStack(spacing: 4) {
                            nudge("arrow.up") { rover.nudgeGimbal(dx: 0, dy: 10) }
                            nudge("scope") { rover.centerGimbal() }
                            nudge("arrow.down") { rover.nudgeGimbal(dx: 0, dy: -10) }
                        }
                        nudge("arrow.right") { rover.nudgeGimbal(dx: 10, dy: 0) }
                    }
                }
                Spacer()
                Button { rover.toggleLights() } label: {
                    Image(systemName: rover.lightsOn ? "lightbulb.max.fill" : "lightbulb")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(rover.lightsOn ? .yellow : nil)
                .help("Lights (L)")
            }
        }
        .frame(width: 220)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func nudge(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 26, height: 22)
        }
        .buttonStyle(.glass)
    }
}

struct KeyHints: View {
    var body: some View {
        HStack(spacing: 14) {
            hint(["W A S D", "← ↑ ↓ →"], "Drive")
            hint(["Space"], "Stop")
            hint(["⇧ + arrows"], "Camera")
            hint(["C"], "Center")
            hint(["L"], "Lights")
        }
        .font(.caption)
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { k in
                Text(k)
                    .font(.caption2.monospaced().weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            }
            Text(label).foregroundStyle(.secondary)
        }
    }
}
