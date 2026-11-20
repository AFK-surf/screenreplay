using System.Runtime.InteropServices;

namespace Replay.Recorder;

/// <summary>
/// Where NVIDIA's driver has Fast Sync on (its vertical sync setting, VSYNCMODE, at "Fast"), read from its settings
/// (NVAPI's DRS), never changed. With Fast Sync a game's frames reach the screen in a way the system's capture then
/// gives every other frame stale (2026-11-15: Psycho Sleuth's recording flickered, and ended with Fast Sync off; the
/// same in Discord's share, OBS's display capture and the taskbar's preview, the one report found). The replay window
/// says so (state.json's fastSync) with how to turn it off; nothing is left out or changed for it.
/// <para>Said as "global" where the global profile has it, and the names of the program profiles the person set it
/// in (about 270 ms for the driver's 8000 profiles). "" where it is on nowhere, there is no NVIDIA driver, or it cannot be read.</para>
/// </summary>
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

    /// <summary>Where Fast Sync is on ("global", program profiles' names, joined by "; "), "" nowhere or not known.
    /// REPLAY_TEST_FASTSYNC: what it says instead (a test of the window's words).</summary>
    public static unsafe string Where()
    {
        var test = Environment.GetEnvironmentVariable("REPLAY_TEST_FASTSYNC");
        if (test is not null)
        {
            return test;
        }

        if (!NativeLibrary.TryLoad("nvapi64.dll", out _))
        {
            return "";
        }

        var setting = (byte*)NativeMemory.AllocZeroed(SettingSize);
        var profile = (byte*)NativeMemory.AllocZeroed(ProfileSize);
        IntPtr session = IntPtr.Zero;
        try
        {
            if (((delegate* unmanaged[Cdecl]<int>)Fn(0x0150E828))() != 0)
            {
                return "";
            }

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
