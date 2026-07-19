using System.Media;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace GoldPriceBar.Windows;

internal sealed class ToastWindow : Window
{
    private static ToastWindow? current;
    private readonly DispatcherTimer dismissTimer;

    private ToastWindow(string title, string body)
    {
        Width = 380;
        SizeToContent = SizeToContent.Height;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = false;

        var stack = new StackPanel();
        var titleLabel = UiStyles.Label(title, 16, Brushes.White);
        titleLabel.FontWeight = FontWeights.Bold;
        var bodyLabel = UiStyles.Label(body, 13, new SolidColorBrush(Color.FromRgb(225, 225, 225)));
        bodyLabel.TextWrapping = TextWrapping.Wrap;
        bodyLabel.Margin = new Thickness(0, 7, 0, 0);
        stack.Children.Add(titleLabel);
        stack.Children.Add(bodyLabel);

        Content = new Border
        {
            CornerRadius = new CornerRadius(12),
            Background = UiStyles.PanelBrush,
            BorderBrush = UiStyles.GoldBrush,
            BorderThickness = new Thickness(4, 1, 1, 1),
            Padding = new Thickness(18, 15, 18, 15),
            Child = stack,
        };

        dismissTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        dismissTimer.Tick += (_, _) => Dismiss();
        MouseLeftButtonUp += (_, _) => Dismiss();
    }

    internal static void ShowToast(string title, string body)
    {
        current?.Dismiss();
        SystemSounds.Beep.Play();
        var toast = new ToastWindow(title, body);
        current = toast;
        toast.Show();
        toast.UpdateLayout();
        var work = SystemParameters.WorkArea;
        toast.Left = work.Right - toast.Width - 20;
        toast.Top = work.Top + 20;
        toast.Opacity = 0;
        toast.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(220)));
        toast.dismissTimer.Start();
    }

    private void Dismiss()
    {
        dismissTimer.Stop();
        var animation = new DoubleAnimation(0, TimeSpan.FromMilliseconds(180));
        animation.Completed += (_, _) =>
        {
            if (ReferenceEquals(current, this)) current = null;
            Close();
        };
        BeginAnimation(OpacityProperty, animation);
    }
}
