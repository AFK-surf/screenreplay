using System.Runtime.InteropServices;

namespace Replay.Recording;

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

    public static IntPtr MonitorOf(IntPtr hwnd) => MonitorFromWindow(hwnd, 2);

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
