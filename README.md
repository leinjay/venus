# Venus Tools iOS 原型

这是一个以 SwiftUI 编写的 iPhone + Apple Watch 原型，用于预览 Ruleline 风格和多工具 Tab 布局。各 Tab 内容仅作演示，工具清单与交互可以继续调整。

## 需求文档

- [工具目录与组织约定](docs/tools/README.md)：各工具的需求入口，以及后续按工具组织代码的目录规则。
- [任务提醒工具需求](docs/tools/reminders.md)：第一个完整工具的需求，统一编辑页支持文字/语音/图片 AI 对话与属性表单，对话和今日总结所用模型可配置；另含任务完成状态、查找过滤、依赖图、系统通知与 Apple Watch。

需求文档描述后续目标；下方“原型包含”与“当前限制”描述现有代码，两者不代表相同的实现进度。

## 打开项目

1. 在安装了 Xcode 的 Mac 上打开 VenusTools.xcodeproj。
2. 选择 VenusTools scheme 和 iPhone Simulator。
3. 点击 Run 运行 iPhone 应用。
4. 若要预览 Apple Watch 端，在 Xcode 中选择配对的 Watch Simulator；先运行 iPhone 应用以同步演示提醒。

项目使用系统 SwiftUI 和 WatchConnectivity，没有第三方依赖；原型目标版本为 iOS 17 与 watchOS 10。真机运行时需在 Xcode 中配置 Apple 开发者签名。

若当前没有 Mac，也可在浏览器中直接打开 Preview/index.html 查看并交互浏览四个 iPhone 页面。

## GitHub Actions 云端构建

仓库包含 `.github/workflows/build.yml`。推送到 `main` 或 `master`、创建 Pull Request，或在 Actions 中手动运行 `Build iOS package`，都会使用 GitHub 提供的 macOS runner 构建 iPhone 应用和 Apple Watch 配套应用，并生成 `VenusTools-unsigned.ipa`。构建完成后，可在该次 Actions 运行的 Artifacts 区域下载 `VenusTools-unsigned-ipa`。

这个 IPA 未签名，适合检查打包产物；安装到真机或通过 TestFlight 分发仍需 Apple 开发者签名与相应配置。

## 原型包含

- 专注：25 分钟倒计时。
- 换算：千米/英里即时转换。
- 清单：本机保存待办。
- 提醒：iPhone 与 Apple Watch 之间同步提醒列表，并可在手表端标记完成。

视觉颜色与卡片样式集中在 VenusTools/Shared/AppTheme.swift。计时、换算、清单和提醒数据逻辑分别位于 Stores，方便替换界面风格时保留功能定义。

## 当前限制

此工作区运行在 Windows，未安装 Xcode、iOS SDK 或 watchOS SDK，因此无法在这里编译或启动 Apple 模拟器。项目文件按 Xcode 工程结构生成，需在 Mac 上用 Xcode 打开运行。同步原型使用 WatchConnectivity 的最新列表快照，不处理两端同时编辑同一条提醒的冲突；当前不安排本地通知。
