import SwiftUI

extension View {
    /// Glass panel used for every HUD card.
    func hudCard(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    /// Removes keyboard focus from text fields so driving keys work again.
    func releasesFocusOnTap() -> some View {
        contentShape(Rectangle())
            .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
}

/// Small rounded label, e.g. "STEADY".
struct Badge: View {
    let text: String
    var color: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// A boolean owned by a view. Stand-in for `@State`, whose macro needs Xcode.
@MainActor
final class ViewFlag: ObservableObject {
    @Published var on = false
}
