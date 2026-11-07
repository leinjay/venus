import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private struct TaskVoiceButtonFrame: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct TaskRecordingWaveform: View {
    var level: Double
    var color: Color
    private let weights: [Double] = [0.3, 0.6, 0.9, 0.5, 0.75, 1, 0.65, 0.85, 0.4, 0.7, 0.95, 0.55, 0.3]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule().fill(color).frame(width: 4, height: 4 + 28 * level * weights[index])
            }
        }.frame(height: 32).animation(.easeOut(duration: 0.1), value: level)
    }
}

struct TaskEditorView: View {
    @ObservedObject var store: ReminderStore
    @StateObject private var voice = TaskVoiceInput()
    @StateObject private var recorder = TaskAudioRecorder()
    @ObservedObject private var registry = ModelRegistry.shared
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var inputFocused: Bool
    @State private var draft: TaskDraft
    @State private var restoredNotice: String?
    @State private var modelSettings = false
    @State private var openSettingsAfterDismiss = false
    @State private var followReply = true
    @State private var editorVisible = false
    @State private var assistantID: UUID?
    @State private var sentInput: String?
    @State private var lastProgressSaved = Date.distantPast
    @State private var speechTask: Task<Void, Never>?
    @State private var speechID = UUID()
    @State private var transcribing = false
    @State private var speechError: String?
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
    @GestureState private var voicePressed = false
    @State private var voiceMode = false
    @State private var voiceHold = TaskVoiceHold()
    @State private var voiceGestureConsumed = false
    @State private var voiceHoldShowsAction = false
    @State private var accessibleVoiceHold = false
    @State private var voiceButtonFrame = CGRect.zero
    @State private var recordingAudioID: UUID?
    @State private var voiceReviewOriginal: String?
    @State private var photoLibrary = false
    @State private var voicePrefix = ""
    @State private var lastVoiceInput = ""
    @State private var imageToEdit: TaskImage?
    var onSaved: (UUID) -> Void
    var onClose: () -> Void

    init(store: ReminderStore, task: ReminderItem? = nil, restoredVersion: ReminderItem? = nil, onSaved: @escaping (UUID) -> Void, onClose: @escaping () -> Void) {
        self.store = store; self.onSaved = onSaved; self.onClose = onClose
        var value = TaskDraft(); value.base = task; value.task = restoredVersion ?? task ?? ReminderItem()
        if let restoredVersion, let task { value.task.id = task.id; value.task.lifecycle = task.lifecycle; value.task.deletedAt = nil; value.task.notificationVersion = task.notificationVersion; value.tab = 1; _ = restoredVersion }
        var notice: String?
        if restoredVersion == nil, let saved = store.loadDraft(value.key), saved.base?.lifecycle == value.base?.lifecycle {
            value = saved; notice = "已恢复上次草稿"
        }
        if let task {
            do {
                if let conversation = try store.conversation(task.id) {
                    value.conversationID = conversation.id
                    if value.messages.isEmpty { value.messages = conversation.messages }
                }
            } catch { notice = "历史对话读取失败，原文件已保留；请先保留本页内容再重试。" }
        }
        if value.task.schedule.mode != .instant {
            value.task.schedule.instant = value.task.schedule.trigger() ?? Date()
            value.task.schedule.mode = .instant
        }
        value.conversationID = value.conversationID ?? UUID()
        value.messages = TaskConversation.recovered(value.messages)
        _draft = State(initialValue: value)
        _restoredNotice = State(initialValue: notice)
        _pendingImages = State(initialValue: Set(value.selectedImageIDs ?? []))
        _conflicts = State(initialValue: value.unresolvedConflicts ?? [])
        _conflictingTask = State(initialValue: value.conflictProposal)
    }

    private var editorContent: some View {
        VStack(spacing: 0) {
            if processing && draft.tab == 1 { HStack { ProgressView(); Text("正在回复，可继续编辑属性"); Spacer(); Button("停止", action: cancelAnalysis) }.font(.caption).padding(.horizontal).padding(.bottom, 8) }
            if draft.tab == 0 { conversation } else { form }
        }
        .background(AppTheme.canvas.ignoresSafeArea())
        .coordinateSpace(name: "task-editor")
        .overlay { recordingOverlay }
        .navigationTitle(draft.base == nil ? "新建任务" : "编辑任务")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("返回", action: leaveKeepingDraft) }
            ToolbarItem(placement: .topBarTrailing) { Button(action: showModelOptions) { Image(systemName: "cpu") }.accessibilityLabel("选择模型与管理配置") }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    inputFocused = false
                    draft.tab = draft.tab == 0 ? 1 : 0
                } label: {
                    Image(systemName: draft.tab == 0 ? "list.bullet.rectangle" : "bubble.left.and.bubble.right")
                }
                .accessibilityLabel(draft.tab == 0 ? "切换到属性表单" : "切换到与 AI 对话")
                .accessibilityHint("保留当前草稿并切换编辑方式")
            }
            ToolbarItem(placement: .topBarTrailing) { Button("保存", action: prepareSave).fontWeight(.semibold).accessibilityHint("保存当前任务属性，停止尚未完成的回复") }
        }
        .toolbar(.hidden, for: .tabBar)
    }

    private var observedEditor: some View {
        editorContent
        .onAppear { editorVisible = true }
        .onChange(of: draft.task) { old, new in
            for field in TaskField.allCases where field.value(old) != field.value(new) { draft.fieldRevisions[field.rawValue, default: 0] += 1 }
            persistDraft()
        }
        .onChange(of: draft.input) { _, _ in persistDraft() }
        .onChange(of: draft.images) { _, _ in persistDraft() }
        .onChange(of: draft.tab) { _, _ in cancelVoiceHold(); persistDraft() }
        .onChange(of: voicePressed) { _, pressed in
            if !pressed {
                // onEnded owns an intentional release; a reset without it is an interruption.
                Task { @MainActor in
                    await Task.yield()
                    guard !voicePressed, !accessibleVoiceHold else { return }
                    if voiceHold.isActive { cancelVoiceHold() }
                    voiceGestureConsumed = false
                }
            }
        }
        .onChange(of: voice.recording) { _, recording in
            if !recording {
                if voiceHold.isActive { finishVoiceHold() }
                applyVoiceText(voice.text)
            }
        }
        .onChange(of: recorder.seconds) { _, seconds in
            if seconds >= 120 && voiceHold.isActive { finishVoiceHold() }
        }
        .onChange(of: photos) { _, values in
            Task { for value in values {
                do { if let data = try await value.loadTransferable(type: Data.self) { try addImage(data) } }
                catch { self.error = error.localizedDescription }
            }; photos = [] }
        }
        .onReceive(voice.$text) { text in
            if !voice.recording { applyVoiceText(text) }
        }
        .onDisappear { editorVisible = false; cancelAnalysis(); cancelSpeech(); cancelVoiceHold(); if !finished { persistDraft() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { editorVisible = true }
            else {
                cancelVoiceHold()
                if phase == .background { editorVisible = false; cancelAnalysis(); cancelSpeech(); persistDraft() }
            }
        }
    }

    private var editorDialogs: some View {
        observedEditor
        .alert("请检查", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("知道了") { error = nil } } message: { Text(error ?? "") }
    }

    var body: some View {
        editorDialogs
        .sheet(isPresented: $modelSettings, onDismiss: { if openSettingsAfterDismiss { openSettingsAfterDismiss = false; navigation.openModels() } }) {
            NavigationStack {
                List {
                    Section { ModelBindingPanel(purpose: .dialogue, onManage: openModelSettings) }
                    Section { ModelBindingPanel(purpose: .transcription, onManage: openModelSettings) }
                }.navigationTitle("本次任务使用的模型")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { modelSettings = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDependencies) { dependencyPicker }
        .sheet(item: $imageToEdit) { image in imageEditor(image) }
        .sheet(isPresented: $camera) { TaskCamera { image in do { if let data = image.jpegData(compressionQuality: 0.9) { try addImage(data) } } catch { self.error = error.localizedDescription } } }
        .photosPicker(isPresented: $photoLibrary, selection: $photos, maxSelectionCount: 3, matching: .images)
        .sheet(isPresented: Binding(get: { !saveConflicts.isEmpty }, set: { if !$0 { saveConflicts = [] } })) { externalConflictSheet }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let restoredNotice {
                        Text(restoredNotice).font(.caption).foregroundStyle(AppTheme.secondary)
                    }
                    if draft.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 30)).foregroundStyle(AppTheme.pine)
                            Text("从一件想做的事开始").font(.title3).fontWeight(.semibold)
                            Text("告诉我想做什么，我会帮你整理任务。也可以随时切到属性表单调整。")
                                .font(.subheadline).foregroundStyle(AppTheme.secondary)
                            Text(registry.selected(.dialogue)?.name ?? "请点击右上角模型图标选择模型")
                                .font(.caption).foregroundStyle(AppTheme.pine)
                        }.padding(.top, 24).padding(.bottom, 12)
                    }
                    ForEach(draft.messages) { message in messageRow(message).id(message.id) }
                    conversationMaterials
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(DragGesture().onChanged { _ in followReply = false })
            .onChange(of: draft.messages.last?.text) { _, _ in if followReply { proxy.scrollTo("conversation-bottom", anchor: .bottom) } }
            .onChange(of: draft.messages.count) { _, _ in if followReply { withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) } } }
            .overlay(alignment: .bottomTrailing) {
                if !followReply && !draft.messages.isEmpty {
                    Button { followReply = true; withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) } } label: {
                        Image(systemName: "arrow.down").padding(12).background(AppTheme.surface, in: Circle()).shadow(color: .black.opacity(0.08), radius: 8)
                    }.padding(12).accessibilityLabel("回到最新对话")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
    }

    private func messageRow(_ message: TaskMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isUser { Spacer(minLength: 32) }
            else { Image(systemName: "sparkles").font(.caption).foregroundStyle(AppTheme.pine).padding(.top, 14) }
            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty { Text(message.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if message.state == .receiving {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(message.text.isEmpty ? "正在等待回复…" : "正在接收回复、核对任务属性…") }.font(.caption).foregroundStyle(AppTheme.secondary)
                } else if message.state == .stopped {
                    Text("已停止 · 本轮未应用属性").font(.caption).foregroundStyle(AppTheme.secondary)
                } else if message.state == .failed {
                    Text("回复未完成 · 本轮未应用属性").font(.caption).foregroundStyle(AppTheme.terracotta)
                }
                if let date = message.date { Text(date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(AppTheme.secondary) }
            }.padding(14).background(message.isUser ? AppTheme.sage : AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            if !message.isUser { Spacer(minLength: 8) }
        }
    }

    private var conversationMaterials: some View {
        VStack(alignment: .leading, spacing: 16) {
                if let issue = speechError ?? voice.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(issue).font(.caption).foregroundStyle(AppTheme.terracotta)
                        HStack {
                            Button("选择语音模型", action: showModelOptions)
                            if voice.needsSettings { Button("打开应用权限") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } }
                            Spacer()
                            Button { speechError = nil; voice.error = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("收起语音提示")
                        }.font(.caption)
                    }.surfaceCard()
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
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if voice.finalizing { HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("正在完成文字识别…") }.font(.caption).foregroundStyle(AppTheme.secondary) }
            if let audio = draft.audio, !voiceHold.isActive {
                HStack(spacing: 10) {
                    Label(recorder.recording ? "录音 \(recorder.seconds) 秒" : transcribing ? "正在转写录音…" : "录音已保留", systemImage: "waveform").font(.caption)
                    Spacer()
                    if !recorder.recording {
                        if transcribing { Button("停止", action: cancelSpeech) }
                        else if audio.transcript != nil { Button("插入文字", action: insertTranscript) }
                        else { Button("重试转写", action: transcribeAudio) }
                        Button { removeAudio() } label: { Image(systemName: "trash") }.accessibilityLabel("删除录音")
                    }
                }.font(.caption)
                if let transcript = audio.transcript {
                    TextField("核对转写文字", text: Binding(get: { draft.audio?.transcript ?? transcript }, set: { draft.audio?.transcript = $0; persistDraft() }), axis: .vertical).lineLimit(2...4).font(.caption)
                }
            }
            if voiceReviewOriginal != nil {
                HStack {
                    Text("已转为文字，可修改后发送").foregroundStyle(AppTheme.secondary)
                    Spacer()
                    Button("取消这段") {
                        voiceHold.cancel(); voice.cancel()
                        if let original = voiceReviewOriginal { draft.input = original }
                        voiceReviewOriginal = nil; persistDraft()
                    }
                }.font(.caption)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    cancelVoiceHold(); voiceReviewOriginal = nil
                    voiceMode.toggle(); inputFocused = !voiceMode
                } label: {
                    Image(systemName: voiceMode ? "keyboard" : "waveform.circle")
                        .font(.system(size: 24)).frame(width: 36, height: 48)
                }.accessibilityLabel(voiceMode ? "切换键盘输入" : "切换按住说话")
                    .disabled(voiceHold.isActive)
                if voiceMode { holdToTalk }
                else {
                    TextField("说说你想做的事…", text: $draft.input, axis: .vertical)
                        .lineLimit(1...5).focused($inputFocused).padding(.horizontal, 12).padding(.vertical, 13)
                        .frame(minHeight: 48).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .disabled(voiceHold.isActive)
                }
                Menu {
                    Button("从相册添加图片", systemImage: "photo") { inputFocused = false; photoLibrary = true }
                    Button("拍摄") { inputFocused = false; if UIImagePickerController.isSourceTypeAvailable(.camera) { camera = true } else { error = "此设备没有可用相机" } }
                    Button("粘贴图片") { if let image = UIPasteboard.general.image, let data = image.jpegData(compressionQuality: 0.9) { do { try addImage(data) } catch { self.error = error.localizedDescription } } else { error = "剪贴板中没有可用图片" } }
                } label: { Image(systemName: "plus.circle").font(.system(size: 24)).frame(width: 36, height: 48) }
                    .accessibilityLabel("添加图片或拍摄").disabled(voiceHold.isActive)
                if !voiceMode || (voiceHold.isActive ? voiceHoldShowsAction : processing) {
                    Button { if processing { cancelAnalysis(); persistDraft() } else { submit() } } label: {
                        Text(processing ? "停止" : "发送")
                            .font(.subheadline.weight(.semibold)).frame(width: 48, height: 48)
                            .foregroundStyle(.white).background(AppTheme.pine, in: RoundedRectangle(cornerRadius: 12))
                    }.accessibilityLabel(processing ? "停止" : "发送")
                    .disabled(voiceHold.isActive || (!processing && (isRecording || transcribing || (draft.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty))))
                    .opacity(!processing && draft.input.isEmpty && pendingImages.isEmpty ? 0.5 : 1)
                }
            }.buttonStyle(.plain)
            HStack {
                Text("\(draft.input.count) / 2,000 字").foregroundStyle(draft.input.count > 2000 ? AppTheme.terracotta : AppTheme.secondary)
                Spacer()
                Text(voiceMode ? "松手转文字 · 上滑到 × 取消" : "离开自动保留草稿").foregroundStyle(AppTheme.secondary)
            }.font(.caption2)
        }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            .background(AppTheme.canvas)
            .overlay(alignment: .top) { Rectangle().fill(AppTheme.line).frame(height: 1) }
    }

    private var isRecording: Bool { voice.recording || recorder.recording }

    private var cancelRegion: CGRect { TaskVoiceHold.cancelRegion(above: voiceButtonFrame) }

    private var holdToTalk: some View {
        Text(transcribing ? "正在转文字…" : voiceHold.isActive ? "松开转文字" : "按住说话")
            .font(.body.weight(.medium)).frame(maxWidth: .infinity).frame(height: 48)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .background(GeometryReader { geometry in
                Color.clear.preference(key: TaskVoiceButtonFrame.self, value: geometry.frame(in: .named("task-editor")))
            })
            .onPreferenceChange(TaskVoiceButtonFrame.self) { voiceButtonFrame = $0 }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("task-editor"))
                .updating($voicePressed) { _, pressed, _ in pressed = true }
                .onChanged { value in
                    if !voiceGestureConsumed { voiceGestureConsumed = true; beginVoiceHold() }
                    updateVoiceTarget(value.location)
                }
                .onEnded { value in
                    updateVoiceTarget(value.location); finishVoiceHold()
                    voiceGestureConsumed = false
                })
            .allowsHitTesting(!transcribing && !voice.finalizing)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(voiceHold.isActive ? "结束录音并转文字" : "按住说话，松开转文字")
            .accessibilityHint("向上滑入取消区后松手可撤销录音")
            .accessibilityAction {
                if voiceHold.isActive { finishVoiceHold() }
                else { beginVoiceHold(accessibility: true) }
            }
            .accessibilityAction(named: Text("取消录音")) { cancelVoiceHold() }
    }

    private var recordingOverlay: some View {
        GeometryReader { geometry in
            if voiceHold.isActive, !voiceButtonFrame.isEmpty {
                let cancel = cancelRegion
                let armed = voiceHold.cancelsOnRelease
                let feedback = armed ? Color(red: 0.93, green: 0.28, blue: 0.31) : AppTheme.sage
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.68).ignoresSafeArea()
                    if cancel.minY > 100 {
                        VStack(spacing: 14) {
                            if isRecording {
                                TaskRecordingWaveform(level: recorder.recording ? recorder.level : voice.level,
                                                      color: armed ? .white : AppTheme.ink)
                            } else { ProgressView().tint(armed ? .white : AppTheme.ink) }
                            Text(armed ? "松开取消" : isRecording ? "松开转文字" : "正在开启麦克风…")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(armed ? .white : AppTheme.ink)
                        }
                        .frame(width: min(230, geometry.size.width - 48), height: 100)
                        .background(feedback, in: RoundedRectangle(cornerRadius: 24))
                        .overlay(alignment: .bottom) {
                            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 18))
                                .foregroundStyle(feedback).offset(y: 12)
                        }
                        .position(x: geometry.size.width / 2, y: cancel.midY - 125)
                    }
                    VStack(spacing: 6) {
                        Image(systemName: "xmark").font(.system(size: 24, weight: .medium))
                            .frame(width: 64, height: 64)
                            .background(armed ? feedback : .white.opacity(0.18), in: Circle())
                            .scaleEffect(armed ? 1.12 : 1)
                        Text(armed ? "松开取消" : "滑到这里取消").font(.caption)
                    }.foregroundStyle(.white)
                        .position(x: cancel.midX, y: cancel.midY + 10)
                    Text(armed ? "松开取消" : "松开转文字")
                        .font(.body.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: voiceButtonFrame.width, height: voiceButtonFrame.height)
                        .background(armed ? feedback : .white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                        .position(x: voiceButtonFrame.midX, y: voiceButtonFrame.midY)
                }
                .animation(.easeOut(duration: 0.12), value: armed)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func updateVoiceTarget(_ point: CGPoint) {
        let previous = voiceHold.cancelsOnRelease
        voiceHold.move(to: point, cancelRegion: cancelRegion)
        if previous != voiceHold.cancelsOnRelease { UISelectionFeedbackGenerator().selectionChanged() }
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
                DatePicker("执行时间", selection: Binding(
                    get: { draft.task.schedule.instant },
                    set: {
                        draft.task.schedule.instant = $0
                        draft.task.schedule.mode = .instant
                        draft.task.schedule.recurrenceAnchor = nil
                        draft.task.schedule.timeZone = TimeZone.current.identifier
                    }
                ), displayedComponents: [.date, .hourAndMinute])
                Picker("执行周期", selection: $draft.task.schedule.recurrence) {
                    ForEach(TaskSchedule.Recurrence.allCases) { Text($0.title).tag($0) }
                }
                if draft.task.schedule.recurrence == .hourly {
                    Stepper("每 \(draft.task.schedule.intervalHours) 小时执行一次", value: $draft.task.schedule.intervalHours, in: 1...8760)
                    TextField("间隔小时数", value: $draft.task.schedule.intervalHours, format: .number).keyboardType(.numberPad)
                }
                if draft.task.schedule.recurrence != .once {
                    Text("完成本次后自动进入下一次。每天、每周和每月按设置时区的相同时刻执行；每月遇到短月在月末执行。").font(.caption).foregroundStyle(.secondary)
                    Text("系统最多预排 64 条通知，打开 App 时自动续排。").font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: draft.task.schedule.recurrence) { _, _ in
                draft.task.schedule.recurrenceAnchor = nil
                draft.task.schedule.timeZone = TimeZone.current.identifier
            }
            .onChange(of: draft.task.schedule.intervalHours) { _, _ in draft.task.schedule.recurrenceAnchor = nil }
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
    @discardableResult
    private func persistDraft() -> Bool {
        guard !finished else { return true }
        var value = draft
        value.unresolvedConflicts = conflicts; value.conflictProposal = conflictingTask
        value.selectedImageIDs = draft.images.filter { pendingImages.contains($0.id) }.map(\.id)
        do { try store.saveDraft(value); return true } catch { self.error = "草稿保存失败：\(error.localizedDescription)"; return false }
    }
    private func cancelAnalysis() {
        requestID = UUID(); analysis?.cancel(); analysis = nil
        if processing, let id = assistantID, let index = draft.messages.firstIndex(where: { $0.id == id }) { draft.messages[index].state = .stopped }
        if processing, draft.input.isEmpty, let sentInput { draft.input = sentInput }
        processing = false; assistantID = nil; sentInput = nil
    }
    private func leaveKeepingDraft() {
        inputFocused = false; editorVisible = false
        cancelAnalysis(); cancelSpeech(); cancelVoiceHold()
        guard persistDraft() else { editorVisible = true; return }
        finished = true; onClose()
    }
    private func openModelSettings() {
        inputFocused = false; cancelAnalysis(); cancelSpeech(); cancelVoiceHold()
        guard persistDraft() else { return }
        openSettingsAfterDismiss = true; modelSettings = false
    }
    private func showModelOptions() {
        inputFocused = false; cancelVoiceHold(); cancelSpeech(); persistDraft()
        modelSettings = true
    }
    private func cancelSpeech() { speechID = UUID(); speechTask?.cancel(); speechTask = nil; transcribing = false }
    private func applyVoiceText(_ text: String) {
        guard voiceHold.phase == .released, registry.selected(.transcription) == nil,
              !text.isEmpty, editorVisible, !finished, draft.input == lastVoiceInput else { return }
        let combined = voicePrefix + text
        guard combined.count <= 2000 else { speechError = "语音识别结果超过 2,000 字，请缩短录音后重试。"; return }
        if voiceReviewOriginal == nil { voiceReviewOriginal = lastVoiceInput }
        draft.input = combined; lastVoiceInput = draft.input; voiceMode = false
    }
    private func finishVoiceHold() {
        guard voiceHold.isActive else { return }
        guard voiceHold.release() else { cancelVoiceHold(); return }
        accessibleVoiceHold = false
        if voice.starting || recorder.starting { cancelVoiceHold(); return }
        if let id = recordingAudioID, draft.audio?.id == id {
            recorder.stop(); recordingAudioID = nil; voiceMode = false; transcribeAudio()
        } else {
            voiceMode = false; voice.finish(); applyVoiceText(voice.text)
        }
    }
    private func cancelVoiceHold() {
        voiceHold.cancel(); accessibleVoiceHold = false
        voice.cancel(); recorder.stop()
        if let id = recordingAudioID, let audio = draft.audio, audio.id == id {
            store.removeAudio(audio); draft.audio = nil
            persistDraft()
        }
        recordingAudioID = nil
    }
    private func beginVoiceHold(accessibility: Bool = false) {
        guard !transcribing, !voice.finalizing, !voice.starting, !recorder.starting, !voiceHold.isActive else { return }
        inputFocused = false; speechError = nil; voice.error = nil
        // A retained failed recording must be resolved explicitly, never deleted by a new gesture.
        guard draft.audio == nil else { speechError = "请先转写或删除已保留的录音，再录制下一段。"; return }
        if registry.selected(.transcription) != nil {
            do { _ = try registry.resolve(.transcription) }
            catch { speechError = error.localizedDescription; modelSettings = true; return }
        }
        voice.cancel(); voice.text = ""
        voiceHoldShowsAction = processing
        let token = voiceHold.begin(); accessibleVoiceHold = accessibility
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if registry.selected(.transcription) != nil {
            let audio = TaskAudio(filename: "audio-\(UUID()).m4a")
            Task {
                do {
                    guard editorVisible, voiceHold.isActive, voiceHold.accepts(token) else { return }
                    try await recorder.start(at: store.audioURL(audio))
                    guard editorVisible, voiceHold.isActive, voiceHold.accepts(token) else { store.removeAudio(audio); return }
                    recordingAudioID = audio.id; draft.audio = audio; persistDraft()
                } catch is CancellationError { store.removeAudio(audio) }
                catch {
                    store.removeAudio(audio)
                    guard voiceHold.accepts(token) else { return }
                    cancelVoiceHold(); speechError = error.localizedDescription
                }
            }
        } else {
            lastVoiceInput = draft.input; voicePrefix = draft.input.isEmpty ? "" : draft.input + "\n"
            Task {
                guard editorVisible, voiceHold.isActive, voiceHold.accepts(token) else { return }
                await voice.start()
                guard voiceHold.accepts(token) else { return }
                if !voice.recording { cancelVoiceHold() }
            }
        }
    }
    private func transcribeAudio() {
        guard let audio = draft.audio, !recorder.recording, !transcribing else { return }
        cancelSpeech(); speechError = nil; let token = speechID
        let originalInput = draft.input
        transcribing = true
        speechTask = Task {
            do {
                let text = try await ConfiguredModelService.shared.transcribe(audio: store.audioURL(audio))
                try Task.checkCancellation()
                guard token == speechID, draft.audio?.id == audio.id else { return }
                transcribing = false; draft.audio?.transcript = text
                if draft.input == originalInput { insertTranscript() } else { persistDraft() }
            } catch {
                guard token == speechID else { return }; transcribing = false
                speechError = error is CancellationError ? "转写已停止，录音已保留，可重试或删除。" : "\(error.localizedDescription)。录音已保留，可重试或删除。"
                persistDraft()
            }
        }
    }
    private func insertTranscript() {
        guard let text = draft.audio?.transcript else { return }
        let combined = draft.input + (draft.input.isEmpty ? "" : "\n") + text
        guard combined.count <= 2000 else { speechError = "转写文字与当前输入超过 2,000 字，请先编辑录音转写文字，再插入；没有截断或删除录音。"; persistDraft(); return }
        voiceReviewOriginal = draft.input
        draft.input = combined; removeAudio(); voiceMode = false; inputFocused = false
    }
    private func removeAudio() {
        cancelSpeech(); recorder.stop()
        if let audio = draft.audio { store.removeAudio(audio) }
        draft.audio = nil; persistDraft()
    }
    private func addImage(_ data: Data) throws {
        guard !finished else { return }
        guard draft.images.count < 10, pendingImages.count < 3 else { throw TaskFailure("每轮最多 3 张图片，一份草稿最多保留 10 张") }
        let jpeg = try TaskImageReader.validatedJPEG(data)
        cancelAnalysis(); let image = try store.storeImage(jpeg); draft.images.append(image); pendingImages.insert(image.id); persistDraft()
    }
    private func submit() {
        guard !voiceHold.isActive else { return }
        voiceHold.cancel(); voice.cancel(); voiceReviewOriginal = nil
        let input = draft.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = draft.images.filter { pendingImages.contains($0.id) }
        guard selected.allSatisfy({ !$0.text.isEmpty }) else { error = "请先点开本轮图片，明确选择文字提取并核对结果，或取消本轮使用该图"; return }
        let imageText = selected.map(\.text).joined(separator: "\n---\n")
        guard input.count + imageText.count <= 2000 else { error = "本轮合计超过 2,000 字，请编辑识别文字、取消部分图片或分次输入"; return }
        guard !input.isEmpty || !selected.isEmpty else { return }
        cancelAnalysis(); inputFocused = false; processing = true; followReply = true
        let token = requestID, base = draft.task, revisions = draft.fieldRevisions, dialogue = draft.messages
        sentInput = input
        draft.messages.append(TaskMessage(isUser: true, text: input + (selected.isEmpty ? "" : "\n[\(selected.count) 张图片的文字资料]"), state: .complete))
        let assistant = TaskMessage(isUser: false, text: "", state: .receiving)
        assistantID = assistant.id; draft.messages.append(assistant); draft.input = ""
        guard persistDraft() else { cancelAnalysis(); return }
        analysis = Task {
            do {
                let proposal = try await TaskAI.propose(input: input, imageText: imageText, draft: base, candidates: store.reminders, dialogue: dialogue, onProgress: { text in
                    guard token == requestID, processing, let index = draft.messages.firstIndex(where: { $0.id == assistant.id }) else { return }
                    draft.messages[index].text = text
                    if Date().timeIntervalSince(lastProgressSaved) >= 0.5 { lastProgressSaved = Date(); persistDraft() }
                })
                try Task.checkCancellation(); guard token == requestID else { return }
                var changed = draft.task; conflicts = []; conflictingTask = proposal.task
                for field in proposal.fields {
                    if draft.fieldRevisions[field.rawValue, default: 0] != revisions[field.rawValue, default: 0] || field.value(draft.task) != field.value(base) { conflicts.append(field) }
                    else { field.copy(from: proposal.task, to: &changed) }
                }
                draft.task = changed
                if let index = draft.messages.firstIndex(where: { $0.id == assistant.id }) {
                    draft.messages[index].text = proposal.message + (conflicts.isEmpty ? "" : "\n有些属性同时被修改，我保留了你的值，请在下方核对建议。")
                    draft.messages[index].state = .complete
                }
                pendingImages.subtract(selected.map(\.id)); processing = false; assistantID = nil; sentInput = nil; persistDraft()
            } catch {
                guard token == requestID else { return }; processing = false
                if let index = draft.messages.firstIndex(where: { $0.id == assistant.id }) {
                    draft.messages[index].state = error is CancellationError ? .stopped : .failed
                    let prefix = draft.messages[index].text.isEmpty ? "" : draft.messages[index].text + "\n\n"
                    draft.messages[index].text = prefix + (error is CancellationError ? "本轮已停止。" : error.localizedDescription)
                }
                if draft.input.isEmpty { draft.input = input }
                assistantID = nil; sentInput = nil; persistDraft()
            }
        }
    }
    private func prepareSave() {
        cancelAnalysis(); cancelSpeech(); cancelVoiceHold(); choices = []
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
    @ObservedObject private var registry = ModelRegistry.shared
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
        .confirmationDialog("删除本机 Qwen3 资源？", isPresented: $delete, titleVisibility: .visible) { Button("删除模型", role: .destructive) { Task { await model.remove() } } } message: {
            Text("以下配置将需要重新准备资源：" + registry.configurations.filter { $0.execution == .onDevice && $0.modelID == LocalQwenService.modelID }.map(\.name).joined(separator: "、") + "。配置、任务和已保存文字仍保留。")
        }
    }
}
