import AIRunsCore
import Foundation
import XCTest
@testable import AIRunsApp

private enum AccountTestError: Error { case unavailable }

private actor MemoryAccountStore: AccountPersisting {
    var rows: [ManagedAccount]
    var loadFails: Bool
    var saveFails = false
    private var holdNextSave = false
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private(set) var saves = 0
    private(set) var profileRequests = 0

    init(_ rows: [ManagedAccount] = [], loadFails: Bool = false) {
        self.rows = rows
        self.loadFails = loadFails
    }
    func load() throws -> [ManagedAccount] {
        if loadFails { throw AccountTestError.unavailable }
        return rows
    }
    func save(_ rows: [ManagedAccount]) async throws {
        saves += 1
        if saveFails { throw AccountTestError.unavailable }
        if holdNextSave {
            holdNextSave = false
            await withCheckedContinuation { saveContinuation = $0 }
        }
        self.rows = rows
    }
    func profileURL(for account: ManagedAccount) -> URL {
        profileRequests += 1
        return URL(fileURLWithPath: "/tmp/airuns-test-profiles").appendingPathComponent(account.id.uuidString)
    }
    func failSaving() { saveFails = true }
    func pauseNextSave() { holdNextSave = true }
    func saveIsPaused() -> Bool { saveContinuation != nil }
    func completeSave() { saveContinuation?.resume(); saveContinuation = nil }
}

private actor FakeAccountClient: AccountConnecting {
    let account: ManagedAccount
    var windows: [AccountRateWindow]
    var quotaRefreshed = true
    var email = "sample@example.invalid"
    var refreshFails: Bool
    var holdConnect: Bool
    private(set) var connects = 0
    private(set) var refreshes = 0
    private(set) var cancellations = 0
    private(set) var submittedCodes: [String] = []
    private var authorizationHandler: (@Sendable (URL) -> Void)?
    private var continuation: CheckedContinuation<AccountConnectionResult, Error>?

    init(account: ManagedAccount, percent: Double = 25, refreshFails: Bool = false, holdConnect: Bool = false) {
        self.account = account
        self.windows = [AccountRateWindow(id: "primary", title: "Session", usedPercent: percent)!]
        self.refreshFails = refreshFails
        self.holdConnect = holdConnect
    }
    private var result: AccountConnectionResult {
        .init(account: account.verified(email: email, plan: "Test plan"), windows: quotaRefreshed ? windows : [],
              note: quotaRefreshed ? nil : "Usage limits could not be refreshed.", quotaRefreshed: quotaRefreshed)
    }
    func connect(onAuthorization: @escaping @Sendable (URL) -> Void) async throws -> AccountConnectionResult {
        connects += 1
        authorizationHandler = onAuthorization
        if holdConnect {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        onAuthorization(URL(string: "https://auth.openai.com/authorize?state=synthetic")!)
        return result
    }
    func refresh() throws -> AccountConnectionResult {
        refreshes += 1
        if refreshFails { throw AccountTestError.unavailable }
        return result
    }
    func cancel() { cancellations += 1 }
    func disconnect() {}
    func submitCode(_ code: String) { submittedCodes.append(code) }
    func emitAuthorization(_ url: URL) { authorizationHandler?(url) }
    func failRefreshing() { refreshFails = true }
    func completeConnect() { continuation?.resume(returning: result); continuation = nil }
    func failQuotaOnly() { quotaRefreshed = false }
    func useEmail(_ value: String) { email = value }
    func reportNoWindows() { windows = []; quotaRefreshed = true }
}

final class AccountManagerTests: XCTestCase {
    @MainActor
    func testAPIAcceptanceUsesNoCLIProfilesAndDisconnectSurvivesRefresh() async throws {
        let store = MemoryAccountStore()
        let keys = TestAPIKeyStore()
        let manager = AccountManager(store: store, makeClient: { account, profile in
            XCTAssertNil(profile)
            return APIAccountClient(account: account, keyStore: keys) { _ in
                (200, Data(#"{"data":[{"id":"qwen-max"}]}"#.utf8))
            }
        }, openAuthorization: { _ in XCTFail("API keys do not use browser authorization") })
        var roots: [UsageSourceRoot] = []
        manager.onProfilesChanged = { roots = $0 }
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.isLoaded && !manager.isBusy }

        await manager.add(provider: .qwen, label: "Example", credentials: .init(key: "sk-example", qwenPlatform: .china))
        let account = try XCTUnwrap(manager.accounts.first)
        XCTAssertEqual(manager.states[account.id]?.note, "Qwen models: qwen-max")
        XCTAssertNotNil(account.lastVerifiedAt)
        XCTAssertTrue(roots.isEmpty)
        let profiles = await store.profileRequests
        XCTAssertEqual(profiles, 0)
        let stored = try JSONEncoder().encode(account)
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("sk-example"))

        await manager.disconnect(id: account.id)
        await manager.refresh(id: account.id)
        XCTAssertEqual(manager.states[account.id]?.status, .disconnected)
        XCTAssertNil(try keys.load(for: account))
    }


    @MainActor
    private func eventually(_ condition: @MainActor () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Expected account state did not arrive", file: file, line: line)
    }

    @MainActor
    func testCorruptRegistryBlocksNewAccountsInsteadOfOverwritingIt() async throws {
        let store = MemoryAccountStore(loadFails: true)
        let manager = AccountManager(store: store, makeClient: { account, _ in FakeAccountClient(account: account) },
                                     openAuthorization: { _ in XCTFail("Startup must not open a browser") })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.loadError != nil }
        await manager.add(provider: .codex, label: "Another account")
        XCTAssertFalse(manager.isLoaded)
        XCTAssertTrue(manager.accounts.isEmpty)
        let saves = await store.saves
        XCTAssertEqual(saves, 0)
    }

    @MainActor
    func testStartupOnlyRefreshesAndDoesNotStartInteractiveSignIn() async throws {
        let account = ManagedAccount(provider: .codex, label: "Personal")
        let client = FakeAccountClient(account: account), store = MemoryAccountStore([account])
        var opened: [URL] = []
        let manager = AccountManager(store: store, makeClient: { _, _ in client }, openAuthorization: { opened.append($0) })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.states[account.id]?.status == .connected }
        let connects = await client.connects
        XCTAssertEqual(connects, 0)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertNil(manager.connectingID)
    }

    @MainActor
    func testAccountsWithSameEmailKeepSeparateQuotaReadings() async throws {
        let first = ManagedAccount(provider: .codex, label: "Personal")
        let second = ManagedAccount(provider: .codex, label: "School")
        let firstClient = FakeAccountClient(account: first, percent: 10)
        let secondClient = FakeAccountClient(account: second, percent: 80)
        let store = MemoryAccountStore([first, second])
        let manager = AccountManager(store: store, makeClient: { account, _ in
            account.id == first.id ? firstClient : secondClient
        }, openAuthorization: { _ in XCTFail("No interactive request was made") })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.states[first.id]?.status == .connected && manager.states[second.id]?.status == .connected }
        XCTAssertEqual(manager.accounts.count, 2)
        XCTAssertEqual(manager.accounts[0].email, manager.accounts[1].email)
        XCTAssertEqual(manager.states[first.id]?.windows.first?.usedPercent, 10)
        XCTAssertEqual(manager.states[second.id]?.windows.first?.usedPercent, 80)
        let saved = await store.rows
        XCTAssertEqual(Set(saved.map(\.id)), [first.id, second.id])
    }

    @MainActor
    func testRefreshFailureRetainsOldWindowAndCaptureTimeAsStale() async throws {
        let account = ManagedAccount(provider: .codex)
        let client = FakeAccountClient(account: account), store = MemoryAccountStore([account])
        let manager = AccountManager(store: store, makeClient: { _, _ in client }, openAuthorization: { _ in })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.states[account.id]?.status == .connected }
        let capture = manager.states[account.id]?.updatedAt
        await client.failRefreshing()
        await manager.refresh(id: account.id)
        XCTAssertEqual(manager.states[account.id]?.status, .stale)
        XCTAssertEqual(manager.states[account.id]?.windows.first?.usedPercent, 25)
        XCTAssertEqual(manager.states[account.id]?.updatedAt, capture)
    }

    @MainActor
    func testCancelledSignInIgnoresLateSuccess() async throws {
        let account = ManagedAccount(provider: .codex)
        let client = FakeAccountClient(account: account, refreshFails: true, holdConnect: true)
        let store = MemoryAccountStore([account])
        let manager = AccountManager(store: store, makeClient: { _, _ in client }, openAuthorization: { _ in })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.states[account.id]?.status == .failed }
        let login = Task { await manager.reconnect(id: account.id) }
        try await eventually { await client.connects == 1 }
        manager.cancelLogin()
        await client.completeConnect()
        await login.value
        XCTAssertNil(manager.connectingID)
        XCTAssertEqual(manager.states[account.id]?.status, .disconnected)
        XCTAssertNil(manager.accounts.first?.email)
        let saves = await store.saves
        XCTAssertEqual(saves, 0)
    }

    @MainActor
    func testSaveFailureDoesNotBeginLoginOrReplaceExistingMetadata() async throws {
        let account = ManagedAccount(provider: .codex)
        let store = MemoryAccountStore([account])
        let manager = AccountManager(store: store, makeClient: { account, _ in FakeAccountClient(account: account) },
                                     openAuthorization: { _ in XCTFail("Failed metadata save must block sign-in") })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.states[account.id]?.status == .connected }
        await store.failSaving()
        await manager.add(provider: .claude, label: "Other")
        XCTAssertEqual(manager.accounts.map(\.id), [account.id])
        XCTAssertNotNil(manager.message)
        XCTAssertNil(manager.connectingID)
    }

    @MainActor
    func testCancelledSignInRollsBackMetadataIfCancellationArrivesDuringSave() async throws {
        let account = ManagedAccount(provider: .codex)
        let client = FakeAccountClient(account: account, refreshFails: true)
        let store = MemoryAccountStore([account])
        let manager = AccountManager(store: store, makeClient: { _, _ in client }, openAuthorization: { _ in })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.states[account.id]?.status == .failed }
        await store.pauseNextSave()
        let login = Task { await manager.reconnect(id: account.id) }
        try await eventually { await store.saveIsPaused() }
        manager.cancelLogin()
        await store.completeSave()
        await login.value
        XCTAssertNil(manager.accounts.first?.email)
        let saved = await store.rows
        XCTAssertNil(saved.first?.email)
        XCTAssertEqual(manager.states[account.id]?.status, .disconnected)
    }

    @MainActor
    func testBootstrapAlwaysPublishesUsageRootsIncludingNativeFallbackOnFailure() async throws {
        let store = MemoryAccountStore(loadFails: true)
        let manager = AccountManager(store: store, makeClient: { account, _ in FakeAccountClient(account: account) },
                                     openAuthorization: { _ in })
        var callbacks: [[UsageSourceRoot]] = []
        manager.onProfilesChanged = { callbacks.append($0) }
        manager.start()
        defer { manager.stop() }
        try await eventually { !callbacks.isEmpty }
        XCTAssertTrue(callbacks[0].isEmpty)
    }

    @MainActor
    func testDisconnectKeepsMetadataAndHistoryRootsButClearsQuota() async throws {
        let account = ManagedAccount(provider: .codex)
        let client = FakeAccountClient(account: account), store = MemoryAccountStore([account])
        let manager = AccountManager(store: store, makeClient: { _, _ in client }, openAuthorization: { _ in })
        var roots: [UsageSourceRoot] = []
        manager.onProfilesChanged = { roots = $0 }
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.states[account.id]?.status == .connected }
        XCTAssertEqual(roots.count, 2)
        await manager.disconnect(id: account.id)
        XCTAssertEqual(manager.accounts.map(\.id), [account.id])
        XCTAssertEqual(manager.states[account.id]?.status, .disconnected)
        XCTAssertTrue(manager.states[account.id]?.windows.isEmpty == true)
        XCTAssertEqual(roots.count, 2)
    }

    @MainActor
    func testAddUsesSeparateUUIDAndPersistsOnlyDisplayMetadata() async throws {
        let store = MemoryAccountStore()
        var opened: [URL] = []
        let manager = AccountManager(store: store, makeClient: { account, _ in FakeAccountClient(account: account) },
                                     openAuthorization: { opened.append($0) })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.isLoaded }
        await manager.add(provider: .codex, label: "Personal")
        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.accounts.first?.label, "Personal")
        XCTAssertEqual(manager.states[try XCTUnwrap(manager.accounts.first?.id)]?.status, .connected)
        let saved = await store.rows
        let encoded = try JSONEncoder().encode(saved)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("auth.openai.com"))
        XCTAssertFalse(text.contains("access_token"))
        XCTAssertFalse(text.contains("synthetic"))
        XCTAssertTrue(opened.allSatisfy { $0.host == "auth.openai.com" })
    }

    @MainActor
    func testQuotaFailureRetainsStaleReadingOnlyForSameVerifiedIdentity() async throws {
        let account = ManagedAccount(provider: .codex)
        let client = FakeAccountClient(account: account), store = MemoryAccountStore([account])
        let manager = AccountManager(store: store, makeClient: { _, _ in client }, openAuthorization: { _ in })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.states[account.id]?.status == .connected }
        let capture = manager.states[account.id]?.updatedAt
        await client.failQuotaOnly()
        await manager.refresh(id: account.id)
        XCTAssertEqual(manager.states[account.id]?.status, .stale)
        XCTAssertEqual(manager.states[account.id]?.windows.first?.usedPercent, 25)
        XCTAssertEqual(manager.states[account.id]?.updatedAt, capture)
        await client.useEmail("another@example.invalid")
        await manager.refresh(id: account.id)
        XCTAssertEqual(manager.states[account.id]?.status, .connected)
        XCTAssertTrue(manager.states[account.id]?.windows.isEmpty == true)
        XCTAssertNil(manager.states[account.id]?.updatedAt)
    }

    @MainActor
    func testNewSignInNeverInheritsPriorQuotaEvenForSameEmail() async throws {
        let account = ManagedAccount(provider: .codex)
        let client = FakeAccountClient(account: account), store = MemoryAccountStore([account])
        let manager = AccountManager(store: store, makeClient: { _, _ in client }, openAuthorization: { _ in })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.states[account.id]?.status == .connected }
        await client.failQuotaOnly()
        await manager.reconnect(id: account.id)
        XCTAssertEqual(manager.states[account.id]?.status, .connected)
        XCTAssertTrue(manager.states[account.id]?.windows.isEmpty == true)
        XCTAssertNil(manager.states[account.id]?.updatedAt)
    }

    @MainActor
    func testSuccessfulUnavailableQuotaClearsOldWindows() async throws {
        let account = ManagedAccount(provider: .codex)
        let client = FakeAccountClient(account: account), store = MemoryAccountStore([account])
        let manager = AccountManager(store: store, makeClient: { _, _ in client }, openAuthorization: { _ in })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.states[account.id]?.status == .connected }
        await client.reportNoWindows()
        await manager.refresh(id: account.id)
        XCTAssertEqual(manager.states[account.id]?.status, .connected)
        XCTAssertTrue(manager.states[account.id]?.windows.isEmpty == true)
    }

    @MainActor
    func testRenameSurvivesARefreshFromTheExistingClient() async throws {
        let account = ManagedAccount(provider: .codex, label: "Personal")
        let client = FakeAccountClient(account: account), store = MemoryAccountStore([account])
        let manager = AccountManager(store: store, makeClient: { _, _ in client }, openAuthorization: { _ in })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.states[account.id]?.status == .connected }
        await manager.rename(id: account.id, label: "School")
        await manager.refresh(id: account.id)
        XCTAssertEqual(manager.accounts.first?.label, "School")
        XCTAssertEqual(manager.accounts.first?.email, "sample@example.invalid")
        let saved = await store.rows
        XCTAssertEqual(saved.first?.label, "School")
    }

    @MainActor
    func testOneTimeCodeIsSentOnlyDuringSignInAndNeverSavedAsMetadata() async throws {
        let account = ManagedAccount(provider: .claude)
        let client = FakeAccountClient(account: account, refreshFails: true, holdConnect: true)
        let store = MemoryAccountStore([account])
        let manager = AccountManager(store: store, makeClient: { _, _ in client }, openAuthorization: { _ in })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.states[account.id]?.status == .failed }
        await manager.submitCode("not-active")
        let login = Task { await manager.reconnect(id: account.id) }
        try await eventually { await client.connects == 1 }
        await manager.submitCode("synthetic-onetime-code\n")
        let submitted = await client.submittedCodes
        XCTAssertEqual(submitted, ["synthetic-onetime-code"])
        await client.completeConnect()
        await login.value
        let saved = await store.rows
        let encoded = try JSONEncoder().encode(saved)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("synthetic-onetime-code"))
    }

    @MainActor
    func testOnlyValidatedProviderLinksCanOpenDuringTheCurrentSignIn() async throws {
        let account = ManagedAccount(provider: .codex)
        let client = FakeAccountClient(account: account, refreshFails: true, holdConnect: true)
        let store = MemoryAccountStore([account])
        var opened: [URL] = []
        let manager = AccountManager(store: store, makeClient: { _, _ in client }, openAuthorization: { opened.append($0) })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.states[account.id]?.status == .failed }
        let login = Task { await manager.reconnect(id: account.id) }
        try await eventually { await client.connects == 1 }
        await client.emitAuthorization(URL(string: "https://auth.openai.com/authorize?state=synthetic")!)
        try await eventually { opened.count == 1 }
        manager.openSignInPage()
        XCTAssertEqual(opened.count, 2)
        await client.emitAuthorization(URL(string: "https://auth.openai.com.evil.invalid/authorize")!)
        try await eventually { manager.connectingID == nil }
        await client.completeConnect()
        await login.value
        XCTAssertEqual(opened.count, 2)
        XCTAssertTrue(opened.allSatisfy { $0.host == "auth.openai.com" })
        XCTAssertTrue(manager.message?.contains("rejected") == true)
    }

    @MainActor
    func testClaudeBrowserRetryDoesNotDuplicateTheCLIsAutomaticBrowserOpen() async throws {
        let account = ManagedAccount(provider: .claude)
        let client = FakeAccountClient(account: account, refreshFails: true, holdConnect: true)
        let store = MemoryAccountStore([account])
        var opened: [URL] = []
        let manager = AccountManager(store: store, makeClient: { _, _ in client }, openAuthorization: { opened.append($0) })
        manager.start()
        defer { manager.stop() }
        try await eventually { manager.states[account.id]?.status == .failed }
        let login = Task { await manager.reconnect(id: account.id) }
        try await eventually { await client.connects == 1 }
        let authorization = URL(string: "https://claude.ai/oauth/authorize?state=synthetic")!
        await client.emitAuthorization(authorization)
        try await eventually { manager.authorizationURL == authorization }
        XCTAssertTrue(opened.isEmpty, "Claude's CLI already opens its browser sign-in")
        manager.openSignInPage()
        XCTAssertEqual(opened, [authorization])
        await client.completeConnect()
        await login.value
    }
}
