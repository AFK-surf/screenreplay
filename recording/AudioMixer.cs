namespace Replay.Recording;

internal sealed class AudioMixer
{
    public const int Rate = AudioSource.Rate;
    private const int Capacity = Rate * 4;
    private const int Snap = Rate / 100;

    public const long Latency = 1_200_000;

    private readonly float[][] rings;
    private readonly long[] next;
    private readonly long t0;
    private long emitted;
    private readonly float[] mix = new float[Rate / 5 * 2];
    private readonly float[][] each;

    public AudioMixer(int sources, long t0Hns, long startFrame)
    {
        rings = new float[sources][];
        next = new long[sources];
        each = new float[sources][];
        for (var i = 0; i < sources; i++)
        {
            rings[i] = new float[Capacity * 2];
            next[i] = long.MinValue;
            each[i] = new float[mix.Length];
        }

        t0 = t0Hns;
        emitted = startFrame;
    }

    public long Emitted => emitted;

    public int Sources => rings.Length;

    public void Add(int source, long timeHns, float[] samples, int frames)
    {
        var at = (long)Math.Round((timeHns - t0) * (double)Rate / 10_000_000.0);
        if (next[source] != long.MinValue && Math.Abs(at - next[source]) <= Snap)
        {
            at = next[source];
        }

        next[source] = at + frames;
        var ring = rings[source];
        for (var k = 0; k < frames; k++)
        {
            var p = at + k;
            if (p < emitted || p >= emitted + Capacity)
            {
                continue;
            }

            var i = (int)(p % Capacity) * 2;
            ring[i] = samples[k * 2];
            ring[i + 1] = samples[k * 2 + 1];
        }
    }

    public void Emit(long nowHns, Action<long, float[], float[][], int, int> sink)
    {
        var until = (long)Math.Floor((nowHns - Latency - t0) * (double)Rate / 10_000_000.0);
        while (until > emitted)
        {
            var n = (int)Math.Min(until - emitted, mix.Length / 2);
            for (var k = 0; k < n; k++)
            {
                var i = (int)((emitted + k) % Capacity) * 2;
                float l = 0, r = 0;
                for (var s = 0; s < rings.Length; s++)
                {
                    var a = rings[s][i];
                    var b = rings[s][i + 1];
                    each[s][k * 2] = a;
                    each[s][k * 2 + 1] = b;
                    l += a;
                    r += b;
                    rings[s][i] = 0;
                    rings[s][i + 1] = 0;
                }

                mix[k * 2] = Math.Clamp(l, -1f, 1f);
                mix[k * 2 + 1] = Math.Clamp(r, -1f, 1f);
            }

            sink(emitted, mix, each, 0, n);
            emitted += n;
        }
    }
}
