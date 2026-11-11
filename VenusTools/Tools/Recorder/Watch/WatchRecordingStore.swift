import Foundation
import Combine
import AVFoundation

private struct WatchRecordingFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@MainActor
final class WatchRecordingStore: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var isStarting = false
    @Published private(set) var seconds = 0
    @Published private(set) var level = 0.0
    @Published private(set) var message = "录完后自动回传，成功后清理手表副本"
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var timer: Task<Void, Never>?
    private var currentID: UUID?
    private var startedAt: Date?
    private var currentSupplementID: UUID?
    private var currentSupplementTitle: String?
    private var token = UUID()

    func start(using reminderStore: WatchReminderStore) async {
        guard !isRecording, !isStarting else { return }
        let supplementID = reminderStore.selectedRecordingTargetID
        if let targetID = supplementID,
           !reminderStore.recordingTargets.contains(where: { $0.id == targetID }) {
            errorMessage = "补录目标已不在手机录音清单中，请重新选择。"
            reminderStore.selectRecordingTarget(nil)
            return
        }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard allowed else { errorMessage = "请在 Apple Watch 设置中允许 Venus 使用麦克风。"; return }
        do {
            try RecordingStorage.prepare()
            let id = UUID()
            let url = RecordingStorage.audioDirectory.appendingPathComponent("\(id.uuidString).m4a")
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else { throw WatchRecordingFailure(message: "手表麦克风未能启动，请重试") }
            self.recorder = recorder
            currentID = id
            startedAt = .now
            currentSupplementID = supplementID
            currentSupplementTitle = supplementID.flatMap { id in reminderStore.recordingTargets.first(where: { $0.id == id })?.title }
            seconds = 0
            isPaused = false
            isRecording = true
            message = currentSupplementTitle.map { "录音中 · 将补录到\($0)" } ?? "录音中 · 点按结束后传回 iPhone"
            let currentToken = UUID()
            token = currentToken
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.token == currentToken else { return }
                    self.seconds = Int(recorder.currentTime)
                    recorder.updateMeters()
                    self.level = min(1, max(0, (Double(recorder.averagePower(forChannel: 0)) + 55) / 55))
                    if self.seconds >= 1800 { self.stop(using: reminderStore); return }
                }
            }
        } catch {
            currentSupplementID = nil
            currentSupplementTitle = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            errorMessage = error.localizedDescription
        }
    }

    func togglePause() {
        guard isRecording, let recorder else { return }
        if isPaused {
            guard recorder.record() else { errorMessage = "录音未能继续，请结束并保存当前内容。"; return }
            isPaused = false
            message = currentSupplementTitle.map { "录音中 · 将补录到\($0)" } ?? "录音中 · 点按结束后传回 iPhone"
        } else {
            recorder.pause()
            isPaused = true
            message = "已暂停 · 可继续或结束录音"
            level = 0
        }
    }

    func stop(using reminderStore: WatchReminderStore) {
        guard let id = currentID, let recorder else { return }
        let duration = recorder.currentTime
        let fileName = "\(id.uuidString).m4a"
        recorder.stop()
        self.recorder = nil
        currentID = nil
        isRecording = false
        isPaused = false
        level = 0
        seconds = Int(duration)
        timer?.cancel()
        timer = nil
        token = UUID()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let createdAt = startedAt ?? .now
        startedAt = nil
        let supplementID = currentSupplementID
        let item = VoiceRecording(id: id, title: (supplementID == nil ? "手表录音 · " : "手表补录 · ") + createdAt.formatted(date: .abbreviated, time: .shortened),
                                  createdAt: createdAt, duration: duration, audioFileName: fileName,
                                  transcript: "", summary: "", origin: .appleWatch, supplementForID: supplementID)
        reminderStore.sendWatchRecording(item, from: RecordingStorage.audioDirectory.appendingPathComponent(fileName))
        reminderStore.selectRecordingTarget(nil)
        currentSupplementID = nil
        currentSupplementTitle = nil
        message = reminderStore.recordingSyncMessage
    }

}
