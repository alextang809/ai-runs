import AIRunsCore
import Foundation

enum QwenAPIPlatform: String, CaseIterable, Codable, Sendable {
    case china, international

    var displayName: String {
        switch self {
        case .china: return "Qwen AI Platform (China)"
        case .international: return "QwenCloud (Singapore)"
        }
    }

    var modelsURL: URL {
        let host = self == .china ? "maas.qianwenaiapi.com" : "maas.qwencloudapi.com"
        return URL(string: "https://\(host)/compatible-mode/v1/models")!
    }
}

struct APIAccountCredentials: Codable, Sendable {
    let key: String
    let qwenPlatform: QwenAPIPlatform?
}

enum APIAccountError: Error, LocalizedError {
    case missingKey, invalidKey, rejectedKey, keychain, invalidResponse, requestFailed, cancelled, busy

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Connect an API key to refresh this account."
        case .invalidKey: return "Enter a valid API key. Qwen requires a standard pay-as-you-go key."
        case .rejectedKey: return "API key rejected. Check the key and its platform or region."
        case .keychain: return "The API key could not be accessed in macOS Keychain."
        case .invalidResponse: return "The provider returned an unexpected response."
        case .requestFailed: return "The provider could not complete the request. Try again."
        case .cancelled: return "Account connection cancelled."
        case .busy: return "An account request is already in progress."
        }
    }
}

actor APIAccountClient: AccountConnecting {
    typealias Transport = @Sendable (URLRequest) async throws -> (Int, Data)

    private let account: ManagedAccount
    private let keyStore: any APIAccountKeyStoring
    private let transport: Transport
    private var activeRequest: Task<String, Error>?

    init(account: ManagedAccount, keyStore: any APIAccountKeyStoring = APIAccountKeychain(),
         transport: @escaping Transport = { try await APIAccountHTTP.get($0) }) {
        self.account = account
        self.keyStore = keyStore
        self.transport = transport
    }

    func connect(onAuthorization: @escaping @Sendable (URL) -> Void) async throws -> AccountConnectionResult {
        throw APIAccountError.missingKey
    }

    func connect(_ credentials: APIAccountCredentials,
                 authorizeSave: @escaping @Sendable () async throws -> Void = {}) async throws -> AccountConnectionResult {
        try await verify(credentials, authorizeSave: authorizeSave)
    }

    func refresh() async throws -> AccountConnectionResult {
        guard let credentials = try keyStore.load(for: account) else { throw APIAccountError.missingKey }
        return try await verify(credentials, authorizeSave: nil)
    }

    func cancel() { activeRequest?.cancel() }

    func disconnect() throws {
        cancel()
        try keyStore.remove(for: account)
    }

    private func verify(_ credentials: APIAccountCredentials,
                        authorizeSave: (@Sendable () async throws -> Void)?) async throws -> AccountConnectionResult {
        guard activeRequest == nil else { throw APIAccountError.busy }
        let key = credentials.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 1_024, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw APIAccountError.invalidKey
        }
        let url: URL
        switch account.provider {
        case .deepseek:
            url = URL(string: "https://api.deepseek.com/user/balance")!
        case .qwen:
            guard let platform = credentials.qwenPlatform, !key.hasPrefix("sk-sp-") else { throw APIAccountError.invalidKey }
            url = platform.modelsURL
        case .codex, .claude, .qwenSubscription:
            throw APIAccountError.invalidKey
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let send = transport, provider = account.provider, authorizedRequest = request
        let task = Task {
            let (status, data) = try await send(authorizedRequest)
            return try Self.summary(provider: provider, status: status, data: data)
        }
        activeRequest = task
        defer { activeRequest = nil }
        let note: String
        do {
            note = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            try await authorizeSave?()
            try Task.checkCancellation()
            guard !task.isCancelled else { throw APIAccountError.cancelled }
        } catch {
            if error is CancellationError || task.isCancelled || Task.isCancelled { throw APIAccountError.cancelled }
            throw error as? APIAccountError ?? APIAccountError.requestFailed
        }
        if authorizeSave != nil {
            try keyStore.save(.init(key: key, qwenPlatform: credentials.qwenPlatform), for: account)
        }
        return AccountConnectionResult(account: account.verified(email: nil, plan: nil), windows: [], note: note)
    }

    private static func summary(provider: AccountProvider, status: Int, data: Data) throws -> String {
        if status == 401 || status == 403 { throw APIAccountError.rejectedKey }
        guard status == 200 else { throw APIAccountError.requestFailed }
        let decoder = JSONDecoder()
        switch provider {
        case .deepseek:
            guard let response = try? decoder.decode(DeepSeekBalance.self, from: data) else {
                throw APIAccountError.invalidResponse
            }
            return try response.summary()
        case .qwen:
            guard let response = try? decoder.decode(QwenModels.self, from: data) else {
                throw APIAccountError.invalidResponse
            }
            return response.summary
        case .codex, .claude, .qwenSubscription:
            throw APIAccountError.invalidResponse
        }
    }
}

private struct DeepSeekBalance: Decodable {
    struct Balance: Decodable {
        let currency: String
        let total_balance: String
    }

    let is_available: Bool
    let balance_infos: [Balance]

    func summary() throws -> String {
        guard balance_infos.count <= 2, Set(balance_infos.map(\.currency)).count == balance_infos.count,
              balance_infos.allSatisfy({ balance in
                  ["CNY", "USD"].contains(balance.currency)
                  && balance.total_balance.utf8.count <= 32
                  && balance.total_balance.range(of: #"\A-?[0-9]+(\.[0-9]+)?\z"#, options: .regularExpression) != nil
              }) else { throw APIAccountError.invalidResponse }
        let balances = balance_infos.map { "\($0.currency) \($0.total_balance)" }.joined(separator: " · ")
        let summary = balances.isEmpty ? "API balance unavailable." : "API balance: \(balances)."
        return is_available ? summary : summary + " Balance is insufficient for API calls."
    }
}

private struct QwenModels: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]

    var summary: String {
        let models = Set(data.map(\.id).filter {
            $0.utf8.count <= 80 && $0.lowercased().hasPrefix("qwen")
                && $0.range(of: #"\A[a-zA-Z0-9._-]+\z"#, options: .regularExpression) != nil
        }).sorted()
        guard !models.isEmpty else { return "API key verified. No Qwen models were returned." }
        let shown = models.prefix(6).joined(separator: ", ")
        return "Qwen models: \(shown)" + (models.count > 6 ? " (+\(models.count - 6) more)" : "")
    }
}

private final class APIAccountHTTP: NSObject, URLSessionTaskDelegate {
    static func get(_ request: URLRequest) async throws -> (Int, Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: APIAccountHTTP(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIAccountError.invalidResponse }
        guard http.statusCode == 200 else { return (http.statusCode, Data()) }
        let maximumBytes = 1_048_576
        guard http.expectedContentLength <= maximumBytes else { throw APIAccountError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw APIAccountError.invalidResponse }
            data.append(byte)
        }
        return (http.statusCode, data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
