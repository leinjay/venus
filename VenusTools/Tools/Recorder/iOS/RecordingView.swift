import SwiftUI

struct RecordingView: View {
    @ObservedObject var store: RecordingStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    BrandHeader(eyebrow: "VOICE NOTES", title: "录音", subtitle: "先把对话留下来，再慢慢整理重点。")

                    recorderCard

                    if !store.recordings.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("最近录音").font(.system(size: 19, weight: .semibold, design: .serif)).foregroundStyle(AppTheme.ink)
                                Spacer()
                                Text("\(store.recordings.count) 条").font(.caption).foregroundStyle(AppTheme.secondary)
                            }
                            ForEach(store.recordings) { item in
                                NavigationLink {
                                    RecordingDetailView(store: store, recordingID: item.id)
                                } label: {
                                    recordingRow(item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack(spacing: 9) {
                        Image(systemName: "applewatch").foregroundStyle(AppTheme.pine)
                        Text("手表录音同步后会出现在这里。")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.secondary)
                    }
                    .padding(14)
                    .background(AppTheme.sage.opacity(0.7), in: RoundedRectangle(cornerRadius: 17))
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
            .background(AppTheme.canvas.ignoresSafeArea())
            .navigationTitle("录音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { RecordingModelsView() } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("录音模型")
                }
            }
        }
        .alert("录音提示", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var recorderCard: some View {
        VStack(spacing: 18) {
            HStack {
                AccentLabel(title: store.isRecording ? "正在录音" : "准备就绪", color: store.isRecording ? AppTheme.terracotta : AppTheme.pine)
                Spacer()
                Image(systemName: store.isRecording ? "waveform" : "waveform.badge.mic")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(AppTheme.pine)
            }

            ZStack {
                Circle().fill(AppTheme.sage.opacity(0.78)).frame(width: 104, height: 104)
                Circle().stroke(AppTheme.pine.opacity(0.16), lineWidth: 1).frame(width: 118, height: 118)
                Image(systemName: "waveform")
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(store.isRecording ? AppTheme.terracotta : AppTheme.pine)
                    .scaleEffect(store.isRecording ? 1 + store.audioLevel * 0.15 : 1)
                    .animation(.easeOut(duration: 0.15), value: store.audioLevel)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)

            Text(Self.timeText(store.recordingSeconds))
                .font(.system(size: 31, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(AppTheme.ink)
            Text(store.isRecording
                 ? "\(store.captionMessage) · 单条片段约 20 MB 上限"
                 : (store.supplementTargetTitle.map { "将补录到「\($0)」" } ?? "本机保存，录音内容不会自动发送"))
                .font(.caption).foregroundStyle(AppTheme.secondary).multilineTextAlignment(.center)

            Button {
                if store.isRecording { store.stopRecording() }
                else { Task { await store.startRecording() } }
            } label: {
                Label(store.isRecording ? (store.isSupplementing ? "结束并补录" : "结束并保存")
                      : (store.isStarting ? "正在准备…" : (store.workingID != nil ? "正在处理…" : (store.pendingSupplementForID == nil ? "开始录音" : "开始补录"))),
                      systemImage: store.isRecording ? "stop.fill" : "record.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .foregroundStyle(.white)
                    .background(store.isRecording ? AppTheme.terracotta : AppTheme.pine, in: Capsule())
            }
            .disabled(store.isStarting || store.workingID != nil)
            .buttonStyle(.plain)

            if store.pendingSupplementForID != nil {
                Button("取消补录") { store.cancelSupplement() }
                    .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.secondary)
                    .disabled(store.isStarting)
            }

            if store.isRecording || !store.liveTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(store.isRecording ? AppTheme.terracotta : AppTheme.pine).frame(width: 6, height: 6)
                        Text("实时字幕").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.secondary)
                    }
                    Text(store.liveTranscript.isEmpty ? "正在聆听…" : store.liveTranscript)
                        .font(.system(size: 15)).foregroundStyle(store.liveTranscript.isEmpty ? AppTheme.secondary : AppTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .padding(14)
                .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 17))
            }
        }
        .surfaceCard(padding: 18)
    }

    private func recordingRow(_ item: VoiceRecording) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.origin == .appleWatch ? "applewatch" : "waveform.circle.fill")
                .font(.system(size: 23)).foregroundStyle(AppTheme.pine)
                .frame(width: 42, height: 42).background(AppTheme.sage, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.ink).lineLimit(1)
                Text("\(item.origin == .appleWatch ? "Apple Watch · " : "")\(item.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(Self.timeText(Int(item.duration)))\(item.supplementalSegments.isEmpty ? "" : " · 补录 \(item.supplementalSegments.count) 段")")
                    .font(.caption).foregroundStyle(AppTheme.secondary).lineLimit(1)
                Text(item.summary.isEmpty ? (item.transcript.isEmpty ? "等待转写" : String(item.transcript.prefix(55))) : String(item.summary.prefix(55)))
                    .font(.caption).foregroundStyle(AppTheme.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.secondary.opacity(0.7))
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.line, lineWidth: 1) }
    }

    static func timeText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct RecordingAnalysisHistoryView: View {
    @ObservedObject var store: RecordingStore

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                BrandHeader(eyebrow: "VOICE LIBRARY", title: "分析历史", subtitle: "保存的转写与分析都在这里。")
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                if store.analysisHistory.isEmpty {
                    ContentUnavailableView("还没有分析历史", systemImage: "text.bubble", description: Text("在录音详情里完成分析并保存后，会出现在这里。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.analysisHistory) { archive in
                            NavigationLink {
                                RecordingAnalysisArchiveDetail(archive: archive)
                            } label: {
                                analysisHistoryRow(archive)
                            }
                            .listRowBackground(AppTheme.surface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { store.deleteAnalysisArchive(archive.id) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                }
            }
            .background(AppTheme.canvas.ignoresSafeArea())
            .navigationTitle("分析历史")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("录音提示", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private func analysisHistoryRow(_ archive: RecordingAnalysisArchive) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill").foregroundStyle(AppTheme.pine)
                Text(archive.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.ink).lineLimit(1)
                Spacer(minLength: 0)
                Text(archive.savedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(AppTheme.secondary)
            }
            Text(archive.analysisPreview).font(.caption).foregroundStyle(AppTheme.secondary).lineLimit(2)
            Text("转写 \(archive.transcript.count) 字 · \(RecordingView.timeText(Int(archive.duration)))")
                .font(.caption2).foregroundStyle(AppTheme.secondary)
        }
        .padding(.vertical, 7)
    }
}

private struct RecordingModelsView: View {
    var body: some View {
        List {
            Section {
                Text("实时字幕始终使用 Apple Speech。录音详情默认用 Apple Speech 本机转写；也可选 Whisper 本机模型，或主动配置并授权外部转写服务。分析服务只接收转写文字。")
                    .font(.caption).foregroundStyle(AppTheme.secondary)
                ModelBindingPanel(purpose: .recordingTranscription)
                ModelBindingPanel(purpose: .recordingSummary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.canvas)
        .navigationTitle("录音模型")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RecordingTranscriptionModelPicker: View {
    @Binding var selection: RecordingTranscriptionModel
    @ObservedObject private var registry = ModelRegistry.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("本机识别") {
                ForEach(RecordingTranscriptionModel.allCases.filter { $0 != .configuredService }) { model in
                    Button { selection = model; dismiss() } label: {
                        modelRow(model)
                    }
                    .listRowBackground(AppTheme.surface)
                }
            }
            Section("自定义服务") {
                if registry.selected(.recordingTranscription) != nil {
                    Button { selection = .configuredService; dismiss() } label: {
                        modelRow(.configuredService)
                    }
                    .listRowBackground(AppTheme.surface)
                }
                NavigationLink { RecordingModelsView() } label: {
                    Label("管理自定义识别服务", systemImage: "slider.horizontal.3")
                        .foregroundStyle(AppTheme.pine)
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.canvas)
        .navigationTitle("选择转写模型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
        }
    }

    private func modelRow(_ model: RecordingTranscriptionModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selection == model ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selection == model ? AppTheme.pine : AppTheme.secondary)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.ink)
                Text(model.detail).font(.caption).foregroundStyle(AppTheme.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private struct RecordingDetailView: View {
    @ObservedObject var store: RecordingStore
    let recordingID: UUID
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var modelRegistry = ModelRegistry.shared
    @AppStorage("recording.transcription.model") private var selectedModelRawValue = RecordingTranscriptionModel.appleSpeech.rawValue
    @State private var confirmDelete = false
    @State private var showingTranscript = true
    @State private var showingModelPicker = false
    @State private var analysisMessages: [RecordingAnalysisMessage] = []
    @State private var analysisDraft = ""
    @State private var isAnalyzing = false
    @State private var analysisSaved = false
    @State private var analysisError: String?
    @State private var isScrubbing = false
    @State private var scrubberValue: TimeInterval = 0

    private var item: VoiceRecording? { store.recording(recordingID) }
    private var isWorking: Bool { store.workingID == recordingID }
    private var selectedModel: RecordingTranscriptionModel {
        RecordingTranscriptionModel(rawValue: selectedModelRawValue) ?? .appleSpeech
    }
    private var selectedModelBinding: Binding<RecordingTranscriptionModel> {
        Binding(
            get: { RecordingTranscriptionModel(rawValue: selectedModelRawValue) ?? .appleSpeech },
            set: { selectedModelRawValue = $0.rawValue }
        )
    }
    private var activeLineID: UUID? {
        guard store.playingID == recordingID, let item else { return nil }
        return timelineLines(for: item).first(where: { store.playbackCurrentTime >= $0.start && store.playbackCurrentTime <= max($0.end, $0.start + 0.15) })?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let item {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                AccentLabel(title: item.origin == .appleWatch ? "Apple Watch" : "iPhone")
                                Text(item.title).font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(AppTheme.ink)
                                Text("\(item.createdAt.formatted(date: .complete, time: .shortened)) · \(RecordingView.timeText(Int(item.duration)))")
                                    .font(.caption).foregroundStyle(AppTheme.secondary)
                                if !item.supplementalSegments.isEmpty {
                                    Text("含 \(item.supplementalSegments.count) 段补录")
                                        .font(.caption).foregroundStyle(AppTheme.pine)
                                }
                            }
                            Spacer(minLength: 0)
                            Button(role: .destructive) { confirmDelete = true } label: {
                                Image(systemName: "trash").frame(width: 40, height: 40).foregroundStyle(AppTheme.terracotta)
                                    .background(AppTheme.terracotta.opacity(0.11), in: Circle())
                            }.accessibilityLabel("删除录音")
                        }

                        Button {
                            if showingTranscript {
                                showingTranscript = false
                                if analysisMessages.isEmpty {
                                    if !item.summary.isEmpty {
                                        analysisMessages = [RecordingAnalysisMessage(role: .assistant, text: item.summary)]
                                    } else {
                                        sendAnalysisPrompt("请分析这段录音，概括主要内容、关键主题、决定和待办。", for: item)
                                    }
                                }
                            } else {
                                showingTranscript = true
                            }
                        } label: {
                            Label(showingTranscript ? "录音分析" : "查看转写", systemImage: showingTranscript ? "bubble.left.and.bubble.right" : "text.alignleft")
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                                .foregroundStyle(AppTheme.pine).background(AppTheme.sage, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(showingTranscript && (item.transcriptForAnalysis.isEmpty || item.hasUntranscribedSupplement || isWorking))

                        if showingTranscript {
                            transcriptPanel(item)
                        } else {
                            analysisPanel(item)
                        }
                    }
                    .padding(20).padding(.bottom, 24)
                } else {
                    ContentUnavailableView("录音已删除", systemImage: "waveform.slash", description: Text("返回录音列表查看其他内容。"))
                }
            }
            .background(AppTheme.canvas.ignoresSafeArea())
            .onChange(of: activeLineID) { _, id in
                guard showingTranscript, let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: analysisMessages.last?.id) { _, id in
                guard !showingTranscript, let id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
            .onChange(of: analysisMessages.last?.text) { _, _ in
                guard !showingTranscript, let id = analysisMessages.last?.id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let item {
                    VStack(spacing: 0) {
                        if !showingTranscript { analysisComposer(item) }
                        playbackPanel(item)
                    }
                }
            }
        }
        .onAppear { if let item { store.preparePlayback(item) } }
        .onChange(of: item?.audioFileNames) { _, _ in if let item { store.preparePlayback(item) } }
        .task(id: recordingID) {
            while store.workingID == recordingID && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, let item = store.recording(recordingID), shouldAutoTranscribe(item) else { return }
            await store.transcribe(item, model: selectedModel)
        }
        .navigationTitle("录音详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { store.prepareSupplement(for: recordingID); dismiss() } label: {
                        Label("补录到这条录音", systemImage: "waveform.badge.plus")
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("删除录音", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("录音操作")
            }
        }
        .confirmationDialog("删除这条录音？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除录音", role: .destructive) { if let item { store.delete(item) } }
            Button("取消", role: .cancel) {}
        } message: { Text("音频、转写和分析都会从本机移除。") }
        .alert("录音提示", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .alert("分析提示", isPresented: Binding(get: { analysisError != nil }, set: { if !$0 { analysisError = nil } })) {
            Button("好", role: .cancel) { analysisError = nil }
        } message: { Text(analysisError ?? "") }
        .sheet(isPresented: $showingModelPicker) {
            NavigationStack {
                RecordingTranscriptionModelPicker(selection: selectedModelBinding)
            }
        }
    }

    private func transcriptPanel(_ item: VoiceRecording) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("转写文字")
                .font(.system(size: 20, weight: .semibold, design: .serif)).foregroundStyle(AppTheme.ink)

            HStack(spacing: 10) {
                Button {
                    Task { await store.transcribe(item, model: selectedModel) }
                } label: {
                    Label(isWorking ? "处理中…" : "重新生成", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 11)
                        .foregroundStyle(.white).background(AppTheme.pine, in: Capsule())
                }
                .disabled(isWorking)
                Button { showingModelPicker = true } label: {
                    Label("选择模型", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 11)
                        .foregroundStyle(AppTheme.pine).background(AppTheme.sage, in: Capsule())
                }
            }
            .buttonStyle(.plain)

            if isWorking, !store.workingMessage.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().tint(AppTheme.pine)
                    Text(store.workingMessage).font(.caption).foregroundStyle(AppTheme.secondary)
                }
            }

            Divider().overlay(AppTheme.line)
            VStack(alignment: .leading, spacing: 10) {
                Text("概览").font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(AppTheme.ink)
                currentModelOverview
                Text("说话人分离和声线估计在本机完成；首次使用会下载约 41 MB 模型。")
                    .font(.caption).foregroundStyle(AppTheme.secondary)
                if item.speakerProfiles.isEmpty {
                    if let count = item.speakerCount {
                        Text("已区分 \(count) 位说话人；重新分析可生成讲话占比和声线估计。")
                            .font(.caption).foregroundStyle(AppTheme.secondary)
                    } else {
                        Text("尚未区分说话人。生成本机时间轴后，可查看人数、讲话占比和声线估计。")
                            .font(.caption).foregroundStyle(AppTheme.secondary)
                    }
                    if !item.transcript.isEmpty {
                        Button {
                            Task { await store.distinguishSpeakers(item) }
                        } label: {
                            Label("区分说话人并生成时间轴", systemImage: "person.2.wave.2")
                                .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.pine)
                        }
                        .disabled(isWorking)
                    }
                } else {
                    Text("检测到 \(item.speakerProfiles.count) 位说话人")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.ink)
                    let totalSpeech = item.speakerProfiles.reduce(0) { $0 + $1.speechDuration }
                    ForEach(item.speakerProfiles) { profile in
                        let share = totalSpeech > 0 ? profile.speechDuration / totalSpeech : 0
                        HStack(spacing: 8) {
                            Text(profile.label).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.pine).frame(width: 54, alignment: .leading)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(AppTheme.line)
                                    Capsule().fill(AppTheme.pine).frame(width: geometry.size.width * CGFloat(share))
                                }
                            }
                            .frame(height: 5)
                            Text("\(Int((share * 100).rounded()))% · \(playerTimeText(profile.speechDuration))")
                                .font(.caption.monospacedDigit()).foregroundStyle(AppTheme.secondary)
                            Text(profile.voiceEstimate.title)
                                .font(.caption2.weight(.medium)).foregroundStyle(AppTheme.secondary)
                        }
                    }
                    Text("声线按本机音高范围粗略估计，不代表说话人的真实性别。")
                        .font(.caption2).foregroundStyle(AppTheme.secondary)
                    Button {
                        Task { await store.distinguishSpeakers(item) }
                    } label: {
                        Label("重新区分说话人", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.pine)
                    }
                    .disabled(isWorking)
                }
            }

            Divider().overlay(AppTheme.line)
            VStack(alignment: .leading, spacing: 8) {
                Text("具体转写").font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(AppTheme.ink)
                if item.transcriptLines.isEmpty, item.speakerTranscript == nil, !item.transcript.isEmpty,
                   selectedModel == .configuredService {
                    Text("自定义服务没有提供时间戳。生成说话人时间轴后，可逐句点击定位播放。")
                        .font(.caption).foregroundStyle(AppTheme.secondary)
                }
                if item.transcriptForAnalysis.isEmpty {
                    Text("还没有转写文字。开始转写后，全文会显示在这里。")
                        .font(.subheadline).foregroundStyle(AppTheme.secondary)
                } else {
                    let lines = timelineLines(for: item)
                    if lines.isEmpty {
                        Text(item.speakerTranscript ?? item.transcript)
                            .font(.system(size: 15)).foregroundStyle(AppTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    } else {
                        ForEach(lines) { line in
                            Button {
                                store.play(item, from: line.start)
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(alignment: .top, spacing: 9) {
                                        Text(playerTimeText(line.start))
                                            .font(.caption2.monospacedDigit().weight(.medium)).foregroundStyle(AppTheme.pine)
                                            .frame(width: 42, alignment: .leading)
                                        Text("\(speakerLabel(line.speakerID, item: item))：\(line.text)")
                                            .font(.system(size: 15)).foregroundStyle(AppTheme.ink)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    GeometryReader { geometry in
                                        let trackWidth = geometry.size.width
                                        let duration = max(max(item.duration, store.playbackDuration), 0.1)
                                        let start = min(trackWidth, trackWidth * CGFloat(line.start / duration))
                                        let width = max(5, min(trackWidth - start, trackWidth * CGFloat(max(0.08, line.end - line.start) / duration)))
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(AppTheme.line)
                                            Capsule().fill(activeLineID == line.id ? AppTheme.terracotta : AppTheme.pine)
                                                .frame(width: width).offset(x: start)
                                            if store.playingID == item.id {
                                                Capsule().fill(AppTheme.terracotta)
                                                    .frame(width: 2, height: 8)
                                                    .offset(x: min(trackWidth - 2, max(0, trackWidth * CGFloat(store.playbackCurrentTime / duration))))
                                            }
                                        }
                                    }
                                    .frame(height: 3).padding(.leading, 51)
                                }
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(activeLineID == line.id ? AppTheme.sage.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .id(line.id)
                            Divider().overlay(AppTheme.line.opacity(0.7))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var currentModelOverview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(selectedModel.title, systemImage: selectedModel == .configuredService ? "cloud" : "iphone")
                .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.pine)
            Text(selectedModel.detail).font(.caption).foregroundStyle(AppTheme.secondary)
            if selectedModel == .configuredService, let config = modelRegistry.selected(.recordingTranscription) {
                Text("\(config.provider) · \(config.modelID) · \(config.execution.title)")
                    .font(.caption).foregroundStyle(AppTheme.secondary)
            }
            Text(selectedModel == .configuredService
                 ? "自定义服务负责音频识别；时间轴和说话人分析仍在本机完成。"
                 : "实时字幕固定使用 Apple Speech；说话人分离和声线估计在本机完成。")
                .font(.caption).foregroundStyle(AppTheme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timelineLines(for item: VoiceRecording) -> [RecordingTranscriptLine] {
        if !item.transcriptLines.isEmpty { return item.transcriptLines }
        guard let speakerTranscript = item.speakerTranscript else { return [] }
        var result: [RecordingTranscriptLine] = []
        for rawLine in speakerTranscript.components(separatedBy: .newlines) {
            guard let close = rawLine.firstIndex(of: "]"), rawLine.first == "[" else { continue }
            let timeText = String(rawLine[rawLine.index(after: rawLine.startIndex)..<close])
            let parts = timeText.split(separator: ":").compactMap { Double($0) }
            guard parts.count >= 2 else { continue }
            let start = parts.count == 2 ? parts[0] * 60 + parts[1] : parts[0] * 3600 + parts[1] * 60 + parts[2]
            let content = rawLine[rawLine.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard let separator = content.firstIndex(where: { $0 == "：" || $0 == ":" }) else { continue }
            let label = content[..<separator].trimmingCharacters(in: .whitespaces)
            let text = content[content.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            let speakerID = label.range(of: "说话人 ") == nil ? nil : Int(label.filter(\.isNumber)).map { $0 - 1 }
            let lineID = UUID(uuidString: String(format: "00000000-0000-0000-%04X-%012llX", result.count & 0xffff, UInt64(max(0, start * 1000))))!
            result.append(RecordingTranscriptLine(id: lineID, start: start, end: start + 2, speakerID: speakerID, text: text))
        }
        for index in result.indices where index + 1 < result.count {
            result[index].end = max(result[index].start + 0.2, result[index + 1].start)
        }
        return result
    }

    private func speakerLabel(_ id: Int?, item: VoiceRecording) -> String {
        guard let id else { return "未区分" }
        return item.speakerProfiles.first(where: { $0.id == id })?.label ?? "说话人 \(id + 1)"
    }

    private func analysisPanel(_ item: VoiceRecording) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("录音分析").font(.system(size: 20, weight: .semibold, design: .serif)).foregroundStyle(AppTheme.ink)
                    Text("围绕这段录音继续提问")
                        .font(.caption).foregroundStyle(AppTheme.secondary)
                }
                Spacer()
                NavigationLink { RecordingModelsView() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.pine)
                        .frame(width: 34, height: 34).background(AppTheme.sage, in: Circle())
                }
                .accessibilityLabel("设置分析模型")
                Button {
                    do {
                        try store.saveAnalysisArchive(for: item, messages: analysisMessages)
                        analysisSaved = true
                    } catch { analysisError = error.localizedDescription }
                } label: {
                    Label(analysisSaved ? "已保存" : "保存此次转写和分析", systemImage: analysisSaved ? "checkmark" : "square.and.arrow.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(analysisSaved ? AppTheme.secondary : AppTheme.pine)
                }
                .disabled(analysisSaved || isAnalyzing || !analysisMessages.contains(where: { $0.role == .assistant && !$0.text.isEmpty }))
            }

            if item.transcriptForAnalysis.isEmpty || item.hasUntranscribedSupplement {
                Text("先完成这条录音及补录的转写，再开始分析。")
                    .font(.subheadline).foregroundStyle(AppTheme.secondary)
            } else if analysisMessages.isEmpty {
                Text("正在准备对话…")
                    .font(.subheadline).foregroundStyle(AppTheme.secondary)
            } else {
                ForEach(analysisMessages) { message in
                    analysisMessageRow(message)
                        .id(message.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func analysisMessageRow(_ message: RecordingAnalysisMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 5) {
                Text(message.role == .user ? "你" : "录音助手")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(message.role == .user ? AppTheme.pine : AppTheme.secondary)
                Text(message.text.isEmpty ? "正在组织回答…" : message.text)
                    .font(.system(size: 15))
                    .foregroundStyle(message.text.isEmpty ? AppTheme.secondary : AppTheme.ink)
                    .textSelection(.enabled)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(message.role == .user ? AppTheme.sage : AppTheme.surface,
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(message.role == .user ? .clear : AppTheme.line, lineWidth: 1)
            }
            if message.role == .assistant { Spacer(minLength: 36) }
        }
    }

    private func analysisComposer(_ item: VoiceRecording) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("继续问这段录音…", text: $analysisDraft, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 15))
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .onSubmit { submitAnalysisDraft(for: item) }
            Button { submitAnalysisDraft(for: item) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(AppTheme.pine, in: Circle())
            }
            .disabled(isAnalyzing || analysisDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.transcriptForAnalysis.isEmpty || item.hasUntranscribedSupplement)
            .opacity(isAnalyzing ? 0.6 : 1)
        }
        .padding(.horizontal, 15).padding(.top, 9).padding(.bottom, 8)
        .background(AppTheme.surface)
        .overlay(alignment: .top) { Rectangle().fill(AppTheme.line).frame(height: 1) }
    }

    private func submitAnalysisDraft(for item: VoiceRecording) {
        let prompt = analysisDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        analysisDraft = ""
        sendAnalysisPrompt(prompt, for: item)
    }

    private func sendAnalysisPrompt(_ prompt: String, for item: VoiceRecording) {
        guard !isAnalyzing else { return }
        let userMessage = RecordingAnalysisMessage(role: .user, text: prompt)
        analysisMessages.append(userMessage)
        let requestConversation = analysisMessages
        let reply = RecordingAnalysisMessage(role: .assistant, text: "")
        analysisMessages.append(reply)
        isAnalyzing = true
        analysisSaved = false
        Task {
            do {
                let output = try await store.analyze(item, conversation: requestConversation, onProgress: { partial in
                    guard let index = analysisMessages.firstIndex(where: { $0.id == reply.id }) else { return }
                    analysisMessages[index].text = partial
                })
                if let index = analysisMessages.firstIndex(where: { $0.id == reply.id }) {
                    analysisMessages[index].text = output
                }
            } catch {
                analysisMessages.removeAll { $0.id == reply.id }
                analysisError = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func shouldAutoTranscribe(_ item: VoiceRecording) -> Bool {
        if item.hasUntranscribedSupplement { return true }
        let transcript = item.transcriptForAnalysis.trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty { return true }
        return item.duration >= 45 && transcript.count <= 28
    }

    private func playbackPanel(_ item: VoiceRecording) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 14) {
                Button { store.togglePlayback(item) } label: {
                    Image(systemName: store.playbackIsPlaying && store.playingID == item.id ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(AppTheme.pine, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.playbackIsPlaying && store.playingID == item.id ? "暂停" : "播放")

                VStack(spacing: 0) {
                    Slider(value: Binding(
                        get: { isScrubbing ? scrubberValue : store.playbackCurrentTime },
                        set: { scrubberValue = $0 }
                    ), in: 0...max(store.playbackDuration, 0.1), onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing { store.seekPlayback(to: scrubberValue) }
                        else { scrubberValue = store.playbackCurrentTime }
                    })
                    .tint(AppTheme.pine)
                    HStack {
                        Text(playerTimeText(isScrubbing ? scrubberValue : store.playbackCurrentTime))
                        Spacer()
                        Text(playerTimeText(store.playbackDuration))
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(AppTheme.secondary)
                }

                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button("\(rate.formatted(.number.precision(.fractionLength(0...2))))×") {
                            store.setPlaybackRate(Float(rate))
                        }
                    }
                } label: {
                    Text("\(store.playbackRate.formatted(.number.precision(.fractionLength(0...2))))×")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(AppTheme.pine)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(AppTheme.sage, in: Capsule())
                }
                .accessibilityLabel("播放速度")
            }
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 7)
        .background(AppTheme.surface)
        .overlay(alignment: .top) { Rectangle().fill(AppTheme.line).frame(height: 1) }
    }

    private func playerTimeText(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
        return RecordingView.timeText(seconds)
    }
}

private struct RecordingAnalysisArchiveDetail: View {
    let archive: RecordingAnalysisArchive

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    AccentLabel(title: "分析历史")
                    Text(archive.title)
                        .font(.system(size: 25, weight: .semibold, design: .serif)).foregroundStyle(AppTheme.ink)
                    Text("\(archive.recordingCreatedAt.formatted(date: .complete, time: .shortened)) · \(RecordingView.timeText(Int(archive.duration))) · 保存于 \(archive.savedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(AppTheme.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("转写内容").font(.system(size: 19, weight: .semibold, design: .serif)).foregroundStyle(AppTheme.ink)
                    Text(archive.transcript)
                        .font(.system(size: 15)).foregroundStyle(AppTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .padding(14)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(AppTheme.line, lineWidth: 1) }
                }

                Divider().overlay(AppTheme.line)

                VStack(alignment: .leading, spacing: 12) {
                    Text("分析对话").font(.system(size: 19, weight: .semibold, design: .serif)).foregroundStyle(AppTheme.ink)
                    ForEach(archive.messages) { message in
                        HStack {
                            if message.role == .user { Spacer(minLength: 36) }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role == .user ? "你" : "录音助手")
                                    .font(.caption2.weight(.semibold)).foregroundStyle(AppTheme.secondary)
                                Text(message.text).font(.system(size: 15)).foregroundStyle(AppTheme.ink).textSelection(.enabled)
                            }
                            .padding(13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(message.role == .user ? AppTheme.sage : AppTheme.surface,
                                        in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(AppTheme.line, lineWidth: message.role == .user ? 0 : 1) }
                            if message.role == .assistant { Spacer(minLength: 36) }
                        }
                    }
                }
            }
            .padding(20).padding(.bottom, 36)
        }
        .background(AppTheme.canvas.ignoresSafeArea())
        .navigationTitle("分析历史")
        .navigationBarTitleDisplayMode(.inline)
    }
}
