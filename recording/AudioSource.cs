using System.Runtime.InteropServices;

namespace Replay.Recording;

/// <summary>Which sound a source takes.</summary>
internal enum AudioKind
{
    /// <summary>What the default playback device plays (WASAPI loopback).</summary>
    System,

    /// <summary>The default microphone.</summary>
    Microphone,

    /// <summary>What one process and its children play, alone (process loopback).</summary>
    Process,
}

/// <summary>
/// One WASAPI capture stream in shared mode, asked for as 48 kHz stereo 32-bit float (the audio engine converts the
/// rate and the channels: AUTOCONVERTPCM), read by polling. Its packets come with the performance counter's time of
/// their first frame, which places them on the recording's timeline. Called through the COM interfaces' tables
/// directly (IMMDeviceEnumerator, IMMDevice, IAudioClient, IAudioCaptureClient), which trimming leaves as they are.
/// </summary>
internal sealed unsafe class AudioSource : IDisposable
{
    public const int Rate = 48000;

    private const uint ClsctxAll = 0x17;
    private const uint StreamLoopback = 0x00020000;
    private const uint StreamEventCallback = 0x00040000;
    private const uint StreamAutoConvertPcm = 0x80000000;
    private const uint StreamSrcDefaultQuality = 0x08000000;
    private const uint SessionDisplayHide = 0x20000000;
    private const uint SessionDisplayHideWhenExpired = 0x40000000;
    private const uint BufferSilent = 0x2;

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    private struct WaveFormat
    {
        public ushort Tag;
        public ushort Channels;
        public uint SamplesPerSec;
        public uint AvgBytesPerSec;
        public ushort BlockAlign;
        public ushort BitsPerSample;
        public ushort Size;
    }

    private IntPtr client;
    private IntPtr capture;
    private IntPtr wake;
    private readonly bool asFloat;
    private float[] scratch = new float[4096];

    public AudioKind Kind { get; }

    /// <summary>The device's id when it was opened (system sound, microphone): reopened when the default changes.</summary>
    public string DeviceId { get; }

    private AudioSource(AudioKind kind, IntPtr client, bool asFloat, string deviceId)
    {
        Kind = kind;
        this.client = client;
        this.asFloat = asFloat;
        DeviceId = deviceId;
    }

    private static T Slot<T>(IntPtr obj, int index) where T : unmanaged => ((T*)*(IntPtr*)obj)[index];

    private static WaveFormat Format(bool asFloat) => new()
    {
        // WAVE_FORMAT_IEEE_FLOAT, WAVE_FORMAT_PCM
        Tag = (ushort)(asFloat ? 3 : 1),
        Channels = 2,
        SamplesPerSec = Rate,
        BitsPerSample = (ushort)(asFloat ? 32 : 16),
        BlockAlign = (ushort)(asFloat ? 8 : 4),
        AvgBytesPerSec = (uint)(Rate * (asFloat ? 8 : 4)),
        Size = 0,
    };

    /// <summary>The id of the default device of <paramref name="flow"/> (0 playback, 1 capture); "" none.</summary>
    public static string DefaultDeviceId(int flow)
    {
        var device = DefaultDevice(flow);
        if (device == IntPtr.Zero)
        {
            return "";
        }

        try
        {
            return IdOf(device);
        }
        finally
        {
            Marshal.Release(device);
        }
    }

    private static string IdOf(IntPtr device)
    {
        IntPtr text;
        // IMMDevice::GetId (5)
        if (((delegate* unmanaged[Stdcall]<IntPtr, IntPtr*, int>)Slot<IntPtr>(device, 5))(device, &text) < 0 || text == IntPtr.Zero)
        {
            return "";
        }

        var id = Marshal.PtrToStringUni(text) ?? "";
        Native.CoTaskMemFree(text);
        return id;
    }

    private static IntPtr DefaultDevice(int flow)
    {
        Native.CoInitializeEx(IntPtr.Zero, 0);
        if (Native.CoCreateInstance(in Native.CLSID_MMDeviceEnumerator, IntPtr.Zero, ClsctxAll, in Native.IID_IMMDeviceEnumerator, out var enumerator) < 0)
        {
            return IntPtr.Zero;
        }

        try
        {
            IntPtr device;
            // IMMDeviceEnumerator::GetDefaultAudioEndpoint (4): eRender 0 / eCapture 1, eConsole 0
            var hr = ((delegate* unmanaged[Stdcall]<IntPtr, int, int, IntPtr*, int>)Slot<IntPtr>(enumerator, 4))(enumerator, flow, 0, &device);
            return hr < 0 ? IntPtr.Zero : device;
        }
        finally
        {
            Marshal.Release(enumerator);
        }
    }

    /// <summary>The default playback device's sound, or the default microphone; null when there is no such device.</summary>
    public static AudioSource? OpenDevice(AudioKind kind)
    {
        var device = DefaultDevice(kind == AudioKind.Microphone ? 1 : 0);
        if (device == IntPtr.Zero)
        {
            return null;
        }

        IntPtr client = IntPtr.Zero;
        try
        {
            var iid = Native.IID_IAudioClient;
            // IMMDevice::Activate (3)
            Native.Check(((delegate* unmanaged[Stdcall]<IntPtr, Guid*, uint, IntPtr, IntPtr*, int>)Slot<IntPtr>(device, 3))(device, &iid, ClsctxAll, IntPtr.Zero, &client), "IMMDevice.Activate");
            var source = new AudioSource(kind, client, true, IdOf(device));
            client = IntPtr.Zero;
            try
            {
                // Hide the loopback capture session from the Windows Volume Mixer so only the viewer's playback session appears.
                source.Initialize(kind == AudioKind.System ? (StreamLoopback | SessionDisplayHide | SessionDisplayHideWhenExpired) : 0);
                return source;
            }
            catch
            {
                source.Dispose();
                throw;
            }
        }
        finally
        {
            Native.Release(client);
            Marshal.Release(device);
        }
    }

    /// <summary>What process <paramref name="pid"/> and the processes it started play, nothing else.</summary>
    public static AudioSource OpenProcess(uint pid)
    {
        Native.CoInitializeEx(IntPtr.Zero, 0);
        // AUDIOCLIENT_ACTIVATION_PARAMS { AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK, { pid, INCLUDE_TARGET_PROCESS_TREE } }
        var parameters = stackalloc int[3] { 1, (int)pid, 0 };
        // PROPVARIANT { VT_BLOB, BLOB { cbSize, pBlobData } }
        var variant = stackalloc byte[24];
        new Span<byte>(variant, 24).Clear();
        *(ushort*)variant = 65;
        *(uint*)(variant + 8) = 12;
        *(IntPtr*)(variant + 16) = (IntPtr)parameters;

        var done = Native.CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero);
        var handler = CompletionHandler.Create(done);
        IntPtr operation = IntPtr.Zero, activated = IntPtr.Zero;
        try
        {
            Native.Check(Native.ActivateAudioInterfaceAsync("VAD\\Process_Loopback", in Native.IID_IAudioClient, (IntPtr)variant, handler, out operation), "ActivateAudioInterfaceAsync");
            if (Native.WaitForSingleObject(done, 5000) != 0)
            {
                throw new TimeoutException("process loopback activation did not complete");
            }

            int result;
            // IActivateAudioInterfaceAsyncOperation::GetActivateResult (3)
            Native.Check(((delegate* unmanaged[Stdcall]<IntPtr, int*, IntPtr*, int>)Slot<IntPtr>(operation, 3))(operation, &result, &activated), "GetActivateResult");
            Native.Check(result, "process loopback activation");
            var iid = Native.IID_IAudioClient;
            Native.Check(Marshal.QueryInterface(activated, in iid, out var client), "IAudioClient");
            var source = new AudioSource(AudioKind.Process, client, true, "process:" + pid);
            try
            {
                source.Initialize(StreamLoopback | StreamEventCallback);
                return source;
            }
            catch
            {
                source.Dispose();
                throw;
            }
        }
        finally
        {
            Native.Release(activated);
            Native.Release(operation);
            Marshal.Release(handler);
            Native.CloseHandle(done);
        }
    }

    private void Initialize(uint flags)
    {
        var format = Format(asFloat);
        // Use a fresh session GUID when hiding from the Volume Mixer so Windows never reuses a pre-existing visible default session.
        var session = (flags & SessionDisplayHide) != 0 ? Guid.NewGuid() : Guid.Empty;
        var sessionPtr = (flags & SessionDisplayHide) != 0 ? &session : null;
        // IAudioClient::Initialize (3): shared, 200 ms of buffer
        var hr = ((delegate* unmanaged[Stdcall]<IntPtr, int, uint, long, long, WaveFormat*, Guid*, int>)Slot<IntPtr>(client, 3))(
            client, 0, flags | StreamAutoConvertPcm | StreamSrcDefaultQuality, 2_000_000, 0, &format, sessionPtr);
        Native.Check(hr, "IAudioClient.Initialize");
        if ((flags & StreamEventCallback) != 0)
        {
            // (process loopback wants an event to signal; it is polled all the same)
            wake = Native.CreateEvent(IntPtr.Zero, false, false, IntPtr.Zero);
            // IAudioClient::SetEventHandle (13)
            Native.Check(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, int>)Slot<IntPtr>(client, 13))(client, wake), "IAudioClient.SetEventHandle");
        }

        var iid = Native.IID_IAudioCaptureClient;
        IntPtr service;
        // IAudioClient::GetService (14)
        Native.Check(((delegate* unmanaged[Stdcall]<IntPtr, Guid*, IntPtr*, int>)Slot<IntPtr>(client, 14))(client, &iid, &service), "IAudioClient.GetService");
        capture = service;
    }

    public void Start()
    {
        // IAudioClient::Start (10)
        Native.Check(((delegate* unmanaged[Stdcall]<IntPtr, int>)Slot<IntPtr>(client, 10))(client), "IAudioClient.Start");
    }

    /// <summary>Hands each waiting packet to <paramref name="take"/>: its time (100 ns, the performance counter's) and
    /// its frames, stereo float at 48 kHz. Throws when the device went away.</summary>
    public void Drain(Action<long, float[], int> take)
    {
        for (var guard = 0; guard < 64; guard++)
        {
            uint next;
            // IAudioCaptureClient::GetNextPacketSize (5)
            Native.Check(((delegate* unmanaged[Stdcall]<IntPtr, uint*, int>)Slot<IntPtr>(capture, 5))(capture, &next), "GetNextPacketSize");
            if (next == 0)
            {
                return;
            }

            byte* data;
            uint frames, flags;
            ulong devicePosition, qpc;
            // IAudioCaptureClient::GetBuffer (3)
            Native.Check(((delegate* unmanaged[Stdcall]<IntPtr, byte**, uint*, uint*, ulong*, ulong*, int>)Slot<IntPtr>(capture, 3))(
                capture, &data, &frames, &flags, &devicePosition, &qpc), "GetBuffer");
            try
            {
                var n = (int)frames;
                if (scratch.Length < n * 2)
                {
                    scratch = new float[n * 2];
                }

                if ((flags & BufferSilent) != 0 || data is null)
                {
                    Array.Clear(scratch, 0, n * 2);
                }
                else if (asFloat)
                {
                    new ReadOnlySpan<float>(data, n * 2).CopyTo(scratch);
                }
                else
                {
                    var pcm = new ReadOnlySpan<short>(data, n * 2);
                    for (var i = 0; i < n * 2; i++)
                    {
                        scratch[i] = pcm[i] / 32768f;
                    }
                }

                // (a packet's time missing: taken as having just ended)
                var at = qpc != 0 ? (long)qpc : Native.NowHns() - n * 10_000_000L / Rate;
                take(at, scratch, n);
            }
            finally
            {
                // IAudioCaptureClient::ReleaseBuffer (4)
                ((delegate* unmanaged[Stdcall]<IntPtr, uint, int>)Slot<IntPtr>(capture, 4))(capture, frames);
            }
        }
    }

    public void Dispose()
    {
        if (client != IntPtr.Zero)
        {
            // IAudioClient::Stop (11)
            ((delegate* unmanaged[Stdcall]<IntPtr, int>)Slot<IntPtr>(client, 11))(client);
        }

        Native.Release(capture);
        capture = IntPtr.Zero;
        Native.Release(client);
        client = IntPtr.Zero;
        if (wake != IntPtr.Zero)
        {
            Native.CloseHandle(wake);
            wake = IntPtr.Zero;
        }
    }

    /// <summary>
    /// The IActivateAudioInterfaceCompletionHandler ActivateAudioInterfaceAsync calls back: a COM object made by hand
    /// (its table of four functions, a reference count and the event it sets), agile, so any thread may call it.
    /// </summary>
    private static class CompletionHandler
    {
        private static readonly IntPtr Table = MakeTable();

        private static IntPtr MakeTable()
        {
            var table = (IntPtr*)NativeMemory.Alloc((nuint)(4 * sizeof(IntPtr)));
            table[0] = (IntPtr)(delegate* unmanaged[Stdcall]<IntPtr, Guid*, IntPtr*, int>)&QueryInterface;
            table[1] = (IntPtr)(delegate* unmanaged[Stdcall]<IntPtr, uint>)&AddRefExport;
            table[2] = (IntPtr)(delegate* unmanaged[Stdcall]<IntPtr, uint>)&Release;
            table[3] = (IntPtr)(delegate* unmanaged[Stdcall]<IntPtr, IntPtr, int>)&ActivateCompleted;
            return (IntPtr)table;
        }

        // the object: { table, references, event }
        public static IntPtr Create(IntPtr done)
        {
            var obj = (IntPtr*)NativeMemory.Alloc((nuint)(3 * sizeof(IntPtr)));
            obj[0] = Table;
            obj[1] = 1;
            obj[2] = done;
            return (IntPtr)obj;
        }

        [UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvStdcall)])]
        private static int QueryInterface(IntPtr self, Guid* iid, IntPtr* result)
        {
            if (*iid == Native.IID_IUnknown || *iid == Native.IID_IActivateAudioInterfaceCompletionHandler || *iid == Native.IID_IAgileObject)
            {
                AddRef(self);
                *result = self;
                return 0;
            }

            *result = IntPtr.Zero;
            // E_NOINTERFACE
            return unchecked((int)0x80004002);
        }

        [UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvStdcall)])]
        private static uint AddRefExport(IntPtr self) => AddRef(self);

        private static uint AddRef(IntPtr self) => (uint)Interlocked.Increment(ref ((long*)self)[1]);

        [UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvStdcall)])]
        private static uint Release(IntPtr self)
        {
            var left = Interlocked.Decrement(ref ((long*)self)[1]);
            if (left == 0)
            {
                NativeMemory.Free((void*)self);
            }

            return (uint)left;
        }

        [UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvStdcall)])]
        private static int ActivateCompleted(IntPtr self, IntPtr operation)
        {
            Native.SetEvent(((IntPtr*)self)[2]);
            return 0;
        }
    }
}
