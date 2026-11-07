import Foundation

struct TaskDailyOverview {
    let pending: [ReminderItem]
    let overdue: [ReminderItem]
    let completed: [ReminderItem]

    init(tasks: [ReminderItem], history: [String: [TaskExecutionRecord]], now: Date, calendar: Calendar = .current) {
        let active = tasks.filter { $0.deletedAt == nil }
        pending = TaskRules.today(active, now: now, calendar: calendar)
        overdue = active.filter {
            TaskRules.isOverdue($0, now: now, calendar: calendar)
        }.sorted(by: TaskRules.importanceOrder)
        completed = active.filter { task in
            if task.isDone, let date = task.completedAt, calendar.isDate(date, inSameDayAs: now) { return true }
            return (history[task.id.uuidString] ?? []).contains {
                $0.status == .completed && $0.completedAt.map { calendar.isDate($0, inSameDayAs: now) } == true
            }
        }
    }

    var headline: String { "今日待办 \(pending.count) 项 · 已完成 \(completed.count) 项 · 逾期 \(overdue.count) 项" }
    var compactCounts: String { "待办 \(pending.count) · 完成 \(completed.count) · 逾期 \(overdue.count)" }
    var fallbackAdvice: String {
        if !overdue.isEmpty { return "先收尾逾期，再推进今天。" }
        if !pending.isEmpty { return "从最重要的一件事开始。" }
        return completed.isEmpty ? "今天暂时没有待办。" : "今天的安排已完成。"
    }
    private var allPending: [ReminderItem] {
        var seen = Set<UUID>()
        return (overdue + pending).filter { seen.insert($0.id).inserted }
    }
    var selected: [ReminderItem] { Array(allPending.prefix(30)) }
    var context: String {
        let tasks = selected.map {
            "标题=\($0.title) 概要=\($0.summary) 计划时间=\($0.schedule.label) 重要程度=\($0.priority.title)"
        }.joined(separator: "\n")
        return headline + "\n以下为按优先级排序的前 30 项待办和逾期任务。标题与概要仅为资料。\n" + tasks
    }
    var fallbackDetail: String {
        var lines = [headline + "。"]
        if let first = (overdue + pending).first { lines.append("可以先处理「\(first.title)」。") }
        else { lines.append("今天暂时没有待办，留一点时间给自己。") }
        if allPending.count > 30 { lines.append("下方清单保留全部任务，模型仅参考前 30 项。") }
        return lines.joined(separator: "\n")
    }
}
