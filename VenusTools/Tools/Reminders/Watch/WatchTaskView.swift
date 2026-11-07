import SwiftUI

private enum WatchTaskScope: String, CaseIterable {
    case pending = "待办", today = "今天", completed = "已完成"
}

// Keep the phone palette, with darker small text for the Watch's cream surfaces.
private enum WatchTaskPalette {
    static let secondary = Color(hex: 0x566459)
    static let warning = Color(hex: 0x875019)
}

private struct WatchTaskScreen: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(AppTheme.ink)
            .background(AppTheme.canvas.ignoresSafeArea())
            .containerBackground(AppTheme.canvas, for: .navigation)
    }
}

struct WatchContentView: View {
    @StateObject private var store = WatchReminderStore()
    @State private var scope = WatchTaskScope.pending
    @Environment(\.scenePhase) private var scenePhase

    private var tasks: [ReminderItem] {
        switch scope {
        case .pending: return store.reminders.filter { !$0.isDone }.sorted(by: TaskRules.executionOrder)
        case .today: return TaskRules.today(store.reminders)
        case .completed: return store.reminders.filter(\.isDone).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("随身任务").font(.system(size: 23, weight: .semibold, design: .serif))
                    HStack(spacing: 4) {
                        ForEach(WatchTaskScope.allCases, id: \.self) { item in
                            Button { scope = item } label: {
                                Text(item.rawValue).font(.caption2).bold().frame(maxWidth: .infinity).padding(.vertical, 8)
                                    .foregroundStyle(scope == item ? AppTheme.surface : AppTheme.ink)
                                    .background(scope == item ? AppTheme.pine : AppTheme.surface, in: Capsule())
                                    .overlay { Capsule().stroke(scope == item ? AppTheme.pine : AppTheme.line, lineWidth: 1) }
                            }.buttonStyle(.plain)
                                .accessibilityValue(scope == item ? "已选择" : "未选择")
                        }
                    }
                    if tasks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: store.hasSnapshot ? "checklist" : "iphone.and.arrow.forward").font(.title2).foregroundStyle(AppTheme.pine)
                            Text(store.hasSnapshot ? "这里暂时没有任务" : "等待第一份任务").font(.headline)
                            Text(store.hasSnapshot ? "在手机上添加或调整任务后，点击下方同步。已完成仅显示最近 7 天。" : "先在 iPhone 打开 Venus，再点击同步。收到任务后，离线也能查看缓存。")
                                .font(.caption2).foregroundStyle(WatchTaskPalette.secondary)
                        }.padding(.vertical, 8)
                    }
                    LazyVStack(spacing: 8) {
                        ForEach(tasks) { task in
                            NavigationLink { WatchTaskDetailView(store: store, taskID: task.id) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(AppTheme.pine)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(task.title).font(.subheadline).foregroundStyle(AppTheme.ink).lineLimit(3)
                                        Text(task.schedule.label).font(.caption2).foregroundStyle(WatchTaskPalette.secondary)
                                        if task.schedule.recurrence != .once { Text(task.schedule.recurrenceLabel).font(.caption2).foregroundStyle(WatchTaskPalette.secondary) }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay { RoundedRectangle(cornerRadius: 14).stroke(AppTheme.line, lineWidth: 1) }
                            }.buttonStyle(.plain)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.syncMessage).font(.caption2)
                        if let date = store.lastSyncedAt { Text("最近接收：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(WatchTaskPalette.secondary) }
                        Button { store.requestSync() } label: {
                            Label("同步手机任务", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption).fontWeight(.semibold)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .foregroundStyle(AppTheme.surface)
                                .background(AppTheme.pine, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain)
                        Text("提醒时间在手机设置；请开启 Venus 的手表通知镜像。").font(.caption2).foregroundStyle(WatchTaskPalette.secondary)
                    }.padding(.top, 6)
                }.padding(.horizontal, 10)
            }.modifier(WatchTaskScreen()).navigationTitle("Venus")
                .onChange(of: scenePhase) { _, phase in if phase == .active { store.requestSync() } }
        }.tint(AppTheme.pine)
    }
}

private struct WatchTaskDetailView: View {
    @ObservedObject var store: WatchReminderStore
    let taskID: UUID

    var body: some View {
        ScrollView {
            if let task = store.reminders.first(where: { $0.id == taskID }) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(task.title).font(.headline)
                    Label(task.isDone ? "已完成" : "待完成", systemImage: task.isDone ? "checkmark.circle.fill" : "circle.dotted").font(.caption).foregroundStyle(AppTheme.pine)
                    Text(task.schedule.label).font(.caption)
                    Text(task.schedule.recurrenceLabel).font(.caption)
                    if !task.summary.isEmpty { Text(task.summary).font(.body) }
                    if task.priority != .unspecified { Text("重要程度：\(task.priority.title)").font(.caption).foregroundStyle(WatchTaskPalette.warning) }
                    if !task.prerequisiteIDs.isEmpty { Text("还有 \(task.prerequisiteIDs.count) 项前置未完成").font(.caption).foregroundStyle(WatchTaskPalette.warning) }
                    Text("任务由 iPhone 管理，可在手机上编辑或完成。").font(.caption2).foregroundStyle(WatchTaskPalette.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            } else {
                Text("任务已不在同步范围内，请返回列表。").font(.caption).padding()
            }
        }.modifier(WatchTaskScreen()).navigationTitle("任务详情")
    }
}
