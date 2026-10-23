# Venus Watch 精简版与 Windows 安装

- 日期：2026-10-22；基于当前 `codex/task-module` 分支。
- 本轮目标：在真实 Apple Watch 安装 Venus，查看手机任务并接收执行时间提醒。手机与手表属于同一个应用的配套安装，不新建独立任务库。
- 用户设备：iPhone 18 Pro / iOS 27.0.1，Apple Watch Series 11 / watchOS 27.0.1（按用户提供的信息记录）。社区工具的公开实测主要覆盖 watchOS 26；不能把这些记录等同于本组设备安装已验证。

## 本轮功能约定

1. 手表提供“待办 / 今天 / 已完成”三个范围，默认待办。最近完成仅保留近 7 个自然日，手机任务不因此删除。
2. 列表展示标题、执行时间、完成状态；详情补充概要、重要程度及未完成前置数量。手表首版不提供创建、AI、编辑表单、依赖图或完成状态修改入口；历史版本尚未确认的完成操作继续使用已有确认协议处理。
3. 手机是任务数据的唯一来源。手表接收所有未删除的未完成任务与近 7 日已完成任务；仅传递查看和版本校验所需属性，不传 Markdown 正文、图片、标签、AI 对话或模型。
4. 手机保存、修改、完成或删除任务后推送最新快照。手表启动、回到前台和手动点击同步时请求快照；不可立即连接时排队请求，保留已有缓存并说明状态。首次未同步不能显示“已同步”，空任务库需区别于尚未收到数据。
5. 显示最近实际收到快照的时间；读取本机缓存不伪造同步时间。大于 40 KB 的快照继续走后台文件传输，不截断任务，也不覆盖更新的任务确认。
6. 提醒由 iPhone 统一安排，通过系统通知转发到配对手表；手表不重复安排同一任务的本地通知。这一阶段不承诺手机离线后手表独立定时提醒。需要允许手机通知、开启 Watch 镜像，并符合系统关于手机锁屏、手表佩戴及解锁等条件。
7. 配套 IPA 保留现有手机版，Watch 不包含 Qwen3 或新增付费能力。安装器要对两端使用同一个账号、协调签名及 Bundle ID，才能验证 WatchConnectivity 数据共享。不能把另一账号或另一 Bundle ID 的旧手机应用当作这一安装的主应用。

## 2026-10-23 配色调整

Watch 列表、空态、同步状态和任务详情统一沿用手机版的米白背景 `#F5F2E9`、浅色卡片 `#FFFDF7`、深色正文 `#26352C` 与深绿 `#315744`。此前部分文字继承 watchOS 默认浅色前景，叠在米白背景上辨识不清；两页现通过同一个页面修饰器明确正文前景和背景，并使用 watchOS 的 navigation container background 统一导航容器背景。

小字号辅助文字单独加深为 `#566459`，重要程度与前置提示使用深琥珀 `#875019`；不修改手机版公共色值。选中范围和同步按钮为深绿底、浅色文字，未选范围与任务卡片增加浅边线。颜色按米白背景及卡片两种底色检查文字对比度，目标均至少 4.5:1。此次仅调整显示，保留原有任务同步、筛选和操作。

配套构建版本更新为 4，手机与 Watch 保持相同版本及原 Bundle ID。Windows 可检查 Swift 语法、色值对比和云端编译；实际字号、导航文字及常亮显示仍需 Watch 真机确认。导航背景 API 依据 [Apple containerBackground 文档](https://developer.apple.com/documentation/swiftui/view/containerbackground(_:for:))。

## Windows 安装步骤

现有真实软件目录为 `D:\software-common`，工具放在 `D:\software-common\iLoader`。选择 [AndreySemjonov 的 iLoader Watch 分支 v2.3.4-fork.2](https://github.com/AndreySemjonov/iloader/releases/tag/v2.3.4-fork.2)，这是社区维护的便携版本，不是原版 iLoader 的官方发布。下载后核对发布页的 SHA-256 与构建来源，不把 Apple 账号或配对文件写入项目。

使用本次构建的 `VenusTools-iPhone-Watch-unsigned.ipa`，不要选择移除了 Watch 的 iPhone-only IPA。它仍是未签名包，由 iLoader 使用用户自己的账号重新签名后安装；本机准备好安装文件不等于已经安装到手机或手表。

1. 在 iPhone 和 Watch 开启开发者模式；手机连接电脑，解锁并信任电脑，手表保持解锁并靠近手机。
2. 打开 iLoader，用户自行登录 Apple 账号，选择 iPhone。
3. 选择 `Your apps → More installation options → Install once`，选择完整配套 IPA。等待手机安装与手表安装分别完成。
4. 在 iPhone 打开 Venus；创建或编辑任务后，在 Watch 打开 Venus 并点击同步。确认标题、概要、时间及完成状态与手机一致，再关闭连接验证缓存仍可查看。
5. 在手机创建 2 分钟后执行的任务并允许通知；在 iPhone 的 Watch App 中开启 Venus 通知镜像。佩戴并解锁手表，锁定手机屏幕，检查到时提醒。先退出会抑制通知的专注模式。
6. 免费签名约 7 天到期，需用同一账号再次 `Install once` 续签。该分支的自动续签只覆盖手机应用，不能当作已支持 Watch 自动续签。

来源：[作者的 Windows 安装与免费账号说明](https://github.com/AndreySemjonov/X6-Watch-Remote#on-windows-recommended-iloader-fork)、[Apple 通知转发机制](https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding)。社区有部分硬件的成功记录，不能代替本项目与用户设备组合的实测。

## 验证范围

交付前验证快照筛选和精简、旧版本快照合并、打包结构，以及 macOS 云端对 iPhone 和 watchOS 的真实编译。检查 IPA 内两端 Bundle ID、配套引用、最低系统版本和可执行文件。模型只链接手机，Watch 不携带模型资源。

账号登录、设备信任、手表开发者模式、通知镜像及真机安装结果需要用户在自己的设备上完成；不要求用户在聊天中提供密码。验收区分“已编译 / 已打包 / 安装器已放置”和“手机、手表已安装运行”。
