using System.Runtime.InteropServices;
using System.Text;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;

namespace Replay.Recording;

internal sealed class HdrToSdr : IDisposable
{
    private const float Knee = 0.98f;

    private const string Source = """
        Texture2D<float4> picture : register(t0);
        cbuffer Tone : register(b0) { float scale; float peak; float knee; float unused; };

        float4 vs(uint id : SV_VertexID) : SV_Position
        {
            float2 uv = float2((id << 1) & 2, id & 2);
            return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
        }

        float3 encode(float3 c)
        {
            return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055;
        }

        float4 ps(float4 position : SV_Position) : SV_Target
        {
            float3 c = picture.Load(int3(position.xy, 0)).rgb * scale;
            c = (c == c) ? clamp(c, -64, 1024) : 0;
            float y = dot(c, float3(0.2126, 0.7152, 0.0722));
            if (y <= 0)
            {
                return float4(0, 0, 0, 1);
            }

            // outside BT.709 (a primary below 0): toward the grey of its brightness, just far enough
            float lo = min(c.r, min(c.g, c.b));
            if (lo < 0)
            {
                c = y + (c - y) * (y / (y - lo));
            }

            // above the knee: knee..peak rolled into knee..1
            if (y > knee)
            {
                float x = (y - knee) / (peak - knee);
                float a = (peak - knee) / (1 - knee);
                float rolled = min(1, knee + (1 - knee) * a * x / (1 + (a - 1) * x));
                c *= rolled / y;
                y = rolled;
            }

            // a primary still above 1: toward white's grey of its brightness
            float hi = max(c.r, max(c.g, c.b));
            if (hi > 1)
            {
                c = y >= 1 ? 1 : y + (c - y) * ((1 - y) / (hi - y));
            }

            return float4(encode(saturate(c)), 1);
        }
        """;

    private readonly Gpu gpu;
    private readonly ID3D11Multithread multithread;
    private readonly ID3D11VertexShader vertexShader;
    private readonly ID3D11PixelShader pixelShader;
    private readonly ID3D11Buffer constants;
    private ID3D11Texture2D? output;
    private ID3D11RenderTargetView? outputView;
    private ID3D11Texture2D? inputTexture;
    private ID3D11ShaderResourceView? inputView;
    private int width, height;

    public HdrToSdr(Gpu gpu)
    {
        this.gpu = gpu;
        multithread = gpu.Device.QueryInterface<ID3D11Multithread>();
        vertexShader = gpu.Device.CreateVertexShader(Compile("vs", "vs_5_0"));
        pixelShader = gpu.Device.CreatePixelShader(Compile("ps", "ps_5_0"));
        constants = gpu.Device.CreateBuffer(new BufferDescription(16, BindFlags.ConstantBuffer, ResourceUsage.Default));
    }

    public void ConvertInto(ID3D11Texture2D source, ID3D11RenderTargetView targetView, int w, int h, DisplayColor display)
    {
        using var view = gpu.Device.CreateShaderResourceView(source);
        Draw(view, targetView, w, h, display);
    }

    public ID3D11Texture2D Convert(ID3D11Texture2D source, int w, int h, DisplayColor display)
    {
        if (output is null || w != width || h != height)
        {
            outputView?.Dispose();
            output?.Dispose();
            output = gpu.Device.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)w,
                Height = (uint)h,
                MipLevels = 1,
                ArraySize = 1,
                Format = Format.B8G8R8A8_UNorm,
                SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Default,
                BindFlags = BindFlags.RenderTarget | BindFlags.ShaderResource,
            });
            outputView = gpu.Device.CreateRenderTargetView(output);
            width = w;
            height = h;
        }

        if (inputView is null || inputTexture is null || inputTexture.NativePointer != source.NativePointer)
        {
            inputView?.Dispose();
            inputTexture?.Dispose();
            inputView = gpu.Device.CreateShaderResourceView(source);
            // AddRef source so its COM pointer cannot be recycled while the cached inputView holds it.
            source.AddRef();
            inputTexture = new ID3D11Texture2D(source.NativePointer);
        }

        Draw(inputView, outputView!, w, h, display);
        return output;
    }

    private void Draw(ID3D11ShaderResourceView sourceView, ID3D11RenderTargetView targetView, int w, int h, DisplayColor display)
    {
        var white = Math.Max(1f, display.SdrWhiteNits);
        Span<float> tone = [DisplayColor.ScRgbNits / white, Math.Max(Knee + 0.25f, display.PeakNits / white), Knee, 0];
        var context = gpu.Context;
        // Guard immediate context draw sequence; encoder threads share the same D3D11 device context.
        multithread.Enter();
        try
        {
            context.UpdateSubresource(tone, constants);
            context.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
            context.IASetInputLayout(null);
            context.VSSetShader(vertexShader);
            context.PSSetShader(pixelShader);
            context.PSSetShaderResource(0, sourceView);
            context.PSSetConstantBuffer(0, constants);
            context.RSSetViewport(new Viewport(0, 0, w, h));
            context.OMSetRenderTargets(targetView);
            context.Draw(3, 0);
            context.PSSetShaderResource(0, null!);
            context.OMSetRenderTargets((ID3D11RenderTargetView)null!);
        }
        finally
        {
            multithread.Leave();
        }
    }

    [DllImport("d3dcompiler_47.dll")]
    private static extern unsafe int D3DCompile(byte* data, nuint size, byte* name, IntPtr defines, IntPtr include, byte* entry, byte* target, uint flags1, uint flags2, out IntPtr code, out IntPtr errors);

    private static unsafe byte[] Compile(string entry, string target)
    {
        var source = Encoding.UTF8.GetBytes(Source);
        var name = Encoding.ASCII.GetBytes("HdrToSdr.hlsl\0");
        var entryBytes = Encoding.ASCII.GetBytes(entry + "\0");
        var targetBytes = Encoding.ASCII.GetBytes(target + "\0");
        IntPtr code, errors;
        int hr;
        fixed (byte* s = source, n = name, e = entryBytes, t = targetBytes)
        {
            // D3DCOMPILE_OPTIMIZATION_LEVEL3
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

    // ID3DBlob: GetBufferPointer (3), GetBufferSize (4)
    private static unsafe IntPtr BlobPointer(IntPtr blob) => ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr>)(*(IntPtr**)blob)[3])(blob);

    private static unsafe nuint BlobSize(IntPtr blob) => ((delegate* unmanaged[Stdcall]<IntPtr, nuint>)(*(IntPtr**)blob)[4])(blob);

    public void Dispose()
    {
        inputView?.Dispose();
        inputTexture?.Dispose();
        outputView?.Dispose();
        output?.Dispose();
        constants.Dispose();
        pixelShader.Dispose();
        vertexShader.Dispose();
        multithread.Dispose();
    }
}
