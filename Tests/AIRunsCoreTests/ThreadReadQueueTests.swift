import XCTest
@testable import AIRunsCore

final class ThreadReadQueueTests: XCTestCase {
    func testRefreshDuringRegularReadWaitsForItsOwnResult() {
        let regular = ThreadReadQueue().requesting(.regular)
        let queued = regular.requesting(.refresh)
        XCTAssertEqual(queued.active, .regular, "the current result still belongs to the periodic read")
        XCTAssertTrue(queued.refreshPending)
        XCTAssertFalse(queued.shouldAnnounce, "the earlier periodic result must not announce the refresh")

        let refresh = queued.completing()
        XCTAssertEqual(refresh.active, .refresh, "the explicit refresh must run after the smaller read")
        XCTAssertFalse(refresh.refreshPending)
        XCTAssertTrue(refresh.shouldAnnounce)
        XCTAssertNil(refresh.completing().active)
        XCTAssertFalse(refresh.completing().shouldAnnounce)
    }

    func testRepeatedRefreshClicksCoalesceBehindCurrentRead() {
        let regular = ThreadReadQueue().requesting(.regular)
        let queued = (0..<20).reduce(regular) { queue, _ in queue.requesting(.refresh) }
        XCTAssertEqual(queued.active, .regular)
        XCTAssertTrue(queued.refreshPending)
        let refresh = queued.completing()
        XCTAssertEqual(refresh.active, .refresh)
        XCTAssertNil(refresh.completing().active, "twenty clicks produce only one queued read")
    }

    func testPeriodicTicksDoNotQueueExtraWorkOrEraseRefresh() {
        let regular = ThreadReadQueue().requesting(.regular)
        XCTAssertEqual(regular.requesting(.regular), regular)
        let queued = regular.requesting(.refresh)
        XCTAssertEqual(queued.requesting(.regular), queued)
        let refreshing = queued.completing()
        XCTAssertEqual(refreshing.requesting(.regular), refreshing)
        XCTAssertNil(refreshing.completing().active)
    }

    func testRefreshDuringRefreshQueuesOneNewReadAfterLatestClick() {
        let refreshing = ThreadReadQueue().requesting(.refresh)
        let queued = refreshing.requesting(.refresh).requesting(.refresh)
        XCTAssertEqual(queued.active, .refresh)
        XCTAssertTrue(queued.refreshPending)
        let next = queued.completing()
        XCTAssertEqual(next.active, .refresh)
        XCTAssertFalse(next.refreshPending)
        XCTAssertNil(next.completing().active)
    }

    func testCompletionCanDrainUnavailableReadsAndAcceptLaterRequests() {
        // Starting a queued request can discover permission was revoked. Completing
        // that unavailable request must release the gate for the next timer tick.
        let queued = ThreadReadQueue().requesting(.regular).requesting(.refresh)
        let unavailableRefresh = queued.completing()
        XCTAssertEqual(unavailableRefresh.active, .refresh)
        XCTAssertTrue(unavailableRefresh.shouldAnnounce, "an unavailable explicit refresh still reports its status")
        let idle = unavailableRefresh.completing()
        XCTAssertNil(idle.active)
        XCTAssertFalse(idle.refreshPending)
        XCTAssertFalse(idle.shouldAnnounce)
        XCTAssertEqual(idle.requesting(.regular).active, .regular)
    }

    func testIdleCompletionDoesNotCreateWork() {
        XCTAssertEqual(ThreadReadQueue().completing(), ThreadReadQueue())
    }

    func testRequestsReturnNewValuesWithoutChangingEarlierState() {
        let idle = ThreadReadQueue()
        let active = idle.requesting(.regular)
        let queued = active.requesting(.refresh)
        XCTAssertNil(idle.active)
        XCTAssertFalse(active.refreshPending)
        XCTAssertTrue(queued.refreshPending)
    }
}
