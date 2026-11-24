import Foundation

enum Shell {
    /// Runs a tool and returns its stdout (no shell involved, arguments passed as-is).
    static func run(_ path: String, _ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            p.terminationHandler = { _ in
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: d, encoding: .utf8) ?? "")
            }
            do { try p.run() } catch { cont.resume(returning: "") }
        }
    }

    /// Single-quotes a string for POSIX shells.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
