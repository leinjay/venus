import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @StateObject private var focusStore = FocusTimerStore()
    @StateObject private var checklistStore = ChecklistStore()
    @StateObject private var reminderStore = ReminderStore()

    var body: some View {
        TabView(selection: $selectedTab) {
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
        }
        .onChange(of: reminderStore.notificationTaskID) { _, id in if id != nil { selectedTab = 0 } }
        .tint(AppTheme.pine)
        .preferredColorScheme(.light)
    }
}
