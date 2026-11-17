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

    func testUserRenameIsNotOverwrittenBySuggestions() {
        var store = SessionStore()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        store.apply(AgentEvent(tool: .codex, kind: .promptStart, sessionId: "s", at: t, prompt: "<wake reason=\"mention\"> fix flaky test"))
        XCTAssertEqual(store.sessions["codex:s"]?.title, "fix flaky test")
        XCTAssertEqual(store.sessions["codex:s"]?.firstPrompt, "fix flaky test")
        store.setSuggestedTitle(id: "codex:s", to: "Flaky test fix")
        XCTAssertEqual(store.sessions["codex:s"]?.title, "Flaky test fix")
        store.rename(id: "codex:s", to: "Mine")
        store.setSuggestedTitle(id: "codex:s", to: "Something else")
        XCTAssertEqual(store.sessions["codex:s"]?.title, "Mine")
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

    func testToolTitleTakesTheLatestSummary() throws {
        let url = try write([
            ["type": "summary", "summary": "Old name"],
            ["type": "user", "message": ["role": "user", "content": "hi"]],
            ["type": "summary", "summary": "Login refactor"],
        ])
        XCTAssertEqual(TranscriptReader.toolTitle(at: url), "Login refactor")
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

final class ActivityTests: XCTestCase {
    func testShellCommandsInWords() {
        XCTAssertEqual(ActivityDescriber.describe(command: "cd /x && xcodebuild -scheme App build"), "Building")
        XCTAssertEqual(ActivityDescriber.describe(command: "xcodebuild -scheme App test"), "Running tests")
        XCTAssertEqual(ActivityDescriber.describe(command: "swift test 2>&1 | tail"), "Running tests")
        XCTAssertEqual(ActivityDescriber.describe(command: "cat tests/fixtures.json"), "Reading files")
        XCTAssertEqual(ActivityDescriber.describe(command: "git commit -m x"), "Committing")
        XCTAssertEqual(ActivityDescriber.describe(command: "rg TODO Sources"), "Searching the code")
        XCTAssertEqual(ActivityDescriber.describe(command: "/usr/local/bin/ffmpeg -i a.mov"), "Running ffmpeg")
    }

    func testToolsInWords() {
        XCTAssertEqual(ActivityDescriber.describe(toolName: "Edit", input: ["file_path": "/a/b/PanelViews.swift"]), "Editing PanelViews.swift")
        XCTAssertEqual(ActivityDescriber.describe(toolName: "Read", input: [:]), "Reading files")
        XCTAssertEqual(ActivityDescriber.describe(toolName: "mcp__claude-code-remote__send_message", input: nil), "Using claude-code-remote")
        XCTAssertEqual(ActivityDescriber.describe(toolName: "shell", input: ["command": ["bash", "-lc", "npm test"]]), "Running tests")
        XCTAssertEqual(ActivityDescriber.describe(toolName: "apply_patch", input: ["input": "*** Begin Patch\n*** Update File: src/app.ts\n"]), "Editing app.ts")
    }

    func testProgressFromTodoWriteAndPlan() {
        let todos: [String: Any] = ["todos": [
            ["content": "Read code", "activeForm": "Reading code", "status": "completed"],
            ["content": "Build lens", "activeForm": "Building the lens", "status": "in_progress"],
            ["content": "Test", "activeForm": "Testing", "status": "pending"],
        ]]
        XCTAssertEqual(ActivityDescriber.progress(toolName: "TodoWrite", input: todos),
                       RunProgress(done: 1, total: 3, current: "Building the lens"))
        let plan: [String: Any] = ["plan": [["step": "One", "status": "completed"], ["step": "Two", "status": "pending"]]]
        XCTAssertEqual(ActivityDescriber.progress(toolName: "update_plan", input: plan)?.summary, "1/2 · Two")
        XCTAssertNil(ActivityDescriber.progress(toolName: "Bash", input: ["command": "ls"]))
    }

    func testRelaySource() {
        XCTAssertEqual(TextUtils.relaySource(in: "<relay from=\"coordinator\" session=\"s1\">do it</relay>"), "coordinator")
        XCTAssertNil(TextUtils.relaySource(in: "fix the bug"))
    }

    private func event(_ kind: EventKind, at seconds: TimeInterval, tool: AgentTool = .claudeCode,
                       activity: String? = nil, progress: RunProgress? = nil, prompt: String? = nil,
                       drivenBy: String? = nil) -> AgentEvent {
        AgentEvent(tool: tool, kind: kind, sessionId: "s1", at: Date(timeIntervalSince1970: seconds), prompt: prompt,
                   activity: activity, progress: progress, drivenBy: drivenBy)
    }

    func testStoreTracksActivityProgressAndDriver() {
        var store = SessionStore()
        XCTAssertNil(store.lastSeen(.claudeCode))
        store.apply(event(.promptStart, at: 0, prompt: "<relay from=\"coordinator\">x</relay>", drivenBy: "coordinator"))
        var session = store.sessions.values.first!
        XCTAssertEqual(session.activity, "Thinking")
        XCTAssertEqual(session.drivenBy, "coordinator")
        store.apply(event(.toolActivity, at: 5, activity: "Building", progress: RunProgress(done: 1, total: 2, current: "B")))
        session = store.sessions.values.first!
        XCTAssertEqual(session.activity, "Building")
        XCTAssertEqual(session.progress?.summary, "1/2 · B")
        store.apply(event(.turnEnd, at: 9))
        session = store.sessions.values.first!
        XCTAssertNil(session.activity)
        XCTAssertNotNil(session.progress, "unfinished plans stay")
        XCTAssertEqual(store.lastSeen(.claudeCode), Date(timeIntervalSince1970: 9))
        XCTAssertNil(store.lastSeen(.codex))
    }

    func testSettledTitleRespectsRename() {
        var store = SessionStore()
        store.apply(event(.promptStart, at: 0, prompt: "fix the login bug"))
        let id = store.sessions.keys.first!
        store.settleTitle(id: id, to: "Login bug")
        XCTAssertEqual(store.sessions[id]?.title, "Login bug")
        XCTAssertEqual(store.sessions[id]?.titleSettled, true)
        store.rename(id: id, to: "Mine")
        store.settleTitle(id: id, to: "Other")
        XCTAssertEqual(store.sessions[id]?.title, "Mine")
    }

    func testOldSessionsFileStillLoads() throws {
        let json = """
        {"sessions":{"claude-code:s1":{"tool":"claude-code","sessionId":"s1","title":"T","state":"working",
        "startedAt":0,"turnStartedAt":0,"lastEventAt":0,"terminal":{}}}}
        """
        let store = try JSONDecoder().decode(SessionStore.self, from: Data(json.utf8))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertNil(store.lastSeen(.claudeCode))
    }

    func testParserFillsActivity() {
        let payload: [String: Any] = ["session_id": "s1", "hook_event_name": "PostToolUse", "tool_name": "Bash",
                                      "tool_input": ["command": "cd x && swift build"]]
        let parsed = EventParser.parse(tool: .claudeCode, payload: payload, at: Date(), terminal: TerminalContext())
        XCTAssertEqual(parsed?.activity, "Building")
    }
}

final class ClaudeDesktopIndexTests: XCTestCase {
    func testParsesOnlyWhatItNeedsAndJoinsOnCLIId() throws {
        let object: [String: Any] = ["sessionId": "local_abc", "cliSessionId": "84e0", "title": " Lens work ",
                                     "isArchived": false, "lastActivityAt": 1_700_000_000_000.0,
                                     "prompt": "private"]
        let session = try XCTUnwrap(ClaudeDesktopIndex.parse(object: object))
        XCTAssertEqual(session.title, "Lens work")
        XCTAssertEqual(session.lastActivityAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(ClaudeDesktopIndex.session(forCLI: "84e0", in: [session])?.sessionId, "local_abc")
        XCTAssertNil(ClaudeDesktopIndex.session(forCLI: "other", in: [session]))
        XCTAssertNil(ClaudeDesktopIndex.parse(object: ["title": "no id"]))
    }

    func testLoadsFromDiskAndFillsLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("x/y", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"sessionId":"local_1","cliSessionId":"c1","title":"T"}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("local_1.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("other.json"))
        let sessions = ClaudeDesktopIndex.load(root: root)
        XCTAssertEqual(sessions.map(\.sessionId), ["local_1"])
        XCTAssertEqual(ClaudeDesktopIndex.link(template: "claude://code/{id}?c={cli}", session: sessions[0])?.absoluteString,
                       "claude://code/local_1?c=c1")
        try? FileManager.default.removeItem(at: root)
    }
}

final class TimelineTests: XCTestCase {
    private func t(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60) }
    private func ev(_ kind: EventKind, _ minutes: Double, tasks: Int = 0) -> AgentEvent {
        AgentEvent(tool: .claudeCode, kind: kind, sessionId: "s1", at: t(minutes), backgroundTasks: tasks)
    }

    func testLifelineFollowsStateChanges() {
        var store = SessionStore()
        store.apply(ev(.promptStart, 0))
        store.apply(ev(.toolActivity, 5))
        store.apply(ev(.turnEnd, 10))
        store.apply(ev(.promptStart, 14))
        store.apply(ev(.turnEnd, 20, tasks: 1))
        let spans = store.lifeline(for: "claude-code:s1", now: t(25))
        XCTAssertEqual(spans.map(\.kind), [.working, .waiting, .working, .background])
        XCTAssertEqual(spans[0].end, t(10))
        XCTAssertEqual(spans[1].end, t(14))
        XCTAssertNil(spans[3].end)
    }

    func testResolveClosesLifelineButKeepsHistory() {
        var store = SessionStore()
        store.apply(ev(.promptStart, 0))
        store.apply(ev(.turnEnd, 10))
        store.resolve(id: "claude-code:s1", at: t(13))
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.history?["claude-code:s1"]?.last?.end, t(13))
    }

    func testStats() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let history: [String: [ActivitySpan]] = [
            "a": [ActivitySpan(kind: .working, start: t(0), end: t(30)),
                  ActivitySpan(kind: .waiting, start: t(30), end: t(34)),
                  ActivitySpan(kind: .working, start: t(34))],
            "b": [ActivitySpan(kind: .waiting, start: t(50), end: t(52))],
        ]
        let stats = ActivityStats.compute(history: history, now: t(60), window: 3600, bucketCount: 4, calendar: calendar)
        XCTAssertEqual(stats.buckets.count, 4)
        XCTAssertEqual(stats.buckets.map(\.working).reduce(0, +), 56, accuracy: 0.01)
        XCTAssertEqual(stats.buckets.map(\.waiting).reduce(0, +), 6, accuracy: 0.01)
        XCTAssertEqual(stats.averageReply ?? 0, 180, accuracy: 0.01)
        XCTAssertEqual(stats.sessionsToday, 2)
    }
}
