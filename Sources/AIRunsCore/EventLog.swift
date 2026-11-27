import Foundation

/// Where AI Runs keeps its files. Everything lives in `~/.airuns` so the hook
/// helper and the app agree without any configuration. `AIRUNS_HOME`
/// overrides the location (used by tests).
public struct AIRunsPaths: Sendable {
    public let root: URL

    public init(root: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let root {
            self.root = root
        } else if let custom = environment["AIRUNS_HOME"], !custom.isEmpty {
            self.root = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            self.root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".airuns", isDirectory: true)
        }
    }

    public var events: URL { root.appendingPathComponent("events.jsonl") }
    public var sessions: URL { root.appendingPathComponent("sessions.json") }
    public var pins: URL { root.appendingPathComponent("pins.json") }
    public var cursor: URL { root.appendingPathComponent("cursor.json") }
    public var binDirectory: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public var hookHelper: URL { binDirectory.appendingPathComponent("airuns-hook") }

    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}

/// Appends records to the event log. Used by the hook helper; one `write`
/// per record so concurrent hooks do not interleave lines.
public enum EventLogWriter {
    public static func append(_ line: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        var data = line
        data.append(0x0A)
        _ = data.withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
    }
}

/// Reads lines appended to the event log since the last read. Keeps a byte
/// offset so the app can pick up events written while it was not running.
public final class EventLogReader {
    public let url: URL
    public private(set) var offset: UInt64
    private var partial = Data()

    public init(url: URL, offset: UInt64 = 0) {
        self.url = url
        self.offset = offset
    }

    /// Where a new reader has to start so that no line is lost: `offset`, less
    /// the bytes of a trailing line that was read before it was finished.
    /// This, not `offset`, is what belongs in a saved cursor.
    public var resumeOffset: UInt64 {
        let pending = UInt64(partial.count)
        return offset >= pending ? offset - pending : 0
    }

    /// Complete lines written since the last call. A trailing line without a
    /// newline is kept until it is finished.
    /// A bounded recovery read leaves the unread tail to the live reader. If
    /// compaction invalidated the boundary, the live reader handles the new log.
    public func readNewLines(upTo endOffset: UInt64? = nil) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if let endOffset, endOffset > size { return [] }
        let readEnd = min(size, endOffset ?? size)
        if size < offset {
            // The log was truncated or replaced: start over.
            offset = 0
            partial = Data()
        }
        guard readEnd > offset else { return [] }
        try? handle.seek(toOffset: offset)
        let count = Int(min(readEnd - offset, UInt64(Int.max)))
        let chunk = (try? handle.read(upToCount: count)) ?? Data()
        offset += UInt64(chunk.count)

        var buffer = partial + chunk
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        partial = buffer
        return lines
    }

    /// Empties the log once it has been fully read and has grown past
    /// `limit` bytes.
    public func compactIfNeeded(limit: UInt64 = 5_000_000) {
        guard partial.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size >= limit, size == offset
        else { return }
        if (try? Data().write(to: url)) != nil { offset = 0 }
    }
}

/// Small JSON load/save helpers for the app's state files.
public enum JSONFile {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
