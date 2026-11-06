using System.Windows;
using System.Windows.Media.Animation;

namespace JuiceDownloader.Controls;

/// <summary>Global motion switch and shared easing/duration helpers for code-driven animations.</summary>
public static class Motion
{
    public static bool Enabled { get; set; } = true;

    public static Duration Ms(int milliseconds)
        => new(TimeSpan.FromMilliseconds(Enabled ? milliseconds : 0));

    public static TimeSpan Delay(int milliseconds)
        => TimeSpan.FromMilliseconds(Enabled ? milliseconds : 0);

    public static IEasingFunction EaseOut { get; } = new QuarticEase { EasingMode = EasingMode.EaseOut };
    public static IEasingFunction EaseOutStrong { get; } = new QuinticEase { EasingMode = EasingMode.EaseOut };
    public static IEasingFunction EaseInOut { get; } = new CubicEase { EasingMode = EasingMode.EaseInOut };
    public static IEasingFunction EaseIn { get; } = new CubicEase { EasingMode = EasingMode.EaseIn };
    public static IEasingFunction Spring { get; } = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.35 };

    public static DoubleAnimation Double(double? from, double to, int ms, IEasingFunction? easing = null, int delayMs = 0)
    {
        var a = new DoubleAnimation
        {
            To = to,
            Duration = Ms(ms),
            EasingFunction = easing ?? EaseOut,
            BeginTime = Delay(delayMs),
        };
        if (from.HasValue) a.From = from;
        return a;
    }
}
