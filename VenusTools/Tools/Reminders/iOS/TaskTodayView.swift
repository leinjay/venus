import SwiftUI

struct TaskTodayView: View {
    @ObservedObject var store: ReminderStore
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()
    @State private var summary = ""
    @State private var error: String?
    @State private var stale = false
    @State private var generating = false
    @State private var request: Task<Void, Never>?
    @State private var token = UUID()
    var onManageModels: (() -> Void)? = nil
    var onOpen: (UUID) -> Void
    private var today: [ReminderItem] { TaskRules.today(store.reminders, now: now) }
    private var overdue: [ReminderItem] { let start = Calendar.current.startOfDay(for: now); return store.reminders.filter { !$0.isDone && $0.schedule.trigger().map { $0 < start } == true }.sorted(by: TaskRules.importanceOrder) }
    private var unplanned: [ReminderItem] { store.reminders.filter { !$0.isDone && $0.schedule.mode == .unplanned } }
    private var completed: [ReminderItem] { store.reminders.filter { $0.isDone && $0.completedAt.map { Calendar.current.isDate($0, inSameDayAs: now) } == true } }
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    var body: some View {
        NavigationStack { List {
            Section {
                Text(now.formatted(date: .complete, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                Text("今天 \(today.count) 项待办 · 已完成 \(completed.count) 项").font(.headline)
                if generating { HStack { ProgressView(); Text("正在总结"); Spacer(); Button("取消") { cancel() } } }
                if stale { Text("内容已变化，点击刷新").font(.caption).foregroundStyle(AppTheme.amber) }
                if !summary.isEmpty { Text(summary).textSelection(.enabled) }
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                Button("刷新 AI 总结") { generate() }.disabled(generating)
            }
            Section("今日待办 · \(today.count)") {
                if today.isEmpty { Text("今天没有安排待办任务") }
                ForEach(today) { task in row(task, elapsed: task.schedule.mode == .instant && (task.schedule.trigger() ?? .distantFuture) < now) }
            }
            if !overdue.isEmpty { Section("此前逾期 · \(overdue.count)") { ForEach(overdue) { row($0) } } }
            if !unplanned.isEmpty { Section { DisclosureGroup("未安排 · \(unplanned.count) 项") { ForEach(unplanned) { row($0) } } } }
            if !completed.isEmpty { Section { DisclosureGroup("今天已完成 · \(completed.count) 项") { ForEach(completed) { row($0) } } } }
            Section { ModelBindingPanel(purpose: .summary, onManage: onManageModels) }
        }.navigationTitle("今天要做的事").toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        .task { generate() }
        .onChange(of: store.revision) { _, _ in now = Date(); cancel(); stale = true }
        .onReceive(timer) { date in if TaskSchedule.dayString(now) != TaskSchedule.dayString(date) { cancel(); stale = true }; now = date }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in now = Date(); cancel(); stale = true }
        .onDisappear { cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in cancel() }
        }
    }
    private func row(_ task: ReminderItem, elapsed: Bool = false) -> some View {
        Button { onOpen(task.id) } label: { VStack(alignment: .leading, spacing: 5) { Text(task.title).foregroundStyle(AppTheme.ink); Text(task.schedule.label + (elapsed ? " · 时间已过" : "")).font(.caption).foregroundStyle(.secondary); let count = store.unfinishedPrerequisites(task); if count > 0 { Label("\(count) 项前置任务未完成", systemImage: "link").font(.caption).foregroundStyle(AppTheme.amber) } } }
    }
    private func cancel() { token = UUID(); request?.cancel(); request = nil; generating = false }
    private func generate() {
        cancel(); now = Date(); stale = false; error = nil
        guard !today.isEmpty || !overdue.isEmpty else { summary = "今天没有待办或此前逾期任务。"; return }
        let selected = Array((today + overdue).prefix(30))
        let input = selected.map { task in "ID=\(task.id) 标题=\(task.title) 概要=\(task.summary) 时间=\(task.schedule.label) 等级=\(task.priority.title) 未完成前置=\(store.unfinishedPrerequisites(task))" }.joined(separator: "\n")
        let current = token, revision = store.revision
        generating = true
        request = Task {
            do {
                let output = try await ConfiguredModelService.shared.respond(purpose: .summary, system: "只归纳给出的真实任务，不猜测新任务或完成状态，不改动数据。只输出JSON：{\"items\":[{\"id\":\"原始任务UUID\",\"summary\":\"简短行动要点\"}]}。保留原顺序，每个输入任务恰好出现一次，不重新估算数量。", prompt: input)
                let object = try TaskAI.parseObject(output)
                guard let entries = object["items"] as? [[String: String]], entries.count == selected.count else { throw TaskFailure("总结内容不完整，请查看下方完整清单或重试") }
                let ids = entries.compactMap { $0["id"].flatMap(UUID.init(uuidString:)) }
                guard Set(ids) == Set(selected.map(\.id)), ids.count == Set(ids).count, entries.allSatisfy({ $0["summary"]?.isEmpty == false }) else { throw TaskFailure("模型总结包含无效任务，已保留真实任务清单") }
                guard !Task.isCancelled, token == current, revision == store.revision else { return }
                summary = selected.map { task in "• \(task.title)：\(entries.first { $0["id"]?.lowercased() == task.id.uuidString.lowercased() }?["summary"] ?? "")" }.joined(separator: "\n")
                if today.count + overdue.count > 30 { summary += "\n本次概述前 30 项，完整清单共 \(today.count + overdue.count) 项。" }
                generating = false
            } catch { guard token == current else { return }; generating = false; if !(error is CancellationError) { self.error = "\(error.localizedDescription)。下方真实清单仍可使用。" } }
        }
    }
}
