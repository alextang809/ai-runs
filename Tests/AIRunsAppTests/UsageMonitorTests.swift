import AIRunsCore
import XCTest
@testable import AIRunsApp

private actor SuspendedUsageWorker: UsageWorking {
    private var pending: [Int: CheckedContinuation<UsageSnapshot, Never>] = [:]
    private var selections: [UsagePeriod] = []
    private var events: [String] = []
    var callCount: Int { selections.count }
    var eventOrder: [String] { events }
    func refresh(period: UsagePeriod, forceDiscovery: Bool) async -> UsageSnapshot {
        let id = selections.count
        events.append("scan")
        selections.append(period)
        return await withCheckedContinuation { pending[id] = $0 }
    }
    func currentSnapshot(period: UsagePeriod) -> UsageSnapshot { sample(period, input: 7) }
    func updateManagedRoots(_ roots: [UsageSourceRoot]) { events.append("roots") }
    func finish(_ id: Int, input: Int64) {
        pending.removeValue(forKey: id)?.resume(returning: sample(selections[id], input: input))
    }
    private func sample(_ period: UsagePeriod, input: Int64) -> UsageSnapshot {
        let now = Date()
        let record = UsageRecord(id: "sample", provider: .codex, timestamp: now,
                                 counts: TokenCounts(input: input, output: 1)!)
        return UsageLedger.snapshot(UsageScanOutput(records: [record], availableProviders: [.codex],
                                    refreshedAt: now), period: period, now: now)
    }
}

final class UsageMonitorTests: XCTestCase {
    @MainActor private func waitFor(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Usage update did not settle")
    }

    @MainActor
    func testDefaultIsRolling24HoursAndStartingTwiceDoesNotDuplicateScan() async throws {
        let suite = "usage-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let worker = SuspendedUsageWorker()
        let monitor = UsageMonitor(defaults: defaults, worker: worker)
        XCTAssertEqual(monitor.period, .last24Hours)
        let initialCalls = await worker.callCount
        XCTAssertEqual(initialCalls, 0)
        monitor.start(); monitor.start()
        try await waitFor { await worker.callCount == 1 }
        await worker.finish(0, input: 100)
        try await waitFor { monitor.snapshot.providers[0].counts?.input == 100 }
        let settledCalls = await worker.callCount
        XCTAssertEqual(settledCalls, 1)
        monitor.stop()
    }

    @MainActor
    func testOlderInFlightPeriodCannotOverwriteNewSelection() async throws {
        let suite = "usage-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let worker = SuspendedUsageWorker()
        let monitor = UsageMonitor(defaults: defaults, worker: worker)
        monitor.start()
        try await waitFor { await worker.callCount == 1 }
        monitor.select(.today)
        try await waitFor { monitor.snapshot.period == .today && monitor.snapshot.providers[0].counts?.input == 7 }
        await worker.finish(0, input: 100)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(monitor.snapshot.period, .today)
        XCTAssertEqual(monitor.snapshot.providers[0].counts?.input, 7)
        XCTAssertEqual(defaults.string(forKey: UsageMonitor.periodKey), "today")
        monitor.stop()
    }

    @MainActor
    func testRefreshRequestsCoalesceAndStoppedResultIsNotPublished() async throws {
        let suite = "usage-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let worker = SuspendedUsageWorker()
        let monitor = UsageMonitor(defaults: defaults, worker: worker)
        monitor.start()
        try await waitFor { await worker.callCount == 1 }
        monitor.refreshNow(); monitor.refreshNow()
        await worker.finish(0, input: 10)
        try await waitFor { await worker.callCount == 2 }
        monitor.stop()
        await worker.finish(1, input: 90)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(monitor.snapshot.providers[0].counts?.input, 10)
        let settledCalls = await worker.callCount
        XCTAssertEqual(settledCalls, 2)
    }

    @MainActor
    func testManagedRootsAreConfiguredBeforeFirstScanAndLateRootsCannotRestartStop() async throws {
        let suite = "usage-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let worker = SuspendedUsageWorker()
        let monitor = UsageMonitor(defaults: defaults, worker: worker)
        monitor.includeManagedRoots([])
        try await waitFor { await worker.callCount == 1 }
        let order = await worker.eventOrder
        XCTAssertEqual(order, ["roots", "scan"])
        monitor.stop()
        await worker.finish(0, input: 10)

        let later = SuspendedUsageWorker()
        let stopped = UsageMonitor(defaults: defaults, worker: later)
        stopped.includeManagedRoots([])
        stopped.stop()
        try await waitFor { await later.eventOrder == ["roots"] }
        try await Task.sleep(nanoseconds: 10_000_000)
        let calls = await later.callCount
        XCTAssertEqual(calls, 0)
    }

    func testLocalWorkerScansOnlyInjectedLogsAndReusesSnapshotForOtherPeriod() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-worker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let time = ISO8601DateFormatter().string(from: Date())
        let counts: [String: Any] = ["input_tokens": 50, "output_tokens": 5, "total_tokens": 55]
        let objects: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "sample-thread"]],
            ["type": "token_usage_record", "timestamp": time,
             "payload": ["response_id": "sample-response", "thread_id": "sample-thread",
                         "usage": counts, "thread_token_usage": counts]]
        ]
        let text = try objects.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        let source = logs.appendingPathComponent("sample.jsonl")
        try Data(text.utf8).write(to: source)
        let worker = LocalUsageWorker(paths: AIRunsPaths(root: root.appendingPathComponent("app")),
                                      roots: [UsageSourceRoot(provider: .codex, url: logs)])
        let scanned = await worker.refresh(period: .last24Hours, forceDiscovery: true)
        XCTAssertEqual(scanned.providers[0].counts?.total, 55)
        let other = await worker.currentSnapshot(period: .last7Days)
        XCTAssertEqual(other.providers[0].counts?.total, 55)
        XCTAssertEqual(other.period, .last7Days)
        XCTAssertEqual(try Data(contentsOf: source), Data(text.utf8))
    }
}
