# Windows 浏览器预览 Venus Tools

更新时间：2026-10-26

每次现有 `Build iOS package` 工作流运行时，新增独立任务 `Build Appetize iOS Simulator preview`，与真机包同时构建，生成 ARM64 iOS Simulator 应用。触发条件为推送到 `main`、`master`、`codex/task-module`、Pull Request 或手动运行工作流。Appetize 任务与真机打包任务互不依赖，各自显示成功或失败。

## 下载哪个文件

| GitHub Artifacts 名称 | 用途 |
| --- | --- |
| `VenusTools-Appetize-iOS-Simulator` | 上传 Appetize，在 Windows 浏览器查看原生页面和基本操作 |
| `VenusTools-iPhone-only-unsigned-ipa` | 重新签名后安装到真实 iPhone |
| `VenusTools-iPhone-Watch-unsigned-ipa` | 真实 iPhone 和 Watch 的配套安装包 |

Appetize 需要真正以 `iphonesimulator` 编译的 `.app`，并压缩成 ZIP；现有真机 IPA 解压或改后缀不能替代模拟器构建。官方推荐 ARM 模拟器包，见 [Appetize 的 iOS 构建要求](https://docs.appetize.io/platform/app-management/uploading-apps/ios)。

## 第一次使用

1. 登录 GitHub，打开 [Venus Actions](https://github.com/leinjay/venus/actions/workflows/build.yml)。
2. 找到最新一轮构建，确认 `Build Appetize iOS Simulator preview` 成功。若需要手动构建，点击 **Run workflow**，选择包含当前代码的分支后运行；当前开发分支为 `codex/task-module`。
3. 在该次运行页面的 **Artifacts** 下载 `VenusTools-Appetize-iOS-Simulator`。
4. **只解压 GitHub 下载的外层 ZIP 一次**。里面会有 `VenusTools-Appetize-iOS-Simulator.zip`；保留这个内层 ZIP，上传它。内层 ZIP 的根目录应为 `VenusTools.app/`，不是 `Payload/`。
5. 打开 [Appetize 上传页面](https://appetize.io/upload)，按页面提示注册或登录账号，上传上述内层 ZIP。无需 Apple 开发者证书。
6. 处理完成后进入该应用预览页，选择可用的 iPhone 设备与 **iOS 17 或更新版本**，启动预览。使用鼠标点击、拖动和键盘输入，浏览任务、设置、专注、换算、清单等页面。具体设备和可用时长以 Appetize 账号当前页面为准。

本次工作流只生成并保存 GitHub 构建产物；上传 Appetize 由用户按上面步骤操作，不要求在仓库填写 Appetize API 密钥。

## 后续更新

从新一轮构建下载同名 artifact，再在 [Appetize Apps](https://appetize.io/apps) 选择原有应用，进入对应 build 的 **Settings → Update build**，上传新的内层 ZIP。这样可以继续使用已有应用入口。操作以 [Appetize 更新说明](https://docs.appetize.io/platform/app-management/uploading-apps) 为准。

## 预览范围

- 可用来检查真实 SwiftUI 页面、导航、表单、本地任务增删改和皮肤切换；这不是之前的 HTML 原型。
- 本机 Qwen3 推理需要真机体验；云模拟器不作为 MLX GPU、内存、速度或离线语音识别的验收环境。摄像头、麦克风、通知等能力以云平台支持为准。
- 预览 ZIP 不包含 Watch 配套应用；手表页面和跨设备同步仍需配对的真实设备或 Mac 上的配对模拟器。
- 需要试用外部模型时，可自行添加测试配置；保存配置不等于发起调用，仍遵循原有外发授权流程。云预览不建议导入个人正式密钥或真实任务材料，外部模型调用可能另行计费。
- 流水线会检查 ARM64 架构、`iPhoneSimulator` 平台、MLX 资源、ZIP 根目录和校验，防止误上传真机包。构建成功不等于已在 Appetize 账号中完成运行验证。

## 常见问题

- **提示包无效：** 检查是否误上传 GitHub 的外层 artifact ZIP，或选了 `.ipa`。应上传内层 `VenusTools-Appetize-iOS-Simulator.zip`。
- **页面出现不支持的设备或系统提示：** 选择符合 iOS 17 及以上的可用运行环境。
- **看不到最新改动：** 确认下载的构建属于正确分支和提交，并更新了 Appetize 中对应的 build。
- **模拟器任务失败：** 打开该任务的构建日志查看具体错误；真机包与预览包独立产出，不能用真机 IPA 顶替模拟器包。
