import SwiftUI
import RoverKit

/// The rover's command line (`POST /send_command`), like the web UI's input box.
struct ConsolePanel: View {
    @Environment(RoverClient.self) private var rover
    @StateObject private var state = ConsoleState()

    private let presets: [(String, String)] = [
        ("Chassis feedback", #"base -c {"T":130}"#),
        ("IMU data", #"base -c {"T":126}"#),
        ("Wi‑Fi info", #"base -c {"T":405}"#),
        ("OLED: show text", #"base -c {"T":3,"lineNum":0,"Text":"Hello"}"#),
        ("OLED: restore", #"base -c {"T":-3}"#),
        ("Show received data on screen", "base -r on"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if state.log.isEmpty {
                            Text("Commands go to the rover's host program. Most replies appear on the rover's screen or log; this view shows whether the rover accepted them.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                        ForEach(state.log) { e in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(e.ok ? .green : .red)
                                Text(e.command).font(.callout.monospaced()).textSelection(.enabled)
                                Spacer(minLength: 0)
                                Text(e.date, style: .time).font(.caption).foregroundStyle(.tertiary)
                            }
                            .id(e.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: state.log.count) { _, _ in
                    if let last = state.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Menu {
                    ForEach(presets, id: \.1) { title, cmd in
                        Button(title) { state.input = cmd }
                    }
                } label: {
                    Image(systemName: "text.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Insert a common command: chassis feedback, IMU data, Wi‑Fi info, text on the rover's OLED screen, and more.")

                TextField(#"base -c {"T":130}"#, text: $state.input)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit(send)
                    .help("A command for the rover's host program. `base -c {…}` sends JSON straight to the ESP32 controller (see Waveshare's JSON command list). Press Return to send.")

                Button("Send", action: send)
                    .help("Send the command to the rover. The log shows whether the rover accepted it; replies appear on the rover's screen or log.")
                    .disabled(state.input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }

    private func send() {
        let cmd = state.input.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        state.input = ""
        Task {
            let ok = await rover.sendCommandLine(cmd)
            state.log.append(.init(command: cmd, ok: ok, date: Date()))
        }
    }
}

@MainActor
final class ConsoleState: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let command: String
        let ok: Bool
        let date: Date
    }
    @Published var input = ""
    @Published var log: [Entry] = []
}
