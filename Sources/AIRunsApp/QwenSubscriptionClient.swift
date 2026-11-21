import AIRunsCore
import Foundation

/// The Qwen Code daemon owns device polling, refresh tokens and revocation.
actor QwenSubscriptionClient: AccountConnecting {
    private let account: ManagedAccount
    private let profile: URL
    private var operation: Task<AccountConnectionResult, Error>?

    init(account: ManagedAccount, profile: URL) {
        self.account = account
        self.profile = profile
    }

    func connect(onAuthorization: @escaping @Sendable (URL) -> Void) async throws -> AccountConnectionResult {
        try await run { try await $0.signIn(onAuthorization: onAuthorization) }
    }

    func refresh() async throws -> AccountConnectionResult {
        try await run { try await $0.identity() }
    }

    func cancel() { operation?.cancel() }

    func disconnect() async throws {
        _ = try await run { session in
            try await session.signOut()
            return .init()
        }
    }

    private func run(_ action: @escaping @Sendable (QwenSubscriptionSession) async throws -> QwenSubscriptionIdentity)
        async throws -> AccountConnectionResult {
        guard operation == nil else { throw ManagedAccountClientError.busy }
        let account = self.account, profile = self.profile
        let task = Task {
            let identity = try await QwenSubscriptionDaemon.perform(account: account, profile: profile, action: action)
            try Task.checkCancellation()
            return AccountConnectionResult(account: account.verified(email: identity.email, plan: identity.plan),
                windows: [], note: "Connected through Qwen Code. Subscription limits are unavailable.")
        }
        operation = task
        defer { operation = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

struct QwenSubscriptionIdentity: Decodable, Sendable {
    var email: String?
    var member_type: String?

    var plan: String? { member_type }

    func validated() throws -> Self {
        guard let member_type, !member_type.isEmpty, member_type.count <= 128,
              member_type.rangeOfCharacter(from: .controlCharacters) == nil,
              email.map({ $0.count <= 320 && $0.rangeOfCharacter(from: .controlCharacters) == nil }) ?? true
        else { throw ManagedAccountClientError.invalidResponse }
        return self
    }
}

struct QwenSubscriptionSession: Sendable {
    typealias Request = @Sendable (String, String) async throws -> Data
    let request: Request

    private struct State: Decodable { let enabled: Bool; let signedIn: Bool }
    private struct Flow: Decodable {
        let id: String
        let status: String
        let authorizationUrl: URL?
        let userInfo: QwenSubscriptionIdentity?
    }

    func signIn(onAuthorization: @escaping @Sendable (URL) -> Void) async throws -> QwenSubscriptionIdentity {
        let flow = try await decode(Flow.self, "POST", "/auth/subscription/flows?paywallScene=desktop")
        guard UUID(uuidString: flow.id) != nil else { throw ManagedAccountClientError.invalidResponse }
        let path = "/auth/subscription/flows/\(flow.id)"
        do {
            return try await waitForSignIn(path, id: flow.id, onAuthorization: onAuthorization)
        } catch {
            if !Task.isCancelled { _ = try? await request("DELETE", path) }
            throw error
        }
    }

    private func waitForSignIn(_ path: String, id: String, onAuthorization: @Sendable (URL) -> Void)
        async throws -> QwenSubscriptionIdentity {
        let deadline = ContinuousClock.now + .seconds(600)
        var opened = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let update = try await decode(Flow.self, "GET", path)
            guard update.id == id else { throw ManagedAccountClientError.invalidResponse }
            if let url = update.authorizationUrl, !opened {
                guard ManagedAccountClient.isAuthorizationURL(url, for: .qwenSubscription)
                else { throw ManagedAccountClientError.invalidAuthorizationURL }
                try Task.checkCancellation()
                onAuthorization(url)
                opened = true
            }
            switch update.status {
            case "ready":
                guard opened, let identity = update.userInfo else { throw ManagedAccountClientError.invalidResponse }
                return try identity.validated()
            case "waiting":
                try await Task.sleep(for: .seconds(1))
            case "error":
                throw ManagedAccountClientError.authorizationRejected
            default:
                throw ManagedAccountClientError.invalidResponse
            }
        }
        throw ManagedAccountClientError.timedOut
    }

    func identity() async throws -> QwenSubscriptionIdentity {
        let state = try await decode(State.self, "GET", "/auth/subscription")
        guard state.enabled else { throw ManagedAccountClientError.unsupportedAccount }
        guard state.signedIn, let identity = try await decode(QwenSubscriptionIdentity?.self, "POST", "/auth/subscription/userinfo")
        else { throw ManagedAccountClientError.notSignedIn }
        return try identity.validated()
    }

    func signOut() async throws {
        _ = try await request("POST", "/auth/subscription/revoke")
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ method: String, _ path: String) async throws -> Value {
        let data = try await request(method, path)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ManagedAccountClientError.invalidResponse }
    }

    static func port(from line: String) -> Int? {
        let prefix = "qwen serve listening on http://127.0.0.1:"
        guard line.hasPrefix(prefix), let boundary = line.range(of: " (mode=http-bridge, workspace=")
        else { return nil }
        let digits = line[line.index(line.startIndex, offsetBy: prefix.count)..<boundary.lowerBound]
        guard let port = Int(digits), (1...65_535).contains(port), String(port) == digits else { return nil }
        return port
    }
}
