import Foundation
import WhisperKit

actor WhisperKitTranscriptionService {
    static let shared = WhisperKitTranscriptionService()

    private var loadedModelName: String?
    private var pipeline: WhisperKit?

    func unload() {
        pipeline = nil
        loadedModelName = nil
    }

    func prepare(model: RecordingTranscriptionModel, folder: URL, tokenizerFolder: URL) async throws {
        guard let name = model.whisperModelName else { throw ModelFailure("模型类型无效。") }
        pipeline = nil
        loadedModelName = nil
        let config = WhisperKitConfig(model: name, modelFolder: folder.path, tokenizerFolder: tokenizerFolder,
                                      verbose: false, load: true, download: false)
        pipeline = try await WhisperKit(config)
        loadedModelName = name
    }

    func transcribe(_ url: URL, model: RecordingTranscriptionModel) async throws -> TimestampedSpeechTranscript {
        guard let modelName = model.whisperModelName else {
            throw ModelFailure("请选择 Whisper 模型后再转写。")
        }

        if loadedModelName != modelName || pipeline == nil {
            pipeline = nil
            let folder = await WhisperModelDownloads.shared.modelFolder(for: model)
            guard let folder else { throw ModelFailure("请先在模型列表下载 \(model.title)。") }
            let tokenizerFolder = await WhisperModelDownloads.shared.tokenizerFolder(for: model)
            let config = WhisperKitConfig(model: modelName, modelFolder: folder.path, tokenizerFolder: tokenizerFolder, verbose: false, load: true, download: false, useBackgroundDownloadSession: true)
            pipeline = try await WhisperKit(config)
            loadedModelName = modelName
        }
        guard let pipeline else { throw ModelFailure("Whisper 模型加载失败，请重试。") }

        let results = try await pipeline.transcribe(
            audioPath: url.path,
            decodeOptions: DecodingOptions(language: "zh", wordTimestamps: true)
        )
        let text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ModelFailure("Whisper 没有识别到语音内容。") }
        let segments = results.flatMap(\.segments).map { segment in
            let start = TimeInterval(max(0, segment.start))
            let end = TimeInterval(max(segment.start, segment.end))
            return TimestampedSpeechSegment(start: start, duration: end - start, text: segment.text)
        }
        return TimestampedSpeechTranscript(text: text, segments: segments)
    }
}

@MainActor
final class WhisperModelDownloads: ObservableObject {
    static let shared = WhisperModelDownloads()
    @Published private(set) var progress: [RecordingTranscriptionModel: Double] = [:]
    @Published private(set) var errors: [RecordingTranscriptionModel: String] = [:]
    @Published private(set) var revision = 0

    private func root(for model: RecordingTranscriptionModel) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecordingWhisperModels", isDirectory: true)
            .appendingPathComponent(model.rawValue, isDirectory: true)
    }

    func tokenizerFolder(for model: RecordingTranscriptionModel) -> URL { root(for: model) }

    func modelFolder(for model: RecordingTranscriptionModel) -> URL? {
        let root = root(for: model)
        let marker = root.appendingPathComponent("model-path.txt")
        guard let relative = try? String(contentsOf: marker, encoding: .utf8),
              !relative.isEmpty, !relative.contains(".."), !relative.hasPrefix("/") else { return nil }
        let folder = root.appendingPathComponent(relative, isDirectory: true)
        let files = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        return files.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) } ? folder : nil
    }

    func size(for model: RecordingTranscriptionModel) -> Int64 {
        guard let folder = modelFolder(for: model),
              let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    func download(_ model: RecordingTranscriptionModel) async {
        guard let name = model.whisperModelName, progress[model] == nil else { return }
        progress[model] = 0
        errors[model] = nil
        do {
            let root = root(for: model)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let folder = try await WhisperKit.download(variant: name, downloadBase: root, useBackgroundSession: false) { value in
                let fraction = value.fractionCompleted
                Task { @MainActor in
                    guard WhisperModelDownloads.shared.progress[model] != nil else { return }
                    WhisperModelDownloads.shared.progress[model] = fraction
                }
            }
            let rootPath = root.standardizedFileURL.path + "/"
            let folderPath = folder.standardizedFileURL.path
            guard folderPath.hasPrefix(rootPath) else { throw ModelFailure("模型保存位置无效。") }
            let relative = String(folderPath.dropFirst(rootPath.count))
            try await WhisperKitTranscriptionService.shared.prepare(model: model, folder: folder, tokenizerFolder: root)
            try relative.write(to: root.appendingPathComponent("model-path.txt"), atomically: true, encoding: .utf8)
            guard modelFolder(for: model) != nil else { throw ModelFailure("模型文件不完整，请重新下载。") }
            revision += 1
        } catch {
            errors[model] = error.localizedDescription
        }
        progress[model] = nil
    }

    func remove(_ model: RecordingTranscriptionModel) async {
        guard progress[model] == nil, modelFolder(for: model) != nil else { return }
        await WhisperKitTranscriptionService.shared.unload()
        do {
            try FileManager.default.removeItem(at: root(for: model))
            errors[model] = nil
            revision += 1
        } catch { errors[model] = error.localizedDescription }
    }
}
