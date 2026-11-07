import SwiftUI

struct TaskExecutionCalendarView: View {
    @ObservedObject var store: ReminderStore
    let taskID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var month = Date()
    @State private var selectedDate = Date()
    @State private var now = Date()
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        return calendar
    }
    private var monthInterval: DateInterval { calendar.dateInterval(of: .month, for: month)! }
    private var days: [Date] {
        let interval = monthInterval
        return (0..<(calendar.range(of: .day, in: .month, for: month)?.count ?? 0)).compactMap {
            calendar.date(byAdding: .day, value: $0, to: interval.start)
        }
    }
    private var leadingDays: Int { (calendar.component(.weekday, from: monthInterval.start) + 5) % 7 }
    private var entries: [TaskExecutionEntry] {
        guard let task = store.item(taskID) else { return [] }
        return TaskExecutionHistory.entries(task: task, records: store.executions(taskID), in: monthInterval, now: now, calendar: calendar)
    }
    private var grouped: [Date: [TaskExecutionEntry]] {
        Dictionary(grouping: entries) { calendar.startOfDay(for: $0.scheduledAt) }
    }
    private func color(_ status: TaskExecutionEntry.Status) -> Color {
        switch status {
        case .completed: return .green
        case .overdue: return .red
        case .pending: return AppTheme.amber
        case .planned: return AppTheme.pine
        case .rescheduled: return AppTheme.secondary
        }
    }
    private func formatted(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    private func changeMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: monthInterval.start) else { return }
        month = next
        selectedDate = next
    }
    private func dayCell(_ day: Date, records: [TaskExecutionEntry]) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: selectedDate)
        let statuses = TaskExecutionEntry.Status.allCases.filter { status in records.contains { $0.status == status } }
        return Button { selectedDate = day } label: {
            VStack(spacing: 5) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(calendar.isDateInToday(day) ? .bold : .regular))
                HStack(spacing: 3) {
                    ForEach(statuses.prefix(3), id: \.self) { status in
                        Circle().fill(color(status)).frame(width: 5, height: 5)
                    }
                }.frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(AppTheme.ink)
            .background(selected ? AppTheme.sage : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(selected ? AppTheme.pine : .clear) }
        }.buttonStyle(.plain)
            .accessibilityLabel("\(formatted(day, format: "M月d日"))，\(records.count) 次执行，\(statuses.map(\.title).joined(separator: "，"))")
    }
    private func executionRow(_ entry: TaskExecutionEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(formatted(entry.scheduledAt, format: "HH:mm")).font(.headline)
                Spacer()
                AccentLabel(title: entry.status.title, color: color(entry.status))
            }
            Text("计划执行 \(formatted(entry.scheduledAt, format: "yyyy年M月d日 HH:mm"))")
            if let completed = entry.completedAt {
                Text("实际完成 \(formatted(completed, format: "yyyy年M月d日 HH:mm"))")
            } else if entry.status == .completed {
                Text("历史完成时间未知")
            }
            if let source = entry.source { Text(source).foregroundStyle(AppTheme.secondary) }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).surfaceCard(padding: 14)
    }
    var body: some View {
        let daysToEntries = grouped
        let selected = daysToEntries[calendar.startOfDay(for: selectedDate)] ?? []
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let task = store.item(taskID) {
                        Text(task.title).font(.headline)
                        Text(task.schedule.recurrenceLabel).font(.caption).foregroundStyle(AppTheme.secondary)
                    }
                    VStack(spacing: 12) {
                        HStack {
                            Button { changeMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("上个月")
                            Spacer()
                            Text(formatted(month, format: "yyyy年M月")).font(.headline)
                            Spacer()
                            Button { changeMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("下个月")
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.caption).foregroundStyle(AppTheme.secondary) }
                            ForEach(0..<leadingDays, id: \.self) { _ in Color.clear.frame(height: 44) }
                            ForEach(days, id: \.self) { day in dayCell(day, records: daysToEntries[calendar.startOfDay(for: day)] ?? []) }
                        }
                    }.surfaceCard(padding: 12)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(TaskExecutionEntry.Status.allCases, id: \.self) { status in
                                Label { Text(status.title) } icon: { Circle().fill(color(status)).frame(width: 6, height: 6) }
                            }
                        }.font(.caption2).foregroundStyle(AppTheme.secondary)
                    }
                    Text("\(formatted(selectedDate, format: "M月d日")) · \(selected.count) 次执行").font(.headline)
                    if selected.isEmpty { Text("当天没有执行计划或记录").foregroundStyle(AppTheme.secondary).font(.subheadline) }
                    ForEach(selected) { executionRow($0) }
                    Text("按计划执行日期归档，完成时间单独记录。升级前仅恢复仍保留的历史记录。")
                        .font(.caption2).foregroundStyle(AppTheme.secondary)
                }.padding(16)
            }
            .background(AppTheme.canvas)
            .navigationTitle("执行日历").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("今天") { now = Date(); month = now; selectedDate = now }
                }
                ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } }
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
    }
}
