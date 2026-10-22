import Foundation

struct ModelFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum ModelExecution: String, Codable, CaseIterable, Identifiable {
    case onDevice, lanService, thirdParty
    var id: String { rawValue }
    var title: String { switch self { case .onDevice: return "iPhone 本机"; case .lanService: return "局域网服务"; case .thirdParty: return "第三方服务" } }
}
enum ModelAdapter: String, Codable, CaseIterable, Identifiable {
    case mlx, openAI, anthropic, gemini
    var id: String { rawValue }
    var title: String { switch self { case .mlx: return "本机 MLX"; case .openAI: return "Chat Completions 兼容"; case .anthropic: return "Anthropic Messages"; case .gemini: return "Gemini generateContent" } }
}
enum ModelPurpose: String, CaseIterable, Identifiable {
    case dialogue, summary, search
    var id: String { rawValue }
    var binding: String { "reminders." + (self == .search ? ModelPurpose.dialogue.rawValue : rawValue) }
    var title: String { switch self { case .dialogue: return "任务 AI 对话"; case .summary: return "今日总结"; case .search: return "智能查找" } }
    var disclosure: String {
        switch self {
        case .dialogue: return "本轮文字、必要对话、最新任务草稿、明确相关的依赖候选，以及本机语音转写和图片识别文字。原始图片和录音不发送。"
        case .summary: return "今日及此前逾期任务中前 30 项的标题、概要、时间、重要程度和未完成前置数量。完整清单留在手机。"
        case .search: return "仅本次查询、当前日期和时区，用于解析查找条件；不发送任务列表。"
        }
    }
}
struct ModelGeneration: Codable, Equatable {
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    var tokenField = "max_tokens"
    var repetitionPenalty: Float?
    var stop: [String] = []
    var stream = false
    var jsonOutput = false
}
struct ModelTestResult: Codable, Equatable {
    var fingerprint: String
    var date: Date
    var message: String
    var success: Bool
}
struct ModelConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var execution = ModelExecution.onDevice
    var adapter = ModelAdapter.mlx
    var provider = "MLX"
    var modelID = "mlx-community/Qwen3-1.7B-4bit"
    var baseURL = ""
    var requiresKey = false
    var credentialRef: String?
    var enabled = true
    var timeoutSeconds = 60
    var generation = ModelGeneration()
    var apiVersion = "2023-06-01"
    var revision = 1
    var createdAt = Date()
    var updatedAt = Date()
    var test: ModelTestResult?
    var textCapable = true

    // No name, timestamps or test status: renaming never invalidates a binding/grant.
    var fingerprint: String {
        var copy = self
        copy.name = ""; copy.revision = 0; copy.createdAt = .distantPast; copy.updatedAt = .distantPast; copy.test = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(copy).base64EncodedString()) ?? "invalid"
    }
    var destination: String { URL(string: baseURL)?.host ?? "iPhone 本机" }
    var validTest: ModelTestResult? { test?.fingerprint == fingerprint ? test : nil }
    static func defaults() -> [ModelConfiguration] {
        var text = ModelConfiguration(); text.name = "本机文字整理"
        var vision = ModelConfiguration(); vision.name = "本机图片理解"; vision.modelID = "mlx-community/Qwen2-VL-2B-Instruct-4bit"; vision.textCapable = false; vision.enabled = false
        var speech = ModelConfiguration(); speech.name = "本机语音转写"; speech.provider = "WhisperKit"; speech.modelID = "whisper-small"; speech.textCapable = false; speech.enabled = false
        var bocha = ModelConfiguration(); bocha.name = "博查深度求索测试"; bocha.execution = .thirdParty; bocha.adapter = .openAI
        bocha.provider = "博查兼容网关"; bocha.baseURL = "https://api.bocha.cn/v1"; bocha.modelID = "deepseek-v4-flash"; bocha.requiresKey = true
        return [text, vision, speech, bocha]
    }
}

enum ModelValidation {
    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCompatibilityMapping.lowercased()
    }
    static func isPrivateHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        if host.contains(":") { return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let parts = labels.compactMap { Int($0) }
        guard labels.count == 4, parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
    }
    static func validateKey(_ key: String) throws {
        guard key.count <= 4096, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ModelFailure("密钥含无效控制字符或长度超过限制") }
    }
    static func validate(_ config: ModelConfiguration, among all: [ModelConfiguration]) throws {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...50).contains(name.count), name.range(of: "[\\p{Han}]", options: .regularExpression) != nil else { throw ModelFailure("配置名称需为 1～50 字，包含中文") }
        guard !all.contains(where: { $0.id != config.id && nameKey($0.name) == nameKey(name) }) else { throw ModelFailure("已有同名配置，请使用唯一中文名称") }
        guard !config.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, config.modelID.count <= 200 else { throw ModelFailure("请填写实际模型标识，最多 200 字") }
        guard (10...120).contains(config.timeoutSeconds) else { throw ModelFailure("超时需为 10～120 秒") }
        if config.execution == .onDevice {
            guard config.adapter == .mlx, !config.requiresKey, config.credentialRef == nil, config.baseURL.isEmpty else { throw ModelFailure("本机配置不使用地址或推理密钥") }
            guard ["mlx-community/Qwen3-1.7B-4bit", "mlx-community/Qwen2-VL-2B-Instruct-4bit", "whisper-small"].contains(config.modelID) else { throw ModelFailure("请选择受支持的本机模板") }
            if config.modelID != "mlx-community/Qwen3-1.7B-4bit", config.enabled { throw ModelFailure("视觉 MLX / WhisperKit 运行库尚未接入，模板暂不可启用；现有本机 OCR 和系统语音仍可使用") }
        } else {
            guard config.adapter != .mlx, let url = URL(string: config.baseURL), let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw ModelFailure("请填写无账号、查询参数或片段的 API 根地址") }
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !["chat/completions", "messages", ":generateContent", ":streamGenerateContent"].contains(where: { path.hasSuffix($0) }) else { throw ModelFailure("请填写 API 根地址，移除末尾操作路径") }
            if config.execution == .lanService {
                guard isPrivateHost(host) else { throw ModelFailure("局域网地址需为私网 IP 或 .local 域名；公网服务请选择第三方") }
                guard url.scheme == "https" || !config.requiresKey else { throw ModelFailure("使用密钥的局域网服务必须启用 HTTPS") }
            } else if url.scheme != "https" { throw ModelFailure("第三方服务必须使用 HTTPS") }
            if config.execution == .lanService && config.adapter != .openAI { throw ModelFailure("局域网服务当前使用 Chat Completions 兼容协议") }
            if config.adapter == .anthropic, config.apiVersion.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) == nil { throw ModelFailure("API 版本需为 yyyy-MM-dd 格式") }
            if config.adapter != .openAI && !config.requiresKey { throw ModelFailure("此协议需要 API Key") }
        }
        guard !config.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelFailure("请填写提供方") }
        let g = config.generation
        if let n = g.maxTokens, !(1...131_072).contains(n) { throw ModelFailure("输出上限需为 1～131072 的整数，并符合服务商模型限制") }
        if config.execution == .onDevice, let n = g.maxTokens, n > 4096 { throw ModelFailure("本机输出上限最多 4096 token") }
        if let t = g.temperature, !t.isFinite || !(0...2).contains(t) { throw ModelFailure("温度需在 0～2 范围内") }
        if let p = g.topP, !p.isFinite || p <= 0 || p > 1 { throw ModelFailure("Top-p 需大于 0 且不超过 1") }
        if let p = g.repetitionPenalty, !p.isFinite || p <= 0 || config.execution != .onDevice { throw ModelFailure("重复惩罚仅用于本机且必须大于 0") }
        if config.adapter == .anthropic, g.temperature != nil || g.topP != nil { throw ModelFailure("当前 Anthropic 参数模板不发送温度或 Top-p") }
        guard ["max_tokens", "max_completion_tokens"].contains(g.tokenField), g.stop.count <= 4, g.stop.allSatisfy({ !$0.isEmpty && $0.count <= 100 }) else { throw ModelFailure("请检查 token 字段及停止序列（最多 4 项，每项 100 字）") }
        if g.jsonOutput && config.adapter == .anthropic { throw ModelFailure("当前 Anthropic 模板不声明 JSON 模式，请使用应用结果校验") }
    }
}
