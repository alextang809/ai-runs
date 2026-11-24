import XCTest
@testable import AIRunsCore

final class HoldTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func local(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
    }

    private let key = Session.key(tool: .codex, sessionId: "demo")

    private func store(at now: Date, waiting: Bool = true) -> SessionStore {
        var store = SessionStore()
        store.apply(AgentEvent(tool: .codex, kind: .promptStart, sessionId: "demo", at: now.addingTimeInterval(-120),
                               prompt: "Draft the sample report", transcriptPath: "/test/demo.jsonl"))
        if waiting {
            store.apply(AgentEvent(tool: .codex, kind: .turnEnd, sessionId: "demo", at: now.addingTimeInterval(-60),
                                   lastMessage: "Which template should I use?"))
        }
        return store
    }

    // MARK: Store

    func testHoldLeavesNeedsYouAndComesBackWhenDue() throws {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now)
        XCTAssertEqual(store.needsUserCount, 1)

        XCTAssertTrue(store.hold(id: key, until: now.addingTimeInterval(3600), at: now))
        XCTAssertEqual(store.needsUserCount, 0)
        XCTAssertEqual(store.held.map(\.id), [key])
        XCTAssertTrue(try XCTUnwrap(store.sessions[key]).isHeld)

        XCTAssertFalse(store.reconcileHolds(now: now.addingTimeInterval(1800)))
        XCTAssertEqual(store.needsUserCount, 0)

        XCTAssertTrue(store.reconcileHolds(now: now.addingTimeInterval(3601)))
        let back = try XCTUnwrap(store.sessions[key])
        XCTAssertTrue(back.isBackFromHold)
        XCTAssertTrue(back.needsUser)
        XCTAssertEqual(store.needsUserCount, 1)
        XCTAssertTrue(store.held.isEmpty)
        XCTAssertEqual(back.hold?.returnText, "Back from hold")

        store.acknowledgeReturn(id: key)
        XCTAssertNil(store.sessions[key]?.hold)
        XCTAssertEqual(store.needsUserCount, 1, "Its real state still needs the user")
    }

    func testMissedDeadlineComesBackOnTheNextLook() {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now)
        store.hold(id: key, until: now.addingTimeInterval(600), at: now)
        // The Mac slept for two days.
        XCTAssertTrue(store.reconcileHolds(now: now.addingTimeInterval(2 * 86400)))
        XCTAssertEqual(store.needsUserCount, 1)
    }

    func testDueHoldCountsEvenWhenTheSessionIsDoneOrWorking() {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now, waiting: false)
        XCTAssertEqual(store.needsUserCount, 0)
        XCTAssertTrue(store.hold(id: key, until: now.addingTimeInterval(60), at: now))
        store.reconcileHolds(now: now.addingTimeInterval(61))
        XCTAssertEqual(store.sessions[key]?.state, .working)
        XCTAssertEqual(store.needsUserCount, 1)
    }

    func testOpeningBeforeDueKeepsTheHold() {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now)
        store.hold(id: key, until: now.addingTimeInterval(3600), at: now)
        store.acknowledgeReturn(id: key)
        XCTAssertTrue(store.sessions[key]?.isHeld == true)
    }

    func testApprovalCannotBeHeldAndEndsAHold() {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now, waiting: false)
        store.apply(AgentEvent(tool: .codex, kind: .needsApproval, sessionId: "demo", at: now, approvalDetail: "make test"))
        XCTAssertFalse(store.hold(id: key, until: now.addingTimeInterval(3600), at: now))
        XCTAssertNil(store.sessions[key]?.hold)

        store.apply(AgentEvent(tool: .codex, kind: .toolActivity, sessionId: "demo", at: now.addingTimeInterval(5)))
        XCTAssertTrue(store.hold(id: key, until: now.addingTimeInterval(3600), at: now.addingTimeInterval(6)))
        store.apply(AgentEvent(tool: .codex, kind: .needsApproval, sessionId: "demo", at: now.addingTimeInterval(10),
                               approvalDetail: "make release"))
        XCTAssertNil(store.sessions[key]?.hold)
        XCTAssertEqual(store.needsUserCount, 1)
    }

    func testDoneAndNewRepliesStayHeld() {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now)
        store.hold(id: key, until: now.addingTimeInterval(3600), at: now)
        store.apply(AgentEvent(tool: .codex, kind: .promptStart, sessionId: "demo", at: now.addingTimeInterval(10),
                               prompt: "continue", transcriptPath: "/test/demo.jsonl", drivenBy: "coordinator"))
        store.apply(AgentEvent(tool: .codex, kind: .turnEnd, sessionId: "demo", at: now.addingTimeInterval(20),
                               lastMessage: "All done. Everything is finished."))
        XCTAssertTrue(store.sessions[key]?.isHeld == true)
        XCTAssertEqual(store.needsUserCount, 0)
        store.apply(AgentEvent(tool: .codex, kind: .question, sessionId: "demo", at: now.addingTimeInterval(30)))
        XCTAssertTrue(store.sessions[key]?.isHeld == true)
    }

    func testUserPromptEndsAReturnedHoldOnly() {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now)
        store.hold(id: key, until: now.addingTimeInterval(60), at: now)
        store.reconcileHolds(now: now.addingTimeInterval(61))
        store.apply(AgentEvent(tool: .codex, kind: .promptStart, sessionId: "demo", at: now.addingTimeInterval(70),
                               prompt: "Use the short template", transcriptPath: "/test/demo.jsonl"))
        XCTAssertNil(store.sessions[key]?.hold)
    }

    func testHoldSurvivesSessionEndPruningAndReload() throws {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now)
        store.hold(id: key, until: now.addingTimeInterval(3 * 86400), waitingOn: "  Li ", at: now)
        store.apply(AgentEvent(tool: .codex, kind: .sessionEnd, sessionId: "demo", at: now.addingTimeInterval(5)))
        XCTAssertNotNil(store.sessions[key]?.hold)
        store.pruneStale(now: now.addingTimeInterval(2 * 86400))
        XCTAssertNotNil(store.sessions[key]?.hold)
        let reloaded = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        let hold = try XCTUnwrap(reloaded.sessions[key]?.hold)
        XCTAssertEqual(hold.waitingName, "Li")
        XCTAssertEqual(hold.returnText, "Check back with Li")
    }

    func testRemoveCancelsAndUndoRestores() throws {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now)
        store.hold(id: key, until: now.addingTimeInterval(3600), at: now)
        let removed = try XCTUnwrap(store.sessions[key])
        store.dismiss(id: key, at: now)
        XCTAssertNil(store.sessions[key])
        store.restore(removed)
        XCTAssertTrue(store.sessions[key]?.isHeld == true)
    }

    func testRescheduleKeepsWaitingNameAndBringBackEndsIt() {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now)
        store.hold(id: key, until: now.addingTimeInterval(3600), waitingOn: "", at: now)
        XCTAssertNil(store.sessions[key]?.hold?.waitingName)
        XCTAssertEqual(store.sessions[key]?.hold?.returnText, "Check back")
        store.setWaitingName(id: key, "Sam")
        store.reschedule(id: key, until: now.addingTimeInterval(7200), at: now)
        XCTAssertEqual(store.sessions[key]?.hold?.waitingName, "Sam")
        XCTAssertEqual(store.sessions[key]?.hold?.until, now.addingTimeInterval(7200))
        store.bringBack(id: key, at: now)
        XCTAssertNil(store.sessions[key]?.hold)
        XCTAssertEqual(store.needsUserCount, 1)
    }

    func testRefusesAPastTime() {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now)
        XCTAssertFalse(store.hold(id: key, until: now, at: now))
        XCTAssertFalse(store.hold(id: key, until: now.addingTimeInterval(-60), at: now))
    }

    func testHoldReplacesLegacyIgnore() throws {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now)
        store.setIgnored(id: key, true, at: now)
        XCTAssertTrue(try XCTUnwrap(store.sessions[key]).isIgnored)
        store.hold(id: key, until: now.addingTimeInterval(3600), at: now)
        XCTAssertFalse(try XCTUnwrap(store.sessions[key]).isIgnored)
        XCTAssertNil(store.sessions[key]?.ignored)
    }

    func testOldSessionsWithoutHoldStillDecode() throws {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now)
        store.setIgnored(id: key, true, at: now)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as? [String: Any])
        var sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        var row = try XCTUnwrap(sessions[key] as? [String: Any])
        row["hold"] = nil
        sessions[key] = row
        json["sessions"] = sessions
        let decoded = try JSONDecoder().decode(SessionStore.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(try XCTUnwrap(decoded.sessions[key]).isIgnored)
        XCTAssertNil(decoded.sessions[key]?.hold)
    }

    func testThreadRowTakesOverTheHoldOfItsExecutor() {
        let now = date(2026, 11, 24, 10)
        var store = SessionStore()
        store.apply(AgentEvent(tool: .claudeCode, kind: .promptStart, sessionId: "local", at: now, prompt: "Check the export"))
        store.apply(AgentEvent(tool: .claudeCode, kind: .turnEnd, sessionId: "local", at: now.addingTimeInterval(5),
                               lastMessage: "Which file?"))
        let own = Session.key(tool: .claudeCode, sessionId: "local")
        XCTAssertTrue(store.hold(id: own, until: now.addingTimeInterval(3600), at: now.addingTimeInterval(6)))
        var wake = AgentEvent(tool: .claudeCode, kind: .promptStart, sessionId: "local", at: now.addingTimeInterval(10),
                              prompt: "continue", drivenBy: "coordinator")
        wake.thread = ProjectThread(projectId: "chan_demo", threadId: "cmsg_demo")
        store.apply(wake)
        let threadKey = Session.key(tool: .claudeCode, thread: ProjectThread(projectId: "chan_demo", threadId: "cmsg_demo"))
        XCTAssertNil(store.sessions[own])
        XCTAssertTrue(store.sessions[threadKey]?.isHeld == true)
    }

    // MARK: Alerts

    func testHoldWithdrawsAndNeverReannouncesTheSameMoment() throws {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now)
        var planner = AlertPlanner()
        planner.prime([])
        let all: Set<AlertKind> = Set(AlertKind.allCases)
        XCTAssertEqual(planner.changes(in: Array(store.sessions.values), enabled: all, now: now).post.map(\.id), [key])

        store.hold(id: key, until: now.addingTimeInterval(60), at: now)
        let held = planner.changes(in: Array(store.sessions.values), enabled: all, now: now)
        XCTAssertTrue(held.post.isEmpty)
        XCTAssertEqual(held.ended, [key], "The notification and reminder are withdrawn")

        store.reconcileHolds(now: now.addingTimeInterval(61))
        let due = planner.changes(in: Array(store.sessions.values), enabled: all, now: now.addingTimeInterval(61))
        XCTAssertTrue(due.post.isEmpty, "Coming back is silent")
        XCTAssertTrue(due.ended.isEmpty)

        store.acknowledgeReturn(id: key)
        let opened = planner.changes(in: Array(store.sessions.values), enabled: all, now: now.addingTimeInterval(62))
        XCTAssertTrue(opened.post.isEmpty, "The same wait is not news after the hold")

        store.apply(AgentEvent(tool: .codex, kind: .question, sessionId: "demo", at: now.addingTimeInterval(90)))
        let next = planner.changes(in: Array(store.sessions.values), enabled: all, now: now.addingTimeInterval(91))
        XCTAssertEqual(next.post.map(\.id), [key], "A new moment is announced as usual")
    }

    func testApprovalOnAHeldSessionAlertsAsUsual() {
        let now = date(2026, 11, 24, 10)
        var store = store(at: now)
        var planner = AlertPlanner()
        store.hold(id: key, until: now.addingTimeInterval(3600), at: now)
        planner.prime(Array(store.sessions.values), now: now)
        store.apply(AgentEvent(tool: .codex, kind: .needsApproval, sessionId: "demo", at: now.addingTimeInterval(5)))
        let changes = planner.changes(in: Array(store.sessions.values), enabled: [.approval], now: now.addingTimeInterval(6))
        XCTAssertEqual(changes.post.map(\.id), [key])
    }

    // MARK: Dates

    func testPresetsOnATuesday() {
        let plan = HoldPlan(now: date(2026, 11, 24, 13, 40), calendar: calendar) // Tuesday
        XCTAssertEqual(plan.date(for: .later), date(2026, 11, 24, 16, 40))
        XCTAssertEqual(plan.date(for: .tomorrow), date(2026, 11, 25, 9))
        XCTAssertEqual(plan.date(for: .week), date(2026, 11, 27, 9))
        XCTAssertEqual(plan.date(for: .waiting), date(2026, 11, 26, 9))
        XCTAssertEqual(plan.segments.map(\.label), ["Today", "Wed", "Thu", "Fri", "Mon"])
        XCTAssertEqual(plan.segments.last?.isNextWeek, true)
        XCTAssertEqual(plan.segments[2].dropDate, date(2026, 11, 26, 9))
        XCTAssertEqual(plan.title(for: .later), "Today 4:40 PM")
        XCTAssertEqual(plan.title(for: .week), "Fri 9:00 AM")
        XCTAssertEqual(plan.backText(date(2026, 11, 26, 9)), "Back Thu 9:00 AM")
    }

    func testThursdayWeekPresetMovesToMonday() {
        let plan = HoldPlan(now: date(2026, 11, 26, 10), calendar: calendar) // Thursday
        XCTAssertEqual(plan.date(for: .week), date(2026, 11, 30, 9))
        XCTAssertEqual(plan.segments.map(\.label), ["Today", "Fri", "Mon"])
    }

    func testFridayAndWeekendShowTodayAndMonday() {
        for day in [27, 28, 29] { // Fri, Sat, Sun
            let plan = HoldPlan(now: date(2026, 11, day, 10), calendar: calendar)
            XCTAssertEqual(plan.segments.map(\.label), ["Today", "Mon"], "day \(day)")
            XCTAssertEqual(plan.segments.last?.dropDate, date(2026, 11, 30, 9))
        }
        // Sunday: Friday is five days away.
        XCTAssertEqual(HoldPlan(now: date(2026, 11, 29, 10), calendar: calendar).date(for: .week), date(2026, 12, 4, 9))
        XCTAssertEqual(HoldPlan(now: date(2026, 11, 28, 10), calendar: calendar).date(for: .week), date(2026, 11, 30, 9))
    }

    func testMondayLineHasTheWholeWeek() {
        let plan = HoldPlan(now: date(2026, 11, 23, 10), calendar: calendar)
        XCTAssertEqual(plan.segments.map(\.label), ["Today", "Tue", "Wed", "Thu", "Fri", "Mon"])
        XCTAssertEqual(plan.segments.last?.daysAhead, 7)
    }

    func testLateEveningLaterNamesTheNextDay() {
        let plan = HoldPlan(now: date(2026, 11, 24, 22, 30), calendar: calendar)
        XCTAssertEqual(plan.date(for: .later), date(2026, 11, 25, 1, 30))
        XCTAssertEqual(plan.title(for: .later), "Tomorrow 1:30 AM")
        XCTAssertEqual(plan.segment(for: plan.date(for: .later)).label, "Wed")
    }

    func testJustBeforeMidnightNeverSchedulesIntoThePast() {
        let plan = HoldPlan(now: date(2026, 11, 24, 23, 59), calendar: calendar)
        XCTAssertGreaterThan(plan.date(for: .tomorrow), plan.now)
        XCTAssertEqual(plan.date(for: .tomorrow), date(2026, 11, 25, 9))
    }

    func testSegmentsForDatesPastTheLine() {
        let plan = HoldPlan(now: date(2026, 11, 26, 10), calendar: calendar) // Thursday
        // Waiting from Thursday checks back on Saturday, which sits on Monday's stretch.
        let saturday = plan.date(for: .waiting)
        XCTAssertEqual(saturday, date(2026, 11, 28, 9))
        XCTAssertEqual(plan.segment(for: saturday).label, "Mon")
        XCTAssertEqual(plan.segment(for: plan.now.addingTimeInterval(-3600)).label, "Today")
        let later = date(2026, 12, 8, 9)
        XCTAssertTrue(plan.isBeyondLine(later))
        XCTAssertEqual(plan.when(later), "Tue 8 Dec 9:00 AM")
    }

    func testDaylightSavingChanges() {
        // US clocks go back on 2026-11-01 and forward on 2026-03-08.
        let fallBack = HoldPlan(now: date(2026, 10, 31, 20), calendar: calendar)
        XCTAssertEqual(local(fallBack.date(for: .tomorrow)).hour, 9)
        XCTAssertEqual(local(fallBack.date(for: .tomorrow)).day, 1)
        let springForward = HoldPlan(now: date(2026, 3, 7, 20), calendar: calendar)
        XCTAssertEqual(local(springForward.date(for: .tomorrow)).hour, 9)
        XCTAssertEqual(local(springForward.date(for: .waiting)).day, 9)
        XCTAssertEqual(springForward.daysAhead(of: springForward.date(for: .waiting)), 2)
    }

    func testTimeZoneDecidesTheDay() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // Tuesday 22:00 in New York is Wednesday 12:00 in Tokyo.
        let instant = date(2026, 11, 24, 22)
        XCTAssertEqual(HoldPlan(now: instant, calendar: calendar).segments.first?.label, "Today")
        XCTAssertEqual(HoldPlan(now: instant, calendar: calendar).segments.count, 5)
        XCTAssertEqual(HoldPlan(now: instant, calendar: tokyo).segments.map(\.label), ["Today", "Thu", "Fri", "Mon"])
    }
}
