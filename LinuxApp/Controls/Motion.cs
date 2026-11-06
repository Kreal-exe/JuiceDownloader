namespace JuiceDownloader.Controls;

/// <summary>The "Animations" setting: counters, bars and entrances jump straight to their value when it is off.</summary>
public static class Motion
{
    public static bool Enabled { get; set; } = true;

    /// <summary>A strong ease-out (cubic) for counters and bars.</summary>
    public static double EaseOut(double t) => 1 - Math.Pow(1 - Math.Clamp(t, 0, 1), 3);
}
