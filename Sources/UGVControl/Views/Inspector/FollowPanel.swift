import SwiftUI
import AppKit
import RoverKit

/// "Follow the cat" settings, status and the optional Claude assistant.
struct FollowPanel: View {
    @Environment(FollowController.self) private var follow
    @Environment(RoverClient.self) private var rover
    @StateObject private var keyField = KeyFieldState()

    var body: some View {
        @Bindable var follow = follow
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: follow.target.symbol)
                        .font(.title)
                        .foregroundStyle(follow.isActive ? Color.accentColor : .secondary)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(follow.isActive ? follow.phase.title : "Not following").font(.headline)
                        Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Button {
                    follow.toggle()
                } label: {
                    Label(follow.isActive ? "Stop Following" : "Follow the \(follow.target.title)",
                          systemImage: follow.isActive ? "stop.fill" : "pawprint.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(follow.isActive ? .red : .accentColor)
                .controlSize(.large)
                .help(follow.isActive
                      ? "Stop following and brake. Any manual drive key, the STOP button or Space also stops it."
                      : "The rover keeps the \(follow.target.rawValue) in the middle of the camera view and slowly drives closer until it fills the chosen share of the frame. It never reverses. Shortcut: F.")

                Picker("Follow", selection: $follow.target) {
                    ForEach(FollowTarget.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(follow.isActive)
                .help("What to follow. Cats and dogs are found by Apple's on-device image recognition; people by its body detector. Change it while stopped.")
            } footer: {
                Text("Uses the camera feed on this Mac — the rover's own vision modes can stay off. Keep the camera looking straight ahead; following re-centres it when it starts.")
            }

            Section("Behaviour") {
                LabeledContent {
                    HStack {
                        Slider(value: $follow.settings.maxSpeed, in: 0.05...0.3)
                        Text(String(format: "%.2f m/s", follow.settings.maxSpeed)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                } label: { Text("Top speed") }
                .help("The fastest it drives towards the target. 0.10–0.15 m/s is a calm walking pace for a cat; the rover slows down further as it gets close.")

                LabeledContent {
                    HStack {
                        Text("Far").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $follow.settings.targetSize, in: 0.25...0.8)
                        Text("Close").font(.caption).foregroundStyle(.secondary)
                    }
                } label: { Text("Distance") }
                .help("How close to get: the rover stops approaching once the target fills this share of the frame height. Far ≈ a couple of metres, Close ≈ half a metre.")

                LabeledContent {
                    Slider(value: $follow.settings.maxTurn, in: 0.3...1.2)
                } label: { Text("Turn speed") }
                .help("How quickly the rover turns to keep the target centred. Lower is smoother; higher keeps up with a cat that darts sideways.")

                Toggle("Search when lost", isOn: $follow.settings.searchWhenLost)
                    .help("If the target leaves the frame, turn slowly towards where it was last seen (or where Claude says it went) for up to 12 seconds, then wait.")
            }

            claudeSection
        }
        .formStyle(.grouped)
        .onAppear { keyField.refresh() }
    }

    private var statusDetail: String {
        guard follow.isActive else { return "Press F or the paw button to start." }
        if let d = follow.detection {
            let pos = d.box.midX < 0.4 ? "left" : (d.box.midX > 0.6 ? "right" : "centre")
            let src = switch d.source {
            case .claude: " (seen by Claude)"
            case .tracker: " (tracking)"
            default: ""
            }
            return "\(follow.target.title) \(pos), \(Int(d.box.height * 100))% of frame\(src) · \(String(format: "%.2f m/s", follow.command.linear))"
        }
        return follow.phase == .noVideo ? "Waiting for the camera feed." : "No \(follow.target.rawValue) in view."
    }

    // MARK: Claude

    private var claudeSection: some View {
        @Bindable var follow = follow
        let claude = follow.claude
        return Section {
            Picker("Run Claude via", selection: Binding(get: { claude.backend }, set: { claude.backend = $0; keyField.refresh() })) {
                ForEach(ClaudeBackend.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Claude Code: use the Claude Code app installed on this Mac and the Claude account it's signed in with — no API key needed. API Key: call the Anthropic API directly with a key from console.anthropic.com.")

            if claude.backend == .claudeCode {
                if let path = claude.cli.displayPath {
                    Label("Using Claude Code at \(path)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                        .help("Each check runs `claude -p` with the camera frame, tools off, and counts towards your Claude plan's usage. If Claude Code isn't signed in, open Terminal and run `claude` once.")
                } else {
                    Label("Claude Code isn't installed on this Mac.", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                    Button("Install Claude Code…") {
                        NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!)
                    }
                    .help("Open the Claude Code page in your browser. After installing, restart this app.")
                }
            }

            Toggle("Ask Claude for help", isOn: $follow.claudeEnabled)
                .disabled(!claude.isAvailable)
                .help("Every few seconds, show Claude one camera frame. It reports obstacles in the path — the rover then only turns, never drives forward, for 4 seconds — and where the target went when the Mac loses it. Each answer takes about 5 seconds.")

            LabeledContent {
                Stepper(value: $follow.claudeInterval, in: 3...20, step: 1) {
                    Text("every \(Int(follow.claudeInterval)) s").monospacedDigit()
                }
            } label: { Text("Check") }
            .disabled(!follow.claudeEnabled)
            .help("How often to ask Claude while following. While searching it asks twice as often (at most every 2.5 s). Fewer checks use less of your Claude plan or API credits.")

            if let a = follow.advice {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: a.safeToDrive && !a.obstacleAhead ? "checkmark.shield" : "exclamationmark.triangle.fill")
                            .foregroundStyle(a.safeToDrive && !a.obstacleAhead ? Color.green : Color.orange)
                        Text(a.note.isEmpty ? "—" : a.note)
                    }
                    Text("\(a.targetVisible ? "Sees the \(follow.target.rawValue) (\(a.direction.rawValue))" : "Doesn't see the \(follow.target.rawValue)") · \(String(format: "%.1f s", a.latency)) · \(follow.claudeRequests) checks")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .help("Claude's latest look at the camera.")
            }
            if let e = follow.claudeError {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }

            if claude.backend == .api {
                if keyField.hasKey {
                    HStack {
                        Label("API key saved in Keychain", systemImage: "key.fill").foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") {
                            APIKeyStore.delete()
                            keyField.refresh()
                            follow.claudeEnabled = false
                        }
                        .help("Delete the Anthropic API key from this Mac's Keychain.")
                    }
                } else {
                    SecureField("Anthropic API key", text: $keyField.input)
                        .help("Paste an API key from console.anthropic.com. It's stored in your login Keychain and only sent to api.anthropic.com.")
                    HStack {
                        Button("Get a Key…") {
                            NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!)
                        }
                        .help("Open the Anthropic Console in your browser to create an API key.")
                        Spacer()
                        Button("Save Key") {
                            APIKeyStore.save(keyField.input)
                            keyField.input = ""
                            keyField.refresh()
                        }
                        .disabled(keyField.input.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Store the key in the Keychain so “Ask Claude for help” can use it.")
                    }
                }
            }
        } header: {
            Label("Claude", systemImage: "sparkles")
        } footer: {
            Text("Optional. Following works without it; Claude adds obstacle checks and a second pair of eyes. Frames go to Anthropic only while following with this on.")
        }
    }
}

@MainActor
final class KeyFieldState: ObservableObject {
    @Published var input = ""
    @Published var hasKey = false
    func refresh() { hasKey = APIKeyStore.hasKey }
}
