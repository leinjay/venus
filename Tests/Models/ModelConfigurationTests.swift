import XCTest
@testable import VenusModelCore

final class ModelConfigurationTests: XCTestCase {
    private func remote(_ adapter: ModelAdapter = .openAI) -> ModelConfiguration {
        var config = ModelConfiguration.defaults().last!
        config.adapter = adapter; config.credentialRef = "secure-reference"
        if adapter == .anthropic { config.baseURL = "https://api.anthropic.com/v1" }
        if adapter == .gemini { config.baseURL = "https://generativelanguage.googleapis.com/v1beta"; config.modelID = "gemini-test" }
        return config
    }
    private func body(_ config: ModelConfiguration) throws -> [String: Any] {
        let request = try ModelWire.request(config, key: "test-secret", system: "system text", prompt: "user text")
        return try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
    }
    func testNamesAreChineseUniqueTrimmedAndCaseInsensitive() throws {
        var first = remote(); first.name = "工作 TEST"
        try ModelValidation.validate(first, among: [])
        var second = first; second.id = UUID(); second.name = " 工作 test "
        XCTAssertThrowsError(try ModelValidation.validate(second, among: [first]))
        second.name = "Only English"; XCTAssertThrowsError(try ModelValidation.validate(second, among: []))
        second.name = "工作总结"; XCTAssertNoThrow(try ModelValidation.validate(second, among: [first]))
    }
    func testRenameKeepsCallIdentityWhileCredentialsAndGenerationInvalidateIt() {
        let original = remote(); var changed = original
        changed.name = "重命名"; changed.revision += 1; changed.updatedAt = Date().addingTimeInterval(10)
        XCTAssertEqual(original.fingerprint, changed.fingerprint)
        changed.credentialRef = "new-secret-reference"; XCTAssertNotEqual(original.fingerprint, changed.fingerprint)
        changed = original; changed.generation.maxTokens = 1234; XCTAssertNotEqual(original.fingerprint, changed.fingerprint)
        changed = original; changed.enabled = false; XCTAssertNotEqual(original.fingerprint, changed.fingerprint)
    }
    func testRemoteURLAndLANTrustBoundaries() throws {
        var config = remote()
        for url in ["http://api.example.com/v1", "https://user:pass@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1/chat/completions", "https://example.com/v1/chat/completions/"] {
            config.baseURL = url; XCTAssertThrowsError(try ModelValidation.validate(config, among: []), url)
        }
        config.execution = .lanService; config.requiresKey = false; config.baseURL = "http://192.168.10.2:11434/v1"
        XCTAssertNoThrow(try ModelValidation.validate(config, among: []))
        config.requiresKey = true; XCTAssertThrowsError(try ModelValidation.validate(config, among: []))
        config.requiresKey = false; config.baseURL = "https://public.example.com/v1"; XCTAssertThrowsError(try ModelValidation.validate(config, among: []))
        XCTAssertFalse(ModelValidation.isPrivateHost("172.32.0.1")); XCTAssertTrue(ModelValidation.isPrivateHost("172.16.0.1"))
    }
    func testBochaBodyMatchesSuppliedChatProtocolAndDoesNotPersistSecret() throws {
        let config = remote()
        let request = try ModelWire.request(config, key: "test-secret", system: "system text", prompt: "user text")
        XCTAssertEqual(request.url?.absoluteString, "https://api.bocha.cn/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        let object = try body(config)
        XCTAssertEqual(object["model"] as? String, "deepseek-v4-flash"); XCTAssertEqual(object["stream"] as? Bool, false)
        XCTAssertNil(object["max_tokens"]); XCTAssertNil(object["max_completion_tokens"])
        XCTAssertFalse(String(data: try JSONEncoder().encode(config), encoding: .utf8)!.contains("test-secret"))
        var capped = config; capped.generation.maxTokens = 100; capped.generation.tokenField = "max_completion_tokens"
        let cappedBody = try body(capped); XCTAssertEqual(cappedBody["max_completion_tokens"] as? Int, 100); XCTAssertNil(cappedBody["max_tokens"])
    }
    func testAnthropicAndGeminiUseDistinctAuthenticationAndShapes() throws {
        let anthropic = remote(.anthropic)
        let request = try ModelWire.request(anthropic, key: "test-secret", system: "system text", prompt: "user text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let object = try body(anthropic); XCTAssertEqual(object["system"] as? String, "system text"); XCTAssertEqual(object["max_tokens"] as? Int, 1024)
        let gemini = remote(.gemini)
        let geminiRequest = try ModelWire.request(gemini, key: "test-secret", system: "system text", prompt: "user text")
        XCTAssertEqual(geminiRequest.url?.path, "/v1beta/models/gemini-test:generateContent")
        XCTAssertEqual(geminiRequest.value(forHTTPHeaderField: "x-goog-api-key"), "test-secret")
        let g = try body(gemini); XCTAssertNotNil(g["contents"]); XCTAssertNotNil(g["systemInstruction"]); XCTAssertNil(g["messages"])
    }
    func testMalformedEmptyHTTPErrorAndTruncatedResponsesFail() throws {
        let config = remote()
        for value in ["<html>gateway</html>", "{}", "{\"error\":{}}", "{\"choices\":[{\"message\":{\"content\":\"partial\"},\"finish_reason\":\"length\"}]}"] {
            XCTAssertThrowsError(try ModelWire.response(Data(value.utf8), config: config, status: 200))
        }
        for status in [302, 401, 402, 429, 500] { XCTAssertThrowsError(try ModelWire.response(Data(), config: config, status: status)) }
        let valid = Data("{\"choices\":[{\"message\":{\"content\":\"有效结果\",\"reasoning_content\":\"private thinking\"},\"finish_reason\":\"stop\"}]}".utf8)
        XCTAssertEqual(try ModelWire.response(valid, config: config, status: 200), "有效结果")
    }
    func testStreamRequiresTerminationAndIgnoresReasoning() throws {
        var config = remote(); config.generation.stream = true
        let raw = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"正文\"}}]}\n\ndata: [DONE]\n\n"
        XCTAssertEqual(try ModelWire.response(Data(raw.utf8), config: config, status: 200), "正文")
        XCTAssertThrowsError(try ModelWire.response(Data(raw.replacingOccurrences(of: "data: [DONE]", with: "").utf8), config: config, status: 200))
    }
    func testManagedHeaderValuesCannotInjectHeaders() throws {
        XCTAssertThrowsError(try ModelWire.request(remote(), key: "bad\r\nHost: evil", system: "", prompt: ""))
        var config = remote(.anthropic); config.apiVersion = "2023-06-01\nX-Evil: value"
        XCTAssertThrowsError(try ModelWire.request(config, key: "test-secret", system: "", prompt: ""))
    }
    func testUnsupportedMediaTemplatesCannotBeEnabledOrUsedAsText() throws {
        let defaults = ModelConfiguration.defaults()
        XCTAssertEqual(Set(defaults.map { ModelValidation.nameKey($0.name) }).count, defaults.count)
        for var template in defaults.filter({ !$0.textCapable }) {
            XCTAssertFalse(template.enabled); XCTAssertNoThrow(try ModelValidation.validate(template, among: defaults))
            template.enabled = true; XCTAssertThrowsError(try ModelValidation.validate(template, among: defaults))
        }
    }
}
