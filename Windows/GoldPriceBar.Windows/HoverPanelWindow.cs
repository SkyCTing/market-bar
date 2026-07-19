using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using GoldPriceBar.Core;

namespace GoldPriceBar.Windows;

internal sealed class HoverPanelWindow : Window
{
    private readonly TextBlock providerLabel;
    private readonly TextBlock priceLabel;
    private readonly TextBlock changeLabel;
    private readonly Dictionary<string, TextBlock> values = [];

    internal HoverPanelWindow()
    {
        Width = 320;
        SizeToContent = SizeToContent.Height;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;

        providerLabel = UiStyles.Label("积存金", 12);
        priceLabel = UiStyles.Label("¥ 0.00", 26, Brushes.White);
        priceLabel.FontWeight = FontWeights.Bold;
        priceLabel.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        changeLabel = UiStyles.Label("0.00  0.00%", 13);

        var content = new StackPanel();
        content.Children.Add(providerLabel);
        content.Children.Add(priceLabel);
        content.Children.Add(changeLabel);
        content.Children.Add(Divider());
        content.Children.Add(UiStyles.Label("行情数据", 11, UiStyles.GoldBrush));
        AddRow(content, "london", "伦敦金");
        AddRow(content, "goldTd", "黄金T+D");
        AddRow(content, "converted", "伦敦金换算 (¥/g)");
        AddRow(content, "premium", "溢价 (¥/g)");
        AddRow(content, "usdCnh", "离岸人民币");
        AddRow(content, "dxy", "美元指数");
        content.Children.Add(Divider());
        AddRow(content, "updated", "更新时间");
        AddRow(content, "interval", "刷新频率");
        AddRow(content, "alerts", "价格提醒");

        Content = new Border
        {
            CornerRadius = new CornerRadius(12),
            Background = UiStyles.PanelBrush,
            BorderBrush = new SolidColorBrush(Color.FromArgb(150, 80, 80, 85)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(16),
            Child = content,
            Effect = new System.Windows.Media.Effects.DropShadowEffect
            {
                BlurRadius = 16,
                ShadowDepth = 3,
                Opacity = 0.4,
            },
        };
    }

    internal void ShowAbove(PriceBarWindow anchor, AppSnapshot snapshot)
    {
        Update(snapshot);
        Show();
        UpdateLayout();
        var center = anchor.PointToScreen(new Point(anchor.ActualWidth / 2, anchor.ActualHeight / 2));
        var work = NativeMethods.WorkingAreaDip(
            anchor,
            new System.Drawing.Point((int)center.X, (int)center.Y));
        Left = Math.Clamp(anchor.Left + anchor.Width - Width, work.Left, work.Right - Width);
        Top = anchor.Top - ActualHeight - 6 >= work.Top
            ? anchor.Top - ActualHeight - 6
            : Math.Min(work.Bottom - ActualHeight, anchor.Top + anchor.ActualHeight + 6);
    }

    internal void Update(AppSnapshot snapshot)
    {
        providerLabel.Text = snapshot.Provider.DisplayName();
        priceLabel.Text = "¥ " + snapshot.FormattedPrice;
        changeLabel.Text = $"{snapshot.Price.ChangeAmount}  {snapshot.Price.ChangePercent}";
        changeLabel.Foreground = UiStyles.TrendBrush(snapshot.Price.IsNegative);

        SetQuote("london", snapshot.Market.LondonGold);
        SetQuote("goldTd", snapshot.Market.GoldTD);
        SetQuote("usdCnh", snapshot.Market.UsdCnh);
        SetQuote("dxy", snapshot.Market.DollarIndex);
        SetValue("converted", snapshot.Market.ConvertedPrice > 0
            ? snapshot.Market.ConvertedPrice.ToString("F2", CultureInfo.InvariantCulture)
            : "--", null);
        SetValue("premium", snapshot.Market.ConvertedPrice > 0
            ? snapshot.Market.Premium.ToString("+0.00;-0.00;0.00", CultureInfo.InvariantCulture)
            : "--", snapshot.Market.Premium);
        SetValue("updated", snapshot.LastUpdated?.ToLocalTime().ToString("HH:mm:ss") ?? "--:--:--", null);
        SetValue("interval", $"{snapshot.RefreshIntervalSeconds} 秒", null);
        var alertParts = new List<string>();
        if (snapshot.HighThreshold is double high) alertParts.Add($"≥ {high:F2}");
        if (snapshot.LowThreshold is double low) alertParts.Add($"≤ {low:F2}");
        SetValue("alerts", alertParts.Count == 0 ? "未设置" : string.Join(" | ", alertParts), null);
    }

    private void SetQuote(string key, QuoteRow row)
    {
        var percent = Math.Truncate(row.RaisePercent * 10_000) / 100;
        SetValue(key, row.Price == "--" ? "--" : $"{row.Price}  {(percent > 0 ? "+" : string.Empty)}{percent:F2}%", row.Raise);
    }

    private void SetValue(string key, string value, double? raise)
    {
        values[key].Text = value;
        values[key].Foreground = raise switch
        {
            < 0 => UiStyles.FallBrush,
            > 0 => UiStyles.RiseBrush,
            _ => Brushes.White,
        };
    }

    private void AddRow(Panel parent, string key, string title)
    {
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Auto) });
        var titleLabel = UiStyles.Label(title, 11);
        var valueLabel = UiStyles.Label("--", 11, Brushes.White);
        valueLabel.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        Grid.SetColumn(valueLabel, 1);
        grid.Children.Add(titleLabel);
        grid.Children.Add(valueLabel);
        values[key] = valueLabel;
        parent.Children.Add(grid);
    }

    private static Border Divider() => new()
    {
        Height = 1,
        Background = new SolidColorBrush(Color.FromArgb(90, 130, 130, 135)),
        Margin = new Thickness(0, 12, 0, 9),
    };
}
