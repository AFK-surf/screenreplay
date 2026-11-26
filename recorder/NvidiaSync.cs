using System.Runtime.InteropServices;

namespace Replay.Recorder;

// Detects NVIDIA Fast Sync via NVAPI DRS, which causes WGC/DXGI capture to deliver alternating stale frames.
internal static class NvidiaSync
{
    private const uint VsyncMode = 0x00A879CF;
    private const uint Fast = 0x18888888;

    // NVDRS_SETTING (version 1, packed by 4): version, name (2048 UTF-16), id, type, location, isCurrentPredefined,
    // isPredefinedValid, the predefined value (4100 bytes), the current one
    private const int SettingSize = 4 + 4096 + 5 * 4 + 4100 + 4100;
    private const int SettingLocation = 4 + 4096 + 8;
    private const int SettingPredefined = 4 + 4096 + 12;
    private const int SettingCurrent = 4 + 4096 + 20 + 4100;

    // NVDRS_PROFILE (version 1): version, name (2048 UTF-16), gpuSupport, isPredefined, numOfApps, numOfSettings
    private const int ProfileSize = 4 + 4096 + 16;

    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr QueryInterface(uint id);

    private static IntPtr Fn(uint id)
    {
        var f = QueryInterface(id);
        if (f == IntPtr.Zero)
        {
            throw new EntryPointNotFoundException($"NVAPI 0x{id:x8}");
        }

        return f;
    }

    private static readonly object Gate = new();

    // 0 not tried, 1 NvAPI ready, -1 none (no NVIDIA driver)
    private static int state;

    public static unsafe string Where()
    {
        var test = Environment.GetEnvironmentVariable("REPLAY_TEST_FASTSYNC");
        if (test is not null)
        {
            return test;
        }

        // (the library loaded and NvAPI initialized once for the process, not every 5 minutes: each load and each
        // NvAPI_Initialize counted one more reference, never given back)
        lock (Gate)
        {
            if (state == 0)
            {
                try
                {
                    state = NativeLibrary.TryLoad("nvapi64.dll", out _) && ((delegate* unmanaged[Cdecl]<int>)Fn(0x0150E828))() == 0 ? 1 : -1;
                }
                catch (Exception)
                {
                    state = -1;
                }
            }
        }

        if (state < 0)
        {
            return "";
        }

        var setting = (byte*)NativeMemory.AllocZeroed(SettingSize);
        var profile = (byte*)NativeMemory.AllocZeroed(ProfileSize);
        IntPtr session = IntPtr.Zero;
        try
        {

            var destroy = (delegate* unmanaged[Cdecl]<IntPtr, int>)Fn(0xDAD9CFF8);
            if (((delegate* unmanaged[Cdecl]<IntPtr*, int>)Fn(0x0694D52E))(&session) != 0)
            {
                return "";
            }

            var opened = session;
            try
            {
                if (((delegate* unmanaged[Cdecl]<IntPtr, int>)Fn(0x375DBD6B))(opened) != 0)
                {
                    return "";
                }

                var get = (delegate* unmanaged[Cdecl]<IntPtr, IntPtr, uint, byte*, int>)Fn(0x73BF8338);
                bool FastIn(IntPtr p, bool ownOnly)
                {
                    new Span<byte>(setting, SettingSize).Clear();
                    *(uint*)setting = SettingSize | 0x10000;
                    if (get(opened, p, VsyncMode, setting) != 0)
                    {
                        return false;
                    }

                    // (a program's: set on its profile itself (location 0, not taken from the global one), by the
                    // person, not NVIDIA's own predefined value (some ship with Fast: Google Play Games'))
                    return *(uint*)(setting + SettingCurrent) == Fast
                        && (!ownOnly || *(uint*)(setting + SettingLocation) == 0 && *(uint*)(setting + SettingPredefined) == 0);
                }

                var found = new List<string>();
                IntPtr global;
                if (((delegate* unmanaged[Cdecl]<IntPtr, IntPtr*, int>)Fn(0x617BFF9F))(opened, &global) == 0 && FastIn(global, false))
                {
                    found.Add("global");
                }

                uint count;
                var info = (delegate* unmanaged[Cdecl]<IntPtr, IntPtr, byte*, int>)Fn(0x61CD6FD6);
                var at = (delegate* unmanaged[Cdecl]<IntPtr, uint, IntPtr*, int>)Fn(0xBC371EE0);
                if (((delegate* unmanaged[Cdecl]<IntPtr, uint*, int>)Fn(0x1DAE4FBC))(opened, &count) == 0)
                {
                    for (uint i = 0; i < count; i++)
                    {
                        IntPtr p;
                        if (at(opened, i, &p) != 0 || p == global || !FastIn(p, true))
                        {
                            continue;
                        }

                        new Span<byte>(profile, ProfileSize).Clear();
                        *(uint*)profile = ProfileSize | 0x10000;
                        var name = info(opened, p, profile) == 0 ? new string((char*)(profile + 4)) : "?";
                        found.Add(name);
                    }
                }

                return string.Join("; ", found);
            }
            finally
            {
                destroy(opened);
            }
        }
        catch (Exception)
        {
            return "";
        }
        finally
        {
            NativeMemory.Free(setting);
            NativeMemory.Free(profile);
        }
    }
}
