import Foundation
import Combine
import WatchConnectivity
import UserNotifications

final class ReminderStore: NSObject, ObservableObject, WCSessionDelegate, UNUserNotificationCenterDelegate {
    @Published private(set) var database = TaskDatabase()
    @Published private(set) var syncMessage = "提醒保存在 iPhone"
    @Published private(set) var notificationMessage = ""
    @Published var errorMessage: String?
    @Published var notificationTaskID: UUID?
    private let directory: URL
    private let dataURL: URL
    private let session = WCSession.default
    private let notifications: TaskNotifications
    private var writable = true
    var reminders: [ReminderItem] { database.tasks.filter { $0.deletedAt == nil } }
    var deleted: [ReminderItem] { database.tasks.filter { $0.deletedAt != nil } }
    var revision: Int { database.revision }

    override init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Reminders", isDirectory: true)
        dataURL = directory.appendingPathComponent("tasks-v2.json")
        notifications = TaskNotifications(directory: directory)
        super.init()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dataURL.path) {
                database = try JSONDecoder().decode(TaskDatabase.self, from: Data(contentsOf: dataURL))
                guard database.schema == 2 else { throw TaskFailure("任务数据库版本不兼容，请保留原文件") }
            } else {
                var migrated = TaskDatabase()
                if let old = UserDefaults.standard.data(forKey: "venus.tools.reminders.v1") {
                    migrated.tasks = try JSONDecoder().decode([ReminderItem].self, from: old)
                }
                try write(migrated); database = migrated
            }
            var clean = database
            let expired = clean.tasks.filter { $0.deletedAt.map { Date().timeIntervalSince($0) > 30 * 86_400 } == true }
            clean.tasks.removeAll { task in expired.contains { $0.id == task.id } }
            for task in expired { clean.history.removeValue(forKey: task.id.uuidString) }
            if !expired.isEmpty { clean.revision += 1; try write(clean); database = clean }
            for task in expired { try? removeConversation(task.id) }
            clearExpiredDrafts()
        } catch { writable = false; errorMessage = "无法读取或迁移任务：\(error.localizedDescription)。原数据已保留，请释放空间后重新打开。" }
        UNUserNotificationCenter.current().delegate = self
        if WCSession.isSupported() { session.delegate = self; session.activate() }
        refreshNotifications()
    }

    func item(_ id: UUID) -> ReminderItem? { reminders.first { $0.id == id } }
    func versions(_ id: UUID) -> [TaskVersion] { database.history[id.uuidString] ?? [] }
    func unfinishedPrerequisites(_ task: ReminderItem) -> Int {
        task.prerequisiteIDs.filter { item($0)?.isDone == false }.count
    }

    private func write(_ value: TaskDatabase) throws {
        guard writable else { throw TaskFailure("数据暂不可写，请先处理读取错误") }
        try JSONEncoder().encode(value).write(to: dataURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func commit(_ value: TaskDatabase) throws {
        try write(value)
        database = value
        publishSnapshot()
        refreshNotifications()
    }

    func save(_ draft: TaskDraft, resolving choices: Set<TaskField> = []) throws -> UUID {
        var task = draft.task
        let old = item(task.id)
        if let base = draft.base {
            guard let latest = old, latest.lifecycle == base.lifecycle else { throw TaskFailure("任务已删除或重新恢复，请重新打开") }
            let (merged, conflicts) = TaskRules.merge(base: base, draft: task, latest: latest)
            task = merged
            for field in conflicts where choices.contains(field) { field.copy(from: draft.task, to: &task) }
        } else if database.tasks.contains(where: { $0.id == task.id }) { throw TaskFailure("任务已保存，请重新打开") }
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.tags = TaskRules.normalizedTags(task.tags)
        try TaskRules.validate(task, among: reminders, previous: old)
        var next = database
        next.revision += 1
        task.revision = next.revision
        for field in TaskField.allCases where old.map({ field.value($0) != field.value(task) }) ?? true {
            task.fieldVersions[field.rawValue] = next.revision
        }
        if old?.isDone != task.isDone { task.completedAt = task.isDone ? Date() : nil }
        if old?.addedAt != task.addedAt { task.addedAtInferred = false }
        if let old, old.schedule != task.schedule { task.notificationVersion = UUID() }
        next.tasks.removeAll { $0.id == task.id }; next.tasks.append(task)
        var history = next.history[task.id.uuidString] ?? []
        history.insert(TaskVersion(source: "iPhone 保存", task: task), at: 0)
        next.history[task.id.uuidString] = Array(history.prefix(20))
        try saveConversation(draft)
        try commit(next)
        try? discardDraft(draft.key)
        if task.schedule.trigger().map({ $0 > Date() }) == true { refreshNotifications(requestPermission: true) }
        return task.id
    }

    func toggle(_ task: ReminderItem) {
        guard loadDraft(task.id.uuidString) == nil else { errorMessage = "此任务有未保存草稿，请先进入编辑保存或放弃草稿"; return }
        var draft = TaskDraft(); draft.base = task; draft.task = task; draft.task.isDone.toggle()
        do { _ = try save(draft) } catch { errorMessage = error.localizedDescription }
    }

    func remove(_ task: ReminderItem) {
        do {
            var next = database; next.revision += 1
            for index in next.tasks.indices {
                if next.tasks[index].id == task.id { next.tasks[index].deletedAt = Date(); next.tasks[index].revision = next.revision }
                if next.tasks[index].prerequisiteIDs.contains(task.id) {
                    next.tasks[index].prerequisiteIDs.removeAll { $0 == task.id }
                    next.tasks[index].revision = next.revision
                    next.tasks[index].fieldVersions[TaskField.prerequisiteIDs.rawValue] = next.revision
                }
            }
            // Deleted tasks never reconnect their former prerequisites on restore.
            if let index = next.tasks.firstIndex(where: { $0.id == task.id }) { next.tasks[index].prerequisiteIDs = [] }
            try commit(next); try? discardDraft(task.id.uuidString)
        } catch { errorMessage = error.localizedDescription }
    }

    func restore(_ task: ReminderItem) {
        do {
            var next = database; next.revision += 1
            guard let index = next.tasks.firstIndex(where: { $0.id == task.id }) else { return }
            next.tasks[index].deletedAt = nil; next.tasks[index].lifecycle = UUID()
            next.tasks[index].prerequisiteIDs = []; next.tasks[index].revision = next.revision
            try commit(next)
        } catch { errorMessage = error.localizedDescription }
    }

    func permanentlyDelete(_ task: ReminderItem) {
        do {
            var next = database; next.revision += 1
            next.tasks.removeAll { $0.id == task.id }; next.history.removeValue(forKey: task.id.uuidString)
            try commit(next); try? discardDraft(task.id.uuidString); try? removeConversation(task.id)
        } catch { errorMessage = error.localizedDescription }
    }

    func saveDraft(_ draft: TaskDraft) throws {
        guard writable else { throw TaskFailure("数据暂不可写，请保留本页内容") }
        var value = draft; value.updatedAt = Date()
        if value.base != nil { try saveConversation(value) }
        if !value.hasPendingEdits { try discardDraft(value.key); return }
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("draft-\(value.key).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func loadDraft(_ key: String) -> TaskDraft? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("draft-\(key).json")),
              let draft = try? JSONDecoder().decode(TaskDraft.self, from: data), Date().timeIntervalSince(draft.updatedAt) <= 7 * 86_400 else { return nil }
        return draft
    }
    func discardDraft(_ key: String) throws {
        if let draft = loadDraft(key) {
            for image in draft.images { try? FileManager.default.removeItem(at: imageURL(image)) }
            if let audio = draft.audio { removeAudio(audio) }
        }
        let url = directory.appendingPathComponent("draft-\(key).json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func imageURL(_ image: TaskImage) -> URL { directory.appendingPathComponent(image.filename) }
    func storeImage(_ data: Data) throws -> TaskImage {
        let image = TaskImage(filename: "image-\(UUID()).jpg")
        try data.write(to: imageURL(image), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); return image
    }
    func removeImage(_ image: TaskImage) { try? FileManager.default.removeItem(at: imageURL(image)) }
    func audioURL(_ audio: TaskAudio) -> URL { directory.appendingPathComponent(audio.filename) }
    func removeAudio(_ audio: TaskAudio) { try? FileManager.default.removeItem(at: audioURL(audio)) }
    func conversation(_ id: UUID) throws -> TaskConversation? {
        try TaskConversationArchive(directory: directory).load(id)
    }
    private func saveConversation(_ draft: TaskDraft) throws {
        guard !draft.messages.isEmpty else { return }
        let old = try conversation(draft.task.id)
        let value = TaskConversation(id: old?.id ?? draft.conversationID ?? UUID(), taskID: draft.task.id, messages: draft.messages)
        try TaskConversationArchive(directory: directory).save(value)
    }
    private func removeConversation(_ id: UUID) throws {
        try TaskConversationArchive(directory: directory).remove(id)
    }
    private func clearExpiredDrafts() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        var referenced = Set<String>()
        for file in files where file.lastPathComponent.hasPrefix("draft-") {
            guard let draft = try? JSONDecoder().decode(TaskDraft.self, from: Data(contentsOf: file)) else { continue }
            if Date().timeIntervalSince(draft.updatedAt) > 7 * 86_400 {
                if let audio = draft.audio { removeAudio(audio) }
                for image in draft.images { removeImage(image) }; try? FileManager.default.removeItem(at: file)
            } else { referenced.formUnion(draft.images.map(\.filename)); if let audio = draft.audio { referenced.insert(audio.filename) } }
        }
        for file in files where (file.lastPathComponent.hasPrefix("image-") || file.lastPathComponent.hasPrefix("audio-")) && !referenced.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
    }

    func refreshNotifications(requestPermission: Bool = false) {
        let tasks = database.tasks
        Task { let message = await notifications.reconcile(tasks, requestPermission: requestPermission)
            await MainActor.run { self.notificationMessage = message }
        }
    }

    func retryDelivery() { publishSnapshot(); refreshNotifications(requestPermission: true) }

    private func snapshot() -> TaskSnapshot {
        TaskRules.watchSnapshot(reminders, revision: database.revision)
    }
    private func snapshotContext() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(snapshot()) else { return [:] }
        if data.count > 40_000 {
            queueSnapshotFile(data)
            return ["snapshotPendingRevision": database.revision]
        }
        return ["taskSnapshot": data]
    }
    private func queueSnapshotFile(_ data: Data) {
        guard session.activationState == .activated else { return }
        let transfers = session.outstandingFileTransfers.filter { $0.file.metadata?["kind"] as? String == "taskSnapshot" }
        if transfers.contains(where: { $0.file.metadata?["revision"] as? Int == database.revision }) { return }
        for transfer in transfers { transfer.cancel() }
        do {
            let url = directory.appendingPathComponent("watch-snapshot-\(UUID()).json")
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            session.transferFile(url, metadata: ["kind": "taskSnapshot", "revision": database.revision])
        } catch { syncMessage = "大列表同步未开始，请重试：\(error.localizedDescription)" }
    }
    private func publishSnapshot() {
        guard WCSession.isSupported(), session.activationState == .activated else { return }
        guard session.isPaired else { syncMessage = "已保存 · 等待配对手表"; return }
        guard session.isWatchAppInstalled else { syncMessage = "已保存 · 手表任务应用尚未安装"; return }
        do { try session.updateApplicationContext(snapshotContext()); syncMessage = "已保存 · 等待手表接收" }
        catch { syncMessage = "已保存 · 手表同步待重试" }
    }
    private func receive(_ context: [String: Any]) -> [String: Any] {
        guard let data = context["completionOperation"] as? Data,
              let operation = try? JSONDecoder().decode(CompletionOperation.self, from: data) else { return snapshotContext() }
        var ack: CompletionAck
        if let previous = database.acknowledgements[operation.id.uuidString] { ack = previous }
        else {
            var next = database
            let index = next.tasks.firstIndex { $0.id == operation.taskID }
            let accepted = index.map { TaskRules.accepts(operation, for: next.tasks[$0]) } ?? false
            ack = CompletionAck(operationID: operation.id, accepted: accepted)
            if accepted, let index {
                next.revision += 1; next.tasks[index].isDone = operation.isDone
                next.tasks[index].completedAt = operation.isDone ? Date() : nil
                next.tasks[index].revision = next.revision
                next.tasks[index].fieldVersions[TaskField.isDone.rawValue] = next.revision
                ack.completionRevision = next.revision
                var history = next.history[operation.taskID.uuidString] ?? []
                history.insert(TaskVersion(source: "Apple Watch", task: next.tasks[index]), at: 0)
                next.history[operation.taskID.uuidString] = Array(history.prefix(20))
            }
            next.acknowledgements[operation.id.uuidString] = ack
            if next.acknowledgements.count > 512 { next.acknowledgements = [operation.id.uuidString: ack] }
            do { try commit(next) } catch { errorMessage = error.localizedDescription; return snapshotContext() }
        }
        var reply = snapshotContext(); reply["completionAck"] = try? JSONEncoder().encode(ack)
        if let task = snapshot().tasks.first(where: { $0.id == operation.taskID }) {
            reply["completionTask"] = try? JSONEncoder().encode(task)
        }
        return reply
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.publishSnapshot() }
    }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async { replyHandler(self.receive(message)) }
    }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        DispatchQueue.main.async { let reply = self.receive(userInfo); session.transferUserInfo(reply) }
    }
    func sessionReachabilityDidChange(_ session: WCSession) { DispatchQueue.main.async { self.publishSnapshot() } }
    func sessionWatchStateDidChange(_ session: WCSession) { DispatchQueue.main.async { self.publishSnapshot() } }
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard fileTransfer.file.metadata?["kind"] as? String == "taskSnapshot" else { return }
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        if error != nil { DispatchQueue.main.async { self.syncMessage = "大列表同步待重试" } }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.notificationTaskID = (response.notification.request.content.userInfo["taskID"] as? String).flatMap(UUID.init(uuidString:)); completionHandler() }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
}
