using System.Buffers.Binary;

namespace Replay.Recording;

// Maps HIDP_BUTTON_CAPS / HIDP_VALUE_CAPS (72 B) and HIDP_DATA (8 B), ignoring vendor pages (e.g. DualSense IMU/timestamps).
public sealed class HidLayout
{
    private const int CapsSize = 72;
    private const byte None = 0, Button = 1, Axis = 2, Hat = 3;

    private readonly byte[] kind;
    private readonly int[] slot;
    private readonly byte[] report;
    private readonly int[] min;
    private readonly int[] max;
    private readonly byte[] bits;

    public ControllerCounter Counter { get; }

    public bool UsesReportIds { get; }

    private HidLayout(int indices, int buttons, int axes, int hats, bool ids)
    {
        kind = new byte[indices];
        slot = new int[indices];
        report = new byte[indices];
        min = new int[indices];
        max = new int[indices];
        bits = new byte[indices];
        Counter = new ControllerCounter(buttons, hats, axes);
        UsesReportIds = ids;
    }

    public static HidLayout? From(ReadOnlySpan<byte> buttonCaps, ReadOnlySpan<byte> valueCaps)
    {
        int indices = 0, buttons = 0, axes = 0, hats = 0;
        var ids = false;
        for (var pass = 0; pass < 2; pass++)
        {
            HidLayout? layout = pass == 1 ? new HidLayout(indices, buttons, axes, hats, ids) : null;
            int b = 0, a = 0, h = 0;
            for (var c = 0; c + CapsSize <= buttonCaps.Length; c += CapsSize)
            {
                var cap = buttonCaps.Slice(c, CapsSize);
                if (U16(cap, 0) != 0x09)
                {
                    continue;
                }

                var (di0, di1) = DataIndices(cap);
                for (var di = di0; di <= di1; di++)
                {
                    if (layout is null)
                    {
                        indices = Math.Max(indices, di + 1);
                        buttons++;
                        ids |= cap[2] != 0;
                    }
                    else
                    {
                        layout.Set(di, Button, b++, cap[2], 0, 0, 0);
                    }
                }
            }

            for (var c = 0; c + CapsSize <= valueCaps.Length; c += CapsSize)
            {
                var cap = valueCaps.Slice(c, CapsSize);
                var page = U16(cap, 0);
                var (di0, di1) = DataIndices(cap);
                var usage0 = U16(cap, 56);
                for (var di = di0; di <= di1; di++)
                {
                    var usage = cap[12] != 0 ? usage0 + (di - di0) : usage0;
                    var what = page == 0x01 && usage is >= 0x30 and <= 0x38 ? Axis
                        : page == 0x02 && usage is 0xC4 or 0xC5 ? Axis
                        : page == 0x01 && usage == 0x39 ? Hat
                        : None;
                    if (what == None)
                    {
                        continue;
                    }

                    if (layout is null)
                    {
                        indices = Math.Max(indices, di + 1);
                        _ = what == Axis ? axes++ : hats++;
                        ids |= cap[2] != 0;
                    }
                    else
                    {
                        layout.Set(di, what, what == Axis ? a++ : h++, cap[2], I32(cap, 40), I32(cap, 44), U16(cap, 18));
                    }
                }
            }

            if (layout is not null)
            {
                return layout;
            }

            if (buttons + axes + hats == 0)
            {
                return null;
            }
        }

        return null;
    }

    private void Set(int di, byte what, int at, byte reportId, int lo, int hi, int bitSize)
    {
        kind[di] = what;
        slot[di] = at;
        report[di] = reportId;
        min[di] = lo;
        max[di] = hi;
        bits[di] = (byte)Math.Clamp(bitSize, 0, 32);
    }

    private static (int, int) DataIndices(ReadOnlySpan<byte> cap) =>
        cap[12] != 0 ? (U16(cap, 68), U16(cap, 70)) : (U16(cap, 68), U16(cap, 68));

    private static int U16(ReadOnlySpan<byte> s, int at) => BinaryPrimitives.ReadUInt16LittleEndian(s[at..]);

    private static int I32(ReadOnlySpan<byte> s, int at) => BinaryPrimitives.ReadInt32LittleEndian(s[at..]);

    public void Apply(byte reportId, ReadOnlySpan<byte> data, int count)
    {
        var c = Counter;
        for (var di = 0; di < kind.Length; di++)
        {
            if (kind[di] == Button && (!UsesReportIds || report[di] == reportId))
            {
                c.Buttons[slot[di]] = false;
            }
        }

        for (var i = 0; i < count && (i + 1) * 8 <= data.Length; i++)
        {
            var di = U16(data, i * 8);
            if (di >= kind.Length)
            {
                continue;
            }

            var raw = BinaryPrimitives.ReadUInt32LittleEndian(data[(i * 8 + 4)..]);
            switch (kind[di])
            {
                case Button:
                    c.Buttons[slot[di]] = true;
                    break;
                case Axis:
                    c.Axes[slot[di]] = Normal(di, raw);
                    break;
                case Hat:
                    var v = Value(di, raw);
                    c.Switches[slot[di]] = v < min[di] || v > max[di] ? 0 : (int)(v - min[di]) + 1;
                    break;
            }
        }
    }

    private long Value(int di, uint raw)
    {
        var n = bits[di];
        if (min[di] < 0 && n is > 0 and < 32 && (raw & (1u << (n - 1))) != 0)
        {
            return (long)raw - (1L << n);
        }

        return min[di] < 0 && n == 32 ? (int)raw : raw;
    }

    private double Normal(int di, uint raw)
    {
        long lo = min[di], hi = max[di];
        if (hi <= lo)
        {
            lo = 0;
            hi = bits[di] is > 0 and < 32 ? (1L << bits[di]) - 1 : uint.MaxValue;
        }

        return Math.Clamp((Value(di, raw) - lo) / (double)(hi - lo), 0, 1);
    }
}
