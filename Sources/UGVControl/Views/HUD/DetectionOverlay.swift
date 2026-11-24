import SwiftUI
import RoverKit

/// Draws the followed target's box over the video (inside the image's own frame).
struct DetectionOverlay: View {
    @Environment(FollowController.self) private var follow

    var body: some View {
        GeometryReader { geo in
            if follow.isActive, let d = follow.detection {
                let r = CGRect(x: d.box.minX * geo.size.width, y: d.box.minY * geo.size.height,
                               width: d.box.width * geo.size.width, height: d.box.height * geo.size.height)
                let color: Color = switch d.source {
                case .claude: .purple
                case .tracker: .yellow
                default: .green
                }
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(color, lineWidth: 3)
                        .frame(width: r.width, height: r.height)
                    Label("\(d.label) \(Int(d.confidence * 100))%", systemImage: follow.target.symbol)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(color, in: Capsule())
                        .foregroundStyle(.white)
                        .offset(y: -22)
                }
                .offset(x: r.minX, y: r.minY)
                .animation(.easeOut(duration: 0.15), value: d.box)
            }
        }
        .allowsHitTesting(false)
    }
}
