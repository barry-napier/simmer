import Foundation
import Observation
import os

/// One line in the debug log.
struct LogLine: Identifiable, Sendable {
    let id: Int
    let text: String
}

/// In-memory debug log shown in the Debug Log window, mirrored to
/// ~/Library/Logs/Simmer/simmer.log and the unified system log.
@MainActor
@Observable
final class Log {
    static let shared = Log()

    private(set) var lines: [LogLine] = []

    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private let maxLines = 1000
    @ObservationIgnored private let maxFileBytes = 2_000_000
    @ObservationIgnored private let logger = Logger(subsystem: "com.barrynapier.simmer", category: "debug")
    @ObservationIgnored private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    let fileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Simmer/simmer.log")

    private init() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func add(_ message: String) {
        let text = "\(timeFormatter.string(from: Date()))  \(message)"
        lines.append(LogLine(id: nextID, text: text))
        nextID += 1
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        logger.info("\(message, privacy: .public)")
        appendToFile(text + "\n")
    }

    /// Clears the window and deletes the log file.
    func clear() {
        lines.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    var allText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    private func appendToFile(_ text: String) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
           size > maxFileBytes {
            try? fm.removeItem(at: fileURL)
        }
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
