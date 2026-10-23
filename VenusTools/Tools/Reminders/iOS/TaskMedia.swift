import SwiftUI
import PhotosUI
import Vision
import Speech
import AVFoundation
import ImageIO

@MainActor
final class TaskVoiceInput: ObservableObject {
    @Published var text = ""
    @Published var error: String?
    @Published private(set) var needsSettings = false
    @Published private(set) var recording = false
    @Published private(set) var starting = false
    private let engine = AVAudioEngine()
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var timer: Task<Void, Never>?
    private var hasTap = false
    private var identity = UUID()

    func start() async {
        guard !starting, !recording else { return }
        cancel()
        error = nil; needsSettings = false
        let identity = self.identity
        starting = true
        defer { starting = false }
        let authorized = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) } }
        let microphone = await withCheckedContinuation { continuation in AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) } }
        guard identity == self.identity else { return }
        guard authorized, microphone else { needsSettings = true; error = "请在 iPhone 设置中允许 Venus 使用麦克风与语音识别。也可改选音频转写模型；当前文字已保留。"; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            error = "当前设备暂不支持普通话离线识别，请使用文字输入"; return
        }
        text = ""; error = nil
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers); try audio.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
            self.request = request
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw TaskFailure("麦克风暂不可用") }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }; hasTap = true
            recognition = recognizer.recognitionTask(with: request) { result, failure in
                Task { @MainActor in
                    guard identity == self.identity else { return }
                    if let result { self.text = result.bestTranscription.formattedString }
                    if result?.isFinal == true || failure != nil {
                        self.stop()
                        if let failure {
                            let issue = failure as NSError
                            if issue.domain == "kLSRErrorDomain", issue.code == 301 { return }
                            self.needsSettings = issue.code == 201 || issue.code == 1700
                            self.error = TaskSpeechIssue.message(domain: issue.domain, code: issue.code)
                        }
                    }
                }
            }
            engine.prepare(); try engine.start(); recording = true
            timer = Task { try? await Task.sleep(for: .seconds(120)); if !Task.isCancelled { self.stop() } }
        } catch { cancel(); self.error = error.localizedDescription }
    }
    func stop() {
        engine.stop(); if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio(); recording = false; timer?.cancel(); timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func cancel() { identity = UUID(); stop(); recognition?.cancel(); recognition = nil; request = nil }
}

@MainActor
final class TaskAudioRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var starting = false
    @Published private(set) var seconds = 0
    private var recorder: AVAudioRecorder?
    private var timer: Task<Void, Never>?
    private var identity = UUID()

    func start(at url: URL) async throws {
        guard !starting && !recording else { return }
        identity = UUID(); let token = identity; starting = true
        defer { starting = false }
        let allowed = await withCheckedContinuation { continuation in AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) } }
        guard token == identity else { throw CancellationError() }
        guard allowed else { throw TaskFailure("请在 iPhone 设置中允许 Venus 使用麦克风；音频模型转写不需要开启 Siri。") }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: .duckOthers); try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            guard recorder.prepareToRecord(), recorder.record() else { throw TaskFailure("麦克风录音未能启动，请重试") }
            self.recorder = recorder; seconds = 0; recording = true
            timer = Task { [weak self] in
                for second in 1...120 {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, token == self.identity else { return }
                    self.seconds = second
                }
                self?.stop()
            }
        } catch { stop(); throw error }
    }
    func stop() {
        identity = UUID(); timer?.cancel(); timer = nil
        recorder?.stop(); recorder = nil; recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum TaskImageReader {
    static func validatedJPEG(_ data: Data) throws -> Data {
        guard data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, ["public.jpeg", "public.png", "public.heic"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 48_000_000 / height else { throw TaskFailure("仅支持 20 MB、4,800 万像素以内的单张 JPEG、PNG 或 HEIC 静态图片") }
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else { throw TaskFailure("图片无法解码，请重新选择") }
        return jpeg
    }
    static func recognize(_ url: URL) async throws -> String {
        try await Task.detached {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = true
            try VNImageRequestHandler(url: url).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            guard !text.isEmpty else { throw TaskFailure("没有识别到清晰文字。当前模式不理解无文字照片，请补充文字说明") }
            return text
        }.value
    }
}

struct TaskCamera: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: TaskCamera
        init(parent: TaskCamera) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }; parent.dismiss()
        }
    }
}
