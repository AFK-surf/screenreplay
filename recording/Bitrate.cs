namespace Replay.Recording;

public static class Bitrate
{
    public static int For(int width, int height, int frameRate, string quality, string codec)
    {
        var megapixels = Math.Max(2, width) * (double)Math.Max(2, height) / 1_000_000.0;
        var q = quality switch { "low" => 0.5, "medium" => 0.75, "ultra" => 1.6, _ => 1.0 };
        var c = string.Equals(codec, "HEVC", StringComparison.OrdinalIgnoreCase) ? 1.0 : 1.5;
        var bps = 3_000_000.0 * Math.Pow(megapixels, 0.8) * Math.Pow(Math.Max(1, frameRate) / 30.0, 0.6) * q * c;
        return (int)Math.Round(Math.Clamp(bps, 1_000_000.0, 150_000_000.0));
    }
}
