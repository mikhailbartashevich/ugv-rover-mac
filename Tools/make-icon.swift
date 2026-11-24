// Renders the app icon: Tools/make-icon.sh → Resources/AppIcon.icns
import SwiftUI
import AppKit

/// A six-wheeled rover with a pan-tilt camera, on a night-teal squircle.
struct RoverIcon: View {
    private let teal = Color(red: 0.24, green: 0.86, blue: 0.62)

    var body: some View {
        ZStack {
            // Squircle background with Big Sur–style margins and shadow.
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.25, blue: 0.31),
                                              Color(red: 0.03, green: 0.08, blue: 0.12)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RadialGradient(colors: [teal.opacity(0.35), .clear], center: .init(x: 0.72, y: 0.22),
                                   startRadius: 10, endRadius: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 186, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 12)

            // Horizon grid
            Canvas { ctx, size in
                var p = Path()
                for i in 0..<6 {
                    let y = 690 + CGFloat(i * i) * 9
                    p.move(to: CGPoint(x: 140, y: y)); p.addLine(to: CGPoint(x: 884, y: y))
                }
                for i in -5...5 {
                    p.move(to: CGPoint(x: 512 + CGFloat(i) * 40, y: 690))
                    p.addLine(to: CGPoint(x: 512 + CGFloat(i) * 150, y: 900))
                }
                ctx.stroke(p, with: .color(teal.opacity(0.18)), lineWidth: 2)
            }
            .frame(width: 1024, height: 1024)
            .mask(RoundedRectangle(cornerRadius: 186, style: .continuous).frame(width: 824, height: 824))

            // Signal arcs
            ForEach(0..<3) { i in
                Circle()
                    .trim(from: 0.62, to: 0.88)
                    .stroke(teal.opacity(0.9 - Double(i) * 0.25), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .frame(width: CGFloat(70 + i * 56), height: CGFloat(70 + i * 56))
                    .position(x: 318, y: 300)
            }

            // Antenna
            Capsule().fill(Color(white: 0.75)).frame(width: 10, height: 190).position(x: 318, y: 440)
            Circle().fill(teal).frame(width: 30, height: 30).position(x: 318, y: 340)
                .shadow(color: teal, radius: 12)

            // Shadow under the rover
            Ellipse().fill(.black.opacity(0.45)).frame(width: 600, height: 60).blur(radius: 14).position(x: 512, y: 735)

            // Camera mast + pan-tilt head
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.55)).frame(width: 34, height: 110).position(x: 600, y: 470)
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.72)], startPoint: .top, endPoint: .bottom))
                .frame(width: 210, height: 118)
                .position(x: 610, y: 380)
            Circle().fill(Color(white: 0.12)).frame(width: 84, height: 84).position(x: 672, y: 380)
            Circle().fill(RadialGradient(colors: [teal, Color(red: 0.05, green: 0.35, blue: 0.4)],
                                         center: .center, startRadius: 2, endRadius: 34))
                .frame(width: 60, height: 60).position(x: 672, y: 380)
                .shadow(color: teal.opacity(0.8), radius: 16)
            Circle().fill(.white.opacity(0.85)).frame(width: 16, height: 16).position(x: 660, y: 368)

            // Chassis
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.14)], startPoint: .top, endPoint: .bottom))
                .frame(width: 560, height: 120)
                .position(x: 512, y: 580)
            RoundedRectangle(cornerRadius: 6).fill(teal).frame(width: 470, height: 12).position(x: 512, y: 548)
                .shadow(color: teal.opacity(0.8), radius: 8)
            // Headlight
            Capsule().fill(Color(red: 1, green: 0.92, blue: 0.6)).frame(width: 18, height: 46).position(x: 785, y: 585)
                .shadow(color: .yellow.opacity(0.9), radius: 14)

            // Six wheels (three visible per side)
            ForEach([330.0, 512.0, 694.0], id: \.self) { x in
                wheel.position(x: x, y: 660)
            }
        }
        .frame(width: 1024, height: 1024)
    }

    private var wheel: some View {
        ZStack {
            Circle().fill(Color(white: 0.07)).frame(width: 156, height: 156)
            ForEach(0..<12) { i in
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.2))
                    .frame(width: 14, height: 26).offset(y: -70).rotationEffect(.degrees(Double(i) * 30))
            }
            Circle().fill(Color(white: 0.55)).frame(width: 74, height: 74)
            Circle().fill(Color(white: 0.3)).frame(width: 30, height: 30)
        }
    }
}

@MainActor
func render(to path: String) throws {
    let renderer = ImageRenderer(content: RoverIcon())
    renderer.scale = 1
    guard let cg = renderer.cgImage else { throw NSError(domain: "icon", code: 1) }
    let rep = NSBitmapImageRep(cgImage: cg)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

try MainActor.assumeIsolated { try render(to: CommandLine.arguments[1]) }
