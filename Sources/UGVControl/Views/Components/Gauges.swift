import SwiftUI

/// Battery icon filled to `fraction`, red when low.
struct BatteryGlyph: View {
    let fraction: Double?
    let low: Bool

    var body: some View {
        let f = fraction ?? 0
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).stroke(.primary.opacity(0.5), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(low ? Color.red : (f > 0.5 ? Color.green : Color.yellow))
                    .frame(width: max(0, 22 * f))
                    .padding(2)
                    .opacity(fraction == nil ? 0 : 1)
            }
            .frame(width: 26, height: 12)
            RoundedRectangle(cornerRadius: 1).fill(.primary.opacity(0.5)).frame(width: 2, height: 5)
        }
        .accessibilityLabel(fraction.map { "Battery \(Int($0 * 100)) percent" } ?? "Battery unknown")
    }
}

/// Top-down pan indicator: a dial with a needle at the pan angle (0° = straight ahead).
struct PanDial: View {
    let angle: Double

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.2), lineWidth: 1.5)
            ForEach([-90.0, 0, 90, 180], id: \.self) { a in
                Capsule().fill(.primary.opacity(0.35)).frame(width: 1.5, height: 5)
                    .offset(y: -24).rotationEffect(.degrees(a))
            }
            Capsule().fill(Color.accentColor).frame(width: 3, height: 22)
                .offset(y: -11)
                .rotationEffect(.degrees(angle))
            Circle().fill(.primary).frame(width: 6, height: 6)
        }
        .animation(.snappy, value: angle)
        .accessibilityLabel("Pan \(Int(angle)) degrees")
    }
}

/// Vertical tilt scale from −30° to 90° with a marker.
struct TiltGauge: View {
    let angle: Double
    var range: ClosedRange<Double> = -30...90

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let pos = (range.upperBound - angle) / (range.upperBound - range.lowerBound) * h
            let zero = range.upperBound / (range.upperBound - range.lowerBound) * h
            ZStack(alignment: .top) {
                Capsule().fill(.primary.opacity(0.15)).frame(width: 4)
                Rectangle().fill(.primary.opacity(0.4)).frame(width: 10, height: 1).offset(y: zero)
                Capsule().fill(Color.accentColor).frame(width: 12, height: 4).offset(y: pos - 2)
            }
            .frame(maxWidth: .infinity)
        }
        .animation(.snappy, value: angle)
        .accessibilityLabel("Tilt \(Int(angle)) degrees")
    }
}

/// Thin centre reticle over the video, like the stock web UI.
struct Crosshair: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var p = Path()
            p.move(to: CGPoint(x: c.x - 70, y: c.y)); p.addLine(to: CGPoint(x: c.x - 12, y: c.y))
            p.move(to: CGPoint(x: c.x + 12, y: c.y)); p.addLine(to: CGPoint(x: c.x + 70, y: c.y))
            p.move(to: CGPoint(x: c.x, y: c.y + 8)); p.addLine(to: CGPoint(x: c.x, y: c.y + 18))
            ctx.stroke(p, with: .color(.white.opacity(0.55)), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
        .shadow(color: .black.opacity(0.4), radius: 1)
    }
}
