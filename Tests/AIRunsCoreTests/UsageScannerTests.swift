import Foundation
import XCTest
@testable import AIRunsCore

final class UsageScannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func record(_ id: String, input: Int = 11, content: String = "Sample text") throws -> Data {
        let row: [String: Any] = [
            "type": "assistant", "sessionId": "sample-session", "requestId": "request-\(id)",
            "timestamp": "2026-11-19T12:00:00Z",
            "message": ["id": "message-\(id)", "model": "sample-model", "stop_reason": "end_turn",
                        "usage": ["input_tokens": input, "output_tokens": 5,
                                  "cache_read_input_tokens": 3, "cache_creation_input_tokens": 2],
                        "content": [["type": "text", "text": content]]],
        ]
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        data.append(0x0a)
        return data
    }

    private func completed(_ scanner: inout UsageScanner, budget: Int = 128) -> UsageScanOutput {
        var output = scanner.scan(now: now, byteBudget: budget)
        for _ in 0..<500 where output.scanning {
            output = scanner.scan(now: now, byteBudget: budget)
        }
        XCTAssertFalse(output.scanning, "The bounded scan must make progress")
        return output
    }

    func testBudgetedScanMakesProgressAndCachesOnlyUsageMetadata() throws {
        let root = try folder(), cache = root.appendingPathComponent("cache.json")
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("sample.jsonl")
        try (record("one", content: "SYNTHETIC PRIVATE CONTENT") + record("two")).write(to: file)
        var scanner = UsageScanner(roots: [.init(provider: .claudeCode, url: logs)], cacheURL: cache)
        let first = scanner.scan(now: now, byteBudget: 17)
        XCTAssertTrue(first.scanning)
        let output = completed(&scanner, budget: 17)
        XCTAssertEqual(output.records.count, 2)
        XCTAssertEqual(output.availableProviders, [.claudeCode])
        let cacheText = try String(contentsOf: cache, encoding: .utf8)
        XCTAssertFalse(cacheText.contains("SYNTHETIC PRIVATE CONTENT"))
        XCTAssertFalse(cacheText.contains("Sample text"))
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAppendAndRestartAreIdempotent() throws {
        let root = try folder(), logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("sample.jsonl"), cache = root.appendingPathComponent("cache.json")
        try record("one").write(to: file)
        let roots = [UsageSourceRoot(provider: .claudeCode, url: logs)]
        var scanner = UsageScanner(roots: roots, cacheURL: cache)
        XCTAssertEqual(completed(&scanner).records.count, 1)
        var restarted = UsageScanner(roots: roots, cacheURL: cache)
        XCTAssertEqual(completed(&restarted).records.count, 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: record("two"))
        try handle.close()
        XCTAssertEqual(completed(&restarted).records.count, 2)
        XCTAssertEqual(completed(&restarted).records.count, 2)
        var again = UsageScanner(roots: roots, cacheURL: cache)
        XCTAssertEqual(completed(&again).records.count, 2)
    }

    func testIncompleteTailIsNotPersistedAndCanCompleteAfterRestart() throws {
        let root = try folder(), logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("sample.jsonl"), cache = root.appendingPathComponent("cache.json")
        let row = try record("one", content: "SYNTHETIC SECRET TAIL")
        try row.dropLast().write(to: file)
        let roots = [UsageSourceRoot(provider: .claudeCode, url: logs)]
        var scanner = UsageScanner(roots: roots, cacheURL: cache)
        XCTAssertTrue(completed(&scanner).records.isEmpty)
        XCTAssertFalse(try String(contentsOf: cache, encoding: .utf8).contains("SYNTHETIC SECRET TAIL"))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0a]))
        try handle.close()
        var restarted = UsageScanner(roots: roots, cacheURL: cache)
        XCTAssertEqual(completed(&restarted).records.count, 1)
    }

    func testTruncationAndSameSizeReplacementDiscardOldContributions() throws {
        let root = try folder(), file = root.appendingPathComponent("sample.jsonl")
        try (record("one") + record("two")).write(to: file)
        var scanner = UsageScanner(roots: [.init(provider: .claudeCode, url: root)])
        XCTAssertEqual(completed(&scanner).records.count, 2)
        try record("new", input: 17).write(to: file)
        let truncated = completed(&scanner)
        XCTAssertEqual(truncated.records.count, 1)
        XCTAssertEqual(truncated.records[0].counts.total, 27)
        try record("alt", input: 19).write(to: file)
        let replaced = completed(&scanner)
        XCTAssertEqual(replaced.records.count, 1)
        XCTAssertEqual(replaced.records[0].counts.total, 29)
    }

    func testMissingRootsAndUsageFreeFilesAreUnavailableRatherThanMeasuredZero() throws {
        let root = try folder()
        try Data("{\"type\":\"user\"}\n".utf8).write(to: root.appendingPathComponent("sample.jsonl"))
        var scanner = UsageScanner(roots: [.init(provider: .claudeCode, url: root),
                                          .init(provider: .codex, url: root.appendingPathComponent("missing"))])
        let output = completed(&scanner)
        XCTAssertTrue(output.records.isEmpty)
        XCTAssertTrue(output.availableProviders.isEmpty)
    }

    func testOversizedLineCannotStallTheScan() throws {
        let root = try folder(), file = root.appendingPathComponent("sample.jsonl")
        var bytes = Data(repeating: 0x78, count: 2_048)
        bytes.append(0x0a)
        bytes.append(try record("one"))
        try bytes.write(to: file)
        var scanner = UsageScanner(roots: [.init(provider: .claudeCode, url: root)], maxLineBytes: 512)
        let output = completed(&scanner, budget: 73)
        XCTAssertEqual(output.records.count, 1)
        XCTAssertTrue(output.issues[.claudeCode, default: []].contains(.unsupportedHistory))
    }

    func testNestedLinksAreSkippedButExplicitRootLinksWork() throws {
        let root = try folder(), logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try record("one").write(to: logs.appendingPathComponent("sample.jsonl"))
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("loop"), withDestinationURL: logs)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: logs)
        var scanner = UsageScanner(roots: [.init(provider: .claudeCode, url: alias),
                                          .init(provider: .claudeCode, url: logs)])
        XCTAssertEqual(completed(&scanner).records.count, 1)
    }

    func testDiscoveryIsThrottledAndCanBeExplicitlyRefreshed() throws {
        let root = try folder()
        try record("one").write(to: root.appendingPathComponent("one.jsonl"))
        var scanner = UsageScanner(roots: [.init(provider: .claudeCode, url: root)])
        XCTAssertEqual(completed(&scanner).records.count, 1)
        try record("two").write(to: root.appendingPathComponent("two.jsonl"))
        XCTAssertEqual(completed(&scanner).records.count, 1)
        let refreshed = scanner.scan(now: now, forceDiscovery: true)
        XCTAssertEqual(refreshed.records.count, 2)
    }

    func testCorruptCacheRebuildsWithoutTrustingStoredContributions() throws {
        let root = try folder(), logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try record("one").write(to: logs.appendingPathComponent("sample.jsonl"))
        let cache = root.appendingPathComponent("cache.json")
        try Data("not a cache".utf8).write(to: cache)
        var scanner = UsageScanner(roots: [.init(provider: .claudeCode, url: logs)], cacheURL: cache)
        XCTAssertEqual(completed(&scanner).records.count, 1)
    }

    func testCacheWriteFailurePreservesObservedUsageAndReportsFailure() throws {
        let root = try folder()
        try record("one").write(to: root.appendingPathComponent("sample.jsonl"))
        var scanner = UsageScanner(roots: [.init(provider: .claudeCode, url: root)], cacheURL: root)
        let output = completed(&scanner)
        XCTAssertEqual(output.records.count, 1)
        XCTAssertTrue(output.issues[.claudeCode, default: []].contains(.ioFailure))
    }

    func testCacheCannotOverwriteASelectedSourceFile() throws {
        let root = try folder(), file = root.appendingPathComponent("sample.jsonl")
        let original = try record("one")
        try original.write(to: file)
        var scanner = UsageScanner(roots: [.init(provider: .claudeCode, url: root)], cacheURL: file)
        let output = completed(&scanner)
        XCTAssertEqual(output.records.count, 1)
        XCTAssertTrue(output.issues[.claudeCode, default: []].contains(.ioFailure))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testRootUpdatesRetainSelectedHistoryAndDropRemovedProfiles() throws {
        let root = try folder(), first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try record("one").write(to: first.appendingPathComponent("sample.jsonl"))
        try record("two").write(to: second.appendingPathComponent("sample.jsonl"))
        let firstRoot = UsageSourceRoot(provider: .claudeCode, url: first)
        let secondRoot = UsageSourceRoot(provider: .claudeCode, url: second)
        var scanner = UsageScanner(roots: [firstRoot])
        XCTAssertEqual(completed(&scanner).records.count, 1)
        scanner.updateRoots([firstRoot, secondRoot])
        XCTAssertEqual(completed(&scanner).records.count, 2)
        scanner.updateRoots([secondRoot])
        XCTAssertEqual(completed(&scanner).records.count, 1)
    }

    func testDesktopDiscoveryReadsOnlyKnownTranscriptAndAuditLocations() throws {
        let root = try folder()
        let session = root.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions/account/group/session")
        let projects = session.appendingPathComponent(".claude/projects/project")
        let workspace = session.appendingPathComponent("workspace/generated")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try record("one").write(to: projects.appendingPathComponent("sample.jsonl"))
        try record("one").write(to: session.appendingPathComponent("audit.jsonl"))
        try record("unrelated").write(to: workspace.appendingPathComponent("output.jsonl"))
        var scanner = UsageScanner(roots: UsageSourceRoot.defaults(home: root, environment: [:]))
        let output = completed(&scanner)
        XCTAssertEqual(output.records.count, 2)
        XCTAssertEqual(Set(output.records.map(\.id)).count, 1, "The ledger can deduplicate shared native/audit identity")
    }

    func testIncompleteDiscoveryCannotTrustCachedPathsOutsideSelectedRoots() throws {
        let root = try folder(), logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("sample.jsonl"), cache = root.appendingPathComponent("cache.json")
        try record("one").write(to: file)
        let roots = [UsageSourceRoot(provider: .claudeCode, url: logs)]
        var original = UsageScanner(roots: roots, cacheURL: cache)
        XCTAssertEqual(completed(&original).records.count, 1)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        var files = try XCTUnwrap(json["files"] as? [String: Any])
        files[root.appendingPathComponent("outside.jsonl").path] = files[file.path]
        json["files"] = files
        try JSONSerialization.data(withJSONObject: json).write(to: cache)
        var scanner = UsageScanner(roots: roots, cacheURL: cache, discoveryEntryLimit: 1)
        let output = completed(&scanner)
        XCTAssertEqual(output.records.count, 1)
        XCTAssertTrue(output.issues[.claudeCode, default: []].contains(.unsupportedHistory))
    }

    func testZeroByteBudgetDoesNotReadARecord() throws {
        let root = try folder(), row = try record("one")
        try row.write(to: root.appendingPathComponent("sample.jsonl"))
        var scanner = UsageScanner(roots: [.init(provider: .claudeCode, url: root)])
        for _ in 0...row.count {
            let output = scanner.scan(now: now, byteBudget: 0)
            XCTAssertTrue(output.records.isEmpty)
            XCTAssertTrue(output.scanning)
        }
        XCTAssertEqual(completed(&scanner).records.count, 1)
    }

    func testClockRollbackDoesNotFreezeDiscovery() throws {
        let root = try folder()
        try record("one").write(to: root.appendingPathComponent("one.jsonl"))
        var scanner = UsageScanner(roots: [.init(provider: .claudeCode, url: root)])
        XCTAssertEqual(completed(&scanner).records.count, 1)
        try record("two").write(to: root.appendingPathComponent("two.jsonl"))
        XCTAssertEqual(scanner.scan(now: now.addingTimeInterval(-10)).records.count, 2)
    }

    func testDesktopNestedProjectLinksCannotEscapeSelectedStore() throws {
        for linkedComponent in ["projects", ".claude"] {
            let root = try folder(), outside = root.appendingPathComponent("outside")
            let session = root.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions/account/group/session")
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            let target = linkedComponent == "projects" ? outside : outside.appendingPathComponent("projects")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try record("outside").write(to: target.appendingPathComponent("sample.jsonl"))
            let link = linkedComponent == "projects" ? session.appendingPathComponent(".claude/projects")
                : session.appendingPathComponent(".claude")
            if linkedComponent == "projects" {
                try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            var scanner = UsageScanner(roots: UsageSourceRoot.defaults(home: root, environment: [:]))
            let output = completed(&scanner)
            XCTAssertTrue(output.records.isEmpty, "Nested \(linkedComponent) link must not expose an outside history tree")
            XCTAssertTrue(output.issues[.claudeCode, default: []].contains(.unsupportedHistory))
        }
    }

    func testRetainedEventLimitIsGlobalAcrossFiles() throws {
        let root = try folder(), logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try (record("one") + record("two")).write(to: logs.appendingPathComponent("first.jsonl"))
        try (record("three") + record("four")).write(to: logs.appendingPathComponent("second.jsonl"))
        let cache = root.appendingPathComponent("cache.json")
        let roots = [UsageSourceRoot(provider: .claudeCode, url: logs)]
        var scanner = UsageScanner(roots: roots, cacheURL: cache, maxRetainedEvents: 3)
        let output = completed(&scanner, budget: 91)
        XCTAssertEqual(output.records.count, 3)
        XCTAssertTrue(output.issues[.claudeCode, default: []].contains(.unsupportedHistory))
        let saved = try XCTUnwrap(UsageScanDiskCache.load(from: cache, roots: roots.map(\.cacheIdentity)))
        XCTAssertEqual(saved.files.values.reduce(0) { $0 + $1.parser.retainedEventCount }, 3)
    }

    func testCapacityAtExactByteBoundaryStopsRapidPollingImmediately() throws {
        let root = try folder(), first = try record("one")
        try (first + record("two")).write(to: root.appendingPathComponent("sample.jsonl"))
        var scanner = UsageScanner(roots: [.init(provider: .claudeCode, url: root)], maxRetainedEvents: 1)
        let output = scanner.scan(now: now, byteBudget: first.count)
        XCTAssertEqual(output.records.count, 1)
        XCTAssertFalse(output.scanning)
        XCTAssertTrue(output.issues[.claudeCode, default: []].contains(.unsupportedHistory))
    }

    func testCapacityCheckpointSurvivesRestartWithoutParsingOrSavingPastLimit() throws {
        let root = try folder(), logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let firstTwo = try record("one") + record("two")
        let original = try firstTwo + record("three", content: "SYNTHETIC UNPARSED PRIVATE TAIL")
        let file = logs.appendingPathComponent("sample.jsonl"), cache = root.appendingPathComponent("cache.json")
        try original.write(to: file)
        let roots = [UsageSourceRoot(provider: .claudeCode, url: logs)]
        var scanner = UsageScanner(roots: roots, cacheURL: cache, maxRetainedEvents: 2)
        XCTAssertEqual(completed(&scanner).records.count, 2)
        let before = try Data(contentsOf: cache)
        let saved = try XCTUnwrap(UsageScanDiskCache.load(from: cache, roots: roots.map(\.cacheIdentity)))
        XCTAssertEqual(saved.files[file.path]?.offset, UInt64(firstTwo.count))
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("SYNTHETIC UNPARSED PRIVATE TAIL"))
        let modified = try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date
        var restarted = UsageScanner(roots: roots, cacheURL: cache, maxRetainedEvents: 2)
        for _ in 0..<3 {
            let output = restarted.scan(now: now, byteBudget: 17)
            XCTAssertFalse(output.scanning)
            XCTAssertEqual(output.records.count, 2)
            XCTAssertTrue(output.issues[.claudeCode, default: []].contains(.unsupportedHistory))
        }
        XCTAssertEqual(try Data(contentsOf: cache), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date, modified)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testRotationReleasesGlobalCapacityBeforeAnyFileIsRead() throws {
        let root = try folder(), first = root.appendingPathComponent("first.jsonl")
        try (record("one") + record("two")).write(to: first)
        var scanner = UsageScanner(roots: [.init(provider: .claudeCode, url: root)], maxRetainedEvents: 2)
        XCTAssertEqual(completed(&scanner).records.count, 2)
        try Data().write(to: first)
        let second = root.appendingPathComponent("second.jsonl")
        try record("new").write(to: second)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(10)], ofItemAtPath: second.path)
        let output = scanner.scan(now: now, byteBudget: 10_000, forceDiscovery: true)
        XCTAssertFalse(output.scanning)
        XCTAssertEqual(output.records.count, 1)
        XCTAssertTrue(output.records.first?.id.contains("message-new") == true)
        XCTAssertFalse(output.issues[.claudeCode, default: []].contains(.unsupportedHistory))
    }

    func testOversizedCachedCorpusIsRejectedAndRebuiltWithinNewLimit() throws {
        let root = try folder(), logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try (record("one") + record("two") + record("three")).write(to: logs.appendingPathComponent("sample.jsonl"))
        let cache = root.appendingPathComponent("cache.json")
        let roots = [UsageSourceRoot(provider: .claudeCode, url: logs)]
        var original = UsageScanner(roots: roots, cacheURL: cache, maxRetainedEvents: 5)
        XCTAssertEqual(completed(&original).records.count, 3)
        let oversized = try XCTUnwrap(UsageScanDiskCache.load(from: cache, roots: roots.map(\.cacheIdentity)))
        XCTAssertThrowsError(try UsageScanDiskCache.load(from: cache, roots: roots.map(\.cacheIdentity),
                                                       maximumRetainedEvents: 2))
        let rejected = root.appendingPathComponent("rejected-cache.json")
        XCTAssertThrowsError(try oversized.save(to: rejected, maximumRetainedEvents: 2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        var smaller = UsageScanner(roots: roots, cacheURL: cache, maxRetainedEvents: 2)
        let rebuilt = completed(&smaller)
        XCTAssertEqual(rebuilt.records.count, 2)
        XCTAssertTrue(rebuilt.issues[.claudeCode, default: []].contains(.unsupportedHistory))
        let saved = try XCTUnwrap(UsageScanDiskCache.load(from: cache, roots: roots.map(\.cacheIdentity)))
        XCTAssertEqual(saved.files.values.reduce(0) { $0 + $1.parser.retainedEventCount }, 2)
    }

    func testIncompleteClaudeRequestsConsumeCapacityWithoutPublishingZeroUsage() throws {
        let root = try folder(), file = root.appendingPathComponent("sample.jsonl")
        var incomplete = try XCTUnwrap(JSONSerialization.jsonObject(with: record("pending")) as? [String: Any])
        var message = try XCTUnwrap(incomplete["message"] as? [String: Any])
        message["stop_reason"] = NSNull()
        message["usage"] = ["input_tokens": 10, "output_tokens": 0]
        incomplete["message"] = message
        var bytes = try JSONSerialization.data(withJSONObject: incomplete)
        bytes.append(0x0a)
        bytes.append(try record("one"))
        bytes.append(try record("two"))
        try bytes.write(to: file)
        var scanner = UsageScanner(roots: [.init(provider: .claudeCode, url: root)], maxRetainedEvents: 2)
        let output = completed(&scanner)
        XCTAssertEqual(output.records.count, 1)
        XCTAssertTrue(output.issues[.claudeCode, default: []].contains(.unsupportedHistory))
        XCTAssertTrue(output.issues[.claudeCode, default: []].contains(.incompleteRecord))
    }

    func testCodexCanonicalAndMirroredSnapshotsBothConsumeRetainedCapacity() throws {
        let root = try folder(), cache = root.appendingPathComponent("cache.json")
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let counts: [String: Any] = ["input_tokens": 10, "output_tokens": 0, "total_tokens": 10]
        let objects: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "sample"]],
            ["type": "token_usage_record", "timestamp": "2026-11-19T12:00:00Z",
             "payload": ["response_id": "one", "thread_id": "sample", "usage": counts, "thread_token_usage": counts]],
            ["type": "event_msg", "timestamp": "2026-11-19T12:00:00Z",
             "payload": ["type": "token_count", "info": ["total_token_usage": counts]]],
            ["type": "token_usage_record", "timestamp": "2026-11-19T12:00:00Z",
             "payload": ["response_id": "two", "thread_id": "sample", "usage": counts, "thread_token_usage": counts]],
        ]
        var bytes = Data()
        for object in objects {
            bytes.append(try JSONSerialization.data(withJSONObject: object))
            bytes.append(0x0a)
        }
        try bytes.write(to: logs.appendingPathComponent("sample.jsonl"))
        let roots = [UsageSourceRoot(provider: .codex, url: logs)]
        var scanner = UsageScanner(roots: roots, cacheURL: cache, maxRetainedEvents: 2)
        let output = completed(&scanner)
        XCTAssertEqual(output.records.map(\.id), ["codex:response:one"])
        XCTAssertTrue(output.issues[.codex, default: []].contains(.unsupportedHistory))
        let saved = try XCTUnwrap(UsageScanDiskCache.load(from: cache, roots: roots.map(\.cacheIdentity)))
        XCTAssertEqual(saved.files.values.reduce(0) { $0 + $1.parser.retainedEventCount }, 2)
    }
}
