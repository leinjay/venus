import Foundation

enum RecordingOrigin: String, Codable {
    case iPhone
    case appleWatch
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
}

extension Notification.Name {
    static let watchRecordingArrived = Notification.Name("venus.recordings.watch-arrived")
}
