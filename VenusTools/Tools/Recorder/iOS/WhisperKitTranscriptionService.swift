import Foundation
import CryptoKit
import SherpaOnnx
import SherpaOnnxC

private struct SpeechModelFile {
    let path: String
    let sha256: String?
    let estimatedSize: Int64
}

private struct SpeechModelSpec {
    let repository: String
    let revision: String
    let files: [SpeechModelFile]
}

@MainActor
final class OfflineSpeechModels: ObservableObject {
    static let shared = OfflineSpeechModels()
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var speed: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var revision = 0
    private var active: Set<String> = []

    private let specs: [String: SpeechModelSpec] = [
        ModelConfiguration.senseVoiceID: SpeechModelSpec(
            repository: "chris-cao/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17",
            revision: "20dc3ebe15651c2e26d7e07b04fcd84a39c3b920",
            files: [
                SpeechModelFile(path: "model.int8.onnx", sha256: "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51", estimatedSize: 239_000_000),
                SpeechModelFile(path: "tokens.txt", sha256: "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc", estimatedSize: 315_894)
            ]),
        ModelConfiguration.qwenASRID: SpeechModelSpec(
            repository: "csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
            revision: "68818b2313fe77bd06f6a7c5068ff3ef59d02b8a",
            files: [
                SpeechModelFile(path: "conv_frontend.onnx", sha256: "d22dc4423e0940e49884e903d2ea2f7e5567c14fc1aed97e4e26d6b8f208ef9e", estimatedSize: 44_100_000),
                SpeechModelFile(path: "encoder.int8.onnx", sha256: "60748d3e6744a57c9c91e1b17424a6c2990567e8adceb0783940c03ed98fa9d9", estimatedSize: 182_000_000),
                SpeechModelFile(path: "decoder.int8.onnx", sha256: "4f6885be5959ae26af3089d38ee7972c5fafbeeb1cf8d5e76eab6d8b61ca5771", estimatedSize: 756_000_000),
                SpeechModelFile(path: "tokenizer/merges.txt", sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5", estimatedSize: 1_671_853),
                SpeechModelFile(path: "tokenizer/tokenizer_config.json", sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c", estimatedSize: 12_500),
                SpeechModelFile(path: "tokenizer/vocab.json", sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910", estimatedSize: 2_780_000)
            ])
    ]

    private func directory(_ id: String) -> URL {
        let name = id == ModelConfiguration.senseVoiceID ? "SenseVoiceSmall" : "Qwen3ASR06B"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models/OfflineSpeech", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    func isReady(_ id: String) -> Bool {
        guard let spec = specs[id] else { return false }
        let dir = directory(id)
        guard (try? String(contentsOf: dir.appendingPathComponent("verified"), encoding: .utf8)) == spec.revision else { return false }
        return spec.files.allSatisfy {
            ((try? dir.appendingPathComponent($0.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }
    }

    func modelDirectory(_ id: String) throws -> URL {
        guard isReady(id) else { throw ModelFailure("请先在模型列表下载并校验模型。") }
        return directory(id)
    }

    func size(_ id: String) -> Int64 {
        guard let spec = specs[id] else { return 0 }
        if !isReady(id) { return spec.files.reduce(0) { $0 + $1.estimatedSize } }
        return spec.files.reduce(0) {
            $0 + Int64((try? directory(id).appendingPathComponent($1.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func download(_ id: String) async {
        guard let spec = specs[id], progress[id] == nil, !active.contains(id) else { return }
        progress[id] = 0
        speed[id] = 0
        errors[id] = nil
        let dir = directory(id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let marker = dir.appendingPathComponent("verified")
            try? FileManager.default.removeItem(at: marker)
            let total = Double(spec.files.reduce(Int64(0)) { $0 + $1.estimatedSize })
            var completed: Int64 = 0
            for file in spec.files {
                try Task.checkCancellation()
                let url = URL(string: "https://huggingface.co/\(spec.repository)/resolve/\(spec.revision)/\(file.path)")!
                let start = completed
                let delegate = SpeechDownloadProgress { written, rate in
                    Task { @MainActor in
                        guard self.progress[id] != nil else { return }
                        self.progress[id] = min(0.99, Double(start + written) / total)
                        self.speed[id] = rate
                    }
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = 300
                let (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw ModelFailure("下载 \(file.path) 失败，HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。")
                }
                let actual = (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard actual > 0 else { throw ModelFailure("下载文件为空：\(file.path)") }
                if let expected = file.sha256 {
                    let hash = try await Task.detached(priority: .utility) {
                        let handle = try FileHandle(forReadingFrom: temporary)
                        defer { try? handle.close() }
                        var digest = SHA256()
                        while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty { digest.update(data: block) }
                        return digest.finalize().map { String(format: "%02x", $0) }.joined()
                    }.value
                    guard hash == expected else { throw ModelFailure("文件校验失败：\(file.path)，请重试。") }
                }
                let dest = dir.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(at: temporary, to: dest)
                completed += Int64(actual)
            }
            try spec.revision.write(to: marker, atomically: true, encoding: .utf8)
            revision += 1
        } catch {
            errors[id] = error.localizedDescription
        }
        progress[id] = nil
        speed[id] = nil
    }

    func remove(_ id: String) {
        guard progress[id] == nil, !active.contains(id), specs[id] != nil else {
            errors[id] = "模型正在使用或下载，请稍后再删除。"
            return
        }
        do {
            try FileManager.default.removeItem(at: directory(id))
            errors[id] = nil
            revision += 1
        } catch { errors[id] = error.localizedDescription }
    }

    func beginUse(_ id: String) throws -> URL {
        guard !active.contains(id), progress[id] == nil else { throw ModelFailure("模型正在使用或下载，请稍后重试。") }
        let dir = try modelDirectory(id)
        active.insert(id)
        return dir
    }
    func endUse(_ id: String) { active.remove(id) }
}

private final class SpeechDownloadProgress: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let callback: @Sendable (Int64, Double) -> Void
    private var lastTime = Date()
    private var lastBytes: Int64 = 0
    init(_ callback: @escaping @Sendable (Int64, Double) -> Void) { self.callback = callback }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime)
        if elapsed >= 0.5 {
            callback(totalBytesWritten, Double(totalBytesWritten - lastBytes) / elapsed)
            lastTime = now
            lastBytes = totalBytesWritten
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

enum OfflineSpeechTranscription {
    static func transcribe(_ url: URL, modelID: String) async throws -> TimestampedSpeechTranscript {
        let directory = try await OfflineSpeechModels.shared.beginUse(modelID)
        do {
            let worker = Task.detached(priority: .userInitiated) { try recognize(url, modelID: modelID, directory: directory) }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            await OfflineSpeechModels.shared.endUse(modelID)
            return result
        } catch {
            await OfflineSpeechModels.shared.endUse(modelID)
            throw error
        }
    }

    private static func recognize(_ url: URL, modelID: String, directory: URL) throws -> TimestampedSpeechTranscript {
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(),
            modelConfig: sherpaOnnxOfflineModelConfig(tokens: "", numThreads: 2)
        )
        let recognizer: OpaquePointer?
        if modelID == ModelConfiguration.senseVoiceID {
            recognizer = directory.appendingPathComponent("model.int8.onnx").path.withCString { model in
                directory.appendingPathComponent("tokens.txt").path.withCString { tokens in
                    config.model_config.sense_voice.model = model
                    config.model_config.sense_voice.use_itn = 1
                    config.model_config.tokens = tokens
                    return SherpaOnnxCreateOfflineRecognizer(&config)
                }
            }
        } else {
            recognizer = directory.appendingPathComponent("conv_frontend.onnx").path.withCString { frontend in
                directory.appendingPathComponent("encoder.int8.onnx").path.withCString { encoder in
                    directory.appendingPathComponent("decoder.int8.onnx").path.withCString { decoder in
                        directory.appendingPathComponent("tokenizer").path.withCString { tokenizer in
                            config.model_config.qwen3_asr.conv_frontend = frontend
                            config.model_config.qwen3_asr.encoder = encoder
                            config.model_config.qwen3_asr.decoder = decoder
                            config.model_config.qwen3_asr.tokenizer = tokenizer
                            config.model_config.qwen3_asr.max_total_len = 512
                            config.model_config.qwen3_asr.max_new_tokens = 512
                            config.model_config.qwen3_asr.temperature = 0.000001
                            config.model_config.qwen3_asr.top_p = 0.8
                            return SherpaOnnxCreateOfflineRecognizer(&config)
                        }
                    }
                }
            }
        }
        guard let recognizer else { throw ModelFailure("离线模型无法加载，请检查空间或重新下载。") }
        defer { SherpaOnnxDestroyOfflineRecognizer(recognizer) }
        var samples: [Float] = []
        var segments: [TimestampedSpeechSegment] = []
        var offset: TimeInterval = 0
        let sampleRate = 16_000
        let chunkSize = sampleRate * 20
        func decode(_ chunk: [Float]) throws {
            try Task.checkCancellation()
            guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw ModelFailure("无法创建语音识别任务。") }
            defer { SherpaOnnxDestroyOfflineStream(stream) }
            SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), chunk, Int32(chunk.count))
            SherpaOnnxDecodeOfflineStream(recognizer, stream)
            guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw ModelFailure("语音模型未返回结果。") }
            defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
            let text = result.pointee.text.map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let duration = Double(chunk.count) / Double(sampleRate)
            if !text.isEmpty { segments.append(TimestampedSpeechSegment(start: offset, duration: duration, text: text)) }
            offset += duration
        }
        try RecorderAudioSamples.read(from: url, sampleRate: sampleRate) { buffer in
            samples.append(contentsOf: buffer)
            while samples.count >= chunkSize {
                try decode(Array(samples.prefix(chunkSize)))
                samples.removeFirst(chunkSize)
            }
        }
        if !samples.isEmpty { try decode(samples) }
        return TimestampedSpeechTranscript(text: segments.map(\.text).joined(), segments: segments)
    }
}
