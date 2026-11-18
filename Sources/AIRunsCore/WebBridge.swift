import Foundation

/// The browser extension talks to AI Runs through Chrome's native messaging:
/// the browser starts `airuns-hook` with the extension's origin as its
/// argument and sends one length-prefixed JSON message on stdin.
///
/// Messages: `{"site": "chatgpt"|"claude", "event": "start"|"stop"|"title"|"ping",
/// "conversation": id, "url", "title", "prompt", "reply"}`.
public enum WebBridge {
    /// The name browsers look up the connector by.
    public static let hostName = "io.github.alextang809.airuns"
    /// Fixed by the public key in the extension's manifest.
    public static let extensionID = "cgcadenphemidecnlmjniciiknpkmipn"
    public static var allowedOrigin: String { "chrome-extension://\(extensionID)/" }

    /// Reads one message: a 4-byte little-endian length, then that many bytes.
    public static func readMessage(_ read: (Int) -> Data) -> Data? {
        let header = read(4)
        guard header.count == 4 else { return nil }
        let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length > 0, length < 1_048_576 else { return nil }
        let body = read(length)
        return body.count == length ? body : nil
    }

    public static func frame(_ object: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var length = UInt32(body.count).littleEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Turns a message into a hook-style record: the tool's raw value and a
    /// payload EventParser understands. Nil for pings and anything unknown.
    public static func record(from message: [String: Any]) -> (tool: AgentTool, payload: [String: Any])? {
        let tool: AgentTool
        switch message["site"] as? String {
        case "chatgpt": tool = .chatgpt
        case "claude": tool = .claudeWeb
        default: return nil
        }
        guard let conversation = message["conversation"] as? String, !conversation.isEmpty else { return nil }
        let name: String
        switch message["event"] as? String {
        case "start": name = "UserPromptSubmit"
        case "stop": name = "Stop"
        case "title": name = "TitleUpdate"
        default: return nil
        }
        var payload: [String: Any] = ["session_id": conversation, "hook_event_name": name]
        if let url = message["url"] as? String { payload["url"] = url }
        if let title = message["title"] as? String { payload["title"] = title }
        if let prompt = message["prompt"] as? String, !prompt.isEmpty { payload["prompt"] = prompt }
        if let reply = message["reply"] as? String, !reply.isEmpty { payload["last_assistant_message"] = reply }
        return (tool, payload)
    }
}

/// Tells Chromium browsers that the AI Runs extension may start the helper:
/// a small JSON file in each browser's `NativeMessagingHosts` folder.
public struct BrowserConnector {
    public struct Browser: Equatable, Sendable {
        public var name: String
        /// Under ~/Library/Application Support.
        public var folder: String
    }

    public static let browsers: [Browser] = [
        Browser(name: "Chrome", folder: "Google/Chrome"),
        Browser(name: "Chrome Beta", folder: "Google/Chrome Beta"),
        Browser(name: "Chrome Canary", folder: "Google/Chrome Canary"),
        Browser(name: "Arc", folder: "Arc/User Data"),
        Browser(name: "Brave", folder: "BraveSoftware/Brave-Browser"),
        Browser(name: "Edge", folder: "Microsoft Edge"),
        Browser(name: "Vivaldi", folder: "Vivaldi"),
        Browser(name: "Chromium", folder: "Chromium"),
    ]

    let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    private func manifestURL(for browser: Browser) -> URL {
        home.appendingPathComponent("Library/Application Support")
            .appendingPathComponent(browser.folder, isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(WebBridge.hostName).json")
    }

    private func browserExists(_ browser: Browser) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(for: browser)
            .deletingLastPathComponent().deletingLastPathComponent().path)
    }

    public static func manifest(helper: URL) -> [String: Any] {
        [
            "name": WebBridge.hostName,
            "description": "AI Runs: follows your ChatGPT and Claude chats",
            "path": helper.path,
            "type": "stdio",
            "allowed_origins": [WebBridge.allowedOrigin],
        ]
    }

    /// Installed browsers, and whether each is connected to this helper.
    public func status(helper: URL) -> [(browser: Browser, connected: Bool)] {
        Self.browsers.filter(browserExists).map { browser in
            let data = try? Data(contentsOf: manifestURL(for: browser))
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (browser, object?["path"] as? String == helper.path)
        }
    }

    /// Writes the connector for every installed browser. Returns their names.
    @discardableResult
    public func install(helper: URL) throws -> [String] {
        let data = try JSONSerialization.data(withJSONObject: Self.manifest(helper: helper),
                                              options: [.prettyPrinted, .sortedKeys])
        var names: [String] = []
        for browser in Self.browsers where browserExists(browser) {
            let url = manifestURL(for: browser)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            names.append(browser.name)
        }
        return names
    }

    public func uninstall() {
        for browser in Self.browsers { try? FileManager.default.removeItem(at: manifestURL(for: browser)) }
    }
}
