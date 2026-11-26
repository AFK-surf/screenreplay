using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using Replay.Recording;
using Windows.Graphics.Capture;

namespace Replay.Recorder;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        var paths = RecorderPaths.FromEnvironment();
        Replay.Recording.DisplayMemory.File = Path.Combine(paths.Root, "display-color.json");
        var rootKey = Convert.ToHexString(System.Security.Cryptography.SHA1.HashData(Encoding.UTF8.GetBytes(paths.Root.ToLowerInvariant())))[..12];
        var mutexName = @"Local\ReplayRecorder.Single." + rootKey;
        if (args.Contains("--quit"))
        {
            var quitPath = Path.Combine(paths.Root, "quit.request");
            using var probe = new Mutex(false, mutexName, out var noneRunning);
            if (!noneRunning)
            {
                try { WriteAtomic(quitPath, "quit"); } catch (Exception) { }
                var exited = false;
                try
                {
                    if (probe.WaitOne(4500))
                    {
                        exited = true;
                        probe.ReleaseMutex();
                    }
                }
                catch (AbandonedMutexException)
                {
                    exited = true;
                }
                // Never leave quit.request behind once the old instance has exited, otherwise the newly launched
                // instance after an update would consume it on startup and immediately quit.
                if (exited)
                {
                    TryTakeRequest(quitPath);
                }
            }
            else
            {
                TryTakeRequest(quitPath);
            }
            return;
        }
        if (!args.Contains("--background") && !args.Contains("--updated") && !Packaged.StartedAtSignIn())
        {
            try { WriteAtomic(Path.Combine(paths.Root, "open.request"), "open"); } catch (Exception) { }
        }
        using var single = new Mutex(true, mutexName, out var first);
        if (!first)
        {
            return;
        }

        // Any quit.request already on disk before this instance claimed the single-instance mutex belonged to a
        // previous instance (e.g. an older version's --quit race during update), never to us.
        TryTakeRequest(Path.Combine(paths.Root, "quit.request"));

        // DPI_AWARENESS_CONTEXT_SYSTEM_AWARE (-2)
        SetProcessDpiAwarenessContext(-2);
        using var app = new RecorderApp(paths, wasUpdated: args.Contains("--updated"));
        app.Run();
    }

    internal static void WriteAtomic(string path, string content)
    {
        var tmp = $"{path}.{Environment.ProcessId}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(tmp, content);
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception)
        {
            try { File.Delete(tmp); } catch (Exception) { }
            File.WriteAllText(path, content);
        }
    }

    internal static bool TryTakeRequest(string path)
    {
        for (var i = 0; i < 6; i++)
        {
            if (!File.Exists(path))
            {
                return false;
            }
            try
            {
                File.Delete(path);
                return true;
            }
            catch (FileNotFoundException)
            {
                return false;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Thread.Sleep(25);
            }
        }
        return false;
    }

    internal static bool TryConsumeRequest(string path, out string content)
    {
        content = "";
        for (var i = 0; i < 6; i++)
        {
            if (!File.Exists(path))
            {
                return false;
            }
            try
            {
                content = File.ReadAllText(path).Trim();
                File.Delete(path);
                return true;
            }
            catch (FileNotFoundException)
            {
                return false;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Thread.Sleep(25);
            }
        }
        return false;
    }

    [DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr context);
}

internal sealed record RecorderPaths(string Root, string Buffer, string ReplayExe)
{
    public string Markers => Path.Combine(Root, "markers.jsonl");

    public string Apps => Path.Combine(Root, "apps.jsonl");

    public string Windows => Path.Combine(Root, "windows.jsonl");

    public string State => Path.Combine(Root, "state.json");

    public string Settings => Path.Combine(Root, "settings.json");

    public static RecorderPaths FromEnvironment()
    {
        var root = Environment.GetEnvironmentVariable("REPLAY_ROOT") is { Length: > 0 } r
            ? r
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Replay");
        var exe = Environment.GetEnvironmentVariable("REPLAY_WINDOW_EXE") is { Length: > 0 } e
            ? e
            // Do not name "replay.exe": NVIDIA driver matches a game profile and enables G-SYNC pacing on the viewer.
            : Path.Combine(AppContext.BaseDirectory, "ScreenReplayViewer.exe");
        Directory.CreateDirectory(root);
        return new RecorderPaths(root, Path.Combine(root, "Buffer"), exe);
    }
}

internal sealed class RecorderApp : IDisposable
{
    private const int HotkeyOpen = 1;
    private const int HotkeyMark = 2;
    private const int HotkeySaveLast = 3;

    private RecorderPaths paths;
    private string bufferTrouble = "";

    private bool diskTight;

    private volatile string fastSync = "";
    private DateTimeOffset lastFastSync = DateTimeOffset.MinValue;
    private readonly List<string> oldBuffers = new();
    private readonly MessageWindow window;

    private readonly RawInput input;
    private readonly XInputPads controllers;
    private readonly Tray tray;
    private readonly WindowTrack windows;
    private readonly nuint watch;
    private readonly TrayPanel panel;
    private readonly NoteCard notes;
    private readonly Updater updater;
    private readonly DateTimeOffset startedAt = DateTimeOffset.UtcNow;
    private readonly TrayMenuItem statusItem;
    private readonly TrayMenuItem resumeItem;
    private readonly TrayMenuItem pause15Item;
    private readonly TrayMenuItem pause60Item;
    private readonly TrayMenuItem turnOffItem;
    private readonly TrayMenuItem turnOnItem;
    private ScreenRecorder? recorder;
    private (CaptureTarget Target, DateTimeOffset Since)? pendingDisplay;
    private bool starting;
    private bool locked;
    private DateTimeOffset? pausedUntil;
    private string lastApp = "";

    private IntPtr frontNoted;
    private uint frontNotedPid;

    public RecorderApp(RecorderPaths paths, bool wasUpdated = false)
    {
        this.paths = paths;
        L.Root = paths.Root;
        var buildTag = "";
        try
        {
            var bt = Path.Combine(AppContext.BaseDirectory, "build.txt");
            if (File.Exists(bt)) buildTag = " (" + File.ReadAllText(bt).Trim() + ")";
        }
        catch (Exception)
        {
        }
        Log($"app started: v{Updater.AppVersion}{buildTag}, os={Environment.OSVersion.Version}, packaged={Packaged.Is}, pid={Environment.ProcessId}");
        // Must construct MessageWindow first to install its SynchronizationContext before any awaits.
        window = new MessageWindow(Log);
        window.CloseAsked += async () => await ExitAsync();
        input = new RawInput(window, Log);
        window.Input = input.Handle;
        window.InputDevice = input.DeviceChanged;
        controllers = new XInputPads(window, input.Activity, Log);
        Packaged.RestartAfterUpdate(Log);
        ReadBuffers();
        statusItem = new TrayMenuItem(L.Status("starting")) { Enabled = false };
        resumeItem = Item("继续录制", "Resume recording", Resume);
        resumeItem.Visible = false;
        var menu = new List<TrayMenuItem?>
        {
            statusItem,
            null,
            Item("打开回放", "Open replay", () => OpenReplay(), "Ctrl+Alt+R"),
            Item("设置…", "Settings…", () => OpenReplay(showSettings: true)),
            Item("已保存片段文件夹", "Saved clips folder", OpenClipsFolder),
            Item("标记此刻", "Mark this moment", Mark, "Ctrl+Alt+M"),
            Item("保存最近一段", "Save the last moments", async () => await SaveLastAsync(), "Ctrl+Alt+S"),
            null,
        };
        pause15Item = Item("暂停 15 分钟", "Pause for 15 minutes", () => PauseFor(TimeSpan.FromMinutes(15)));
        pause60Item = Item("暂停 1 小时", "Pause for 1 hour", () => PauseFor(TimeSpan.FromHours(1)));
        turnOffItem = Item("关闭后台录制", "Turn off background recording", () => SetEnabled(false));
        turnOnItem = Item("开启后台录制", "Turn on background recording", () => SetEnabled(true));
        turnOnItem.Visible = false;
        menu.Add(turnOnItem);
        menu.Add(pause15Item);
        menu.Add(pause60Item);
        menu.Add(resumeItem);
        menu.Add(turnOffItem);
        menu.Add(null);
        menu.Add(Item("退出", "Quit", async () => await ExitAsync()));
        tray = new Tray(window, menu, () => OpenReplay())
        {
            Icon = TrayIcon("tray-off.ico"),
            Text = "ScreenReplay",
            Visible = string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("REPLAY_TEST_WINDOW")),
        };

        panel = new TrayPanel(paths.ReplayExe, paths.Root, window.Handle, FindReplay, Log);
        notes = new NoteCard(paths.ReplayExe, paths.Root, FindReplay, Log);
        updater = new Updater(
            paths.Root,
            IsReplayWindowVisible,
            Log,
            (title, body) => tray.ShowBalloonTip(3500, title, body, warning: false),
            wasUpdated);
        tray.Panel = (x, y) => panel.Show(x, y);
        window.PanelChose += Chosen;

        window.HotkeyPressed += id =>
        {
            if (id == HotkeyOpen)
            {
                OpenReplay();
            }
            else if (id == HotkeyMark)
            {
                Mark();
            }
            else if (id == HotkeySaveLast)
            {
                _ = SaveLastAsync();
            }
        };
        windows = new WindowTrack(window, paths.Windows, Log, _ =>
        {
            recorder?.ScreenChanged();
            NoteForegroundApp();
        }, () =>
        {
            Log("desktop switched");
            recorder?.ScreenChanged();
        }) { Active = false };
        window.SessionChanged += OnSessionChanged;
        window.PowerChanged += OnPowerChanged;
        void RenewPanelSoon(string why)
        {
            if (renewTimer != 0)
            {
                window.Stop(renewTimer);
                renewTimer = 0;
            }

            if (exiting)
            {
                return;
            }

            renewTimer = window.Every(3000, () =>
            {
                window.Stop(renewTimer);
                renewTimer = 0;
                if (exiting)
                {
                    return;
                }

                panel.Renew(why);
                notes.Renew();
                RenewReplayIfHidden(why);
            });
        }

        window.DisplayChanged += () =>
        {
            Log("display changed");
            recorder?.DisplayChanged();
            recorder?.ScreenChanged();
            RenewPanelSoon("displays changed");
            _ = CheckAsync();
        };
        window.ScreenPower += on =>
        {
            Replay.Recording.DisplayMemory.ScreenOn(on);
            Log(on ? "screen on" : "screen off");
            recorder?.DisplayChanged();
            if (on)
            {
                recorder?.RenewCapture("the screen came on");
                RenewPanelSoon("screen on");
            }
        };
        watch = window.Every(2000, async () => await CheckAsync());
        var ui = SynchronizationContext.Current;
        asks = new FileSystemWatcher(paths.Root) { NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite, EnableRaisingEvents = true };
        FileSystemEventHandler asked = (_, e) =>
        {
            if (e.Name is "pause.request" or "settings.json" or "viewer.json" or "purge.request" or "quit.request" or "update.request" or
                "open.request" or "save.request" or "flush.request" or "capture-diag.request")
            {
                ui?.Post(_ => _ = CheckAsync(), null);
            }
        };
        asks.Created += asked;
        asks.Changed += asked;
        asks.Renamed += (s, e) => asked(s, e);
        _ = CheckAsync();
        if (!exiting && FindReplay() is null)
        {
            Program.TryTakeRequest(Path.Combine(paths.Root, "export.busy"));
            StartReplay(hidden: true);
        }
    }

    private readonly FileSystemWatcher asks;

    private nuint renewTimer;

    private Process? replay;
    private volatile bool renewingReplay;
    private volatile bool openAfterRenew;
    private bool replayWasVisible;
    private DateTimeOffset? replayHiddenSince;
    private DateTimeOffset replayStartedAt = DateTimeOffset.MinValue;

    private void OnSessionChanged(int code)
    {
        // WTS_SESSION_LOCK 7, WTS_CONSOLE_DISCONNECT 2, WTS_REMOTE_DISCONNECT 4
        if (code is 7 or 2 or 4)
        {
            locked = true;
            Log($"session locked (code={code})");
        }
        // WTS_SESSION_UNLOCK 8, WTS_CONSOLE_CONNECT 1, WTS_REMOTE_CONNECT 3
        else if (code is 8 or 1 or 3)
        {
            locked = false;
            Log($"session unlocked (code={code})");
        }

        _ = CheckAsync();
    }

    private bool asleep;

    private void OnPowerChanged(int code)
    {
        if (code == 4)
        {
            asleep = true;
            Log("sleep");
        }
        else if (code is 7 or 18)
        {
            if (!asleep)
            {
                return;
            }

            asleep = false;
            Log("woke");
        }
        else
        {
            return;
        }

        _ = CheckAsync();
    }

    private readonly List<(TrayMenuItem Item, string Zh, string En)> labelled = [];

    private TrayMenuItem Item(string zh, string en, Action onClick, string keys = "")
    {
        var item = new TrayMenuItem(L.T(zh, en), onClick, keys);
        labelled.Add((item, zh, en));
        return item;
    }

    private bool? labelledEnglish;

    private void Relabel()
    {
        var en = L.English;
        if (labelledEnglish == en)
        {
            return;
        }

        labelledEnglish = en;
        foreach (var (item, zh, english) in labelled)
        {
            item.Text = en ? english : zh;
        }
    }

    private string? HoldReason()
    {
        if (locked || asleep)
        {
            return "locked";
        }

        if (pausedUntil is { } until && until > DateTimeOffset.Now)
        {
            statusArg = until.ToLocalTime().ToString("HH:mm");
            return "paused";
        }

        if (settings.PauseInFullscreen && FullScreen.GameInFront())
        {
            return "fullscreen";
        }

        return null;
    }

    private bool checking;

    private bool checkAgain;

    private async Task CheckAsync()
    {
        if (checking)
        {
            checkAgain = true;
            return;
        }

        checking = true;
        try
        {
            do
            {
                checkAgain = false;
                await CheckOnceAsync();
            }
            while (checkAgain && !exiting);
        }
        finally
        {
            checking = false;
        }
    }

    private async Task CheckOnceAsync()
    {
        if (exiting)
        {
            return;
        }

        var quitRequest = Path.Combine(paths.Root, "quit.request");
        if (Program.TryTakeRequest(quitRequest))
        {
            await ExitAsync();
            return;
        }
        var openRequest = Path.Combine(paths.Root, "open.request");
        if (Program.TryTakeRequest(openRequest))
        {
            OpenReplay();
        }
        NoteForegroundApp();
        var pauseRequest = Path.Combine(paths.Root, "pause.request");
        if (Program.TryConsumeRequest(pauseRequest, out var asked))
        {
            if (asked == "resume")
            {
                pausedUntil = null;
            }
            else if (int.TryParse(asked, out var minutes) && minutes > 0)
            {
                pausedUntil = DateTimeOffset.Now + TimeSpan.FromMinutes(minutes);
            }
        }
        if (pausedUntil is { } until && until <= DateTimeOffset.Now)
        {
            pausedUntil = null;
        }

        var purgeRequest = Path.Combine(paths.Root, "purge.request");
        if (Program.TryTakeRequest(purgeRequest))
        {
            if (recorder is not null)
            {
                await StopRecorderAsync();
                await recorder.DisposeAsync();
                recorder = null;
            }
            Purge();
        }

        var wanted = RecorderSettings.ReadCached(paths.Settings);
        updater.Poll(wanted.AutoUpdate, DateTimeOffset.UtcNow - startedAt >= TimeSpan.FromSeconds(60));
        ApplyAutostart(wanted.Consented && wanted.Autostart);
        if (wanted.Consented)
        {
            RegisterHotkeys();
        }
        var (bufferDir, trouble) = ResolveBuffer(wanted.BufferDir);
        bufferTrouble = trouble;
        if (!string.Equals(Path.GetFullPath(bufferDir), Path.GetFullPath(paths.Buffer), StringComparison.OrdinalIgnoreCase))
        {
            if (recorder is not null)
            {
                await StopRecorderAsync();
                await recorder.DisposeAsync();
                recorder = null;
            }

            var before = paths.Buffer;
            paths = paths with { Buffer = bufferDir };
            oldBuffers.RemoveAll(d => string.Equals(d, bufferDir, StringComparison.OrdinalIgnoreCase));
            if (Directory.Exists(before) && Directory.EnumerateFiles(before, "*.mp4").Any() &&
                !oldBuffers.Contains(before, StringComparer.OrdinalIgnoreCase))
            {
                oldBuffers.Add(before);
            }
            Log($"buffer: {before} -> {bufferDir}" + (trouble.Length > 0 ? $" ({trouble}: {wanted.BufferDir} cannot be written)" : wanted.BufferDir.Length == 0 ? " (back to the default)" : " (as the settings ask)"));
            WriteBuffers();
        }
        if (recorder is not null && recorderCodec != "" && recorderCodec != EffectiveCodecFor(wanted))
        {
            await StopRecorderAsync();
            await recorder.DisposeAsync();
            recorder = null;
        }

        if (recorder is not null && (wanted.Window != settings.Window || wanted.SystemAudio != settings.SystemAudio || wanted.Microphone != settings.Microphone ||
            wanted.Codec != settings.Codec || wanted.MaxHeight != settings.MaxHeight || wanted.FrameRate != settings.FrameRate || wanted.Quality != settings.Quality))
        {
            await StopRecorderAsync();
            await recorder.DisposeAsync();
            recorder = null;
            pendingDisplay = null;
        }

        // Wait 2 s after primary monitor switch or resolution change (e.g. MUX handoff) before restarting capture.
        if (recorder is { IsRunning: true, Target: { IsWindow: false } curTarget } && Replay.Recording.DisplayMemory.ScreenIsOn)
        {
            var primaryNow = CaptureTarget.PrimaryMonitor();
            if (primaryNow is { Width: >= 320, Height: >= 200 }
                && (primaryNow.Monitor != curTarget.Monitor || primaryNow.Width != curTarget.Width || primaryNow.Height != curTarget.Height))
            {
                var nowUtc = DateTimeOffset.UtcNow;
                if (pendingDisplay is { } pd && pd.Target == primaryNow)
                {
                    if (nowUtc - pd.Since >= TimeSpan.FromSeconds(2))
                    {
                        Log($"primary display changed: {curTarget.Width}x{curTarget.Height} (0x{curTarget.Monitor:X}) -> {primaryNow.Width}x{primaryNow.Height} (0x{primaryNow.Monitor:X}), restarting recorder");
                        pendingDisplay = null;
                        await StopRecorderAsync();
                        await recorder.DisposeAsync();
                        recorder = null;
                    }
                }
                else
                {
                    pendingDisplay = (primaryNow, nowUtc);
                }
            }
            else
            {
                pendingDisplay = null;
            }
        }
        else
        {
            pendingDisplay = null;
        }

        settings = wanted;
        recorder?.SetSkipUnrecorded(ReadFoldGaps());
        Housekeeping();
        CheckReplayIdle();
        Relabel();
        statusArg = "";
        var hold = settings.Enabled && settings.Consented ? HoldReason() : "disabled";
        if (hold is null && DiskFree() is >= 0 and < (1L << 30))
        {
            hold = "diskLow";
        }
        resumeItem.Visible = pausedUntil is not null && (settings.Enabled && settings.Consented);
        pause15Item.Visible = (settings.Enabled && settings.Consented);
        pause60Item.Visible = (settings.Enabled && settings.Consented);
        turnOffItem.Visible = (settings.Enabled && settings.Consented);
        turnOnItem.Visible = !(settings.Enabled && settings.Consented);
        if (hold is not null)
        {
            if (recorder?.IsRunning == true)
            {
                await StopRecorderAsync();
            }

            windows.Active = false;
            SetStatus(hold);
            return;
        }

        if (recorder?.IsRunning == true || starting)
        {
            var saveRequest = Path.Combine(paths.Root, "save.request");
            if (Program.TryTakeRequest(saveRequest))
            {
                _ = SaveLastAsync();
            }

            await FlushIfAskedAsync();
            TraceIfAsked();
            if (!windows.Active)
            {
                windows.Active = true;
                windows.Restart();
            }

            SetStatus("recording");
            return;
        }

        if (noEncoderAt is { } at && DateTimeOffset.UtcNow - at < TimeSpan.FromMinutes(1))
        {
            SetStatus("noEncoder");
            return;
        }

        starting = true;
        try
        {
            var target = TestTarget() ?? CaptureTarget.PrimaryMonitor();
            if (target is null)
            {
                SetStatus("noDisplay");
                return;
            }

            await RequestBorderlessAsync();
            recorder ??= CreateRecorder(target);
            await recorder.StartAsync(target, CancellationToken.None);
            SetStatus("recording");
        }
        catch (Exception ex)
        {
            noEncoderAt = ex is NoEncoderException ? DateTimeOffset.UtcNow : null;
            SetStatus(noEncoderAt is null ? "startFailed" : "noEncoder");
            Log("start failed: " + ex);
        }
        finally
        {
            starting = false;
        }
    }

    private static CaptureTarget? TestTarget()
    {
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("REPLAY_TEST_WINDOW")))
        {
            return null;
        }

        var hwnd = TestHandle("REPLAY_TEST_WINDOW");
        return (hwnd != IntPtr.Zero ? CaptureTarget.ForWindow(hwnd) : null) ?? new CaptureTarget(IntPtr.Zero, new IntPtr(-1), 0, 0, 0);
    }

    private static IntPtr TestHandle(string name)
    {
        var value = Environment.GetEnvironmentVariable(name);
        if (string.IsNullOrWhiteSpace(value))
        {
            return IntPtr.Zero;
        }

        var hex = value.Trim().ToLowerInvariant().Replace("0x", string.Empty, StringComparison.Ordinal);
        return long.TryParse(hex, System.Globalization.NumberStyles.HexNumber, null, out var handle) ? new IntPtr(handle) : new IntPtr(-1);
    }

    private RecorderSettings settings = RecorderSettings.Default;

    private bool? autostartApplied;

    private void ApplyAutostart(bool on)
    {
        if (autostartApplied == on || !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("REPLAY_TEST_WINDOW")))
        {
            return;
        }

        autostartApplied = on;
        if (Packaged.Is)
        {
            _ = Packaged.SetStartupAsync(on, Log);
            return;
        }

        try
        {
            using var run = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
            if (on)
            {
                run.SetValue("Replay", $"\"{Environment.ProcessPath}\" --background");
            }
            else
            {
                run.DeleteValue("Replay", throwOnMissingValue: false);
            }
        }
        catch (Exception ex)
        {
            Log("autostart failed: " + ex.Message);
        }
    }

    private DateTimeOffset lastHousekeeping = DateTimeOffset.MinValue;

    private (string Dir, string Trouble) ResolveBuffer(string wanted)
    {
        var fallback = Path.Combine(paths.Root, "Buffer");
        if (wanted.Length == 0)
        {
            return (fallback, "");
        }

        if (string.Equals(Path.GetFullPath(wanted), Path.GetFullPath(paths.Buffer), StringComparison.OrdinalIgnoreCase) && Directory.Exists(wanted))
        {
            return (wanted, "");
        }

        try
        {
            Directory.CreateDirectory(wanted);
            var probe = Path.Combine(wanted, ".write-probe");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return (wanted, "");
        }
        catch (Exception)
        {
            return (fallback, "bufferUnavailable");
        }
    }

    private void WriteBuffers()
    {
        try
        {
            var olds = string.Join(",", oldBuffers.Select(Json));
            Program.WriteAtomic(Path.Combine(paths.Root, "buffers.json"), $"{{\"current\":{Json(paths.Buffer)},\"old\":[{olds}]}}");
        }
        catch (IOException)
        {
        }
    }

    private void ReadBuffers()
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(paths.Root, "buffers.json")));
            if (doc.RootElement.TryGetProperty("old", out var olds) && olds.ValueKind == System.Text.Json.JsonValueKind.Array)
            {
                foreach (var d in olds.EnumerateArray())
                {
                    if (d.GetString() is { Length: > 0 } dir)
                    {
                        oldBuffers.Add(dir);
                    }
                }
            }
            if (doc.RootElement.TryGetProperty("current", out var cur) && cur.GetString() is { Length: > 0 } was &&
                !string.Equals(was, paths.Buffer, StringComparison.OrdinalIgnoreCase) && !oldBuffers.Contains(was, StringComparer.OrdinalIgnoreCase))
            {
                oldBuffers.Add(was);
            }
        }
        catch (Exception)
        {
        }
    }

    private long DiskFree()
    {
        try
        {
            return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(paths.Buffer))!).AvailableFreeSpace;
        }
        catch (Exception)
        {
            return -1;
        }
    }

    private void Purge()
    {
        var count = 0;
        foreach (var dir in oldBuffers.Append(paths.Buffer).Distinct(StringComparer.OrdinalIgnoreCase).ToList())
        {
            if (!Directory.Exists(dir))
            {
                continue;
            }
            foreach (var file in Directory.EnumerateFiles(dir).ToList())
            {
                var ext = Path.GetExtension(file).ToLowerInvariant();
                if (ext == ".mp4" || SegmentStore.Sidecars.Contains(ext))
                {
                    TryDelete(file);
                    count += ext == ".mp4" ? 1 : 0;
                }
            }
        }
        var thumbs = Path.Combine(paths.Root, "Thumbs");
        if (Directory.Exists(thumbs))
        {
            foreach (var file in Directory.EnumerateFiles(thumbs).ToList())
            {
                TryDelete(file);
            }
        }
        var icons = Path.Combine(paths.Root, "AppIcons");
        if (Directory.Exists(icons))
        {
            foreach (var file in Directory.EnumerateFiles(icons, "*.txt").ToList())
            {
                TryDelete(file);
            }
        }
        TryDelete(paths.Apps);
        TryDelete(paths.Markers);
        windows.Clear();
        oldBuffers.Clear();
        WriteBuffers();
        Log($"purge: {count} segments deleted, as the replay window asked");
    }

    private void Housekeeping()
    {
        if (DateTimeOffset.UtcNow - lastHousekeeping < TimeSpan.FromSeconds(30))
        {
            return;
        }

        lastHousekeeping = DateTimeOffset.UtcNow;
        if (DateTimeOffset.UtcNow - lastFastSync >= TimeSpan.FromMinutes(5))
        {
            lastFastSync = DateTimeOffset.UtcNow;
            _ = Task.Run(() =>
            {
                var was = fastSync;
                fastSync = NvidiaSync.Where();
                if (fastSync != was)
                {
                    Log("nvidia fast sync: " + (fastSync == "" ? "off" : fastSync));
                }
            });
        }

        var skipUnrecorded = ReadFoldGaps();
        var store = recorder?.Store ?? new SegmentStore(paths.Buffer);
        DateTimeOffset? earliestKept = null;

        if (oldBuffers.Count > 0)
        {
            var oldStores = new List<(string Dir, SegmentStore Store)>();
            foreach (var dir in oldBuffers)
            {
                if (Directory.Exists(dir))
                {
                    oldStores.Add((dir, new SegmentStore(dir)));
                }
            }

            if (skipUnrecorded)
            {
                try
                {
                    var allStores = oldStores.Select(x => x.Store).Append(store).ToList();
                    SegmentStore.PruneRecordedAcross(allStores, settings.Window);
                }
                catch (Exception ex)
                {
                    Log("expire (recorded across buffers) failed: " + ex.Message);
                }
            }
            else
            {
                foreach (var (_, old) in oldStores)
                {
                    try
                    {
                        old.Prune(DateTimeOffset.UtcNow - settings.Window);
                    }
                    catch (Exception ex)
                    {
                        Log("expire (old buffer) failed: " + ex.Message);
                    }
                }
            }

            var gone = new List<string>();
            foreach (var (dir, old) in oldStores)
            {
                try
                {
                    var rem = old.List();
                    if (rem.Count == 0)
                    {
                        gone.Add(dir);
                    }
                    else if (earliestKept is null || rem[0].StartUtc < earliestKept)
                    {
                        earliestKept = rem[0].StartUtc;
                    }
                }
                catch (Exception ex)
                {
                    Log("expire (old buffer list) failed: " + ex.Message);
                }
            }
            if (gone.Count > 0)
            {
                foreach (var dir in gone)
                {
                    Log($"buffer: the folder written before is empty now, forgotten: {dir}");
                }
                oldBuffers.RemoveAll(d => gone.Contains(d));
                WriteBuffers();
            }
        }
        else if (recorder?.IsRunning != true)
        {
            try
            {
                if (skipUnrecorded)
                {
                    store.PruneRecorded(settings.Window);
                }
                else
                {
                    store.Prune(DateTimeOffset.UtcNow - settings.Window);
                }
            }
            catch (Exception ex)
            {
                Log("expire failed: " + ex.Message);
            }
        }

        try
        {
            var segments = store.List().OrderBy(s => s.StartUtc).ToList();
            if (segments.Count > 0 && (earliestKept is null || segments[0].StartUtc < earliestKept))
            {
                earliestKept = segments[0].StartUtc;
            }
            var sizes = segments.Select(s => s.Bytes).ToList();
            var total = sizes.Sum();
            var free = DiskFree();
            const long KeepFree = 10L << 30;
            diskTight = free >= 0 && free < KeepFree;
            for (var i = 0; i < segments.Count - 1; i++)
            {
                var low = free >= 0 && free < KeepFree;
                if (!low)
                {
                    break;
                }

                if (TryDelete(segments[i].Path))
                {
                    foreach (var ext in SegmentStore.Sidecars)
                    {
                        TryDelete(Path.ChangeExtension(segments[i].Path, ext));
                    }
                    total -= sizes[i];
                    if (free >= 0)
                    {
                        free += sizes[i];
                    }
                }
            }

            var stems = segments.Select(s => Path.GetFileNameWithoutExtension(s.Path)).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var thumbs = Path.Combine(paths.Root, "Thumbs");
            if (Directory.Exists(thumbs))
            {
                foreach (var file in Directory.EnumerateFiles(thumbs, "*.thumbs"))
                {
                    if (!stems.Contains(Path.GetFileNameWithoutExtension(file)) && File.Exists(Path.Combine(paths.Buffer, Path.GetFileNameWithoutExtension(file) + ".mp4")) is false)
                    {
                        TryDelete(file);
                    }
                }
            }

            // Orphan sidecars (.input/.levels/.thumbs/.json, legacy .m4a) and broken .mp4 without .json left behind
            // in the active buffer folder from earlier crashes/kills: only touch files older than 5 minutes so an
            // in-flight segment finalization is never disturbed.
            if (Directory.Exists(paths.Buffer))
            {
                var orphanCutoff = DateTime.UtcNow.AddMinutes(-5);
                foreach (var file in Directory.EnumerateFiles(paths.Buffer))
                {
                    var ext = Path.GetExtension(file).ToLowerInvariant();
                    if (ext == ".recording")
                    {
                        continue;
                    }
                    var stem = Path.GetFileNameWithoutExtension(file);
                    var isOrphan = false;
                    if (SegmentStore.Sidecars.Contains(ext))
                    {
                        isOrphan = !stems.Contains(stem) && !File.Exists(Path.Combine(paths.Buffer, stem + ".mp4"));
                    }
                    else if (ext == ".m4a")
                    {
                        isOrphan = true;
                    }
                    else if (ext == ".mp4")
                    {
                        isOrphan = !stems.Contains(stem) && !File.Exists(Path.ChangeExtension(file, ".json"));
                    }
                    if (isOrphan)
                    {
                        try
                        {
                            if (File.GetLastWriteTimeUtc(file) < orphanCutoff)
                            {
                                TryDelete(file);
                            }
                        }
                        catch (Exception)
                        {
                        }
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log("prune failed: " + ex.Message);
        }

        var wallCutoff = DateTimeOffset.UtcNow - settings.Window;
        var metaCutoff = earliestKept is { } e && e < wallCutoff ? e : wallCutoff;
        TrimLines(paths.Apps, metaCutoff);
        TrimLines(paths.Markers, metaCutoff);
        windows.Prune(metaCutoff);
    }

    private (DateTime Written, long Length, bool FoldGaps)? viewerFoldCache;

    private bool ReadFoldGaps()
    {
        var path = Path.Combine(paths.Root, "viewer.json");
        try
        {
            var info = new FileInfo(path);
            var written = info.Exists ? info.LastWriteTimeUtc : DateTime.MinValue;
            var length = info.Exists ? info.Length : -1;
            if (viewerFoldCache is { } c && c.Written == written && c.Length == length)
            {
                return c.FoldGaps;
            }

            var value = true;
            if (info.Exists)
            {
                using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(path));
                if (doc.RootElement.TryGetProperty("fold_gaps", out var fg) &&
                    fg.ValueKind is System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False)
                {
                    value = fg.GetBoolean();
                }
            }
            viewerFoldCache = (written, length, value);
            return value;
        }
        catch (Exception)
        {
            return viewerFoldCache?.FoldGaps ?? true;
        }
    }

    private static bool TryDelete(string path)
    {
        try
        {
            File.Delete(path);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private readonly Dictionary<string, DateTimeOffset> lastTrim = [];

    private void TrimLines(string path, DateTimeOffset cutoffTime)
    {
        try
        {
            if (!File.Exists(path) || new FileInfo(path).Length < 256 << 10 ||
                (lastTrim.TryGetValue(path, out var then) && DateTimeOffset.UtcNow - then < TimeSpan.FromMinutes(10)))
            {
                return;
            }

            lastTrim[path] = DateTimeOffset.UtcNow;
            var cutoff = cutoffTime.ToUnixTimeMilliseconds();
            var kept = new List<string>();
            string? before = null;
            foreach (var line in File.ReadAllLines(path))
            {
                var at = line.StartsWith("{\"at\":", StringComparison.Ordinal) && long.TryParse(line.AsSpan(6, Math.Max(0, line.IndexOf(',') - 6)), out var v) ? v : 0;
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

            File.WriteAllLines(path + ".tmp", kept, new UTF8Encoding(false));
            File.Move(path + ".tmp", path, overwrite: true);
        }
        catch (Exception ex)
        {
            Log("trim failed: " + ex.Message);
        }
    }

    private DateTimeOffset? noEncoderAt;

    private int hevcFaults;
    private DateTimeOffset lastHevcFault = DateTimeOffset.MinValue;
    private bool noHevcThisRun;
    private string recorderCodec = "";

    private (string Codec, string Why) EffectiveCodec() => EffectiveCodecOf(settings);

    private string EffectiveCodecFor(RecorderSettings s) => EffectiveCodecOf(s).Codec;

    private (string Codec, string Why) EffectiveCodecOf(RecorderSettings settings)
    {
        if (settings.Codec != "HEVC")
        {
            return ("H264", "");
        }

        if (!Decoders.Hevc)
        {
            return ("H264", "nodecoder");
        }

        return noHevcThisRun ? ("H264", "faults") : ("HEVC", "");
    }

    private ScreenRecorder CreateRecorder(CaptureTarget target)
    {
        var codec = EffectiveCodec().Codec;
        recorderCodec = codec;
        var options = new RecorderOptions(paths.Buffer, settings.Window, settings.FrameRate, settings.MaxHeight, codec, settings.Quality)
        {
            SegmentLength = TimeSpan.FromSeconds(30),
            SystemAudio = settings.SystemAudio,
            Microphone = settings.Microphone && !target.IsWindow,
            Activity = input.Activity,
            ForceHdr = Environment.GetEnvironmentVariable("REPLAY_FORCE_HDR") == "1",
            SkipUnrecorded = ReadFoldGaps(),
        };
        var created = new ScreenRecorder(options, OnRecorderEvent);
        created.Faulted += (_, ex) =>
        {
            Log("faulted: " + ex);
            if (created.ActualCodec == "HEVC" && ex is not CaptureStalledException)
            {
                hevcFaults = DateTimeOffset.UtcNow - lastHevcFault < TimeSpan.FromMinutes(10) ? hevcFaults + 1 : 1;
                lastHevcFault = DateTimeOffset.UtcNow;
                if (hevcFaults >= 2)
                {
                    noHevcThisRun = true;
                }
            }
        };
        created.CodecFallback += (_, ex) => Log("HEVC unavailable, recording H.264: " + ex.Message);
        return created;
    }

    private static bool borderlessAsked;

    private async Task RequestBorderlessAsync()
    {
        if (borderlessAsked)
        {
            return;
        }

        borderlessAsked = true;
        try
        {
            var asked = DateTimeOffset.UtcNow;
            var status = await GraphicsCaptureAccess.RequestAccessAsync(GraphicsCaptureAccessKind.Borderless);
            Log($"borderless capture: {status} ({(DateTimeOffset.UtcNow - asked).TotalSeconds:0.0} s)");
        }
        catch (Exception)
        {
        }
    }

    private async Task FlushIfAskedAsync()
    {
        var request = Path.Combine(paths.Root, "flush.request");
        if (recorder is null || !Program.TryTakeRequest(request))
        {
            return;
        }

        if (!Replay.Recording.DisplayMemory.ScreenIsOn)
        {
            // Skip viewer-driven flushes while the screen is off to avoid chopping 30 s segments into short keyframe-heavy segments.
            return;
        }

        try
        {
            await recorder.FlushAsync(CancellationToken.None);
        }
        catch (Exception ex)
        {
            Log("flush failed: " + ex.Message);
        }
    }

    private DateTimeOffset? traceUntil;

    private void TraceIfAsked()
    {
        var request = Path.Combine(paths.Root, "capture-diag.request");
        if (traceUntil is null && Program.TryTakeRequest(request))
        {
            Replay.Recording.FrameTrace.Take();
            Replay.Recording.FrameTrace.On = true;
            traceUntil = DateTimeOffset.UtcNow.AddSeconds(20);
            Log("capture diagnosis: tracing 20 s");
        }
        else if (traceUntil is { } until && DateTimeOffset.UtcNow >= until)
        {
            Replay.Recording.FrameTrace.On = false;
            traceUntil = null;
            File.WriteAllLines(Path.Combine(paths.Root, "capture-diag.txt"), Replay.Recording.FrameTrace.Take());
            Log("capture diagnosis: written");
        }
    }

    private async Task StopRecorderAsync()
    {
        if (recorder is null)
        {
            return;
        }

        try
        {
            await recorder.StopAsync(CancellationToken.None);
        }
        catch (Exception ex)
        {
            Log("stop failed: " + ex);
        }
    }

    private readonly Dictionary<string, IntPtr> trayIcons = [];

    private IntPtr TrayIcon(string name)
    {
        if (!trayIcons.TryGetValue(name, out var icon))
        {
            icon = Tray.LoadIcon(Path.Combine(AppContext.BaseDirectory, name));
            trayIcons[name] = icon;
        }

        return icon;
    }

    private string statusArg = "";

    private void SetStatus(string code)
    {
        var recording = recorder?.IsRunning == true;
        input.Listening = recording;
        controllers.Listening = recording;
        var off =!(settings.Enabled && settings.Consented) || code is "startFailed" or "noDisplay" or "noEncoder";
        tray.Icon = TrayIcon(recording ? "ScreenReplay.ico" : off ? "tray-off.ico" : "tray-paused.ico");
        var text = L.Status(code, statusArg);
        statusItem.Text = text;
        tray.Text = "ScreenReplay" + " · " + text;
        WriteState(code, text);
    }

    private void WriteState(string code, string text)
    {
        try
        {
            var size = recorder?.OutputSize;
            long free = -1;
            try
            {
                free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(paths.Buffer))!).AvailableFreeSpace;
            }
            catch (Exception)
            {
            }

            (int Encoded, int Skipped) pace = recorder?.IsRunning == true ? recorder.Pace : (0, 0);
            var bitrate = recorder?.ActualBitrate is > 0 and var b ? b : size is { } d ? Bitrate.For(d.Width, d.Height, settings.FrameRate, settings.Quality, recorder?.ActualCodec ?? settings.Codec) : 0;
            var head = $"{{\"status\":{Json(text)},\"statusCode\":{Json(code)},\"audioTrouble\":{Json(audioTrouble)},\"statusArg\":{Json(statusArg)},\"recording\":{(recorder?.IsRunning == true ? "true" : "false")},";
            var body =
                $"\"codec\":{Json(recorder?.ActualCodec ?? "")},\"codecWhy\":{Json(recorder?.FellBack == true ? "fallback" : EffectiveCodec().Why)},\"width\":{size?.Width ?? 0},\"height\":{size?.Height ?? 0},\"fps\":{recorder?.ActualFrameRate ?? settings.FrameRate},\"fpsAsked\":{settings.FrameRate},\"fpsWhy\":{Json(recorder?.FrameRateFellBack == true ? "fallback" : "")},\"displayHz\":{DisplayHz()}," +
                $"\"bitrate\":{bitrate},\"diskFree\":{free},\"screenWidth\":{recorder?.Target?.Width ?? 0},\"screenHeight\":{recorder?.Target?.Height ?? 0}," +
                $"\"bufferDir\":{Json(paths.Buffer)},\"bufferTrouble\":{Json(bufferTrouble)},\"diskTight\":{(diskTight ? "true" : "false")},\"fastSync\":{Json(fastSync)}," +
                $"\"sharedGpu\":{(Replay.Recording.Graphics.Shared ? "true" : "false")},\"framesEncoded\":{pace.Encoded},\"framesSkipped\":{pace.Skipped}}}";
            // Rewrite on change or every 5 s; viewer treats state.json older than 10 s as recorder offline.
            var now = DateTimeOffset.UtcNow;
            var said = head + body;
            if (said == stateSaid && now - stateWritten < TimeSpan.FromSeconds(5))
            {
                return;
            }

            var json = head + $"\"at\":{now.ToUnixTimeMilliseconds()}," + body;
            WriteWhole(paths.State, json);
            stateSaid = said;
            stateWritten = now;
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private string stateSaid = "";
    private DateTimeOffset stateWritten = DateTimeOffset.MinValue;

    internal static void WriteWhole(string path, string text)
    {
        var part = path + ".part";
        File.WriteAllText(part, text);
        try
        {
            File.Move(part, path, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            File.WriteAllText(path, text);
            try { File.Delete(part); } catch (Exception) { }
        }
    }

    private bool hotkeysOn;

    private void RegisterHotkeys()
    {
        if (hotkeysOn)
        {
            return;
        }

        hotkeysOn = true;
        // MOD_CONTROL | MOD_ALT, and the letter's virtual-key code
        window.RegisterHotkey(HotkeyOpen, 0x2 | 0x1, 'R');
        window.RegisterHotkey(HotkeyMark, 0x2 | 0x1, 'M');
        if (!window.RegisterHotkey(HotkeySaveLast, 0x2 | 0x1, 'S'))
        {
            Log("Ctrl+Alt+S is taken by another app");
        }
    }

    private void SetEnabled(bool on)
    {
        if (on && !settings.Consented)
        {
            OpenReplay();
            return;
        }

        try
        {
            var node = File.Exists(paths.Settings)
                ? System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(paths.Settings)) as System.Text.Json.Nodes.JsonObject
                : null;
            node ??= new System.Text.Json.Nodes.JsonObject();
            node["enabled"] = on;
            WriteWhole(paths.Settings, node.ToJsonString());
        }
        catch (Exception e)
        {
            Log($"settings not written: {e.Message}");
        }

        if (on)
        {
            pausedUntil = null;
        }

        _ = CheckAsync();
    }

    private void PauseFor(TimeSpan length)
    {
        pausedUntil = DateTimeOffset.Now + length;
        _ = CheckAsync();
    }

    private void Resume()
    {
        pausedUntil = null;
        _ = CheckAsync();
    }

    private bool savingLast;

    private async Task SaveLastAsync()
    {
        if (savingLast || recorder is null)
        {
            return;
        }

        savingLast = true;
        notes.Saving();
        try
        {
            if (recorder.IsRunning)
            {
                try
                {
                    await recorder.FlushAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(10));
                }
                catch (TimeoutException)
                {
                    Log("save last: flush timed out");
                }
            }

            var segments = recorder.Store.List().OrderBy(s => s.StartUtc).ToList();
            var dir = ClipsFolder();
            Directory.CreateDirectory(dir);
            var start = segments.Count > 0 ? segments[^1].EndUtc - TimeSpan.FromSeconds(settings.LastSeconds) : DateTimeOffset.UtcNow;
            var stem = Path.Combine(dir, $"{L.T("回放", "Replay")} {start.ToLocalTime():yyyy-MM-dd HH-mm-ss}");
            var output = stem + ".mp4";
            for (var n = 2; File.Exists(output) || File.Exists(output + ".partial.mp4"); n++)
            {
                output = $"{stem} ({n}).mp4";
            }
            var length = TimeSpan.FromSeconds(settings.LastSeconds);
            var result = await Task.Run(() => ClipJoiner.SaveLast(segments, length, output));
            if (result != 0 && segments.Count > 1)
            {
                Log("save last: joining failed (" + result + "), the newest segment alone");
                result = await Task.Run(() => ClipJoiner.SaveLast(segments.TakeLast(1).ToList(), length, output));
            }
            if (result == 0)
            {
                Append(Path.Combine(paths.Root, "saved.jsonl"), $"{{\"at\":{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()},\"path\":{Json(output)}}}");
                if (!notes.Saved(output))
                {
                    tray.ShowBalloonTip(2000, "ScreenReplay", L.T($"已保存最近 {settings.LastSeconds} 秒", $"Saved the last {settings.LastSeconds} seconds"), warning: false);
                }
            }
            else
            {
                Log("save last failed: " + result);
                Tell(2000, L.T("没能保存最近一段", "Couldn't save the last moments"), warning: true);
            }
        }
        catch (Exception ex)
        {
            Log("save last failed: " + ex);
        }
        finally
        {
            savingLast = false;
        }
    }

    private void Mark()
    {
        Append(paths.Markers, $"{{\"at\":{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()},\"kind\":\"mark\"}}");
        Tell(1500, L.T("已在时间轴上标记此刻", "Marked this moment on the timeline"), warning: false);
    }

    private void Tell(int balloonMs, string text, bool warning)
    {
        if (!notes.Text(text, warning))
        {
            tray.ShowBalloonTip(balloonMs, "ScreenReplay", text, warning);
        }
    }

    private void NoteForegroundApp()
    {
        var front = ForegroundApp.Front();
        var frontPid = ForegroundApp.PidOf(front);
        if (front != IntPtr.Zero && front == frontNoted && frontPid == frontNotedPid && !ForegroundApp.Unseen(front))
        {
            return;
        }

        frontNotedPid = frontPid;

        var (name, exe, title, helper) = ForegroundApp.Now();
        if (name.Length == 0 || name == lastApp || locked || !(settings.Enabled && settings.Consented))
        {
            frontNoted = name.Length > 0 && name == lastApp ? front : IntPtr.Zero;
            return;
        }

        frontNoted = front;

        lastApp = name;
        Append(paths.Apps, $"{{\"at\":{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()},\"app\":{Json(name)}}}");
        KeepAppIcon(name, exe, title);
        if (helper.Length > 0 && !string.Equals(helper, name, StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                var dir = Path.Combine(paths.Root, "AppIcons");
                foreach (var ext in new[] { ".txt", ".png" })
                {
                    var from = Path.Combine(dir, name.ToLowerInvariant() + ext);
                    var to = Path.Combine(dir, helper.ToLowerInvariant() + ext);
                    if (File.Exists(from) && File.Exists(to))
                    {
                        File.Copy(from, to, overwrite: true);
                    }
                }
            }
            catch (Exception ex)
            {
                Log("app icon alias failed: " + ex.Message);
            }
        }
    }

    private static bool TitleLike(string text) =>
        text.Contains(" - ") || text.Contains(" — ") || text.Contains(" – ") || text.Contains(" | ") ||
        (!text.Contains(' ') && text.Contains(':'));

    private static string OwnName(string exe, string name)
    {
        var info = System.Diagnostics.FileVersionInfo.GetVersionInfo(exe);
        bool bare(string? s) => string.IsNullOrEmpty(s) ||
            (string.Equals(s, name, StringComparison.OrdinalIgnoreCase) && !s.Contains('.') && (s.Contains('_') || s == s.ToLowerInvariant()));
        var description = info.FileDescription?.Trim();
        if (bare(description))
        {
            description = info.ProductName?.Trim();
        }
        return bare(description) ? "" : description!;
    }

    private readonly HashSet<string> namesChecked = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> iconsChecked = new(StringComparer.OrdinalIgnoreCase);

    private void KeepAppIcon(string name, string exe, string title)
    {
        try
        {
            var dir = Path.Combine(paths.Root, "AppIcons");
            var file = Path.Combine(dir, name.ToLowerInvariant() + ".png");
            var named = Path.Combine(dir, name.ToLowerInvariant() + ".txt");
            var kept = File.Exists(named) ? File.ReadAllText(named).Trim() : "";
            var stale = File.Exists(named) && (kept == name || TitleLike(kept) ||
                DateTime.UtcNow - File.GetLastWriteTimeUtc(named) > TimeSpan.FromDays(1));
            if (!stale && File.Exists(named) && exe.Length > 0 && namesChecked.Add(name))
            {
                var own = OwnName(exe, name);
                stale = own.Length > 0 && own != kept;
            }
            var iconStale = !File.Exists(file);
            if (!iconStale && exe.Length > 0 && iconsChecked.Add(name))
            {
                iconStale = File.GetLastWriteTimeUtc(exe) > File.GetLastWriteTimeUtc(file);
            }
            if (!iconStale && File.Exists(named) && !stale)
            {
                return;
            }

            if (exe.Length == 0)
            {
                return;
            }

            Directory.CreateDirectory(dir);
            if (!File.Exists(named) || stale)
            {
                var description = OwnName(exe, name);
                if (description.Length == 0)
                {
                    title = title.Trim();
                    description = title.Length > 0 && title.Length <= 40 && !TitleLike(title) ? title : name;
                }
                File.WriteAllText(named, description);
            }

            if (!iconStale)
            {
                return;
            }

            AppIconPng.Save(exe, file);
        }
        catch (Exception ex)
        {
            Log("app icon failed: " + ex.Message);
        }
    }

    private static string ClipsFolder()
        => Environment.GetEnvironmentVariable("REPLAY_OUT") is { Length: > 0 } custom
            ? custom
            : L.ClipsFolder();

    private void OpenClipsFolder()
    {
        try
        {
            var dir = ClipsFolder();
            Directory.CreateDirectory(dir);
            Process.Start(new ProcessStartInfo(dir) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            tray.ShowBalloonTip(3000, "ScreenReplay", L.T("片段文件夹打不开：", "Couldn't open the clips folder: ") + ex.Message, warning: true);
        }
    }

    private (int Pid, IntPtr Window)? FindReplay()
    {
        try
        {
            if (replay is { HasExited: false } mine)
            {
                var hwnd = ForegroundApp.TopWindowOf(mine.Id);
                if (hwnd != IntPtr.Zero)
                {
                    return (mine.Id, hwnd);
                }
            }
        }
        catch (Exception)
        {
        }

        foreach (var process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(paths.ReplayExe)))
        {
            using (process)
            {
                try
                {
                    if (panel.Owns(process.Id) || notes.Owns(process.Id) ||
                        !string.Equals(process.MainModule?.FileName, paths.ReplayExe, StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    var hwnd = process.MainWindowHandle != IntPtr.Zero ? process.MainWindowHandle : ForegroundApp.TopWindowOf(process.Id);
                    if (hwnd != IntPtr.Zero)
                    {
                        return (process.Id, hwnd);
                    }
                }
                catch (System.ComponentModel.Win32Exception) { }
                catch (InvalidOperationException) { }
            }
        }

        return null;
    }

    private bool IsReplayWindowVisible() => FindReplay() is { } found && ForegroundApp.IsReplayShown(found.Window);

    private bool IsExportBusy()
    {
        try
        {
            var busy = Path.Combine(paths.Root, "export.busy");
            if (!File.Exists(busy))
            {
                return false;
            }

            return DateTimeOffset.UtcNow - File.GetLastWriteTimeUtc(busy) < TimeSpan.FromHours(2);
        }
        catch (Exception)
        {
            return false;
        }
    }

    // Replaces a hidden resident viewer to reclaim long-lived GPU decoder/swap-chain allocations that NVIDIA drivers cannot safely release in-process.
    private void RenewReplayIfHidden(string why)
    {
        if (exiting || renewingReplay || IsExportBusy() ||
            !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("REPLAY_TEST_WINDOW")))
        {
            return;
        }

        // (skip the initial WM_POWERBROADCAST "screen on" delivered right after process startup)
        if (!replayWasVisible && DateTimeOffset.UtcNow - replayStartedAt < TimeSpan.FromSeconds(10))
        {
            return;
        }

        var found = FindReplay();
        if (found is null || ForegroundApp.IsReplayShown(found.Value.Window) ||
            ForegroundApp.HasOtherVisibleWindow(found.Value.Pid, found.Value.Window))
        {
            return;
        }

        Process? old = null;
        try
        {
            if (replay is { HasExited: false } mine && mine.Id == found.Value.Pid)
            {
                old = mine;
                replay = null;
            }
            else
            {
                old = Process.GetProcessById(found.Value.Pid);
            }

            renewingReplay = true;
            replayWasVisible = false;
            replayHiddenSince = null;
            Log($"replay window: renewed ({why}), pid {old.Id}");
            old.Kill();
        }
        catch (Exception ex)
        {
            renewingReplay = false;
            old?.Dispose();
            Log("replay window: not renewed: " + ex.Message);
            return;
        }

        var ui = SynchronizationContext.Current;
        _ = Task.Run(() =>
        {
            try
            {
                old.WaitForExit(2000);
            }
            catch (Exception)
            {
            }

            old.Dispose();
            Program.TryTakeRequest(Path.Combine(paths.Root, "export.busy"));
            void Finish()
            {
                renewingReplay = false;
                var show = openAfterRenew;
                openAfterRenew = false;
                if (exiting)
                {
                    return;
                }

                if (FindReplay() is null)
                {
                    StartReplay(hidden: !show);
                }
                else if (show)
                {
                    OpenReplay();
                }
            }

            if (ui is null)
            {
                Finish();
            }
            else
            {
                ui.Post(_ => Finish(), null);
            }
        });
    }

    private void CheckReplayIdle()
    {
        if (exiting || renewingReplay || !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("REPLAY_TEST_WINDOW")))
        {
            return;
        }

        var found = FindReplay();
        if (found is null)
        {
            replayWasVisible = false;
            replayHiddenSince = null;
            return;
        }

        if (ForegroundApp.IsReplayShown(found.Value.Window))
        {
            replayWasVisible = true;
            replayHiddenSince = null;
            return;
        }

        if (ForegroundApp.HasOtherVisibleWindow(found.Value.Pid, found.Value.Window))
        {
            replayHiddenSince = null;
            return;
        }

        var bloated = false;
        if (!replayWasVisible)
        {
            try
            {
                using var proc = Process.GetProcessById(found.Value.Pid);
                bloated = proc.PrivateMemorySize64 > 250L * 1024 * 1024;
            }
            catch (Exception)
            {
            }
        }

        if (!replayWasVisible && !bloated)
        {
            replayHiddenSince = null;
            return;
        }

        if (IsExportBusy())
        {
            replayHiddenSince = null;
            return;
        }

        var now = DateTimeOffset.UtcNow;
        replayHiddenSince ??= now;
        if (now - replayHiddenSince.Value >= TimeSpan.FromSeconds(30))
        {
            RenewReplayIfHidden(bloated ? "idle memory trim" : "idle after use");
        }
    }

    private void OpenReplay(bool showSettings = false)
    {
        if (exiting)
        {
            return;
        }

        if (showSettings)
        {
            try { Program.WriteAtomic(Path.Combine(paths.Root, "settings.request"), "settings"); } catch (Exception) { }
        }

        if (renewingReplay)
        {
            openAfterRenew = true;
            return;
        }

        if (FindReplay() is { } found)
        {
            ForegroundApp.Bring(found.Window);
            return;
        }

        StartReplay(hidden: false);
    }

    private void StartReplay(bool hidden)
    {
        var info = new ProcessStartInfo(paths.ReplayExe) { UseShellExecute = false, WorkingDirectory = AppContext.BaseDirectory };
        if (hidden)
        {
            info.Environment["REPLAY_HIDDEN"] = "1";
        }
        info.Environment["REPLAY_DIR"] = paths.Buffer;
        info.Environment["REPLAY_ROOT"] = paths.Root;
        info.Environment["REPLAY_RESIDENT"] = "1";
        info.Environment["REPLAY_RECORDER_HWND"] = window.Handle.ToInt64().ToString("x");
        try
        {
            var started = Process.Start(info);
            if (started is not null && !ChildJob.Hold(started))
            {
                Log("replay window: not bound to the recorder's life");
            }

            if (replay is { HasExited: false })
            {
                started?.Dispose();
            }
            else
            {
                replay?.Dispose();
                replay = started;
                replayStartedAt = DateTimeOffset.UtcNow;
            }
        }
        catch (Exception ex)
        {
            Log("open replay failed: " + ex.Message);
            tray.ShowBalloonTip(3000, "ScreenReplay", L.T("回放窗口打不开：", "Couldn't open the replay window: ") + ex.Message, warning: true);
        }
    }

    private void Chosen(int command)
    {
        switch (command)
        {
            case 1: OpenReplay(); break;
            case 2: OpenReplay(showSettings: true); break;
            case 3: OpenClipsFolder(); break;
            case 4: Mark(); break;
            case 5: _ = SaveLastAsync(); break;
            case 6: PauseFor(TimeSpan.FromMinutes(15)); break;
            case 7: PauseFor(TimeSpan.FromHours(1)); break;
            case 8: Resume(); break;
            case 9: SetEnabled(false); break;
            case 10: SetEnabled(true); break;
            case 11: _ = ExitAsync(); break;
        }
    }

    private bool exiting;

    private async Task ExitAsync()
    {
        if (exiting)
        {
            return;
        }

        exiting = true;
        window.Stop(watch);
        if (renewTimer != 0)
        {
            window.Stop(renewTimer);
            renewTimer = 0;
        }

        asks.EnableRaisingEvents = false;
        foreach (var process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(paths.ReplayExe)))
        {
            using (process)
            {
                try
                {
                    if (string.Equals(process.MainModule?.FileName, paths.ReplayExe, StringComparison.OrdinalIgnoreCase))
                    {
                        process.Kill();
                    }
                }
                catch (Exception) { }
            }
        }
        tray.Visible = false;
        panel.Dispose();
        notes.Dispose();
        await StopRecorderAsync();
        if (recorder is not null)
        {
            await recorder.DisposeAsync();
            recorder = null;
        }

        Program.TryTakeRequest(Path.Combine(paths.Root, "quit.request"));
        Log("quit");
        window.Quit();
    }

    public void Run() => window.Run();

    public void Dispose()
    {
        window.SessionChanged -= OnSessionChanged;
        exiting = true;
        panel.Dispose();
        notes.Dispose();
        if (recorder is not null)
        {
            try
            {
                recorder.DisposeAsync().AsTask().Wait(TimeSpan.FromSeconds(5));
            }
            catch (Exception)
            {
            }

            recorder = null;
        }

        replay?.Dispose();
        replay = null;
        updater.Dispose();
        windows.Dispose();
        tray.Dispose();
        foreach (var icon in trayIcons.Values)
        {
            Tray.FreeIcon(icon);
        }

        trayIcons.Clear();
        asks.Dispose();
        input.Dispose();
        controllers.Dispose();
        window.Dispose();
    }

    private void Append(string path, string line)
    {
        try
        {
            File.AppendAllText(path, line + "\n", new UTF8Encoding(false));
        }
        catch (IOException ex)
        {
            Log("append failed: " + ex.Message);
        }
    }

    private string audioTrouble = "";

    private void OnRecorderEvent(RecorderEvent e)
    {
        Log($"{e.Level} {e.Code}: {e.Message}");
        if (e.Level != "info" && e.Code.StartsWith("audio.", StringComparison.Ordinal))
        {
            audioTrouble = e.Code;
        }
        else if (e.Code.StartsWith("audio.", StringComparison.Ordinal) && e.Code.EndsWith("Back", StringComparison.Ordinal)
            && audioTrouble.StartsWith(e.Code[..^"Back".Length], StringComparison.Ordinal))
        {
            audioTrouble = "";
        }
    }

    private readonly object logGate = new();
    private int logWrites;

    private void Log(string text)
    {
        try
        {
            lock (logGate)
            {
                var file = Path.Combine(paths.Root, "recorder.log");
                if (++logWrites % 64 == 1 && File.Exists(file) && new FileInfo(file).Length > 2_000_000)
                {
                    File.Move(file, Path.Combine(paths.Root, "recorder.old.log"), overwrite: true);
                }

                File.AppendAllText(file, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {text}\n");
            }
        }
        catch (IOException)
        {
        }
    }

    private static int DisplayHz()
    {
        var mode = new DevMode { dmSize = (ushort)Marshal.SizeOf<DevMode>() };
        return EnumDisplaySettingsW(null, -1, ref mode) ? (int)mode.dmDisplayFrequency : 0;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DevMode
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public uint dmFields;
        public int dmPositionX, dmPositionY;
        public uint dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplaySettingsW(string? deviceName, int modeNum, ref DevMode mode);

    internal static string Json(string text)
    {
        var b = new StringBuilder("\"");
        foreach (var ch in text)
        {
            b.Append(ch switch
            {
                '"' => "\\\"",
                '\\' => "\\\\",
                < ' ' => $"\\u{(int)ch:x4}",
                _ => ch.ToString(),
            });
        }

        return b.Append('"').ToString();
    }
}

internal sealed record RecorderSettings(
    bool Enabled,
    TimeSpan Window,
    long MaxBytes,
    bool Autostart,
    bool SystemAudio,
    bool Microphone,
    bool PauseInFullscreen,
    string Codec = "HEVC",
    int MaxHeight = 0,
    int FrameRate = 30,
    string Quality = "high",
    int LastSeconds = 30,
    string BufferDir = "",
    bool Consented = false,
    bool AutoUpdate = true)
{
    public const int ConsentVersion = 1;

    public static RecorderSettings Default { get; } = new(false, TimeSpan.FromHours(2), 20L << 30, false, true, false, false);

    private static (string Path, DateTime Written, long Length, RecorderSettings Read)? cached;

    // Retries transient read/parse races and never clobbers valid cached settings with Default.
    public static RecorderSettings ReadCached(string path)
    {
        DateTime written;
        long length;
        bool exists;
        try
        {
            var info = new FileInfo(path);
            exists = info.Exists;
            written = exists ? info.LastWriteTimeUtc : DateTime.MinValue;
            length = exists ? info.Length : -1;
        }
        catch (Exception)
        {
            return cached is { } prev && prev.Path == path ? prev.Read : Read(path);
        }

        if (cached is { } c && c.Path == path && c.Written == written && c.Length == length)
        {
            return c.Read;
        }

        if (!exists)
        {
            cached = (path, written, length, Default);
            return Default;
        }

        for (var i = 0; i < 4; i++)
        {
            if (TryRead(path, out var read))
            {
                try
                {
                    var info2 = new FileInfo(path);
                    written = info2.Exists ? info2.LastWriteTimeUtc : written;
                    length = info2.Exists ? info2.Length : length;
                }
                catch (Exception) { }
                cached = (path, written, length, read);
                return read;
            }
            Thread.Sleep(25);
        }

        return cached is { } last && last.Path == path ? last.Read : Default;
    }

    public static RecorderSettings Read(string path) => TryRead(path, out var read) ? read : Default;

    private static bool TryRead(string path, out RecorderSettings result)
    {
        result = Default;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(path));
            var root = doc.RootElement;
            bool Flag(string name, bool fallback)
                => root.TryGetProperty(name, out var v) && v.ValueKind is System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False
                    ? v.GetBoolean()
                    : fallback;
            int Number(string name, int fallback)
                => root.TryGetProperty(name, out var v) && v.TryGetInt32(out var n) ? n : fallback;
            string Text(string name, string fallback)
                => root.TryGetProperty(name, out var v) && v.ValueKind == System.Text.Json.JsonValueKind.String ? v.GetString() ?? fallback : fallback;
            var minutes = Math.Clamp(Number("windowMinutes", 120), 5, 24 * 60);
            var gb = Math.Max(0, Number("maxGB", 20));
            result = new RecorderSettings(
                Flag("enabled", Default.Enabled),
                TimeSpan.FromMinutes(minutes),
                (long)gb << 30,
                Flag("autostart", Default.Autostart),
                Flag("systemAudio", Default.SystemAudio),
                Flag("microphone", Default.Microphone),
                Flag("pauseInFullscreen", Default.PauseInFullscreen),
                Text("codec", Default.Codec).Equals("h264", StringComparison.OrdinalIgnoreCase) ? "H264" : "HEVC",
                Math.Clamp(Number("maxHeight", Default.MaxHeight), 0, 4320),
                Number("fps", Default.FrameRate) switch { >= 120 => 120, >= 90 => 90, >= 60 => 60, _ => 30 },
                Text("quality", Default.Quality) is "low" or "medium" or "high" or "ultra" ? Text("quality", Default.Quality) : Default.Quality,
                Math.Clamp(Number("lastSeconds", Default.LastSeconds), 5, 600),
                Text("bufferDir", "").Trim(),
                root.TryGetProperty("consent", out var consent) && consent.ValueKind == System.Text.Json.JsonValueKind.Object &&
                    consent.TryGetProperty("version", out var version) && version.TryGetInt32(out var v) && v >= ConsentVersion,
                Flag("autoUpdate", true));
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
}

internal static class L
{
    public static string Root { get; set; } = "";

    private static bool english;
    private static long readAt = -1;

    public static bool English
    {
        get
        {
            var now = Environment.TickCount64;
            if (readAt >= 0 && now - readAt < 2000)
            {
                return english;
            }

            readAt = now;
            var language = "system";
            try
            {
                var path = Path.Combine(Root, "viewer.json");
                if (File.Exists(path))
                {
                    using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(path));
                    if (doc.RootElement.TryGetProperty("language", out var l) && l.ValueKind == System.Text.Json.JsonValueKind.String)
                    {
                        language = l.GetString() ?? "system";
                    }
                }
            }
            catch (Exception)
            {
            }

            english = language switch
            {
                "en" => true,
                "zh" => false,
                _ => System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName != "zh",
            };
            return english;
        }
    }

    public static string T(string zh, string en) => English ? en : zh;

    public static string Status(string code, string arg = "") => code switch
    {
        "recording" => T("后台录制中", "Recording in the background"),
        "locked" => T("已锁屏，暂停中", "Paused while locked"),
        "paused" => T($"已暂停，{arg} 继续", $"Paused until {arg}"),
        "fullscreen" => T("全屏应用在前台，暂停中", "Paused: a full-screen app is in front"),
        "disabled" => T("后台录制已关闭", "Background recording is off"),
        "diskLow" => T("磁盘空间不足，暂停录制", "Paused: the disk is almost full"),
        "noDisplay" => T("找不到主显示器", "No main display found"),
        "startFailed" => T("录制没能开始", "Recording couldn't start"),
        "noEncoder" => T("显卡不支持硬件视频编码，无法录制", "Can't record: the graphics has no hardware video encoder"),
        _ => T("启动中…", "Starting…"),
    };

    public static string ClipsFolder()
    {
        var videos = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Videos");
        var chinese = Path.Combine(videos, "回放");
        return English && !Directory.Exists(chinese) ? Path.Combine(videos, "Replay") : chinese;
    }
}

internal static class FullScreen
{
    // QUNS_BUSY = 2 (borderless fullscreen), QUNS_RUNNING_D3D_FULL_SCREEN = 3 (exclusive fullscreen).
    [DllImport("shell32.dll")]
    private static extern int SHQueryUserNotificationState(out int state);

    public static bool GameInFront()
        => SHQueryUserNotificationState(out var state) == 0 && state is 2 or 3;
}

internal static class ForegroundApp
{
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hwnd, int cmd);

    public static IntPtr Front() => GetForegroundWindow();

    public static uint PidOf(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            return 0;
        }

        GetWindowThreadProcessId(hwnd, out var pid);
        return pid;
    }

    public static string Name()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero)
        {
            return "";
        }

        GetWindowThreadProcessId(hwnd, out var pid);
        try
        {
            using var process = Process.GetProcessById((int)pid);
            return process.ProcessName;
        }
        catch (ArgumentException)
        {
            return "";
        }
    }

    public static (string Name, string Exe, string Title, string Process) Now()
    {
        var hwnd = Shown(GetForegroundWindow());
        if (hwnd == IntPtr.Zero)
        {
            return ("", "", "", "");
        }

        GetWindowThreadProcessId(hwnd, out var pid);
        var text = new StringBuilder(256);
        GetWindowText(hwnd, text, 256);
        try
        {
            using var process = Process.GetProcessById((int)pid);
            var exe = "";
            try
            {
                exe = process.MainModule?.FileName ?? "";
            }
            catch (Exception)
            {
            }

            var name = process.ProcessName;
            var relaunch = RelaunchExe(hwnd);
            var relaunchDir = relaunch.Length > 0 ? System.IO.Path.GetDirectoryName(relaunch) ?? "" : "";
            var ownDir = exe.Length > 0 ? System.IO.Path.GetDirectoryName(exe) ?? "" : "";
            if (relaunchDir.Length > 0 && ownDir.StartsWith(relaunchDir.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))
            {
                return (System.IO.Path.GetFileNameWithoutExtension(relaunch), relaunch, text.ToString(), name);
            }

            if (exe.Length > 0 && HelperOf(process, exe) is { } owner)
            {
                return (owner.Name, owner.Exe, text.ToString(), name);
            }

            return (name, exe, text.ToString(), name);
        }
        catch (ArgumentException)
        {
            return ("", "", "", "");
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessBasicInformation
    {
        public IntPtr Reserved1;
        public IntPtr PebBaseAddress;
        public IntPtr Reserved2a, Reserved2b;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr process, int infoClass, ref ProcessBasicInformation info, int size, out int returned);

    private static (string Name, string Exe)? HelperOf(Process process, string exe)
    {
        try
        {
            var info = FileVersionInfo.GetVersionInfo(exe);
            var own = info.FileDescription?.Trim() ?? "";
            if (own.Length > 0 && !string.Equals(own, process.ProcessName, StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            static string Maker(string? company) => (company ?? "").Trim().Split(' ', 2)[0];
            var maker = Maker(info.CompanyName);
            if (maker.Length == 0)
            {
                return null;
            }

            var current = process;
            for (var depth = 0; depth < 4; depth++)
            {
                var pbi = new ProcessBasicInformation();
                if (NtQueryInformationProcess(current.Handle, 0, ref pbi, Marshal.SizeOf<ProcessBasicInformation>(), out _) != 0)
                {
                    return null;
                }

                var parent = Process.GetProcessById((int)pbi.InheritedFromUniqueProcessId);
                // Guard against PID reuse: a parent started after its child is not its real parent.
                var parentExe = parent.StartTime <= current.StartTime ? parent.MainModule?.FileName ?? "" : "";
                if (parentExe.Length > 0 && string.Equals(parent.ProcessName, process.ProcessName, StringComparison.OrdinalIgnoreCase))
                {
                    // Only dispose intermediate parent Process handles; caller owns the initial process.
                    if (!ReferenceEquals(current, process))
                    {
                        current.Dispose();
                    }

                    current = parent;
                    continue;
                }

                if (!ReferenceEquals(current, process))
                {
                    current.Dispose();
                }

                var owner = parentExe.Length > 0 &&
                    string.Equals(Maker(FileVersionInfo.GetVersionInfo(parentExe).CompanyName), maker, StringComparison.OrdinalIgnoreCase)
                    ? (parent.ProcessName, parentExe)
                    : ((string, string)?)null;
                parent.Dispose();
                return owner;
            }

            return null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    [DllImport("user32.dll")]
    private static extern bool GetWindowDisplayAffinity(IntPtr hwnd, out uint affinity);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hwnd);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLongW(IntPtr hwnd, int index);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr hwnd, StringBuilder name, int max);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int value, int size);

    // WDA_EXCLUDEFROMCAPTURE (0x10)
    public static bool Unseen(IntPtr hwnd) => GetWindowDisplayAffinity(hwnd, out var a) && (a & 0x10) != 0;

    public static IntPtr Shown(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !Unseen(hwnd))
        {
            return hwnd;
        }

        for (var h = GetWindow(hwnd, 2 /* GW_HWNDNEXT */); h != IntPtr.Zero; h = GetWindow(h, 2))
        {
            if (!IsWindowVisible(h) || IsIconic(h) || Unseen(h))
            {
                continue;
            }

            if (DwmGetWindowAttribute(h, 14 /* DWMWA_CLOAKED */, out var cloaked, 4) == 0 && cloaked != 0)
            {
                continue;
            }

            var ex = GetWindowLongW(h, -20);
            if ((ex & 0x80) != 0 && GetWindow(h, 4 /* GW_OWNER */) == IntPtr.Zero)
            {
                continue;
            }

            // WS_EX_LAYERED | WS_EX_TRANSPARENT click-through overlay
            if ((ex & 0x80020) == 0x80020)
            {
                continue;
            }

            var cls = new StringBuilder(64);
            GetClassNameW(h, cls, 64);
            if (cls.ToString() is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd")
            {
                return IntPtr.Zero;
            }

            return h;
        }

        return IntPtr.Zero;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        int GetCount(out uint count);
        int GetAt(uint index, out PropertyKey key);
        int GetValue(ref PropertyKey key, out PropVariant value);
        int SetValue(ref PropertyKey key, ref PropVariant value);
        int Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropertyKey
    {
        public Guid Format;
        public uint Id;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropVariant
    {
        public ushort Type;
        public ushort Reserved1, Reserved2, Reserved3;
        public IntPtr Value;
        public IntPtr Value2;
    }

    [DllImport("shell32.dll")]
    private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PropVariant value);

    private static string RelaunchExe(IntPtr hwnd)
    {
        try
        {
            var iid = typeof(IPropertyStore).GUID;
            if (SHGetPropertyStoreForWindow(hwnd, ref iid, out var store) != 0 || store == null)
            {
                return "";
            }

            try
            {
                var key = new PropertyKey { Format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), Id = 2 };
                if (store.GetValue(ref key, out var value) != 0)
                {
                    return "";
                }

                // (VT_LPWSTR)
                var command = value.Type == 31 ? Marshal.PtrToStringUni(value.Value) ?? "" : "";
                PropVariantClear(ref value);
                command = command.Trim();
                string file;
                if (command.StartsWith('"'))
                {
                    var end = command.IndexOf('"', 1);
                    file = end > 0 ? command[1..end] : "";
                }
                else
                {
                    var end = command.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
                    file = end > 0 ? command[..(end + 4)] : "";
                }
                return file.Length > 0 && File.Exists(file) ? System.IO.Path.GetFullPath(file) : "";
            }
            finally
            {
                Marshal.ReleaseComObject(store);
            }
        }
        catch (Exception)
        {
            return "";
        }
    }

    public static string Title()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero)
        {
            return "";
        }

        var text = new StringBuilder(256);
        GetWindowText(hwnd, text, 256);
        return text.ToString();
    }

    public static string Path()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero)
        {
            return "";
        }

        GetWindowThreadProcessId(hwnd, out var pid);
        try
        {
            using var process = Process.GetProcessById((int)pid);
            return process.MainModule?.FileName ?? "";
        }
        catch (Exception)
        {
            return "";
        }
    }

    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);

    public static IntPtr TopWindowOf(int pid)
    {
        var found = IntPtr.Zero;
        EnumWindows((h, _) =>
        {
            GetWindowThreadProcessId(h, out var owner);
            if (owner != (uint)pid || GetWindow(h, 4) != IntPtr.Zero)
            {
                return true;
            }
            var title = new StringBuilder(64);
            GetWindowText(h, title, 64);
            if (title.ToString() == "ScreenReplay")
            {
                found = h;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WinRect
    {
        public int Left, Top, Right, Bottom;
    }

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hwnd, out WinRect rect);

    public static bool IsReplayShown(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !IsWindowVisible(hwnd))
        {
            return false;
        }
        if (DwmGetWindowAttribute(hwnd, 14 /* DWMWA_CLOAKED */, out var cloaked, 4) == 0 && cloaked != 0)
        {
            return false;
        }
        return GetWindowRect(hwnd, out var r) && (r.Right - r.Left) >= 600;
    }

    public static bool HasOtherVisibleWindow(int pid, IntPtr mainHwnd)
    {
        var any = false;
        EnumWindows((h, _) =>
        {
            if (h == mainHwnd)
            {
                return true;
            }
            GetWindowThreadProcessId(h, out var owner);
            if (owner == (uint)pid && IsWindowVisible(h))
            {
                var title = new StringBuilder(64);
                GetWindowText(h, title, 64);
                if (title.ToString() is "ScreenReplay Tray" or "ScreenReplay Note")
                {
                    any = true;
                    return false;
                }
            }
            return true;
        }, IntPtr.Zero);
        return any;
    }

    public static void Bring(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            return;
        }

        ShowWindow(hwnd, 9);
        SetForegroundWindow(hwnd);
    }
}
