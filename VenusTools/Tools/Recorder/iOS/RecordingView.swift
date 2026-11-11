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
            .navigationTitle("录音分析")
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

private struct RecordingModelsView: View {
    var body: some View {
        List {
            Section {
                Text("实时字幕优先使用 iPhone 本机的普通话离线识别。只有你点击转写或分析时，所选模型才会接收对应录音或文字。")
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

private struct RecordingDetailView: View {
    @ObservedObject var store: RecordingStore
    let recordingID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var showingTranscript = false
    @State private var selectedTab: RecordingDetailTab = .transcript
    @State private var isScrubbing = false
    @State private var scrubberValue: TimeInterval = 0

    private var item: VoiceRecording? { store.recording(recordingID) }
    private var isWorking: Bool { store.workingID == recordingID }

    var body: some View {
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
                        store.prepareSupplement(for: item.id)
                        dismiss()
                    } label: {
                        Label("补录到这条录音", systemImage: "waveform.badge.plus")
                            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .foregroundStyle(AppTheme.pine).background(AppTheme.sage, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Picker("录音内容", selection: $selectedTab) {
                        ForEach(RecordingDetailTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(AppTheme.pine)

                    if selectedTab == .transcript {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let item { playbackPanel(item) }
        }
        .onAppear { if let item { store.preparePlayback(item) } }
        .onChange(of: item?.audioFileNames) { _, _ in if let item { store.preparePlayback(item) } }
        .navigationTitle("录音详情")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除这条录音？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除录音", role: .destructive) { if let item { store.delete(item) } }
            Button("取消", role: .cancel) {}
        } message: { Text("音频、转写和分析都会从本机移除。") }
        .alert("录音提示", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .sheet(isPresented: $showingTranscript) {
            if let item { RecordingTranscriptSheet(text: item.speakerTranscript ?? item.transcript) }
        }
    }

    private func transcriptPanel(_ item: VoiceRecording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("转写文字").font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(AppTheme.ink)
                Text("本机离线识别或已配置的转写模型")
                    .font(.caption).foregroundStyle(AppTheme.secondary)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Button(isWorking ? "处理中…" : (item.hasUntranscribedSupplement ? "转写补录" : (item.transcript.isEmpty ? "开始转写" : "重新转写"))) {
                        Task { await store.transcribe(item) }
                    }
                    .font(.caption.weight(.semibold)).disabled(isWorking)
                    Button(item.speakerTranscript == nil ? "区分说话人" : "重新区分") {
                        Task { await store.distinguishSpeakers(item) }
                    }
                    .font(.caption.weight(.semibold)).disabled(isWorking)
                }
            }
            .buttonStyle(.plain)
            if isWorking, !store.workingMessage.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().tint(AppTheme.pine)
                    Text(store.workingMessage).font(.caption).foregroundStyle(AppTheme.secondary)
                }
            }
            if item.transcriptForAnalysis.isEmpty {
                Text("还没有转写文字。开始转写后，全文会显示在这里。")
                    .font(.subheadline).foregroundStyle(AppTheme.secondary)
            } else {
                Button { showingTranscript = true } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let count = item.speakerCount {
                            Label("已区分 \(count) 位说话人", systemImage: "person.2.wave.2")
                                .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.pine)
                        }
                        Text(item.speakerTranscript ?? item.transcript)
                            .font(.system(size: 15)).foregroundStyle(AppTheme.ink)
                            .lineLimit(10).frame(maxWidth: .infinity, alignment: .leading)
                        Label("点按查看全文", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption).foregroundStyle(AppTheme.pine)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Label("人数由模型自动估计；录音后在本机识别，首次联网下载约 41 MB，音频不会上传。", systemImage: "lock.shield")
                .font(.caption2).foregroundStyle(AppTheme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).surfaceCard()
    }

    private func analysisPanel(_ item: VoiceRecording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("录音分析").font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(AppTheme.ink)
                    Text("摘要、主题、决定与行动项")
                        .font(.caption).foregroundStyle(AppTheme.secondary)
                }
                Spacer()
                Button(isWorking ? "整理中…" : "生成分析") { Task { await store.analyze(item) } }
                    .font(.caption.weight(.semibold)).disabled(isWorking || item.transcriptForAnalysis.isEmpty || item.hasUntranscribedSupplement)
            }
            if item.summary.isEmpty {
                Text(isWorking && !store.workingMessage.isEmpty ? store.workingMessage : "完成转写后生成分析结果。")
                    .font(.subheadline).foregroundStyle(AppTheme.secondary)
            } else {
                Text(item.summary).font(.system(size: 15)).foregroundStyle(AppTheme.ink).textSelection(.enabled)
            }
            NavigationLink("管理录音分析模型") { RecordingModelsView() }
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading).surfaceCard()
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

private enum RecordingDetailTab: String, CaseIterable, Identifiable, Hashable {
    case transcript
    case analysis
    var id: String { rawValue }
    var title: String { self == .transcript ? "转写文字" : "录音分析" }
}

private struct RecordingTranscriptSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 16))
                    .foregroundStyle(AppTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(20)
            }
            .background(AppTheme.canvas.ignoresSafeArea())
            .navigationTitle("转写全文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}
