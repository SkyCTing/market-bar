using System.Globalization;

namespace GoldPriceBar.Core;

public enum GoldProvider
{
    ZheShang,
    MinSheng,
}

public static class GoldProviderExtensions
{
    public static string DisplayName(this GoldProvider provider) => provider switch
    {
        GoldProvider.ZheShang => "浙商积存金",
        GoldProvider.MinSheng => "民生积存金",
        _ => "积存金",
    };

    public static string ShortName(this GoldProvider provider) => provider switch
    {
        GoldProvider.ZheShang => "浙商",
        GoldProvider.MinSheng => "民生",
        _ => "积存金",
    };

    public static Uri Endpoint(this GoldProvider provider) => provider switch
    {
        GoldProvider.ZheShang => new("https://api.jdjygold.com/gw2/generic/produTools/h5/m/getGoldPrice?goldCode=CZB-JCJ"),
        GoldProvider.MinSheng => new("https://ms.jr.jd.com/gw2/generic/CreatorSer/newh5/m/getFirstRelatedProductInfo?reqData=%7B%22circleId%22%3A%2213245%22%2C%22invokeSource%22%3A5%2C%22productId%22%3A%2221001001000001%22%7D"),
        _ => throw new ArgumentOutOfRangeException(nameof(provider)),
    };
}

public sealed record PriceInfo(
    double Price,
    string ChangeAmount,
    string ChangePercent,
    bool? IsNegative)
{
    public static PriceInfo Empty { get; } = new(0, "0.00", "0.00%", null);
    public bool IsValid => double.IsFinite(Price) && Price > 0;
}

public sealed record QuoteRow(
    string Name,
    string Price,
    double Raise,
    double RaisePercent)
{
    public static QuoteRow Empty(string name) => new(name, "--", 0, 0);
}

public sealed record MarketData(
    QuoteRow LondonGold,
    QuoteRow GoldTD,
    QuoteRow UsdCnh,
    QuoteRow DollarIndex,
    double ConvertedPrice,
    double Premium)
{
    public static MarketData Empty { get; } = new(
        QuoteRow.Empty("伦敦金"),
        QuoteRow.Empty("黄金T+D"),
        QuoteRow.Empty("离岸人民币"),
        QuoteRow.Empty("美元指数"),
        0,
        0);
}

public sealed record AppSnapshot(
    GoldProvider Provider,
    PriceInfo Price,
    MarketData Market,
    DateTimeOffset? LastUpdated,
    int RefreshIntervalSeconds,
    double? HighThreshold,
    double? LowThreshold)
{
    public string FormattedPrice => Price.Price.ToString("F2", CultureInfo.InvariantCulture);
}

public enum CharacterSize
{
    Small = 220,
    Standard = 240,
    Large = 260,
}

public enum DockEdge
{
    Left,
    Right,
}

public sealed class AppSettings
{
    public GoldProvider Provider { get; set; } = GoldProvider.ZheShang;
    public int RefreshIntervalSeconds { get; set; } = 1;
    public double? HighThreshold { get; set; }
    public double? LowThreshold { get; set; }
    public bool FloatingCharacterVisible { get; set; } = true;
    public CharacterSize FloatingCharacterSize { get; set; } = CharacterSize.Standard;
    public double? CharacterLeft { get; set; }
    public double? CharacterTop { get; set; }
    public string? CharacterMonitor { get; set; }
    public bool CharacterDocked { get; set; }
    public DockEdge CharacterDockEdge { get; set; } = DockEdge.Right;

    public void Normalize()
    {
        if (RefreshIntervalSeconds is not (1 or 2 or 5 or 10))
        {
            RefreshIntervalSeconds = 1;
        }

        if (!Enum.IsDefined(FloatingCharacterSize))
        {
            FloatingCharacterSize = CharacterSize.Standard;
        }

        if (HighThreshold is double high && (!double.IsFinite(high) || high <= 0))
        {
            HighThreshold = null;
        }

        if (LowThreshold is double low && (!double.IsFinite(low) || low <= 0))
        {
            LowThreshold = null;
        }
    }
}
