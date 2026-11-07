import Foundation
import CoreGraphics

/// A release can only request transcription; sending a chat message is a separate action.
struct TaskVoiceHold {
    enum Phase: Equatable { case idle, holding, cancelling, released, cancelled }
    private(set) var phase: Phase = .idle
    private(set) var id = UUID()
    var isActive: Bool { phase == .holding || phase == .cancelling }
    var cancelsOnRelease: Bool { phase == .cancelling }

    mutating func begin() -> UUID {
        id = UUID(); phase = .holding; return id
    }
    mutating func move(to point: CGPoint, cancelRegion: CGRect) {
        guard isActive else { return }
        phase = !cancelRegion.isEmpty && cancelRegion.contains(point) ? .cancelling : .holding
    }
    @discardableResult mutating func release() -> Bool {
        guard isActive else { return false }
        let convert = !cancelsOnRelease
        phase = convert ? .released : .cancelled
        return convert
    }
    mutating func cancel() { phase = .cancelled; id = UUID() }
    func accepts(_ token: UUID) -> Bool { token == id && (isActive || phase == .released) }
    static func cancelRegion(above button: CGRect) -> CGRect {
        guard !button.isEmpty else { return .zero }
        return CGRect(x: button.midX - 44, y: max(60, button.minY - 86) - 44, width: 88, height: 88)
    }
}

struct TaskFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct TaskNotificationOccurrence {
    var task: ReminderItem
    var date: Date
    var identifier: String { "task.\(task.id).\(date.timeIntervalSince1970)" }
}

enum TaskRules {
    static func nextCycle(afterCompleting task: ReminderItem, now: Date) throws -> ReminderItem {
        guard let due = task.schedule.trigger(),
              let next = task.schedule.nextOccurrence(after: max(now, due)), task.schedule.recurrence != .once else {
            throw TaskFailure("无法计算下一次执行时间，请检查执行周期")
        }
        var result = task
        result.schedule.recurrenceAnchor = task.schedule.recurrenceAnchor ?? due
        result.schedule.mode = .instant
        result.schedule.instant = next
        result.isDone = false
        result.completedAt = nil
        result.notificationVersion = UUID()
        return result
    }

    /// Keep the earliest future occurrences across all tasks within iOS's shared notification capacity.
    static func notificationPlan(_ tasks: [ReminderItem], after now: Date, limit: Int, ledger: [String: Date]) -> [TaskNotificationOccurrence] {
        var candidates = tasks.compactMap { task -> TaskNotificationOccurrence? in
            guard !task.isDone, task.deletedAt == nil else { return nil }
            if task.schedule.recurrence == .once, let delivered = ledger[task.notificationVersion.uuidString], delivered <= now { return nil }
            guard let date = task.schedule.nextOccurrence(after: now) else { return nil }
            return TaskNotificationOccurrence(task: task, date: date)
        }
        var result: [TaskNotificationOccurrence] = []
        for _ in 0..<max(0, limit) {
            candidates.sort {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.task.id.uuidString < $1.task.id.uuidString
            }
            guard !candidates.isEmpty else { break }
            let occurrence = candidates.removeFirst()
            result.append(occurrence)
            if occurrence.task.schedule.recurrence != .once,
               let date = occurrence.task.schedule.nextOccurrence(after: occurrence.date) {
                candidates.append(TaskNotificationOccurrence(task: occurrence.task, date: date))
            }
        }
        return result
    }

    static func isOverdue(_ task: ReminderItem, now: Date, calendar: Calendar = .current) -> Bool {
        guard !task.isDone, task.deletedAt == nil, let date = task.schedule.trigger(calendar: calendar) else { return false }
        let cutoff = task.schedule.mode == .day ? calendar.startOfDay(for: now) : now
        return date < cutoff
    }

    static func notificationText(_ task: ReminderItem, hideDetails: Bool) -> (title: String, body: String) {
        guard !hideDetails else { return ("你有一项任务待处理", "打开 Venus 查看任务详情") }
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = task.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = task.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = !summary.isEmpty ? summary : !details.isEmpty ? details : "点击查看任务详情"
        let body = text.count > 280 ? String(text.prefix(280)) + "…" : text
        return (title.isEmpty ? "任务提醒" : title, body)
    }

    static func normalizedTags(_ tags: [TaskTag]) -> [TaskTag] {
        var result: [TaskTag] = []
        for tag in tags {
            let clean = TaskTag(key: tag.key.trimmingCharacters(in: .whitespacesAndNewlines), value: tag.value.trimmingCharacters(in: .whitespacesAndNewlines))
            result.removeAll { $0.key.lowercased() == clean.key.lowercased() }
            result.append(clean)
        }
        return result
    }

    static func validate(_ task: ReminderItem, among tasks: [ReminderItem], previous: ReminderItem? = nil) throws {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard previous?.title == task.title || (!title.isEmpty && title.count <= 100) else { throw TaskFailure("标题需要 1～100 个字符") }
        guard previous?.summary == task.summary || task.summary.count <= 300 else { throw TaskFailure("概要最多 300 个字符") }
        guard previous?.body == task.body || task.body.count <= 20_000 else { throw TaskFailure("具体内容最多 20,000 个字符") }
        guard task.tags.count <= 20, task.tags.allSatisfy({ (1...20).contains($0.key.count) && (1...50).contains($0.value.count) }) else {
            throw TaskFailure("最多 20 个标签；名称 1～20 字，值 1～50 字")
        }
        guard task.schedule.mode != .day || task.schedule.trigger() != nil else { throw TaskFailure("执行日期无效") }
        if task.schedule.recurrence != .once {
            guard task.schedule.mode == .instant, TimeZone(identifier: task.schedule.timeZone) != nil else { throw TaskFailure("周期任务需要精确执行时间和有效时区") }
            guard task.schedule.recurrence != .hourly || (1...8760).contains(task.schedule.intervalHours) else { throw TaskFailure("间隔小时数需要在 1～8760 之间") }
            guard task.schedule.recurrenceAnchor.map({ $0 <= task.schedule.instant }) ?? true else { throw TaskFailure("周期起点不能晚于执行时间") }
        }
        let active = tasks.filter { $0.deletedAt == nil && $0.id != task.id } + [task]
        let ids = Set(active.map(\.id))
        guard Set(task.prerequisiteIDs).count == task.prerequisiteIDs.count, task.prerequisiteIDs.allSatisfy({ ids.contains($0) && $0 != task.id }) else {
            throw TaskFailure("前置任务不存在、重复或引用了当前任务")
        }
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        var visiting = Set<UUID>(), visited = Set<UUID>()
        func visit(_ id: UUID) -> Bool {
            if visiting.contains(id) { return false }
            if visited.contains(id) { return true }
            visiting.insert(id)
            for dependency in byID[id]?.prerequisiteIDs ?? [] { if !visit(dependency) { return false } }
            visiting.remove(id); visited.insert(id)
            return true
        }
        guard visit(task.id) else { throw TaskFailure("这些前置任务会形成循环，请调整依赖") }
    }

    /// Return conflicts; untouched fields always adopt the latest authoritative value.
    static func merge(base: ReminderItem, draft: ReminderItem, latest: ReminderItem) -> (ReminderItem, [TaskField]) {
        var result = latest
        var conflicts: [TaskField] = []
        for field in TaskField.allCases where field.value(base) != field.value(draft) {
            if field == .isDone, latest.schedule.recurrence != .once, base.schedule != latest.schedule {
                conflicts.append(field)
                continue
            }
            if field.value(latest) != field.value(base), field.value(latest) != field.value(draft) {
                conflicts.append(field)
            } else { field.copy(from: draft, to: &result) }
        }
        return (result, conflicts)
    }

    static func accepts(_ operation: CompletionOperation, for task: ReminderItem) -> Bool {
        task.deletedAt == nil && operation.taskID == task.id && operation.lifecycle == task.lifecycle
            && operation.baseRevision == (task.fieldVersions[TaskField.isDone.rawValue] ?? 0)
    }

    static func canContinue(after ack: CompletionAck, task: ReminderItem) -> Bool {
        task.schedule.recurrence == .once && ack.accepted && ack.completionRevision == task.fieldVersions[TaskField.isDone.rawValue]
            && ack.completionRevision != nil && task.deletedAt == nil
    }

    static func mergeSnapshot(_ incoming: TaskSnapshot, into current: TaskSnapshot) -> TaskSnapshot {
        guard incoming.revision >= current.revision else { return current }
        let latest = Dictionary(uniqueKeysWithValues: current.tasks.map { ($0.id, $0) })
        var result = incoming.tasks.map { task in
            if let newer = latest[task.id], newer.revision > task.revision { return newer }
            return task
        }
        let included = Set(result.map(\.id))
        // A live acknowledgement can precede an older, slower background file.
        result += current.tasks.filter { !included.contains($0.id) && $0.revision > incoming.revision }
        return TaskSnapshot(revision: incoming.revision, tasks: result)
    }

    static func dependencyIDs(for id: UUID, tasks: [ReminderItem]) -> Set<UUID> {
        let active = tasks.filter { $0.deletedAt == nil }
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        var result: Set<UUID> = [id]
        func ancestors(_ id: UUID) {
            for parent in byID[id]?.prerequisiteIDs ?? [] where result.insert(parent).inserted { ancestors(parent) }
        }
        ancestors(id)
        var descendants: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for task in active where !descendants.contains(task.id) && task.prerequisiteIDs.contains(where: descendants.contains) {
                descendants.insert(task.id); result.insert(task.id); changed = true
            }
        }
        for descendant in descendants { ancestors(descendant) }
        return result
    }

    /// The phone owns the data; Watch gets a compact, read-only projection.
    static func watchSnapshot(_ tasks: [ReminderItem], revision: Int, now: Date = Date(), calendar: Calendar = .current) -> TaskSnapshot {
        let start = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -6, to: start)!
        let active = tasks.filter { $0.deletedAt == nil }
        let unfinished = Set(active.filter { !$0.isDone }.map(\.id))
        let visible = active.filter {
            !$0.isDone || $0.completedAt.map { $0 >= cutoff } == true
        }.map { task -> ReminderItem in
            var value = task
            value.body = ""; value.tags = []
            value.prerequisiteIDs = task.prerequisiteIDs.filter { unfinished.contains($0) }
            return value
        }
        return TaskSnapshot(revision: revision, tasks: visible)
    }

    static func matches(_ task: ReminderItem, query: String) -> Bool {
        let text = ([task.title, task.summary, task.body] + task.tags.map { "\($0.key):\($0.value)" }).joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            let word = String(term).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if text.contains(word) { return true }
            guard (2...10).contains(word.count) else { return false }
            let title = Array(task.title.lowercased()), needle = Array(word)
            guard !title.isEmpty else { return false }
            for length in max(1, needle.count - 1)...(needle.count + 1) where length <= title.count {
                for start in 0...(title.count - length) {
                    if editDistance(Array(title[start..<(start + length)]), needle) <= 1 { return true }
                }
            }
            return false
        }
    }

    static func relevance(_ task: ReminderItem, query: String) -> Int {
        query.split(whereSeparator: \.isWhitespace).reduce(0) { score, word in
            let term = String(word)
            if task.title.localizedCaseInsensitiveContains(term) { return score + 100 }
            if task.summary.localizedCaseInsensitiveContains(term) { return score + 40 }
            if task.tags.contains(where: { "\($0.key):\($0.value)".localizedCaseInsensitiveContains(term) }) { return score + 30 }
            if task.body.localizedCaseInsensitiveContains(term) { return score + 10 }
            return score + 1
        }
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, char) in a.enumerated() {
            var next = [i + 1]
            for (j, other) in b.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (char == other ? 0 : 1))) }
            row = next
        }
        return row[b.count]
    }

    static func today(_ tasks: [ReminderItem], now: Date = Date(), calendar: Calendar = .current) -> [ReminderItem] {
        tasks.filter { $0.deletedAt == nil && !$0.isDone && $0.schedule.trigger(calendar: calendar).map { calendar.isDate($0, inSameDayAs: now) } == true }
            .sorted(by: importanceOrder)
    }
    static func importanceOrder(_ a: ReminderItem, _ b: ReminderItem) -> Bool {
        if a.priority != b.priority { return a.priority.rawValue > b.priority.rawValue }
        return executionOrder(a, b)
    }
    static func executionOrder(_ a: ReminderItem, _ b: ReminderItem) -> Bool {
        let left = a.schedule.trigger() ?? .distantFuture, right = b.schedule.trigger() ?? .distantFuture
        if left != right { return left < right }
        if a.addedAt != b.addedAt { return a.addedAt > b.addedAt }
        return a.id.uuidString < b.id.uuidString
    }
}
