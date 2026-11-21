namespace Replay.Recording;

/// <summary>
/// How busy the mouse, the keyboard and game controllers were, for the replay window's timeline (written beside each
/// segment as its <c>.input</c>, one byte each 100 ms, as its <c>.levels</c> is). Only counts are kept, never which key,
/// which button or where: keys pressed (a key held down counts once), mouse buttons pressed, wheel notches, a
/// controller's buttons and switches pressed and how far its sticks and triggers moved, each in 10 ms slots of the
/// performance counter's clock (the one the segments are timed by), the last 3 minutes. Not the mouse's movement (the
/// user, 2026-11-14: clicks and the wheel only). Told of the input on one thread (the recorder's window: each WM_INPUT,
/// each look at the controllers) and read on another as a segment is completed: a slot read while it is being made new
/// reads as nothing, which is all it costs. Nothing is allocated as the input comes.
/// </summary>
public sealed class InputActivity
{
    private const long Slot = 100_000;
    private const int Slots = 18_000;
    private const long Bucket = 1_000_000;

    // (each 100 ms is rated over the second around it, from 450 ms before it to 550 ms after: a burst reads as busy
    // where it happened, and typing, a key every 150 ms or so, as steady rather than every other bucket)
    private const long Before = 4_500_000;
    private const long After = 5_500_000;

    private readonly long[] stamp = new long[Slots];
    private readonly int[] keys = new int[Slots];
    private readonly int[] clicks = new int[Slots];
    private readonly int[] wheel = new int[Slots];

    // a controller's sticks and triggers: how far they moved, in thousandths of an axis' whole travel
    private readonly int[] axes = new int[Slots];

    public InputActivity()
    {
        Array.Fill(stamp, -1L);
    }

    /// <summary>A key pressed (not its repeats) <paramref name="lagMs"/> ago.</summary>
    public void Key(int lagMs) => keys[At(lagMs)]++;

    /// <summary><paramref name="n"/> presses counted as keys are (a controller's buttons and switches).</summary>
    public void Presses(int n, int lagMs) => keys[At(lagMs)] += n;

    /// <summary><paramref name="n"/> mouse buttons pressed.</summary>
    public void Click(int n, int lagMs) => clicks[At(lagMs)] += n;

    /// <summary>The wheel turned by <paramref name="delta"/> (120 a notch, either way, either wheel).</summary>
    public void Wheel(int delta, int lagMs) => wheel[At(lagMs)] += Math.Abs(delta);

    /// <summary>A controller's sticks and triggers moved by <paramref name="travel"/> together (each axis' change, 1
    /// its whole travel).</summary>
    public void Axes(double travel, int lagMs) => axes[At(lagMs)] += (int)Math.Round(travel * 1000);

    private long last;

    /// <summary>When the latest input came (the performance counter's clock, 100 ns; 0 none yet).</summary>
    public long LastHns => Volatile.Read(ref last);

    /// <summary>The slot of the moment <paramref name="lagMs"/> ago, emptied first when it held older counts.</summary>
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

    /// <summary>The intensity of each 100 ms from <paramref name="startHns"/> (the counter's clock), <paramref name="count"/>
    /// of them: 0 nothing, 255 as busy as it gets (see <see cref="Intensity"/>).</summary>
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
        // (sums from the first slot, each kind; a slot not of its moment, or not come yet, as nothing)
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
            // (the second's part still to come when the segment closed left out: a rate over what there is of it)
            var upTo = (int)Math.Clamp(now + 1 - first, from + 1, to);
            var seconds = (upTo - from) * (Slot / 10_000_000.0);
            bytes[b] = Intensity((sk[upTo] - sk[from]) / seconds, (sc[upTo] - sc[from]) / seconds,
                (sw[upTo] - sw[from]) / 120.0 / seconds, (sa[upTo] - sa[from]) / 1000.0 / seconds);
        }

        return bytes;
    }

    /// <summary>
    /// Rates (a second) as one byte. The presses (keys and a controller's buttons, mouse buttons, half a wheel notch
    /// each) and a controller's sticks' and triggers' travel each on a log scale, then taken together as either being
    /// busy (1 - (1 - a)(1 - b)): typing at 6 keys a second reads 0.76, clicking 3 times a second 0.54, a game on the
    /// keyboard and mouse (5 presses a second) 0.70; a stick worked steadily (3 travels a second) 0.58, with 2 buttons
    /// a second 0.76. Anything at all is 1 at least, so a byte of 0 means none.
    /// </summary>
    public static byte Intensity(double keysPerSecond, double clicksPerSecond, double notchesPerSecond, double axesPerSecond = 0)
    {
        var presses = keysPerSecond + clicksPerSecond + notchesPerSecond * 0.5;
        if (presses <= 0 && axesPerSecond <= 0)
        {
            return 0;
        }

        // (12 presses a second: the most; 20 travels a second: both sticks and a trigger thrown end to end several
        // times a second)
        var a = Math.Min(1.0, Math.Log2(1 + presses) / Math.Log2(13));
        var b = Math.Min(1.0, Math.Log2(1 + axesPerSecond / 0.25) / Math.Log2(81));
        var any = 1 - (1 - a) * (1 - b);
        return (byte)Math.Clamp((int)Math.Round(any * 255), 1, 255);
    }
}
