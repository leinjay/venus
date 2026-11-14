import Foundation
import Combine
import Darwin

private final class NoModelRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class ConfiguredModelService {
    static let shared = ConfiguredModelService()
    private var requests: [UUID: Task<String, Error>] = [:]
    private var observer: AnyCancellable?
    private init() {
        observer = ModelRegistry.shared.$callEpoch.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            for task in self.requests.values { task.cancel() }
        }
    }
    func respond(purpose: ModelPurpose, system: String, prompt: String, onProgress: (@MainActor @Sendable (String) -> Void)? = nil) async throws -> String {
        let registry = ModelRegistry.shared, config = try registry.resolve(purpose), epoch = registry.callEpoch
        let credential = try registry.credential(config)
        let id = UUID()
        let work = Task { try await self.perform(config: config, credential: credential, system: system, prompt: prompt, limit: 60, onProgress: { [weak self] text in
            guard self?.requests[id] != nil, registry.callEpoch == epoch else { return }
            onProgress?(text)
        }) }
        requests[id] = work; defer { requests.removeValue(forKey: id) }
        let output = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        guard registry.callEpoch == epoch, try registry.resolve(purpose).fingerprint == config.fingerprint else { throw CancellationError() }
        return output
    }
    func transcribe(audio url: URL, purpose: ModelPurpose = .transcription) async throws -> String {
        let registry = ModelRegistry.shared, config = try registry.resolve(purpose), epoch = registry.callEpoch
        if config.execution == .onDevice, ModelConfiguration.localSpeechIDs.contains(config.modelID) {
            let output = try await OfflineSpeechTranscription.transcribe(url, modelID: config.modelID)
            try Task.checkCancellation()
            guard registry.callEpoch == epoch, try registry.resolve(purpose).id == config.id else { throw CancellationError() }
            return output.text
        }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 20_000_001) <= 20_000_000 else { throw ModelFailure("录音超过 20 MB，请重新录制较短内容") }
        let audio = try Data(contentsOf: url), credential = try registry.credential(config), id = UUID()
        let isWAV = url.pathExtension.lowercased() == "wav"
        let work = Task { try await self.perform(config: config, credential: credential, system: "", prompt: "", limit: 60, audio: audio, wav: isWAV) }
        requests[id] = work; defer { requests.removeValue(forKey: id) }
        let output = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        guard registry.callEpoch == epoch, try registry.resolve(purpose).fingerprint == config.fingerprint else { throw CancellationError() }
        return output
    }
    func test(config: ModelConfiguration, credential: ModelCredential?, onProgress: (@MainActor @Sendable (String) -> Void)? = nil) async throws -> String {
        // Always a fixed sample, never task data. Testing grants no task permission.
        if config.adapter == .transcription {
            guard let sample = Bundle.main.url(forResource: "transcription-probe", withExtension: "wav") else { throw ModelFailure("固定音频测试样本缺失") }
            return try await perform(config: config, credential: credential, system: "", prompt: "", limit: 60, audio: Data(contentsOf: sample), wav: true)
        }
        return try await perform(config: config, credential: credential, system: "你是连接测试助手。", prompt: "请只回复：连接成功", limit: 60, onProgress: onProgress)
    }
    private func perform(config: ModelConfiguration, credential: ModelCredential?, system: String, prompt: String, limit: TimeInterval, onProgress: (@MainActor @Sendable (String) -> Void)? = nil, audio: Data? = nil, wav: Bool = false) async throws -> String {
        let overallDeadline = Date().addingTimeInterval(min(Double(config.timeoutSeconds), limit))
        try ModelValidation.validate(config, among: [])
        guard config.enabled, (audio == nil ? config.textCapable : config.adapter == .transcription) else { throw ModelFailure("配置已禁用或当前能力不可用") }
        if config.execution == .onDevice {
            guard config.modelID == LocalQwenService.modelID else { throw ModelFailure("此本机运行库尚未接入") }
            return try await LocalQwenService.shared.respond(system: system, prompt: prompt, generation: config.generation, timeout: min(Double(config.timeoutSeconds), limit), onProgress: onProgress)
        }
        if config.execution == .lanService, let host = URL(string: config.baseURL)?.host {
            guard try await Self.resolvesPrivately(host) else { throw ModelFailure("局域网域名未解析为私网地址，请检查地址或改为第三方服务") }
        }
        let remaining = overallDeadline.timeIntervalSinceNow
        guard remaining > 0 else { throw ModelFailure("模型调用超时，输入已保留") }
        var request = try audio.map { try ModelTranscriptionWire.request(config, key: credential?.key, audio: $0, deadline: remaining, wav: wav) }
            ?? ModelWire.request(config, key: credential?.key, system: system, prompt: prompt, deadline: remaining)
        try ModelRegistry.validateHeaders(credential?.headers ?? [:])
        if !(credential?.headers.isEmpty ?? true), request.url?.scheme != "https" { throw ModelFailure("携带敏感请求头的服务必须使用 HTTPS") }
        for (name, value) in credential?.headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = request.timeoutInterval; settings.timeoutIntervalForResource = request.timeoutInterval
        settings.urlCache = nil; settings.httpCookieStorage = nil; settings.httpShouldSetCookies = false
        let session = URLSession(configuration: settings, delegate: NoModelRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let deadline = Date().addingTimeInterval(request.timeoutInterval)
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ModelFailure("服务没有返回 HTTP 响应") }
            if (300...399).contains(response.statusCode) { return try ModelWire.response(Data(), config: config, status: response.statusCode) }
            var result = Data()
            var decoder = ModelStreamDecoder(adapter: config.adapter)
            let streaming = audio == nil && (response.mimeType?.lowercased() == "text/event-stream" || config.generation.stream && response.mimeType?.lowercased() != "application/json") && (200...299).contains(response.statusCode)
            var lastUpdate = Date.distantPast, lastText = ""
            for try await byte in bytes {
                try Task.checkCancellation()
                guard Date() < deadline else { throw ModelFailure("模型调用超时，输入已保留") }
                guard result.count < 2_000_000 else { throw ModelFailure("响应过大，请降低输出上限") }
                result.append(byte)
                if streaming, try decoder.append(byte), decoder.text != lastText, Date().timeIntervalSince(lastUpdate) >= 0.08 {
                    lastUpdate = Date(); lastText = decoder.text; onProgress?(decoder.text)
                }
            }
            try Task.checkCancellation()
            if audio != nil { return try ModelTranscriptionWire.response(result, config: config, status: response.statusCode) }
            if streaming {
                let output = try decoder.finish(); onProgress?(output); return output
            }
            var responseConfig = config
            responseConfig.generation.stream = false
            let output = try ModelWire.response(result, config: responseConfig, status: response.statusCode)
            onProgress?(output)
            return output
        } catch let failure as ModelFailure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            let code = (error as? URLError)?.code
            if code == .timedOut { throw ModelFailure("模型调用超时，输入已保留") }
            throw ModelFailure("无法连接模型服务，请检查网络、服务地址或本地网络权限")
        }
    }
    nonisolated private static func resolvesPrivately(_ host: String) async throws -> Bool {
        if host == "localhost" || host.contains(":") || host.split(separator: ".").allSatisfy({ Int($0) != nil }) { return ModelValidation.isPrivateHost(host) }
        return await Task.detached {
            var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
            var info: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return false }
            defer { freeaddrinfo(first) }
            var entry: UnsafeMutablePointer<addrinfo>? = first, found = false
            while let value = entry {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(value.pointee.ai_addr, value.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
                      ModelValidation.isPrivateHost(String(cString: buffer)) else { return false }
                found = true; entry = value.pointee.ai_next
            }
            return found
        }.value
    }
}
