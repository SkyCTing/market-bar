using System.Windows.Media.Imaging;

namespace GoldPriceBar.Windows;

internal sealed class CharacterImageCache
{
    internal const int MaximumCount = 8;
    internal const long MaximumCost = 10 * 1024 * 1024;

    private sealed record Entry(string Name, BitmapImage Image, long Cost);

    private readonly Dictionary<string, LinkedListNode<Entry>> byName = new(StringComparer.Ordinal);
    private readonly LinkedList<Entry> recency = new();
    private long totalCost;

    internal BitmapImage Get(string name)
    {
        if (byName.TryGetValue(name, out var existing))
        {
            recency.Remove(existing);
            recency.AddFirst(existing);
            return existing.Value.Image;
        }

        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.UriSource = new Uri($"pack://application:,,,/Assets/FloatingCharacter/{name}.png", UriKind.Absolute);
        image.EndInit();
        image.Freeze();
        var cost = Math.Max(0, image.PixelWidth) * (long)Math.Max(0, image.PixelHeight) * 4;
        var node = new LinkedListNode<Entry>(new Entry(name, image, cost));
        recency.AddFirst(node);
        byName[name] = node;
        totalCost += cost;
        Trim();
        return image;
    }

    internal void Clear()
    {
        byName.Clear();
        recency.Clear();
        totalCost = 0;
    }

    private void Trim()
    {
        while (byName.Count > MaximumCount || totalCost > MaximumCost)
        {
            var node = recency.Last;
            if (node is null) return;
            recency.RemoveLast();
            byName.Remove(node.Value.Name);
            totalCost -= node.Value.Cost;
        }
    }
}
