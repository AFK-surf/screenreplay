using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Replay.Recorder;

/// <summary>
/// The programs the recorder starts and keeps (the resident replay window, the tray's panel, the note card kept warm)
/// held in a job of its own that ends them as the recorder ends, however it ends: quit, killed, crashed. Before, one
/// killed from Task Manager left its viewers running with nobody to show them (each 100-300 MB). Only these three are
/// put in it, each as it starts (the recorder itself is not in it, so the installer an update starts is never ended with
/// it); what they start in turn (a folder opened, a clip played in another program) leaves the job silently
/// (JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK) and outlives them as before.
/// </summary>
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

    /// <summary>`process` (just started by the recorder) ended with the recorder from now on; false where it could not
    /// be (logged by the caller where it matters: it then runs as before, unbound).</summary>
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
