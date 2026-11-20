using Vortice;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.WIC;

namespace Replay.Recording;

/// <summary>
/// The segment's thumbnails made as it is recorded: each half second (of the segment's own time) the picture just made
/// for the encoder (NV12, SDR already) is copied on the GPU, shrunk by the video processor to at most 384 × 216 BGRA
/// and read back a frame or two later, never waited for; JPEG'd on a pool thread and kept by its segment's writer,
/// which writes them beside the segment as its <c>.thumbs</c> (<see cref="SegmentWriter"/>). The replay window's
/// hover preview and filmstrip read them from there: nothing is decoded again to make them (the user, 2026-11-17:
/// 「这个缩略图一定要高性能，占用也要尽可能少」; a key frame's alone, every 2 s, changed too seldom under the pointer).
/// </summary>
internal sealed class Thumbnailer : IDisposable
{
    public const long StepHns = 5_000_000;
    private const int MaxW = 384, MaxH = 216;
    private const float Quality = 0.75f;

    private readonly Gpu gpu;
    private readonly ID3D11VideoDevice videoDevice;
    private readonly ID3D11VideoContext videoContext;
    private readonly int inW, inH, outW, outH;
    private readonly ID3D11Texture2D copy;
    private readonly ID3D11Texture2D small;
    private readonly ID3D11VideoProcessorEnumerator enumerator;
    private readonly ID3D11VideoProcessor processor;
    private readonly ID3D11VideoProcessorInputView inputView;
    private readonly ID3D11VideoProcessorOutputView outputView;
    private readonly IWICImagingFactory wic = new();

    // read-backs under way, oldest first: each its staging texture and whose it is
    private sealed record Pending(ID3D11Texture2D Staging, SegmentWriter Writer, long Ms);
    private readonly Queue<Pending> pending = new();
    private readonly Stack<ID3D11Texture2D> free = new();

    public Thumbnailer(Gpu gpu, int width, int height, int frameRate)
    {
        this.gpu = gpu;
        inW = width & ~1;
        inH = height & ~1;
        outW = MaxW;
        outH = (int)((long)MaxW * inH / inW);
        if (outH > MaxH)
        {
            outH = MaxH;
            outW = (int)((long)MaxH * inW / inH);
        }
        outW &= ~1;
        outH &= ~1;
        videoDevice = gpu.Device.QueryInterface<ID3D11VideoDevice>();
        videoContext = gpu.Context.QueryInterface<ID3D11VideoContext>();
        // (the encoder's texture is a render target only: copied into one the processor reads)
        copy = gpu.Device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)inW,
            Height = (uint)inH,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.NV12,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.Decoder,
        });
        small = gpu.Device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)outW,
            Height = (uint)outH,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.RenderTarget,
        });
        var desc = new VideoProcessorContentDescription
        {
            InputFrameFormat = VideoFrameFormat.Progressive,
            InputFrameRate = new Rational((uint)frameRate, 1),
            InputWidth = (uint)inW,
            InputHeight = (uint)inH,
            OutputFrameRate = new Rational((uint)frameRate, 1),
            OutputWidth = (uint)outW,
            OutputHeight = (uint)outH,
            Usage = VideoUsage.OptimalSpeed,
        };
        videoDevice.CreateVideoProcessorEnumerator(ref desc, out var e).CheckError();
        enumerator = e!;
        videoDevice.CreateVideoProcessor(enumerator, 0, out var p).CheckError();
        processor = p!;
        videoDevice.CreateVideoProcessorInputView(copy, enumerator, new VideoProcessorInputViewDescription
        {
            FourCC = 0,
            ViewDimension = VideoProcessorInputViewDimension.Texture2D,
            Texture2D = new Texture2DVideoProcessorInputView { MipSlice = 0, ArraySlice = 0 },
        }, out var iv).CheckError();
        inputView = iv!;
        videoDevice.CreateVideoProcessorOutputView(small, enumerator, new VideoProcessorOutputViewDescription
        {
            ViewDimension = VideoProcessorOutputViewDimension.Texture2D,
            Texture2D = new Texture2DVideoProcessorOutputView { MipSlice = 0 },
        }, out var ov).CheckError();
        outputView = ov!;
        videoContext.VideoProcessorSetStreamFrameFormat(processor, 0, VideoFrameFormat.Progressive);
        videoContext.VideoProcessorSetStreamSourceRect(processor, 0, true, new RawRect(0, 0, inW, inH));
        videoContext.VideoProcessorSetStreamDestRect(processor, 0, true, new RawRect(0, 0, outW, outH));
        videoContext.VideoProcessorSetOutputTargetRect(processor, true, new RawRect(0, 0, outW, outH));
        videoContext.VideoProcessorSetStreamAutoProcessingMode(processor, 0, false);
        using var context1 = videoContext.QueryInterfaceOrNull<ID3D11VideoContext1>();
        if (context1 is not null)
        {
            context1.VideoProcessorSetStreamColorSpace1(processor, 0, ColorSpaceType.YcbcrStudioG22LeftP709);
            context1.VideoProcessorSetOutputColorSpace1(processor, ColorSpaceType.RgbFullG22NoneP709);
        }
    }

    /// <summary>The picture in <paramref name="target"/>'s <paramref name="slice"/> (the encoder's, just made) shrunk
    /// and its read-back begun, its thumbnail <paramref name="writer"/>'s at <paramref name="ms"/> into its segment.
    /// On the recorder's clock thread, as each frame is made.</summary>
    public void Take(ID3D11Texture2D target, uint slice, SegmentWriter writer, long ms)
    {
        var ctx = gpu.Context;
        ctx.CopySubresourceRegion(copy, 0, 0, 0, 0, target, slice, new Vortice.Mathematics.Box(0, 0, 0, inW, inH, 1));
        videoContext.VideoProcessorBlt(processor, outputView, 0, 1, [new VideoProcessorStream { Enable = true, InputSurface = inputView }]).CheckError();
        var staging = free.Count > 0 ? free.Pop() : gpu.Device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)outW,
            Height = (uint)outH,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Staging,
            CPUAccessFlags = CpuAccessFlags.Read,
        });
        ctx.CopyResource(staging, small);
        writer.ThumbAsked();
        pending.Enqueue(new Pending(staging, writer, ms));
    }

    /// <summary>The read-backs whose copies the GPU has done taken (each asked without waiting) and handed to a pool
    /// thread to be JPEG'd; <paramref name="all"/>: every one, waited for (the recording stopping).</summary>
    public void Collect(bool all = false)
    {
        var ctx = gpu.Context;
        while (pending.Count > 0)
        {
            var p = pending.Peek();
            MappedSubresource map;
            try
            {
                map = ctx.Map(p.Staging, 0, MapMode.Read, all ? Vortice.Direct3D11.MapFlags.None : Vortice.Direct3D11.MapFlags.DoNotWait);
            }
            catch (SharpGen.Runtime.SharpGenException ex) when (ex.HResult == unchecked((int)0x887A000A))
            {
                // (DXGI_ERROR_WAS_STILL_DRAWING: the next frame asks again)
                return;
            }

            pending.Dequeue();
            var rows = new byte[outW * outH * 4];
            unsafe
            {
                for (var y = 0; y < outH; y++)
                {
                    new ReadOnlySpan<byte>((byte*)map.DataPointer + (long)y * map.RowPitch, outW * 4).CopyTo(rows.AsSpan(y * outW * 4));
                }
            }

            ctx.Unmap(p.Staging, 0);
            free.Push(p.Staging);
            var (w, h, writer, ms) = (outW, outH, p.Writer, p.Ms);
            ThreadPool.QueueUserWorkItem(_ => writer.ThumbMade(ms, Jpeg(rows, w, h)));
        }
    }

    private byte[]? Jpeg(byte[] bgra, int w, int h)
    {
        try
        {
            using var stream = new MemoryStream();
            using var encoder = wic.CreateEncoder(ContainerFormat.Jpeg);
            encoder.Initialize(stream, BitmapEncoderCacheOption.NoCache);
            using var frame = encoder.CreateNewFrame(out var props);
            props.Set("ImageQuality", Quality);
            frame.Initialize(props);
            props.Dispose();
            frame.SetSize((uint)w, (uint)h);
            frame.SetPixelFormat(PixelFormat.Format32bppBGR);
            unsafe
            {
                fixed (byte* px = bgra)
                {
                    using var bitmap = wic.CreateBitmapFromMemory((uint)w, (uint)h, PixelFormat.Format32bppBGR, (uint)(w * 4), (uint)bgra.Length, px);
                    frame.WriteSource(bitmap);
                }
            }

            frame.Commit();
            encoder.Commit();
            return stream.ToArray();
        }
        catch (Exception)
        {
            return null;
        }
    }

    public void Dispose()
    {
        while (pending.Count > 0)
        {
            var p = pending.Dequeue();
            p.Writer.ThumbMade(p.Ms, null);
            p.Staging.Dispose();
        }

        while (free.Count > 0)
        {
            free.Pop().Dispose();
        }

        outputView.Dispose();
        inputView.Dispose();
        processor.Dispose();
        enumerator.Dispose();
        small.Dispose();
        copy.Dispose();
        videoContext.Dispose();
        videoDevice.Dispose();
        wic.Dispose();
    }
}
