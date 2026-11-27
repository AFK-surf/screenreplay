using System.Collections.Concurrent;
using System.Runtime.InteropServices;

namespace Replay.Recorder;

// Top-level hidden window (not HWND_MESSAGE) because TaskbarCreated is only broadcast to top-level windows.
internal sealed class MessageWindow : IDisposable
{
    public const uint TrayCallback = WmApp + 2;

    public const uint PanelCommand = WmApp + 0x51;

    private const uint WmApp = 0x8000;
    private const uint WmPosted = WmApp + 1;
    private const uint WmClose = 0x0010;
    private const uint WmTimer = 0x0113;
    private const uint WmHotkey = 0x0312;
    private const uint WmWtsSessionChange = 0x02B1;
    private const uint WmPowerBroadcast = 0x0218;
    private const string ClassName = "ScreenReplay.Recorder";

    private delegate IntPtr WndProcHandler(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WndClassEx
    {
        public int Size;
        public uint Style;
        public IntPtr WndProc;
        public int ClassExtra;
        public int WindowExtra;
        public IntPtr Instance;
        public IntPtr Icon;
        public IntPtr Cursor;
        public IntPtr Background;
        public string? MenuName;
        public string ClassName;
        public IntPtr SmallIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Msg
    {
        public IntPtr Hwnd;
        public uint Message;
        public IntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public int X;
        public int Y;
        public uint Private;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClassExW(ref WndClassEx wc);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool UnregisterClassW(string className, IntPtr instance);

    [DllImport("user32.dll")]
    private static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid setting, uint flags);

    [DllImport("user32.dll")]
    private static extern bool UnregisterPowerSettingNotification(IntPtr handle);

    private IntPtr powerNotify;

    /// <summary>GUID_CONSOLE_DISPLAY_STATE: the console's displays off (0), on (1) or dimmed (2).</summary>
    private static Guid consoleDisplayState = new("6fe69556-704a-47a0-8f24-c28d936fda47");

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowExW(uint exStyle, string className, string title, uint style, int x, int y, int w, int h,
        IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern IntPtr DefWindowProcW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern int GetMessageW(out Msg msg, IntPtr hwnd, uint min, uint max);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref Msg msg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessageW(ref Msg msg);

    [DllImport("user32.dll")]
    private static extern void PostQuitMessage(int code);

    [DllImport("user32.dll")]
    private static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern UIntPtr SetTimer(IntPtr hwnd, UIntPtr id, uint ms, IntPtr proc);

    [DllImport("user32.dll")]
    private static extern bool KillTimer(IntPtr hwnd, UIntPtr id);

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hwnd, int id);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessageW(string name);

    [DllImport("user32.dll")]
    private static extern bool ChangeWindowMessageFilterEx(IntPtr hwnd, uint msg, uint action, IntPtr status);

    [DllImport("wtsapi32.dll")]
    private static extern bool WTSRegisterSessionNotification(IntPtr hwnd, uint flags);

    [DllImport("wtsapi32.dll")]
    private static extern bool WTSUnRegisterSessionNotification(IntPtr hwnd);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandleW(string? name);

    private readonly WndProcHandler proc;
    private readonly Action<string> log;
    private readonly IntPtr instance;
    private readonly uint taskbarCreated;
    private readonly Dictionary<nuint, Action> timers = [];
    private readonly List<int> hotkeys = [];
    private readonly ConcurrentQueue<(SendOrPostCallback Callback, object? State)> posted = new();
    private readonly SynchronizationContext? before;
    private nuint nextTimer = 1;

    public IntPtr Handle { get; }

    public event Action<int>? HotkeyPressed;

    public event Action<int>? SessionChanged;

    public event Action<int>? PowerChanged;

    public event Action<int>? PanelChose;

    public event Action<IntPtr, IntPtr>? TrayMessage;

    public event Action? TaskbarCreated;

    public Action<IntPtr>? Input;

    public Action<IntPtr, IntPtr>? InputDevice;

    public event Action? CloseAsked;

    public event Action? DisplayChanged;

    public event Action<bool>? ScreenPower;

    public MessageWindow(Action<string> log)
    {
        this.log = log;
        proc = WndProc;
        instance = GetModuleHandleW(null);
        var wc = new WndClassEx
        {
            Size = Marshal.SizeOf<WndClassEx>(),
            WndProc = Marshal.GetFunctionPointerForDelegate(proc),
            Instance = instance,
            ClassName = ClassName,
        };
        RegisterClassExW(ref wc);
        Handle = CreateWindowExW(0, ClassName, "ScreenReplay", 0x80000000, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        if (Handle == IntPtr.Zero)
        {
            throw new InvalidOperationException("the recorder's window could not be made: " + Marshal.GetLastWin32Error());
        }

        taskbarCreated = RegisterWindowMessageW("TaskbarCreated");
        // (let through when the recorder runs elevated, where messages from a lower process are filtered out)
        ChangeWindowMessageFilterEx(Handle, taskbarCreated, 1, IntPtr.Zero);
        ChangeWindowMessageFilterEx(Handle, PanelCommand, 1, IntPtr.Zero);
        WTSRegisterSessionNotification(Handle, 0);
        powerNotify = RegisterPowerSettingNotification(Handle, ref consoleDisplayState, 0);
        before = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(new Context(this));
    }

    public void Run()
    {
        while (GetMessageW(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessageW(ref msg);
        }
    }

    public void Quit() => PostQuitMessage(0);

    public nuint Every(int ms, Action tick)
    {
        var id = nextTimer++;
        timers[id] = tick;
        SetTimer(Handle, id, (uint)ms, IntPtr.Zero);
        return id;
    }

    public void Stop(nuint id)
    {
        if (timers.Remove(id))
        {
            KillTimer(Handle, id);
        }
    }

    public bool RegisterHotkey(int id, uint modifiers, uint key)
    {
        // MOD_NOREPEAT: holding the keys does not repeat the action.
        var ok = RegisterHotKey(Handle, id, modifiers | 0x4000, key);
        if (ok)
        {
            hotkeys.Add(id);
        }

        return ok;
    }

    public void UnregisterHotkeys()
    {
        foreach (var id in hotkeys)
        {
            UnregisterHotKey(Handle, id);
        }

        hotkeys.Clear();
    }

    private IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        // (nothing thrown may leave a window procedure: it would end the process; written to recorder.log instead, where
        // WinForms showed its exception dialog)
        try
        {
            switch (msg)
            {
                case RawInput.WmInput:
                    // (counted, then handed on: DefWindowProc lets go of what Windows keeps of it)
                    Input?.Invoke(lParam);
                    break;
                case RawInput.WmInputDeviceChange:
                    InputDevice?.Invoke(wParam, lParam);
                    return IntPtr.Zero;
                case WmPosted:
                    while (posted.TryDequeue(out var p))
                    {
                        try
                        {
                            p.Callback(p.State);
                        }
                        catch (Exception ex)
                        {
                            log("unhandled: " + ex);
                        }
                    }

                    return IntPtr.Zero;
                case WmTimer:
                    if (timers.TryGetValue((nuint)wParam, out var tick))
                    {
                        tick();
                    }

                    return IntPtr.Zero;
                case WmHotkey:
                    HotkeyPressed?.Invoke((int)wParam);
                    return IntPtr.Zero;
                case WmWtsSessionChange:
                    SessionChanged?.Invoke((int)wParam);
                    return IntPtr.Zero;
                case WmPowerBroadcast when (int)wParam == 0x8013:
                    // PBT_POWERSETTINGCHANGE: lParam a POWERBROADCAST_SETTING (the GUID, DataLength, then the data)
                    if (lParam != IntPtr.Zero && Marshal.PtrToStructure<Guid>(lParam) == consoleDisplayState && Marshal.ReadInt32(lParam, 16) >= 4)
                    {
                        ScreenPower?.Invoke(Marshal.ReadInt32(lParam, 20) != 0);
                    }

                    return (IntPtr)1;
                case WmPowerBroadcast:
                    PowerChanged?.Invoke((int)wParam);
                    return (IntPtr)1;
                case TrayCallback:
                    TrayMessage?.Invoke(wParam, lParam);
                    return IntPtr.Zero;
                case PanelCommand:
                    PanelChose?.Invoke((int)wParam);
                    return IntPtr.Zero;
                case 0x007E:
                    // WM_DISPLAYCHANGE (sent to every top-level window, this hidden one too)
                    DisplayChanged?.Invoke();
                    break;
                case WmClose:
                    CloseAsked?.Invoke();
                    return IntPtr.Zero;
            }

            if (msg == taskbarCreated && taskbarCreated != 0)
            {
                TaskbarCreated?.Invoke();
                return IntPtr.Zero;
            }
        }
        catch (Exception ex)
        {
            log("unhandled: " + ex);
            return IntPtr.Zero;
        }

        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    private void Post(SendOrPostCallback callback, object? state)
    {
        posted.Enqueue((callback, state));
        PostMessageW(Handle, WmPosted, IntPtr.Zero, IntPtr.Zero);
    }

    public void Dispose()
    {
        foreach (var id in timers.Keys.ToList())
        {
            Stop(id);
        }

        foreach (var id in hotkeys)
        {
            UnregisterHotKey(Handle, id);
        }

        hotkeys.Clear();
        WTSUnRegisterSessionNotification(Handle);
        if (powerNotify != IntPtr.Zero)
        {
            UnregisterPowerSettingNotification(powerNotify);
            powerNotify = IntPtr.Zero;
        }
        DestroyWindow(Handle);
        UnregisterClassW(ClassName, instance);
        SynchronizationContext.SetSynchronizationContext(before);
    }

    private sealed class Context(MessageWindow window) : SynchronizationContext
    {
        private readonly int thread = Environment.CurrentManagedThreadId;

        public override void Post(SendOrPostCallback d, object? state) => window.Post(d, state);

        public override void Send(SendOrPostCallback d, object? state)
        {
            if (Environment.CurrentManagedThreadId == thread)
            {
                d(state);
                return;
            }

            using var done = new ManualResetEventSlim();
            Exception? thrown = null;
            window.Post(_ =>
            {
                try
                {
                    d(state);
                }
                catch (Exception ex)
                {
                    thrown = ex;
                }
                finally
                {
                    done.Set();
                }
            }, null);
            done.Wait();
            if (thrown is not null)
            {
                throw thrown;
            }
        }

        public override SynchronizationContext CreateCopy() => this;
    }
}
