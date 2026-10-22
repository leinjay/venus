import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct TaskEditorView: View {
    @ObservedObject var store: ReminderStore
    @StateObject private var voice = TaskVoiceInput()
    @State private var draft: TaskDraft
    @State private var restorable: TaskDraft?
    @State private var askRestore = false
    @State private var askLeave = false
    @State private var askSaveDuringAnalysis = false
    @State private var error: String?
    @State private var analysis: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var processing = false
    @State private var finished = false
    @State private var conflicts: [TaskField] = []
    @State private var conflictingTask: ReminderItem?
    @State private var saveConflicts: [TaskField] = []
    @State private var choices: Set<TaskField> = []
    @State private var photos: [PhotosPickerItem] = []
    @State private var pendingImages: Set<UUID> = []
    @State private var camera = false
    @State private var showDependencies = false
    @State private var previewMarkdown = false
    @State private var tagKey = ""
    @State private var tagValue = ""
    @State private var voicePrefix = ""
    @State private var lastVoiceInput = ""
    @State private var imageToEdit: TaskImage?
    var onSaved: (UUID) -> Void
    var onClose: () -> Void

    init(store: ReminderStore, task: ReminderItem? = nil, restoredVersion: ReminderItem? = nil, onSaved: @escaping (UUID) -> Void, onClose: @escaping () -> Void) {
        self.store = store; self.onSaved = onSaved; self.onClose = onClose
        var value = TaskDraft(); value.base = task; value.task = restoredVersion ?? task ?? ReminderItem()
        if let restoredVersion, let task { value.task.id = task.id; value.task.lifecycle = task.lifecycle; value.task.deletedAt = nil; value.task.notificationVersion = task.notificationVersion; value.tab = 1; _ = restoredVersion }
        _draft = State(initialValue: value)
        _restorable = State(initialValue: restoredVersion == nil ? store.loadDraft(value.key) : nil)
    }

    private var editorContent: some View {
        VStack(spacing: 0) {
            Picker("编辑方式", selection: $draft.tab) { Text("与 AI 对话").tag(0); Text("属性表单").tag(1) }
                .pickerStyle(.segmented).padding()
            if processing { HStack { ProgressView(); Text("正在整理，可继续编辑表单"); Spacer(); Button("取消", action: cancelAnalysis) }.font(.caption).padding(.horizontal).padding(.bottom, 8) }
            if draft.tab == 0 { conversation } else { form }
        }
        .background(AppTheme.canvas.ignoresSafeArea())
        .navigationTitle(draft.base == nil ? "新建任务" : "编辑任务")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("返回") { voice.stop(); askLeave = true } }
            ToolbarItem(placement: .topBarTrailing) { Button("保存") { if processing { askSaveDuringAnalysis = true } else { prepareSave() } }.fontWeight(.semibold) }
        }
    }

    private var observedEditor: some View {
        editorContent
        .onAppear { askRestore = restorable != nil }
        .onChange(of: draft.task) { old, new in
            for field in TaskField.allCases where field.value(old) != field.value(new) { draft.fieldRevisions[field.rawValue, default: 0] += 1 }
            persistDraft()
        }
        .onChange(of: draft.input) { _, _ in if processing { cancelAnalysis() }; persistDraft() }
        .onChange(of: draft.images) { _, _ in persistDraft() }
        .onChange(of: draft.tab) { _, _ in voice.stop(); persistDraft() }
        .onChange(of: photos) { _, values in
            Task { for value in values {
                do { if let data = try await value.loadTransferable(type: Data.self) { try addImage(data) } }
                catch { self.error = error.localizedDescription }
            }; photos = [] }
        }
        .onReceive(voice.$text) { text in
            if !text.isEmpty, !finished, draft.input == lastVoiceInput {
                draft.input = voicePrefix + text; lastVoiceInput = draft.input
            }
        }
        .onReceive(voice.$error) { if let value = $0 { error = value } }
        .onDisappear { cancelAnalysis(); voice.cancel(); if !finished { persistDraft() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in cancelAnalysis(); voice.cancel(); persistDraft() }
    }

    private var editorDialogs: some View {
        observedEditor
        .alert("发现未完成草稿，最多保留 7 天", isPresented: $askRestore) {
            Button("恢复草稿") {
                if let restorable {
                    draft = restorable; pendingImages = Set(restorable.selectedImageIDs ?? [])
                    conflicts = restorable.unresolvedConflicts ?? []; conflictingTask = restorable.conflictProposal
                }
                restorable = nil
            }
            Button("放弃旧草稿", role: .destructive) { try? store.discardDraft(draft.key); restorable = nil }
        }
        .confirmationDialog("离开编辑页", isPresented: $askLeave, titleVisibility: .visible) {
            Button("保存任务并离开") { if processing { askSaveDuringAnalysis = true } else { prepareSave() } }
            Button("保留草稿并离开") { cancelAnalysis(); persistDraft(); finished = true; onClose() }
            Button("放弃本次编辑", role: .destructive) { cancelAnalysis(); try? store.discardDraft(draft.key); for image in draft.images { store.removeImage(image) }; finished = true; onClose() }
            Button("继续编辑", role: .cancel) {}
        }
        .confirmationDialog("AI 尚未完成，当前保存不会包含其后续结果", isPresented: $askSaveDuringAnalysis, titleVisibility: .visible) {
            Button("保存当前草稿") { cancelAnalysis(); prepareSave() }
        }
        .alert("请检查", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("知道了") { error = nil } } message: { Text(error ?? "") }
    }

    var body: some View {
        editorDialogs
        .sheet(isPresented: $showDependencies) { dependencyPicker }
        .sheet(item: $imageToEdit) { image in imageEditor(image) }
        .sheet(isPresented: $camera) { TaskCamera { image in do { if let data = image.jpegData(compressionQuality: 0.9) { try addImage(data) } } catch { self.error = error.localizedDescription } } }
        .sheet(isPresented: Binding(get: { !saveConflicts.isEmpty }, set: { if !$0 { saveConflicts = [] } })) { externalConflictSheet }
    }

    private var conversation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ModelBindingPanel(purpose: .dialogue).surfaceCard(padding: 14)
                Text("用文字、语音或图片中的文字描述一件事。AI 整理后可切换表单检查，点击保存才创建或更新任务。")
                    .font(.subheadline).foregroundStyle(AppTheme.secondary)
                ForEach(draft.messages) { message in
                    HStack { if message.isUser { Spacer(minLength: 28) }; Text(message.text).textSelection(.enabled).padding(14).background(message.isUser ? AppTheme.sage : AppTheme.surface, in: RoundedRectangle(cornerRadius: 16)); if !message.isUser { Spacer(minLength: 28) } }
                }
                if !conflicts.isEmpty, let proposal = conflictingTask {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("这些属性在 AI 处理期间有新修改，已保留当前值").font(.headline)
                        ForEach(conflicts) { field in
                            VStack(alignment: .leading) {
                                Text(field.label).fontWeight(.medium)
                                Text("建议：\(display(field, proposal))").font(.caption).lineLimit(4)
                                HStack {
                                    Button("使用建议") { field.copy(from: proposal, to: &draft.task); conflicts.removeAll { $0 == field }; persistDraft() }
                                    Button("保留当前") { conflicts.removeAll { $0 == field }; persistDraft() }
                                }.buttonStyle(.bordered)
                            }
                        }
                    }.surfaceCard()
                }
                if !draft.images.isEmpty {
                    Text("图片仅作草稿材料，保存后清理；当前只提取文字，不理解照片场景。").font(.caption).foregroundStyle(AppTheme.secondary)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top) { ForEach(draft.images) { image in
                            VStack {
                                Button { imageToEdit = image } label: {
                                    if let value = UIImage(contentsOfFile: store.imageURL(image).path) { Image(uiImage: value).resizable().scaledToFill().frame(width: 100, height: 90).clipped().clipShape(RoundedRectangle(cornerRadius: 10)) }
                                }
                                Toggle("本轮使用", isOn: Binding(get: { pendingImages.contains(image.id) }, set: { selected in
                                    cancelAnalysis()
                                    if selected && pendingImages.count < 3 { pendingImages.insert(image.id) } else { pendingImages.remove(image.id) }
                                })).font(.caption).frame(width: 110)
                                Button("移除", role: .destructive) { cancelAnalysis(); pendingImages.remove(image.id); draft.images.removeAll { $0.id == image.id }; store.removeImage(image); draft.messages.append(TaskMessage(isUser: false, text: "图片已移除，已合并的任务属性仍保留，可在表单中修改。")) }
                            }
                        } }
                    }
                }
                TextField("例如：明天下午三点去取快递", text: $draft.input, axis: .vertical).lineLimit(3...8).padding(14).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                HStack {
                    Button { if voice.recording { voice.stop() } else { lastVoiceInput = draft.input; voicePrefix = draft.input.isEmpty ? "" : draft.input + "\n"; Task { await voice.start() } } } label: { Label(voice.recording ? "结束录音" : "语音", systemImage: voice.recording ? "stop.circle.fill" : "mic") }.disabled(voice.starting)
                    PhotosPicker(selection: $photos, maxSelectionCount: 3, matching: .images) { Image(systemName: "photo") }.accessibilityLabel("从相册添加图片")
                    Menu {
                        Button("拍摄") { if UIImagePickerController.isSourceTypeAvailable(.camera) { camera = true } else { error = "此设备没有可用相机" } }
                        Button("粘贴图片") { if let image = UIPasteboard.general.image, let data = image.jpegData(compressionQuality: 0.9) { do { try addImage(data) } catch { self.error = error.localizedDescription } } else { error = "剪贴板中没有可用图片" } }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("拍摄或粘贴图片")
                    Spacer()
                    Button("整理任务", action: submit).buttonStyle(.borderedProminent).disabled(processing || voice.recording || (draft.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty))
                }.buttonStyle(.bordered)
                Text("\(draft.input.count) / 2,000 字 · 录音最多 2 分钟").font(.caption).foregroundStyle(AppTheme.secondary)
            }.padding()
        }.scrollDismissesKeyboard(.interactively)
    }

    private var form: some View {
        Form {
            Section("任务") {
                TextField("标题（必填）", text: $draft.task.title, axis: .vertical)
                TextField("概要", text: $draft.task.summary, axis: .vertical)
                Picker("重要程度", selection: $draft.task.priority) { ForEach(TaskPriority.allCases) { Text($0.title).tag($0) } }
                Toggle("已完成", isOn: $draft.task.isDone)
                Text("此处的修改在点击保存后生效").font(.caption).foregroundStyle(.secondary)
            }
            Section("时间") {
                DatePicker("添加时间", selection: $draft.task.addedAt)
                Picker("执行时间", selection: $draft.task.schedule.mode) { Text("未安排").tag(TaskSchedule.Mode.unplanned); Text("仅日期").tag(TaskSchedule.Mode.day); Text("精确时刻").tag(TaskSchedule.Mode.instant) }
                if draft.task.schedule.mode == .day {
                    DatePicker("执行日期", selection: Binding(get: { draft.task.schedule.trigger() ?? Date() }, set: { draft.task.schedule.day = TaskSchedule.dayString($0) }), displayedComponents: .date)
                    Text("当天 09:00 提醒；若时间已过则不补发").font(.caption)
                } else if draft.task.schedule.mode == .instant {
                    DatePicker("执行时刻", selection: $draft.task.schedule.instant)
                    Text("固定同一时刻，按当前时区显示").font(.caption)
                }
            }.onChange(of: draft.task.schedule.mode) { _, mode in if mode == .day && draft.task.schedule.day.isEmpty { draft.task.schedule.day = TaskSchedule.dayString(Date()) } }
            Section("具体内容 · Markdown") {
                Toggle("阅读预览", isOn: $previewMarkdown)
                if previewMarkdown { Text(.init(draft.task.body.isEmpty ? "暂无内容" : draft.task.body)).textSelection(.enabled) }
                else { TextEditor(text: $draft.task.body).frame(minHeight: 180) }
                Text("\(draft.task.body.count) / 20,000 字").font(.caption).foregroundStyle(.secondary)
            }
            Section("标签") {
                ForEach(Array(draft.task.tags.enumerated()), id: \.offset) { index, tag in
                    HStack { Text("\(tag.key): \(tag.value)"); Spacer(); Button(role: .destructive) { draft.task.tags.remove(at: index) } label: { Image(systemName: "minus.circle") } }
                }
                HStack { TextField("名称", text: $tagKey); TextField("值", text: $tagValue); Button("添加") { draft.task.tags = TaskRules.normalizedTags(draft.task.tags + [TaskTag(key: tagKey, value: tagValue)]); tagKey = ""; tagValue = "" } }
            }
            Section("前置任务") {
                ForEach(draft.task.prerequisiteIDs, id: \.self) { id in HStack { Text(store.item(id)?.title ?? "已删除任务，请移除"); Spacer(); Button("移除") { draft.task.prerequisiteIDs.removeAll { $0 == id } } } }
                Button("选择前置任务") { showDependencies = true }
                Text("依赖用于提示，不阻止任务完成或到时提醒。").font(.caption).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden)
    }

    private var dependencyPicker: some View {
        NavigationStack { List(store.reminders.filter { $0.id != draft.task.id }) { task in
            Button {
                if draft.task.prerequisiteIDs.contains(task.id) { draft.task.prerequisiteIDs.removeAll { $0 == task.id } }
                else {
                    var candidate = draft.task; candidate.prerequisiteIDs.append(task.id)
                    if candidate.title.isEmpty { candidate.title = "待补充" }
                    do { try TaskRules.validate(candidate, among: store.reminders); draft.task.prerequisiteIDs.append(task.id) } catch { self.error = error.localizedDescription }
                }
            } label: { HStack { Text(task.title); Spacer(); if draft.task.prerequisiteIDs.contains(task.id) { Image(systemName: "checkmark") } } }
        }.navigationTitle("选择前置任务").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showDependencies = false } } } }
    }

    private func imageEditor(_ image: TaskImage) -> some View {
        NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 16) {
            if let value = UIImage(contentsOfFile: store.imageURL(image).path) { Image(uiImage: value).resizable().scaledToFit().frame(maxHeight: 280) }
            Text("受限模式：仅提取图片中文字，不理解场景。图片中的相对日期需自行提供参考日期。").font(.caption).foregroundStyle(.secondary)
            Button("仅提取图中文字") {
                cancelAnalysis(); let token = requestID
                Task {
                    do {
                        let text = try await TaskImageReader.recognize(store.imageURL(image))
                        guard token == requestID, let index = draft.images.firstIndex(where: { $0.id == image.id }) else { return }
                        draft.images[index].text = text
                    } catch { self.error = error.localizedDescription }
                }
            }.buttonStyle(.borderedProminent)
            Text("核对并编辑识别文字")
            TextEditor(text: Binding(get: { draft.images.first { $0.id == image.id }?.text ?? "" }, set: { text in
                cancelAnalysis(); if let index = draft.images.firstIndex(where: { $0.id == image.id }) { draft.images[index].text = text }
            })).frame(minHeight: 220)
        }.padding() }.navigationTitle("图片文字").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { imageToEdit = nil } } } }
    }

    private var externalConflictSheet: some View {
        NavigationStack { List {
            Section { Text("任务在其他入口被更新。默认保留最新已保存值，勾选才使用本页修改。") }
            ForEach(saveConflicts) { field in
                Toggle(isOn: Binding(get: { choices.contains(field) }, set: {
                    if $0 { choices.insert(field) } else { choices.remove(field) }
                })) {
                    VStack(alignment: .leading) {
                        Text(field.label)
                        Text("本页：\(display(field, draft.task))").font(.caption)
                        if let latest = store.item(draft.task.id) {
                            Text("已保存：\(display(field, latest))").font(.caption)
                        }
                    }
                }
            }
        }.navigationTitle("确认属性冲突").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { saveConflicts = [] } }
            ToolbarItem(placement: .confirmationAction) { Button("确认保存") { finishSave() } }
        } }
    }
    private func display(_ field: TaskField, _ task: ReminderItem) -> String {
        if field == .schedule { return task.schedule.label }
        if field == .isDone { return task.isDone ? "已完成" : "未完成" }
        if field == .priority { return task.priority.title }
        if field == .addedAt { return task.addedAt.formatted() }
        if field == .prerequisiteIDs { return task.prerequisiteIDs.compactMap { store.item($0)?.title }.joined(separator: "、") }
        if field == .tags { return task.tags.map { "\($0.key):\($0.value)" }.joined(separator: "、") }
        return field.value(task)
    }
    private func persistDraft() {
        guard !finished else { return }
        var value = draft
        value.unresolvedConflicts = conflicts; value.conflictProposal = conflictingTask
        value.selectedImageIDs = draft.images.filter { pendingImages.contains($0.id) }.map(\.id)
        do { try store.saveDraft(value) } catch { self.error = "草稿保存失败：\(error.localizedDescription)" }
    }
    private func cancelAnalysis() { requestID = UUID(); analysis?.cancel(); analysis = nil; processing = false }
    private func addImage(_ data: Data) throws {
        guard !finished else { return }
        guard draft.images.count < 10, pendingImages.count < 3 else { throw TaskFailure("每轮最多 3 张图片，一份草稿最多保留 10 张") }
        let jpeg = try TaskImageReader.validatedJPEG(data)
        cancelAnalysis(); let image = try store.storeImage(jpeg); draft.images.append(image); pendingImages.insert(image.id); persistDraft()
    }
    private func submit() {
        voice.stop()
        let input = draft.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = draft.images.filter { pendingImages.contains($0.id) }
        guard selected.allSatisfy({ !$0.text.isEmpty }) else { error = "请先点开本轮图片，明确选择文字提取并核对结果，或取消本轮使用该图"; return }
        let imageText = selected.map(\.text).joined(separator: "\n---\n")
        guard input.count + imageText.count <= 2000 else { error = "本轮合计超过 2,000 字，请编辑识别文字、取消部分图片或分次输入"; return }
        cancelAnalysis(); processing = true
        let token = requestID, base = draft.task, revisions = draft.fieldRevisions
        analysis = Task {
            do {
                let proposal = try await TaskAI.propose(input: input, imageText: imageText, draft: base, candidates: store.reminders, dialogue: draft.messages)
                try Task.checkCancellation(); guard token == requestID else { return }
                var changed = draft.task; conflicts = []; conflictingTask = proposal.task
                for field in proposal.fields {
                    if draft.fieldRevisions[field.rawValue, default: 0] != revisions[field.rawValue, default: 0] || field.value(draft.task) != field.value(base) { conflicts.append(field) }
                    else { field.copy(from: proposal.task, to: &changed) }
                }
                draft.task = changed
                draft.messages.append(TaskMessage(isUser: true, text: input + (selected.isEmpty ? "" : "\n[\(selected.count) 张图片的文字资料]")))
                let labels = proposal.fields.filter { !conflicts.contains($0) }.map(\.label).joined(separator: "、")
                draft.messages.append(TaskMessage(isUser: false, text: proposal.message + (labels.isEmpty ? "" : "\n草稿已更新：\(labels)。请检查后保存。")))
                draft.input = ""; pendingImages = []; processing = false; persistDraft()
            } catch {
                guard token == requestID else { return }; processing = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    private func prepareSave() {
        cancelAnalysis(); voice.cancel(); choices = []
        if let base = draft.base, let latest = store.item(base.id) {
            let (_, conflicts) = TaskRules.merge(base: base, draft: draft.task, latest: latest)
            if !conflicts.isEmpty { saveConflicts = conflicts; return }
        }
        finishSave()
    }
    private func finishSave() {
        do { let id = try store.save(draft, resolving: choices); finished = true; saveConflicts = []; onSaved(id) }
        catch { self.error = error.localizedDescription }
    }
}

struct QwenModelPanel: View {
    @ObservedObject private var model = LocalQwenService.shared
    @State private var importer = false
    @State private var cellular = false
    @State private var delete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: "sparkles"); Text("本机 Qwen3").font(.headline); Spacer(); if model.ready { Image(systemName: "checkmark.shield") } }
            Text(model.status).font(.caption).textSelection(.enabled)
            if model.preparing { ProgressView(value: model.progress); Button("暂停下载") { model.cancelDownload() } }
            else if !model.ready {
                Text("首次约 984 MB，需至少 2 GB 可用空间。准备后可离线使用，内容留在手机。").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Wi-Fi 下载") { model.download() }; Button("导入目录") { importer = true } }.buttonStyle(.bordered)
                Button("使用蜂窝网络下载") { cellular = true }.font(.caption)
            } else { Button("删除模型", role: .destructive) { delete = true }.font(.caption).disabled(model.generating) }
        }.surfaceCard(padding: 14)
        .fileImporter(isPresented: $importer, allowedContentTypes: [.folder]) { result in if case .success(let url) = result { Task { await model.importDirectory(url) } } }
        .confirmationDialog("使用蜂窝网络下载约 984 MB 模型，可能产生流量费用", isPresented: $cellular, titleVisibility: .visible) { Button("继续下载") { model.download(allowsCellular: true) } }
        .confirmationDialog("删除后 AI 暂不可用，任务和已保存文字仍保留", isPresented: $delete, titleVisibility: .visible) { Button("删除模型", role: .destructive) { Task { await model.remove() } } }
    }
}
