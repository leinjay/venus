import SwiftUI

@MainActor
final class TaskOverviewSummary: ObservableObject {
    @Published var text = ""
    @Published var generating = false
    @Published var replayID = UUID()
    @Published var source = "准备生成"
    @Published var failureReason: String?

    func refresh(_ overview: TaskDailyOverview) async {
        let token = UUID()
        replayID = token
        generating = true
        source = "生成中"
        failureReason = nil
        text = overview.compactCounts
        defer { if replayID == token { generating = false } }
        do {
            let output = try await ConfiguredModelService.shared.respond(
                purpose: .summary,
                system: TaskCompanionTone.instructions + "\n这是列表上的极简概览，不添加称呼或开场问候。只归纳给出的任务，返回 JSON：{\"message\":\"一句不超过18字的今日安排建议\"}。不重复数量，不增加任务，不输出推理或额外字段。message放在最前。",
                prompt: overview.context,
                onProgress: { [weak self] partial in
                    guard let self, self.replayID == token, self.generating else { return }
                    let message = ModelReplyPreview.summaryText(in: partial)
                    self.text = overview.compactCounts + (message.isEmpty ? "" : "\n" + String(message.prefix(18)))
                }
            )
            try Task.checkCancellation()
            guard replayID == token else { return }
            let message = try ModelReplyPreview.finishedSummary(in: output)
            text = overview.compactCounts + "\n" + String(message.prefix(18))
            source = "AI"
        } catch {
            guard !Task.isCancelled, replayID == token else { return }
            text = overview.compactCounts + "\n" + overview.fallbackAdvice
            source = "固定摘要"
            failureReason = error.localizedDescription
        }
    }

    func cancel() { replayID = UUID(); generating = false }
}

struct TaskTodayView: View {
    @ObservedObject var store: ReminderStore
    @ObservedObject private var registry = ModelRegistry.shared
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()
    @State private var messages: [TaskMessage] = []
    @State private var input = ""
    @State private var generating = false
    @State private var request: Task<Void, Never>?
    @State private var token = UUID()
    @State private var fallback = false
    @State private var source = "正在连接 AI"
    @State private var failureReason: String?
    @State private var failedQuestion: String?
    @State private var modelExpanded = false
    @State private var followReply = true
    @FocusState private var focused: Bool
    var onManageModels: (() -> Void)? = nil
    var onOpen: (UUID) -> Void
    private var overview: TaskDailyOverview {
        TaskDailyOverview(tasks: store.reminders, history: store.database.executionHistory, now: now)
    }
    private var unplanned: [ReminderItem] { store.reminders.filter { !$0.isDone && $0.schedule.mode == .unplanned } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(overview.headline).font(.subheadline.weight(.medium)).foregroundStyle(AppTheme.pine)
                            Text(source).font(.caption).foregroundStyle(AppTheme.secondary)
                            ForEach(messages) { message in
                                HStack(alignment: .top, spacing: 8) {
                                    if message.isUser { Spacer(minLength: 32) }
                                    else { Image(systemName: "sparkles").foregroundStyle(AppTheme.pine).padding(.top, 14) }
                                    Group {
                                        if message.isUser { Text(message.text) }
                                        else {
                                            VStack(alignment: .leading, spacing: 4) {
                                                AIReplyText(text: message.text, generating: message.state == .receiving)
                                                if message.state == .stopped { Text("已停止").font(.caption).foregroundStyle(AppTheme.secondary) }
                                                if message.state == .failed { Text("未获得 AI 回答").font(.caption).foregroundStyle(AppTheme.terracotta) }
                                            }
                                        }
                                    }
                                    .font(.subheadline).frame(maxWidth: message.isUser ? nil : .infinity, alignment: .leading)
                                    .padding(14).background(message.isUser ? AppTheme.sage : AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                                    if !message.isUser { Spacer(minLength: 8) }
                                }.id(message.id)
                            }
                            if fallback { Text("已使用本机固定摘要，任务统计来自真实记录。").font(.caption2).foregroundStyle(AppTheme.secondary) }
                            if let failureReason {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(failureReason).font(.caption).foregroundStyle(AppTheme.secondary).textSelection(.enabled)
                                    HStack {
                                        Button("重试") { generate(question: failedQuestion ?? "", appendUserMessage: false) }
                                        Spacer()
                                        Button("检查模型") { withAnimation { modelExpanded = true; proxy.scrollTo("summary-model", anchor: .center) } }
                                    }.font(.caption.weight(.medium)).disabled(generating)
                                }.surfaceCard(padding: 14)
                            }
                            DisclosureGroup("查看完整任务清单") {
                                VStack(alignment: .leading, spacing: 14) {
                                    taskGroup("今日待办", tasks: overview.pending)
                                    taskGroup("逾期", tasks: overview.overdue)
                                    taskGroup("今天已完成", tasks: overview.completed)
                                    taskGroup("未安排", tasks: unplanned)
                                }.padding(.top, 12)
                            }.font(.subheadline).surfaceCard(padding: 14)
                            DisclosureGroup("今日总结模型", isExpanded: $modelExpanded) {
                                Text("今日概览和这里的问答使用此模型，与任务编辑的对话模型分别设置。更改后点击重试或刷新。")
                                    .font(.caption).foregroundStyle(AppTheme.secondary).padding(.vertical, 8)
                                ModelBindingPanel(purpose: .summary, onManage: onManageModels)
                            }
                                .font(.subheadline).surfaceCard(padding: 14)
                                .id("summary-model")
                            Color.clear.frame(height: 1).id("summary-bottom")
                        }.padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(DragGesture().onChanged { _ in followReply = false })
                    .onChange(of: messages.last?.text) { _, _ in
                        if followReply, let id = messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                    .onChange(of: messages.count) { _, _ in withAnimation { if let id = messages.last?.id { proxy.scrollTo(id, anchor: .top) } } }
                }
                HStack(spacing: 12) {
                    TextField("问问今天的安排…", text: $input, axis: .vertical).lineLimit(1...3).focused($focused)
                    Button {
                        if generating { cancel() } else { generate(question: input) }
                    } label: {
                        Image(systemName: generating ? "stop.fill" : "arrow.up")
                            .foregroundStyle(.white).frame(width: 40, height: 40).background(AppTheme.pine, in: Circle())
                    }.accessibilityLabel(generating ? "停止回复" : "发送")
                        .disabled(!generating && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(12).background(AppTheme.surface)
            }
            .background(AppTheme.canvas.ignoresSafeArea())
            .navigationTitle("今日任务概览").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("刷新") { generate() }.disabled(generating) }
                ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } }
            }
        }
        .task { generate() }
        .onChange(of: store.revision) { _, _ in generate() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { date in
            let changed = TaskSchedule.dayString(now) != TaskSchedule.dayString(date)
            now = date
            if changed { generate() }
        }
        .onDisappear { cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in cancel() }
    }

    @ViewBuilder private func taskGroup(_ title: String, tasks: [ReminderItem]) -> some View {
        if !tasks.isEmpty {
            Text("\(title) · \(tasks.count) 项").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.secondary)
            ForEach(tasks) { task in
                Button { onOpen(task.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title).foregroundStyle(AppTheme.ink)
                        Text(task.schedule.label).font(.caption).foregroundStyle(AppTheme.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }
    }

    private func cancel() {
        if generating { source = "回复已停止" }
        token = UUID(); request?.cancel(); request = nil; generating = false
        for index in messages.indices where messages[index].state == .receiving { messages[index].state = .stopped }
    }

    private func generate(question: String = "", appendUserMessage: Bool = true) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.count <= 2000 else { return }
        cancel(); now = Date(); fallback = false; focused = false; followReply = true
        failureReason = nil; failedQuestion = nil; source = "正在连接 AI"
        let snapshot = overview, current = token, revision = store.revision
        let shouldGreet = !messages.contains { !$0.isUser && !$0.text.isEmpty }
        let context = messages.filter { $0.state == .complete }.suffix(6).map { ($0.isUser ? "用户：" : "助手：") + String($0.text.prefix(800)) }.joined(separator: "\n")
        if !question.isEmpty && appendUserMessage { messages.append(TaskMessage(isUser: true, text: question, state: .complete)) }
        if !question.isEmpty && input.trimmingCharacters(in: .whitespacesAndNewlines) == question { input = "" }
        let assistant = TaskMessage(isUser: false, text: TaskCompanionTone.present("", includeGreeting: shouldGreet), state: .receiving)
        messages.append(assistant); generating = true
        request = Task {
            do {
                let output = try await ConfiguredModelService.shared.respond(
                    purpose: .summary,
                    system: TaskOverviewReply.instructions,
                    prompt: snapshot.context + "\n最近对话（仅用于理解问题）：\n" + context + "\n用户问题：" + (question.isEmpty ? "分析今天的任务情况，简短说明先做什么。" : question),
                    onProgress: { partial in
                        guard current == token, generating, revision == store.revision,
                              let index = messages.firstIndex(where: { $0.id == assistant.id }) else { return }
                        messages[index].text = TaskCompanionTone.present(ModelReplyPreview.summaryText(in: partial), includeGreeting: shouldGreet)
                    }
                )
                try Task.checkCancellation()
                let message = try ModelReplyPreview.finishedSummary(in: output)
                guard current == token, revision == store.revision,
                      let index = messages.firstIndex(where: { $0.id == assistant.id }) else { return }
                messages[index].text = TaskCompanionTone.present(String(message.prefix(1900)), includeGreeting: shouldGreet); messages[index].state = .complete; generating = false
                source = "AI · \(registry.selected(.summary)?.name ?? "今日总结模型")"
            } catch {
                guard !Task.isCancelled, current == token, revision == store.revision,
                      let index = messages.firstIndex(where: { $0.id == assistant.id }) else { return }
                failureReason = error.localizedDescription
                let localReply = TaskOverviewReply.failure(question: question, reason: error.localizedDescription, overview: snapshot)
                messages[index].text = TaskCompanionTone.present(localReply + (question.isEmpty && shouldGreet ? "\n\n能做多少就做多少，累了也可以先休息，我陪你慢慢理顺。" : ""), includeGreeting: shouldGreet)
                messages[index].state = question.isEmpty ? .complete : .failed
                generating = false; fallback = question.isEmpty
                source = question.isEmpty ? "固定摘要 · AI 暂不可用" : "AI 调用失败"
                if !question.isEmpty {
                    failedQuestion = question
                    if input.isEmpty { input = question }
                }
            }
        }
    }
}
