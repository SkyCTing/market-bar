# 提醒功能实现说明（待做）

> 起因：`~/SourceCode/mac-reminders/monthly-reminder.sh` 那个 launchd + osascript 的月度提醒，想搬进 MarketBar，并且**时间/文案可自定义**。
> 已确认的三个决策：**① 宠物说话 + 声音，没理会再弹模态框**、**② 重复规则支持 每天/每周/每月**、**③ 菜单里管理**。

## 目标

- 常驻的 app 内提醒，不依赖 launchd 脚本
- 可以配置多条提醒，每条：时间（HH:mm）+ 重复规则（每天 / 每周某天 / 每月某号）+ 标题 + 正文
- 到点：人物冒气泡说正文 + 响一声 → 若 N 秒内没被确认，弹置顶模态框（「知道了 / 10 分钟后再提醒」，顺延次数封顶，沿用脚本的语义）
- 菜单里能增删改、能立即测试

## 数据模型（新增 `Sources/MarketBar/Reminder.swift`，纯逻辑可单测）

```swift
struct Reminder: Codable, Equatable, Identifiable, Sendable {
    enum Repeat: Codable, Equatable, Sendable {
        case daily                 // 每天
        case weekly(weekday: Int)  // 1=周日 … 7=周六（Calendar 的 weekday 约定）
        case monthly(day: Int)     // 1…31
    }

    var id: UUID
    var title: String      // 弹框标题
    var body: String       // 正文（人物气泡也说这句）
    var hour: Int
    var minute: Int
    var repeat: Repeat
}
```

**纯逻辑（重点测这几条）**

```swift
enum ReminderScheduler {
    /// 这条提醒在给定时刻是否该触发
    static func isDue(_ reminder: Reminder, at date: Date, calendar: Calendar = TradingSession.calendar) -> Bool
    /// 触发后的去重键：同一天同一分钟只触发一次（用 "yyyy-MM-dd HH:mm"）
    static func fireKey(_ reminder: Reminder, at date: Date, calendar: Calendar = TradingSession.calendar) -> String
    /// 下一次触发时间（菜单里显示「下次 9月15日 09:58」）
    static func nextFireDate(after date: Date, reminder: Reminder, calendar: Calendar = TradingSession.calendar) -> Date?
}
```

- `monthly(day:)` 遇到「31 号但当月只有 30 天」：**当月没有这一天就跳过**（不提前、不顺延，简单可预期）
- 全部用北京时间（复用 `TradingSession.calendar`，本机时区无关，有现成测试范式）

## 持久化

- `UserDefaults` 存 JSON 数组：`defaults.set(try? JSONEncoder().encode(reminders), forKey: "reminders")`
- 键名加进现有的 `SettingsKey`（`MarketBar.swift` 里那个私有枚举），顺手加进 `loadSettings()` / `saveSettings()`
- 已触发记录（去重键）只放内存，不持久化 —— 重启后同一天同一分钟可能重复触发一次，可接受

## 调度

- 复用 app 已有的 1 秒 tick（`refreshPrice()`），或用独立的 20–30 秒 `Timer`
  - **建议独立 timer（30 秒）**：提醒不需要秒级精度，也避免和金价刷新耦合
- 每 tick：对每条 reminder 算 `isDue`，再用 `fireKey` 去重；命中就进入「提醒流程」
- 睡眠唤醒后不补偿（错过就错过），简单可预期

## 提醒流程（两个都要）

1. `FloatingCharacterController.showSpeech(...)` 让人物说正文（已有接口，说话气泡是现成的）+ `NSSound(named:)` 响一声
2. 起一个 60 秒的 timer；期间如果用户在菜单里点了「知道了」或气泡消失事件触发，则取消
3. 60 秒内没被确认 → 弹**置顶模态框**（`NSAlert`，`.critical` 级别，`runModal()`），按钮：「知道了」/「10 分钟后再提醒」
   - 顺延：最多 6 次（沿用脚本的 `MAX_SNOOZE=6`），每次 10 分钟
   - ⚠️ `runModal()` 会阻塞主线程一整轮 —— 这期间金价刷新会停。**可以接受**（和脚本行为一致），但要在代码注释里写明
4. 声音：`NSSound(named: "Sosumi")`（脚本用的那个），连续响 3 声

## 菜单（`rebuildMenu()` 里加）

新增「提醒」子菜单（放在「设置刷新频率」附近）：

```
提醒
├── 09:58  每月15号 · 还信用卡     （点击 = 编辑）
├── 14:50  每天 · 看一下收盘
├── ──────────
├── 添加提醒…
├── 清空全部
└── 测试：立即提醒
```

- **添加**：`NSAlert` + accessory view（沿用现有 `showPriceInputDialog` 的写法）
  - 第一个框：时间，`HH:mm` 格式（用 `DatePicker` 更省事，`.hourMinute` 模式）
  - 第二个框：重复（`NSPopUpButton`：每天 / 每周X / 每月X号）
  - 第三个框：正文
- **编辑**：点已有条目 → 同一个对话框，预填当前值
- **删除**：列表项按 `⌥` 点击删除，或子菜单里加「删除…」

## 文件清单

| 文件 | 改动 |
|---|---|
| `Sources/MarketBar/Reminder.swift` | 新增：模型 + `ReminderScheduler` 纯逻辑 |
| `Sources/MarketBar/ReminderCenter.swift` | 新增：调度 timer、去重、提醒流程、snooze 状态机 |
| `Sources/MarketBar/MarketBar.swift` | `SettingsKey` 加键、load/save、`rebuildMenu()` 加子菜单、AppDelegate 接线、`applicationDidFinishLaunching` 启动 timer |
| `Tests/MarketBarTests/ReminderTests.swift` | 新增：`isDue` 的三种重复规则、去重键、`nextFireDate`、月末边界（31 号） |

## 验证

1. `swift build` + `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`（当前 159 项要保持全绿）
2. 菜单里添加一条「1 分钟后」的每天提醒 → 等一分钟 → 人物气泡 + 声音 → 不理会 60 秒 → 模态框 → 点「10 分钟后再提醒」→ 确认顺延
3. 用「测试：立即提醒」跳过等待
4. 重启 app，确认配置还在

## 注意

- ⚠️ **改完代码重新安装 app 后，辅助功能授权会失效**（签名变化）—— 见项目记忆 `marketbar-permissions`。提醒功能本身不需要辅助功能权限，但微信未读徽标需要，重装后要提醒用户重新授权
- 模态框会阻塞整轮刷新，`runModal` 前后各记一条日志便于排查

---

# 第二轮改进（用户 2026-09-25 提出，待做）

## 1. 时间精确到秒

- `Reminder` 加 `second: Int = 0`；`timeText` 变 `HH:mm:ss`
- `ReminderScheduler.isDue` 比较到秒；`fireKey` 也带上秒（同秒只触发一次）
- ⚠️ **扫描间隔要改**：现在 30 秒扫一次，做不到秒级。改成 `nextFireDate` 计算的**精确排程**（定一个 Timer 到那个时刻），每次触发/配置变更后重排下一次
- UI 的时间输入换成 `NSDatePicker`（`datePickerElements = .hourMinuteSecond`）

## 2. 配置界面人性化

现在是把「每天 / 每周日…每周六 / 每月1号…每月31号」共 39 项塞进一个 `NSPopUpButton`，太糙。改成：

- 时间：`NSDatePicker`（时/分/秒）
- 重复：`NSPopUpButton` 只有三项 —— **每天 / 每周 / 每月**
- 选「每周」时，**下面才出现**一个「周几」的星期选择器（7 个分段控件或第二个 popup）
- 选「每月」时，**下面才出现**一个「几号」的输入（1–31，或 popup）
- 文案：一个输入框
- 用一个自定义 `NSView` 做 accessory view，按上面结构手动布局（参考现有 `showPriceInputDialog` 与价格提醒对话框的写法）

## 3.「智能跳过节假日」开关

- `Reminder` 加 `skipHolidays: Bool = false`
- 勾选后，触发前先查节假日（**已有现成数据**：`MarketCalendar.HolidayCache.load(year:to:)` + `MarketCalendar.isTradingDay`，每天自动拉一次）
- **待确认的行为**：撞上节假日时是
  - (a) **直接跳过**（当天不提醒），还是
  - (b) **顺延到下一个交易日/工作日**再提醒（比如「每月 15 号还信用卡」撞上周六 → 周一提醒）
  → 实现前先问用户；建议默认 (b)，更符合「还信用卡」这类场景
- 这个开关同样受用于周末：勾选后周末也不提醒

## 验证补充

- 秒级：设一条「1 分钟 10 秒后」的提醒，确认误差在 1 秒内
- 节假日：把系统日期临时改到某个法定节假日（或用注入的 holidays 字典写单测），确认跳过/顺延符合预期
