import XCTest
@testable import VenusTaskCore

final class TaskRulesTests: XCTestCase {
    func testOverdueUsesTheExactTimeForTimedTasksAndExcludesInactiveTasks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var task = ReminderItem(title: "提醒", dueAt: now.addingTimeInterval(-1))
        XCTAssertTrue(TaskRules.isOverdue(task, now: now))
        task.isDone = true
        XCTAssertFalse(TaskRules.isOverdue(task, now: now))
        task.isDone = false
        task.deletedAt = now
        XCTAssertFalse(TaskRules.isOverdue(task, now: now))
        task.deletedAt = nil
        task.schedule.instant = now
        XCTAssertFalse(TaskRules.isOverdue(task, now: now))
        task.schedule.instant = now.addingTimeInterval(60)
        XCTAssertFalse(TaskRules.isOverdue(task, now: now))
        task.schedule.mode = .unplanned
        XCTAssertFalse(TaskRules.isOverdue(task, now: now))
    }

    func testDateOnlyTaskBecomesOverdueOnTheFollowingLocalDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let noon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12)))
        let nextDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 8)))
        var task = ReminderItem()
        task.schedule = TaskSchedule(mode: .day, day: "2026-11-07")
        XCTAssertFalse(TaskRules.isOverdue(task, now: noon, calendar: calendar))
        XCTAssertTrue(TaskRules.isOverdue(task, now: nextDay, calendar: calendar))
    }

    func testNotificationShowsTitleAndSummaryWithBodyFallback() {
        var task = ReminderItem(); task.title = "  交报告  "; task.summary = "周五前提交"; task.body = "完整报告内容"
        let text = TaskRules.notificationText(task, hideDetails: false)
        XCTAssertEqual(text.title, "交报告"); XCTAssertEqual(text.body, "周五前提交")
        task.summary = " \n "
        XCTAssertEqual(TaskRules.notificationText(task, hideDetails: false).body, "完整报告内容")
        task.body = ""; task.title = ""
        XCTAssertEqual(TaskRules.notificationText(task, hideDetails: false).title, "任务提醒")
        XCTAssertFalse(TaskRules.notificationText(task, hideDetails: false).body.isEmpty)
    }

    func testNotificationPrivacyAndLongContent() {
        var task = ReminderItem(); task.title = "私人任务"; task.summary = String(repeating: "详", count: 300)
        let visible = TaskRules.notificationText(task, hideDetails: false)
        XCTAssertEqual(visible.body.count, 281); XCTAssertTrue(visible.body.hasSuffix("…"))
        let hidden = TaskRules.notificationText(task, hideDetails: true)
        XCTAssertEqual(hidden.title, "你有一项任务待处理")
        XCTAssertEqual(hidden.body, "打开 Venus 查看任务详情")
    }

    func testWatchSnapshotSharesSummaryButOmitsHeavyContentAndDeletedTasks() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var parent = ReminderItem(); parent.title = "前置"
        var completed = ReminderItem(); completed.title = "已完成前置"; completed.isDone = true; completed.completedAt = now
        var deleted = ReminderItem(); deleted.title = "回收站"; deleted.deletedAt = now
        var task = ReminderItem(); task.title = "要查看的任务"; task.summary = "手表上的概要"
        task.body = String(repeating: "完整正文", count: 5_000); task.tags = [TaskTag(key: "地点", value: "家")]
        task.prerequisiteIDs = [parent.id, completed.id, deleted.id, UUID()]
        task.revision = 17; task.fieldVersions[TaskField.isDone.rawValue] = 9
        let snapshot = TaskRules.watchSnapshot([task, parent, completed, deleted], revision: 20, now: now)
        let projected = try XCTUnwrap(snapshot.tasks.first { $0.id == task.id })
        XCTAssertEqual(snapshot.revision, 20); XCTAssertEqual(snapshot.tasks.count, 3)
        XCTAssertEqual(projected.summary, task.summary); XCTAssertTrue(projected.body.isEmpty); XCTAssertTrue(projected.tags.isEmpty)
        XCTAssertEqual(projected.prerequisiteIDs, [parent.id]); XCTAssertEqual(projected.lifecycle, task.lifecycle)
        XCTAssertEqual(projected.revision, 17); XCTAssertEqual(projected.fieldVersions, task.fieldVersions)
        XCTAssertEqual(task.body.count, 20_000) // Projection never changes the phone's source data.
    }

    func testWatchSnapshotKeepsAllPendingAndOnlySevenLocalDaysOfCompletedTasks() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12))!
        let cutoff = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16))!
        var pending = ReminderItem(); pending.title = "很早的未完成任务"; pending.addedAt = .distantPast
        var recent = ReminderItem(); recent.isDone = true; recent.completedAt = cutoff
        var old = recent; old.id = UUID(); old.completedAt = cutoff.addingTimeInterval(-1)
        var unknown = recent; unknown.id = UUID(); unknown.completedAt = nil
        let snapshot = TaskRules.watchSnapshot([pending, recent, old, unknown], revision: 4, now: now, calendar: calendar)
        XCTAssertEqual(Set(snapshot.tasks.map(\.id)), Set([pending.id, recent.id]))
        let empty = TaskRules.watchSnapshot([], revision: 5, now: now, calendar: calendar)
        XCTAssertEqual(empty.revision, 5); XCTAssertTrue(empty.tasks.isEmpty)
    }

    func testLegacyMigrationKeepsIdentityAndUnknownCompletionTime() throws {
        let id = UUID()
        let legacy = "{\"id\":\"\(id)\",\"title\":\"旧提醒\",\"dueAt\":1000,\"isDone\":true}"
        let task = try JSONDecoder().decode(ReminderItem.self, from: Data(legacy.utf8))
        XCTAssertEqual(task.id, id); XCTAssertEqual(task.schedule.mode, .instant)
        XCTAssertTrue(task.isDone); XCTAssertTrue(task.addedAtInferred); XCTAssertNil(task.completedAt)
        XCTAssertEqual(try JSONDecoder().decode(ReminderItem.self, from: JSONEncoder().encode(task)), task)
    }
    func testDependencyCycleAndDeletedReferenceRejected() throws {
        var a = ReminderItem(); a.title = "A"
        var b = ReminderItem(); b.title = "B"; b.prerequisiteIDs = [a.id]
        a.prerequisiteIDs = [b.id]
        XCTAssertThrowsError(try TaskRules.validate(a, among: [a, b]))
        a.prerequisiteIDs = [UUID()]
        XCTAssertThrowsError(try TaskRules.validate(a, among: [a, b]))
    }
    func testDependencyGraphIncludesCoPrerequisitesButNotUnrelatedBranches() {
        var a = ReminderItem(), b = ReminderItem(), c = ReminderItem(), d = ReminderItem(), extra = ReminderItem()
        b.prerequisiteIDs = [a.id, d.id]; c.prerequisiteIDs = [b.id]; extra.prerequisiteIDs = [d.id]
        let ids = TaskRules.dependencyIDs(for: a.id, tasks: [a, b, c, d, extra])
        XCTAssertEqual(ids, Set([a.id, b.id, c.id, d.id])); a.title = "A"; d.title = "D"
    }
    func testThreeWayMergePreservesPhoneCompletionAndDetectsTitleConflict() {
        var base = ReminderItem(); base.title = "原始"
        var draft = base; draft.title = "表单"; draft.summary = "新增概要"
        var latest = base; latest.title = "手机"; latest.isDone = true
        let (merged, conflicts) = TaskRules.merge(base: base, draft: draft, latest: latest)
        XCTAssertEqual(conflicts, [.title]); XCTAssertEqual(merged.title, "手机")
        XCTAssertTrue(merged.isDone); XCTAssertEqual(merged.summary, "新增概要")
    }
    func testWatchCannotRebaseConflictingOrPreDeleteOperation() {
        var task = ReminderItem(); task.fieldVersions["isDone"] = 4
        let op = CompletionOperation(taskID: task.id, lifecycle: task.lifecycle, baseRevision: 4, isDone: true)
        XCTAssertTrue(TaskRules.accepts(op, for: task))
        task.fieldVersions["isDone"] = 5; task.isDone = true
        XCTAssertFalse(TaskRules.accepts(op, for: task))
        task.fieldVersions["isDone"] = 4; task.lifecycle = UUID()
        XCTAssertFalse(TaskRules.accepts(op, for: task))
    }
    func testWatchDoesNotReplayQueuedIntentOverPhoneChangeAfterAcknowledgedOperation() {
        var task = ReminderItem(); task.fieldVersions["isDone"] = 7
        let ack = CompletionAck(operationID: UUID(), accepted: true, completionRevision: 7)
        XCTAssertTrue(TaskRules.canContinue(after: ack, task: task))
        task.fieldVersions["isDone"] = 8
        XCTAssertFalse(TaskRules.canContinue(after: ack, task: task))
        XCTAssertFalse(TaskRules.canContinue(after: CompletionAck(operationID: UUID(), accepted: false), task: task))
    }
    func testDateOnlyTravelsButInstantStaysFixedAndInvalidDatesFail() {
        var china = Calendar(identifier: .gregorian); china.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var london = china; london.timeZone = TimeZone(identifier: "Europe/London")!
        let day = TaskSchedule(mode: .day, day: "2026-10-21")
        XCTAssertEqual(china.component(.hour, from: day.trigger(calendar: china)!), 9)
        XCTAssertEqual(london.component(.hour, from: day.trigger(calendar: london)!), 9)
        XCTAssertNotEqual(day.trigger(calendar: china), day.trigger(calendar: london))
        let fixed = TaskSchedule(mode: .instant, instant: day.trigger(calendar: china)!)
        XCTAssertEqual(fixed.trigger(calendar: china), fixed.trigger(calendar: london))
        XCTAssertNil(TaskSchedule(mode: .day, day: "2026-02-31").trigger(calendar: china))
    }
    func testTodayDoesNotCountUnknownCompletionOrYesterday() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = TaskSchedule(mode: .day, day: "2026-10-21").trigger(calendar: calendar)!
        var today = ReminderItem(); today.schedule = TaskSchedule(mode: .day, day: "2026-10-21")
        var yesterday = today; yesterday.id = UUID(); yesterday.schedule.day = "2026-10-20"
        var done = today; done.id = UUID(); done.isDone = true
        XCTAssertEqual(TaskRules.today([today, yesterday, done, ReminderItem()], now: now, calendar: calendar).map(\.id), [today.id])
    }
    func testTagsNormalizeAndFuzzySearchRequiresAllTerms() {
        let tags = TaskRules.normalizedTags([TaskTag(key: " Area ", value: " Home "), TaskTag(key: "area", value: "Office")])
        XCTAssertEqual(tags, [TaskTag(key: "area", value: "Office")])
        var task = ReminderItem(); task.title = "Buy apples"; task.tags = [TaskTag(key: "place", value: "market")]
        XCTAssertTrue(TaskRules.matches(task, query: "appls market")); XCTAssertFalse(TaskRules.matches(task, query: "apples hospital"))
    }
    func testLegacyOversizeAttributesArePreservedUntilEdited() throws {
        var legacy = ReminderItem(); legacy.title = String(repeating: "旧", count: 110)
        var edited = legacy; edited.isDone = true
        XCTAssertNoThrow(try TaskRules.validate(edited, among: [legacy], previous: legacy))
        edited.title += "新"
        XCTAssertThrowsError(try TaskRules.validate(edited, among: [legacy], previous: legacy))
    }
    func testDirectTitleMatchRanksAboveFuzzyAndBodyMatches() {
        var direct = ReminderItem(); direct.title = "Buy apples"
        var fuzzy = ReminderItem(); fuzzy.title = "Buy appls"
        var body = ReminderItem(); body.title = "Shopping"; body.body = "apples"
        XCTAssertGreaterThan(TaskRules.relevance(direct, query: "apples"), TaskRules.relevance(body, query: "apples"))
        XCTAssertGreaterThan(TaskRules.relevance(body, query: "apples"), TaskRules.relevance(fuzzy, query: "apples"))
    }
    func testBackgroundSnapshotCannotOverwriteNewerLiveAcknowledgement() {
        var task = ReminderItem(); task.title = "较新确认"; task.revision = 7; task.isDone = true
        let current = TaskSnapshot(revision: 4, tasks: [task])
        var stale = task; stale.revision = 5; stale.isDone = false
        let merged = TaskRules.mergeSnapshot(TaskSnapshot(revision: 5, tasks: [stale]), into: current)
        XCTAssertTrue(merged.tasks[0].isDone)
        XCTAssertEqual(TaskRules.mergeSnapshot(TaskSnapshot(revision: 5, tasks: []), into: current).tasks.map(\.id), [task.id])
        XCTAssertTrue(TaskRules.mergeSnapshot(TaskSnapshot(revision: 8, tasks: []), into: current).tasks.isEmpty)
        XCTAssertEqual(TaskRules.mergeSnapshot(TaskSnapshot(revision: 3, tasks: []), into: current).revision, 4)
    }
}
