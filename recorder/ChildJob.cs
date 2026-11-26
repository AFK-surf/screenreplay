using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Replay.Recorder;

internal static class ChildJob
{
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JobObjectLimitKillOnJobClose = 0x2000;
    private const uint JobObjectLimitBreakawayOk = 0x800;
    private const uint JobObjectLimitSilentBreakawayOk = 0x1000;

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimit
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public nuint MinimumWorkingSetSize;
        public nuint MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public nuint Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimit
    {
        public BasicLimit Basic;
        public IoCounters Io;
        public nuint ProcessMemoryLimit;
        public nuint JobMemoryLimit;
        public nuint PeakProcessMemoryUsed;
        public nuint PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObjectW(IntPtr attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimit info, int size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    private static readonly object Gate = new();

    // (held for the process's life and never closed by hand: its closing as the process ends is what ends the children)
    private static IntPtr job;
    private static bool tried;

    public static bool Hold(Process? process)
    {
        if (process is null)
        {
            return false;
        }

        lock (Gate)
        {
            if (!tried)
            {
                tried = true;
                var made = CreateJobObjectW(IntPtr.Zero, null);
                if (made != IntPtr.Zero)
                {
                    var info = new ExtendedLimit();
                    info.Basic.LimitFlags = JobObjectLimitKillOnJobClose | JobObjectLimitBreakawayOk | JobObjectLimitSilentBreakawayOk;
                    if (SetInformationJobObject(made, JobObjectExtendedLimitInformation, ref info, Marshal.SizeOf<ExtendedLimit>()))
                    {
                        job = made;
                    }
                }
            }

            if (job == IntPtr.Zero)
            {
                return false;
            }

            try
            {
                return AssignProcessToJobObject(job, process.Handle);
            }
            catch (Exception)
            {
                return false;
            }
        }
    }
}
