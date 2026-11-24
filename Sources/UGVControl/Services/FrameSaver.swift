import AppKit
import RoverKit

/// Saves the current video frame to ~/Pictures/UGV Rover/ on the Mac.
@MainActor
enum FrameSaver {
    static func save(from video: VideoStream, rover: RoverClient) {
        guard let jpeg = video.currentJPEG else {
            rover.show("No video frame to save", symbol: "video.slash")
            return
        }
        do {
            let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("UGV Rover", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "-")
            let url = dir.appendingPathComponent("Rover \(stamp).jpg")
            try jpeg.write(to: url)
            rover.show("Frame saved to Pictures › UGV Rover", symbol: "photo.badge.checkmark")
        } catch {
            rover.show("Couldn't save frame: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }
}
