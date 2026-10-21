import Foundation
import Combine
import WatchConnectivity

private struct PendingCompletion: Codable {
    var operation: CompletionOperation
    var sent = false
    var transferQueued = false
    var nextIntent: Bool?
}
private struct WatchTaskCache: Codable {
    var snapshot = TaskSnapshot(revision: -1, tasks: [])
    var pending: [String: PendingCompletion] = [:]
}

final class WatchReminderStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published private var cache = WatchTaskCache()
    @Published private(set) var syncMessage = "等待 iPhone 同步"
    private let session = WCSession.default
    private let key = "venus.tools.watch.tasks.v2"
    private var timer: AnyCancellable?
    var reminders: [ReminderItem] {
        cache.snapshot.tasks.map { item in
            var task = item
            if let pending = cache.pending[item.id.uuidString] { task.isDone = pending.nextIntent ?? pending.operation.isDone }
            return task
        }
    }
    func isPending(_ id: UUID) -> Bool { cache.pending[id.uuidString] != nil }

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(WatchTaskCache.self, from: data) { cache = value }
        if WCSession.isSupported() { session.delegate = self; session.activate() }
        timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, !self.cache.pending.isEmpty else { return }
            self.syncMessage = "待同步 · 手机提醒可能尚未取消"
            self.sendPending()
        }
    }

    func toggle(_ item: ReminderItem) {
        guard let base = cache.snapshot.tasks.first(where: { $0.id == item.id }) else { return }
        let desired = !item.isDone, key = item.id.uuidString
        if var pending = cache.pending[key] {
            if pending.sent { pending.nextIntent = desired == pending.operation.isDone ? nil : desired; cache.pending[key] = pending }
            else if desired == base.isDone { cache.pending.removeValue(forKey: key) }
            else { pending.operation.isDone = desired; cache.pending[key] = pending }
        } else {
            cache.pending[key] = PendingCompletion(operation: CompletionOperation(taskID: item.id, lifecycle: base.lifecycle, baseRevision: base.fieldVersions[TaskField.isDone.rawValue] ?? 0, isDone: desired))
        }
        persist(); syncMessage = "待同步 · 手机提醒可能尚未取消"; sendPending()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: key) }
    }
    private func sendPending() {
        guard session.activationState == .activated else { return }
        for key in Array(cache.pending.keys) {
            guard var pending = cache.pending[key], let data = try? JSONEncoder().encode(pending.operation) else { continue }
            let message: [String: Any] = ["completionOperation": data]
            if session.isReachable {
                pending.sent = true; cache.pending[key] = pending; persist()
                session.sendMessage(message, replyHandler: { reply in DispatchQueue.main.async { self.receive(reply) } }, errorHandler: { _ in DispatchQueue.main.async { self.syncMessage = "待同步 · 稍后重试" } })
            } else if !pending.transferQueued {
                // Persist operation identity before handing it to background transport.
                pending.sent = true; pending.transferQueued = true; cache.pending[key] = pending; persist()
                session.transferUserInfo(message)
            }
        }
    }
    private func receive(_ context: [String: Any]) {
        if let data = context["taskSnapshot"] as? Data, let snapshot = try? JSONDecoder().decode(TaskSnapshot.self, from: data), snapshot.revision >= cache.snapshot.revision {
            cache.snapshot = snapshot
            for key in Array(cache.pending.keys) {
                guard let pending = cache.pending[key] else { continue }
                if !snapshot.tasks.contains(where: { $0.id == pending.operation.taskID && $0.lifecycle == pending.operation.lifecycle }) { cache.pending.removeValue(forKey: key) }
            }
        }
        if let data = context["completionAck"] as? Data, let ack = try? JSONDecoder().decode(CompletionAck.self, from: data),
           let entry = cache.pending.first(where: { $0.value.operation.id == ack.operationID }) {
            cache.pending.removeValue(forKey: entry.key)
            if ack.accepted, let desired = entry.value.nextIntent,
               let task = cache.snapshot.tasks.first(where: { $0.id == entry.value.operation.taskID }), desired != task.isDone {
                cache.pending[entry.key] = PendingCompletion(operation: CompletionOperation(taskID: task.id, lifecycle: task.lifecycle, baseRevision: task.fieldVersions[TaskField.isDone.rawValue] ?? 0, isDone: desired))
            } else if !ack.accepted { syncMessage = "手机任务已更新，已采用手机状态" }
        }
        persist()
        if cache.pending.isEmpty { if syncMessage != "手机任务已更新，已采用手机状态" { syncMessage = "已与 iPhone 同步" } }
        else { syncMessage = "待同步 · 手机提醒可能尚未取消"; sendPending() }
    }
    private func activate() {
        receive(session.receivedApplicationContext)
        if session.isReachable { session.sendMessage(["requestTaskSnapshot": true], replyHandler: { reply in DispatchQueue.main.async { self.receive(reply) } }, errorHandler: { _ in }) }
        sendPending()
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { DispatchQueue.main.async { self.activate() } }
    func sessionReachabilityDidChange(_ session: WCSession) { DispatchQueue.main.async { self.activate() } }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) { DispatchQueue.main.async { self.receive(applicationContext) } }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { DispatchQueue.main.async { self.receive(userInfo) } }
}
