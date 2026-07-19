using System.Globalization;
using System.Windows;
using System.Windows.Controls;

namespace GoldPriceBar.Windows;

internal sealed class PriceInputDialog : Window
{
    private readonly TextBox input;

    internal PriceInputDialog(string title, string message, double? currentValue)
    {
        Title = title;
        Width = 380;
        Height = 190;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = false;
        Topmost = true;

        input = new TextBox
        {
            Text = currentValue?.ToString("F2", CultureInfo.InvariantCulture) ?? string.Empty,
            Margin = new Thickness(0, 12, 0, 14),
            FontSize = 14,
        };
        var ok = new Button { Content = "确定", Width = 80, IsDefault = true, Margin = new Thickness(6, 0, 0, 0) };
        var cancel = new Button { Content = "取消", Width = 80, IsCancel = true, Margin = new Thickness(6, 0, 0, 0) };
        ok.Click += (_, _) =>
        {
            if (!double.TryParse(input.Text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var value) || value <= 0)
            {
                MessageBox.Show(this, "请输入有效的正数价格。", "输入无效", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            Value = value;
            DialogResult = true;
        };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);
        var panel = new StackPanel { Margin = new Thickness(20) };
        panel.Children.Add(UiStyles.Label(message, 13, System.Windows.Media.Brushes.Black));
        panel.Children.Add(input);
        panel.Children.Add(buttons);
        Content = panel;
        Loaded += (_, _) => { input.Focus(); input.SelectAll(); };
    }

    internal double? Value { get; private set; }
}
