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
