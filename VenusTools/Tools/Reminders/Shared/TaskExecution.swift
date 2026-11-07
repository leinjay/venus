import Foundation

struct TaskExecutionRecord: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case completed, reopened, rescheduled }
    var id = UUID()
    var scheduledAt: Date
    var schedule: TaskSchedule
    var status: Status
    var completedAt: Date?
    var recordedAt: Date
    var source: String
}

struct TaskExecutionEntry: Identifiable {
    enum Status: String, CaseIterable {
        case completed, overdue, pending, planned, rescheduled
        var title: String {
            switch self {
            case .completed: return "已完成"
            case .overdue: return "逾期未完成"
            case .pending: return "待执行"
            case .planned: return "计划执行"
            case .rescheduled: return "计划已调整"
            }
        }
    }
    var id: Date { scheduledAt }
    var scheduledAt: Date
    var status: Status
    var completedAt: Date?
    var source: String?
}

enum TaskExecutionHistory {
    static func record(_ task: ReminderItem, status: TaskExecutionRecord.Status, at date: Date, source: String, into records: inout [TaskExecutionRecord]) {
        guard let scheduled = task.schedule.trigger() ?? task.completedAt else { return }
        let existing = records.firstIndex { $0.scheduledAt == scheduled }
        let record = TaskExecutionRecord(
            id: existing.map { records[$0].id } ?? UUID(),
            scheduledAt: scheduled, schedule: task.schedule, status: status,
            completedAt: status == .completed ? task.completedAt : nil, recordedAt: date, source: source
        )
        if let existing { records[existing] = record } else { records.append(record) }
    }

    static func capture(previous: ReminderItem?, current: ReminderItem, completedCycle: ReminderItem?, at date: Date, source: String, into records: inout [TaskExecutionRecord]) {
        if let completedCycle {
            record(completedCycle, status: .completed, at: date, source: source, into: &records)
            return
        }
        if current.isDone && previous?.isDone != true {
            record(current, status: .completed, at: date, source: source, into: &records)
        }
        if let previous {
            if previous.isDone && !current.isDone && previous.schedule == current.schedule {
                record(previous, status: .reopened, at: date, source: source, into: &records)
            }
            if previous.schedule != current.schedule && !previous.isDone {
                record(previous, status: .rescheduled, at: date, source: source, into: &records)
            }
        }
    }

    static func migrate(task: ReminderItem, versions: [TaskVersion]) -> [TaskExecutionRecord] {
        var records: [TaskExecutionRecord] = []
        var previous: ReminderItem?
        for version in versions.sorted(by: { $0.savedAt < $1.savedAt }) {
            // Advancing a recurring task is already represented by the preceding completed version.
            let advancedCycle = previous?.isDone == true && previous?.schedule.recurrence != .once
                && previous?.schedule != version.task.schedule
            if !advancedCycle {
                capture(previous: previous, current: version.task, completedCycle: nil,
                        at: version.task.completedAt ?? version.savedAt, source: version.source, into: &records)
            }
            previous = version.task
        }
        if task.isDone, !records.contains(where: { $0.scheduledAt == task.schedule.trigger() }) {
            record(task, status: .completed, at: task.completedAt ?? task.addedAt, source: "旧任务记录", into: &records)
        }
        return records
    }

    private static func dates(_ schedule: TaskSchedule, in interval: DateInterval, through end: Date) -> [Date] {
        var result: [Date] = []
        var next = schedule.nextOccurrence(after: interval.start.addingTimeInterval(-0.001))
        while let date = next, date < interval.end, date <= end {
            result.append(date)
            guard schedule.recurrence != .once,
                  let following = schedule.nextOccurrence(after: date), following > date else { break }
            next = following
        }
        return result
    }

    static func entries(task: ReminderItem, records: [TaskExecutionRecord], in interval: DateInterval, now: Date, calendar: Calendar = .current) -> [TaskExecutionEntry] {
        var entries: [Date: TaskExecutionEntry] = [:]
        if !task.isDone {
            for date in dates(task.schedule, in: interval, through: interval.end) {
                let cutoff = task.schedule.mode == .day ? calendar.startOfDay(for: now) : now
                let status: TaskExecutionEntry.Status = date < cutoff ? .overdue : calendar.isDate(date, inSameDayAs: now) ? .pending : .planned
                entries[date] = TaskExecutionEntry(scheduledAt: date, status: status)
            }
        }
        // Persisted schedule snapshots also describe periods missed before completion or rescheduling.
        for record in records.sorted(by: { $0.recordedAt < $1.recordedAt }) {
            if record.status != .reopened {
                for date in dates(record.schedule, in: interval, through: record.recordedAt) where entries[date]?.status != .completed {
                    entries[date] = TaskExecutionEntry(scheduledAt: date, status: .overdue)
                }
            }
            guard interval.contains(record.scheduledAt), record.scheduledAt < interval.end else { continue }
            let status: TaskExecutionEntry.Status
            switch record.status {
            case .completed: status = .completed
            case .reopened: status = record.scheduledAt < now ? .overdue : .pending
            case .rescheduled: status = .rescheduled
            }
            entries[record.scheduledAt] = TaskExecutionEntry(
                scheduledAt: record.scheduledAt, status: status, completedAt: record.completedAt, source: record.source
            )
        }
        return entries.values.sorted { $0.scheduledAt < $1.scheduledAt }
    }
}
