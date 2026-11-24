import SwiftUI
import RoverKit

/// Short confirmation messages ("Photo saved on rover"…).
struct ToastView: View {
    @Environment(RoverClient.self) private var rover

    var body: some View {
        ZStack {
            if let t = rover.toast {
                Label(t.text, systemImage: t.symbol)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(t.id)
            }
        }
        .animation(.snappy, value: rover.toast)
        .allowsHitTesting(false)
    }
}
