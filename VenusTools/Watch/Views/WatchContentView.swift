import SwiftUI

struct WatchContentView: View {
    @StateObject private var store = WatchReminderStore()

    private var sortedReminders: [ReminderItem] {
        store.reminders.sorted { $0.dueAt < $1.dueAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 7) {
                    Image(systemName: "leaf.fill").foregroundStyle(AppTheme.pine)
                    Text("RULELINE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(AppTheme.pine)
                    Spacer()
                    Image(systemName: "applewatch")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.secondary)
                }
                .padding(.top, 6)

                Text("今日提醒")
                    .font(.system(size: 23, weight: .semibold, design: .serif))
                    .foregroundStyle(AppTheme.ink)

                HStack(spacing: 9) {
                    Image(systemName: "sparkle").foregroundStyle(AppTheme.amber)
                    Text(store.syncMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.secondary)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))

                if sortedReminders.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "arrow.down.to.line").foregroundStyle(AppTheme.pine)
                        Text("提醒会从 iPhone 同步到这里。")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    ForEach(sortedReminders) { item in
                        Button {
                            store.toggle(item)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(item.isDone ? AppTheme.pine : AppTheme.amber)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(AppTheme.ink)
                                        .multilineTextAlignment(.leading)
                                    Text(item.dueAt.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 10))
                                        .foregroundStyle(AppTheme.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("点选一项即可标记完成")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .background(AppTheme.canvas.ignoresSafeArea())
    }
}
