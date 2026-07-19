using GoldPriceBar.Core;
using Xunit;

namespace GoldPriceBar.Core.Tests;

public sealed class CoreTests
{
    [Fact]
    public void ParsesZheShangAndTruncatesPercentage()
    {
        const string json = """
            {"resultData":{"data":{"lastPrice":1049.59,"raise":-4.08,"raisePercent":-0.003899}}}
            """;
        var result = GoldPriceService.ParseZheShang(json);
        Assert.Equal(1049.59, result.Price);
        Assert.Equal("-4.08", result.ChangeAmount);
        Assert.Equal("-0.38%", result.ChangePercent);
        Assert.True(result.IsNegative);
    }

    [Fact]
    public void ParsesMinShengStrings()
    {
        const string json = """
            {"resultData":{"data":{"minimumPriceValue":"1021.25","rateValue":"+0.21%","dayFluctuateNum":"+2.13"}}}
            """;
        var result = GoldPriceService.ParseMinSheng(json);
        Assert.Equal(1021.25, result.Price);
        Assert.Equal("+2.13", result.ChangeAmount);
        Assert.False(result.IsNegative);
    }

    [Fact]
    public void ParsesMarketAndCalculatesConvertedPriceAndPremium()
    {
        const string json = """
            {"resultData":{"data":[
              {"uniqueCode":"WG-XAUUSD","name":"伦敦金","lastPrice":2400.0,"raise":12,"raisePercent":0.005},
              {"uniqueCode":"SGE-Au(T+D)","name":"黄金T+D","lastPrice":570.0,"raise":2,"raisePercent":0.003},
              {"uniqueCode":"FX-USDCNH","name":"离岸人民币","lastPrice":7.2,"raise":0.01,"raisePercent":0.001},
              {"uniqueCode":"FX-DXY","name":"美元指数","lastPrice":104.123,"raise":-0.1,"raisePercent":-0.001}
            ]}}
            """;
        var result = GoldPriceService.ParseMarketData(json, 0);
        Assert.Equal(2400d / 31.1035 * 7.2, result.ConvertedPrice, 6);
        Assert.Equal(570 - result.ConvertedPrice, result.Premium, 6);
        Assert.Equal("7.2000", result.UsdCnh.Price);
    }

    [Fact]
    public void AlertEvaluatorTriggersOnlyWhenCrossingThreshold()
    {
        var evaluator = new PriceAlertEvaluator();
        Assert.Empty(evaluator.Evaluate(999, 1000, 900));
        Assert.Equal([PriceAlertKind.High], evaluator.Evaluate(1000, 1000, 900));
        Assert.Empty(evaluator.Evaluate(1001, 1000, 900));
        Assert.Empty(evaluator.Evaluate(999, 1000, 900));
        Assert.Equal([PriceAlertKind.High], evaluator.Evaluate(1002, 1000, 900));
    }

    [Fact]
    public void MarketReactionUsesOneYuanThresholdAndCooldown()
    {
        var detector = new MarketReactionDetector();
        var start = DateTimeOffset.UnixEpoch;
        Assert.Null(detector.Process(1000, start));
        Assert.Null(detector.Process(1000.5, start.AddSeconds(1)));
        Assert.Equal(MarketReactionKind.RapidRise, detector.Process(1001.5, start.AddSeconds(2))?.Kind);
        Assert.Null(detector.Process(1003, start.AddSeconds(20)));
        Assert.Equal(MarketReactionKind.RapidRise, detector.Process(1004, start.AddSeconds(48))?.Kind);
    }

    [Fact]
    public void ClickSequenceEscalatesAndCoolsDown()
    {
        var sequence = new ClickSequence();
        var start = DateTimeOffset.UnixEpoch;
        var doubleInterval = TimeSpan.FromMilliseconds(500);
        Assert.Equal(ClickReaction.PendingSingle, sequence.Register(start, doubleInterval));
        Assert.Equal(ClickReaction.DoubleClick, sequence.Register(start.AddMilliseconds(200), doubleInterval));
        Assert.Equal(ClickReaction.Impatient, sequence.Register(start.AddMilliseconds(400), doubleInterval));
        Assert.Equal(ClickReaction.Hide, sequence.Register(start.AddMilliseconds(600), doubleInterval));
        Assert.Equal(ClickReaction.IgnoredDuringCooldown, sequence.Register(start.AddSeconds(2), doubleInterval));
        Assert.Equal(ClickReaction.PendingSingle, sequence.Register(start.AddSeconds(8.7), doubleInterval));
    }

    [Fact]
    public void DragProjectionHasThresholdAndMaximumDistance()
    {
        Assert.Equal((0d, 0d), DragPhysics.Project(649, 0));
        var result = DragPhysics.Project(2000, 2000);
        var length = Math.Sqrt(result.X * result.X + result.Y * result.Y);
        Assert.Equal(120, length, 6);
    }

    [Fact]
    public void PriceBarPlacementClampsAndSnapsToEveryWorkAreaEdge()
    {
        const double workLeft = 100;
        const double workTop = 50;
        const double workWidth = 1000;
        const double workHeight = 700;
        const double width = 360;
        const double height = 42;

        Assert.Equal(
            (workLeft, workTop),
            PriceBarPlacementPolicy.ClampAndSnap(110, 60, width, height, workLeft, workTop, workWidth, workHeight));
        Assert.Equal(
            (740d, 708d),
            PriceBarPlacementPolicy.ClampAndSnap(730, 700, width, height, workLeft, workTop, workWidth, workHeight));
        Assert.Equal(
            (250d, 300d),
            PriceBarPlacementPolicy.ClampAndSnap(250, 300, width, height, workLeft, workTop, workWidth, workHeight));
        Assert.Equal(
            (workLeft, 708d),
            PriceBarPlacementPolicy.ClampAndSnap(-500, 900, width, height, workLeft, workTop, workWidth, workHeight));
    }

    [Fact]
    public void PriceBarPlacementDoesNotSnapWhileDragging()
    {
        Assert.Equal(
            (110d, 60d),
            PriceBarPlacementPolicy.Clamp(110, 60, 360, 42, 100, 50, 1000, 700));
    }

    [Fact]
    public async Task SettingsRoundTripAndCorruptionFallback()
    {
        var directory = System.IO.Path.Combine(System.IO.Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        var path = System.IO.Path.Combine(directory, "settings.json");
        try
        {
            var store = new SettingsStore(path);
            await store.SaveAsync(new AppSettings
            {
                Provider = GoldProvider.MinSheng,
                RefreshIntervalSeconds = 5,
                HighThreshold = 1100,
                FloatingCharacterSize = CharacterSize.Large,
                CharacterDocked = true,
                CharacterDockEdge = DockEdge.Left,
            });
            var loaded = await store.LoadAsync();
            Assert.Equal(GoldProvider.MinSheng, loaded.Provider);
            Assert.Equal(5, loaded.RefreshIntervalSeconds);
            Assert.Equal(CharacterSize.Large, loaded.FloatingCharacterSize);
            Assert.True(loaded.CharacterDocked);

            await File.WriteAllTextAsync(path, "not-json");
            var fallback = await store.LoadAsync();
            Assert.Equal(GoldProvider.ZheShang, fallback.Provider);
            Assert.Equal(1, fallback.RefreshIntervalSeconds);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
    }
}
