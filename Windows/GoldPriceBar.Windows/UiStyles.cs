using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace GoldPriceBar.Windows;

internal static class UiStyles
{
    internal static readonly Brush RiseBrush = new SolidColorBrush(Color.FromRgb(242, 64, 56));
    internal static readonly Brush FallBrush = new SolidColorBrush(Color.FromRgb(52, 199, 89));
    internal static readonly Brush NeutralBrush = new SolidColorBrush(Color.FromRgb(175, 175, 175));
    internal static readonly Brush GoldBrush = new SolidColorBrush(Color.FromRgb(255, 214, 0));
    internal static readonly Brush PanelBrush = new SolidColorBrush(Color.FromArgb(246, 35, 35, 38));

    internal static Brush TrendBrush(bool? isNegative) => isNegative switch
    {
        true => FallBrush,
        false => RiseBrush,
        null => NeutralBrush,
    };

    internal static TextBlock Label(string text, double size = 12, Brush? brush = null) => new()
    {
        Text = text,
        FontFamily = new FontFamily("Segoe UI"),
        FontSize = size,
        Foreground = brush ?? NeutralBrush,
        VerticalAlignment = VerticalAlignment.Center,
    };

    internal static string Price(double value) => value.ToString("F2", CultureInfo.InvariantCulture);

    internal static string Percentage(QuoteRowView row)
    {
        var percent = Math.Truncate(row.RaisePercent * 10_000) / 100;
        return $"{row.Price}  {(percent > 0 ? "+" : string.Empty)}{percent:F2}%";
    }
}

internal readonly record struct QuoteRowView(string Price, double Raise, double RaisePercent);
