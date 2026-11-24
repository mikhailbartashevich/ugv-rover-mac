import SwiftUI

/// Right-hand inspector: a compact icon tab bar (fits five tabs) and the selected panel.
struct InspectorView: View {
    @Binding var tab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(InspectorTab.allCases) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.symbol).font(.system(size: 15, weight: .medium))
                            Text(t.title).font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .foregroundStyle(tab == t ? Color.accentColor : Color.secondary)
                        .background(tab == t ? Color.accentColor.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(t.help)
                    .accessibilityAddTraits(tab == t ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            switch tab {
            case .modes: ModesPanel()
            case .follow: FollowPanel()
            case .media: MediaPanel()
            case .network: NetworkPanel()
            case .console: ConsolePanel()
            }
        }
    }
}

extension InspectorTab {
    var help: String {
        switch self {
        case .modes: "Modes: the rover's vision modes and reactions, speed, camera, lights and stream quality."
        case .follow: "Follow: make the rover slowly follow a cat, dog or person on its own, optionally with Claude checking for obstacles."
        case .media: "Media: photos and videos stored on the rover — view, download or delete them."
        case .network: "Network: this Mac's connection status, moving the rover onto your Wi‑Fi, and finding the rover on the network."
        case .console: "Console: send raw commands to the rover's host program."
        }
    }
}
