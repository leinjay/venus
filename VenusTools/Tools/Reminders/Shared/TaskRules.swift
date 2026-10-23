import Foundation

struct TaskFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum TaskRules {
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
        ack.accepted && ack.completionRevision == task.fieldVersions[TaskField.isDone.rawValue]
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
