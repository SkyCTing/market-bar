using System.Globalization;
using System.Text.Json;

namespace GoldPriceBar.Core;

public sealed class GoldPriceService
{
    private static readonly Uri MarketQuoteEndpoint = new(
        "https://ms.jr.jd.com/gw2/generic/jdtwt/h5/m/getSimpleQuoteUseUniqueCodes?reqData=%7B%22ticket%22%3A%22gold-price-h5%22%2C%22uniqueCodes%22%3A%5B%22WG-XAUUSD%22%2C%22SGE-Au(T%2BD)%22%2C%22FX-USDCNH%22%2C%22FX-DXY%22%5D%7D");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private readonly HttpClient client;

    public GoldPriceService(HttpClient? client = null)
    {
        this.client = client ?? new HttpClient();
        this.client.Timeout = TimeSpan.FromSeconds(5);
    }

    public async Task<PriceInfo> FetchPriceInfoAsync(
        GoldProvider provider,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var json = await client.GetStringAsync(provider.Endpoint(), cancellationToken);
            return provider == GoldProvider.ZheShang
                ? ParseZheShang(json)
                : ParseMinSheng(json);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return PriceInfo.Empty;
        }
        catch (HttpRequestException)
        {
            return PriceInfo.Empty;
        }
        catch (JsonException)
        {
            return PriceInfo.Empty;
        }
    }

    public async Task<MarketData> FetchMarketDataAsync(
        double currentGoldPrice,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var json = await client.GetStringAsync(MarketQuoteEndpoint, cancellationToken);
            return ParseMarketData(json, currentGoldPrice);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return MarketData.Empty;
        }
        catch (HttpRequestException)
        {
            return MarketData.Empty;
        }
        catch (JsonException)
        {
            return MarketData.Empty;
        }
    }

    public static PriceInfo ParseZheShang(string json)
    {
        var response = JsonSerializer.Deserialize<ZheShangResponse>(json, JsonOptions);
        var node = response?.ResultData?.Data;
        var price = node?.LastPrice ?? 0;
        var raise = node?.Raise ?? 0;
        var percent = Math.Truncate((node?.RaisePercent ?? 0) * 10_000) / 100;
        return new PriceInfo(
            price,
            raise.ToString("F2", CultureInfo.InvariantCulture),
            percent.ToString("F2", CultureInfo.InvariantCulture) + "%",
            raise < 0 ? true : raise > 0 ? false : null);
    }

    public static PriceInfo ParseMinSheng(string json)
    {
        var response = JsonSerializer.Deserialize<MinShengResponse>(json, JsonOptions);
        var node = response?.ResultData?.Data;
        _ = double.TryParse(
            node?.MinimumPriceValue,
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out var price);
        var amount = node?.DayFluctuateNum ?? "0.00";
        bool? isNegative = amount.StartsWith("-", StringComparison.Ordinal)
            ? true
            : double.TryParse(amount, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) && value > 0
                ? false
                : null;
        return new PriceInfo(price, amount, node?.RateValue ?? "0.00%", isNegative);
    }

    public static MarketData ParseMarketData(string json, double currentGoldPrice)
    {
        var response = JsonSerializer.Deserialize<MarketQuoteResponse>(json, JsonOptions);
        var items = response?.ResultData?.Data ?? [];
        var byCode = items
            .Where(item => !string.IsNullOrWhiteSpace(item.UniqueCode))
            .GroupBy(item => item.UniqueCode!, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.First(), StringComparer.Ordinal);

        byCode.TryGetValue("WG-XAUUSD", out var london);
        byCode.TryGetValue("SGE-Au(T+D)", out var goldTd);
        byCode.TryGetValue("FX-USDCNH", out var usdCnh);
        byCode.TryGetValue("FX-DXY", out var dxy);

        var converted = london?.LastPrice > 0 && usdCnh?.LastPrice > 0
            ? london.LastPrice.Value / 31.1035 * usdCnh.LastPrice.Value
            : 0;
        var premium = converted > 0 && goldTd?.LastPrice > 0
            ? goldTd.LastPrice.Value - converted
            : 0;

        return new MarketData(
            MakeRow(london, "伦敦金", 2),
            MakeRow(goldTd, "黄金T+D", 2),
            MakeRow(usdCnh, "离岸人民币", 4),
            MakeRow(dxy, "美元指数", 3),
            converted,
            premium);
    }

    private static QuoteRow MakeRow(MarketQuoteItem? item, string fallbackName, int decimals)
    {
        if (item is null)
        {
            return QuoteRow.Empty(fallbackName);
        }

        return new QuoteRow(
            item.Name ?? fallbackName,
            (item.LastPrice ?? 0).ToString($"F{decimals}", CultureInfo.InvariantCulture),
            item.Raise ?? 0,
            item.RaisePercent ?? 0);
    }

    private sealed class ZheShangResponse
    {
        public ZheShangResultData? ResultData { get; set; }
    }

    private sealed class ZheShangResultData
    {
        public ZheShangData? Data { get; set; }
    }

    private sealed class ZheShangData
    {
        public double? LastPrice { get; set; }
        public double? Raise { get; set; }
        public double? RaisePercent { get; set; }
    }

    private sealed class MinShengResponse
    {
        public MinShengResultData? ResultData { get; set; }
    }

    private sealed class MinShengResultData
    {
        public MinShengData? Data { get; set; }
    }

    private sealed class MinShengData
    {
        public string? MinimumPriceValue { get; set; }
        public string? RateValue { get; set; }
        public string? DayFluctuateNum { get; set; }
    }

    private sealed class MarketQuoteResponse
    {
        public MarketQuoteResultData? ResultData { get; set; }
    }

    private sealed class MarketQuoteResultData
    {
        public List<MarketQuoteItem>? Data { get; set; }
    }

    private sealed class MarketQuoteItem
    {
        public string? UniqueCode { get; set; }
        public string? Name { get; set; }
        public double? LastPrice { get; set; }
        public double? Raise { get; set; }
        public double? RaisePercent { get; set; }
    }
}
