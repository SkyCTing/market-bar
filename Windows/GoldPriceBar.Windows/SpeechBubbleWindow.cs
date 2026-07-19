using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using DrawingPoint = System.Drawing.Point;

namespace GoldPriceBar.Windows;

internal sealed class SpeechBubbleWindow : Window
{
    private readonly TextBlock label;
    private readonly DispatcherTimer dismissTimer;

    internal SpeechBubbleWindow()
    {
        Width = 196;
        Height = 62;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = false;
        IsHitTestVisible = false;

        label = UiStyles.Label(string.Empty, 13, new SolidColorBrush(Color.FromRgb(70, 46, 97)));
        label.TextAlignment = TextAlignment.Center;
        label.TextWrapping = TextWrapping.Wrap;
        label.HorizontalAlignment = HorizontalAlignment.Stretch;
        Content = new Border
        {
            CornerRadius = new CornerRadius(13),
            Background = new SolidColorBrush(Color.FromArgb(250, 255, 251, 242)),
            BorderBrush = new SolidColorBrush(Color.FromRgb(125, 65, 174)),
            BorderThickness = new Thickness(1.5),
            Padding = new Thickness(12, 8, 12, 8),
            Child = label,
        };
        dismissTimer = new DispatcherTimer();
        dismissTimer.Tick += (_, _) => HideBubble();
    }

    internal void ShowBubble(string text, Window anchor, TimeSpan? duration)
    {
        label.Text = text;
        Reposition(anchor);
        if (!IsVisible) Show();
        dismissTimer.Stop();
        if (duration is not null)
        {
            dismissTimer.Interval = duration.Value;
            dismissTimer.Start();
        }
    }

    internal void Reposition(Window anchor)
    {
        if (!anchor.IsLoaded) return;
        var dpi = NativeMethods.Dpi(anchor);
        var centerPhysical = anchor.PointToScreen(new Point(anchor.ActualWidth / 2, 0));
        var work = NativeMethods.WorkingAreaDip(
            anchor,
            new DrawingPoint((int)centerPhysical.X, (int)centerPhysical.Y));
        var anchorLeft = centerPhysical.X / dpi.DpiScaleX - anchor.ActualWidth / 2;
        var anchorTop = centerPhysical.Y / dpi.DpiScaleY;
        Left = Math.Clamp(anchorLeft + anchor.ActualWidth / 2 - Width / 2, work.Left, work.Right - Width);
        Top = anchorTop - Height - 6;
        if (Top < work.Top)
        {
            Top = Math.Min(work.Bottom - Height, anchorTop + anchor.ActualHeight + 6);
        }
    }

    internal void HideBubble()
    {
        dismissTimer.Stop();
        Hide();
    }
}
