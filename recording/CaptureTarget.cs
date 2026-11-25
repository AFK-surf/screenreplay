namespace Replay.Recording;

public sealed record CaptureTarget(IntPtr Monitor, IntPtr Window, int Width, int Height, uint ProcessId)
{
    public bool IsWindow => Window != IntPtr.Zero;

    public static CaptureTarget? PrimaryMonitor()
    {
        // MONITOR_DEFAULTTOPRIMARY
        var monitor = Native.MonitorFromPoint(0, 1);
        if (monitor == IntPtr.Zero)
        {
            return null;
        }

        var info = new Native.MonitorInfo { Size = System.Runtime.InteropServices.Marshal.SizeOf<Native.MonitorInfo>() };
        if (!Native.GetMonitorInfo(monitor, ref info))
        {
            return null;
        }

        return new CaptureTarget(monitor, IntPtr.Zero, info.Monitor.Right - info.Monitor.Left, info.Monitor.Bottom - info.Monitor.Top, 0);
    }

    public static CaptureTarget? ForWindow(IntPtr hwnd)
    {
        if (!Native.IsWindow(hwnd) || !Native.GetWindowRect(hwnd, out var r))
        {
            return null;
        }

        Native.GetWindowThreadProcessId(hwnd, out var pid);
        return new CaptureTarget(IntPtr.Zero, hwnd, r.Right - r.Left, r.Bottom - r.Top, pid);
    }
}

public readonly record struct VideoSize(int Width, int Height)
{
    public static VideoSize Fit(int width, int height, int maxHeight)
    {
        double w = Math.Max(2, width), h = Math.Max(2, height);
        if (maxHeight > 0 && h > maxHeight)
        {
            w = w * maxHeight / h;
            h = maxHeight;
        }

        return new VideoSize(Even(w), Even(h));
    }

    private static int Even(double v) => Math.Max(2, (int)Math.Floor(v / 2) * 2);
}
