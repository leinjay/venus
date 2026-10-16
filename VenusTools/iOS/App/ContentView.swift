import SwiftUI

struct ContentView: View {
    @StateObject private var focusStore = FocusTimerStore()
    @StateObject private var checklistStore = ChecklistStore()
    @StateObject private var reminderStore = ReminderStore()

    var body: some View {
        TabView {
            NavigationStack {
                FocusView(store: focusStore)
            }
            .tabItem {
                Label("专注", systemImage: "timer")
            }

            NavigationStack {
                ConverterView()
            }
            .tabItem {
                Label("换算", systemImage: "arrow.left.arrow.right")
            }

            NavigationStack {
                ChecklistView(store: checklistStore)
            }
            .tabItem {
                Label("清单", systemImage: "checklist")
            }

            NavigationStack {
                RemindersView(store: reminderStore)
            }
            .tabItem {
                Label("提醒", systemImage: "bell")
            }
        }
        .tint(AppTheme.pine)
        .preferredColorScheme(.light)
    }
}
