using System.Runtime.InteropServices;
using Vortice.DXGI;
using Vortice.MediaFoundation;

namespace Replay.Recording;

// Single async hardware MFT shared across all segments: recreating an MFT per segment leaks named sections/mutexes on NVIDIA drivers. No B-frames so output order matches input order.
internal sealed unsafe class VideoEncoder : IDisposable
{
    private const int MF_E_NOTACCEPTING = unchecked((int)0xC00D36B5);
    private const int MF_E_TRANSFORM_NEED_MORE_INPUT = unchecked((int)0xC00D6D72);
    private const int MF_E_TRANSFORM_STREAM_CHANGE = unchecked((int)0xC00D6D61);
    private const uint METransformNeedInput = 601, METransformHaveOutput = 602, METransformDrainComplete = 603, MEError = 1;
    private static readonly Guid CategoryVideoEncoder = new("f79eac7d-e545-4387-bdee-d647d7bde42a");
    private static readonly Guid EnumAdapterLuid = new("1d39518c-e220-4da8-a07f-ba172552d6b1");
    private static readonly Guid TransformAsyncUnlock = new("e5666d6b-3422-4eb6-a421-da7db1f8e207");
    private static readonly Guid IID_IMFMediaEventGenerator = new("2cd0bd52-bcd5-4b89-b62c-eadc0c031e7d");
    private static readonly Guid IID_IMFShutdown = new("97ec2ea4-0e42-4937-97ac-9d6d328824e1");
    private static readonly Guid SampleExtension_DecodeTimestamp = new("73a954d4-09e2-4861-befc-94bd97c08e6e");

    private readonly IMFActivate activate;
    private readonly IMFTransform mft;
    private readonly IntPtr events;
    private readonly IntPtr codecApi;
    private readonly bool providesSamples;
    private readonly int outputSize;
    private readonly Thread pump;
    private readonly object inputGate = new();
    private readonly SemaphoreSlim needInput = new(0);
    private readonly ManualResetEventSlim drained = new(false);
    private readonly List<SegmentWriter> segments = new();
    private IMFMediaType outputType;
    private volatile Exception? fault;
    private volatile bool disposed;
    private long epochTicks = long.MinValue;
    private long lastInput = long.MinValue;

    public EncodeSettings Settings { get; }

    private VideoEncoder(IMFActivate activate, IMFTransform mft, EncodeSettings settings)
    {
        this.activate = activate;
        this.mft = mft;
        Settings = settings;
        var unknown = mft.NativePointer;
        Native.Check(Marshal.QueryInterface(unknown, in IID_IMFMediaEventGenerator, out events), "IMFMediaEventGenerator");
        Marshal.QueryInterface(unknown, in Native.IID_ICodecAPI, out codecApi);
        // IMFTransform::GetOutputStreamInfo (7): MFT_OUTPUT_STREAM_INFO { flags, size, alignment }
        var info = stackalloc uint[3];
        Native.Check(((delegate* unmanaged[Stdcall]<IntPtr, uint, uint*, int>)(*(IntPtr**)unknown)[7])(unknown, 0, info), "GetOutputStreamInfo");
        // MFT_OUTPUT_STREAM_PROVIDES_SAMPLES, MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES
        providesSamples = (info[0] & 0x300) != 0;
        outputSize = (int)Math.Max(info[1], 1u << 20);
        outputType = mft.GetOutputCurrentType(0);
        pump = new Thread(Pump) { IsBackground = true, Name = "recorder encoder", Priority = ThreadPriority.AboveNormal };
    }

    public static VideoEncoder Create(Gpu gpu, EncodeSettings settings)
    {
        Gpu.StartMediaFoundation();
        var candidates = Candidates(gpu, settings.Hevc);
        Exception? last = null;
        try
        {
            for (var i = 0; i < candidates.Count; i++)
            {
                var candidate = candidates[i]!;
                IMFTransform? mft = null;
                try
                {
                    mft = candidate.ActivateObject<IMFTransform>();
                    using (var attrs = mft.Attributes)
                    {
                        attrs.Set(TransformAsyncUnlock, 1u);
                    }

                    mft.ProcessMessage(TMessageType.MessageSetD3DManager, (nuint)gpu.Manager.NativePointer);
                    Configure(mft, settings);
                    var encoder = new VideoEncoder(candidate, mft, settings);
                    candidates[i] = null;
                    mft.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, 0);
                    mft.ProcessMessage(TMessageType.MessageNotifyStartOfStream, 0);
                    encoder.pump.Start();
                    return encoder;
                }
                catch (Exception ex)
                {
                    last = ex;
                    candidates[i] = null;
                    try
                    {
                        candidate.ShutdownObject();
                    }
                    catch (Exception)
                    {
                    }

                    mft?.Dispose();
                    candidate.Dispose();
                }
            }
        }
        finally
        {
            foreach (var other in candidates)
            {
                other?.Dispose();
            }
        }

        throw new NoEncoderException((settings.Hevc ? "no HEVC" : "no H.264") + " hardware encoder could be made" + (last is null ? "" : ": " + last.Message), last?.HResult ?? unchecked((int)0xC00D5212), candidates.Count == 0);
    }

    private static List<IMFActivate?> Candidates(Gpu gpu, bool hevc)
    {
        var info = stackalloc Guid[2] { Native.MediaType_Video, hevc ? Native.VideoFormat_HEVC : Native.VideoFormat_H264 };
        // MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER
        const uint flags = 0x4 | 0x40;
        var activates = IntPtr.Zero;
        uint count = 0;
        try
        {
            using var dxgi = gpu.Device.QueryInterface<IDXGIDevice>();
            using var adapter = dxgi.GetAdapter();
            var luid = adapter.Description.Luid;
            using var attrs = MediaFactory.MFCreateAttributes(1);
            attrs.Set(EnumAdapterLuid, (ulong)(uint)luid.HighPart << 32 | luid.LowPart);
            if (Native.MFTEnum2(CategoryVideoEncoder, flags, IntPtr.Zero, (IntPtr)info, attrs.NativePointer, out activates, out count) < 0)
            {
                count = 0;
            }
        }
        catch (Exception)
        {
            count = 0;
        }

        if (count == 0)
        {
            Native.Check(Native.MFTEnumEx(CategoryVideoEncoder, flags, IntPtr.Zero, (IntPtr)info, out activates, out count), "MFTEnumEx");
        }

        var list = new List<IMFActivate?>();
        for (var i = 0; i < count; i++)
        {
            list.Add(new IMFActivate(Marshal.ReadIntPtr(activates, i * IntPtr.Size)));
        }

        if (activates != IntPtr.Zero)
        {
            Native.CoTaskMemFree(activates);
        }

        return list;
    }

    private static void Configure(IMFTransform mft, EncodeSettings settings)
    {
        // Peak-constrained VBR, no auto-GOP (explicit keyframes), no B-frames (required for lossless segment joining).
        if (QueryCodecApi(mft) is var api && api != IntPtr.Zero)
        {
            try
            {
                SetUInt(api, Native.AVEncCommonRateControlMode, 1);
                SetUInt(api, Native.AVEncCommonMeanBitRate, (uint)settings.Bitrate);
                SetUInt(api, Native.AVEncCommonMaxBitRate, (uint)Math.Min(int.MaxValue, settings.Bitrate * 2L));
                SetUInt(api, Native.AVEncCommonBufferSize, (uint)settings.Bitrate);
                SetUInt(api, Native.AVEncMPVGOPSize, (uint)(settings.FrameRate * 600));
                SetUInt(api, Native.AVEncMPVDefaultBPictureCount, 0);
                SetUInt(api, Native.AVEncVideoMinQP, 22);
            }
            finally
            {
                Marshal.Release(api);
            }
        }

        using (var output = MediaFactory.MFCreateMediaType())
        {
            output.Set(Native.MT_MAJOR_TYPE, Native.MediaType_Video);
            output.Set(Native.MT_SUBTYPE, settings.Hevc ? Native.VideoFormat_HEVC : Native.VideoFormat_H264);
            output.Set(Native.MT_AVG_BITRATE, (uint)settings.Bitrate);
            // eAVEncH265VProfile_Main_420_8, eAVEncH264VProfile_High
            output.Set(Native.MT_MPEG2_PROFILE, settings.Hevc ? 1u : 100u);
            SegmentWriter.SetPicture(output, settings);
            mft.SetOutputType(0, output, 0);
        }

        using (var input = MediaFactory.MFCreateMediaType())
        {
            input.Set(Native.MT_MAJOR_TYPE, Native.MediaType_Video);
            input.Set(Native.MT_SUBTYPE, Native.VideoFormat_NV12);
            SegmentWriter.SetPicture(input, settings);
            mft.SetInputType(0, input, 0);
        }
    }

    private static IntPtr QueryCodecApi(IMFTransform mft) =>
        Marshal.QueryInterface(mft.NativePointer, in Native.IID_ICodecAPI, out var api) < 0 ? IntPtr.Zero : api;

    // ICodecAPI::SetValue (9) with VARIANT VT_UI4.
    private static int SetUInt(IntPtr api, Guid name, uint v)
    {
        var value = stackalloc byte[24];
        new Span<byte>(value, 24).Clear();
        *(ushort*)value = 19;
        *(uint*)(value + 8) = v;
        return ((delegate* unmanaged[Stdcall]<IntPtr, Guid*, void*, int>)(*(IntPtr**)api)[9])(api, &name, value);
    }

    public IMFMediaType OutputType()
    {
        lock (segments)
        {
            var copy = MediaFactory.MFCreateMediaType();
            outputType.CopyAllItems(copy);
            return copy;
        }
    }

    internal long Attach(SegmentWriter segment, DateTimeOffset startUtc)
    {
        lock (segments)
        {
            if (epochTicks == long.MinValue)
            {
                epochTicks = startUtc.UtcTicks;
            }

            segments.Add(segment);
            return startUtc.UtcTicks - epochTicks;
        }
    }

    internal void Detach(SegmentWriter segment)
    {
        lock (segments)
        {
            segments.Remove(segment);
        }
    }

    public bool ReadyWithin(TimeSpan wait)
    {
        if (!needInput.Wait(wait))
        {
            return false;
        }

        // Peek only: restore semaphore count so Encode consumes the input request.
        needInput.Release();
        return true;
    }

    private static readonly int slowFor = int.TryParse(Environment.GetEnvironmentVariable("REPLAY_TEST_SLOW_ENCODER"), out var ms) ? ms : 0;

    private static readonly int slowKey = int.TryParse(Environment.GetEnvironmentVariable("REPLAY_TEST_SLOW_KEY"), out var km) ? km : 0;

    private volatile bool keyIn;

    public void Encode(IMFSample sample, long time, long duration, bool key)
    {
        lock (inputGate)
        {
            ThrowIfFaulted();
            // Enforce strictly monotonic timestamps across segment boundaries.
            time = Math.Max(time, lastInput == long.MinValue ? time : lastInput + 1);
            sample.SampleTime = time;
            sample.SampleDuration = duration;
            for (var tries = 0; ; tries++)
            {
                if (!needInput.Wait(TimeSpan.FromSeconds(5)))
                {
                    ThrowIfFaulted();
                    throw new TimeoutException("the encoder took no frame for 5 s");
                }

                ThrowIfFaulted();
                if (key && codecApi != IntPtr.Zero)
                {
                    SetUInt(codecApi, Native.AVEncVideoForceKeyFrame, 1);
                }

                keyIn = key && slowKey > 0;

                // IMFTransform::ProcessInput (24)
                var hr = ((delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, uint, int>)(*(IntPtr**)mft.NativePointer)[24])(mft.NativePointer, 0, sample.NativePointer, 0);
                if (hr == MF_E_NOTACCEPTING && tries < 8)
                {
                    // Stale METransformNeedInput left over from before a drain.
                    continue;
                }

                Native.Check(hr, "the encoder's ProcessInput");
                lastInput = time;
                return;
            }
        }
    }

    public void Drain()
    {
        lock (inputGate)
        {
            if (disposed || fault is not null)
            {
                return;
            }

            drained.Reset();
            mft.ProcessMessage(TMessageType.MessageCommandDrain, 0);
            drained.Wait(TimeSpan.FromSeconds(3));
            // After drain, an async MFT will not request input again until MessageNotifyStartOfStream.
            mft.ProcessMessage(TMessageType.MessageNotifyStartOfStream, 0);
        }
    }

    private void ThrowIfFaulted()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (fault is { } ex)
        {
            throw new InvalidOperationException("the encoder failed: " + ex.Message, ex);
        }
    }

    private void Pump()
    {
        try
        {
            while (!disposed)
            {
                IntPtr ev;
                // IMFMediaEventGenerator::GetEvent (3), waiting (MF_E_SHUTDOWN once the encoder is shut down)
                var hr = ((delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr*, int>)(*(IntPtr**)events)[3])(events, 0, &ev);
                if (hr < 0)
                {
                    if (!disposed)
                    {
                        fault = new COMException("the encoder's events", hr);
                    }

                    break;
                }

                uint type;
                int status;
                // IMFMediaEvent::GetType (33), GetStatus (35)
                ((delegate* unmanaged[Stdcall]<IntPtr, uint*, int>)(*(IntPtr**)ev)[33])(ev, &type);
                ((delegate* unmanaged[Stdcall]<IntPtr, int*, int>)(*(IntPtr**)ev)[35])(ev, &status);
                Marshal.Release(ev);
                if (status < 0 || type == MEError)
                {
                    fault = new COMException("the encoder failed", status < 0 ? status : unchecked((int)0x80004005));
                    break;
                }

                switch (type)
                {
                    case METransformNeedInput:
                        if (slowFor > 0)
                        {
                            Thread.Sleep(slowFor);
                        }

                        if (keyIn)
                        {
                            keyIn = false;
                            Thread.Sleep(slowKey);
                        }

                        needInput.Release();
                        break;
                    case METransformHaveOutput:
                        Output();
                        break;
                    case METransformDrainComplete:
                        drained.Set();
                        break;
                }
            }
        }
        catch (Exception ex)
        {
            if (!disposed)
            {
                fault = ex;
            }
        }
        finally
        {
            needInput.Release(64);
            drained.Set();
            lock (segments)
            {
                foreach (var segment in segments)
                {
                    segment.EncoderGone();
                }
            }
        }
    }

    private void Output()
    {
        var buffer = stackalloc byte[32];
        IMFSample? own = null;
        while (true)
        {
            // MFT_OUTPUT_DATA_BUFFER { stream 0, sample, status, events }
            new Span<byte>(buffer, 32).Clear();
            if (!providesSamples)
            {
                own ??= OwnSample();
                *(IntPtr*)(buffer + 8) = own.NativePointer;
            }

            uint status;
            // IMFTransform::ProcessOutput (25)
            var hr = ((delegate* unmanaged[Stdcall]<IntPtr, uint, uint, void*, uint*, int>)(*(IntPtr**)mft.NativePointer)[25])(mft.NativePointer, 0, 1, buffer, &status);
            var made = *(IntPtr*)(buffer + 8);
            var collection = *(IntPtr*)(buffer + 24);
            if (collection != IntPtr.Zero)
            {
                Marshal.Release(collection);
            }

            if (hr == MF_E_TRANSFORM_STREAM_CHANGE)
            {
                using var type = mft.GetOutputAvailableType(0, 0);
                mft.SetOutputType(0, type, 0);
                lock (segments)
                {
                    outputType.Dispose();
                    outputType = mft.GetOutputCurrentType(0);
                }

                continue;
            }

            if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT)
            {
                own?.Dispose();
                return;
            }

            Native.Check(hr, "the encoder's ProcessOutput");
            using var sample = providesSamples ? new IMFSample(made) : own!;
            Route(sample);
            return;
        }
    }

    private IMFSample OwnSample()
    {
        var sample = MediaFactory.MFCreateSample();
        using var memory = MediaFactory.MFCreateMemoryBuffer(outputSize);
        sample.AddBuffer(memory);
        return sample;
    }

    private void Route(IMFSample sample)
    {
        var time = sample.SampleTime;
        SegmentWriter? target = null;
        long start = 0;
        lock (segments)
        {
            foreach (var segment in segments)
            {
                if (segment.EncoderStart <= time && (target is null || segment.EncoderStart >= start))
                {
                    target = segment;
                    start = segment.EncoderStart;
                }
            }
        }

        if (target is null)
        {
            return;
        }

        sample.SampleTime = time - start;
        // Query DTS directly via IMFAttributes::GetUINT64 (8) to avoid Vortice throwing/catching on every frame when absent.
        var key = SampleExtension_DecodeTimestamp;
        ulong dts;
        var got = ((delegate* unmanaged[Stdcall]<IntPtr, Guid*, ulong*, int>)(*(IntPtr**)sample.NativePointer)[8])(sample.NativePointer, &key, &dts);
        if (got >= 0)
        {
            sample.Set(SampleExtension_DecodeTimestamp, (ulong)Math.Max(0, (long)dts - start));
        }

        target.WriteEncoded(sample);
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        lock (inputGate)
        {
            disposed = true;
        }

        try
        {
            mft.ProcessMessage(TMessageType.MessageNotifyEndOfStream, 0);
            mft.ProcessMessage(TMessageType.MessageNotifyEndStreaming, 0);
        }
        catch (Exception)
        {
        }

        if (Marshal.QueryInterface(mft.NativePointer, in IID_IMFShutdown, out var shutdown) >= 0)
        {
            ((delegate* unmanaged[Stdcall]<IntPtr, int>)(*(IntPtr**)shutdown)[3])(shutdown);
            Marshal.Release(shutdown);
        }

        try
        {
            activate.ShutdownObject();
        }
        catch (Exception)
        {
        }

        if (!pump.Join(TimeSpan.FromSeconds(2)))
        {
            // Pump thread hung in driver: leak COM refs rather than releasing under it and crashing.
            return;
        }

        Native.Release(codecApi);
        Marshal.Release(events);
        outputType.Dispose();
        mft.Dispose();
        activate.Dispose();
        // Leave needInput/drained to GC in case a hung pump still signals them.
    }
}

public sealed class NoEncoderException(string message, int hresult, bool none) : COMException(message, hresult)
{
    public bool None { get; } = none;
}
