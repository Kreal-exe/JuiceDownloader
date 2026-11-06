# Captures the main window of a process to a PNG using PrintWindow (DWM-composited, DPI independent).
param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$SendKeys = "",
    [string]$Click = "",          # "x,y" in physical pixels relative to the visible window frame
    [double]$WaitAfterKeys = 1.2,
    [int]$Wheel = 0,              # mouse-wheel notches at the window centre (negative = scroll down)
    [switch]$Screen               # copy pixels from the screen instead of PrintWindow
)

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32 {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, IntPtr extra);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT rect, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    // Process.MainWindowHandle may return an invisible helper window (popup/tooltip host); pick the visible top-level one.
    public static IntPtr FindMainWindow(uint pid) {
        IntPtr best = IntPtr.Zero; int bestArea = 0;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid || !IsWindowVisible(h)) return true;
            RECT r; GetWindowRect(h, out r);
            int area = (r.Right - r.Left) * (r.Bottom - r.Top);
            if (area > bestArea) { bestArea = area; best = h; }
            return true;
        }, IntPtr.Zero);
        return best;
    }
}
"@

[Win32]::SetProcessDPIAware() | Out-Null
$hwnd = [Win32]::FindMainWindow([uint32]$ProcessId)
if ($hwnd -eq 0) { throw "No visible window for process $ProcessId" }

[Win32]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 300

if ($Click -ne "") {
    $frame0 = New-Object Win32+RECT
    [Win32]::DwmGetWindowAttribute($hwnd, 9, [ref]$frame0, 16) | Out-Null
    $parts = $Click.Split(',')
    $cx = $frame0.Left + [int]$parts[0]; $cy = $frame0.Top + [int]$parts[1]
    [Win32]::SetCursorPos($cx, $cy) | Out-Null
    Start-Sleep -Milliseconds 150
    [Win32]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)   # left down
    [Win32]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)   # left up
    Start-Sleep -Seconds $WaitAfterKeys
}

if ($SendKeys -ne "") {
    $shell = New-Object -ComObject WScript.Shell
    $shell.SendKeys($SendKeys)
    Start-Sleep -Seconds $WaitAfterKeys
}

if ($Wheel -ne 0) {
    $frame1 = New-Object Win32+RECT
    [Win32]::DwmGetWindowAttribute($hwnd, 9, [ref]$frame1, 16) | Out-Null
    [Win32]::SetCursorPos([int](($frame1.Left + $frame1.Right) / 2), [int](($frame1.Top + $frame1.Bottom) / 2)) | Out-Null
    Start-Sleep -Milliseconds 100
    $notches = [Math]::Abs($Wheel); $dir = [Math]::Sign($Wheel)
    $delta = if ($dir -gt 0) { [uint32]120 } else { [uint32](4294967296 - 120) }   # WHEEL_DELTA as unsigned DWORD
    for ($i = 0; $i -lt $notches; $i++) { [Win32]::mouse_event(0x0800, 0, 0, $delta, [IntPtr]::Zero); Start-Sleep -Milliseconds 40 }
    Start-Sleep -Seconds $WaitAfterKeys
}

$rect = New-Object Win32+RECT
[Win32]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
# park the cursor outside the window so no hover state leaks into the shot
[Win32]::SetCursorPos($rect.Right + 40, $rect.Bottom + 40) | Out-Null
Start-Sleep -Milliseconds 500

$w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
if ($Screen) {
    $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
} else {
    $hdc = $g.GetHdc()
    [Win32]::PrintWindow($hwnd, $hdc, 2) | Out-Null   # PW_RENDERFULLCONTENT
    $g.ReleaseHdc($hdc)
}
$g.Dispose()

# trim the invisible resize border that GetWindowRect includes
$frame = New-Object Win32+RECT
[Win32]::DwmGetWindowAttribute($hwnd, 9, [ref]$frame, 16) | Out-Null
$cropX = $frame.Left - $rect.Left; $cropY = $frame.Top - $rect.Top
$cropW = $frame.Right - $frame.Left; $cropH = $frame.Bottom - $frame.Top
if ($cropW -gt 0 -and $cropH -gt 0 -and ($cropX -gt 0 -or $cropY -gt 0 -or $cropW -lt $w -or $cropH -lt $h)) {
    $cropped = $bmp.Clone((New-Object System.Drawing.Rectangle $cropX, $cropY, $cropW, $cropH), $bmp.PixelFormat)
    $bmp.Dispose(); $bmp = $cropped
}

New-Item -ItemType Directory -Force (Split-Path -Parent $Out) | Out-Null
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host "Saved $Out ($($bmp.Width) x $($bmp.Height))"
$bmp.Dispose()
