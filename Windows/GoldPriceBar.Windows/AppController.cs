using System.Drawing;
using System.Globalization;
using System.Windows;
using System.Windows.Threading;
using GoldPriceBar.Core;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace GoldPriceBar.Windows;

internal sealed class AppController : IDisposable
{
    private readonly Dispatcher dispatcher;
    private readonly SettingsStore settingsStore;
    private readonly GoldPriceService service = new();
    private readonly PriceAlertEvaluator alertEvaluator = new();
    private readonly MarketReactionDetector marketDetector = new();
    private readonly DispatcherTimer refreshTimer = new();
    private readonly DispatcherTimer hoverDismissTimer = new() { Interval = TimeSpan.FromMilliseconds(180) };
    private readonly SemaphoreSlim saveLock = new(1, 1);
    private readonly Forms.NotifyIcon trayIcon = new();
    private readonly Forms.ContextMenuStrip trayMenu = new();
    private readonly PriceBarWindow priceBar = new();
    private readonly HoverPanelWindow hoverPanel = new();
    private readonly FloatingCharacterWindow character;
    private readonly AppSettings settings;
    private readonly CancellationTokenSource cancellation = new();
    private Icon? applicationIcon;
    private PriceInfo currentPrice = PriceInfo.Empty;
    private MarketData currentMarket = MarketData.Empty;
    private DateTimeOffset? lastUpdated;
    private bool fetching;
    private bool disposed;

    private AppController(Dispatcher dispatcher, SettingsStore settingsStore, AppSettings settings)
    {
        this.dispatcher = dispatcher;
        this.settingsStore = settingsStore;
        this.settings = settings;
        character = new FloatingCharacterWindow(settings);
        refreshTimer.Tick += async (_, _) => await RefreshAsync();
        hoverDismissTimer.Tick += (_, _) =>
        {
            hoverDismissTimer.Stop();
            hoverPanel.Hide();
        };
        priceBar.HoverEntered += ShowHover;
        priceBar.HoverExited += ScheduleHoverDismiss;
        priceBar.LeftClicked += ToggleHover;
        priceBar.RightClicked += ShowTrayMenu;
        priceBar.DragStarted += () =>
        {
            hoverDismissTimer.Stop();
            hoverPanel.Hide();
        };
        hoverPanel.MouseEnter += (_, _) => hoverDismissTimer.Stop();
        hoverPanel.MouseLeave += (_, _) => ScheduleHoverDismiss();
        character.PlacementChanged += placement =>
        {
            settings.CharacterLeft = placement.Left;
            settings.CharacterTop = placement.Top;
            settings.CharacterMonitor = placement.Monitor;
            settings.CharacterDocked = placement.Docked;
            settings.CharacterDockEdge = placement.DockEdge;
            _ = SaveSettingsAsync();
        };
    }

    internal static async Task<AppController> CreateAsync(Dispatcher dispatcher)
    {
        var store = new SettingsStore();
        var settings = await store.LoadAsync();
        return new AppController(dispatcher, store, settings);
    }

    internal void Start()
    {
        ConfigureTray();
        RebuildMenu();
        priceBar.Update(Snapshot());
        priceBar.Show();
        character.UpdateQuote("0.00", null);
        character.SetCharacterVisible(settings.FloatingCharacterVisible);
        character.SetPowerSaving(NativeMethods.IsBatterySaverEnabled);
        RestartRefreshTimer();
        SystemEvents.SessionSwitch += HandleSessionSwitch;
        SystemEvents.PowerModeChanged += HandlePowerModeChanged;
        _ = RefreshAsync();
    }

    internal void ShowDetails()
    {
        if (!disposed) ShowHover();
    }

    private void ConfigureTray()
    {
        var resource = System.Windows.Application.GetResourceStream(
            new Uri("pack://application:,,,/Assets/AppIcon.ico", UriKind.Absolute));
        if (resource is not null)
        {
            applicationIcon = new Icon(resource.Stream);
            trayIcon.Icon = applicationIcon;
        }
        else
        {
            trayIcon.Icon = SystemIcons.Information;
        }
        trayIcon.Text = "GoldPriceBar 0.00";
        trayIcon.Visible = true;
        trayIcon.ContextMenuStrip = trayMenu;
        trayIcon.MouseClick += (_, args) =>
        {
            if (args.Button == Forms.MouseButtons.Left)
            {
                dispatcher.BeginInvoke(ToggleHover);
            }
        };
    }

    private async Task RefreshAsync()
    {
        if (fetching || disposed) return;
        fetching = true;
        try
        {
            var providerAtStart = settings.Provider;
            var priceInfo = await service.FetchPriceInfoAsync(providerAtStart, cancellation.Token);
            if (providerAtStart != settings.Provider) return;
            currentPrice = priceInfo;
            lastUpdated = DateTimeOffset.Now;
            UpdatePriceSurfaces();

            if (priceInfo.IsValid)
            {
                var reaction = marketDetector.Process(priceInfo.Price, DateTimeOffset.Now);
                if (reaction is not null) character.ReactToMarket(reaction);
                CheckAlerts(priceInfo.Price);
            }

            currentMarket = await service.FetchMarketDataAsync(priceInfo.Price, cancellation.Token);
            if (providerAtStart != settings.Provider) return;
            if (hoverPanel.IsVisible) hoverPanel.Update(Snapshot());
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        finally
        {
            fetching = false;
        }
    }

    private void UpdatePriceSurfaces()
    {
        var snapshot = Snapshot();
        priceBar.Update(snapshot);
        character.UpdateQuote(snapshot.FormattedPrice, currentPrice.IsNegative);
        trayIcon.Text = TruncateTooltip($"{settings.Provider.DisplayName()} {snapshot.FormattedPrice}");
        if (hoverPanel.IsVisible) hoverPanel.Update(snapshot);
    }

    private AppSnapshot Snapshot() => new(
        settings.Provider,
        currentPrice,
        currentMarket,
        lastUpdated,
        settings.RefreshIntervalSeconds,
        settings.HighThreshold,
        settings.LowThreshold);

    private void CheckAlerts(double price)
    {
        foreach (var alert in alertEvaluator.Evaluate(price, settings.HighThreshold, settings.LowThreshold))
        {
            if (alert == PriceAlertKind.High && settings.HighThreshold is double high)
            {
                ToastWindow.ShowToast(
                    "📈 金价上涨提醒",
                    $"{settings.Provider.DisplayName()} 当前价格 {price:F2}，已达到 ≥ {high:F2} 的提醒条件");
            }
            else if (alert == PriceAlertKind.Low && settings.LowThreshold is double low)
            {
                ToastWindow.ShowToast(
                    "📉 金价下跌提醒",
                    $"{settings.Provider.DisplayName()} 当前价格 {price:F2}，已达到 ≤ {low:F2} 的提醒条件");
            }
        }
    }

    private void RebuildMenu()
    {
        trayMenu.Items.Clear();
        foreach (var provider in Enum.GetValues<GoldProvider>())
        {
            var item = new Forms.ToolStripMenuItem(provider.DisplayName())
            {
                Checked = provider == settings.Provider,
                Enabled = provider != settings.Provider,
            };
            item.Click += async (_, _) => await SelectProviderAsync(provider);
            trayMenu.Items.Add(item);
        }

        var refresh = new Forms.ToolStripMenuItem("设置刷新频率");
        foreach (var seconds in new[] { 1, 2, 5, 10 })
        {
            var item = new Forms.ToolStripMenuItem($"{seconds} 秒") { Checked = settings.RefreshIntervalSeconds == seconds };
            item.Click += (_, _) =>
            {
                settings.RefreshIntervalSeconds = seconds;
                RestartRefreshTimer();
                RebuildMenu();
                _ = SaveSettingsAsync();
                if (hoverPanel.IsVisible) hoverPanel.Update(Snapshot());
            };
            refresh.DropDownItems.Add(item);
        }
        trayMenu.Items.Add(refresh);
        trayMenu.Items.Add(BuildAlertsMenu());
        trayMenu.Items.Add(new Forms.ToolStripSeparator());
        trayMenu.Items.Add(BuildCharacterMenu());
        trayMenu.Items.Add(new Forms.ToolStripSeparator());
        var quit = new Forms.ToolStripMenuItem("退出");
        quit.Click += (_, _) => System.Windows.Application.Current.Shutdown();
        trayMenu.Items.Add(quit);
    }

    private Forms.ToolStripMenuItem BuildAlertsMenu()
    {
        var alerts = new Forms.ToolStripMenuItem("价格提醒");
        if (settings.HighThreshold is double high)
        {
            alerts.DropDownItems.Add(new Forms.ToolStripMenuItem($"📈 高价提醒: ≥ {high:F2}") { Enabled = false });
            AddAlertCommands(alerts, true, "修改高价提醒", "清除高价提醒");
        }
        else
        {
            var setHigh = new Forms.ToolStripMenuItem("设置高价提醒 (≥)");
            setHigh.Click += (_, _) => EditAlert(true);
            alerts.DropDownItems.Add(setHigh);
        }
        alerts.DropDownItems.Add(new Forms.ToolStripSeparator());
        if (settings.LowThreshold is double low)
        {
            alerts.DropDownItems.Add(new Forms.ToolStripMenuItem($"📉 低价提醒: ≤ {low:F2}") { Enabled = false });
            AddAlertCommands(alerts, false, "修改低价提醒", "清除低价提醒");
        }
        else
        {
            var setLow = new Forms.ToolStripMenuItem("设置低价提醒 (≤)");
            setLow.Click += (_, _) => EditAlert(false);
            alerts.DropDownItems.Add(setLow);
        }
        if (settings.HighThreshold is not null || settings.LowThreshold is not null)
        {
            alerts.DropDownItems.Add(new Forms.ToolStripSeparator());
            var clear = new Forms.ToolStripMenuItem("清除所有提醒");
            clear.Click += (_, _) =>
            {
                settings.HighThreshold = null;
                settings.LowThreshold = null;
                alertEvaluator.Reset();
                RebuildMenu();
                _ = SaveSettingsAsync();
            };
            alerts.DropDownItems.Add(clear);
        }
        return alerts;
    }

    private void AddAlertCommands(
        Forms.ToolStripMenuItem parent,
        bool high,
        string editTitle,
        string clearTitle)
    {
        var edit = new Forms.ToolStripMenuItem(editTitle);
        edit.Click += (_, _) => EditAlert(high);
        var clear = new Forms.ToolStripMenuItem(clearTitle);
        clear.Click += (_, _) =>
        {
            if (high) settings.HighThreshold = null; else settings.LowThreshold = null;
            alertEvaluator.Reset();
            RebuildMenu();
            _ = SaveSettingsAsync();
        };
        parent.DropDownItems.Add(edit);
        parent.DropDownItems.Add(clear);
    }

    private Forms.ToolStripMenuItem BuildCharacterMenu()
    {
        var floating = new Forms.ToolStripMenuItem("浮动窗口");
        var visible = new Forms.ToolStripMenuItem("显示人物") { Checked = settings.FloatingCharacterVisible };
        visible.Click += (_, _) =>
        {
            settings.FloatingCharacterVisible = !settings.FloatingCharacterVisible;
            character.SetCharacterVisible(settings.FloatingCharacterVisible);
            RebuildMenu();
            _ = SaveSettingsAsync();
        };
        floating.DropDownItems.Add(visible);
        var sizeMenu = new Forms.ToolStripMenuItem("调整大小");
        foreach (var option in Enum.GetValues<CharacterSize>())
        {
            var title = option switch
            {
                CharacterSize.Small => "最小（220×220）",
                CharacterSize.Standard => "默认（240×240）",
                CharacterSize.Large => "最大（260×260）",
                _ => option.ToString(),
            };
            var item = new Forms.ToolStripMenuItem(title) { Checked = settings.FloatingCharacterSize == option };
            item.Click += (_, _) =>
            {
                settings.FloatingCharacterSize = option;
                character.SetSize(option);
                RebuildMenu();
                _ = SaveSettingsAsync();
            };
            sizeMenu.DropDownItems.Add(item);
        }
        floating.DropDownItems.Add(sizeMenu);
        return floating;
    }

    private async Task SelectProviderAsync(GoldProvider provider)
    {
        settings.Provider = provider;
        currentPrice = PriceInfo.Empty;
        currentMarket = MarketData.Empty;
        marketDetector.Reset();
        alertEvaluator.Reset();
        UpdatePriceSurfaces();
        RebuildMenu();
        await SaveSettingsAsync();
        await RefreshAsync();
    }

    private void EditAlert(bool high)
    {
        var dialog = new PriceInputDialog(
            high ? "设置高价提醒" : "设置低价提醒",
            high ? "当金价 ≥ 输入值时发送通知提醒" : "当金价 ≤ 输入值时发送通知提醒",
            high ? settings.HighThreshold : settings.LowThreshold);
        if (dialog.ShowDialog() != true || dialog.Value is not double value) return;
        if (high) settings.HighThreshold = value; else settings.LowThreshold = value;
        alertEvaluator.Reset();
        RebuildMenu();
        _ = SaveSettingsAsync();
    }

    private void RestartRefreshTimer()
    {
        refreshTimer.Stop();
        refreshTimer.Interval = TimeSpan.FromSeconds(settings.RefreshIntervalSeconds);
        refreshTimer.Start();
    }

    private void ShowHover()
    {
        hoverDismissTimer.Stop();
        if (!hoverPanel.IsVisible) hoverPanel.ShowAbove(priceBar, Snapshot());
        else hoverPanel.Update(Snapshot());
    }

    private void ToggleHover()
    {
        if (hoverPanel.IsVisible) hoverPanel.Hide(); else ShowHover();
    }

    private void ScheduleHoverDismiss()
    {
        hoverDismissTimer.Stop();
        hoverDismissTimer.Start();
    }

    private void ShowTrayMenu()
    {
        RebuildMenu();
        trayMenu.Show(Forms.Cursor.Position);
    }

    private void HandleSessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        dispatcher.BeginInvoke(() => character.SetSessionActive(
            e.Reason is not (SessionSwitchReason.SessionLock or SessionSwitchReason.SessionLogoff or SessionSwitchReason.SessionRemoteControl)));
    }

    private void HandlePowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        dispatcher.BeginInvoke(() =>
        {
            if (e.Mode == PowerModes.Suspend) character.SetScreenAwake(false);
            if (e.Mode == PowerModes.Resume) character.SetScreenAwake(true);
            character.SetPowerSaving(NativeMethods.IsBatterySaverEnabled);
        });
    }

    private async Task SaveSettingsAsync()
    {
        await saveLock.WaitAsync();
        try
        {
            await settingsStore.SaveAsync(settings);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
        finally
        {
            saveLock.Release();
        }
    }

    private static string TruncateTooltip(string value) => value.Length <= 63 ? value : value[..63];

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        cancellation.Cancel();
        refreshTimer.Stop();
        hoverDismissTimer.Stop();
        SystemEvents.SessionSwitch -= HandleSessionSwitch;
        SystemEvents.PowerModeChanged -= HandlePowerModeChanged;
        trayIcon.Visible = false;
        trayIcon.Dispose();
        trayMenu.Dispose();
        hoverPanel.Close();
        priceBar.Dispose();
        character.Dispose();
        applicationIcon?.Dispose();
        cancellation.Dispose();
        saveLock.Dispose();
    }
}
