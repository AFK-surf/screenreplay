using System.Runtime.InteropServices;

namespace Replay.Recording;

/// <summary>
/// A recorded window's state (a test window's recording): whether it is there to be captured, and its monitor.
/// <para>The monitor's recording is the monitor's alone. A full-screen app's window was captured in its stead from
/// 2026-11-15 02:20 (9717780) against a game's alternating stale pictures in independent flip; the window's capture
/// alternated as well, and the user had it removed the same evening (no switching of sources, the monitor always).</para>
/// </summary>
internal static class WindowShown
{
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, uint attribute, out int value, int size);

    /// <summary>The monitor a window is on (the nearest when it is on none).</summary>
    public static IntPtr MonitorOf(IntPtr hwnd) => MonitorFromWindow(hwnd, 2);

    /// <summary>Whether a window is there to be captured: not closed, hidden, minimised or cloaked (on another virtual
    /// desktop, a UWP app suspended).</summary>
    public static bool Showing(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !Native.IsWindow(hwnd) || !IsWindowVisible(hwnd) || IsIconic(hwnd))
        {
            return false;
        }

        // DWMWA_CLOAKED
        return DwmGetWindowAttribute(hwnd, 14, out var cloaked, 4) != 0 || cloaked == 0;
    }
}
