import AIRunsCore
import CoreFoundation
import Darwin
import Foundation

public enum ManagedAccountClientError: Error, LocalizedError, Equatable, Sendable {
    case cliUnavailable, launchFailed, unsafeProfile, invalidResponse, requestFailed
    case timedOut, cancelled, outputLimit, authorizationRejected, invalidAuthorizationURL
    case notSignedIn, unsupportedAccount, profileMismatch, busy, invalidCode

    public var errorDescription: String? {
        switch self {
        case .cliUnavailable: return "Install the provider's command-line app before connecting this account."
        case .launchFailed: return "The provider's command-line app could not be started."
        case .unsafeProfile: return "This account needs a private AI Runs profile without symbolic links."
        case .invalidResponse: return "The provider returned an unsupported response. Update its command-line app and retry."
        case .requestFailed: return "The provider could not complete this request. Please retry."
        case .timedOut: return "The account request timed out. Please retry."
        case .cancelled: return "Account connection cancelled."
        case .outputLimit: return "The provider returned too much output. The account process was stopped."
        case .authorizationRejected: return "The account sign-in was not completed."
        case .invalidAuthorizationURL: return "The provider returned an unrecognized sign-in address."
        case .notSignedIn: return "Sign in to this account again."
        case .unsupportedAccount: return "Use a ChatGPT or claude.ai subscription account for this connection."
        case .profileMismatch: return "The provider could not confirm this isolated account profile. Update its command-line app."
        case .busy: return "An account request is already in progress."
        case .invalidCode: return "Enter the single authorization code shown by the provider."
        }
    }
}

/// Each client is scoped to one AI Runs-owned CLI profile. Native credentials are
/// never imported or read; only the provider CLI performs login and logout.
public actor ManagedAccountClient {
    private var account: ManagedAccount
    private let profileURL: URL
    private let executableURL: URL?
    private let requestTimeout: TimeInterval
    private let authorizationTimeout: TimeInterval
    private var rpc: ManagedAccountRPC?
    private var command: ManagedAccountProcess?
    private var loginID: String?
    private var operation = UUID()
    private var connecting = false, refreshing = false, disconnecting = false

    public init(account: ManagedAccount, profileURL: URL, executableURL: URL? = nil,
                requestTimeout: TimeInterval = 30, authorizationTimeout: TimeInterval = 300) {
        self.account = account
        self.profileURL = profileURL
        self.executableURL = executableURL
        self.requestTimeout = Self.bounded(requestTimeout, maximum: 60)
        self.authorizationTimeout = Self.bounded(authorizationTimeout, maximum: 600)
    }

    public nonisolated static func terminateOwnedProcesses() { OwnedAccountProcesses.shared.terminateAll() }

    public nonisolated static func isAuthorizationURL(_ url: URL, for provider: AccountProvider) -> Bool {
        let hosts: Set<String> = provider == .codex ? ["chatgpt.com", "auth.openai.com"] : ["claude.ai"]
        return url.scheme?.lowercased() == "https" && hosts.contains(url.host?.lowercased() ?? "")
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }

    public func connect(onAuthorization: @escaping @Sendable (URL) -> Void) async throws -> AccountConnectionResult {
        guard !connecting, !refreshing, !disconnecting else { throw ManagedAccountClientError.busy }
        try validateProfile()
        operation = UUID()
        let token = operation
        connecting = true
        defer { if operation == token { connecting = false; loginID = nil } }
        do {
            let result: AccountConnectionResult
            switch account.provider {
            case .codex: result = try await connectCodex(onAuthorization: onAuthorization)
            case .claude:
                try prepareClaudeProfile()
                let guardedAuthorization: @Sendable (URL) async -> Void = { url in
                    await self.deliverAuthorization(url, token: token, callback: onAuthorization)
                }
                _ = try await runCommand(["auth", "login", "--claudeai"], timeout: authorizationTimeout,
                                         onAuthorization: guardedAuthorization)
                guard operation == token, !Task.isCancelled else { throw ManagedAccountClientError.cancelled }
                result = try await readClaudeAccount()
            }
            guard operation == token, !Task.isCancelled else { throw ManagedAccountClientError.cancelled }
            account = result.account
            return result
        } catch {
            if operation == token { await cancel() }
            throw Self.safe(error)
        }
    }

    public func refresh() async throws -> AccountConnectionResult {
        guard !connecting, !refreshing, !disconnecting else { throw ManagedAccountClientError.busy }
        try validateProfile()
        let token = operation
        refreshing = true
        defer { refreshing = false }
        do {
            let result = try await (account.provider == .codex ? readCodexAccount() : readClaudeAccount())
            guard operation == token, !Task.isCancelled else { throw ManagedAccountClientError.cancelled }
            account = result.account
            return result
        } catch {
            if operation == token { await cancel() }
            throw Self.safe(error)
        }
    }

    public func cancel() async {
        operation = UUID()
        connecting = false
        let active = rpc
        rpc = nil
        let activeCommand = command
        command = nil
        let currentLogin = loginID
        loginID = nil
        if let active, let currentLogin {
            let parameters = try? JSONSerialization.data(withJSONObject: ["loginId": currentLogin])
            _ = try? await active.request("account/login/cancel", parameters: parameters, timeout: min(requestTimeout, 2))
        }
        await active?.stop()
        await activeCommand?.stop()
    }

    public func disconnect() async throws {
        guard !disconnecting else { throw ManagedAccountClientError.busy }
        disconnecting = true
        defer { disconnecting = false }
        await cancel()
        try validateProfile()
        if account.provider == .codex {
            let server = try await codexServer()
            do { _ = try await server.request("account/logout", timeout: requestTimeout) }
            catch { await server.stop(); rpc = nil; throw Self.safe(error) }
            await server.stop()
            rpc = nil
        } else {
            _ = try await runCommand(["auth", "logout"], timeout: requestTimeout)
        }
    }

    public func submitCode(_ code: String) async throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard account.provider == .claude, connecting, let command,
              !trimmed.isEmpty, trimmed.utf8.count <= 8_192,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { throw ManagedAccountClientError.invalidCode }
        try await command.send(Data((trimmed + "\n").utf8))
    }

    private func connectCodex(onAuthorization: @escaping @Sendable (URL) -> Void) async throws -> AccountConnectionResult {
        let token = operation
        let server = try await codexServer()
        let parameters = try JSONSerialization.data(withJSONObject: ["type": "chatgpt"])
        let started = try Self.object(await server.request("account/login/start", parameters: parameters, timeout: requestTimeout))
        guard operation == token, !Task.isCancelled else { throw ManagedAccountClientError.cancelled }
        guard let id = Self.text(started["loginId"]), let rawURL = Self.text(started["authUrl"], limit: 16_384),
              let url = URL(string: rawURL), Self.isAuthorizationURL(url, for: .codex) else {
            throw ManagedAccountClientError.invalidAuthorizationURL
        }
        loginID = id
        onAuthorization(url)
        let completed = try Self.object(await server.waitFor("account/login/completed", matching: ["loginId": id],
                                                             timeout: authorizationTimeout))
        guard operation == token, !Task.isCancelled else { throw ManagedAccountClientError.cancelled }
        guard Self.boolean(completed["success"]) == true else { throw ManagedAccountClientError.authorizationRejected }
        loginID = nil
        return try await readCodexAccount()
    }

    private func codexServer() async throws -> ManagedAccountRPC {
        let token = operation
        if let rpc {
            let open = await rpc.isOpen()
            guard operation == token else { throw ManagedAccountClientError.cancelled }
            if open { return rpc }
            self.rpc = nil
        }
        let child = try await startProcess(["-c", "cli_auth_credentials_store=\"file\"", "app-server"])
        let server = ManagedAccountRPC(child: child)
        rpc = server
        await server.beginReading()
        do {
            let parameters = try JSONSerialization.data(withJSONObject: [
                "clientInfo": ["name": "ai_runs", "title": "AI Runs", "version": "1.0"],
                "capabilities": ["experimentalApi": false]
            ])
            _ = try await server.request("initialize", parameters: parameters, timeout: requestTimeout)
            try await server.notify("initialized")
            return server
        } catch {
            await server.stop()
            if rpc === server { rpc = nil }
            throw Self.safe(error)
        }
    }

    private func readCodexAccount() async throws -> AccountConnectionResult {
        let server = try await codexServer()
        let parameters = try JSONSerialization.data(withJSONObject: ["refreshToken": false])
        let value = try Self.object(await server.request("account/read", parameters: parameters, timeout: requestTimeout))
        guard let identity = value["account"] as? [String: Any] else { throw ManagedAccountClientError.notSignedIn }
        guard identity["type"] as? String == "chatgpt" else { throw ManagedAccountClientError.unsupportedAccount }
        let verified = account.verified(email: Self.text(identity["email"], limit: 320), plan: Self.text(identity["planType"]))
        do {
            let quotas = try Self.object(await server.request("account/rateLimits/read", timeout: requestTimeout))
            let windows = Self.rateWindows(quotas)
            return AccountConnectionResult(account: verified, windows: windows,
                note: windows.isEmpty ? "Usage limits are unavailable for this account." : nil)
        } catch is CancellationError { throw ManagedAccountClientError.cancelled }
        catch let error as ManagedAccountClientError where error == .cancelled { throw error }
        catch { return AccountConnectionResult(account: verified, windows: [], note: "Usage limits could not be refreshed.", quotaRefreshed: false) }
    }

    private func readClaudeAccount() async throws -> AccountConnectionResult {
        let output = try await runCommand(["auth", "status", "--json"], timeout: requestTimeout)
        let status = try Self.object(output)
        guard Self.boolean(status["loggedIn"]) == true else { throw ManagedAccountClientError.notSignedIn }
        guard status["authMethod"] as? String == "claude.ai" else { throw ManagedAccountClientError.unsupportedAccount }
        guard let directory = Self.text(status["configDirectory"], limit: 8_192),
              URL(fileURLWithPath: directory).standardizedFileURL.path == profileURL.standardizedFileURL.path else {
            throw ManagedAccountClientError.profileMismatch
        }
        let verified = account.verified(email: Self.text(status["email"], limit: 320), plan: Self.text(status["subscriptionType"]))
        return AccountConnectionResult(account: verified, windows: [],
            note: "Connected. Claude does not expose usage limits through its documented sign-in commands.")
    }

    private func startProcess(_ arguments: [String]) async throws -> ManagedAccountProcess {
        let token = operation
        try validateProfile()
        let executable = try Self.resolveExecutable(provider: account.provider, override: executableURL)
        let child = ManagedAccountProcess()
        try await child.start(executable: executable, arguments: arguments,
                              environment: Self.scopedEnvironment(provider: account.provider, profile: profileURL),
                              directory: profileURL)
        guard operation == token, !Task.isCancelled else {
            await child.stop()
            throw ManagedAccountClientError.cancelled
        }
        return child
    }

    private func runCommand(_ arguments: [String], timeout: TimeInterval,
                            onAuthorization: (@Sendable (URL) async -> Void)? = nil) async throws -> Data {
        let token = operation
        let child = try await startProcess(arguments)
        command = child
        let provider = account.provider
        do {
            let output = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await Self.collectCommand(child, provider: provider, onAuthorization: onAuthorization) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await child.stop(.timedOut)
                    throw ManagedAccountClientError.timedOut
                }
                guard let value = try await group.next() else { throw ManagedAccountClientError.requestFailed }
                group.cancelAll()
                return value
            }
            if operation == token { command = nil }
            return output
        } catch {
            await child.stop(Self.safe(error))
            if operation == token { command = nil }
            throw Self.safe(error)
        }
    }

    private func validateProfile() throws {
        let path = profileURL.standardizedFileURL
        guard let resolved = realpath(path.path, nil) else { throw ManagedAccountClientError.unsafeProfile }
        defer { free(resolved) }
        guard path.isFileURL, Self.physicalPath(path.path) == String(cString: resolved),
              path.lastPathComponent == account.id.uuidString.lowercased(),
              path.deletingLastPathComponent().lastPathComponent == account.provider.rawValue else {
            throw ManagedAccountClientError.unsafeProfile
        }
        for folder in [path, path.deletingLastPathComponent(), path.deletingLastPathComponent().deletingLastPathComponent()] {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: folder.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0 else { throw ManagedAccountClientError.unsafeProfile }
        }
    }

    private func prepareClaudeProfile() throws {
        let settings = profileURL.appendingPathComponent("settings.json")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: settings.path),
           attributes[.type] as? FileAttributeType != .typeRegular { throw ManagedAccountClientError.unsafeProfile }
        let data = Data(#"{"forceLoginMethod":"claudeai"}"#.utf8)
        do {
            try data.write(to: settings, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        } catch { throw ManagedAccountClientError.unsafeProfile }
    }

    private static func collectCommand(_ child: ManagedAccountProcess, provider: AccountProvider,
                                       onAuthorization: (@Sendable (URL) async -> Void)?) async throws -> Data {
        var output = Data(), lineBuffer = Data(), seen: Set<URL> = []
        for await event in child.events {
            try Task.checkCancellation()
            switch event {
            case .output(let data):
                output.append(data)
                guard output.count <= 262_144 else { throw ManagedAccountClientError.outputLimit }
                if let onAuthorization {
                    lineBuffer.append(data)
                    while let end = lineBuffer.firstIndex(of: 0x0A) {
                        let text = String(decoding: lineBuffer.prefix(upTo: end), as: UTF8.self)
                        lineBuffer.removeSubrange(...end)
                        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
                        for match in detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
                            guard let url = match.url, isAuthorizationURL(url, for: provider),
                                  url.path.hasPrefix("/oauth/authorize"), seen.insert(url).inserted else { continue }
                            await onAuthorization(url)
                        }
                    }
                }
            case .exited(let status):
                guard status == 0 else { throw ManagedAccountClientError.requestFailed }
                return output
            case .failed(let error): throw error
            }
        }
        throw ManagedAccountClientError.requestFailed
    }

    static func scopedEnvironment(provider: AccountProvider, profile: URL,
                                  inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let allowed: Set<String> = ["HOME", "PATH", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM", "COLORTERM", "NO_COLOR",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"]
        var result = inherited.filter { name, _ in
            allowed.contains(name) || name.hasPrefix("LC_")
        }
        result[provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] = profile.path
        return result
    }

    private func deliverAuthorization(_ url: URL, token: UUID, callback: @Sendable (URL) -> Void) {
        guard operation == token, connecting else { return }
        callback(url)
    }

    private static func physicalPath(_ path: String) -> String {
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { return "/private" + path }
        return path
    }

    private static func resolveExecutable(provider: AccountProvider, override: URL?) throws -> URL {
        if let override {
            guard override.isFileURL, FileManager.default.isExecutableFile(atPath: override.path) else {
                throw ManagedAccountClientError.cliUnavailable
            }
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path]
        var candidates = paths.map { URL(fileURLWithPath: $0).appendingPathComponent(provider.rawValue) }
        if provider == .codex {
            candidates += [URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
                           home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex")]
        }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw ManagedAccountClientError.cliUnavailable
        }
        return executable
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManagedAccountClientError.invalidResponse
        }
        return value
    }

    private static func text(_ value: Any?, limit: Int = 256) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= limit,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func number(_ value: Any?) -> NSNumber? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value
    }

    private static func bounded(_ value: TimeInterval, maximum: Double) -> TimeInterval {
        max(0.05, min(value.isFinite ? value : 30, maximum))
    }

    private static func safe(_ error: Error) -> ManagedAccountClientError {
        error as? ManagedAccountClientError ?? (error is CancellationError ? .cancelled : .requestFailed)
    }

    private static func rateWindows(_ object: [String: Any]) -> [AccountRateWindow] {
        var groups = object["rateLimitsByLimitId"] as? [String: Any] ?? [:]
        if groups.isEmpty, let legacy = object["rateLimits"] as? [String: Any] { groups["codex"] = legacy }
        return groups.keys.sorted().prefix(8).flatMap { key -> [AccountRateWindow] in
            guard let group = groups[key] as? [String: Any] else { return [] }
            return ["primary", "secondary"].compactMap { lane in
                guard let raw = group[lane] as? [String: Any], let percent = number(raw["usedPercent"]) else { return nil }
                let duration = number(raw["windowDurationMins"]).flatMap { Int($0.stringValue) }
                    .flatMap { (1...525_600).contains($0) ? $0 : nil }
                let seconds = number(raw["resetsAt"])?.doubleValue
                let reset = seconds.flatMap { (-62_135_596_800...253_402_300_799).contains($0) ? Date(timeIntervalSince1970: $0) : nil }
                let name = text(group["limitName"]) ?? key
                let title = duration == 300 ? "5-hour" : (duration == 10_080 ? "Weekly" : lane.capitalized)
                return AccountRateWindow(id: "\(key):\(lane)", title: groups.count > 1 ? "\(name) · \(title)" : title,
                                         usedPercent: percent.doubleValue, durationMinutes: duration, resetsAt: reset)
            }
        }
    }
}
