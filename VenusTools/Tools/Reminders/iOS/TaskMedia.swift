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
    @Published private(set) var recording = false
    private let engine = AVAudioEngine()
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var timer: Task<Void, Never>?
    private var hasTap = false

    func start() async {
        let authorized = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) } }
        let microphone = await withCheckedContinuation { continuation in AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) } }
        guard authorized, microphone else { error = "请在系统设置中允许麦克风与语音识别，仍可直接输入文字"; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            error = "当前设备暂不支持普通话离线识别，请使用文字输入"; return
        }
        cancel(); text = ""; error = nil
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
                    if let result { self.text = result.bestTranscription.formattedString }
                    if result?.isFinal == true || failure != nil {
                        self.stop()
                        if let failure { self.error = "语音识别已停止：\(failure.localizedDescription)，已识别文字保留" }
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
    func cancel() { stop(); recognition?.cancel(); recognition = nil; request = nil }
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
