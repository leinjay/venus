import Foundation
import WhisperKit

actor WhisperKitTranscriptionService {
    static let shared = WhisperKitTranscriptionService()

    private var loadedModelName: String?
    private var pipeline: WhisperKit?

    func transcribe(_ url: URL, model: RecordingTranscriptionModel) async throws -> TimestampedSpeechTranscript {
        guard let modelName = model.whisperModelName else {
            throw ModelFailure("请选择 Whisper 模型后再转写。")
        }

        if loadedModelName != modelName || pipeline == nil {
            pipeline = nil
            let config = WhisperKitConfig(model: modelName, verbose: false, useBackgroundDownloadSession: true)
            pipeline = try await WhisperKit(config)
            loadedModelName = modelName
        }
        guard let pipeline else { throw ModelFailure("Whisper 模型加载失败，请重试。") }

        let results = try await pipeline.transcribe(
            audioPath: url.path,
            decodeOptions: DecodingOptions(wordTimestamps: true, language: "zh")
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
