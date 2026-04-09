# GoldPriceBar

macOS 状态栏黄金积存金实时价格监控应用。

积存金数据来源于京东金额。https://gold-price-pro.pf.jd.com/

## 功能

### 实时金价显示

- 启动后在状态栏显示当前黄金价格，默认展示 `浙商积存金 xx.xx`
- 接口取值失败时显示 `0.00`

### 数据源切换

- 菜单支持切换 `浙商积存金` / `民生积存金`

### 刷新频率设置

- 支持设置刷新间隔：`1 秒`、`2 秒`、`5 秒`、`10 秒`
- 当前选中频率会打勾标记

### 价格提醒

- 支持设置 **高价提醒**（金价 ≥ 设定值时提醒）
- 支持设置 **低价提醒**（金价 ≤ 设定值时提醒）
- 触发时弹出悬浮 Toast 通知窗口 + 系统提示音
- 每次穿越阈值只通知一次，价格回到正常范围后自动复位
- 支持修改、清除单个提醒或一键清除所有提醒

### 设置持久化

- 数据源、刷新频率、高低价提醒阈值均通过 `UserDefaults` 持久化
- 退出重启后自动恢复上次设置

## 系统要求

- macOS 13.0 (Ventura) 及以上
- Swift 6.2+

## 代码结构

```
goldPriceBar/
├── Package.swift                              # Swift Package 工程定义
├── AppIcon.icns                               # 应用图标
├── Sources/goldPriceBar/
│   └── goldPriceBar.swift                     # 应用主实现
├── scripts/
│   └── build-dmg.sh                           # DMG 打包脚本
└── dist/                                      # 打包产出目录
    ├── GoldPriceBar.app                       # macOS 应用包
    └── GoldPriceBar-1.0.0.dmg                 # DMG 安装包
```

## 运行方式

### 方式一：Xcode 运行

1. 使用 Xcode 打开项目目录中的 `Package.swift`
2. 选择 `goldPriceBar` 可执行目标
3. 直接运行

### 方式二：命令行运行

```bash
swift build
.build/debug/goldPriceBar
```

## 打包发布

运行打包脚本，自动完成 release 编译 → 创建 .app 包 → 生成 DMG：

```bash
bash scripts/build-dmg.sh
```

产出文件位于 `dist/` 目录：

- `GoldPriceBar.app` — macOS 应用包
- `GoldPriceBar-1.0.0.dmg` — DMG 安装包（含 Applications 快捷方式，可拖拽安装）

## 技术实现

| 模块 | 技术方案 |
|------|----------|
| UI 框架 | AppKit（NSStatusBar + NSMenu） |
| 网络请求 | URLSession + async/await |
| 数据解析 | JSONDecoder（Codable） |
| 通知提醒 | 自定义悬浮 Toast 窗口（NSPanel） |
| 数据持久化 | UserDefaults |
| 并发安全 | Swift Strict Concurrency（@MainActor） |