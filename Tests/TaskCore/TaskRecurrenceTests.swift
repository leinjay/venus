import XCTest
@testable import VenusTaskCore

final class TaskRecurrenceTests: XCTestCase {
    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func task(_ cycle: TaskSchedule.Recurrence, start: String = "2026-01-31T09:00:00+08:00") -> ReminderItem {
        var task = ReminderItem(title: "周期任务", dueAt: date(start))
        task.schedule.timeZone = "Asia/Shanghai"
        task.schedule.recurrence = cycle
        return task
    }

    func testLegacyScheduleDefaultsToOnceAndRecurringScheduleRoundTrips() throws {
        let legacy = Data(#"{"mode":"instant","instant":1000,"timeZone":"Asia/Shanghai"}"#.utf8)
        let schedule = try JSONDecoder().decode(TaskSchedule.self, from: legacy)
        XCTAssertEqual(schedule.recurrence, .once)
        XCTAssertEqual(schedule.intervalHours, 1)
        XCTAssertNil(schedule.nextOccurrence(after: schedule.instant))
        var recurring = task(.hourly)
        recurring.schedule.intervalHours = 3
        recurring.schedule.recurrenceAnchor = recurring.schedule.instant
        XCTAssertEqual(try JSONDecoder().decode(ReminderItem.self, from: JSONEncoder().encode(recurring)), recurring)
    }

    func testHourlyCompletionSkipsMissedPeriodsAndKeepsTheOriginalPhase() throws {
        var pending = task(.hourly, start: "2026-11-07T09:00:00+08:00")
        pending.schedule.intervalHours = 3
        let completedAt = date("2026-11-08T10:30:00+08:00")
        let next = try TaskRules.nextCycle(afterCompleting: pending, now: completedAt)
        XCTAssertEqual(next.schedule.instant, date("2026-11-08T12:00:00+08:00"))
        XCTAssertFalse(next.isDone)
        XCTAssertNil(next.completedAt)
        XCTAssertEqual(next.schedule.recurrenceAnchor, pending.schedule.instant)
        XCTAssertNotEqual(next.notificationVersion, pending.notificationVersion)
        XCTAssertEqual(next.id, pending.id)
        XCTAssertEqual(next.schedule.nextOccurrence(after: next.schedule.instant), date("2026-11-08T15:00:00+08:00"))
    }

    func testEarlyCompletionAdvancesAtLeastOnePeriod() throws {
        let pending = task(.daily, start: "2026-11-07T09:00:00+08:00")
        let next = try TaskRules.nextCycle(afterCompleting: pending, now: date("2026-11-06T10:00:00+08:00"))
        XCTAssertEqual(next.schedule.instant, date("2026-11-08T09:00:00+08:00"))
        XCTAssertThrowsError(try TaskRules.nextCycle(afterCompleting: task(.once), now: Date()))
    }

    func testMonthlyShortMonthDoesNotShiftTheFollowingMonth() throws {
        let january = task(.monthly)
        let february = try TaskRules.nextCycle(afterCompleting: january, now: january.schedule.instant)
        XCTAssertEqual(february.schedule.instant, date("2026-02-28T09:00:00+08:00"))
        let march = try TaskRules.nextCycle(afterCompleting: february, now: february.schedule.instant)
        XCTAssertEqual(march.schedule.instant, date("2026-03-31T09:00:00+08:00"))
        XCTAssertEqual(january.schedule.nextOccurrence(after: date("2030-12-01T00:00:00+08:00")), date("2030-12-31T09:00:00+08:00"))
    }

    func testDailyAndWeeklyKeepLocalTimeAcrossDaylightSaving() {
        var daily = task(.daily, start: "2026-03-07T09:00:00-05:00")
        daily.schedule.timeZone = "America/New_York"
        XCTAssertEqual(daily.schedule.nextOccurrence(after: daily.schedule.instant), date("2026-03-08T09:00:00-04:00"))
        daily.schedule.recurrence = .weekly
        XCTAssertEqual(daily.schedule.nextOccurrence(after: daily.schedule.instant), date("2026-03-14T09:00:00-04:00"))
    }

    func testRecurrenceChangesParticipateInMergingAndValidation() throws {
        let base = task(.daily)
        var draft = base
        draft.schedule.recurrence = .weekly
        XCTAssertNotEqual(TaskField.schedule.value(base), TaskField.schedule.value(draft))
        var latest = base
        latest.schedule.recurrence = .monthly
        XCTAssertEqual(TaskRules.merge(base: base, draft: draft, latest: latest).1, [.schedule])
        draft = base
        draft.isDone = true
        XCTAssertEqual(TaskRules.merge(base: base, draft: draft, latest: latest).1, [.isDone])
        draft.schedule.recurrence = .hourly
        draft.schedule.intervalHours = 0
        XCTAssertThrowsError(try TaskRules.validate(draft, among: []))
    }

    func testNotificationPlanHonorsStartTimesAndGlobalCapacity() {
        let recurring = task(.daily, start: "2026-11-10T09:00:00+08:00")
        let once = task(.once, start: "2026-11-11T08:00:00+08:00")
        var done = recurring
        done.id = UUID()
        done.isDone = true
        let plan = TaskRules.notificationPlan([recurring, once, done], after: date("2026-11-07T00:00:00+08:00"), limit: 4, ledger: [:])
        XCTAssertEqual(plan.map(\.date), [
            date("2026-11-10T09:00:00+08:00"), date("2026-11-11T08:00:00+08:00"),
            date("2026-11-11T09:00:00+08:00"), date("2026-11-12T09:00:00+08:00")
        ])
        XCTAssertEqual(Set(plan.map(\.identifier)).count, 4)
        XCTAssertTrue(TaskRules.notificationPlan([recurring], after: Date(), limit: 0, ledger: [:]).isEmpty)
        let overduePlan = TaskRules.notificationPlan([recurring, once], after: date("2026-11-15T10:00:00+08:00"), limit: 2, ledger: [:])
        XCTAssertEqual(overduePlan.map(\.date), [date("2026-11-16T09:00:00+08:00"), date("2026-11-17T09:00:00+08:00")])
        XCTAssertTrue(TaskRules.notificationPlan([once], after: date("2026-11-07T00:00:00+08:00"), limit: 4, ledger: [once.notificationVersion.uuidString: .distantPast]).isEmpty)
    }

    func testWatchAcknowledgementCannotReplayAnOldIntentIntoTheNextCycle() {
        var recurring = task(.daily)
        recurring.fieldVersions[TaskField.isDone.rawValue] = 5
        let ack = CompletionAck(operationID: UUID(), accepted: true, completionRevision: 5)
        XCTAssertFalse(TaskRules.canContinue(after: ack, task: recurring))
    }
}
