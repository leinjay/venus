import XCTest
@testable import VenusTaskCore

final class TaskConversationTests: XCTestCase {
    func testLegacyMessagesAndDraftsDecodeWithoutNewFields() throws {
        let id = UUID()
        let message = try JSONDecoder().decode(TaskMessage.self, from: Data("{\"id\":\"\(id)\",\"isUser\":true,\"text\":\"以前的输入\"}".utf8))
        XCTAssertEqual(message.id, id); XCTAssertNil(message.state); XCTAssertNil(message.date)
        var draft = TaskDraft(); draft.messages = [message]
        let data = try JSONEncoder().encode(draft)
        let restored = try JSONDecoder().decode(TaskDraft.self, from: data)
        XCTAssertEqual(restored.messages[0].text, "以前的输入"); XCTAssertNil(restored.audio)
    }
    func testConversationSurvivesDraftRemovalAndRetainsIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = TaskConversationArchive(directory: directory)
        var conversation = TaskConversation(taskID: UUID(), messages: [TaskMessage(isUser: true, text: "明天取快递", state: .complete)])
        try archive.save(conversation)
        let draftURL = directory.appendingPathComponent("draft-new.json")
        try JSONEncoder().encode(TaskDraft()).write(to: draftURL)
        try FileManager.default.removeItem(at: draftURL)
        conversation.messages.append(TaskMessage(isUser: false, text: "已整理", state: .complete))
        try archive.save(conversation)
        let restored = try XCTUnwrap(archive.load(conversation.taskID))
        XCTAssertEqual(restored.id, conversation.id); XCTAssertEqual(restored.messages.map(\.text), ["明天取快递", "已整理"])
        var other = conversation; other.id = UUID()
        XCTAssertThrowsError(try archive.save(other))
        XCTAssertEqual(try archive.load(conversation.taskID)?.id, conversation.id)
        try archive.remove(conversation.taskID); XCTAssertNil(try archive.load(conversation.taskID))
    }
    func testInterruptedRepliesRecoverAsStoppedAndWrongTaskCannotLoad() throws {
        let messages = [TaskMessage(isUser: true, text: "输入", state: .complete), TaskMessage(isUser: false, text: "部分文字", state: .receiving)]
        let recovered = TaskConversation.recovered(messages)
        XCTAssertEqual(recovered.map(\.id), messages.map(\.id)); XCTAssertEqual(recovered.last?.state, .stopped)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = UUID(), wrong = TaskConversation(taskID: UUID(), messages: messages)
        let file = directory.appendingPathComponent("conversation-\(expected.uuidString).json")
        let original = try JSONEncoder().encode(wrong); try original.write(to: file)
        XCTAssertThrowsError(try TaskConversationArchive(directory: directory).load(expected))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testDisabledDictationHasActionableChineseRecoveryMessage() {
        let message = TaskSpeechIssue.message(domain: "kLSRErrorDomain", code: 201)
        XCTAssertTrue(message.contains("启用听写")); XCTAssertTrue(message.contains("音频转写模型")); XCTAssertFalse(message.contains("are disabled"))
    }
    func testReadingConversationAloneDoesNotLeaveTaskLockedByAnEmptyDraft() {
        var task = ReminderItem(); task.title = "已保存任务"
        var draft = TaskDraft(); draft.task = task; draft.base = task
        draft.messages = [TaskMessage(isUser: false, text: "以前的对话", state: .complete)]
        XCTAssertFalse(draft.hasPendingEdits)
        draft.input = "新的输入"; XCTAssertTrue(draft.hasPendingEdits)
        draft.input = ""; draft.audio = TaskAudio(filename: "audio-test.m4a"); XCTAssertTrue(draft.hasPendingEdits)
        draft.audio = nil; draft.task.title = "未保存修改"; XCTAssertTrue(draft.hasPendingEdits)
    }
}
