import XCTest
@testable import VenusModelCore

final class ModelConversationTests: XCTestCase {
    private func config(_ adapter: ModelAdapter = .openAI) -> ModelConfiguration {
        var value = ModelConfiguration.defaults().last!
        value.adapter = adapter
        return value
    }
    private func packet(_ value: [String: Any]) throws -> String {
        "data: " + String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)! + "\r\n\r\n"
    }
    func testStreamSplitsChineseUTF8AndPublishesBeforeCompletion() throws {
        var decoder = ModelStreamDecoder(adapter: .openAI)
        let first = try packet(["choices": [["delta": ["content": "{\"message\":\"已整理"]]]])
        for byte in first.utf8 { _ = try decoder.append(byte) }
        XCTAssertEqual(ModelReplyPreview.message(in: decoder.text), "已整理")
        let second = try packet(["choices": [["delta": ["content": "到草稿\",\"changes\":{}}"], "finish_reason": "stop"]]])
        for byte in second.utf8 { _ = try decoder.append(byte) }
        XCTAssertThrowsError(try decoder.finish())
        for byte in "data: [DONE]\n\n".utf8 { _ = try decoder.append(byte) }
        XCTAssertEqual(try decoder.finish(), "{\"message\":\"已整理到草稿\",\"changes\":{}}")
    }
    func testPreviewHidesAttributesThinkingAndIncompleteEscapes() {
        XCTAssertEqual(ModelReplyPreview.message(in: "{\"changes\":{\"message\":\"秘密字段\"},\"message\":\"需要几点提醒？"), "需要几点提醒？")
        XCTAssertEqual(ModelReplyPreview.message(in: "<think>秘密推理 {\"message\":\"不要显示\"}"), "")
        XCTAssertEqual(ModelReplyPreview.message(in: "<think>隐藏</think>{\"message\":\"请确认"), "请确认")
        XCTAssertEqual(ModelReplyPreview.message(in: "```json\n{\"message\":\"第一行\\n第二行\\"), "第一行\n第二行")
        XCTAssertEqual(ModelReplyPreview.message(in: #"{"message":"确认\uD83D"#), "确认")
        XCTAssertEqual(ModelReplyPreview.message(in: #"{"message":"确认\uD83D\uDE00"#), "确认😀")
        XCTAssertEqual(ModelReplyPreview.message(in: #"{"message":"他说\"明天\"","changes":{"title":"内部标题"}}"#), "他说\"明天\"")
        XCTAssertEqual(ModelReplyPreview.message(in: "not JSON {\"message\":\"hidden\"}"), "")
    }
    func testThinkingAndBrokenStreamNeverBecomeVisibleTaskReply() throws {
        var decoder = ModelStreamDecoder(adapter: .openAI)
        for byte in try packet(["choices": [["delta": ["reasoning_content": "private reasoning"]]]]).utf8 { _ = try decoder.append(byte) }
        XCTAssertEqual(decoder.text, "")
        XCTAssertThrowsError(try decoder.finish())
        let truncated = try packet(["choices": [["delta": ["content": "partial"], "finish_reason": "length"]]])
        XCTAssertThrowsError(try ModelWire.response(Data((truncated + "data: [DONE]\n\n").utf8), config: { var c = config(); c.generation.stream = true; return c }(), status: 200))
    }
    func testAnthropicAndGeminiStreamsAndErrorEvents() throws {
        var anthropic = ModelStreamDecoder(adapter: .anthropic)
        let text = try packet(["type": "content_block_delta", "delta": ["type": "text_delta", "text": "结果"]])
        for byte in (text + "event: message_stop\n\n").utf8 { _ = try anthropic.append(byte) }
        XCTAssertThrowsError(try anthropic.finish())
        for byte in try packet(["type": "message_stop"]).utf8 { _ = try anthropic.append(byte) }
        XCTAssertEqual(try anthropic.finish(), "结果")
        var gemini = ModelStreamDecoder(adapter: .gemini)
        for byte in try packet(["candidates": [["content": ["parts": [["text": "不显示", "thought": true], ["text": "正文"]]], "finishReason": "STOP"]]]).utf8 { _ = try gemini.append(byte) }
        XCTAssertEqual(try gemini.finish(), "正文")
        var failed = ModelStreamDecoder(adapter: .anthropic)
        XCTAssertThrowsError(try Array(packet(["type": "error", "error": ["type": "overloaded"]]).utf8).forEach { _ = try failed.append($0) })
    }
    func testAudioBindingMatchesOnlyAudioAdapterAndHasSeparateConsent() {
        var speech = config(.transcription); speech.textCapable = false
        XCTAssertTrue(ModelPurpose.transcription.accepts(speech))
        XCTAssertFalse(ModelPurpose.dialogue.accepts(speech))
        XCTAssertFalse(ModelPurpose.transcription.accepts(config()))
        XCTAssertNotEqual(ModelPurpose.transcription.binding, ModelPurpose.dialogue.binding)
        XCTAssertTrue(ModelPurpose.transcription.disclosure.contains("录音"))
    }
    func testTranscriptionMultipartUsesAudioRouteAndNeverChatParameters() throws {
        var speech = config(.transcription); speech.textCapable = false
        let audio = Data([0, 1, 2, 3])
        let request = try ModelTranscriptionWire.request(speech, key: "test-secret", audio: audio)
        XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/form-data; boundary="))
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertNotNil(body.range(of: audio))
        let text = String(data: body, encoding: .utf8)!
        XCTAssertTrue(text.contains("name=\"model\"")); XCTAssertTrue(text.contains("recording.m4a"))
        XCTAssertFalse(text.contains("messages")); XCTAssertFalse(text.contains("test-secret")); XCTAssertFalse(text.contains("max_tokens"))
        XCTAssertThrowsError(try ModelWire.request(speech, key: "test-secret", system: "", prompt: ""))
        speech.generation.stream = true; XCTAssertThrowsError(try ModelValidation.validate(speech, among: []))
    }
    func testTranscriptionRejectsEmptyHTMLAndErrorBodies() throws {
        var speech = config(.transcription); speech.textCapable = false
        XCTAssertEqual(try ModelTranscriptionWire.response(Data("{\"text\":\" 去取快递 \"}".utf8), config: speech, status: 200), "去取快递")
        for body in ["<html>OK</html>", "{\"text\":\" \"}", "{\"error\":{}}", "{\"choices\":[]}"] {
            XCTAssertThrowsError(try ModelTranscriptionWire.response(Data(body.utf8), config: speech, status: 200))
        }
        XCTAssertThrowsError(try ModelTranscriptionWire.response(Data(), config: speech, status: 401))
        speech.baseURL += "/audio/transcriptions"; XCTAssertThrowsError(try ModelValidation.validate(speech, among: []))
    }
}
