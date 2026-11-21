import Foundation
import XCTest
@testable import AIRunsCore

final class AccountRegistryTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("airuns-accounts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func permissions(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return try XCTUnwrap(value).intValue
    }

    func testMetadataRoundTripAndPrivatePermissions() throws {
        let parent = try temporaryRoot(), root = parent.appendingPathComponent("accounts")
        let registry = AccountRegistry(root: root)
        let account = ManagedAccount(provider: .codex, label: "Work", email: "sample@example.test", plan: "sample")
        try registry.save([account])
        let profile = try registry.profileURL(for: account)
        XCTAssertEqual(try registry.load(), [account])
        XCTAssertEqual(profile.lastPathComponent, account.id.uuidString.lowercased())
        XCTAssertEqual(try permissions(root), 0o700)
        XCTAssertEqual(try permissions(profile.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(profile), 0o700)
        XCTAssertEqual(try permissions(root.appendingPathComponent("accounts.json")), 0o600)
    }

    func testMissingRegistryLoadDoesNotCreateStorage() throws {
        let root = try temporaryRoot().appendingPathComponent("accounts")
        XCTAssertEqual(try AccountRegistry(root: root).load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRootAndProviderSymlinksAreRejectedWithoutChangingTargets() throws {
        let parent = try temporaryRoot(), outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let originalPermissions = try permissions(outside)
        let root = parent.appendingPathComponent("accounts")
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        let account = ManagedAccount(provider: .codex)
        XCTAssertThrowsError(try AccountRegistry(root: root).profileURL(for: account))
        XCTAssertEqual(try permissions(outside), originalPermissions)
        try FileManager.default.removeItem(at: root)
        let registry = AccountRegistry(root: root)
        try registry.save([])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("codex"), withDestinationURL: outside)
        XCTAssertThrowsError(try registry.profileURL(for: account))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testMetadataSymlinkIsNotReadOrReplaced() throws {
        let parent = try temporaryRoot(), root = parent.appendingPathComponent("accounts")
        let registry = AccountRegistry(root: root)
        try registry.save([])
        let target = parent.appendingPathComponent("outside.json"), expected = Data("fixture data".utf8)
        try expected.write(to: target)
        let metadata = root.appendingPathComponent("accounts.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: target)
        XCTAssertThrowsError(try registry.load())
        XCTAssertThrowsError(try registry.save([ManagedAccount(provider: .codex)]))
        XCTAssertEqual(try Data(contentsOf: target), expected)
    }

    func testDuplicateAccountsCannotReplaceExistingMetadata() throws {
        let root = try temporaryRoot().appendingPathComponent("accounts"), account = ManagedAccount(provider: .claude)
        let registry = AccountRegistry(root: root)
        try registry.save([account])
        XCTAssertThrowsError(try registry.save([account, account]))
        XCTAssertEqual(try registry.load(), [account])
    }

    func testInvalidUUIDMetadataCannotEscapeManagedRoot() throws {
        let root = try temporaryRoot().appendingPathComponent("accounts"), registry = AccountRegistry(root: root)
        try registry.save([])
        let invalid = Data("""
        [{"id":"../../outside","provider":"codex","label":"Sample","createdAt":"2026-01-10T12:00:00Z"}]
        """.utf8)
        let metadata = root.appendingPathComponent("accounts.json")
        try invalid.write(to: metadata)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        XCTAssertThrowsError(try registry.load())
    }

    func testOnlyValidatedQuotaWindowsCanBeCreatedOrDecoded() throws {
        XCTAssertNil(AccountRateWindow(id: "primary", title: "Session", usedPercent: .nan))
        XCTAssertNil(AccountRateWindow(id: "primary", title: "Session", usedPercent: 101))
        XCTAssertNil(AccountRateWindow(id: "primary", title: "Session", usedPercent: 10, durationMinutes: -1))
        let invalid = Data(#"{"id":"primary","title":"Session","usedPercent":-1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AccountRateWindow.self, from: invalid))
        XCTAssertNotNil(AccountRateWindow(id: "primary", title: "Session", usedPercent: 0))
    }
}
