using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.MediaFoundation;

namespace Replay.Recording;

public sealed record RecorderOptions(string Folder, TimeSpan Keep, int FrameRate, int MaxHeight, string Codec, string Quality)
{
    public TimeSpan SegmentLength { get; init; } = TimeSpan.FromSeconds(30);

    public bool SystemAudio { get; init; } = true;

    public bool Microphone { get; init; }

    public InputActivity? Activity { get; init; }

    public bool ForceHdr { get; init; }

    public bool SkipUnrecorded { get; init; } = true;
}

public sealed record RecorderEvent(string Level, string Code, string Message);

public sealed class ScreenRecorder : IAsyncDisposable
{
    private const int MF_E_SAMPLEALLOCATOR_EMPTY = unchecked((int)0xC00D4A3E);

    private RecorderOptions options;
    private volatile bool skipUnrecorded;
    private readonly Action<RecorderEvent> report;
    private readonly object segmentsGate = new();
    private readonly List<Open> segments = new();
    private readonly List<Task> closing = new();

    private Gpu? gpu;
    // Owned exclusively by ClockLoop thread.
    private ScreenCapture? capture;

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
        skipUnrecorded = options.SkipUnrecorded;
        this.report = report ?? (_ => { });
        Store = new SegmentStore(options.Folder);
    }

    public void SetSkipUnrecorded(bool value) => skipUnrecorded = value;

    public SegmentStore Store { get; }

    public bool IsRunning { get; private set; }

    public CaptureTarget? Target { get; private set; }

    public VideoSize? OutputSize { get; private set; }

    public string ActualCodec { get; private set; } = "";

    public bool FellBack { get; private set; }

    public bool FrameRateFellBack { get; private set; }

    public int ActualFrameRate => options.FrameRate;

    public int ActualBitrate { get; private set; }

    public (int Encoded, int Skipped) Pace { get; private set; }

    public event EventHandler<Exception>? Faulted;

    public event EventHandler<Exception>? CodecFallback;

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
        displayChanged = false;
        renewAsked = null;
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
        Report("info", "recorder.started", $"{ActualCodec} {size.Width}x{size.Height} {options.FrameRate} fps {ActualBitrate / 1000} kbps, {audioSources} sound source(s), GPU {gpu.AdapterName}");
    }

    private Exception? faultOnStop;

    private static IntPtr MonitorOf(CaptureTarget target) => target.IsWindow ? WindowShown.MonitorOf(target.Window) : target.Monitor;

    private string Describe(DisplayColor display)
        => (display.Hdr ? $"HDR, SDR white {display.SdrWhiteNits:0} nits, peak {display.PeakNits:0} nits" : "SDR")
           + (options.ForceHdr && !display.Hdr ? " (FP16 capture forced)" : "");

    private ScreenCapture MakeCapture(CaptureTarget target, DisplayColor display)
    {
        var made = new ScreenCapture(gpu!, target, options.FrameRate, display.Hdr || options.ForceHdr, display,
            msg => Report("warning", "capture.frameError", msg),
            msg => Report("info", "capture.resized", msg));
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

    public void DisplayChanged() => displayChanged = true;

    private volatile string? renewAsked;
    private long changedAt;

    // WGC captures created before display sleep can stop producing frames after wake; renew alongside the active one.
    public void RenewCapture(string why) => renewAsked = why;

    public void ScreenChanged() => Volatile.Write(ref changedAt, Native.NowHns());

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
            var published = capture;
            ScreenCapture? pending = null;
            long pendingSince = 0;
            var stall = new StallWatcher(published.Frames, Native.NowHns());
            var pendingFromStall = false;
            var stallTest = Environment.GetEnvironmentVariable("REPLAY_TEST_STALL") is not null;
            var stallTestRealInput = Environment.GetEnvironmentVariable("REPLAY_TEST_STALL_REAL_INPUT") == "1";
            try
            {
                while (!stopAsked)
                {
                    Thread.Sleep(100);
                    var now = Native.NowHns();
                    var inputHns = options.Activity?.LastHns ?? 0;
                    var fgHns = Volatile.Read(ref changedAt);
                    var poked = stallTest && !stallTestRealInput ? now : Math.Max(inputHns, fgHns);
                    stall.Observe(published.Frames, now, poked);

                    string? renew = null;
                    var renewIsStall = false;
                    if (pending is null && renewAsked is { } asked && DisplayMemory.Trusted)
                    {
                        renewAsked = null;
                        renew = asked;
                    }
                    else if (pending is null)
                    {
                        var action = stall.Evaluate(now, (!primary.IsWindow && DisplayMemory.ScreenIsOn) || stallTest);
                        if (action == StallAction.Restart)
                        {
                            var devReason = gpu?.DeviceRemovedReason ?? 0;
                            Report("warning", "capture.restarting",
                                $"renewed capture stalled again without producing live frames (frames={published.Frames}, noFrame={(now - stall.LastFrameAt) / 10_000_000.0:0.1}s, deviceRemoved=0x{devReason:X8}): restarting recorder");
                            faultOnStop = new CaptureStalledException("the capture stalled again after renewal");
                            stopAsked = true;
                            break;
                        }
                        else if (action == StallAction.Renew)
                        {
                            var devReason = gpu?.DeviceRemovedReason ?? 0;
                            var by = fgHns >= inputHns ? "fg/desktop" : "input";
                            renew = $"no new frame in {(now - stall.LastFrameAt) / 10_000_000.0:0.1} s though {by} changed {(now - stall.PokedSince) / 10_000_000.0:0.1} s ago (frames={published.Frames}, streak={stall.StallStreak}, deviceRemoved=0x{devReason:X8})";
                            renewIsStall = true;
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
                        pendingFromStall = false;
                    }

                    if (pending is not null)
                    {
                        if (pending.FirstFrame.IsSet)
                        {
                            Interlocked.Exchange(ref ready, pending)?.Dispose();
                            intendedHdr = pending.Hdr;
                            published = pending;
                            stall.NoteSwapped(published.Frames, now, pendingFromStall);
                            Report("info", "capture.source", $"{pending.Width}x{pending.Height}" + (pending.Hdr ? " FP16" : "") + $", after {(now - pendingSince) / 10_000} ms");
                            pending = null;
                            pendingFromStall = false;
                        }
                        else if (now - pendingSince > GiveUp)
                        {
                            var devReason = gpu?.DeviceRemovedReason ?? 0;
                            Report("warning", "capture.sourceFailed", $"no picture in 1.5 s from the new capture (deviceRemoved=0x{devReason:X8}, failures={stall.SourceFailures + 1}): the one in use kept");
                            pending.Dispose();
                            pending = null;
                            var wasStall = pendingFromStall;
                            pendingFromStall = false;
                            if (stall.NoteSourceFailed(now, wasStall, DisplayMemory.ScreenIsOn || stallTest))
                            {
                                Report("warning", "capture.restarting", $"renewed capture gave no picture twice (deviceRemoved=0x{devReason:X8}): restarting recorder");
                                faultOnStop = new CaptureStalledException("the capture stayed stalled after renewal failed twice");
                                stopAsked = true;
                                break;
                            }
                        }
                    }

                    if (pending is null && renew is not null)
                    {
                        stall.NoteRenewStarted(now);
                        Report("info", "capture.renew", renew);
                    }

                    if (pending is null && ((hdr != intendedHdr && look) || renew is not null))
                    {
                        try
                        {
                            pending = MakeCapture(primary, display);
                            pendingSince = now;
                            pendingFromStall = renewIsStall;
                            pending.Start();
                        }
                        catch (Exception ex)
                        {
                            pending?.Dispose();
                            pending = null;
                            pendingFromStall = false;
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
        // D3D11_BIND_RENDER_TARGET
        attrs.Set(Native.SA_D3D11_BINDFLAGS, 0x20u);
        using var type = MediaFactory.MFCreateMediaType();
        type.Set(Native.MT_MAJOR_TYPE, Native.MediaType_Video);
        type.Set(Native.MT_SUBTYPE, Native.VideoFormat_NV12);
        type.Set(Native.MT_FRAME_SIZE, Native.Pack((uint)size.Width, (uint)size.Height));
        type.Set(Native.MT_INTERLACE_MODE, 2u);
        type.Set(Native.MT_PIXEL_ASPECT_RATIO, Native.Pack(1, 1));
        // 2 initial, 6 max (no B-frames; ClockLoop gates via Ready): caps 4K NV12 pool at ~24-71 MiB.
        allocator.InitializeSampleAllocatorEx(2, 6, attrs, type);
        return allocator;
    }

    private long Period => (long)Math.Round(10_000_000.0 / options.FrameRate);

    private long AudioFrameOf(long hns) => (long)Math.Round((hns - t0) * (double)AudioMixer.Rate / 10_000_000.0);

    private DateTimeOffset UtcOf(long hns) => utcAtQpc + TimeSpan.FromTicks(hns - qpcAtUtc);

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
        const long KeyFrames = 30;
        long segmentStart = 0, lastTime = 0, lastKey = 0, seen = 0, sinceKey = 0;
        const long PaceEvery = 100_000_000;
        long paceStart = 0;
        // Tolerate a single late frame (up to 4 periods, e.g. 4K keyframe or GPU wake); skip only on consecutive late frames.
        const long Patience = 4;
        var late = false;
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
        int segEncoded = 1, segSkipped = 0;
        long segCaptured = 0, segCapBase = 0;
        try
        {
            t0 = Native.NowHns();
            segmentStart = t0;
            current = Begin(first, t0);
            seen = capture!.Frames;
            segCapBase = seen;
            EncodeFrame(current.Writer, 0, true);
            if (audioSources > 0)
            {
                audioThread = new Thread(AudioLoop) { IsBackground = true, Name = "recorder sound", Priority = ThreadPriority.AboveNormal };
                audioThread.Start();
            }

            next = Task.Run(() => MakeWriter(OutputSize!.Value, encode!.Hevc));
            var tick = t0 + Period;
            paceStart = t0;
            // Credit-based pacing (trigger at 0.75 period) avoids 33 ms cadence drops on 240 Hz displays while capping average FPS.
            var credit = 0.0;
            var creditAt = t0;
            double Credit(long at)
            {
                credit = Math.Min(1.0, credit + (double)(at - creditAt) / Period);
                creditAt = at;
                return credit;
            }

            var creditDue = long.MaxValue;
            while (!stopAsked)
            {
                Wait(timer, Math.Min(tick, creditDue), capture.FrameEvent);
                creditDue = long.MaxValue;
                if (stopAsked)
                {
                    break;
                }

                var now = Native.NowHns();
                if (now >= tick)
                {
                    tick += Period;
                    if (tick < now - Period)
                    {
                        tick = now + Period;
                    }
                }

                if (Interlocked.Exchange(ref ready, null) is { } swapped)
                {
                    var old = capture;
                    segCaptured += Math.Max(0, old.Frames - segCapBase);
                    capture = swapped;
                    segCapBase = capture.Frames;
                    old?.Dispose();
                    seen = -1;
                }

                now = Native.NowHns();
                var flush = Interlocked.Exchange(ref flushAsked, null);
                if (now >= segmentStart + length || flush is not null)
                {
                    var boundary = flush is null ? segmentStart + length : now;
                    var segDur = boundary - segmentStart;
                    var segCapTotal = segCaptured + Math.Max(0, capture.Frames - segCapBase);
                    var segPoked = Math.Max(options.Activity?.LastHns ?? 0, Volatile.Read(ref changedAt));
                    if (segEncoded <= 1 && segDur >= 150_000_000 && DisplayMemory.ScreenIsOn && segPoked > segmentStart)
                    {
                        Report("warning", "capture.stillSegment",
                            $"{segDur / 10_000_000.0:0.#} s segment encoded {segEncoded} frame while active (captured={segCapTotal}, skipped={segSkipped}, totalFrames={capture.Frames}, deviceRemoved=0x{(gpu?.DeviceRemovedReason ?? 0):X8})");
                    }

                    var writer = next.GetAwaiter().GetResult();
                    Close(current, segDur, AudioFrameOf(boundary), flush);
                    if (now - boundary > length)
                    {
                        boundary = now;
                    }

                    segmentStart = boundary;
                    current = Begin(writer, boundary);
                    seen = capture.Frames;
                    segEncoded = 1;
                    segSkipped = 0;
                    segCaptured = 0;
                    segCapBase = seen;
                    EncodeFrame(current.Writer, 0, true);
                    credit = 0;
                    creditAt = now;
                    lastTime = lastKey = sinceKey = 0;
                    next = Task.Run(() => MakeWriter(OutputSize!.Value, encode!.Hevc));
                }
                else if (capture.Frames != seen && Credit(now) < 0.75)
                {
                    creditDue = now + (long)((0.75 - credit) * Period) + 1;
                }
                else if (capture.Frames != seen && !Ready(encoder!))
                {
                    skipped++;
                    segSkipped++;
                }
                else if (capture.Frames != seen)
                {
                    encoded++;
                    segEncoded++;
                    seen = capture.Frames;
                    credit -= 1.0;
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
                else
                {
                    // Collect pending GPU thumbnail read-backs even on idle screens so segments do not close without thumbnails.
                    CollectThumbs();
                }

                if (now - paceStart >= PaceEvery)
                {
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
            // Drain final thumbnail read-backs on ClockLoop (the owning D3D11 thread) before completing segments.
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
                var aborting = next.ContinueWith(t =>
                {
                    if (t.IsCompletedSuccessfully)
                    {
                        t.Result.Abort();
                    }
                });
                lock (segmentsGate)
                {
                    closing.Add(aborting);
                }
            }
        }

        audioThread?.Join(TimeSpan.FromSeconds(5));
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

    private static unsafe void Wait(IntPtr timer, long dueHns, IntPtr frame)
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
            if (frame == IntPtr.Zero)
            {
                Native.WaitForSingleObject(timer, 1000);
                return;
            }

            var both = stackalloc IntPtr[2] { timer, frame };
            Native.WaitForMultipleObjects(2, both, false, 1000);
        }
        else if (frame != IntPtr.Zero)
        {
            Native.WaitForSingleObject(frame, (uint)Math.Max(1, left / 10_000));
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

                // Pad missing audio with silence on the completion task (never under segments lock on ClockLoop) if the audio thread stalled.
                var lateBy = audioSources > 0 && (mixer?.Emitted ?? 0) < open.AudioEnd
                    ? open.AudioEnd - Math.Max(open.AudioStart, mixer?.Emitted ?? 0)
                    : 0;
                segments.RemoveAt(i--);
                closing.RemoveAll(t => t.IsCompleted);
                closing.Add(Task.Run(() =>
                {
                    if (lateBy > 0)
                    {
                        try
                        {
                            open.Writer.PadAudio(open.AudioEnd - open.AudioStart);
                            Report("info", "audio.padded", $"the sound was {lateBy / AudioMixer.Rate} s late: silence in its place");
                        }
                        catch (Exception ex)
                        {
                            Report("warning", "audio.writeFailed", ex.Message);
                        }
                    }

                    Complete(open);
                }));
            }
        }
    }

    private void Complete(Open open)
    {
        try
        {
            var input = options.Activity?.Read(open.StartHns, SegmentWriter.Buckets(open.DurationHns));
            var segment = open.Writer.Finish(open.DurationHns, input);
            if (segment is not null)
            {
                SegmentClosed?.Invoke(this, segment);
            }

            if (skipUnrecorded)
            {
                Store.PruneRecorded(options.Keep);
            }
            else
            {
                Store.Prune(DateTimeOffset.UtcNow - options.Keep);
            }
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
            // D3D11 texture media buffers report 0 length until set; SinkWriter rejects empty samples.
            using (var surface = buffer.QueryInterface<IMF2DBuffer>())
            {
                buffer.CurrentLength = surface.ContiguousLength;
            }
            capture!.WithLatest((source, w, h, display) =>
            {
                var sdr = converter!.Convert(source, w, h, display, texture, (uint)slice);
                Thumbs(writer, sdr, w, h, time);
            });
            if (FrameTrace.On) FrameTrace.Note($"encode at={time / 10000.0:F2} key={key} target={texture.NativePointer:x} slice={slice} captured={capture.LatestTime / 10000.0:F2}");
            writer.WriteVideo(sample, time, Period, key);
        }
        finally
        {
            sample.Dispose();
        }
    }

    // Must run on ClockLoop thread (all Thumbnailer GPU calls are affine to it).
    private void CollectThumbs()
    {
        if (thumbnailer is null)
        {
            return;
        }

        try
        {
            thumbnailer.Collect();
        }
        catch (Exception ex)
        {
            Report("warning", "thumbnails.failed", ex.Message);
            thumbnailer.Dispose();
            thumbnailer = null;
        }
    }

    private void Thumbs(SegmentWriter writer, ID3D11Texture2D sdrBgra, int srcW, int srcH, long time)
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
                thumbnailer.Take(sdrBgra, srcW, srcH, writer, time / 10_000);
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
        var troubled = new bool[kinds.Count];
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

public sealed class CaptureStalledException(string message) : Exception(message);
