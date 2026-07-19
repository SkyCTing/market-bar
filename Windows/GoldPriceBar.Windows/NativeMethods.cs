using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using DrawingPoint = System.Drawing.Point;
using FormsScreen = System.Windows.Forms.Screen;

namespace GoldPriceBar.Windows;

internal static class NativeMethods
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LastInputInfo
    {
        public uint Size;
        public uint Time;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SystemPowerStatus
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public uint BatteryLifeTime;
        public uint BatteryFullLifeTime;
    }

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LastInputInfo info);

    [DllImport("kernel32.dll")]
    private static extern bool GetSystemPowerStatus(out SystemPowerStatus status);

    [DllImport("user32.dll")]
    internal static extern uint GetDoubleClickTime();

    internal static TimeSpan IdleDuration
    {
        get
        {
            var info = new LastInputInfo { Size = (uint)Marshal.SizeOf<LastInputInfo>() };
            if (!GetLastInputInfo(ref info))
            {
                return TimeSpan.Zero;
            }
            var elapsed = unchecked((uint)Environment.TickCount - info.Time);
            return TimeSpan.FromMilliseconds(elapsed);
        }
    }

    internal static bool IsBatterySaverEnabled =>
        GetSystemPowerStatus(out var status) && status.SystemStatusFlag == 1;

    internal static DpiScale Dpi(Window window) => VisualTreeHelper.GetDpi(window);

    internal static Rect WorkingAreaDip(Window window, DrawingPoint physicalPoint)
    {
        var screen = FormsScreen.FromPoint(physicalPoint);
        var dpi = Dpi(window);
        return new Rect(
            screen.WorkingArea.Left / dpi.DpiScaleX,
            screen.WorkingArea.Top / dpi.DpiScaleY,
            screen.WorkingArea.Width / dpi.DpiScaleX,
            screen.WorkingArea.Height / dpi.DpiScaleY);
    }

    internal static Rect PrimaryWorkingAreaDip(Window window)
    {
        var screen = FormsScreen.PrimaryScreen ?? FormsScreen.AllScreens[0];
        var dpi = Dpi(window);
        return new Rect(
            screen.WorkingArea.Left / dpi.DpiScaleX,
            screen.WorkingArea.Top / dpi.DpiScaleY,
            screen.WorkingArea.Width / dpi.DpiScaleX,
            screen.WorkingArea.Height / dpi.DpiScaleY);
    }

    internal static DrawingPoint CursorPosition => System.Windows.Forms.Cursor.Position;

    internal static string MonitorName(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        return FormsScreen.FromHandle(handle).DeviceName;
    }
}
