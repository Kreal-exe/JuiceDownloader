using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using JuiceDownloader.Controls;
using JuiceDownloader.Core;
using JuiceDownloader.ViewModels;
using Microsoft.Win32;

namespace JuiceDownloader.Views;

public partial class MainWindow : Window, IDialogService
{
    private readonly OverviewView _overview = new();
    private readonly LyricsView _lyrics = new();
    private readonly GapsView _gaps = new();
    private readonly RulesView _rules = new();
    private readonly SettingsView _settings = new();
    private readonly AboutView _about = new();
    private readonly Dictionary<AppPage, SectionView> _sections = [];
    private readonly Dictionary<AppPage, RadioButton> _nav;

    private MainViewModel? _vm;
    private bool _navigating;
    private AppPage _lastPage = AppPage.Overview;

    public MainWindow()
    {
        InitializeComponent();
        _nav = new Dictionary<AppPage, RadioButton>
        {
            [AppPage.Overview] = NavOverview,
            [AppPage.Albums] = NavAlbums,
            [AppPage.Unreleased] = NavUnreleased,
            [AppPage.Compilations] = NavCompilations,
            [AppPage.SessionEdits] = NavSessionEdits,
            [AppPage.Originals] = NavOriginals,
            [AppPage.Studio] = NavStudio,
            [AppPage.Instrumentals] = NavInstrumentals,
            [AppPage.Remixes] = NavRemixes,
            [AppPage.Snippets] = NavSnippets,
            [AppPage.Media] = NavMedia,
            [AppPage.Rules] = NavRules,
            [AppPage.Lyrics] = NavLyrics,
            [AppPage.Gaps] = NavGaps,
            [AppPage.Settings] = NavSettings,
            [AppPage.About] = NavAbout,
        };
        DataContextChanged += OnDataContextChanged;
        SourceInitialized += (_, _) =>
        {
            WindowBackdrop.HideSystemCaptionButtons(this);
            ApplyBackdrop();
        };
        StateChanged += (_, _) => UpdateMaximizedLayout();
        Loaded += OnLoaded;
        PreviewKeyDown += OnPreviewKeyDown;
        Closing += OnClosing;
        ThemeManager.Changed += ApplyBackdrop;
    }

    private void OnDataContextChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (_vm is not null)
        {
            _vm.PropertyChanged -= OnVmPropertyChanged;
            _vm.Download.PropertyChanged -= OnDownloadPropertyChanged;
            _vm.Download.Celebrate -= Overlay.Celebrate;
            _vm.Settings.ThemeChanged -= OnThemeChanged;
            _vm.Settings.BackdropChanged -= ApplyBackdrop;
        }

        _vm = e.NewValue as MainViewModel;
        if (_vm is null) return;

        _vm.PropertyChanged += OnVmPropertyChanged;
        _vm.Download.PropertyChanged += OnDownloadPropertyChanged;
        _vm.Download.Celebrate += Overlay.Celebrate;
        Overlay.DataContext = _vm.Download;
        _lyrics.DataContext = _vm.Lyrics;
        _gaps.DataContext = _vm.Gaps;
        _rules.DataContext = _vm.Rules;
        _vm.Settings.ThemeChanged += OnThemeChanged;
        _vm.Settings.BackdropChanged += ApplyBackdrop;
        _vm.ToastRequested += ShowToast;

        RestoreWindowSize();
        ShowPage(_vm.CurrentPage);
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        StartAmbientAnimation();
        UpdateMaximizedLayout();
        MoveNavIndicator(animate: false);

        if (Motion.Enabled)
        {
            Root.Opacity = 0;
            RootScale.ScaleX = RootScale.ScaleY = 0.985;
            Root.BeginAnimation(OpacityProperty, Motion.Double(0, 1, 380));
            RootScale.BeginAnimation(ScaleTransform.ScaleXProperty, Motion.Double(0.985, 1, 650, Motion.EaseOutStrong));
            RootScale.BeginAnimation(ScaleTransform.ScaleYProperty, Motion.Double(0.985, 1, 650, Motion.EaseOutStrong));
        }
    }

    private void MoveNavIndicator(bool animate)
    {
        var radio = _nav[_vm?.CurrentPage ?? AppPage.Overview];

        if (!radio.IsLoaded) return;
        var y = radio.TranslatePoint(new Point(0, 0), NavGrid).Y;

        if (!animate || !Motion.Enabled)
        {
            NavIndicatorT.BeginAnimation(TranslateTransform.YProperty, null);
            NavIndicatorT.Y = y;
            return;
        }

        NavIndicatorT.BeginAnimation(TranslateTransform.YProperty, Motion.Double(null, y, 420, Motion.Spring));
    }

    private System.Windows.Threading.DispatcherTimer? _toastTimer;

    private void ShowToast(string glyph, string text)
    {
        ToastGlyph.Text = glyph;
        ToastText.Text = text;
        Toast.Visibility = Visibility.Visible;

        if (Motion.Enabled)
        {
            Toast.BeginAnimation(OpacityProperty, Motion.Double(0, 1, 220));
            ToastT.BeginAnimation(TranslateTransform.YProperty, Motion.Double(-16, 0, 480, Motion.Spring));
        }
        else
        {
            Toast.Opacity = 1;
        }

        _toastTimer?.Stop();
        _toastTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(3.2) };
        _toastTimer.Tick += (_, _) =>
        {
            _toastTimer!.Stop();
            var fade = Motion.Double(null, 0, 240, Motion.EaseIn);
            fade.Completed += (_, _) => Toast.Visibility = Visibility.Collapsed;
            Toast.BeginAnimation(OpacityProperty, fade);
            ToastT.BeginAnimation(TranslateTransform.YProperty, Motion.Double(null, -10, 240, Motion.EaseIn));
        };
        _toastTimer.Start();
    }

    private void OnVmPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_vm is not null && e.PropertyName == nameof(MainViewModel.CurrentPage)) ShowPage(_vm.CurrentPage);
    }

    private void OnDownloadPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_vm is null || e.PropertyName != nameof(DownloadViewModel.IsOverlayVisible)) return;
        if (_vm.Download.IsOverlayVisible) Overlay.Show();
        else Overlay.Hide();
    }

    // ───────────── navigation ─────────────

    private UIElement ViewFor(AppPage page)
    {
        switch (page)
        {
            case AppPage.Overview: return _overview;
            case AppPage.Lyrics: return _lyrics;
            case AppPage.Gaps: return _gaps;
            case AppPage.Rules: return _rules;
            case AppPage.Settings: return _settings;
            case AppPage.About: return _about;
        }

        // One view per section, made when first shown: each keeps its own place in its list.
        if (!_sections.TryGetValue(page, out var view))
        {
            view = new SectionView { DataContext = _vm?.Sections.First(s => s.Page == page) };
            _sections[page] = view;
        }
        return view;
    }

    private void ShowPage(AppPage page)
    {
        _navigating = true;
        _nav[page].IsChecked = true;
        _navigating = false;

        var forward = (int)page >= (int)_lastPage;
        _lastPage = page;
        Pages.Navigate(ViewFor(page), forward);
        MoveNavIndicator(animate: true);
    }

    private void OnNavChecked(object sender, RoutedEventArgs e)
    {
        if (_navigating || _vm is null) return;
        foreach (var (page, radio) in _nav)
        {
            if (!ReferenceEquals(sender, radio)) continue;
            _vm.CurrentPage = page;
            return;
        }
    }

    // ───────────── chrome ─────────────

    private void OnMinimize(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;

    private void OnMaximize(object sender, RoutedEventArgs e)
        => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    private void OnClose(object sender, RoutedEventArgs e) => Close();

    private void UpdateMaximizedLayout()
    {
        // With a custom chrome a maximized window overshoots the screen by the resize border.
        Root.Margin = WindowState == WindowState.Maximized ? new Thickness(7) : new Thickness(0);
        MaxButton.Content = WindowState == WindowState.Maximized ? "" : "";
    }

    private void OnThemeChanged()
    {
        ThemeManager.Apply(App.Settings.Theme);
        ApplyBackdrop();
        MoveNavIndicator(animate: false);
    }

    private void ApplyBackdrop()
    {
        var mica = WindowBackdrop.Apply(this, ThemeManager.IsDark, App.Settings.Backdrop);
        Root.Background = (Brush)FindResource(mica ? "Brush.BgTranslucent" : "Brush.Bg");
    }

    private void StartAmbientAnimation()
    {
        if (!Motion.Enabled) return;
        Drift(Blob1T, 70, 40, 26);
        Drift(Blob2T, -60, 50, 31);
        Drift(Blob3T, 40, -60, 37);
    }

    private static void Drift(System.Windows.Media.TranslateTransform t, double dx, double dy, int seconds)
    {
        var x = new DoubleAnimation(0, dx, TimeSpan.FromSeconds(seconds)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } };
        var y = new DoubleAnimation(0, dy, TimeSpan.FromSeconds(seconds * 1.3)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } };
        t.BeginAnimation(System.Windows.Media.TranslateTransform.XProperty, x);
        t.BeginAnimation(System.Windows.Media.TranslateTransform.YProperty, y);
    }

    // ───────────── window size persistence ─────────────

    private void RestoreWindowSize()
    {
        var s = App.Settings;
        if (s.WindowWidth >= MinWidth && s.WindowHeight >= MinHeight)
        {
            Width = s.WindowWidth;
            Height = s.WindowHeight;
        }

        // Never exceed the work area (a 1240×800 default is taller than a 1080p screen at 150 % scaling)
        // and centre inside it, so the custom title bar can never start off-screen.
        var area = SystemParameters.WorkArea;
        Width = Math.Max(MinWidth, Math.Min(Width, area.Width - 16));
        Height = Math.Max(Math.Min(MinHeight, area.Height - 16), Math.Min(Height, area.Height - 16));
        Left = area.Left + Math.Max(0, (area.Width - Width) / 2);
        Top = area.Top + Math.Max(0, (area.Height - Height) / 2);

        if (s.WindowMaximized) WindowState = WindowState.Maximized;
    }

    /// <summary>
    /// Space works like Quick Look: it opens the preview of the row under the pointer, or else of the row last clicked,
    /// and closes it again. With no preview to open it plays and pauses, unless it is being typed.
    /// </summary>
    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (_vm is null || Confirm.Visibility == Visibility.Visible) return;

        if (_vm.Preview.IsVisible)
        {
            if (e.Key == Key.Left) _vm.Preview.PreviousCommand.Execute(null);
            else if (e.Key == Key.Right) _vm.Preview.NextCommand.Execute(null);
            else if (e.Key == Key.Space) _vm.Preview.CloseCommand.Execute(null);
            else return;
            e.Handled = true;
            return;
        }

        if (e.Key != Key.Space || Keyboard.FocusedElement is TextBoxBase or ComboBox) return;
        if (_vm.LyricsSheet.IsVisible || _vm.Download.IsOverlayVisible) return;

        var hovered = (Mouse.DirectlyOver as FrameworkElement)?.DataContext as IRowNode;
        var row = hovered?.Node ?? _vm.LastClicked;
        if (row is not null && !row.IsDirectory && Library.PreviewOf(row.Name) != PreviewKind.None)
        {
            _ = _vm.Preview.OpenAsync(row);
            e.Handled = true;
        }
        else if (_vm.Player.IsVisible)
        {
            _vm.Player.ToggleCommand.Execute(null);
            e.Handled = true;
        }
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        _vm?.Player.Shutdown();
        _vm?.Preview.Shutdown();
        var s = App.Settings;
        s.WindowMaximized = WindowState == WindowState.Maximized;
        if (WindowState == WindowState.Normal)
        {
            s.WindowWidth = Width;
            s.WindowHeight = Height;
        }
        Settings.SettingsStore.Save(s);
    }

    // ───────────── IDialogService ─────────────

    public Task<bool> ConfirmAsync(string title, string body, string okText, bool danger)
        => Confirm.ShowAsync(title, body, okText, danger);

    public string? PickFolder(string? startIn)
    {
        var dialog = new OpenFolderDialog { Multiselect = false, Title = Localization.LocalizationManager.Instance["download.pickFolder"] };
        if (startIn is { Length: > 0 } && System.IO.Directory.Exists(startIn)) dialog.InitialDirectory = startIn;
        return dialog.ShowDialog(this) == true ? dialog.FolderName : null;
    }
}
