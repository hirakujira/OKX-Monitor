import XCTest
@testable import OKXMonitorCore

final class RefreshScheduleTests: XCTestCase {
    func testOnlyRequestedScopeIsScheduledAndFreshRevisitsAreSkipped() {
        var schedule = RefreshSchedule()
        XCTAssertTrue(schedule.begin(.balances, force: false, now: 100))
        schedule.finish(.balances, failed: false, rateLimited: false, now: 101)
        XCTAssertFalse(schedule.begin(.balances, force: false, now: 110))
        XCTAssertTrue(schedule.begin(.dci, force: false, now: 110))
        schedule.finish(.dci, failed: false, rateLimited: false, now: 111)
        XCTAssertFalse(schedule.begin(.dci, force: false, now: 141))
        XCTAssertTrue(schedule.begin(.balances, force: false, now: 141))
        XCTAssertTrue(schedule.begin(.dci, force: false, now: 231))
        XCTAssertEqual(MonitorTab.perpetuals.scope, MonitorTab.options.scope)
    }

    func testManualRefreshBypassesFreshnessButDebouncesRapidTaps() {
        var schedule = RefreshSchedule()
        XCTAssertTrue(schedule.begin(.dci, force: false, now: 100))
        schedule.finish(.dci, failed: false, rateLimited: false, now: 101)
        XCTAssertFalse(schedule.begin(.dci, force: true, now: 102))
        XCTAssertTrue(schedule.begin(.dci, force: true, now: 104))
    }

    func testRateLimitBackoffCannotBeBypassedByManualRefresh() {
        var schedule = RefreshSchedule()
        var now: TimeInterval = 100
        for delay: TimeInterval in [30, 60, 120, 240, 300, 300] {
            XCTAssertTrue(schedule.begin(.dci, force: false, now: now))
            schedule.finish(.dci, failed: true, rateLimited: true, now: now)
            XCTAssertFalse(schedule.begin(.dci, force: true, now: now + delay - 1))
            now += delay
        }
        XCTAssertTrue(schedule.begin(.dci, force: false, now: now))
        schedule.finish(.dci, failed: false, rateLimited: false, now: now)
        XCTAssertTrue(schedule.begin(.dci, force: true, now: now + 3))
        schedule.finish(.dci, failed: true, rateLimited: true, now: now + 3)
        XCTAssertTrue(schedule.begin(.dci, force: true, now: now + 33))
    }

    func testCancellationRetriesWithoutWaitingForNormalInterval() {
        var schedule = RefreshSchedule()
        XCTAssertTrue(schedule.begin(.balances, force: false, now: 100))
        schedule.cancel(.balances)
        XCTAssertFalse(schedule.begin(.balances, force: false, now: 101))
        XCTAssertTrue(schedule.begin(.balances, force: false, now: 103))
    }

    func testOrdinaryFailureWaitsBeforeAutomaticRetry() {
        var schedule = RefreshSchedule()
        XCTAssertTrue(schedule.begin(.dci, force: false, now: 100))
        schedule.finish(.dci, failed: true, rateLimited: false, now: 101)
        XCTAssertFalse(schedule.begin(.dci, force: false, now: 106))
        XCTAssertTrue(schedule.begin(.dci, force: false, now: 131))
        XCTAssertTrue(OKXError.api("50011").isRateLimited)
        XCTAssertTrue(OKXError.http(429).isRateLimited)
        XCTAssertFalse(OKXError.api("50102").isRateLimited)
    }
}
