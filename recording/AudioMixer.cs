namespace Replay.Recording;

/// <summary>
/// The sources' sound put on one timeline and mixed: frame <c>p</c> of the timeline is the moment
/// <c>T0 + p / 48 kHz</c>, T0 the recording's first video frame, so that the sound is in step with the picture by
/// construction. Each source's packets land where their time says (within 10 ms of where the one before ended they are
/// taken as following it without a break, so the small jitter of packet times never makes a click); what no source
/// filled is silence. The mix is given out a little behind real time (<see cref="Latency"/>), once every source has
/// delivered what it has of it.
/// </summary>
internal sealed class AudioMixer
{
    public const int Rate = AudioSource.Rate;
    private const int Capacity = Rate * 4;
    private const int Snap = Rate / 100;

    /// <summary>How far behind now the mix is given out (100 ns).</summary>
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

    /// <summary>Where on the timeline the mix has been given out to.</summary>
    public long Emitted => emitted;

    public int Sources => rings.Length;

    /// <summary>A packet of source <paramref name="source"/>: its time and its frames (stereo).</summary>
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

    /// <summary>The mix up to <paramref name="nowHns"/> less the latency given to <paramref name="sink"/> in pieces:
    /// (their first frame on the timeline, the mix, each source's own, the offset in them, the frames).</summary>
    public void Emit(long nowHns, Action<long, float[], float[][], int, int> sink)
    {
        var until = (long)Math.Floor((nowHns - Latency - t0) * (double)Rate / 10_000_000.0);
        // (a stall longer than the ring: what is too old is silence, given out at once)
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
