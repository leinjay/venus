import AVFoundation
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
    let lines: [RecordingTranscriptLine]
    let speakerProfiles: [RecordingSpeakerProfile]
}

enum SpeakerDiarizationService {
    private static let sampleRate = 16_000
    private static let interClipSilence = 0.6

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
        guard let segmentation = Bundle.main.url(forResource: "segmentation.int8", withExtension: "onnx", subdirectory: "RecorderModels"),
              let embedding = Bundle.main.url(forResource: "speaker-embedding.zh", withExtension: "onnx", subdirectory: "RecorderModels") else {
            throw ModelFailure("安装包缺少内置说话人模型。")
        }
        return try await Task.detached(priority: .userInitiated) {
            onStatus("正在用内置模型区分说话人…")
            return try runDiarization(audioURLs: audioURLs, transcripts: transcripts, modelPaths: (segmentation, embedding))
        }.value
    }

    private struct TimedSpeakerText {
        var start: TimeInterval
        var end: TimeInterval
        var speaker: Int
        var text: String
    }

    private struct SpeakerInterval {
        var start: TimeInterval
        var end: TimeInterval
        var speaker: Int
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
            try RecorderAudioSamples.read(from: url, sampleRate: sampleRate) { samples.append(contentsOf: $0) }
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
        let intervals = speakerSegments.map {
            SpeakerInterval(start: TimeInterval($0.start), end: TimeInterval($0.end), speaker: Int($0.speaker))
        }
        let speakers = Set(intervals.map(\.speaker))

        var recognized: [TimedSpeakerText] = []
        for clipIndex in transcripts.indices {
            for word in transcripts[clipIndex].segments {
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let paddedStart = clipOffsets[clipIndex] + max(0, word.start)
                let paddedEnd = paddedStart + max(0.05, word.duration)
                let midpoint = (paddedStart + paddedEnd) / 2
                let closest = intervals.max { lhs, rhs in
                    overlap(lhs.start, lhs.end, paddedStart, paddedEnd) < overlap(rhs.start, rhs.end, paddedStart, paddedEnd)
                }
                var speaker = -1
                if let closest {
                    let intersection = overlap(closest.start, closest.end, paddedStart, paddedEnd)
                    let gap = midpoint < closest.start ? closest.start - midpoint : (midpoint > closest.end ? midpoint - closest.end : 0)
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
        let profiles = speakers.sorted().map { speaker in
            let duration = intervals.filter { $0.speaker == speaker }.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            return RecordingSpeakerProfile(
                id: speaker,
                speechDuration: duration,
                voiceEstimate: estimateVoice(in: samples, intervals: intervals, speaker: speaker)
            )
        }
        let profileByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let lines = turns.map { turn in
            RecordingTranscriptLine(start: turn.start, end: turn.end, speakerID: turn.speaker >= 0 ? turn.speaker : nil, text: turn.text)
        }
        let formatted = turns.map { turn in
            let speakerLabel = turn.speaker < 0 ? "未区分" : (profileByID[turn.speaker]?.label ?? "说话人 \(turn.speaker + 1)")
            return "[\(timeLabel(turn.start))] \(speakerLabel)：\(turn.text)"
        }.joined(separator: "\n")
        guard !formatted.isEmpty else { throw ModelFailure("没有生成说话人转写结果。") }
        return SpeakerDiarizationOutput(transcript: formatted, speakerCount: speakers.count, lines: lines, speakerProfiles: profiles)
    }

    private static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate > 0 else { throw ModelFailure("录音采样率无法读取。") }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func overlap(_ lhsStart: TimeInterval, _ lhsEnd: TimeInterval, _ rhsStart: TimeInterval, _ rhsEnd: TimeInterval) -> TimeInterval {
        max(0, min(lhsEnd, rhsEnd) - max(lhsStart, rhsStart))
    }

    private static func estimateVoice(in samples: [Float], intervals: [SpeakerInterval], speaker: Int) -> RecordingVoiceEstimate {
        let frameSize = 512
        let frameDuration = Double(frameSize) / Double(sampleRate)
        var pitches: [Double] = []
        for interval in intervals where interval.speaker == speaker && interval.end - interval.start >= frameDuration {
            let available = max(1, Int((interval.end - interval.start) / 0.7))
            let sampleCount = min(3, available)
            for index in 0..<sampleCount {
                let center = interval.start + (Double(index + 1) / Double(sampleCount + 1)) * (interval.end - interval.start)
                let start = max(0, Int((center - frameDuration / 2) * Double(sampleRate)))
                guard start + frameSize <= samples.count else { continue }
                if let pitch = pitch(in: samples[start..<(start + frameSize)]) { pitches.append(pitch) }
                if pitches.count >= 60 { break }
            }
            if pitches.count >= 60 { break }
        }
        guard !pitches.isEmpty else { return .unknown }
        pitches.sort()
        let median = pitches[pitches.count / 2]
        if median < 150 { return .masculine }
        if median > 185 { return .feminine }
        return .unknown
    }

    private static func pitch(in frame: ArraySlice<Float>) -> Double? {
        let values = Array(frame)
        let mean = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        let centered = values.map { Double($0) - mean }
        let energy = centered.reduce(0.0) { $0 + $1 * $1 }
        guard energy > 0.0001 else { return nil }
        let minimumLag = sampleRate / 350
        let maximumLag = min(sampleRate / 70, centered.count / 2)
        var bestLag = 0
        var bestScore = 0.0
        for lag in minimumLag...maximumLag {
            var product = 0.0
            var leftEnergy = 0.0
            var rightEnergy = 0.0
            for index in 0..<(centered.count - lag) {
                let left = centered[index]
                let right = centered[index + lag]
                product += left * right
                leftEnergy += left * left
                rightEnergy += right * right
            }
            let score = product / sqrt(max(0.0000001, leftEnergy * rightEnergy))
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        guard bestLag > 0, bestScore >= 0.4 else { return nil }
        return Double(sampleRate) / Double(bestLag)
    }

    private static func timeLabel(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time))
        if totalSeconds >= 3600 { return String(format: "%d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60) }
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

}

enum RecorderAudioSamples {
    static func read(from url: URL, sampleRate: Int, consume: ([Float]) throws -> Void) throws {
        let input = try AVAudioFile(forReading: url)
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: outputFormat) else {
            throw ModelFailure("录音格式无法转换为离线模型需要的音频格式。")
        }
        var finished = false
        while !finished {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_384) else {
                throw ModelFailure("无法分配音频缓冲区。")
            }
            var conversionError: NSError?
            var readError: Error?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                guard input.framePosition < input.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let remaining = input.length - input.framePosition
                let framesToRead = AVAudioFrameCount(min(Int64(requested), remaining))
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
                guard buffer.frameLength > 0 else {
                    readError = ModelFailure("录音文件意外结束。")
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if status == .error { throw ModelFailure("音频转换失败。") }
            if let channel = output.floatChannelData?.pointee, output.frameLength > 0 {
                try consume(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
            }
            if status == .endOfStream {
                finished = true
            } else if output.frameLength == 0 {
                throw ModelFailure("音频转换没有产生数据。")
            }
        }
    }
}
