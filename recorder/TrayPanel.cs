using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Replay.Recorder;

/// <summary>
/// The tray's panel (the user, 2026-11-14: the menu drawn as the replay window is, not Windows' own): hosted as an
/// in-process secondary window inside the single resident ScreenReplayViewer.exe (WM_APP + 0x54), sharing its D3D11
/// device, shaders, and font atlas instead of keeping a second idle viewer process alive. Where the resident viewer
/// is unavailable (e.g. mid-renew), returns false so the icon's own menu opens immediately instead.
/// </summary>
internal sealed class TrayPanel(string exe, string root, IntPtr recorder, Func<(int Pid, IntPtr Window)?> findReplay, Action<string> log) : IDisposable
{
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(int pid);

    [DllImport("user32.dll")]
    private static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp);

    private volatile bool disposed;

    /// <summary>No separate tray process is owned anymore (hosted in-process inside the resident viewer).</summary>
    public bool Owns(int pid) => false;

    /// <summary>No-op: the tray menu shares the single resident viewer process.</summary>
    public void Warm() { }

    /// <summary>No-op: the resident viewer is renewed as a whole by RecorderApp.RenewReplayIfHidden.</summary>
    public void Renew(string why) { }

    private readonly object noteLock = new();

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

    /// <summary>Opens the tray panel at screen pixels (x, y) inside the resident viewer; false if unavailable.</summary>
    public bool Show(int x, int y)
    {
        if (disposed)
        {
            return false;
        }

        _ = exe;
        var target = findReplay();
        if (target is not { } found || found.Window == IntPtr.Zero)
        {
            log("tray panel: resident viewer unavailable, using native menu");
            return false;
        }

        // (the recorder in front first, as the icon's menu was, so it may hand the focus on to the panel)
        SetForegroundWindow(recorder);
        AllowSetForegroundWindow(found.Pid);
        if (!PostMessageW(found.Window, 0x8000 + 0x54, (IntPtr)x, (IntPtr)y))
        {
            log("tray panel: post failed, using native menu");
            return false;
        }

        Note("shown (in-process, pid " + found.Pid + ")");
        return true;
    }

    public void Dispose()
    {
        disposed = true;
    }
}
