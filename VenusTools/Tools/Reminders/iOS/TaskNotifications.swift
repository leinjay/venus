import Foundation
import UserNotifications

/// Serial reconciliation keeps logical execution versions independent of time-zone recalculation.
actor TaskNotifications {
    private let center = UNUserNotificationCenter.current()
    private let ledgerURL: URL
    private var ledger: [String: Date]
    private var generation = 0
    private var running = false
    private var pending: (tasks: [ReminderItem], requestPermission: Bool)?

    init(directory: URL) {
        ledgerURL = directory.appendingPathComponent("notifications.json")
        ledger = (try? JSONDecoder().decode([String: Date].self, from: Data(contentsOf: ledgerURL))) ?? [:]
    }

    func reconcile(_ tasks: [ReminderItem], requestPermission: Bool) async -> String {
        generation += 1
        pending = (tasks, requestPermission || (pending?.requestPermission ?? false))
        guard !running else { return "正在更新通知" }
        running = true
        defer { running = false }
        var result = "正在更新通知"
        // Drain sequentially: an old suspended add must finish before the newest pass removes it.
        while let next = pending {
            pending = nil
            result = await apply(next.tasks, requestPermission: next.requestPermission)
        }
        return result
    }

    private func apply(_ tasks: [ReminderItem], requestPermission: Bool) async -> String {
        let current = generation
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined, requestPermission {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            settings = await center.notificationSettings()
        }
        guard current == generation else { return "正在更新通知" }
        let existing = await center.pendingNotificationRequests()
        guard current == generation else { return "正在更新通知" }
        let now = Date()
        let validVersions = Set(tasks.map { $0.notificationVersion.uuidString })
        ledger = ledger.filter { validVersions.contains($0.key) }
        let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        // Capacity is shared with other app notifications; leave non-task entries intact.
        let available = max(0, 64 - existing.filter { !$0.identifier.hasPrefix("task.") }.count)
        let planned = TaskRules.notificationPlan(tasks, after: now, limit: available + 1, ledger: ledger)
        let selected = Array(planned.prefix(available))
        center.removePendingNotificationRequests(withIdentifiers: existing.filter { $0.identifier.hasPrefix("task.") }.map(\.identifier))
        guard allowed else { return "通知权限未开启，任务已保存在本机" }
        var failures = 0
        for occurrence in selected {
            let item = occurrence.task
            guard current == generation else { return "正在更新通知" }
            let date = occurrence.date
            let content = UNMutableNotificationContent()
            let text = TaskRules.notificationText(item, hideDetails: UserDefaults.standard.bool(forKey: "tasks.hideNotificationTitle"))
            content.title = text.title
            content.body = text.body
            content.sound = .default
            content.userInfo = ["taskID": item.id.uuidString]
            var parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            parts.timeZone = Calendar.current.timeZone
            let request = UNNotificationRequest(identifier: occurrence.identifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            do {
                try await center.add(request)
                guard current == generation else { continue }
                ledger[item.notificationVersion.uuidString] = date
                try JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
            } catch { failures += 1 }
        }
        if failures > 0 { return "\(failures) 项通知未安排，请重试" }
        if planned.count > selected.count { return "已安排最近 \(selected.count) 次提醒 · 系统上限 64 条，打开 App 自动续排" }
        return "未来任务提醒已安排 · \(selected.count) 次"
    }
}
