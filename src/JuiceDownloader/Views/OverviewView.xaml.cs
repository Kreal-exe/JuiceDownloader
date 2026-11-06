using System.ComponentModel;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using JuiceDownloader.Controls;
using JuiceDownloader.ViewModels;

namespace JuiceDownloader.Views;

/// <summary>
/// The ring is one arc. While the catalog loads a short dash opens into the 110° spinner as it speeds up; when it has
/// come the spinner runs one last lap, braking to twelve o'clock while its length eases to the real share, and settles
/// exactly in place at its final size. Speed and length never jump.
/// </summary>
public partial class OverviewView : UserControl
{
    private const double SpinSweep = 110;
    private const double SpinDash = 4;
    private const double SpinSeconds = 1.1;
    private const double SpinSpeed = 360 / SpinSeconds; // degrees per second
    private const int SpinUpMs = 600;

    private MainViewModel? _vm;
    private bool _spinning;
    private bool _braking;
    private int _token;
    private DateTime _brakeEnd;

    public OverviewView()
    {
        InitializeComponent();
        DataContextChanged += (_, e) =>
        {
            if (_vm is not null) _vm.PropertyChanged -= OnVmPropertyChanged;
            _vm = e.NewValue as MainViewModel;
            if (_vm is null) return;
            _vm.PropertyChanged += OnVmPropertyChanged;
            ValueArc.EndAngle = _vm.RingAngle;
            if (_vm.IsLoading) SetSpinning(true);
        };
    }

    private void OnVmPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_vm is null) return;
        if (e.PropertyName == nameof(MainViewModel.IsLoading)) SetSpinning(_vm.IsLoading);
        else if (e.PropertyName == nameof(MainViewModel.RingAngle) && !_spinning)
        {
            if (!_braking)
            {
                ShowResult();
                return;
            }
            // The result arrived during the last lap: keep easing towards it and still land with the brake.
            var remaining = Math.Max(0, (int)(_brakeEnd - DateTime.UtcNow).TotalMilliseconds);
            ValueArc.BeginAnimation(Arc.EndAngleProperty, Motion.Double(null, _vm.RingAngle, remaining, Motion.EaseOut));
        }
    }

    private void ShowResult()
        => ValueArc.BeginAnimation(Arc.EndAngleProperty, Motion.Double(null, _vm?.RingAngle ?? 0, 1100, Motion.EaseOutStrong));

    private void SetSpinning(bool spinning)
    {
        if (_spinning == spinning) return;
        _spinning = spinning;
        var token = ++_token;
        var angle = RingRotate.Angle;

        if (spinning)
        {
            _braking = false;
            if (!Motion.Enabled)
            {
                ValueArc.BeginAnimation(Arc.EndAngleProperty, null);
                ValueArc.EndAngle = SpinSweep;
                return;
            }

            // Down to a short dash, then open into the spinner while it speeds up.
            var open = new DoubleAnimationUsingKeyFrames();
            open.KeyFrames.Add(new EasingDoubleKeyFrame(SpinDash, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(200)), Motion.EaseInOut));
            open.KeyFrames.Add(new EasingDoubleKeyFrame(SpinSweep, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(200 + SpinUpMs)), Motion.EaseInOut));
            ValueArc.BeginAnimation(Arc.EndAngleProperty, open);

            // A quadratic ease-in reaches full speed after covering half of what full speed would.
            var spinUp = SpinSpeed * SpinUpMs / 1000.0 / 2;
            var up = new DoubleAnimation(angle, angle + spinUp, TimeSpan.FromMilliseconds(SpinUpMs))
            {
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn },
            };
            up.Completed += (_, _) =>
            {
                if (token != _token) return;
                var from = angle + spinUp;
                RingRotate.BeginAnimation(RotateTransform.AngleProperty,
                    new DoubleAnimation(from, from + 360, TimeSpan.FromSeconds(SpinSeconds)) { RepeatBehavior = RepeatBehavior.Forever });
            };
            RingRotate.BeginAnimation(RotateTransform.AngleProperty, up);
            return;
        }

        // The last lap: brake to the next twelve o'clock at least half a turn ahead (a quadratic ease-out starts at
        // twice its average speed, so the duration follows from the distance and the speed stays continuous) while
        // the length eases from the spinner's to the real share.
        var target = Math.Ceiling((angle + 180) / 360) * 360;
        var brakeMs = Motion.Enabled ? (int)Math.Round((target - angle) / SpinSpeed * 2 * 1000) : 0;
        _braking = true;
        _brakeEnd = DateTime.UtcNow.AddMilliseconds(brakeMs);
        ValueArc.BeginAnimation(Arc.EndAngleProperty, Motion.Double(null, _vm?.RingAngle ?? 0, brakeMs, Motion.EaseInOut));
        var brake = Motion.Double(angle, target, brakeMs, new QuadraticEase { EasingMode = EasingMode.EaseOut });
        brake.Completed += (_, _) =>
        {
            if (token != _token) return;
            _braking = false;
            RingRotate.BeginAnimation(RotateTransform.AngleProperty, null);
            RingRotate.Angle = 0;
            ShowResult();
        };
        RingRotate.BeginAnimation(RotateTransform.AngleProperty, brake);
    }
}
