using System.Buffers.Binary;
using System.Runtime.InteropServices;
using Replay.Recording;

namespace Replay.Recorder;

// Uses Raw Input (RIDEV_INPUTSINK) instead of LL hooks to avoid input latency and AV false positives.
internal sealed class RawInput : IDisposable
{
    public const uint WmInput = 0x00FF;
    public const uint WmInputDeviceChange = 0x00FE;
    private const uint RidevInputSink = 0x100;
    private const uint RidevDevNotify = 0x2000;
    private const uint RidevRemove = 0x1;
    private const uint RidInput = 0x10000003;
    private const int HeaderSize = 8 + 2 * 8;

    [StructLayout(LayoutKind.Sequential)]
    private struct Device
    {
        public ushort UsagePage;
        public ushort Usage;
        public uint Flags;
        public IntPtr Target;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterRawInputDevices([In] Device[] devices, uint count, uint size);

    [DllImport("user32.dll")]
    private static extern uint GetRawInputData(IntPtr input, uint command, ref byte data, ref uint size, uint headerSize);

    [DllImport("user32.dll")]
    private static extern uint GetRawInputData(IntPtr input, uint command, IntPtr data, ref uint size, uint headerSize);

    [DllImport("user32.dll")]
    private static extern int GetMessageTime();

    private readonly MessageWindow window;
    private readonly Action<string> log;
    private nuint padCheck;
    private bool padsOn;

    private readonly bool[] down = new bool[512];
    private bool listening;

    private byte[] buffer = new byte[1024];

    public InputActivity Activity { get; } = new();

    public HidPads Pads { get; }

    public RawInput(MessageWindow window, Action<string> log)
    {
        this.window = window;
        this.log = log;
        Pads = new HidPads(Activity, log);
    }

    public bool Listening
    {
        get => listening;
        set
        {
            if (value == listening)
            {
                return;
            }

            if (!Register(value, RidevInputSink, 0x02, 0x06))
            {
                return;
            }

            listening = value;
            Array.Clear(down);
            Pads.Forget();
            if (value)
            {
                CheckPads();
                padCheck = window.Every(2000, CheckPads);
            }
            else
            {
                window.Stop(padCheck);
                padCheck = 0;
                if (padsOn)
                {
                    padsOn = !Register(false, 0, 0x04, 0x05);
                }
            }
        }
    }

    private bool Register(bool on, uint flags, ushort a, ushort b)
    {
        var f = on ? flags : RidevRemove;
        var target = on ? window.Handle : IntPtr.Zero;
        var devices = new[]
        {
            new Device { UsagePage = 0x01, Usage = a, Flags = f, Target = target },
            new Device { UsagePage = 0x01, Usage = b, Flags = f, Target = target },
        };
        if (!RegisterRawInputDevices(devices, 2, (uint)Marshal.SizeOf<Device>()))
        {
            log($"raw input 0x{a:x}/0x{b:x} {(on ? "on" : "off")} failed: {Marshal.GetLastWin32Error()}");
            return false;
        }

        return true;
    }

    // Only subscribe to HID gamepad/joystick reports when a non-XInput pad is present; XInput HID interfaces spam ~1000 reports/s at rest.
    private void CheckPads()
    {
        var want = Pads.AnyToRead();
        if (want != padsOn && Register(want, RidevInputSink | RidevDevNotify, 0x04, 0x05))
        {
            padsOn = want;
            if (!want)
            {
                Pads.Forget();
            }

            log($"controller (HID) reports {(want ? "read" : "not asked for")}");
        }
    }

    public void Handle(IntPtr lParam)
    {
        if (!listening)
        {
            return;
        }

        var size = (uint)buffer.Length;
        var got = GetRawInputData(lParam, RidInput, ref buffer[0], ref size, (uint)HeaderSize);
        if (got == uint.MaxValue)
        {
            size = 0;
            GetRawInputData(lParam, RidInput, IntPtr.Zero, ref size, (uint)HeaderSize);
            if (size <= buffer.Length || size > 1 << 20)
            {
                return;
            }

            buffer = new byte[size];
            got = GetRawInputData(lParam, RidInput, ref buffer[0], ref size, (uint)HeaderSize);
        }

        if (got == uint.MaxValue || got < HeaderSize + 8)
        {
            return;
        }

        var data = buffer.AsSpan(0, (int)got);
        var lag = Math.Clamp(unchecked(Environment.TickCount - GetMessageTime()), 0, 5000);
        var type = BinaryPrimitives.ReadUInt32LittleEndian(data);
        if (type == 0 && got >= HeaderSize + 24)
        {
            Mouse(data[HeaderSize..], lag);
        }
        else if (type == 1 && got >= HeaderSize + 16)
        {
            Keyboard(data[HeaderSize..], lag);
        }
        else if (type == 2)
        {
            Pads.Report(MemoryMarshal.Read<IntPtr>(data[8..]), data[HeaderSize..], lag);
        }
    }

    public void DeviceChanged(IntPtr wParam, IntPtr lParam)
    {
        if (listening)
        {
            Pads.Changed(wParam == 1, lParam);
        }
    }

    private void Mouse(Span<byte> m, int lag)
    {
        var buttons = BinaryPrimitives.ReadUInt16LittleEndian(m[4..]);
        if (buttons == 0)
        {
            return;
        }

        var wheelData = BinaryPrimitives.ReadInt16LittleEndian(m[6..]);

        // RI_MOUSE_LEFT/RIGHT/MIDDLE/BUTTON_4/BUTTON_5_DOWN
        var pressed = System.Numerics.BitOperations.PopCount(buttons & 0x0155u);
        if (pressed > 0)
        {
            Activity.Click(pressed, lag);
        }

        // RI_MOUSE_WHEEL, RI_MOUSE_HWHEEL
        if ((buttons & 0x0C00) != 0 && wheelData != 0)
        {
            Activity.Wheel(wheelData, lag);
        }
    }

    private void Keyboard(Span<byte> k, int lag)
    {
        var make = BinaryPrimitives.ReadUInt16LittleEndian(k);
        var flags = BinaryPrimitives.ReadUInt16LittleEndian(k[2..]);
        var vkey = BinaryPrimitives.ReadUInt16LittleEndian(k[6..]);
        // (0xFF: no key, part of another's sequence; KEYBOARD_OVERRUN_MAKE_CODE)
        if (vkey == 0xFF || make == 0xFF)
        {
            return;
        }

        var key = (make & 0xFF) | ((flags & 0x02) != 0 ? 0x100 : 0);
        if ((flags & 0x01) != 0)
        {
            down[key] = false;
            return;
        }

        if (down[key])
        {
            return;
        }

        down[key] = true;
        Activity.Key(lag);
    }

    public void Dispose()
    {
        Listening = false;
    }
}
