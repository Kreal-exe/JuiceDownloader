using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace JuiceDownloader.Controls;

/// <summary>Applies Windows 11 Mica (DWM system backdrop) and dark/light title-bar mode to a WPF window.</summary>
public static class WindowBackdrop
{
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
    private const int DWMSBT_NONE = 1;
    private const int DWMSBT_MAINWINDOW = 2; // Mica

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    private const int GWL_STYLE = -16;
    private const int WS_SYSMENU = 0x00080000;
    private const uint SWP_FRAMECHANGED = 0x0020;
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOZORDER = 0x0004;

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr hwnd, int index);

    [DllImport("user32.dll")]
    private static extern int SetWindowLong(IntPtr hwnd, int index, int value);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    /// <summary>
    /// With the glass frame extended over the whole client area, DWM keeps painting its own caption buttons
    /// underneath ours. Dropping WS_SYSMENU removes them; our custom buttons handle minimize/maximize/close.
    /// </summary>
    public static void HideSystemCaptionButtons(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;
        var style = GetWindowLong(hwnd, GWL_STYLE);
        SetWindowLong(hwnd, GWL_STYLE, style & ~WS_SYSMENU);
        SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER);
    }

    public static bool IsSupported => Environment.OSVersion.Version.Build >= 22621;

    /// <summary>Returns true when Mica is active and the window content should be translucent.</summary>
    public static bool Apply(Window window, bool dark, bool enable)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return false;

        var darkMode = dark ? 1 : 0;
        try { DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref darkMode, sizeof(int)); } catch { /* older builds */ }

        var active = false;
        if (enable && IsSupported)
        {
            var backdrop = DWMSBT_MAINWINDOW;
            try { active = DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int)) == 0; } catch { active = false; }
        }
        else if (IsSupported)
        {
            var none = DWMSBT_NONE;
            try { DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref none, sizeof(int)); } catch { /* ignore */ }
        }

        if (HwndSource.FromHwnd(hwnd) is { CompositionTarget: { } target })
        {
            // Transparent composition lets the DWM material show through; otherwise paint the theme background.
            target.BackgroundColor = active ? Colors.Transparent : (dark ? Color.FromRgb(0x0B, 0x0D, 0x14) : Color.FromRgb(0xF3, 0xF4, 0xF9));
        }

        return active;
    }
}
