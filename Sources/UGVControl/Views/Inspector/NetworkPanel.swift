import SwiftUI
import AppKit
import RoverKit

@MainActor
final class NetPanelState: ObservableObject {
    @Published var homeSSID = ""
    @Published var homePass = ""
    @Published var sudoPass = ""
    @Published var scanning = false
    @Published var found: [String] = []
    @Published var didScan = false
    @Published var orderMessage: String?
}

struct NetworkPanel: View {
    @Environment(RoverClient.self) private var rover
    @Environment(NetworkStatus.self) private var net
    @Environment(RoverProvisioner.self) private var prov
    @StateObject private var st = NetPanelState()

    var body: some View {
        Form {
            macSection
            setupSection
            findSection
            cableSection
        }
        .formStyle(.grouped)
        .task { await net.loadPreferredNetworks() }
    }

    // MARK: This Mac

    private var macSection: some View {
        Section {
            LabeledContent("Internet") {
                Label(net.internetOK == true ? "Online" : (net.internetOK == nil ? "Checking…" : "Offline"),
                      systemImage: net.internetOK == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(net.internetOK == true ? .green : .red)
            }
            LabeledContent("Default route", value: net.serviceName(for: net.defaultInterface) ?? "—")
            LabeledContent("Rover reachable via") {
                if let i = net.interface(reaching: rover.hostIP) {
                    Text("\(i.service) · \(i.ipv4)")
                } else {
                    Text("No matching interface").foregroundStyle(.orange)
                }
            }
            DisclosureGroup("Interfaces") {
                ForEach(net.interfaces) { i in
                    LabeledContent(i.service, value: "\(i.name) · \(i.ipv4)").font(.caption)
                }
            }
        } header: {
            HStack {
                Text("This Mac")
                Spacer()
                Button { Task { await net.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Re-check this Mac's network connections and internet access now (it also refreshes every 5 seconds).")
            }
        }
    }

    // MARK: One-button setup

    private var setupSection: some View {
        Section {
            if !net.onRoverHotspot && !prov.isRunning && prov.newHost == nil {
                Label {
                    Text("First, join the rover's **AccessPopup** Wi‑Fi (password `1234567890`) from the Wi‑Fi menu. Your internet will drop for about a minute.")
                } icon: {
                    Image(systemName: "1.circle.fill").foregroundStyle(.blue)
                }
                .font(.callout)
            }

            HStack {
                TextField("Home Wi‑Fi name", text: $st.homeSSID)
                    .help("The name (SSID) of the Wi‑Fi the rover should join — usually your home network, or your phone's hotspot when you're out.")
                if !net.preferredNetworks.isEmpty {
                    Menu {
                        ForEach(net.preferredNetworks, id: \.self) { n in
                            Button(n) { st.homeSSID = n }
                        }
                    } label: { Image(systemName: "list.bullet") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Pick from the Wi‑Fi networks this Mac has joined before.")
                }
            }
            SecureField("Home Wi‑Fi password", text: $st.homePass)
                .help("That network's password. It's sent once to the rover to save the network there and is not stored on this Mac. Leave empty for an open network.")
            DisclosureGroup("Advanced") {
                SecureField("Rover sudo password (if required)", text: $st.sudoPass)
                    .help("Only if the rover asks for one: the password of the rover's Linux user, needed to change its network settings.")
                Text("Only needed if the rover's user can't run sudo without a password.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button {
                Task {
                    await prov.run(ssid: st.homeSSID, password: st.homePass, sudoPassword: st.sudoPass,
                                   rover: rover, net: net)
                }
            } label: {
                HStack {
                    if prov.isRunning { ProgressView().controlSize(.small) }
                    Text(prov.isRunning ? "Setting Up…" : "Move Rover to My Wi‑Fi")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(prov.isRunning || st.homeSSID.isEmpty)
            .help("With this Mac on the rover's AccessPopup Wi‑Fi: saves your network on the rover, lets it switch over, puts the Mac back on your Wi‑Fi and finds the rover's new address. Takes about a minute; the rover remembers the network from then on.")

            if !prov.steps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(prov.steps) { s in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            stepIcon(s.state).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).foregroundStyle(s.state == .pending ? .secondary : .primary)
                                if let d = s.detail {
                                    Text(d).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .font(.callout)
            }
            if let e = prov.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let ip = prov.newHost {
                Label("Done! Rover is at \(ip) and your Mac is back online.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        } header: {
            Label("Connect Rover to Home Wi‑Fi", systemImage: "wifi")
        } footer: {
            Text("The rover remembers this network and joins it on every boot. Away from home, it falls back to its AccessPopup hotspot.")
        }
    }

    @ViewBuilder private func stepIcon(_ s: RoverProvisioner.StepState) -> some View {
        switch s {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    // MARK: Find

    private var findSection: some View {
        Section("Find Rover on This Network") {
            HStack {
                Button(st.scanning ? "Scanning…" : "Scan", systemImage: "magnifyingglass") {
                    Task {
                        st.scanning = true; st.found = []; st.didScan = true
                        st.found = await RoverScanner.scan(prefixes: net.localPrefixes)
                        st.scanning = false
                    }
                }
                .disabled(st.scanning)
                .help("Look for a rover on every network this Mac is on, by checking each address for the rover's web app on port 5000. Takes a few seconds.")
                if st.scanning { ProgressView().controlSize(.small) }
            }
            ForEach(st.found, id: \.self) { ip in
                LabeledContent(ip) {
                    Button("Use") { rover.host = ip; Task { await rover.connect() } }
                        .help("Connect to the rover at \(ip).")
                }
            }
            if !st.scanning && st.found.isEmpty && st.didScan {
                Text("No rover found on port 5000.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Cable

    private var cableSection: some View {
        Section {
            Text("Alternative: keep the Mac's Wi‑Fi on AccessPopup and get internet another way — iPhone over USB, Ethernet, or a USB Wi‑Fi dongle. Wi‑Fi must be last in the service order so internet traffic doesn't go to the rover.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent("Service order") {
                Text(net.serviceOrder.joined(separator: " → "))
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
            }
            Button("Move Wi‑Fi to Last", systemImage: "arrow.down.to.line") {
                Task { st.orderMessage = await net.demoteService("Wi-Fi") ?? "Done" }
            }
            .help("Put Wi‑Fi last in macOS's network service order, so internet traffic prefers your cable or iPhone while Wi‑Fi stays connected to the rover. macOS asks for an administrator password. Undo in System Settings › Network › ⋯ › Set Service Order.")
            if let m = st.orderMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Label("Wi‑Fi to Rover, Internet via Cable", systemImage: "cable.connector")
        } footer: {
            Text("Requires an administrator password.")
        }
    }
}
