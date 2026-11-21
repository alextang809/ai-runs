import AIRunsCore
import Foundation
import XCTest
@testable import AIRunsApp

final class APIAccountClientTests: XCTestCase {
    func testDeepSeekVerifiesBalanceAndCanRefreshAndDisconnect() async throws {
        let account = ManagedAccount(provider: .deepseek)
        let store = TestAPIKeyStore()
        let client = APIAccountClient(account: account, keyStore: store) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/user/balance")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            return (200, Data(#"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"0.00"}]}"#.utf8))
        }
        let result = try await client.connect(.init(key: " sk-test ", qwenPlatform: nil))
        XCTAssertNotNil(result.account.lastVerifiedAt)
        XCTAssertEqual(result.note, "API balance: CNY 0.00. Balance is insufficient for API calls.")
        XCTAssertTrue(result.windows.isEmpty)
        let refreshed = try await client.refresh()
        XCTAssertEqual(refreshed.note, result.note)
        try await client.disconnect()
        XCTAssertNil(try store.load(for: account))
    }

    func testQwenUsesSelectedPlatformAndOnlyShowsQwenModels() async throws {
        let account = ManagedAccount(provider: .qwen)
        let client = APIAccountClient(account: account, keyStore: TestAPIKeyStore()) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://maas.qianwenaiapi.com/compatible-mode/v1/models")
            return (200, Data(#"{"data":[{"id":"qwen-max"},{"id":"deepseek-v4"},{"id":"qwen-max"},{"id":"qwen-plus"}]}"#.utf8))
        }
        let result = try await client.connect(.init(key: "sk-test", qwenPlatform: .china))
        XCTAssertEqual(result.note, "Qwen models: qwen-max, qwen-plus")
        XCTAssertTrue(result.windows.isEmpty)
    }

    func testRejectedReplacementPreservesPriorKey() async throws {
        let account = ManagedAccount(provider: .qwen)
        let store = TestAPIKeyStore()
        let existing = APIAccountCredentials(key: "sk-original", qwenPlatform: .international)
        try store.save(existing, for: account)
        let client = APIAccountClient(account: account, keyStore: store) { _ in (401, Data("private response".utf8)) }
        do {
            _ = try await client.connect(.init(key: "sk-invalid", qwenPlatform: .china))
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(error as? APIAccountError, .rejectedKey)
        }
        XCTAssertEqual(try store.load(for: account)?.key, existing.key)
        XCTAssertEqual(try store.load(for: account)?.qwenPlatform, existing.qwenPlatform)
    }

    func testCancelBeforeAuthorizingKeychainWriteDoesNotSaveKey() async throws {
        let account = ManagedAccount(provider: .deepseek)
        let store = TestAPIKeyStore()
        let client = APIAccountClient(account: account, keyStore: store) { _ in
            (200, Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"2.50"}]}"#.utf8))
        }
        do {
            _ = try await client.connect(.init(key: "sk-test", qwenPlatform: nil)) { throw CancellationError() }
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? APIAccountError, .cancelled)
        }
        XCTAssertNil(try store.load(for: account))
    }

    func testMalformedOrCancelledVerificationNeverWritesKey() async throws {
        let account = ManagedAccount(provider: .deepseek)
        let store = TestAPIKeyStore()
        let invalid = APIAccountClient(account: account, keyStore: store) { _ in (200, Data("{}".utf8)) }
        let credentials = APIAccountCredentials(key: "sk-test", qwenPlatform: nil)
        do {
            _ = try await invalid.connect(credentials)
            XCTFail("Expected response validation failure")
        } catch {
            XCTAssertEqual(error as? APIAccountError, .invalidResponse)
        }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let waiting = APIAccountClient(account: account, keyStore: store) { _ in
            signal.yield(())
            try await Task.sleep(for: .seconds(10))
            return (200, Data(#"{"is_available":true,"balance_infos":[]}"#.utf8))
        }
        let attempt = Task { try await waiting.connect(credentials) }
        for await _ in started { break }
        await waiting.cancel()
        do {
            _ = try await attempt.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? APIAccountError, .cancelled)
        }
        XCTAssertNil(try store.load(for: account))
    }
}

final class TestAPIKeyStore: APIAccountKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: APIAccountCredentials] = [:]

    func load(for account: ManagedAccount) throws -> APIAccountCredentials? {
        lock.withLock { keys[account.id] }
    }

    func save(_ credentials: APIAccountCredentials, for account: ManagedAccount) throws {
        lock.withLock { keys = keys.merging([account.id: credentials]) { _, new in new } }
    }

    func remove(for account: ManagedAccount) throws {
        lock.withLock { keys = keys.filter { $0.key != account.id } }
    }
}
