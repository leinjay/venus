import AVFoundation
import CryptoKit
import Foundation
import SherpaOnnx

struct TimestampedSpeechSegment: Sendable {
    let start: TimeInterval
    let duration: TimeInterval
    let text: String
}

struct TimestampedSpeechTranscript: Sendable {
    let text: String
    let segments: [TimestampedSpeechSegment]
}

struct SpeakerDiarizationOutput: Sendable {
    let transcript: String
    let speakerCount: Int
}

enum SpeakerDiarizationService {
    private static let sampleRate = 16_000
    private static let interClipSilence = 0.6
    private static let modelDirectory = RecordingStorage.root
        .appendingPathComponent("Models", isDirectory: true)
        .appendingPathComponent("SpeakerDiarization", isDirectory: true)

    private struct ModelFile: Sendable {
        let name: String
        let url: URL
        let sha256: String
        let minimumBytes: Int
    }

    private static let segmentationModel = ModelFile(
        name: "segmentation.int8.onnx",
        url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/9403a6902bb58e3d5ae8c7e77c3422de279db2e0/model.int8.onnx")!,
        sha256: "d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d",
        minimumBytes: 1_000_000
    )

    private static let embeddingModel = ModelFile(
        name: "speaker-embedding.zh.onnx",
        url: URL(string: "https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/8be2a75c9ed7a590538b268e46fbb65e1aa9d208/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx")!,
        sha256: "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b",
        minimumBytes: 30_000_000
    )

    static func diarize(
        audioURLs: [URL],
        transcripts: [TimestampedSpeechTranscript],
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> SpeakerDiarizationOutput {
        guard !audioURLs.isEmpty, audioURLs.count == transcripts.count else {
            throw ModelFailure("录音片段不完整，请重新尝试区分说话人。")
        }
        let totalDuration = try audioURLs.reduce(0.0) { total, url in
            total + (try duration(of: url))
        }
        guard totalDuration <= 60 * 60 else {
            throw ModelFailure("单次最多区分 60 分钟录音，请减少补录片段后重试。")
        }
        onStatus("正在检查分人模型（首次下载约 41 MB）…")
        let modelPaths = try await ensureModels()
        return try await Task.detached(priority: .userInitiated) {
            onStatus("模型已就绪，正在本机分析说话人…")
            try runDiarization(audioURLs: audioURLs, transcripts: transcripts, modelPaths: modelPaths)
        }.value
    }

    private static func ensureModels() async throws -> (segmentation: URL, embedding: URL) {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        var directoryURL = modelDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directoryURL.setResourceValues(values)

        async let segmentation = ensureModel(segmentationModel)
        async let embedding = ensureModel(embeddingModel)
        return try await (segmentation, embedding)
    }

    private static func ensureModel(_ model: ModelFile) async throws -> URL {
        let destination = modelDirectory.appendingPathComponent(model.name)
        if isValidModel(at: destination, model: model) { return destination }
        try? FileManager.default.removeItem(at: destination)

        var request = URLRequest(url: model.url)
        request.timeoutInterval = 180
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw ModelFailure("说话人模型下载失败，请检查网络后重试。")
        }
        guard isValidModel(at: temporaryURL, model: model) else {
            throw ModelFailure("下载的说话人模型校验失败，请重试。")
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path
        )
        return destination
    }

    private static func isValidModel(at url: URL, model: ModelFile) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= model.minimumBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == model.sha256
    }

    private struct TimedSpeakerText {
        var start: TimeInterval
        var end: TimeInterval
        var speaker: Int
        var text: String
    }

    private static func runDiarization(
        audioURLs: [URL],
        transcripts: [TimestampedSpeechTranscript],
        modelPaths: (segmentation: URL, embedding: URL)
    ) throws -> SpeakerDiarizationOutput {
        let durations = try audioURLs.map { try duration(of: $0) }
        let totalDuration = durations.reduce(0, +)

        var estimatedFrames = Int(totalDuration * Double(sampleRate))
        if audioURLs.count > 1 { estimatedFrames += Int(Double(sampleRate) * interClipSilence * Double(audioURLs.count - 1)) }
        var samples = [Float]()
        samples.reserveCapacity(estimatedFrames)
        var clipOffsets: [TimeInterval] = []
        for (index, url) in audioURLs.enumerated() {
            clipOffsets.append(Double(samples.count) / Double(sampleRate))
            try appendResampledSamples(from: url, into: &samples)
            if index < audioURLs.count - 1 {
                samples.append(contentsOf: repeatElement(0, count: Int(Double(sampleRate) * interClipSilence)))
            }
        }
        guard !samples.isEmpty else { throw ModelFailure("录音没有可分析的音频数据。") }

        let pyannote = sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
            model: modelPaths.segmentation.path,
            windowShiftRatio: 0.1
        )
        let segmentation = sherpaOnnxOfflineSpeakerSegmentationModelConfig(
            pyannote: pyannote,
            numThreads: 2,
            provider: "cpu"
        )
        let embedding = sherpaOnnxSpeakerEmbeddingExtractorConfig(
            model: modelPaths.embedding.path,
            numThreads: 2,
            provider: "cpu"
        )
        let clustering = sherpaOnnxFastClusteringConfig(numClusters: -1, threshold: 0.5)
        var config = sherpaOnnxOfflineSpeakerDiarizationConfig(
            segmentation: segmentation,
            embedding: embedding,
            clustering: clustering,
            minDurationOn: 0.3,
            minDurationOff: 0.5
        )
        let diarizer = withUnsafePointer(to: &config) {
            SherpaOnnxOfflineSpeakerDiarizationWrapper(config: $0)
        }
        guard diarizer.sampleRate == sampleRate else { throw ModelFailure("说话人模型采样率不匹配。") }
        let speakerSegments = diarizer.process(samples: samples)
        let speakers = Set(speakerSegments.map(\.speaker))

        var recognized: [TimedSpeakerText] = []
        for clipIndex in transcripts.indices {
            for word in transcripts[clipIndex].segments {
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let paddedStart = clipOffsets[clipIndex] + max(0, word.start)
                let paddedEnd = paddedStart + max(0.05, word.duration)
                let midpoint = (paddedStart + paddedEnd) / 2
                let closest = speakerSegments.max { lhs, rhs in
                    overlap(lhs.start, lhs.end, paddedStart, paddedEnd) < overlap(rhs.start, rhs.end, paddedStart, paddedEnd)
                }
                var speaker = -1
                if let closest {
                    let intersection = overlap(closest.start, closest.end, paddedStart, paddedEnd)
                    let closestStart = TimeInterval(closest.start)
                    let closestEnd = TimeInterval(closest.end)
                    let gap = midpoint < closestStart ? closestStart - midpoint : (midpoint > closestEnd ? midpoint - closestEnd : 0)
                    if intersection > 0 || gap <= 0.45 { speaker = closest.speaker }
                }
                let unpaddedStart = max(0, paddedStart - Double(clipIndex) * interClipSilence)
                let unpaddedEnd = max(unpaddedStart, paddedEnd - Double(clipIndex) * interClipSilence)
                recognized.append(TimedSpeakerText(start: unpaddedStart, end: unpaddedEnd, speaker: speaker, text: text))
            }
        }
        guard !recognized.isEmpty else { throw ModelFailure("本机离线识别没有找到可对齐的文字。") }
        recognized.sort { $0.start < $1.start }

        var turns: [TimedSpeakerText] = []
        for word in recognized {
            if let last = turns.indices.last,
               turns[last].speaker == word.speaker,
               word.start - turns[last].end <= 1.2 {
                turns[last].text += word.text
                turns[last].end = max(turns[last].end, word.end)
            } else {
                turns.append(word)
            }
        }
        let formatted = turns.map { turn in
            "[\(timeLabel(turn.start))] \(turn.speaker < 0 ? "未区分" : "说话人 \(turn.speaker + 1)")：\(turn.text)"
        }.joined(separator: "\n")
        guard !formatted.isEmpty else { throw ModelFailure("没有生成说话人转写结果。") }
        return SpeakerDiarizationOutput(transcript: formatted, speakerCount: speakers.count)
    }

    private static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate > 0 else { throw ModelFailure("录音采样率无法读取。") }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func overlap(_ lhsStart: Float, _ lhsEnd: Float, _ rhsStart: TimeInterval, _ rhsEnd: TimeInterval) -> TimeInterval {
        max(0, min(TimeInterval(lhsEnd), rhsEnd) - max(TimeInterval(lhsStart), rhsStart))
    }

    private static func timeLabel(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time))
        if totalSeconds >= 3600 { return String(format: "%d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60) }
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private static func appendResampledSamples(from url: URL, into samples: inout [Float]) throws {
        let input = try AVAudioFile(forReading: url)
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: outputFormat) else {
            throw ModelFailure("录音格式无法转换为说话人模型需要的音频格式。")
        }
        var finished = false
        while !finished {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_384) else {
                throw ModelFailure("无法分配音频缓冲区。")
            }
            var conversionError: NSError?
            var readError: Error?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard input.framePosition < input.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let remaining = input.length - input.framePosition
                let framesToRead = AVAudioFrameCount(min(Int64(16_384), remaining))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: framesToRead) else {
                    readError = ModelFailure("无法读取录音片段")
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                do {
                    try input.read(into: buffer, frameCount: framesToRead)
                } catch {
                    readError = error
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if status == .error { throw ModelFailure("音频转换失败。") }
            if let channel = output.floatChannelData?.pointee, output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream {
                finished = true
            } else if output.frameLength == 0 {
                throw ModelFailure("音频转换没有产生数据。")
            }
        }
    }
}
