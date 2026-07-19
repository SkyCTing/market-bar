using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using GoldPriceBar.Core;
using DrawingPoint = System.Drawing.Point;

namespace GoldPriceBar.Windows;

internal sealed class FloatingCharacterWindow : Window, IDisposable
{
    private enum MotionState
    {
        Hidden,
        Paused,
        Ambient,
        Action,
        Sleeping,
    }

    private sealed record DragSample(Point Point, double Timestamp);

    private static readonly TimeSpan ActionDuration = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan SpeechDuration = TimeSpan.FromSeconds(3.5);
    private static readonly TimeSpan IdleThreshold = TimeSpan.FromMinutes(5);
    private static readonly Rect DockedRightSignRect = new(0.32, 0.54, 0.53, 0.34);

    private readonly CharacterImageCache imageCache = new();
    private readonly SpeechBubbleWindow speechBubble = new();
    private readonly ClickSequence clickSequence = new();
    private readonly Image characterImage = new() { Stretch = Stretch.Fill };
    private readonly TextBlock priceLabel = new()
    {
        FontFamily = new FontFamily("Cascadia Mono, Consolas"),
        FontWeight = FontWeights.Bold,
        TextAlignment = TextAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly Canvas priceCanvas = new();
    private readonly Grid rootGrid = new();
    private readonly Grid ambientGrid = new();
    private readonly Grid actionGrid = new();
    private readonly ScaleTransform ambientScale = new(1, 1);
    private readonly RotateTransform ambientRotate = new(0);
    private readonly TranslateTransform ambientTranslate = new(0, 0);
    private readonly ScaleTransform actionScale = new(1, 1);
    private readonly RotateTransform actionRotate = new(0);
    private readonly TranslateTransform actionTranslate = new(0, 0);
    private readonly ScaleTransform landingScale = new(1, 1);
    private readonly RotateTransform landingRotate = new(0);
    private readonly TranslateTransform landingTranslate = new(0, 0);
    private readonly DispatcherTimer ambientActionTimer = new();
    private readonly DispatcherTimer actionTimer = new();
    private readonly DispatcherTimer speechTimer = new();
    private readonly DispatcherTimer activityTimer = new();
    private readonly DispatcherTimer blinkTimer = new();
    private readonly DispatcherTimer pendingClickTimer = new();
    private readonly DispatcherTimer settleTimer = new();
    private readonly List<DragSample> dragSamples = [];

    private CharacterSize size;
    private CharacterEmotion emotion = CharacterEmotion.Happy;
    private CharacterPose pose = CharacterPose.Happy;
    private MotionState motionState = MotionState.Hidden;
    private DockEdge dockEdge;
    private bool docked;
    private bool characterVisible;
    private bool sessionActive = true;
    private bool screenAwake = true;
    private bool powerSaving;
    private bool dragging;
    private bool dragStarted;
    private bool allowClose;
    private int remainingBlinks;
    private bool blinkClosed;
    private Point dragStartPoint;
    private double dragStartLeft;
    private double dragStartTop;
    private double maximumDragDistance;
    private string price = "0.00";
    private bool? isNegative;

    internal FloatingCharacterWindow(AppSettings settings)
    {
        size = settings.FloatingCharacterSize;
        docked = settings.CharacterDocked;
        dockEdge = settings.CharacterDockEdge;
        Width = docked ? size.DockedSize().Width : size.FullSize().Width;
        Height = docked ? size.DockedSize().Height : size.FullSize().Height;
        Left = settings.CharacterLeft ?? SystemParameters.WorkArea.Right - Width - 20;
        Top = settings.CharacterTop ?? SystemParameters.WorkArea.Bottom - Height - 20;

        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;

        rootGrid.RenderTransformOrigin = new Point(0.5, 0.5);
        ambientGrid.RenderTransformOrigin = new Point(0.5, 0.5);
        actionGrid.RenderTransformOrigin = new Point(0.5, 0.5);
        rootGrid.RenderTransform = TransformGroup(landingScale, landingRotate, landingTranslate);
        ambientGrid.RenderTransform = TransformGroup(ambientScale, ambientRotate, ambientTranslate);
        actionGrid.RenderTransform = TransformGroup(actionScale, actionRotate, actionTranslate);
        actionGrid.Children.Add(characterImage);
        priceCanvas.Children.Add(priceLabel);
        actionGrid.Children.Add(priceCanvas);
        ambientGrid.Children.Add(actionGrid);
        rootGrid.Children.Add(ambientGrid);
        Content = rootGrid;

        SizeChanged += (_, _) => LayoutPrice();
        MouseLeftButtonDown += HandleMouseDown;
        MouseMove += HandleMouseMove;
        MouseLeftButtonUp += HandleMouseUp;
        Closing += (_, e) => { if (!allowClose) e.Cancel = true; };

        ambientActionTimer.Tick += (_, _) =>
        {
            ambientActionTimer.Stop();
            if (motionState == MotionState.Ambient && !docked)
            {
                PlayAction(RandomAction(emotion), ActionDuration);
            }
        };
        actionTimer.Tick += (_, _) =>
        {
            actionTimer.Stop();
            FinishAction();
        };
        speechTimer.Tick += (_, _) =>
        {
            speechTimer.Stop();
            if (motionState == MotionState.Ambient)
            {
                ShowSpeech(SpeechKind.Ambient);
                ScheduleSpeech();
            }
        };
        activityTimer.Tick += (_, _) => EvaluateMotion();
        blinkTimer.Tick += (_, _) => AdvanceBlink();
        pendingClickTimer.Tick += (_, _) =>
        {
            pendingClickTimer.Stop();
            PerformClick(ClickReaction.PendingSingle);
        };
        settleTimer.Tick += (_, _) =>
        {
            settleTimer.Stop();
            PersistPlacement();
            EvaluateMotion();
        };

        UpdateImage();
    }

    internal event Action<CharacterPlacement>? PlacementChanged;

    internal void SetCharacterVisible(bool visible)
    {
        characterVisible = visible;
        if (visible)
        {
            if (!IsVisible) Show();
            ClampToCurrentScreen();
            UpdateImage();
            StartActivityTimer(TimeSpan.FromSeconds(30));
            EvaluateMotion();
        }
        else
        {
            StopAllTimers();
            StopAllAnimations();
            speechBubble.HideBubble();
            imageCache.Clear();
            motionState = MotionState.Hidden;
            Hide();
        }
    }

    internal void SetSize(CharacterSize newSize)
    {
        if (size == newSize) return;
        var centerX = Left + Width / 2;
        var centerY = Top + Height / 2;
        size = newSize;
        var target = docked ? size.DockedSize() : size.FullSize();
        Width = target.Width;
        Height = target.Height;
        Left = centerX - Width / 2;
        Top = centerY - Height / 2;
        ClampToCurrentScreen();
        LayoutPrice();
        PersistPlacement();
    }

    internal void UpdateQuote(string formattedPrice, bool? negative)
    {
        price = formattedPrice;
        isNegative = negative;
        priceLabel.Text = price;
        priceLabel.Foreground = UiStyles.TrendBrush(negative);
        var nextEmotion = negative == true ? CharacterEmotion.Sad : CharacterEmotion.Happy;
        if (nextEmotion != emotion)
        {
            emotion = nextEmotion;
            if (motionState != MotionState.Sleeping)
            {
                StopAction();
                SetPose(CharacterPoseInfo.Base(emotion));
                EvaluateMotion();
            }
        }
        else if (motionState is not (MotionState.Action or MotionState.Sleeping))
        {
            SetPose(CharacterPoseInfo.Base(emotion));
        }
        LayoutPrice();
    }

    internal void ReactToMarket(MarketReaction reaction)
    {
        if (!characterVisible || !sessionActive || !screenAwake) return;
        pendingClickTimer.Stop();
        clickSequence.ResetBurst();
        if (motionState == MotionState.Sleeping) Wake(false);
        var speech = reaction.Kind == MarketReactionKind.RapidRise ? SpeechKind.RapidRise : SpeechKind.RapidFall;
        if (docked)
        {
            StartBlinkSequence(3);
        }
        else
        {
            var targetPose = reaction.Kind == MarketReactionKind.RapidRise
                ? Pick([CharacterPose.HappyCheer, CharacterPose.HappyDance, CharacterPose.HappyThumbsUp])
                : Pick([CharacterPose.SadFacepalm, CharacterPose.SadHide, CharacterPose.SadShiver]);
            PlayAction(targetPose, ActionDuration);
        }
        ShowSpeech(speech, reaction.Delta);
    }

    internal void SetSessionActive(bool active)
    {
        sessionActive = active;
        if (active) EvaluateMotion(); else PauseAll();
    }

    internal void SetScreenAwake(bool awake)
    {
        screenAwake = awake;
        if (awake) EvaluateMotion(); else PauseAll();
    }

    internal void SetPowerSaving(bool enabled)
    {
        powerSaving = enabled;
        EvaluateMotion();
    }

    private void EvaluateMotion()
    {
        if (!characterVisible)
        {
            motionState = MotionState.Hidden;
            return;
        }
        if (!sessionActive || !screenAwake)
        {
            PauseAll();
            return;
        }
        if (NativeMethods.IdleDuration >= IdleThreshold)
        {
            EnterSleep();
            return;
        }
        if (motionState == MotionState.Sleeping)
        {
            Wake(true);
        }
        if (powerSaving)
        {
            PauseAmbient();
            return;
        }
        if (motionState != MotionState.Action && !dragging)
        {
            BeginAmbient();
        }
    }

    private void BeginAmbient()
    {
        motionState = MotionState.Ambient;
        StartActivityTimer(TimeSpan.FromSeconds(30));
        if (docked)
        {
            StopAmbientAnimations();
            ScheduleBlink();
        }
        else
        {
            StartAmbientAnimations();
            ScheduleAmbientAction();
        }
        ScheduleSpeech();
    }

    private void EnterSleep()
    {
        if (motionState == MotionState.Sleeping) return;
        StopAction();
        StopAmbientAnimations();
        SetPose(docked ? CharacterPoseInfo.Base(emotion) : CharacterPose.HappySleepy);
        motionState = MotionState.Sleeping;
        ShowSpeech(SpeechKind.Sleeping, persistent: true);
        StartActivityTimer(TimeSpan.FromSeconds(5));
    }

    private void Wake(bool showSpeech)
    {
        if (motionState != MotionState.Sleeping) return;
        speechBubble.HideBubble();
        SetPose(CharacterPoseInfo.Base(emotion));
        motionState = MotionState.Paused;
        StartActivityTimer(TimeSpan.FromSeconds(30));
        if (showSpeech) ShowSpeech(SpeechKind.Wake);
    }

    private void PauseAll()
    {
        pendingClickTimer.Stop();
        clickSequence.ResetBurst();
        StopAction();
        PauseAmbient();
        speechBubble.HideBubble();
    }

    private void PauseAmbient()
    {
        ambientActionTimer.Stop();
        speechTimer.Stop();
        blinkTimer.Stop();
        StopAmbientAnimations();
        if (motionState != MotionState.Action) motionState = MotionState.Paused;
        if (motionState != MotionState.Sleeping) SetPose(CharacterPoseInfo.Base(emotion));
    }

    private void ScheduleAmbientAction()
    {
        if (ambientActionTimer.IsEnabled || motionState != MotionState.Ambient) return;
        ambientActionTimer.Interval = TimeSpan.FromSeconds(Random.Shared.NextDouble() * 5 + 10);
        ambientActionTimer.Start();
    }

    private void ScheduleSpeech()
    {
        if (speechTimer.IsEnabled || motionState != MotionState.Ambient || powerSaving) return;
        speechTimer.Interval = TimeSpan.FromSeconds(Random.Shared.NextDouble() * 45 + 45);
        speechTimer.Start();
    }

    private void ScheduleBlink()
    {
        if (blinkTimer.IsEnabled || motionState != MotionState.Ambient || !docked) return;
        remainingBlinks = 1;
        blinkClosed = false;
        blinkTimer.Interval = TimeSpan.FromSeconds(Random.Shared.NextDouble() + 4.5);
        blinkTimer.Start();
    }

    private void StartBlinkSequence(int count)
    {
        if (!docked || count <= 0) return;
        ambientActionTimer.Stop();
        speechTimer.Stop();
        StopAmbientAnimations();
        blinkTimer.Stop();
        remainingBlinks = count;
        blinkClosed = false;
        motionState = MotionState.Action;
        blinkTimer.Interval = TimeSpan.FromMilliseconds(1);
        blinkTimer.Start();
    }

    private void AdvanceBlink()
    {
        blinkTimer.Stop();
        if (!docked || remainingBlinks <= 0)
        {
            blinkClosed = false;
            UpdateImage();
            motionState = MotionState.Paused;
            EvaluateMotion();
            return;
        }
        if (!blinkClosed)
        {
            blinkClosed = true;
            UpdateImage();
            blinkTimer.Interval = TimeSpan.FromMilliseconds(120);
            blinkTimer.Start();
        }
        else
        {
            blinkClosed = false;
            remainingBlinks--;
            UpdateImage();
            if (remainingBlinks == 0)
            {
                motionState = MotionState.Paused;
                EvaluateMotion();
            }
            else
            {
                blinkTimer.Interval = TimeSpan.FromMilliseconds(140);
                blinkTimer.Start();
            }
        }
    }

    private void PlayAction(CharacterPose targetPose, TimeSpan duration)
    {
        ambientActionTimer.Stop();
        speechTimer.Stop();
        actionTimer.Stop();
        motionState = MotionState.Action;
        StopAmbientAnimations();
        ResetActionTransforms();
        SetPose(targetPose);
        AnimateAction(targetPose);
        actionTimer.Interval = duration;
        actionTimer.Start();
    }

    private void FinishAction()
    {
        actionTimer.Stop();
        ResetActionTransforms();
        SetPose(CharacterPoseInfo.Base(emotion));
        motionState = MotionState.Paused;
        EvaluateMotion();
    }

    private void StopAction()
    {
        actionTimer.Stop();
        ambientActionTimer.Stop();
        ResetActionTransforms();
        if (motionState == MotionState.Action) motionState = MotionState.Paused;
    }

    private void HandleClick()
    {
        if (!characterVisible || !sessionActive || !screenAwake) return;
        if (motionState == MotionState.Sleeping)
        {
            clickSequence.ResetBurst();
            Wake(true);
            EvaluateMotion();
            return;
        }
        if (powerSaving) return;

        var reaction = clickSequence.Register(
            DateTimeOffset.Now,
            TimeSpan.FromMilliseconds(NativeMethods.GetDoubleClickTime()));
        switch (reaction)
        {
            case ClickReaction.PendingSingle:
                pendingClickTimer.Stop();
                pendingClickTimer.Interval = TimeSpan.FromMilliseconds(NativeMethods.GetDoubleClickTime());
                pendingClickTimer.Start();
                break;
            case ClickReaction.DoubleClick:
            case ClickReaction.Impatient:
            case ClickReaction.Hide:
                pendingClickTimer.Stop();
                PerformClick(reaction);
                break;
            case ClickReaction.IgnoredDuringCooldown:
                pendingClickTimer.Stop();
                if (motionState != MotionState.Action) EvaluateMotion();
                break;
        }
    }

    private void PerformClick(ClickReaction reaction)
    {
        var targetPose = reaction switch
        {
            ClickReaction.PendingSingle => RandomAction(emotion),
            ClickReaction.DoubleClick when emotion == CharacterEmotion.Sad => CharacterPose.SadStomp,
            ClickReaction.DoubleClick => Pick([CharacterPose.HappyDance, CharacterPose.HappyCheer]),
            ClickReaction.Impatient => Pick([CharacterPose.SadPout, CharacterPose.SadFacepalm]),
            ClickReaction.Hide => CharacterPose.SadHide,
            _ => CharacterPoseInfo.Base(emotion),
        };
        var speech = reaction switch
        {
            ClickReaction.PendingSingle => SpeechKind.Click,
            ClickReaction.DoubleClick => SpeechKind.DoubleClick,
            ClickReaction.Impatient => SpeechKind.Impatient,
            ClickReaction.Hide => SpeechKind.Hide,
            _ => SpeechKind.Click,
        };
        if (docked)
        {
            StartBlinkSequence(reaction switch
            {
                ClickReaction.PendingSingle => 2,
                ClickReaction.DoubleClick => 4,
                ClickReaction.Impatient => 5,
                ClickReaction.Hide => 6,
                _ => 2,
            });
            if (reaction is ClickReaction.Impatient or ClickReaction.Hide) PlayDockPeek(true);
        }
        else
        {
            PlayAction(targetPose, reaction == ClickReaction.Hide ? ClickSequence.HideDuration : ActionDuration);
        }
        ShowSpeech(speech);
    }

    private void HandleMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        CancelWindowAnimations();
        settleTimer.Stop();
        dragging = true;
        dragStarted = false;
        maximumDragDistance = 0;
        dragStartPoint = PointToScreen(e.GetPosition(this));
        dragStartLeft = Left;
        dragStartTop = Top;
        dragSamples.Clear();
        RecordDragSample(dragStartPoint);
        CaptureMouse();
        e.Handled = true;
    }

    private void HandleMouseMove(object sender, MouseEventArgs e)
    {
        if (!dragging || e.LeftButton != MouseButtonState.Pressed) return;
        var point = PointToScreen(e.GetPosition(this));
        RecordDragSample(point);
        var dpi = NativeMethods.Dpi(this);
        var deltaX = (point.X - dragStartPoint.X) / dpi.DpiScaleX;
        var deltaY = (point.Y - dragStartPoint.Y) / dpi.DpiScaleY;
        maximumDragDistance = Math.Max(maximumDragDistance, Math.Sqrt(deltaX * deltaX + deltaY * deltaY));
        if (!dragStarted && maximumDragDistance >= 4)
        {
            dragStarted = true;
            pendingClickTimer.Stop();
            clickSequence.ResetBurst();
            StopAction();
            StopAmbientAnimations();
            speechBubble.HideBubble();
            motionState = MotionState.Paused;
        }

        var physical = new DrawingPoint((int)point.X, (int)point.Y);
        var work = NativeMethods.WorkingAreaDip(this, physical);
        if (docked)
        {
            var inward = dockEdge == DockEdge.Left ? deltaX : -deltaX;
            if (inward >= 48)
            {
                RestoreFull(point, work);
                deltaX = 0;
                deltaY = 0;
            }
            else
            {
                Left = dockEdge == DockEdge.Left ? work.Left : work.Right - Width;
                Top = Math.Clamp(dragStartTop + deltaY, work.Top, work.Bottom - Height);
                speechBubble.Reposition(this);
                return;
            }
        }

        Left = Math.Clamp(dragStartLeft + deltaX, work.Left, work.Right - Width);
        Top = Math.Clamp(dragStartTop + deltaY, work.Top, work.Bottom - Height);
        speechBubble.Reposition(this);
    }

    private void HandleMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (!dragging || e.ChangedButton != MouseButton.Left) return;
        var point = PointToScreen(e.GetPosition(this));
        RecordDragSample(point);
        dragging = false;
        ReleaseMouseCapture();
        if (maximumDragDistance < 4)
        {
            HandleClick();
            e.Handled = true;
            return;
        }

        var dpi = NativeMethods.Dpi(this);
        var physical = new DrawingPoint((int)point.X, (int)point.Y);
        var work = NativeMethods.WorkingAreaDip(this, physical);
        var pointerX = point.X / dpi.DpiScaleX;
        if (!docked && Math.Abs(pointerX - work.Left) <= 36)
        {
            EnterDock(DockEdge.Left, work);
        }
        else if (!docked && Math.Abs(pointerX - work.Right) <= 36)
        {
            EnterDock(DockEdge.Right, work);
        }
        else if (docked)
        {
            PlayDockPeek(false);
            SettleAfter(TimeSpan.FromMilliseconds(450));
        }
        else
        {
            ApplyInertia(work, dpi);
        }
        e.Handled = true;
    }

    private void ApplyInertia(Rect work, DpiScale dpi)
    {
        var velocity = DragVelocity(dpi);
        var projected = powerSaving || !SystemParameters.ClientAreaAnimation
            ? (0d, 0d)
            : DragPhysics.Project(velocity.X, velocity.Y);
        var targetLeft = Math.Clamp(Left + projected.Item1, work.Left, work.Right - Width);
        var targetTop = Math.Clamp(Top + projected.Item2, work.Top, work.Bottom - Height);
        if (Math.Abs(projected.Item1) < 0.01 && Math.Abs(projected.Item2) < 0.01)
        {
            if (!powerSaving) PlayLanding(velocity.X);
            SettleAfter(powerSaving ? TimeSpan.Zero : TimeSpan.FromMilliseconds(450));
            return;
        }

        AnimateWindowPosition(targetLeft, targetTop, TimeSpan.FromMilliseconds(450), () =>
        {
            PlayLanding(velocity.X);
            SettleAfter(TimeSpan.FromMilliseconds(450));
        });
    }

    private void EnterDock(DockEdge edge, Rect work)
    {
        StopAction();
        StopAmbientAnimations();
        speechBubble.HideBubble();
        docked = true;
        dockEdge = edge;
        var targetSize = size.DockedSize();
        var targetLeft = edge == DockEdge.Left ? work.Left : work.Right - targetSize.Width;
        var targetTop = Math.Clamp(Top + Height / 2 - targetSize.Height / 2, work.Top, work.Bottom - targetSize.Height);
        motionState = MotionState.Paused;
        UpdateImage();
        if (powerSaving || !SystemParameters.ClientAreaAnimation)
        {
            Width = targetSize.Width;
            Height = targetSize.Height;
            Left = targetLeft;
            Top = targetTop;
            PersistPlacement();
            EvaluateMotion();
            return;
        }
        AnimateDockFrame(targetLeft, targetTop, targetSize.Width, targetSize.Height, () =>
        {
            PlayDockPeek(false);
            SettleAfter(TimeSpan.FromMilliseconds(450));
        });
    }

    private void RestoreFull(Point pointer, Rect work)
    {
        var target = size.FullSize();
        docked = false;
        Width = target.Width;
        Height = target.Height;
        var dpi = NativeMethods.Dpi(this);
        var pointerX = pointer.X / dpi.DpiScaleX;
        var pointerY = pointer.Y / dpi.DpiScaleY;
        Left = Math.Clamp(pointerX - Width * (dockEdge == DockEdge.Left ? 0.2 : 0.8), work.Left, work.Right - Width);
        Top = Math.Clamp(pointerY - Height * 0.5, work.Top, work.Bottom - Height);
        dragStartPoint = pointer;
        dragStartLeft = Left;
        dragStartTop = Top;
        UpdateImage();
    }

    private void AnimateWindowPosition(double targetLeft, double targetTop, TimeSpan duration, Action completed)
    {
        AnimatedLeft = Left;
        AnimatedTop = Top;
        var leftAnimation = new DoubleAnimation(Left, targetLeft, duration) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } };
        var topAnimation = new DoubleAnimation(Top, targetTop, duration) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } };
        topAnimation.Completed += (_, _) =>
        {
            BeginAnimation(AnimatedLeftProperty, null);
            BeginAnimation(AnimatedTopProperty, null);
            Left = targetLeft;
            Top = targetTop;
            completed();
        };
        BeginAnimation(AnimatedLeftProperty, leftAnimation);
        BeginAnimation(AnimatedTopProperty, topAnimation);
    }

    private void AnimateDockFrame(double left, double top, double width, double height, Action completed)
    {
        var duration = TimeSpan.FromMilliseconds(250);
        AnimateWindowPosition(left, top, duration, () => { });
        var widthAnimation = new DoubleAnimation(ActualWidth, width, duration);
        var heightAnimation = new DoubleAnimation(ActualHeight, height, duration);
        heightAnimation.Completed += (_, _) =>
        {
            BeginAnimation(WidthProperty, null);
            BeginAnimation(HeightProperty, null);
            Width = width;
            Height = height;
            Left = left;
            Top = top;
            LayoutPrice();
            completed();
        };
        BeginAnimation(WidthProperty, widthAnimation);
        BeginAnimation(HeightProperty, heightAnimation);
    }

    public static readonly DependencyProperty AnimatedLeftProperty = DependencyProperty.Register(
        nameof(AnimatedLeft), typeof(double), typeof(FloatingCharacterWindow),
        new PropertyMetadata(0d, (owner, args) => ((FloatingCharacterWindow)owner).Left = (double)args.NewValue));

    public static readonly DependencyProperty AnimatedTopProperty = DependencyProperty.Register(
        nameof(AnimatedTop), typeof(double), typeof(FloatingCharacterWindow),
        new PropertyMetadata(0d, (owner, args) => ((FloatingCharacterWindow)owner).Top = (double)args.NewValue));

    public double AnimatedLeft { get => (double)GetValue(AnimatedLeftProperty); set => SetValue(AnimatedLeftProperty, value); }
    public double AnimatedTop { get => (double)GetValue(AnimatedTopProperty); set => SetValue(AnimatedTopProperty, value); }

    private void PlayLanding(double velocityX)
    {
        ResetLandingTransforms();
        var direction = velocityX >= 0 ? 1 : -1;
        landingTranslate.BeginAnimation(TranslateTransform.YProperty, KeyFrames([0, -12, 4, -5, 2, 0], 450));
        landingRotate.BeginAnimation(RotateTransform.AngleProperty, KeyFrames([0, direction * 3.2, -direction * 2, direction, 0], 450));
        landingScale.BeginAnimation(ScaleTransform.ScaleXProperty, KeyFrames([1, 0.96, 1.045, 0.985, 1], 450));
        landingScale.BeginAnimation(ScaleTransform.ScaleYProperty, KeyFrames([1, 0.96, 1.045, 0.985, 1], 450));
    }

    private void PlayDockPeek(bool emphasized)
    {
        var outward = dockEdge == DockEdge.Left ? -1d : 1d;
        var distance = emphasized ? 18d : 12d;
        landingTranslate.BeginAnimation(
            TranslateTransform.XProperty,
            KeyFrames([outward * distance, -outward * distance * 0.45, outward * distance * 0.18, 0], 450));
    }

    private void StartAmbientAnimations()
    {
        if (ambientScale.HasAnimatedProperties) return;
        var scale = new DoubleAnimation(0.985, 1.020, TimeSpan.FromSeconds(1.3)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever };
        var floating = new DoubleAnimation(-3, 5, TimeSpan.FromSeconds(1.6)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever };
        var sway = new DoubleAnimation(-0.8, 0.8, TimeSpan.FromSeconds(2.2)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever };
        scale.EasingFunction = floating.EasingFunction = sway.EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut };
        ambientScale.BeginAnimation(ScaleTransform.ScaleXProperty, scale);
        ambientScale.BeginAnimation(ScaleTransform.ScaleYProperty, scale);
        ambientTranslate.BeginAnimation(TranslateTransform.YProperty, floating);
        ambientRotate.BeginAnimation(RotateTransform.AngleProperty, sway);
    }

    private void StopAmbientAnimations()
    {
        ambientScale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
        ambientScale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        ambientTranslate.BeginAnimation(TranslateTransform.YProperty, null);
        ambientRotate.BeginAnimation(RotateTransform.AngleProperty, null);
        ambientScale.ScaleX = ambientScale.ScaleY = 1;
        ambientTranslate.X = ambientTranslate.Y = 0;
        ambientRotate.Angle = 0;
    }

    private void AnimateAction(CharacterPose targetPose)
    {
        if (targetPose is CharacterPose.HappyDance or CharacterPose.SadTurn)
        {
            var animation = new DoubleAnimation(-4, 4, TimeSpan.FromMilliseconds(450)) { AutoReverse = true, RepeatBehavior = new RepeatBehavior(3) };
            actionRotate.BeginAnimation(RotateTransform.AngleProperty, animation);
        }
        else if (targetPose is CharacterPose.SadPout or CharacterPose.SadFacepalm or CharacterPose.SadShiver)
        {
            var animation = KeyFrames([0, -5, 5, -4, 4, 0], 650);
            animation.RepeatBehavior = new RepeatBehavior(3);
            actionTranslate.BeginAnimation(TranslateTransform.XProperty, animation);
        }
        else if (targetPose is CharacterPose.HappyClap or CharacterPose.HappyThumbsUp)
        {
            var animation = new DoubleAnimation(0.94, 1.06, TimeSpan.FromMilliseconds(350)) { AutoReverse = true, RepeatBehavior = new RepeatBehavior(4) };
            actionScale.BeginAnimation(ScaleTransform.ScaleXProperty, animation);
            actionScale.BeginAnimation(ScaleTransform.ScaleYProperty, animation);
        }
        else
        {
            var animation = KeyFrames([0, -2, 10, -2, 5, 0], 700);
            animation.RepeatBehavior = new RepeatBehavior(3);
            actionTranslate.BeginAnimation(TranslateTransform.YProperty, animation);
        }
    }

    private void ResetActionTransforms()
    {
        actionScale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
        actionScale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        actionRotate.BeginAnimation(RotateTransform.AngleProperty, null);
        actionTranslate.BeginAnimation(TranslateTransform.XProperty, null);
        actionTranslate.BeginAnimation(TranslateTransform.YProperty, null);
        actionScale.ScaleX = actionScale.ScaleY = 1;
        actionRotate.Angle = 0;
        actionTranslate.X = actionTranslate.Y = 0;
    }

    private void ResetLandingTransforms()
    {
        landingScale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
        landingScale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        landingRotate.BeginAnimation(RotateTransform.AngleProperty, null);
        landingTranslate.BeginAnimation(TranslateTransform.XProperty, null);
        landingTranslate.BeginAnimation(TranslateTransform.YProperty, null);
        landingScale.ScaleX = landingScale.ScaleY = 1;
        landingRotate.Angle = 0;
        landingTranslate.X = landingTranslate.Y = 0;
    }

    private void StopAllAnimations()
    {
        StopAmbientAnimations();
        ResetActionTransforms();
        ResetLandingTransforms();
        BeginAnimation(AnimatedLeftProperty, null);
        BeginAnimation(AnimatedTopProperty, null);
        BeginAnimation(WidthProperty, null);
        BeginAnimation(HeightProperty, null);
    }

    private void CancelWindowAnimations()
    {
        var currentLeft = Left;
        var currentTop = Top;
        var currentWidth = ActualWidth > 0 ? ActualWidth : Width;
        var currentHeight = ActualHeight > 0 ? ActualHeight : Height;
        BeginAnimation(AnimatedLeftProperty, null);
        BeginAnimation(AnimatedTopProperty, null);
        BeginAnimation(WidthProperty, null);
        BeginAnimation(HeightProperty, null);
        Left = currentLeft;
        Top = currentTop;
        Width = currentWidth;
        Height = currentHeight;
        ResetLandingTransforms();
    }

    private void SetPose(CharacterPose newPose)
    {
        pose = newPose;
        UpdateImage();
    }

    private void UpdateImage()
    {
        if (!characterVisible && !IsVisible)
        {
            characterImage.Source = null;
            return;
        }
        if (docked)
        {
            characterImage.Source = imageCache.Get(blinkClosed ? "character-docked-sneak-blink" : "character-docked-sneak-open");
            characterImage.RenderTransformOrigin = new Point(0.5, 0.5);
            characterImage.RenderTransform = dockEdge == DockEdge.Left ? new ScaleTransform(-1, 1) : Transform.Identity;
        }
        else
        {
            characterImage.Source = imageCache.Get(pose.ResourceName());
            characterImage.RenderTransform = Transform.Identity;
        }
        LayoutPrice();
    }

    private void LayoutPrice()
    {
        if (ActualWidth <= 0 || ActualHeight <= 0) return;
        var normalized = docked
            ? dockEdge == DockEdge.Right
                ? DockedRightSignRect
                : new Rect(1 - DockedRightSignRect.Right, DockedRightSignRect.Top, DockedRightSignRect.Width, DockedRightSignRect.Height)
            : pose.SignRect();
        var left = normalized.Left * ActualWidth + 5;
        var top = normalized.Top * ActualHeight + 4;
        var width = Math.Max(1, normalized.Width * ActualWidth - 10);
        var height = Math.Max(1, normalized.Height * ActualHeight - 8);
        priceLabel.Text = price;
        priceLabel.Foreground = UiStyles.TrendBrush(isNegative);
        priceLabel.Width = width;
        priceLabel.Height = height;
        priceLabel.FontSize = FitFont(price, width, height);
        Canvas.SetLeft(priceLabel, left);
        Canvas.SetTop(priceLabel, top);
    }

    private double FitFont(string text, double width, double height)
    {
        var dpi = IsLoaded ? NativeMethods.Dpi(this).PixelsPerDip : 1;
        var low = 8d;
        var high = Math.Min(40, height * 0.9);
        var typeface = new Typeface(priceLabel.FontFamily, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
        for (var index = 0; index < 12; index++)
        {
            var middle = (low + high) / 2;
            var formatted = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, typeface, middle, Brushes.Black, dpi);
            if (formatted.Width <= width && formatted.Height <= height) low = middle; else high = middle;
        }
        return low;
    }

    private void ShowSpeech(
        SpeechKind kind,
        double delta = 0,
        TimeSpan? duration = null,
        bool persistent = false)
    {
        if (!characterVisible) return;
        speechBubble.ShowBubble(
            SpeechCatalog.Text(kind, emotion, delta),
            this,
            persistent ? null : duration ?? SpeechDuration);
    }

    private void ClampToCurrentScreen()
    {
        var point = new DrawingPoint((int)(Left + Width / 2), (int)(Top + Height / 2));
        var work = NativeMethods.WorkingAreaDip(this, point);
        Left = docked && dockEdge == DockEdge.Left ? work.Left
            : docked ? work.Right - Width
            : Math.Clamp(Left, work.Left, work.Right - Width);
        Top = Math.Clamp(Top, work.Top, work.Bottom - Height);
    }

    private void PersistPlacement()
    {
        PlacementChanged?.Invoke(new CharacterPlacement(Left, Top, IsLoaded ? NativeMethods.MonitorName(this) : string.Empty, docked, dockEdge));
    }

    private void StartActivityTimer(TimeSpan interval)
    {
        if (activityTimer.IsEnabled && activityTimer.Interval == interval) return;
        activityTimer.Stop();
        activityTimer.Interval = interval;
        activityTimer.Start();
    }

    private void SettleAfter(TimeSpan duration)
    {
        settleTimer.Stop();
        if (duration <= TimeSpan.Zero)
        {
            PersistPlacement();
            EvaluateMotion();
            return;
        }
        settleTimer.Interval = duration;
        settleTimer.Start();
    }

    private void RecordDragSample(Point point)
    {
        var now = Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
        dragSamples.Add(new DragSample(point, now));
        dragSamples.RemoveAll(sample => now - sample.Timestamp > 0.12);
        if (dragSamples.Count > 8) dragSamples.RemoveRange(0, dragSamples.Count - 8);
    }

    private Vector DragVelocity(DpiScale dpi)
    {
        if (dragSamples.Count < 2) return new Vector();
        var first = dragSamples[0];
        var last = dragSamples[^1];
        var duration = last.Timestamp - first.Timestamp;
        if (duration <= 0) return new Vector();
        return new Vector(
            (last.Point.X - first.Point.X) / dpi.DpiScaleX / duration,
            (last.Point.Y - first.Point.Y) / dpi.DpiScaleY / duration);
    }

    private void StopAllTimers()
    {
        ambientActionTimer.Stop();
        actionTimer.Stop();
        speechTimer.Stop();
        activityTimer.Stop();
        blinkTimer.Stop();
        pendingClickTimer.Stop();
        settleTimer.Stop();
    }

    private static CharacterPose RandomAction(CharacterEmotion targetEmotion)
    {
        var actions = CharacterPoseInfo.Actions(targetEmotion);
        return actions[Random.Shared.Next(actions.Count)];
    }

    private static CharacterPose Pick(IReadOnlyList<CharacterPose> values) => values[Random.Shared.Next(values.Count)];

    private static TransformGroup TransformGroup(params Transform[] transforms)
    {
        var group = new TransformGroup();
        foreach (var transform in transforms) group.Children.Add(transform);
        return group;
    }

    private static DoubleAnimationUsingKeyFrames KeyFrames(IReadOnlyList<double> values, int durationMilliseconds)
    {
        var animation = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromMilliseconds(durationMilliseconds) };
        for (var index = 0; index < values.Count; index++)
        {
            animation.KeyFrames.Add(new SplineDoubleKeyFrame(
                values[index],
                KeyTime.FromPercent(index / (double)(values.Count - 1)),
                new KeySpline(0.42, 0, 0.58, 1)));
        }
        return animation;
    }

    public void Dispose()
    {
        StopAllTimers();
        StopAllAnimations();
        speechBubble.Close();
        imageCache.Clear();
        allowClose = true;
        Close();
    }
}
