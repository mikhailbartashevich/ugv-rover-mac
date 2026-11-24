import SwiftUI

/// Right-hand inspector with four tabs.
struct InspectorView: View {
    @Binding var tab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            switch tab {
            case .modes: ModesPanel()
            case .media: MediaPanel()
            case .network: NetworkPanel()
            case .console: ConsolePanel()
            }
        }
    }
}
