using System.Runtime.InteropServices;

namespace Replay.Recording;

/// <summary>Win32 entry points and the Media Foundation / Core Audio identifiers this library uses (values as the
/// Windows SDK's headers define them: mfapi.h, mfidl.h, mfreadwrite.h, mfobjects.h, codecapi.h, Audioclient.h,
/// mmdeviceapi.h, Windows.Graphics.Capture.Interop.h, windows.graphics.directx.direct3d11.interop.h).</summary>
internal static partial class Native
{
    // --- Media Foundation attributes ---
    public static readonly Guid MT_MAJOR_TYPE = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    public static readonly Guid MT_SUBTYPE = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    public static readonly Guid MT_AVG_BITRATE = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    public static readonly Guid MT_FRAME_SIZE = new("1652c33d-d6b2-4012-b834-72030849a37d");
    public static readonly Guid MT_FRAME_RATE = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    public static readonly Guid MT_PIXEL_ASPECT_RATIO = new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
    public static readonly Guid MT_INTERLACE_MODE = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    public static readonly Guid MT_MPEG2_PROFILE = new("ad76a80b-2d5c-4e0b-b375-64e520137036");
    public static readonly Guid MT_VIDEO_PRIMARIES = new("dbfbe4d7-0740-4ee0-8192-850ab0e21935");
    public static readonly Guid MT_TRANSFER_FUNCTION = new("5fb0fce9-be5c-4935-a811-ec838f8eed93");
    public static readonly Guid MT_YUV_MATRIX = new("3e23d450-2c75-4d25-a00e-b91670d12327");
    public static readonly Guid MT_VIDEO_NOMINAL_RANGE = new("c21b8ee5-b956-4071-8daf-325edf5cab11");
    public static readonly Guid MT_AUDIO_NUM_CHANNELS = new("37e48bf5-645e-4c5b-89de-ada9e29b696a");
    public static readonly Guid MT_AUDIO_SAMPLES_PER_SECOND = new("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
    public static readonly Guid MT_AUDIO_BITS_PER_SAMPLE = new("f2deb57f-40fa-4764-aa33-ed4f2d1ff669");
    public static readonly Guid MT_AUDIO_BLOCK_ALIGNMENT = new("322de230-9eeb-43bd-ab7a-ff412251541d");
    public static readonly Guid MT_AUDIO_AVG_BYTES_PER_SECOND = new("1aab75c8-cfef-451c-ab95-ac034b8e1731");
    public static readonly Guid MT_ALL_SAMPLES_INDEPENDENT = new("c9173739-5e56-461c-b713-46fb995cb95f");
    public static readonly Guid MT_AAC_PAYLOAD_TYPE = new("bfbabe79-7434-4d1c-94f0-72a3b9e17188");
    public static readonly Guid MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION = new("7632f0e6-9538-4d61-acda-ea29c8c14456");

    public static readonly Guid MediaType_Video = new("73646976-0000-0010-8000-00aa00389b71");
    public static readonly Guid MediaType_Audio = new("73647561-0000-0010-8000-00aa00389b71");
    public static readonly Guid VideoFormat_NV12 = FourCC("NV12");
    public static readonly Guid VideoFormat_H264 = FourCC("H264");
    public static readonly Guid VideoFormat_HEVC = FourCC("HEVC");
    public static readonly Guid AudioFormat_PCM = new("00000001-0000-0010-8000-00aa00389b71");
    public static readonly Guid AudioFormat_AAC = new("00001610-0000-0010-8000-00aa00389b71");

    public static readonly Guid TRANSCODE_CONTAINERTYPE = new("150ff23f-4abc-478b-ac4f-e1916fba1cca");
    public static readonly Guid TranscodeContainerType_MPEG4 = new("dc6cd05d-b9d0-40ef-bd35-fa622c1ab28a");
    public static readonly Guid READWRITE_ENABLE_HARDWARE_TRANSFORMS = new("a634a91c-822b-41b9-a494-4de4643612b0");
    public static readonly Guid SINK_WRITER_D3D_MANAGER = new("ec822da2-e1e9-4b29-a0d8-563c719f5269");
    public static readonly Guid SINK_WRITER_DISABLE_THROTTLING = new("08b845d8-2b74-4afe-9d53-be16d2d5ae4f");
    public static readonly Guid SA_D3D11_BINDFLAGS = new("eacf97ad-065c-4408-bee3-fdcbfd128be2");
    public static readonly Guid PD_DURATION = new("6c990d33-bb8e-477a-8598-0d5d96fcd88a");
    public static readonly Guid SampleExtension_CleanPoint = new("9cdf01d8-a0f0-43ba-b077-eaa06cbd728a");
    public static readonly Guid SampleExtension_Discontinuity = new("9cdf01d9-a0f0-43ba-b077-eaa06cbd728a");
    public static readonly Guid MFT_CATEGORY_VIDEO_DECODER = new("d6c02d4b-6833-45b4-971a-05a4b04bab91");

    // --- encoder properties (ICodecAPI's, given to the sink writer with the input type) ---
    public static readonly Guid AVEncCommonRateControlMode = new("1c0608e9-370c-4710-8a58-cb6181c42423");
    public static readonly Guid AVEncCommonMeanBitRate = new("f7222374-2144-4815-b550-a37f8e12ee52");
    public static readonly Guid AVEncCommonMaxBitRate = new("9651eae4-39b9-4ebf-85ef-d7f444ec7465");
    public static readonly Guid AVEncCommonBufferSize = new("0db96574-b6a4-4c8b-8106-3773de0310cd");
    public static readonly Guid AVEncMPVGOPSize = new("95f31b26-95a4-41aa-9303-246a7fc6eef1");
    public static readonly Guid AVEncMPVDefaultBPictureCount = new("8d390aac-dc5c-4200-b57f-814d04babab2");
    public static readonly Guid AVEncVideoMinQP = new("0ee22c6a-a37c-4568-b5f1-9d4c2b3ab886");
    public static readonly Guid AVEncVideoForceKeyFrame = new("398c1b98-8353-475a-9ef2-8f265d260345");
    public static readonly Guid IID_ICodecAPI = new("901db4c7-31ce-41a2-85dc-8fa0bf41b8da");

    // --- Core Audio ---
    public static readonly Guid CLSID_MMDeviceEnumerator = new("bcde0395-e52f-467c-8e3d-c4579291692e");
    public static readonly Guid IID_IMMDeviceEnumerator = new("a95664d2-9614-4f35-a746-de8db63617e6");
    public static readonly Guid IID_IAudioClient = new("1cb9ad4c-dbfa-4c32-b178-c2f568a703b2");
    public static readonly Guid IID_IAudioCaptureClient = new("c8adbd64-e71e-48a0-a4de-185c395cd317");
    public static readonly Guid IID_IActivateAudioInterfaceCompletionHandler = new("41d949ab-9862-444a-80f6-c261334da5eb");
    public static readonly Guid IID_IAgileObject = new("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90");
    public static readonly Guid IID_IUnknown = new("00000000-0000-0000-c000-000000000046");

    // --- capture interop ---
    public static readonly Guid IID_IGraphicsCaptureItemInterop = new("3628e81b-3cac-4c60-b7f4-23ce0e0c3356");
    public static readonly Guid IID_IGraphicsCaptureItem = new("79c3f95b-31f7-4ec2-a464-632ef5d30760");
    public static readonly Guid IID_IDirect3DDxgiInterfaceAccess = new("a9b3d012-3df2-4ee3-b8d1-8695f457d3c1");
    public static readonly Guid IID_ID3D11Texture2D = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

    private static Guid FourCC(string code)
    {
        var v = (uint)code[0] | (uint)code[1] << 8 | (uint)code[2] << 16 | (uint)code[3] << 24;
        return new Guid(v, 0x0000, 0x0010, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71);
    }

    public static ulong Pack(uint high, uint low) => (ulong)high << 32 | low;

    // --- Win32 ---
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect
    {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MonitorInfo
    {
        public int Size;
        public Rect Monitor;
        public Rect Work;
        public uint Flags;
    }

    [LibraryImport("user32.dll")]
    public static partial IntPtr MonitorFromPoint(long point, uint flags);

    [LibraryImport("user32.dll", EntryPoint = "GetMonitorInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetWindowRect(IntPtr hwnd, out Rect rect);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool IsWindow(IntPtr hwnd);

    [LibraryImport("user32.dll")]
    public static partial uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    [LibraryImport("d3d11.dll")]
    public static partial int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);

    [LibraryImport("combase.dll", StringMarshalling = StringMarshalling.Utf16)]
    public static partial int WindowsCreateString(string text, int length, out IntPtr hstring);

    [LibraryImport("combase.dll")]
    public static partial int WindowsDeleteString(IntPtr hstring);

    [LibraryImport("combase.dll")]
    public static partial int RoGetActivationFactory(IntPtr classId, in Guid iid, out IntPtr factory);

    [LibraryImport("ole32.dll")]
    public static partial int CoCreateInstance(in Guid clsid, IntPtr outer, uint context, in Guid iid, out IntPtr instance);

    [LibraryImport("ole32.dll")]
    public static partial void CoTaskMemFree(IntPtr p);

    [LibraryImport("ole32.dll")]
    public static partial int CoInitializeEx(IntPtr reserved, uint init);

    [LibraryImport("mmdevapi.dll", StringMarshalling = StringMarshalling.Utf16)]
    public static partial int ActivateAudioInterfaceAsync(string path, in Guid iid, IntPtr activationParams, IntPtr handler, out IntPtr operation);

    [LibraryImport("kernel32.dll", EntryPoint = "CreateWaitableTimerExW")]
    public static partial IntPtr CreateWaitableTimerEx(IntPtr attributes, IntPtr name, uint flags, uint access);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetWaitableTimer(IntPtr timer, in long dueTime, int period, IntPtr completion, IntPtr arg, [MarshalAs(UnmanagedType.Bool)] bool resume);

    [LibraryImport("kernel32.dll")]
    public static partial uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [LibraryImport("kernel32.dll")]
    public static unsafe partial uint WaitForMultipleObjects(uint count, IntPtr* handles, [MarshalAs(UnmanagedType.Bool)] bool waitAll, uint milliseconds);

    [LibraryImport("kernel32.dll", EntryPoint = "CreateEventW")]
    public static partial IntPtr CreateEvent(IntPtr attributes, [MarshalAs(UnmanagedType.Bool)] bool manualReset, [MarshalAs(UnmanagedType.Bool)] bool initialState, IntPtr name);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool CloseHandle(IntPtr handle);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetEvent(IntPtr handle);

    [LibraryImport("avrt.dll", EntryPoint = "AvSetMmThreadCharacteristicsW", StringMarshalling = StringMarshalling.Utf16)]
    public static partial IntPtr AvSetMmThreadCharacteristics(string task, ref uint index);

    [LibraryImport("avrt.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool AvRevertMmThreadCharacteristics(IntPtr handle);

    [LibraryImport("mfplat.dll")]
    public static partial int MFTEnumEx(Guid category, uint flags, IntPtr input, IntPtr output, out IntPtr activates, out uint count);

    [LibraryImport("mfplat.dll")]
    public static partial int MFTEnum2(Guid category, uint flags, IntPtr input, IntPtr output, IntPtr attributes, out IntPtr activates, out uint count);

    /// <summary>Now, in the 100 ns units of the performance counter (the clock capture frames and WASAPI packets are
    /// stamped with).</summary>
    public static long NowHns()
    {
        var t = System.Diagnostics.Stopwatch.GetTimestamp();
        var f = System.Diagnostics.Stopwatch.Frequency;
        return f == 10_000_000 ? t : (long)((Int128)t * 10_000_000 / f);
    }

    public static void Check(int hr, string what)
    {
        if (hr < 0)
        {
            throw new COMException(what, hr);
        }
    }

    public static unsafe void Release(IntPtr p)
    {
        if (p != IntPtr.Zero)
        {
            Marshal.Release(p);
        }
    }
}
