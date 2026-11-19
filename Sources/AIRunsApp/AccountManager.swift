import AIRunsCore
import AppKit
import Combine
import Foundation

protocol AccountConnecting: Actor {
    func connect(onAuthorization: @escaping @Sendable (URL) -> Void) async throws -> AccountConnectionResult
    func refresh() async throws -> AccountConnectionResult
    func cancel() async
    func disconnect() async throws
    func submitCode(_ code: String) async throws
}

extension ManagedAccountClient: AccountConnecting {}

extension AccountConnecting {
    func submitCode(_ code: String) async throws { throw AccountActionError.codeUnavailable }
}

protocol AccountPersisting: Actor {
    func load() async throws -> [ManagedAccount]
    func save(_ accounts: [ManagedAccount]) async throws
    func profileURL(for account: ManagedAccount) async throws -> URL
}

actor AccountPersistence: AccountPersisting {
    private let registry: AccountRegistry
    init(root: URL) { registry = AccountRegistry(root: root) }
    func load() throws -> [ManagedAccount] { try registry.load() }
    func save(_ accounts: [ManagedAccount]) throws { try registry.save(accounts) }
    func profileURL(for account: ManagedAccount) throws -> URL { try registry.profileURL(for: account) }
}

enum AccountStatus: Equatable {
    case connected, connecting, refreshing, stale, disconnected, failed
}

struct AccountRowState: Equatable {
    let status: AccountStatus
    var windows: [AccountRateWindow] = []
    var updatedAt: Date? = nil
    var note: String? = nil
}

private enum AccountActionError: Error { case codeUnavailable, profileMismatch }

/// UI state only. Registry I/O and provider processes belong to their own actors;
/// browser sign-in is entered exclusively by explicit Add or Reconnect actions.
@MainActor
final class AccountManager: ObservableObject {
    typealias ClientFactory = @Sendable (ManagedAccount, URL) -> any AccountConnecting
    @Published private(set) var accounts: [ManagedAccount] = []
    @Published private(set) var states: [UUID: AccountRowState] = [:]
    @Published private(set) var connectingID: UUID?
    @Published private(set) var message: String?
    @Published private(set) var isLoaded = false
    @Published private(set) var loadError: String?
    @Published private(set) var isBusy = false
    @Published private(set) var authorizationURL: URL?
    @Published private(set) var submittingCode = false
    var onProfilesChanged: (([UsageSourceRoot]) -> Void)?

    private let store: any AccountPersisting
    private let makeClient: ClientFactory
    private let openAuthorization: @MainActor (URL) -> Void
    private var clients: [UUID: any AccountConnecting] = [:]
    private var operations: [UUID: UUID] = [:]
    private var generation = UUID()
    private var loginAttempt: UUID?
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var isRunning = false
    private var metadataWriting = false
    private var metadataWaiters: [CheckedContinuation<Void, Never>] = []

    init(paths: AIRunsPaths = AIRunsPaths(), store: (any AccountPersisting)? = nil,
         makeClient: ClientFactory? = nil, openAuthorization: (@MainActor (URL) -> Void)? = nil) {
        self.store = store ?? AccountPersistence(root: paths.root.appendingPathComponent("accounts"))
        self.makeClient = makeClient ?? { ManagedAccountClient(account: $0, profileURL: $1) }
        self.openAuthorization = openAuthorization ?? { NSWorkspace.shared.open($0) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        reload()
        let current = generation
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
                guard let self, self.isRunning, self.generation == current else { return }
                self.refreshAll()
            }
        }
    }

    func stop() {
        ManagedAccountClient.terminateOwnedProcesses()
        isRunning = false
        generation = UUID()
        loadTask?.cancel(); loadTask = nil
        refreshTask?.cancel(); refreshTask = nil
        timerTask?.cancel(); timerTask = nil
        cancelLogin()
        for client in clients.values { Task { await client.cancel() } }
        operations = [:]
    }

    func retryLoading() {
        guard connectingID == nil, !isBusy else { return }
        if !isRunning { start() } else { reload() }
    }

    private func reload() {
        guard loadTask == nil else { return }
        let current = generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.acquireMetadata()
            do {
                defer { self.releaseMetadata() }
                let saved = try await self.store.load()
                guard !Task.isCancelled, self.generation == current else { return }
                self.states = Dictionary(uniqueKeysWithValues: saved.map { account in
                    let retained = self.accounts.first { $0.id == account.id }?.provider == account.provider
                        ? self.states[account.id] : nil
                    return (account.id, retained ?? AccountRowState(status: .disconnected, note: "Not refreshed yet"))
                })
                self.accounts = saved
                self.isLoaded = true
                self.loadError = nil
                self.message = nil
            } catch {
                guard self.generation == current else { return }
                self.isLoaded = false
                self.loadError = "Saved accounts couldn’t be loaded. Retry before making changes."
                self.message = self.loadError
            }
            guard self.generation == current else { return }
            self.loadTask = nil
            await self.publishProfileRoots(generation: current)
            if self.isLoaded { self.refreshAll() }
        }
    }

    func refreshAll() {
        guard isLoaded, isRunning, refreshTask == nil else { return }
        let current = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            for account in self.accounts {
                guard !Task.isCancelled, self.generation == current else { return }
                await self.refresh(id: account.id)
            }
            if self.generation == current { self.refreshTask = nil }
        }
    }

    func refresh(id: UUID) async {
        guard isLoaded, connectingID != id, states[id]?.status != .refreshing,
              let account = accounts.first(where: { $0.id == id }) else { return }
        let current = generation, operation = UUID(), previous = states[id]
        operations[id] = operation
        setState(id, .init(status: .refreshing, windows: previous?.windows ?? [], updatedAt: previous?.updatedAt))
        do {
            let client = try await client(for: account)
            let result = try await client.refresh()
            guard active(id: id, operation: operation, generation: current), !Task.isCancelled else { return }
            try await accept(result, id: id, generation: current) {
                self.active(id: id, operation: operation, generation: current)
            }
            guard active(id: id, operation: operation, generation: current) else { return }
            setState(id, refreshedState(result, previous: previous, priorAccount: account))
        } catch {
            guard active(id: id, operation: operation, generation: current) else { return }
            setState(id, .init(status: previous?.updatedAt == nil ? .failed : .stale,
                               windows: previous?.windows ?? [], updatedAt: previous?.updatedAt,
                               note: previous?.updatedAt == nil ? "Usage is unavailable. Try refreshing or reconnecting."
                                  : "Couldn’t refresh. Showing the last successful reading."))
        }
    }

    func add(provider: AccountProvider, label: String) async {
        guard canEdit(), connectingID == nil else { return }
        guard validLabel(label) else { message = "Use an account name of 128 characters or fewer."; return }
        let account = ManagedAccount(provider: provider, label: label)
        let attempt = beginSignIn(account.id)
        let current = generation
        do {
            await acquireMetadata()
            do {
                defer { releaseMetadata() }
                guard loginAttempt == attempt, generation == current else { return }
                _ = try await store.profileURL(for: account)
                let updated = accounts + [account]
                try await save(updated)
                accounts = updated
            }
            await publishProfileRoots(generation: current)
            guard loginAttempt == attempt, generation == current else { return }
            await connect(account, attempt: attempt, generation: current)
        } catch {
            guard loginAttempt == attempt, generation == current else { return }
            finishSignIn(account.id, state: .init(status: .failed, note: safeSignInError(error)))
        }
    }

    func reconnect(id: UUID) async {
        guard canEdit(), connectingID == nil, states[id]?.status != .refreshing,
              let account = accounts.first(where: { $0.id == id }) else { return }
        let attempt = beginSignIn(id)
        await connect(account, attempt: attempt, generation: generation)
    }

    private func beginSignIn(_ id: UUID) -> UUID {
        let attempt = UUID()
        loginAttempt = attempt
        connectingID = id
        authorizationURL = nil
        message = nil
        operations[id] = UUID()
        setState(id, .init(status: .connecting, note: "Complete sign-in in your browser."))
        return attempt
    }

    private func connect(_ account: ManagedAccount, attempt: UUID, generation current: UUID) async {
        do {
            let client = try await client(for: account)
            guard loginAttempt == attempt, generation == current else { return }
            let result = try await client.connect { [weak self] url in
                Task { @MainActor [weak self] in self?.receiveAuthorization(url, account: account, attempt: attempt) }
            }
            guard loginAttempt == attempt, generation == current, !Task.isCancelled else { return }
            try await accept(result, id: account.id, generation: current) { self.loginAttempt == attempt }
            guard loginAttempt == attempt, generation == current else { return }
            finishSignIn(account.id, state: .init(status: .connected,
                         windows: result.quotaRefreshed ? result.windows : [],
                         updatedAt: result.quotaRefreshed ? Date() : nil,
                         note: result.note ?? (result.quotaRefreshed ? nil : "Usage limits could not be refreshed.")))
        } catch {
            guard loginAttempt == attempt, generation == current else { return }
            finishSignIn(account.id, state: .init(status: .failed, note: safeSignInError(error)))
        }
    }

    func cancelLogin() {
        guard let id = connectingID else { return }
        finishSignIn(id, state: .init(status: .disconnected, note: "Sign-in cancelled."))
        if let client = clients[id] { Task { await client.cancel() } }
    }

    private func finishSignIn(_ id: UUID, state: AccountRowState) {
        loginAttempt = nil
        connectingID = nil
        authorizationURL = nil
        submittingCode = false
        setState(id, state)
        if !accounts.contains(where: { $0.id == id }), state.status == .failed { message = state.note }
    }

    private func receiveAuthorization(_ url: URL, account: ManagedAccount, attempt: UUID) {
        guard loginAttempt == attempt, connectingID == account.id else { return }
        guard ManagedAccountClient.isAuthorizationURL(url, for: account.provider) else {
            cancelLogin()
            message = "The sign-in link was rejected. Try reconnecting."
            return
        }
        guard authorizationURL == nil else { return }
        authorizationURL = url
        // Claude's owner CLI opens its sign-in page itself; keep the validated
        // URL for an explicit retry without opening a second browser tab.
        if account.provider == .codex { openAuthorization(url) }
    }

    func openSignInPage() {
        guard let id = connectingID, let account = accounts.first(where: { $0.id == id }),
              let url = authorizationURL, ManagedAccountClient.isAuthorizationURL(url, for: account.provider) else { return }
        openAuthorization(url)
    }

    func submitCode(_ raw: String) async {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = connectingID, let client = clients[id], !submittingCode,
              !code.isEmpty, code.utf8.count <= 4_096,
              code.rangeOfCharacter(from: .controlCharacters) == nil else { return }
        let attempt = loginAttempt
        submittingCode = true
        defer { if loginAttempt == attempt { submittingCode = false } }
        do { try await client.submitCode(code) }
        catch { if loginAttempt == attempt { message = "The code could not be submitted. Try again or reconnect." } }
    }

    func disconnect(id: UUID) async {
        guard canEdit(), let account = accounts.first(where: { $0.id == id }) else { return }
        if connectingID == id { cancelLogin() }
        let current = generation, operation = UUID(), previous = states[id]
        operations[id] = operation
        setState(id, .init(status: .refreshing, windows: previous?.windows ?? [], updatedAt: previous?.updatedAt,
                           note: "Disconnecting…"))
        do {
            let client = try await client(for: account)
            await client.cancel()
            try await client.disconnect()
            guard active(id: id, operation: operation, generation: current) else { return }
            setState(id, .init(status: .disconnected, note: "Disconnected. Local history is kept."))
        } catch {
            guard active(id: id, operation: operation, generation: current) else { return }
            setState(id, .init(status: .stale, windows: previous?.windows ?? [], updatedAt: previous?.updatedAt,
                               note: "Couldn’t disconnect. Try again."))
        }
    }

    func rename(id: UUID, label: String) async {
        guard canEdit(), validLabel(label), !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await acquireMetadata()
        defer { releaseMetadata() }
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        let renamed = ManagedAccount(id: id, provider: account.provider, label: label, email: account.email,
                                     plan: account.plan, createdAt: account.createdAt, lastVerifiedAt: account.lastVerifiedAt)
        let updated = accounts.map { $0.id == id ? renamed : $0 }
        do { try await save(updated); accounts = updated }
        catch { message = "Account details could not be saved. Reload before making changes." }
    }

    private func client(for account: ManagedAccount) async throws -> any AccountConnecting {
        if let client = clients[account.id] { return client }
        let profile = try await store.profileURL(for: account)
        if let client = clients[account.id] { return client }
        let client = makeClient(account, profile)
        clients[account.id] = client
        return client
    }

    private func accept(_ result: AccountConnectionResult, id: UUID, generation current: UUID,
                        isCurrent: @MainActor () -> Bool) async throws {
        await acquireMetadata()
        defer { releaseMetadata() }
        guard generation == current, isCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard let account = accounts.first(where: { $0.id == id }),
              result.account.id == id, result.account.provider == account.provider else { throw AccountActionError.profileMismatch }
        let verified = account.verified(email: result.account.email, plan: result.account.plan)
        let previous = accounts
        let updated = accounts.map { $0.id == id ? verified : $0 }
        try await save(updated)
        guard generation == current, isCurrent(), !Task.isCancelled else {
            // The metadata gate still excludes every other write. A cancellation
            // during the atomic save restores the previous display metadata.
            try await save(previous)
            throw CancellationError()
        }
        accounts = updated
    }

    private func save(_ accounts: [ManagedAccount]) async throws {
        guard isLoaded, loadError == nil else { throw AccountRegistryError.readFailed }
        do { try await store.save(accounts) }
        catch {
            isLoaded = false
            loadError = "Account details could not be saved. Reload before making changes."
            message = loadError
            throw error
        }
    }

    private func publishProfileRoots(generation current: UUID) async {
        guard isLoaded else { onProfilesChanged?([]); return }
        var roots: [UsageSourceRoot] = []
        for account in accounts {
            do {
                let profile = try await store.profileURL(for: account)
                guard generation == current else { return }
                if account.provider == .codex {
                    roots += [.init(provider: .codex, url: profile.appendingPathComponent("sessions")),
                              .init(provider: .codex, url: profile.appendingPathComponent("archived_sessions"))]
                } else {
                    roots.append(.init(provider: .claudeCode, url: profile.appendingPathComponent("projects")))
                }
            } catch { message = "Some account history folders could not be opened." }
        }
        if generation == current { onProfilesChanged?(roots) }
    }

    private func active(id: UUID, operation: UUID, generation current: UUID) -> Bool {
        generation == current && operations[id] == operation
    }

    private func canEdit() -> Bool {
        guard isLoaded, loadError == nil else {
            message = "Load saved accounts before making changes."
            return false
        }
        return true
    }

    private func validLabel(_ label: String) -> Bool {
        label.count <= 128 && label.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func safeSignInError(_ error: Error) -> String {
        (error as? ManagedAccountClientError)?.localizedDescription
            ?? (error as? AccountRegistryError)?.localizedDescription ?? "Couldn’t sign in. Try reconnecting."
    }

    private func refreshedState(_ result: AccountConnectionResult, previous: AccountRowState?,
                                priorAccount: ManagedAccount) -> AccountRowState {
        if result.quotaRefreshed {
            return .init(status: .connected, windows: result.windows, updatedAt: Date(), note: result.note)
        }
        let sameIdentity = priorAccount.email == result.account.email && priorAccount.plan == result.account.plan
        if sameIdentity, let previous, previous.updatedAt != nil {
            return .init(status: .stale, windows: previous.windows, updatedAt: previous.updatedAt,
                         note: "Couldn’t refresh usage. Showing the last successful reading.")
        }
        return .init(status: .connected, note: result.note ?? "Usage limits could not be refreshed.")
    }

    private func setState(_ id: UUID, _ state: AccountRowState) { states = states.merging([id: state]) { _, new in new } }

    private func acquireMetadata() async {
        if !metadataWriting { metadataWriting = true; isBusy = true; return }
        await withCheckedContinuation { metadataWaiters.append($0) }
    }

    private func releaseMetadata() {
        if metadataWaiters.isEmpty { metadataWriting = false; isBusy = false }
        else { metadataWaiters.removeFirst().resume() }
    }
}
