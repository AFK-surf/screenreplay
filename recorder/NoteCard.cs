using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Replay.Recorder;

internal sealed class NoteCard(string exe, string root, Func<(int Pid, IntPtr Window)?> findReplay, Action<string> log) : IDisposable
{
    [DllImport("user32.dll")]
    private static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp);

    private readonly object gate = new();
    private Process? shown;
    private bool shownInProcess;
    private int id = (int)(DateTimeOffset.UtcNow.ToUnixTimeSeconds() % 1_000_000);
    private (string Mode, string Path, string Text, bool Warn) asked;

    private string NoteFile => Path.Combine(root, "note.json");

    private bool disposed;

    public bool Owns(int pid)
    {
        lock (gate)
        {
            try
            {
                return shown is { HasExited: false } && shown.Id == pid;
            }
            catch (InvalidOperationException)
            {
                return false;
            }
        }
    }

    public void Warm() { }

    public void Renew() { }

    public bool Saving() => Ask("saved", "", "", false);

    public bool Saved(string path)
    {
        lock (gate)
        {
            if (shownInProcess && asked.Mode == "saved")
            {
                asked = ("saved", path, "", false);
                var wrote = Write();
                if (findReplay() is { } found && found.Window != IntPtr.Zero)
                {
                    PostMessageW(found.Window, 0x8000 + 0x53, IntPtr.Zero, IntPtr.Zero);
                }
                return wrote;
            }

            if (shown is { HasExited: true } && asked.Mode == "saved")
            {
                return true;
            }

            if (shown is not null && asked.Mode == "saved")
            {
                asked = ("saved", path, "", false);
                return Write();
            }
        }

        return Ask("saved", path, "", false);
    }

    public bool Text(string text, bool warning) => Ask("text", "", text, warning);

    private bool Ask(string mode, string path, string text, bool warning)
    {
        lock (gate)
        {
            if (disposed)
            {
                return false;
            }

            Kill(shown);
            shown = null;
            shownInProcess = false;
            id++;
            asked = (mode, path, text, warning);
            Write();

            if (findReplay() is { } found && found.Window != IntPtr.Zero &&
                PostMessageW(found.Window, 0x8000 + 0x53, IntPtr.Zero, IntPtr.Zero))
            {
                shownInProcess = true;
                log($"note card: {mode} shown (in-process), pid {found.Pid}");
                return true;
            }

            shown = Start(mode, path, text, warning);
            log($"note card: {mode} shown (fallback), pid {shown?.Id}");
            return shown is not null;
        }
    }

    private bool Write()
    {
        try
        {
            var json = "{\"id\":" + id + ",\"mode\":" + Json(asked.Mode) + ",\"path\":" + Json(asked.Path) + ",\"text\":" +
                Json(asked.Text) + ",\"warn\":" + (asked.Warn ? "true" : "false") + "}";
            var part = NoteFile + ".part";
            File.WriteAllText(part, json);
            File.Move(part, NoteFile, overwrite: true);
            return true;
        }
        catch (Exception ex)
        {
            log("note card: not told: " + ex.Message);
            return false;
        }
    }

    // Hand-written JSON for trimmed Store builds (no reflection-based serializer).
    private static string Json(string s) => RecorderApp.Json(s);

    private Process? Start(string mode, string path, string text, bool warning)
    {
        try
        {
            var info = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(exe)! };
            info.Environment["REPLAY_NOTE"] = mode;
            info.Environment["REPLAY_NOTE_PATH"] = path;
            info.Environment["REPLAY_NOTE_TEXT"] = text;
            info.Environment["REPLAY_NOTE_WARN"] = warning ? "1" : "0";
            info.Environment["REPLAY_ROOT"] = root;
            info.Environment["MBUI_WINDOW"] = "note";
            // Skip video GPU device/decoder init since the note card only displays images.
            info.Environment["MBUI_NO_VIDEO_GPU"] = "1";
            info.Environment.Remove("REPLAY_TRAY");
            info.Environment.Remove("REPLAY_RESIDENT");
            info.Environment.Remove("REPLAY_HIDDEN");
            var started = Process.Start(info);
            ChildJob.Hold(started);
            return started;
        }
        catch (Exception ex)
        {
            log("note card: not started: " + ex.Message);
            return null;
        }
    }

    private static void Kill(Process? p)
    {
        try
        {
            if (p is { HasExited: false })
            {
                p.Kill();
            }
        }
        catch (Exception)
        {
        }

        p?.Dispose();
    }

    public void Dispose()
    {
        lock (gate)
        {
            disposed = true;
            Kill(shown);
            shown = null;
            shownInProcess = false;
        }
    }
}
