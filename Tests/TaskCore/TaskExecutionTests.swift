import XCTest
@testable import VenusTaskCore

final class TaskExecutionTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func task() -> ReminderItem {
        var task = ReminderItem(title: "执行记录", dueAt: date("2026-11-01T09:00:00Z"))
        task.schedule.recurrence = .daily
        task.schedule.timeZone = "UTC"
        return task
    }
    private var interval: DateInterval {
        DateInterval(start: date("2026-11-01T00:00:00Z"), end: date("2026-11-05T00:00:00Z"))
    }

    func testCompletionPreservesActualTimeAndAllMissedOccurrences() throws {
        let before = task()
        let finished = date("2026-11-03T10:00:00Z")
        var completed = before
        completed.isDone = true
        completed.completedAt = finished
        let next = try TaskRules.nextCycle(afterCompleting: completed, now: finished)
        var records: [TaskExecutionRecord] = []
        TaskExecutionHistory.capture(previous: before, current: next, completedCycle: completed,
                                     at: finished, source: "Apple Watch", into: &records)
        let entries = TaskExecutionHistory.entries(task: next, records: records, in: interval, now: finished)
        XCTAssertEqual(entries.map(\.scheduledAt), (1...4).map { date("2026-11-0\($0)T09:00:00Z") })
        XCTAssertEqual(entries.map(\.status), [.completed, .overdue, .overdue, .planned])
        XCTAssertEqual(entries.first?.completedAt, finished)
        XCTAssertEqual(entries.first?.source, "Apple Watch")
    }

    func testReopeningUpdatesTheSameOccurrenceInsteadOfDuplicatingIt() {
        var pending = task()
        pending.schedule.recurrence = .once
        var completed = pending
        completed.isDone = true
        completed.completedAt = date("2026-11-01T10:00:00Z")
        var records: [TaskExecutionRecord] = []
        TaskExecutionHistory.capture(previous: pending, current: completed, completedCycle: nil,
                                     at: completed.completedAt!, source: "iPhone", into: &records)
        let id = records.first?.id
        TaskExecutionHistory.capture(previous: completed, current: pending, completedCycle: nil,
                                     at: date("2026-11-01T11:00:00Z"), source: "iPhone", into: &records)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, id)
        XCTAssertEqual(records.first?.status, .reopened)
        XCTAssertNil(records.first?.completedAt)
        let entries = TaskExecutionHistory.entries(task: pending, records: records, in: interval, now: date("2026-11-02T00:00:00Z"))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.status, .overdue)
    }

    func testRecordsSurviveVersionRetentionAndDatabaseRoundTrip() throws {
        var database = TaskDatabase()
        let original = task()
        database.tasks = [original]
        var records: [TaskExecutionRecord] = []
        for offset in 0..<40 {
            var completed = original
            completed.schedule.instant = original.schedule.instant.addingTimeInterval(Double(offset) * 86_400)
            completed.isDone = true
            completed.completedAt = completed.schedule.instant.addingTimeInterval(300)
            TaskExecutionHistory.record(completed, status: .completed, at: completed.completedAt!, source: "iPhone", into: &records)
        }
        database.executionHistory[original.id.uuidString] = records
        database.history = [:]
        let restored = try JSONDecoder().decode(TaskDatabase.self, from: JSONEncoder().encode(database))
        XCTAssertEqual(restored.executionHistory[original.id.uuidString], records)
        XCTAssertEqual(records.count, 40)
    }

    func testLegacyDatabaseRecoversCompletionWithoutTreatingNextCycleAsReopened() throws {
        var completed = task()
        completed.isDone = true
        completed.completedAt = date("2026-11-01T10:00:00Z")
        let next = try TaskRules.nextCycle(afterCompleting: completed, now: completed.completedAt!)
        var database = TaskDatabase()
        database.tasks = [next]
        database.history[next.id.uuidString] = [
            TaskVersion(savedAt: date("2026-11-01T10:00:01Z"), source: "自动安排下一次", task: next),
            TaskVersion(savedAt: completed.completedAt!, source: "完成本次", task: completed)
        ]
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(database)) as? [String: Any])
        old.removeValue(forKey: "executionHistory")
        let migrated = try JSONDecoder().decode(TaskDatabase.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(migrated.executionHistory[next.id.uuidString]?.count, 1)
        XCTAssertEqual(migrated.executionHistory[next.id.uuidString]?.first?.status, .completed)
    }

    func testReschedulingPreservesPastMissesAndCancelledSchedule() {
        let previous = task()
        var updated = previous
        updated.schedule.instant = date("2026-11-10T09:00:00Z")
        var records: [TaskExecutionRecord] = []
        let changed = date("2026-11-03T10:00:00Z")
        TaskExecutionHistory.capture(previous: previous, current: updated, completedCycle: nil,
                                     at: changed, source: "iPhone", into: &records)
        let entries = TaskExecutionHistory.entries(task: updated, records: records, in: interval, now: changed)
        XCTAssertEqual(entries.map(\.status), [.rescheduled, .overdue, .overdue])
        XCTAssertEqual(entries.count, 3)
    }

    func testMonthIntervalExcludesTheNextMonthsFirstDay() {
        let current = task()
        let november = DateInterval(start: date("2026-11-01T00:00:00Z"), end: date("2026-12-01T00:00:00Z"))
        let entries = TaskExecutionHistory.entries(task: current, records: [], in: november, now: november.start)
        XCTAssertEqual(entries.count, 30)
        XCTAssertTrue(entries.allSatisfy { $0.scheduledAt < november.end })
    }
}
