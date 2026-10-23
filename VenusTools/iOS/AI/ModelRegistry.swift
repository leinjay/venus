import Foundation
import Combine
import Security
import CryptoKit

struct ModelCredential: Codable, Equatable {
    var key = ""
    var headers: [String: String] = [:]
}
private enum ModelKeychain {
    static let service = (Bundle.main.bundleIdentifier ?? "Venus") + ".models"
    static func read(_ reference: String?) throws -> ModelCredential? {
        guard let reference else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ModelFailure("无法读取安全存储，请解锁手机或重新填写凭据") }
        return try JSONDecoder().decode(ModelCredential.self, from: data)
    }
    static func write(_ value: ModelCredential, reference: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly, kSecValueData as String: try JSONEncoder().encode(value)]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw ModelFailure("凭据写入失败，原配置已保留") }
    }
    static func delete(_ reference: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference] as CFDictionary)
    }
}
private struct ModelSettingsData: Codable {
    var schema = 1
    var configurations: [ModelConfiguration]
    var bindings: [String: UUID]
    var grants: [String: String] = [:]
}

@MainActor
final class ModelRegistry: ObservableObject {
    static let shared = ModelRegistry()
    @Published private var data: ModelSettingsData
    @Published private(set) var callEpoch = 0
    @Published var storageError: String?
    private let file: URL
    private var writable = true
    var configurations: [ModelConfiguration] { data.configurations.sorted { $0.createdAt < $1.createdAt } }

    private init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Settings", isDirectory: true)
        file = folder.appendingPathComponent("models-v1.json")
        let defaults = ModelConfiguration.defaults()
        data = ModelSettingsData(configurations: defaults, bindings: [ModelPurpose.dialogue.binding: defaults[0].id, ModelPurpose.summary.binding: defaults[0].id])
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                let loaded = try JSONDecoder().decode(ModelSettingsData.self, from: Data(contentsOf: file))
                guard loaded.schema == 1 else { throw ModelFailure("模型配置版本不兼容，原文件已保留") }
                data = loaded
            } else { try write(data) }
        } catch { writable = false; storageError = "模型配置读取失败，已停止写入：\(error.localizedDescription)" }
    }
    private func write(_ value: ModelSettingsData) throws {
        guard writable else { throw ModelFailure("配置存储不可写，请先处理读取错误") }
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func configuration(_ id: UUID?) -> ModelConfiguration? { data.configurations.first { $0.id == id } }
    func selected(_ purpose: ModelPurpose) -> ModelConfiguration? { configuration(data.bindings[purpose.binding]) }
    func credential(_ configuration: ModelConfiguration) throws -> ModelCredential? { try ModelKeychain.read(configuration.credentialRef) }
    func references(_ id: UUID) -> [ModelPurpose] { [.dialogue, .summary, .transcription].filter { data.bindings[$0.binding] == id } }
    func status(_ config: ModelConfiguration) -> String {
        if !config.enabled { return config.execution == .onDevice && !config.textCapable ? "尚未接入运行能力" : "已禁用" }
        if config.execution == .onDevice {
            if config.modelID != LocalQwenService.modelID { return "此本机运行库尚未接入" }
            if !LocalQwenService.shared.ready { return "模型未下载或未验证" }
            return config.validTest?.success == true ? "本机文字测试成功" : "已下载 · 待推理验证"
        }
        if config.requiresKey, (try? credential(config))?.key.isEmpty != false { return "请填写或导入密钥" }
        guard let test = config.validTest else { return "未测试" }
        return test.success ? (config.adapter == .transcription ? "音频转写测试成功" : "文字测试成功") : "测试失败"
    }
    func save(_ value: ModelConfiguration, credential: ModelCredential?) throws {
        var config = value; config.name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.modelID = config.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        config.baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let old = configuration(config.id), previousCredential = try old.flatMap { try self.credential($0) }
        var addedReference: String?
        if config.execution == .onDevice { config.credentialRef = nil }
        else if let credential, !credential.key.isEmpty || !credential.headers.isEmpty {
            try Self.validateHeaders(credential.headers)
            try ModelValidation.validateKey(credential.key)
            if !credential.headers.isEmpty, URL(string: config.baseURL)?.scheme != "https" { throw ModelFailure("携带敏感请求头的服务必须使用 HTTPS") }
            if credential == previousCredential { config.credentialRef = old?.credentialRef }
            else {
                let reference = config.credentialRef != old?.credentialRef ? (config.credentialRef ?? UUID().uuidString) : UUID().uuidString
                try ModelKeychain.write(credential, reference: reference); addedReference = reference; config.credentialRef = reference
            }
        } else { config.credentialRef = nil }
        do {
            try ModelValidation.validate(config, among: data.configurations)
            if config.requiresKey, credential?.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { throw ModelFailure("请填写 API Key；凭据不可用时不能保存为已配置") }
            config.revision = (old?.revision ?? 0) + 1; config.createdAt = old?.createdAt ?? value.createdAt; config.updatedAt = Date()
            if config.test?.fingerprint != config.fingerprint { config.test = nil }
            var next = data
            if let index = next.configurations.firstIndex(where: { $0.id == config.id }) { next.configurations[index] = config }
            else { next.configurations.append(config) }
            let changed = old?.fingerprint != config.fingerprint
            if changed { for purpose in ModelPurpose.allCases where next.bindings[purpose.binding] == config.id { next.grants.removeValue(forKey: purpose.rawValue) } }
            try write(next); data = next
            if changed { callEpoch += 1 }
            if let reference = old?.credentialRef, reference != config.credentialRef, !next.configurations.contains(where: { $0.credentialRef == reference }) { ModelKeychain.delete(reference) }
        } catch { if let addedReference { ModelKeychain.delete(addedReference) }; throw error }
    }
    func bind(_ id: UUID?, to purpose: ModelPurpose) throws {
        if let id { guard let config = configuration(id), config.enabled, purpose.accepts(config) else { throw ModelFailure("请选择已启用且支持此功能的模型配置") } }
        guard data.bindings[purpose.binding] != id else { return }
        var next = data; next.bindings[purpose.binding] = id
        for affected in ModelPurpose.allCases where affected.binding == purpose.binding { next.grants.removeValue(forKey: affected.rawValue) }
        try write(next); data = next; callEpoch += 1
    }
    func delete(_ config: ModelConfiguration, replacingWith replacement: UUID? = nil) throws {
        if let replacement { guard replacement != config.id, let target = configuration(replacement), target.enabled, references(config.id).allSatisfy({ $0.accepts(target) }) else { throw ModelFailure("替代配置须支持所有被引用功能") } }
        var next = data
        for purpose in ModelPurpose.allCases where next.bindings[purpose.binding] == config.id {
            next.bindings[purpose.binding] = replacement; next.grants.removeValue(forKey: purpose.rawValue)
        }
        next.configurations.removeAll { $0.id == config.id }
        try write(next); data = next; callEpoch += 1
        if let reference = config.credentialRef, !next.configurations.contains(where: { $0.credentialRef == reference }) { ModelKeychain.delete(reference) }
    }
    func authorized(_ purpose: ModelPurpose, config: ModelConfiguration) -> Bool {
        config.execution == .onDevice || data.grants[purpose.rawValue] == config.fingerprint + purpose.disclosure
    }
    func setAuthorization(_ allowed: Bool, purpose: ModelPurpose) throws {
        guard let config = selected(purpose) else { throw ModelFailure("请先选择模型配置") }
        var next = data; next.grants[purpose.rawValue] = allowed ? config.fingerprint + purpose.disclosure : nil
        try write(next); data = next; callEpoch += 1
    }
    func resolve(_ purpose: ModelPurpose) throws -> ModelConfiguration {
        guard let config = selected(purpose) else { throw ModelFailure("\(purpose.title)尚未配置模型，请在设置中选择") }
        guard config.enabled, purpose.accepts(config) else { throw ModelFailure("所选配置已禁用或不支持此功能，请重新选择") }
        guard authorized(purpose, config: config) else { throw ModelFailure("请先在模型卡片中确认此功能的外发授权") }
        return config
    }
    func recordTest(id: UUID, fingerprint: String, result: ModelTestResult) throws {
        guard let config = configuration(id), config.fingerprint == fingerprint else { return }
        var next = data; if let index = next.configurations.firstIndex(where: { $0.id == id }) { next.configurations[index].test = result }
        try write(next); data = next
    }
    static func validateHeaders(_ headers: [String: String]) throws {
        let blocked = Set(["authorization", "x-api-key", "x-goog-api-key", "host", "content-type", "content-length", "anthropic-version", "cookie", "connection"])
        guard headers.count <= 8 else { throw ModelFailure("高级请求头最多 8 项") }
        for (key, value) in headers {
            guard key.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil, !blocked.contains(key.lowercased()), !value.contains("\r"), !value.contains("\n"), value.count <= 2000 else { throw ModelFailure("请求头格式无效或覆盖了应用管理的字段") }
        }
    }
    func importSetup(_ bytes: Data, passphrase: String) throws {
        struct Envelope: Decodable { var version: Int; var combined: String }
        struct Setup: Decodable { var name: String; var baseURL: String; var modelID: String; var apiKey: String }
        guard bytes.count < 100_000, let envelope = try? JSONDecoder().decode(Envelope.self, from: bytes), envelope.version == 1,
              let encrypted = Data(base64Encoded: envelope.combined) else { throw ModelFailure("不是有效的加密初始化文件") }
        let key = SymmetricKey(data: SHA256.hash(data: Data(passphrase.trimmingCharacters(in: .whitespacesAndNewlines).utf8)))
        guard let clear = try? AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key), let setup = try? JSONDecoder().decode(Setup.self, from: clear) else { throw ModelFailure("导入口令不正确或文件已损坏") }
        var config = configurations.first { $0.name == setup.name && $0.baseURL == setup.baseURL && $0.modelID == setup.modelID } ?? ModelConfiguration()
        config.name = setup.name; config.execution = .thirdParty; config.adapter = .openAI; config.provider = "博查兼容网关"
        config.baseURL = setup.baseURL; config.modelID = setup.modelID; config.requiresKey = true; config.enabled = true
        try save(config, credential: ModelCredential(key: setup.apiKey))
    }
}
