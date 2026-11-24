import Foundation
import Observation

/// Photos and videos stored on the rover (ugv_rpi `/get_photo_names`, `/pictures/…`,
/// `/get_video_names`, `/videos/…`, `/delete_photo`, `/delete_video`).
@MainActor
@Observable
public final class MediaLibrary {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case photos, videos
        public var id: String { rawValue }
        var listPath: String { self == .photos ? "get_photo_names" : "get_video_names" }
        var filePath: String { self == .photos ? "pictures" : "videos" }
        var deletePath: String { self == .photos ? "delete_photo" : "delete_video" }
    }

    public private(set) var photos: [String] = []
    public private(set) var videos: [String] = []
    public private(set) var isLoading = false
    public private(set) var error: String?

    public init() {}

    public func items(_ kind: Kind) -> [String] { kind == .photos ? photos : videos }

    public func url(_ name: String, kind: Kind, base: URL) -> URL {
        base.appendingPathComponent(kind.filePath).appendingPathComponent(name)
    }

    public func refresh(base: URL) async {
        isLoading = true
        defer { isLoading = false }
        do {
            photos = try await list(.photos, base: base)
            videos = try await list(.videos, base: base)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func delete(_ name: String, kind: Kind, base: URL) async {
        var req = URLRequest(url: base.appendingPathComponent(kind.deletePath))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = "filename=\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)".data(using: .utf8)
        _ = try? await URLSession.shared.data(for: req)
        await refresh(base: base)
    }

    /// Downloads to ~/Downloads/UGV Rover/ and returns the local file.
    public func download(_ name: String, kind: Kind, base: URL) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: url(name, kind: kind, base: base))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UGV Rover", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private func list(_ kind: Kind, base: URL) async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent(kind.listPath))
        return (try JSONSerialization.jsonObject(with: data) as? [String]) ?? []
    }
}
