namespace Replay.Recording;

/// <summary>
/// The mean bitrate a recording is encoded at, from its picture, frame rate, quality and codec:
/// <code>
///   bitrate = 3 Mbps × (pixels / 1 000 000)^0.8 × (fps / 30)^0.6 × quality × codec
///   quality: low 0.5, medium 0.75, high 1, ultra 1.6        codec: HEVC 1, H.264 1.5
///   held to 1 … 150 Mbps
/// </code>
/// The exponents under 1 give a large picture fewer bits per pixel than a small one (text stays sharp on a laptop's
/// screen at a modest rate, a 4K screen does not need four times 1080p's), and a doubled frame rate about half again as
/// many (consecutive frames of a screen differ little). At high quality, HEVC: 1080p30 5.4 Mbps, 1440p60 12.9 Mbps,
/// 4K30 16.3 Mbps, 4K60 24.7 Mbps; H.264 1.5 times those. The replay window's Settings computes the same
/// (app/settings_data.mbt, planned_bitrate) for its estimate of the disk a recording takes.
/// </summary>
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
