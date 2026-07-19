# GoldPriceBar for Windows

Windows 客户端使用 .NET 10 WPF 开发，与 Swift macOS 客户端共享人物图片和产品行为。

## 功能

- 默认在主任务栏附近显示金价条；支持左键拖动、跨屏放置和上下左右边缘吸附
- 浙商/民生积存金、1/2/5/10 秒刷新、行情详情和高低价提醒
- 完整浮动人物、三档尺寸、红涨绿跌、左右贴边、睡眠唤醒及低电量暂停
- 随机动作、中文气泡、1 元快速行情反应、连续点击彩蛋及拖拽惯性
- 单实例运行；设置保存到 `%LocalAppData%/GoldPriceBar/settings.json`

## 开发

要求 Windows 10/11 x64 与 .NET 10 SDK：

```powershell
dotnet restore Windows/GoldPriceBar.sln
dotnet test Windows/GoldPriceBar.sln -c Release
dotnet run --project Windows/GoldPriceBar.Windows/GoldPriceBar.Windows.csproj
```

## 便携发布

```powershell
./scripts/build-windows.ps1
```

脚本会运行测试并生成自包含的 `dist/GoldPriceBar-Windows-x64-1.0.2.zip`。用户解压后直接运行 `GoldPriceBar.exe`，无需安装 .NET。
