import SwiftUI

enum SettingsRoute: Hashable { case models }

@MainActor
final class AppNavigation: ObservableObject {
    @Published var selectedTab = 0
    @Published var settingsPath: [SettingsRoute] = []
    @Published private(set) var returnTab: Int?
    private var returnAction: (() -> Void)?
    func openModels(onReturn: (() -> Void)? = nil) {
        if selectedTab != 2 { returnTab = selectedTab; returnAction = onReturn }
        settingsPath = [.models]; selectedTab = 2
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
                .tag(2)
        }
        .id(skin)
        .environmentObject(navigation)
        .onAppear { reminderStore.updateWatchRecordingTargets(recordingStore.watchRecordingTargets) }
        .onChange(of: recordingStore.watchRecordingTargets) { _, targets in reminderStore.updateWatchRecordingTargets(targets) }
        .onChange(of: reminderStore.notificationTaskID) { _, id in if id != nil { navigation.selectedTab = 0 } }
        .tint(AppTheme.pine)
        .preferredColorScheme(.light)
    }
}
