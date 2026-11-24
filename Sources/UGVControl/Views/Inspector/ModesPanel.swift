import SwiftUI
import RoverKit

/// Everything from the stock web UI's right column: vision, reactions, speed,
/// camera, lights, stream quality.
struct ModesPanel: View {
    @Environment(RoverClient.self) private var rover

    var body: some View {
        @Bindable var rover = rover
        Form {
            if !rover.socket.isConnected {
                Section {
                    Label("The control channel is offline, so modes can't be changed. Driving still works.",
                          systemImage: "bolt.horizontal.circle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            Section("Vision") {
                ForEach(VisionMode.Group.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.rawValue).font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(VisionMode.allCases.filter { $0.group == group }) { mode in
                                OptionTile(title: mode.title, symbol: mode.symbol, selected: rover.visionMode == mode) {
                                    rover.setVisionMode(mode)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .disabled(!rover.socket.isConnected)

            Section {
                Picker("On detection", selection: Binding(get: { rover.reaction }, set: { rover.setReaction($0) })) {
                    ForEach(DetectionReaction.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Movement lock", isOn: Binding(get: { rover.movementLocked }, set: { rover.setMovementLocked($0) }))
            } header: {
                Text("Reactions")
            } footer: {
                Text("Movement lock is LOCK / UNLOCK from the rover's web UI.")
            }
            .disabled(!rover.socket.isConnected)

            Section("Driving") {
                Picker("Speed", selection: Binding(get: { rover.speedPreset }, set: { if let p = $0 { rover.setSpeedPreset(p) } })) {
                    ForEach(SpeedPreset.allCases) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 12) {
                    Text("Max speed")
                    Slider(value: $rover.speedRate, in: 0.1...1.0)
                        .frame(minWidth: 120)
                    Text(String(format: "%.2f m/s", rover.maxSpeed))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }

            Section("Camera") {
                Toggle("Stabilisation", isOn: Binding(get: { rover.steady }, set: { rover.setSteady($0) }))
                LabeledContent("Direction") {
                    Button("Look Ahead") { rover.lookAhead() }
                }
                Picker("Zoom", selection: Binding(get: { rover.zoom }, set: { rover.setZoom($0) })) {
                    ForEach(CameraZoom.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!rover.socket.isConnected)
                Picker("Stream quality", selection: Binding(get: { rover.resolution }, set: { if let r = $0 { rover.setResolution(r) } })) {
                    if rover.resolution == nil { Text("Default").tag(StreamResolution?.none) }
                    ForEach(StreamResolution.allCases) { Text($0.title).tag(Optional($0)) }
                }
                .disabled(!rover.socket.isConnected)
            }

            Section("Lights") {
                Picker("Head light", selection: Binding(get: { rover.headLight }, set: { rover.setHeadLight($0) })) {
                    ForEach(HeadLight.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Chassis lights", isOn: Binding(get: { rover.chassisLightOn }, set: { rover.setChassisLight($0) }))
            }
            .disabled(!rover.socket.isConnected)
        }
        .formStyle(.grouped)
    }
}
