using System.Globalization;
using System.Text.Json;

namespace Replay.Recording;

public sealed record Segment(string Path, DateTimeOffset StartUtc, DateTimeOffset EndUtc, long Bytes, int Width, int Height, double DurationMs);

public sealed class SegmentStore(string folder)
{
    public static readonly string[] Sidecars = [".json", ".levels", ".input", ".thumbs"];

    public string Folder { get; } = folder;

    private readonly Dictionary<string, Segment> read = new(StringComparer.OrdinalIgnoreCase);

    public IReadOnlyList<Segment> List()
    {
        var found = new List<Segment>();
        if (!Directory.Exists(Folder))
        {
            return found;
        }

        lock (read)
        {
            var there = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var mp4 in Directory.EnumerateFiles(Folder, "*.mp4"))
            {
                if (!string.Equals(System.IO.Path.GetExtension(mp4), ".mp4", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                there.Add(mp4);
                if (!read.TryGetValue(mp4, out var segment))
                {
                    if (Read(mp4) is not { } now)
                    {
                        continue;
                    }

                    read[mp4] = segment = now;
                }

                found.Add(segment);
            }

            foreach (var gone in read.Keys.Where(k => !there.Contains(k)).ToList())
            {
                read.Remove(gone);
            }
        }

        found.Sort((a, b) => a.StartUtc.CompareTo(b.StartUtc));
        return found;
    }

    private static Segment? Read(string mp4)
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(System.IO.Path.ChangeExtension(mp4, ".json")));
            var root = doc.RootElement;
            var duration = root.GetProperty("durationMs").GetDouble();
            DateTimeOffset start;
            if (root.TryGetProperty("startUtc", out var s) && s.ValueKind == JsonValueKind.String &&
                DateTimeOffset.TryParse(s.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
            {
                start = parsed;
            }
            else if (!TryStartOfName(System.IO.Path.GetFileName(mp4), out start))
            {
                return null;
            }

            var w = root.TryGetProperty("width", out var wv) && wv.TryGetInt32(out var wi) ? wi : 0;
            var h = root.TryGetProperty("height", out var hv) && hv.TryGetInt32(out var hi) ? hi : 0;
            return new Segment(mp4, start, start + TimeSpan.FromMilliseconds(duration), new FileInfo(mp4).Length, w, h, duration);
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static bool TryStartOfName(string name, out DateTimeOffset start)
    {
        start = default;
        if (name.Length < 19 || !DateTime.TryParseExact(name[..19], "yyyyMMdd-HHmmss-fff", CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var t))
        {
            return false;
        }

        start = new DateTimeOffset(t, TimeSpan.Zero);
        return true;
    }

    public int Prune(DateTimeOffset before)
    {
        var gone = 0;
        foreach (var segment in List())
        {
            if (segment.EndUtc >= before)
            {
                continue;
            }

            if (DeleteSegment(segment))
            {
                gone++;
            }
        }

        return gone;
    }

    public int PruneRecorded(TimeSpan keep)
    {
        var segments = List();
        var keepMs = Math.Max(0.0, keep.TotalMilliseconds);
        var accMs = 0.0;
        var keepFrom = 0;
        for (var i = segments.Count - 1; i >= 0; i--)
        {
            accMs += Math.Max(0.0, segments[i].DurationMs);
            if (accMs >= keepMs)
            {
                keepFrom = i;
                break;
            }
        }

        if (accMs < keepMs)
        {
            return 0;
        }

        var gone = 0;
        for (var i = 0; i < keepFrom; i++)
        {
            if (DeleteSegment(segments[i]))
            {
                gone++;
            }
        }

        return gone;
    }

    public static int PruneRecordedAcross(IReadOnlyList<SegmentStore> stores, TimeSpan keep)
    {
        var all = new List<(SegmentStore Store, Segment Segment)>();
        foreach (var store in stores)
        {
            foreach (var seg in store.List())
            {
                all.Add((store, seg));
            }
        }

        all.Sort((a, b) => a.Segment.StartUtc.CompareTo(b.Segment.StartUtc));
        var keepMs = Math.Max(0.0, keep.TotalMilliseconds);
        var accMs = 0.0;
        var keepFrom = 0;
        for (var i = all.Count - 1; i >= 0; i--)
        {
            accMs += Math.Max(0.0, all[i].Segment.DurationMs);
            if (accMs >= keepMs)
            {
                keepFrom = i;
                break;
            }
        }

        if (accMs < keepMs)
        {
            return 0;
        }

        var gone = 0;
        for (var i = 0; i < keepFrom; i++)
        {
            if (all[i].Store.DeleteSegment(all[i].Segment))
            {
                gone++;
            }
        }

        return gone;
    }

    private bool DeleteSegment(Segment segment)
    {
        try
        {
            File.Delete(segment.Path);
        }
        catch (Exception)
        {
            return false;
        }

        foreach (var ext in Sidecars)
        {
            try
            {
                File.Delete(System.IO.Path.ChangeExtension(segment.Path, ext));
            }
            catch (Exception)
            {
            }
        }

        lock (read)
        {
            read.Remove(segment.Path);
        }

        return true;
    }

    public void DeleteUnfinished()
    {
        if (!Directory.Exists(Folder))
        {
            return;
        }

        foreach (var file in Directory.EnumerateFiles(Folder, "*" + SegmentWriter.TempExtension))
        {
            try
            {
                File.Delete(file);
            }
            catch (Exception)
            {
            }
        }
    }
}
