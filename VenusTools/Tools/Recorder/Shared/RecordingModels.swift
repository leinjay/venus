import Foundation

enum RecordingOrigin: String, Codable {
    case iPhone
    case appleWatch
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

    var audioFileNames: [String] { [audioFileName] + supplementalSegments.map(\.audioFileName) }
    var hasUntranscribedSupplement: Bool { supplementalSegments.contains { $0.transcript.isEmpty } }
    var transcriptForAnalysis: String { speakerTranscript ?? transcript }
}

extension VoiceRecording {
    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, duration, audioFileName, transcript, summary, origin, supplementalSegments, supplementForID, baseTranscript, speakerTranscript, speakerCount
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
