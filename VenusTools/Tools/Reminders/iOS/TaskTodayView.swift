import SwiftUI

@MainActor
final class TaskOverviewSummary: ObservableObject {
    @Published var text = ""
    @Published var generating = false
    @Published var replayID = UUID()

    func refresh(_ overview: TaskDailyOverview) async {
        let token = UUID()
        replayID = token
        generating = true
        text = overview.compactCounts
        defer { if replayID == token { generating = false } }
        do {
            let output = try await ConfiguredModelService.shared.respond(
                purpose: .summary,
                system: "只归纳给出的任务，返回 JSON：{\"message\":\"一句不超过18字的今日安排建议\"}。不重复数量，不增加任务，不输出推理或额外字段。message放在最前。",
                prompt: overview.context,
                onProgress: { [weak self] partial in
                    guard let self, self.replayID == token, self.generating else { return }
                    let message = ModelReplyPreview.message(in: partial)
                    self.text = overview.compactCounts + (message.isEmpty ? "" : "\n" + String(message.prefix(18)))
                }
            )
            try Task.checkCancellation()
            guard replayID == token else { return }
            let object = try TaskAI.parseObject(output)
            guard let message = object["message"] as? String, !message.isEmpty, message.count <= 30 else { throw TaskFailure("摘要格式无效") }
            text = overview.compactCounts + "\n" + String(message.prefix(18))
        } catch {
            guard !Task.isCancelled, replayID == token else { return }
            text = overview.compactCounts + "\n" + overview.fallbackAdvice
        }
    }

    func cancel() { replayID = UUID(); generating = false }
}

struct TaskTodayView: View {
    @ObservedObject var store: ReminderStore
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()
    @State private var messages: [TaskMessage] = []
    @State private var input = ""
    @State private var generating = false
    @State private var request: Task<Void, Never>?
    @State private var token = UUID()
    @State private var fallback = false
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
                                            }
                                        }
                                    }
                                    .font(.subheadline).frame(maxWidth: message.isUser ? nil : .infinity, alignment: .leading)
                                    .padding(14).background(message.isUser ? AppTheme.sage : AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                                    if !message.isUser { Spacer(minLength: 8) }
                                }.id(message.id)
                            }
                            if fallback { Text("已使用本机固定摘要，任务统计来自真实记录。").font(.caption2).foregroundStyle(AppTheme.secondary) }
                            DisclosureGroup("查看完整任务清单") {
                                VStack(alignment: .leading, spacing: 14) {
                                    taskGroup("今日待办", tasks: overview.pending)
                                    taskGroup("逾期", tasks: overview.overdue)
                                    taskGroup("今天已完成", tasks: overview.completed)
                                    taskGroup("未安排", tasks: unplanned)
                                }.padding(.top, 12)
                            }.font(.subheadline).surfaceCard(padding: 14)
                            DisclosureGroup("总结使用的模型") { ModelBindingPanel(purpose: .summary, onManage: onManageModels) }
                                .font(.subheadline).surfaceCard(padding: 14)
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
        token = UUID(); request?.cancel(); request = nil; generating = false
        for index in messages.indices where messages[index].state == .receiving { messages[index].state = .stopped }
    }

    private func generate(question: String = "") {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.count <= 2000 else { return }
        cancel(); now = Date(); fallback = false; focused = false; followReply = true
        let snapshot = overview, current = token, revision = store.revision
        let context = messages.suffix(6).map { ($0.isUser ? "用户：" : "助手：") + String($0.text.prefix(800)) }.joined(separator: "\n")
        if !question.isEmpty { messages.append(TaskMessage(isUser: true, text: question, state: .complete)) }
        if !question.isEmpty { input = "" }
        let assistant = TaskMessage(isUser: false, text: "", state: .receiving)
        messages.append(assistant); generating = true
        request = Task {
            do {
                let output = try await ConfiguredModelService.shared.respond(
                    purpose: .summary,
                    system: "只分析给出的真实任务，不新建、不修改、不虚构任务。不重新计算数量，顶部统计为准。只返回JSON：{\"message\":\"简洁的今日任务分析或对用户的回答，不超过600字\"}。message先输出；保留任务原名，不输出推理。仅参考前30项时说明范围。",
                    prompt: snapshot.context + "\n最近对话（仅用于理解问题）：\n" + context + "\n用户问题：" + (question.isEmpty ? "分析今天的任务情况，简短说明先做什么。" : question),
                    onProgress: { partial in
                        guard current == token, generating, revision == store.revision,
                              let index = messages.firstIndex(where: { $0.id == assistant.id }) else { return }
                        messages[index].text = ModelReplyPreview.message(in: partial)
                    }
                )
                try Task.checkCancellation()
                let object = try TaskAI.parseObject(output)
                guard let message = object["message"] as? String, !message.isEmpty else { throw TaskFailure("总结格式不正确") }
                guard current == token, revision == store.revision,
                      let index = messages.firstIndex(where: { $0.id == assistant.id }) else { return }
                messages[index].text = String(message.prefix(2000)); messages[index].state = .complete; generating = false
            } catch {
                guard !Task.isCancelled, current == token,
                      let index = messages.firstIndex(where: { $0.id == assistant.id }) else { return }
                messages[index].text = snapshot.fallbackDetail
                messages[index].state = .complete; generating = false; fallback = true
            }
        }
    }
}
