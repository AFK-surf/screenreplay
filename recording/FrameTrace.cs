namespace Replay.Recording;

public static class FrameTrace
{
    private static readonly string[] lines = new string[4096];
    private static int next;
    private static readonly object gate = new();

    public static volatile bool On;

    internal static void Note(string line)
    {
        if (!On)
        {
            return;
        }

        var stamp = System.Diagnostics.Stopwatch.GetTimestamp() * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
        lock (gate)
        {
            lines[next % lines.Length] = $"{stamp:F2} {line}";
            next++;
        }
    }

    public static string[] Take()
    {
        lock (gate)
        {
            var count = Math.Min(next, lines.Length);
            var output = new string[count];
            for (var i = 0; i < count; i++)
            {
                output[i] = lines[(next - count + i) % lines.Length];
            }

            next = 0;
            return output;
        }
    }
}
