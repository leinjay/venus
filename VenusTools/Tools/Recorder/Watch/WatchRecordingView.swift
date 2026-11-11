import SwiftUI

struct WatchRecordingView: View {
    @ObservedObject var store: WatchRecordingStore
    @ObservedObject var reminderStore: WatchReminderStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").foregroundStyle(AppTheme.pine)
                    Text("随身录音").font(.system(size: 19, weight: .semibold, design: .serif)).foregroundStyle(AppTheme.ink)
                }.frame(maxWidth: .infinity, alignment: .leading)

                NavigationLink {
                    WatchRecordingTargetPicker(reminderStore: reminderStore)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: reminderStore.selectedRecordingTargetID == nil ? "plus.circle" : "waveform.badge.plus")
                        Text(reminderStore.selectedRecordingTargetTitle.map { "补录到：\($0)" } ?? "新建独立录音")
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .font(.caption).foregroundStyle(AppTheme.pine)
                    .padding(10).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(store.isRecording || store.isStarting)

                Text(timeText(store.seconds))
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .monospacedDigit().foregroundStyle(AppTheme.ink)

                HStack(alignment: .center, spacing: 4) {
                    ForEach(0..<9, id: \.self) { index in
                        Capsule().fill(store.isRecording ? AppTheme.terracotta : AppTheme.pine.opacity(0.36))
                            .frame(width: 4, height: CGFloat(5 + min(1, store.level * Double((index % 4) + 1)) * 20))
                    }
                }.frame(height: 26)

                if store.isRecording {
                    HStack(spacing: 9) {
                        Button { store.togglePause() } label: {
                            Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 43, height: 43).foregroundStyle(AppTheme.pine)
                                .background(AppTheme.sage, in: Circle())
                        }.buttonStyle(.plain).accessibilityLabel(store.isPaused ? "继续录音" : "暂停录音")
                        Button { store.stop(using: reminderStore) } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 52, height: 52).foregroundStyle(.white)
                                .background(AppTheme.terracotta, in: Circle())
                        }.buttonStyle(.plain).accessibilityLabel("结束并传输录音")
                    }
                } else {
                    Button { Task { await store.start(using: reminderStore) } } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "record.circle")
                            Text(store.isStarting ? "正在准备" : "开始录音").fontWeight(.semibold)
                        }
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .foregroundStyle(.white).background(AppTheme.pine, in: Capsule())
                    }
                    .buttonStyle(.plain).disabled(store.isStarting)
                }

                Text(store.isRecording ? (store.isPaused ? "已暂停" : "录音中") : store.message)
                    .font(.caption2).foregroundStyle(AppTheme.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)

                Text(reminderStore.recordingSyncMessage)
                    .font(.caption2).foregroundStyle(AppTheme.pine)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 10)
        }
        .foregroundStyle(AppTheme.ink)
        .background(AppTheme.canvas.ignoresSafeArea())
        .containerBackground(AppTheme.canvas, for: .navigation)
        .navigationTitle("录音")
        .alert("录音提示", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private func timeText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct WatchRecordingTargetPicker: View {
    @ObservedObject var reminderStore: WatchReminderStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    reminderStore.selectRecordingTarget(nil)
                    dismiss()
                } label: {
                    targetRow(title: "新建独立录音", subtitle: "单独保存为一条录音", selected: reminderStore.selectedRecordingTargetID == nil)
                }.buttonStyle(.plain)

                ForEach(reminderStore.recordingTargets) { item in
                    Button {
                        reminderStore.selectRecordingTarget(item.id)
                        dismiss()
                    } label: {
                        targetRow(title: item.title,
                                  subtitle: "\(item.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(timeText(Int(item.duration)))",
                                  selected: reminderStore.selectedRecordingTargetID == item.id)
                    }.buttonStyle(.plain)
                }

                if reminderStore.recordingTargets.isEmpty {
                    Text("手机录音清单同步后，可选择一条录音进行补录。")
                        .font(.caption2).foregroundStyle(AppTheme.secondary).padding(.vertical, 8)
                    Button { reminderStore.requestSync() } label: {
                        Label("同步手机录音清单", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                            .foregroundStyle(.white).background(AppTheme.pine, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 8).padding(.vertical, 6)
        }
        .foregroundStyle(AppTheme.ink)
        .background(AppTheme.canvas.ignoresSafeArea())
        .containerBackground(AppTheme.canvas, for: .navigation)
        .navigationTitle("选择补录目标")
    }

    private func targetRow(title: String, subtitle: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark.circle.fill" : "waveform.circle")
                .foregroundStyle(selected ? AppTheme.pine : AppTheme.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold)).lineLimit(2)
                Text(subtitle).font(.caption2).foregroundStyle(AppTheme.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(9)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func timeText(_ seconds: Int) -> String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}
