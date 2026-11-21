import Foundation

/// Read-only log scanning. Call from a background worker, not from a view body.
/// Each pass has a byte budget; the single atomic cache contains usage metadata
/// and its complete-line checkpoints together, never transcript text.
public struct UsageScanner: Sendable {
    private var roots: [UsageSourceRoot]
    private let cacheURL: URL?
    private let maxLineBytes: Int
    private let discoveryInterval: TimeInterval
    private let discoveryEntryLimit: Int
    private let maxRetainedEvents: Int
    private var files: [String: UsageCachedFile] = [:]
    private var inventory: [String: UsageProvider] = [:]
    private var discoveryIssues: [UsageProvider: Set<UsageIssue>] = [:]
    private var lastDiscovery: Date?
    private var lastSavedAt: Date?
    private var loadedCache = false
    private var cacheDirty = false
    private var buffers: [String: ReadBuffer] = [:]
    private var tailsAtEOF: [String: UInt64] = [:]

    public init(roots: [UsageSourceRoot], cacheURL: URL? = nil,
                maxLineBytes: Int = 8 * 1_024 * 1_024, discoveryInterval: TimeInterval = 60,
                discoveryEntryLimit: Int = 20_000, maxRetainedEvents: Int = 100_000) {
        self.roots = roots
        self.cacheURL = cacheURL
        self.maxLineBytes = max(1, min(maxLineBytes, 8 * 1_024 * 1_024))
        self.discoveryInterval = max(0, discoveryInterval)
        self.discoveryEntryLimit = max(1, min(discoveryEntryLimit, 100_000))
        self.maxRetainedEvents = max(0, min(maxRetainedEvents, 100_000))
    }

    /// Reconfigures selected profiles while retaining still-selected history.
    /// Call on the same background worker that owns this scanner.
    public mutating func updateRoots(_ roots: [UsageSourceRoot]) {
        guard Set(roots.map(\.cacheIdentity)) != Set(self.roots.map(\.cacheIdentity)) else { return }
        self.roots = roots
        files = files.filter { path, state in roots.contains { $0.contains(path: path, provider: state.provider) } }
        buffers = buffers.filter { files[$0.key] != nil }
        tailsAtEOF = tailsAtEOF.filter { files[$0.key] != nil }
        inventory = [:]
        discoveryIssues = [:]
        lastDiscovery = nil
        cacheDirty = true
    }

    public mutating func scan(now: Date = Date(), byteBudget: Int = 16 * 1_024 * 1_024,
                              forceDiscovery: Bool = false) -> UsageScanOutput {
        var passIssues: [UsageProvider: Set<UsageIssue>] = [:]
        loadCacheIfNeeded(issues: &passIssues)
        discoverIfNeeded(now: now, force: forceDiscovery)
        var remaining = max(0, min(byteBudget, 64 * 1_024 * 1_024))
        var scanning = false
        // Recent files are visited first for quick initial feedback. Their
        // modification dates never determine when a token was consumed.
        var infos: [String: UsageFileInfo] = [:]
        for (path, provider) in inventory {
            do { infos[path] = try UsageFileInfo(url: URL(fileURLWithPath: path)) }
            catch { passIssues[provider, default: []].insert(.ioFailure) }
        }
        let ordered = infos.keys.sorted {
            let first = infos[$0]?.modified ?? 0, second = infos[$1]?.modified ?? 0
            return first == second ? $0 < $1 : first > second
        }
        // Rotation or root changes must release old history before capacity is
        // tested, even when a different (newer) file is visited first below.
        var prepared: Set<String> = []
        for path in ordered {
            guard let provider = inventory[path] else { continue }
            do {
                let url = URL(fileURLWithPath: path)
                guard let info = infos[path] else { continue }
                try prepare(path: path, url: url, provider: provider, info: info)
                prepared.insert(path)
            } catch {
                passIssues[provider, default: []].insert(.ioFailure)
            }
        }
        var retainedEvents = files.values.reduce(0) { $0 + $1.parser.retainedEventCount }
        var capacityLimited = false
        for path in ordered where prepared.contains(path) {
            guard let provider = inventory[path], let info = infos[path] else { continue }
            do {
                let url = URL(fileURLWithPath: path)
                guard var state = files[path] else { continue }
                if tailsAtEOF[path] == info.size { continue }
                if state.offset >= info.size && buffers[path] == nil { continue }
                if retainedEvents >= maxRetainedEvents {
                    buffers[path] = nil
                    capacityLimited = true
                    passIssues[provider, default: []].insert(.unsupportedHistory)
                    continue
                }
                if remaining == 0 { scanning = true; continue }
                var limited = false
                scanning = try read(path: path, url: url, info: info, state: &state,
                                    remaining: &remaining, retainedEvents: &retainedEvents,
                                    capacityLimited: &limited) || scanning
                files[path] = state
                if limited {
                    capacityLimited = true
                    passIssues[provider, default: []].insert(.unsupportedHistory)
                }
            } catch {
                passIssues[provider, default: []].insert(.ioFailure)
            }
        }
        // The scanner needs a capacity change, not another byte-budget pass.
        // Reporting scanning here would trigger an endless rapid polling loop.
        if capacityLimited { scanning = false }
        saveIfNeeded(now: now, scanning: scanning, issues: &passIssues)
        return output(now: now, scanning: scanning, passIssues: passIssues)
    }

    private mutating func loadCacheIfNeeded(issues: inout [UsageProvider: Set<UsageIssue>]) {
        guard !loadedCache else { return }
        loadedCache = true
        guard let cacheURL else { return }
        do {
            guard !roots.contains(where: { $0.contains(path: cacheURL.standardizedFileURL.path, provider: $0.provider) })
            else { throw CocoaError(.fileReadUnknown) }
            if let cache = try UsageScanDiskCache.load(from: cacheURL, roots: cacheRoots,
                                                      maximumRetainedEvents: maxRetainedEvents) {
                files = cache.files.filter { path, state in
                    state.parser.provider == state.provider
                        && roots.contains { $0.contains(path: path, provider: state.provider) }
                }
                if files.count != cache.files.count {
                    cacheDirty = true
                    for provider in roots.map(\.provider) { issues[provider, default: []].insert(.ioFailure) }
                }
            }
        } catch UsageScanCacheError.retainedEventLimit {
            cacheDirty = true
            for provider in roots.map(\.provider) { issues[provider, default: []].insert(.unsupportedHistory) }
        } catch {
            for provider in roots.map(\.provider) { issues[provider, default: []].insert(.ioFailure) }
        }
    }

    private var cacheRoots: [String] { Array(Set(roots.map(\.cacheIdentity))).sorted() }

    private mutating func discoverIfNeeded(now: Date, force: Bool) {
        if !force, let lastDiscovery {
            let elapsed = now.timeIntervalSince(lastDiscovery)
            if elapsed >= 0 && elapsed < discoveryInterval { return }
        }
        let discovered = UsageDiscovery.discover(roots, entryLimit: discoveryEntryLimit)
        inventory = discovered.files.filter { path, provider in
            roots.contains { $0.contains(path: path, provider: provider) }
        }
        discoveryIssues = discovered.issues
        for (path, provider) in discovered.files where inventory[path] == nil {
            discoveryIssues[provider, default: []].insert(.unsupportedHistory)
        }
        lastDiscovery = now
        if discovered.complete {
            let retained = files.filter { inventory[$0.key] == $0.value.provider }
            if retained.count != files.count { files = retained; cacheDirty = true }
            buffers = buffers.filter { inventory[$0.key] != nil }
            tailsAtEOF = tailsAtEOF.filter { inventory[$0.key] != nil }
        } else {
            // An incomplete inventory must not erase previously known usage.
            for (path, state) in files where inventory[path] == nil { inventory[path] = state.provider }
        }
    }

    private mutating func prepare(path: String, url: URL, provider: UsageProvider,
                                  info: UsageFileInfo) throws {
        let prior = files[path]
        if let prior, prior.provider == provider, try info.matches(prior, url: url),
           !(prior.prefixLength == 0 && info.size > 0) {
            if prior.observedSize != info.size || prior.modified != info.modified {
                var updated = prior
                updated.observedSize = info.size
                updated.modified = info.modified
                files[path] = updated
                tailsAtEOF[path] = nil
                cacheDirty = true
            }
        } else {
            files[path] = try info.initialState(url: url, provider: provider)
            buffers[path] = nil
            tailsAtEOF[path] = nil
            cacheDirty = true
        }
    }

    private struct ReadBuffer: Sendable {
        var readOffset: UInt64
        var bytes = Data()
        var discarding: Bool
    }

    private mutating func read(path: String, url: URL, info: UsageFileInfo,
                               state: inout UsageCachedFile, remaining: inout Int,
                               retainedEvents: inout Int, capacityLimited: inout Bool) throws -> Bool {
        var buffer = buffers.removeValue(forKey: path)
            ?? ReadBuffer(readOffset: state.offset, discarding: state.discardingOversizedLine)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: buffer.readOffset)
        while remaining > 0 && buffer.readOffset < info.size {
            guard retainedEvents < maxRetainedEvents else {
                capacityLimited = true
                return false
            }
            let amount = min(remaining, 256 * 1_024, Int(min(info.size - buffer.readOffset, UInt64(Int.max))))
            guard let data = try handle.read(upToCount: amount), !data.isEmpty else { break }
            let limited = consumeChunk(data, buffer: &buffer, state: &state, retainedEvents: &retainedEvents)
            remaining -= data.count
            cacheDirty = true
            if limited {
                capacityLimited = true
                return false
            }
        }
        if buffer.readOffset < info.size {
            guard retainedEvents < maxRetainedEvents else {
                capacityLimited = true
                return false
            }
            buffers[path] = buffer
            return true
        }
        if buffer.discarding {
            state.offset = buffer.readOffset
            state.discardingOversizedLine = true
        }
        if !buffer.bytes.isEmpty || buffer.discarding { tailsAtEOF[path] = info.size }
        return false
    }

    private func consumeChunk(_ chunk: Data, buffer: inout ReadBuffer, state: inout UsageCachedFile,
                              retainedEvents: inout Int) -> Bool {
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: 0x0a) {
            guard retainedEvents < maxRetainedEvents else { return true }
            let segment = chunk[start..<newline]
            append(segment, buffer: &buffer, state: &state)
            buffer.readOffset += UInt64(segment.count + 1)
            if !buffer.discarding, !buffer.bytes.isEmpty {
                let previous = state.parser.retainedEventCount
                // Each parser consumes one JSON event and retains at most one
                // new request, incomplete identity, or cumulative snapshot.
                state.parser.consume(buffer.bytes)
                retainedEvents += state.parser.retainedEventCount - previous
            }
            buffer.bytes.removeAll(keepingCapacity: true)
            buffer.discarding = false
            state.offset = buffer.readOffset
            state.discardingOversizedLine = false
            start = chunk.index(after: newline)
        }
        let tail = chunk[start...]
        guard tail.isEmpty || retainedEvents < maxRetainedEvents else { return true }
        append(tail, buffer: &buffer, state: &state)
        buffer.readOffset += UInt64(tail.count)
        if buffer.discarding {
            state.offset = buffer.readOffset
            state.discardingOversizedLine = true
        }
        return false
    }

    private func append(_ bytes: Data.SubSequence, buffer: inout ReadBuffer, state: inout UsageCachedFile) {
        guard !buffer.discarding else { return }
        guard bytes.count <= maxLineBytes - buffer.bytes.count else {
            buffer.bytes.removeAll(keepingCapacity: false)
            buffer.discarding = true
            state.issues.insert(.unsupportedHistory)
            return
        }
        buffer.bytes.append(contentsOf: bytes)
    }

    private mutating func saveIfNeeded(now: Date, scanning: Bool,
                                       issues: inout [UsageProvider: Set<UsageIssue>]) {
        guard cacheDirty, let cacheURL,
              !scanning || lastSavedAt == nil || now.timeIntervalSince(lastSavedAt!) >= 2 else { return }
        do {
            // A caller cannot accidentally turn a selected source into the cache.
            guard inventory[cacheURL.standardizedFileURL.path] == nil else { throw CocoaError(.fileWriteUnknown) }
            try UsageScanDiskCache(roots: cacheRoots, files: files)
                .save(to: cacheURL, maximumRetainedEvents: maxRetainedEvents)
            cacheDirty = false
            lastSavedAt = now
        } catch UsageScanCacheError.retainedEventLimit {
            for provider in roots.map(\.provider) { issues[provider, default: []].insert(.unsupportedHistory) }
        } catch {
            for provider in roots.map(\.provider) { issues[provider, default: []].insert(.ioFailure) }
        }
    }

    private func output(now: Date, scanning: Bool,
                        passIssues: [UsageProvider: Set<UsageIssue>]) -> UsageScanOutput {
        var records: [UsageRecord] = []
        var available: Set<UsageProvider> = []
        var issues = discoveryIssues
        for (provider, values) in passIssues { issues[provider, default: []].formUnion(values) }
        for state in files.values {
            let result = state.parser.result()
            records += result.records
            if !result.records.isEmpty { available.insert(state.provider) }
            issues[state.provider, default: []].formUnion(state.issues)
            issues[state.provider, default: []].formUnion(result.issues)
        }
        return UsageScanOutput(records: records, availableProviders: available, issues: issues,
                               scanning: scanning, refreshedAt: now)
    }
}
