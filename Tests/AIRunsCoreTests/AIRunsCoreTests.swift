import Foundation
import XCTest
@testable import AIRunsCore

final class EventParserTests: XCTestCase {
    private func line(tool: String, payload: [String: Any], env: [String: String] = [:], tty: String? = nil,
                      at: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> Data {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return HookRecord.makeLine(tool: tool, payload: data, environment: env, tty: tty, receivedAt: at)
    }

    func testClaudePromptSubmit() throws {
        let data = line(tool: "claude-code",
                        payload: ["session_id": "abc", "hook_event_name": "UserPromptSubmit",
                                  "prompt": "Refactor the login flow", "cwd": "/Users/me/web-app"],
                        env: ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:XYZ", "HOME": "/x"],
                        tty: "/dev/ttys004")
        let event = try XCTUnwrap(EventParser.parse(line: data))
        XCTAssertEqual(event.tool, .claudeCode)
        XCTAssertEqual(event.kind, .promptStart)
        XCTAssertEqual(event.sessionId, "abc")
        XCTAssertEqual(event.prompt, "Refactor the login flow")
        XCTAssertEqual(event.cwd, "/Users/me/web-app")
        XCTAssertEqual(event.terminal.itermSessionId, "w0t1p0:XYZ")
        XCTAssertEqual(event.terminal.tty, "/dev/ttys004")
        XCTAssertEqual(event.terminal.appName, "iTerm2")
        XCTAssertEqual(event.at, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testCodexStopCarriesLastMessage() throws {
        let data = line(tool: "codex", payload: ["session_id": "s1", "hook_event_name": "Stop", "turn_id": "t1",
                                                 "last_assistant_message": "Done. Want tests too?",
                                                 "stop_hook_active": false])
        let event = try XCTUnwrap(EventParser.parse(line: data))
        XCTAssertEqual(event.tool, .codex)
        XCTAssertEqual(event.kind, .turnEnd)
        XCTAssertEqual(event.lastMessage, "Done. Want tests too?")
    }

    func testStopWithRunningBackgroundTaskKeepsWorking() throws {
        let data = line(tool: "claude-code", payload: [
            "session_id": "a", "hook_event_name": "Stop", "last_assistant_message": "Tests still running.",
            "background_tasks": [["id": "b1", "status": "running", "type": "shell"],
                                 ["id": "b2", "status": "completed", "type": "shell"]],
        ])
        let event = try XCTUnwrap(EventParser.parse(line: data))
        XCTAssertEqual(event.backgroundTasks, 1)
        var store = SessionStore()
        store.apply(event)
        let session = try XCTUnwrap(store.sessions["claude-code:a"])
        XCTAssertEqual(session.state, .working)
        XCTAssertTrue(session.isInBackground)
        XCTAssertEqual(store.needsUserCount, 0)
    }

    func testPermissionRequestUsesCommand() throws {
        let data = line(tool: "codex", payload: ["session_id": "s1", "hook_event_name": "PermissionRequest",
                                                 "tool_name": "Bash", "tool_input": ["command": "prisma migrate deploy"]])
        let event = try XCTUnwrap(EventParser.parse(line: data))
        XCTAssertEqual(event.kind, .needsApproval)
        XCTAssertEqual(event.approvalDetail, "prisma migrate deploy")
    }

    func testOnlyPermissionNotificationsCount() {
        let idle = line(tool: "claude-code", payload: ["session_id": "a", "hook_event_name": "Notification",
                                                       "notification_type": "idle_prompt", "message": "Waiting"])
        XCTAssertNil(EventParser.parse(line: idle))
        let permission = line(tool: "claude-code", payload: ["session_id": "a", "hook_event_name": "Notification",
                                                             "notification_type": "permission_prompt",
                                                             "message": "Claude needs your permission to use Bash"])
        XCTAssertEqual(EventParser.parse(line: permission)?.kind, .needsApproval)
    }

    func testRejectsUnknownToolsAndGarbage() {
        XCTAssertNil(EventParser.parse(line: line(tool: "other", payload: ["session_id": "a", "hook_event_name": "Stop"])))
        XCTAssertNil(EventParser.parse(line: Data("not json".utf8)))
        XCTAssertNil(EventParser.parse(line: line(tool: "codex", payload: ["hook_event_name": "Stop"])))
    }

    func testNonJSONPayloadIsKeptRaw() throws {
        let data = HookRecord.makeLine(tool: "codex", payload: Data("oops".utf8), environment: [:], tty: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["payload"] as? [String: Any])?["raw"] as? String, "oops")
    }
}

final class SessionStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ kind: EventKind, _ id: String = "s1", tool: AgentTool = .claudeCode, minutes: Double,
                       prompt: String? = nil, last: String? = nil) -> AgentEvent {
        AgentEvent(tool: tool, kind: kind, sessionId: id, at: t0.addingTimeInterval(minutes * 60), prompt: prompt,
                   lastMessage: last, cwd: "/Users/me/web-app")
    }

    func testLifecycle() throws {
        var store = SessionStore()
        store.apply(event(.promptStart, minutes: 0, prompt: "Refactor login"))
        var session = try XCTUnwrap(store.sessions["claude-code:s1"])
        XCTAssertEqual(session.state, .working)
        XCTAssertEqual(session.title, "Refactor login")
        XCTAssertEqual(session.project, "web-app")

        store.apply(event(.needsApproval, minutes: 5))
        XCTAssertEqual(store.sessions["claude-code:s1"]?.state, .needsApproval)

        store.apply(event(.toolActivity, minutes: 6))
        XCTAssertEqual(store.sessions["claude-code:s1"]?.state, .working)

        store.apply(event(.turnEnd, minutes: 10, last: "All done. Add tests?"))
        session = try XCTUnwrap(store.sessions["claude-code:s1"])
        XCTAssertEqual(session.state, .yourTurn)
        XCTAssertEqual(session.waitingSince, t0.addingTimeInterval(600))
        XCTAssertEqual(session.lastMessage, "All done. Add tests?")

        // Replying starts a new turn on the same session, title unchanged.
        store.apply(event(.promptStart, minutes: 12, prompt: "yes please"))
        session = try XCTUnwrap(store.sessions["claude-code:s1"])
        XCTAssertEqual(session.state, .working)
        XCTAssertEqual(session.title, "Refactor login")
        XCTAssertNil(session.waitingSince)

        store.apply(event(.sessionEnd, minutes: 20))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testToolActivityCreatesWorkingSessionForUnseenSession() throws {
        // A session that started before the hooks were installed.
        var store = SessionStore()
        store.apply(event(.toolActivity, minutes: 0))
        let session = try XCTUnwrap(store.sessions["claude-code:s1"])
        XCTAssertEqual(session.state, .working)
        XCTAssertTrue(session.hasGenericTitle)
        XCTAssertEqual(session.project, "web-app")
    }

    func testStopWithoutPromptCreatesSession() {
        var store = SessionStore()
        store.apply(event(.turnEnd, tool: .codex, minutes: 0, last: "Finished"))
        XCTAssertEqual(store.sessions["codex:s1"]?.title, "Codex session")
        XCTAssertEqual(store.sessions["codex:s1"]?.state, .yourTurn)
    }

    func testOrderingPutsLongestWaitingFirst() {
        var store = SessionStore()
        store.apply(event(.promptStart, "working", minutes: 0, prompt: "w"))
        store.apply(event(.promptStart, "turnLate", minutes: 0, prompt: "a"))
        store.apply(event(.turnEnd, "turnLate", minutes: 30))
        store.apply(event(.promptStart, "turnEarly", minutes: 0, prompt: "b"))
        store.apply(event(.turnEnd, "turnEarly", minutes: 10))
        store.apply(event(.promptStart, "approval", minutes: 0, prompt: "c"))
        store.apply(event(.needsApproval, "approval", minutes: 40))
        XCTAssertEqual(store.ordered().map(\.sessionId), ["approval", "turnEarly", "turnLate", "working"])
        XCTAssertEqual(store.needsUserCount, 3)
        XCTAssertEqual(store.workingCount, 1)
    }

    func testResolveRenameAndPrune() {
        var store = SessionStore()
        store.apply(event(.promptStart, "a", minutes: 0, prompt: "x"))
        store.apply(event(.promptStart, "b", minutes: 0, prompt: "y"))
        store.rename(id: "claude-code:a", to: "  New name ")
        XCTAssertEqual(store.sessions["claude-code:a"]?.title, "New name")
        store.resolve(id: "claude-code:a")
        XCTAssertNil(store.sessions["claude-code:a"])
        store.pruneStale(now: t0.addingTimeInterval(25 * 3600))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testQuietSession() throws {
        var store = SessionStore()
        store.apply(event(.promptStart, minutes: 0, prompt: "x"))
        let session = try XCTUnwrap(store.sessions["claude-code:s1"])
        XCTAssertFalse(session.isQuiet(now: t0.addingTimeInterval(10 * 60)))
        XCTAssertTrue(session.isQuiet(now: t0.addingTimeInterval(31 * 60)))
    }

    func testCodable() throws {
        var store = SessionStore()
        store.apply(event(.promptStart, minutes: 0, prompt: "x"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try JSONFile.save(store, to: url)
        XCTAssertEqual(JSONFile.load(SessionStore.self, from: url), store)
    }
}

final class TextUtilsTests: XCTestCase {
    func testTitleCleansPrompt() {
        XCTAssertEqual(TextUtils.title(fromPrompt: "  Fix   the\nbug ```let x = 1``` please "), "Fix the bug please")
        XCTAssertEqual(TextUtils.title(fromPrompt: "   "), "Untitled session")
        let long = String(repeating: "word ", count: 30)
        XCTAssertTrue(TextUtils.title(fromPrompt: long).hasSuffix("…"))
        XCTAssertLessThanOrEqual(TextUtils.title(fromPrompt: long).count, 49)
    }

    func testCleanPromptRemovesInjectedTags() {
        XCTAssertEqual(TextUtils.cleanPrompt("<system-reminder>ctx</system-reminder>\n<ide_opened_file path=\"a\">x</ide_opened_file> Fix the login bug"),
                       "Fix the login bug")
        XCTAssertNil(TextUtils.cleanPrompt("<task-notification><status>done</status></task-notification>"))
        XCTAssertEqual(TextUtils.title(fromPrompt: "<command-name>/clear</command-name>"), "Untitled session")
    }

    func testGenericTitleIsReplacedByLaterPrompt() throws {
        var store = SessionStore()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        store.apply(AgentEvent(tool: .claudeCode, kind: .turnEnd, sessionId: "s", at: t))
        store.apply(AgentEvent(tool: .claudeCode, kind: .promptStart, sessionId: "s", at: t, prompt: "<x>noise</x>"))
        XCTAssertEqual(store.sessions["claude-code:s"]?.title, "Claude Code session")
        store.apply(AgentEvent(tool: .claudeCode, kind: .promptStart, sessionId: "s", at: t, prompt: "Add export to PDF"))
        XCTAssertEqual(store.sessions["claude-code:s"]?.title, "Add export to PDF")
        store.apply(AgentEvent(tool: .claudeCode, kind: .promptStart, sessionId: "s", at: t, prompt: "something else"))
        XCTAssertEqual(store.sessions["claude-code:s"]?.title, "Add export to PDF")
    }

    func testLastQuestion() {
        XCTAssertEqual(TextUtils.lastQuestion(in: "Done. I updated 6 files. Want me to add tests next?"),
                       "Want me to add tests next?")
        XCTAssertNil(TextUtils.lastQuestion(in: "All done."))
        XCTAssertEqual(TextUtils.lastQuestion(in: "改好了。要不要加测试？"), "要不要加测试？")
    }

    func testDurations() {
        XCTAssertEqual(TextUtils.duration(20), "now")
        XCTAssertEqual(TextUtils.duration(9 * 60), "9m")
        XCTAssertEqual(TextUtils.duration(65 * 60), "1h 05m")
        XCTAssertEqual(TextUtils.duration(50 * 3600), "2d 2h")
        XCTAssertEqual(TextUtils.age(5 * 3600), "5h")
        XCTAssertEqual(TextUtils.age(80 * 3600), "3d")
    }
}

final class PinBoardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testGroupsAndStaleCards() {
        var board = PinBoard()
        board.add(PinCard(title: "Fresh idea", createdAt: now.addingTimeInterval(-3600)))
        board.add(PinCard(title: "Login", group: "web-app", createdAt: now.addingTimeInterval(-7200)))
        board.add(PinCard(title: "Old", group: "web-app", createdAt: now.addingTimeInterval(-4 * 24 * 3600)))
        let groups = board.groups(now: now)
        XCTAssertEqual(groups.map(\.name), ["Inbox", "web-app"])
        XCTAssertEqual(groups[1].cards.map(\.title), ["Login"])
        XCTAssertEqual(board.staleCards(now: now).map(\.title), ["Old"])

        let old = board.staleCards(now: now)[0]
        board.touch(id: old.id, now: now)
        XCTAssertTrue(board.staleCards(now: now).isEmpty)

        board.archive(id: old.id)
        XCTAssertNil(board.card(id: old.id))
        XCTAssertEqual(board.archived.first?.title, "Old")
    }

    func testPinSessionSuggestsNextStepAndDoesNotDuplicate() {
        var store = SessionStore()
        store.apply(AgentEvent(tool: .claudeCode, kind: .promptStart, sessionId: "s", at: now, prompt: "Refactor login",
                               cwd: "/Users/me/web-app"))
        store.apply(AgentEvent(tool: .claudeCode, kind: .turnEnd, sessionId: "s", at: now,
                               lastMessage: "Split auth into hooks. Want me to add tests next?"))
        let session = store.sessions["claude-code:s"]!
        var board = PinBoard()
        let card = board.pin(session: session, now: now)
        XCTAssertEqual(card.title, "Refactor login")
        XCTAssertEqual(card.group, "web-app")
        XCTAssertEqual(card.next, "Want me to add tests next?")
        XCTAssertTrue(card.nextIsSuggested)
        board.pin(session: session, now: now)
        XCTAssertEqual(board.cards.count, 1)
    }

    func testUpdateClearsSuggestionFlag() {
        var board = PinBoard()
        let card = PinCard(title: "x", next: "Suggested?", nextIsSuggested: true)
        board.add(card)
        board.update(id: card.id, next: "My own step", group: "  ")
        XCTAssertEqual(board.card(id: card.id)?.next, "My own step")
        XCTAssertEqual(board.card(id: card.id)?.nextIsSuggested, false)
        XCTAssertEqual(board.card(id: card.id)?.group, "Inbox")
    }

    func testHandoff() {
        let card = PinCard(title: "Pricing copy", next: "Pick a version", excerpt: "Lead with the free tier.")
        let text = PinBoard.handoff(for: card)
        XCTAssertTrue(text.contains("Pricing copy"))
        XCTAssertTrue(text.contains("Lead with the free tier."))
        XCTAssertTrue(text.contains("Next step: Pick a version"))
    }
}

final class TranscriptReaderTests: XCTestCase {
    private func write(_ lines: [[String: Any]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n")
        try Data(text.utf8).write(to: url)
        return url
    }

    func testClaudeTranscriptSkipsMetaAndCommands() throws {
        let url = try write([
            ["type": "summary", "summary": "x"],
            ["type": "user", "isMeta": true, "message": ["role": "user", "content": "Caveat: local commands"]],
            ["type": "user", "message": ["role": "user", "content": "<command-name>/clear</command-name>"]],
            ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "<ide_selection>code</ide_selection>"],
                                                                     ["type": "text", "text": "Add dark mode to settings"]]]],
            ["type": "user", "message": ["role": "user", "content": "second prompt"]],
        ])
        XCTAssertEqual(TranscriptReader.firstUserPrompt(at: url), "Add dark mode to settings")
    }

    func testCodexRollout() throws {
        let url = try write([
            ["type": "session_meta", "payload": ["id": "x"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                                                  "content": [["type": "input_text", "text": "<environment_context>cwd</environment_context>"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                                                  "content": [["type": "input_text", "text": "Write tests for the parser"]]]],
        ])
        XCTAssertEqual(TranscriptReader.firstUserPrompt(at: url), "Write tests for the parser")
    }

    func testMissingFile() {
        XCTAssertNil(TranscriptReader.firstUserPrompt(at: URL(fileURLWithPath: "/nonexistent/file.jsonl")))
    }
}

final class EventLogTests: XCTestCase {
    func testReaderHandlesPartialLinesAndTruncation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let reader = EventLogReader(url: url)
        XCTAssertEqual(reader.readNewLines(), [])

        try EventLogWriter.append(Data("one".utf8), to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tw".utf8))
        XCTAssertEqual(reader.readNewLines().map { String(decoding: $0, as: UTF8.self) }, ["one"])
        try handle.write(contentsOf: Data("o\n".utf8))
        try handle.close()
        XCTAssertEqual(reader.readNewLines().map { String(decoding: $0, as: UTF8.self) }, ["two"])

        try Data("three\n".utf8).write(to: url)
        XCTAssertEqual(reader.readNewLines().map { String(decoding: $0, as: UTF8.self) }, ["three"])
    }

    func testPathsHonourEnvironment() {
        let paths = AIRunsPaths(environment: ["AIRUNS_HOME": "/tmp/airuns-test"])
        XCTAssertEqual(paths.events.path, "/tmp/airuns-test/events.jsonl")
        XCTAssertEqual(paths.hookHelper.path, "/tmp/airuns-test/bin/airuns-hook")
    }
}

final class HookInstallerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testToolNotFound() {
        XCTAssertEqual(HookInstaller(home: home).status(for: .codex), .toolNotFound)
    }

    func testInstallKeepsUserHooksAndIsIdempotent() throws {
        let installer = HookInstaller(home: home)
        let claudeDir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "afplay ping.aiff"]]]]],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: claudeDir.appendingPathComponent("settings.json"))
        XCTAssertEqual(installer.status(for: .claudeCode), .notInstalled)

        let helper = URL(fileURLWithPath: "/Users/me/.airuns/bin/airuns-hook")
        try installer.install(tool: .claudeCode, helper: helper)
        try installer.install(tool: .claudeCode, helper: helper)
        XCTAssertEqual(installer.status(for: .claudeCode), .installed)

        let config = try installer.readConfig(for: .claudeCode)
        XCTAssertEqual(config["model"] as? String, "opus")
        let hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2, "user hook kept, ours added once")
        let notification = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        XCTAssertEqual(notification.first?["matcher"] as? String, "permission_prompt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeDir.appendingPathComponent("settings.json.airuns-backup").path))

        try installer.uninstall(tool: .claudeCode)
        let after = try installer.readConfig(for: .claudeCode)
        let afterHooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        XCTAssertEqual(Array(afterHooks.keys), ["Stop"])
        XCTAssertEqual(installer.status(for: .claudeCode), .notInstalled)
    }

    func testCodexInstallCreatesHooksFile() throws {
        let installer = HookInstaller(home: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try installer.install(tool: .codex, helper: URL(fileURLWithPath: "/Users/my name/.airuns/bin/airuns-hook"))
        XCTAssertEqual(installer.status(for: .codex), .installed)
        let hooks = try XCTUnwrap(try installer.readConfig(for: .codex)["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let handler = try XCTUnwrap((stop.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(handler["command"] as? String, "'/Users/my name/.airuns/bin/airuns-hook' codex")
        try installer.uninstall(tool: .codex)
        XCTAssertNil(try installer.readConfig(for: .codex)["hooks"])
    }

    func testRefusesInvalidJSON() throws {
        let installer = HookInstaller(home: home)
        let dir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try installer.install(tool: .claudeCode, helper: URL(fileURLWithPath: "/x/airuns-hook")))
    }
}
