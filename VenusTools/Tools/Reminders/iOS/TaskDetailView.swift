import SwiftUI

struct TaskDetailView: View {
    @ObservedObject var store: ReminderStore
    let taskID: UUID
    var onEdit: () -> Void
    var onOpen: (UUID) -> Void
    var onRestore: (UUID) -> Void
    @State private var tab = 0
    @State private var history = false
    @State private var executionCalendar = false
    @State private var delete = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if let task = store.item(taskID) {
                VStack {
                    Picker("详情页签", selection: Binding(get: { tab }, set: { selection in
                        if selection == 1 { onEdit() } else { tab = selection }
                    })) { Text("任务信息").tag(0); Text("任务编辑").tag(1); Text("依赖查看").tag(2) }.pickerStyle(.segmented).padding()
                    if tab == 0 { information(task) }
                    else { TaskDependencyView(tasks: store.reminders, current: taskID, onOpen: onOpen) }
                }
                .navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button { executionCalendar = true } label: { Image(systemName: "calendar") }.accessibilityLabel("执行日历") }
                    ToolbarItem(placement: .topBarTrailing) { Menu { Button("修改记录") { history = true }; Button("移到回收站", role: .destructive) { delete = true } } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("任务更多操作") }
                }
                .confirmationDialog("移到回收站？30 天内可恢复。\(store.reminders.filter { $0.prerequisiteIDs.contains(taskID) }.count) 项后续任务会解除此依赖，恢复时不自动重连。", isPresented: $delete, titleVisibility: .visible) { Button("移到回收站", role: .destructive) { store.remove(task); if store.item(taskID) == nil { dismiss() } } }
                .sheet(isPresented: $executionCalendar) { TaskExecutionCalendarView(store: store, taskID: taskID) }
                .sheet(isPresented: $history) {
                    NavigationStack { List(store.versions(taskID)) { version in
                        VStack(alignment: .leading, spacing: 8) { Text(version.savedAt.formatted()); Text("\(version.source) · \(version.task.title)").font(.caption).foregroundStyle(.secondary); Button("进入表单预览与恢复") { history = false; onRestore(version.id) } }
                    }.navigationTitle("最近 20 个版本").toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { history = false } } } }
                }
            } else { ContentUnavailableView("任务已移除", systemImage: "trash", description: Text("可返回列表，在回收站查看。")) }
        }.background(AppTheme.canvas.ignoresSafeArea())
        .onAppear { tab = 0 }
    }
    private func information(_ task: ReminderItem) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Text(task.title).font(.system(size: 28, weight: .semibold, design: .serif)).textSelection(.enabled)
            Button { store.toggle(task) } label: { Label(task.isDone ? "已完成 · 点击恢复" : task.schedule.recurrence == .once ? "标记为已完成" : "完成本次，安排下一次", systemImage: task.isDone ? "checkmark.circle.fill" : "circle") }.buttonStyle(.bordered)
            if !task.summary.isEmpty { Text(task.summary).font(.body).foregroundStyle(AppTheme.secondary).textSelection(.enabled) }
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("执行时间", value: task.schedule.label)
                LabeledContent("执行周期", value: task.schedule.recurrenceLabel)
                LabeledContent("添加时间", value: task.addedAt.formatted())
                if task.addedAtInferred { Text("添加时间由旧数据迁移补齐").font(.caption).foregroundStyle(.secondary) }
                LabeledContent("重要程度", value: task.priority.title)
                if task.isDone { LabeledContent("完成时间", value: task.completedAt?.formatted() ?? "历史完成时间未知") }
                if !task.tags.isEmpty { Text(task.tags.map { "\($0.key):\($0.value)" }.joined(separator: " · ")) }
            }.font(.subheadline).surfaceCard()
            if !task.prerequisiteIDs.isEmpty {
                VStack(alignment: .leading, spacing: 12) { Text("前置任务").font(.headline); ForEach(task.prerequisiteIDs, id: \.self) { id in if let parent = store.item(id) { Button { onOpen(id) } label: { Label(parent.title, systemImage: parent.isDone ? "checkmark.circle" : "circle.dotted") } } } }.surfaceCard()
            }
            if !task.body.isEmpty { VStack(alignment: .leading, spacing: 12) { Text("具体内容").font(.headline); Text(.init(task.body)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.surfaceCard() }
        }.padding(20).padding(.bottom, 70) }
    }
}

struct TaskDependencyView: View {
    let tasks: [ReminderItem]
    let current: UUID
    var onOpen: (UUID) -> Void
    @State private var zoom = 1.0
    private var related: [ReminderItem] { let ids = TaskRules.dependencyIDs(for: current, tasks: tasks); return tasks.filter { ids.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString } }
    private var columns: [[ReminderItem]] {
        let values = related
        let byID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        var memo: [UUID: Int] = [:]
        func depth(_ id: UUID, visited: Set<UUID> = []) -> Int {
            if let known = memo[id] { return known }; guard !visited.contains(id) else { return 0 }
            let next = visited.union([id])
            let value = (byID[id]?.prerequisiteIDs.compactMap { byID[$0] == nil ? nil : depth($0, visited: next) }.max().map { $0 + 1 }) ?? 0
            memo[id] = value; return value
        }
        let grouped = Dictionary(grouping: values) { depth($0.id) }
        return (0...max(0, memo.values.max() ?? 0)).map { grouped[$0] ?? [] }
    }
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("前置 → 后续 · \(related.count) 项任务").font(.caption); Spacer(); Button { zoom = max(0.4, zoom - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }; Button { zoom = min(1.8, zoom + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }; Button("复位") { zoom = 1 } }.padding(.horizontal)
            Text("包含完整上下游及共同前置。拖动查看，点节点打开任务。").font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
            GeometryReader { geometry in
                let groups = columns
                let size = CGSize(width: CGFloat(max(1, groups.count)) * 260 + 32, height: CGFloat(max(1, groups.map(\.count).max() ?? 1)) * 132 + 32)
                let positions = positions(groups)
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            for task in related { for parent in task.prerequisiteIDs {
                                guard let start = positions[parent], let end = positions[task.id] else { continue }
                                let a = CGPoint(x: start.x + 190, y: start.y + 48), b = CGPoint(x: end.x, y: end.y + 48)
                                var line = Path(); line.move(to: a); line.addCurve(to: b, control1: CGPoint(x: a.x + 35, y: a.y), control2: CGPoint(x: b.x - 35, y: b.y))
                                context.stroke(line, with: .color(AppTheme.pine.opacity(0.45)), style: StrokeStyle(lineWidth: 2))
                                var arrow = Path(); arrow.move(to: CGPoint(x: b.x - 7, y: b.y - 4)); arrow.addLine(to: b); arrow.addLine(to: CGPoint(x: b.x - 7, y: b.y + 4)); context.stroke(arrow, with: .color(AppTheme.pine), lineWidth: 2)
                            } }
                        }.frame(width: size.width, height: size.height)
                        ForEach(related) { task in
                            Button { onOpen(task.id) } label: {
                                VStack(alignment: .leading, spacing: 8) { HStack { Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle"); if task.id == current { Text("当前任务").font(.caption2).bold() } }; Text(task.title).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading); Text(task.isDone ? "已完成" : "待完成").font(.caption2) }
                                    .frame(width: 160, height: 72, alignment: .leading).padding(12).background(task.id == current ? AppTheme.sage : AppTheme.surface, in: RoundedRectangle(cornerRadius: 15)).overlay { RoundedRectangle(cornerRadius: 15).stroke(task.id == current ? AppTheme.pine : AppTheme.line, lineWidth: task.id == current ? 2 : 1) }
                            }.buttonStyle(.plain).offset(x: positions[task.id]?.x ?? 0, y: positions[task.id]?.y ?? 0)
                        }
                    }.frame(width: size.width, height: size.height, alignment: .topLeading).scaleEffect(zoom, anchor: .topLeading).frame(width: max(geometry.size.width, size.width * zoom), height: max(geometry.size.height, size.height * zoom), alignment: .topLeading)
                }
            }
        }
    }
    private func positions(_ columns: [[ReminderItem]]) -> [UUID: CGPoint] {
        var result: [UUID: CGPoint] = [:]
        for (column, tasks) in columns.enumerated() { for (row, task) in tasks.enumerated() { result[task.id] = CGPoint(x: CGFloat(column) * 260 + 16, y: CGFloat(row) * 132 + 16) } }
        return result
    }
}

struct TaskRecycleView: View {
    @ObservedObject var store: ReminderStore
    @Environment(\.dismiss) private var dismiss
    @State private var permanent: ReminderItem?
    var body: some View {
        NavigationStack { List {
            Section { Text("任务在删除 30 天后自动清理。恢复保留任务身份与属性，原依赖关系不重连。").font(.caption) }
            ForEach(store.deleted) { task in VStack(alignment: .leading, spacing: 8) { Text(task.title); Text("删除于 \(task.deletedAt?.formatted() ?? "")").font(.caption); HStack { Button("恢复") { store.restore(task) }; Spacer(); Button("永久删除", role: .destructive) { permanent = task } }.buttonStyle(.bordered) } }
        }.navigationTitle("回收站").toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        .confirmationDialog("永久删除任务及其历史？此操作不可恢复。", isPresented: Binding(get: { permanent != nil }, set: { if !$0 { permanent = nil } }), titleVisibility: .visible) { Button("永久删除", role: .destructive) { if let permanent { store.permanentlyDelete(permanent) }; permanent = nil } }
        }
    }
}
