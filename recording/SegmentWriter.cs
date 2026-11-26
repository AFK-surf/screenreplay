using System.Globalization;
using System.Runtime.InteropServices;
using Vortice.MediaFoundation;

namespace Replay.Recording;

internal sealed record EncodeSettings(int Width, int Height, int FrameRate, int Bitrate, bool Hevc, bool Audio);

internal sealed class SegmentWriter : IDisposable
{
    public const string TempExtension = ".recording";
    private const int AudioRate = 48000;
    private const int LevelFrames = AudioRate / 10;

    private readonly object gate = new();
    private readonly VideoEncoder encoder;
    private readonly IMFSinkWriter writer;
    private readonly string tempPath;
    private readonly int videoStream;
    private readonly int audioStream = -1;
    private readonly int sources;
    private readonly EncodeSettings settings;
    private bool finished;
    private string stem = "";
    private string folder = "";
    private DateTimeOffset startUtc;

    private readonly List<byte> levels = new();
    private readonly double[] windowSum;
    private int windowFrames;
    private long audioWritten;

    public EncodeSettings Settings => settings;

    private readonly object thumbsGate = new();
    private int thumbsAsked;
    private readonly List<(long Ms, byte[] Jpeg)> thumbs = new();

    internal long NextThumbHns { get; set; }

    internal void ThumbAsked()
    {
        lock (thumbsGate)
        {
            thumbsAsked++;
        }
    }

    internal void ThumbMade(long ms, byte[]? jpeg)
    {
        lock (thumbsGate)
        {
            if (jpeg is not null)
            {
                thumbs.Add((ms, jpeg));
            }

            thumbsAsked--;
            Monitor.PulseAll(thumbsGate);
        }
    }

    // Binary format ("RPT2"): count, then [int64 ms, uint32 len, jpeg bytes] (read by replay_index.cpp).
    private void WriteThumbs()
    {
        List<(long Ms, byte[] Jpeg)> made;
        lock (thumbsGate)
        {
            var until = Environment.TickCount64 + 2000;
            while (thumbsAsked > 0 && Environment.TickCount64 < until)
            {
                Monitor.Wait(thumbsGate, 100);
            }

            made = thumbs.OrderBy(t => t.Ms).ToList();
            thumbs.Clear();
            thumbs.TrimExcess();
        }

        if (made.Count == 0)
        {
            return;
        }

        using var out_ = new FileStream(Path.Combine(folder, stem + ".thumbs"), FileMode.Create, FileAccess.Write, FileShare.None, 65536);
        using var w = new BinaryWriter(out_);
        w.Write("RPT2"u8);
        w.Write((uint)made.Count);
        foreach (var (ms, jpeg) in made)
        {
            w.Write(ms);
            w.Write((uint)jpeg.Length);
            w.Write(jpeg);
        }
    }

    public long Frames { get; private set; }

    private SegmentWriter(VideoEncoder encoder, IMFSinkWriter writer, string tempPath, int videoStream, int audioStream, EncodeSettings settings, int sources)
    {
        this.encoder = encoder;
        this.writer = writer;
        this.tempPath = tempPath;
        this.videoStream = videoStream;
        this.audioStream = audioStream;
        this.settings = settings;
        this.sources = Math.Max(1, sources);
        windowSum = new double[this.sources];
    }

    public static SegmentWriter Create(VideoEncoder encoder, string folder, int audioSources)
    {
        var settings = encoder.Settings;
        Directory.CreateDirectory(folder);
        var temp = Path.Combine(folder, "next-" + Guid.NewGuid().ToString("N")[..8] + TempExtension);
        using var attrs = MediaFactory.MFCreateAttributes(1);
        attrs.Set(Native.TRANSCODE_CONTAINERTYPE, Native.TranscodeContainerType_MPEG4);
        IMFSinkWriter? writer = null;
        try
        {
            writer = MediaFactory.MFCreateSinkWriterFromURL(temp, null, attrs);

            using var videoType = encoder.OutputType();
            var video = writer.AddStream(videoType);
            writer.SetInputMediaType(video, videoType, null);

            var audio = -1;
            if (settings.Audio)
            {
                using var audioOut = MediaFactory.MFCreateMediaType();
                audioOut.Set(Native.MT_MAJOR_TYPE, Native.MediaType_Audio);
                audioOut.Set(Native.MT_SUBTYPE, Native.AudioFormat_AAC);
                audioOut.Set(Native.MT_AUDIO_BITS_PER_SAMPLE, 16u);
                audioOut.Set(Native.MT_AUDIO_SAMPLES_PER_SECOND, (uint)AudioRate);
                audioOut.Set(Native.MT_AUDIO_NUM_CHANNELS, 2u);
                audioOut.Set(Native.MT_AUDIO_AVG_BYTES_PER_SECOND, 24000u);
                audioOut.Set(Native.MT_AAC_PAYLOAD_TYPE, 0u);
                audioOut.Set(Native.MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29u);
                audio = writer.AddStream(audioOut);

                using var audioIn = MediaFactory.MFCreateMediaType();
                audioIn.Set(Native.MT_MAJOR_TYPE, Native.MediaType_Audio);
                audioIn.Set(Native.MT_SUBTYPE, Native.AudioFormat_PCM);
                audioIn.Set(Native.MT_AUDIO_BITS_PER_SAMPLE, 16u);
                audioIn.Set(Native.MT_AUDIO_SAMPLES_PER_SECOND, (uint)AudioRate);
                audioIn.Set(Native.MT_AUDIO_NUM_CHANNELS, 2u);
                audioIn.Set(Native.MT_AUDIO_BLOCK_ALIGNMENT, 4u);
                audioIn.Set(Native.MT_AUDIO_AVG_BYTES_PER_SECOND, (uint)(AudioRate * 4));
                audioIn.Set(Native.MT_ALL_SAMPLES_INDEPENDENT, 1u);
                writer.SetInputMediaType(audio, audioIn, null);
            }

            writer.BeginWriting();
            return new SegmentWriter(encoder, writer, temp, video, audio, settings, audioSources);
        }
        catch
        {
            writer?.Dispose();
            TryDelete(temp);
            throw;
        }
    }

    internal static void SetPicture(IMFMediaType type, EncodeSettings settings)
    {
        type.Set(Native.MT_FRAME_SIZE, Native.Pack((uint)settings.Width, (uint)settings.Height));
        type.Set(Native.MT_FRAME_RATE, Native.Pack((uint)settings.FrameRate, 1));
        type.Set(Native.MT_PIXEL_ASPECT_RATIO, Native.Pack(1, 1));
        // MFVideoInterlace_Progressive
        type.Set(Native.MT_INTERLACE_MODE, 2u);
        // BT.709 primaries, transfer and matrix, 16-235
        type.Set(Native.MT_VIDEO_PRIMARIES, 2u);
        type.Set(Native.MT_TRANSFER_FUNCTION, 5u);
        type.Set(Native.MT_YUV_MATRIX, 1u);
        type.Set(Native.MT_VIDEO_NOMINAL_RANGE, 2u);
    }

    public void Begin(string folder, DateTimeOffset startUtc)
    {
        this.folder = folder;
        this.startUtc = startUtc;
        stem = startUtc.UtcDateTime.ToString("yyyyMMdd-HHmmss-fff", CultureInfo.InvariantCulture) + "-" + Guid.NewGuid().ToString("N")[..8];
        EncoderStart = encoder.Attach(this, startUtc);
    }

    internal long EncoderStart { get; private set; } = long.MaxValue;

    private long encoded;
    private Exception? videoFault;
    private bool encoderGone;

    public void WriteVideo(IMFSample sample, long time, long duration, bool key)
    {
        lock (gate)
        {
            if (finished)
            {
                return;
            }

            Frames++;
        }

        // Must call outside gate: encoder output callback acquires gate while this waits for encoder input.
        try
        {
            encoder.Encode(sample, EncoderStart + time, duration, key);
        }
        catch
        {
            lock (gate)
            {
                Frames--;
            }

            throw;
        }
    }

    internal void WriteEncoded(IMFSample sample)
    {
        lock (gate)
        {
            if (finished)
            {
                return;
            }

            try
            {
                writer.WriteSample(videoStream, sample);
            }
            catch (Exception ex)
            {
                videoFault ??= ex;
            }

            encoded++;
            Monitor.PulseAll(gate);
        }
    }

    internal void EncoderGone()
    {
        lock (gate)
        {
            encoderGone = true;
            Monitor.PulseAll(gate);
        }
    }

    private bool AllEncoded(int ms)
    {
        var until = Environment.TickCount64 + ms;
        lock (gate)
        {
            while (encoded < Frames && !encoderGone)
            {
                var left = until - Environment.TickCount64;
                if (left <= 0)
                {
                    return false;
                }

                Monitor.Wait(gate, (int)left);
            }

            return true;
        }
    }

    public void WriteAudio(long at, ReadOnlySpan<float> mix, IReadOnlyList<float[]> each, int offset, int frames)
    {
        if (audioStream < 0 || frames <= 0)
        {
            return;
        }

        lock (gate)
        {
            if (finished)
            {
                return;
            }

            // Fill audio gaps up to 60 s with silence so subsequent audio stays synced to video.
            if (at > audioWritten)
            {
                var gap = Math.Min(at - audioWritten, AudioRate * 60L);
                WriteSilence(gap);
                if (at > audioWritten)
                {
                    audioWritten = at;
                }
            }
            var skip = (int)Math.Max(0, audioWritten - at);
            if (skip >= frames)
            {
                return;
            }

            WritePcm(mix.Slice((offset + skip) * 2, (frames - skip) * 2), frames - skip);
            for (var k = skip; k < frames; k++)
            {
                Level(each, offset, k);
            }
        }
    }

    public void PadAudio(long until)
    {
        if (audioStream < 0)
        {
            return;
        }

        lock (gate)
        {
            if (!finished && audioWritten < until)
            {
                WriteSilence(until - audioWritten);
            }
        }
    }

    // Must hold gate. Writes 200 ms chunks directly into MF buffer memory to avoid LOH float[] allocations.
    private void WriteSilence(long frames)
    {
        while (frames > 0)
        {
            var n = (int)Math.Min(frames, AudioRate / 5);
            var bytes = n * 4;
            using var buffer = MediaFactory.MFCreateMemoryBuffer(bytes);
            buffer.Lock(out var data, out _, out _);
            unsafe
            {
                new Span<byte>((void*)data, bytes).Clear();
            }

            buffer.Unlock();
            buffer.CurrentLength = bytes;
            using var sample = MediaFactory.MFCreateSample();
            sample.AddBuffer(buffer);
            sample.SampleTime = audioWritten * 10_000_000 / AudioRate;
            sample.SampleDuration = (audioWritten + n) * 10_000_000 / AudioRate - sample.SampleTime;
            writer.WriteSample(audioStream, sample);
            audioWritten += n;
            for (var k = 0; k < n; k++)
            {
                Level(null, 0, k);
            }

            frames -= n;
        }
    }

    private void Level(IReadOnlyList<float[]>? each, int offset, int k)
    {
        if (each is not null)
        {
            for (var s = 0; s < each.Count && s < sources; s++)
            {
                var l = each[s][(offset + k) * 2];
                var r = each[s][(offset + k) * 2 + 1];
                windowSum[s] += (l * l + r * r) * 0.5;
            }
        }

        if (++windowFrames == LevelFrames)
        {
            CloseWindow();
        }
    }

    private void CloseWindow()
    {
        if (windowFrames == 0)
        {
            return;
        }

        var loudest = 0.0;
        for (var s = 0; s < sources; s++)
        {
            loudest = Math.Max(loudest, windowSum[s] / windowFrames);
            windowSum[s] = 0;
        }

        windowFrames = 0;
        levels.Add(LevelByte(Math.Sqrt(loudest)));
    }

    public static byte LevelByte(double rms)
    {
        if (rms <= 0)
        {
            return 0;
        }

        var db = 20 * Math.Log10(rms);
        return (byte)Math.Clamp(Math.Round((db + 50) / 50 * 255), 0, 255);
    }

    private void WritePcm(ReadOnlySpan<float> samples, int frames)
    {
        var bytes = frames * 4;
        using var buffer = MediaFactory.MFCreateMemoryBuffer(bytes);
        buffer.Lock(out var data, out _, out _);
        unsafe
        {
            var target = new Span<short>((void*)data, frames * 2);
            for (var i = 0; i < frames * 2; i++)
            {
                var v = samples[i];
                target[i] = (short)Math.Clamp((int)MathF.Round(v * 32767f), -32768, 32767);
            }
        }

        buffer.Unlock();
        buffer.CurrentLength = bytes;
        using var sample = MediaFactory.MFCreateSample();
        sample.AddBuffer(buffer);
        sample.SampleTime = audioWritten * 10_000_000 / AudioRate;
        sample.SampleDuration = (audioWritten + frames) * 10_000_000 / AudioRate - sample.SampleTime;
        writer.WriteSample(audioStream, sample);
        audioWritten += frames;
    }

    public static int Buckets(long durationHns) => (int)Math.Ceiling(durationHns / 10_000.0 / 100.0);

    public Segment? Finish(long durationHns, byte[]? input = null)
    {
        lock (gate)
        {
            if (finished)
            {
                return null;
            }

            if (Frames == 0)
            {
                Abort();
                return null;
            }
        }

        if (!AllEncoded(250))
        {
            encoder.Drain();
            AllEncoded(1000);
        }

        lock (gate)
        {
            if (finished)
            {
                return null;
            }

            finished = true;
            encoder.Detach(this);
            if (videoFault is not null)
            {
                writerGone = true;
                writer.Dispose();
                TryDelete(tempPath);
                throw new InvalidOperationException("the segment's video could not be written: " + videoFault.Message, videoFault);
            }

            if (audioStream >= 0)
            {
                var want = durationHns * AudioRate / 10_000_000;
                if (want > audioWritten)
                {
                    WriteSilence(Math.Min(want - audioWritten, AudioRate * 2L));
                }
            }

            writer.Finalize();
            writerGone = true;
            writer.Dispose();
        }

        CloseWindow();
        var durationMs = durationHns / 10_000.0;
        var count = Buckets(durationHns);
        while (levels.Count < count)
        {
            levels.Add(0);
        }

        if (levels.Count > count)
        {
            levels.RemoveRange(count, levels.Count - count);
        }

        var mp4 = Path.Combine(folder, stem + ".mp4");
        if (audioStream >= 0)
        {
            File.WriteAllBytes(Path.Combine(folder, stem + ".levels"), levels.ToArray());
        }

        if (input is not null)
        {
            File.WriteAllBytes(Path.Combine(folder, stem + ".input"), input);
        }

        WriteThumbs();

        var start = startUtc.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", CultureInfo.InvariantCulture);
        File.WriteAllText(Path.Combine(folder, stem + ".json"),
            $"{{\"startUtc\":\"{start}\",\"durationMs\":{durationMs.ToString("0.###", CultureInfo.InvariantCulture)},\"width\":{settings.Width},\"height\":{settings.Height},\"fps\":{settings.FrameRate}}}");
        File.Move(tempPath, mp4, overwrite: true);
        return new Segment(mp4, startUtc, startUtc + TimeSpan.FromTicks(durationHns), new FileInfo(mp4).Length, settings.Width, settings.Height, durationMs);
    }

    public void Abort()
    {
        lock (gate)
        {
            if (finished && writerGone)
            {
                return;
            }

            finished = true;
            writerGone = true;
            encoder.Detach(this);
            try
            {
                writer.Dispose();
            }
            catch (Exception)
            {
            }

            TryDelete(tempPath);
        }
    }

    private bool writerGone;

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception)
        {
        }
    }

    public void Dispose()
    {
        if (!finished)
        {
            Abort();
        }
    }
}
