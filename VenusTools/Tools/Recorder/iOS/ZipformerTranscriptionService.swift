import Foundation
import SherpaOnnx
import SherpaOnnxC

enum ZipformerTranscriptionService {
    private static let sampleRate = 16_000

    private struct RecognitionResult: Decodable {
        let text: String
        let startTime: TimeInterval
        let timestamps: [TimeInterval]

        enum CodingKeys: String, CodingKey {
            case text, timestamps
            case startTime = "start_time"
        }
    }

    static func transcribe(_ url: URL, alignSpeakers: Bool = false) async throws -> TimestampedSpeechTranscript {
        let job = Task.detached(priority: .userInitiated) { try recognize(url, alignSpeakers: alignSpeakers) }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    private static func recognize(_ url: URL, alignSpeakers: Bool) throws -> TimestampedSpeechTranscript {
        guard let model = Bundle.main.url(forResource: "zipformer-model.int8", withExtension: "onnx", subdirectory: "RecorderModels"),
              let tokens = Bundle.main.url(forResource: "zipformer-tokens", withExtension: "txt", subdirectory: "RecorderModels") else {
            throw ModelFailure("安装包缺少内置中文转写模型。")
        }
        let modelConfig = sherpaOnnxOnlineModelConfig(
            tokens: "",
            zipformer2Ctc: sherpaOnnxOnlineZipformer2CtcModelConfig(),
            numThreads: 2
        )
        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: sampleRate),
            modelConfig: modelConfig,
            enableEndpoint: alignSpeakers,
            rule2MinTrailingSilence: 0.6,
            rule3MinUtteranceLength: 15
        )
        let handle = model.path.withCString { modelPath in
            tokens.path.withCString { tokensPath in
                config.model_config.zipformer2_ctc.model = modelPath
                config.model_config.tokens = tokensPath
                return SherpaOnnxCreateOnlineRecognizer(&config)
            }
        }
        guard let recognizer = handle else { throw ModelFailure("内置中文转写模型加载失败。") }
        defer { SherpaOnnxDestroyOnlineRecognizer(recognizer) }
        guard let stream = SherpaOnnxCreateOnlineStream(recognizer) else {
            throw ModelFailure("无法初始化本机音频识别。")
        }
        defer { SherpaOnnxDestroyOnlineStream(stream) }

        let decoder = JSONDecoder()
        var segments: [TimestampedSpeechSegment] = []
        func appendResult() throws {
            guard let json = SherpaOnnxGetOnlineStreamResultAsJson(recognizer, stream) else { return }
            defer { SherpaOnnxDestroyOnlineStreamResultJson(json) }
            let result = try decoder.decode(RecognitionResult.self, from: Data(String(cString: json).utf8))
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let first = result.timestamps.first ?? 0
            let last = result.timestamps.last ?? first
            segments.append(TimestampedSpeechSegment(
                start: result.startTime + first,
                duration: max(0.12, last - first + 0.12),
                text: text
            ))
        }
        func decodeAvailableAudio() throws {
            while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
                try Task.checkCancellation()
                SherpaOnnxDecodeOnlineStream(recognizer, stream)
                if SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) != 0 {
                    try appendResult()
                    SherpaOnnxOnlineStreamReset(recognizer, stream)
                }
            }
        }

        try RecorderAudioSamples.read(from: url, sampleRate: sampleRate) { samples in
            SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), samples, Int32(samples.count))
            try decodeAvailableAudio()
        }
        let tail = [Float](repeating: 0, count: sampleRate)
        SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), tail, Int32(tail.count))
        SherpaOnnxOnlineStreamInputFinished(stream)
        try decodeAvailableAudio()
        try appendResult()
        return TimestampedSpeechTranscript(text: segments.map(\.text).joined(separator: "\n"), segments: segments)
    }
}
