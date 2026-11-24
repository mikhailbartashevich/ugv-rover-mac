import SwiftUI
import RoverKit

/// Glass cards floating over the video. Falls back to a stacked layout when the
/// window (or the space left by the inspector) is narrow.
struct HUDOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                TelemetryCard()
                ViewThatFits(in: .horizontal) {
                    StatusChips().frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
                GimbalCard()
            }

            Spacer(minLength: 0)

            ToastView()

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 16) {
                    DriveCard()
                    Spacer(minLength: 0)
                    MediaBar()
                    Spacer(minLength: 0)
                    SpeedCard()
                }
                HStack(alignment: .bottom, spacing: 16) {
                    DriveCard()
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 12) {
                        MediaBar()
                        SpeedCard()
                    }
                }
            }
        }
    }
}
