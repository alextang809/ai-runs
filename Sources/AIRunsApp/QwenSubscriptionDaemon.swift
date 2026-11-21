import AIRunsCore
import Foundation

enum QwenSubscriptionDaemon {
    static func perform(account: ManagedAccount, profile: URL,
                        action: @Sendable (QwenSubscriptionSession) async throws -> QwenSubscriptionIdentity)
        async throws -> QwenSubscriptionIdentity {
        try ManagedAccountClient.validateProfile(account: account, profileURL: profile)
        let executable = try ManagedAccountClient.resolveExecutable(provider: .qwenSubscription, override: nil)
        let token = UUID().uuidString + UUID().uuidString
        let scoped = ManagedAccountClient.scopedEnvironment(provider: .qwenSubscription, profile: profile,
            executableDirectory: executable.deletingLastPathComponent())
        let environment = scoped.merging([
            "HOME": profile.path,
            "QWEN_SERVER_TOKEN": token,
            "QWEN_RUNTIME_DIR": profile.path,
            "QWEN_CONVERSATIONS_DIR": profile.appendingPathComponent("conversations").path
        ]) { _, value in value }
        let child = ManagedAccountProcess()
        try Task.checkCancellation()
        try await child.start(executable: executable,
            arguments: ["serve", "--hostname", "127.0.0.1", "--port", "0", "--require-auth", "--no-web", "--max-sessions", "1"],
            environment: environment, directory: profile)
        do {
            let port = try await discoverPort(child)
            let http = QwenLoopbackClient(port: port, token: token)
            defer { http.invalidate() }
            try await http.verifyAuthentication()
            let result = try await action(QwenSubscriptionSession { method, path in
                try await http.request(method, path)
            })
            await child.stop()
            return result
        } catch {
            await child.stop()
            throw error
        }
    }

    private static func discoverPort(_ child: ManagedAccountProcess) async throws -> Int {
        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                var buffer = Data()
                for await event in child.events {
                    try Task.checkCancellation()
                    guard case let .output(bytes) = event else { break }
                    buffer.append(bytes)
                    guard buffer.count <= 131_072 else { throw ManagedAccountClientError.outputLimit }
                    while let end = buffer.firstIndex(of: 10) {
                        let line = String(decoding: buffer[..<end], as: UTF8.self)
                        buffer.removeSubrange(...end)
                        if let port = QwenSubscriptionSession.port(from: line) { return port }
                    }
                }
                throw ManagedAccountClientError.launchFailed
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw ManagedAccountClientError.timedOut
            }
            defer { group.cancelAll() }
            guard let port = try await group.next() else { throw ManagedAccountClientError.launchFailed }
            return port
        }
    }
}

private final class QwenLoopbackClient: Sendable {
    private struct Capabilities: Decodable { let features: [String] }

    private let session: URLSession
    private let base: String
    private let token: String

    init(port: Int, token: String) {
        self.base = "http://127.0.0.1:\(port)"
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": false, "HTTPSEnable": false, "SOCKSEnable": false]
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration, delegate: RejectQwenRedirects(), delegateQueue: nil)
    }

    deinit { invalidate() }

    func invalidate() { session.invalidateAndCancel() }

    func verifyAuthentication() async throws {
        let data = try await request("GET", "/capabilities")
        guard let capabilities = try? JSONDecoder().decode(Capabilities.self, from: data),
              capabilities.features.contains("require_auth") else { throw ManagedAccountClientError.invalidResponse }
    }

    func request(_ method: String, _ path: String) async throws -> Data {
        guard let url = URL(string: base + path), url.host == "127.0.0.1", url.scheme == "http"
        else { throw ManagedAccountClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ManagedAccountClientError.invalidResponse }
        if http.statusCode == 404 { throw ManagedAccountClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ManagedAccountClientError.requestFailed }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 262_144 else { throw ManagedAccountClientError.outputLimit }
            data.append(byte)
        }
        return data
    }
}

private final class RejectQwenRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
