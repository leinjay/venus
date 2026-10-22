import SwiftUI

private struct ModelHeaderDraft: Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var value = ""
}

struct ModelConfigurationEditor: View {
    @ObservedObject private var registry = ModelRegistry.shared
    @Environment(\.dismiss) private var dismiss
    @State private var config: ModelConfiguration
    @State private var key: String
    @State private var headers: [ModelHeaderDraft]
    private let original: ModelConfiguration
    private let originalCredential: ModelCredential
    private let isNew: Bool
    @State private var error: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var testToken = UUID()
    @State private var askLeave = false
    @State private var askReset = false
    @State private var nextExecution: ModelExecution?
    @State private var nextAdapter: ModelAdapter?
    @State private var nextPreset: (String, ModelAdapter, String, String, Bool)?

    init(configuration: ModelConfiguration? = nil) {
        var value = configuration ?? ModelConfiguration()
        if configuration == nil { value.name = "" }
        let credential = (try? ModelRegistry.shared.credential(value)) ?? ModelCredential()
        original = value; originalCredential = credential; isNew = configuration == nil
        _config = State(initialValue: value); _key = State(initialValue: credential.key)
        _headers = State(initialValue: credential.headers.sorted { $0.key < $1.key }.map { ModelHeaderDraft(name: $0.key, value: $0.value) })
    }
    private var credential: ModelCredential { ModelCredential(key: key.trimmingCharacters(in: .whitespacesAndNewlines), headers: Dictionary(headers.filter { !$0.name.isEmpty }.map { ($0.name.trimmingCharacters(in: .whitespaces), $0.value) }, uniquingKeysWith: { first, _ in first })) }
    private var changed: Bool { config != original || credential != originalCredential }
    private var testCurrent: ModelTestResult? { config.validTest }

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("唯一中文名称，例如 工作总结", text: $config.name)
                Picker("运行位置", selection: Binding(get: { config.execution }, set: { nextExecution = $0; askReset = true })) {
                    ForEach(ModelExecution.allCases) { Text($0.title).tag($0) }
                }
                Toggle("启用配置", isOn: $config.enabled)
                if !registry.references(config.id).isEmpty { Text("影响功能：\(registry.references(config.id).map(\.title).joined(separator: "、"))。改名不影响引用。").font(.caption).foregroundStyle(.secondary) }
            }
            if config.execution == .onDevice { localFields }
            else { remoteFields }
            advanced
            testSection
            if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            Section { Button("保存配置", action: save).disabled(testing) }
        }.navigationTitle(isNew ? "添加模型" : "编辑模型")
            .navigationBarBackButtonHidden()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { if changed { askLeave = true } else { dismiss() } } } }
            .confirmationDialog("有未保存修改", isPresented: $askLeave, titleVisibility: .visible) { Button("放弃修改", role: .destructive) { cancelTest(); dismiss() }; Button("继续编辑", role: .cancel) {} }
            .confirmationDialog("切换会清空不兼容参数、密钥和测试结果", isPresented: $askReset, titleVisibility: .visible) {
                Button("清空并切换") { reset() }
                Button("取消", role: .cancel) { nextExecution = nil; nextAdapter = nil; nextPreset = nil }
            }
            .onChange(of: config.fingerprint) { _, _ in cancelTest() }
            .onChange(of: key) { _, _ in credentialsChanged() }
            .onChange(of: headers) { _, _ in credentialsChanged() }
            .onChange(of: config.baseURL) { old, new in if URL(string: old)?.host != URL(string: new)?.host { key = ""; headers = []; config.credentialRef = nil } }
            .onDisappear { cancelTest() }
    }
    private var localFields: some View {
        Section("本机模板") {
            Picker("模型资源", selection: $config.modelID) {
                Text("Qwen3 · 文字").tag("mlx-community/Qwen3-1.7B-4bit")
                Text("Qwen2-VL · 图片模板（暂不可用）").tag("mlx-community/Qwen2-VL-2B-Instruct-4bit")
                Text("Whisper small · 语音模板（暂不可用）").tag("whisper-small")
            }.onChange(of: config.modelID) { _, id in config.textCapable = id == LocalQwenService.modelID; config.enabled = config.textCapable; config.provider = id == "whisper-small" ? "WhisperKit" : "MLX" }
            if config.modelID == LocalQwenService.modelID { QwenModelPanel() }
            else { Text("此模板保留配置位置，运行能力尚未接入，不能启用或被文字功能引用。现有 OCR 和系统离线语音不受影响。").font(.caption) }
        }
    }
    private var remoteFields: some View {
        Section("服务接入") {
            Menu("使用接入预设") {
                Button("博查深度求索") { preset("博查兼容网关", .openAI, "https://api.bocha.cn/v1", "deepseek-v4-flash") }
                Button("DeepSeek 官方") { preset("DeepSeek 官方", .openAI, "https://api.deepseek.com", "deepseek-chat") }
                Button("OpenAI 兼容服务") { preset("兼容服务", .openAI, "https://api.openai.com/v1", "") }
                Button("Anthropic") { preset("Anthropic", .anthropic, "https://api.anthropic.com/v1", "") }
                Button("Gemini") { preset("Google", .gemini, "https://generativelanguage.googleapis.com/v1beta", "") }
                if config.execution == .lanService {
                    Button("Ollama") { preset("Ollama", .openAI, "http://192.168.1.100:11434/v1", "qwen3", requiresKey: false) }
                    Button("LM Studio") { preset("LM Studio", .openAI, "http://192.168.1.100:1234/v1", "", requiresKey: false) }
                }
            }
            TextField("提供方", text: $config.provider)
            Picker("协议", selection: Binding(get: { config.adapter }, set: { nextAdapter = $0; askReset = true })) {
                ForEach(ModelAdapter.allCases.filter { $0 != .mlx && (config.execution != .lanService || $0 == .openAI) }) { Text($0.title).tag($0) }
            }
            TextField("API 根地址", text: $config.baseURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("实际模型 ID / 部署名称", text: $config.modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
            if config.adapter == .openAI { Toggle("使用 Bearer 密钥", isOn: $config.requiresKey) }
            if config.requiresKey { SecureField("API Key（安全保存）", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled() }
            if config.adapter == .anthropic { TextField("API 版本", text: $config.apiVersion) }
            Text(config.execution == .lanService ? "localhost / 127.0.0.1 指手机自身。请使用电脑私网地址并开放服务；HTTP 会明文传输，携带真实密钥时必须 HTTPS。若服务转发云端，请选择第三方。" : "内容将发送到填写的服务；保存不会发起请求，工具首次使用仍需单独授权。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var advanced: some View {
        Section {
            DisclosureGroup("高级参数（留空使用默认值）") {
                Stepper("请求超时：\(config.timeoutSeconds) 秒", value: $config.timeoutSeconds, in: 10...120, step: 5)
                Text("任务单次调用仍最多 60 秒，采用两者中较小值。").font(.caption)
                TextField("输出 token 上限", value: $config.generation.maxTokens, format: .number).keyboardType(.numberPad)
                if config.adapter != .anthropic {
                    TextField("温度", value: $config.generation.temperature, format: .number).keyboardType(.decimalPad)
                    TextField("Top-p", value: $config.generation.topP, format: .number).keyboardType(.decimalPad)
                }
                if config.execution == .onDevice {
                    TextField("重复惩罚", value: $config.generation.repetitionPenalty, format: .number).keyboardType(.decimalPad)
                } else {
                    if config.adapter == .openAI { Picker("输出上限参数", selection: $config.generation.tokenField) { Text("max_tokens").tag("max_tokens"); Text("max_completion_tokens").tag("max_completion_tokens") } }
                    TextField("停止序列（每行一个，最多 4 个）", text: Binding(get: { config.generation.stop.joined(separator: "\n") }, set: { config.generation.stop = $0.components(separatedBy: "\n").filter { !$0.isEmpty } }), axis: .vertical)
                    Toggle("使用流式协议", isOn: $config.generation.stream)
                    if config.adapter != .anthropic { Toggle("请求 JSON 输出（须服务支持）", isOn: $config.generation.jsonOutput) }
                    Text("高级能力未单独验证；文字测试不会认证图片、工具调用或 JSON 模式。未知模型先保留服务商默认值。").font(.caption).foregroundStyle(.secondary)
                    ForEach($headers) { $header in
                        VStack { TextField("请求头名称", text: $header.name).textInputAutocapitalization(.never).autocorrectionDisabled(); SecureField("请求头敏感值", text: $header.value) }
                    }
                    HStack { Button("添加请求头") { headers.append(ModelHeaderDraft()) }.disabled(headers.count >= 8); if !headers.isEmpty { Button("移除末项", role: .destructive) { headers.removeLast() } } }
                }
            }
        }
    }
    private var testSection: some View {
        Section("测试当前表单") {
            Text("仅发送固定的‘连接成功’测试文字，不读取任务。外部调用可能产生服务费用；测试不会保存表单或授权任务外发。").font(.caption).foregroundStyle(.secondary)
            if testing { HStack { ProgressView(); Text("测试中，最多 60 秒"); Button("取消", action: cancelTest) } }
            else { Button("测试配置", action: test) }
            if let result = testCurrent { Text((result.success ? "文字测试成功：" : "测试失败：") + result.message).font(.caption); Text(result.date.formatted()).font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private func credentialsChanged() { config.credentialRef = config.execution == .onDevice ? nil : UUID().uuidString; config.test = nil; cancelTest() }
    private func reset() {
        cancelTest()
        if let pending = nextPreset {
            applyPreset(pending.0, pending.1, pending.2, pending.3, requiresKey: pending.4)
            nextPreset = nil; return
        }
        let execution = nextExecution ?? config.execution, adapter = nextAdapter ?? (execution == .onDevice ? .mlx : .openAI)
        config.execution = execution; config.adapter = adapter; config.generation = ModelGeneration(); config.credentialRef = nil; config.test = nil
        config.modelID = execution == .onDevice ? LocalQwenService.modelID : ""; config.baseURL = ""; config.provider = execution == .onDevice ? "MLX" : "自定义服务"
        config.requiresKey = execution == .thirdParty || adapter != .openAI && execution != .onDevice; config.textCapable = true
        key = ""; headers = []; nextExecution = nil; nextAdapter = nil
    }
    private func preset(_ provider: String, _ adapter: ModelAdapter, _ url: String, _ modelID: String, requiresKey: Bool = true) {
        nextPreset = (provider, adapter, url, modelID, requiresKey); askReset = true
    }
    private func applyPreset(_ provider: String, _ adapter: ModelAdapter, _ url: String, _ modelID: String, requiresKey: Bool) {
        cancelTest(); config.provider = provider; config.adapter = adapter; config.baseURL = url; config.modelID = modelID
        config.generation = ModelGeneration(); config.requiresKey = requiresKey; config.credentialRef = nil; key = ""; headers = []; config.test = nil
    }
    private func save() {
        do {
            try validateCredentials()
            try registry.save(config, credential: config.execution == .onDevice ? nil : credential); dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func validateCredentials() throws {
        guard Set(headers.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }).count == headers.count else { throw ModelFailure("请求头名称不可重复") }
        guard headers.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }) else { throw ModelFailure("请填写请求头名称或移除空项") }
        try ModelRegistry.validateHeaders(credential.headers)
        try ModelValidation.validateKey(credential.key)
        if !credential.headers.isEmpty, URL(string: config.baseURL)?.scheme != "https" { throw ModelFailure("携带敏感请求头的服务必须使用 HTTPS") }
    }
    private func cancelTest() { testToken = UUID(); testTask?.cancel(); testTask = nil; testing = false }
    private func test() {
        cancelTest(); error = nil
        do { try ModelValidation.validate(config, among: registry.configurations); try validateCredentials() }
        catch { self.error = error.localizedDescription; return }
        let snapshot = config, credentials = credential, fingerprint = config.fingerprint, token = testToken
        testing = true
        testTask = Task {
            do {
                let response = try await ConfiguredModelService.shared.test(config: snapshot, credential: credentials)
                try Task.checkCancellation(); guard token == testToken, config.fingerprint == fingerprint else { return }
                let redacted = ([credentials.key] + Array(credentials.headers.values)).filter { !$0.isEmpty }.reduce(response) { $0.replacingOccurrences(of: $1, with: "[已隐藏]") }
                config.test = ModelTestResult(fingerprint: fingerprint, date: Date(), message: String(redacted.prefix(160)), success: true); testing = false
            } catch {
                guard token == testToken else { return }; testing = false
                if !(error is CancellationError) { config.test = ModelTestResult(fingerprint: fingerprint, date: Date(), message: error.localizedDescription, success: false) }
            }
        }
    }
}
