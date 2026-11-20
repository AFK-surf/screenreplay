using System.Runtime.InteropServices;
using Replay.Recording;

namespace Replay.Recorder;

/// <summary>
/// Game controllers that are not XInput's (a DualSense or DualShock, a joystick), from their HID reports as Raw Input
/// brings them to the recorder's window (Generic Desktop's gamepad and joystick, RIDEV_INPUTSINK: in the background, a
/// game in front). Each device's reports read by hid.dll from its preparsed data (<see cref="HidLayout"/>: buttons,
/// axes, hats; never compared byte by byte, a DualSense's motion sensors and timestamps changing in every report), what
/// changed going to <see cref="InputActivity"/> as counts. A device whose name says it is an XInput one ("IG_") is
/// passed over: <see cref="XInputPads"/> counts it. What a device needs is made as its first report comes, nothing as
/// the rest do.
/// </summary>
internal sealed class HidPads(InputActivity activity, Action<string> log)
{
    private const uint RidiPreparsedData = 0x20000005;
    private const uint RidiDeviceName = 0x20000007;
    private const int HidpStatusSuccess = 0x00110000;

    [DllImport("user32.dll", EntryPoint = "GetRawInputDeviceInfoW")]
    private static extern uint GetRawInputDeviceInfo(IntPtr device, uint command, ref byte data, ref uint size);

    [DllImport("user32.dll", EntryPoint = "GetRawInputDeviceInfoW")]
    private static extern uint GetRawInputDeviceInfo(IntPtr device, uint command, IntPtr data, ref uint size);

    [DllImport("hid.dll")]
    private static extern int HidP_GetCaps(ref byte preparsed, ref byte caps);

    [DllImport("hid.dll")]
    private static extern int HidP_GetButtonCaps(int type, ref byte caps, ref ushort length, ref byte preparsed);

    [DllImport("hid.dll")]
    private static extern int HidP_GetValueCaps(int type, ref byte caps, ref ushort length, ref byte preparsed);

    [DllImport("hid.dll")]
    private static extern uint HidP_MaxDataListLength(int type, ref byte preparsed);

    [DllImport("hid.dll")]
    private static extern int HidP_GetData(int type, ref byte data, ref uint length, ref byte preparsed, ref byte report, uint reportLength);

    /// <summary>A device's reports and how to read them; null for one passed over.</summary>
    private sealed class Device(byte[] preparsed, HidLayout layout, byte[] data)
    {
        public readonly byte[] Preparsed = preparsed;
        public readonly HidLayout Layout = layout;
        public readonly byte[] Data = data;
    }

    [DllImport("user32.dll")]
    private static extern uint GetRawInputDeviceList(ref byte list, ref uint count, uint size);

    [DllImport("user32.dll")]
    private static extern uint GetRawInputDeviceList(IntPtr list, ref uint count, uint size);

    private const uint RidiDeviceInfo = 0x2000000b;

    private readonly Dictionary<IntPtr, Device?> devices = [];

    // the devices listed, each whether it is a gamepad or joystick not XInput's, and the last look it was seen in
    private readonly Dictionary<IntPtr, (bool Read, int Seen)> listed = [];
    private byte[] list = new byte[64 * 16];
    private int look;

    /// <summary>Whether a gamepad or joystick that is not XInput's is there now (each device asked about once).</summary>
    public bool AnyToRead()
    {
        var count = 0u;
        if (GetRawInputDeviceList(IntPtr.Zero, ref count, 16) == uint.MaxValue)
        {
            return false;
        }

        if (count * 16 > list.Length)
        {
            list = new byte[count * 16 + 16 * 16];
        }

        count = (uint)(list.Length / 16);
        var n = GetRawInputDeviceList(ref list[0], ref count, 16);
        if (n == uint.MaxValue)
        {
            return false;
        }

        look++;
        var any = false;
        for (var i = 0; i < n; i++)
        {
            // RAWINPUTDEVICELIST: hDevice, dwType (RIM_TYPEHID 2)
            var device = MemoryMarshal.Read<IntPtr>(list.AsSpan(i * 16));
            if (BitConverter.ToUInt32(list, i * 16 + 8) != 2)
            {
                continue;
            }

            if (!listed.TryGetValue(device, out var known))
            {
                known = (IsPad(device), look);
            }

            listed[device] = (known.Read, look);
            any |= known.Read;
        }

        // (those no longer listed forgotten)
        foreach (var (device, entry) in listed)
        {
            if (entry.Seen != look)
            {
                listed.Remove(device);
            }
        }

        return any;
    }

    /// <summary>A gamepad (1/5) or joystick (1/4) whose name does not say XInput's ("IG_").</summary>
    private static bool IsPad(IntPtr device)
    {
        // RID_DEVICE_INFO: cbSize, dwType, then the HID's vendor, product, version, usUsagePage, usUsage
        var info = new byte[32];
        BitConverter.TryWriteBytes(info, 32u);
        var size = 32u;
        if (GetRawInputDeviceInfo(device, RidiDeviceInfo, ref info[0], ref size) == uint.MaxValue)
        {
            return false;
        }

        var page = BitConverter.ToUInt16(info, 20);
        var usage = BitConverter.ToUInt16(info, 22);
        return page == 0x01 && usage is 0x04 or 0x05 && !IsXInput(device);
    }

    private static bool IsXInput(IntPtr device)
    {
        var size = 0u;
        GetRawInputDeviceInfo(device, RidiDeviceName, IntPtr.Zero, ref size);
        var name = new byte[Math.Max(2, (int)size * 2)];
        return GetRawInputDeviceInfo(device, RidiDeviceName, ref name[0], ref size) != uint.MaxValue &&
            System.Text.Encoding.Unicode.GetString(name).Contains("IG_", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Each device made again as it next reports (recording held: its readings before it are not compared with
    /// those after).</summary>
    public void Forget() => devices.Clear();

    /// <summary>A device came (WM_INPUT_DEVICE_CHANGE's GIDC_ARRIVAL) or went.</summary>
    public void Changed(bool arrived, IntPtr device)
    {
        if (!arrived)
        {
            if (devices.Remove(device, out var gone) && gone is not null)
            {
                log("controller (HID) disconnected");
            }

            return;
        }

        Get(device);
    }

    /// <summary>A WM_INPUT of a gamepad or joystick: its RAWHID (<paramref name="hid"/>: the size of a report, how many,
    /// the reports one after another).</summary>
    public void Report(IntPtr device, ReadOnlySpan<byte> hid, int lag)
    {
        if (hid.Length < 8 || Get(device) is not { } d)
        {
            return;
        }

        var size = (int)BitConverter.ToUInt32(hid);
        var count = (int)BitConverter.ToUInt32(hid[4..]);
        var reports = hid[8..];
        var presses = 0;
        var travel = 0.0;
        for (var i = 0; i < count && size > 0 && (i + 1) * size <= reports.Length; i++)
        {
            var r = reports.Slice(i * size, size);
            var n = (uint)(d.Data.Length / 8);
            if (n == 0 || HidP_GetData(0, ref d.Data[0], ref n, ref d.Preparsed[0], ref MemoryMarshal.GetReference(r), (uint)size) != HidpStatusSuccess)
            {
                continue;
            }

            d.Layout.Apply(d.Layout.UsesReportIds ? r[0] : (byte)0, d.Data, (int)n);
            var (p, t) = d.Layout.Counter.Take();
            presses += p;
            travel += t;
        }

        if (presses > 0)
        {
            activity.Presses(presses, lag);
        }

        if (travel > 0)
        {
            activity.Axes(travel, lag);
        }
    }

    private Device? Get(IntPtr device)
    {
        if (devices.TryGetValue(device, out var known))
        {
            return known;
        }

        Device? made = null;
        try
        {
            made = Make(device);
        }
        catch (Exception ex)
        {
            log("controller (HID) unreadable: " + ex.Message);
        }

        devices[device] = made;
        return made;
    }

    private Device? Make(IntPtr device)
    {
        // (an XInput pad's name says IG_, and XInput counts it)
        if (IsXInput(device))
        {
            return null;
        }

        var size = 0u;
        GetRawInputDeviceInfo(device, RidiPreparsedData, IntPtr.Zero, ref size);
        if (size == 0)
        {
            return null;
        }

        var preparsed = new byte[size];
        if (GetRawInputDeviceInfo(device, RidiPreparsedData, ref preparsed[0], ref size) == uint.MaxValue)
        {
            return null;
        }

        // HIDP_CAPS: NumberInputButtonCaps at 46, NumberInputValueCaps at 48 (64 bytes)
        var caps = new byte[64];
        if (HidP_GetCaps(ref preparsed[0], ref caps[0]) != HidpStatusSuccess)
        {
            return null;
        }

        var nb = BitConverter.ToUInt16(caps, 46);
        var nv = BitConverter.ToUInt16(caps, 48);
        var buttonCaps = new byte[Math.Max(1, (int)nb) * 72];
        var valueCaps = new byte[Math.Max(1, (int)nv) * 72];
        if (nb > 0 && HidP_GetButtonCaps(0, ref buttonCaps[0], ref nb, ref preparsed[0]) != HidpStatusSuccess)
        {
            nb = 0;
        }

        if (nv > 0 && HidP_GetValueCaps(0, ref valueCaps[0], ref nv, ref preparsed[0]) != HidpStatusSuccess)
        {
            nv = 0;
        }

        var layout = HidLayout.From(buttonCaps.AsSpan(0, nb * 72), valueCaps.AsSpan(0, nv * 72));
        if (layout is null)
        {
            return null;
        }

        var c = layout.Counter;
        log($"controller (HID) connected: {c.Buttons.Length} buttons, {c.Axes.Length} axes, {c.Switches.Length} hats");
        var data = new byte[Math.Max(1, HidP_MaxDataListLength(0, ref preparsed[0])) * 8];
        return new Device(preparsed, layout, data);
    }
}
