using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.MediaFoundation;
using WinRT;

namespace Replay.Recording;

/// <summary>What the recorder tells of the computer's GPU.</summary>
public static class Graphics
{
    /// <summary>The default GPU shares the computer's memory: integrated graphics (<see cref="Gpu.SharedMemory"/>).</summary>
    public static bool Shared => Gpu.DefaultIsShared();
}

/// <summary>The Direct3D 11 device everything runs on: the capture's frames land in it, the video processor converts
/// them there and the encoder reads them from it (shared with Media Foundation by a DXGI device manager), so a frame
/// never leaves the GPU.</summary>
internal sealed class Gpu : IDisposable
{
    public ID3D11Device Device { get; }
    public ID3D11DeviceContext Context { get; }
    public IMFDXGIDeviceManager Manager { get; }
    public Windows.Graphics.DirectX.Direct3D11.IDirect3DDevice WinRtDevice { get; }

    private static int started;

    public static void StartMediaFoundation()
    {
        if (Interlocked.Exchange(ref started, 1) == 0)
        {
            MediaFactory.MFStartup(false).CheckError();
        }
    }

    public Gpu()
    {
        StartMediaFoundation();
        var levels = new[] { FeatureLevel.Level_11_1, FeatureLevel.Level_11_0 };
        D3D11.D3D11CreateDevice(IntPtr.Zero, DriverType.Hardware, DeviceCreationFlags.BgraSupport | DeviceCreationFlags.VideoSupport,
            levels, out var device, out var context).CheckError();
        Device = device!;
        Context = context!;
        // (the encoder's threads and ours use the immediate context: D3D serialises them)
        using (var mt = Device.QueryInterface<ID3D11Multithread>())
        {
            mt.SetMultithreadProtected(true);
        }

        Manager = MediaFactory.MFCreateDXGIDeviceManager();
        Manager.ResetDevice(Device).CheckError();

        using var dxgi = Device.QueryInterface<IDXGIDevice>();
        Native.Check(Native.CreateDirect3D11DeviceFromDXGIDevice(dxgi.NativePointer, out var inspectable), "CreateDirect3D11DeviceFromDXGIDevice");
        try
        {
            WinRtDevice = MarshalInterface<Windows.Graphics.DirectX.Direct3D11.IDirect3DDevice>.FromAbi(inspectable);
        }
        finally
        {
            Marshal.Release(inspectable);
        }
    }

    /// <summary>The GPU shares the computer's memory (D3D11's UnifiedMemoryArchitecture: integrated graphics, Intel's
    /// or AMD's in the processor). Its video engine most often both encodes and decodes, so recording and a video
    /// playing take turns on it; the window suggests a smaller picture there (state.json's sharedGpu).</summary>
    public bool SharedMemory => Device.CheckFeatureOptions2().UnifiedMemoryArchitecture;

    private static int shared = -1;

    /// <summary><see cref="SharedMemory"/> of the default GPU, looked at once (a device made and let go: false where none can be).</summary>
    public static bool DefaultIsShared()
    {
        if (shared < 0)
        {
            try
            {
                using var gpu = new Gpu();
                shared = gpu.SharedMemory ? 1 : 0;
            }
            catch (Exception)
            {
                shared = 0;
            }
        }

        return shared == 1;
    }

    /// <summary>The D3D11 texture behind a capture frame's surface (a new reference).</summary>
    public static unsafe ID3D11Texture2D TextureOf(Windows.Graphics.DirectX.Direct3D11.IDirect3DSurface surface)
    {
        var unknown = MarshalInterface<Windows.Graphics.DirectX.Direct3D11.IDirect3DSurface>.FromManaged(surface);
        try
        {
            var iid = Native.IID_IDirect3DDxgiInterfaceAccess;
            Native.Check(Marshal.QueryInterface(unknown, in iid, out var access), "IDirect3DDxgiInterfaceAccess");
            try
            {
                var texIid = Native.IID_ID3D11Texture2D;
                IntPtr texture;
                var getInterface = (delegate* unmanaged[Stdcall]<IntPtr, Guid*, IntPtr*, int>)(*(IntPtr**)access)[3];
                Native.Check(getInterface(access, &texIid, &texture), "IDirect3DDxgiInterfaceAccess.GetInterface");
                return new ID3D11Texture2D(texture);
            }
            finally
            {
                Marshal.Release(access);
            }
        }
        finally
        {
            Marshal.Release(unknown);
        }
    }

    public void Dispose()
    {
        (WinRtDevice as IDisposable)?.Dispose();
        Manager.Dispose();
        Context.ClearState();
        Context.Flush();
        Context.Dispose();
        Device.Dispose();
    }
}
