import SwiftUI

enum SettingsRoute: Hashable { case models }

@MainActor
final class AppNavigation: ObservableObject {
    @Published var selectedTab = 0
    @Published var settingsPath: [SettingsRoute] = []
    @Published private(set) var returnTab: Int?
    private var returnAction: (() -> Void)?
    func openModels(onReturn: (() -> Void)? = nil) {
        if selectedTab != 4 { returnTab = selectedTab; returnAction = onReturn }
        settingsPath = [.models]; selectedTab = 4
    }
    func returnFromSettings() {
        let tab = returnTab, action = returnAction
        returnTab = nil; returnAction = nil; settingsPath = []
        if let tab { selectedTab = tab }
        action?()
    }
}

struct ContentView: View {
    @StateObject private var navigation = AppNavigation()
    @StateObject private var focusStore = FocusTimerStore()
    @StateObject private var checklistStore = ChecklistStore()
    @StateObject private var reminderStore = ReminderStore()

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            RemindersView(store: reminderStore)
                .tabItem { Label("任务", systemImage: "bell") }
                .tag(0)
            NavigationStack {
                FocusView(store: focusStore)
            }
            .tabItem {
                Label("专注", systemImage: "timer")
            }
            .tag(1)

            NavigationStack {
                ConverterView()
            }
            .tabItem {
                Label("换算", systemImage: "arrow.left.arrow.right")
            }
            .tag(2)

            NavigationStack {
                ChecklistView(store: checklistStore)
            }
            .tabItem {
                Label("清单", systemImage: "checklist")
            }
            .tag(3)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(4)
        }
        .environmentObject(navigation)
        .onChange(of: reminderStore.notificationTaskID) { _, id in if id != nil { navigation.selectedTab = 0 } }
        .tint(AppTheme.pine)
        .preferredColorScheme(.light)
    }
}
