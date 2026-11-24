import AppKit

/// Development aid: with `UGV_SNAPSHOT=/path/prefix` set, the app writes PNGs of its
/// main window after launch (one per `UGV_SNAPSHOT_TABS`, e.g. "hud,modes,media"),
/// so the layout can be checked without anyone looking at the screen.
@MainActor
enum DebugSnapshot {
    static var prefix: String? { ProcessInfo.processInfo.environment["UGV_SNAPSHOT"] }

    static var tabs: [String] {
        (ProcessInfo.processInfo.environment["UGV_SNAPSHOT_TABS"] ?? "hud")
            .split(separator: ",").map(String.init)
    }

    /// Calls `show(tab)` for each requested tab, then saves the window.
    static func run(show: @escaping (String) -> Void) {
        guard let prefix else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            for tab in tabs {
                show(tab)
                try? await Task.sleep(for: .seconds(2.5))
                save(to: "\(prefix)-\(tab).png")
            }
            if ProcessInfo.processInfo.environment["UGV_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
        }
    }

    private static func save(to path: String) {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
