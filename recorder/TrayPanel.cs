using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Replay.Recorder;

/// <summary>
/// The tray's panel (the user, 2026-11-14: the menu drawn as the replay window is, not Windows' own): the replay
/// window's program run with REPLAY_TRAY=1 (app/tray_panel.mbt), started the first time it is asked for and kept,
/// hidden; shown at the pointer when the icon is pressed with the right button, over the other windows, given the
/// focus (it hides itself as it loses it). What is chosen in it comes back to the recorder's window
/// (MessageWindow.PanelChose). Where it cannot be shown the icon's own menu opens instead.
/// </summary>
internal sealed class TrayPanel(string exe, string root, IntPtr recorder, Action<string> log) : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X, Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        public int Size;
        public Rect Monitor;
        public Rect Work;
        public uint Flags;
    }

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(Point pt, uint flags);

    [DllImport("user32.dll")]
    private static extern bool GetMonitorInfoW(IntPtr monitor, ref MonitorInfo info);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(int pid);

    private Process? process;

    /// <summary>Let go of (the recorder quits): never started again after.</summary>
    private volatile bool disposed;

    /// <summary>Whether `pid` is the panel's (not the replay window's).</summary>
    public bool Owns(int pid)
    {
        try
        {
            return process is { HasExited: false } p && p.Id == pid;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    /// <summary>Started now if it is not running, so the first press shows it at once.</summary>
    public void Warm()
    {
        if (disposed)
        {
            return;
        }

        try
        {
            if (process is { HasExited: false })
            {
                return;
            }

            process?.Dispose();
            var info = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(exe)! };
            info.Environment["REPLAY_TRAY"] = "1";
            info.Environment["REPLAY_ROOT"] = root;
            info.Environment["REPLAY_RECORDER_HWND"] = recorder.ToInt64().ToString("x");
            // (beside the replay window's run, never handed to it as the same program started again would be)
            info.Environment["MBUI_WINDOW"] = "tray";
            info.Environment.Remove("REPLAY_RESIDENT");
            info.Environment.Remove("REPLAY_HIDDEN");
            // (what mbui says on its own (a frame that stalled: HANG …; no DirectComposition) kept in tray.log, so a
            // panel shown empty can be told by its time from one that stalled and one whose drawing failed: the user's,
            // 2026-11-17, 「打开tray menu的时候卡住了，显示了这么个框」, once, not again on trying)
            info.RedirectStandardError = true;
            info.RedirectStandardOutput = true;
            process = Process.Start(info);
            if (process is not null)
            {
                // (ended with the recorder however it ends: ChildJob)
                ChildJob.Hold(process);
                process.ErrorDataReceived += (_, e) => Note(e.Data);
                process.OutputDataReceived += (_, e) => Note(e.Data);
                process.BeginErrorReadLine();
                process.BeginOutputReadLine();
                Note("started, pid " + process.Id);
            }
        }
        catch (Exception ex)
        {
            log("tray panel: not started: " + ex.Message);
            process = null;
        }
    }

    private readonly object noteLock = new();

    /// <summary>A line of the panel's own (or of its life) put in tray.log beside the buffer, with its time; the file
    /// begun again past 1 MB.</summary>
    private void Note(string? line)
    {
        if (string.IsNullOrEmpty(line))
        {
            return;
        }

        try
        {
            lock (noteLock)
            {
                var file = Path.Combine(root, "tray.log");
                if (File.Exists(file) && new FileInfo(file).Length > 1_000_000)
                {
                    File.Delete(file);
                }

                File.AppendAllText(file, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff ") + line + Environment.NewLine);
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    /// <summary>
    /// After the screen came on again or the displays changed: a panel kept hidden through it started anew, its
    /// drawing made on the device as it is now. (mbui makes its Direct3D device once and never again: one lost to a
    /// driver's reset while the panel was hidden would leave it drawing nothing, its window shown as an empty frame.)
    /// One showing is left as it is.
    /// </summary>
    public void Renew(string why)
    {
        if (disposed)
        {
            return;
        }

        try
        {
            if (process is not { HasExited: false })
            {
                return;
            }

            var window = ForegroundApp.TopWindowOf(process.Id);
            if (window != IntPtr.Zero && IsWindowVisible(window))
            {
                return;
            }

            Note("renewed: " + why);
            process.Kill();
            process.WaitForExit(2000);
            process.Dispose();
            process = null;
            Warm();
        }
        catch (Exception ex)
        {
            log("tray panel: not renewed: " + ex.Message);
        }
    }

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    /// <summary>Shown with its corner at the pointer (x, y: screen pixels), opening towards the screen's middle as a
    /// tray menu does; false where it could not be.</summary>
    public bool Show(int x, int y)
    {
        if (disposed)
        {
            return false;
        }

        Warm();
        if (process is null)
        {
            return false;
        }

        // (just started: its window made within 2 s, or the menu instead)
        var window = IntPtr.Zero;
        for (var i = 0; i < 40 && window == IntPtr.Zero && !process.HasExited; i++)
        {
            window = ForegroundApp.TopWindowOf(process.Id);
            if (window == IntPtr.Zero)
            {
                Thread.Sleep(50);
            }
        }

        if (window == IntPtr.Zero || !GetWindowRect(window, out var r))
        {
            log("tray panel: no window");
            return false;
        }

        var w = r.Right - r.Left;
        var h = r.Bottom - r.Top;
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        // MONITOR_DEFAULTTONEAREST
        GetMonitorInfoW(MonitorFromPoint(new Point { X = x, Y = y }, 2), ref info);
        var work = info.Work;
        var left = x - w < work.Left ? x : x - w;
        var top = y - h < work.Top ? y : y - h;
        left = Math.Clamp(left, work.Left, Math.Max(work.Left, work.Right - w));
        top = Math.Clamp(top, work.Top, Math.Max(work.Top, work.Bottom - h));
        // (the recorder in front first, as the icon's menu was, so it may hand the focus on to the panel)
        SetForegroundWindow(recorder);
        AllowSetForegroundWindow(process.Id);
        // HWND_TOPMOST; SWP_NOSIZE | SWP_SHOWWINDOW
        SetWindowPos(window, new IntPtr(-1), left, top, 0, 0, 0x0001 | 0x0040);
        SetForegroundWindow(window);
        Note("shown");
        return true;
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        try
        {
            if (process is { HasExited: false })
            {
                process.Kill();
            }
        }
        catch (Exception)
        {
        }

        process?.Dispose();
        process = null;
    }
}
