import Foundation

enum TaskPriority: Int, Codable, CaseIterable, Identifiable {
    case unspecified, low, medium, high
    var id: Int { rawValue }
    var title: String { ["未指定", "低", "中", "高"][rawValue] }
}

struct TaskTag: Codable, Equatable, Hashable {
    var key: String
    var value: String
}

struct TaskSchedule: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case unplanned, day, instant }
    var mode: Mode = .unplanned
    var day: String = ""
    var instant: Date = Date()
    var timeZone: String = TimeZone.current.identifier
    var recurrence: Recurrence = .once
    var intervalHours: Int = 1
    var recurrenceAnchor: Date?

    enum Recurrence: String, Codable, CaseIterable, Identifiable {
        case once, hourly, daily, weekly, monthly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .once: return "仅执行一次"
            case .hourly: return "每隔若干小时"
            case .daily: return "每天"
            case .weekly: return "每周"
            case .monthly: return "每月"
            }
        }
    }

    var recurrenceLabel: String {
        recurrence == .hourly ? "每 \(intervalHours) 小时" : recurrence.title
    }

    /// Calculate from the original anchor so January 31 → February 28 → March 31 does not drift.
    func nextOccurrence(after date: Date) -> Date? {
        guard let first = trigger() else { return nil }
        if first > date { return first }
        guard recurrence != .once else { return nil }
        let anchor = recurrenceAnchor ?? first
        if recurrence == .hourly {
            guard (1...8760).contains(intervalHours) else { return nil }
            let interval = Double(intervalHours) * 3600
            let count = floor(date.timeIntervalSince(anchor) / interval) + 1
            return anchor.addingTimeInterval(max(1, count) * interval)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        let component: Calendar.Component
        let stride: Int
        switch recurrence {
        case .daily: component = .day; stride = 1
        case .weekly: component = .day; stride = 7
        case .monthly: component = .month; stride = 1
        default: return nil
        }
        let distance = calendar.dateComponents([component], from: anchor, to: date).value(for: component) ?? 0
        var index = max(1, distance / stride)
        for _ in 0..<3 {
            guard let candidate = calendar.date(byAdding: component, value: index * stride, to: anchor) else { return nil }
            if candidate > date && candidate >= first { return candidate }
            index += 1
        }
        return nil
    }

    static func == (lhs: TaskSchedule, rhs: TaskSchedule) -> Bool {
        guard lhs.mode == rhs.mode, lhs.recurrence == rhs.recurrence else { return false }
        if lhs.recurrence != .once {
            guard lhs.timeZone == rhs.timeZone, lhs.recurrenceAnchor == rhs.recurrenceAnchor else { return false }
            if lhs.recurrence == .hourly && lhs.intervalHours != rhs.intervalHours { return false }
        }
        switch lhs.mode {
        case .unplanned: return true
        case .day: return lhs.day == rhs.day
        case .instant: return lhs.instant == rhs.instant
        }
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    func trigger(calendar: Calendar = .current) -> Date? {
        switch mode {
        case .unplanned: return nil
        case .instant: return instant
        case .day:
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 9)
            guard let date = calendar.date(from: components), Self.dayString(date, calendar: calendar) == day else { return nil }
            return date
        }
    }

    var label: String {
        switch mode {
        case .unplanned: return "未安排时间"
        case .day: return "\(day) · 当天提醒"
        case .instant: return instant.formatted(date: .abbreviated, time: .shortened)
        }
    }
}

extension TaskSchedule {
    enum CodingKeys: String, CodingKey {
        case mode, day, instant, timeZone, recurrence, intervalHours, recurrenceAnchor
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .unplanned
        day = try values.decodeIfPresent(String.self, forKey: .day) ?? ""
        instant = try values.decodeIfPresent(Date.self, forKey: .instant) ?? Date()
        timeZone = try values.decodeIfPresent(String.self, forKey: .timeZone) ?? TimeZone.current.identifier
        recurrence = try values.decodeIfPresent(Recurrence.self, forKey: .recurrence) ?? .once
        intervalHours = try values.decodeIfPresent(Int.self, forKey: .intervalHours) ?? 1
        recurrenceAnchor = try values.decodeIfPresent(Date.self, forKey: .recurrenceAnchor)
    }
}

struct ReminderItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = ""
    var summary = ""
    var body = ""
    var addedAt = Date()
    var addedAtInferred = false
    var schedule = TaskSchedule()
    var tags: [TaskTag] = []
    var prerequisiteIDs: [UUID] = []
    var priority: TaskPriority = .unspecified
    var isDone = false
    var completedAt: Date?
    var deletedAt: Date?
    var revision = 0
    var fieldVersions: [String: Int] = [:]
    var lifecycle = UUID()
    var notificationVersion = UUID()

    init() {}
    init(id: UUID = UUID(), title: String, dueAt: Date, isDone: Bool = false) {
        self.id = id; self.title = title; self.schedule = TaskSchedule(mode: .instant, instant: dueAt)
        self.isDone = isDone
    }

    enum CodingKeys: String, CodingKey {
        case id, title, summary, body, addedAt, addedAtInferred, schedule, tags, prerequisiteIDs
        case priority, isDone, completedAt, deletedAt, revision, fieldVersions, lifecycle, notificationVersion, dueAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        addedAtInferred = try c.decodeIfPresent(Bool.self, forKey: .addedAtInferred) ?? !c.contains(.addedAt)
        schedule = try c.decodeIfPresent(TaskSchedule.self, forKey: .schedule) ?? TaskSchedule()
        if !c.contains(.schedule), let legacy = try c.decodeIfPresent(Date.self, forKey: .dueAt) {
            schedule = TaskSchedule(mode: .instant, instant: legacy)
        }
        tags = try c.decodeIfPresent([TaskTag].self, forKey: .tags) ?? []
        prerequisiteIDs = try c.decodeIfPresent([UUID].self, forKey: .prerequisiteIDs) ?? []
        priority = try c.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .unspecified
        isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        fieldVersions = try c.decodeIfPresent([String: Int].self, forKey: .fieldVersions) ?? [:]
        lifecycle = try c.decodeIfPresent(UUID.self, forKey: .lifecycle) ?? UUID()
        notificationVersion = try c.decodeIfPresent(UUID.self, forKey: .notificationVersion) ?? UUID()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title)
        try c.encode(summary, forKey: .summary); try c.encode(body, forKey: .body)
        try c.encode(addedAt, forKey: .addedAt); try c.encode(addedAtInferred, forKey: .addedAtInferred)
        try c.encode(schedule, forKey: .schedule); try c.encode(tags, forKey: .tags)
        try c.encode(prerequisiteIDs, forKey: .prerequisiteIDs); try c.encode(priority, forKey: .priority)
        try c.encode(isDone, forKey: .isDone); try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt); try c.encode(revision, forKey: .revision)
        try c.encode(fieldVersions, forKey: .fieldVersions); try c.encode(lifecycle, forKey: .lifecycle)
        try c.encode(notificationVersion, forKey: .notificationVersion)
    }
}

enum TaskField: String, Codable, CaseIterable, Identifiable {
    case title, summary, body, addedAt, schedule, tags, prerequisiteIDs, priority, isDone
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: return "标题"
        case .summary: return "概要"
        case .body: return "具体内容"
        case .addedAt: return "添加时间"
        case .schedule: return "执行时间"
        case .tags: return "标签"
        case .prerequisiteIDs: return "前置任务"
        case .priority: return "重要程度"
        case .isDone: return "是否完成"
        }
    }
    func value(_ task: ReminderItem) -> String {
        switch self {
        case .title: return task.title
        case .summary: return task.summary
        case .body: return task.body
        case .addedAt: return String(task.addedAt.timeIntervalSince1970)
        case .schedule:
            if task.schedule.recurrence != .once { return json(task.schedule) }
            switch task.schedule.mode {
            case .unplanned: return "unplanned"
            case .day: return "day:\(task.schedule.day)"
            case .instant: return "instant:\(task.schedule.instant.timeIntervalSince1970)"
            }
        case .tags: return json(task.tags)
        case .prerequisiteIDs: return json(task.prerequisiteIDs)
        case .priority: return String(task.priority.rawValue)
        case .isDone: return String(task.isDone)
        }
    }
    private func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? ""
    }
    func copy(from other: ReminderItem, to task: inout ReminderItem) {
        switch self {
        case .title: task.title = other.title
        case .summary: task.summary = other.summary
        case .body: task.body = other.body
        case .addedAt: task.addedAt = other.addedAt
        case .schedule: task.schedule = other.schedule
        case .tags: task.tags = other.tags
        case .prerequisiteIDs: task.prerequisiteIDs = other.prerequisiteIDs
        case .priority: task.priority = other.priority
        case .isDone: task.isDone = other.isDone
        }
    }
}

struct TaskVersion: Codable, Identifiable {
    var id = UUID()
    var savedAt = Date()
    var source: String
    var task: ReminderItem
}

enum TaskMessageState: String, Codable { case receiving, complete, stopped, failed }

struct TaskMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var isUser: Bool
    var text: String
    var date: Date? = Date()
    var state: TaskMessageState?
}

struct TaskConversation: Codable, Identifiable {
    var id = UUID()
    var taskID: UUID
    var messages: [TaskMessage] = []
    var updatedAt = Date()

    static func recovered(_ messages: [TaskMessage]) -> [TaskMessage] {
        messages.map { message in
            var value = message
            if value.state == .receiving { value.state = .stopped }
            return value
        }
    }
}

struct TaskConversationArchive {
    let directory: URL
    private func file(_ taskID: UUID) -> URL { directory.appendingPathComponent("conversation-\(taskID.uuidString).json") }
    func load(_ taskID: UUID) throws -> TaskConversation? {
        let url = file(taskID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(TaskConversation.self, from: Data(contentsOf: url))
        guard value.taskID == taskID else { throw TaskFailure("对话归属校验失败，原文件已保留") }
        return value
    }
    func save(_ value: TaskConversation) throws {
        if let old = try load(value.taskID), old.id != value.id { throw TaskFailure("会话标识不一致，原对话已保留") }
        var snapshot = value; snapshot.messages = TaskConversation.recovered(value.messages)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(snapshot).write(to: file(value.taskID), options: options)
    }
    func remove(_ taskID: UUID) throws {
        let url = file(taskID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

struct TaskImage: Codable, Identifiable, Equatable {
    var id = UUID()
    var filename: String
    var text: String = ""
}

struct TaskDraft: Codable {
    var task = ReminderItem()
    var base: ReminderItem?
    var messages: [TaskMessage] = []
    var input = ""
    var images: [TaskImage] = []
    var tab = 0
    var updatedAt = Date()
    var fieldRevisions: [String: Int] = [:]
    var unresolvedConflicts: [TaskField]?
    var conflictProposal: ReminderItem?
    var selectedImageIDs: [UUID]?
    var conversationID: UUID?
    var audio: TaskAudio?
    var key: String { base?.id.uuidString ?? "new" }
    var hasPendingEdits: Bool {
        base == nil || task != base || !input.isEmpty || !images.isEmpty || audio != nil || !(unresolvedConflicts ?? []).isEmpty
    }
}

struct TaskAudio: Codable, Identifiable, Equatable {
    var id = UUID()
    var filename: String
    var transcript: String?
}

enum TaskSpeechIssue {
    static func message(domain: String, code: Int) -> String {
        if domain == "kLSRErrorDomain" && code == 201 {
            return "系统听写已关闭。请前往 iPhone 设置 → 通用 → 键盘 → 启用听写，并检查 Siri 与屏幕使用时间限制；也可在模型入口改选音频转写模型，无需 Siri。已识别文字保留。"
        }
        if domain == "kLSRErrorDomain" && code == 102 { return "系统尚未安装离线语音资源，请检查听写语言，或改选已配置的音频转写模型。" }
        if code == 1700 { return "系统未授权语音识别，请在 iPhone 设置中检查 Venus 权限，或改选音频转写模型。" }
        if code == 1110 { return "没有听清语音，请靠近麦克风重试；已识别文字保留。" }
        return "系统语音识别中断，请重试或改选音频转写模型；已识别文字保留。"
    }
}

struct CompletionOperation: Codable, Identifiable {
    var id = UUID()
    var taskID: UUID
    var lifecycle: UUID
    var baseRevision: Int
    var isDone: Bool
}

struct CompletionAck: Codable {
    var operationID: UUID
    var accepted: Bool
    var completionRevision: Int? = nil
}

struct TaskSnapshot: Codable {
    var revision: Int
    var tasks: [ReminderItem]
}

struct TaskDatabase: Codable {
    var schema = 2
    var revision = 0
    var tasks: [ReminderItem] = []
    var history: [String: [TaskVersion]] = [:]
    var acknowledgements: [String: CompletionAck] = [:]
    var executionHistory: [String: [TaskExecutionRecord]] = [:]
}


extension TaskDatabase {
    enum CodingKeys: String, CodingKey { case schema, revision, tasks, history, acknowledgements, executionHistory }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(Int.self, forKey: .schema) ?? 2
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        tasks = try values.decodeIfPresent([ReminderItem].self, forKey: .tasks) ?? []
        history = try values.decodeIfPresent([String: [TaskVersion]].self, forKey: .history) ?? [:]
        acknowledgements = try values.decodeIfPresent([String: CompletionAck].self, forKey: .acknowledgements) ?? [:]
        if let stored = try values.decodeIfPresent([String: [TaskExecutionRecord]].self, forKey: .executionHistory) {
            executionHistory = stored
        } else {
            executionHistory = Dictionary(uniqueKeysWithValues: tasks.map { task in
                (task.id.uuidString, TaskExecutionHistory.migrate(task: task, versions: history[task.id.uuidString] ?? []))
            })
        }
    }
}
