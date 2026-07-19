using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using GoldPriceBar.Core;
using Microsoft.Win32;
using FormsScreen = System.Windows.Forms.Screen;

namespace GoldPriceBar.Windows;

internal sealed class PriceBarWindow : Window, IDisposable
{
    private const double DragThreshold = 4;

    private readonly TextBlock providerLabel;
    private readonly TextBlock priceLabel;
    private readonly TextBlock changeLabel;
    private bool dragging;
    private bool dragStarted;
    private bool hasUserMoved;
    private Point dragStartPoint;
    private double dragStartLeft;
    private double dragStartTop;
    private double maximumDragDistance;

    internal PriceBarWindow()
    {
        Width = 360;
        Height = 42;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        Cursor = Cursors.SizeAll;

        providerLabel = UiStyles.Label("浙商", 12, Brushes.White);
        providerLabel.FontWeight = FontWeights.SemiBold;
        priceLabel = UiStyles.Label("0.00", 17, Brushes.White);
        priceLabel.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        priceLabel.FontWeight = FontWeights.Bold;
        changeLabel = UiStyles.Label("(0.00 0.00%)", 12, UiStyles.NeutralBrush);
        changeLabel.FontFamily = new FontFamily("Cascadia Mono, Consolas");

        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(providerLabel);
        row.Children.Add(new Border { Width = 10 });
        row.Children.Add(priceLabel);
        row.Children.Add(new Border { Width = 10 });
        row.Children.Add(changeLabel);

        Content = new Border
        {
            CornerRadius = new CornerRadius(10),
            Background = UiStyles.PanelBrush,
            BorderBrush = new SolidColorBrush(Color.FromArgb(150, 90, 90, 95)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(14, 6, 14, 6),
            Child = row,
            Effect = new System.Windows.Media.Effects.DropShadowEffect
            {
                BlurRadius = 12,
                ShadowDepth = 2,
                Opacity = 0.35,
            },
        };

        Loaded += (_, _) => PositionNearTaskbar();
        MouseEnter += (_, _) => HoverEntered?.Invoke();
        MouseLeave += (_, _) => HoverExited?.Invoke();
        MouseLeftButtonDown += HandleMouseDown;
        MouseMove += HandleMouseMove;
        MouseLeftButtonUp += HandleMouseUp;
        LostMouseCapture += HandleLostMouseCapture;
        MouseRightButtonUp += (_, _) => RightClicked?.Invoke();
        SystemEvents.DisplaySettingsChanged += HandleDisplaySettingsChanged;
        SystemEvents.UserPreferenceChanged += HandleUserPreferenceChanged;
    }

    internal event Action? HoverEntered;
    internal event Action? HoverExited;
    internal event Action? LeftClicked;
    internal event Action? RightClicked;
    internal event Action? DragStarted;

    internal void Update(AppSnapshot snapshot)
    {
        providerLabel.Text = snapshot.Provider.ShortName();
        priceLabel.Text = snapshot.FormattedPrice;
        var info = snapshot.Price;
        changeLabel.Text = $"({info.ChangeAmount} {info.ChangePercent})";
        changeLabel.Foreground = UiStyles.TrendBrush(info.IsNegative);
    }

    internal void PositionNearTaskbar()
    {
        if (!IsLoaded)
        {
            return;
        }

        var screen = FormsScreen.PrimaryScreen ?? FormsScreen.AllScreens[0];
        var dpi = NativeMethods.Dpi(this);
        var work = screen.WorkingArea;
        var bounds = screen.Bounds;
        var workLeft = work.Left / dpi.DpiScaleX;
        var workTop = work.Top / dpi.DpiScaleY;
        var workRight = work.Right / dpi.DpiScaleX;
        var workBottom = work.Bottom / dpi.DpiScaleY;
        const double gap = 8;

        Left = workRight - Width - gap;
        Top = workBottom - Height - gap;
        if (work.Top > bounds.Top)
        {
            Top = workTop + gap;
        }
        if (work.Left > bounds.Left)
        {
            Left = workLeft + gap;
            Top = workBottom - Height - gap;
        }
    }

    private void HandleMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left || dragging)
        {
            return;
        }

        dragging = true;
        dragStarted = false;
        maximumDragDistance = 0;
        dragStartPoint = PointToScreen(e.GetPosition(this));
        dragStartLeft = Left;
        dragStartTop = Top;
        CaptureMouse();
        e.Handled = true;
    }

    private void HandleMouseMove(object sender, MouseEventArgs e)
    {
        if (!dragging || e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        var point = PointToScreen(e.GetPosition(this));
        var dpi = NativeMethods.Dpi(this);
        var deltaX = (point.X - dragStartPoint.X) / dpi.DpiScaleX;
        var deltaY = (point.Y - dragStartPoint.Y) / dpi.DpiScaleY;
        maximumDragDistance = Math.Max(maximumDragDistance, Math.Sqrt(deltaX * deltaX + deltaY * deltaY));
        if (!dragStarted && maximumDragDistance >= DragThreshold)
        {
            dragStarted = true;
            hasUserMoved = true;
            DragStarted?.Invoke();
        }

        if (!dragStarted)
        {
            return;
        }

        var physical = new System.Drawing.Point((int)point.X, (int)point.Y);
        var work = NativeMethods.WorkingAreaDip(this, physical);
        var placement = PriceBarPlacementPolicy.Clamp(
            dragStartLeft + deltaX,
            dragStartTop + deltaY,
            Width,
            Height,
            work.Left,
            work.Top,
            work.Width,
            work.Height);
        Left = placement.Left;
        Top = placement.Top;
    }

    private void HandleMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (!dragging || e.ChangedButton != MouseButton.Left)
        {
            return;
        }

        var wasDrag = dragStarted;
        dragging = false;
        ReleaseMouseCapture();
        if (wasDrag)
        {
            SnapToCurrentScreen();
        }
        else
        {
            LeftClicked?.Invoke();
        }
        e.Handled = true;
    }

    private void HandleLostMouseCapture(object sender, MouseEventArgs e)
    {
        if (!dragging)
        {
            return;
        }

        var wasDrag = dragStarted;
        dragging = false;
        if (wasDrag)
        {
            SnapToCurrentScreen();
        }
    }

    private void SnapToCurrentScreen()
    {
        var work = NativeMethods.WorkingAreaDip(this, NativeMethods.CursorPosition);
        var placement = PriceBarPlacementPolicy.ClampAndSnap(
            Left,
            Top,
            Width,
            Height,
            work.Left,
            work.Top,
            work.Width,
            work.Height);
        Left = placement.Left;
        Top = placement.Top;
    }

    private void HandleWorkAreaChanged()
    {
        if (!IsLoaded)
        {
            return;
        }

        if (!hasUserMoved)
        {
            PositionNearTaskbar();
            return;
        }

        var center = PointToScreen(new Point(ActualWidth / 2, ActualHeight / 2));
        var physical = new System.Drawing.Point((int)center.X, (int)center.Y);
        var work = NativeMethods.WorkingAreaDip(this, physical);
        var placement = PriceBarPlacementPolicy.ClampAndSnap(
            Left,
            Top,
            Width,
            Height,
            work.Left,
            work.Top,
            work.Width,
            work.Height);
        Left = placement.Left;
        Top = placement.Top;
    }

    public void Dispose()
    {
        SystemEvents.DisplaySettingsChanged -= HandleDisplaySettingsChanged;
        SystemEvents.UserPreferenceChanged -= HandleUserPreferenceChanged;
        Close();
    }

    private void HandleDisplaySettingsChanged(object? sender, EventArgs e) =>
        Dispatcher.BeginInvoke(HandleWorkAreaChanged);

    private void HandleUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e) =>
        Dispatcher.BeginInvoke(HandleWorkAreaChanged);
}
