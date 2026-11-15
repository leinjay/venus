import SwiftUI
import UIKit

enum SettingsRoute: Hashable { case models }

@MainActor
final class AppNavigation: ObservableObject {
    @Published var selectedTab = 0
    @Published var settingsPath: [SettingsRoute] = []
    @Published private(set) var returnTab: Int?
    private var returnAction: (() -> Void)?
    func openModels(onReturn: (() -> Void)? = nil) {
        if selectedTab != 3 { returnTab = selectedTab; returnAction = onReturn }
        settingsPath = [.models]; selectedTab = 3
    }
    func returnFromSettings() {
        let tab = returnTab, action = returnAction
        returnTab = nil; returnAction = nil; settingsPath = []
        if let tab { selectedTab = tab }
        action?()
    }
}

struct ContentView: View {
    @AppStorage(AppSkin.storageKey) private var skin = AppSkin.classic.rawValue
    @StateObject private var navigation = AppNavigation()
    @StateObject private var reminderStore = ReminderStore()
    @StateObject private var recordingStore = RecordingStore()
    @AppStorage("recording.transcription.bindingMigrated") private var recordingBindingMigrated = false
    @AppStorage("recording.transcription.fullAudioModel") private var previousRecordingModel = "appleSpeech"

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            RemindersView(store: reminderStore)
                .tabItem { Label("任务", systemImage: "bell") }
                .tag(0)
            RecordingView(store: recordingStore)
                .tabItem { Label("录音", systemImage: "waveform") }
                .tag(1)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .id(skin)
        .background(KeyboardOutsideTap().allowsHitTesting(false))
        .safeAreaInset(edge: .bottom, spacing: 0) { ModelDownloadBar() }
        .environmentObject(navigation)
        .onAppear {
            reminderStore.updateWatchRecordingTargets(recordingStore.watchRecordingTargets)
            if !recordingBindingMigrated {
                do {
                    if previousRecordingModel != "configuredService" {
                        try ModelRegistry.shared.bind(nil, to: .recordingTranscription)
                    }
                    recordingBindingMigrated = true
                } catch {
                    recordingStore.errorMessage = "录音模型设置迁移失败：\(error.localizedDescription)"
                }
            }
        }
        .onChange(of: recordingStore.watchRecordingTargets) { _, targets in reminderStore.updateWatchRecordingTargets(targets) }
        .onChange(of: reminderStore.notificationTaskID) { _, id in if id != nil { navigation.selectedTab = 0 } }
        .tint(AppTheme.pine)
        .preferredColorScheme(.light)
    }
}

private struct ModelDownloadBar: View {
    @ObservedObject private var speech = OfflineSpeechModels.shared
    @ObservedObject private var textModel = LocalQwenService.shared
    var body: some View {
        if !speech.progress.isEmpty || textModel.preparing {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(speech.progress.keys.sorted(), id: \.self) { id in
                    downloadRow(id == ModelConfiguration.senseVoiceID ? "SenseVoice" : "Qwen3 ASR",
                                progress: speech.progress[id] ?? 0, speed: speech.speed[id] ?? 0,
                                status: speech.downloadStatus[id] ?? "正在准备…")
                }
                if textModel.preparing {
                    downloadRow("Qwen3", progress: textModel.progress, speed: textModel.downloadSpeed, status: textModel.status)
                }
            }
            .padding(12).background(AppTheme.surface)
        }
    }
    private func downloadRow(_ name: String, progress: Double, speed: Double, status: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(name) · \(Int(progress * 100))%")
                Spacer()
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s")
                    .monospacedDigit()
            }.font(.caption)
            ProgressView(value: progress).progressViewStyle(.linear).tint(.blue)
            Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// A window observer also covers navigation destinations and presented sheets.
private struct KeyboardOutsideTap: UIViewRepresentable {
    func makeUIView(context: Context) -> Observer { Observer() }
    func updateUIView(_ uiView: Observer, context: Context) {}
    static func dismantleUIView(_ uiView: Observer, coordinator: ()) { uiView.detach() }

    final class Observer: UIView, UIGestureRecognizerDelegate {
        private lazy var tap: UITapGestureRecognizer = {
            let value = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            value.cancelsTouchesInView = false
            value.delaysTouchesEnded = false
            value.delegate = self
            return value
        }()
        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            window?.addGestureRecognizer(tap)
        }
        func detach() { tap.view?.removeGestureRecognizer(tap) }
        @objc private func dismissKeyboard() { window?.endEditing(true) }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
