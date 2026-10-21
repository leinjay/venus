import SwiftUI

struct WatchContentView: View {
    @StateObject private var store = WatchReminderStore()
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 12) {
            Text("任务提醒").font(.system(size: 23, weight: .semibold, design: .serif))
            Text(store.syncMessage).font(.caption2).foregroundStyle(AppTheme.secondary)
            if store.reminders.isEmpty { Text("在 iPhone 上添加任务后同步到这里。包含全部未完成及最近 7 天已完成任务。").font(.caption) }
            ForEach(store.reminders.sorted(by: TaskRules.executionOrder)) { task in
                Button { store.toggle(task) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle").foregroundStyle(AppTheme.pine)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.title).font(.subheadline).foregroundStyle(AppTheme.ink)
                            Text(task.schedule.label).font(.caption2).foregroundStyle(AppTheme.secondary)
                            if task.priority != .unspecified { Text("重要程度：\(task.priority.title)").font(.caption2).foregroundStyle(AppTheme.amber) }
                            if !task.prerequisiteIDs.isEmpty { Text("\(task.prerequisiteIDs.count) 项前置未完成").font(.caption2).foregroundStyle(AppTheme.amber) }
                            if store.isPending(task.id) { Text("待同步").font(.caption2).foregroundStyle(AppTheme.terracotta) }
                        }
                        Spacer(minLength: 0)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
            }
        }.padding(10) }.background(AppTheme.canvas.ignoresSafeArea())
    }
}
