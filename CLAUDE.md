# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 常用命令

```bash
swift build                       # → .build/debug/MarketBar

# 本机只装了 Command Line Tools，跑测试必须指定 Xcode 工具链
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ReminderSchedulerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ReminderSchedulerTests/testNextFireDate

bash scripts/build-dmg.sh                 # → dist/MarketBar.app + dist/MarketBar-<版本>.dmg
bash scripts/release.sh 1.2.3 "发布说明"    # 改版本号→打包→提交→tag→推送→建 Release
swift scripts/make-icon.swift             # 重新生成 AppIcon.icns
bash scripts/make-focus-shortcuts.sh      # 重新生成 FocusShortcuts/ 里两个快捷指令
```

SwiftPM 可执行目标，**没有 Xcode 工程、没有外部依赖**。

## 架构

### 谁持有谁

`AppDelegate`（`Sources/MarketBar/MarketBar.swift`，全仓最大的文件）是所有东西的持有者：状态栏项、菜单、悬停面板、刷新定时器，以及每个功能的 controller。

**菜单每次打开都整体重建** —— `menuNeedsUpdate` → `rebuildMenu()` 先 `removeAllItems()` 再从零铺一遍。所以菜单项状态永远是最新的，不要为菜单加「只刷新某一项」的逻辑，那和现有做法会打架。

### 主循环

`refreshPrice()` 是核心循环：`@MainActor`，由 1 秒定时器驱动，被 `quoteRefreshGate` 门控（防止重入）。**任何网络调用都不能 await 在这里** —— 它会占住刷新槽，拖慢金价和状态栏。要发请求就起 detached `Task`（参考 `scheduleDailyBarsLoadIfNeeded`）。

### 每个功能的形状

- **纯逻辑**：不 `import AppKit`，可直接单测。`Reminder.swift`（调度规则）、`PriceAlert.swift`（阈值判定）、`WatchlistDraft.swift`、`AppUpdate.swift`、`MeetingMode.swift` 等
- **状态 + 持久化**：`@MainActor final class XxxStore`，`init(defaults: UserDefaults = .standard)` 可注入 —— 测试传自己的 suite
- **UI / 编排**：放 `AppDelegate`，或独立的 `XxxWindow` / `XxxController`

最容易写错的逻辑（日期、版本号比较、坐标几何、状态映射）都被刻意抽成纯函数，就是为了能钉测试。

### 呈现层有个必须知道的形状

`AlertPresenter` 是**所有**提醒（定时、倒计时、价格提醒）的唯一显示入口。但它有**两条内部旁路**会绕过 `fire`：

1. `armPendingConfirm` 的确认计时器**直接调 `presentModal`**
2. 顺延（「10 分钟后再提醒」）计时器**重入 `fire`**

任何「全局拦截提醒」的需求（会议模式就是）**两处都要堵**，只堵 `fire` 会漏弹窗。

### 网络

没有统一的 HTTP 层。每个功能自己写一个可注入的 `Transport` 闭包（见 `AISign.swift` / `AppUpdate.swift` / `StockTrend.swift` / `GoldHistoryRecorder.swift`），测试用具名 `actor` 做应答队列 —— **不要用 `URLProtocol`**。

### 测试

XCTest（**不是** swift-testing）。需要 AppKit 的用例标 `@MainActor`；注入 `UserDefaults(suiteName: "Xxx.\(UUID())")` 并在 tearDown 里 `removePersistentDomain`。

⚠️ 测试之间会通过 `NSApp.windows` 互相污染：有的用例靠 `NSApp.windows.first { ... }` 找自己的窗口。**凡是创建了人物/气泡窗口的测试，tearDown 里必须把它们收掉**，否则会把别的测试指到错误的窗口上。

## 跨文件的硬约定

**给持久化模型加字段，必须手写 `init(from:)` 并用 `decodeIfPresent` 兜底。** Swift 合成的解码器遇到缺字段会抛 `keyNotFound` —— 结果是整个模型解不出来，**用户数据被清空**。数组还要逐条 lossy 解码（`Reminder.swift` 的 `LossyReminder`），一条坏数据不能让整份归零。`save()` 绝不能在编码失败时 `set(nil)`，那等于删掉整个 key。

**版本号只有一个来源**：`scripts/build-dmg.sh` 里的 `VERSION`，`release.sh` 是唯一写入者。Info.plist 是打包时才生成的，仓库里没有 —— 所以 `swift run` 出来的进程**没有 bundle**，凡是读版本号的功能（「关于」「检查更新」「开机自启动」）都要处理这种情况并优雅降级。

## 环境坑（踩过，代价不小）

- **`log` 被 shell 里的同名函数劫持**，`log show ...` 报 `too many arguments`。查应用日志一律用 `/usr/bin/log`。这个坑让我误判过好几次「日志里没有记录」——其实是命令根本没跑起来。同理，`cmd | head` 之后的 `$?` 是 `head` 的退出码，不是 `cmd` 的；要看真实退出码就不要接管道。
- **ad-hoc 签名**：每次覆盖安装 `/Applications/MarketBar.app` 都会让 **辅助功能**、**自动化**、**登录项** 三项授权同时失效。本地验证尽量攒着一次装完。
- 状态栏项在外接屏上，`screencapture` 要加 `-D 2`；应用日志里的进程名是 `MarketBar`。

## 看着像 bug、但不是

- `FloatingCharacter.swift` 里徽标约束的 `.multiplier: 0.76` —— AppKit 的约束纵向坐标是**翻转**的，`.centerY == 0.76 × .bottom` 落在距底 24%（身体位置）。这是要的效果，别「修」。
- 会议模式下状态栏显示的 `——` 是**故意留的占位**：状态栏项按内容定宽，留空会缩到几乎点不到，用户就找不回来关掉了。

## 平台限制（别去试，已经查证过）

- **设置系统专注模式（勿扰）没有公开 API**：`INFocusStatus.isFocused` 是 `readonly`，无 DoNotDisturb framework，老的 `defaults write com.apple.notificationcenterui` 在 Big Sur 之后已失效。只能借道快捷指令（见 `FocusShortcuts/` 与 `scripts/make-focus-shortcuts.sh`）。
- **探测「屏幕正在被共享/录制」没有公开 API**：整个 SDK 只有早已废弃的 `CGDisplayIsCaptured`；系统的屏幕录制指示器**也不在** `CGWindowListCopyWindowInfo` 里（实测录制前后 123 个窗口一个不多）。麦克风/摄像头**占用**倒是能探测（CoreAudio / CoreMediaIO，无需权限）。
- **`SMAppService` 的状态反直觉**：从没注册过的 app 报 `.notFound`，`.notRegistered` 只在「注册后又注销」时出现。
- 老格式 `.plist` 喂给 `shortcuts sign` 会报「格式不对」：它只吃**二进制** plist，且输入文件**必须带 `.shortcut` 扩展名**。

## 其它

`docs/reminders-plan.md` 是提醒功能的设计说明。README.md 面向用户，是功能与用法的权威描述——改了行为记得同步。
