using System.Runtime.InteropServices;

namespace Replay.Recorder;

internal sealed class TrayMenuItem(string text, Action? click = null, string keys = "")
{
    public string Text { get; set; } = text;

    public string Keys { get; set; } = keys;

    public bool Enabled { get; init; } = true;

    public bool Visible { get; set; } = true;

    public bool Checked { get; set; }

    public Action? Click { get; } = click;
}

internal sealed class Tray : IDisposable
{
    private const uint NimAdd = 0;
    private const uint NimModify = 1;
    private const uint NimDelete = 2;
    private const uint NimSetVersion = 4;
    private const uint NifMessage = 0x01;
    private const uint NifIcon = 0x02;
    private const uint NifTip = 0x04;
    private const uint NifInfo = 0x10;
    private const uint NifShowTip = 0x80;
    private const uint NotifyIconVersion4 = 4;
    private const int WmLButtonUp = 0x0202;
    private const int WmLButtonDblClk = 0x0203;
    private const int WmContextMenu = 0x007B;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public int Size;
        public IntPtr Window;
        public uint Id;
        public uint Flags;
        public uint CallbackMessage;
        public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Tip;
        public uint State;
        public uint StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string Info;
        public uint TimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string InfoTitle;
        public uint InfoFlags;
        public Guid Item;
        public IntPtr BalloonIcon;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern bool Shell_NotifyIconW(uint message, ref NotifyIconData data);

    [DllImport("user32.dll")]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool AppendMenuW(IntPtr menu, uint flags, UIntPtr id, string? text);

    [DllImport("user32.dll")]
    private static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr tpm);

    [DllImport("user32.dll")]
    private static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadImageW(IntPtr instance, string name, uint type, int cx, int cy, uint flags);

    [DllImport("user32.dll")]
    private static extern IntPtr LoadIconW(IntPtr instance, IntPtr name);

    private readonly MessageWindow window;
    private readonly IReadOnlyList<TrayMenuItem?> menu;
    private readonly Action leftClick;
    private IntPtr icon;
    private string text = "";
    private bool visible;
    private bool added;
    private bool doubleClicked;

    public Func<int, int, bool>? Panel { get; set; }

    public Tray(MessageWindow window, IReadOnlyList<TrayMenuItem?> menu, Action leftClick)
    {
        this.window = window;
        this.menu = menu;
        this.leftClick = leftClick;
        window.TrayMessage += OnMessage;
        window.TaskbarCreated += OnTaskbarCreated;
    }

    public IntPtr Icon
    {
        get => icon;
        set
        {
            if (value == icon && (added || !visible))
            {
                return;
            }

            icon = value;
            Update();
        }
    }

    public string Text
    {
        get => text;
        set
        {
            var cut = value.Length > 127 ? value[..127] : value;
            if (cut == text && (added || !visible))
            {
                return;
            }

            text = cut;
            Update();
        }
    }

    public bool Visible
    {
        get => visible;
        set
        {
            visible = value;
            Update();
        }
    }

    public void ShowBalloonTip(int timeoutMs, string title, string text, bool warning)
    {
        if (!added)
        {
            return;
        }

        var data = Data(NifInfo);
        data.InfoTitle = title.Length > 63 ? title[..63] : title;
        data.Info = text.Length > 255 ? text[..255] : text;
        data.InfoFlags = warning ? 2u : 0u;
        data.TimeoutOrVersion = (uint)timeoutMs;
        Shell_NotifyIconW(NimModify, ref data);
    }

    private NotifyIconData Data(uint flags) => new()
    {
        Size = Marshal.SizeOf<NotifyIconData>(),
        Window = window.Handle,
        Id = 1,
        Flags = flags,
        Tip = "",
        Info = "",
        InfoTitle = "",
    };

    private void Update()
    {
        if (!visible)
        {
            if (added)
            {
                var gone = Data(0);
                Shell_NotifyIconW(NimDelete, ref gone);
                added = false;
            }

            return;
        }

        var data = Data(NifMessage | NifIcon | NifTip | NifShowTip);
        data.CallbackMessage = MessageWindow.TrayCallback;
        data.Icon = icon;
        data.Tip = text;
        if (added)
        {
            Shell_NotifyIconW(NimModify, ref data);
            return;
        }

        // (not there yet at sign-in, before Explorer's taskbar: added when TaskbarCreated comes)
        added = Shell_NotifyIconW(NimAdd, ref data);
        if (added)
        {
            data.TimeoutOrVersion = NotifyIconVersion4;
            Shell_NotifyIconW(NimSetVersion, ref data);
        }
    }

    private void OnTaskbarCreated()
    {
        added = false;
        Update();
    }

    private void OnMessage(IntPtr wParam, IntPtr lParam)
    {
        // NOTIFYICON_VERSION_4: the event in lParam's low word, the point (the icon's, or the pointer's) in wParam
        var ev = (int)(lParam.ToInt64() & 0xFFFF);
        if (ev == WmLButtonDblClk)
        {
            doubleClicked = true;
        }
        else if (ev == WmLButtonUp)
        {
            if (!doubleClicked)
            {
                leftClick();
            }

            doubleClicked = false;
        }
        else if (ev == WmContextMenu)
        {
            var at = wParam.ToInt64();
            var (x, y) = ((short)(at & 0xFFFF), (short)((at >> 16) & 0xFFFF));
            if (Panel?.Invoke(x, y) != true)
            {
                ShowMenu(x, y);
            }
        }
    }

    private IntPtr BuildMenu(List<TrayMenuItem> shown)
    {
        var popup = CreatePopupMenu();
        foreach (var item in menu)
        {
            if (item is null)
            {
                AppendMenuW(popup, 0x800, UIntPtr.Zero, null);
                continue;
            }

            if (!item.Visible)
            {
                continue;
            }

            shown.Add(item);
            var flags = (item.Enabled ? 0u : 0x1u) | (item.Checked ? 0x8u : 0u);
            AppendMenuW(popup, flags, (UIntPtr)shown.Count, item.Keys.Length > 0 ? item.Text + "\t" + item.Keys : item.Text);
        }

        return popup;
    }

    private void ShowMenu(int x, int y)
    {
        var shown = new List<TrayMenuItem>();
        var popup = BuildMenu(shown);
        try
        {
            // SetForegroundWindow before TrackPopupMenuEx and post WM_NULL after so the menu dismisses cleanly.
            SetForegroundWindow(window.Handle);
            var align = GetSystemMetrics(40) != 0 ? 0x8u : 0x0u;
            var chosen = TrackPopupMenuEx(popup, 0x100 | 0x2 | align, x, y, window.Handle, IntPtr.Zero);
            PostMessageW(window.Handle, 0, IntPtr.Zero, IntPtr.Zero);
            if (chosen > 0 && chosen <= shown.Count)
            {
                shown[chosen - 1].Click?.Invoke();
            }
        }
        finally
        {
            DestroyMenu(popup);
        }
    }

    public static IntPtr LoadIcon(string path)
    {
        var icon = LoadImageW(IntPtr.Zero, path, 1, GetSystemMetrics(49), GetSystemMetrics(50), 0x10);
        return icon != IntPtr.Zero ? icon : LoadIconW(IntPtr.Zero, 32512);
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr icon);

    public static void FreeIcon(IntPtr icon)
    {
        if (icon != IntPtr.Zero)
        {
            DestroyIcon(icon);
        }
    }

    public void Dispose()
    {
        window.TrayMessage -= OnMessage;
        window.TaskbarCreated -= OnTaskbarCreated;
        Visible = false;
    }
}
