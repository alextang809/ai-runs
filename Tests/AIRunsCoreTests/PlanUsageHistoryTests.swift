import Foundation
import XCTest
@testable import AIRunsCore

final class PlanUsageHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testQuotaSamplesSurviveReopenAndSeparateAccountsCyclesAndIdentities() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AccountRegistry(root: root)
        let first = ManagedAccount(provider: .codex, label: "First", email: "first@example.invalid")
        let other = ManagedAccount(provider: .codex, label: "Other", email: "first@example.invalid")
        let replacement = first.verified(email: "switched@example.invalid", plan: nil)
        let reset = start.addingTimeInterval(3_600)
        try registry.recordPlanUsage(for: first, windows: [window("short", 11, reset), window("weekly", 23, reset)], at: start)
        try registry.recordPlanUsage(for: first, windows: [window("short", 12, reset)], at: start.addingTimeInterval(60))
        try registry.recordPlanUsage(for: first, windows: [window("short", 9, reset)], at: start)
        try registry.recordPlanUsage(for: first, windows: [window("short", 21, reset)], at: start.addingTimeInterval(300))
        try registry.recordPlanUsage(for: first, windows: [window("short", 1, reset.addingTimeInterval(3_600))], at: reset)
        try registry.recordPlanUsage(for: other, windows: [window("short", 50, reset)], at: start)
        try registry.recordPlanUsage(for: replacement, windows: [window("short", 30, reset)], at: start)

        let reopened = AccountRegistry(root: root)
        let cycles = try reopened.loadPlanUsage(for: first).cycles
        XCTAssertEqual(cycles.count, 3)
        XCTAssertEqual(cycles.first { $0.windowID == "short" && $0.resetsAt == reset }?.samples.map(\.usedPercent), [12, 21])
        XCTAssertEqual(try reopened.loadPlanUsage(for: other).cycles.first?.samples.first?.usedPercent, 50)
        XCTAssertEqual(try reopened.loadPlanUsage(for: replacement).cycles.first?.samples.first?.usedPercent, 30)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for file in files {
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, 0o600)
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("@example.invalid"))
        }
    }

    func testDoesNotInventCyclesAndPrunesOldSamples() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AccountRegistry(root: root)
        let account = ManagedAccount(provider: .codex, label: "Example", email: "first@example.invalid")
        let otherProvider = ManagedAccount(provider: .claude, label: "Example", email: "first@example.invalid")
        let valid = window("valid", 0, start.addingTimeInterval(3_600))

        try registry.recordPlanUsage(for: otherProvider, windows: [valid], at: start)
        try registry.recordPlanUsage(for: account, windows: [window("expired", 80, start), window("unknown", 61, nil)], at: start)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try registry.recordPlanUsage(for: account, windows: [valid], at: start)
        XCTAssertEqual(try registry.loadPlanUsage(for: account).cycles.first?.samples.first?.usedPercent, 0)
        let later = start.addingTimeInterval(46 * 86_400)
        try registry.recordPlanUsage(for: account, windows: [window("valid", 20, later.addingTimeInterval(3_600))], at: later)
        XCTAssertEqual(try registry.loadPlanUsage(for: account).cycles.map { $0.samples.map(\.usedPercent) }, [[20]])
    }

    func testQuotaHistoryRejectsSymlinksWithoutAffectingTheRegistry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AccountRegistry(root: root)
        let account = ManagedAccount(provider: .codex, label: "Example", email: "first@example.invalid")
        try registry.save([account])
        let metadata = root.appendingPathComponent("accounts.json")
        let link = root.appendingPathComponent("plan-usage-\(account.id.uuidString.lowercased()).json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: metadata)
        let sample = window("valid", 20, start.addingTimeInterval(3_600))

        XCTAssertThrowsError(try registry.recordPlanUsage(for: account, windows: [sample], at: start))
        XCTAssertThrowsError(try registry.loadPlanUsage(for: account))
        XCTAssertEqual(try registry.load(), [account])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), metadata.path)
    }

    private func window(_ id: String, _ percent: Double, _ reset: Date?) -> AccountRateWindow {
        AccountRateWindow(id: id, title: "Example", usedPercent: percent, resetsAt: reset)!
    }
}
