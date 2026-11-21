import CryptoKit
import Darwin
import Foundation

enum UsageFileParser: Codable, Sendable {
    case codex(CodexUsageParser)
    case claude(ClaudeUsageParser)

    init(provider: UsageProvider) {
        self = provider == .codex ? .codex(CodexUsageParser()) : .claude(ClaudeUsageParser())
    }

    mutating func consume(_ line: Data) {
        switch self {
        case .codex(var parser):
            // Release the enum's old payload before mutating value-type storage.
            // Keeping it alive would copy the whole usage history on every line.
            self = .codex(CodexUsageParser())
            parser.consume(line)
            self = .codex(parser)
        case .claude(var parser):
            self = .claude(ClaudeUsageParser())
            parser.consume(line)
            self = .claude(parser)
        }
    }

    func result() -> UsageParseResult {
        switch self { case .codex(let parser): return parser.result(); case .claude(let parser): return parser.result() }
    }

    var provider: UsageProvider {
        switch self { case .codex: return .codex; case .claude: return .claudeCode }
    }

    var retainedEventCount: Int {
        switch self {
        case .codex(let parser): return parser.retainedEventCount
        case .claude(let parser): return parser.retainedEventCount
        }
    }
}

struct UsageCachedFile: Codable, Sendable {
    var provider: UsageProvider
    var device: UInt64
    var inode: UInt64
    /// Always a complete newline boundary, except while explicitly discarding
    /// an oversized line. No raw transcript fragment is persisted.
    var offset: UInt64 = 0
    var observedSize: UInt64
    var modified: TimeInterval
    var prefixLength: Int
    var prefixDigest: String
    var discardingOversizedLine = false
    var issues: Set<UsageIssue> = []
    var parser: UsageFileParser
}

enum UsageScanCacheError: Error {
    case retainedEventLimit
}

struct UsageScanDiskCache: Codable {
    // Bump when parser accounting changes, not just when the JSON shape changes.
    static let version = 1
    var version = Self.version
    let roots: [String]
    let files: [String: UsageCachedFile]

    static func load(from url: URL, roots: [String], maximumRetainedEvents: Int = 100_000) throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let cache = try decoder.decode(Self.self, from: data)
        guard cache.version == version, cache.roots == roots, cache.files.count <= 5_000,
              cache.files.values.allSatisfy({ $0.offset <= $0.observedSize && (0...256).contains($0.prefixLength)
                  && ($0.prefixDigest.isEmpty || $0.prefixDigest.count == 64) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard withinEventLimit(cache.files, maximum: maximumRetainedEvents) else {
            throw UsageScanCacheError.retainedEventLimit
        }
        return cache
    }

    func save(to url: URL, maximumRetainedEvents: Int = 100_000) throws {
        // Check state before allocating an encoded JSON copy. The byte cap below
        // remains a backstop for unusually large identities or other metadata.
        guard Self.withinEventLimit(files, maximum: maximumRetainedEvents) else {
            throw UsageScanCacheError.retainedEventLimit
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let temporary = parent.appendingPathComponent(".usage-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func withinEventLimit(_ files: [String: UsageCachedFile], maximum: Int) -> Bool {
        var remaining = max(0, min(maximum, 100_000))
        for state in files.values {
            let retained = state.parser.retainedEventCount
            guard retained <= remaining else { return false }
            remaining -= retained
        }
        return true
    }

    private static let maximumBytes = 64 * 1_024 * 1_024
}

struct UsageFileInfo {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modified: TimeInterval

    init(url: URL) throws {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let size = values[.size] as? NSNumber,
              let inode = values[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        self.device = (values[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        self.inode = inode.uint64Value
        self.size = size.uint64Value
        self.modified = (values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }

    func initialState(url: URL, provider: UsageProvider) throws -> UsageCachedFile {
        let length = Int(min(size, 256))
        return UsageCachedFile(provider: provider, device: device, inode: inode, observedSize: size,
                               modified: modified, prefixLength: length, prefixDigest: try Self.digest(url, length: length),
                               parser: UsageFileParser(provider: provider))
    }

    func matches(_ state: UsageCachedFile, url: URL) throws -> Bool {
        guard device == state.device, inode == state.inode, size >= state.offset,
              size >= state.observedSize else { return false }
        // A size-preserving rewrite cannot be an ordinary append.
        if size == state.observedSize && modified != state.modified { return false }
        if size == state.observedSize && modified == state.modified { return true }
        return try Self.digest(url, length: state.prefixLength) == state.prefixDigest
    }

    private static func digest(_ url: URL, length: Int) throws -> String {
        guard length > 0 else { return "" }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: length) ?? Data()
        return SHA256.hash(data: prefix).map { String(format: "%02x", $0) }.joined()
    }
}
