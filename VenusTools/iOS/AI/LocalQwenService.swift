import Foundation
import Combine
import CryptoKit
import MLXLLM
import MLXLMCommon

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate {
    let update: (Int64) -> Void
    init(update: @escaping (Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { update(totalBytesWritten) }
}

actor LocalQwenEngine {
    private var container: ModelContainer?
    private var busy = false
    func unload() { container = nil }
    func respond(directory: URL, system: String, prompt: String, generation: ModelGeneration = ModelGeneration(), timeout: TimeInterval = 60) async throws -> String {
        guard !busy else { throw TaskFailure("另一项 AI 操作正在处理，请稍后重试") }
        busy = true; defer { busy = false }
        let deadline = Date().addingTimeInterval(timeout)
        if container == nil { container = try await LLMModelFactory.shared.loadContainer(configuration: MLXLMCommon.ModelConfiguration(directory: directory)) }
        try Task.checkCancellation()
        guard let container else { throw TaskFailure("模型加载失败") }
        let result = try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(messages: [
                ["role": "system", "content": system], ["role": "user", "content": prompt]
            ], additionalContext: ["enable_thinking": false]))
            guard input.text.tokens.size <= 6000 else { throw TaskFailure("模型上下文过长，请缩短输入或具体内容") }
            let maximum = generation.maxTokens ?? 1800
            let parameters = GenerateParameters(maxTokens: maximum, temperature: Float(generation.temperature ?? 0.2), topP: Float(generation.topP ?? 0.9), repetitionPenalty: generation.repetitionPenalty)
            let result: GenerateResult = try MLXLMCommon.generate(input: input, parameters: parameters, context: context) { (_: [Int]) -> GenerateDisposition in
                Task.isCancelled || Date() >= deadline ? .stop : .more
            }
            try Task.checkCancellation()
            guard Date() < deadline else { throw TaskFailure("AI 处理超时，输入已保留") }
            guard result.generationTokenCount < maximum else { throw TaskFailure("模型输出过长或被截断，请分次补充") }
            return result.output
        }
        let cleaned = Self.clean(result)
        guard !cleaned.isEmpty else { throw TaskFailure("模型返回了空结果，请重试") }
        return cleaned
    }
    private static func clean(_ text: String) -> String {
        var result = text
        if let end = result.range(of: "</think>") { result = String(result[end.upperBound...]) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class LocalQwenService: ObservableObject {
    static let shared = LocalQwenService()
    static let modelID = "mlx-community/Qwen3-1.7B-4bit"
    static let revision = "3b1b1768f8f8cf8351c712464f906e86c2b8269e"
    struct File: Sendable {
        let name: String; let size: Int64; let sha256: String
    }
    static let files: [File] = [
        File(name: "added_tokens.json", size: 707, sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
        File(name: "config.json", size: 937, sha256: "507a6701220524eb8b283425bf0856a9ae4f21f4052e563896ddd668994b1dc7"),
        File(name: "merges.txt", size: 1671853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        File(name: "model.safetensors", size: 968080210, sha256: "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f"),
        File(name: "model.safetensors.index.json", size: 49731, sha256: "1e3058d4ba4b04e4de35b74467725cbef90ff022198404218e48f21adc9cfa15"),
        File(name: "special_tokens_map.json", size: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
        File(name: "tokenizer.json", size: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
        File(name: "tokenizer_config.json", size: 9706, sha256: "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0"),
        File(name: "vocab.json", size: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910")
    ]
    @Published private(set) var ready = false
    @Published private(set) var preparing = false
    @Published private(set) var generating = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Qwen3 尚未准备"
    private let engine = LocalQwenEngine()
    private var downloadTask: Task<Void, Never>?
    let directory: URL

    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models/Qwen3-1.7B-4bit", isDirectory: true)
        ready = (try? String(contentsOf: directory.appendingPathComponent("verified"), encoding: .utf8)) == Self.revision
            && Self.files.allSatisfy { file in (try? directory.appendingPathComponent(file.name).resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.size) }
        if ready { status = "Qwen3 已就绪 · 本机离线处理" }
    }

    func download(allowsCellular: Bool = false) {
        guard !preparing, !generating else { return }
        preparing = true
        downloadTask = Task {
            defer { preparing = false }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var resources = URLResourceValues(); resources.isExcludedFromBackup = true
                var modelDirectory = directory; try modelDirectory.setResourceValues(resources)
                let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                guard capacity > 2_000_000_000 else { throw TaskFailure("请预留至少 2 GB 空间用于下载与校验") }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.allowsCellularAccess = allowsCellular
                configuration.waitsForConnectivity = true
                configuration.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let total = Self.files.reduce(Int64(0)) { $0 + $1.size }
                var completed: Int64 = 0
                for file in Self.files {
                    try Task.checkCancellation()
                    let target = directory.appendingPathComponent(file.name)
                    if await Self.verified(target, file: file) { completed += file.size; continue }
                    status = "正在下载 \(file.name)"
                    let offset = completed
                    let delegate = ModelDownloadProgress { count in Task { @MainActor in self.progress = Double(offset + count) / Double(total) } }
                    let url = URL(string: "https://huggingface.co/\(Self.modelID)/resolve/\(Self.revision)/\(file.name)")!
                    let (temporary, response) = try await session.download(for: URLRequest(url: url), delegate: delegate)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TaskFailure("下载失败，请稍后重试") }
                    status = "正在校验 \(file.name)"
                    guard await Self.verified(temporary, file: file) else { throw TaskFailure("模型校验失败，请重新下载 \(file.name)") }
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    try FileManager.default.moveItem(at: temporary, to: target)
                    completed += file.size; progress = Double(completed) / Double(total)
                }
                try Data(Self.revision.utf8).write(to: directory.appendingPathComponent("verified"), options: .atomic)
                ready = true; status = "Qwen3 已就绪 · 本机离线处理"
            } catch is CancellationError { status = "已暂停，已校验文件将保留" }
            catch { status = "\(error.localizedDescription) · 可重试" }
        }
    }
    func cancelDownload() { downloadTask?.cancel() }
    func remove() async {
        guard !generating, !preparing else { return }
        await engine.unload()
        do { try FileManager.default.removeItem(at: directory); ready = false; progress = 0; status = "模型已删除，任务仍保留" }
        catch { status = error.localizedDescription }
    }
    func importDirectory(_ source: URL) async {
        guard !preparing, !generating else { return }
        preparing = true; defer { preparing = false }
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        do {
            // Verify all sources before replacing the current model.
            for (index, file) in Self.files.enumerated() {
                status = "校验导入：\(file.name)"; progress = Double(index) / Double(Self.files.count)
                guard await Self.verified(source.appendingPathComponent(file.name), file: file) else { throw TaskFailure("文件缺失或版本不匹配：\(file.name)") }
            }
            await engine.unload(); ready = false
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var resources = URLResourceValues(); resources.isExcludedFromBackup = true
            var modelDirectory = directory; try modelDirectory.setResourceValues(resources)
            for file in Self.files {
                let target = directory.appendingPathComponent(file.name)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: source.appendingPathComponent(file.name), to: target)
            }
            try Data(Self.revision.utf8).write(to: directory.appendingPathComponent("verified"), options: .atomic)
            ready = true; status = "Qwen3 已导入 · 本机离线处理"; progress = 1
        } catch { status = error.localizedDescription }
    }
    nonisolated private static func verified(_ url: URL, file: File) async -> Bool {
        await Task.detached {
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.size), let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            var digest = SHA256()
            do {
                while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
                return digest.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
            } catch { return false }
        }.value
    }
    func respond(system: String, prompt: String, generation: ModelGeneration = ModelGeneration(), timeout: TimeInterval = 60) async throws -> String {
        guard ready else { throw TaskFailure("请先准备本机 Qwen3 模型，或使用属性表单") }
        guard !generating, !preparing else { throw TaskFailure("模型正在处理另一项操作") }
        generating = true; defer { generating = false }
        return try await engine.respond(directory: directory, system: system, prompt: prompt, generation: generation, timeout: timeout)
    }
}
