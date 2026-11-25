using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;

namespace Replay.Recording;

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
    private ID3D11RenderTargetView? latestView;
    private Format latestFormat;
    private HdrToSdr? hdrToSdr;
    private bool disposed;

    public ManualResetEventSlim FirstFrame { get; } = new(false);

    public IntPtr FrameEvent { get; }

    public event Action? Closed;

    public int Width { get; private set; }
    public int Height { get; private set; }

    public long LatestTime { get; private set; }

    public long Frames { get; private set; }

    public CaptureTarget Target { get; }

    public bool Hdr { get; }

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
        // Half frame period: 90% caused 240 Hz displays to miss compositions and drop 60 fps captures to ~50 fps.
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
        // 2 buffers (vs 4): OnFrame copies immediately and disposes; saves ~127 MiB VRAM at 4K FP16.
        pool = Direct3D11CaptureFramePool.CreateFreeThreaded(gpu.WinRtDevice, poolFormat, 2, poolSize);
        pool.FrameArrived += OnFrame;
        session = pool.CreateCaptureSession(item);
        session.IsCursorCaptureEnabled = true;
        try
        {
            session.IsBorderRequired = false;
        }
        catch (Exception)
        {
        }

        try
        {
            session.MinUpdateInterval = TimeSpan.FromTicks(minStepTicks);
        }
        catch (Exception)
        {
        }
    }

    public void Start()
    {
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
                return;
            }

            if (failFirstFrame || (stallAt > 0 && Native.NowHns() >= stallAt && latest is not null))
            {
                return;
            }

            var content = frame.ContentSize;
            var resized = content.Width != poolSize.Width || content.Height != poolSize.Height;
            if (resized)
            {
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

                // On HDR, tone-map FP16 scRGB directly into SDR BGRA latest to avoid a 63 MiB 4K FP16 intermediate copy.
                var convertInline = Hdr && (desc.BindFlags & BindFlags.ShaderResource) != 0;
                var wantFormat = convertInline ? Format.B8G8R8A8_UNorm : (Hdr ? Format.R16G16B16A16_Float : Format.B8G8R8A8_UNorm);
                if (latest is null || Width != w || Height != h || latestFormat != wantFormat)
                {
                    latestView?.Dispose();
                    latestView = null;
                    latest?.Dispose();
                    latest = gpu.Device.CreateTexture2D(new Texture2DDescription
                    {
                        Width = (uint)w,
                        Height = (uint)h,
                        MipLevels = 1,
                        ArraySize = 1,
                        Format = wantFormat,
                        SampleDescription = new SampleDescription(1, 0),
                        Usage = ResourceUsage.Default,
                        BindFlags = BindFlags.RenderTarget | BindFlags.ShaderResource,
                    });
                    if (convertInline)
                    {
                        latestView = gpu.Device.CreateRenderTargetView(latest);
                    }
                    latestFormat = wantFormat;
                    Width = w;
                    Height = h;
                }

                if (convertInline)
                {
                    hdrToSdr ??= new HdrToSdr(gpu);
                    hdrToSdr.ConvertInto(texture, latestView!, w, h, display);
                }
                else
                {
                    gpu.Context.CopySubresourceRegion(latest, 0, 0, 0, 0, texture, 0, new Box(0, 0, 0, w, h, 1));
                }
                if (FrameTrace.On) FrameTrace.Note($"capture t={frame.SystemRelativeTime.Ticks / 10000.0:F2} surface={texture.NativePointer:x} {w}x{h}");
                LatestTime = frame.SystemRelativeTime.Ticks;
                Frames++;
                // Signal under lock so SetEvent never races with CloseHandle in Dispose.
                Native.SetEvent(FrameEvent);
            }

            FirstFrame.Set();
        }
        catch (Exception ex)
        {
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
            latestView?.Dispose();
            latestView = null;
            latest?.Dispose();
            latest = null;
            hdrToSdr?.Dispose();
            hdrToSdr = null;
        }

        FirstFrame.Dispose();
        // Safe to close: frame callbacks are unhooked above and ClockLoop only disposes captures between waits.
        Native.CloseHandle(FrameEvent);
    }
}
