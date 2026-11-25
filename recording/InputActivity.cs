namespace Replay.Recording;

// Single-writer (UI/input thread), lock-free reader (segment completion thread).
public sealed class InputActivity
{
    private const long Slot = 100_000;
    private const int Slots = 18_000;
    private const long Bucket = 1_000_000;

    private const long Before = 4_500_000;
    private const long After = 5_500_000;

    private readonly long[] stamp = new long[Slots];
    private readonly int[] keys = new int[Slots];
    private readonly int[] clicks = new int[Slots];
    private readonly int[] wheel = new int[Slots];

    private readonly int[] axes = new int[Slots];

    public InputActivity()
    {
        Array.Fill(stamp, -1L);
    }

    public void Key(int lagMs) => keys[At(lagMs)]++;

    public void Presses(int n, int lagMs) => keys[At(lagMs)] += n;

    public void Click(int n, int lagMs) => clicks[At(lagMs)] += n;

    public void Wheel(int delta, int lagMs) => wheel[At(lagMs)] += Math.Abs(delta);

    public void Axes(double travel, int lagMs) => axes[At(lagMs)] += (int)Math.Round(travel * 1000);

    private long last;

    public long LastHns => Volatile.Read(ref last);

    private int At(int lagMs)
    {
        var hns = Native.NowHns() - lagMs * 10_000L;
        if (hns > Volatile.Read(ref last))
        {
            Volatile.Write(ref last, hns);
        }

        var abs = hns / Slot;
        var i = (int)(abs % Slots);
        if (stamp[i] != abs)
        {
            keys[i] = clicks[i] = wheel[i] = axes[i] = 0;
            Volatile.Write(ref stamp[i], abs);
        }

        return i;
    }

    public byte[] Read(long startHns, int count)
    {
        var bytes = new byte[Math.Max(0, count)];
        if (count <= 0)
        {
            return bytes;
        }

        var now = Native.NowHns() / Slot;
        var first = (startHns - Before) / Slot;
        var last = (startHns + count * Bucket + After) / Slot;
        var n = (int)(last - first);
        var sk = new long[n + 1];
        var sc = new long[n + 1];
        var sw = new long[n + 1];
        var sa = new long[n + 1];
        for (var j = 0; j < n; j++)
        {
            var abs = first + j;
            var i = (int)(((abs % Slots) + Slots) % Slots);
            long k = 0, c = 0, w = 0, a = 0;
            if (abs <= now && Volatile.Read(ref stamp[i]) == abs)
            {
                k = keys[i];
                c = clicks[i];
                w = wheel[i];
                a = axes[i];
                if (Volatile.Read(ref stamp[i]) != abs)
                {
                    k = c = w = a = 0;
                }
            }

            sk[j + 1] = sk[j] + k;
            sc[j + 1] = sc[j] + c;
            sw[j + 1] = sw[j] + w;
            sa[j + 1] = sa[j] + a;
        }

        for (var b = 0; b < count; b++)
        {
            var at = startHns + b * Bucket;
            var from = (int)((at - Before) / Slot - first);
            var to = (int)Math.Clamp((at + After) / Slot - first, from + 1, n);
            var upTo = (int)Math.Clamp(now + 1 - first, from + 1, to);
            var seconds = (upTo - from) * (Slot / 10_000_000.0);
            bytes[b] = Intensity((sk[upTo] - sk[from]) / seconds, (sc[upTo] - sc[from]) / seconds,
                (sw[upTo] - sw[from]) / 120.0 / seconds, (sa[upTo] - sa[from]) / 1000.0 / seconds);
        }

        return bytes;
    }

    public static byte Intensity(double keysPerSecond, double clicksPerSecond, double notchesPerSecond, double axesPerSecond = 0)
    {
        var presses = keysPerSecond + clicksPerSecond + notchesPerSecond * 0.5;
        if (presses <= 0 && axesPerSecond <= 0)
        {
            return 0;
        }

        var a = Math.Min(1.0, Math.Log2(1 + presses) / Math.Log2(13));
        var b = Math.Min(1.0, Math.Log2(1 + axesPerSecond / 0.25) / Math.Log2(81));
        var any = 1 - (1 - a) * (1 - b);
        return (byte)Math.Clamp((int)Math.Round(any * 255), 1, 255);
    }
}
