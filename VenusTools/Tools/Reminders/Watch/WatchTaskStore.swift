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
    var syncedAt: Date?
}

private struct PendingWatchRecordingTransfer: Codable {
    var recording: VoiceRecording
    var filePath: String
}

final class WatchReminderStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published private var cache = WatchTaskCache()
    @Published private(set) var syncMessage = "等待 iPhone 同步"
    @Published private(set) var recordingSyncMessage = "录音会先保存在手表"
    private let session = WCSession.default
    private let key = "venus.tools.watch.tasks.v2"
    private let recordingTransferKey = "venus.tools.watch.recordings.pending.v1"
    private var recordingTransfers: [PendingWatchRecordingTransfer] = []
    private var timer: AnyCancellable?
    private var waitingForSnapshot = false
    var lastSyncedAt: Date? { cache.syncedAt }
    var hasSnapshot: Bool { cache.snapshot.revision >= 0 }
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
        if let data = UserDefaults.standard.data(forKey: recordingTransferKey), let value = try? JSONDecoder().decode([PendingWatchRecordingTransfer].self, from: data) { recordingTransfers = value }
        if hasSnapshot { syncMessage = "显示上次同步的任务" }
        if WCSession.isSupported() { session.delegate = self; session.activate() }
        timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            if !self.cache.pending.isEmpty {
                self.syncMessage = "待同步 · 手机提醒可能尚未取消"
                self.sendPending()
            }
            self.flushRecordingTransfers()
        }
    }

    func sendWatchRecording(_ recording: VoiceRecording, from url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            recordingSyncMessage = "录音文件不存在，请重新录制"
            return
        }
        if !recordingTransfers.contains(where: { $0.recording.id == recording.id }) {
            recordingTransfers.append(PendingWatchRecordingTransfer(recording: recording, filePath: url.path))
            persistRecordingTransfers()
        }
        recordingSyncMessage = "录音已保存 · 正在等待传输"
        flushRecordingTransfers()
    }

    private func persistRecordingTransfers() {
        if let data = try? JSONEncoder().encode(recordingTransfers) { UserDefaults.standard.set(data, forKey: recordingTransferKey) }
    }

    private func flushRecordingTransfers() {
        guard !recordingTransfers.isEmpty else { return }
        guard session.activationState == .activated else { recordingSyncMessage = "录音已保存在手表 · 等待连接 iPhone"; return }
        for pending in Array(recordingTransfers) {
            let url = URL(fileURLWithPath: pending.filePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                recordingTransfers.removeAll { $0.recording.id == pending.recording.id }
                persistRecordingTransfers()
                recordingSyncMessage = "录音文件已不在手表，请重新录制"
                continue
            }
            let alreadyQueued = session.outstandingFileTransfers.contains { $0.file.metadata?["kind"] as? String == "watchRecording" && $0.file.metadata?["id"] as? String == pending.recording.id.uuidString }
            guard !alreadyQueued else { continue }
            let item = pending.recording
            session.transferFile(url, metadata: [
                "kind": "watchRecording",
                "id": item.id.uuidString,
                "title": item.title,
                "createdAt": item.createdAt.timeIntervalSince1970,
                "duration": item.duration,
                "audioFileName": item.audioFileName
            ])
            recordingSyncMessage = "正在传输录音到 iPhone"
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
    private func receive(_ context: [String: Any], markReceived: Bool = true) {
        var receivedSnapshot = false
        if let data = context["taskSnapshot"] as? Data, let snapshot = try? JSONDecoder().decode(TaskSnapshot.self, from: data), snapshot.revision >= cache.snapshot.revision {
            cache.snapshot = TaskRules.mergeSnapshot(snapshot, into: cache.snapshot)
            receivedSnapshot = true
            if markReceived { cache.syncedAt = Date() }
            waitingForSnapshot = false
            for key in Array(cache.pending.keys) {
                guard let pending = cache.pending[key] else { continue }
                if !cache.snapshot.tasks.contains(where: { $0.id == pending.operation.taskID && $0.lifecycle == pending.operation.lifecycle }) { cache.pending.removeValue(forKey: key) }
            }
        }
        if let revision = context["snapshotPendingRevision"] as? Int, revision > cache.snapshot.revision { waitingForSnapshot = true }
        if let data = context["completionTask"] as? Data, let task = try? JSONDecoder().decode(ReminderItem.self, from: data) {
            if let index = cache.snapshot.tasks.firstIndex(where: { $0.id == task.id }) {
                if cache.snapshot.tasks[index].revision <= task.revision { cache.snapshot.tasks[index] = task }
            } else if task.revision >= cache.snapshot.revision { cache.snapshot.tasks.append(task) }
        }
        if let data = context["completionAck"] as? Data, let ack = try? JSONDecoder().decode(CompletionAck.self, from: data),
           let entry = cache.pending.first(where: { $0.value.operation.id == ack.operationID }) {
            cache.pending.removeValue(forKey: entry.key)
            if let desired = entry.value.nextIntent,
               let task = cache.snapshot.tasks.first(where: { $0.id == entry.value.operation.taskID }),
               task.lifecycle == entry.value.operation.lifecycle, TaskRules.canContinue(after: ack, task: task), desired != task.isDone {
                cache.pending[entry.key] = PendingCompletion(operation: CompletionOperation(taskID: task.id, lifecycle: task.lifecycle, baseRevision: task.fieldVersions[TaskField.isDone.rawValue] ?? 0, isDone: desired))
            } else if !ack.accepted { syncMessage = "手机任务已更新，已采用手机状态" }
        }
        persist()
        if cache.pending.isEmpty {
            if waitingForSnapshot { syncMessage = "任务列表传输中" }
            else if receivedSnapshot && markReceived && syncMessage != "手机任务已更新，已采用手机状态" { syncMessage = "已与 iPhone 同步" }
        }
        else { syncMessage = "待同步 · 手机提醒可能尚未取消"; sendPending() }
    }
    func requestSync() {
        guard session.activationState == .activated else { syncMessage = "正在准备与 iPhone 连接"; return }
        receive(session.receivedApplicationContext, markReceived: false)
        if session.isReachable {
            syncMessage = "正在同步 iPhone 任务"
            session.sendMessage(["requestTaskSnapshot": true], replyHandler: { reply in
                DispatchQueue.main.async { self.receive(reply) }
            }, errorHandler: { _ in
                DispatchQueue.main.async { self.syncMessage = "同步未完成，请打开手机 Venus 后重试" }
            })
        } else {
            syncMessage = hasSnapshot ? "显示缓存 · 等待 iPhone 连接" : "等待 iPhone · 请打开手机 Venus"
            if !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo["requestTaskSnapshot"] as? Bool == true }) {
                session.transferUserInfo(["requestTaskSnapshot": true])
            }
        }
        sendPending()
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if let error { self.syncMessage = "连接失败：\(error.localizedDescription)" }
            else { self.requestSync(); self.flushRecordingTransfers() }
        }
    }
    func sessionReachabilityDidChange(_ session: WCSession) { DispatchQueue.main.async { self.requestSync(); self.flushRecordingTransfers() } }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) { DispatchQueue.main.async { self.receive(applicationContext) } }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { DispatchQueue.main.async { self.receive(userInfo) } }
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?["kind"] as? String == "taskSnapshot", let data = try? Data(contentsOf: file.fileURL) else { return }
        DispatchQueue.main.async { self.receive(["taskSnapshot": data]) }
    }
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard fileTransfer.file.metadata?["kind"] as? String == "watchRecording",
              let id = fileTransfer.file.metadata?["id"] as? String else { return }
        DispatchQueue.main.async {
            if let error {
                self.recordingSyncMessage = "传输未完成 · 稍后会重试"
                _ = error
                return
            }
            if let pending = self.recordingTransfers.first(where: { $0.recording.id.uuidString == id }) {
                try? FileManager.default.removeItem(atPath: pending.filePath)
            }
            self.recordingTransfers.removeAll { $0.recording.id.uuidString == id }
            self.persistRecordingTransfers()
            self.recordingSyncMessage = "录音已传到 iPhone"
        }
    }
}
