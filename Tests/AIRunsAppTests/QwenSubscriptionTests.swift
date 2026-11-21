import AIRunsCore
import Foundation
import XCTest
@testable import AIRunsApp

final class QwenSubscriptionTests: XCTestCase {
    func testFlowOpensOnlyValidatedProviderURLAndReturnsVerifiedMembership() async throws {
        let flow = UUID()
        let browser = URL(string: "https://chat.qwen.ai/authorize?user_code=example")!
        let opened = URLRecorder()
        let protocolClient = QwenSubscriptionSession { method, path in
            switch (method, path) {
            case ("POST", "/auth/subscription/flows?paywallScene=desktop"):
                return Data("{\"id\":\"\(flow)\",\"status\":\"waiting\"}".utf8)
            case ("GET", "/auth/subscription/flows/\(flow)"):
                return Data("{\"id\":\"\(flow)\",\"status\":\"ready\",\"authorizationUrl\":\"\(browser)\",\"userInfo\":{\"member_type\":\"Pro\",\"email\":\"sample@example.test\"}}".utf8)
            default:
                XCTFail("Unexpected request")
                throw ManagedAccountClientError.requestFailed
            }
        }
        let identity = try await protocolClient.signIn { opened.append($0) }
        XCTAssertEqual(opened.urls, [browser])
        XCTAssertEqual(identity.plan, "Pro")
        XCTAssertEqual(identity.email, "sample@example.test")
    }

    func testRefreshAndLogoutUseTheOwnedDaemonContract() async throws {
        let client = QwenSubscriptionSession { method, path in
            switch (method, path) {
            case ("GET", "/auth/subscription"):
                return Data(#"{"enabled":true,"signedIn":true}"#.utf8)
            case ("POST", "/auth/subscription/userinfo"):
                return Data(#"{"member_type":"Plus","email":"sample@example.test"}"#.utf8)
            case ("POST", "/auth/subscription/revoke"):
                return Data()
            default:
                XCTFail("Unexpected request")
                throw ManagedAccountClientError.requestFailed
            }
        }
        let identity = try await client.identity()
        XCTAssertEqual(identity.plan, "Plus")
        try await client.signOut()
    }

    func testSignedOutDaemonIsNotTreatedAsConnected() async throws {
        let client = QwenSubscriptionSession { method, path in
            XCTAssertEqual(method, "GET")
            XCTAssertEqual(path, "/auth/subscription")
            return Data(#"{"enabled":true,"signedIn":false}"#.utf8)
        }
        do {
            _ = try await client.identity()
            XCTFail("Expected a signed-out account")
        } catch {
            XCTAssertEqual(error as? ManagedAccountClientError, .notSignedIn)
        }
    }

    func testSubscriptionProfileUsesItsOwnHomeAndNoInheritedSecrets() {
        let profile = URL(fileURLWithPath: "/tmp/airuns-qwen-test")
        let environment = ManagedAccountClient.scopedEnvironment(provider: .qwenSubscription, profile: profile,
            inherited: ["QWEN_HOME": "/tmp/native", "QWEN_SERVER_TOKEN": "example", "DASHSCOPE_API_KEY": "example",
                        "QWEN_RUNTIME_DIR": "/tmp/native"])
        XCTAssertEqual(environment["QWEN_HOME"], profile.path)
        XCTAssertNil(environment["QWEN_SERVER_TOKEN"])
        XCTAssertNil(environment["DASHSCOPE_API_KEY"])
        XCTAssertNil(environment["QWEN_RUNTIME_DIR"])
    }

    func testRejectsUnownedServerAndAuthorizationAddresses() {
        XCTAssertEqual(QwenSubscriptionSession.port(from: "qwen serve listening on http://127.0.0.1:37801 (mode=http-bridge, workspace=/tmp/test)"), 37801)
        XCTAssertNil(QwenSubscriptionSession.port(from: "qwen serve listening on http://localhost:37801 (mode=http-bridge, workspace=/tmp/test)"))
        XCTAssertNil(QwenSubscriptionSession.port(from: "qwen serve listening on http://127.0.0.1:37801@evil.test (mode=http-bridge, workspace=/tmp/test)"))
        XCTAssertFalse(ManagedAccountClient.isAuthorizationURL(URL(string: "https://chat.qwen.ai.example.test/authorize")!, for: .qwenSubscription))
        XCTAssertFalse(ManagedAccountClient.isAuthorizationURL(URL(string: "https://chat.qwen.ai/settings")!, for: .qwenSubscription))
    }
}

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []
    func append(_ url: URL) { lock.withLock { values.append(url) } }
    var urls: [URL] { lock.withLock { values } }
}
