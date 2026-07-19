namespace GoldPriceBar.Core;

public enum PriceAlertKind
{
    High,
    Low,
}

public sealed class PriceAlertEvaluator
{
    private bool highTriggered;
    private bool lowTriggered;

    public IReadOnlyList<PriceAlertKind> Evaluate(double price, double? high, double? low)
    {
        if (!double.IsFinite(price) || price <= 0)
        {
            return [];
        }

        var triggered = new List<PriceAlertKind>(2);
        if (high is > 0)
        {
            if (price >= high && !highTriggered)
            {
                highTriggered = true;
                triggered.Add(PriceAlertKind.High);
            }
            else if (price < high)
            {
                highTriggered = false;
            }
        }
        else
        {
            highTriggered = false;
        }

        if (low is > 0)
        {
            if (price <= low && !lowTriggered)
            {
                lowTriggered = true;
                triggered.Add(PriceAlertKind.Low);
            }
            else if (price > low)
            {
                lowTriggered = false;
            }
        }
        else
        {
            lowTriggered = false;
        }

        return triggered;
    }

    public void Reset()
    {
        highTriggered = false;
        lowTriggered = false;
    }
}

public enum MarketReactionKind
{
    RapidRise,
    RapidFall,
}

public sealed record MarketReaction(MarketReactionKind Kind, double Delta);

public sealed class MarketReactionDetector
{
    public const double PriceDeltaThreshold = 1;
    public static readonly TimeSpan Cooldown = TimeSpan.FromSeconds(45);

    private double? lastValidPrice;
    private DateTimeOffset? lastReactionAt;

    public MarketReaction? Process(double price, DateTimeOffset now)
    {
        if (!double.IsFinite(price) || price <= 0)
        {
            return null;
        }

        var previous = lastValidPrice;
        lastValidPrice = price;
        if (previous is null)
        {
            return null;
        }

        var delta = price - previous.Value;
        if (Math.Abs(delta) < PriceDeltaThreshold ||
            lastReactionAt is not null && now - lastReactionAt < Cooldown)
        {
            return null;
        }

        lastReactionAt = now;
        return new MarketReaction(
            delta > 0 ? MarketReactionKind.RapidRise : MarketReactionKind.RapidFall,
            delta);
    }

    public void Reset()
    {
        lastValidPrice = null;
        lastReactionAt = null;
    }
}

public enum ClickReaction
{
    PendingSingle,
    DoubleClick,
    Impatient,
    Hide,
    IgnoredDuringCooldown,
}

public sealed class ClickSequence
{
    public static readonly TimeSpan BurstInterval = TimeSpan.FromSeconds(3);
    public static readonly TimeSpan TerminalCooldown = TimeSpan.FromSeconds(8);
    public static readonly TimeSpan HideDuration = TimeSpan.FromSeconds(4);

    private int count;
    private DateTimeOffset? burstStartedAt;
    private DateTimeOffset? lastClickedAt;
    private DateTimeOffset? cooldownUntil;

    public ClickReaction Register(DateTimeOffset now, TimeSpan doubleClickInterval)
    {
        if (cooldownUntil is not null && now < cooldownUntil)
        {
            return ClickReaction.IgnoredDuringCooldown;
        }

        var lastInterval = lastClickedAt is null ? null : now - lastClickedAt;
        var burstAge = burstStartedAt is null ? null : now - burstStartedAt;
        if (burstAge is not null && burstAge >= TimeSpan.Zero && burstAge <= BurstInterval)
        {
            count++;
        }
        else
        {
            count = 1;
            burstStartedAt = now;
        }
        lastClickedAt = now;

        return count switch
        {
            1 => ClickReaction.PendingSingle,
            2 when lastInterval is not null && lastInterval <= doubleClickInterval => ClickReaction.DoubleClick,
            2 => ClickReaction.PendingSingle,
            3 => ClickReaction.Impatient,
            _ => EnterCooldown(now),
        };
    }

    public void ResetBurst()
    {
        count = 0;
        burstStartedAt = null;
        lastClickedAt = null;
    }

    private ClickReaction EnterCooldown(DateTimeOffset now)
    {
        cooldownUntil = now + TerminalCooldown;
        ResetBurst();
        return ClickReaction.Hide;
    }
}

public static class DragPhysics
{
    public const double SpeedThreshold = 650;
    public const double ProjectionFactor = 0.12;
    public const double MaximumDisplacement = 120;

    public static (double X, double Y) Project(double velocityX, double velocityY)
    {
        var speed = Math.Sqrt(velocityX * velocityX + velocityY * velocityY);
        if (speed < SpeedThreshold)
        {
            return (0, 0);
        }

        var x = velocityX * ProjectionFactor;
        var y = velocityY * ProjectionFactor;
        var magnitude = Math.Sqrt(x * x + y * y);
        if (magnitude > MaximumDisplacement)
        {
            var scale = MaximumDisplacement / magnitude;
            x *= scale;
            y *= scale;
        }
        return (x, y);
    }
}

public static class PriceBarPlacementPolicy
{
    public const double EdgeSnapDistance = 16;

    public static (double Left, double Top) Clamp(
        double left,
        double top,
        double width,
        double height,
        double workLeft,
        double workTop,
        double workWidth,
        double workHeight) => Place(
            left,
            top,
            width,
            height,
            workLeft,
            workTop,
            workWidth,
            workHeight,
            false);

    public static (double Left, double Top) ClampAndSnap(
        double left,
        double top,
        double width,
        double height,
        double workLeft,
        double workTop,
        double workWidth,
        double workHeight) => Place(
            left,
            top,
            width,
            height,
            workLeft,
            workTop,
            workWidth,
            workHeight,
            true);

    private static (double Left, double Top) Place(
        double left,
        double top,
        double width,
        double height,
        double workLeft,
        double workTop,
        double workWidth,
        double workHeight,
        bool snap)
    {
        var maxLeft = workLeft + Math.Max(0, workWidth - Math.Max(0, width));
        var maxTop = workTop + Math.Max(0, workHeight - Math.Max(0, height));
        var placedLeft = Math.Clamp(left, workLeft, maxLeft);
        var placedTop = Math.Clamp(top, workTop, maxTop);

        if (!snap)
        {
            return (placedLeft, placedTop);
        }

        if (placedLeft - workLeft <= EdgeSnapDistance)
        {
            placedLeft = workLeft;
        }
        else if (maxLeft - placedLeft <= EdgeSnapDistance)
        {
            placedLeft = maxLeft;
        }

        if (placedTop - workTop <= EdgeSnapDistance)
        {
            placedTop = workTop;
        }
        else if (maxTop - placedTop <= EdgeSnapDistance)
        {
            placedTop = maxTop;
        }

        return (placedLeft, placedTop);
    }
}
