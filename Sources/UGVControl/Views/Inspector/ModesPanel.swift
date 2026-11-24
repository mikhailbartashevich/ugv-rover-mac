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
                                .help(mode.helpText)
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
                .help("What the rover does when the active vision mode detects something: nothing, take a photo, or record a video. It triggers at most once every 3 seconds; files land in the Media tab.")
                Toggle("Vision can move camera & wheels", isOn: Binding(get: { !rover.movementLocked }, set: { rover.setMovementLocked(!$0) }))
                    .help("UNLOCK in the rover's web UI. When on, Faces and Color aim the camera at what they track, and Auto Drive follows a line on the floor by driving the wheels. Off (LOCK, the default) means vision only watches.")
            } header: {
                Text("Reactions")
            } footer: {
                Text("Turn “Vision can move” on only in a clear area — Auto Drive will drive by itself.")
            }
            .disabled(!rover.socket.isConnected)

            Section("Driving") {
                Picker("Speed", selection: Binding(get: { rover.speedPreset }, set: { if let p = $0 { rover.setSpeedPreset(p) } })) {
                    ForEach(SpeedPreset.allCases) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .help("Speed presets, as in the rover's web UI: Slow 30 %, Middle 66 %, Fast 100 % of 1.3 m/s. Keys 1 / 2 / 3.")
                HStack(spacing: 12) {
                    Text("Max speed")
                    Slider(value: $rover.speedRate, in: 0.1...1.0)
                        .frame(minWidth: 120)
                        .help("Top driving speed for keyboard, on-screen pad and game controller, 10–100 % of 1.3 m/s.")
                    Text(String(format: "%.2f m/s", rover.maxSpeed))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }

            Section("Camera") {
                Toggle("Stabilisation", isOn: Binding(get: { rover.steady }, set: { rover.setSteady($0) }))
                    .help("Use the rover's IMU to hold the camera's tilt steady over bumps; pan stays straight ahead (G).")
                LabeledContent("Direction") {
                    Button("Look Ahead") { rover.lookAhead() }
                        .help("Point the camera straight forward and level (C).")
                }
                Picker("Zoom", selection: Binding(get: { rover.zoom }, set: { rover.setZoom($0) })) {
                    ForEach(CameraZoom.allCases) { Text($0.title).tag($0) }
                }
                .help("Digital zoom of the rover's camera (Z cycles). Affects the stream, photos and recordings.")
                .pickerStyle(.segmented)
                .disabled(!rover.socket.isConnected)
                Picker("Stream quality", selection: Binding(get: { rover.resolution }, set: { if let r = $0 { rover.setResolution(r) } })) {
                    if rover.resolution == nil { Text("Default").tag(StreamResolution?.none) }
                    ForEach(StreamResolution.allCases) { Text($0.title).tag(Optional($0)) }
                }
                .help("Camera resolution on the rover. Lower is smoother over weak Wi‑Fi and leaves more CPU for vision modes; higher gives sharper photos.")
                .disabled(!rover.socket.isConnected)
            }

            Section("Lights") {
                Picker("Head light", selection: Binding(get: { rover.headLight }, set: { rover.setHeadLight($0) })) {
                    ForEach(HeadLight.allCases) { Text($0.title).tag($0) }
                }
                .help("Head light: Off, Auto (switches on when the vision mode detects something) or On. L toggles it.")
                .pickerStyle(.segmented)
                Toggle("Chassis lights", isOn: Binding(get: { rover.chassisLightOn }, set: { rover.setChassisLight($0) }))
                    .help("The lights on the rover's body (B).")
            }
            .disabled(!rover.socket.isConnected)
        }
        .formStyle(.grouped)
    }
}

extension VisionMode {
    /// Tooltip for each vision mode (behaviour from the rover's cv_ctrl.py).
    var helpText: String {
        switch self {
        case .none: "Turn the rover's computer vision off — saves its CPU and battery."
        case .motion: "Highlight anything that moves in front of the camera."
        case .faces: "Detect faces. With “Vision can move” on, the camera turns to keep the biggest face centred."
        case .objects: "Recognise and label everyday objects (people, cats, cups…) with the rover's object detector."
        case .color: "Track an object of one colour (set in the rover's config). With “Vision can move” on, the camera follows it."
        case .hands: "Recognise hand gestures with MediaPipe."
        case .autoDrive: "Line following: with “Vision can move” on, the rover drives itself along a line on the floor. Use in a clear area."
        case .faceMesh: "MediaPipe face mesh: draws facial landmarks on the video."
        case .pose: "MediaPipe body pose: draws a skeleton on people in view."
        }
    }
}
