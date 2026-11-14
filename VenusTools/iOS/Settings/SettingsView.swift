import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(AppSkin.storageKey) private var skin = AppSkin.classic.rawValue
    @ObservedObject private var registry = ModelRegistry.shared
    @EnvironmentObject private var navigation: AppNavigation
    var body: some View {
        NavigationStack(path: $navigation.settingsPath) {
            List {
                Section("外观") {
                    Picker("皮肤", selection: $skin) {
                        ForEach(AppSkin.allCases) { skin in Text(skin.title).tag(skin.rawValue) }
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").font(.title2).foregroundStyle(AppTheme.pine)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(skin == AppSkin.sky.rawValue ? "晴空蓝" : "松林绿").foregroundStyle(AppTheme.ink)
                            Text("清爽底色 · 柔和卡片 · 清晰文字").font(.caption).foregroundStyle(AppTheme.secondary)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
                }

                Section {
                    NavigationLink(value: SettingsRoute.models) {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("模型列表", systemImage: "cpu")
                            Text("\(registry.configurations.count) 个具名配置 · 供各工具引用").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink("使用列表") { ModelBindingsView() }
                } footer: { Text("默认使用手机本机模型。局域网或第三方模型需自行配置，并按功能确认发送范围。") }
                if let error = registry.storageError { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("设置")
                .navigationDestination(for: SettingsRoute.self) { _ in ModelListView() }
        }
        .onChange(of: navigation.settingsPath) { _, path in
            if path.isEmpty && navigation.returnTab != nil { navigation.returnFromSettings() }
        }
    }
}

struct ModelListView: View {
    @EnvironmentObject private var navigation: AppNavigation
    @ObservedObject private var registry = ModelRegistry.shared
    @ObservedObject private var local = LocalQwenService.shared
    @ObservedObject private var speechModels = OfflineSpeechModels.shared
    @State private var adding = false
    @State private var deleting: ModelConfiguration?
    @State private var importer = false
    @State private var importData: Data?
    @State private var importPassword = ""
    @State private var importSheet = false
    @State private var importError: String?
    @State private var message: String?
    var body: some View {
        List {
            Section {
                NavigationLink("添加模型") { ModelConfigurationEditor() }
                NavigationLink("使用列表") { ModelBindingsView() }
                Button("导入加密初始化文件") { importer = true }
            }
            Section("已保存模型 · \(registry.configurations.count)") {
                if registry.configurations.isEmpty { Text("添加第一个具名配置，工具即可按名称选择。") }
                ForEach(registry.configurations) { config in
                    if ModelConfiguration.localSpeechIDs.contains(config.modelID) {
                        OfflineSpeechModelRow(config: config)
                    } else {
                    NavigationLink { ModelConfigurationEditor(configuration: config) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(config.name).font(.headline)
                            HStack(spacing: 8) {
                                Text(config.execution == .onDevice ? "离线" : "在线")
                                Text(config.adapter == .transcription ? "语音" : (config.textCapable ? "文字" : (config.modelID == "whisper-small" ? "语音" : "图像")))
                                Text(config.execution == .onDevice ? "大小见模型资源" : "云端 · 无本地大小")
                            }.font(.caption2).foregroundStyle(AppTheme.pine)
                            Text("\(config.execution.title) · \(config.provider)").font(.caption)
                            Text(config.modelID).font(.caption2).foregroundStyle(.secondary)
                            Text("\(registry.status(config)) · \(config.capabilityTitle) · \(registry.references(config.id).count) 个功能引用").font(.caption2).foregroundStyle(.secondary)
                            if config.execution == .onDevice && !config.textCapable {
                                Text(config.modelID == "whisper-small" ? "尚未集成 WhisperKit；可另配音频转写模型，或选择系统离线识别。" : "尚未集成视觉运行库；当前图片使用本机文字提取。")
                                    .font(.caption).foregroundStyle(AppTheme.terracotta)
                            }
                            if let test = config.validTest { Text("最近测试 \(test.date.formatted())").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }.swipeActions { Button("删除", role: .destructive) { deleting = config } }
                    }
                }
            }
            Section("本机模型资源") {
                QwenModelPanel()
                Text("语音模型可在模型列表中下载；在使用列表为各场景选择转写模型。").font(.caption).foregroundStyle(.secondary)
                Text("Qwen3 固定版本：\(LocalQwenService.revision)\n运行库 MLX Swift examples 2.25.9；多个文字配置共享这一份权重，生成参数分别保存。").font(.caption2).textSelection(.enabled)
            }
        }.navigationTitle("模型列表")
            .navigationBarBackButtonHidden(navigation.returnTab != nil && navigation.settingsPath == [.models])
            .toolbar {
                if navigation.returnTab != nil && navigation.settingsPath == [.models] {
                    ToolbarItem(placement: .topBarLeading) { Button { navigation.returnFromSettings() } label: { Label("返回任务", systemImage: "chevron.left") } }
                }
            }
            .sheet(item: $deleting) { ModelDeleteView(configuration: $0) }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.data, .json]) { result in
                do {
                    let url = try result.get(), granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 100_001) <= 100_000 else { throw ModelFailure("初始化文件过大") }
                    importData = try Data(contentsOf: url); importPassword = ""; importError = nil; importSheet = true
                } catch { message = "无法读取初始化文件，请重新选择" }
            }
            .sheet(isPresented: $importSheet, onDismiss: { importData = nil; importPassword = "" }) {
                NavigationStack { Form {
                    Text("此文件用于本次私人初始化。导入后密钥只写入手机 Keychain，不改变任何工具的模型选择或外发授权。")
                    SecureField("初始化口令", text: $importPassword).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("解密并导入") {
                        do {
                            guard let bytes = importData else { return }
                            try registry.importSetup(bytes, passphrase: importPassword)
                            importSheet = false; message = "模型凭据已导入。请打开配置测试，再为所需工具选择模型。"
                        } catch { importError = error.localizedDescription }
                    }
                    if let importError { Text(importError).foregroundStyle(.red) }
                }.navigationTitle("导入初始化").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { importSheet = false } } } }
            }
            .alert("模型配置", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("知道了") { message = nil } } message: { Text(message ?? "") }
    }
}

private struct ModelDeleteView: View {
    let configuration: ModelConfiguration
    @ObservedObject private var registry = ModelRegistry.shared
    @Environment(\.dismiss) private var dismiss
    @State private var replacement: UUID?
    @State private var error: String?
    var body: some View {
        NavigationStack { Form {
            Text("删除“\(configuration.name)”？模型资源、任务和已保存文本会保留，专属凭据会从手机清理。")
            let references = registry.references(configuration.id)
            if !references.isEmpty {
                Text("正在引用：\(references.map(\.title).joined(separator: "、"))；智能查找跟随对话。")
                Picker("引用处理", selection: $replacement) {
                    Text("解除以上引用").tag(UUID?.none)
                    ForEach(registry.configurations.filter { candidate in candidate.id != configuration.id && candidate.enabled && references.allSatisfy({ $0.accepts(candidate) }) }) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            Button("确认删除", role: .destructive) {
                do { try registry.delete(configuration, replacingWith: replacement); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        }.navigationTitle("删除模型配置").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } } }
    }
}

struct ModelBindingsView: View {
    var body: some View {
        List {
            Section { ModelBindingPanel(purpose: .dialogue); ModelBindingPanel(purpose: .summary); ModelBindingPanel(purpose: .search); ModelBindingPanel(purpose: .transcription); ModelBindingPanel(purpose: .recordingSummary); ModelBindingPanel(purpose: .recordingTranscription) }
            Section { Text("模型改名后引用保持有效；禁用、删除或调用参数变更后，旧请求会停止。配置测试仅使用固定样本，不代表已授权发送任务。").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("使用列表")
    }
}

struct OfflineSpeechModelRow: View {
    let config: ModelConfiguration
    @ObservedObject private var models = OfflineSpeechModels.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(config.name).font(.headline)
                    Text("离线 · 语音 · \(ByteCountFormatter.string(fromByteCount: models.size(config.modelID), countStyle: .file))")
                        .font(.caption).foregroundStyle(AppTheme.pine)
                    Text("来源：Hugging Face（中国境外）").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if models.isReady(config.modelID) {
                    VStack(alignment: .trailing) {
                        Text("已下载").font(.caption).foregroundStyle(AppTheme.pine)
                        Button(role: .destructive) { models.remove(config.modelID) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless).accessibilityLabel("删除 \(config.name)")
                    }
                } else if models.progress[config.modelID] == nil {
                    Button { Task { await models.download(config.modelID) } } label: {
                        Image(systemName: "arrow.down.circle").font(.title2)
                    }.buttonStyle(.borderless).accessibilityLabel("下载 \(config.name)")
                }
            }
            if let progress = models.progress[config.modelID] {
                ProgressView(value: progress).tint(.blue)
                HStack {
                    Text("下载中 \(Int(progress * 100))%")
                    Spacer()
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(models.speed[config.modelID] ?? 0), countStyle: .file))/s")
                }.font(.caption2).foregroundStyle(.secondary)
            }
            if let error = models.errors[config.modelID] {
                Text("操作失败：\(error)").font(.caption).foregroundStyle(AppTheme.terracotta).textSelection(.enabled)
            }
        }.padding(.vertical, 5)
    }
}

struct ModelBindingPanel: View {
    let purpose: ModelPurpose
    var onManage: (() -> Void)? = nil
    @EnvironmentObject private var navigation: AppNavigation
    @ObservedObject private var registry = ModelRegistry.shared
    @ObservedObject private var speechModels = OfflineSpeechModels.shared
    @State private var consent = false
    @State private var error: String?
    private var selected: ModelConfiguration? { registry.selected(purpose) }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(purpose.title + "模型").font(.headline)
            if purpose == .search { Text("跟随 AI 对话：\(selected?.name ?? "未配置")").font(.subheadline) }
            else {
                Picker("模型", selection: Binding(get: { selected?.id }, set: { id in
                    do { try registry.bind(id, to: purpose) } catch { self.error = error.localizedDescription }
                })) {
                    Text(purpose == .transcription || purpose == .recordingTranscription ? "系统离线识别" : "未配置").tag(UUID?.none)
                    ForEach(registry.configurations.filter { $0.enabled && purpose.accepts($0) || $0.id == selected?.id }) { config in Text(config.name + " · " + config.execution.title + (config.enabled ? "" : "（已禁用）")).tag(Optional(config.id)) }
                }
            }
            if let config = selected {
                Text("\(config.execution.title) · \(registry.status(config))").font(.caption).foregroundStyle(.secondary)
                if config.execution != .onDevice {
                    Text("目标：\(config.destination)").font(.caption).textSelection(.enabled)
                    if registry.authorized(purpose, config: config) {
                        Button(role: .destructive) { do { try registry.setAuthorization(false, purpose: purpose) } catch { self.error = error.localizedDescription } } label: {
                            Text("撤回本功能外发授权")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .font(.caption).buttonStyle(.borderless)
                    } else {
                        Button { consent = true } label: {
                            Label("查看并确认发送范围", systemImage: "hand.raised")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.pine).buttonStyle(.borderless)
                    }
                }
            }
            if (purpose == .transcription || purpose == .recordingTranscription) && selected == nil {
                Text(purpose == .transcription
                     ? "任务语音默认使用手机本机离线识别；也可添加音频转写服务并单独授权。"
                     : "录音默认使用手机本机离线识别；也可添加音频转写服务，录音外发需单独授权。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("管理模型配置") { if let onManage { onManage() } else { navigation.openModels() } }
                .font(.caption).buttonStyle(.borderless)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.vertical, 6)
            .confirmationDialog("允许\(purpose.title)发送到 \(selected?.name ?? "")（\(selected?.destination ?? "")）？", isPresented: $consent, titleVisibility: .visible) {
                Button("允许本功能使用此配置") { do { try registry.setAuthorization(true, purpose: purpose) } catch { self.error = error.localizedDescription } }
            } message: { Text(purpose.disclosure + "\n服务费用和数据保留由服务商决定。修改目标、模型或协议后需重新确认。") }
    }
}
