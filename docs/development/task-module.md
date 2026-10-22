# 任务模块首轮实现约定

- 日期：2026-10-21
- 分支：`codex/task-module`，从当前 `main` 提交创建，保留工作区已有设置需求修改。
- 产品需求入口：[任务提醒](../tools/reminders.md)。本文记录当前开发阶段及差异，不替代正式需求。

用户要求开始实现任务模块，模型暂时写死本地 Qwen3。因此本轮对话、智能查找与今日总结固定使用 `mlx-community/Qwen3-1.7B-4bit`，暂不交付设置文档中的多服务商配置。后续通过独立服务替换为配置绑定，不将地址或密钥放进任务模型。

Qwen3 权重固定 revision `3b1b1768f8f8cf8351c712464f906e86c2b8269e`，MLX Swift examples 固定 `2.25.9`，仅链接 iPhone。模型不进入 Git 或安装包。iPhone 提供用户主动下载、取消、删除与 Files 目录导入；电脑准备脚本校验权重后缓存至被忽略的 `.models/`。Windows 不能执行 MLX；本机运行指 iPhone 本机，不是连接电脑的推理服务器。

本轮实现任务属性、列表/网格、筛选排序、统一编辑页、共享草稿、三方字段合并、详情/依赖、回收站、最近版本、今日助手、系统通知及手机权威的 Watch 完成操作。旧提醒 UUID、时间和完成状态保留；未知历史完成时间不伪造。

Watch 快照超过 40 KB 时通过文件传输，不截断任务；完成操作和确认保留小消息通道。较新的逐任务确认不能被较慢返回的旧快照覆盖，排队意图仅在对应确认版本仍有效时续交。文件传输完成时间仍取决于系统调度。

本轮媒体阶段约定：语音采用系统支持的本机语音识别，强制离线，不可用时说明原因；尚未接入 WhisperKit。图片提供选图/拍摄/粘贴及本机 OCR，必须明确由用户选择文字提取模式；Qwen3 不具备视觉能力，无文字照片不宣称理解成功。完整场景理解、图片裁剪和 Whisper 模型下载仍按正式需求后续接入。本轮不将这些条目标为验收通过。

模型输出仅提出字段变更，通过字段、长度、时间和依赖校验后合并草稿；未保存手动修改优先。编辑期间手机或 Watch 的新值在保存前做三方比较，冲突需用户选择。无效、取消、超时或迟到输出不能直接写入任务。

验证使用独立的 Foundation 规则测试及 macOS 云端 Xcode 构建；通知呈现、配对手表离线操作、模型真机推理与速度仍须 iPhone 16 / Apple Watch 实机验证。成功编译不等同于达到需求中的质量和性能门槛。

## 使用与模型准备

1. 在 Mac 的 Xcode 打开 `VenusTools.xcodeproj`，等待 Swift Package 解析后运行 `VenusTools` scheme。模型运行库仅链接 iPhone 目标，Watch 无模型依赖。
2. 默认进入任务工具。点击新建进入独立编辑页，可先切属性表单直接保存一条任务。
3. AI 对话页与今日总结中都有“本机 Qwen3”准备区。主动选择 Wi-Fi 下载；使用蜂窝网络需单独确认。模型完整性校验成功才标记就绪。
4. 也可运行 `python scripts/install_qwen3.py`，将生成的 `.models/Qwen3-1.7B-4bit` 整个目录复制到手机 Files，再用“导入目录”选择它。电脑下载不代表手机已经安装；应用会重新校验每个文件。
5. 准备完成后关闭网络，检查对话、智能查找与今日总结。模型删除只清理权重，任务与已保存文本仍保留。

`Package.resolved` 固定本轮已解析的传递依赖，避免换电脑后自动换用另一套运行库。权重 revision、每个文件的大小及 SHA-256 同时固定在 iPhone 服务中，导入和下载使用同一套校验。

## 本轮检查范围

- 核心规则测试覆盖迁移、依赖循环及共同前置、三方合并、Watch 字段版本与确认后的排队意图、日期跨时区、今日口径、模糊查找、相关性和旧字段限长。
- 本地语法检查遍历全部 Swift 文件；工程检查解析 Xcode 项目并检查对象标识及文件引用。
- 通过分支推送触发 macOS 构建 iPhone 与 Watch 配套应用，产出未签名 IPA。真实运行需要 Apple 开发者签名；未签名 IPA不能直接作为真机安装包。
- 打包阶段额外检查手机包内的 Watch 应用与 MLX Metal 资源，不能只检查两个目标各自编译成功。原型的 Watch 嵌入目录为空，本轮修正到手机包的 `Watch/`，并使用单目标 watchOS 应用的 `WKApplication` 标识。
- 本轮尚未测得需求文档中的 AI 准确率、推理延迟或设备内存结果；系统语音可用性、本地网络与系统权限、通知呈现、手表后台传输仍须在对应设备上验证。

## 安装包与 Apple Watch 安装约定（2026-10-22）

用户反馈包含 Watch 子包的 IPA 在 AltServer 传输时导致崩溃。此前只验证了编译和包结构，没有验证 AltServer 侧载；目前也没有崩溃堆栈，不能确定其内部失败原因。为隔离这项兼容问题，云端始终编译完整工程，再提供两份名称明确的产物：

| Actions 产物 | 内含文件 | 用途 |
| --- | --- | --- |
| `VenusTools-iPhone-only-unsigned-ipa` | `VenusTools-iPhone-only-unsigned.ipa` | 供 AltServer / AltStore 对 iPhone 应用重新签名并安装；不含 Watch 应用。 |
| `VenusTools-iPhone-Watch-unsigned-ipa` | `VenusTools-iPhone-Watch-unsigned.ipa` | 保留完整 iPhone 与 Watch 结构供检查；不作为当前 AltServer 安装入口。 |

两份 IPA 均未签名，不能直接安装。完整应用的真机开发安装走下方 Xcode 流程；不能把“未签名的完整 IPA”当作可直接传给手表的安装文件。AltStore 官方仓库的 [Apple Watch 重签名支持问题 #229](https://github.com/altstoreio/AltStore/issues/229) 仍未关闭；这不证明所有当前版本都失败，也不足以保证本项目能通过 AltServer 安装 Watch 应用。

iPhone-only 产物由 `scripts/package_iphone_only.py` 从完整 IPA 派生，移除 `Watch/`、WatchKit 支持文件及其他识别出的 watchOS 子包，保留手机程序、iOS 扩展、文件权限与 MLX Metal 资源。回归测试校验移除范围、保留内容、源文件保护及重复打包；流水线仍要求完整包内存在 Watch 应用。源码与 Watch 目标继续保留。手机会区分“未配对手表”和“手表任务应用尚未安装”，避免误报正在同步。

### 给手表安装开发版

1. 使用 Mac 上的 Xcode 打开 `VenusTools.xcodeproj`。在 `VenusTools` 与 `VenusToolsWatch` 两个目标的 Signing & Capabilities 中选择同一个开发团队并开启自动签名。
2. 如需改成自己的唯一 Bundle ID，手机例如使用 `com.yourname.VenusTools`，手表使用 `com.yourname.VenusTools.watchkitapp`；同时把 Watch 的 `WKCompanionAppBundleIdentifier` 改成手机的 ID，Debug 与 Release 保持一致。不要混用被侧载工具改过 ID 的手机包和仍指向原 ID 的 Watch 包。
3. 将已配对 Apple Watch 的 iPhone 连接 Mac，解锁并信任电脑，按系统提示启用手机和手表的开发者模式，等待 Xcode 完成设备准备。
4. 先选择 `VenusTools` scheme，在这台 iPhone 上运行；再选择 `VenusToolsWatch` scheme，以配对的 Apple Watch 为运行目标并运行。Xcode 完成签名和安装后，在手表上检查任务列表、完成操作与手机同步。

依据：[Apple 的真机运行步骤](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html)、[watchOS 工程与配套 Bundle ID 约束](https://developer.apple.com/documentation/technotes/tn3157-updating-your-watchos-project-for-swiftui-and-widgetkit)。本项目尚未完成 Windows 到真实 Watch 的安装验证；后续查到的社区 iLoader Watch 分支及本轮精简查看版，统一见 [Venus Watch 精简版与 Windows 安装](watch-companion.md)。该实验性路线不依赖用户拥有 Mac，也不代表已经验证所有设备与系统版本。

只安装 iPhone-only 版时，没有手表上的任务列表与完成操作；手机已获准发送的通知仍可由系统转发到配对手表，无须先安装 watchOS 应用，具体显示取决于通知镜像设置与设备状态，见 [Apple 的 watchOS 通知说明](https://developer.apple.com/documentation/watchOS-Apps/notifications)。这与 WatchConnectivity 数据同步是两条不同的能力。

验证边界：打包测试及云端编译可以验证两份产物结构，不能代替 AltServer、签名、手机通知或手表同步的实机验收。本次调整尚未实测 AltServer 安装。
