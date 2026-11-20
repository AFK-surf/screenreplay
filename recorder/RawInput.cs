using System.Buffers.Binary;
using System.Runtime.InteropServices;
using Replay.Recording;

namespace Replay.Recorder;

/// <summary>
/// How busy the mouse, the keyboard and game controllers are, while recording (the replay window's timeline marks it):
/// Raw Input on the recorder's window (RIDEV_INPUTSINK: told whichever window has the focus), not low-level hooks,
/// which every key and move would wait on (a game's input delayed) and which antivirus programs take for a keylogger.
/// Only counts go on to <see cref="Activity"/>: a key's press (not its repeats while held: which keys are down is
/// known here for that alone, never kept), mouse buttons pressed and the wheel's notches (not its movement); a gamepad's
/// or joystick's HID reports to <see cref="HidPads"/>, XInput's pads read by <see cref="XInputPads"/>. Listening only
/// while recording: paused, locked or off, nothing is asked of Windows.
/// </summary>
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

    // keys down now, by scan code (and E0's): a make while down is the key repeating
    private readonly bool[] down = new bool[512];
    private bool listening;

    // (what WM_INPUT brings read into: a mouse's or a key's 48 bytes at most, a gamepad's reports more; made larger
    // only the first time one does not fit)
    private byte[] buffer = new byte[1024];

    public InputActivity Activity { get; } = new();

    /// <summary>Game controllers that are not XInput's, from their HID reports.</summary>
    public HidPads Pads { get; }

    public RawInput(MessageWindow window, Action<string> log)
    {
        this.window = window;
        this.log = log;
        Pads = new HidPads(Activity, log);
    }

    /// <summary>Listening while recording, not otherwise.</summary>
    public bool Listening
    {
        get => listening;
        set
        {
            if (value == listening)
            {
                return;
            }

            // (mouse 1/2 and keyboard 1/6; removing takes no window)
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

    /// <summary>Generic Desktop's <paramref name="a"/> and <paramref name="b"/> registered with <paramref name="flags"/>
    /// to the window, or removed.</summary>
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

    /// <summary>
    /// Gamepads' and joysticks' reports (1/5, 1/4) asked for only while one that is not XInput's is there, looked for
    /// every 2 s in the list of devices: an XInput pad's own HID side sends ~1000 reports a second even at rest, which
    /// cost the recorder some 2% of a core taken and passed over (2026-11-14), and XInputPads reads it anyway.
    /// </summary>
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

    /// <summary>A WM_INPUT's lParam: what came counted. (Read into a buffer kept, nothing allocated; the window
    /// procedure hands the message on to DefWindowProc after it.)</summary>
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
            // (larger than any before: the buffer made to fit, once)
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
        // (how long ago it came: the window's thread may have been busy a moment)
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

    /// <summary>A WM_INPUT_DEVICE_CHANGE: a gamepad or joystick came (GIDC_ARRIVAL, 1) or went.</summary>
    public void DeviceChanged(IntPtr wParam, IntPtr lParam)
    {
        if (listening)
        {
            Pads.Changed(wParam == 1, lParam);
        }
    }

    /// <summary>A mouse's buttons pressed and its wheel; its movement not (the user, 2026-11-14): a report that only
    /// moves (nearly all of them) is let go of at its first look.</summary>
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
            // RI_KEY_BREAK: let go
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
