using System.Collections.ObjectModel;
using JuiceDownloader.Localization;
using JuiceDownloader.Settings;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace JuiceDownloader.ViewModels;

public sealed record LanguageOption(string Code, string Label)
{
    public override string ToString() => Label;
}

public sealed partial class SettingsViewModel : ObservableObject
{
    private static LocalizationManager Loc => LocalizationManager.Instance;

    private readonly AppSettings _settings;
    private readonly Action _save;

    public event Action? ThemeChanged;
    public event Action? ResetRequested;

    public SettingsViewModel(AppSettings settings, Action save)
    {
        _settings = settings;
        _save = save;

        _animations = settings.Animations;
        _theme = settings.Theme;
        _destination = settings.Destination;
        _parallel = settings.Parallel;
        _confirmDownloads = settings.ConfirmDownloads;
        _refreshOnLaunch = settings.RefreshOnLaunch;

        RebuildLanguages();
        _selectedLanguage = Languages.FirstOrDefault(l => l.Code == settings.Language) ?? Languages[0];

        Loc.LanguageChanged += (_, _) =>
        {
            var code = SelectedLanguage?.Code ?? "auto";
            RebuildLanguages();
            _selectedLanguage = Languages.FirstOrDefault(l => l.Code == code) ?? Languages[0];
            OnPropertyChanged(nameof(SelectedLanguage));
        };
    }

    public ObservableCollection<LanguageOption> Languages { get; } = [];
    public IReadOnlyList<int> ParallelChoices => AppSettings.ParallelChoices;

    [ObservableProperty] private LanguageOption? _selectedLanguage;
    [ObservableProperty] private string _theme;
    [ObservableProperty] private bool _animations;
    [ObservableProperty] private string _destination;
    [ObservableProperty] private int _parallel;
    [ObservableProperty] private bool _confirmDownloads;
    [ObservableProperty] private bool _refreshOnLaunch;

    partial void OnSelectedLanguageChanged(LanguageOption? value)
    {
        if (value is null) return;
        _settings.Language = value.Code;
        _save();
        Loc.Apply(value.Code);
    }

    partial void OnThemeChanged(string value)
    {
        _settings.Theme = value;
        _save();
        ThemeChanged?.Invoke();
    }

    partial void OnAnimationsChanged(bool value)
    {
        _settings.Animations = value;
        Controls.Motion.Enabled = value;
        _save();
    }

    partial void OnDestinationChanged(string value)
    {
        _settings.Destination = value;
        _save();
    }

    partial void OnParallelChanged(int value)
    {
        _settings.Parallel = value;
        _save();
    }

    partial void OnConfirmDownloadsChanged(bool value)
    {
        _settings.ConfirmDownloads = value;
        _save();
    }

    partial void OnRefreshOnLaunchChanged(bool value)
    {
        _settings.RefreshOnLaunch = value;
        _save();
    }

    [RelayCommand]
    private void SetTheme(string theme) => Theme = theme;

    [RelayCommand]
    private void Reset()
    {
        Theme = "dark";
        Animations = true;
        Destination = AppSettings.DefaultDestination;
        Parallel = AppSettings.DefaultParallel;
        ConfirmDownloads = true;
        RefreshOnLaunch = true;
        SelectedLanguage = Languages[0];
        ResetRequested?.Invoke();
    }

    private void RebuildLanguages()
    {
        Languages.Clear();
        var detected = LocalizationManager.Languages.First(l => l.Code == LocalizationManager.DetectSystemLanguage());
        Languages.Add(new LanguageOption("auto", Loc.Format("settings.language.auto", detected.NativeName)));
        foreach (var l in LocalizationManager.Languages)
            Languages.Add(new LanguageOption(l.Code, l.NativeName));
    }
}
