import XCTest
@testable import VenusTaskCore

final class TaskRulesTests: XCTestCase {
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
