import Foundation

enum RecordingOrigin: String, Codable {
    case iPhone
    case appleWatch
}

enum RecordingTranscriptionModel: String, CaseIterable, Identifiable, Codable, Hashable {
    case appleSpeech
    case whisperTiny
    case whisperBase
    case whisperSmall
    case whisperLargeTurbo
    case configuredService

    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .whisperTiny: return "Whisper Tiny"
        case .whisperBase: return "Whisper Base"
        case .whisperSmall: return "Whisper Small"
        case .whisperLargeTurbo: return "Whisper Large v3 Turbo"
        case .configuredService: return "自定义转写服务"
        }
    }
    var detail: String {
        switch self {
        case .appleSpeech: return "默认推荐 · 本机离线 · 无需下载 · 词级时间戳"
        case .whisperTiny: return "本机离线 · 轻量快速 · 分段时间戳 · 首次下载模型"
        case .whisperBase: return "本机离线 · 速度与准确度平衡 · 分段时间戳"
        case .whisperSmall: return "本机离线 · 更高准确度 · 分段时间戳 · 需要更多存储"
        case .whisperLargeTurbo: return "本机离线 · 准确度优先 · 分段时间戳 · 首次下载约 626 MB"
        case .configuredService: return "使用设置中绑定的服务 · 需先确认音频外发授权"
        }
    }
    var whisperModelName: String? {
        switch self {
        case .appleSpeech: return nil
        case .whisperTiny: return "tiny"
        case .whisperBase: return "base"
        case .whisperSmall: return "small"
        case .whisperLargeTurbo: return "large-v3-v20240930_626MB"
        case .configuredService: return nil
        }
    }
    var supportsWordTimestamps: Bool { self == .appleSpeech }
}

enum RecordingAnalysisRole: String, Codable, Hashable {
    case user
    case assistant
}

struct RecordingAnalysisMessage: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var role: RecordingAnalysisRole
    var text: String
    var createdAt: Date = .now
}

struct RecordingAnalysisArchive: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var recordingID: UUID
    var title: String
    var recordingCreatedAt: Date
    var savedAt: Date = .now
    var duration: TimeInterval
    var transcript: String
    var messages: [RecordingAnalysisMessage]

    var analysisPreview: String {
        messages.last(where: { $0.role == .assistant })?.text ?? "尚无分析回复"
    }
}

struct RecordingTranscriptLine: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var speakerID: Int?
    var text: String
}

enum RecordingVoiceEstimate: String, Codable, Sendable {
    case masculine
    case feminine
    case unknown

    var title: String {
        switch self {
        case .masculine: return "偏男声"
        case .feminine: return "偏女声"
        case .unknown: return "无法判断"
        }
    }

    var labelPrefix: String {
        switch self {
        case .masculine: return "男"
        case .feminine: return "女"
        case .unknown: return "说话人"
        }
    }
}

struct RecordingSpeakerProfile: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var speechDuration: TimeInterval
    var voiceEstimate: RecordingVoiceEstimate

    var label: String {
        let letter = String(UnicodeScalar(65 + (id % 26))!)
        return voiceEstimate == .unknown ? "说话人\(letter)" : "\(voiceEstimate.labelPrefix)\(letter)"
    }
}

struct RecordingAudioSegment: Codable, Identifiable, Equatable {
    var id: UUID
    var audioFileName: String
    var duration: TimeInterval
    var transcript: String
    var origin: RecordingOrigin
    var createdAt: Date
}

struct WatchRecordingTarget: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
}

struct VoiceRecording: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var audioFileName: String
    var transcript: String
    var summary: String
    var origin: RecordingOrigin
    var supplementalSegments: [RecordingAudioSegment] = []
    var supplementForID: UUID? = nil
    var baseTranscript: String? = nil
    var speakerTranscript: String? = nil
    var speakerCount: Int? = nil
    var transcriptLines: [RecordingTranscriptLine] = []
    var speakerProfiles: [RecordingSpeakerProfile] = []

    var audioFileNames: [String] { [audioFileName] + supplementalSegments.map(\.audioFileName) }
    var hasUntranscribedSupplement: Bool { supplementalSegments.contains { $0.transcript.isEmpty } }
    var transcriptForAnalysis: String { speakerTranscript ?? transcript }
}

extension VoiceRecording {
    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, duration, audioFileName, transcript, summary, origin, supplementalSegments, supplementForID, baseTranscript, speakerTranscript, speakerCount, transcriptLines, speakerProfiles
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        audioFileName = try values.decode(String.self, forKey: .audioFileName)
        transcript = try values.decode(String.self, forKey: .transcript)
        summary = try values.decode(String.self, forKey: .summary)
        origin = try values.decode(RecordingOrigin.self, forKey: .origin)
        supplementalSegments = try values.decodeIfPresent([RecordingAudioSegment].self, forKey: .supplementalSegments) ?? []
        supplementForID = try values.decodeIfPresent(UUID.self, forKey: .supplementForID)
        baseTranscript = try values.decodeIfPresent(String.self, forKey: .baseTranscript)
        speakerTranscript = try values.decodeIfPresent(String.self, forKey: .speakerTranscript)
        speakerCount = try values.decodeIfPresent(Int.self, forKey: .speakerCount)
        transcriptLines = try values.decodeIfPresent([RecordingTranscriptLine].self, forKey: .transcriptLines) ?? []
        speakerProfiles = try values.decodeIfPresent([RecordingSpeakerProfile].self, forKey: .speakerProfiles) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(duration, forKey: .duration)
        try values.encode(audioFileName, forKey: .audioFileName)
        try values.encode(transcript, forKey: .transcript)
        try values.encode(summary, forKey: .summary)
        try values.encode(origin, forKey: .origin)
        try values.encode(supplementalSegments, forKey: .supplementalSegments)
        try values.encodeIfPresent(supplementForID, forKey: .supplementForID)
        try values.encodeIfPresent(baseTranscript, forKey: .baseTranscript)
        try values.encodeIfPresent(speakerTranscript, forKey: .speakerTranscript)
        try values.encodeIfPresent(speakerCount, forKey: .speakerCount)
        try values.encode(transcriptLines, forKey: .transcriptLines)
        try values.encode(speakerProfiles, forKey: .speakerProfiles)
    }
}

struct VoiceRecordingCatalog: Codable {
    var schema = 1
    var recordings: [VoiceRecording] = []
}

enum RecordingStorage {
    static var root: URL {
        #if os(watchOS)
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VenusRecordings", isDirectory: true)
        #else
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VenusRecordings", isDirectory: true)
        #endif
    }

    static var audioDirectory: URL { root.appendingPathComponent("Audio", isDirectory: true) }
    static var incomingDirectory: URL { root.appendingPathComponent("Incoming", isDirectory: true) }
    static var catalogURL: URL { root.appendingPathComponent("recordings-v1.json") }
    static var analysisHistoryURL: URL { root.appendingPathComponent("analysis-history-v1.json") }

    static func prepare() throws {
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incomingDirectory, withIntermediateDirectories: true)
    }

    static func audioURL(for recording: VoiceRecording) -> URL {
        audioDirectory.appendingPathComponent(recording.audioFileName)
    }

    static func audioURLs(for recording: VoiceRecording) -> [URL] {
        recording.audioFileNames.map { audioDirectory.appendingPathComponent($0) }
    }
}

extension Notification.Name {
    static let watchRecordingArrived = Notification.Name("venus.recordings.watch-arrived")
}
