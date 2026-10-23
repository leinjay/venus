import SwiftUI

enum TaskRoute: Hashable {
    case detail(UUID), edit(UUID), new, restore(UUID, UUID)
    var isEditing: Bool { switch self { case .detail: return false; default: return true } }
}

struct RemindersView: View {
    @ObservedObject var store: ReminderStore
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [TaskRoute] = []
    @State private var query = ""
    @State private var keywords: String?
    @State private var explanation = ""
    @State private var status = 0
    @State private var priority = -1
    @State private var tagQuery = ""
    @State private var tagsMatchAny = false
    @State private var fromDate: Date?
    @State private var toDate: Date?
    @State private var filter = false
    @State private var recycle = false
    @State private var today = false
    @State private var manageAfterToday = false
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchID = UUID()
    @State private var searchError: String?
    @AppStorage("tasks.grid") private var grid = false
    @AppStorage("tasks.sort") private var sort = 0
    @AppStorage("tasks.sortExplicit") private var sortExplicit = false
    @AppStorage("tasks.hideNotificationTitle") private var hideTitle = false

    private var filtered: [ReminderItem] {
        let tags = tagQuery.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        let result = store.reminders.filter { task in
            guard status == 2 || task.isDone == (status == 1), priority < 0 || task.priority.rawValue == priority,
                  TaskRules.matches(task, query: keywords ?? query) else { return false }
            if let fromDate, task.schedule.trigger().map({ $0 >= Calendar.current.startOfDay(for: fromDate) }) != true { return false }
            if let toDate {
                let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: toDate))!
                if task.schedule.trigger().map({ $0 < end }) != true { return false }
            }
            if !tags.isEmpty {
                let values = task.tags.map { "\($0.key):\($0.value)".lowercased() }
                let matches = tags.map { tag in values.contains { $0 == tag } }
                if tagsMatchAny ? !matches.contains(true) : matches.contains(false) { return false }
            }
            return true
        }
        return result.sorted { a, b in
            if !(keywords ?? query).isEmpty && !sortExplicit {
                let left = TaskRules.relevance(a, query: keywords ?? query), right = TaskRules.relevance(b, query: keywords ?? query)
                if left != right { return left > right }
            }
            if sort == 1, a.addedAt != b.addedAt { return a.addedAt > b.addedAt }
            if sort == 2 { return TaskRules.importanceOrder(a, b) }
            return TaskRules.executionOrder(a, b)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    BrandHeader(eyebrow: "MAKE ROOM FOR WHAT MATTERS", title: "任务", subtitle: "琐事、计划和想做的事，都有一个位置。")
                    HStack {
                        Label("\(store.reminders.filter { !$0.isDone }.count) 项待办", systemImage: "circle.dotted")
                        Spacer()
                        Text("今天 \(TaskRules.today(store.reminders).count) 项").foregroundStyle(AppTheme.pine)
                    }.font(.subheadline).surfaceCard(padding: 14)
                    if !explanation.isEmpty { HStack(alignment: .top) { Image(systemName: "sparkles"); Text(explanation); Spacer(); Button("清除") { resetFilters() } }.font(.caption).surfaceCard(padding: 12) }
                    HStack {
                        Picker("完成状态", selection: $status) { Text("未完成").tag(0); Text("已完成").tag(1); Text("全部").tag(2) }.pickerStyle(.segmented)
                        Button { grid.toggle() } label: { Image(systemName: grid ? "list.bullet" : "square.grid.2x2") }.accessibilityLabel(grid ? "切换列表" : "切换卡片")
                    }
                    HStack {
                        Text("\(filtered.count) 项结果").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if searching { ProgressView() }
                        Button("智能查找") { intelligentSearch() }.font(.subheadline).disabled(searching || query.isEmpty)
                    }
                    DisclosureGroup("任务使用的模型") {
                        ModelBindingPanel(purpose: .dialogue)
                        ModelBindingPanel(purpose: .summary)
                        ModelBindingPanel(purpose: .search)
                    }.font(.subheadline).surfaceCard(padding: 14)
                    if filtered.isEmpty {
                        ContentUnavailableView(store.reminders.isEmpty ? "从一件小事开始" : "没有匹配任务", systemImage: "tray", description: Text(store.reminders.isEmpty ? "点击右上角添加任务，用对话或表单记录。" : "试试其他关键词或清除过滤条件。"))
                    } else {
                        LazyVGrid(columns: grid ? [GridItem(.flexible()), GridItem(.flexible())] : [GridItem(.flexible())], spacing: 12) {
                            ForEach(filtered) { task in TaskCard(task: task, blocked: store.unfinishedPrerequisites(task), compact: grid, onOpen: { path.append(.detail(task.id)) }, onToggle: { store.toggle(task) }) }
                        }
                    }
                    Text(store.notificationMessage).font(.caption).foregroundStyle(.secondary)
                    Text(store.syncMessage).font(.caption).foregroundStyle(.secondary)
                }.padding(20).padding(.bottom, 76)
            }
            .background(AppTheme.canvas.ignoresSafeArea())
            .navigationTitle("任务提醒").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "标题、内容、标签或自然语言")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { filter = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.accessibilityLabel("筛选与排序") }
                ToolbarItem(placement: .topBarTrailing) { Button { path.append(.new) } label: { Image(systemName: "plus") }.accessibilityLabel("新建任务") }
                ToolbarItem(placement: .topBarTrailing) { Menu {
                    Button("回收站（\(store.deleted.count)）") { recycle = true }
                    Button("重试通知与同步") { store.retryDelivery() }
                    Toggle("通知隐藏标题与内容", isOn: $hideTitle)
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("任务选项") }
            }
            .navigationDestination(for: TaskRoute.self) { route in
                switch route {
                case .detail(let id): TaskDetailView(store: store, taskID: id, onEdit: { path.append(.edit(id)) }, onOpen: { path.append(.detail($0)) }, onRestore: { path.append(.restore(id, $0)) })
                case .new: TaskEditorView(store: store, onSaved: { id in if !path.isEmpty { path.removeLast() }; path.append(.detail(id)) }, onClose: { if !path.isEmpty { path.removeLast() } })
                case .edit(let id):
                    if let item = store.item(id) { TaskEditorView(store: store, task: item, onSaved: { _ in if !path.isEmpty { path.removeLast() } }, onClose: { if !path.isEmpty { path.removeLast() } }) }
                    else { ContentUnavailableView("任务已不存在", systemImage: "trash") }
                case .restore(let id, let versionID):
                    if let item = store.item(id), let version = store.versions(id).first(where: { $0.id == versionID }) {
                        TaskEditorView(store: store, task: item, restoredVersion: version.task, onSaved: { _ in if !path.isEmpty { path.removeLast() } }, onClose: { if !path.isEmpty { path.removeLast() } })
                    }
                }
            }
        }
        .overlay { if path.last?.isEditing != true { TaskAssistantButton { today = true } } }
        .sheet(isPresented: $filter) { filterSheet }
        .sheet(isPresented: $recycle) { TaskRecycleView(store: store) }
        .sheet(isPresented: $today, onDismiss: {
            if manageAfterToday { manageAfterToday = false; navigation.openModels(onReturn: { today = true }) }
        }) {
            TaskTodayView(store: store, onManageModels: { manageAfterToday = true; today = false }) { id in today = false; path.append(.detail(id)) }
        }
        .onChange(of: query) { _, _ in searchTask?.cancel(); searchID = UUID(); searching = false; keywords = nil; explanation = "" }
        .onChange(of: hideTitle) { _, _ in store.refreshNotifications() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { store.refreshNotifications() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in store.refreshNotifications() }
        .onChange(of: store.notificationTaskID) { _, id in if let id { if store.item(id) != nil { path = [.detail(id)] } else { searchError = "该任务已删除或不存在" }; store.notificationTaskID = nil } }
        .alert("请检查", isPresented: Binding(get: { store.errorMessage != nil || searchError != nil }, set: { if !$0 { store.errorMessage = nil; searchError = nil } })) { Button("知道了") { store.errorMessage = nil; searchError = nil } } message: { Text(searchError ?? store.errorMessage ?? "") }
    }

    private var filterSheet: some View {
        NavigationStack { Form {
            Section("排序") {
                Picker("排序方式", selection: Binding(get: { sort }, set: { sort = $0; sortExplicit = true })) { Text("执行时间：早到晚").tag(0); Text("添加时间：新到旧").tag(1); Text("重要程度：高到低").tag(2) }
                if sortExplicit { Button("查找时优先相关性") { sortExplicit = false } }
            }
            Section("过滤") {
                Picker("重要程度", selection: $priority) { Text("全部").tag(-1); ForEach(TaskPriority.allCases) { Text($0.title).tag($0.rawValue) } }
                TextField("标签，例如 领域:生活,地点:家", text: $tagQuery)
                Toggle("多个标签匹配任意一个", isOn: $tagsMatchAny)
                Toggle("限定开始日期", isOn: Binding(get: { fromDate != nil }, set: { fromDate = $0 ? Date() : nil }))
                if fromDate != nil { DatePicker("从", selection: Binding(get: { fromDate ?? Date() }, set: { fromDate = $0 }), displayedComponents: .date) }
                Toggle("限定结束日期", isOn: Binding(get: { toDate != nil }, set: { toDate = $0 ? Date() : nil }))
                if toDate != nil { DatePicker("到", selection: Binding(get: { toDate ?? Date() }, set: { toDate = $0 }), displayedComponents: .date) }
            }
            Button("清除查找与过滤") { resetFilters() }
        }.navigationTitle("筛选与排序").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { filter = false } } } }
    }
    private func resetFilters() { query = ""; keywords = nil; explanation = ""; status = 0; priority = -1; tagQuery = ""; fromDate = nil; toDate = nil }
    private func intelligentSearch() {
        searchTask?.cancel(); searchID = UUID(); let token = searchID, input = query
        guard input.count <= 2000 else { searchError = "查找条件最多 2,000 字"; return }
        searching = true
        searchTask = Task {
            do {
                let output = try await ConfiguredModelService.shared.respond(purpose: .search, system: "解析任务查询，不执行操作。只输出JSON：{\"keywords\":\"主题关键词，可为空\",\"status\":0未完成或1已完成或2全部,\"priority\":-1全部或0未指定或1低或2中或3高,\"from\":\"yyyy-MM-dd或空\",\"to\":\"yyyy-MM-dd或空\",\"tags\":\"key:value，以英文逗号分隔，可空\",\"explanation\":\"简短说明查询条件\"}。相对日期依据当前日历日和时区；只解析条件，不要生成任务。", prompt: "今天：\(TaskSchedule.dayString(Date()))，时区：\(TimeZone.current.identifier)\n查询：\(input)")
                let object = try TaskAI.parseObject(output)
                guard token == searchID, !Task.isCancelled else { return }
                guard let terms = object["keywords"] as? String, let state = object["status"] as? Int, (0...2).contains(state), let importance = object["priority"] as? Int, (-1...3).contains(importance) else { throw TaskFailure("查找条件格式不正确，请重试") }
                func date(_ key: String) throws -> Date? {
                    guard let value = object[key] as? String, !value.isEmpty else { return nil }
                    let schedule = TaskSchedule(mode: .day, day: value)
                    guard let date = schedule.trigger() else { throw TaskFailure("查找日期不正确") }; return date
                }
                let start = try date("from"), end = try date("to")
                guard start == nil || end == nil || start! <= end! else { throw TaskFailure("开始日期晚于结束日期") }
                keywords = terms; status = state; priority = importance; tagQuery = object["tags"] as? String ?? ""
                fromDate = start; toDate = end; explanation = object["explanation"] as? String ?? "已应用智能查找条件"; searching = false
            } catch { guard token == searchID else { return }; searching = false; if !(error is CancellationError) { searchError = error.localizedDescription } }
        }
    }
}

struct TaskCard: View {
    let task: ReminderItem
    let blocked: Int
    var compact = false
    var onOpen: () -> Void
    var onToggle: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) { Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(task.isDone ? AppTheme.pine : AppTheme.amber).padding(.vertical, 3) }.buttonStyle(.plain).accessibilityLabel(task.isDone ? "恢复未完成" : "标记完成")
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(AppTheme.ink).multilineTextAlignment(.leading).strikethrough(task.isDone).lineLimit(compact ? 4 : 2)
                    if !task.summary.isEmpty { Text(task.summary).font(.caption).foregroundStyle(AppTheme.secondary).lineLimit(2) }
                    Text(task.schedule.label).font(.caption).foregroundStyle(AppTheme.secondary)
                    HStack { if task.priority != .unspecified { AccentLabel(title: task.priority.title, color: task.priority == .high ? AppTheme.terracotta : AppTheme.pine) }; if blocked > 0 { Label("\(blocked)", systemImage: "link").font(.caption).foregroundStyle(AppTheme.amber) } }
                    if !task.tags.isEmpty { Text(task.tags.prefix(3).map { "\($0.key):\($0.value)" }.joined(separator: " · ")).font(.caption2).foregroundStyle(AppTheme.secondary).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.frame(maxWidth: .infinity, alignment: .leading).surfaceCard(padding: compact ? 12 : 16)
    }
}

struct TaskAssistantButton: View {
    var action: () -> Void
    @AppStorage("tasks.assistantRight") private var right = true
    @AppStorage("tasks.assistantHeight") private var height = 0.86
    @GestureState private var translation = CGSize.zero
    var body: some View {
        GeometryReader { geometry in
            let x: CGFloat = right ? max(34, geometry.size.width - 38) : 38
            let y = max(38, min(geometry.size.height - 38, geometry.size.height * height))
            Button(action: action) { Image(systemName: "sparkles").font(.title2).foregroundStyle(.white).frame(width: 56, height: 56).background(AppTheme.pine, in: Circle()).shadow(color: AppTheme.pine.opacity(0.22), radius: 10, y: 5) }
                .accessibilityLabel("打开今日任务总结").accessibilityHint("可拖动调整位置")
                .position(x: x + translation.width, y: y + translation.height)
                .simultaneousGesture(DragGesture(minimumDistance: 12).updating($translation) { value, state, _ in state = value.translation }.onEnded { value in
                    right = x + value.translation.width > geometry.size.width / 2
                    height = Double(max(38, min(geometry.size.height - 38, y + value.translation.height)) / max(1, geometry.size.height))
                })
        }.allowsHitTesting(true)
    }
}
