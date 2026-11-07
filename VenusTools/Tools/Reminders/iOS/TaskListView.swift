import SwiftUI
import UIKit

enum TaskRoute: Hashable {
    case detail(UUID), new, restore(UUID, UUID), models
    var isEditing: Bool { switch self { case .detail, .models: return false; default: return true } }
}

struct RemindersView: View {
    @ObservedObject var store: ReminderStore
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [TaskRoute] = []
    @State private var detailEditing = false
    @State private var revealedTaskID: UUID?
    @State private var taskToDelete: ReminderItem?
    @State private var query = ""
    @State private var keywords: String?
    @State private var explanation = ""
    @State private var now = Date()
    @State private var status = 0
    @State private var priority = -1
    @State private var tagQuery = ""
    @State private var tagsMatchAny = false
    @State private var fromDate: Date?
    @State private var toDate: Date?
    @State private var showFilters = false
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
            let matchesStatus = status == 3 ? TaskRules.isOverdue(task, now: now) : status == 2 || task.isDone == (status == 1)
            guard matchesStatus, priority < 0 || task.priority.rawValue == priority,
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
                    if !explanation.isEmpty { HStack(alignment: .top) { Image(systemName: "sparkles"); Text(explanation); Spacer(); Button("清除") { resetFilters() } }.font(.caption).surfaceCard(padding: 12) }
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondary)
                        TextField("标题、内容、标签或自然语言", text: $query)
                            .submitLabel(.search)
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清除搜索") }
                    }.padding(12).background(AppTheme.line.opacity(0.65), in: Capsule())
                    HStack {
                        Picker("完成状态", selection: $status) { Text("逾期").tag(3); Text("未完成").tag(0); Text("已完成").tag(1); Text("全部").tag(2) }.pickerStyle(.segmented)
                        Button { grid.toggle() } label: { Image(systemName: grid ? "list.bullet" : "square.grid.2x2") }.accessibilityLabel(grid ? "切换列表" : "切换卡片")
                    }
                    filterBar
                    HStack {
                        Text("\(filtered.count) 项结果").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if searching { ProgressView() }
                        Button("智能查找") { intelligentSearch() }.font(.subheadline).disabled(searching || query.isEmpty)
                    }
                    if filtered.isEmpty {
                        ContentUnavailableView(store.reminders.isEmpty ? "从一件小事开始" : "没有匹配任务", systemImage: "tray", description: Text(store.reminders.isEmpty ? "点击右上角添加任务，用对话或表单记录。" : "试试其他关键词或清除过滤条件。"))
                    } else {
                        LazyVGrid(columns: grid ? [GridItem(.flexible()), GridItem(.flexible())] : [GridItem(.flexible())], spacing: 12) {
                            ForEach(filtered) { task in
                                TaskCard(
                                    task: task, blocked: store.unfinishedPrerequisites(task), now: now, compact: grid,
                                    revealedTaskID: $revealedTaskID,
                                    onOpen: { path.append(.detail(task.id)) },
                                    onToggle: { store.toggle(task) },
                                    onDelete: { taskToDelete = task }
                                )
                            }
                        }
                    }
                    Text(store.notificationMessage).font(.caption).foregroundStyle(.secondary)
                    Text(store.syncMessage).font(.caption).foregroundStyle(.secondary)
                }.padding(20).padding(.bottom, 76)
            }
            .background(AppTheme.canvas.ignoresSafeArea())
            .navigationTitle("任务提醒").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { path.append(.new) } label: { Image(systemName: "plus") }.accessibilityLabel("新建任务") }
                ToolbarItem(placement: .topBarTrailing) { Menu {
                    NavigationLink(value: TaskRoute.models) {
                        Label("任务使用的模型", systemImage: "cpu")
                    }
                    Button("回收站（\(store.deleted.count)）") { recycle = true }
                    Button("重试通知与同步") { store.retryDelivery() }
                    Toggle("通知隐藏标题与内容", isOn: $hideTitle)
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("任务选项") }
            }
            .navigationDestination(for: TaskRoute.self) { route in
                switch route {
                case .models:
                    List {
                        Section { ModelBindingPanel(purpose: .dialogue) }
                        Section { ModelBindingPanel(purpose: .summary) }
                        Section { ModelBindingPanel(purpose: .search) }
                    }.navigationTitle("任务使用的模型")
                        .navigationBarTitleDisplayMode(.inline)
                case .detail(let id): TaskDetailView(store: store, taskID: id, onEditingChanged: { detailEditing = $0 }, onOpen: { path.append(.detail($0)) }, onRestore: { path.append(.restore(id, $0)) })
                case .new: TaskEditorView(store: store, onSaved: { id in if !path.isEmpty { path.removeLast() }; path.append(.detail(id)) }, onClose: { if !path.isEmpty { path.removeLast() } })
                case .restore(let id, let versionID):
                    if let item = store.item(id), let version = store.versions(id).first(where: { $0.id == versionID }) {
                        TaskEditorView(store: store, task: item, restoredVersion: version.task, onSaved: { _ in if !path.isEmpty { path.removeLast() } }, onClose: { if !path.isEmpty { path.removeLast() } })
                    }
                }
            }
        }
        .overlay { if path.last?.isEditing != true && !detailEditing { TaskAssistantButton { today = true } } }
        .sheet(isPresented: $showFilters) { filterSheet }
        .sheet(isPresented: $recycle) { TaskRecycleView(store: store) }
        .sheet(isPresented: $today, onDismiss: {
            if manageAfterToday { manageAfterToday = false; navigation.openModels(onReturn: { today = true }) }
        }) {
            TaskTodayView(store: store, onManageModels: { manageAfterToday = true; today = false }) { id in today = false; path.append(.detail(id)) }
        }
        .onChange(of: query) { _, _ in searchTask?.cancel(); searchID = UUID(); searching = false; keywords = nil; explanation = "" }
        .onChange(of: hideTitle) { _, _ in store.refreshNotifications() }
        .onAppear { now = Date() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .onChange(of: scenePhase) { _, phase in if phase == .active { now = Date(); store.refreshNotifications() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in store.refreshNotifications() }
        .onChange(of: store.notificationTaskID) { _, id in if let id { if store.item(id) != nil { path = [.detail(id)] } else { searchError = "该任务已删除或不存在" }; store.notificationTaskID = nil } }
        .confirmationDialog("移到回收站？", isPresented: Binding(
            get: { taskToDelete != nil },
            set: { if !$0 { taskToDelete = nil } }
        ), titleVisibility: .visible, presenting: taskToDelete) { task in
            Button("删除", role: .destructive) { store.remove(task) }
        } message: { task in
            Text("30 天内可恢复。\(store.reminders.filter { $0.prerequisiteIDs.contains(task.id) }.count) 项后续任务会解除此依赖。")
        }
        .alert("请检查", isPresented: Binding(get: { store.errorMessage != nil || searchError != nil }, set: { if !$0 { store.errorMessage = nil; searchError = nil } })) { Button("知道了") { store.errorMessage = nil; searchError = nil } } message: { Text(searchError ?? store.errorMessage ?? "") }
    }

    private func filterLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }.frame(maxWidth: .infinity, minHeight: 44)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("排序方式", selection: Binding(get: { sort }, set: { sort = $0; sortExplicit = true })) {
                    Text("执行时间：早到晚").tag(0)
                    Text("添加时间：新到旧").tag(1)
                    Text("重要程度：高到低").tag(2)
                }
                if sortExplicit { Button("查找时优先相关性") { sortExplicit = false } }
            } label: {
                filterLabel(sort == 1 ? "添加时间" : sort == 2 ? "重要排序" : "执行时间")
            }.accessibilityLabel("排序方式")
            Menu {
                Picker("重要程度", selection: $priority) {
                    Text("全部重要程度").tag(-1)
                    ForEach(TaskPriority.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } label: {
                filterLabel(TaskPriority(rawValue: priority).map { "\($0.title)优先级" } ?? "重要程度")
            }.accessibilityLabel("重要程度筛选")
            Button { showFilters = true } label: { filterLabel("筛选") }
                .foregroundStyle(!tagQuery.isEmpty || fromDate != nil || toDate != nil ? AppTheme.pine : AppTheme.ink)
                .accessibilityLabel("更多筛选")
            Button("重置") {
                resetFilters()
                sort = 0
                sortExplicit = false
            }.foregroundStyle(AppTheme.pine).frame(minWidth: 44, minHeight: 44)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(AppTheme.ink)
        .buttonStyle(.plain)
    }

    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section("标签") {
                    TextField("例如 领域:生活,地点:家", text: $tagQuery)
                    Toggle("多个标签匹配任意一个", isOn: $tagsMatchAny)
                }
                Section("执行日期") {
                    Toggle("限定开始日期", isOn: Binding(get: { fromDate != nil }, set: { fromDate = $0 ? Date() : nil }))
                    if fromDate != nil { DatePicker("从", selection: Binding(get: { fromDate ?? Date() }, set: { fromDate = $0 }), displayedComponents: .date) }
                    Toggle("限定结束日期", isOn: Binding(get: { toDate != nil }, set: { toDate = $0 ? Date() : nil }))
                    if toDate != nil { DatePicker("到", selection: Binding(get: { toDate ?? Date() }, set: { toDate = $0 }), displayedComponents: .date) }
                }
            }
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showFilters = false } } }
        }
    }

    private func resetFilters() { query = ""; keywords = nil; explanation = ""; status = 0; priority = -1; tagQuery = ""; fromDate = nil; toDate = nil; tagsMatchAny = false }
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
    let now: Date
    let compact: Bool
    @Binding var revealedTaskID: UUID?
    var onOpen: () -> Void
    var onToggle: () -> Void
    var onDelete: () -> Void
    @State private var dragOffset: CGFloat = 0

    private var isRevealed: Bool { revealedTaskID == task.id }
    private var actionWidth: CGFloat { compact ? 56 : 76 }
    private var revealWidth: CGFloat { actionWidth * 2 }
    private var toggleTitle: String { task.isDone ? "标为未完成" : "标为已完成" }
    private var isOverdue: Bool { TaskRules.isOverdue(task, now: now) }

    private var executionDate: Date? {
        if task.schedule.recurrence == .once { return task.completedAt ?? task.schedule.trigger() }
        guard !task.isDone else { return nil }
        return task.schedule.nextOccurrence(after: now)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private var executionTimeInfo: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.schedule.recurrence == .once ? "上次执行时间" : "下次执行时间")
            Text(executionDate.map(formattedDate) ?? (task.isDone ? "已完成" : "未安排时间"))
                .lineLimit(1).minimumScaleFactor(0.75)
        }.accessibilityElement(children: .combine)
    }

    private var creationTimeInfo: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("创建时间")
            Text(formattedDate(task.addedAt)).lineLimit(1).minimumScaleFactor(0.75)
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusBadges: some View {
        AccentLabel(title: task.schedule.recurrenceLabel, color: AppTheme.pine)
        if isOverdue { AccentLabel(title: "逾期", color: .red) }
        AccentLabel(title: task.isDone ? "已完成" : "未完成", color: task.isDone ? AppTheme.pine : AppTheme.amber)
        if task.priority != .unspecified {
            AccentLabel(title: task.priority.title, color: task.priority == .high ? AppTheme.terracotta : AppTheme.pine)
        }
    }

    private var allBadges: some View {
        HStack(spacing: 4) {
            statusBadges
            ForEach(Array(task.tags.enumerated()), id: \.offset) { _, tag in
                AccentLabel(title: "\(tag.key):\(tag.value)", color: AppTheme.pine)
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var badgeLine: some View {
        ViewThatFits(in: .horizontal) {
            allBadges
            HStack(spacing: 4) {
                statusBadges
                if !task.tags.isEmpty { AccentLabel(title: "+\(task.tags.count)", color: AppTheme.pine) }
            }.fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 4) {
                AccentLabel(title: task.schedule.recurrenceLabel, color: AppTheme.pine)
                let count = 1 + (isOverdue ? 1 : 0) + (task.priority == .unspecified ? 0 : 1) + task.tags.count
                AccentLabel(title: "+\(count)", color: AppTheme.secondary)
            }.lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ([task.schedule.recurrenceLabel]
             + (isOverdue ? ["逾期"] : [])
             + [task.isDone ? "已完成" : "未完成"]
             + (task.priority == .unspecified ? [] : [task.priority.title])
             + task.tags.map { "\($0.key):\($0.value)" }).joined(separator: "，")
        )
    }

    private var title: some View {
        HStack(alignment: .top, spacing: 6) {
            if task.isDone {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.pine).accessibilityHidden(true)
            }
            Text(task.title).foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.leading).strikethrough(task.isDone).lineLimit(compact ? 4 : 2)
        }.font(.headline)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    title.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    allBadges
                }
                VStack(alignment: .leading, spacing: 6) {
                    title.frame(maxWidth: .infinity, alignment: .leading)
                    badgeLine
                }
            }
            if !task.summary.isEmpty {
                Text(task.summary).font(.caption).foregroundStyle(AppTheme.secondary).lineLimit(2)
            }
            Group {
                if compact {
                    VStack(alignment: .leading, spacing: 8) {
                        executionTimeInfo
                        creationTimeInfo.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    HStack(alignment: .bottom, spacing: 8) {
                        executionTimeInfo
                        Spacer(minLength: 0)
                        creationTimeInfo
                    }
                }
            }.font(.caption2).foregroundStyle(AppTheme.secondary)
            if blocked > 0 {
                Label("\(blocked)", systemImage: "link").font(.caption).foregroundStyle(AppTheme.amber)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(padding: compact ? 12 : 16)
        .contentShape(Rectangle())
    }

    private func reveal(_ id: UUID?) {
        withAnimation(.easeOut(duration: 0.2)) { revealedTaskID = id }
    }

    private func tapCard() {
        if revealedTaskID != nil { reveal(nil) } else { onOpen() }
    }

    private func finishSwipe(_ translation: CGFloat?) {
        withAnimation(.easeOut(duration: 0.2)) {
            if let translation {
                if translation <= -24 { revealedTaskID = task.id }
                if translation >= 24, isRevealed { revealedTaskID = nil }
            }
            dragOffset = 0
        }
    }

    private func actionButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button {
            reveal(nil)
            action()
        } label: {
            Text(title).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .frame(width: actionWidth).frame(maxHeight: .infinity)
                .foregroundStyle(.white).background(color)
        }.buttonStyle(.plain)
    }

    var body: some View {
        let offset = min(0, max(-revealWidth, (isRevealed ? -revealWidth : 0) + dragOffset))
        cardContent
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tapCard() }
        .accessibilityAction(named: Text(toggleTitle)) { reveal(nil); onToggle() }
        .accessibilityAction(named: Text("删除")) { reveal(nil); onDelete() }
        .offset(x: offset)
        .background(alignment: .trailing) {
            HStack(spacing: 0) {
                actionButton(toggleTitle, color: AppTheme.pine, action: onToggle)
                actionButton("删除", color: .red, action: onDelete)
            }
            .allowsHitTesting(isRevealed)
            .accessibilityHidden(!isRevealed)
        }
        .overlay {
            TaskCardTouchSurface(
                isRevealed: isRevealed,
                onTap: tapCard,
                onSwipeChanged: { dragOffset = $0 },
                onSwipeFinished: finishSwipe
            )
            .padding(.trailing, -offset)
            .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onDisappear {
            if isRevealed { revealedTaskID = nil }
        }
    }
}

private struct TaskCardTouchSurface: UIViewRepresentable {
    var isRevealed: Bool
    var onTap: () -> Void
    var onSwipeChanged: (CGFloat) -> Void
    var onSwipeFinished: (CGFloat?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(surface: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let coordinator = context.coordinator
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = coordinator
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped))
        tap.delegate = coordinator
        tap.require(toFail: pan)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.surface = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var surface: TaskCardTouchSurface

        init(surface: TaskCardTouchSurface) { self.surface = surface }

        @objc func tapped() { surface.onTap() }

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view?.window).x
            switch recognizer.state {
            case .began, .changed: surface.onSwipeChanged(translation)
            case .ended: surface.onSwipeFinished(translation)
            case .cancelled, .failed: surface.onSwipeFinished(nil)
            default: break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let movement = pan.translation(in: pan.view?.window)
            return abs(movement.x) > abs(movement.y) && (movement.x < 0 || surface.isRevealed)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // Give the card pan first refusal. A vertical drag fails its direction check and goes to the scroll view.
            gestureRecognizer is UIPanGestureRecognizer && isEnclosingScrollPan(other, for: gestureRecognizer)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            gestureRecognizer is UITapGestureRecognizer && isEnclosingScrollPan(other, for: gestureRecognizer)
        }

        private func isEnclosingScrollPan(_ other: UIGestureRecognizer, for gesture: UIGestureRecognizer) -> Bool {
            guard let scroll = other.view as? UIScrollView else { return false }
            return other === scroll.panGestureRecognizer && gesture.view?.isDescendant(of: scroll) == true
        }
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
