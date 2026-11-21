using System.Runtime.InteropServices;
using Vortice.DXGI;

namespace Replay.Recording;

/// <summary>
/// How a monitor shows colour: in HDR or not (Windows' HDR switch: its DXGI output's colour space is
/// RGB_FULL_G2084_NONE_P2020), how bright SDR content's white is on it there (the "SDR content brightness" slider:
/// DISPLAYCONFIG_SDR_WHITE_LEVEL) and its brightest (the output's MaxLuminance), in nits.
/// </summary>
internal readonly record struct DisplayColor(bool Hdr, float SdrWhiteNits, float PeakNits)
{
    /// <summary>scRGB's 1.0: 80 nits.</summary>
    public const float ScRgbNits = 80;

    public static readonly DisplayColor Sdr = new(false, ScRgbNits, ScRgbNits);

    /// <summary>The monitor's colour now (a new DXGI factory each time: an old one's outputs keep what they were made
    /// with); SDR where it cannot be read.</summary>
    public static DisplayColor Of(IntPtr monitor)
    {
        try
        {
            using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
            for (uint a = 0; factory.EnumAdapters1(a, out var adapter).Success; a++)
            {
                using (adapter)
                {
                    for (uint o = 0; adapter.EnumOutputs(o, out var output).Success; o++)
                    {
                        using (output)
                        {
                            using var output6 = output.QueryInterfaceOrNull<IDXGIOutput6>();
                            if (output6 is null)
                            {
                                continue;
                            }

                            var desc = output6.Description1;
                            if (desc.Monitor != monitor)
                            {
                                continue;
                            }

                            if (desc.ColorSpace != ColorSpaceType.RgbFullG2084NoneP2020)
                            {
                                return Sdr;
                            }

                            // (with the monitor asleep or off its path is not active and it says no peak: the desktop
                            // is still composed with the white it had, so that is kept, else the frames come out
                            // several times too bright, 2026-11-16. With the screen turned off by power settings the
                            // path stays and says 80 nits (scRGB's default) with the right peak, and for a few seconds
                            // after it comes back on: nothing read then is believed, 2026-11-17)
                            var trusted = DisplayMemory.Trusted;
                            var readWhite = trusted ? SdrWhiteOf(desc.DeviceName) : null;
                            float? readPeak = trusted && desc.MaxLuminance > 0 ? desc.MaxLuminance : null;
                            var known = DisplayMemory.Of(desc.DeviceName);
                            var white = readWhite ?? known?.White ?? ScRgbNits;
                            var peak = readPeak ?? known?.Peak ?? 1000;
                            if (readWhite is not null && readPeak is not null)
                            {
                                DisplayMemory.Keep(desc.DeviceName, white, peak);
                            }

                            return new DisplayColor(true, white, Math.Max(peak, white));
                        }
                    }
                }
            }
        }
        catch (Exception)
        {
        }

        return Sdr;
    }

    // --- the display configuration's paths (wingdi.h) ---
    [StructLayout(LayoutKind.Sequential)]
    private struct Luid
    {
        public uint Low;
        public int High;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PathInfo
    {
        // DISPLAYCONFIG_PATH_SOURCE_INFO
        public Luid SourceAdapter;
        public uint SourceId;
        public uint SourceModeIndex;
        public uint SourceStatus;
        // DISPLAYCONFIG_PATH_TARGET_INFO
        public Luid TargetAdapter;
        public uint TargetId;
        public uint TargetModeIndex;
        public uint OutputTechnology;
        public uint Rotation;
        public uint Scaling;
        public uint RefreshNumerator;
        public uint RefreshDenominator;
        public uint ScanLineOrdering;
        public int TargetAvailable;
        public uint TargetStatus;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential, Size = 64)]
    private struct ModeInfo
    {
        public uint InfoType;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Header
    {
        public uint Type;
        public uint Size;
        public Luid Adapter;
        public uint Id;
    }

    // (Unicode, so that it is blittable and the name is not copied through the ANSI code page)
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private unsafe struct SourceName
    {
        public Header Header;
        public fixed char GdiName[32];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SdrWhite
    {
        public Header Header;
        public uint Level;
    }

    [DllImport("user32.dll")]
    private static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);

    [DllImport("user32.dll")]
    private static extern int QueryDisplayConfig(uint flags, ref uint pathCount, [Out] PathInfo[] paths, ref uint modeCount, [Out] ModeInfo[] modes, IntPtr topology);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref SourceName info);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref SdrWhite info);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref AdvancedColor info);

    // DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO: Value's bit 0 advancedColorSupported, bit 1 enabled
    [StructLayout(LayoutKind.Sequential)]
    private struct AdvancedColor
    {
        public Header Header;
        public uint Value;
        public uint Encoding;
        public uint BitsPerColor;
    }

    /// <summary>The SDR white level of the display whose GDI name is <paramref name="device"/> (\\.\DISPLAY1), in nits;
    /// null where it cannot be read.</summary>
    private static unsafe float? SdrWhiteOf(string device)
    {
        // QDC_ONLY_ACTIVE_PATHS
        const uint Active = 2;
        if (GetDisplayConfigBufferSizes(Active, out var pathCount, out var modeCount) != 0)
        {
            return null;
        }

        var paths = new PathInfo[pathCount];
        var modes = new ModeInfo[modeCount];
        if (QueryDisplayConfig(Active, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero) != 0)
        {
            return null;
        }

        for (var i = 0; i < pathCount; i++)
        {
            // DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME
            var name = new SourceName { Header = new Header { Type = 1, Size = (uint)sizeof(SourceName), Adapter = paths[i].SourceAdapter, Id = paths[i].SourceId } };
            if (DisplayConfigGetDeviceInfo(ref name) != 0 || !string.Equals(new string(name.GdiName), device, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            // (a monitor switched off at its button keeps its path, held by the system: DISPLAYCONFIG_TARGET_FORCED_
            // AVAILABILITY_* in its status, and it no longer says it supports advanced colour; its white then reads 80
            // nits, which the desktop is not composed with, 2026-11-17: tstatus 0x11 adv 2 off, 0x1 and 3 on)
            if ((paths[i].TargetStatus & 0x1C) != 0)
            {
                return null;
            }

            var color = new AdvancedColor { Header = new Header { Type = 9, Size = (uint)sizeof(AdvancedColor), Adapter = paths[i].TargetAdapter, Id = paths[i].TargetId } };
            if (DisplayConfigGetDeviceInfo(ref color) == 0 && (color.Value & 1) == 0)
            {
                return null;
            }

            // DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL: in thousandths of scRGB's 80 nits
            var white = new SdrWhite { Header = new Header { Type = 11, Size = (uint)sizeof(SdrWhite), Adapter = paths[i].TargetAdapter, Id = paths[i].TargetId } };
            if (DisplayConfigGetDeviceInfo(ref white) != 0 || white.Level == 0)
            {
                return null;
            }

            return white.Level / 1000f * ScRgbNits;
        }

        return null;
    }
}

/// <summary>
/// Each HDR monitor's SDR white and peak as last read while it was on, kept in a file (<see cref="File"/>) so that a
/// recorder started while the monitor is asleep still has them.
/// </summary>
public static class DisplayMemory
{
    private static readonly object Gate = new();
    private static Dictionary<string, (float White, float Peak)>? known;

    /// <summary>Where they are kept (display-color.json in the buffer's root); only in memory where unset.</summary>
    public static string? File { get; set; }

    // (Environment.TickCount64 since when the screen has been on; -1 while it is off)
    private static long onSince;

    /// <summary>The console's screen turned off or on (GUID_CONSOLE_DISPLAY_STATE).</summary>
    public static void ScreenOn(bool on)
    {
        // (the first word comes as the notification is registered, the recorder starting: on then is on already)
        var first = Interlocked.Read(ref onSince) == 0;
        Interlocked.Exchange(ref onSince, !on ? -1 : first ? Math.Max(1, Environment.TickCount64 - 5000) : Environment.TickCount64);
    }

    /// <summary>Whether the console's screen is on (as last told; on until told otherwise).</summary>
    public static bool ScreenIsOn => Interlocked.Read(ref onSince) >= 0;

    /// <summary>Whether what a monitor says of its white and peak is believed: not while the screen is off, nor in the
    /// 5 s after it comes on (20:19:49 on 2026-11-16 read 80 nits, then 276 3 s later).</summary>
    internal static bool Trusted
    {
        get
        {
            var since = Interlocked.Read(ref onSince);
            return since == 0 || (since > 0 && Environment.TickCount64 - since >= 5000);
        }
    }

    internal static (float White, float Peak)? Of(string device)
    {
        lock (Gate)
        {
            return Load().TryGetValue(device, out var k) ? k : null;
        }
    }

    internal static void Keep(string device, float white, float peak)
    {
        lock (Gate)
        {
            var all = Load();
            if (all.TryGetValue(device, out var k) && k == (white, peak))
            {
                return;
            }

            all[device] = (white, peak);
            if (File is null)
            {
                return;
            }

            try
            {
                // (written and read without JsonSerializer: the shipped recorder is trimmed, which turns its
                // reflection off, and it threw, so the store build never kept or found them, 2026-11-20)
                var temp = File + ".tmp";
                using (var stream = System.IO.File.Create(temp))
                using (var json = new System.Text.Json.Utf8JsonWriter(stream))
                {
                    json.WriteStartObject();
                    foreach (var (name, kept) in all)
                    {
                        json.WriteStartArray(name);
                        json.WriteNumberValue(kept.White);
                        json.WriteNumberValue(kept.Peak);
                        json.WriteEndArray();
                    }

                    json.WriteEndObject();
                }

                System.IO.File.Move(temp, File, true);
            }
            catch (Exception)
            {
            }
        }
    }

    private static Dictionary<string, (float White, float Peak)> Load()
    {
        if (known is not null)
        {
            return known;
        }

        known = new(StringComparer.OrdinalIgnoreCase);
        try
        {
            if (File is not null && System.IO.File.Exists(File))
            {
                using var read = System.Text.Json.JsonDocument.Parse(System.IO.File.ReadAllText(File));
                foreach (var p in read.RootElement.EnumerateObject())
                {
                    var v = p.Value;
                    if (v.ValueKind == System.Text.Json.JsonValueKind.Array && v.GetArrayLength() == 2
                        && v[0].TryGetSingle(out var white) && v[1].TryGetSingle(out var peak) && white > 0 && peak > 0)
                    {
                        known[p.Name] = (white, peak);
                    }
                }
            }
        }
        catch (Exception)
        {
        }

        return known;
    }
}
