import Foundation
import Combine
import WatchConnectivity

final class ReminderStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var reminders: [ReminderItem] = []
    @Published private(set) var syncMessage = "提醒会在配对 Apple Watch 后同步"
    private let storageKey = "venus.tools.reminders.v1"
    private let session = WCSession.default

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ReminderItem].self, from: data) {
            reminders = saved
        } else {
            let now = Date()
            reminders = [
                ReminderItem(title: "喝水休息", dueAt: now.addingTimeInterval(60 * 60)),
                ReminderItem(title: "补充维生素", dueAt: now.addingTimeInterval(3 * 60 * 60)),
                ReminderItem(title: "给植物浇水", dueAt: now.addingTimeInterval(24 * 60 * 60))
            ]
            persist()
        }
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
    }

    func add(title: String, dueAt: Date) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        reminders.append(ReminderItem(title: value, dueAt: dueAt))
        saveAndSync()
    }

    func toggle(_ item: ReminderItem) {
        guard let index = reminders.firstIndex(where: { $0.id == item.id }) else { return }
        reminders[index].isDone.toggle()
        saveAndSync()
    }

    func remove(_ item: ReminderItem) {
        reminders.removeAll { $0.id == item.id }
        saveAndSync()
    }

    private func saveAndSync() {
        persist()
        syncMessage = "已保存 · 正在同步"
        sendCurrentSnapshot()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(reminders) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func sendCurrentSnapshot() {
        guard WCSession.isSupported(), session.activationState == .activated,
              let data = try? JSONEncoder().encode(reminders) else { return }
        do {
            try session.updateApplicationContext(["reminders": data])
            syncMessage = session.isPaired ? "已同步到 Apple Watch" : "提醒已保存，等待 Apple Watch 配对"
        } catch {
            syncMessage = "已保存在 iPhone，稍后重试同步"
        }
    }

    private func receiveSnapshot(_ context: [String: Any]) {
        guard let data = context["reminders"] as? Data,
              let incoming = try? JSONDecoder().decode([ReminderItem].self, from: data) else { return }
        DispatchQueue.main.async {
            guard incoming != self.reminders else { return }
            self.reminders = incoming
            self.persist()
            self.syncMessage = "已从 Apple Watch 更新"
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if error == nil {
                self.syncMessage = session.isPaired ? "Apple Watch 同步已就绪" : "提醒已保存，等待 Apple Watch 配对"
                self.sendCurrentSnapshot()
            } else {
                self.syncMessage = "提醒已保存在 iPhone"
            }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receiveSnapshot(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receiveSnapshot(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receiveSnapshot(userInfo)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
