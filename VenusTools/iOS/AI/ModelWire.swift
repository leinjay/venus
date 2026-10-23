import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ModelWire {
    static func request(_ config: ModelConfiguration, key: String?, system: String, prompt: String, deadline: TimeInterval = 60) throws -> URLRequest {
        try ModelValidation.validate(config, among: [])
        guard config.execution != .onDevice else { throw ModelFailure("本机模型不使用网络请求") }
        try ModelValidation.validateKey(key ?? "")
        if config.requiresKey, key?.isEmpty != false { throw ModelFailure("此配置缺少密钥，请在设置中填写") }
        let root = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let g = config.generation
        var body: [String: Any]
        var address: String
        switch config.adapter {
        case .openAI:
            address = root + "/chat/completions"
            body = ["model": config.modelID, "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]], "stream": g.stream]
            if let n = g.maxTokens { body[g.tokenField] = n }
            if let t = g.temperature { body["temperature"] = t }
            if let p = g.topP { body["top_p"] = p }
            if !g.stop.isEmpty { body["stop"] = g.stop }
            if g.jsonOutput { body["response_format"] = ["type": "json_object"] }
        case .anthropic:
            address = root + "/messages"
            body = ["model": config.modelID, "system": system, "messages": [["role": "user", "content": prompt]], "max_tokens": g.maxTokens ?? 1024, "stream": g.stream]
            if !g.stop.isEmpty { body["stop_sequences"] = g.stop }
        case .gemini:
            guard config.modelID.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { throw ModelFailure("Gemini 模型标识包含不支持的路径字符") }
            address = root + "/models/" + config.modelID + (g.stream ? ":streamGenerateContent?alt=sse" : ":generateContent")
            body = ["systemInstruction": ["parts": [["text": system]]], "contents": [["role": "user", "parts": [["text": prompt]]]]]
            var generation: [String: Any] = [:]
            if let n = g.maxTokens { generation["maxOutputTokens"] = n }
            if let t = g.temperature { generation["temperature"] = t }
            if let p = g.topP { generation["topP"] = p }
            if !g.stop.isEmpty { generation["stopSequences"] = g.stop }
            if g.jsonOutput { generation["responseMimeType"] = "application/json" }
            if !generation.isEmpty { body["generationConfig"] = generation }
        case .mlx, .transcription: throw ModelFailure("此配置不支持文字对话，请选择文字模型")
        }
        guard let url = URL(string: address) else { throw ModelFailure("服务地址无效") }
        var request = URLRequest(url: url, timeoutInterval: min(Double(config.timeoutSeconds), deadline))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if config.requiresKey, let key {
            switch config.adapter {
            case .openAI: request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            case .anthropic: request.setValue(key, forHTTPHeaderField: "x-api-key")
            case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            case .mlx, .transcription: break
            }
        }
        if config.adapter == .anthropic { request.setValue(config.apiVersion, forHTTPHeaderField: "anthropic-version") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func response(_ data: Data, config: ModelConfiguration, status: Int) throws -> String {
        guard data.count <= 2_000_000 else { throw ModelFailure("响应过大，请降低输出上限") }
        guard (200...299).contains(status) else {
            switch status {
            case 401, 403: throw ModelFailure("鉴权失败（\(status)），请检查密钥和模型权限")
            case 402: throw ModelFailure("服务余额不足（402），请检查服务商账户")
            case 429:
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let error = object?["error"] as? [String: Any]
                let code = (error?["code"] as? String ?? error?["type"] as? String ?? "").lowercased()
                if code.contains("quota") || code.contains("balance") { throw ModelFailure("服务额度或余额不足（429），请检查服务商账户") }
                throw ModelFailure("服务限流（429），请稍后重试并检查额度")
            case 404: throw ModelFailure("模型或接口不存在（404），请检查模型 ID 和 API 根路径")
            case 300...399: throw ModelFailure("服务返回重定向，已停止请求，请检查 API 根地址")
            case 500...599: throw ModelFailure("模型服务暂不可用（\(status)），稍后重试")
            default: throw ModelFailure("服务拒绝请求（\(status)），请核对模型、协议和参数")
            }
        }
        if config.generation.stream { return try stream(data, config: config) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil else { throw ModelFailure("服务未返回有效模型 JSON 响应") }
        let text = try content(object, adapter: config.adapter)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelFailure("模型返回了空结果或不兼容格式") }
        return text
    }

    static func content(_ object: [String: Any], adapter: ModelAdapter) throws -> String {
        switch adapter {
        case .openAI:
            guard let first = (object["choices"] as? [[String: Any]])?.first else { return "" }
            if first["finish_reason"] as? String == "length" { throw ModelFailure("输出被截断，请增加输出上限或缩短输入") }
            let message = (first["message"] as? [String: Any]) ?? (first["delta"] as? [String: Any]) ?? [:]
            if let value = message["content"] as? String { return value }
            return (message["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case .anthropic:
            if object["stop_reason"] as? String == "max_tokens" || (object["delta"] as? [String: Any])?["stop_reason"] as? String == "max_tokens" { throw ModelFailure("输出被截断，请增加输出上限或缩短输入") }
            if object["type"] as? String == "error" { throw ModelFailure("模型流返回错误，请检查配置后重试") }
            if let delta = object["delta"] as? [String: Any], delta["type"] as? String == "text_delta" { return delta["text"] as? String ?? "" }
            return (object["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case .gemini:
            guard let candidate = (object["candidates"] as? [[String: Any]])?.first else { return "" }
            if candidate["finishReason"] as? String == "MAX_TOKENS" { throw ModelFailure("输出被截断，请增加输出上限或缩短输入") }
            return ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []).filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        case .mlx, .transcription: return ""
        }
    }
    private static func stream(_ data: Data, config: ModelConfiguration) throws -> String {
        var decoder = ModelStreamDecoder(adapter: config.adapter)
        for byte in data { _ = try decoder.append(byte) }
        return try decoder.finish()
    }
}

/// Bytes may split UTF-8 characters or SSE lines. Only decoded content reaches callers.
struct ModelStreamDecoder {
    let adapter: ModelAdapter
    init(adapter: ModelAdapter) { self.adapter = adapter }
    private var line = Data()
    private var dataLines: [String] = []
    private var byteCount = 0
    private(set) var text = ""
    private(set) var packets = 0
    private var terminated = false

    mutating func append(_ byte: UInt8) throws -> Bool {
        byteCount += 1
        guard byteCount <= 2_000_000 else { throw ModelFailure("响应过大，请降低输出上限") }
        if byte != 10 { line.append(byte); return false }
        return try consumeLine()
    }
    private mutating func consumeLine() throws -> Bool {
        if line.last == 13 { line.removeLast() }
        guard let value = String(data: line, encoding: .utf8) else { throw ModelFailure("流式响应编码无效") }
        line.removeAll(keepingCapacity: true)
        if value.isEmpty { return try dispatch() }
        if value.hasPrefix("data:") { dataLines.append(String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        return false
    }
    private mutating func dispatch() throws -> Bool {
        guard !dataLines.isEmpty else { return false }
        let value = dataLines.joined(separator: "\n"); dataLines.removeAll(keepingCapacity: true)
        guard !terminated else { return false }
        if value == "[DONE]", adapter == .openAI { terminated = true; return true }
        guard let bytes = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], object["error"] == nil else { throw ModelFailure("流式响应包含错误或无效片段") }
        text += try ModelWire.content(object, adapter: adapter); packets += 1
        if adapter == .gemini, let candidates = object["candidates"] as? [[String: Any]], candidates.first?["finishReason"] as? String == "STOP" { terminated = true }
        if adapter == .anthropic, object["type"] as? String == "message_stop" { terminated = true }
        return true
    }
    mutating func finish() throws -> String {
        if !line.isEmpty { _ = try consumeLine() }
        _ = try dispatch()
        guard terminated, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelFailure("流式响应未完整结束，未应用任务属性") }
        return text
    }
}

/// Extract only a top-level JSON message; never show raw attributes, protocol or reasoning.
enum ModelReplyPreview {
    static func message(in output: String) -> String {
        var raw = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("<think>") {
            guard let end = raw.range(of: "</think>") else { return "" }
            raw = String(raw[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if raw.hasPrefix("```") {
            guard let newline = raw.firstIndex(of: "\n") else { return "" }
            raw = String(raw[raw.index(after: newline)...])
        }
        guard raw.first == "{" else { return "" }
        let chars = Array(raw)
        var depth = 0, index = 0, expectsKey = false
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                let start = index; index += 1
                var escaped = false
                while index < chars.count {
                    if !escaped && chars[index] == "\"" { break }
                    if !escaped && chars[index] == "\\" { escaped = true } else { escaped = false }
                    index += 1
                }
                guard index < chars.count else { return "" }
                if depth == 1 && expectsKey {
                    let key = String(chars[start...index])
                    var next = index + 1
                    while next < chars.count && chars[next].isWhitespace { next += 1 }
                    guard next < chars.count, chars[next] == ":" else { return "" }
                    next += 1
                    while next < chars.count && chars[next].isWhitespace { next += 1 }
                    if (try? JSONDecoder().decode(String.self, from: Data(key.utf8))) == "message" {
                        guard next < chars.count && chars[next] == "\"" else { return "" }
                        return partialString(chars, from: next)
                    }
                    expectsKey = false
                }
            } else if char == "{" || char == "[" { depth += 1; if depth == 1 { expectsKey = true } }
            else if char == "}" || char == "]" { depth -= 1 }
            else if char == "," && depth == 1 { expectsKey = true }
            index += 1
        }
        return ""
    }
    private static func partialString(_ chars: [Character], from start: Int) -> String {
        var index = start + 1, escaped = false
        while index < chars.count {
            if !escaped && chars[index] == "\"" { break }
            if !escaped && chars[index] == "\\" { escaped = true } else { escaped = false }
            index += 1
        }
        // An unfinished escape or surrogate pair can occupy at most twelve characters.
        for dropped in 0...min(12, index - start - 1) {
            let end = index - dropped
            let candidate = String(chars[start..<end]) + "\""
            if let decoded = try? JSONDecoder().decode(String.self, from: Data(candidate.utf8)) { return String(decoded.prefix(2000)) }
        }
        return ""
    }
}

enum ModelTranscriptionWire {
    static func request(_ config: ModelConfiguration, key: String?, audio: Data, deadline: TimeInterval = 60, wav: Bool = false) throws -> URLRequest {
        try ModelValidation.validate(config, among: [])
        guard config.adapter == .transcription, !audio.isEmpty, audio.count <= 20_000_000 else { throw ModelFailure("请选择音频转写模型并提供 20 MB 以内的录音") }
        guard !config.modelID.contains("\r"), !config.modelID.contains("\n") else { throw ModelFailure("模型标识含无效控制字符") }
        try ModelValidation.validateKey(key ?? "")
        if config.requiresKey, key?.isEmpty != false { throw ModelFailure("语音转写配置缺少密钥") }
        let boundary = "Venus-" + UUID().uuidString
        var body = Data()
        func add(_ value: String) { body.append(Data(value.utf8)) }
        for (name, value) in [("model", config.modelID), ("response_format", "json")] {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.\(wav ? "wav" : "m4a")\"\r\nContent-Type: \(wav ? "audio/wav" : "audio/mp4")\r\n\r\n")
        body.append(audio); add("\r\n--\(boundary)--\r\n")
        let root = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: root + "/audio/transcriptions") else { throw ModelFailure("语音转写地址无效") }
        var request = URLRequest(url: url, timeoutInterval: min(Double(config.timeoutSeconds), deadline))
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        if config.requiresKey, let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        return request
    }
    static func response(_ data: Data, config: ModelConfiguration, status: Int) throws -> String {
        if !(200...299).contains(status) { return try ModelWire.response(data, config: config, status: status) }
        guard data.count <= 2_000_000, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil,
              let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelFailure("转写服务没有返回有效文字，请检查音频模型及接口") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
