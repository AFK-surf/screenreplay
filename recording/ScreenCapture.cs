using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;

namespace Replay.Recording;

/// <summary>
/// Windows.Graphics.Capture of a monitor or a window, the pointer drawn in, no yellow border where the system allows
/// it. Each frame that arrives is copied into one texture of our own (the newest picture), which the recorder's clock
/// takes when a new one has come (at most once a tick): the capture's buffers go back to the system at once, and a
/// segment's first frame is the picture as it is, whether or not one has just come.
/// <para>On an HDR desktop the frames are taken as FP16 scRGB (8-bit BGRA had an HDR game's colours wrong, 2026-11-15), which the
/// converter makes SDR.</para>
/// </summary>
internal sealed class ScreenCapture : IDisposable
{
    private readonly Gpu gpu;
    private readonly GraphicsCaptureItem item;
    private readonly Direct3D11CaptureFramePool pool;
    private readonly GraphicsCaptureSession session;
    private readonly Action<string>? onError;
    private readonly Action<string>? onResized;
    private readonly object gate = new();
    private readonly DirectXPixelFormat poolFormat;
    private long minStepTicks;
    private long lastErrorAt;
    private int suppressedErrors;
    private Windows.Graphics.SizeInt32 poolSize;
    private ID3D11Texture2D? latest;
    private bool disposed;

    /// <summary>Set once the first frame is in.</summary>
    public ManualResetEventSlim FirstFrame { get; } = new(false);

    /// <summary>Set as each frame is taken (an auto-reset event): what the recorder's clock waits on beside its timer.</summary>
    public IntPtr FrameEvent { get; }

    /// <summary>The capture stopped by itself (the window closed, the monitor gone).</summary>
    public event Action? Closed;

    public int Width { get; private set; }
    public int Height { get; private set; }

    /// <summary>When the newest frame was composed (100 ns, the performance counter's clock).</summary>
    public long LatestTime { get; private set; }

    public long Frames { get; private set; }

    /// <summary>What is captured.</summary>
    public CaptureTarget Target { get; }

    /// <summary>Frames taken as FP16 scRGB (an HDR desktop), not BGRA.</summary>
    public bool Hdr { get; }

    /// <summary>The colour of the display it is on, as last looked at (its SDR white and peak, for the FP16 frames).</summary>
    public DisplayColor Display
    {
        get
        {
            lock (gate)
            {
                return display;
            }
        }
        set
        {
            lock (gate)
            {
                display = value;
            }
        }
    }

    private DisplayColor display;

    public ScreenCapture(Gpu gpu, CaptureTarget target, int frameRate, bool hdr, DisplayColor display, Action<string>? onError = null, Action<string>? onResized = null)
    {
        this.gpu = gpu;
        this.onError = onError;
        this.onResized = onResized;
        Target = target;
        Hdr = hdr;
        this.display = display;
        // (half the period: frames come at most twice the recording's rate, and the recorder's clock takes one a period
        // as each comes (ScreenRecorder's credit). At 90% (15 ms) on a 240 Hz screen a frame that came a composition late
        // was put off to the 5th (20.8 ms), and with the clock's own ticks beside it about a third of a 60 fps
        // recording's frames were 33 ms apart (the user, 2026-11-21: 48-52 fps of a window changing 225 times a second,
        // 60.0 with this). REPLAY_TEST_MINSTEP: another share of the period, in percent (tests only))
        minStepTicks = 10_000_000L * 5 / 10 / Math.Max(1, frameRate);
        if (int.TryParse(Environment.GetEnvironmentVariable("REPLAY_TEST_MINSTEP"), out var pct) && pct >= 0)
        {
            minStepTicks = 10_000_000L * pct / 100 / Math.Max(1, frameRate);
        }
        FrameEvent = Native.CreateEvent(IntPtr.Zero, false, false, IntPtr.Zero);
        poolFormat = hdr ? DirectXPixelFormat.R16G16B16A16Float : DirectXPixelFormat.B8G8R8A8UIntNormalized;
        item = CreateItem(target);
        item.Closed += (_, _) => Closed?.Invoke();
        poolSize = item.Size;
        // (2 buffers: OnFrame drains immediately, GPU-copies into `latest`, and disposes the frame in finally;
        // at 4K FP16 each buffer is 63.3 MiB, so 2 vs 4 saves ~127 MiB VRAM and halves DWM shared surface pressure)
        pool = Direct3D11CaptureFramePool.CreateFreeThreaded(gpu.WinRtDevice, poolFormat, 2, poolSize);
        pool.FrameArrived += OnFrame;
        session = pool.CreateCaptureSession(item);
        session.IsCursorCaptureEnabled = true;
        try
        {
            // (granted by GraphicsCaptureAccess.RequestAccessAsync(Borderless), which the app asks for; else it throws
            // or is ignored, and the border shows)
            session.IsBorderRequired = false;
        }
        catch (Exception)
        {
        }

        try
        {
            // (frames no closer together than half the recording's period: a 240 Hz screen is not copied 240 times a
            // second for a 60 fps recording; Windows 11 24H2 and later)
            session.MinUpdateInterval = TimeSpan.FromTicks(minStepTicks);
        }
        catch (Exception)
        {
        }
    }

    public void Start()
    {
        // (tests only: REPLAY_TEST_STALL=<s>, the recording's first capture gives no new frames after that many seconds;
        // REPLAY_TEST_STALL_FAIL=<n>, the next n captures give no first frame at all, to test restart escalation)
        if (Interlocked.Exchange(ref stallAsked, 1) == 0
            && double.TryParse(Environment.GetEnvironmentVariable("REPLAY_TEST_STALL"), System.Globalization.CultureInfo.InvariantCulture, out var s) && s > 0)
        {
            stallAt = Native.NowHns() + (long)(s * 10_000_000);
            if (int.TryParse(Environment.GetEnvironmentVariable("REPLAY_TEST_STALL_FAIL"), out var fails) && fails > 0)
            {
                Volatile.Write(ref stallFailLeft, fails);
            }
        }
        else if (Volatile.Read(ref stallFailLeft) > 0 && Interlocked.Decrement(ref stallFailLeft) >= 0)
        {
            failFirstFrame = true;
        }

        session.StartCapture();
    }

    private static int stallAsked;
    private static int stallFailLeft;
    private long stallAt;
    private bool failFirstFrame;

    private static unsafe GraphicsCaptureItem CreateItem(CaptureTarget target)
    {
        const string name = "Windows.Graphics.Capture.GraphicsCaptureItem";
        Native.Check(Native.WindowsCreateString(name, name.Length, out var hstring), "WindowsCreateString");
        IntPtr factory = IntPtr.Zero, result = IntPtr.Zero;
        try
        {
            Native.Check(Native.RoGetActivationFactory(hstring, in Native.IID_IGraphicsCaptureItemInterop, out factory), "RoGetActivationFactory");
            var iid = Native.IID_IGraphicsCaptureItem;
            var vtable = *(IntPtr**)factory;
            // IGraphicsCaptureItemInterop: CreateForWindow (3), CreateForMonitor (4)
            var create = (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, Guid*, IntPtr*, int>)vtable[target.IsWindow ? 3 : 4];
            Native.Check(create(factory, target.IsWindow ? target.Window : target.Monitor, &iid, &result), "CreateForWindow/Monitor");
            return GraphicsCaptureItem.FromAbi(result);
        }
        finally
        {
            Native.Release(result);
            Native.Release(factory);
            Native.WindowsDeleteString(hstring);
        }
    }

    private void OnFrame(Direct3D11CaptureFramePool sender, object args)
    {
        Direct3D11CaptureFrame? frame = null;
        try
        {
            // Drain any backlog so only the newest composed frame is copied and older buffers return to DWM at once.
            while (sender.TryGetNextFrame() is { } next)
            {
                frame?.Dispose();
                frame = next;
            }

            if (frame is null)
            {
                return;
            }

            if (Target.IsWindow && !WindowShown.Showing(Target.Window))
            {
                // (a window hidden or minimised: the picture before kept)
                return;
            }

            if (failFirstFrame || (stallAt > 0 && Native.NowHns() >= stallAt && latest is not null))
            {
                // (tests only: a capture stuck as one was after the screen woke, 2026-11-21)
                return;
            }

            var content = frame.ContentSize;
            var resized = content.Width != poolSize.Width || content.Height != poolSize.Height;
            if (resized)
            {
                // (the window resized: the pool's buffers made to its size; this frame still used, cut to it)
                var prev = poolSize;
                sender.Recreate(gpu.WinRtDevice, poolFormat, 2, content);
                poolSize = content;
                onResized?.Invoke($"{prev.Width}x{prev.Height} -> {content.Width}x{content.Height}");
            }

            var frameTicks = frame.SystemRelativeTime.Ticks;
            if (!resized && latest is not null && frameTicks >= LatestTime && frameTicks - LatestTime < minStepTicks)
            {
                return;
            }

            using var texture = Gpu.TextureOf(frame.Surface);
            var desc = texture.Description;
            var w = Math.Min(content.Width, (int)desc.Width) & ~1;
            var h = Math.Min(content.Height, (int)desc.Height) & ~1;
            if (w < 2 || h < 2)
            {
                return;
            }

            lock (gate)
            {
                if (disposed)
                {
                    return;
                }

                if (latest is null || Width != w || Height != h)
                {
                    latest?.Dispose();
                    latest = gpu.Device.CreateTexture2D(new Texture2DDescription
                    {
                        Width = (uint)w,
                        Height = (uint)h,
                        MipLevels = 1,
                        ArraySize = 1,
                        Format = Hdr ? Format.R16G16B16A16_Float : Format.B8G8R8A8_UNorm,
                        SampleDescription = new SampleDescription(1, 0),
                        Usage = ResourceUsage.Default,
                        BindFlags = BindFlags.RenderTarget | BindFlags.ShaderResource,
                    });
                    Width = w;
                    Height = h;
                }

                gpu.Context.CopySubresourceRegion(latest, 0, 0, 0, 0, texture, 0, new Box(0, 0, 0, w, h, 1));
                if (FrameTrace.On) FrameTrace.Note($"capture t={frame.SystemRelativeTime.Ticks / 10000.0:F2} surface={texture.NativePointer:x} {w}x{h}");
                LatestTime = frame.SystemRelativeTime.Ticks;
                Frames++;
                // (the recorder's clock woken: the frame taken as it comes, not at its next tick; under the lock, so
                // never after Dispose has closed it)
                Native.SetEvent(FrameEvent);
            }

            FirstFrame.Set();
        }
        catch (Exception ex)
        {
            // (a frame lost; the device's loss shows in the encoder's next write; reported rate-limited so repeated
            // WGC/D3D11 callback failures leave a trace in recorder.log)
            if (!disposed && onError is not null)
            {
                var errNow = Native.NowHns();
                if (errNow - Interlocked.Read(ref lastErrorAt) >= 50_000_000)
                {
                    Interlocked.Exchange(ref lastErrorAt, errNow);
                    var skipped = Interlocked.Exchange(ref suppressedErrors, 0);
                    var more = skipped > 0 ? $" (+{skipped} more)" : "";
                    onError($"{ex.GetType().Name}: {ex.Message} (0x{ex.HResult:X8}){more}");
                }
                else
                {
                    Interlocked.Increment(ref suppressedErrors);
                }
            }
        }
        finally
        {
            frame?.Dispose();
        }
    }

    /// <summary>Runs <paramref name="use"/> with the newest picture while no frame replaces it.</summary>
    public bool WithLatest(Action<ID3D11Texture2D, int, int, DisplayColor> use)
    {
        lock (gate)
        {
            if (latest is null || disposed)
            {
                return false;
            }

            use(latest, Width, Height, display);
            return true;
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            disposed = true;
        }

        try
        {
            pool.FrameArrived -= OnFrame;
            session.Dispose();
            pool.Dispose();
        }
        catch (Exception)
        {
        }

        lock (gate)
        {
            latest?.Dispose();
            latest = null;
        }

        FirstFrame.Dispose();
        // (closed once nothing can set it or wait on it: the frames' callbacks are unhooked above, and the recorder's
        // clock disposes a capture only between its waits)
        Native.CloseHandle(FrameEvent);
    }
}
