import Foundation
import Combine
import WatchConnectivity

final class WatchReminderStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var reminders: [ReminderItem] = []
    @Published private(set) var syncMessage = "等待 iPhone 同步"
    private let storageKey = "venus.tools.watch.reminders.v1"
    private let session = WCSession.default

    override init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ReminderItem].self, from: data) {
            reminders = saved
        }
        super.init()
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
    }

    func toggle(_ item: ReminderItem) {
        guard let index = reminders.firstIndex(where: { $0.id == item.id }) else { return }
        reminders[index].isDone.toggle()
        persistAndSend()
    }

    private func persistAndSend() {
        guard let data = try? JSONEncoder().encode(reminders) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        guard WCSession.isSupported(), session.activationState == .activated else { return }
        do {
            try session.updateApplicationContext(["reminders": data])
            syncMessage = "已同步"
        } catch {
            syncMessage = "稍后重试同步"
        }
    }

    private func receiveSnapshot(_ context: [String: Any]) {
        guard let data = context["reminders"] as? Data,
              let incoming = try? JSONDecoder().decode([ReminderItem].self, from: data) else { return }
        DispatchQueue.main.async {
            guard incoming != self.reminders else { return }
            self.reminders = incoming
            UserDefaults.standard.set(data, forKey: self.storageKey)
            self.syncMessage = "已与 iPhone 同步"
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if error == nil, !self.reminders.isEmpty {
                self.syncMessage = "提醒已就绪"
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
}
