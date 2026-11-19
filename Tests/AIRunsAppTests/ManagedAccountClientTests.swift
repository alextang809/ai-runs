import AIRunsCore
import Foundation
import Darwin
import XCTest
@testable import AIRunsApp

final class ManagedAccountClientTests: XCTestCase {
    private final class URLs: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []
        func append(_ url: URL) { lock.lock(); stored.append(url); lock.unlock() }
        var values: [URL] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private final class WeakProcess {
        weak var value: ManagedAccountProcess?
        init(_ value: ManagedAccountProcess?) { self.value = value }
    }

    private func client(_ mode: String, provider: AccountProvider = .codex,
                        timeout: TimeInterval = 2) throws -> (ManagedAccountClient, URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("airuns-account-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let account = ManagedAccount(provider: provider, label: "Sample")
        let profile = try AccountRegistry(root: root.appendingPathComponent("accounts")).profileURL(for: account)
        let executable = root.appendingPathComponent(mode)
        try Data(Self.fakeCLI.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ManagedAccountClient(account: account, profileURL: profile, executableURL: executable,
                                          requestTimeout: timeout, authorizationTimeout: 2)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        addTeardownBlock { await client.cancel() }
        return (client, profile)
    }

    func testCodexConnectHandlesOutOfOrderCompletionAndRealQuotaWindows() async throws {
        let (client, profile) = try client("rpc_out_of_order"), urls = URLs()
        let result = try await client.connect { urls.append($0) }
        XCTAssertEqual(result.account.email, "sample@example.test")
        XCTAssertEqual(result.windows.map(\.usedPercent).sorted(), [0, 25])
        XCTAssertEqual(urls.values.count, 1)
        XCTAssertEqual(urls.values.first?.host, "auth.openai.com")
        let calls = try String(contentsOf: profile.appendingPathComponent("calls.jsonl"))
        XCTAssertTrue(calls.contains("cli_auth_credentials_store"))
        XCTAssertTrue(calls.contains("\"profile_matches_cwd\": true"))
        XCTAssertFalse(calls.contains("thread/start"))
        XCTAssertFalse(calls.contains("turn/start"))
        try await client.disconnect()
        XCTAssertTrue(try String(contentsOf: profile.appendingPathComponent("calls.jsonl")).contains("account/logout"))
    }

    func testMissingQuotaRemainsUnavailableRatherThanZero() async throws {
        let (client, _) = try client("rpc_quota_missing")
        let result = try await client.connect { _ in }
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertNotNil(result.note)
        XCTAssertTrue(result.quotaRefreshed)
    }

    func testQuotaFailureIsDistinctFromFreshExplicitUnavailability() async throws {
        let (client, _) = try client("rpc_quota_error")
        let result = try await client.connect { _ in }
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertFalse(result.quotaRefreshed)
        XCTAssertFalse(result.note?.contains("fixture-private-error") ?? true)
    }

    func testInvalidAuthorizationHostNeverReachesCallback() async throws {
        let (client, _) = try client("rpc_bad_url"), urls = URLs()
        do { _ = try await client.connect { urls.append($0) }; XCTFail("Expected rejected URL") }
        catch { XCTAssertEqual(error as? ManagedAccountClientError, .invalidAuthorizationURL) }
        XCTAssertTrue(urls.values.isEmpty)
    }

    func testLoginFailureDoesNotExposeProviderErrorText() async throws {
        let (client, _) = try client("rpc_failure")
        do { _ = try await client.connect { _ in }; XCTFail("Expected login failure") }
        catch {
            XCTAssertEqual(error as? ManagedAccountClientError, .authorizationRejected)
            XCTAssertFalse(error.localizedDescription.contains("fixture-private-error"))
        }
    }

    func testCancelStopsPendingLoginAndRejectsLateCompletion() async throws {
        let (client, profile) = try client("rpc_pending"), opened = expectation(description: "Authorization URL")
        let task = Task { try await client.connect { _ in opened.fulfill() } }
        await fulfillment(of: [opened], timeout: 2)
        await client.cancel()
        do { _ = try await task.value; XCTFail("A cancelled login must not become connected") }
        catch { XCTAssertEqual(error as? ManagedAccountClientError, .cancelled) }
        let calls = try String(contentsOf: profile.appendingPathComponent("calls.jsonl"))
        XCTAssertTrue(calls.contains("account/login/cancel"))
        XCTAssertFalse(calls.contains("account/read"), "Late completion must not restart account work after cancel")
    }

    func testRPCRequestsHaveBoundedTimeouts() async throws {
        let (client, _) = try client("rpc_timeout", timeout: 0.1)
        let started = ProcessInfo.processInfo.systemUptime
        do { _ = try await client.connect { _ in }; XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ManagedAccountClientError, .timedOut) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
    }

    func testClaudeSubscriptionConnectVerifiesItsOwnProfileWithoutInventedQuota() async throws {
        let (client, profile) = try client("claude_success", provider: .claude), urls = URLs()
        let result = try await client.connect { urls.append($0) }
        XCTAssertEqual(result.account.email, "sample@example.test")
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertNotNil(result.note)
        XCTAssertEqual(urls.values.first?.host, "claude.ai")
        XCTAssertTrue(try String(contentsOf: profile.appendingPathComponent("calls.jsonl")).contains("--claudeai"))
        try await client.disconnect()
    }

    func testClaudeWrongProfileAndConsoleIdentityAreRejected() async throws {
        for mode in ["claude_wrong_profile", "claude_console"] {
            let (client, _) = try client(mode, provider: .claude)
            do { _ = try await client.connect { _ in }; XCTFail("Expected isolated subscription account") }
            catch {
                let kind = error as? ManagedAccountClientError
                XCTAssertTrue(kind == .profileMismatch || kind == .unsupportedAccount)
            }
        }
    }

    func testSplitClaudeAuthorizationOutputOpensOnlyTheCompleteURL() async throws {
        let (client, _) = try client("claude_split", provider: .claude), urls = URLs()
        _ = try await client.connect { urls.append($0) }
        XCTAssertEqual(urls.values.count, 1)
        XCTAssertEqual(urls.values.first?.query, "sample=true")
    }

    func testClaudeManualCodeUsesOnlyOwnedLoginInput() async throws {
        let (client, _) = try client("claude_manual", provider: .claude)
        let opened = expectation(description: "Claude URL")
        let task = Task { try await client.connect { _ in opened.fulfill() } }
        await fulfillment(of: [opened], timeout: 2)
        do { try await client.submitCode("fixture-code\nextra"); XCTFail("Expected single code") }
        catch { XCTAssertEqual(error as? ManagedAccountClientError, .invalidCode) }
        try await client.submitCode("fixture-code")
        let result = try await task.value
        XCTAssertEqual(result.account.email, "sample@example.test")
    }

    func testSynchronousShutdownStopsOnlyTrackedAccountProcesses() async throws {
        let (client, profile) = try client("rpc_pending"), opened = expectation(description: "Owned login")
        let task = Task { try await client.connect { _ in opened.fulfill() } }
        await fulfillment(of: [opened], timeout: 2)
        let executable = profile.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("observer_sleep")
        try Data(Self.fakeCLI.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let unrelated = Process()
        unrelated.executableURL = executable
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }
        let started = ProcessInfo.processInfo.systemUptime
        ManagedAccountClient.terminateOwnedProcesses()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertTrue(unrelated.isRunning)
        do { _ = try await task.value; XCTFail("Expected stopped account process") }
        catch { XCTAssertTrue(error is ManagedAccountClientError) }
    }

    func testOversizedProviderOutputIsStoppedWithoutLeakingIt() async throws {
        let (client, _) = try client("rpc_flood")
        do { _ = try await client.connect { _ in }; XCTFail("Expected output limit") }
        catch { XCTAssertEqual(error as? ManagedAccountClientError, .outputLimit) }
    }

    func testCancelledReleasedOwnerStillKillsCLIThatIgnoresTermination() async throws {
        let (_, profile) = try client("rpc_ignore_term")
        let container = profile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = container.appendingPathComponent("rpc_ignore_term")
        var child: ManagedAccountProcess? = ManagedAccountProcess()
        let weakChild = WeakProcess(child)
        try await child?.start(executable: executable, arguments: [],
            environment: ManagedAccountClient.scopedEnvironment(provider: .codex, profile: profile), directory: profile)
        defer { ManagedAccountClient.terminateOwnedProcesses() }
        let pidFile = profile.appendingPathComponent("owned.pid")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pidText = try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)
        let ownedPID = try XCTUnwrap(pid_t(pidText))
        let observer = container.appendingPathComponent("observer_sleep")
        try Data(Self.fakeCLI.utf8).write(to: observer)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: observer.path)
        let unrelated = Process()
        unrelated.executableURL = observer
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }

        await child?.stop()
        child = nil
        try await Task.sleep(nanoseconds: 1_400_000_000)

        let exists = kill(ownedPID, 0), existenceError = errno
        XCTAssertEqual(exists, -1, "The CLI must really exit after its owner is released")
        XCTAssertEqual(existenceError, ESRCH)
        XCTAssertNil(weakChild.value)
        XCTAssertTrue(unrelated.isRunning, "Cleanup must not touch an unrelated fake process")
    }

    func testMalformedQuotaNumbersStayUnavailable() async throws {
        let (client, _) = try client("rpc_quota_invalid")
        let result = try await client.connect { _ in }
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.quotaRefreshed)
    }

    func testBooleanResetAndDurationAreNotInterpretedAsNumbers() async throws {
        for mode in ["rpc_quota_optional_invalid", "rpc_quota_optional_extreme"] {
            let (client, _) = try client(mode)
            let result = try await client.connect { _ in }
            XCTAssertEqual(result.windows.first?.usedPercent, 25)
            XCTAssertNil(result.windows.first?.durationMinutes)
            XCTAssertNil(result.windows.first?.resetsAt)
        }
    }

    func testScopedEnvironmentPreservesHomeAndRemovesCredentialAndProviderOverrides() {
        let profile = URL(fileURLWithPath: "/tmp/owned-profile")
        let environment = ManagedAccountClient.scopedEnvironment(provider: .codex, profile: profile, inherited: [
            "HOME": "/tmp/original-home", "PATH": "/usr/bin", "OPENAI_API_KEY": "fixture-key",
            "ANTHROPIC_AUTH_TOKEN": "fixture-token", "CODEX_HOME": "/tmp/native-profile",
            "CLAUDE_CONFIG_DIR": "/tmp/native-claude", "ANTHROPIC_BASE_URL": "https://example.test",
            "CLAUDE_CODE_USE_BEDROCK": "1", "AWS_PROFILE": "sample", "XDG_CONFIG_HOME": "/tmp/config"
            , "TOKEN": "fixture-token", "API_BASE_URL": "https://example.test", "NODE_OPTIONS": "--require=fixture"
        ])
        XCTAssertEqual(environment["HOME"], "/tmp/original-home")
        XCTAssertEqual(environment["CODEX_HOME"], profile.path)
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(environment["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(environment["ANTHROPIC_BASE_URL"])
        XCTAssertNil(environment["CLAUDE_CODE_USE_BEDROCK"])
        XCTAssertNil(environment["AWS_PROFILE"])
        XCTAssertNil(environment["XDG_CONFIG_HOME"])
        XCTAssertNil(environment["TOKEN"])
        XCTAssertNil(environment["API_BASE_URL"])
        XCTAssertNil(environment["NODE_OPTIONS"])
    }

    func testOnlyExactOfficialHTTPSAuthorizationHostsAreAccepted() {
        for value in ["http://auth.openai.com/oauth", "https://auth.openai.com.example.test/oauth",
                      "https://person@auth.openai.com/oauth", "https://auth.openai.com:8443/oauth"] {
            XCTAssertFalse(ManagedAccountClient.isAuthorizationURL(URL(string: value)!, for: .codex))
        }
        XCTAssertTrue(ManagedAccountClient.isAuthorizationURL(URL(string: "https://chatgpt.com/oauth")!, for: .codex))
        XCTAssertFalse(ManagedAccountClient.isAuthorizationURL(URL(string: "https://console.anthropic.com/oauth")!, for: .claude))
    }

    private static let fakeCLI = #"""
    #!/usr/bin/python3
    import json, os, signal, sys, time
    mode = os.path.basename(sys.argv[0])
    if mode == "observer_sleep": time.sleep(30); sys.exit(0)
    profile = os.environ.get("CODEX_HOME") or os.environ.get("CLAUDE_CONFIG_DIR")
    def log(value):
        with open(os.path.join(profile, "calls.jsonl"), "a") as stream:
            stream.write(json.dumps(value) + "\n")
    log({"args":sys.argv[1:], "profile_matches_cwd":os.getcwd() == profile})
    if mode == "rpc_ignore_term":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        temporary = os.path.join(profile, "owned.pid.tmp")
        with open(temporary, "w") as stream: stream.write(str(os.getpid()))
        os.replace(temporary, os.path.join(profile, "owned.pid"))
        print("ready", flush=True)
        while True: time.sleep(1)
    if mode.startswith("claude_"):
        if "login" in sys.argv:
            if mode == "claude_split":
                print("https://claude.ai/oauth/authorize?sample=", end="", flush=True)
                time.sleep(0.08)
                print("true", flush=True)
            else: print("https://claude.ai/oauth/authorize?sample=true", flush=True)
            if mode == "claude_manual":
                if sys.stdin.readline().strip() != "fixture-code": sys.exit(1)
        elif "status" in sys.argv:
            print(json.dumps({"loggedIn":True, "authMethod":"api_key" if mode == "claude_console" else "claude.ai",
                 "configDirectory":"/tmp/other-profile" if mode == "claude_wrong_profile" else profile,
                 "email":"sample@example.test", "subscriptionType":"sample"}), flush=True)
        sys.exit(0)
    def emit(value): print(json.dumps(value), flush=True)
    if mode == "rpc_flood": print("x" * 400000, flush=True); time.sleep(1)
    for line in sys.stdin:
        request = json.loads(line)
        method, request_id = request.get("method"), request.get("id")
        log({"method":method})
        if method == "initialized": continue
        result = {}
        if method == "initialize": result = {"userAgent":"sample"}
        elif method == "account/login/start":
            if mode == "rpc_timeout": time.sleep(30)
            result = {"type":"chatgpt", "loginId":"sample-login", "authUrl":
                "https://example.test/oauth" if mode == "rpc_bad_url" else "https://auth.openai.com/oauth/authorize?sample=true"}
            if mode == "rpc_out_of_order":
                emit({"method":"account/login/completed", "params":{"loginId":"other-login", "success":False}})
                emit({"method":"account/login/completed", "params":{"loginId":"sample-login", "success":True}})
        elif method == "account/read": result = {"account":{"type":"chatgpt", "email":"sample@example.test", "planType":"sample"}}
        elif method == "account/rateLimits/read":
            if mode == "rpc_quota_optional_extreme":
                emit({"id":request_id,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":9223372036854775807,"resetsAt":1e300}}}})
                continue
            if mode == "rpc_quota_optional_invalid":
                emit({"id":request_id,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":True,"resetsAt":False}}}})
                continue
            if mode == "rpc_quota_error":
                emit({"id":request_id, "error":{"code":-32000, "message":"fixture-private-error"}})
                continue
            if mode == "rpc_quota_invalid":
                emit({"id":request_id, "result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":True},"secondary":{"usedPercent":"22"}}}}})
                continue
            result = {} if mode == "rpc_quota_missing" else {"rateLimits":{"primary":{"usedPercent":99}}, "rateLimitsByLimitId":{
                "codex":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000000}},
                "other":{"secondary":{"usedPercent":0,"windowDurationMins":10080}}}}
        elif method == "account/login/cancel" and mode == "rpc_pending":
            emit({"method":"account/login/completed", "params":{"loginId":"sample-login", "success":True}})
        emit({"id":request_id,"result":result})
        if method == "account/login/start" and mode not in ("rpc_out_of_order", "rpc_pending"):
            emit({"method":"account/login/completed", "params":{"loginId":"sample-login", "success":mode != "rpc_failure", "error":"fixture-private-error"}})
    """#
}
