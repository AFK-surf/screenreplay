using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.MediaFoundation;

namespace Replay.Recording;

/// <summary>How a recorder records.</summary>
/// <param name="Folder">Where its segments go.</param>
/// <param name="Keep">How long segments are kept (older ones deleted as each new one is closed).</param>
/// <param name="FrameRate">30 or 60: the most frames a second (fewer, none, while the screen changes less).</param>
/// <param name="MaxHeight">The picture brought down to this height at most (0: the source's own).</param>
/// <param name="Codec">"HEVC" (H.264 where it cannot be made) or "H264".</param>
/// <param name="Quality">low, medium, high or ultra (see <see cref="Bitrate"/>).</param>
public sealed record RecorderOptions(string Folder, TimeSpan Keep, int FrameRate, int MaxHeight, string Codec, string Quality)
{
    public TimeSpan SegmentLength { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>The default playback device's sound (for a window's recording: only that window's process's sound).</summary>
    public bool SystemAudio { get; init; } = true;

    /// <summary>The default microphone, mixed in (never for a window's recording).</summary>
    public bool Microphone { get; init; }

    /// <summary>How busy the mouse, the keyboard and game controllers were: each segment's <c>.input</c> written of it (none: no file).</summary>
    public InputActivity? Activity { get; init; }

    /// <summary>Tests only: frames taken as FP16 and made SDR as on an HDR desktop, whatever the display is.</summary>
    public bool ForceHdr { get; init; }
}

/// <summary>Something the recorder reports: its level ("info", "warning", "error"), a code and words.</summary>
public sealed record RecorderEvent(string Level, string Code, string Message);

/// <summary>
/// Records a monitor or a window into the buffer's folder as segments of <see cref="RecorderOptions.SegmentLength"/>,
/// each an MP4 of its own starting on a keyframe, the end of one the start of the next.
/// <para>A clock thread looks at each tick of the frame rate whether a new picture was captured (one comes only when the
/// screen changed) and, if so, converts and scales it on the GPU and hands it to the hardware encoder, stamped with
/// the moment it was composed (a variable frame rate, capped at the one asked for: a still screen writes nothing);
/// an audio thread reads the sound's sources, mixes them on the same timeline (<see cref="AudioMixer"/>) and writes
/// the mix into the segment its moment belongs to. A segment is closed once its sound is all in; the next one's
/// writer is made ahead, so the switch takes no time.</para>
/// <para>A source thread looks every 2 s and on a display change whether the display is in HDR, which the capture is
/// taken in (FP16 while it is). When that changes it starts the new capture
/// beside the one in use and hands it to the clock once its first frame is in, which takes it from its next tick on
/// (the old one let go then): the encoder and the segment go on, the picture fitted into the same size, with no gap.</para>
/// </summary>
public sealed class ScreenRecorder : IAsyncDisposable
{
    private const int MF_E_SAMPLEALLOCATOR_EMPTY = unchecked((int)0xC00D4A3E);

    private RecorderOptions options;
    private readonly Action<RecorderEvent> report;
    private readonly object segmentsGate = new();
    private readonly List<Open> segments = new();
    private readonly List<Task> closing = new();

    private Gpu? gpu;
    /// <summary>The capture the clock encodes from (changed only by the clock's thread).</summary>
    private ScreenCapture? capture;

    /// <summary>A capture the source thread has ready for the clock to take in the current one's stead.</summary>
    private ScreenCapture? ready;

    private Thread? sourceThread;
    private volatile bool displayChanged;
    private FrameConverter? converter;
    private Thumbnailer? thumbnailer;
    private IMFVideoSampleAllocatorEx? allocator;
    private Thread? clockThread;
    private Thread? audioThread;
    private volatile bool stopAsked;
    private volatile bool videoDone;
    private TaskCompletionSource? flushAsked;
    private TaskCompletionSource? stopped;
    private EncodeSettings? encode;
    private int audioSources;
    private long t0;
    private long qpcAtUtc;
    private DateTimeOffset utcAtQpc;

    /// <summary>A segment being written or waiting for the rest of its sound.</summary>
    private sealed class Open
    {
        public required SegmentWriter Writer;
        public long StartHns;
        public long AudioStart;
        public long AudioEnd = long.MaxValue;
        public long DurationHns;
        public long ClosedAt;
        public TaskCompletionSource? Flushed;
    }

    public ScreenRecorder(RecorderOptions options, Action<RecorderEvent>? report = null)
    {
        this.options = options;
        this.report = report ?? (_ => { });
        Store = new SegmentStore(options.Folder);
    }

    public SegmentStore Store { get; }

    public bool IsRunning { get; private set; }

    public CaptureTarget? Target { get; private set; }

    /// <summary>The recording's picture size (null before it first started).</summary>
    public VideoSize? OutputSize { get; private set; }

    /// <summary>The codec it records with: "HEVC" or "H264" ("" before it first started).</summary>
    public string ActualCodec { get; private set; } = "";

    /// <summary>HEVC was asked for and could not be made: H.264 instead.</summary>
    public bool FellBack { get; private set; }

    /// <summary>The frame rate asked for (90 or 120) the encoder would not take: recording at 60 instead.</summary>
    public bool FrameRateFellBack { get; private set; }

    /// <summary>The frame rate it records at (60 where 90 or 120 was asked and refused).</summary>
    public int ActualFrameRate => options.FrameRate;

    public int ActualBitrate { get; private set; }

    /// <summary>Of the last 10 s: the frames encoded and those left out because the encoder was still busy (it fell
    /// behind), (0, 0) before the first 10 s.</summary>
    public (int Encoded, int Skipped) Pace { get; private set; }

    /// <summary>Recording stopped by itself on an error (it may be started again).</summary>
    public event EventHandler<Exception>? Faulted;

    /// <summary>HEVC could not be made; recording goes on in H.264.</summary>
    public event EventHandler<Exception>? CodecFallback;

    /// <summary>A segment was completed and is in the folder.</summary>
    public event EventHandler<Segment>? SegmentClosed;

    private void Report(string level, string code, string message)
    {
        try
        {
            report(new RecorderEvent(level, code, message));
        }
        catch (Exception)
        {
        }
    }

    public Task StartAsync(CaptureTarget target, CancellationToken cancel = default)
    {
        if (IsRunning)
        {
            return Task.CompletedTask;
        }

        return Task.Run(() =>
        {
            try
            {
                StartCore(target);
            }
            catch
            {
                TearDown();
                throw;
            }
        }, cancel);
    }

    private void StartCore(CaptureTarget target)
    {
        Store.DeleteUnfinished();
        Target = target;
        stopAsked = false;
        videoDone = false;
        gpu = new Gpu();
        var display = DisplayColor.Of(MonitorOf(target));
        Report("info", "display.color", Describe(display));
        capture = MakeCapture(target, display);
        capture.Start();
        if (!capture.FirstFrame.Wait(TimeSpan.FromSeconds(5)))
        {
            throw new TimeoutException("no picture came from the capture in 5 s");
        }

        var size = VideoSize.Fit(capture.Width, capture.Height, options.MaxHeight);
        OutputSize = size;
        audioSources = target.IsWindow ? (options.SystemAudio ? 1 : 0) : (options.SystemAudio ? 1 : 0) + (options.Microphone ? 1 : 0);
        var hevc = string.Equals(options.Codec, "HEVC", StringComparison.OrdinalIgnoreCase) && !FellBack;
        SegmentWriter first;
        try
        {
            first = MakeWriter(size, hevc);
        }
        catch (Exception ex) when (options.FrameRate > 60)
        {
            // (90 or 120 frames a second the encoder refuses at this size, an older GPU's: 60, and that said)
            Report("warning", "video.frameRateUnavailable", $"{options.FrameRate} fps could not be encoded: " + ex.Message);
            FrameRateFellBack = true;
            options = options with { FrameRate = 60 };
            try
            {
                first = MakeWriter(size, hevc);
            }
            catch (Exception ex2) when (hevc)
            {
                FellBack = true;
                Report("warning", "video.hevcUnavailable", "HEVC encoder could not be made: " + ex2.Message);
                CodecFallback?.Invoke(this, ex2);
                first = MakeWriter(size, false);
            }
        }
        catch (Exception ex) when (hevc)
        {
            FellBack = true;
            Report("warning", "video.hevcUnavailable", "HEVC encoder could not be made: " + ex.Message);
            CodecFallback?.Invoke(this, ex);
            first = MakeWriter(size, false);
        }

        ActualCodec = first.Settings.Hevc ? "HEVC" : "H264";
        ActualBitrate = first.Settings.Bitrate;
        encode = first.Settings;
        converter = new FrameConverter(gpu, size.Width, size.Height, options.FrameRate);
        try
        {
            thumbnailer = new Thumbnailer(gpu, size.Width, size.Height, options.FrameRate);
        }
        catch (Exception ex)
        {
            // (no thumbnails of its own: the replay window makes them from the segments' key frames, as before)
            Report("warning", "thumbnails.unavailable", ex.Message);
        }

        allocator = MakeAllocator(gpu, size);

        stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        IsRunning = true;
        utcAtQpc = DateTimeOffset.UtcNow;
        qpcAtUtc = Native.NowHns();
        clockThread = new Thread(() => ClockLoop(first)) { IsBackground = true, Name = "recorder clock", Priority = ThreadPriority.Highest };
        clockThread.Start();
        sourceThread = new Thread(SourceLoop) { IsBackground = true, Name = "recorder source" };
        sourceThread.Start();
        Report("info", "recorder.started", $"{ActualCodec} {size.Width}x{size.Height} {options.FrameRate} fps {ActualBitrate / 1000} kbps, {audioSources} sound source(s)");
    }

    private Exception? faultOnStop;

    private static IntPtr MonitorOf(CaptureTarget target) => target.IsWindow ? WindowShown.MonitorOf(target.Window) : target.Monitor;

    private string Describe(DisplayColor display)
        => (display.Hdr ? $"HDR, SDR white {display.SdrWhiteNits:0} nits, peak {display.PeakNits:0} nits" : "SDR")
           + (options.ForceHdr && !display.Hdr ? " (FP16 capture forced)" : "");

    /// <summary>A capture of <paramref name="target"/> (FP16 on an HDR display), which stops the recording when it is
    /// gone.</summary>
    private ScreenCapture MakeCapture(CaptureTarget target, DisplayColor display)
    {
        var made = new ScreenCapture(gpu!, target, options.FrameRate, display.Hdr || options.ForceHdr, display);
        if (target == Target)
        {
            made.Closed += () =>
            {
                Report("warning", "capture.closed", "the captured " + (target.IsWindow ? "window" : "monitor") + " is gone");
                stopAsked = true;
                faultOnStop = new InvalidOperationException("the capture target closed");
            };
        }

        return made;
    }

    /// <summary>The display's settings changed (WM_DISPLAYCHANGE): its HDR looked at again at once, not at the next 2 s.</summary>
    public void DisplayChanged() => displayChanged = true;

    private volatile string? renewAsked;
    private long changedAt;

    /// <summary>A new capture started beside the one in use (the screen woke: a capture made before the screen went
    /// off gave no new frame after it came on, 2026-11-21, ten minutes of a still picture over the apps in use).</summary>
    public void RenewCapture(string why) => renewAsked = why;

    /// <summary>Something on the screen surely changed (another window came to the front): the capture is expected to
    /// give a frame soon after.</summary>
    public void ScreenChanged() => Volatile.Write(ref changedAt, Native.NowHns());

    /// <summary>
    /// Whether the display is in HDR, looked at every 2 s and on a display change: the capture taken as FP16 while it
    /// is. When that changes a new capture is started beside the one in use and handed to the clock once its first
    /// frame is in; one that gives none in 1.5 s is dropped and tried again at the next look.
    /// </summary>
    private void SourceLoop()
    {
        const long GiveUp = 15_000_000, DisplayEvery = 20_000_000;
        try
        {
            var primary = Target!;
            var monitor = MonitorOf(primary);
            var display = capture!.Display;
            var lastDisplay = Native.NowHns();
            var intendedHdr = capture.Hdr;
            // (the capture last handed to the clock)
            var published = capture;
            ScreenCapture? pending = null;
            long pendingSince = 0;
            // (the capture's newest frame as last seen, and when it came; a new capture made at most each 30 s for a
            // stall: input or another window in front 2 s ago and still no frame since)
            const long Stall = 20_000_000, RenewEvery = 300_000_000;
            long lastFrames = published.Frames, lastFrameAt = Native.NowHns(), lastRenew = long.MinValue / 2;
            var stallTest = Environment.GetEnvironmentVariable("REPLAY_TEST_STALL") is not null;
            try
            {
                while (!stopAsked)
                {
                    Thread.Sleep(100);
                    var now = Native.NowHns();
                    if (published.Frames != lastFrames)
                    {
                        lastFrames = published.Frames;
                        lastFrameAt = now;
                    }

                    string? renew = null;
                    if (renewAsked is { } asked && DisplayMemory.Trusted)
                    {
                        renewAsked = null;
                        renew = asked;
                    }
                    else if (now - lastRenew >= RenewEvery && (!primary.IsWindow || stallTest))
                    {
                        // (a monitor only: input and the window in front say nothing of whether a window recorded
                        // changed; tests only: REPLAY_TEST_STALL, the screen taken as changing all the time)
                        var poked = stallTest ? now - Stall : Math.Max(options.Activity?.LastHns ?? 0, Volatile.Read(ref changedAt));
                        if (poked > lastFrameAt && now - poked >= Stall)
                        {
                            renew = $"no new frame in {(now - lastFrameAt) / 10_000_000} s though the input or the window in front changed {(now - poked) / 10_000_000} s ago";
                        }
                    }

                    var look = displayChanged || now - lastDisplay >= DisplayEvery;
                    if (look)
                    {
                        displayChanged = false;
                        lastDisplay = now;
                        var looked = DisplayColor.Of(monitor);
                        if (looked != display)
                        {
                            display = looked;
                            Report("info", "display.color", Describe(display));
                            published.Display = display;
                        }
                    }

                    var hdr = display.Hdr || options.ForceHdr;
                    if (pending is not null && pending.Hdr != hdr)
                    {
                        pending.Dispose();
                        pending = null;
                    }

                    if (pending is not null)
                    {
                        if (pending.FirstFrame.IsSet)
                        {
                            Interlocked.Exchange(ref ready, pending)?.Dispose();
                            intendedHdr = pending.Hdr;
                            published = pending;
                            lastFrames = published.Frames;
                            lastFrameAt = now;
                            Report("info", "capture.source",$"{pending.Width}x{pending.Height}" + (pending.Hdr ? " FP16" : "") + $", after {(now - pendingSince) / 10_000} ms");
                            pending = null;
                        }
                        else if (now - pendingSince > GiveUp)
                        {
                            Report("warning", "capture.sourceFailed", "no picture in 1.5 s from the new capture: the one in use kept");
                            pending.Dispose();
                            pending = null;
                        }
                    }

                    if (pending is null && renew is not null)
                    {
                        lastRenew = now;
                        Report("info", "capture.renew", renew);
                    }

                    if (pending is null && ((hdr != intendedHdr && look) || renew is not null))
                    {
                        try
                        {
                            pending = MakeCapture(primary, display);
                            pendingSince = now;
                            pending.Start();
                        }
                        catch (Exception ex)
                        {
                            pending?.Dispose();
                            pending = null;
                            Report("warning", "capture.closed", "the recording's target cannot be captured again: " + ex.Message);
                            faultOnStop = ex;
                            stopAsked = true;
                        }
                    }
                }
            }
            finally
            {
                pending?.Dispose();
            }
        }
        catch (Exception ex)
        {
            Report("error", "capture.sourceLoop", ex.ToString());
        }
    }

    /// <summary>The recording's one encoder (made with its first segment's writer, kept till it stops).</summary>
    private VideoEncoder? encoder;

    private SegmentWriter MakeWriter(VideoSize size, bool hevc)
    {
        var bitrate = Bitrate.For(size.Width, size.Height, options.FrameRate, options.Quality, hevc ? "HEVC" : "H264");
        var settings = new EncodeSettings(size.Width, size.Height, options.FrameRate, bitrate, hevc, audioSources > 0);
        if (encoder is not null && encoder.Settings != settings)
        {
            encoder.Dispose();
            encoder = null;
        }

        encoder ??= VideoEncoder.Create(gpu!, settings);
        return SegmentWriter.Create(encoder, options.Folder, audioSources);
    }

    private static IMFVideoSampleAllocatorEx MakeAllocator(Gpu gpu, VideoSize size)
    {
        var allocator = new IMFVideoSampleAllocatorEx(MediaFactory.MFCreateVideoSampleAllocatorEx(typeof(IMFVideoSampleAllocatorEx).GUID));
        allocator.SetDirectXManager(gpu.Manager);
        using var attrs = MediaFactory.MFCreateAttributes(1);
        // D3D11_BIND_RENDER_TARGET: the video processor writes into them
        attrs.Set(Native.SA_D3D11_BINDFLAGS, 0x20u);
        using var type = MediaFactory.MFCreateMediaType();
        type.Set(Native.MT_MAJOR_TYPE, Native.MediaType_Video);
        type.Set(Native.MT_SUBTYPE, Native.VideoFormat_NV12);
        type.Set(Native.MT_FRAME_SIZE, Native.Pack((uint)size.Width, (uint)size.Height));
        type.Set(Native.MT_INTERLACE_MODE, 2u);
        type.Set(Native.MT_PIXEL_ASPECT_RATIO, Native.Pack(1, 1));
        allocator.InitializeSampleAllocatorEx(4, 24, attrs, type);
        return allocator;
    }

    /// <summary>The shortest time between two frames: the frame rate asked for, as a cap.</summary>
    private long Period => (long)Math.Round(10_000_000.0 / options.FrameRate);

    /// <summary>Where moment <paramref name="hns"/> is on the sound's timeline (48 kHz frames from the start).</summary>
    private long AudioFrameOf(long hns) => (long)Math.Round((hns - t0) * (double)AudioMixer.Rate / 10_000_000.0);

    private DateTimeOffset UtcOf(long hns) => utcAtQpc + TimeSpan.FromTicks(hns - qpcAtUtc);

    /// <summary>
    /// The picture's clock: at most once a period it looks whether the capture has a new frame (Windows.Graphics.Capture
    /// gives one only when something on the screen changed) and encodes it, stamped with the moment it was composed;
    /// while nothing changes nothing is written. A segment is a stretch of time: it ends at its length (or at a flush)
    /// whatever was drawn, and the next begins there with the picture as it is then, a keyframe at its 0. Within a
    /// segment a frame is a keyframe when 2 s have passed since the last one and either 30 frames came since (the
    /// screen moving, at 15 fps or more: one every 2 s) or the screen was still for 2 s before it. A screen that changes
    /// only a little now and then (a caret blinking, a clock's seconds) so gets none but its segment's first: a 4K
    /// keyframe is some 200 KB, the frames between it a few KB.
    /// </summary>
    private void ClockLoop(SegmentWriter first)
    {
        var mmcssTask = 0u;
        var mmcss = Native.AvSetMmThreadCharacteristics("Capture", ref mmcssTask);
        // CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS
        var timer = Native.CreateWaitableTimerEx(IntPtr.Zero, IntPtr.Zero, 0x2, 0x1F0003);
        Exception? fault = null;
        Open? current = null;
        Task<SegmentWriter>? next = null;
        var length = options.SegmentLength.Ticks;
        const long KeyEvery = 20_000_000;
        // (2 s at 15 fps: a screen that moves at least that much is moving; video at 24-60 fps among it)
        const long KeyFrames = 30;
        long segmentStart = 0, lastTime = 0, lastKey = 0, seen = 0, sinceKey = 0;
        const long PaceEvery = 100_000_000;
        long paceStart = 0;
        // (an encoder that keeps up is waited for up to 4 frames' time before a frame is left out: one frame now and then
        // takes it longer than a frame's time, a 4K keyframe (each segment's first, every 2 s of a moving screen), the
        // GPU waking from idle; an RTX 5080 so lost 1 frame in 30 s at a whole frame's wait, 1 or 2 in 10 s at half.
        // Late twice running is it falling behind)
        const long Patience = 4;
        var late = false;
        // whether the encoder takes a frame in now: within a frame's time (it keeps up); else, the frame before taken
        // in on time, within 4 frames' (late once: a keyframe, the GPU waking); late twice running, it falls behind
        bool Ready(VideoEncoder encoder)
        {
            if (encoder.ReadyWithin(TimeSpan.FromTicks(Period)))
            {
                late = false;
                return true;
            }

            if (late)
            {
                return false;
            }

            late = true;
            return encoder.ReadyWithin(TimeSpan.FromTicks(Period * (Patience - 1)));
        }
        int encoded = 0, skipped = 0;
        try
        {
            t0 = Native.NowHns();
            segmentStart = t0;
            current = Begin(first, t0);
            seen = capture!.Frames;
            EncodeFrame(current.Writer, 0, true);
            if (audioSources > 0)
            {
                audioThread = new Thread(AudioLoop) { IsBackground = true, Name = "recorder sound", Priority = ThreadPriority.AboveNormal };
                audioThread.Start();
            }

            next = Task.Run(() => MakeWriter(OutputSize!.Value, encode!.Hevc));
            var tick = t0;
            paceStart = t0;
            while (!stopAsked)
            {
                tick += Period;
                var now = Native.NowHns();
                if (tick < now - Period)
                {
                    // (the clock fell behind (the computer stalled): on from now, not a run of ticks to catch up)
                    tick = now;
                }

                Wait(timer, tick);
                if (stopAsked)
                {
                    break;
                }

                if (Interlocked.Exchange(ref ready, null) is { } swapped)
                {
                    // another capture (HDR on or off): its picture from now on,
                    // the first of it at this tick
                    var old = capture;
                    capture = swapped;
                    old?.Dispose();
                    seen = -1;
                }

                now = Native.NowHns();
                var flush = Interlocked.Exchange(ref flushAsked, null);
                if (now >= segmentStart + length || flush is not null)
                {
                    // the boundary: the segment's length, or now for a flush; where the clock stalled for longer than a
                    // segment, the next one starts now, the stretch between a gap like any other
                    var boundary = flush is null ? segmentStart + length : now;
                    var writer = next.GetAwaiter().GetResult();
                    Close(current, boundary - segmentStart, AudioFrameOf(boundary), flush);
                    if (now - boundary > length)
                    {
                        boundary = now;
                    }

                    segmentStart = boundary;
                    current = Begin(writer, boundary);
                    seen = capture.Frames;
                    EncodeFrame(current.Writer, 0, true);
                    lastTime = lastKey = sinceKey = 0;
                    next = Task.Run(() => MakeWriter(OutputSize!.Value, encode!.Hevc));
                }
                else if (capture.Frames != seen && !Ready(encoder!))
                {
                    // the encoder still busy with the frames it has (a GPU too slow for this size and rate, or its
                    // video engine shared with a video being played): this tick's frame left out, not waited for, so
                    // the clock keeps time and the encoder is given no more than it can do; the next tick takes the
                    // newest picture (seen left as it is)
                    skipped++;
                }
                else if (capture.Frames != seen)
                {
                    encoded++;
                    seen = capture.Frames;
                    // its own moment (when it was composed), after the frame before it and not after now
                    var at = Math.Clamp(capture.LatestTime - segmentStart, lastTime + 10_000, Math.Max(lastTime + 10_000, now - segmentStart));
                    var key = at - lastKey >= KeyEvery && (sinceKey >= KeyFrames || at - lastTime >= KeyEvery);
                    EncodeFrame(current.Writer, at, key);
                    lastTime = at;
                    sinceKey = key ? 0 : sinceKey + 1;
                    if (key)
                    {
                        lastKey = at;
                    }
                }

                if (now - paceStart >= PaceEvery)
                {
                    // (said as it starts and as it ends, not every 10 s it lasts)
                    if ((skipped > 0) != (Pace.Skipped > 0))
                    {
                        Report("info", "video.behind", skipped > 0
                            ? $"the encoder fell behind: {skipped} of {encoded + skipped} frames left out in {(now - paceStart) / 10_000_000.0:0.#} s"
                            : "the encoder keeps up again");
                    }

                    Pace = (encoded, skipped);

                    encoded = skipped = 0;
                    paceStart = now;
                }

                CloseDue(now);
            }

            var end = Native.NowHns();
            Close(current, end - segmentStart, AudioFrameOf(end), Interlocked.Exchange(ref flushAsked, null));
            current = null;
        }
        catch (Exception ex)
        {
            fault = ex;
            Report("error", "video.failed", ex.ToString());
            if (current is not null)
            {
                // (what was written of it kept where it can be)
                try
                {
                    var end = Native.NowHns();
                    Close(current, end - segmentStart, AudioFrameOf(end), null);
                }
                catch (Exception)
                {
                }
            }
        }
        finally
        {
            // (the last thumbnails' read-backs taken here, on the thread that began them, before the segments are
            // completed)
            try
            {
                thumbnailer?.Collect(all: true);
            }
            catch (Exception)
            {
            }

            videoDone = true;
            Native.CloseHandle(timer);
            if (mmcss != IntPtr.Zero)
            {
                Native.AvRevertMmThreadCharacteristics(mmcss);
            }

            if (next is not null)
            {
                next.ContinueWith(t =>
                {
                    if (t.IsCompletedSuccessfully)
                    {
                        t.Result.Abort();
                    }
                });
            }
        }

        // the sound's thread finishes the segments still open, then everything is let go
        audioThread?.Join(TimeSpan.FromSeconds(5));
        // (the source thread stopped too, where the clock ended on an error)
        stopAsked = true;
        sourceThread?.Join(TimeSpan.FromSeconds(5));
        CloseDue(long.MaxValue);
        Task[] waiting;
        lock (segmentsGate)
        {
            waiting = closing.ToArray();
        }

        try
        {
            Task.WaitAll(waiting, TimeSpan.FromSeconds(10));
        }
        catch (Exception)
        {
        }

        fault ??= faultOnStop;
        faultOnStop = null;
        TearDown();
        Report("info", "recorder.stopped", fault is null ? "stopped" : "stopped on an error");
        IsRunning = false;
        stopped?.TrySetResult();
        if (fault is not null && !stopRequestedByCaller)
        {
            Faulted?.Invoke(this, fault);
        }
    }

    private volatile bool stopRequestedByCaller;

    private static void Wait(IntPtr timer, long dueHns)
    {
        var left = dueHns - Native.NowHns();
        if (left <= 0)
        {
            return;
        }

        if (timer != IntPtr.Zero)
        {
            var relative = -left;
            Native.SetWaitableTimer(timer, in relative, 0, IntPtr.Zero, IntPtr.Zero, false);
            Native.WaitForSingleObject(timer, 1000);
        }
        else
        {
            Thread.Sleep(TimeSpan.FromTicks(left));
        }
    }

    private Open Begin(SegmentWriter writer, long startHns)
    {
        writer.Begin(options.Folder, UtcOf(startHns));
        var open = new Open { Writer = writer, StartHns = startHns, AudioStart = AudioFrameOf(startHns) };
        lock (segmentsGate)
        {
            segments.Add(open);
        }

        return open;
    }

    /// <summary>The segment ends <paramref name="durationHns"/> after its start; it is completed once the sound up to
    /// <paramref name="audioEnd"/> is in it.</summary>
    private void Close(Open open, long durationHns, long audioEnd, TaskCompletionSource? flushed)
    {
        lock (segmentsGate)
        {
            open.DurationHns = durationHns;
            open.AudioEnd = audioEnd;
            open.ClosedAt = Native.NowHns();
            open.Flushed = flushed;
        }
    }

    /// <summary>The closed segments whose sound is all in (or that waited too long for it) completed, each on a task.</summary>
    private void CloseDue(long nowHns)
    {
        lock (segmentsGate)
        {
            for (var i = 0; i < segments.Count; i++)
            {
                var open = segments[i];
                if (open.AudioEnd == long.MaxValue)
                {
                    continue;
                }

                var soundIn = audioSources == 0 || (mixer is { } m && m.Emitted >= open.AudioEnd) || nowHns - open.ClosedAt > 30_000_000 || videoDone && audioThread is null;
                if (!soundIn)
                {
                    continue;
                }

                if (audioSources > 0 && (mixer?.Emitted ?? 0) < open.AudioEnd)
                {
                    // (the sound's thread held up (a system device going away as the screen turned off blocked it a
                    // minute, 2026-11-21): the rest of its sound silence, not a track 20 s shorter than its picture)
                    try
                    {
                        open.Writer.PadAudio(open.AudioEnd - open.AudioStart);
                        Report("info", "audio.padded", $"the sound was {(open.AudioEnd - Math.Max(open.AudioStart, mixer?.Emitted ?? 0)) / AudioMixer.Rate} s late: silence in its place");
                    }
                    catch (Exception ex)
                    {
                        Report("warning", "audio.writeFailed", ex.Message);
                    }
                }

                segments.RemoveAt(i--);
                closing.RemoveAll(t => t.IsCompleted);
                closing.Add(Task.Run(() => Complete(open)));
            }
        }
    }

    private void Complete(Open open)
    {
        try
        {
            // (the input's activity over the segment's time, each of its 100 ms as its levels are)
            var input = options.Activity?.Read(open.StartHns, SegmentWriter.Buckets(open.DurationHns));
            var segment = open.Writer.Finish(open.DurationHns, input);
            if (segment is not null)
            {
                SegmentClosed?.Invoke(this, segment);
            }

            Store.Prune(DateTimeOffset.UtcNow - options.Keep);
        }
        catch (Exception ex)
        {
            Report("error", "segment.failed", ex.ToString());
            open.Writer.Abort();
        }
        finally
        {
            open.Flushed?.TrySetResult();
        }
    }

    private unsafe void EncodeFrame(SegmentWriter writer, long time, bool key)
    {
        IMFSample? sample = null;
        for (var tries = 0; sample is null; tries++)
        {
            try
            {
                sample = allocator!.AllocateSample();
            }
            catch (SharpGen.Runtime.SharpGenException ex) when (ex.HResult == MF_E_SAMPLEALLOCATOR_EMPTY && tries < 50)
            {
                // (every texture still with the encoder: it catches up in a moment)
                Thread.Sleep(2);
            }
        }

        try
        {
            using var buffer = sample.GetBufferByIndex(0);
            using var dxgi = buffer.QueryInterface<IMFDXGIBuffer>();
            var resource = dxgi.GetResource(Native.IID_ID3D11Texture2D);
            using var texture = new ID3D11Texture2D(resource);
            var slice = dxgi.SubresourceIndex;
            // (a texture's buffer says no length till it is given one, and the sink writer refuses an empty sample)
            using (var surface = buffer.QueryInterface<IMF2DBuffer>())
            {
                buffer.CurrentLength = surface.ContiguousLength;
            }
            capture!.WithLatest((source, w, h, display) => converter!.Convert(source, w, h, display, texture, (uint)slice));
            Thumbs(writer, texture, (uint)slice, time);
            FrameTrace.Note($"encode at={time / 10000.0:F2} key={key} target={texture.NativePointer:x} slice={slice} captured={capture.LatestTime / 10000.0:F2}");
            writer.WriteVideo(sample, time, Period, key);
        }
        finally
        {
            sample.Dispose();
        }
    }

    /// <summary>The read-backs of thumbnails the GPU has done taken, and this frame's begun where one is due.</summary>
    private void Thumbs(SegmentWriter writer, ID3D11Texture2D texture, uint slice, long time)
    {
        if (thumbnailer is null)
        {
            return;
        }

        try
        {
            thumbnailer.Collect();
            if (time >= writer.NextThumbHns)
            {
                writer.NextThumbHns = (time / Thumbnailer.StepHns + 1) * Thumbnailer.StepHns;
                thumbnailer.Take(texture, slice, writer, time / 10_000);
            }
        }
        catch (Exception ex)
        {
            Report("warning", "thumbnails.failed", ex.Message);
            thumbnailer.Dispose();
            thumbnailer = null;
        }
    }

    private AudioMixer? mixer;

    private void AudioLoop()
    {
        var mmcssTask = 0u;
        var mmcss = Native.AvSetMmThreadCharacteristics("Audio", ref mmcssTask);
        Native.CoInitializeEx(IntPtr.Zero, 0);
        var kinds = new List<AudioKind>();
        if (Target!.IsWindow)
        {
            kinds.Add(AudioKind.Process);
        }
        else
        {
            if (options.SystemAudio)
            {
                kinds.Add(AudioKind.System);
            }

            if (options.Microphone)
            {
                kinds.Add(AudioKind.Microphone);
            }
        }

        var sources = new AudioSource?[kinds.Count];
        var retryAt = new long[kinds.Count];
        // (a source lost or not opened: said again once it is open, so the replay window's warning goes)
        var troubled = new bool[kinds.Count];
        // (the frames are stamped with the moment they were composed, the sound with the moment it was played: one clock)
        var local = new AudioMixer(kinds.Count, t0, 0);
        mixer = local;
        long lastDeviceCheck = 0;
        try
        {
            while (true)
            {
                var now = Native.NowHns();
                for (var i = 0; i < kinds.Count; i++)
                {
                    if (sources[i] is null && now >= retryAt[i])
                    {
                        sources[i] = OpenSource(kinds[i]);
                        retryAt[i] = now + 30_000_000;
                        if (sources[i] is null)
                        {
                            troubled[i] = true;
                        }
                        else if (troubled[i])
                        {
                            troubled[i] = false;
                            Report("info", Code(kinds[i]) + "Back", "the sound is recorded again");
                        }
                    }

                    if (sources[i] is not { } source)
                    {
                        continue;
                    }

                    try
                    {
                        var index = i;
                        source.Drain((at, samples, frames) => local.Add(index, at, samples, frames));
                    }
                    catch (Exception ex)
                    {
                        Report("warning", Code(kinds[i]) + "Lost", ex.Message);
                        troubled[i] = true;
                        source.Dispose();
                        sources[i] = null;
                        retryAt[i] = now + 10_000_000;
                    }
                }

                if (now - lastDeviceCheck > 30_000_000)
                {
                    // (headphones plugged in, another default chosen: the source moved to the device now the default)
                    lastDeviceCheck = now;
                    for (var i = 0; i < kinds.Count; i++)
                    {
                        if (sources[i] is { } source && kinds[i] != AudioKind.Process &&
                            AudioSource.DefaultDeviceId(kinds[i] == AudioKind.Microphone ? 1 : 0) is { Length: > 0 } id && id != source.DeviceId)
                        {
                            Report("info", Code(kinds[i]) + "DeviceChanged", "the default device changed");
                            source.Dispose();
                            sources[i] = null;
                            retryAt[i] = 0;
                        }
                    }
                }

                local.Emit(now, Route);
                CloseDue(now);
                if (videoDone)
                {
                    bool left;
                    lock (segmentsGate)
                    {
                        left = segments.Count > 0;
                    }

                    if (!left)
                    {
                        break;
                    }
                }

                Thread.Sleep(10);
            }
        }
        catch (Exception ex)
        {
            Report("error", "audio.failed", ex.ToString());
        }
        finally
        {
            foreach (var source in sources)
            {
                source?.Dispose();
            }

            if (mmcss != IntPtr.Zero)
            {
                Native.AvRevertMmThreadCharacteristics(mmcss);
            }
        }
    }

    private static string Code(AudioKind kind) => kind switch
    {
        AudioKind.Microphone => "audio.microphone",
        AudioKind.Process => "audio.process",
        _ => "audio.system",
    };

    private AudioSource? OpenSource(AudioKind kind)
    {
        try
        {
            var source = kind == AudioKind.Process ? AudioSource.OpenProcess(Target!.ProcessId) : AudioSource.OpenDevice(kind);
            if (source is null)
            {
                Report("warning", Code(kind) + "Missing", "no such device");
                return null;
            }

            source.Start();
            return source;
        }
        catch (Exception ex)
        {
            Report("warning", Code(kind) + "Failed", ex.Message);
            return null;
        }
    }

    /// <summary>A piece of the mix written into the segments its moments belong to.</summary>
    private void Route(long at, float[] mix, float[][] each, int offset, int frames)
    {
        lock (segmentsGate)
        {
            foreach (var open in segments)
            {
                var from = Math.Max(at, open.AudioStart);
                var to = Math.Min(at + frames, open.AudioEnd);
                if (to <= from)
                {
                    continue;
                }

                try
                {
                    open.Writer.WriteAudio(from - open.AudioStart, mix, each, offset + (int)(from - at), (int)(to - from));
                }
                catch (Exception ex)
                {
                    Report("warning", "audio.writeFailed", ex.Message);
                }
            }
        }
    }

    /// <summary>The segment being written closed now (its sound waited for), so that it can be read; recording goes
    /// on in the next.</summary>
    public Task FlushAsync(CancellationToken cancel = default)
    {
        if (!IsRunning)
        {
            return Task.CompletedTask;
        }

        var asked = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var before = Interlocked.CompareExchange(ref flushAsked, asked, null);
        return (before ?? asked).Task.WaitAsync(cancel);
    }

    public async Task StopAsync(CancellationToken cancel = default)
    {
        if (!IsRunning || stopped is null)
        {
            return;
        }

        stopRequestedByCaller = true;
        stopAsked = true;
        try
        {
            await stopped.Task.WaitAsync(cancel);
        }
        finally
        {
            stopRequestedByCaller = false;
        }
    }

    private void TearDown()
    {
        try
        {
            allocator?.UninitializeSampleAllocator();
        }
        catch (Exception)
        {
        }

        allocator?.Dispose();
        allocator = null;
        try
        {
            thumbnailer?.Collect(all: true);
        }
        catch (Exception)
        {
        }

        thumbnailer?.Dispose();
        thumbnailer = null;
        converter?.Dispose();
        converter = null;
        capture?.Dispose();
        capture = null;
        Interlocked.Exchange(ref ready, null)?.Dispose();
        // (the segments' writers it was giving frames to are all finished or let go of by now)
        encoder?.Dispose();
        encoder = null;
        gpu?.Dispose();
        gpu = null;
        mixer = null;
        audioThread = null;
        clockThread = null;
        sourceThread = null;
        lock (segmentsGate)
        {
            foreach (var open in segments)
            {
                open.Writer.Abort();
                open.Flushed?.TrySetResult();
            }

            segments.Clear();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
    }
}
