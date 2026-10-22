# Venus Tools iOS 原型

这是一个以 SwiftUI 编写的 iPhone + Apple Watch 多工具应用。任务提醒已进入首轮实现，专注、换算和清单保留原型功能；页面沿用 Ruleline 风格。

## 需求文档

- [工具目录与组织约定](docs/tools/README.md)：各工具的需求入口，以及后续按工具组织代码的目录规则。
- [任务提醒工具需求](docs/tools/reminders.md)：第一个完整工具的需求，统一编辑页支持文字/语音/图片 AI 对话与属性表单，对话和今日总结所用模型可配置；另含任务完成状态、查找过滤、依赖图、系统通知与 Apple Watch。
- [任务模块开发与模型准备](docs/development/task-module.md)：首轮实现边界、固定 Qwen3 安装及手机导入步骤。

需求文档描述后续目标；下方“当前实现”与“当前限制”描述现有代码，两者不代表相同的实现进度。

## 打开项目

1. 在安装了 Xcode 的 Mac 上打开 VenusTools.xcodeproj。
2. 选择 VenusTools scheme 和 iPhone Simulator。
3. 点击 Run 运行 iPhone 应用。
4. 若要预览 Apple Watch 端，在 Xcode 中选择配对的 Watch Simulator；先运行 iPhone 应用以同步演示提醒。

项目使用 SwiftUI、WatchConnectivity 与固定版本的 MLX Swift 依赖，目标为 iOS 17 与 watchOS 10。Xcode 会解析运行库；Qwen3 权重通过应用主动下载或 Files 导入，不进入安装包。真机运行时需在 Xcode 中配置 Apple 开发者签名。

若当前没有 Mac，也可在浏览器中直接打开 Preview/index.html 查看并交互浏览四个 iPhone 页面。

## GitHub Actions 云端构建

仓库包含 `.github/workflows/build.yml`。推送到 `main`、`master` 或 `codex/task-module`、创建 Pull Request，或在 Actions 中手动运行 `Build iOS package`，都会使用 GitHub 提供的 macOS runner 构建 iPhone 应用和 Apple Watch 配套应用。构建完成后，在该次 Actions 运行的 Artifacts 区域选择：

- `VenusTools-iPhone-only-unsigned-ipa`：手机安装入口，内含 `VenusTools-iPhone-only-unsigned.ipa`，供 AltServer / AltStore 重新签名；已移除 Watch 子包。
- `VenusTools-iPhone-Watch-unsigned-ipa`：完整手机与手表配套包，内含 `VenusTools-iPhone-Watch-unsigned.ipa`，供社区 iLoader Watch 分支尝试签名安装；不作为 AltServer 安装入口。

两份 IPA 都未签名，不能直接安装。包含 Watch 的旧包存在用户反馈的 AltServer 崩溃，本次拆包尚未实测 AltServer 安装。手表开发版可使用 Mac + Xcode 统一签名并运行；Windows 实验性安装步骤及功能约定见 [Venus Watch 精简版与 Windows 安装](docs/development/watch-companion.md)。只安装手机版仍可使用系统通知镜像，手表任务列表与完成操作需安装配套应用。

## 当前实现

- 专注：25 分钟倒计时。
- 换算：千米/英里即时转换。
- 清单：本机保存待办。
- 任务：独立新建/编辑页（AI 对话与属性表单）、完整任务属性、本地草稿与版本、列表/网格、查找过滤、详情/依赖图、回收站、今日助手和系统通知；Watch 精简版查看待办、今日任务、最近完成及概要，支持手动同步和离线缓存。

任务模块位于 `VenusTools/Tools/Reminders/`，按 iOS、Watch、Shared 组织；本机 Qwen3 服务位于 `VenusTools/iOS/AI/`。主题与卡片样式继续使用 `VenusTools/Shared/AppTheme.swift`。

## 当前限制

当前工作区为 Windows，不能在这里执行 MLX 或运行 Apple 模拟器。规则测试与完整编译通过 macOS Actions 检查；推理准确率、速度、通知呈现与手表后台同步仍须真机验证。本轮语音使用系统离线识别；图片仅提供明确选择的本机 OCR，完整照片场景理解和 WhisperKit 尚未接入。设置中的多模型绑定仍待实现，当前固定本机 Qwen3。
