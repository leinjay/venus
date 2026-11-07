import XCTest
@testable import VenusTaskCore

final class TaskDailyOverviewTests: XCTestCase {
    func testCompanionGreetingIsUsedOnlyWhenRequestedAndNeverDoubled() {
        XCTAssertTrue(TaskCompanionTone.instructions.contains("浩浩"))
        XCTAssertTrue(TaskCompanionTone.instructions.contains("不要每轮重复"))
        let opening = TaskCompanionTone.present("我们慢慢来。", includeGreeting: true)
        XCTAssertEqual(opening, "亲爱的浩浩，今天辛苦了。\n\n我们慢慢来。")
        XCTAssertEqual(TaskCompanionTone.present(opening, includeGreeting: true), opening)
        XCTAssertEqual(TaskCompanionTone.present("已经整理到草稿。", includeGreeting: false), "已经整理到草稿。")
    }
    private let now = ISO8601DateFormatter().date(from: "2026-11-08T12:00:00+08:00")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    func testOverviewCountsRecurringCompletionsAndDoesNotDuplicateOverdueTasks() {
        var pending = ReminderItem(title: "今天要做", dueAt: now.addingTimeInterval(3600))
        pending.schedule.timeZone = "Asia/Shanghai"
        let lateToday = ReminderItem(title: "今天已过时", dueAt: now.addingTimeInterval(-3600))
        let yesterday = ReminderItem(title: "昨天未做", dueAt: now.addingTimeInterval(-86_400))
        var done = pending
        done.id = UUID()
        done.isDone = true
        done.completedAt = now
        var recurring = pending
        recurring.id = UUID()
        recurring.schedule.recurrence = .daily
        recurring.schedule.instant = now.addingTimeInterval(86_400)
        var completedCycle = recurring
        completedCycle.schedule.instant = now.addingTimeInterval(-3600)
        completedCycle.isDone = true
        completedCycle.completedAt = now
        var records: [TaskExecutionRecord] = []
        TaskExecutionHistory.record(completedCycle, status: .completed, at: now, source: "iPhone", into: &records)
        var deleted = yesterday
        deleted.id = UUID()
        deleted.deletedAt = now
        let overview = TaskDailyOverview(
            tasks: [pending, lateToday, yesterday, done, recurring, deleted],
            history: [recurring.id.uuidString: records + records], now: now, calendar: calendar
        )
        XCTAssertEqual(overview.pending.count, 2)
        XCTAssertEqual(overview.overdue.count, 2)
        XCTAssertEqual(overview.completed.count, 2)
        XCTAssertEqual(Set(overview.selected.map(\.id)), Set([pending.id, lateToday.id, yesterday.id]))
        XCTAssertEqual(overview.selected.count, 3)
        XCTAssertTrue(overview.compactCounts.contains("待办 2"))
        XCTAssertTrue(overview.compactCounts.contains("完成 2"))
    }

    func testEmptyOverviewAndMidnightHaveDeterministicFallbacks() {
        let empty = TaskDailyOverview(tasks: [], history: [:], now: now, calendar: calendar)
        XCTAssertTrue(empty.fallbackDetail.contains("今天暂时没有待办"))
        XCTAssertFalse(empty.fallbackAdvice.isEmpty)
        let today = ReminderItem(title: "跨天任务", dueAt: now)
        let nextDay = TaskDailyOverview(tasks: [today], history: [:], now: now.addingTimeInterval(86_400), calendar: calendar)
        XCTAssertTrue(nextDay.pending.isEmpty)
        XCTAssertEqual(nextDay.overdue.count, 1)
    }

    func testTaskSwipesRequireDeliberateHorizontalMovement() {
        XCTAssertEqual(TaskDetailSwipe.action(tab: 0, translation: CGSize(width: -100, height: 5)), .exit)
        XCTAssertEqual(TaskDetailSwipe.action(tab: 0, translation: CGSize(width: 100, height: 5)), .tab(1))
        XCTAssertEqual(TaskDetailSwipe.action(tab: 1, translation: CGSize(width: -100, height: 5)), .tab(0))
        XCTAssertEqual(TaskDetailSwipe.action(tab: 1, translation: CGSize(width: 100, height: 5)), .none)
        XCTAssertEqual(TaskDetailSwipe.action(tab: 0, translation: CGSize(width: -20, height: 5)), .none)
        XCTAssertEqual(TaskDetailSwipe.action(tab: 0, translation: CGSize(width: 90, height: 100)), .none)
    }
}
