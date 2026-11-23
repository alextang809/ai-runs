import Foundation

/// Desktop rollouts can omit all shell environment fields. Only the header is
/// needed. A terminal explicitly reported by a later hook always takes priority.
@MainActor
enum CodexDesktopOrigin {
    private final class Entry {
        let isDesktop: Bool
        let expires: Date
        init(result: Bool?) {
            isDesktop = result ?? false
            // A missing or partial header can become readable while Codex starts.
            expires = result == nil ? Date().addingTimeInterval(15) : .distantFuture
        }
    }

    private static let results: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 256
        return cache
    }()

    static func matches(path: String, sessionID: String) -> Bool {
        let key = "\(sessionID)\n\(path)" as NSString
        if let cached = results.object(forKey: key), cached.expires > Date() { return cached.isDesktop }
        let entry = Entry(result: readHeader(path: path, sessionID: sessionID))
        results.setObject(entry, forKey: key)
        return entry.isDesktop
    }

    private static func readHeader(path: String, sessionID: String) -> Bool? {
        let url = URL(fileURLWithPath: path)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 131_072),
              let first = data.split(separator: 10, maxSplits: 1).first,
              let record = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
              record["type"] as? String == "session_meta", let payload = record["payload"] as? [String: Any],
              payload["id"] as? String == sessionID, let origin = payload["originator"] as? String else { return nil }
        return origin == "Codex Desktop"
    }
}
