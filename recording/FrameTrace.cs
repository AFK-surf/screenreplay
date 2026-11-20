namespace Replay.Recording;

/// <summary>
/// What happened to the last few thousand frames, kept in memory only, for a diagnosis asked for by hand (the app's
/// capture-diag.request): each frame the capture handed over (its composition time, the capture's surface), each frame
/// encoded (the texture and slice the picture was converted into, its time). Nothing of the picture itself.
/// </summary>
public static class FrameTrace
{
    private static readonly string[] lines = new string[4096];
    private static int next;
    private static readonly object gate = new();

    /// <summary>Whether frames are traced (off unless asked: the app turns it on for a diagnosis).</summary>
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

    /// <summary>The lines noted, oldest first, and the trace emptied.</summary>
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
