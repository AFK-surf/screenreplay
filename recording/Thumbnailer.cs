using System.Runtime.InteropServices;
using System.Text;
using Vortice;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;
using Vortice.WIC;

namespace Replay.Recording;

/// <summary>
/// The segment's thumbnails made as it is recorded: each half second (of the segment's own time) the SDR BGRA picture
/// already made for the encoder is shrunk on the GPU by a lightweight shader to at most 384 × 216 BGRA (avoiding an
/// extra 4K NV12 copy texture and a second 4K ID3D11VideoProcessor) and read back a frame or two later, never waited
/// for; JPEG'd on a pool thread and kept by its segment's writer, which writes them beside the segment as its
/// <c>.thumbs</c> (<see cref="SegmentWriter"/>).
/// </summary>
internal sealed class Thumbnailer : IDisposable
{
    public const long StepHns = 5_000_000;
    private const int MaxW = 384, MaxH = 216;
    private const float Quality = 0.75f;

    private const string Source = """
        Texture2D<float4> picture : register(t0);
        SamplerState samp : register(s0);
        cbuffer Params : register(b0) { float2 uvMax; float2 halfStep; };

        struct VsOut
        {
            float4 pos : SV_Position;
            float2 uv : TEXCOORD0;
        };

        VsOut vs(uint id : SV_VertexID)
        {
            VsOut o;
            float2 uv = float2((id << 1) & 2, id & 2);
            o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
            o.uv = uv;
            return o;
        }

        float4 ps(VsOut i) : SV_Target
        {
            float2 uv = i.uv * uvMax;
            float2 d = halfStep;
            float3 c = 0.25 * (
                picture.SampleLevel(samp, clamp(uv + float2(-d.x, -d.y), 0, uvMax), 0).rgb +
                picture.SampleLevel(samp, clamp(uv + float2( d.x, -d.y), 0, uvMax), 0).rgb +
                picture.SampleLevel(samp, clamp(uv + float2(-d.x,  d.y), 0, uvMax), 0).rgb +
                picture.SampleLevel(samp, clamp(uv + float2( d.x,  d.y), 0, uvMax), 0).rgb);
            return float4(c, 1);
        }
        """;

    private readonly Gpu gpu;
    private readonly ID3D11Multithread multithread;
    private readonly ID3D11VertexShader vertexShader;
    private readonly ID3D11PixelShader pixelShader;
    private readonly ID3D11SamplerState sampler;
    private readonly ID3D11Buffer constants;
    private readonly int outW, outH;
    private readonly ID3D11Texture2D small;
    private readonly ID3D11RenderTargetView smallView;
    private ID3D11Texture2D? inputTexture;
    private ID3D11ShaderResourceView? inputView;
    private readonly IWICImagingFactory wic = new();

    // read-backs under way, oldest first: each its staging texture and whose it is
    private sealed record Pending(ID3D11Texture2D Staging, SegmentWriter Writer, long Ms);
    private readonly Queue<Pending> pending = new();
    private readonly Stack<ID3D11Texture2D> free = new();

    // (read-backs not taken yet at most this many: a GPU that holds them back does not have a staging texture made for
    // every frame meanwhile; a thumbnail is then left out)
    private const int MostPending = 4;

    // JPEGs being made on the thread pool: waited for before the WIC factory they use is let go of
    private int encoding;

    public Thumbnailer(Gpu gpu, int width, int height, int frameRate)
    {
        _ = frameRate;
        this.gpu = gpu;
        var inW = width & ~1;
        var inH = height & ~1;
        outW = MaxW;
        outH = (int)((long)MaxW * inH / inW);
        if (outH > MaxH)
        {
            outH = MaxH;
            outW = (int)((long)MaxH * inW / inH);
        }
        outW &= ~1;
        outH &= ~1;

        multithread = gpu.Device.QueryInterface<ID3D11Multithread>();
        vertexShader = gpu.Device.CreateVertexShader(Compile("vs", "vs_5_0"));
        pixelShader = gpu.Device.CreatePixelShader(Compile("ps", "ps_5_0"));
        constants = gpu.Device.CreateBuffer(new BufferDescription(16, BindFlags.ConstantBuffer, ResourceUsage.Default));
        sampler = gpu.Device.CreateSamplerState(new SamplerDescription
        {
            Filter = Filter.MinMagMipLinear,
            AddressU = TextureAddressMode.Clamp,
            AddressV = TextureAddressMode.Clamp,
            AddressW = TextureAddressMode.Clamp,
            MaxLOD = float.MaxValue,
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
        smallView = gpu.Device.CreateRenderTargetView(small);
    }

    /// <summary>The SDR BGRA picture in <paramref name="source"/> (<paramref name="srcW"/> × <paramref name="srcH"/>)
    /// shrunk and its read-back begun, its thumbnail <paramref name="writer"/>'s at <paramref name="ms"/> into its
    /// segment. On the recorder's clock thread, as each frame is made.</summary>
    public void Take(ID3D11Texture2D source, int srcW, int srcH, SegmentWriter writer, long ms)
    {
        if (pending.Count >= MostPending || srcW < 2 || srcH < 2)
        {
            return;
        }

        if (inputView is null || inputTexture is null || inputTexture.NativePointer != source.NativePointer)
        {
            inputView?.Dispose();
            inputTexture?.Dispose();
            inputView = gpu.Device.CreateShaderResourceView(source);
            // (held so that its pointer is not reused by another texture while the view is cached)
            source.AddRef();
            inputTexture = new ID3D11Texture2D(source.NativePointer);
        }

        var desc = source.Description;
        var uvMaxX = Math.Min(1f, (float)srcW / Math.Max(1u, desc.Width));
        var uvMaxY = Math.Min(1f, (float)srcH / Math.Max(1u, desc.Height));
        var scale = Math.Min((double)outW / srcW, (double)outH / srcH);
        var vw = Math.Max(1, Math.Min(outW, (int)Math.Round(srcW * scale)));
        var vh = Math.Max(1, Math.Min(outH, (int)Math.Round(srcH * scale)));
        var vx = (outW - vw) / 2;
        var vy = (outH - vh) / 2;
        Span<float> param = [uvMaxX, uvMaxY, uvMaxX * 0.25f / vw, uvMaxY * 0.25f / vh];

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

        var ctx = gpu.Context;
        multithread.Enter();
        try
        {
            if (vw < outW || vh < outH)
            {
                ctx.ClearRenderTargetView(smallView, new Color4(0f, 0f, 0f, 1f));
            }

            ctx.UpdateSubresource(param, constants);
            ctx.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
            ctx.IASetInputLayout(null);
            ctx.VSSetShader(vertexShader);
            ctx.PSSetShader(pixelShader);
            ctx.PSSetShaderResource(0, inputView);
            ctx.PSSetSampler(0, sampler);
            ctx.PSSetConstantBuffer(0, constants);
            ctx.RSSetViewport(new Viewport(vx, vy, vw, vh));
            ctx.OMSetRenderTargets(smallView);
            ctx.Draw(3, 0);
            ctx.PSSetShaderResource(0, null!);
            ctx.PSSetSampler(0, null!);
            ctx.OMSetRenderTargets((ID3D11RenderTargetView)null!);
            ctx.CopyResource(staging, small);
        }
        finally
        {
            multithread.Leave();
        }

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
            // (its rows in a pooled buffer: 331 KB each, twice a second, every one a new array on the large object heap
            // before, some 2.3 GB an hour for the GC)
            var size = outW * outH * 4;
            var rows = System.Buffers.ArrayPool<byte>.Shared.Rent(size);
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
            Interlocked.Increment(ref encoding);
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    writer.ThumbMade(ms, Jpeg(rows, size, w, h));
                }
                finally
                {
                    System.Buffers.ArrayPool<byte>.Shared.Return(rows);
                    Interlocked.Decrement(ref encoding);
                }
            });
        }
    }

    private byte[]? Jpeg(byte[] bgra, int size, int w, int h)
    {
        try
        {
            // (made at about its size: some 15-30 KB a thumbnail)
            using var stream = new MemoryStream(32 << 10);
            using var encoder = wic.CreateEncoder(ContainerFormat.Jpeg);
            encoder.Initialize(stream, BitmapEncoderCacheOption.NoCache);
            using var frame = encoder.CreateNewFrame(out var props);
            using (props)
            {
                props.Set("ImageQuality", Quality);
                frame.Initialize(props);
            }

            frame.SetSize((uint)w, (uint)h);
            frame.SetPixelFormat(PixelFormat.Format32bppBGR);
            unsafe
            {
                fixed (byte* px = bgra)
                {
                    using var bitmap = wic.CreateBitmapFromMemory((uint)w, (uint)h, PixelFormat.Format32bppBGR, (uint)(w * 4), (uint)size, px);
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

    [DllImport("d3dcompiler_47.dll")]
    private static extern unsafe int D3DCompile(byte* data, nuint size, byte* name, IntPtr defines, IntPtr include, byte* entry, byte* target, uint flags1, uint flags2, out IntPtr code, out IntPtr errors);

    private static unsafe byte[] Compile(string entry, string target)
    {
        var source = Encoding.UTF8.GetBytes(Source);
        var name = Encoding.ASCII.GetBytes("Thumbnailer.hlsl\0");
        var entryBytes = Encoding.ASCII.GetBytes(entry + "\0");
        var targetBytes = Encoding.ASCII.GetBytes(target + "\0");
        IntPtr code, errors;
        int hr;
        fixed (byte* s = source, n = name, e = entryBytes, t = targetBytes)
        {
            hr = D3DCompile(s, (nuint)source.Length, n, IntPtr.Zero, IntPtr.Zero, e, t, 1u << 15, 0, out code, out errors);
        }

        try
        {
            if (hr < 0)
            {
                var message = errors != IntPtr.Zero ? Marshal.PtrToStringAnsi(BlobPointer(errors), (int)BlobSize(errors)) : "";
                throw new COMException("D3DCompile " + entry + ": " + message, hr);
            }

            var bytes = new byte[BlobSize(code)];
            Marshal.Copy(BlobPointer(code), bytes, 0, bytes.Length);
            return bytes;
        }
        finally
        {
            Native.Release(code);
            Native.Release(errors);
        }
    }

    private static unsafe IntPtr BlobPointer(IntPtr blob) => ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr>)(*(IntPtr**)blob)[3])(blob);

    private static unsafe nuint BlobSize(IntPtr blob) => ((delegate* unmanaged[Stdcall]<IntPtr, nuint>)(*(IntPtr**)blob)[4])(blob);

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

        // (the JPEGs still being made finish before their factory goes: 2 s at most, else it is left to them)
        var until = Environment.TickCount64 + 2000;
        while (Volatile.Read(ref encoding) > 0 && Environment.TickCount64 < until)
        {
            Thread.Sleep(5);
        }

        var done = Volatile.Read(ref encoding) == 0;
        inputView?.Dispose();
        inputTexture?.Dispose();
        smallView.Dispose();
        small.Dispose();
        sampler.Dispose();
        constants.Dispose();
        pixelShader.Dispose();
        vertexShader.Dispose();
        multithread.Dispose();
        if (done)
        {
            wic.Dispose();
        }
    }
}
