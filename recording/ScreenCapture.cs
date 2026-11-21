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
    private readonly object gate = new();
    private readonly DirectXPixelFormat poolFormat;
    private readonly long minStepTicks;
    private Windows.Graphics.SizeInt32 poolSize;
    private ID3D11Texture2D? latest;
    private bool disposed;

    /// <summary>Set once the first frame is in.</summary>
    public ManualResetEventSlim FirstFrame { get; } = new(false);

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

    public ScreenCapture(Gpu gpu, CaptureTarget target, int frameRate, bool hdr, DisplayColor display)
    {
        this.gpu = gpu;
        Target = target;
        Hdr = hdr;
        this.display = display;
        minStepTicks = 10_000_000L * 9 / 10 / Math.Max(1, frameRate);
        poolFormat = hdr ? DirectXPixelFormat.R16G16B16A16Float : DirectXPixelFormat.B8G8R8A8UIntNormalized;
        item = CreateItem(target);
        item.Closed += (_, _) => Closed?.Invoke();
        poolSize = item.Size;
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
            // (frames no closer together than 90% of the recording's period: a 240 Hz screen is not copied 120-240
            // times a second for a 60 fps recording; Windows 11 24H2 and later)
            session.MinUpdateInterval = TimeSpan.FromTicks(minStepTicks);
        }
        catch (Exception)
        {
        }
    }

    public void Start()
    {
        // (tests only: REPLAY_TEST_STALL=<s>, the recording's first capture gives no new frames after that many seconds)
        if (Interlocked.Exchange(ref stallAsked, 1) == 0
            && double.TryParse(Environment.GetEnvironmentVariable("REPLAY_TEST_STALL"), System.Globalization.CultureInfo.InvariantCulture, out var s) && s > 0)
        {
            stallAt = Native.NowHns() + (long)(s * 10_000_000);
        }

        session.StartCapture();
    }

    private static int stallAsked;
    private long stallAt;

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
        try
        {
            using var frame = sender.TryGetNextFrame();
            if (frame is null)
            {
                return;
            }

            if (Target.IsWindow && !WindowShown.Showing(Target.Window))
            {
                // (a window hidden or minimised: the picture before kept)
                return;
            }

            if (stallAt > 0 && Native.NowHns() >= stallAt && latest is not null)
            {
                // (tests only: a capture stuck as one was after the screen woke, 2026-11-21)
                return;
            }

            var content = frame.ContentSize;
            var resized = content.Width != poolSize.Width || content.Height != poolSize.Height;
            if (resized)
            {
                // (the window resized: the pool's buffers made to its size; this frame still used, cut to it)
                poolSize = content;
                sender.Recreate(gpu.WinRtDevice, poolFormat, 2, content);
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
                FrameTrace.Note($"capture t={frame.SystemRelativeTime.Ticks / 10000.0:F2} surface={texture.NativePointer:x} {w}x{h}");
                LatestTime = frame.SystemRelativeTime.Ticks;
                Frames++;
            }

            FirstFrame.Set();
        }
        catch (Exception)
        {
            // (a frame lost; the device's loss shows in the encoder's next write)
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
    }
}
