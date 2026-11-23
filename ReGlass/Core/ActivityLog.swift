import Foundation
import os

/// ReGlass's own files in Application Support (the activity log, and ReGlassKit's encrypted Meta sign-in cache).
enum Storage {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ReGlass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// A plain-text record of what happened, kept so a problem can be diagnosed after the fact. iOS keeps only
    /// default-level lines in its own on-device log store, so the app's step-by-step `info`/`debug` lines (sign-in,
    /// connecting, the ownership hand-over) never survive a `log collect`. This file keeps them.
    static let eventsFile = directory.appendingPathComponent("events.log")
}

/// What happened, in order. Each line goes to the unified log (`os.Logger`, subsystem "reglass.app") and is
/// appended to `Storage.eventsFile`, so setup and connection steps can be read back after the fact.
/// Never holds tokens, codes, keys or payloads: ReGlassKit withholds them, and ReGlass logs only states.
final class ActivityLog: Sendable {
    private let logger = Logger(subsystem: "reglass.app", category: "activity")
    private let fileLock = NSLock()
    private static let maxFileBytes = 2 * 1024 * 1024

    func add(_ text: String) {
        logger.info("\(text, privacy: .public)")
        appendToFile(text)
    }

    /// The files worth sharing for a diagnosis. Used by Settings and pulled off the device for debugging.
    func shareableFiles() -> [URL] {
        [Storage.eventsFile].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func appendToFile(_ text: String) {
        let stamp = Self.stamp.string(from: Date())
        let entry = Data((stamp + "  " + text + "\n").utf8)
        fileLock.withLock {
            let file = Storage.eventsFile
            // Keep the file bounded: start over once it passes 2 MB, so it never grows without limit.
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
               size > Self.maxFileBytes {
                try? FileManager.default.removeItem(at: file)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: entry)
            } else {
                // No file yet (or it was just reset): create it, readable only after the first unlock.
                try? entry.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            }
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
