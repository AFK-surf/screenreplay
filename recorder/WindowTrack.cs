using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Replay.Recorder;

/// <summary>
/// Where the windows were (windows.jsonl): a line each time what is on the screen changed, every visible top-level
/// window front to back with its process, title, bounds (DWM's extended frame bounds: what is drawn, without the
/// invisible resize border; physical pixels, the virtual screen's), state and owner, and the primary display the
/// recording is of. The replay window finds by it the window under a point at a moment, and exports one window's part
/// of the picture. Driven by the system's window events (foreground, moves and sizes, shown, hidden, minimized,
/// renamed), at most ten lines a second, a line only when something differs from the last. Kept on this computer
/// only, as the recording is.
/// </summary>
internal sealed class WindowTrack : IDisposable
{
    private const uint EventSystemForeground = 0x0003;
    private const uint EventSystemMoveSizeEnd = 0x000B;
    private const uint EventSystemMinimizeStart = 0x0016;
    private const uint EventSystemMinimizeEnd = 0x0017;
    private const uint EventSystemDesktopSwitch = 0x0020;
    private const uint EventObjectDestroy = 0x8001;
    private const uint EventObjectShow = 0x8002;
    private const uint EventObjectHide = 0x8003;
    private const uint EventObjectReorder = 0x8004;
    private const uint EventObjectLocationChange = 0x800B;
    private const uint EventObjectNameChange = 0x800C;
    private const uint EventObjectCloaked = 0x8017;
    private const uint EventObjectUncloaked = 0x8018;
    private const uint WinEventOutOfContext = 0;
    private const int ObjIdWindow = 0;

    private delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);

    [DllImport("user32.dll")]
    private static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint thread, uint flags);

    [DllImport("user32.dll")]
    private static extern bool UnhookWinEvent(IntPtr hook);

    private delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumProc proc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool IsZoomed(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hwnd, StringBuilder text, int max);

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr hwnd, int index);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    [DllImport("user32.dll")]
    private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(Point pt, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out Rect value, int size);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);

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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MonitorInfo
    {
        public int Size;
        public Rect Monitor;
        public Rect Work;
        public uint Flags;
    }

    private readonly string path;
    private readonly Action<string> log;
    private readonly Action<IntPtr> foreground;
    private readonly Action? desktopSwitch;
    private readonly WinEventProc proc;
    private readonly List<IntPtr> hooks = [];
    private readonly MessageWindow window;
    private nuint timer;
    private readonly Dictionary<uint, string> processNames = [];
    private bool dirty = true;
    private string last = "";
    private bool active;

    /// <summary>Whether lines are written (not while recording is held: locked, paused, turned off). Held, nothing of
    /// the desktop is watched: its six hooks let go of (each called for every window's every move and name change on the
    /// desktop) and its 100 ms timer stopped; taken again as it goes on.</summary>
    public bool Active
    {
        get => active;
        set
        {
            if (value == active)
            {
                return;
            }

            active = value;
            if (value)
            {
                Watch();
            }
            else
            {
                Unwatch();
            }
        }
    }

    public WindowTrack(MessageWindow window, string path, Action<string> log, Action<IntPtr> foreground, Action? desktopSwitch = null)
    {
        this.window = window;
        this.path = path;
        this.log = log;
        this.foreground = foreground;
        this.desktopSwitch = desktopSwitch;
        proc = OnEvent;
        active = true;
        Watch();
    }

    private void Watch()
    {
        if (hooks.Count > 0)
        {
            return;
        }

        foreach (var (min, max) in new[]
                 {
                     (EventSystemForeground, EventSystemForeground),
                     (EventSystemMoveSizeEnd, EventSystemMoveSizeEnd),
                     (EventSystemMinimizeStart, EventSystemMinimizeEnd),
                     (EventSystemDesktopSwitch, EventSystemDesktopSwitch),
                     (EventObjectDestroy, EventObjectReorder),
                     (EventObjectLocationChange, EventObjectNameChange),
                     (EventObjectCloaked, EventObjectUncloaked),
                 })
        {
            var hook = SetWinEventHook(min, max, IntPtr.Zero, proc, 0, 0, WinEventOutOfContext);
            if (hook != IntPtr.Zero)
            {
                hooks.Add(hook);
            }
        }

        timer = window.Every(100, () => Flush(false));
        dirty = true;
    }

    private void Unwatch()
    {
        if (timer != 0)
        {
            window.Stop(timer);
            timer = 0;
        }

        foreach (var hook in hooks)
        {
            UnhookWinEvent(hook);
        }

        hooks.Clear();
    }

    private void OnEvent(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        // (UAC secure desktop / virtual desktop switch: Windows passes hwnd=0, so handle before the window filter)
        if (ev == EventSystemDesktopSwitch)
        {
            dirty = true;
            desktopSwitch?.Invoke();
            return;
        }

        // (a window's own: not its caret's, a scroll bar's or a control's inside it)
        if (idObject != ObjIdWindow || idChild != 0 || hwnd == IntPtr.Zero)
        {
            return;
        }

        if (ev == EventObjectLocationChange || ev == EventObjectNameChange)
        {
            if (!IsTopLevel(hwnd))
            {
                return;
            }
        }

        dirty = true;
        if (ev == EventSystemForeground)
        {
            foreground(hwnd);
            Flush(true);
        }
    }

    private static bool IsTopLevel(IntPtr hwnd) => GetAncestorRoot(hwnd) == hwnd;

    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);

    private static IntPtr GetAncestorRoot(IntPtr hwnd) => GetAncestor(hwnd, 2);

    /// <summary>A line written now if what is on the screen changed (or `force`, the foreground changed).</summary>
    public void Flush(bool force)
    {
        if (!Active || (!dirty && !force))
        {
            return;
        }

        dirty = false;
        try
        {
            var snapshot = Snapshot();
            if (snapshot == last)
            {
                return;
            }

            last = snapshot;
            File.AppendAllText(path, $"{{\"at\":{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()},{snapshot}}}\n", new UTF8Encoding(false));
        }
        catch (Exception ex)
        {
            log("window track failed: " + ex.Message);
        }
    }

    /// <summary>The next line written whatever the last one was (after a pause: the reader starts again from it).</summary>
    public void Restart()
    {
        last = "";
        dirty = true;
    }

    private string Snapshot()
    {
        var old = SetThreadDpiAwarenessContext((IntPtr)(-4));
        try
        {
            var sb = new StringBuilder();
            var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            GetMonitorInfo(MonitorFromPoint(new Point(), 1), ref info);
            // (the window in front as the picture shows it: under ScreenReplay where it is kept out of capture)
            var fg = ForegroundApp.Shown(GetForegroundWindow());
            sb.Append($"\"screen\":[{info.Monitor.Left},{info.Monitor.Top},{info.Monitor.Right - info.Monitor.Left},{info.Monitor.Bottom - info.Monitor.Top}],");
            sb.Append($"\"fg\":{fg.ToInt64()},\"w\":[");
            var first = true;
            EnumWindows((hwnd, _) =>
            {
                // (one kept out of capture is not in the picture: what is under it is)
                if (!IsWindowVisible(hwnd) || ForegroundApp.Unseen(hwnd))
                {
                    return true;
                }

                if (DwmGetWindowAttribute(hwnd, 14, out int cloaked, 4) == 0 && cloaked != 0)
                {
                    return true;
                }

                if (DwmGetWindowAttribute(hwnd, 9, out Rect r, Marshal.SizeOf<Rect>()) != 0 && !GetWindowRect(hwnd, out r))
                {
                    return true;
                }

                var w = r.Right - r.Left;
                var h = r.Bottom - r.Top;
                if (w <= 1 || h <= 1)
                {
                    return true;
                }

                var exStyle = GetWindowLong(hwnd, -20);
                // a layered window the pointer goes through (an overlay: a GPU's, a screen annotator's) is no one's
                // to pick, and covers nothing a person meant
                if ((exStyle & 0x80020) == 0x80020)
                {
                    return true;
                }

                var owner = GetWindow(hwnd, 4);
                var cls = new StringBuilder(64);
                GetClassName(hwnd, cls, 64);
                var className = cls.ToString();
                // (the desktop and the taskbar are no one's window to export)
                if (className is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd")
                {
                    return true;
                }

                var title = new StringBuilder(256);
                GetWindowText(hwnd, title, 256);
                // a tool window without an owner and without a title: an overlay, a tray's, nothing a person picks
                if ((exStyle & 0x80) != 0 && owner == IntPtr.Zero && title.Length == 0)
                {
                    return true;
                }

                GetWindowThreadProcessId(hwnd, out var pid);
                var state = IsIconic(hwnd) ? 1 : IsZoomed(hwnd) ? 2 : 0;
                if (!first)
                {
                    sb.Append(',');
                }

                first = false;
                sb.Append('[').Append(hwnd.ToInt64()).Append(',').Append(owner.ToInt64()).Append(',')
                    .Append(Json(ProcessName(pid))).Append(',').Append(Json(title.ToString())).Append(',')
                    .Append(r.Left).Append(',').Append(r.Top).Append(',').Append(w).Append(',').Append(h).Append(',')
                    .Append(state).Append(',').Append(Json(className)).Append(']');
                return true;
            }, IntPtr.Zero);
            sb.Append(']');
            return sb.ToString();
        }
        finally
        {
            SetThreadDpiAwarenessContext(old);
        }
    }

    private string ProcessName(uint pid)
    {
        if (processNames.TryGetValue(pid, out var name))
        {
            return name;
        }

        try
        {
            using var p = Process.GetProcessById((int)pid);
            name = p.ProcessName;
        }
        catch (Exception)
        {
            name = "";
        }

        if (processNames.Count > 512)
        {
            processNames.Clear();
        }

        processNames[pid] = name;
        return name;
    }

    private static string Json(string text)
    {
        var sb = new StringBuilder("\"");
        foreach (var c in text)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                default:
                    if (c < ' ')
                    {
                        sb.Append($"\\u{(int)c:x4}");
                    }
                    else
                    {
                        sb.Append(c);
                    }

                    break;
            }
        }

        return sb.Append('"').ToString();
    }

    /// <summary>Lines older than `keep` dropped (the buffer's window), the newest before them kept as the start.</summary>
    private DateTimeOffset lastPrune = DateTimeOffset.MinValue;

    /// <summary>Every record deleted (the replay window's 删除全部录像); the windows as they are now written again at the
    /// next flush.</summary>
    public void Clear()
    {
        try
        {
            File.Delete(path);
        }
        catch
        {
        }
        last = "";
        dirty = true;
    }

    public void Prune(TimeSpan keep)
    {
        try
        {
            // (at most every 10 minutes: the file is rewritten whole, and the replay window then reads it again)
            if (!File.Exists(path) || new FileInfo(path).Length < 4 << 20 || DateTimeOffset.UtcNow - lastPrune < TimeSpan.FromMinutes(10))
            {
                return;
            }

            lastPrune = DateTimeOffset.UtcNow;

            var cutoff = DateTimeOffset.UtcNow.Add(-keep).ToUnixTimeMilliseconds();
            var lines = File.ReadAllLines(path);
            var kept = new List<string>();
            string? before = null;
            foreach (var line in lines)
            {
                var at = line.Length > 7 && line.StartsWith("{\"at\":", StringComparison.Ordinal)
                    ? long.TryParse(line.AsSpan(6, Math.Max(0, line.IndexOf(',') - 6)), out var v) ? v : 0
                    : 0;
                if (at < cutoff)
                {
                    before = line;
                }
                else
                {
                    kept.Add(line);
                }
            }

            if (before is not null)
            {
                kept.Insert(0, before);
            }

            // (nothing older than the window: nothing to rewrite)
            if (kept.Count >= lines.Length)
            {
                return;
            }

            File.WriteAllLines(path + ".tmp", kept, new UTF8Encoding(false));
            File.Move(path + ".tmp", path, overwrite: true);
        }
        catch (Exception ex)
        {
            log("window track prune failed: " + ex.Message);
        }
    }

    public void Dispose()
    {
        active = false;
        Unwatch();
    }
}
